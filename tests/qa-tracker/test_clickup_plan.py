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
from unittest import mock
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))

from trackers import clickup, core  # noqa: E402
from trackers.clickup_api import ApiError, FakeTransport, Transport  # noqa: E402
from trackers.ctx import Ctx  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "clickup" / "plan"
REPLAY = FIX / "replay"
WS, SPACE, FOLDER = "9001", "9002", "9003"
TODAY = "2026-11-11"


def _replay(name: str):
    return json.loads((REPLAY / name).read_text(encoding="utf-8"))


class FolderFake(Transport):
    """An in-memory ClickUp folder seeded from the replay fixtures that reflects every write.

    `fail_once` = {(METHOD, path_regex)}: that write is applied, then raises ApiError(500) once
    (a request the server accepted but whose answer was lost).
    """

    def __init__(self, empty: bool = False, fail_once=()):
        self.calls: list = []
        self.fail_once = set(fail_once)
        folder = _replay(f"GET_v2_folder_{FOLDER}.json")
        self.lists = {l["id"]: {"id": l["id"], "name": l["name"]} for l in folder["lists"]}
        self.tasks: dict = {}
        self.comments: dict = {}
        self.docs: dict = {}
        self.pages: dict = {}
        self.n = 0
        for lid in self.lists:
            info = _replay(f"GET_v2_list_{lid}.json")
            self.lists[lid].update(content=info["content"], statuses=info["statuses"])
            if not empty:
                page = _replay("GET_v2_list_%s_task_%s_page_0.json"
                               % (lid, re.sub(r"[&=]", "_", clickup.TASK_QUERY)))
                for t in page["tasks"]:
                    self.tasks[t["id"]] = copy.deepcopy(t)

    def _id(self, p):
        self.n += 1
        return f"{p}{self.n}"

    @staticmethod
    def _plain(md):
        return (md or "").replace("**", "")

    def writes(self, method=None, pattern=""):
        return [c for c in self.calls if (method is None or c[0] == method) and re.search(pattern, c[1])]

    def request(self, method, path, body=None):
        method = method.upper()
        if method != "GET":
            self.calls.append((method, path, copy.deepcopy(body)))
        out = self._handle(method, path, body or {})
        for key in list(self.fail_once):
            if key[0] == method and re.search(key[1], path):
                self.fail_once.discard(key)
                raise ApiError(method, path, 500, "gateway timeout")
        return out

    def _handle(self, method, path, body):
        p, _, _q = path.partition("?")
        if method == "GET" and p == f"/v2/folder/{FOLDER}":
            return {"id": FOLDER, "lists": [{"id": l["id"], "name": l["name"]} for l in self.lists.values()]}
        m = re.fullmatch(r"/v2/list/(\w+)/task", p)
        if m and method == "GET":
            page = int(re.search(r"page=(\d+)", path).group(1))
            ts = [copy.deepcopy(t) for t in self.tasks.values() if t["list"]["id"] == m.group(1)]
            return {"tasks": ts if page == 0 else []}
        if m and method == "POST":
            lid = m.group(1)
            tid = self._id("n")
            pri = body.get("priority")
            self.tasks[tid] = {
                "id": tid, "name": body["name"], "markdown_description": body.get("markdown_content", ""),
                "description": self._plain(body.get("markdown_content")),
                "status": {"status": body.get("status", "to test")},
                "priority": {"id": str(pri)} if pri else None,
                "tags": [{"name": x} for x in body.get("tags", [])],
                "list": {"id": lid, "name": self.lists[lid]["name"]}}
            return {"id": tid}
        m = re.fullmatch(r"/v2/list/(\w+)", p)
        if m:
            lst = self.lists[m.group(1)]
            if method == "GET":
                return copy.deepcopy(lst)
            lst["content"] = self._plain(body.get("markdown_content"))
            return {}
        if method == "POST" and p == f"/v2/folder/{FOLDER}/list":
            lid = self._id("L")
            self.lists[lid] = {"id": lid, "name": body["name"], "content": "",
                               "statuses": copy.deepcopy(next(iter(self.lists.values()))["statuses"])}
            return {"id": lid}
        m = re.fullmatch(r"/v2/task/(\w+)", p)
        if m and method == "PUT":
            t = self.tasks[m.group(1)]
            if "name" in body:
                t["name"] = body["name"]
            if "markdown_content" in body:
                t["markdown_description"] = body["markdown_content"]
                t["description"] = self._plain(body["markdown_content"])
            if "priority" in body:
                t["priority"] = {"id": str(body["priority"])}
            if "status" in body:
                t["status"] = {"status": body["status"]}
            return {}
        m = re.fullmatch(r"/v2/task/(\w+)/comment", p)
        if m:
            self.comments.setdefault(m.group(1), []).append(body["comment_text"])
            return {"id": self._id("c")}
        m = re.fullmatch(r"/v2/task/(\w+)/tag/(.+)", p)
        if m:
            t, tag = self.tasks[m.group(1)], unquote(m.group(2))
            names = [x["name"] for x in t["tags"]]
            if method == "POST" and tag not in names:
                t["tags"].append({"name": tag})
            if method == "DELETE":
                t["tags"] = [x for x in t["tags"] if x["name"] != tag]
            return {}
        m = re.fullmatch(rf"/v3/workspaces/{WS}/tasks/(\w+)/home_list/(\w+)", p)
        if m:
            lid = m.group(2)
            self.tasks[m.group(1)]["list"] = {"id": lid, "name": self.lists[lid]["name"]}
            return {}
        if p == f"/v3/workspaces/{WS}/docs":
            if method == "GET":
                return {"docs": copy.deepcopy(list(self.docs.values())), "next_cursor": None}
            did = self._id("d")
            self.docs[did] = {"id": did, "name": body["name"], "parent": body["parent"]}
            self.pages[did] = []
            return {"id": did}
        m = re.fullmatch(rf"/v3/workspaces/{WS}/docs/(\w+)/pages(?:/(\w+))?", p)
        if m:
            did, pid = m.group(1), m.group(2)
            if method == "GET":
                return copy.deepcopy(self.pages[did])
            if method == "POST":
                pid = self._id("p")
                self.pages[did].append({"id": pid, "name": body["name"], "content": body["content"], "pages": []})
                return {"id": pid}
            page = next(x for x in self.pages[did] if x["id"] == pid)
            page.update(name=body["name"], content=body["content"])
            return {}
        raise ApiError(method, path, 404, "unhandled in FolderFake")


class PlanTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        shutil.copytree(FIX / "project", self.tmp, dirs_exist_ok=True)
        self.today = mock.patch.object(clickup, "today", return_value=TODAY)
        self.today.start()

    def tearDown(self):
        self.today.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_cfg(self, **kw):
        p = self.tmp / "docs/agents/qa-tracker.json"
        data = json.loads(p.read_text())
        data.update(kw)
        p.write_text(json.dumps(data))

    def edit_case(self, file, cid, **kw):
        p = self.tmp / "catalog" / file
        data = json.loads(p.read_text())
        for c in data["cases"]:
            if c["id"] == cid:
                c.update(kw)
        p.write_text(json.dumps(data))

    def run_verb(self, transport, verb="push_plan", apply=False, only=(), overwrite=()):
        cfg = core.load_config(self.tmp)
        out = io.StringIO()
        ctx = Ctx(project=self.tmp, cfg=cfg, catalog=core.load_catalog(self.tmp, cfg),
                  log=core.ActionLog(apply=apply, out=out), cache=core.MapCache(self.tmp),
                  args=argparse.Namespace(only=list(only), overwrite=list(overwrite), transport=transport))
        getattr(clickup, verb)(ctx)
        lines = [ln for ln in out.getvalue().splitlines() if ln]
        return lines, ctx.log.summary()


class PushPlanTests(PlanTestBase):
    def test_dry_run_matches_expected_actions(self):
        fake = FakeTransport(REPLAY)
        lines, summary = self.run_verb(fake)
        self.assertEqual(lines, [
            "DRY\tupdate\tTC-A-002 [description]",
            "DRY\tmove\tTC-A-003: Module: Events → Core: Sign-in",
            "DRY\ttag+\tTC-B-001 technical",
            "DRY\tcreate\tTC-B-002 → Module: Events",
            "DRY\tretire\tTC-A-009 (orphan, Core: Sign-in)",
            "DRY\tskip\tTC-A-009",
        ])
        self.assertEqual(summary, 'SUMMARY {"create": 1, "move": 1, "retire": 1, "skip": 1, "tag+": 1, "update": 1} dry-run')
        self.assertEqual(fake.calls, [])

    def test_apply_writes_exact_requests(self):
        fake = FolderFake()
        self.run_verb(fake, apply=True)
        create = fake.writes("POST", r"/v2/list/902/task$")[0][2]
        self.assertEqual(create["name"], "TC-B-002 · Register for an event")
        self.assertEqual((create["priority"], create["status"], create["tags"]), (3, "to test", ["beginner"]))
        self.assertEqual(create["markdown_content"], (
            "**Level:** Beginner\n\n**Preconditions:** A published event with free seats.\n\n"
            "**Steps:**\n1. Open the event.\n2. Press Register.\n\n"
            "**Expected results:**\n- You get a confirmation email.\n\n"
            "**Evidence:**\n- [ ] Screenshot / recording attached (or n/a)"))
        self.assertTrue(fake.writes("PUT", rf"^/v3/workspaces/{WS}/tasks/t3/home_list/901$"))
        self.assertEqual(fake.comments["t5"], [
            f"Retired on {TODAY}: this case is no longer part of the test plan; the feature it covered was replaced."])
        self.assertEqual(fake.tasks["t5"]["status"]["status"], "skipped")
        self.assertNotIn("t2", fake.comments)  # A-002 is still "to test": no re-verify comment
        self.assertEqual(fake.writes("DELETE"), [])

    def test_update_comment_when_not_to_test(self):
        self.edit_case("area-a.json", "TC-A-003", title="Email verification blocks the home page")
        fake = FolderFake()
        lines, _ = self.run_verb(fake, apply=True)
        self.assertIn("APPLY\tupdate\tTC-A-003 [title]", lines)
        self.assertEqual(fake.comments["t3"],
                         [f"Updated from the catalog on {TODAY} — re-verify if already passed."])
        self.assertEqual(fake.tasks["t3"]["status"]["status"], "passed")  # never touched

    def test_second_run_after_apply_is_empty(self):
        fake = FolderFake()
        self.run_verb(fake, apply=True)
        _, summary = self.run_verb(fake)
        self.assertEqual(summary, "SUMMARY {} dry-run")
        # Review Focus 1: a second machine with an empty cache creates nothing either
        (self.tmp / ".qa" / "tracker-map.json").unlink()
        _, summary = self.run_verb(fake)
        self.assertEqual(summary, "SUMMARY {} dry-run")

    def test_wording_hit_skips_item_only(self):
        # the forbidden-word list does not apply to catalog text (ruling); a file path does
        self.edit_case("area-a.json", "TC-A-002", steps=["Open docs/qa/sign-in.yaml and follow it."])
        fake = FolderFake(empty=True)
        lines, summary = self.run_verb(fake)
        self.assertIn("SKIP\twording\tTC-A-002: docs/qa/sign-in.yaml", lines)
        created = [ln.split("\t")[2].split(" ")[0] for ln in lines if ln.startswith("DRY\tcreate\tTC-")]
        self.assertEqual(created, ["TC-A-001", "TC-A-003", "TC-B-001", "TC-B-002"])
        self.assertIn('"skip": 1', summary)

    def test_wording_hit_in_comment_skips_only_that_retirement(self):
        self.set_cfg(wording={"forbidden": ["replaced"], "allow": [], "patterns": []})
        fake = FolderFake()
        lines, _ = self.run_verb(fake, apply=True)
        self.assertIn("SKIP\twording\tTC-A-009: replaced", lines)
        self.assertNotIn("t5", fake.comments)
        self.assertTrue(fake.writes("POST", r"/v2/list/902/task$"))  # the rest still ran

    def test_human_edit_is_drift_not_overwrite(self):
        cache = core.MapCache(self.tmp)
        cache.put("case", "TC-A-002", "t2", "0" * 40)
        cache.save()
        fake = FolderFake()
        lines, summary = self.run_verb(fake, apply=True)
        self.assertIn("APPLY\tdrift\tTC-A-002", lines)
        self.assertEqual(fake.writes("PUT", r"^/v2/task/t2$"), [])
        self.assertIn('"drift": 1', summary)
        lines, _ = self.run_verb(fake, apply=True, overwrite=["TC-A-002"])
        self.assertIn("APPLY\tupdate\tTC-A-002 [description]", lines)
        self.assertEqual(len(fake.writes("PUT", r"^/v2/task/t2$")), 1)
        stored = core.MapCache(self.tmp).get("case", "TC-A-002")
        self.assertEqual(stored["hash"], core.content_hash(fake.tasks["t2"]["markdown_description"]))

    def test_catalog_change_with_cached_live_hash_is_not_drift(self):
        fake = FolderFake()
        cache = core.MapCache(self.tmp)
        cache.put("case", "TC-A-002", "t2", core.content_hash(fake.tasks["t2"]["markdown_description"]))
        cache.save()
        lines, _ = self.run_verb(fake)
        self.assertIn("DRY\tupdate\tTC-A-002 [description]", lines)
        self.assertNotIn("DRY\tdrift\tTC-A-002", lines)

    def test_only_never_retires_other_areas(self):
        fake = FolderFake()
        lines, summary = self.run_verb(fake, apply=True, only=["area-a.json"])
        self.assertEqual(lines, [
            "APPLY\tupdate\tTC-A-002 [description]",
            "APPLY\tmove\tTC-A-003: Module: Events → Core: Sign-in",
        ])
        self.assertNotIn("t5", fake.comments)
        self.assertEqual(fake.tasks["t5"]["status"]["status"], "to test")
        self.assertEqual(fake.writes("POST", r"/v2/list/902/task$"), [])

    def test_retired_case_is_retired_and_moved(self):
        fake = FolderFake()
        fake.tasks["t9"] = {"id": "t9", "name": "TC-A-004 · Sign in with a one-time code",
                            "markdown_description": "old", "description": "old",
                            "status": {"status": "passed"}, "priority": {"id": "3"}, "tags": [],
                            "list": {"id": "902", "name": "Module: Events"}}
        lines, _ = self.run_verb(fake, apply=True)
        self.assertIn("APPLY\tmove\tTC-A-004: Module: Events → Core: Sign-in", lines)
        self.assertIn("APPLY\tretire\tTC-A-004 (Core: Sign-in)", lines)
        self.assertEqual(fake.comments["t9"], [f"Retired from the catalog on {TODAY}: Replaced by single sign-on."])
        self.assertEqual(fake.tasks["t9"]["status"]["status"], "skipped")
        self.assertEqual(fake.tasks["t9"]["list"]["id"], "901")

    def test_post_500_that_landed_is_found_by_name_next_run(self):
        fake = FolderFake(fail_once={("POST", r"^/v2/list/902/task$")})
        lines, _ = self.run_verb(fake, apply=True)
        self.assertTrue(any(ln.startswith("SKIP\tapi-error\tTC-B-002") for ln in lines), lines)
        self.assertEqual(len(fake.writes("POST", r"^/v2/list/902/task$")), 1)  # never blind-retried
        self.assertIn("APPLY\tretire\tTC-A-009 (orphan, Core: Sign-in)", lines)  # run went on
        lines, summary = self.run_verb(fake)
        self.assertFalse([ln for ln in lines if "\tcreate\t" in ln])
        self.assertEqual(summary, "SUMMARY {} dry-run")

    def test_missing_list_is_created_then_used(self):
        fake = FolderFake(empty=True)
        del fake.lists["902"]
        lines, _ = self.run_verb(fake, apply=True)
        self.assertIn("APPLY\tcreate-list\tModule: Events", lines)
        new = [l for l in fake.lists.values() if l["name"] == "Module: Events"][0]["id"]
        self.assertEqual(len(fake.writes("POST", rf"^/v2/list/{new}/task$")), 2)
        _, summary = self.run_verb(fake)
        self.assertEqual(summary, "SUMMARY {} dry-run")


class GuideDocTests(PlanTestBase):
    def setUp(self):
        super().setUp()
        self.set_cfg(guideAs="doc")

    def test_guide_doc_created_and_tasks_retired(self):
        fake = FolderFake()
        lines, _ = self.run_verb(fake, apply=True)
        docs = fake.writes("POST", rf"^/v3/workspaces/{WS}/docs$")
        self.assertEqual([c[2] for c in docs], [{"name": "QA Guide", "parent": {"id": SPACE, "type": 4}}])
        pages = fake.writes("POST", rf"^/v3/workspaces/{WS}/docs/\w+/pages$")
        self.assertEqual([(c[2]["name"], c[2]["content_format"]) for c in pages],
                         [("Start Here", "text/md"), ("Environment", "text/md")])
        for tid in ("t6", "t7"):
            self.assertEqual(fake.comments[tid], ['This guide now lives in the "QA Guide" doc.'])
            self.assertEqual(fake.tasks[tid]["status"]["status"], "skipped")
            self.assertIn("retired", [x["name"] for x in fake.tasks[tid]["tags"]])
        self.assertNotIn("t8", fake.comments)  # sign-off stays a task, untouched
        self.assertEqual(fake.writes(None, r"/v2/task/t8"), [])
        # found by name next time: no second doc, no new pages, no second retirement
        lines, summary = self.run_verb(fake)
        self.assertEqual(summary, "SUMMARY {} dry-run")
        (self.tmp / ".qa" / "tracker-map.json").unlink()
        _, summary = self.run_verb(fake)
        self.assertEqual(summary, "SUMMARY {} dry-run")

    def test_page_upserted_by_name(self):
        fake = FolderFake()
        self.run_verb(fake, apply=True)
        (self.tmp / "guide" / "01-environment.md").write_text("# Environment\n\nUse the staging site only.\n")
        lines, _ = self.run_verb(fake, apply=True)
        self.assertIn("APPLY\tpage-update\tEnvironment", lines)
        put = fake.writes("PUT", rf"^/v3/workspaces/{WS}/docs/\w+/pages/\w+$")
        self.assertEqual(put[-1][2]["content"], "Use the staging site only.")
        self.assertEqual(put[-1][2]["content_format"], "text/md")

    def test_guide_page_wording_hit_skips_that_page_only(self):
        (self.tmp / "guide" / "01-environment.md").write_text(
            "# Environment\n\nSet QA_BASE_URL in deploy/staging.env before you start.\n")
        fake = FolderFake()
        lines, _ = self.run_verb(fake, apply=True)
        self.assertIn("SKIP\twording\tguide 01-environment.md: deploy/staging.env", lines)
        pages = fake.writes("POST", rf"^/v3/workspaces/{WS}/docs/\w+/pages$")
        self.assertEqual([c[2]["name"] for c in pages], ["Start Here"])
        self.assertNotIn("t7", fake.comments)  # its guide task is kept until the page can go up
        self.assertEqual(fake.tasks["t7"]["status"]["status"], "to test")

    def test_dry_run_with_no_doc_plans_create(self):
        fake = FolderFake()
        lines, _ = self.run_verb(fake)
        self.assertIn("DRY\tdoc-create\tQA Guide", lines)
        self.assertIn("DRY\tpage-create\tStart Here", lines)
        self.assertEqual(fake.calls, [])

    def test_doc_post_500_that_landed_is_not_created_twice(self):
        fake = FolderFake(fail_once={("POST", rf"^/v3/workspaces/{WS}/docs$")})
        lines, _ = self.run_verb(fake, apply=True)
        self.assertTrue(any(ln.startswith("SKIP\tapi-error\tQA Guide") for ln in lines), lines)
        lines, _ = self.run_verb(fake)
        self.assertNotIn("DRY\tdoc-create\tQA Guide", lines)
        self.assertIn("DRY\tpage-create\tStart Here", lines)


class PullAndStatusTests(PlanTestBase):
    def test_pull_lists_drafts_and_writes_only_under_apply(self):
        fake = FolderFake()
        fake.tasks["t5"]["markdown_description"] = (
            "**Preconditions:** A hardware key.\n\n**Steps:**\n1. Insert the key.\n2. Press Sign in.\n\n"
            "**Expected results:**\n- The dashboard opens.")
        catalog_before = sorted((p.name, p.read_text()) for p in (self.tmp / "catalog").iterdir())
        lines, _ = self.run_verb(fake, verb="pull_plan")
        self.assertIn("DRY\tdraft\tTC-A-009 → area-a.yaml", lines)
        out = self.tmp / ".qa" / "tracker" / "pulled" / "area-a.yaml"
        self.assertFalse(out.exists())
        self.run_verb(fake, verb="pull_plan", apply=True)
        text = out.read_text()
        self.assertIn("draft: true", text)
        self.assertIn("Insert the key.", text)
        self.assertEqual(catalog_before, sorted((p.name, p.read_text()) for p in (self.tmp / "catalog").iterdir()))
        self.assertEqual(fake.calls, [])

    def test_pull_reports_drift_and_skips_retired_orphans(self):
        cache = core.MapCache(self.tmp)
        cache.put("case", "TC-A-002", "t2", "0" * 40)
        cache.save()
        fake = FolderFake()
        fake.tasks["t5"]["tags"] = [{"name": "retired"}]
        lines, _ = self.run_verb(fake, verb="pull_plan")
        self.assertEqual(lines, ["DRY\tdrift\tTC-A-002"])

    def test_status_is_dry_even_with_apply(self):
        fake = FolderFake()
        lines, summary = self.run_verb(fake, verb="status", apply=True)
        self.assertTrue(summary.endswith("dry-run"))
        self.assertEqual(fake.calls, [])
        self.assertIn("DRY\tcreate\tTC-B-002 → Module: Events", lines)
        self.assertIn("DRY\tdraft\tTC-A-009 → area-a.yaml", lines)


if __name__ == "__main__":
    unittest.main()
