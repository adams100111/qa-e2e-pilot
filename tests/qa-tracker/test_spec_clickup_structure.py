"""`spec-init` and `push-scenarios` through cli.main, against an in-memory ClickUp space.

`SpecFake` models what the spec layout touches: the QA folder with its statuses and folder-level
custom fields, subfolders, lists and their views, tasks with subtasks and checklists, comments
and Docs. Statuses and custom fields belong to the QA folder's tree: a folder outside it, and
every list in such a folder, has none. It reflects every write and records every non-GET call.
Later spec tests import it.

Docs: a new Doc gets one empty page (unless `create_page` is false), pages nest under
`parent_page_id`, and a page's content is read back re-rendered (blank lines collapsed, the end
trimmed), as ClickUp gives markdown back in its own layout. A Doc and a page carry a `url` only
with `doc_urls` on: the reference lists none. A comment sent as parts (`comment`) is read back as
one text, a `tag` part as `@<user id>`. Comments are read 25 at a time, newest first; the next
page is asked for with the `date` and `id` of the last comment read (`start`, `start_id`).
"""
from __future__ import annotations

import contextlib
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

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "qa-kit" / "scripts"))

from trackers import cli, clickup, core  # noqa: E402
from trackers.clickup_api import ApiError, Transport  # noqa: E402

PROJECT = Path(__file__).resolve().parent / "fixtures" / "spec" / "project"
TARGET = "judge-scoring"
TITLE = "Judges score hackathon submissions"
WS, SPACE, QA = "9001", "9002", "9003"
CASE_STATUSES = ["to test", "testing", "failed", "blocked", "passed", "skipped"]
OWN_STATUSES = ["ready", "in review", "broken", "stuck", "accepted", "left out"]
FOLDER_FIELDS = [("f-ref", "Ref", "short_text"), ("f-role", "Role", "short_text"),
                 ("f-review", "Needs a person's review", "checkbox"), ("f-build", "Build", "short_text")]
JUDGE_CARD = "A judge scores a team submission"
ADMIN_CARD = "An admin watches the ranking"


class SpecFake(Transport):
    """An in-memory ClickUp space: one QA folder, its subfolders, lists, tasks and Docs."""

    def __init__(self, statuses=CASE_STATUSES):
        self.calls: list = []
        self.statuses = list(statuses)
        self.folder_fields = [{"id": i, "name": n, "type": t} for i, n, t in FOLDER_FIELDS]
        self.folders = {QA: {"id": QA, "name": "QA", "parent": None}}
        self.lists: dict = {}
        self.views: dict = {}
        self.tasks: dict = {}
        self.comments: dict = {}
        self.checklists: dict = {}
        self.docs: dict = {}
        self.n = 0
        self.subfolders_ok = True      # False: the subfolder create answers HTTP 400
        self.nest_subfolders = True    # False: the create ignores the parent and makes a top-level folder
        self.task_creates = 0
        self.fail_task_create_at = 0   # the task create with this number fails with HTTP 500 ...
        self.fail_lands = False        # ... after it landed (True) or before (False)
        self.pending: dict = {}        # list id -> GETs still answered 404 (a list made from a template)
        self.template_statuses = None  # statuses of a list made from a template, when not the folder's
        self.pages: dict = {}          # doc id -> its pages, in order: {"id", "name", "content", "parent"}
        self.doc_urls = False          # True: Docs and pages are read back with a `url`
        self.comment_page = 25         # comments a read returns; older ones need `start` and `start_id`
        self.add_list("905", "Bugs", QA)

    # -- seeding

    def new_id(self, prefix):
        self.n += 1
        return f"{prefix}{self.n}"

    def add_folder(self, fid, name, parent):
        self.folders[fid] = {"id": fid, "name": name, "parent": parent}

    def add_list(self, lid, name, folder):
        self.lists[lid] = {"id": lid, "name": name, "folder": folder, "archived": False}
        self.views[lid] = []

    def drop_field(self, name):
        self.folder_fields = [f for f in self.folder_fields if f["name"] != name]

    # -- reading it back in tests

    def writes(self, method=None, pattern=""):
        return [c for c in self.calls if (method is None or c[0] == method) and re.search(pattern, c[1])]

    def tasks_in(self, lid):
        return [t for t in self.tasks.values() if t["list"]["id"] == lid]

    def task(self, name, lid=None):
        found = [t for t in self.tasks.values() if t["name"] == name and (lid is None or t["list"]["id"] == lid)]
        assert len(found) == 1, f"{name}: {len(found)} tasks"
        return found[0]

    def items_of(self, task_id):
        return [i["name"] for c in self.checklists.values() if c["task_id"] == task_id for i in c["items"]]

    # -- views of stored objects

    def in_tree(self, fid):
        """The QA folder or one of its subfolders: only there do its statuses and fields exist."""
        return fid == QA or (fid in self.folders and self.folders[fid]["parent"] == QA)

    def fields_of(self, fid):
        return self.folder_fields if self.in_tree(fid) else []

    def statuses_of(self, lid):
        l = self.lists[lid]
        return (l.get("statuses") or self.statuses) if self.in_tree(l["folder"]) else []

    def folder_view(self, f):
        out = {"id": f["id"], "name": f["name"], "space": {"id": SPACE},
               "statuses": [{"status": s} for s in (self.statuses if self.in_tree(f["id"]) else [])],
               "lists": [{"id": l["id"], "name": l["name"]} for l in self.lists.values()
                         if l["folder"] == f["id"] and not l["archived"]]}
        if f["parent"]:
            out["parent_folder"] = {"id": f["parent"]}
        return out

    def list_view(self, l):
        return {"id": l["id"], "name": l["name"], "folder": {"id": l["folder"]}, "archived": l["archived"],
                "statuses": [{"status": s} for s in self.statuses_of(l["id"])]}

    def view(self, t):
        out = {k: copy.deepcopy(v) for k, v in t.items() if k != "values"}
        out["custom_fields"] = [dict(f, value=copy.deepcopy(t["values"][f["id"]])) if f["id"] in t["values"]
                                else dict(f) for f in self.fields_of(self.lists[t["list"]["id"]]["folder"])]
        out["checklists"] = [copy.deepcopy(c) for c in self.checklists.values() if c["task_id"] == t["id"]]
        return out

    def comment_text(self, body):
        """A stored comment as ClickUp reads it back: one text, a mention as `@<user id>`."""
        if "comment" not in body:
            return body["comment_text"]
        return "".join(f"@{part['user']['id']}" if part.get("type") == "tag" else part.get("text", "")
                       for part in body["comment"])

    def doc_view(self, d):
        out = copy.deepcopy(d)
        if self.doc_urls:
            out["url"] = f"https://app.clickup.com/{WS}/v/dc/{d['id']}"
        return out

    def page_view(self, doc_id, p, deep=True):
        out = {"id": p["id"], "doc_id": doc_id, "name": p["name"],
               "content": re.sub(r"\n{3,}", "\n\n", p["content"]).rstrip()}
        if p["parent"]:
            out["parent_page_id"] = p["parent"]
        if self.doc_urls:
            out["url"] = f"https://app.clickup.com/{WS}/v/dc/{doc_id}/{p['id']}"
        if deep:
            out["pages"] = [self.page_view(doc_id, c) for c in self.pages[doc_id] if c["parent"] == p["id"]]
        return out

    def page_named(self, doc_id, name, parent=None):
        """The one page of a Doc with this name under this parent page (by name; None is the top)."""
        top = None if parent is None else self.page_named(doc_id, parent)["id"]
        found = [p for p in self.pages[doc_id] if p["name"] == name and p["parent"] == top]
        assert len(found) == 1, f"{name}: {len(found)} pages"
        return found[0]

    def bad(self, method, path, why):
        raise ApiError(method, path, 400, why)

    # -- the API

    def create_task(self, method, path, lid, body):
        self.task_creates += 1
        failing = self.task_creates == self.fail_task_create_at
        if failing and not self.fail_lands:
            raise ApiError(method, path, 500, "internal error")
        live = self.statuses_of(lid)
        status = body.get("status") or (live[0] if live else "to do")
        if body.get("status") and status.lower() not in [s.lower() for s in live]:
            self.bad(method, path, "Status not found")
        parent = body.get("parent")
        if parent is not None and (parent not in self.tasks or self.tasks[parent]["list"]["id"] != lid):
            self.bad(method, path, "Parent must be in the same list")
        known = {f["id"] for f in self.fields_of(self.lists[lid]["folder"])}
        values = {}
        for cf in body.get("custom_fields") or []:
            if cf["id"] not in known:
                self.bad(method, path, "Field not found")
            values[cf["id"]] = cf["value"]
        tid = self.new_id("t")
        self.tasks[tid] = {"id": tid, "name": body["name"], "status": {"status": status, "type": "custom"},
                           "list": {"id": lid, "name": self.lists[lid]["name"]}, "parent": parent,
                           "priority": {"id": str(body["priority"])} if body.get("priority") else None,
                           "markdown_description": body.get("markdown_content", ""), "values": values}
        if failing:
            raise ApiError(method, path, 500, "internal error")
        return self.view(self.tasks[tid])

    def request(self, method, path, body=None):
        method = method.upper()
        if method != "GET":
            self.calls.append((method, path, copy.deepcopy(body)))
        if method == "DELETE":
            raise AssertionError(f"the tracker must never delete: {path}")

        m = re.fullmatch(r"/v2/space/(\w+)/folder(\?.*)?", path)
        if m and method == "GET":
            return {"folders": [self.folder_view(f) for f in self.folders.values()]}
        if m and method == "POST":
            if not self.subfolders_ok:
                self.bad(method, path, "Subfolders are not available")
            fid = self.new_id("F")
            self.add_folder(fid, body["name"], body.get("parent_folder_id") if self.nest_subfolders else None)
            return self.folder_view(self.folders[fid])
        m = re.fullmatch(r"/v2/folder/(\w+)(/field|/list)?", path)
        if m and m.group(1) in self.folders:
            fid, sub = m.group(1), m.group(2)
            if sub is None and method == "GET":
                return self.folder_view(self.folders[fid])
            if sub == "/field" and method == "GET":
                return {"fields": copy.deepcopy(self.fields_of(fid))}
            if sub == "/list" and method == "POST":
                lid = self.new_id("L")
                self.add_list(lid, body["name"], fid)
                return self.list_view(self.lists[lid])

        m = re.fullmatch(r"/v2/folder/(\w+)/list_template/([\w-]+)", path)
        if m and method == "POST" and m.group(1) in self.folders:
            lid = self.new_id("L")
            self.add_list(lid, body["name"], m.group(1))
            self.lists[lid]["statuses"] = self.template_statuses
            self.pending[lid] = 2
            return {"id": lid}

        m = re.fullmatch(r"/v2/list/(\w+)/task\?.*page=(\d+)", path)
        if m and method == "GET" and m.group(1) in self.lists:
            return {"tasks": [self.view(t) for t in self.tasks_in(m.group(1))] if m.group(2) == "0" else []}
        m = re.fullmatch(r"/v2/list/(\w+)(/task|/view|/field)?", path)
        if m and m.group(1) in self.lists:
            lid, sub = m.group(1), m.group(2)
            if sub is None and method == "GET":
                if self.pending.get(lid):
                    self.pending[lid] -= 1
                    raise ApiError(method, path, 404, "List not found")
                return self.list_view(self.lists[lid])
            if sub == "/field" and method == "GET":
                return {"fields": copy.deepcopy(self.fields_of(self.lists[lid]["folder"]))}
            if sub == "/view" and method == "GET":
                return {"views": copy.deepcopy(self.views[lid])}
            if sub == "/view" and method == "POST":
                v = dict(copy.deepcopy(body), id=self.new_id("v"))
                self.views[lid].append(v)
                return {"view": v}
            if sub == "/task" and method == "POST":
                return self.create_task(method, path, lid, body)

        m = re.fullmatch(r"/v2/task/(\w+)(/comment(?:\?.*)?|/checklist|/field/[\w-]+)?", path)
        if m and m.group(1) in self.tasks:
            t, sub = self.tasks[m.group(1)], m.group(2)
            if sub is None and method == "GET":
                return self.view(t)
            if sub is None and method == "PUT":
                if "name" in body:
                    t["name"] = body["name"]
                if "markdown_content" in body:
                    t["markdown_description"] = body["markdown_content"]
                if "priority" in body:
                    t["priority"] = {"id": str(body["priority"])}
                if "status" in body:
                    if body["status"].lower() not in [s.lower() for s in self.statuses_of(t["list"]["id"])]:
                        self.bad(method, path, "Status not found")
                    t["status"] = {"status": body["status"], "type": "custom"}
                return self.view(t)
            if sub == "/comment" and method == "POST":
                self.comments.setdefault(t["id"], []).append(body)
                return {"id": self.new_id("c")}
            if sub and sub.startswith("/comment") and method == "GET":
                # newest first, 25 a page; `start` and `start_id` name the last comment of the page before
                rows = [{"id": f"c-{t['id']}-{i}", "comment_text": self.comment_text(c), "date": str(1795000000000 + i)}
                        for i, c in enumerate(self.comments.get(t["id"], []))][::-1]
                q = re.fullmatch(r"/comment\?start=(\d+)&start_id=([\w-]+)", sub)
                if sub != "/comment" and not q:
                    self.bad(method, path, "start and start_id go together")
                if q:
                    at = next((i for i, c in enumerate(rows) if c["id"] == q.group(2) and c["date"] == q.group(1)), None)
                    if at is None:
                        self.bad(method, path, "Comment not found")
                    rows = rows[at + 1:]
                return {"comments": rows[:self.comment_page]}
            if sub == "/checklist" and method == "POST":
                cid = self.new_id("k")
                self.checklists[cid] = {"id": cid, "task_id": t["id"], "name": body["name"], "items": []}
                return {"checklist": copy.deepcopy(self.checklists[cid])}
            if sub and sub.startswith("/field/") and method == "POST":
                t["values"][sub[len("/field/"):]] = body["value"]
                return {}
        m = re.fullmatch(r"/v2/checklist/(\w+)/checklist_item", path)
        if m and method == "POST" and m.group(1) in self.checklists:
            c = self.checklists[m.group(1)]
            c["items"].append({"id": self.new_id("i"), "name": body["name"], "resolved": False})
            return {"checklist": copy.deepcopy(c)}

        m = re.fullmatch(rf"/v3/workspaces/{WS}/docs(\?.*)?", path)
        if m and method == "GET":
            return {"docs": copy.deepcopy(list(self.docs.values()))}
        if m and method == "POST":
            did = self.new_id("d")
            self.docs[did] = {"id": did, "name": body.get("name", ""), "parent": copy.deepcopy(body.get("parent")),
                              "deleted": False, "archived": False}
            self.pages[did] = []
            if body.get("create_page", True):
                self.pages[did].append({"id": self.new_id("p"), "name": "", "content": "", "parent": None})
            return self.doc_view(self.docs[did])
        m = re.fullmatch(rf"/v3/workspaces/{WS}/docs/(\w+)(/pages(?:\?.*)?|/pages/(\w+))?", path)
        if m and m.group(1) in self.docs:
            did, sub, pid = m.group(1), m.group(2), m.group(3)
            pages = self.pages.setdefault(did, [])
            if sub is None and method == "GET":
                return self.doc_view(self.docs[did])
            if sub and pid is None and method == "GET":
                return [self.page_view(did, p) for p in pages if p["parent"] is None]
            if sub == "/pages" and method == "POST":
                parent = body.get("parent_page_id")
                if parent is not None and parent not in {p["id"] for p in pages}:
                    self.bad(method, path, "Parent page not found")
                if body.get("content_format", "text/md") != "text/md":
                    self.bad(method, path, "Unknown content format")
                page = {"id": self.new_id("p"), "name": body.get("name", ""), "content": body.get("content", ""),
                        "parent": parent}
                pages.append(page)
                return self.page_view(did, page, deep=False)
            page = next((p for p in pages if p["id"] == pid), None)
            if page is not None and method == "PUT":
                if body.get("content_edit_mode", "replace") != "replace":
                    self.bad(method, path, "Only a whole replace is expected")
                page.update({k: body[k] for k in ("name", "content") if k in body})
                return {}
        raise ApiError(method, path, 404, "unhandled in SpecFake")


class SpecBase(unittest.TestCase):
    statuses = CASE_STATUSES

    def setUp(self):
        self.new_project()

    def new_project(self):
        """A fresh copy of the project and an empty ClickUp space; the test works on it from here
        on (a test that needs a second one calls this again)."""
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        shutil.copytree(PROJECT, self.tmp, dirs_exist_ok=True)
        self.cfg_path = self.tmp / "docs/agents/qa-tracker.json"
        self.cards_path = self.tmp / ".qa/specs" / TARGET / "tracker-cards.json"
        self.plan_path = self.tmp / ".qa/specs" / TARGET / "checklist.json"
        self.fake = SpecFake(self.statuses)

    def cfg(self):
        return json.loads(self.cfg_path.read_text(encoding="utf-8"))

    def edit_cfg(self, fn):
        data = self.cfg()
        fn(data)
        self.cfg_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def edit_cards(self, fn):
        data = json.loads(self.cards_path.read_text(encoding="utf-8"))
        fn(data)
        self.cards_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def edit_plan(self, fn):
        data = json.loads(self.plan_path.read_text(encoding="utf-8"))
        data = fn(data) or data
        self.plan_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def tracker(self, verb, *extra, apply=True):
        """Run `tracker.sh <verb> --spec judge-scoring` through cli.main with the fake transport."""
        argv = [verb, "--project", str(self.tmp), "--spec", TARGET] + (["--apply"] if apply else []) + list(extra)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(clickup, "transport_for", lambda ctx: self.fake), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(argv)
        return rc, [ln for ln in out.getvalue().splitlines() if ln], err.getvalue()

    def ready(self):
        """spec-init applied, calls forgotten: the state push-scenarios starts from."""
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        self.fake.calls.clear()

    def push(self, *extra, apply=True):
        return self.tracker("push-scenarios", *extra, apply=apply)

    def run_list(self):
        folder = self.cfg()["specs"][TARGET]["folder"]
        lists = [l for l in self.fake.lists.values() if l["folder"] == folder]
        self.assertEqual(len(lists), 1, lists)
        return lists[0]

    def remove_check(self, criterion="C-SCORE-02"):
        self.edit_cards(lambda d: d["cards"][0].update(
            checks=[c for c in d["cards"][0]["checks"] if c["criterion"] != criterion]))
        self.edit_plan(lambda rows: [r for r in rows if r["id"] != criterion])

    def keep_files(self):
        """The cards and the plan as they are now, to put a removed card or check back later."""
        saved = {p: p.read_text(encoding="utf-8") for p in (self.cards_path, self.plan_path)}
        return lambda: [p.write_text(text, encoding="utf-8") for p, text in saved.items()]

    def fail_after(self, method, pattern, status=502, times=1, lands=True):
        """The next `times` matching calls answer `status`, after they landed (or before)."""
        real, left = self.fake.request, [times]

        def flaky(m, path, body=None):
            hit = m.upper() == method and re.search(pattern, path) and left[0] > 0
            if hit and not lands:
                left[0] -= 1
                raise ApiError(m, path, status, "bad gateway")
            out = real(m, path, body)
            if hit:
                left[0] -= 1
                raise ApiError(m, path, status, "bad gateway")
            return out
        self.fake.request = flaky

    def subfolders(self):
        return [f for f in self.fake.folders.values() if f["id"] != QA]


class SpecInitTests(SpecBase):
    def test_spec_init_creates_subfolder_and_doc_and_saves_ids(self):
        before = self.cfg()
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.writes("POST", r"/folder$"),
                         [("POST", f"/v2/space/{SPACE}/folder", {"name": TITLE, "parent_folder_id": QA})])
        sub = next(f for f in self.fake.folders.values() if f["parent"] == QA)
        self.assertEqual(sub["name"], TITLE)
        doc = next(iter(self.fake.docs.values()))
        self.assertEqual(self.fake.writes("POST", r"/docs$"), [
            ("POST", f"/v3/workspaces/{WS}/docs", {"name": TITLE, "parent": {"id": sub["id"], "type": 5}})])
        after = self.cfg()
        self.assertEqual(after["specs"][TARGET],
                         {"enabled": True, "folder": sub["id"], "doc": doc["id"], "layout": "subfolder"})
        self.assertEqual({k: v for k, v in after["fields"].items() if k.startswith("folder:")},
                         {"folder:Ref": "f-ref", "folder:Role": "f-role",
                          "folder:Needs a person's review": "f-review", "folder:Build": "f-build"})
        # every other key is as it was, in the same order, and the file keeps its style
        for key in ("backend", "ids", "listIds"):
            self.assertEqual(after[key], before[key])
        self.assertEqual(after["fields"]["Bugs/Ref"], "f-bug-ref")
        self.assertEqual(list(after), list(before))
        text = self.cfg_path.read_text(encoding="utf-8")
        self.assertEqual(text, json.dumps(after, indent=2, ensure_ascii=False) + "\n")
        # a second run adopts what is saved and writes nothing
        self.fake.calls.clear()
        rc, _, _ = self.tracker("spec-init")
        self.assertEqual(rc, 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), text)

    def test_spec_init_missing_field_prints_clicks_rc1_no_writes(self):
        self.fake.drop_field("Needs a person's review")
        self.fake.statuses.remove("blocked")
        before = self.cfg_path.read_text(encoding="utf-8")
        rc, lines, _ = self.tracker("spec-init")
        self.assertEqual(rc, 1)
        manual = [ln for ln in lines if ln.startswith("MANUAL\t")]
        self.assertEqual(manual, [
            'MANUAL\t1. In the folder: add status "blocked". Add it at folder level so every list gets it.',
            'MANUAL\t2. In the folder: add custom field "Needs a person\'s review" (checkbox). '
            'Add it at folder level so every list gets it.'])
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), before)

    def test_spec_init_field_of_the_wrong_type_is_a_click_step(self):
        next(f for f in self.fake.folder_fields if f["name"] == "Role")["type"] = "labels"
        rc, lines, _ = self.tracker("spec-init")
        self.assertEqual(rc, 1)
        self.assertIn('MANUAL\t1. In the folder: custom field "Role" must be short text (it is labels now).', lines)
        self.assertEqual(self.fake.calls, [])

    def test_spec_init_flat_when_folder_is_subfolder(self):
        self.fake.folders[QA]["parent"] = "9000"
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.writes("POST", r"/folder$"), [])
        doc = next(iter(self.fake.docs.values()))
        self.assertEqual(doc["parent"], {"id": QA, "type": 5})
        self.assertEqual(self.cfg()["specs"][TARGET], {"enabled": True, "doc": doc["id"], "layout": "flat"})
        # run lists then go into the QA folder, named after the spec
        self.assertEqual(self.push()[0], 0)
        names = [l["name"] for l in self.fake.lists.values() if l["folder"] == QA]
        self.assertEqual(names, ["Bugs", f"{TITLE} · Run 1 · next"])
        self.fake.calls.clear()
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_spec_init_flat_on_4xx(self):
        self.fake.subfolders_ok = False
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(len(self.fake.folders), 1)
        saved = self.cfg()["specs"][TARGET]
        self.assertEqual(saved["layout"], "flat")
        self.assertNotIn("folder", saved)
        self.assertEqual(next(iter(self.fake.docs.values()))["parent"], {"id": QA, "type": 5})

    def test_spec_init_subfolder_create_that_landed_is_adopted(self):
        real = self.fake.request

        def flaky(method, path, body=None):
            out = real(method, path, body)
            if method == "POST" and path.endswith("/folder"):
                raise ApiError(method, path, 502, "bad gateway")
            return out
        self.fake.request = flaky
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        subs = [f for f in self.fake.folders.values() if f["parent"] == QA]
        self.assertEqual(len(subs), 1)
        self.assertEqual(self.cfg()["specs"][TARGET]["folder"], subs[0]["id"])

    def test_spec_init_uses_pasted_list(self):
        self.fake.add_folder("F77", "Judging", QA)
        self.fake.add_list("L77", "Judging round one", "F77")
        self.edit_cfg(lambda d: d["specs"][TARGET].update(list="L77"))
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.writes("POST", r"/folder$"), [])
        saved = self.cfg()["specs"][TARGET]
        self.assertEqual((saved["list"], saved["folder"], saved["layout"]), ("L77", "F77", "subfolder"))
        # push-scenarios fills the pasted list as run 1 and creates no list
        self.fake.calls.clear()
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.fake.writes("POST", r"/list$"), [])
        self.assertEqual(self.fake.lists["L77"]["name"], "Judging round one")
        summary = self.fake.task("Run summary", "L77")
        from trackers import clickup_spec
        self.assertEqual(summary["values"]["f-ref"], clickup_spec.ref(TARGET, 1, "summary", "summary"))
        self.assertEqual(len(self.fake.tasks_in("L77")), 6)
        self.fake.calls.clear()
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.fake.calls, [])

    def test_folder_id_is_saved_before_anything_else_can_fail(self):
        self.fail_after("GET", r"/v3/workspaces/\d+/docs", status=503, lands=False)
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 1, (lines, err))
        made = self.subfolders()
        self.assertEqual(len(made), 1)
        saved = self.cfg()["specs"][TARGET]
        self.assertEqual((saved.get("folder"), saved.get("layout")), (made[0]["id"], "subfolder"))
        self.assertNotIn("doc", saved)
        # the next run adopts that folder by its id and only adds the Doc
        self.fake.calls.clear()
        rc, lines, err = self.tracker("spec-init")
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.writes("POST", r"/folder$"), [])
        self.assertEqual(len(self.subfolders()), 1)
        self.assertEqual(self.cfg()["specs"][TARGET]["doc"], next(iter(self.fake.docs.values()))["id"])

    def test_folder_made_outside_the_qa_folder_stops_every_run_until_moved(self):
        self.fake.nest_subfolders = False
        line = (f"SKIP\tsubfolder-not-nested\t{TITLE}: the spec's folder is not inside the QA folder; "
                f"move it into the QA folder, then run again")
        for _ in range(2):  # the first run and the one that adopts the saved id
            rc, lines, _ = self.tracker("spec-init")
            self.assertEqual(rc, 1)
            self.assertIn(line, lines)
        made = self.subfolders()
        self.assertEqual(len(made), 1)
        self.assertEqual(self.cfg()["specs"][TARGET]["folder"], made[0]["id"])
        self.assertEqual(self.fake.docs, {})
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertEqual(self.fake.calls, [])
        # moved by hand: both verbs go on
        made[0]["parent"] = QA
        self.assertEqual(self.tracker("spec-init")[0], 0)
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(len(self.fake.tasks_in(self.run_list()["id"])), 6)
        self.assertEqual(len(self.subfolders()), 1)

    def test_pasted_folder_outside_the_qa_folder_is_refused(self):
        self.fake.add_folder("F88", "Judging", None)
        self.edit_cfg(lambda d: d["specs"][TARGET].update(folder="F88"))
        before = self.cfg_path.read_text(encoding="utf-8")
        rc, lines, _ = self.tracker("spec-init")
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\tsubfolder-not-nested\tJudging: the spec's folder is not inside the QA folder; "
                      "move it into the QA folder, then run again", lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), before)

    def test_pasted_list_must_be_in_the_qa_folder_tree(self):
        self.fake.add_folder("F88", "Judging", None)
        self.fake.add_list("L88", "Judging round one", "F88")
        self.edit_cfg(lambda d: d["specs"][TARGET].update(list="L88"))
        rc, lines, _ = self.tracker("spec-init")
        self.assertEqual(rc, 1)
        self.assertIn(f"SKIP\tlist-outside\tspecs.{TARGET}.list: the list is not in the QA folder or one of "
                      f"its subfolders; move it there, then run again", lines)
        self.assertEqual(self.fake.calls, [])
        # set up while it was inside, moved out afterwards: push-scenarios refuses too
        self.fake.folders["F88"]["parent"] = QA
        self.assertEqual(self.tracker("spec-init")[0], 0)
        self.fake.folders["F88"]["parent"] = None
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.fake.tasks, {})

    def test_flat_list_is_found_again_after_the_spec_title_changed(self):
        self.fake.folders[QA]["parent"] = "9000"
        self.assertEqual(self.tracker("spec-init")[0], 0)
        for failing in (1, 3):  # the Run summary ticket is missing, or it is there and a later one is not
            with self.subTest(failing=failing):
                self.new_project()
                self.fake.folders[QA]["parent"] = "9000"
                self.assertEqual(self.tracker("spec-init")[0], 0)
                self.fake.fail_task_create_at = failing
                self.assertEqual(self.push()[0], 1)
                self.edit_cfg(lambda d: d["specs"][TARGET].update(title="Judges score the final round"))
                rc, lines, _ = self.push()
                self.assertEqual(rc, 0, lines)
                names = [l["name"] for l in self.fake.lists.values() if l["folder"] == QA]
                self.assertEqual(names, ["Bugs", f"{TITLE} · Run 1 · next"])
                self.assertEqual(len(self.fake.tasks), 6)

    def test_dry_run_writes_nothing(self):
        before = self.cfg_path.read_text(encoding="utf-8")
        rc, lines, _ = self.tracker("spec-init", apply=False)
        self.assertEqual(rc, 0)
        self.assertIn(f"DRY\tcreate-folder\t{TITLE}", lines)
        self.assertIn(f"DRY\tdoc-create\t{TITLE}", lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), before)
        self.assertFalse((self.tmp / ".qa/tracker-map.json").exists())
        self.ready()
        saved = self.cfg_path.read_text(encoding="utf-8")
        rc, lines, _ = self.push(apply=False)
        self.assertEqual(rc, 0)
        self.assertIn("DRY\tcreate-list\tRun 1 · next", lines)
        self.assertEqual(len([ln for ln in lines if ln.startswith("DRY\tcreate\t")]), 6)
        self.assertEqual(len([ln for ln in lines if ln.startswith("DRY\tchecklist-item\t")]), 2)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.cfg_path.read_text(encoding="utf-8"), saved)
        self.assertFalse((self.tmp / ".qa/tracker-map.json").exists())


class RefTests(unittest.TestCase):
    def test_ref_format_and_round_trip(self):
        from trackers import clickup_spec as cs
        import hashlib
        key = hashlib.sha256(f"{TARGET}|2|card|judge-scores-a-submission".encode()).hexdigest()[:12]
        value = cs.ref(TARGET, 2, "card", "judge-scores-a-submission")
        self.assertEqual(value, f"qk1-{key}-t")
        self.assertEqual(cs.parse_ref(value), {"key": key, "letter": "t", "role": "to_test", "run": None,
                                                "pending": None})
        self.assertEqual(cs.ref(TARGET, 2, "check", "x", "f")[-2:], "-f")
        run = hashlib.sha256(b"run-2026-11-27").hexdigest()[:8]
        skey = hashlib.sha256(f"{TARGET}|2|summary|summary".encode()).hexdigest()[:12]
        self.assertEqual(cs.ref(TARGET, 2, "summary", "summary"), f"qk1-{skey}-t-open")
        bound = cs.ref(TARGET, 2, "summary", "summary", "p", run="run-2026-11-27")
        self.assertEqual(bound, f"qk1-{skey}-p-{run}")
        self.assertEqual(cs.parse_ref(bound), {"key": skey, "letter": "p", "role": "passed", "run": run,
                                                "pending": None})
        self.assertEqual(cs.parse_ref(f"qk1-{skey}-t-open")["run"], "open")
        for bad in (None, "", "a1b2c3d4e5f6", "qk1-xyz-t", f"qk2-{key}-t", f"qk1-{key}-z", 7):
            self.assertIsNone(cs.parse_ref(bad))


class PushScenariosTests(SpecBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def refs(self, lid):
        from trackers import clickup_spec
        return {t["name"]: clickup_spec.parse_ref(t["values"].get("f-ref")) for t in self.fake.tasks_in(lid)}

    def test_push_scenarios_tree(self):
        from trackers import clickup_spec as cs
        rc, lines, err = self.push()
        self.assertEqual(rc, 0, (lines, err))
        run = self.run_list()
        self.assertEqual(run["name"], "Run 1 · next")
        lid = run["id"]
        self.assertEqual([v["name"] for v in self.fake.views[lid]], ["By status", "By role", "Failed and blocked"])
        self.assertEqual(self.fake.views[lid][1]["grouping"]["field"], "cf_f-role")
        tasks = self.fake.tasks_in(lid)
        self.assertEqual(sorted(t["name"] for t in tasks), sorted([
            "Run summary", JUDGE_CARD, ADMIN_CARD, "Save a valid score",
            "Refuse a score above the maximum", "Judge sees the ranking"]))
        self.assertEqual({t["status"]["status"] for t in tasks}, {"to test"})
        judge, admin = self.fake.task(JUDGE_CARD), self.fake.task(ADMIN_CARD)
        self.assertTrue(judge["markdown_description"].startswith("Noura opens a submission"))
        self.assertEqual((judge["values"]["f-role"], judge["priority"]), ("Judge", {"id": "1"}))
        self.assertEqual((admin["values"]["f-role"], admin["priority"]), ("Admin", {"id": "2"}))
        self.assertIsNone(judge["parent"])
        subs = [t for t in tasks if t["parent"] == judge["id"]]
        self.assertEqual([t["name"] for t in subs],
                         ["Save a valid score", "Refuse a score above the maximum", "Judge sees the ranking"])
        self.assertEqual(subs[0]["markdown_description"],
                         "Open a submission, type 8 in the score box and press Save.\n\n"
                         "The score is saved and shown on the submission page.")
        self.assertEqual([t for t in tasks if t["parent"] == admin["id"]], [])
        self.assertEqual([c["name"] for c in self.fake.checklists.values()], ["Checks"])
        self.assertEqual(self.fake.items_of(admin["id"]), ["Admin sees the ranking", "Hackathon list opens"])
        # identity: every ticket carries a Ref that parses, with the P5 key, in the `to test` letter
        refs = self.refs(lid)
        self.assertTrue(all(r is not None and r["letter"] == "t" for r in refs.values()), refs)
        self.assertEqual(len({r["key"] for r in refs.values()}), 6)
        self.assertEqual(refs["Run summary"]["run"], "open")
        self.assertEqual(judge["values"]["f-ref"], cs.ref(TARGET, 1, "card", "judge-scores-a-submission"))
        self.assertEqual(subs[1]["values"]["f-ref"],
                         cs.ref(TARGET, 1, "check", cs.check_id("judge-scores-a-submission", "C-SCORE-02")))
        # nothing sent carries an id, an assignee or a notification
        sent = json.dumps(self.fake.calls, ensure_ascii=False)
        for token in ("C-SCORE", "C-RANK", "load-clean", "judge-scores-a-submission", TARGET, "assignee"):
            self.assertNotIn(token, sent)
        self.assertEqual(self.fake.comments, {})

    def test_push_scenarios_twice_creates_nothing(self):
        self.assertEqual(self.push()[0], 0)
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(lines, ['SUMMARY {} apply'])

    def test_push_scenarios_resumes_after_failure(self):
        for lands in (False, True):
            with self.subTest(lands=lands):
                self.new_project()
                self.ready()
                self.fake.fail_task_create_at, self.fake.fail_lands = 5, lands
                rc, lines, _ = self.push()
                if lands:  # the create is re-read by Ref and adopted, never sent twice
                    self.assertEqual(rc, 0, lines)
                    self.assertTrue(any(ln.startswith("APPLY\treconciled\t") for ln in lines), lines)
                else:
                    self.assertEqual(rc, 1)
                    self.assertTrue(any(ln.startswith("SKIP\tapi-error\t") for ln in lines), lines)
                    self.assertEqual(len(self.fake.tasks), 5)
                    rc, lines, _ = self.push()
                    self.assertEqual(rc, 0, lines)
                lid = self.run_list()["id"]
                names = [t["name"] for t in self.fake.tasks_in(lid)]
                self.assertEqual(len(names), 6)
                self.assertEqual(len(set(names)), 6)
                self.assertEqual(len({r["key"] for r in self.refs(lid).values()}), 6)
                self.assertEqual(len(self.fake.items_of(self.fake.task(ADMIN_CARD)["id"])), 2)

    def test_list_create_that_failed_before_the_tickets_is_reused(self):
        self.fake.fail_task_create_at = 1  # the list exists, the Run summary ticket does not
        self.assertEqual(self.push()[0], 1)
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(len(self.fake.tasks_in(self.run_list()["id"])), 6)

    def test_push_scenarios_without_map_cache(self):
        self.assertEqual(self.push()[0], 0)
        (self.tmp / ".qa" / "tracker-map.json").unlink()
        self.fake.calls.clear()
        rc, _, _ = self.push()
        self.assertEqual(rc, 0)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(len(self.fake.tasks), 6)
        self.run_list()

    def test_changed_title_and_description_are_updated(self):
        self.assertEqual(self.push()[0], 0)
        self.fake.calls.clear()
        self.edit_cards(lambda d: d["cards"][0]["checks"][0].update(
            title="Save a score within the range", expect="The score is saved and shown beside the team name."))
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        t = self.fake.task("Save a score within the range")
        self.assertTrue(t["markdown_description"].endswith("shown beside the team name."))
        self.assertEqual([c[0] for c in self.fake.calls], ["PUT"])
        self.assertEqual(len(self.fake.tasks), 6)

    def test_removed_check_is_skipped_with_comment(self):
        from trackers import clickup_spec as cs
        self.assertEqual(self.push()[0], 0)
        self.remove_check("C-SCORE-02")
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        t = self.fake.task("Refuse a score above the maximum")
        self.assertEqual(t["status"]["status"], "skipped")
        self.assertEqual(self.fake.comments[t["id"]],
                         [{"comment_text": "No longer part of the plan.", "notify_all": False}])
        self.assertEqual(cs.parse_ref(t["values"]["f-ref"])["letter"], "s")
        self.assertEqual(len(self.fake.tasks), 6)  # still there
        others = [x for x in self.fake.tasks.values() if x["id"] != t["id"]]
        self.assertEqual({x["status"]["status"] for x in others}, {"to test"})
        self.fake.calls.clear()
        rc, _, _ = self.push()
        self.assertEqual(rc, 0)
        self.assertEqual(self.fake.calls, [])

    def test_removed_card_takes_its_checks_with_it(self):
        self.assertEqual(self.push()[0], 0)
        self.edit_cards(lambda d: d.update(cards=d["cards"][1:]))
        self.edit_plan(lambda rows: [dict(r, personas=["admin"]) if r["id"] == "C-RANK-01" else r
                                     for r in rows if not r["id"].startswith("C-SCORE")])
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        skipped = sorted(t["name"] for t in self.fake.tasks.values() if t["status"]["status"] == "skipped")
        self.assertEqual(skipped, sorted([JUDGE_CARD, "Save a valid score",
                                          "Refuse a score above the maximum", "Judge sees the ranking"]))
        self.assertEqual(len(self.fake.tasks), 6)

    def test_removed_check_a_person_moved_is_left_alone(self):
        self.assertEqual(self.push()[0], 0)
        t = self.fake.task("Refuse a score above the maximum")
        t["status"] = {"status": "passed", "type": "custom"}
        self.remove_check("C-SCORE-02")
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertIn("SKIP\tchanged-by-person\tRefuse a score above the maximum", lines)
        self.assertEqual(self.fake.calls, [])

    def test_lint_problem_sends_nothing(self):
        self.edit_cards(lambda d: d["cards"][0].update(title="Judge scores a submission (C-SCORE-01)"))
        self.fake.request = mock.Mock(side_effect=AssertionError("nothing may be sent"))
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\tlint\tjudge-scores-a-submission\t-\tlooks like an id: ")
                            for ln in lines), lines)
        self.fake.request.assert_not_called()
        # a check with no card is a problem too
        self.new_project()
        self.ready()
        self.remove_check("C-SCORE-02")
        self.edit_plan(lambda rows: rows + [{"id": "C-SCORE-02", "persona": "judge"}])
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertIn("SKIP\tlint\t-\tC-SCORE-02\tno card for this check", lines)
        self.assertEqual(self.fake.calls, [])

    def test_person_edited_description_reported_not_overwritten(self):
        self.assertEqual(self.push()[0], 0)
        t = self.fake.task(JUDGE_CARD)
        edited = "Noura scores two submissions, one from each team in her group."
        t["markdown_description"] = edited
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertIn(f"SKIP\tchanged-by-person\t{JUDGE_CARD}", lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(t["markdown_description"], edited)
        # the plan changes too: the person's text still stays
        self.edit_cards(lambda d: d["cards"][0].update(storyline="Noura opens a submission and saves a score."))
        rc, lines, _ = self.push()
        self.assertIn(f"SKIP\tchanged-by-person\t{JUDGE_CARD}", lines)
        self.assertEqual(t["markdown_description"], edited)
        self.assertEqual(self.fake.calls, [])
        # on a machine with no record of what was pushed the text is not replaced either, and
        # the step fails until the person says which text wins
        (self.tmp / ".qa" / "tracker-map.json").unlink()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith(f"SKIP\tdescription-differs\t{JUDGE_CARD}") for ln in lines), lines)
        self.assertEqual(t["markdown_description"], edited)
        rc, lines, _ = self.push("--overwrite", "judge-scores-a-submission")
        self.assertEqual(rc, 0, lines)
        self.assertEqual(t["markdown_description"], "Noura opens a submission and saves a score.")

    def test_needs_spec_init_first(self):
        self.edit_cfg(lambda d: d["specs"].update({TARGET: {"enabled": True}}))
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertTrue(any(ln.startswith("SKIP\tnot-ready\t") for ln in lines), lines)
        self.assertEqual(self.fake.calls, [])

    def test_list_from_template_waits_and_checks_statuses(self):
        from trackers import clickup_spec as cs
        self.edit_cfg(lambda d: d.update(templates={"list": "t-4410"}))
        folder = self.cfg()["specs"][TARGET]["folder"]
        with mock.patch.object(cs.time, "sleep") as sleep:
            rc, lines, err = self.push()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.writes("POST", r"/list_template/"), [
            ("POST", f"/v2/folder/{folder}/list_template/t-4410",
             {"name": "Run 1 · next", "options": {"return_immediately": False, "include_views": True}})])
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(len(self.fake.tasks_in(self.run_list()["id"])), 6)
        # a template without the folder's statuses: the list is not filled, on this run or on
        # the next one, which finds the list again
        self.new_project()
        self.ready()
        self.edit_cfg(lambda d: d.update(templates={"list": "t-4410"}))
        self.fake.template_statuses = ["to do", "done"]
        for _ in range(2):
            with mock.patch.object(cs.time, "sleep"):
                rc, lines, _ = self.push()
            self.assertEqual(rc, 1)
            self.assertTrue(any(ln.startswith("SKIP\tlist-statuses\t") for ln in lines), lines)
            self.assertEqual(self.fake.tasks, {})
        self.assertEqual(len(self.fake.writes("POST", r"/list_template/")), 1)

    def test_id_from_the_config_cannot_reach_into_another_path(self):
        self.edit_cfg(lambda d: d["specs"][TARGET].update(folder="9003/../../list/905"))
        rc, _, err = self.push()
        self.assertEqual(rc, 1)
        self.assertIn(f"config error: specs.{TARGET}.folder must be a ClickUp id", err)
        self.assertEqual(self.fake.calls, [])

    def test_spec_folder_moved_out_of_the_qa_folder_is_refused(self):
        folder = self.cfg()["specs"][TARGET]["folder"]
        self.fake.folders[folder]["parent"] = None
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertIn(f"SKIP\tsubfolder-not-nested\t{TITLE}: the spec's folder is not inside the QA folder; "
                      f"move it into the QA folder, then run again", lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(self.fake.lists.keys(), {"905"})

    def checklists_of(self, name=ADMIN_CARD):
        tid = self.fake.task(name)["id"]
        return [c for c in self.fake.checklists.values() if c["task_id"] == tid]

    def test_checklist_is_not_made_twice_when_list_reads_leave_it_out(self):
        real = self.fake.request

        def bare(method, path, body=None):
            out = real(method, path, body)
            if method == "GET" and re.search(r"/list/\w+/task\?", path):
                for t in out["tasks"]:
                    t.pop("checklists", None)
            if method == "POST" and path.endswith("/task"):
                out.pop("checklists", None)
            return out
        self.fake.request = bare
        self.assertEqual(self.push()[0], 0)
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(len(self.checklists_of()), 1)
        self.assertEqual(self.fake.items_of(self.fake.task(ADMIN_CARD)["id"]),
                         ["Admin sees the ranking", "Hackathon list opens"])

    def test_checklist_and_item_creates_that_landed_are_not_repeated(self):
        for pattern in (r"/task/\w+/checklist$", r"/checklist_item$"):
            with self.subTest(pattern=pattern):
                self.new_project()
                self.ready()
                self.fail_after("POST", pattern)
                self.push()
                self.fake.calls.clear()
                rc, lines, _ = self.push()
                self.assertEqual(rc, 0, lines)
                self.assertEqual(self.fake.calls, [])
                self.assertEqual(len(self.checklists_of()), 1)
                self.assertEqual(self.fake.items_of(self.fake.task(ADMIN_CARD)["id"]),
                                 ["Admin sees the ranking", "Hackathon list opens"])

    def test_check_back_in_the_plan_returns_to_the_first_status(self):
        from trackers import clickup_spec as cs
        self.assertEqual(self.push()[0], 0)
        put_back = self.keep_files()
        self.remove_check("C-SCORE-02")
        self.assertEqual(self.push()[0], 0)
        t = self.fake.task("Refuse a score above the maximum")
        self.assertEqual(t["status"]["status"], "skipped")
        put_back()
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(t["status"]["status"], "to test")
        self.assertEqual(cs.parse_ref(t["values"]["f-ref"])["letter"], "t")
        self.assertEqual(self.fake.comments[t["id"]], [
            {"comment_text": "No longer part of the plan.", "notify_all": False},
            {"comment_text": "Back in the plan.", "notify_all": False}])
        self.assertEqual(len(self.fake.calls), 3)
        self.assertEqual(len(self.fake.tasks), 6)
        self.fake.calls.clear()
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.fake.calls, [])
        # out and back a second time: each move leaves its own comment, once
        self.remove_check("C-SCORE-02")
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(t["status"]["status"], "skipped")
        put_back()
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(t["status"]["status"], "to test")
        self.assertEqual([c["comment_text"] for c in self.fake.comments[t["id"]]], [
            "No longer part of the plan.", "Back in the plan.", "No longer part of the plan.", "Back in the plan."])

    def test_card_back_in_the_plan_brings_its_checks_back(self):
        self.assertEqual(self.push()[0], 0)
        put_back = self.keep_files()
        self.edit_cards(lambda d: d.update(cards=d["cards"][1:]))
        self.edit_plan(lambda rows: [dict(r, personas=["admin"]) if r["id"] == "C-RANK-01" else r
                                     for r in rows if not r["id"].startswith("C-SCORE")])
        self.assertEqual(self.push()[0], 0)
        put_back()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual({t["status"]["status"] for t in self.fake.tasks.values()}, {"to test"})
        self.assertEqual({r["letter"] for r in self.refs(self.run_list()["id"]).values()}, {"t"})

    def test_retired_check_a_person_moved_stays_when_it_returns(self):
        from trackers import clickup_spec as cs
        self.assertEqual(self.push()[0], 0)
        put_back = self.keep_files()
        self.remove_check("C-SCORE-02")
        self.assertEqual(self.push()[0], 0)
        t = self.fake.task("Refuse a score above the maximum")
        t["status"] = {"status": "passed", "type": "custom"}  # a person ran it anyway
        put_back()
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertIn("SKIP\tchanged-by-person\tRefuse a score above the maximum", lines)
        self.assertEqual(self.fake.calls, [])
        self.assertEqual(t["status"]["status"], "passed")
        self.assertEqual(cs.parse_ref(t["values"]["f-ref"])["letter"], "s")
        # and one a person set to skipped while it was in the plan is not taken back either
        other = self.fake.task("Save a valid score")
        other["status"] = {"status": "skipped", "type": "custom"}
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertIn("SKIP\tchanged-by-person\tSave a valid score", lines)
        self.assertEqual(self.fake.calls, [])

    def test_plan_text_cannot_change_the_ticket_formatting(self):
        self.edit_cards(lambda d: d["cards"][0].update(
            storyline="# Final round\n- Noura opens a submission from the smart water metering team\n"
                      "> and saves a score of 8.\n2. The ranking page at https://judging.innovation-lab.co/final_round "
                      "then shows it."))
        self.edit_cards(lambda d: d["cards"][0]["checks"][0].update(
            do="Open a submission marked *urgent* and type 8 in the score box, _only once_."))
        rc, lines, err = self.push()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual(self.fake.task(JUDGE_CARD)["markdown_description"],
                         "\\# Final round\n\\- Noura opens a submission from the smart water metering team\n"
                         "\\> and saves a score of 8.\n2\\. The ranking page at "
                         "https://judging.innovation-lab.co/final_round then shows it.")
        self.assertEqual(self.fake.task("Save a valid score")["markdown_description"],
                         "Open a submission marked \\*urgent\\* and type 8 in the score box, \\_only once\\_.\n\n"
                         "The score is saved and shown on the submission page.")
        self.fake.calls.clear()
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        self.assertEqual(self.fake.calls, [])

    def test_fixed_strings_are_linted_like_any_other_text(self):
        from trackers import clickup_spec as cs
        self.assertEqual((cs.CHECKLIST_NAME, cs.SUMMARY_TITLE, cs.VIEW_STATUS, cs.VIEW_ROLE, cs.VIEW_FAILED,
                          cs.REMOVED_COMMENT, cs.BACK_COMMENT),
                         ("Checks", "Run summary", "By status", "By role", "Failed and blocked",
                          "No longer part of the plan.", "Back in the plan."))
        self.edit_cfg(lambda d: d.update(wording={"forbidden": ["Checks", "blocked"]}))
        rc, lines, _ = self.push()
        self.assertEqual(rc, 1)
        self.assertIn('SKIP\twording\t"Checks": forbidden word: Checks', lines)
        self.assertIn('SKIP\twording\t"Failed and blocked": forbidden word: blocked', lines)
        self.assertEqual(self.fake.checklists, {})
        self.assertEqual([v["name"] for v in self.fake.views[self.run_list()["id"]]], ["By status", "By role"])

    def test_check_id_cannot_collide(self):
        from trackers import clickup_spec as cs
        self.assertEqual(cs.check_id("judge-scores-a-submission", "C-SCORE-02"),
                         "25:judge-scores-a-submission/C-SCORE-02")
        self.assertNotEqual(cs.check_id("ranking/final", "round"), cs.check_id("ranking", "final/round"))
        self.assertNotEqual(cs.check_id("1", "2:ab/c"), cs.check_id("12:ab", "c"))

    def test_bound_list_gets_a_new_list_beside_it(self):
        from trackers import clickup_spec as cs
        self.assertEqual(self.push()[0], 0)
        summary = self.fake.task("Run summary")
        summary["values"]["f-ref"] = cs.ref(TARGET, 1, "summary", "summary", "p", run="run-2026-11-27")
        rc, lines, _ = self.push()
        self.assertEqual(rc, 0, lines)
        folder = self.cfg()["specs"][TARGET]["folder"]
        names = [l["name"] for l in self.fake.lists.values() if l["folder"] == folder]
        self.assertEqual(names, ["Run 1 · next", "Run 2 · next"])
        second = [l["id"] for l in self.fake.lists.values() if l["name"] == "Run 2 · next"][0]
        self.assertEqual(len(self.fake.tasks_in(second)), 6)
        self.assertEqual(self.fake.task("Run summary", second)["values"]["f-ref"],
                         cs.ref(TARGET, 2, "summary", "summary"))


class OwnStatusTests(SpecBase):
    statuses = OWN_STATUSES

    def test_own_status_names(self):
        self.edit_cfg(lambda d: d.update(statuses={
            "case": OWN_STATUSES, "bug": ["open", "triaged", "fixing", "retest", "closed"]}))
        self.ready()
        rc, lines, err = self.push()
        self.assertEqual(rc, 0, (lines, err))
        self.assertEqual({t["status"]["status"] for t in self.fake.tasks.values()}, {"ready"})
        self.remove_check("C-SCORE-02")
        self.assertEqual(self.push()[0], 0)
        self.assertEqual(self.fake.task("Refuse a score above the maximum")["status"]["status"], "left out")


if __name__ == "__main__":
    unittest.main()
