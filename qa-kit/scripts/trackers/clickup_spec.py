"""ClickUp side of the spec verbs: one subfolder per spec, one list per run, one ticket per
scenario card, one subtask (or checklist item) per check.

Identity is the `Ref` custom field (decision P5), never a title: a run list is found by the Ref
of its Run summary ticket and a ticket by its Ref key. `.qa/tracker-map.json` (kind `spec`) only
remembers the description last pushed, to tell a person's edit from a change of plan.

Dry run unless `--apply`. Nothing is deleted: a check that left the plan is set to `skipped`
and comes back to `to test` when the plan holds it again. No assignee is set and every comment is
sent with `notify_all: false`. Every string sent passes `wording.clean`, the tool's own fixed
strings included; plan text sent as markdown is escaped so it renders as written. The one-time side (Ref helpers, folder check, `spec-init`) is in
`clickup_spec_setup`; its public names are re-exported here.
"""
from __future__ import annotations

import re
import time
from typing import Any, Callable, Dict, List, Optional

from trackers import cards, clickup, wording
from trackers.clickup import PRIORITY, Folder, _arg, _keep_cache, _maybe_landed, _real, _status_of
from trackers.clickup_api import ApiError
from trackers.clickup_spec_setup import (FOLDER_FIELDS, KINDS, LETTERS, LIST_OUTSIDE, NOT_NESTED, OPEN,  # noqa: F401
                                         ROLE_OF, SUMMARY_ID, check_folder, check_id, folder_field_key, nested,
                                         parse_ref, ref, ref_key, reletter, remote_id, report_folder_fields,
                                         run_hash, save_spec, spec_init, spec_title)
from trackers.core import WordingError, content_hash, norm, same_status, status_name

CACHE_KIND = "spec"
# the tool's own fixed strings; each is sent through `SpecSync.fixed`, so it is linted like any text
SUMMARY_TITLE = "Run summary"
CHECKLIST_NAME = "Checks"
REMOVED_COMMENT = "No longer part of the plan."
BACK_COMMENT = "Back in the plan."
NEXT_LABEL = "next"
MAX_RUNS = 999          # run numbers a list's summary Ref is matched against
POLL_TRIES = 10         # a list made from a template appears after a moment
POLL_STEP = 2.0
_RUN_NAME_RE = re.compile(r"(?:^| · )Run (\d+) · ")
VIEW_STATUS, VIEW_ROLE, VIEW_FAILED = "By status", "By role", "Failed and blocked"
_MD_LINK = re.compile(r"https?://\S+|\]\([^)\s]*\)")
_MD_LEAD = re.compile(r"^([ \t]*)(#{1,6}(?=[ \t]|$)|>|[-+](?=[ \t])|\d+[.)](?=[ \t]))", re.M)


def plain_md(text: str) -> str:
    """Plan text for `markdown_content`, escaped so ClickUp shows the characters the person wrote:
    `*` and `_` anywhere outside a link, and a `#`, `>` or list marker that starts a line."""
    out, pos = [], 0
    for m in _MD_LINK.finditer(text):
        out += [re.sub(r"([*_])", r"\\\1", text[pos:m.start()]), m.group(0)]
        pos = m.end()
    out.append(re.sub(r"([*_])", r"\\\1", text[pos:]))

    def lead(m):
        mark = m.group(2)
        return f"{m.group(1)}{mark[:-1]}\\{mark[-1]}" if mark[0].isdigit() else f"{m.group(1)}\\{mark}"
    return _MD_LEAD.sub(lead, "".join(out))


def _grouping(field: str) -> dict:
    return {"field": field, "dir": 1, "collapsed": [], "ignore": False}


class SpecSync(clickup._Mirror):
    """The spec's folder, run lists and tickets. Reads are cached per list; writes go through
    `write` (a dry run only logs). Later verbs (sync-run, push-docs, spec-note) build on it."""

    def __init__(self, ctx, c: Optional[cards.Cards] = None):
        # not _Mirror.__init__: that one needs a run and reads every list of the QA folder
        self.ctx, self.cfg, self.log = ctx, ctx.cfg, ctx.log
        self.tr = clickup.transport_for(ctx)
        self.ws, self.space, self.folder_id = clickup._ids(ctx)
        self.folder = Folder(lists={}, tasks=[])
        self.lists = self.folder.lists
        self.only: List[str] = []
        self.overwrite = set(_arg(ctx, "overwrite", []) or [])
        self.today = clickup.today()
        for role in LETTERS:  # case_to_test ... case_skipped: the project's own status names
            setattr(self, f"case_{role}", status_name(self.cfg, "case", role))
        self.case_new = self.case_to_test
        self.field_defs: Dict[str, List[dict]] = {}
        self.missing_fields: set = set()
        self.missing_options: set = set()
        self.by_id: Dict[str, dict] = {}
        self.target: str = ctx.args.spec
        self.layout: str = self.cfg.get("layout") or "subfolder"
        self.spec_folder: str = self.folder_id
        if self.layout != "flat":
            folder = self.cfg.get("folder")
            self.spec_folder = remote_id(folder, f"specs.{self.target}.folder") if folder else ""
        self.pasted: str = remote_id(self.cfg["list"], f"specs.{self.target}.list") if self.cfg.get("list") else ""
        self.title: str = spec_title(ctx)
        self._cards = c
        self._tasks: Dict[str, List[dict]] = {}
        self._summary_keys: Optional[Dict[str, int]] = None
        self._dupes: set = set()
        self._fixed: Dict[str, Optional[str]] = {}
        self._person: set = set()

    # -- small helpers

    @property
    def cards(self) -> cards.Cards:
        if self._cards is None:
            self._cards = cards.load(self.ctx.project, self.target)
        return self._cards

    def fid(self, name: str) -> Optional[str]:
        """The id of a folder-level custom field (`Ref`, `Role`, ...), from the config."""
        value = (self.cfg.get("fields") or {}).get(folder_field_key(name))
        return str(value) if value else None

    def ready(self) -> bool:
        """spec-init has run: the layout is saved and the `Ref` and `Role` field ids are known."""
        missing = [f"field {n}" for n in ("Ref", "Role") if not self.fid(n)]
        if not self.cfg.get("layout") or not self.spec_folder:
            missing.insert(0, "the spec's folder")
        if missing:
            self.log.skip("not-ready", f"{', '.join(missing)}: run spec-init --spec {self.target} --apply")
        return not missing and self.placed()

    def placed(self) -> bool:
        """The spec's folder is (still) inside the QA folder, and a pasted list is in the QA
        folder's tree. Read on every run: nothing is built anywhere else."""
        qa = self.folder_id
        if self.layout != "flat" and self.spec_folder != qa and not nested(self.tr, qa, self.spec_folder):
            self.log.skip("subfolder-not-nested", f"{self.title}: {NOT_NESTED}")
            return False
        if self.pasted:
            home = str((self.get_list(self.pasted).get("folder") or {}).get("id") or "")
            if home not in (qa, self.spec_folder) and not (home and nested(self.tr, qa, home)):
                self.log.skip("list-outside", f"specs.{self.target}.list: {LIST_OUTSIDE}")
                return False
        return True

    def clean(self, item: str, value: str, kind: str = "body") -> Optional[str]:
        """`wording.clean`, or None after logging the skip."""
        try:
            return wording.clean(value, kind, self.cfg)
        except WordingError as err:
            self.log.skip("wording", f"{item}: {err.word}")
            return None

    def fixed(self, value: str, kind: str = "title") -> Optional[str]:
        """One of the tool's own fixed strings, through the same `clean` as any other text
        (checked once per run); None after the skip is logged."""
        if value not in self._fixed:
            self._fixed[value] = self.clean(f'"{value}"', value, kind)
        return self._fixed[value]

    def left(self, kind: str, detail: str) -> None:
        """`SKIP\\t<kind>\\t<detail>` for something left alone on purpose. Counted under its own
        kind, not as a skip, so it does not fail the step (P4)."""
        self.log.out.write(f"SKIP\t{kind}\t{detail}\n")
        self.log.counts[kind] = self.log.counts.get(kind, 0) + 1

    def person_changed(self, title: str, t: Optional[dict] = None) -> None:
        """Report a ticket a person changed; it is left alone and is not a failure (P4). With
        the ticket given it is reported once per run, however many steps leave it."""
        if t is not None:
            if str(t.get("id")) in self._person:
                return
            self._person.add(str(t.get("id")))
        self.left("changed-by-person", title)

    def list_name(self, n: int, label: str = NEXT_LABEL) -> str:
        """`Run <N> · <label>`; in the flat layout prefixed with the spec title."""
        name = f"Run {n} · {label}"
        return f"{self.title} · {name}" if self.layout == "flat" else name

    def label_of(self, entry: dict) -> str:
        """The run label a run list is named after (`Run <N> · <label>`), else its whole name."""
        prefix = self.list_name(entry["n"], "")
        name = entry["name"] or ""
        return name[len(prefix):] if name.startswith(prefix) and len(name) > len(prefix) else name

    def list_tasks(self, list_id: str) -> List[dict]:
        """Every task of a list (subtasks and closed included), read once."""
        if not _real(list_id):
            return []
        if list_id not in self._tasks:
            self._tasks[list_id] = self.reread(list_id)
        return self._tasks[list_id]

    def forget(self, list_id: str) -> None:
        self._tasks.pop(list_id, None)

    def ref_of(self, t: dict) -> Optional[dict]:
        """The task's parsed `Ref`, or None when it has none of ours."""
        fid = self.fid("Ref")
        return parse_ref(self.live_field(t, fid)) if fid else None

    def set_ref(self, t: dict, value: str, detail: str) -> bool:
        return self.set_field(t, self.fid("Ref"), value, detail)

    # -- run lists (decision P6)

    def folder_lists(self) -> List[dict]:
        """`{"id", "name"}` of the lists where the spec's run lists live, a pasted list included."""
        r = self.tr.request("GET", f"/v2/folder/{self.spec_folder}")
        out = [{"id": str(l["id"]), "name": l.get("name") or ""} for l in r.get("lists") or []]
        if self.pasted and self.pasted not in {l["id"] for l in out}:
            out.append({"id": self.pasted, "name": self.get_list(self.pasted).get("name") or ""})
        return out

    def run_lists(self) -> List[dict]:
        """The spec's run lists, oldest first: `{"id", "n", "run", "summary", "name"}`. `run` is
        the summary Ref's run hash, or `open`. `summary` is the Run summary ticket; it is None for
        a list still to be filled (a pasted list, or one made just before a failure)."""
        if self._summary_keys is None:
            self._summary_keys = {ref_key(self.target, n, "summary", SUMMARY_ID): n
                                  for n in range(1, MAX_RUNS + 1)}
        pasted = self.pasted
        out, unfilled = [], []
        for l in self.folder_lists():
            if self.layout == "flat" and l["id"] != pasted and not _RUN_NAME_RE.search(l["name"]):
                continue  # the QA folder also holds the Bugs and catalog lists
            entry = None
            for t in self.list_tasks(l["id"]):
                p = self.ref_of(t)
                if p and p["run"] is not None and p["key"] in self._summary_keys:
                    entry = dict(l, n=self._summary_keys[p["key"]], run=p["run"], summary=t)
                    break
            if entry is not None:
                out.append(entry)
            else:
                unfilled.append(l)
        taken = {e["n"] for e in out}
        for l in unfilled:
            m = _RUN_NAME_RE.search(l["name"])
            n = int(m.group(1)) if m else None
            # ours by the Ref of a ticket it already holds, else by the tool's own exact name
            if n is not None and l["name"] != self.list_name(n) and not self.holds_ours(l["id"], n):
                n = None
            if n is None and l["id"] == pasted:
                n = 1
            if n is not None and n not in taken:
                taken.add(n)
                out.append(dict(l, n=n, run=OPEN, summary=None))
        return sorted(out, key=lambda e: e["n"])

    def holds_ours(self, list_id: str, n: int) -> bool:
        """A list with no Run summary ticket yet holds a card or check ticket of this spec's run
        `n` (a first fill that stopped half way): it is ours whatever its name says now."""
        try:
            plan = self.cards.cards
        except cards.CardsError:
            return False
        keys = {ref_key(self.target, n, "card", c.id) for c in plan}
        keys |= {ref_key(self.target, n, "check", check_id(c.id, ck.criterion)) for c in plan for ck in c.checks}
        return any((self.ref_of(t) or {}).get("key") in keys for t in self.list_tasks(list_id))

    def open_list(self) -> Optional[dict]:
        """The list no run is tied to yet (the newest, should there be two), else None."""
        return next((e for e in reversed(self.run_lists()) if e["run"] == OPEN), None)

    def new_list(self) -> Optional[dict]:
        """Create list N+1, `Run <N> · next`; a `run_lists` entry, or None when it failed."""
        entries = self.run_lists()
        n = entries[-1]["n"] + 1 if entries else 1
        name = self.clean(f"list {n}", self.list_name(n))
        if name is None:
            return None
        templates = self.cfg.get("templates")
        template = templates.get("list") if isinstance(templates, dict) else None
        path = f"/v2/folder/{self.spec_folder}/list"
        body: Dict[str, Any] = {"name": name}
        if template:
            path = f"/v2/folder/{self.spec_folder}/list_template/{remote_id(template, 'templates.list')}"
            body["options"] = {"return_immediately": False, "include_views": True}

        def go():
            try:
                return self.tr.request("POST", path, body)
            except ApiError as err:
                if not _maybe_landed(err):
                    raise
                found = next((l for l in self.folder_lists() if l["name"] == name), None)
                if found is None:
                    raise
                self.log.act("reconciled", f"{name}: the create had landed")
                return found
        r = self.write("create-list", name, go)
        if self.log.apply and not (r and r.get("id")):
            return None
        list_id = str(r["id"]) if r and r.get("id") else f"<new:{name}>"
        if template and _real(list_id) and not self.await_list(list_id, name):
            return None
        return {"id": list_id, "name": name, "n": n, "run": OPEN, "summary": None}

    def await_list(self, list_id: str, name: str) -> bool:
        """Wait until a list made from a template answers, then check it has the folder's statuses."""
        info = None
        for attempt in range(POLL_TRIES):
            try:
                info = self.tr.request("GET", f"/v2/list/{list_id}")
                break
            except ApiError as err:
                if err.status != 404:
                    raise
                time.sleep(POLL_STEP)
        if info is None:
            self.log.skip("list-missing", f"{name}: ClickUp has not finished making it; run again")
            return False
        self.folder.list_info[list_id] = info
        live = self.list_statuses(list_id)
        lacking = [st for st in self.cfg["statuses"]["case"] if not any(same_status(st, x) for x in live)]
        if lacking:
            self.log.skip("list-statuses", f"{name}: the template's list has no status {', '.join(lacking)}")
        return not lacking

    def ensure_views(self, list_id: str, name: str) -> None:
        """The three views of a run list, found by name; only missing ones are created."""
        failed = [self.case_failed, self.case_blocked]
        views = [
            (VIEW_STATUS, {"grouping": _grouping("status")}),
            (VIEW_ROLE, {"grouping": _grouping(f"cf_{self.fid('Role')}")}),
            (VIEW_FAILED, {"grouping": _grouping("status"),
                           "filters": {"op": "AND", "search": "", "show_closed": True,
                                       "fields": [{"field": "status", "op": "EQ", "values": failed}]}}),
        ]
        have = set()
        if _real(list_id):
            have = {norm(v.get("name")) for v in self.tr.request("GET", f"/v2/list/{list_id}/view").get("views") or []}
        for fixed_name, extra in views:
            vname = self.fixed(fixed_name)
            if vname is None or norm(vname) in have:
                continue
            body = dict({"name": vname, "type": "list"}, **extra)
            self.write("create-view", f"{name}: {vname}",
                       lambda body=body: self.tr.request("POST", f"/v2/list/{list_id}/view", body))

    # -- tickets

    def tickets(self, list_id: str) -> Dict[str, dict]:
        """The list's tasks that carry one of our Refs, by `<key>` (subtasks included)."""
        out: Dict[str, dict] = {}
        for t in self.list_tasks(list_id):
            p = self.ref_of(t)
            if p is None:
                continue
            if p["key"] in out:
                if p["key"] not in self._dupes:  # two tasks with one Ref: touch the first only
                    self._dupes.add(p["key"])
                    self.log.skip("duplicate", f"{t.get('name')}: {out[p['key']]['id']}, {t['id']}")
                continue
            out[p["key"]] = t
        return out

    def remember(self, key: str, task_id: Any, desc: str) -> None:
        if self.log.apply and _real(str(task_id)):
            self.ctx.cache.put(CACHE_KIND, key, str(task_id), content_hash(desc))

    def create_ticket(self, list_id: str, key: str, ref_value: str, body: dict, role: Optional[str] = None) -> Optional[dict]:
        """Create a task in the `to test` status with its Ref on the create itself, so a create
        that landed behind a 5xx is found again by Ref and never sent twice. No assignee."""
        fields = [{"id": self.fid("Ref"), "value": ref_value}]
        if role is not None:
            fields.append({"id": self.fid("Role"), "value": role})
        body = dict(body, status=self.case_new, custom_fields=fields)

        def find(tasks: List[dict]) -> Optional[dict]:
            return next((x for x in tasks if (self.ref_of(x) or {}).get("key") == key), None)
        r = self.write("create", body["name"], self.safe_create(list_id, body, find))
        if not (r and r.get("id")):
            return None
        self.remember(key, r["id"], body.get("markdown_content", ""))
        return r

    def edited(self, key: str, t: dict, local_id: str) -> Optional[str]:
        """Why a description that differs from the plan must stay: a person edited it since the
        last push, or nothing here records what was pushed. None: it is ours to update."""
        if local_id in self.overwrite:
            return None
        entry = self.ctx.cache.get(CACHE_KIND, key)
        if entry and entry.get("hash") and str(entry.get("id")) == str(t["id"]):
            return None if content_hash(t.get("markdown_description") or "") == entry["hash"] else "person"
        return "unknown"

    def update_ticket(self, t: dict, key: str, title: str, desc: Optional[str], local_id: str,
                      priority: Optional[int] = None) -> None:
        """Bring an existing ticket's title, description and priority in line with the plan. A
        description a person edited is reported and left; its status is never touched here."""
        body: Dict[str, Any] = {}
        changed: List[str] = []
        if t.get("name") != title:
            body["name"] = title
            changed.append("title")
        if desc is not None:
            if norm(t.get("markdown_description")) == norm(desc):
                self.remember(key, t["id"], desc)
            else:
                why = self.edited(key, t, local_id)
                if why == "person":
                    self.person_changed(t.get("name") or title, t)
                elif why == "unknown":
                    self.log.skip("description-differs", f"{t.get('name') or title}: its text is not the plan's "
                                                         f"and may be a person's; --overwrite {local_id} replaces it")
                else:
                    body["markdown_content"] = desc
                    changed.append("description")
        current = int(t["priority"]["id"]) if t.get("priority") else None
        if priority is not None and current != priority:
            body["priority"] = priority
            changed.append("priority")
        if not body:
            return

        def go():
            self.tr.request("PUT", f"/v2/task/{t['id']}", body)
            if "markdown_content" in body:
                self.remember(key, t["id"], desc)
            return True
        self.write("update", f"{title} [{','.join(changed)}]", go)

    # -- a ticket's status (sync-run, spec-note)

    @staticmethod
    def put_local(t: dict, fid: str, value: Any) -> None:
        """Keep a task as read in step with a field write just made (or, in a dry run, logged)."""
        for f in t.setdefault("custom_fields", []):
            if str(f.get("id")) == fid:
                f["value"] = value
                return
        t["custom_fields"].append({"id": fid, "value": value})

    def note_local(self, t: dict, status: str, ref_value: str) -> None:
        """Keep the task as read in step with a status and Ref write just made (or just logged)."""
        t["status"] = dict(t.get("status") or {}, status=status)
        self.put_local(t, self.fid("Ref"), ref_value)

    def standing(self, t: dict) -> Optional[str]:
        """The status role the tool itself left the ticket in: the role of its Ref letter when the
        live status is that one, or, with a move in progress (two letters), whichever of the two
        the live status is. None when the live status is neither: a person changed it."""
        p = self.ref_of(t)
        if p is None:
            return None
        live = _status_of(t)
        for role in (p["role"], p["pending"]):
            if role and same_status(live, status_name(self.cfg, "case", role)):
                return role
        return None

    def set_role(self, t: dict, role: str, title: Optional[str] = None) -> bool:
        """Move a ticket to the status of `role`. The Ref says so before the status changes
        (`<from><to>`) and takes the single letter after it, so a move that stopped half way is
        finished, or redone toward the status wanted by then, on the next run. A status that is
        already the wanted one only gets its letter. False when the ticket was left: a person
        moved it to another status (reported, not a failure) or a write failed."""
        p = self.ref_of(t)
        if p is None:
            return False
        title = title or t.get("name") or ""
        want = status_name(self.cfg, "case", role)
        at = self.standing(t)
        if at is None and same_status(_status_of(t), want):
            at = role
        if at is None:
            self.person_changed(title, t)
            return False
        if at == role and p["role"] == role and p["pending"] is None:
            return True
        fid, tid = self.fid("Ref"), t["id"]
        now = self.live_field(t, fid)
        final = reletter(now, role)
        mark = reletter(now, at, pending=role)

        def go():
            if at != role:
                if now != mark:
                    self.tr.request("POST", f"/v2/task/{tid}/field/{fid}", {"value": mark})
                self.tr.request("PUT", f"/v2/task/{tid}", {"status": want})
            self.tr.request("POST", f"/v2/task/{tid}/field/{fid}", {"value": final})
            return True
        done = bool(self.write("status", f"{title}: {want}", go)) or not self.log.apply
        if done:
            self.note_local(t, want, final)
        return done

    def ticket_links(self, list_id: str) -> Dict[str, str]:
        """Card id -> the ClickUp link of its ticket in this run list (for the Results page)."""
        n = next((e["n"] for e in self.run_lists() if e["id"] == list_id), None)
        if n is None:
            return {}
        have = self.tickets(list_id)
        out = {}
        for card in self.cards.cards:
            url = (have.get(ref_key(self.target, n, "card", card.id)) or {}).get("url")
            if url:
                out[card.id] = str(url)
        return out

    # -- filling a list

    def fill(self, list_id: str, n: int, retire: bool = True) -> None:
        """Make list `n` match the cards: its views, the Run summary ticket, a ticket per card, a
        subtask or checklist item per check. Creates only what is missing; retires what left
        (not with `retire` False). A subtask of a checklist card's check, which only a run sync
        makes, is neither made nor retired here while its check is in the cards."""
        if self.log.apply and not _real(list_id):
            return
        name = self.list_name(n)
        self.ensure_views(list_id, name)
        have = self.tickets(list_id)
        summary_key = ref_key(self.target, n, "summary", SUMMARY_ID)
        wanted = {summary_key}
        if summary_key not in have:
            title = self.fixed(SUMMARY_TITLE)
            if title is not None:
                self.create_ticket(list_id, summary_key, ref(self.target, n, "summary", SUMMARY_ID), {"name": title})
        for card in self.cards.cards:
            self.fill_card(list_id, n, card, have, wanted)
        if retire:
            self.retire_removed(have, wanted)
        self.forget(list_id)

    def fill_card(self, list_id: str, n: int, card: cards.Card, have: Dict[str, dict], wanted: set) -> None:
        key = ref_key(self.target, n, "card", card.id)
        wanted.add(key)
        wanted.update(ref_key(self.target, n, "check", check_id(card.id, ck.criterion)) for ck in card.checks)
        title = self.clean(card.id, card.title, "title")
        desc = self.clean(card.id, card.storyline) if title is not None else None
        desc = plain_md(desc) if desc is not None else None
        role = self.clean(card.id, card.roleName, "title") if desc is not None else None
        if role is None:
            return
        t = have.get(key)
        if t is None:
            t = self.create_ticket(list_id, key, ref(self.target, n, "card", card.id),
                                   {"name": title, "markdown_content": desc, "priority": PRIORITY[card.priority]}, role)
            if t is None and self.log.apply:
                return  # the create failed and is reported: its checks wait for the next run
        else:
            self.bring_back(t, title)
            self.update_ticket(t, key, title, desc, card.id, PRIORITY[card.priority])
            self.set_field(t, self.fid("Role"), role, f"{title}: Role = {role}")
        if card.as_ == "checklist":
            self.fill_checklist(t, card, title)
            return
        parent = str(t["id"]) if t else f"<new:{title}>"
        for ck in card.checks:
            self.fill_check(list_id, n, card, ck, parent, role, have)

    def fill_check(self, list_id: str, n: int, card: cards.Card, ck: cards.Check, parent: str, role: str,
                   have: Dict[str, dict]) -> None:
        local = check_id(card.id, ck.criterion)
        key = ref_key(self.target, n, "check", local)
        item = f"{card.id} check"
        title = self.clean(item, ck.title, "title")
        do = self.clean(item, ck.do) if title is not None else None
        expect = self.clean(item, ck.expect) if do is not None else None
        if expect is None:
            return
        desc = f"{plain_md(do)}\n\n{plain_md(expect)}"
        t = have.get(key)
        if t is None:
            self.create_ticket(list_id, key, ref(self.target, n, "check", local),
                               {"name": title, "markdown_content": desc, "parent": parent}, role)
        else:
            self.bring_back(t, title)
            self.update_ticket(t, key, title, desc, card.id)

    def _reread_checklist(self, task_id: str) -> Optional[dict]:
        """The task's `Checks` checklist from a fresh read of the task itself, or None."""
        t = self.tr.request("GET", f"/v2/task/{task_id}")
        return next((c for c in t.get("checklists") or [] if c.get("name") == self.fixed(CHECKLIST_NAME)), None)

    def _landed(self, send: Callable[[], Any], find: Callable[[], Any], detail: str) -> Callable[[], Any]:
        """A create that is looked for again before any retry when it may have landed."""
        def go():
            try:
                return send()
            except ApiError as err:
                if not _maybe_landed(err):
                    raise
                found = find()
                if found is None:
                    raise
                self.log.act("reconciled", f"{detail}: the create had landed")
                return found
        return go

    def fill_checklist(self, t: Optional[dict], card: cards.Card, title: str) -> None:
        """A `checklist` card: one item per check in the ticket's `Checks` checklist, found by
        name. An item that left the plan stays (nothing is deleted) and is reported."""
        cname = self.fixed(CHECKLIST_NAME)
        if cname is None:
            return
        names = [x for x in (self.clean(f"{card.id} check", ck.title, "title") for ck in card.checks) if x is not None]
        task_id = str(t["id"]) if t else ""
        checklist = None
        if t is not None and _real(task_id):
            if "checklists" in t:
                checklist = next((c for c in t["checklists"] or [] if c.get("name") == cname), None)
            else:  # this read did not say: ask the task itself before making a second checklist
                checklist = self._reread_checklist(task_id)
        if checklist is None:
            r = self.write("checklist", title, self._landed(
                lambda: self.tr.request("POST", f"/v2/task/{task_id}/checklist", {"name": cname}),
                lambda: self._reread_checklist(task_id), title))
            checklist = (r.get("checklist") or r) if r else None
            if self.log.apply and not (checklist and checklist.get("id")):
                return
        items = [i.get("name") for i in (checklist or {}).get("items") or []]
        for name in names:
            if name in items:
                continue
            items.append(name)  # two checks with one title are one item, in this run and the next
            cid = (checklist or {}).get("id")
            self.write("checklist-item", f"{title}: {name}", self._landed(
                lambda name=name: self.tr.request("POST", f"/v2/checklist/{cid}/checklist_item", {"name": name}),
                lambda name=name: next((i for i in (self._reread_checklist(task_id) or {}).get("items") or []
                                        if i.get("name") == name), None), name))
        for name in items:
            if name not in names:
                self.log.act("item-left", f"{title}: {name} (no longer part of the plan)")

    def retire_removed(self, have: Dict[str, dict], wanted: set) -> None:
        """A card or check ticket that left the plan: comment once, status `skipped`, Ref letter
        `s`. Never deleted. One a person moved to another status is left and reported."""
        text = None
        for key, t in have.items():
            p = self.ref_of(t)
            if key in wanted or p is None or p["run"] is not None:
                continue
            title = t.get("name") or ""
            done = same_status(_status_of(t), self.case_skipped)
            if p["role"] == "skipped" and p["pending"] is None and done:
                continue
            if not done and self.standing(t) is None:
                self.person_changed(title, t)
                continue
            text = text or self.fixed(REMOVED_COMMENT, "body")
            if text is None:
                return

            def go(t=t, done=done):
                tid = str(t["id"])
                if self.last_note(tid) != text:
                    self.comment(tid, text)  # notify_all: false
                if not done:
                    self.tr.request("PUT", f"/v2/task/{tid}", {"status": self.case_skipped})
                # last, so a run that stopped half way is redone
                self.tr.request("POST", f"/v2/task/{tid}/field/{self.fid('Ref')}",
                                {"value": reletter(self.live_field(t, self.fid("Ref")), "skipped")})
                return True
            self.write("retire", title, go)

    def last_note(self, task_id: str) -> Optional[str]:
        """The newer of the tool's two plan notes on a ticket (`No longer part of the plan.`,
        `Back in the plan.`), or None. ClickUp lists comments newest first; `date` decides when given."""
        if not _real(task_id):
            return None
        notes = {x for x in (self.fixed(REMOVED_COMMENT, "body"), self.fixed(BACK_COMMENT, "body")) if x}
        rows = self.tr.request("GET", f"/v2/task/{task_id}/comment").get("comments") or []
        ours = [c for c in rows if str(c.get("comment_text") or "").strip() in notes]
        if not ours:
            return None
        newest = max(ours, key=lambda c: int(c["date"]) if str(c.get("date") or "").isdigit() else 0)
        return str(newest["comment_text"]).strip()

    def bring_back(self, t: dict, title: str) -> None:
        """A ticket whose card or check is in the plan again. Only one the tool itself retired
        (live status `skipped` and Ref letter `s`) goes back to `to test`, with letter `t` and one
        comment. Where status and letter disagree a person moved it: left alone and reported."""
        p = self.ref_of(t)
        if p is None or p["pending"] is not None:
            return  # a status move of a run sync is in progress: that sync finishes it
        skipped = same_status(_status_of(t), self.case_skipped)
        lettered = p["role"] == "skipped"
        if not skipped and not lettered:
            return
        tid = str(t["id"])
        text = self.fixed(BACK_COMMENT, "body")
        if text is None:
            return
        if skipped != lettered:
            # the one disagreement that is ours: a return that stopped before its last step
            half = lettered and same_status(_status_of(t), self.case_to_test) and self.last_note(tid) == text
            if not half:
                self.person_changed(t.get("name") or title, t)
                return

        def go():
            if self.last_note(tid) != text:
                self.comment(tid, text)  # notify_all: false
            if skipped:
                self.tr.request("PUT", f"/v2/task/{tid}", {"status": self.case_to_test})
            # last, so a run that stopped half way is redone
            self.tr.request("POST", f"/v2/task/{tid}/field/{self.fid('Ref')}",
                            {"value": reletter(self.live_field(t, self.fid("Ref")), "to_test")})
            return True
        self.write("return", title, go)


# ---------------------------------------------------------------- push-scenarios


def push_scenarios(ctx) -> None:
    """`tracker.sh push-scenarios`: the open run list, its views and the ticket tree, from the
    cards file. Any lint problem stops it before ClickUp is contacted."""
    target = ctx.args.spec
    c = cards.load(ctx.project, target)
    found = cards.problems(c, cards.plan_rows(ctx.project, target), ctx.cfg)
    for p in found:
        ctx.log.skip("lint", f"{p['card'] or '-'}\t{p['criterion'] or '-'}\t{p['reason']}")
    if found:
        return
    s = SpecSync(ctx, c)
    if not s.ready():
        return
    with _keep_cache(ctx):
        entry = s.open_list()
        if entry is None:
            entry = s.new_list()
        elif _real(entry["id"]) and not s.await_list(entry["id"], entry["name"]):
            return  # an adopted list (one made from a template, say) without the folder's statuses
        if entry is not None:
            s.fill(entry["id"], entry["n"])


def sync_run(ctx) -> None:
    """`tracker.sh sync-run`: a run's results, screenshots and bugs on its run list. The code is
    in `clickup_spec_sync` (imported here on use: that module builds on this one)."""
    from trackers import clickup_spec_sync
    clickup_spec_sync.sync_run(ctx)
