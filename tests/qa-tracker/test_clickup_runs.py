"""ClickUp push-run, push-results, push-bug and update-retest against an in-memory folder."""
from __future__ import annotations

import argparse
import copy
import io
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))

from trackers import clickup, core  # noqa: E402
from trackers.clickup_api import ApiError, Transport  # noqa: E402
from trackers.ctx import Ctx  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "clickup" / "runs"
FOLDER = "9003"
LABEL = "2026-11-11 v1.4.30"
VERDICT_OPTS = ["pass", "fail", "blocked", "deferred", "error"]


def dropdown(fid, name, options):
    return {"id": fid, "name": name, "type": "drop_down",
            "type_config": {"options": [{"id": f"{fid}-o{i}", "name": o, "orderindex": i}
                                        for i, o in enumerate(options)]}}


def text_field(fid, name, kind="short_text"):
    return {"id": fid, "name": name, "type": kind}


class FolderFake(Transport):
    """An in-memory ClickUp folder. Reflects every write; records every non-GET call."""

    def __init__(self):
        self.calls: list = []
        self.lists: dict = {}
        self.fields: dict = {}
        self.tasks: dict = {}
        self.comments: dict = {}
        self.n = 0
        self.fail_create_after_landing = 0  # next N task creates land, then raise HTTP 500
        area = lambda p: [dropdown(f"f-{p}-result", "Last check result", VERDICT_OPTS),  # noqa: E731
                          text_field(f"f-{p}-run", "Last check run")]
        self.add_list("901", "Core: Sign-in", area("a"))
        self.add_list("902", "Module: Events", area("b"))
        self.add_list("904", "Runs", [text_field("f-build", "Build"), text_field("f-env", "Environment"),
                                      text_field("f-lang", "Language"), text_field("f-passed", "Passed", "number"),
                                      text_field("f-failed", "Failed", "number"),
                                      text_field("f-blocked", "Blocked", "number")])
        self.add_list("905", "Bugs", [dropdown("f-sev", "Severity", ["critical", "high", "medium", "low"]),
                                      text_field("f-case", "Case", "list_relationship"),
                                      text_field("f-found", "Found in run"),
                                      dropdown("f-retest", "Retest result", ["passed", "still failing"]),
                                      text_field("f-ref", "Ref")])
        for tid, name, lid in [("a1", "TC-A-001 · Sign in", "901"), ("a2", "TC-A-002 · Wrong password", "901"),
                               ("a3", "TC-A-003 · Remember me", "901"), ("a4", "TC-A-004 · Old", "901"),
                               ("b1", "TC-B-001 · Event list", "902"), ("b2", "TC-B-002 · Event page", "902")]:
            self.add_task(tid, name, lid, "to test")

    def add_list(self, lid, name, fields):
        self.lists[lid] = {"id": lid, "name": name}
        self.fields[lid] = fields

    def add_task(self, tid, name, lid, status, values=None):
        self.tasks[tid] = {"id": tid, "name": name, "status": {"status": status, "type": "closed" if status == "closed" else "custom"},
                           "list": {"id": lid, "name": self.lists[lid]["name"]}, "values": dict(values or {}),
                           "priority": None, "markdown_description": ""}
        return self.tasks[tid]

    def view(self, t):
        out = {k: copy.deepcopy(v) for k, v in t.items() if k != "values"}
        cfs = []
        for f in self.fields[t["list"]["id"]]:
            cf = copy.deepcopy(f)
            if f["id"] in t["values"]:
                cf["value"] = copy.deepcopy(t["values"][f["id"]])
            cfs.append(cf)
        out["custom_fields"] = cfs
        return out

    def field_def(self, t, fid):
        return next(f for f in self.fields[t["list"]["id"]] if f["id"] == fid)

    def store(self, t, fid, value):
        f = self.field_def(t, fid)
        if f["type"] == "drop_down":
            value = next(o["orderindex"] for o in f["type_config"]["options"] if o["id"] == value)
        elif f["type"] == "list_relationship":
            cur = [x["id"] for x in t["values"].get(fid, [])]
            value = [{"id": i} for i in cur + [i for i in value["add"] if i not in cur] if i not in value["rem"]]
        t["values"][fid] = value

    def writes(self, method=None, pattern=""):
        return [c for c in self.calls if (method is None or c[0] == method) and re.search(pattern, c[1])]

    def request(self, method, path, body=None):
        method = method.upper()
        if method != "GET":
            self.calls.append((method, path, copy.deepcopy(body)))
        if method == "GET" and path == f"/v2/folder/{FOLDER}":
            return {"id": FOLDER, "lists": [dict(l) for l in self.lists.values()]}
        m = re.fullmatch(r"/v2/list/(\w+)/task\?.*page=(\d+)", path)
        if m and method == "GET":
            if m.group(2) != "0":
                return {"tasks": []}
            return {"tasks": [self.view(t) for t in self.tasks.values() if t["list"]["id"] == m.group(1)]}
        m = re.fullmatch(r"/v2/list/(\w+)/field", path)
        if m and method == "GET":
            return {"fields": copy.deepcopy(self.fields[m.group(1)])}
        m = re.fullmatch(r"/v2/list/(\w+)", path)
        if m and method == "GET":
            return {"id": m.group(1), "statuses": []}
        m = re.fullmatch(r"/v2/list/(\w+)/task", path)
        if m and method == "POST":
            self.n += 1
            t = self.add_task(f"n{self.n}", body["name"], m.group(1), body.get("status") or "to test")
            t["priority"] = {"id": str(body["priority"])} if body.get("priority") else None
            t["markdown_description"] = body.get("markdown_content", "")
            for cf in body.get("custom_fields") or []:
                self.store(t, cf["id"], cf["value"])
            if self.fail_create_after_landing:
                self.fail_create_after_landing -= 1
                raise ApiError(method, path, 500, "internal error")
            return self.view(t)
        m = re.fullmatch(r"/v2/task/(\w+)/field/([\w-]+)", path)
        if m and method == "POST":
            self.store(self.tasks[m.group(1)], m.group(2), body["value"])
            return {}
        m = re.fullmatch(r"/v2/task/(\w+)/comment", path)
        if m:
            if method == "POST":
                self.comments.setdefault(m.group(1), []).append(body["comment_text"])
                return {"id": "c"}
            return {"comments": [{"comment_text": c} for c in self.comments.get(m.group(1), [])]}
        m = re.fullmatch(r"/v2/task/(\w+)", path)
        if m and method == "PUT":
            t = self.tasks[m.group(1)]
            if "status" in body:
                t["status"] = {"status": body["status"], "type": "custom"}
            return {}
        raise ApiError(method, path, 404, "unhandled in FolderFake")


class RunsBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        shutil.copytree(FIX / "project", self.tmp, dirs_exist_ok=True)
        shutil.copytree(FIX / "run", self.tmp / ".qa" / "runs" / "r1")
        self.cfg_path = self.tmp / "docs/agents/qa-tracker.json"
        self.fake = FolderFake()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def edit_cfg(self, fn):
        data = json.loads(self.cfg_path.read_text())
        fn(data)
        self.cfg_path.write_text(json.dumps(data, indent=2) + "\n")

    def run_verb(self, verb, apply=True):
        cfg = core.load_config(self.tmp)
        out = io.StringIO()
        ctx = Ctx(project=self.tmp, cfg=cfg, catalog=core.load_catalog(self.tmp, cfg),
                  log=core.ActionLog(apply=apply, out=out), cache=core.MapCache(self.tmp),
                  args=argparse.Namespace(only=[], overwrite=[], transport=self.fake, run="r1", label=None))
        getattr(clickup, verb)(ctx)
        return [ln for ln in out.getvalue().splitlines() if ln]

    def ref(self, key, title, persona="user"):
        return core.fingerprint(key, persona, title)

    def bug_tasks(self):
        return [t for t in self.fake.tasks.values() if t["list"]["id"] == "905"]

    def clear_cache(self):
        (self.tmp / ".qa" / "tracker-map.json").unlink()


class PushRunTests(RunsBase):
    def test_push_run_idempotent_by_label(self):
        self.run_verb("push_run")
        creates = self.fake.writes("POST", r"/v2/list/904/task$")
        self.assertEqual([c[2]["name"] for c in creates], [f"Run {LABEL}"])
        t = next(t for t in self.fake.tasks.values() if t["name"] == f"Run {LABEL}")
        self.assertEqual(t["values"], {"f-build": "v1.4.30", "f-env": "staging", "f-lang": "ar",
                                       "f-passed": 2, "f-failed": 1, "f-blocked": 1})
        self.fake.calls.clear()
        self.run_verb("push_run")
        self.assertEqual(self.fake.calls, [])
        # a second machine: empty cache, same label → found by name, nothing written
        self.clear_cache()
        self.run_verb("push_run")
        self.assertEqual(self.fake.calls, [])

    def test_manifest_missing_leaves_fields_empty(self):
        (self.tmp / ".qa/runs/r1/run-manifest.json").unlink()
        self.run_verb("push_run")
        t = next(t for t in self.fake.tasks.values() if t["list"]["id"] == "904")
        self.assertEqual(t["name"], "Run r1")  # no manifest: the label falls back to the run dir
        self.assertNotIn("f-build", t["values"])
        self.assertNotIn("f-env", t["values"])
        self.assertEqual(t["values"]["f-passed"], 2)

    def test_missing_field_id_skips_that_field_only(self):
        self.edit_cfg(lambda d: (d["fields"].pop("Runs/Build"), d["fields"].pop("Core: Sign-in/Last check run")))
        lines = self.run_verb("push_run")
        self.assertEqual([ln for ln in lines if ln.startswith("SKIP")],
                         ["SKIP\tfield-missing\tRuns/Build: run tracker.sh init"])
        t = next(t for t in self.fake.tasks.values() if t["list"]["id"] == "904")
        self.assertNotIn("f-build", t["values"])
        self.assertEqual(t["values"]["f-env"], "staging")
        lines = self.run_verb("push_results")
        self.assertEqual([ln for ln in lines if ln.startswith("SKIP")],
                         ["SKIP\tfield-missing\tCore: Sign-in/Last check run: run tracker.sh init"])
        a1 = self.fake.tasks["a1"]
        self.assertNotIn("f-a-run", a1["values"])
        self.assertEqual(a1["values"]["f-a-result"], 0)  # pass
        self.assertEqual(self.fake.comments["a1"], [f"Checked on {LABEL}: pass (1 checks)."])


class ResultsTests(RunsBase):
    def test_results_never_change_status_by_default(self):
        self.run_verb("push_results")
        self.assertEqual(self.fake.writes("PUT"), [])
        self.assertEqual({t: self.fake.tasks[t]["status"]["status"] for t in ("a1", "a2", "a3", "b1")},
                         {"a1": "to test", "a2": "to test", "a3": "to test", "b1": "to test"})
        self.assertEqual(self.fake.tasks["a2"]["values"], {"f-a-result": 1, "f-a-run": LABEL})
        self.assertEqual(self.fake.tasks["a3"]["values"]["f-a-result"], 2)
        self.assertEqual(self.fake.tasks["b1"]["values"], {"f-b-result": 0, "f-b-run": LABEL})
        self.assertEqual(self.fake.comments["a2"], [f"Checked on {LABEL}: fail (1 checks)."])
        self.assertNotIn("a4", self.fake.comments)
        # unchanged result: no write, no second comment, also with a cleared cache
        self.fake.calls.clear()
        self.run_verb("push_results")
        self.assertEqual(self.fake.calls, [])
        self.clear_cache()
        self.run_verb("push_results")
        self.assertEqual(self.fake.calls, [])

    def test_result_change_comments_once(self):
        self.run_verb("push_results")
        cp = self.tmp / ".qa/runs/r1/checkpoint.json"
        data = json.loads(cp.read_text())
        data["criteria"][1]["verdict"] = "pass"
        cp.write_text(json.dumps(data))
        self.fake.calls.clear()
        self.run_verb("push_results")
        self.assertEqual([c[1] for c in self.fake.writes("POST", r"/comment$")], ["/v2/task/a2/comment"])
        self.assertEqual(self.fake.comments["a2"][-1], f"Checked on {LABEL}: pass (1 checks).")

    def test_results_ceiling_moves_to_testing_only_from_to_test(self):
        self.edit_cfg(lambda d: d.update(statusCeiling="testing"))
        self.fake.tasks["a2"]["status"]["status"] = "passed"
        self.fake.tasks["a3"]["status"]["status"] = "failed"
        self.run_verb("push_results")
        puts = self.fake.writes("PUT")
        self.assertEqual(sorted(c[1] for c in puts), ["/v2/task/a1", "/v2/task/b1"])
        self.assertTrue(all(c[2] == {"status": "testing"} for c in puts))
        self.assertEqual(self.fake.tasks["a2"]["status"]["status"], "passed")
        self.assertEqual(self.fake.tasks["a3"]["status"]["status"], "failed")
        self.fake.calls.clear()
        self.run_verb("push_results")
        self.assertEqual(self.fake.writes("PUT"), [])


class BugTests(RunsBase):
    def ref1(self):
        return self.ref("TC-A-002", "Wrong password shows no error message")

    def test_bug_dedupe_comments_instead_of_creating(self):
        self.fake.add_task("x1", "Wrong password shows no error message", "905", "fixing",
                           {"f-ref": self.ref1(), "f-found": "2026-11-01 v1.4.29"})
        lines = self.run_verb("push_bug")
        self.assertEqual(self.fake.comments["x1"], [f"Still happens on {LABEL}."])
        names = [c[2]["name"] for c in self.fake.writes("POST", r"/v2/list/905/task$")]
        self.assertEqual(names, ["Footer privacy link opens a not found page"])
        self.assertEqual(self.fake.tasks["x1"]["status"]["status"], "fixing")
        self.assertEqual(self.fake.writes("PUT"), [])
        self.assertTrue(any(ln.startswith("SKIP\twording\t") and ln.endswith(": automated") for ln in lines))
        # second run: the comment is already there, the new bug is found by Ref
        self.fake.calls.clear()
        self.run_verb("push_bug")
        self.assertEqual(self.fake.calls, [])

    def test_closed_bug_reappears_as_new_with_note(self):
        self.fake.add_task("x1", "Old sign-in error bug", "905", "closed", {"f-ref": self.ref1()})
        self.run_verb("push_bug")
        creates = {c[2]["name"]: c[2] for c in self.fake.writes("POST", r"/v2/list/905/task$")}
        body = creates["Wrong password shows no error message"]
        self.assertTrue(body["markdown_content"].startswith(
            "Seen again after it was closed: Old sign-in error bug."))
        self.assertEqual(body["status"], "open")
        self.assertNotIn("x1", self.fake.comments)
        self.assertEqual(self.fake.tasks["x1"]["status"]["status"], "closed")
        self.fake.calls.clear()
        self.run_verb("push_bug")
        self.assertEqual(self.fake.writes("POST", r"/task$"), [])

    def test_new_bug_fields_text_and_case_link(self):
        self.run_verb("push_bug")
        creates = {c[2]["name"]: c for c in self.fake.writes("POST", r"/v2/list/905/task$")}
        body = creates["Wrong password shows no error message"][2]
        self.assertEqual(body["markdown_content"],
                         "**What happened**\nThe page reloads with no message.\n\n"
                         "**What should happen**\nA red message says the password is wrong.\n\n"
                         "**Steps**\n1. Open the sign-in page.\n2. Enter a wrong password and submit.")
        new = next(t for t in self.bug_tasks() if t["name"] == "Wrong password shows no error message")
        self.assertEqual(new["values"]["f-ref"], self.ref1())
        self.assertEqual(new["values"]["f-found"], LABEL)
        self.assertEqual(new["values"]["f-sev"], 1)  # high
        self.assertEqual(new["values"]["f-case"], [{"id": "a2"}])
        footer = next(t for t in self.bug_tasks() if t["name"].startswith("Footer"))
        self.assertEqual(footer["values"]["f-ref"], self.ref("C5", "Footer privacy link opens a not found page"))
        self.assertNotIn("f-case", footer["values"])
        sent = json.dumps(self.fake.calls)
        for leak in ("FE/route", "evidence", "BUG-1", "\"C2\"", "C2/"):
            self.assertNotIn(leak, sent)

    def test_priority_follows_severity_table(self):
        self.assertEqual(clickup.SEVERITY_PRIORITY, {"critical": 1, "high": 2, "medium": 3, "low": 4})
        self.run_verb("push_bug")
        pri = {c[2]["name"]: c[2].get("priority") for c in self.fake.writes("POST", r"/v2/list/905/task$")}
        self.assertEqual(pri, {"Wrong password shows no error message": 2,
                               "Footer privacy link opens a not found page": 1})

    def test_wording_hit_skips_only_that_bug(self):
        lines = self.run_verb("push_bug")
        ref3 = self.ref("TC-A-002", "Sign-in button stays disabled")
        self.assertIn(f"SKIP\twording\t{ref3}: automated", lines)
        self.assertEqual(len(self.fake.writes("POST", r"/v2/list/905/task$")), 2)

    def test_cleared_cache_second_run_creates_no_duplicates(self):
        self.run_verb("push_run")
        self.run_verb("push_bug")
        self.clear_cache()
        self.fake.calls.clear()
        self.run_verb("push_run")
        self.run_verb("push_bug")
        self.assertEqual(self.fake.writes("POST", r"/task$"), [])
        self.assertEqual(len(self.bug_tasks()), 2)

    def test_create_that_landed_after_500_is_found_by_ref(self):
        self.fake.fail_create_after_landing = 1
        lines = self.run_verb("push_bug")
        self.assertTrue(any(ln.startswith("APPLY\treconciled\t") for ln in lines))
        self.assertEqual(len(self.bug_tasks()), 2)
        self.fake.calls.clear()
        self.run_verb("push_bug")
        self.assertEqual(self.fake.writes("POST", r"/task$"), [])
        self.assertEqual(len(self.bug_tasks()), 2)

    def test_create_500_that_did_not_land_is_not_retried(self):
        class NoLand(FolderFake):
            def request(s, method, path, body=None):
                if method == "POST" and path == "/v2/list/905/task":
                    s.calls.append((method, path, body))
                    raise ApiError(method, path, 502, "bad gateway")
                return super().request(method, path, body)
        self.fake = NoLand()
        lines = self.run_verb("push_bug")
        self.assertEqual(len(self.fake.writes("POST", r"/v2/list/905/task$")), 2)  # one try per bug
        self.assertEqual(sum(1 for ln in lines if ln.startswith("SKIP\tapi-error")), 2)
        self.assertEqual(self.bug_tasks(), [])


class RetestTests(RunsBase):
    def test_retest_sets_field_never_status(self):
        self.fake.add_task("r1", "Sign in broke", "905", "retest", {"f-case": [{"id": "a1"}]})
        self.fake.add_task("r2", "Wrong password", "905", "retest", {"f-case": [{"id": "a2"}]})
        self.fake.add_task("r3", "Remember me", "905", "retest", {"f-case": [{"id": "a3"}]})
        self.fake.add_task("r4", "Not ready", "905", "fixing", {"f-case": [{"id": "a1"}]})
        self.fake.add_task("r5", "Unrelated", "905", "retest", {"f-case": [{"id": "a4"}]})
        lines = self.run_verb("update_retest")
        self.assertEqual(self.fake.writes("PUT"), [])
        self.assertEqual(self.fake.tasks["r1"]["values"]["f-retest"], 0)  # passed
        self.assertEqual(self.fake.tasks["r2"]["values"]["f-retest"], 1)  # still failing
        self.assertNotIn("f-retest", self.fake.tasks["r3"]["values"])
        self.assertNotIn("f-retest", self.fake.tasks["r4"]["values"])
        self.assertNotIn("f-retest", self.fake.tasks["r5"]["values"])
        self.assertEqual(self.fake.comments["r1"], [f"Retest on {LABEL}: passed."])
        self.assertEqual(self.fake.comments["r2"], [f"Retest on {LABEL}: still failing."])
        self.assertIn("SKIP\tretest-inconclusive\tRemember me: TC-A-003 blocked", lines)
        self.assertEqual({t["status"]["status"] for t in self.bug_tasks()}, {"retest", "fixing"})
        self.fake.calls.clear()
        self.run_verb("update_retest")
        self.assertEqual(self.fake.calls, [])


class DryRunTests(RunsBase):
    def test_dry_run_makes_no_writes(self):
        self.fake.add_task("r1", "Sign in broke", "905", "retest", {"f-case": [{"id": "a1"}]})
        self.edit_cfg(lambda d: d.update(statusCeiling="testing"))
        lines = []
        for verb in ("push_run", "push_results", "push_bug", "update_retest"):
            lines += self.run_verb(verb, apply=False)
        self.assertEqual(self.fake.calls, [])
        self.assertFalse((self.tmp / ".qa" / "tracker-map.json").exists())
        self.assertTrue(any(ln.startswith(f"DRY\tcreate\tRun {LABEL}") for ln in lines))
        self.assertTrue(any(ln.startswith("DRY\tstatus\tTC-A-001") for ln in lines))
        self.assertTrue(any(ln.startswith("DRY\tcreate\t") and "Footer" in ln for ln in lines))
        self.assertFalse(any(ln.startswith("APPLY") for ln in lines))


if __name__ == "__main__":
    unittest.main()
