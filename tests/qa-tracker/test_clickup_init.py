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

PROJECT = Path(__file__).resolve().parent / "fixtures" / "clickup" / "init" / "project"
FOLDER = "9003"
CASE_STATUSES = ["to test", "testing", "failed", "blocked", "passed", "skipped"]
BUG_STATUSES = ["open", "triaged", "fixing", "retest", "closed"]
AREA_FIELDS = ["Role", "Level", "Last check result", "Last check run", "Linked bugs"]


class InitFake(Transport):
    """In-memory folder: lists with statuses, custom fields and views. Records every write."""

    def __init__(self):
        self.calls: list = []
        self.lists: dict = {}
        self.fields: dict = {}
        self.views: dict = {}
        self.n = 0

    def add_list(self, lid, name, statuses=CASE_STATUSES, fields=(), views=()):
        self.lists[lid] = {"id": lid, "name": name, "statuses": [{"status": s} for s in statuses]}
        self.fields[lid] = [{"id": f"cf-{lid}-{i}", "name": f, "type": "short_text"} for i, f in enumerate(fields)]
        self.views[lid] = [{"id": f"v-{lid}-{i}", "name": v} for i, v in enumerate(views)]

    def writes(self, method=None, pattern=""):
        return [c for c in self.calls if (method is None or c[0] == method) and re.search(pattern, c[1])]

    def request(self, method, path, body=None):
        method = method.upper()
        if method != "GET":
            self.calls.append((method, path, copy.deepcopy(body)))
        if method == "GET" and path == f"/v2/folder/{FOLDER}":
            return {"id": FOLDER, "lists": [{"id": l["id"], "name": l["name"]} for l in self.lists.values()]}
        if method == "POST" and path == f"/v2/folder/{FOLDER}/list":
            self.n += 1
            lid = f"L{self.n}"
            self.add_list(lid, body["name"], statuses=CASE_STATUSES)
            return {"id": lid}
        m = re.fullmatch(r"/v2/list/(\w+)(?:/(field|view))?", path)
        if m and m.group(1) in self.lists:
            lid, sub = m.group(1), m.group(2)
            if sub is None and method == "GET":
                return copy.deepcopy(self.lists[lid])
            if sub == "field" and method == "GET":
                return {"fields": copy.deepcopy(self.fields[lid])}
            if sub == "view" and method == "GET":
                return {"views": copy.deepcopy(self.views[lid])}
            if sub == "view" and method == "POST":
                self.n += 1
                self.views[lid].append({"id": f"nv{self.n}", "name": body["name"]})
                return {"view": {"id": f"nv{self.n}", "name": body["name"]}}
        raise ApiError(method, path, 404, "unhandled in InitFake")


class InitBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        shutil.copytree(PROJECT, self.tmp, dirs_exist_ok=True)
        self.cfg_path = self.tmp / "docs/agents/qa-tracker.json"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_init(self, fake, apply=False):
        cfg = core.load_config(self.tmp)
        out = io.StringIO()
        ctx = Ctx(project=self.tmp, cfg=cfg, catalog=core.load_catalog(self.tmp, cfg),
                  log=core.ActionLog(apply=apply, out=out), cache=core.MapCache(self.tmp),
                  args=argparse.Namespace(only=[], overwrite=[], transport=fake))
        clickup.init(ctx)
        return [ln for ln in out.getvalue().splitlines() if ln]

    def seed_complete(self, fake):
        """Every list present with every field, correct statuses and no views."""
        fake.add_list("901", "Core: Sign-in", fields=AREA_FIELDS)
        fake.add_list("902", "Module: Events", fields=AREA_FIELDS)
        fake.add_list("903", "00 – Guide & Sign-off")
        fake.add_list("904", "Runs", fields=["Build", "Environment", "Language", "Passed", "Failed", "Blocked"])
        fake.add_list("905", "Bugs", statuses=BUG_STATUSES,
                      fields=["Severity", "Case", "Found in run", "Retest result", "Ref"])


class InitTests(InitBase):
    def test_init_creates_missing_lists_and_views_only(self):
        fake = InitFake()
        fake.add_list("901", "Core: Sign-in", fields=AREA_FIELDS)
        lines = self.run_init(fake, apply=True)
        created = [c[2]["name"] for c in fake.writes("POST", r"/v2/folder/9003/list$")]
        self.assertEqual(created, ["Module: Events", "00 – Guide & Sign-off", "Runs", "Bugs"])
        # views: Core has all three (its Level field exists), the new Events list gets the two that
        # need no field, Runs one; "By level" (Events) and both Bugs views wait for their field
        views = {(c[1], c[2]["name"]): c[2] for c in fake.writes("POST", r"/view$")}
        self.assertEqual(sorted(n for (_, n) in views), [
            "By level", "By priority", "By priority", "By status", "By status", "Results by run"])
        core_views = {n: b for (p, n), b in views.items() if p == "/v2/list/901/view"}
        self.assertEqual(core_views["By status"], {"name": "By status", "type": "list", "grouping": {
            "field": "status", "dir": 1, "collapsed": [], "ignore": False}})
        self.assertEqual(core_views["By priority"]["grouping"]["field"], "priority")
        self.assertEqual(core_views["By level"]["grouping"]["field"], "cf_cf-901-1")
        self.assertEqual(core_views["By level"]["type"], "list")
        # nothing but list and view creation
        self.assertEqual({c[0] for c in fake.calls}, {"POST"})
        self.assertEqual(len(fake.calls), 4 + 6)
        self.assertTrue(any(ln.startswith("pending\tModule: Events: By level (needs field Level)") for ln in lines))
        self.assertTrue(any(ln.startswith("pending\tBugs: By case (needs field Case)") for ln in lines))
        # a second run finds the lists and views by name: no list is created twice
        fake.calls.clear()
        self.run_init(fake, apply=True)
        self.assertEqual(fake.writes("POST", r"/v2/folder/9003/list$"), [])
        self.assertEqual(fake.writes("POST", r"/view$"), [])

    def test_missing_field_prints_manual_step_and_no_post(self):
        fake = InitFake()
        self.seed_complete(fake)
        fake.fields["901"] = [f for f in fake.fields["901"] if f["name"] != "Last check run"]
        fake.lists["905"]["statuses"] = [{"status": "open"}, {"status": "closed"}]
        lines = self.run_init(fake, apply=True)
        manual = [ln for ln in lines if ln.startswith("MANUAL")]
        self.assertEqual(manual, [
            'MANUAL\t1. In list "Core: Sign-in": add custom field "Last check run" (short text)',
            'MANUAL\t2. In list "Bugs": add status "triaged"',
            'MANUAL\t3. In list "Bugs": add status "fixing"',
            'MANUAL\t4. In list "Bugs": add status "retest"',
        ])
        self.assertEqual(fake.writes(None, r"/field"), [])
        self.assertEqual([c for c in fake.calls if "/folder/" in c[1]], [])  # no list created
        self.assertTrue(all(c[1].endswith("/view") for c in fake.calls))  # views only

    def test_ids_written_back_on_apply(self):
        fake = InitFake()
        self.seed_complete(fake)
        before = json.loads(self.cfg_path.read_text())
        self.run_init(fake, apply=True)
        data = json.loads(self.cfg_path.read_text())
        self.assertEqual(data["lists"], {"Core: Sign-in": "901", "Module: Events": "902",
                                         "00 – Guide & Sign-off": "903", "Runs": "904", "Bugs": "905"})
        self.assertEqual(data["fields"]["Core: Sign-in/Level"], "cf-901-1")
        self.assertEqual(data["fields"]["Bugs/Case"], "cf-905-1")
        self.assertEqual(data["fields"]["Runs/Blocked"], "cf-904-5")
        self.assertEqual(len(data["fields"]), 5 + 5 + 5 + 6)
        for k in ("backend", "catalog", "guideDir", "guideAs", "ids"):
            self.assertEqual(data[k], before[k])
        raw = self.cfg_path.read_text()
        self.assertEqual(raw, json.dumps(data, indent=2, ensure_ascii=False) + "\n")

    def test_dry_run_writes_nothing(self):
        fake = InitFake()
        fake.add_list("901", "Core: Sign-in", fields=AREA_FIELDS)
        raw = self.cfg_path.read_text()
        lines = self.run_init(fake, apply=False)
        self.assertEqual(fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(), raw)
        self.assertTrue(any(ln.startswith("DRY\tcreate-list\tRuns") for ln in lines))
        self.assertTrue(any(ln.startswith("MANUAL") and '"Bugs"' in ln and '"Severity"' in ln for ln in lines))

    def test_rerun_after_manual_steps_fills_ids_and_prints_no_manual(self):
        fake = InitFake()
        self.seed_complete(fake)
        fake.fields["905"] = [f for f in fake.fields["905"] if f["name"] not in ("Severity", "Case")]
        lines = self.run_init(fake, apply=True)
        self.assertEqual(len([ln for ln in lines if ln.startswith("MANUAL")]), 2)
        self.assertEqual(sum(1 for ln in lines if ln.startswith("pending")), 2)
        data = json.loads(self.cfg_path.read_text())
        self.assertNotIn("Bugs/Case", data["fields"])
        # a person adds the two fields in ClickUp
        fake.fields["905"] += [{"id": "cf-sev", "name": "Severity", "type": "drop_down"},
                               {"id": "cf-case", "name": "Case", "type": "list_relationship"}]
        fake.calls.clear()
        lines = self.run_init(fake, apply=True)
        self.assertEqual([ln for ln in lines if ln.startswith("MANUAL") or ln.startswith("pending")], [])
        bug_views = {c[2]["name"]: c[2] for c in fake.writes("POST", r"/v2/list/905/view$")}
        self.assertEqual(sorted(bug_views), ["By case", "Open by severity"])
        self.assertEqual(bug_views["By case"]["grouping"]["field"], "cf_cf-case")
        data = json.loads(self.cfg_path.read_text())
        self.assertEqual(data["fields"]["Bugs/Case"], "cf-case")
        self.assertEqual(data["fields"]["Bugs/Severity"], "cf-sev")


if __name__ == "__main__":
    unittest.main()
