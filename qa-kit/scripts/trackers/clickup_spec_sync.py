"""`sync-run`: a run's recorded results on its ClickUp run list (A6).

The run is tied to a list (decision P6), then every ticket takes the status its result maps to,
"Needs a person's review" is ticked where a person has to confirm, screenshots are attached, the
Run summary ticket is written, the run's bugs are linked to their scenario tickets and old lists
are archived.

What a ticket shows comes only from `spec_runs`: nothing here works a result out, so nothing here
can make one read better than it was recorded. A ticket whose live status is not the one the tool
last wrote (its `Ref` letter) was changed by a person: it is left alone and reported, which is
not a failure. A lint problem, a failed call, a failed upload and a recorded result no ticket
shows are failures (exit 1).

Dry run unless `--apply`: nothing is written or uploaded. Nothing is deleted (lists are
archived), no assignee is set, comments are sent with `notify_all: false`, and every string sent
passes the wording lint and the redaction. A screenshot is sent under a neutral name, never its
local name or path, and only the files `spec_runs` picked are read.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from trackers import cards, clickup, core, spec_docs, spec_runs, wording
from trackers.clickup import _is_closed, _keep_cache, _real, _status_of
from trackers.clickup_api import ApiError
from trackers.clickup_spec import (CHECKLIST_NAME, OPEN, SUMMARY_ID, SUMMARY_TITLE, SpecSync, check_id, plain_md,
                                   ref, ref_key, reletter, remote_id, run_hash)
from trackers.core import WordingError, norm, same_status, status_name
from trackers.ctx import VERSION_RE, _manifest, manifest_build, run_dir_for, run_label

PLAN_CHANGED = "the plan changed since the tickets were made; run push-scenarios"
RETEST_COMMENT = "Earlier result: {status} ({label})."
RETEST_PLAIN = "Earlier result: {status}."
RESULTS_PREFIX = "Full results:"   # a line of the Run summary that starts so is kept (push-docs adds it)
REVIEW_FIELD, BUILD_FIELD = "Needs a person's review", "Build"
UPLOAD_NAME = "screen-{n}{ext}"
# lint reasons that mean the cards and the plan no longer describe the same checks
PLAN_REASONS = ("check is not in the plan", "no card for this check", "check is in two cards",
                "check is repeated in this card", "duplicate card id", "duplicate row in the plan")
_TICKED = (True, "true", "True", 1, "1")


class SyncError(Exception):
    """The sync cannot go on; the message is one plain line for the person."""


def summary_text(states: List[spec_runs.CheckState], ready: Tuple[Optional[bool], List[str]], cfg: dict) -> str:
    """The Run summary ticket's text: the counts, how many results a person has to confirm, and
    ready or not with the reasons. Like the Results page it never reads better than its counts."""
    total = spec_runs.counts(states)
    n = len(states)
    head = f"{n} {'check' if n == 1 else 'checks'}"
    detail = spec_docs._counts_text(total, cfg)
    parts = [f"{head}: {detail}." if detail else f"{head}."]
    review = total.get("needs_review", 0)
    if review:
        parts.append(f"A person needs to confirm {review} {'result' if review == 1 else 'results'}.")
    is_ready, reasons = ready if ready else (None, [])
    if is_ready is True and not spec_docs._all_done(total):
        is_ready, reasons = False, [spec_docs.NOT_FINISHED]
    if is_ready is True:
        parts.append("Ready to ship.")
    elif is_ready is False:
        parts.append("Not ready to ship.")
        if reasons:
            parts.append("\n".join(f"- {r}" for r in reasons))
    return "\n\n".join(parts)


def _put(t: dict, fid: str, value: Any) -> None:
    """Keep a task as read in step with a field write just made (or, in a dry run, logged)."""
    for f in t.setdefault("custom_fields", []):
        if str(f.get("id")) == fid:
            f["value"] = value
            return
    t["custom_fields"].append({"id": fid, "value": value})


class RunSync(SpecSync):
    """One run on its list. `bind` finds or makes the list, `tie` writes the binding, `show`
    brings one ticket in line with one check's state."""

    def __init__(self, ctx, c: Optional[cards.Cards] = None):
        super().__init__(ctx, c)
        self.run_dir: Path = run_dir_for(ctx.project, getattr(ctx.args, "run", None))
        self.run_id: str = self.run_dir.name
        self.label: str = run_label(self.run_dir, ctx.args)
        self.build: str = manifest_build(_manifest(self.run_dir))
        self.retest: bool = bool(getattr(ctx.args, "retest", False)) or self.cfg.get("listMode") == "reuse"
        self.earlier: Optional[str] = None   # the label of the run a retest replaces
        self._lacking_fields: set = set()
        self._build_text: Optional[str] = None

    # -- small helpers

    def did(self, out: Any) -> bool:
        """A `write` went through, or is a dry run's logged line."""
        return bool(out) or not self.log.apply

    def key(self, n: int, kind: str, local_id: str) -> str:
        return ref_key(self.target, n, kind, local_id)

    def run_text(self, item: str, value: str, kind: str = "body", quiet: bool = False) -> Optional[str]:
        """`clean` for text that carries a run label: the label's build number (`v1.4.46`) is a
        version the reader knows the build by, not an internal id, so the lint lets it through."""
        versions = [w for w in re.split(r"[\s()]+", value) if VERSION_RE.match(w) and ("." in w or w[:1] == "v")]
        cfg = self.cfg
        if versions:
            cfg = core.Config(self.cfg)
            cfg.project = getattr(self.cfg, "project", None)
            rules = dict(cfg.get("wording") or {})
            rules["allow"] = list(rules.get("allow") or []) + [w.rstrip(".") for w in versions]
            cfg["wording"] = rules
        try:
            return wording.clean(value, kind, cfg)
        except WordingError as err:
            if not quiet:
                self.log.skip("wording", f"{item}: {err.word}")
            return None

    def field(self, name: str) -> Optional[str]:
        """A folder field's id; a missing one is a failure, reported once."""
        fid = self.fid(name)
        if not fid and name not in self._lacking_fields:
            self._lacking_fields.add(name)
            self.log.skip("field-missing", f"{name}: run tracker.sh init, then spec-init")
        return fid

    def checklist_of(self, t: dict) -> Optional[dict]:
        """The `Checks` checklist of a card ticket; asked from the task when the read left it out."""
        cname = self.fixed(CHECKLIST_NAME)
        if "checklists" in t:
            return next((c for c in t["checklists"] or [] if c.get("name") == cname), None)
        return self._reread_checklist(str(t["id"])) if _real(str(t["id"])) else None

    def item_name(self, card: cards.Card, ck: cards.Check) -> Optional[str]:
        return self.clean(f"{card.id} check", ck.title, "title")

    def plan_keys(self, n: int) -> List[str]:
        """The Ref keys of the plan's tickets in list `n`: the summary, every card, every check."""
        out = [self.key(n, "summary", SUMMARY_ID)]
        for card in self.cards.cards:
            out.append(self.key(n, "card", card.id))
            out += [self.key(n, "check", check_id(card.id, ck.criterion)) for ck in card.checks]
        return out

    # -- the run's list (decision P6)

    def archived(self, run: str) -> bool:
        """This run's list is among the archived ones. Only archived lists named after this run's
        label are read, so a new run costs one extra read."""
        try:
            rows = self.tr.request("GET", f"/v2/folder/{self.spec_folder}/list?archived=true").get("lists") or []
        except ApiError as err:
            if err.status in (401, 403) or not 400 <= err.status < 500:
                raise
            return False
        for l in rows:
            name = l.get("name") or ""
            if not name.endswith(f" · {self.label}"):
                continue
            for t in self.list_tasks(str(l["id"])):
                p = self.ref_of(t)
                if p and p["run"] == run and p["key"] in (self._summary_keys or {}):
                    self.log.skip("archived", f"{name}: the list of this run is archived; "
                                              f"restore it in ClickUp to sync the run again")
                    return True
        return False

    def bind(self, run_id: Optional[str] = None) -> Optional[dict]:
        """The run's list, a `run_lists` entry: the one whose Run summary names the run; on a
        retest the spec's newest list; else the open list; else a new list N+1, filled. None after
        a logged skip. Nothing is tied here: `tie` writes the list's name and the summary's Ref."""
        run = run_hash(run_id or self.run_id)
        entries = self.run_lists()
        entry = next((e for e in entries if e["run"] == run), None)
        if entry is None and self.retest and entries and entries[-1]["run"] != OPEN:
            entry = entries[-1]
            self.earlier = self.label_of(entry)
        if entry is None:
            if self.archived(run):
                return None
            entry = self.open_list()
        if entry is None:
            entry = self.new_list()
            if entry is not None:
                before = self.log.counts.get("skip", 0)
                self.fill(entry["id"], entry["n"])
                if self.log.counts.get("skip", 0) != before:
                    return None  # the fill is reported; the next sync finds the list and goes on
        return entry

    def lacking(self, have: Dict[str, dict], n: int) -> bool:
        """The list has no ticket (or checklist item) for something the plan holds now."""
        wanted = [self.key(n, "summary", SUMMARY_ID)]
        for card in self.cards.cards:
            wanted.append(self.key(n, "card", card.id))
            if card.as_ != "checklist":
                wanted += [self.key(n, "check", check_id(card.id, ck.criterion)) for ck in card.checks]
        if any(k not in have for k in wanted):
            return True
        for card in self.cards.cards:
            if card.as_ != "checklist":
                continue
            checklist = self.checklist_of(have[self.key(n, "card", card.id)])
            items = {i.get("name") for i in (checklist or {}).get("items") or []}
            if any(self.item_name(card, ck) not in items for ck in card.checks):
                return True
        return False

    def tie(self, entry: dict, have: Dict[str, dict]) -> bool:
        """Tie the list to the run: on a retest every ticket is first reset, then the list is
        named after the run, and last the Run summary's Ref takes the run (so a tie that stopped
        half way is done again). False when a step failed: nothing more is written."""
        lid, n = entry["id"], entry["n"]
        summary = have[self.key(n, "summary", SUMMARY_ID)]
        fresh = self.ref_of(summary)["run"] != run_hash(self.run_id)
        name = None
        # only a name the tool gave is replaced: its own `next`, or on a new tie its `Run <N> · ...`
        if entry["name"] == self.list_name(n) or (fresh and entry["name"].startswith(self.list_name(n, ""))):
            name = self.run_text(f"list {n}", self.list_name(n, self.label))
            if name is None:
                return False
        if fresh and self.earlier is not None and not self.reset(have, n):
            return False
        if name is not None and entry["name"] != name:
            if not self.did(self.write("rename-list", name,
                                       lambda: self.tr.request("PUT", f"/v2/list/{lid}", {"name": name}) or True)):
                return False
        if not fresh:
            return True
        fid = self.fid("Ref")
        value = reletter(self.live_field(summary, fid), self.ref_of(summary)["role"], run=self.run_id)
        if not self.did(self.write("bind", name or entry["name"], lambda: self.tr.request(
                "POST", f"/v2/task/{summary['id']}/field/{fid}", {"value": value}) or True)):
            return False
        _put(summary, fid, value)
        return True

    # -- a retest

    def reset(self, have: Dict[str, dict], n: int) -> bool:
        """Before a retest's results: each ticket of the plan gets its earlier result as a
        comment and goes back to the first status, a person's own status included (the comment
        keeps what it said). Checklist items are opened again. False when a write failed."""
        before = self.log.counts.get("skip", 0)
        for key in self.plan_keys(n):
            if key in have:
                self.reset_ticket(have[key])
        for card in self.cards.cards:
            if card.as_ == "checklist":
                t = have[self.key(n, "card", card.id)]
                checklist = self.checklist_of(t)
                for ck in card.checks:
                    self.tick(checklist, t, card, ck, False, kind="retest")
        return self.log.counts.get("skip", 0) == before

    def reset_ticket(self, t: dict) -> None:
        p, live = self.ref_of(t), _status_of(t)
        first = same_status(live, self.case_to_test)
        if p["role"] == "to_test" and first:
            return
        title, tid = t.get("name") or "", str(t["id"])
        text = None
        if not first:  # in the first status with another letter: a reset that stopped before its last step
            shown = next((x for x in self.cfg["statuses"]["case"] if same_status(x, live)), live)
            # the label is read from the list's name, which a person may have changed: when it does
            # not pass the writing rules the comment goes without it
            text = (self.run_text(title, RETEST_COMMENT.format(status=shown, label=self.earlier), quiet=True)
                    or self.run_text(title, RETEST_PLAIN.format(status=shown)))
            if text is None:
                return
        value = reletter(self.live_field(t, self.fid("Ref")), "to_test")

        def go():
            if text is not None:
                if (self.comments(tid) or [""])[0] != text:
                    self.comment(tid, text)  # notify_all: false
                self.tr.request("PUT", f"/v2/task/{tid}", {"status": self.case_to_test})
            # last, so a reset that stopped half way is done again
            self.tr.request("POST", f"/v2/task/{tid}/field/{self.fid('Ref')}", {"value": value})
            return True
        if self.did(self.write("retest", title, go)):
            self.note_local(t, self.case_to_test, value)

    # -- one ticket

    def tick(self, checklist: Optional[dict], t: dict, card: cards.Card, ck: cards.Check, done: bool,
             kind: str = "checklist-item") -> None:
        """Resolve (or open again) a check's item in its card's checklist."""
        name = self.item_name(card, ck)
        item = next((i for i in (checklist or {}).get("items") or [] if i.get("name") == name), None)
        if item is None or bool(item.get("resolved")) == done:
            return
        path = f"/v2/checklist/{checklist['id']}/checklist_item/{item['id']}"
        detail = f"{t.get('name') or ''}: {name} ({'done' if done else 'open'})"
        if self.did(self.write(kind, detail, lambda: self.tr.request("PUT", path, {"resolved": done}) or True)):
            item["resolved"] = done

    def raise_check(self, lid: str, n: int, card: cards.Card, ck: cards.Check, parent: dict) -> Optional[dict]:
        """A checklist check that failed, is blocked or needs a review gets its own subtask, so
        it is never hidden in a checklist. Created with its Ref, like every ticket."""
        local = check_id(card.id, ck.criterion)
        item = f"{card.id} check"
        title = self.clean(item, ck.title, "title")
        do = self.clean(item, ck.do) if title is not None else None
        expect = self.clean(item, ck.expect) if do is not None else None
        role = self.clean(card.id, card.roleName, "title") if expect is not None else None
        if role is None:
            return None
        value = ref(self.target, n, "check", local)
        t = self.create_ticket(lid, self.key(n, "check", local), value,
                               {"name": title, "markdown_content": f"{plain_md(do)}\n\n{plain_md(expect)}",
                                "parent": str(parent["id"])}, role)
        if t is not None and self.ref_of(t) is None:  # the answer to the create left the field out
            self.note_local(t, self.case_to_test, value)
        return t

    def set_review(self, t: dict, want: bool, title: str) -> None:
        fid = self.fid(REVIEW_FIELD)
        if not fid:
            if want:
                self.field(REVIEW_FIELD)
            return
        if (self.live_field(t, fid) in _TICKED) == want:
            return
        detail = f"{title}: needs a person's review = {'yes' if want else 'no'}"
        if self.did(self.write("set-field", detail, lambda: self.tr.request(
                "POST", f"/v2/task/{t['id']}/field/{fid}", {"value": want}) or True)):
            _put(t, fid, want)

    def set_build(self, t: dict, title: str) -> None:
        if not self.build:
            return
        fid = self.field(BUILD_FIELD)
        if not fid:
            return
        if self._build_text is None:
            self._build_text = core.outbound(self.build, self.cfg)
        if self.set_field(t, fid, self._build_text, f"{title}: build = {self._build_text}"):
            _put(t, fid, self._build_text)

    def note(self, t: dict, text: str, title: str) -> None:
        """One of `spec_runs`' fixed sentences as a comment, once."""
        text = self.fixed(text, "body")
        if text is None or text in self.comments(str(t["id"])):
            return
        self.say_comment(t, text, f"{title}: note")

    def attached(self, task_id: str) -> set:
        """The file names already on a ticket (`title`, with its `extension` when left out)."""
        out = set()
        for a in self.tr.request("GET", f"/v2/task/{task_id}").get("attachments") or []:
            title, ext = str(a.get("title") or ""), str(a.get("extension") or "")
            out.add(title)
            if ext and not title.lower().endswith(f".{ext.lower()}"):
                out.add(f"{title}.{ext.lower()}")
        return out

    def attach(self, t: dict, evidence: List[Path], title: str) -> None:
        """Upload the screenshots `spec_runs` picked, each once, as `screen-<n>.<ext>`: a name
        already on the ticket is skipped. The local name and path are never sent."""
        tid = str(t["id"])
        if not evidence or not _real(tid):
            return
        have: Optional[set] = None
        for i, path in enumerate(evidence, 1):
            name = UPLOAD_NAME.format(n=i, ext=Path(path).suffix.lower())
            if have is None:
                have = self.attached(tid)
            if name in have:
                continue

            def go(path=path, name=name):
                try:
                    self.tr.upload(f"/v2/task/{tid}/attachment", Path(path), name)
                except OSError:
                    self.log.skip("upload-failed", f"{title}: {name} could not be read")
                    return None
                return True
            self.write("attach", f"{title}: {name}", go)

    def show(self, t: dict, s: spec_runs.CheckState) -> None:
        """One check's state on its ticket: the status first (a ticket a person moved is left
        whole), then the review tick, the build, the note and the screenshots."""
        title = t.get("name") or ""
        if not self.set_role(t, s.role, title):
            return
        self.set_review(t, s.needs_review, title)
        self.set_build(t, title)
        if s.note:
            self.note(t, s.note, title)
        self.attach(t, s.evidence, title)

    # -- the whole run

    def show_all(self, states: List[spec_runs.CheckState], lid: str, n: int, have: Dict[str, dict]) -> None:
        by_card: Dict[str, List[spec_runs.CheckState]] = {}
        for s in states:
            by_card.setdefault(s.card_id, []).append(s)
        for card in self.cards.cards:
            mine = by_card.get(card.id, [])
            by_check = {s.criterion: s for s in mine}
            t = have[self.key(n, "card", card.id)]
            listed = card.as_ == "checklist"
            checklist = self.checklist_of(t) if listed else None
            for ck in card.checks:
                s = by_check.get(ck.criterion)
                if s is None or s.role is None:
                    continue  # not run yet: the ticket stays as it is
                sub = have.get(self.key(n, "check", check_id(card.id, ck.criterion)))
                if listed:
                    self.tick(checklist, t, card, ck, s.role == "passed")
                    if sub is None and s.raised:
                        sub = self.raise_check(lid, n, card, ck, t)
                if sub is not None:
                    self.show(sub, s)
            if self.set_role(t, spec_runs.card_role(mine)):
                self.set_build(t, t.get("name") or "")

    def summarise(self, states: List[spec_runs.CheckState], t: dict) -> None:
        """The Run summary ticket: the worst status of the run, the counts, ready or not."""
        title = t.get("name") or SUMMARY_TITLE
        # the counts are the tool's own text: written even where a person set the ticket's status
        if self.set_role(t, spec_runs.card_role(states), title):
            self.set_build(t, title)
        text = self.clean("run summary", summary_text(states, spec_runs.ready(self.run_dir), self.cfg))
        if text is None:
            return
        live = t.get("markdown_description") or ""
        kept = [ln for ln in live.splitlines() if ln.startswith(RESULTS_PREFIX)]
        desc = text + (f"\n\n{kept[0]}" if kept else "")
        if norm(live) == norm(desc):
            return

        def go():
            self.tr.request("PUT", f"/v2/task/{t['id']}", {"markdown_content": desc})
            return True
        if self.did(self.write("update", f"{title} [description]", go)):
            t["markdown_description"] = desc

    def report(self, states: List[spec_runs.CheckState]) -> None:
        """What the run recorded and no ticket can show: a result with no card (a failure) and a
        screenshot that is not there (reported only, P11)."""
        for criterion, persona, verdict in spec_runs.unjoined(self.run_dir, self.cards):
            who = f"{criterion} ({persona})" if persona else criterion
            self.log.skip("no-ticket", f"{who}: recorded as {verdict}, and no scenario ticket shows it; "
                                       f"add it to a card, then run push-scenarios")
        titles = {}
        for card in self.cards.cards:
            for ck in card.checks:
                titles[(card.id, ck.criterion)] = ck.title
        by_row = {(s.criterion, s.persona): titles.get((s.card_id, s.criterion)) for s in states}
        for criterion, persona in spec_runs.missing_evidence(self.run_dir, self.cards, self.cfg):
            self.log.act("evidence-missing", f"{by_row.get((criterion, persona)) or criterion}: "
                                             f"a recorded screenshot is not there or cannot be used")

    def bugs_home(self) -> Optional[Tuple[str, str]]:
        """`(Bugs list id, its Ref field id)` when the project keeps its bugs in the QA folder."""
        name = (self.cfg.get("lists") or {}).get("bugs") or clickup.BUGS_LIST
        fid = (self.cfg.get("fields") or {}).get(clickup.field_key(name, "Ref"))
        live = {str(l.get("name")): str(l["id"])
                for l in self.tr.request("GET", f"/v2/folder/{self.folder_id}").get("lists") or []}
        lid = str((self.cfg.get("listIds") or {}).get(name) or live.get(name) or "")
        if not fid or not lid or lid not in live.values():
            return None
        return remote_id(lid, f"listIds.{name}"), str(fid)

    def link_bugs(self, n: int, have: Dict[str, dict]) -> None:
        """Link each bug of this run, found in the Bugs list by its `Ref` fingerprint, to the
        scenario ticket that holds its check (decision P10). A bug with no ticket is reported."""
        if self.cfg.get("bugsTo") == "issue-tracker":
            return
        rows = [r for r in clickup._bug_rows(self.run_dir) if not r.get("duplicateOf")]
        if not rows:
            return
        found = self.bugs_home()
        if found is None:
            self.log.act("bugs-not-linked", "the Bugs list is not set up; run tracker.sh init")
            return
        bid, ref_fid = found
        bugs = self.reread(bid)
        results = core.case_results(self.run_dir)
        closed = status_name(self.cfg, "bug", "closed")
        done: set = set()
        for row in rows:
            criterion = str(row.get("criterionId") or row.get("criterion_id") or "")
            persona = str(row.get("persona") or "")
            raw = str(row.get("title") or "").strip()
            if not raw:
                continue
            # the fingerprint push-bug wrote into the bug's Ref
            mark = core.fingerprint(clickup._case_of(results, criterion) or criterion or str(row.get("id") or ""),
                                    persona, raw)
            if mark in done:
                continue
            done.add(mark)
            shown = core.redact(raw, self.cfg)  # printed here only, never sent
            matches = [b for b in bugs if str(self.live_field(b, ref_fid) or "") == mark]
            bug = next((b for b in matches if not _is_closed(b, closed)), matches[0] if matches else None)
            if bug is None:
                self.log.act("bug-not-found", f"{shown}: not in the Bugs list yet; run push-bug first")
                continue
            card = cards.card_for(self.cards, criterion, persona)
            ticket = have.get(self.key(n, "card", card.id)) if card is not None else None
            if ticket is None:
                self.log.act("bug-unlinked", f"{shown}: no scenario ticket holds its check")
                continue
            bug_id, ticket_id = str(bug["id"]), str(ticket["id"])
            linked = set()
            for link in self.tr.request("GET", f"/v2/task/{bug_id}").get("linked_tasks") or []:
                linked |= {str(link.get("task_id")), str(link.get("link_id"))}
            if ticket_id in linked:
                continue
            self.write("link-bug", f"{shown}: {ticket.get('name') or ''}",
                       lambda b=bug_id, k=ticket_id: self.tr.request("POST", f"/v2/task/{b}/link/{k}") or True)

    def archive(self, current: str) -> None:
        """Archive the spec's run lists older than the newest `keepRuns` that have a run. Never
        an open list, the list just synced or a list of another spec (`run_lists` gives ours)."""
        keep = self.cfg.get("keepRuns")
        keep = keep if isinstance(keep, int) and not isinstance(keep, bool) and keep >= 1 else 3
        bound = [e for e in self.run_lists() if e["run"] != OPEN and e["summary"] is not None]
        for e in bound[:-keep]:
            if e["id"] == current or self.get_list(e["id"]).get("archived"):
                continue
            self.write("archive-list", e["name"],
                       lambda e=e: self.tr.request("PUT", f"/v2/list/{e['id']}", {"archived": True}) or True)

    def run(self) -> None:
        states = spec_runs.states(self.run_dir, self.cards, self.cfg)
        if not any(s.role for s in states) and spec_runs.unjoined(self.run_dir, self.cards):
            # e.g. the newest run is another spec's: tying a list to it would use up this spec's list
            self.log.skip("other-run", "none of this run's results belongs to this spec's cards; "
                                       "name the run with --run")
            return
        self.report(states)
        entry = self.bind()
        if entry is None:
            return
        lid, n = entry["id"], entry["n"]
        if not _real(lid):
            return  # a dry run with no list yet: its creates are logged
        have = self.tickets(lid)
        if self.lacking(have, n):
            raise SyncError(PLAN_CHANGED)
        if not self.tie(entry, have):
            return
        self.show_all(states, lid, n, have)
        self.summarise(states, have[self.key(n, "summary", SUMMARY_ID)])
        self.link_bugs(n, have)
        if self.log.apply and not self.log.counts.get("skip"):
            self.archive(lid)


def sync_run(ctx) -> None:
    """`tracker.sh sync-run [--run <id>] [--retest]`. A plan the cards no longer cover stops it
    before anything is written; a wording problem in the cards stops it before ClickUp is contacted."""
    target = ctx.args.spec
    c = cards.load(ctx.project, target)
    found = cards.problems(c, cards.plan_rows(ctx.project, target), ctx.cfg)
    if any(p["reason"] in PLAN_REASONS for p in found):
        raise SyncError(PLAN_CHANGED)
    for p in found:
        ctx.log.skip("lint", f"{p['card'] or '-'}\t{p['criterion'] or '-'}\t{p['reason']}")
    if found:
        return
    s = RunSync(ctx, c)
    if not s.ready():
        return
    with _keep_cache(ctx):
        s.run()
