"""`sync-run` through cli.main, against the in-memory ClickUp space of the structure tests.

`SyncFake` adds what a run sync touches: attachments (seen only on a single task read, as ClickUp
answers), uploads, task links, checklist item updates, list renames and archiving (an archived
list leaves the folder's list and is listed only with `archived=true`), and tasks that carry a
list-level field (the Bugs list's own `Ref`).
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shutil
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import offline_guard  # noqa: E402,F401  (first: no test reaches the network)

from test_spec_clickup_structure import (ADMIN_CARD, JUDGE_CARD, OWN_STATUSES, QA, TARGET, SpecBase,  # noqa: E402
                                         SpecFake)
from trackers import core  # noqa: E402
from trackers.clickup_api import ApiError  # noqa: E402



class _Spec:
    """`trackers.clickup_spec`, imported on first use. Importing it when this file is loaded
    would set it on the `trackers` package before test_spec_cli runs, and that file's stub of the
    module in `sys.modules` would then be passed by."""

    def __getattr__(self, name):
        from trackers import clickup_spec
        return getattr(clickup_spec, name)


cs = _Spec()
RUN_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "spec" / "run"
RUN_1, RUN_2 = "2026-11-27-judge-scoring", "2026-11-28-judge-scoring"
SAVE, REFUSE, JUDGE_RANK = "Save a valid score", "Refuse a score above the maximum", "Judge sees the ranking"
ADMIN_RANK, HACKATHONS = "Admin sees the ranking", "Hackathon list opens"
LOAD = "load-clean:GET /admin/hackathons:admin"
REVIEW_NOTE = "Passed on this run. A person needs to confirm the expected result."
BUG_TITLE = "A score above the maximum is saved"
NO_RESULTS = "SKIP\tno-results\tthis run has no results for this spec; nothing was synced"
LIST_UNUSED = ("SKIP\tlist-unused\tRun 2 · next: a retest uses the list of the newest run; "
               "this list is left for the next new run")
NEW_CHECK = {"criterion": "C-SCORE-03", "title": "Change a saved score",
             "do": "Open a scored submission, type 6 and press Save.", "expect": "The new score replaces the old one."}


def named(data):
    """The name a screenshot is sent under: `screen-<first 6 hex of its sha256>.png`."""
    return f"screen-{hashlib.sha256(data).hexdigest()[:6]}.png"


def shot(persona, criterion, phase):
    """The upload name of one of the run fixture's screenshots."""
    return named((RUN_FIXTURE / "evidence" / persona / criterion / f"screenshot-{phase}.png").read_bytes())


def row(criterion, persona, verdict, confidence="high"):
    return {"criterion_id": criterion, "persona": persona, "verdict": verdict, "confidence": confidence}


ALL_PASS = [row("C-SCORE-01", "judge", "pass"), row("C-SCORE-02", "judge", "pass"), row("C-RANK-01", "judge", "pass"),
            row("C-RANK-01", "admin", "pass"), row(LOAD, "admin", "pass")]


class SyncFake(SpecFake):
    def __init__(self, statuses):
        super().__init__(statuses)
        self.attachments: dict = {}    # task id -> [{"title", "extension", "data"}]
        self.links: dict = {}          # task id -> the task ids it is linked with
        self.fail_uploads = 0          # the next uploads answer HTTP 500
        self.attach_reads = True       # False: the single task read lists the title without its extension

    def view(self, t):
        out = super().view(t)
        known = {f["id"] for f in out["custom_fields"]}
        out["custom_fields"] += [{"id": k, "name": "Ref", "type": "short_text", "value": v}
                                 for k, v in t["values"].items() if k not in known]
        out["url"] = f"https://app.clickup.com/t/{t['id']}"
        return out

    def add_bug(self, title, ref, status="open"):
        tid = self.new_id("t")
        self.tasks[tid] = {"id": tid, "name": title, "status": {"status": status, "type": "custom"},
                           "list": {"id": "905", "name": "Bugs"}, "parent": None, "priority": None,
                           "markdown_description": "", "values": {"f-bug-ref": ref}}
        return self.tasks[tid]

    def names_on(self, task_id):
        return [a["title"] for a in self.attachments.get(task_id, [])]

    def upload(self, path, file_path, filename):
        self.calls.append(("UPLOAD", path, filename))
        data = Path(file_path).read_bytes()  # a missing file fails here, as in the real transport
        m = re.fullmatch(r"/v2/task/(\w+)/attachment", path)
        if not m or m.group(1) not in self.tasks:
            raise ApiError("POST", path, 404, "Task not found")
        if self.fail_uploads:
            self.fail_uploads -= 1
            raise ApiError("POST", path, 500, "internal error")
        self.attachments.setdefault(m.group(1), []).append(
            {"title": filename, "extension": filename.rsplit(".", 1)[-1], "data": data})
        return {"id": self.new_id("a"), "title": filename}

    def request(self, method, path, body=None):
        method = method.upper()
        m = re.fullmatch(r"/v2/task/(\w+)", path)
        if m and method == "GET" and m.group(1) in self.tasks:
            out = self.view(self.tasks[m.group(1)])
            out["attachments"] = [{"title": a["title"] if self.attach_reads else a["title"].rsplit(".", 1)[0],
                                   "extension": a["extension"]} for a in self.attachments.get(m.group(1), [])]
            out["linked_tasks"] = [{"task_id": m.group(1), "link_id": other}
                                   for other in sorted(self.links.get(m.group(1), set()))]
            return out
        m = re.fullmatch(r"/v2/checklist/(\w+)/checklist_item/(\w+)", path)
        if m and method == "PUT" and m.group(1) in self.checklists:
            self.calls.append((method, path, dict(body)))
            item = next(i for i in self.checklists[m.group(1)]["items"] if i["id"] == m.group(2))
            item.update({k: v for k, v in body.items() if k in ("resolved", "name")})
            return {"checklist": dict(self.checklists[m.group(1)])}
        m = re.fullmatch(r"/v2/task/(\w+)/link/(\w+)", path)
        if m and method == "POST" and m.group(1) in self.tasks and m.group(2) in self.tasks:
            self.calls.append((method, path, body))
            self.links.setdefault(m.group(1), set()).add(m.group(2))
            self.links.setdefault(m.group(2), set()).add(m.group(1))
            return {"task": self.view(self.tasks[m.group(1)])}
        m = re.fullmatch(r"/v2/list/(\w+)", path)
        if m and method == "PUT" and m.group(1) in self.lists:
            self.calls.append((method, path, dict(body)))
            self.lists[m.group(1)].update({k: v for k, v in body.items() if k in ("name", "archived")})
            return self.list_view(self.lists[m.group(1)])
        m = re.fullmatch(r"/v2/folder/(\w+)/list\?archived=true", path)
        if m and method == "GET" and m.group(1) in self.folders:
            return {"lists": [{"id": l["id"], "name": l["name"]} for l in self.lists.values()
                              if l["folder"] == m.group(1) and l["archived"]]}
        return super().request(method, path, body)


class SyncBase(SpecBase):
    def new_project(self):
        super().new_project()
        self.fake = SyncFake(self.statuses)
        self.add_run(RUN_1)

    def setUp(self):
        super().setUp()
        self.ready()
        self.assertEqual(self.push()[0], 0)
        self.fake.calls.clear()

    def record(self, run_id, rows):
        """Write the run's recorded rows; its other files stay as they are."""
        path = self.tmp / ".qa" / "runs" / run_id / "checkpoint.json"
        path.write_text(json.dumps({"criteria": rows}), encoding="utf-8")

    def only_shot(self, run_id, persona, criterion, data):
        """Make `data` the one screenshot of a check in this run; returns the name it is sent under."""
        folder = self.tmp / ".qa" / "runs" / run_id / "evidence" / persona / criterion
        for f in folder.iterdir():
            f.unlink()
        (folder / "screenshot-after.png").write_bytes(data)
        return named(data)

    def fail_ref(self, name, pending, status=502):
        """The next write of this ticket's Ref that carries a move in progress (two letters), or
        with `pending` False its final single letter, fails before it lands."""
        tid = self.fake.task(name)["id"]
        real, left = self.fake.request, [1]

        def flaky(method, path, body=None):
            if left[0] and method == "POST" and path == f"/v2/task/{tid}/field/f-ref":
                if (len(body["value"].split("-")[2]) == 2) == pending:
                    left[0] = 0
                    raise ApiError(method, path, status, "bad gateway")
            return real(method, path, body)
        self.fake.request = flaky

    def touched(self, name, lid=None):
        """The calls made on one ticket."""
        tid = self.fake.task(name, lid)["id"]
        return [c for c in self.fake.calls if re.search(rf"/{tid}(/|$)", c[1])]

    def add_check(self, card=0, check=NEW_CHECK, persona="judge"):
        self.edit_cards(lambda d: d["cards"][card]["checks"].append(dict(check)))
        self.edit_plan(lambda rows: rows + [{"id": check["criterion"], "persona": persona, "kind": "happy-path"}])

    def add_run(self, run_id, rows=None, manifest=None):
        run_dir = self.tmp / ".qa" / "runs" / run_id
        shutil.copytree(RUN_FIXTURE, run_dir, dirs_exist_ok=True)
        if rows is not None:
            self.record(run_id, rows)
        if manifest is not None:
            (run_dir / "run-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return run_dir

    def sync(self, *extra, run=RUN_1, apply=True):
        return self.tracker("sync-run", "--run", run, *extra, apply=apply)

    def lists(self, archived=False):
        folder = self.cfg()["specs"][TARGET]["folder"]
        return [l for l in self.fake.lists.values() if l["folder"] == folder and l["archived"] == archived]

    def state(self, name, lid=None):
        t = self.fake.task(name, lid)
        return t["status"]["status"], cs.parse_ref(t["values"]["f-ref"])["letter"]

    def summary(self, lid=None):
        return self.fake.task("Run summary", lid)

    def texts(self, name, lid=None):
        return [c["comment_text"] for c in self.fake.comments.get(self.fake.task(name, lid)["id"], [])]

    def move(self, name, status):
        self.fake.task(name)["status"]["status"] = status

    def assert_quiet(self):
        """Nothing sent names a person, notifies anybody or carries an id, a path or a local file name."""
        sent = json.dumps(self.fake.calls, ensure_ascii=False)
        for token in ("C-SCORE", "C-RANK", "load-clean", "judge-scores-a-submission", TARGET, RUN_1,
                      "assignee", "screenshot-", str(self.tmp)):
            self.assertNotIn(token, sent)
        for rows in self.fake.comments.values():
            self.assertTrue(all(c["notify_all"] is False for c in rows))


class BindingTests(SyncBase):
    def test_first_sync_binds_open_list_and_renames(self):
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        run = self.run_list()
        self.assertEqual(run["name"], "Run 1 · 2026-11-27")
        self.assertEqual(self.fake.writes("PUT", r"/v2/list/\w+$"), [("PUT", f"/v2/list/{run['id']}",
                                                                     {"name": "Run 1 · 2026-11-27"})])
        self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], cs.run_hash(RUN_1))
        self.assertEqual(self.fake.writes("POST", r"/list$"), [])
        self.assert_quiet()

    def test_second_run_creates_list_2(self):
        self.assertEqual(self.sync()[0], 0)
        before = {t["id"]: json.dumps(t, sort_keys=True) for t in self.fake.tasks_in(self.run_list()["id"])}
        self.add_run(RUN_2, ALL_PASS)
        rc, lines, err = self.sync(run=RUN_2)
        self.assertEqual(rc, 0, (lines, err))
        first, second = self.lists()
        self.assertEqual((first["name"], second["name"]), ("Run 1 · 2026-11-27", "Run 2 · 2026-11-28"))
        self.assertEqual(self.state(REFUSE, second["id"]), ("passed", "p"))
        self.assertEqual(self.state("Run summary", second["id"]), ("passed", "p"))
        self.assertEqual(cs.parse_ref(self.summary(second["id"])["values"]["f-ref"])["run"], cs.run_hash(RUN_2))
        # the first run's list is as it was
        self.assertEqual({t["id"]: json.dumps(t, sort_keys=True) for t in self.fake.tasks_in(first["id"])}, before)
        self.fake.calls.clear()
        self.assertEqual(self.sync(run=RUN_2)[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_open_list_made_by_push_scenarios_is_bound_to_the_next_run(self):
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.push()[0], 0)
        self.add_run(RUN_2, ALL_PASS)
        self.fake.calls.clear()
        self.assertEqual(self.sync(run=RUN_2)[0], 0)
        self.assertEqual(self.fake.writes("POST", r"/list$"), [])
        self.assertEqual([l["name"] for l in self.lists()], ["Run 1 · 2026-11-27", "Run 2 · 2026-11-28"])

    def test_other_machine_finds_bound_list_without_cache(self):
        self.assertEqual(self.sync()[0], 0)
        (self.tmp / ".qa" / "tracker-map.json").unlink()
        self.fake.calls.clear()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(len(self.lists()), 1)

    def test_newest_run_is_synced_when_no_run_is_named(self):
        rc, lines, err = self.tracker("sync-run")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-27")

    def test_build_is_shown_on_the_list_and_the_tickets(self):
        self.add_run(RUN_1, manifest={"build": "v1.4.46 (next@beb2492a7) nightly"})
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-27 v1.4.46")
        for name in (SAVE, JUDGE_CARD, "Run summary"):
            self.assertEqual(self.fake.task(name)["values"].get("f-build"), "v1.4.46")
        self.assertNotIn("beb2492a7", json.dumps(self.fake.calls))

    def test_a_label_that_breaks_the_writing_rules_fails_the_sync(self):
        rc, lines, _ = self.sync("--label", "Automated nightly")
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\twording\t") for ln in lines), lines)
        self.assertEqual(self.run_list()["name"], "Run 1 · next")
        self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], "open")

    def test_a_list_a_person_named_keeps_its_name(self):
        self.new_project()
        self.fake.add_folder("F77", "Judging", QA)
        self.fake.add_list("L77", "Judging round one", "F77")
        self.edit_cfg(lambda d: d["specs"][TARGET].update(list="L77"))
        self.ready()
        self.assertEqual(self.push()[0], 0)
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.lists["L77"]["name"], "Judging round one")
        self.assertEqual(self.state(REFUSE, "L77"), ("failed", "f"))


class StatusTests(SyncBase):
    def test_statuses_follow_verdicts(self):
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.state(SAVE), ("passed", "p"))
        self.assertEqual(self.state(REFUSE), ("failed", "f"))
        self.assertEqual(self.state(JUDGE_RANK), ("blocked", "b"))
        self.assertEqual(self.state(JUDGE_CARD), ("failed", "f"))      # the worst of its checks
        self.assertEqual(self.state(ADMIN_CARD), ("testing", "g"))    # one waits for a review, one is open
        self.assertEqual(self.state("Run summary"), ("failed", "f"))
        self.assertEqual(self.summary()["markdown_description"],
                         "5 checks: 1 to test, 1 testing, 1 failed, 1 blocked, 1 passed.\n\n"
                         "A person needs to confirm 1 result.")
        self.assert_quiet()

    def test_error_and_deferred_get_their_note_once(self):
        self.add_run(RUN_1, [row("C-SCORE-01", "judge", "error"), row("C-SCORE-02", "judge", "deferred")])
        for _ in range(2):
            self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.state(SAVE), ("blocked", "b"))
        self.assertEqual(self.texts(SAVE), ["Could not be checked on this run."])
        self.assertEqual(self.state(REFUSE), ("skipped", "s"))
        self.assertEqual(self.texts(REFUSE), ["Not checked on this run. It was left for a later run."])
        self.assertEqual(self.state(JUDGE_RANK), ("to test", "t"))
        self.assertEqual(self.state(JUDGE_CARD), ("blocked", "b"))

    def test_own_status_names_are_used(self):
        self.statuses = OWN_STATUSES
        self.new_project()
        self.edit_cfg(lambda d: d.update(statuses={"case": OWN_STATUSES,
                                                   "bug": ["open", "triaged", "fixing", "retest", "closed"]}))
        self.ready()
        self.assertEqual(self.push()[0], 0)
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.state(REFUSE), ("broken", "f"))
        self.assertEqual(self.state(SAVE), ("accepted", "p"))
        self.assertIn("1 broken", self.summary()["markdown_description"])

    def test_low_confidence_pass_stays_testing_with_tick(self):
        self.add_run(RUN_1, [row("C-SCORE-01", "judge", "pass", "low")])
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.state(SAVE), ("testing", "g"))
        t = self.fake.task(SAVE)
        self.assertIs(t["values"]["f-review"], True)
        self.assertEqual(self.texts(SAVE), [REVIEW_NOTE])
        self.assertEqual(self.fake.names_on(t["id"]), [shot("judge", "C-SCORE-01", "before"),
                                                       shot("judge", "C-SCORE-01", "after")])
        # nothing but a high-confidence pass is ever written as passed
        self.assertNotIn("passed", [c[2].get("status") for c in self.fake.writes("PUT", r"/v2/task/\w+$")])
        # a second sync adds neither the comment nor the tick again
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_result_recorded_again_in_the_same_run_replaces_the_first(self):
        self.add_run(RUN_1, [row("C-SCORE-01", "judge", "fail"), row("C-SCORE-02", "judge", "pass", "low")])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.state(SAVE), ("failed", "f"))
        self.assertIs(self.fake.task(REFUSE)["values"]["f-review"], True)
        self.add_run(RUN_1, [row("C-SCORE-01", "judge", "pass"), row("C-SCORE-02", "judge", "fail")])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.state(SAVE), ("passed", "p"))
        self.assertEqual(self.state(REFUSE), ("failed", "f"))
        self.assertIs(self.fake.task(REFUSE)["values"]["f-review"], False)

    def test_person_changed_status_is_left(self):
        self.assertEqual(self.sync()[0], 0)
        self.move(REFUSE, "passed")          # a person overrode the failure
        self.add_run(RUN_1, [row("C-SCORE-01", "judge", "fail"), row("C-SCORE-02", "judge", "blocked"),
                             row("C-RANK-01", "judge", "blocked")])
        self.fake.calls.clear()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)       # reported, not a failure
        self.assertIn(f"SKIP\tchanged-by-person\t{REFUSE}", lines)
        self.assertEqual(self.state(REFUSE), ("passed", "f"))
        refuse = self.fake.task(REFUSE)["id"]
        self.assertEqual([c for c in self.fake.calls if re.search(rf"/{refuse}(/|$)", c[1])], [])
        self.assertEqual(self.state(SAVE), ("failed", "f"))   # the others still follow the run
        self.assertIn('"changed-by-person": 1', lines[-1])

    def test_run_with_no_result_for_this_spec_binds_no_list(self):
        other = "2026-11-29-team-registration"
        for rows in ([], [row("C-REG-01", "applicant", "pass"), row("C-REG-02", "applicant", "fail")]):
            with self.subTest(rows=len(rows)):
                self.add_run(other, rows)
                self.fake.calls.clear()
                for argv in (("sync-run", "--run", other), ("sync-run",)):   # named, and picked as the newest
                    rc, lines, err = self.tracker(*argv)
                    self.assertEqual(rc, 0, (lines, err))
                    self.assertEqual(lines[:-1], [NO_RESULTS])
                    self.assertNotIn('"skip"', lines[-1])
                self.assertEqual(self.fake.calls, [])
                self.assertEqual(self.run_list()["name"], "Run 1 · next")
                self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], "open")
        # the spec's own run still takes the open list afterwards
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-27")

    def test_summary_a_person_moved_keeps_its_status_and_still_gets_the_counts(self):
        self.assertEqual(self.sync()[0], 0)
        self.move("Run summary", "blocked")
        self.add_run(RUN_1, ALL_PASS)
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertIn("SKIP\tchanged-by-person\tRun summary", lines)
        self.assertEqual(self.state("Run summary"), ("blocked", "f"))
        self.assertEqual(self.summary()["markdown_description"], "5 checks: 5 passed.")

    def test_ticket_links_and_labels_for_the_doc_pages(self):
        import argparse
        import io
        from unittest import mock
        from trackers import clickup
        from trackers.ctx import Ctx
        self.assertEqual(self.sync()[0], 0)
        self.fake.calls.clear()
        args = argparse.Namespace(spec=TARGET, run=None, retest=False, apply=False, overwrite=[], label=None)
        ctx = Ctx(project=self.tmp, cfg=core.spec_settings(core.load_config(self.tmp), TARGET), catalog=None,
                  log=core.ActionLog(False, io.StringIO()), cache=core.MapCache(self.tmp), args=args)
        with mock.patch.object(clickup, "transport_for", lambda ctx: self.fake):
            s = cs.SpecSync(ctx)
            entry = s.run_lists()[0]
            links = s.ticket_links(entry["id"])
        self.assertEqual(links, {
            "judge-scores-a-submission": f"https://app.clickup.com/t/{self.fake.task(JUDGE_CARD)['id']}",
            "admin-watches-the-ranking": f"https://app.clickup.com/t/{self.fake.task(ADMIN_CARD)['id']}"})
        self.assertEqual(s.label_of(entry), "2026-11-27")
        self.assertEqual(self.fake.calls, [])

    def half_moved(self):
        """SAVE's status landed (passed) and the write of its final Ref letter failed."""
        self.fail_ref(SAVE, pending=False)
        self.assertEqual(self.sync()[0], 1)
        del self.fake.request
        t = self.fake.task(SAVE)
        self.assertEqual(t["status"]["status"], "passed")
        self.assertEqual(cs.parse_ref(t["values"]["f-ref"])["pending"], "passed")   # the move is on record
        return t

    def test_status_written_without_its_letter_is_finished(self):
        self.half_moved()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertNotIn("changed-by-person", "\n".join(lines))
        for name, want in ((SAVE, ("passed", "p")), (REFUSE, ("failed", "f")), ("Run summary", ("failed", "f"))):
            self.assertEqual(self.state(name), want)
            self.assertIsNone(cs.parse_ref(self.fake.task(name)["values"]["f-ref"])["pending"])
        self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], cs.run_hash(RUN_1))

    def test_half_done_move_follows_a_result_recorded_again(self):
        t = self.half_moved()
        self.record(RUN_1, [row("C-SCORE-01", "judge", "fail")])
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertNotIn("changed-by-person", "\n".join(lines))
        self.assertEqual(self.state(SAVE), ("failed", "f"))
        self.assertIsNone(cs.parse_ref(t["values"]["f-ref"])["pending"])
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_move_that_failed_before_anything_changed_is_done_on_the_next_sync(self):
        self.fail_ref(SAVE, pending=True)
        self.assertEqual(self.sync()[0], 1)
        del self.fake.request
        t = self.fake.task(SAVE)
        self.assertEqual((t["status"]["status"], t["values"]["f-ref"][-2:]), ("to test", "-t"))
        self.record(RUN_1, [row("C-SCORE-01", "judge", "fail")])
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertNotIn("changed-by-person", "\n".join(lines))
        self.assertEqual(self.state(SAVE), ("failed", "f"))
        self.assertIsNone(cs.parse_ref(t["values"]["f-ref"])["pending"])

    def test_person_change_during_a_half_done_move_is_left(self):
        t = self.half_moved()
        value = t["values"]["f-ref"]
        self.move(SAVE, "blocked")           # a status that is neither the old nor the new one
        self.record(RUN_1, [row("C-SCORE-01", "judge", "fail")])
        self.fake.calls.clear()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(lines.count(f"SKIP\tchanged-by-person\t{SAVE}"), 1)
        self.assertEqual((t["status"]["status"], t["values"]["f-ref"]), ("blocked", value))
        self.assertEqual(self.touched(SAVE), [])

    def test_sync_twice_no_writes(self):
        self.assertEqual(self.sync()[0], 0)
        self.fake.calls.clear()
        cache = (self.tmp / ".qa" / "tracker-map.json").read_text(encoding="utf-8")
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual((self.tmp / ".qa" / "tracker-map.json").read_text(encoding="utf-8"), cache)

    def test_dry_run_writes_nothing(self):
        config = self.cfg_path.read_text(encoding="utf-8")
        cache = (self.tmp / ".qa" / "tracker-map.json").read_text(encoding="utf-8")
        self.fake.add_bug(BUG_TITLE, core.fingerprint("C-SCORE-02", "judge", BUG_TITLE))
        self.bugs([{"title": BUG_TITLE, "criterionId": "C-SCORE-02", "persona": "judge"}])
        rc, lines, _ = self.sync(apply=False)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])
        self.assertIn(f"DRY\tstatus\t{REFUSE}: failed", lines)
        self.assertIn(f"DRY\tattach\t{REFUSE}: {shot('judge', 'C-SCORE-02', 'before')}", lines)
        self.assertIn(f"DRY\tcreate\t{ADMIN_RANK}", lines)
        self.assertTrue(any(ln.startswith("DRY\tlink-bug\t") for ln in lines), lines)
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), config)
        self.assertEqual((self.tmp / ".qa" / "tracker-map.json").read_text(encoding="utf-8"), cache)
        # a retest in a dry run, and one with no list at all, write nothing either
        self.assertEqual(self.sync()[0], 0)
        self.add_run(RUN_2, ALL_PASS)
        self.fake.calls.clear()
        rc, lines, _ = self.sync("--retest", run=RUN_2, apply=False)
        self.assertEqual(rc, 0, lines)
        self.assertIn(f"DRY\tretest\t{REFUSE}", lines)
        rc, lines, _ = self.sync(run=RUN_2, apply=False)
        self.assertEqual(rc, 0, lines)
        self.assertIn("DRY\tcreate-list\tRun 2 · next", lines)
        self.assertEqual(self.fake.calls, [])

    def bugs(self, rows, run=RUN_1):
        path = self.tmp / ".qa" / "runs" / run / "bugs"
        path.mkdir(exist_ok=True)
        (path / "bugs.json").write_text(json.dumps(rows), encoding="utf-8")

    def test_recorded_row_without_a_card_is_reported_rc1(self):
        rows = json.loads((RUN_FIXTURE / "checkpoint.json").read_text(encoding="utf-8"))["criteria"]
        self.add_run(RUN_1, rows + [row("C-EXPORT-01", "admin", "fail")])
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\tno-ticket\tC-EXPORT-01 (admin): recorded as fail, and no scenario ticket shows it; "
                      "add it to a card, then run push-scenarios", lines)
        self.assertEqual(self.state(REFUSE), ("failed", "f"))  # the rest is still synced
        self.assertNotIn("C-EXPORT", json.dumps(self.fake.calls))

    def test_plan_changed_stops_before_writes(self):
        self.edit_plan(lambda rows: rows + [{"id": "C-EXPORT-01", "persona": "admin", "kind": "happy-path"}])
        rc, lines, err = self.sync()
        self.assertEqual(rc, 1)
        self.assertIn("error: the plan changed since the tickets were made; run push-scenarios", err)
        self.assertEqual(self.fake.calls, [])

    def test_check_added_after_the_tickets_gets_its_ticket_before_the_sync(self):
        for bound in (False, True):   # the list is still open, or already holds this run
            with self.subTest(bound=bound):
                self.new_project()
                self.ready()
                self.assertEqual(self.push()[0], 0)
                if bound:
                    self.assertEqual(self.sync()[0], 0)
                self.add_check()
                rc, lines, err = self.sync()
                self.assertEqual(rc, 0, (lines, err))
                self.assertNotIn("plan changed", err)
                t = self.fake.task(NEW_CHECK["title"])
                self.assertEqual(self.state(NEW_CHECK["title"]), ("to test", "t"))
                self.assertEqual(t["parent"], self.fake.task(JUDGE_CARD)["id"])
                self.assertEqual(self.state(REFUSE), ("failed", "f"))
                self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-27")
                self.assertFalse(any("\tretire\t" in ln for ln in lines), lines)
                self.fake.calls.clear()
                self.assertEqual(self.sync()[0], 0)
                self.assertEqual(self.fake.calls, [])

    def test_check_removed_with_a_recorded_result_is_not_retired_by_the_sync(self):
        self.assertEqual(self.sync()[0], 0)
        self.remove_check("C-SCORE-02")
        self.fake.calls.clear()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1)              # its recorded result has no card now
        self.assertTrue(any(ln.startswith("SKIP\tno-ticket\tC-SCORE-02 (judge): recorded as fail") for ln in lines))
        self.assertEqual(self.state(REFUSE), ("failed", "f"))
        self.assertEqual(self.touched(REFUSE), [])

    def test_wording_problem_in_the_cards_stops_before_clickup(self):
        self.edit_cards(lambda d: d["cards"][0].update(title="Automated judge scoring"))
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\tlint\t") for ln in lines), lines)
        self.assertEqual(self.fake.calls, [])

    def test_ship_verdict_is_shown_as_the_engine_rendered_it(self):
        report = self.tmp / ".qa" / "runs" / RUN_1 / "report.md"
        report.write_text("# Report\n\n## Ship readiness\n\n**NOT SHIP-READY**\n\n- 2 census surface(s) uncovered\n",
                          encoding="utf-8")
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.summary()["markdown_description"].splitlines()[4:],
                         ["Not ready to ship.", "", "- Some screens have not been checked yet."])
        # a report that says ready never reads better than the counts
        report.write_text("# Report\n\n## Ship readiness\n\n**SHIP-READY**\n", encoding="utf-8")
        self.assertEqual(self.sync()[0], 0)
        text = self.summary()["markdown_description"]
        self.assertIn("Not ready to ship.", text)
        self.assertNotIn("\nReady to ship.", text)
        # a line a later step added to the summary is kept
        t = self.summary()
        t["markdown_description"] += "\n\nFull results: [Results page](https://app.clickup.com/9001/v/dc/1)"
        self.add_run(RUN_1, ALL_PASS)
        self.assertEqual(self.sync()[0], 0)
        lines = self.summary()["markdown_description"].splitlines()
        self.assertEqual((lines[0], lines[2], lines[-1]), (
            "5 checks: 5 passed.", "Ready to ship.",
            "Full results: [Results page](https://app.clickup.com/9001/v/dc/1)"))


class ChecklistTests(SyncBase):
    def items(self):
        admin = self.fake.task(ADMIN_CARD)
        return {i["name"]: i["resolved"] for c in self.fake.checklists.values() if c["task_id"] == admin["id"]
                for i in c["items"]}

    def test_checklist_failure_raised_to_subtask(self):
        rows = [row("C-RANK-01", "admin", "fail"), row(LOAD, "admin", "pass")]
        self.add_run(RUN_1, rows)
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        admin = self.fake.task(ADMIN_CARD)
        raised = self.fake.task(ADMIN_RANK)
        self.assertEqual(raised["parent"], admin["id"])
        self.assertEqual(self.state(ADMIN_RANK), ("failed", "f"))
        self.assertEqual(raised["values"]["f-ref"][:-2],
                         cs.ref(TARGET, 1, "check", cs.check_id("admin-watches-the-ranking", "C-RANK-01"))[:-2])
        self.assertEqual(raised["values"]["f-role"], "Admin")
        self.assertEqual(raised["markdown_description"],
                         "Open the leaderboard as an admin.\n\n"
                         "Teams are listed from the highest average score to the lowest.")
        self.assertEqual(self.fake.names_on(raised["id"]), [shot("admin", "C-RANK-01", "after")])
        self.assertEqual(self.items(), {ADMIN_RANK: False, HACKATHONS: True})
        self.assertEqual(self.state(ADMIN_CARD), ("failed", "f"))
        # found again by its Ref: a second sync makes no second subtask
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])
        # passed later in the same run: the subtask follows and the item is ticked
        self.add_run(RUN_1, [row("C-RANK-01", "admin", "pass"), row(LOAD, "admin", "fail")])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.state(ADMIN_RANK), ("passed", "p"))
        self.assertEqual(self.items(), {ADMIN_RANK: True, HACKATHONS: False})
        self.assertEqual(self.state(HACKATHONS), ("failed", "f"))
        self.assert_quiet()

    def test_subtask_create_that_landed_is_not_sent_twice(self):
        self.add_run(RUN_1, [row("C-RANK-01", "admin", "fail")])
        self.fake.fail_task_create_at, self.fake.fail_lands = self.fake.task_creates + 1, True
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertTrue(any(ln.startswith("APPLY\treconciled\t") for ln in lines), lines)
        self.assertEqual(self.state(ADMIN_RANK), ("failed", "f"))
        self.assertEqual(len(self.fake.writes("POST", r"/list/\w+/task$")), 1)

    def test_raised_subtask_is_untouched_when_a_check_is_added_to_the_cards(self):
        self.add_run(RUN_1, [row("C-RANK-01", "admin", "fail"), row(LOAD, "admin", "pass")])
        self.assertEqual(self.sync()[0], 0)
        raised = self.fake.task(ADMIN_RANK)
        before = json.dumps([raised, self.fake.comments.get(raised["id"]), self.fake.names_on(raised["id"])],
                            sort_keys=True)
        extra = {"criterion": "C-RANK-02", "title": "Ranking shows every team",
                 "do": "Open the leaderboard and count the teams.", "expect": "Every team that submitted is listed."}
        self.add_check()                                   # a subtask card gets a ticket
        self.add_check(card=1, check=extra, persona="admin")   # a checklist card gets an item
        self.fake.calls.clear()
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(json.dumps([raised, self.fake.comments.get(raised["id"]),
                                     self.fake.names_on(raised["id"])], sort_keys=True), before)
        self.assertEqual(self.touched(ADMIN_RANK), [])
        self.assertIs(self.fake.task(ADMIN_RANK), raised)      # still the one subtask of that check
        self.assertEqual(self.state(NEW_CHECK["title"]), ("to test", "t"))
        self.assertEqual(self.items(), {ADMIN_RANK: False, HACKATHONS: True, extra["title"]: False})
        self.assertFalse(any("\tretire\t" in ln for ln in lines), lines)
        self.assertNotIn("skipped", [t["status"]["status"] for t in self.fake.tasks.values()])
        self.assertEqual(len(self.fake.tasks), 8)   # summary, 2 cards, 3 checks, the raised one, the new check
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_check_left_for_a_later_run_is_not_taken_for_one_back_in_the_plan(self):
        self.add_run(RUN_1, [row("C-SCORE-01", "judge", "deferred"), row("C-SCORE-02", "judge", "fail")])
        for _ in range(2):
            rc, lines, _ = self.sync()
            self.assertEqual(rc, 0, lines)
            self.assertFalse(any("\treturn\t" in ln for ln in lines), lines)
        self.assertEqual(self.state(SAVE), ("skipped", "s"))
        # recorded again with a result: the ticket follows it, and nothing says it came back
        self.record(RUN_1, [row("C-SCORE-01", "judge", "pass"), row("C-SCORE-02", "judge", "fail")])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.state(SAVE), ("passed", "p"))
        self.assertEqual(self.texts(SAVE), ["Not checked on this run. It was left for a later run."])


class EvidenceTests(SyncBase):
    def test_evidence_uploaded_once_with_neutral_names(self):
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        refused = [shot("judge", "C-SCORE-02", phase) for phase in ("before", "after-message", "after")]
        on = {name: self.fake.names_on(self.fake.task(name)["id"]) for name in (SAVE, REFUSE, JUDGE_RANK, ADMIN_RANK)}
        self.assertEqual(on, {SAVE: [shot("judge", "C-SCORE-01", "after")], REFUSE: refused,
                              JUDGE_RANK: [shot("judge", "C-RANK-01", "before")],
                              ADMIN_RANK: [shot("admin", "C-RANK-01", "after")]})
        refuse = self.fake.task(REFUSE)["id"]
        folder = RUN_FIXTURE / "evidence" / "judge" / "C-SCORE-02"
        self.assertEqual([a["data"] for a in self.fake.attachments[refuse]],
                         [(folder / n).read_bytes() for n in ("screenshot-before.png", "screenshot-after-message.png",
                                                              "screenshot-after.png")])
        sent = [c[2] for c in self.fake.calls if c[0] == "UPLOAD"]
        self.assertEqual(len(sent), 6)
        for name in sent:   # a name says nothing but what the file holds
            self.assertRegex(name, r"^screen-[0-9a-f]{6}\.png$")
        for holder in (JUDGE_CARD, ADMIN_CARD, "Run summary"):
            self.assertEqual(self.fake.names_on(self.fake.task(holder)["id"]), [])
        self.assert_quiet()
        self.fake.calls.clear()
        self.fake.attach_reads = False  # ClickUp may list the title without the extension
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_extension_is_the_files_own_in_lower_case(self):
        folder = self.tmp / ".qa" / "runs" / RUN_1 / "evidence" / "judge" / "C-SCORE-01"
        for f in folder.iterdir():
            f.unlink()
        (folder / "Score Saved.JPG").write_bytes(b"jpeg")
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.names_on(self.fake.task(SAVE)["id"]), [named(b"jpeg")[:-4] + ".jpg"])

    def test_retest_with_other_screenshots_uploads_the_new_ones(self):
        self.assertEqual(self.sync()[0], 0)
        refuse = self.fake.task(REFUSE)["id"]
        first = self.fake.names_on(refuse)
        self.add_run(RUN_2)                  # the same results, recorded again
        new = self.only_shot(RUN_2, "judge", "C-SCORE-02", b"the message after the second round")
        self.fake.calls.clear()
        rc, lines, err = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.names_on(refuse), first + [new])
        # the screenshots that did not change are not sent a second time
        self.assertEqual([c for c in self.fake.calls if c[0] == "UPLOAD"],
                         [("UPLOAD", f"/v2/task/{refuse}/attachment", new)])
        self.fake.calls.clear()
        self.assertEqual(self.sync("--retest", run=RUN_2)[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_check_recorded_again_gets_the_screenshot_of_its_new_result(self):
        self.record(RUN_1, [row("C-SCORE-01", "judge", "fail")])
        self.assertEqual(self.sync()[0], 0)
        save = self.fake.task(SAVE)["id"]
        failed = [shot("judge", "C-SCORE-01", "before"), shot("judge", "C-SCORE-01", "after")]
        self.assertEqual(self.fake.names_on(save), failed)
        new = self.only_shot(RUN_1, "judge", "C-SCORE-01", b"the score is saved now")
        self.record(RUN_1, [row("C-SCORE-01", "judge", "pass")])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.state(SAVE), ("passed", "p"))
        self.assertEqual(self.fake.names_on(save), failed + [new])
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_cap_counts_the_files_of_this_sync(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(evidenceCap=1))
        self.assertEqual(self.sync()[0], 0)
        refuse = self.fake.task(REFUSE)["id"]
        self.assertEqual(self.fake.names_on(refuse), [shot("judge", "C-SCORE-02", "before")])
        new = self.only_shot(RUN_1, "judge", "C-SCORE-02", b"another try, the same message")
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.names_on(refuse), [shot("judge", "C-SCORE-02", "before"), new])

    def test_evidence_none_uploads_nothing(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(evidence="none"))
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.attachments, {})

    def test_missing_screenshot_reported_rc0(self):
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertIn(f"APPLY\tevidence-missing\t{JUDGE_RANK}: a recorded screenshot is not there or cannot be used",
                      lines)

    def test_upload_failure_rc1(self):
        self.fake.fail_uploads = 1
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\tapi-error\t") and re.search(r": screen-[0-9a-f]{6}\.png: HTTP 500", ln)
                            for ln in lines), lines)
        self.assertEqual(self.state(REFUSE), ("failed", "f"))
        # the next sync sends only the one that failed
        self.fake.calls.clear()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(len(self.fake.calls), 1)
        self.assertEqual(self.fake.calls[0][0], "UPLOAD")

    def test_file_that_disappears_fails_only_that_upload(self):
        (self.tmp / ".qa" / "runs" / RUN_1 / "evidence" / "judge" / "C-SCORE-01" / "screenshot-after.png").unlink()
        from trackers import spec_runs
        real = spec_runs.states

        def stale(run_dir, c, cfg):  # the file was there when the states were read
            out = real(run_dir, c, cfg)
            out[0].evidence = [Path(run_dir).resolve() / "evidence/judge/C-SCORE-01/screenshot-after.png"]
            return out
        spec_runs.states = stale
        self.addCleanup(setattr, spec_runs, "states", real)
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1)
        self.assertIn(f"SKIP\tupload-failed\t{SAVE}: a screenshot could not be read", lines)
        self.assertEqual(self.state(REFUSE), ("failed", "f"))


class RetestTests(SyncBase):
    def retest(self, *extra):
        self.assertEqual(self.sync()[0], 0)
        self.add_run(RUN_2, ALL_PASS)
        self.fake.calls.clear()
        return self.sync(*extra, run=RUN_2)

    def check_retested(self):
        run = self.run_list()   # still one list
        self.assertEqual(run["name"], "Run 1 · 2026-11-28")
        self.assertEqual(self.fake.writes("POST", r"/list$"), [])
        self.assertEqual(self.texts(REFUSE), ["Earlier result: failed (2026-11-27)."])
        self.assertEqual(self.texts(SAVE), ["Earlier result: passed (2026-11-27)."])
        self.assertEqual(self.texts(ADMIN_RANK), [REVIEW_NOTE, "Earlier result: testing (2026-11-27)."])
        self.assertEqual(self.texts("Run summary"), ["Earlier result: failed (2026-11-27)."])
        for name in (SAVE, REFUSE, JUDGE_RANK, ADMIN_RANK, JUDGE_CARD, ADMIN_CARD, "Run summary"):
            self.assertEqual(self.state(name), ("passed", "p"), name)
        self.assertIs(self.fake.task(ADMIN_RANK)["values"]["f-review"], False)
        self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], cs.run_hash(RUN_2))
        self.assertEqual(self.summary()["markdown_description"], "5 checks: 5 passed.")

    def test_retest_reuses_and_comments_earlier_result(self):
        rc, lines, err = self.retest("--retest")
        self.assertEqual(rc, 0, (lines, err))
        self.check_retested()
        # every ticket went back to the first status before it took the new result
        refuse = self.fake.task(REFUSE)["id"]
        moves = [c[2]["status"] for c in self.fake.writes("PUT", rf"/v2/task/{refuse}$")]
        self.assertEqual(moves, ["to test", "passed"])
        self.assert_quiet()
        # the same retest again: no second comment, no write at all
        self.fake.calls.clear()
        rc, lines, _ = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])
        self.check_retested()

    def test_list_mode_reuse_is_a_retest(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(listMode="reuse"))
        rc, lines, err = self.retest()
        self.assertEqual(rc, 0, (lines, err))
        self.check_retested()

    def test_retest_that_stopped_half_way_is_finished_without_a_second_comment(self):
        self.assertEqual(self.sync()[0], 0)
        self.add_run(RUN_2, ALL_PASS)
        self.fail_after("PUT", r"/v2/task/\w+$", status=400, times=3, lands=False)
        self.assertEqual(self.sync("--retest", run=RUN_2)[0], 1)
        self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], cs.run_hash(RUN_1))
        del self.fake.request
        rc, lines, _ = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, lines)
        self.check_retested()

    def test_retest_leaves_a_ticket_a_person_changed(self):
        self.assertEqual(self.sync()[0], 0)
        self.move(REFUSE, "passed")
        self.add_run(RUN_2, [row("C-SCORE-02", "judge", "fail")])
        self.fake.calls.clear()
        rc, lines, _ = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(lines.count(f"SKIP\tchanged-by-person\t{REFUSE}"), 1)
        self.assertEqual(self.texts(REFUSE), [])                  # no earlier-result comment
        self.assertEqual(self.state(REFUSE), ("passed", "f"))     # not reset, and not set by the retest
        self.assertEqual(self.touched(REFUSE), [])
        # every other ticket is reset
        self.assertEqual(self.state(SAVE), ("to test", "t"))
        self.assertEqual(self.texts(SAVE), ["Earlier result: passed (2026-11-27)."])
        items = [i["resolved"] for c in self.fake.checklists.values() for i in c["items"]]
        self.assertEqual(items, [False, False])
        self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-28")

    def test_retest_uses_the_newest_bound_list_and_leaves_an_open_list_unused(self):
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.push()[0], 0)      # makes `Run 2 · next`
        first, second = self.lists()
        open_before = json.dumps(self.fake.tasks_in(second["id"]), sort_keys=True)
        self.add_run(RUN_2, ALL_PASS)
        self.fake.calls.clear()
        rc, lines, err = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(lines.count(LIST_UNUSED), 1)
        self.assertEqual([l["name"] for l in self.lists()], ["Run 1 · 2026-11-28", "Run 2 · next"])
        self.assertEqual(self.state(REFUSE, first["id"]), ("passed", "p"))
        self.assertEqual(self.texts(REFUSE, first["id"]), ["Earlier result: failed (2026-11-27)."])
        self.assertEqual(json.dumps(self.fake.tasks_in(second["id"]), sort_keys=True), open_before)
        self.assertEqual(self.fake.writes("PUT", rf"/v2/list/{second['id']}$"), [])
        # the same with `listMode: reuse`, on the next run
        self.edit_cfg(lambda d: d["specs"][TARGET].update(listMode="reuse"))
        self.add_run("2026-11-29-judge-scoring", ALL_PASS)
        rc, lines, err = self.sync(run="2026-11-29-judge-scoring")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual([l["name"] for l in self.lists()], ["Run 1 · 2026-11-29", "Run 2 · next"])
        self.assertEqual(json.dumps(self.fake.tasks_in(second["id"]), sort_keys=True), open_before)

    def test_fixed_note_is_posted_again_after_a_retest(self):
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.texts(ADMIN_RANK), [REVIEW_NOTE])
        self.add_run(RUN_2)                  # the same results: the admin's check waits for a review again
        rc, lines, err = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.texts(ADMIN_RANK), [REVIEW_NOTE, "Earlier result: testing (2026-11-27).", REVIEW_NOTE])
        # and only once per retest
        self.fake.calls.clear()
        self.assertEqual(self.sync("--retest", run=RUN_2)[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_note_is_not_repeated_under_other_comments(self):
        self.record(RUN_1, [row("C-SCORE-01", "judge", "error")])
        self.assertEqual(self.sync()[0], 0)
        save = self.fake.task(SAVE)["id"]
        self.fake.comments[save].append({"comment_text": "The staging server was down that morning.",
                                         "notify_all": False})
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_earlier_result_comment_is_not_repeated_under_a_newer_comment(self):
        self.assertEqual(self.sync()[0], 0)
        refuse = self.fake.task(REFUSE)["id"]
        self.add_run(RUN_2, ALL_PASS)
        # the retest stops on this ticket after its comment, before its status
        self.fail_after("PUT", rf"/v2/task/{refuse}$", status=502, times=1, lands=False)
        self.assertEqual(self.sync("--retest", run=RUN_2)[0], 1)
        del self.fake.request
        self.assertEqual(self.texts(REFUSE), ["Earlier result: failed (2026-11-27)."])
        self.fake.comments[refuse].append({"comment_text": "Checked with the judging team.", "notify_all": False})
        rc, lines, _ = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.texts(REFUSE), ["Earlier result: failed (2026-11-27).", "Checked with the judging team."])
        self.assertEqual(self.state(REFUSE), ("passed", "p"))

    def test_retest_comment_drops_a_list_name_that_breaks_the_writing_rules(self):
        self.assertEqual(self.sync()[0], 0)
        self.run_list()["name"] = "Run 1 · Sprint AC12"
        self.add_run(RUN_2, ALL_PASS)
        rc, lines, _ = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.texts(REFUSE), ["Earlier result: failed."])
        self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-28")

    def test_retest_with_no_earlier_run_is_a_first_sync(self):
        rc, lines, err = self.sync("--retest")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.run_list()["name"], "Run 1 · 2026-11-27")
        self.assertEqual(self.fake.comments.get(self.fake.task(REFUSE)["id"]), None)


class BugTests(SyncBase):
    def bugs(self, rows, run=RUN_1):
        path = self.tmp / ".qa" / "runs" / run / "bugs"
        path.mkdir(exist_ok=True)
        (path / "bugs.json").write_text(json.dumps(rows), encoding="utf-8")

    def seed(self, **over):
        entry = dict({"id": "B1", "title": BUG_TITLE, "criterionId": "C-SCORE-02", "persona": "judge",
                      "severity": "high"}, **over)
        self.bugs([entry])
        return self.fake.add_bug(BUG_TITLE, core.fingerprint("C-SCORE-02", "judge", BUG_TITLE))

    def test_bug_linked_to_card_ticket(self):
        bug = self.seed()
        other = self.fake.add_bug("Ranking shows a team twice", core.fingerprint("C-RANK-01", "judge", "Ranking shows a team twice"))
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        card = self.fake.task(JUDGE_CARD)
        self.assertEqual(self.fake.writes("POST", r"/link/"), [("POST", f"/v2/task/{bug['id']}/link/{card['id']}", None)])
        self.assertEqual(self.fake.links.get(other["id"]), None)   # not a bug of this run
        self.fake.calls.clear()
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.fake.calls, [])
        # seen again in the next run: that run's ticket is linked too
        self.add_run(RUN_2)
        self.bugs([{"title": BUG_TITLE, "criterionId": "C-SCORE-02", "persona": "judge"}], RUN_2)
        self.assertEqual(self.sync(run=RUN_2)[0], 0)
        second = self.lists()[1]["id"]
        self.assertEqual(self.fake.links[bug["id"]], {card["id"], self.fake.task(JUDGE_CARD, second)["id"]})

    def test_bug_without_a_card_or_a_ticket_is_reported_and_left(self):
        self.bugs([{"title": "Export misses the last row", "criterionId": "C-EXPORT-01", "persona": "admin"},
                   {"title": BUG_TITLE, "criterionId": "C-SCORE-02", "persona": "judge"},
                   {"title": "Ranking shows a team twice", "criterionId": "C-RANK-01", "persona": "judge",
                    "duplicateOf": "B7"}])
        self.fake.add_bug("Export misses the last row", core.fingerprint("C-EXPORT-01", "admin", "Export misses the last row"))
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1, lines)   # a bug that was not filed must not pass quietly
        self.assertIn("APPLY\tbug-unlinked\tExport misses the last row: no scenario ticket holds its check", lines)
        self.assertIn(f"SKIP\tbug-not-found\t{BUG_TITLE}: not in the Bugs list yet; run push-bug first", lines)
        self.assertEqual(self.fake.writes("POST", r"/link/"), [])
        # once it is filed the sync links it and passes
        self.fake.add_bug(BUG_TITLE, core.fingerprint("C-SCORE-02", "judge", BUG_TITLE))
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(len(self.fake.writes("POST", r"/link/")), 1)

    def test_run_with_bugs_and_no_bugs_list_fails_the_sync(self):
        self.seed()
        self.edit_cfg(lambda d: (d.pop("listIds"), d.pop("fields")) and d.update(fields={
            k: v for k, v in self.cfg()["fields"].items() if not k.startswith("Bugs/")}))
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1, lines)
        self.assertIn("SKIP\tbugs-not-linked\tthe Bugs list is not set up; run tracker.sh init", lines)
        # a run without bugs does not need the Bugs list
        self.bugs([])
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertFalse(any("bugs-not-linked" in ln for ln in lines), lines)

    def test_bugs_in_the_issue_tracker_are_not_linked(self):
        self.seed()
        self.edit_cfg(lambda d: d.update(bugsTo="issue-tracker"))
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.writes("POST", r"/link/"), [])
        self.assertFalse(any("bug" in ln for ln in lines[:-1]), lines)

    def test_closed_bug_is_linked_only_when_no_open_one_matches(self):
        closed = self.seed()
        closed["status"]["status"] = "closed"
        again = self.fake.add_bug(BUG_TITLE, core.fingerprint("C-SCORE-02", "judge", BUG_TITLE))
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(set(self.fake.links), {again["id"], self.fake.task(JUDGE_CARD)["id"]})


class PlanMoveTests(SyncBase):
    """A check that leaves the plan or comes back: the Ref says so before the status changes, and
    the tool's own notes are found however many comments came after them."""

    CHECK = "Refuse a score above the maximum"

    def ref(self):
        return self.fake.task(self.CHECK)["values"]["f-ref"].split("-")[2]

    def status(self):
        return self.fake.task(self.CHECK)["status"]["status"]

    def talk(self, count=30):
        tid = self.fake.task(self.CHECK)["id"]
        for i in range(count):
            self.fake.comments.setdefault(tid, []).append(
                {"comment_text": f"Looked at this with the team, round {i + 1}.", "notify_all": False})

    def notes(self):
        return [t for t in self.texts(self.CHECK) if t in ("No longer part of the plan.", "Back in the plan.")]

    def test_retire_that_stops_before_the_status_is_marked_and_finished_next_time(self):
        tid = self.fake.task(self.CHECK)["id"]
        self.remove_check("C-SCORE-02")
        self.fail_after("PUT", rf"/v2/task/{tid}$", lands=False)
        self.assertEqual(self.push()[0], 1)
        self.assertEqual((self.status(), self.ref()), ("to test", "ts"))   # a move in progress, not a person's
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual((self.status(), self.ref()), ("skipped", "s"))
        self.assertEqual(self.notes(), ["No longer part of the plan."])
        self.assertFalse(any("changed-by-person" in ln for ln in lines), lines)

    def test_return_that_stops_before_the_status_is_marked_and_finished_next_time(self):
        tid = self.fake.task(self.CHECK)["id"]
        put_back = self.keep_files()
        self.remove_check("C-SCORE-02")
        self.assertEqual(self.push()[0], 0)
        put_back()
        self.fail_after("PUT", rf"/v2/task/{tid}$", lands=False)
        self.assertEqual(self.push()[0], 1)
        self.assertEqual((self.status(), self.ref()), ("skipped", "st"))
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual((self.status(), self.ref()), ("to test", "t"))
        self.assertEqual(self.notes(), ["No longer part of the plan.", "Back in the plan."])
        self.fake.calls.clear()
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_check_that_returns_while_its_retire_is_half_done_comes_back(self):
        put_back = self.keep_files()
        self.remove_check("C-SCORE-02")
        self.fail_ref(self.CHECK, pending=False)       # the status is skipped; the last letter is not written
        self.assertEqual(self.push()[0], 1)
        self.assertEqual((self.status(), self.ref()), ("skipped", "ts"))
        put_back()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual((self.status(), self.ref()), ("to test", "t"))
        self.assertEqual(self.notes(), ["No longer part of the plan.", "Back in the plan."])

    def test_plan_note_is_found_behind_more_than_one_page_of_comments(self):
        # on a run's list a skipped ticket returns only when its newest plan note says it left
        self.assertEqual(self.sync()[0], 0)
        put_back = self.keep_files()
        self.remove_check("C-SCORE-02")
        self.record(RUN_1, [r for r in json.loads((self.tmp / ".qa/runs" / RUN_1 / "checkpoint.json").read_text())
                            ["criteria"] if r.get("criterion_id") != "C-SCORE-02"])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.status(), "skipped")
        self.talk()
        put_back()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.status(), "to test")
        self.assertEqual(self.notes(), ["No longer part of the plan.", "Back in the plan."])

    def test_result_note_is_not_posted_again_behind_more_than_one_page_of_comments(self):
        self.record(RUN_1, [row("C-SCORE-02", "judge", "pass", "low")])
        self.assertEqual(self.sync()[0], 0)
        self.assertEqual(self.texts(self.CHECK).count(REVIEW_NOTE), 1)
        self.talk()
        self.fake.calls.clear()
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.texts(self.CHECK).count(REVIEW_NOTE), 1)
        self.assertEqual(self.fake.calls, [])


class RefGrammarTests(unittest.TestCase):
    KEY = "a1b2c3d4e5f6"

    def test_a_move_in_progress_is_two_letters(self):
        key = self.KEY
        self.assertEqual(cs.parse_ref(f"qk1-{key}-tp"),
                         {"key": key, "letter": "t", "role": "to_test", "run": None, "pending": "passed"})
        self.assertEqual(cs.parse_ref(f"qk1-{key}-fb-0a1b2c3d"),
                         {"key": key, "letter": "f", "role": "failed", "run": "0a1b2c3d", "pending": "blocked"})
        self.assertEqual(cs.parse_ref(f"qk1-{key}-gs-open")["run"], "open")
        # every Ref written so far is read as before, with no move in progress
        self.assertEqual(cs.parse_ref(f"qk1-{key}-t"),
                         {"key": key, "letter": "t", "role": "to_test", "run": None, "pending": None})
        self.assertIsNone(cs.parse_ref(f"qk1-{key}-p-open")["pending"])

    def test_reletter_marks_and_settles_a_move(self):
        key = self.KEY
        self.assertEqual(cs.reletter(f"qk1-{key}-t", "to_test", pending="passed"), f"qk1-{key}-tp")
        self.assertEqual(cs.reletter(f"qk1-{key}-tp", "failed"), f"qk1-{key}-f")
        self.assertEqual(cs.reletter(f"qk1-{key}-tp", "passed", pending="failed"), f"qk1-{key}-pf")
        self.assertEqual(cs.reletter(f"qk1-{key}-tp-0a1b2c3d", "passed"), f"qk1-{key}-p-0a1b2c3d")
        self.assertEqual(cs.reletter(f"qk1-{key}-t-open", "to_test", run="run-2026-11-27", pending="failed"),
                         f"qk1-{key}-tf-{cs.run_hash('run-2026-11-27')}")
        self.assertEqual(cs.reletter(f"qk1-{key}-t", "passed", pending="passed"), f"qk1-{key}-p")  # no move to itself

    def test_anything_else_is_not_a_ref(self):
        key = self.KEY
        for bad in (f"qk1-{key}-tt", f"qk1-{key}-tpf", f"qk1-{key}-tz", f"qk1-{key}-zt", f"qk1-{key}-",
                    f"qk1-{key}-tp-", f"qk1-{key}-t-p", f"qk1-{key}-tp-open-open", f"xqk1-{key}-tp",
                    f"qk1-{key}-tp x", f"qk1-{key}-tp\nqk1-{key}-t", f"qk1-{key}-TP", f"qk1-{key.upper()}-tp",
                    f"qk1-{key}-t p", f"qk1-{key}-tp-0A1B2C3D"):
            self.assertIsNone(cs.parse_ref(bad), bad)


class RecoveryTests(SyncBase):
    """A write of a sync fails once (HTTP 500), after it landed and before. One clean sync after
    it ends where an undisturbed sync ends: no second comment, upload, link or ticket.

    Of the writes of one kind (same call, same shape of body) the first and the last are failed;
    `QA_TRACKER_FULL_SWEEP=1` fails every write in turn."""

    def snapshot(self):
        fake = self.fake
        lists = {l["id"]: l["name"] for l in fake.lists.values()}
        names = {t["id"]: t["name"] for t in fake.tasks.values()}
        tasks = [{"list": lists[t["list"]["id"]], "name": t["name"], "status": t["status"]["status"],
                  "parent": names.get(t["parent"]), "values": dict(t["values"]), "text": t["markdown_description"],
                  "comments": [c["comment_text"] for c in fake.comments.get(t["id"], [])],
                  "files": sorted(fake.names_on(t["id"])),
                  "links": sorted(names[x] for x in fake.links.get(t["id"], ())),
                  "items": sorted((i["name"], i["resolved"]) for c in fake.checklists.values()
                                  if c["task_id"] == t["id"] for i in c["items"])}
                 for t in fake.tasks.values()]
        return {"lists": sorted((l["name"], l["archived"]) for l in fake.lists.values()),
                "tasks": sorted(tasks, key=lambda t: (t["list"], t["parent"] or "", t["name"]))}

    def break_write(self, k, lands):
        """The write number `k` (calls and uploads, counted from 0) answers HTTP 500."""
        fake, seen = self.fake, [0]
        request, upload = fake.request, fake.upload

        def failing(send, method, path):
            hit = seen[0] == k
            seen[0] += 1
            if hit and not lands:
                raise ApiError(method, path, 500, "internal error")
            out = send()
            if hit:
                raise ApiError(method, path, 500, "internal error")
            return out

        def flaky_request(method, path, body=None):
            if method.upper() == "GET":
                return request(method, path, body)
            return failing(lambda: request(method, path, body), method, path)

        def flaky_upload(path, file_path, filename):
            return failing(lambda: upload(path, file_path, filename), "POST", path)
        fake.request, fake.upload = flaky_request, flaky_upload

    @staticmethod
    def kind(call):
        method, path, body = call
        shape = re.sub(r"/[A-Za-z]?\d+(?=/|$)", "/*", path)
        if path.endswith("/field/f-ref"):   # a move in progress, a final letter, the summary's run
            parts = body["value"].split("-")
            return method, shape, len(parts[2]), len(parts)
        return method, shape, tuple(sorted(body)) if isinstance(body, dict) else None

    def picked(self, calls):
        if os.environ.get("QA_TRACKER_FULL_SWEEP"):
            return list(range(len(calls)))
        first, last = {}, {}
        for k, call in enumerate(calls):
            first.setdefault(self.kind(call), k)
            last[self.kind(call)] = k
        return sorted(set(first.values()) | set(last.values()))

    def sweep(self, prepare, act, at_least):
        prepare()
        cache = self.tmp / ".qa" / "tracker-map.json"
        start, saved = copy.deepcopy(self.fake), cache.read_text(encoding="utf-8")

        def again():
            self.fake = copy.deepcopy(start)
            cache.write_text(saved, encoding="utf-8")
        rc, lines, err = act()
        self.assertEqual(rc, 0, (lines, err))
        calls, want = list(self.fake.calls), self.snapshot()
        self.assertGreaterEqual(len(calls), at_least)
        for k in self.picked(calls):
            for lands in (True, False):
                with self.subTest(write=k, call=calls[k][:2], lands=lands):
                    again()
                    self.break_write(k, lands)
                    act()
                    del self.fake.request, self.fake.upload
                    rc, lines, err = act()
                    self.assertEqual(rc, 0, (lines, err))
                    self.assertEqual(self.snapshot(), want)
                    self.fake.calls.clear()
                    self.assertEqual(act()[0], 0)
                    self.assertEqual(self.fake.calls, [])

    def with_bug(self):
        self.fake.add_bug(BUG_TITLE, core.fingerprint("C-SCORE-02", "judge", BUG_TITLE))
        path = self.tmp / ".qa" / "runs" / RUN_1 / "bugs"
        path.mkdir(exist_ok=True)
        (path / "bugs.json").write_text(json.dumps([{"title": BUG_TITLE, "criterionId": "C-SCORE-02",
                                                     "persona": "judge"}]), encoding="utf-8")

    def test_first_sync_recovers_from_any_failed_write(self):
        self.sweep(self.with_bug, self.sync, 30)

    def test_retest_recovers_from_any_failed_write(self):
        def prepare():
            self.assertEqual(self.sync()[0], 0)
            self.add_run(RUN_2, [row("C-SCORE-01", "judge", "fail"), row("C-SCORE-02", "judge", "pass"),
                                 row("C-RANK-01", "judge", "pass"), row("C-RANK-01", "admin", "pass", "low"),
                                 row(LOAD, "admin", "pass")])
            self.only_shot(RUN_2, "judge", "C-SCORE-01", b"the score was not saved this time")
            self.fake.calls.clear()
        self.sweep(prepare, lambda: self.sync("--retest", run=RUN_2), 30)

    def test_second_run_in_a_new_list_recovers_from_any_failed_write(self):
        def prepare():
            self.edit_cfg(lambda d: d["specs"][TARGET].update(keepRuns=1))
            self.assertEqual(self.sync()[0], 0)
            self.add_run(RUN_2, ALL_PASS)
            self.fake.calls.clear()
        self.sweep(prepare, lambda: self.sync(run=RUN_2), 30)


class ArchiveTests(SyncBase):
    def runs(self, count, apply=True):
        """Sync `count` runs, each into its own list; the last one with `apply`."""
        for i in range(1, count + 1):
            run_id = f"2026-11-{20 + i}-judge-scoring"
            self.add_run(run_id, ALL_PASS)
            last = i == count
            rc, lines, err = self.sync(run=run_id, apply=apply if last else True)
            self.assertEqual(rc, 0, (lines, err))
        return lines

    def test_old_lists_archived_beyond_keep_runs(self):
        self.runs(4)
        self.assertEqual([l["name"] for l in self.lists(archived=True)], ["Run 1 · 2026-11-21"])
        self.assertEqual([l["name"] for l in self.lists()],
                         ["Run 2 · 2026-11-22", "Run 3 · 2026-11-23", "Run 4 · 2026-11-24"])
        archived = self.lists(archived=True)[0]["id"]
        self.assertEqual(self.fake.writes("PUT", r"/v2/list/\w+$")[-1], ("PUT", f"/v2/list/{archived}", {"archived": True}))
        self.assertEqual(len(self.fake.tasks_in(archived)), 6)   # nothing in it is touched or removed
        # the numbers go on, and an open list is never archived
        self.assertEqual(self.push()[0], 0)
        self.fake.calls.clear()
        self.assertEqual(self.sync(run="2026-11-24-judge-scoring")[0], 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual([l["name"] for l in self.lists()][-1], "Run 5 · next")
        self.assertEqual(self.fake.lists["905"]["archived"], False)

    def test_keep_runs_is_honoured(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(keepRuns=1))
        self.runs(3)
        self.assertEqual([l["name"] for l in self.lists()], ["Run 3 · 2026-11-23"])
        self.assertEqual(len(self.lists(archived=True)), 2)

    def test_nothing_is_archived_in_a_dry_run_or_after_a_failure(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(keepRuns=1))
        self.runs(1)
        self.add_run("2026-11-22-judge-scoring", ALL_PASS)
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.sync(run="2026-11-22-judge-scoring", apply=False)[0], 0)
        self.assertEqual(self.lists(archived=True), [])
        self.fake.fail_uploads = 1
        self.assertEqual(self.sync(run="2026-11-22-judge-scoring")[0], 1)
        self.assertEqual(self.lists(archived=True), [])
        self.assertEqual(self.sync(run="2026-11-22-judge-scoring")[0], 0)
        self.assertEqual([l["name"] for l in self.lists(archived=True)], ["Run 1 · 2026-11-21"])

    def test_run_whose_list_was_archived_is_not_synced_into_a_new_list(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(keepRuns=1))
        self.runs(2)
        self.fake.calls.clear()
        rc, lines, _ = self.sync(run="2026-11-21-judge-scoring")
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\tarchived\tRun 1 · 2026-11-21: the list of this run is archived; "
                      "restore it in ClickUp to sync the run again", lines)
        self.assertEqual(self.fake.calls, [])


if __name__ == "__main__":
    unittest.main()
