"""`sync-run` through cli.main, against the in-memory ClickUp space of the structure tests.

`SyncFake` adds what a run sync touches: attachments (seen only on a single task read, as ClickUp
answers), uploads, task links, checklist item updates, list renames and archiving (an archived
list leaves the folder's list and is listed only with `archived=true`), and tasks that carry a
list-level field (the Bugs list's own `Ref`).
"""
from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

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

    def add_run(self, run_id, rows=None, manifest=None):
        run_dir = self.tmp / ".qa" / "runs" / run_id
        shutil.copytree(RUN_FIXTURE, run_dir, dirs_exist_ok=True)
        if rows is not None:
            (run_dir / "checkpoint.json").write_text(json.dumps({"criteria": rows}), encoding="utf-8")
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
        shutil.rmtree(self.tmp / ".qa" / "tracker-map.json", ignore_errors=True)
        (self.tmp / ".qa" / "tracker-map.json").unlink(missing_ok=True)
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
        self.assertEqual(self.fake.names_on(t["id"]), ["screen-1.png", "screen-2.png"])
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

    def test_run_of_another_spec_is_refused_before_any_write(self):
        self.add_run("2026-11-29-team-registration", [row("C-REG-01", "applicant", "pass"),
                                                      row("C-REG-02", "applicant", "fail")])
        rc, lines, _ = self.sync(run="2026-11-29-team-registration")
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\tother-run\tnone of this run's results belongs to this spec's cards; "
                      "name the run with --run", lines)
        self.assertEqual(self.fake.calls, [])

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

    def test_status_written_without_its_letter_is_finished(self):
        real, seen = self.fake.request, [0]

        def flaky(method, path, body=None):  # the first status lands, its Ref letter does not
            if method == "POST" and path.endswith("/field/f-ref"):
                seen[0] += 1
                if seen[0] == 2:
                    raise ApiError(method, path, 502, "bad gateway")
            return real(method, path, body)
        self.fake.request = flaky
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 1)
        self.assertEqual(self.state(SAVE), ("passed", "t"))
        del self.fake.request
        rc, lines, _ = self.sync()
        self.assertEqual(rc, 0, lines)
        self.assertNotIn("changed-by-person", "\n".join(lines))
        for name, want in ((SAVE, ("passed", "p")), (REFUSE, ("failed", "f")), ("Run summary", ("failed", "f"))):
            self.assertEqual(self.state(name), want)
        self.assertEqual(cs.parse_ref(self.summary()["values"]["f-ref"])["run"], cs.run_hash(RUN_1))

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
        self.assertIn(f"DRY\tattach\t{REFUSE}: screen-1.png", lines)
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

    def test_card_added_after_the_tickets_stops_before_writes(self):
        def add(d):
            d["cards"][0]["checks"].append({"criterion": "C-SCORE-03", "title": "Change a saved score",
                                            "do": "Open a scored submission, type 6 and press Save.",
                                            "expect": "The new score replaces the old one."})
        self.edit_cards(add)
        self.edit_plan(lambda rows: rows + [{"id": "C-SCORE-03", "persona": "judge", "kind": "happy-path"}])
        rc, lines, err = self.sync()
        self.assertEqual(rc, 1)
        self.assertIn("error: the plan changed since the tickets were made; run push-scenarios", err)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.sync()[0], 0)

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
        self.assertEqual(self.fake.names_on(raised["id"]), ["screen-1.png"])
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


class EvidenceTests(SyncBase):
    def test_evidence_uploaded_once_with_neutral_names(self):
        rc, lines, err = self.sync()
        self.assertEqual(rc, 0, (lines, err))
        on = {name: self.fake.names_on(self.fake.task(name)["id"]) for name in (SAVE, REFUSE, JUDGE_RANK, ADMIN_RANK)}
        self.assertEqual(on, {SAVE: ["screen-1.png"], REFUSE: ["screen-1.png", "screen-2.png", "screen-3.png"],
                              JUDGE_RANK: ["screen-1.png"], ADMIN_RANK: ["screen-1.png"]})
        refuse = self.fake.task(REFUSE)["id"]
        folder = RUN_FIXTURE / "evidence" / "judge" / "C-SCORE-02"
        self.assertEqual([a["data"] for a in self.fake.attachments[refuse]],
                         [(folder / n).read_bytes() for n in ("screenshot-before.png", "screenshot-after-message.png",
                                                              "screenshot-after.png")])
        self.assertEqual({c[2] for c in self.fake.calls if c[0] == "UPLOAD"},
                         {"screen-1.png", "screen-2.png", "screen-3.png"})
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
        self.assertEqual(self.fake.names_on(self.fake.task(SAVE)["id"]), ["screen-1.jpg"])

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
        self.assertTrue(any(ln.startswith("SKIP\tapi-error\t") and "screen-1.png" in ln for ln in lines), lines)
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
        self.assertIn(f"SKIP\tupload-failed\t{SAVE}: screen-1.png could not be read", lines)
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

    def test_retest_resets_a_ticket_a_person_moved_and_keeps_what_it_said(self):
        self.assertEqual(self.sync()[0], 0)
        self.move(REFUSE, "passed")
        self.add_run(RUN_2, [row("C-SCORE-02", "judge", "fail")])
        rc, lines, _ = self.sync("--retest", run=RUN_2)
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.texts(REFUSE), ["Earlier result: passed (2026-11-27)."])
        self.assertEqual(self.state(REFUSE), ("failed", "f"))
        self.assertEqual(self.state(SAVE), ("to test", "t"))
        items = [i["resolved"] for c in self.fake.checklists.values() for i in c["items"]]
        self.assertEqual(items, [False, False])

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
        self.assertEqual(rc, 0, lines)
        self.assertIn("APPLY\tbug-unlinked\tExport misses the last row: no scenario ticket holds its check", lines)
        self.assertIn(f"APPLY\tbug-not-found\t{BUG_TITLE}: not in the Bugs list yet; run push-bug first", lines)
        self.assertEqual(self.fake.writes("POST", r"/link/"), [])

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
    import unittest
    unittest.main()
