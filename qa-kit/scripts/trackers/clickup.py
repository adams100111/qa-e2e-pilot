"""ClickUp backend: push the catalog (and guide) into the QA folder, pull drafts back.

A generalised port of Innovation's `docs/qa/sync_clickup.py`. Dry run unless `--apply`.
Never deletes anything. push-plan sets a case status only to the project's `skipped` status (the
sixth name in `statuses.case`), for retired or orphaned cases and retired guide tasks.

Remote identity is what a person sees (P2): a case is found by the `TC-… · ` prefix of its task
name, a list by name, the guide Doc by name, a page by name. `.qa/tracker-map.json` only caches
remote ids and the last-pushed description hash (used to tell a human edit from a catalog change).

The transport comes from `transport_for(ctx)`: `ctx.transport` or `ctx.args.transport` when set
(tests inject a fake there), else an `HttpTransport` with `CLICKUP_API_TOKEN`.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
import time
import urllib.parse
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from trackers.clickup_api import ApiError, HttpTransport, Transport, token_from_env
from trackers.core import (CONFIG_REL, ConfigError, RunError, WordingError, case_index, case_results,
                           content_hash, fingerprint, norm, outbound, same_status, status_name,
                           validate_catalog)
from trackers.ctx import _manifest, manifest_build, run_dir_for, run_label

try:  # optional, only for writing pulled drafts as YAML
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None  # type: ignore

TC_RE = re.compile(r"^(TC-[A-Z]+-\d+) · ")
PRIORITY = {"P1": 1, "P2": 2, "P3": 3}  # urgent / high / normal
PRIORITY_BACK = {v: k for k, v in PRIORITY.items()}
TAG_RETIRED = "retired"
LEVELS = {"beginner": "Beginner", "needs-setup": "Needs setup", "technical": "Technical"}
MANAGED_TAGS = {"beginner", "needs setup", "technical", "run last"}
DEFAULT_GUIDE_LIST = "00 – Guide & Sign-off"
GUIDE_DOC = "QA Guide"
GUIDE_TASK_PREFIX = "Guide · "
SIGNOFF_PREFIX = "Sign-off · "
GUIDE_RETIRED_COMMENT = 'This guide now lives in the "QA Guide" doc.'
INTRO_TASKS = "New to the platform? Read \"Guide · Start Here\" in the {guide_list} list first, then pick cases tagged beginner."
INTRO_DOC = 'New to the platform? Read the "QA Guide" doc first, then pick cases tagged beginner.'
SPACE_PARENT_TYPE = 4
TASK_QUERY = "subtasks=true&include_closed=true&include_markdown_description=true"
CACHE_KIND = "case"


def today() -> str:
    return time.strftime("%Y-%m-%d")


def transport_for(ctx) -> Transport:
    t = getattr(ctx, "transport", None) or getattr(getattr(ctx, "args", None), "transport", None)
    return t if t is not None else HttpTransport(token_from_env())


def _ids(ctx) -> Tuple[str, Optional[str], str]:
    ids = ctx.cfg.get("ids") or {}
    ws, space, folder = ids.get("workspace"), ids.get("space"), ids.get("folder")
    if not ws or not folder:
        raise ConfigError("ids.workspace and ids.folder must be set for the clickup backend")
    return str(ws), (str(space) if space else None), str(folder)


def _arg(ctx, name: str, default: Any) -> Any:
    v = getattr(getattr(ctx, "args", None), name, None)
    return default if v is None else v


def _maybe_landed(err: ApiError) -> bool:
    return err.status == 0 or err.status >= 500


@contextmanager
def _keep_cache(ctx):
    """Under --apply, save the remote-id cache however the verb ends, so ids learned before a
    failure (an expired token mid-run, say) are not lost."""
    try:
        yield
    finally:
        if ctx.log.apply:
            ctx.cache.save()


# ---------------------------------------------------------------- live state


@dataclass
class Folder:
    lists: Dict[str, str]
    tasks: List[dict]
    by_tc: Dict[str, dict] = field(default_factory=dict)
    by_name: Dict[str, dict] = field(default_factory=dict)
    list_info: Dict[str, dict] = field(default_factory=dict)  # list id -> GET /v2/list/{id}
    dupes: Dict[str, List[str]] = field(default_factory=dict)  # TC id -> task ids, when > 1


def load_folder(ctx, transport: Optional[Transport] = None) -> Folder:
    """Read the folder's lists and every task in them (closed and subtasks included)."""
    tr = transport or transport_for(ctx)
    _, _, folder_id = _ids(ctx)
    folder = tr.request("GET", f"/v2/folder/{folder_id}")
    lists = {l["name"]: str(l["id"]) for l in folder.get("lists") or []}
    tasks: List[dict] = []
    for lid in lists.values():
        page = 0
        while True:
            r = tr.request("GET", f"/v2/list/{lid}/task?{TASK_QUERY}&page={page}")
            got = r.get("tasks") or []
            tasks += got
            if len(got) < 100:
                break
            page += 1
    by_tc: Dict[str, dict] = {}
    seen: Dict[str, List[str]] = {}
    for t in tasks:
        m = TC_RE.match(t.get("name") or "")
        if m:
            ids = seen.setdefault(m.group(1), [])
            if str(t["id"]) not in ids:
                ids.append(str(t["id"]))
            by_tc.setdefault(m.group(1), t)
    dupes = {k: v for k, v in seen.items() if len(v) > 1}
    by_name = {}
    for t in tasks:
        by_name.setdefault(t.get("name"), t)
    return Folder(lists=lists, tasks=tasks, by_tc=by_tc, by_name=by_name, dupes=dupes)


# ---------------------------------------------------------------- text (verbatim from sync_clickup.py)


def case_tags(case: dict) -> set:
    """Tags derived from the catalog; only MANAGED_TAGS are ever added or removed."""
    level = case.get("level") or ("technical" if case.get("audience") == "technical" else None)
    tags = {LEVELS[level].lower()} if level in LEVELS else set()
    if case.get("run_last"):
        tags.add("run last")
    return tags


def describe(case: dict) -> str:
    steps = "\n".join(f"{i}. {s}" for i, s in enumerate(case["steps"], 1))
    expected = "\n".join(f"- {e}" for e in case["expected"])
    meta = []
    if case.get("level") in LEVELS:
        meta.append(f"**Level:** {LEVELS[case['level']]}")
    if case.get("run_last"):
        meta.append("**Run this last:** it changes shared test data that other cases rely on.")
    return "\n\n".join(meta + [
        f"**Preconditions:** {case['preconditions']}",
        f"**Steps:**\n{steps}",
        f"**Expected results:**\n{expected}",
        "**Evidence:**\n- [ ] Screenshot / recording attached (or n/a)",
    ])


def stale(t: dict, desc: str) -> bool:
    """True when the task's description differs from `desc` or still shows raw markdown."""
    return norm(t.get("markdown_description")) != norm(desc) or "**" in (t.get("description") or "")


def intro_body(intro: dict, guide_list: str, guide_as: str = "tasks") -> str:
    def bullets(v):
        return "\n".join(f"- {x}" for x in (v if isinstance(v, list) else [v]))
    parts = [intro["what"]]
    if intro.get("accounts"):
        parts.append(f"**Accounts:** {intro['accounts']}")
    if intro.get("before_you_start"):
        parts.append(f"**Before you start:**\n{bullets(intro['before_you_start'])}")
    if intro.get("run_order"):
        parts.append(f"**Run order:**\n{bullets(intro['run_order'])}")
    if intro.get("manual"):
        parts.append(f"**User Manual:** {intro['manual']} (admin sidebar → User Manual).")
    parts.append(INTRO_DOC if guide_as == "doc" else INTRO_TASKS.format(guide_list=guide_list))
    return "\n\n".join(parts)


# ---------------------------------------------------------------- the sync


class _Sync:
    """One push-plan pass. Holds the transport, live state and helpers that write through the log."""

    def __init__(self, ctx, folder: Optional[Folder] = None):
        self.ctx = ctx
        self.cfg = ctx.cfg
        self.log = ctx.log
        self.tr = transport_for(ctx)
        self.ws, self.space, self.folder_id = _ids(ctx)
        self.folder = folder or load_folder(ctx, self.tr)
        self.lists = self.folder.lists
        self.only = list(_arg(ctx, "only", []) or [])
        self.overwrite = set(_arg(ctx, "overwrite", []) or [])
        self.guide_list = (self.cfg.get("lists") or {}).get("guide") or DEFAULT_GUIDE_LIST
        self.today = today()
        # the project's status names for the roles this tool reads or writes
        self.case_new = status_name(self.cfg, "case", "to_test")
        self.case_testing = status_name(self.cfg, "case", "testing")
        self.case_skipped = status_name(self.cfg, "case", "skipped")
        self.bug_open = status_name(self.cfg, "bug", "open")
        self.bug_retest = status_name(self.cfg, "bug", "retest")
        self.bug_closed = status_name(self.cfg, "bug", "closed")

    # -- transport helpers

    def get_list(self, lid: str) -> dict:
        if lid.startswith("<"):
            return {}
        if lid not in self.folder.list_info:
            self.folder.list_info[lid] = self.tr.request("GET", f"/v2/list/{lid}")
        return self.folder.list_info[lid]

    def list_statuses(self, lid: str) -> set:
        return {x["status"] for x in self.get_list(lid).get("statuses") or []}

    def write(self, kind: str, detail: str, fn: Callable[[], Any]) -> Any:
        """Log the action; under --apply run it. A failed write skips that item, never the run.

        A non-GET 5xx/network failure may have landed, so it is never retried here: the next
        run re-reads the folder and finds the item by name.
        """
        def guarded():
            try:
                return fn()
            except ApiError as err:
                if err.status in (401, 403):
                    raise
                why = "may have landed, re-run to reconcile" if _maybe_landed(err) else "failed"
                self.log.skip("api-error", f"{detail}: HTTP {err.status} ({why})")
                return _FAILED
        out = self.log.act(kind, detail, guarded)
        return None if out is _FAILED else out

    def text(self, item: str, value: str, source: str = "catalog") -> Optional[str]:
        try:
            return outbound(value, self.cfg, source=source)
        except WordingError as err:
            self.log.skip("wording", f"{item}: {err.word}")
            return None

    def ensure_list(self, name: str) -> str:
        if name in self.lists:
            return self.lists[name]
        safe = self.text(f"list {name}", name)
        if safe is None:
            self.lists[name] = f"<skipped:{name}>"
            return self.lists[name]
        r = self.write("create-list", name,
                       lambda: self.tr.request("POST", f"/v2/folder/{self.folder_id}/list", {"name": safe}))
        self.lists[name] = str(r["id"]) if r and r.get("id") else f"<new:{name}>"
        return self.lists[name]

    def comment(self, task_id: str, text: str) -> None:
        self.tr.request("POST", f"/v2/task/{task_id}/comment", {"comment_text": text, "notify_all": False})

    def update_fn(self, t: dict, body: dict, comment: Optional[str], cache_key: Optional[str] = None,
                  pushed: Optional[str] = None, label: str = "") -> Callable[[], Any]:
        def go():
            self.tr.request("PUT", f"/v2/task/{t['id']}", body)
            if cache_key and pushed is not None:
                self.ctx.cache.put(CACHE_KIND, cache_key, t["id"], content_hash(pushed))
            if comment:
                try:
                    self.comment(t["id"], comment)
                except ApiError as err:
                    if err.status in (401, 403):
                        raise
                    self.log.skip("comment-failed", f"{label or t['id']}: HTTP {err.status}")
            return True
        return go

    def create_fn(self, lid: str, body: dict, cache_key: Optional[str] = None) -> Callable[[], Any]:
        def go():
            r = self.tr.request("POST", f"/v2/list/{lid}/task", body)
            if cache_key and r and r.get("id"):
                md = body["markdown_content"]
                self.ctx.cache.put(CACHE_KIND, cache_key, r["id"], content_hash(md))
                # record it, so a second occurrence in this run is an update check, not a create
                self.folder.by_tc[cache_key] = {
                    "id": r["id"], "name": body["name"], "markdown_description": md,
                    "description": md.replace("**", ""), "status": {"status": body.get("status")},
                    "priority": {"id": str(body["priority"])} if body.get("priority") else None,
                    "tags": [{"name": x} for x in body.get("tags", [])],
                    "list": {"id": lid, "name": next((k for k, v in self.lists.items() if v == lid), "")}}
            return r
        return go

    def move(self, t: dict, lid: str, detail: str) -> None:
        if lid.startswith("<"):
            return
        self.write("move", detail, lambda: self.tr.request(
            "PUT", f"/v3/workspaces/{self.ws}/tasks/{t['id']}/home_list/{lid}"))

    def retire(self, t: dict, label: str, detail: str, comment_text: str,
               description: Optional[str] = None) -> None:
        """Once: (description), comment, then tag `retired` (the tag marks it done, so a partial
        failure is redone next run). Then status `skipped` when the list has it.

        A wording hit in the comment skips only the comment; the tag and status still go.
        """
        tagged = any(x.get("name") == TAG_RETIRED for x in t.get("tags") or [])
        if not tagged:
            text = self.text(label, comment_text, source="generated")
            desc = self.text(label, description, source="generated") if description is not None else None
            def go(t=t, text=text, desc=desc):
                if desc is not None and norm(t.get("markdown_description")) != norm(desc):
                    self.tr.request("PUT", f"/v2/task/{t['id']}", {"markdown_content": desc})
                if text is not None:
                    self.comment(t["id"], text)
                self.tr.request("POST", f"/v2/task/{t['id']}/tag/{TAG_RETIRED}")
            self.write("retire", detail, go)
        if not same_status(_status_of(t), self.case_skipped):
            live = next((x for x in self.list_statuses(str(t["list"]["id"]))
                         if same_status(x, self.case_skipped)), None)
            if live is not None:
                self.write("status-skipped", label, lambda t=t, live=live: self.tr.request(
                    "PUT", f"/v2/task/{t['id']}", {"status": live}))
            else:
                self.log.act("skip-pending", f"{label} (list has no '{self.case_skipped}' status yet)")

    # -- drift (D5)

    def is_drift(self, case_id: str, t: dict, desc: str) -> bool:
        """A human edit: live hash != last pushed hash and != catalog hash. Empty cache: no drift."""
        if case_id in self.overwrite:
            return False
        entry = self.ctx.cache.get(CACHE_KIND, case_id)
        if not entry or not entry.get("hash"):
            return False
        live = content_hash(t.get("markdown_description") or "")
        return live != entry["hash"] and live != content_hash(desc)

    def remember(self, case_id: str, t: dict, desc: str) -> None:
        """Under --apply, cache the hash of a task already in sync (equivalent to a push)."""
        if self.log.apply and not stale(t, desc):
            self.ctx.cache.put(CACHE_KIND, case_id, t["id"], content_hash(desc))

    def duplicate(self, cid: str) -> bool:
        ids = self.folder.dupes.get(cid)
        if ids:
            self.log.skip("duplicate", f"{cid}: {', '.join(ids)}")
            return True
        return False

    # -- areas

    def sync_intro(self, lid: str, list_name: str, intro: dict) -> None:
        if lid.startswith("<") and self.log.apply:
            return
        body = self.text(f"intro {list_name}",
                         intro_body(intro, self.guide_list, self.cfg.get("guideAs") or "tasks"))
        if body is None:
            return
        current = "" if lid.startswith("<") else self.get_list(lid).get("content", "") or ""
        if norm(current) != norm(body):
            self.write("intro", list_name, lambda: self.tr.request(
                "PUT", f"/v2/list/{lid}", {"markdown_content": body}))

    def sync_retired(self, area, lid: str, case: dict, name: Optional[str], desc: Optional[str]) -> None:
        cid = case["id"]
        t = self.folder.by_tc.get(cid)
        if not t:
            return
        if str(t["list"]["id"]) != lid:
            self.move(t, lid, f"{cid}: {t['list'].get('name')} → {area.list}")
        if name is not None and desc is not None:
            if stale(t, desc) or t["name"] != name:
                if self.is_drift(cid, t, desc):
                    self.log.act("drift", cid)
                else:
                    self.write("update", f"{cid} [retired content]",
                               self.update_fn(t, {"name": name, "markdown_content": desc}, None, cid, desc, cid))
            else:
                self.remember(cid, t, desc)
        self.retire(t, cid, f"{cid} ({area.list})",
                    f"Retired from the catalog on {self.today}: {case.get('retired_reason', '')}")

    def sync_case(self, area, lid: str, case: dict) -> None:
        cid = case["id"]
        if self.duplicate(cid):
            return
        name = self.text(cid, f"{cid} · {case['title']}")
        desc = self.text(cid, describe(case)) if name is not None else None
        if case.get("retired"):
            self.sync_retired(area, lid, case, name, desc)
            return
        if name is None or desc is None:
            return
        want_tags = case_tags(case)
        t = self.folder.by_tc.get(cid)
        if not t:
            if lid.startswith("<skipped"):
                return
            body = {"name": name, "markdown_content": desc, "priority": PRIORITY[case["priority"]],
                    "status": self.case_new, "tags": sorted(want_tags)}
            if lid.startswith("<") and self.log.apply:
                self.log.skip("api-error", f"{cid}: list {area.list} was not created")
                return
            self.write("create", f"{cid} → {area.list}", self.create_fn(lid, body, cid))
            return
        if self.is_drift(cid, t, desc):
            self.log.act("drift", cid)
            return
        if str(t["list"]["id"]) != lid:
            self.move(t, lid, f"{cid}: {t['list'].get('name')} → {area.list}")
        changed: List[str] = []
        body: Dict[str, Any] = {}
        if t["name"] != name:
            body["name"] = name
            changed.append("title")
        if stale(t, desc):
            body["markdown_content"] = desc
            changed.append("description")
        cur_p = int(t["priority"]["id"]) if t.get("priority") else None
        if cur_p != PRIORITY[case["priority"]]:
            body["priority"] = PRIORITY[case["priority"]]
            changed.append("priority")
        if body:
            comment = None
            if {"title", "description"} & set(changed) and not same_status(_status_of(t), self.case_new):
                comment = self.text(cid, f"Updated from the catalog on {self.today} — re-verify if already passed.",
                                    source="generated")
                if comment is None:
                    return
            self.write("update", f"{cid} [{','.join(changed)}]",
                       self.update_fn(t, body, comment, cid, desc, cid))
        else:
            self.remember(cid, t, desc)
        have_tags = {x["name"] for x in t.get("tags") or []} & MANAGED_TAGS
        for tg in sorted(want_tags - have_tags):
            self.write("tag+", f"{cid} {tg}", lambda tg=tg: self.tr.request(
                "POST", f"/v2/task/{t['id']}/tag/{urllib.parse.quote(tg)}"))
        for tg in sorted(have_tags - want_tags):
            self.write("tag-", f"{cid} {tg}", lambda tg=tg: self.tr.request(
                "DELETE", f"/v2/task/{t['id']}/tag/{urllib.parse.quote(tg)}"))

    def sync_areas(self, catalog) -> None:
        for area in catalog.areas:
            if self.only and area.file not in self.only:
                continue
            if area.missing:
                continue
            lid = self.ensure_list(area.list)
            if area.intro and not lid.startswith("<skipped"):
                self.sync_intro(lid, area.list, area.intro)
            for case in area.cases:
                if isinstance(case, dict) and isinstance(case.get("id"), str):
                    self.sync_case(area, lid, case)

    def retire_orphans(self, catalog, catalog_ok: bool = True) -> None:
        """Retire TC tasks the catalog no longer lists, but only ones we pushed before (cache
        entry with this very task id) or already tagged retired. Anything else may be a tester's new case: report it."""
        if not catalog_ok:
            self.log.skip("orphan-retirement", "skipped: catalog has errors")
            return
        known = case_index(catalog)
        for cid in sorted(self.folder.by_tc):
            if cid in known or self.duplicate(cid):
                continue
            t = self.folder.by_tc[cid]
            lname = t["list"].get("name")
            tagged = any(x.get("name") == TAG_RETIRED for x in t.get("tags") or [])
            entry = self.ctx.cache.get(CACHE_KIND, cid)
            pushed_by_us = bool(entry) and str(entry.get("id")) == str(t["id"])
            if not tagged and not pushed_by_us:
                self.log.act("orphan", f"{cid} ({lname})")
                continue
            self.retire(t, cid, f"{cid} (orphan, {lname})",
                        f"Retired on {self.today}: this case is no longer part of the test plan; "
                        f"the feature it covered was replaced.")

    # -- guide

    def guide_files(self) -> List[Tuple[str, str, str]]:
        """(file name, H1, body) for every guide/*.md, sorted."""
        gdir = Path(self.ctx.project) / self.cfg.get("guideDir", ".qa/guide")
        if not gdir.is_dir():
            return []
        out = []
        for p in sorted(gdir.iterdir()):
            if not (p.is_file() and p.suffix == ".md"):
                continue
            text = p.read_text(encoding="utf-8")
            h1, _, body = text.partition("\n")
            out.append((p.name, h1.lstrip("# ").strip(), body.strip()))
        return out

    def sync_signoff(self, glid: str, body: str) -> None:
        parts = re.split(r"^## (Criterion \d+: .*)$", body, flags=re.M)
        for i in range(1, len(parts), 2):
            raw = f"{SIGNOFF_PREFIX}{parts[i].strip()}"
            name = self.text(raw, raw)
            sec = self.text(raw, parts[i + 1].strip()) if name is not None else None
            if name is None or sec is None:
                continue
            num = re.match(r"Criterion (\d+)", parts[i]).group(1)
            t = next((x for x in self.folder.tasks
                      if (x.get("name") or "").startswith(f"{SIGNOFF_PREFIX}Criterion {num}:")), None)
            if not t:
                self.write("create", name, self.create_fn(glid, {"name": name, "markdown_content": sec}))
            elif t["name"] != name or stale(t, sec):
                self.write("update", name, self.update_fn(t, {"name": name, "markdown_content": sec}, None,
                                                          label=name))

    def sync_guide_tasks(self) -> None:
        files = self.guide_files()
        if not files:
            return
        glid = self.ensure_list(self.guide_list)
        if glid.startswith("<skipped"):
            return
        for fname, h1, body in files:
            if fname.startswith("07"):
                self.sync_signoff(glid, body)
                continue
            raw = f"{GUIDE_TASK_PREFIX}{h1}"
            name = self.text(raw, raw)
            safe = self.text(raw, body) if name is not None else None
            if name is None or safe is None:
                continue
            t = self.folder.by_name.get(name)
            if not t:
                self.write("create", name, self.create_fn(glid, {"name": name, "markdown_content": safe}))
            elif stale(t, safe):
                self.write("update", name, self.update_fn(t, {"markdown_content": safe}, None, label=name))

    def find_docs(self) -> List[dict]:
        """Every `QA Guide` Doc whose parent is the folder's space (v3 Search for Docs, paginated)."""
        found, seen = [], set()
        cursor = None
        while True:
            q = "deleted=false&archived=false&limit=100" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
            r = self.tr.request("GET", f"/v3/workspaces/{self.ws}/docs?{q}")
            for d in r.get("docs") or []:
                parent = d.get("parent") or {}
                if (d.get("name") == GUIDE_DOC and str(parent.get("id")) == self.space
                        and str(parent.get("type")) == str(SPACE_PARENT_TYPE)
                        and not d.get("deleted") and not d.get("archived")
                        and str(d.get("id")) not in {str(x["id"]) for x in found}):
                    found.append(d)
            cursor = r.get("next_cursor")
            if not cursor or cursor in seen:
                return found
            seen.add(cursor)

    def doc_pages(self, doc_id: str) -> Dict[str, dict]:
        r = self.tr.request("GET", f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages"
                                   f"?max_page_depth=-1&content_format=text%2Fmd")
        pages = r if isinstance(r, list) else (r.get("pages") or [])
        out: Dict[str, dict] = {}

        def walk(items):
            for p in items or []:
                out.setdefault(p.get("name"), p)
                walk(p.get("pages"))
        walk(pages)
        return out

    def sync_guide_doc(self) -> None:
        files = self.guide_files()
        if not files:
            return
        if not self.space:
            raise ConfigError("ids.space must be set when guideAs is doc")
        docs = self.find_docs()
        if len(docs) > 1:
            self.log.skip("doc-ambiguous", ", ".join(str(d["id"]) for d in docs))
        else:
            self.sync_doc_pages(files, docs[0] if docs else None)
        for fname, _h1, body in files:
            if fname.startswith("07"):
                glid = self.ensure_list(self.guide_list)
                if not glid.startswith("<skipped"):
                    self.sync_signoff(glid, body)

    def sync_doc_pages(self, files, doc: Optional[dict]) -> None:
        doc_id = str(doc["id"]) if doc else None
        pages = self.doc_pages(doc_id) if doc_id else {}
        if not doc_id:
            r = self.write("doc-create", GUIDE_DOC, lambda: self.tr.request(
                "POST", f"/v3/workspaces/{self.ws}/docs",
                {"name": GUIDE_DOC, "parent": {"id": self.space, "type": SPACE_PARENT_TYPE}}))
            doc_id = str(r["id"]) if r and r.get("id") else None
            if self.log.apply and not doc_id:
                return  # no Doc: no pages and no guide-task retirement
        complete = True  # every guide page is in the Doc (or, in a dry run, planned)
        headings = set()
        for fname, h1, body in files:
            if fname.startswith("07"):
                continue
            name = self.text(f"guide {fname}", h1)
            content = self.text(f"guide {fname}", body) if name is not None else None
            if name is None or content is None:
                complete = False
                continue
            headings.add(h1)
            page = pages.get(name)
            if page is None:
                r = self.write("page-create", name, lambda name=name, content=content: self.tr.request(
                    "POST", f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages",
                    {"name": name, "content": content, "content_format": "text/md"}))
                if self.log.apply and not (r and r.get("id")):
                    complete = False
            elif norm(page.get("content")) != norm(content):
                self.write("page-update", name, lambda page=page, name=name, content=content: self.tr.request(
                    "PUT", f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages/{page['id']}",
                    {"name": name, "content": content, "content_format": "text/md",
                     "content_edit_mode": "replace"}))
        if not complete:
            return
        for t in self.folder.tasks:
            tname = t.get("name") or ""
            if tname.startswith(GUIDE_TASK_PREFIX) and tname[len(GUIDE_TASK_PREFIX):] in headings:
                self.retire(t, tname, tname, GUIDE_RETIRED_COMMENT, description=GUIDE_RETIRED_COMMENT)


_FAILED = object()


def _catalog_ok(ctx) -> bool:
    """Print every validation error. Under --apply any error refuses the push before a write."""
    errors = validate_catalog(ctx.catalog)
    for e in errors:
        where = e.get("file") or "catalog"
        if e.get("id"):
            where += f" {e['id']}"
        ctx.log.out.write(f"ERROR\tcatalog\t{where}: {e.get('reason')}\n")
    if errors and ctx.log.apply:
        raise RunError(f"catalog has {len(errors)} validation error(s); fix them before push-plan --apply")
    return not errors


def _push(ctx, folder: Optional[Folder] = None) -> "_Sync":
    if ctx.catalog is None:
        raise ConfigError("this verb needs a catalog")
    ok = _catalog_ok(ctx)
    s = _Sync(ctx, folder)
    s.sync_areas(ctx.catalog)
    if not s.only:
        s.retire_orphans(ctx.catalog, ok)
        if ctx.cfg.get("guideAs") == "doc":
            s.sync_guide_doc()
        else:
            s.sync_guide_tasks()
    return s


def push_plan(ctx) -> None:
    with _keep_cache(ctx):
        _push(ctx)


# ---------------------------------------------------------------- pull


_SECTION_RE = re.compile(r"\*\*(Preconditions|Steps|Expected results|Evidence|Level|Run this last):\*\*\s*", re.M)


def parse_description(text: str) -> dict:
    """Best-effort reverse of `describe` for a task a person added in ClickUp."""
    out: dict = {"preconditions": "", "steps": [], "expected": []}
    text = text or ""
    marks = list(_SECTION_RE.finditer(text))
    if not marks:
        out["preconditions"] = text.strip()
        return out
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        chunk = text[m.end():end].strip()
        key = m.group(1)
        lines = [re.sub(r"^\s*(?:\d+[.)]|[-*])\s*", "", ln).strip() for ln in chunk.splitlines()]
        lines = [ln for ln in lines if ln]
        if key == "Preconditions":
            out["preconditions"] = chunk
        elif key == "Steps":
            out["steps"] = lines
        elif key == "Expected results":
            out["expected"] = lines
        elif key == "Level":
            lv = {v.lower(): k for k, v in LEVELS.items()}.get(chunk.lower())
            if lv:
                out["level"] = lv
    return out


def _pull(ctx, folder: Folder, report_drift: bool = True) -> Dict[str, List[dict]]:
    catalog = ctx.catalog
    known = case_index(catalog) if catalog is not None else {}
    overwrite = set(_arg(ctx, "overwrite", []) or [])
    by_list = {a.list: a for a in (catalog.areas if catalog else [])}
    by_prefix = {}
    for a in (catalog.areas if catalog else []):
        for p in [a.prefix] + list(a.also_prefixes):
            by_prefix.setdefault(p, a)
    list_names = {v: k for k, v in folder.lists.items()}
    drafts: Dict[str, List[dict]] = {}
    for cid in sorted(folder.by_tc):
        t = folder.by_tc[cid]
        if cid in folder.dupes:
            continue  # push-plan/status report it as SKIP duplicate
        if cid in known:
            if not report_drift:
                continue
            _, case = known[cid]
            if case.get("retired") or cid in overwrite:
                continue
            entry = ctx.cache.get(CACHE_KIND, cid)
            if not entry or not entry.get("hash"):
                continue
            try:
                desc = outbound(describe(case), ctx.cfg, source="catalog")
            except WordingError:
                continue
            live = content_hash(t.get("markdown_description") or "")
            if live != entry["hash"] and live != content_hash(desc):
                ctx.log.act("drift", cid)
            continue
        if any(x.get("name") == TAG_RETIRED for x in t.get("tags") or []):
            continue
        lname = (t.get("list") or {}).get("name") or list_names.get(str((t.get("list") or {}).get("id")), "")
        m = re.match(r"^TC-([A-Z]+)-", cid)
        area = by_list.get(lname) or (by_prefix.get(m.group(1)) if m else None)
        afile = area.file if area else "unsorted.yaml"
        afile = re.sub(r"\.(json|yml)$", ".yaml", afile)
        title = TC_RE.sub("", t.get("name") or "").strip()
        pri = int(t["priority"]["id"]) if t.get("priority") else None
        entry = {"id": cid, "title": title, "priority": PRIORITY_BACK.get(pri, "P3"), "draft": True}
        entry.update(parse_description(t.get("markdown_description") or t.get("description") or ""))
        ctx.log.act("draft", f"{cid} → {afile}")
        drafts.setdefault(afile, []).append(entry)
    return drafts


def _dump(data: dict) -> str:
    if yaml is not None:
        return yaml.safe_dump(data, sort_keys=False, allow_unicode=True)
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"  # JSON is valid YAML


def pull_plan(ctx) -> None:
    """Tracker → catalog drafts. Writes only `.qa/tracker/pulled/*.yaml`, only under --apply."""
    folder = load_folder(ctx)
    drafts = _pull(ctx, folder)
    out_dir = Path(ctx.project) / ".qa" / "tracker" / "pulled"
    for afile, cases in sorted(drafts.items()):
        path = out_dir / afile

        def go(path=path, cases=cases):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(_dump({"cases": cases}), encoding="utf-8")
        ctx.log.act("pull-write", str(path.relative_to(Path(ctx.project))), go)


def status(ctx) -> None:
    """push-plan forced to a dry run, then pull-plan's draft candidates (drift is shown once)."""
    ctx.log.apply = False
    s = _push(ctx)
    _pull(ctx, s.folder, report_drift=False)


# ---------------------------------------------------------------- init


RUNS_LIST = "Runs"
BUGS_LIST = "Bugs"
LEVEL_OPTIONS = "/".join(LEVELS.values())
# (field name, how a person adds it in ClickUp)
AREA_FIELDS = [
    ("Role", "labels"),
    ("Level", f"drop down: {LEVEL_OPTIONS}"),
    ("Last check result", "drop down: pass/fail/blocked/deferred/error"),
    ("Last check run", "short text"),
    ("Linked bugs", f'relationship to the "{BUGS_LIST}" list'),
]
BUG_FIELDS = [
    ("Severity", "drop down: critical/high/medium/low"),
    ("Case", "relationship to tasks"),
    ("Found in run", "short text"),
    ("Retest result", "drop down: passed/still failing"),
    ("Ref", "short text"),
]
RUN_FIELDS = [
    ("Build", "short text"), ("Environment", "short text"), ("Language", "short text"),
    ("Passed", "number"), ("Failed", "number"), ("Blocked", "number"),
]
# (view name, grouping): "status" / "priority" / ("field", <field name>) / None
AREA_VIEWS = [("By status", "status"), ("By priority", "priority"), ("By level", ("field", "Level"))]
RUN_VIEWS = [("Results by run", None)]
BUG_VIEWS = [("Open by severity", ("field", "Severity")), ("By case", ("field", "Case"))]


def field_key(list_name: str, field_name: str) -> str:
    """Key of a custom field id in the config's `fields` map: `<list name>/<field name>`."""
    return f"{list_name}/{field_name}"


def _real(lid: str) -> bool:
    return not lid.startswith("<")


def _save_ids(ctx, lists: Dict[str, str], fields: Dict[str, str]) -> None:
    """Merge found ids into docs/agents/qa-tracker.json (all other keys kept), atomically.

    List ids go to `listIds` (`<list name>` -> id), kept apart from the name-valued `lists`
    settings; field ids go to `fields` (`<list name>/<field name>` -> id). The file keeps its mode.
    """
    path = Path(ctx.project) / CONFIG_REL
    data: dict = {}
    mode = None
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except ValueError as exc:
            raise ConfigError(f"{path}: {exc}") from exc
        if not isinstance(data, dict):
            raise ConfigError(f"{path}: expected a JSON object")
        mode = path.stat().st_mode & 0o7777
    new_lists = dict(data.get("listIds") or {})
    new_fields = dict(data.get("fields") or {})
    new_lists.update(lists)
    new_fields.update(fields)
    if new_lists == (data.get("listIds") or {}) and new_fields == (data.get("fields") or {}):
        return
    data["listIds"], data["fields"] = new_lists, new_fields
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".qa-tracker.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class _Init(_Sync):
    def __init__(self, ctx):
        tr = transport_for(ctx)
        _, _, folder_id = _ids(ctx)
        r = tr.request("GET", f"/v2/folder/{folder_id}")
        lists = {l["name"]: str(l["id"]) for l in r.get("lists") or []}
        super().__init__(ctx, Folder(lists=lists, tasks=[]))
        self.tr = tr
        self.manual = 0
        self.pending: List[Tuple[str, str]] = []
        self.found_lists: Dict[str, str] = {}
        self.found_fields: Dict[str, str] = {}

    def say(self, line: str) -> None:
        self.log.out.write(line + "\n")

    def need_manual(self, list_name: str, what: str) -> None:
        """Collected and printed by flush_manual, so a step missing from several lists is one
        folder-level step (ClickUp fields and statuses added on the folder reach every list)."""
        self.pending.append((list_name, what))

    def flush_manual(self) -> None:
        lists_per: Dict[str, List[str]] = {}
        for list_name, what in self.pending:
            lists_per.setdefault(what, []).append(list_name)
        done = set()
        for list_name, what in self.pending:
            if len(lists_per[what]) > 1:
                if what in done:
                    continue
                done.add(what)
                line = f"In the folder: {what}. Add it at folder level so every list gets it."
            else:
                line = f'In list "{list_name}": {what}'
            self.manual += 1
            self.log.counts["manual"] = self.manual
            self.say(f"MANUAL\t{self.manual}. {line}")
        self.pending = []

    def check_list(self, name: str, fields, views) -> None:
        lid = self.ensure_list(name)
        if lid.startswith("<skipped"):
            return
        if self.log.apply and lid.startswith("<new"):
            self.log.skip("list-missing", name)  # its create failed: no field or view steps yet
            return
        exists = _real(lid)
        if exists:
            self.found_lists[name] = lid
        # fields: GET /v2/list/{id}/field; a list that does not exist yet has none
        have: Dict[str, str] = {}
        if exists:
            for f in self.tr.request("GET", f"/v2/list/{lid}/field").get("fields") or []:
                have.setdefault(norm(f.get("name")), str(f["id"]))
        ids: Dict[str, str] = {}
        for fname, how in fields:
            fid = have.get(norm(fname))
            if fid:
                ids[fname] = fid
                self.found_fields[field_key(name, fname)] = fid
            else:
                how = how.replace('the "Bugs" list', f'the "{self.bugs_list}" list')
                self.need_manual(name, f'add custom field "{fname}" ({how})')
        # statuses: only checked on a list that exists
        if exists and name not in (self.runs_list, self.guide_list):
            want = self.cfg["statuses"]["bug" if name == self.bugs_list else "case"]
            live = {norm(st) for st in self.list_statuses(lid)}
            for st in want:
                if norm(st) not in live:
                    self.need_manual(name, f'add status "{st}"')
        # views: looked up by name in freshly read state
        existing = set()
        if exists:
            existing = {norm(v.get("name")) for v in self.tr.request("GET", f"/v2/list/{lid}/view").get("views") or []}
        for vname, grouping in views:
            if norm(vname) in existing:
                continue
            body = {"name": vname, "type": "list"}
            if isinstance(grouping, tuple):
                fid = ids.get(grouping[1])
                if not fid:
                    self.say(f"pending\t{name}: {vname} (needs field {grouping[1]})")
                    continue
                body["grouping"] = {"field": f"cf_{fid}", "dir": 1, "collapsed": [], "ignore": False}
            elif grouping:
                body["grouping"] = {"field": grouping, "dir": 1, "collapsed": [], "ignore": False}
            if not exists and self.log.apply:
                continue
            self.write("create-view", f"{name}: {vname}",
                       lambda lid=lid, body=body: self.tr.request("POST", f"/v2/list/{lid}/view", body))

    def run(self) -> None:
        lists_cfg = self.cfg.get("lists") or {}
        self.runs_list = lists_cfg.get("runs") or RUNS_LIST
        self.bugs_list = lists_cfg.get("bugs") or BUGS_LIST
        if self.ctx.catalog is not None:
            for area in self.ctx.catalog.areas:
                if not area.missing:
                    self.check_list(area.list, AREA_FIELDS, AREA_VIEWS)
        self.check_list(self.guide_list, [], [])
        self.check_list(self.runs_list, RUN_FIELDS, RUN_VIEWS)
        self.check_list(self.bugs_list, BUG_FIELDS, BUG_VIEWS)


def init(ctx) -> None:
    """Build the folder structure (lists, views), check fields and statuses, print the manual
    click steps, and write the ids found back into docs/agents/qa-tracker.json (only --apply)."""
    s = _Init(ctx)
    with _keep_cache(ctx):
        try:
            s.run()
        finally:
            s.flush_manual()
            if ctx.log.apply:
                _save_ids(ctx, s.found_lists, s.found_fields)


# ---------------------------------------------------------------- runs, results, bugs, retest


SEVERITY_PRIORITY = {"critical": 1, "high": 2, "medium": 3, "low": 4}  # P6
RETEST_PASSED = "passed"
RETEST_FAILING = "still failing"
# run-manifest.json keys per Runs field; the first non-empty one wins, none means left empty
# (Build comes from ctx.manifest_build: the version token only, as in the run label)
MANIFEST_KEYS = {
    "Environment": ("environment", "env"),
    "Language": ("language", "locale", "lang"),
}


def _status_of(t: dict) -> str:
    return str((t.get("status") or {}).get("status") or "").strip().lower()


def _is_closed(t: dict, closed: str) -> bool:
    """The bug is in the project's closed status, or in any status of ClickUp's closed type."""
    return same_status(_status_of(t), closed) or (t.get("status") or {}).get("type") == "closed"


def _bug_rows(run_dir: Path) -> List[dict]:
    path = Path(run_dir) / "bugs" / "bugs.json"
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RunError(f"{path}: cannot read bugs ({exc})") from exc
    rows = data if isinstance(data, list) else (data.get("bugs") or []) if isinstance(data, dict) else []
    return [r for r in rows if isinstance(r, dict)]


def _case_of(results: Dict[str, dict], criterion: Optional[str]) -> str:
    for case_id, entry in results.items():
        if any(c["id"] == criterion for c in entry["criteria"]):
            return case_id
    return ""


def bug_description(actual: str, expected: str, steps: List[str], note: Optional[str] = None) -> str:
    """Plain markdown: What happened / What should happen / Steps. No layer, evidence or ids (D7)."""
    parts = [note] if note else []
    parts.append(f"**What happened**\n{actual or 'Not recorded.'}")
    parts.append(f"**What should happen**\n{expected or 'Not recorded.'}")
    if steps:
        parts.append("**Steps**\n" + "\n".join(f"{i}. {s}" for i, s in enumerate(steps, 1)))
    return "\n\n".join(parts)


class _Mirror(_Sync):
    """push-run / push-results / push-bug / update-retest: mirror one run into the folder.

    Writes go through `write` (dry run logs only). Every string goes through `outbound` with
    source="generated". Bug statuses are never changed; a case status only moves `to test` →
    `testing`, and only with statusCeiling "testing". Nothing is deleted.
    """

    def __init__(self, ctx):
        super().__init__(ctx)
        self.run_dir = run_dir_for(ctx.project, getattr(ctx.args, "run", None))
        self.label = run_label(self.run_dir, ctx.args)
        self.results = case_results(self.run_dir)
        lists_cfg = self.cfg.get("lists") or {}
        self.runs_list = lists_cfg.get("runs") or RUNS_LIST
        self.bugs_list = lists_cfg.get("bugs") or BUGS_LIST
        self.field_defs: Dict[str, List[dict]] = {}
        self.missing_fields: set = set()
        self.missing_options: set = set()
        self.by_id = {str(t["id"]): t for t in self.folder.tasks}

    # -- ids

    def list_id(self, name: str) -> Optional[str]:
        """The list id from cfg listIds (written by init), else the live folder by name. An id that
        is not one of the live folder's lists is refused: the verb then does nothing."""
        lid = (self.cfg.get("listIds") or {}).get(name) or self.lists.get(name)
        if not lid or str(lid) not in {str(v) for v in self.lists.values()}:
            self.log.skip("list-missing", f"{name}: run tracker.sh init")
            return None
        return str(lid)

    def field_id(self, list_name: str, field_name: str) -> Optional[str]:
        key = field_key(list_name, field_name)
        fid = (self.cfg.get("fields") or {}).get(key)
        if not fid:
            if key not in self.missing_fields:
                self.missing_fields.add(key)
                self.log.skip("field-missing", f"{key}: run tracker.sh init")
            return None
        return str(fid)

    def option_id(self, lid: str, fid: str, name: str) -> Optional[str]:
        if lid not in self.field_defs:
            self.field_defs[lid] = self.tr.request("GET", f"/v2/list/{lid}/field").get("fields") or []
        for f in self.field_defs[lid]:
            if str(f.get("id")) == fid:
                for o in (f.get("type_config") or {}).get("options") or []:
                    if norm(o.get("name")) == norm(name):
                        return str(o["id"])
        if fid not in self.missing_options:
            self.missing_options.add(fid)
            self.log.skip("option-missing", f"{fid}: no option {name!r}")
        return None

    @staticmethod
    def live_field(t: dict, fid: str) -> Any:
        """The task's current value of field `fid`: an option id for a dropdown, task ids for a
        relationship, else the raw value."""
        for f in t.get("custom_fields") or []:
            if str(f.get("id")) != fid:
                continue
            v = f.get("value")
            if f.get("type") == "drop_down" and v is not None:
                for o in (f.get("type_config") or {}).get("options") or []:
                    if str(o.get("orderindex")) == str(v) or str(o.get("id")) == str(v):
                        return str(o["id"])
                return str(v)
            if isinstance(v, list):
                return [str(x.get("id")) if isinstance(x, dict) else str(x) for x in v]
            return v
        return None

    def set_field(self, t: dict, fid: str, value: Any, detail: str) -> bool:
        """POST /v2/task/{id}/field/{fid}; a no-op when the live value already matches."""
        live = self.live_field(t, fid)
        if isinstance(value, dict) and "add" in value:
            if set(value["add"]) <= set(live or []):
                return False
        elif live is not None and str(live) == str(value):
            return False
        self.write("set-field", detail, lambda: self.tr.request(
            "POST", f"/v2/task/{t['id']}/field/{fid}", {"value": value}))
        return True

    def comments(self, task_id: str) -> List[str]:
        """Comment texts of a task. Reads only the latest page (ClickUp returns the newest 25),
        enough to see a comment this tool added on a recent run."""
        if task_id.startswith("<"):
            return []
        r = self.tr.request("GET", f"/v2/task/{task_id}/comment")
        return [str(c.get("comment_text") or "").strip() for c in r.get("comments") or []]

    def say_comment(self, t: dict, text: str, detail: str) -> None:
        self.write("comment", detail, lambda: self.comment(t["id"], text))

    def tasks_in(self, lid: str) -> List[dict]:
        return [t for t in self.folder.tasks if str((t.get("list") or {}).get("id")) == lid]

    def reread(self, lid: str) -> List[dict]:
        """Fresh read of one list (closed included), for reconciling a create that may have landed."""
        out: List[dict] = []
        page = 0
        while True:
            got = self.tr.request("GET", f"/v2/list/{lid}/task?{TASK_QUERY}&page={page}").get("tasks") or []
            out += got
            if len(got) < 100:
                return out
            page += 1

    def safe_create(self, lid: str, body: dict, find: Callable[[List[dict]], Optional[dict]]) -> Callable[[], Any]:
        """A create that is never blindly retried: on a 5xx/network error it re-reads the list by
        visible identity and adopts the task if the create landed, else lets the error skip it."""
        def go():
            try:
                return self.tr.request("POST", f"/v2/list/{lid}/task", body)
            except ApiError as err:
                if not _maybe_landed(err):
                    raise
                found = find(self.reread(lid))
                if found is None:
                    raise
                self.log.act("reconciled", f"{body.get('name')}: the create had landed")
                return found
        return go

    def checked(self, kind: str, key: str, live: Optional[dict]) -> Optional[dict]:
        """Verify the cache against the live item: live wins; a stale cache id is reported."""
        entry = self.ctx.cache.get(kind, key)
        if entry and entry.get("id") and (live is None or str(entry["id"]) != str(live["id"])):
            self.log.act("stale-cache", f"{kind} {key}")
        return live

    def gen(self, item: str, value: str) -> Optional[str]:
        return self.text(item, value, source="generated")


# -- push-run


def _manifest_value(manifest: dict, field_name: str) -> Optional[str]:
    if field_name == "Build":
        return manifest_build(manifest) or None
    for k in MANIFEST_KEYS[field_name]:
        v = manifest.get(k)
        if isinstance(v, (str, int, float)) and str(v).strip():
            return str(v).strip()
    return None


def push_run(ctx) -> None:
    with _keep_cache(ctx):
        _push_run(ctx)


def _push_run(ctx) -> None:
    m = _Mirror(ctx)
    rid = m.list_id(m.runs_list)
    if rid is None:
        return
    name = m.gen(f"run {m.label}", f"Run {m.label}")
    if name is None:
        return
    matches = [t for t in m.tasks_in(rid) if t.get("name") == name]
    if len(matches) > 1:
        m.log.skip("duplicate", f"{name}: {', '.join(str(t['id']) for t in matches)}")
        return
    t = m.checked("run", m.label, matches[0] if matches else None)
    if t is None:
        r = m.write("create", f"{name} → {m.runs_list}", m.safe_create(
            rid, {"name": name}, lambda ts: next((x for x in ts if x.get("name") == name), None)))
        if ctx.log.apply and not (r and r.get("id")):
            return
        t = {"id": str(r["id"]) if r and r.get("id") else f"<new:{name}>", "name": name, "custom_fields": r.get("custom_fields") if r else []}
    if ctx.log.apply and not str(t["id"]).startswith("<"):
        ctx.cache.put("run", m.label, str(t["id"]), None)
    manifest = _manifest(m.run_dir)
    verdicts = [e["verdict"] for e in m.results.values()]
    values: List[Tuple[str, Any]] = []
    for fname in ("Build", "Environment", "Language"):
        v = _manifest_value(manifest, fname)
        if v is not None:
            values.append((fname, v))
    values += [("Passed", verdicts.count("pass")), ("Failed", verdicts.count("fail")),
               ("Blocked", verdicts.count("blocked"))]
    texts = []
    for fname, v in values:
        if isinstance(v, str):
            v = m.gen(f"{name} {fname}", v)
            if v is None:
                continue
        texts.append((fname, v))
    for fname, v in texts:
        fid = m.field_id(m.runs_list, fname)
        if fid:
            m.set_field(t, fid, v, f"{name}: {fname} = {v}")


# -- push-results


def push_results(ctx) -> None:
    with _keep_cache(ctx):
        _push_results(ctx)


def _push_results(ctx) -> None:
    m = _Mirror(ctx)
    ceiling = ctx.cfg.get("statusCeiling") == "testing"
    run_text = m.gen(f"run {m.label}", m.label)
    if run_text is None:
        return
    list_names = {v: k for k, v in m.lists.items()}
    for cid in sorted(m.results):
        entry = m.results[cid]
        verdict = entry["verdict"]
        if m.duplicate(cid):
            continue
        t = m.folder.by_tc.get(cid)
        if t is None:
            m.log.skip("no-task", f"{cid}: not in the folder yet (run push-plan)")
            continue
        lname = (t.get("list") or {}).get("name") or list_names.get(str((t.get("list") or {}).get("id")), "")
        lid = str((t.get("list") or {}).get("id"))
        n = len(entry["criteria"])
        comment = m.gen(cid, f"Checked on {m.label}: {verdict} ({n} checks).")
        if comment is None:
            continue
        rfid = m.field_id(lname, "Last check result")
        runfid = m.field_id(lname, "Last check run")
        opt = m.option_id(lid, rfid, verdict) if rfid else None
        # the previous result: the cache when it is about this very task, else the live field
        cached = ctx.cache.get("result", cid)
        if cached and str(cached.get("id")) == str(t["id"]):
            prev = cached.get("hash")
        else:
            prev = verdict if (opt is not None and m.live_field(t, rfid) == opt) else None
        commented = True
        if prev != verdict:
            commented = m.write("comment", f"{cid}: {verdict} ({n} checks)",
                                lambda t=t, c=comment: m.comment(t["id"], c) or True) is not None
        # the result field moves only with its comment, so a failed comment is redone next run
        if opt and (commented or not ctx.log.apply):
            m.set_field(t, rfid, opt, f"{cid}: Last check result = {verdict}")
        if runfid:
            m.set_field(t, runfid, run_text, f"{cid}: Last check run = {m.label}")
        if ceiling and same_status(_status_of(t), m.case_new):
            m.write("status", f"{cid}: {m.case_new} → {m.case_testing}", lambda t=t: m.tr.request(
                "PUT", f"/v2/task/{t['id']}", {"status": m.case_testing}))
        if ctx.log.apply and commented:  # a failed comment is retried next run
            ctx.cache.put("result", cid, str(t["id"]), verdict)


# -- push-bug


def push_bug(ctx) -> None:
    with _keep_cache(ctx):
        _push_bug(ctx)


def _push_bug(ctx) -> None:
    m = _Mirror(ctx)
    rows = _bug_rows(m.run_dir)
    if not rows:
        m.log.act("info", "no bugs to push")
        return
    bid = m.list_id(m.bugs_list)
    if bid is None:
        return
    ref_fid = m.field_id(m.bugs_list, "Ref")
    if ref_fid is None:
        m.log.skip("bugs", "without the Ref field a bug cannot be found again; nothing pushed")
        return
    sev_fid = m.field_id(m.bugs_list, "Severity")
    run_fid = m.field_id(m.bugs_list, "Found in run")
    case_fid = m.field_id(m.bugs_list, "Case")
    run_text = m.gen(f"run {m.label}", m.label)
    if run_text is None:
        return
    bugs = m.tasks_in(bid)
    done: set = set()
    for row in rows:
        if row.get("duplicateOf"):
            m.log.skip("duplicate-of", f"{row.get('title') or 'untitled'}: the export marks it a duplicate")
            continue
        criterion = str(row.get("criterionId") or row.get("criterion_id") or "")
        case_id = _case_of(m.results, criterion)
        ref = fingerprint(case_id or criterion or str(row.get("id") or ""),
                          str(row.get("persona") or ""), str(row.get("title") or ""))
        if ref in done:
            continue
        done.add(ref)
        raw_title = str(row.get("title") or "").strip()
        if not raw_title:
            m.log.skip("no-title", f"{ref}: the export row has no title")
            continue
        title = m.gen(ref, raw_title)
        actual = m.gen(ref, str(row.get("actual") or "").strip()) if title else None
        expected = m.gen(ref, str(row.get("expected") or "").strip()) if actual is not None else None
        steps = []
        if expected is not None:
            for s in row.get("steps") or []:
                s = m.gen(ref, str(s))
                if s is None:
                    steps = None
                    break
                steps.append(s)
        if not title or actual is None or expected is None or steps is None:
            continue
        matches = [t for t in bugs if str(m.live_field(t, ref_fid) or "") == ref]
        live_open = [t for t in matches if not _is_closed(t, m.bug_closed)]
        if len(live_open) > 1:
            m.log.skip("duplicate", f"{ref}: {', '.join(str(t['id']) for t in live_open)}")
            continue
        m.checked("bug", ref, live_open[0] if live_open else None)
        if live_open:
            t = live_open[0]
            if ctx.log.apply:
                ctx.cache.put("bug", ref, str(t["id"]), None)
            if run_fid and m.live_field(t, run_fid) == run_text:
                continue  # found in this very run
            text = m.gen(ref, f"Still happens on {m.label}.")
            if text is not None and text not in m.comments(str(t["id"])):
                m.say_comment(t, text, f"{ref}: still happens ({t.get('name')})")
            continue
        note = None
        if matches:
            note = m.gen(ref, f"Seen again after it was closed: {matches[0].get('name')}.")
            if note is None:
                continue
        desc = bug_description(actual, expected, steps, note)
        body: Dict[str, Any] = {"name": title, "markdown_content": desc, "status": m.bug_open}
        pri = SEVERITY_PRIORITY.get(str(row.get("severity") or "").lower())
        if pri:
            body["priority"] = pri
        # identity fields ride on the create itself, so a create that landed is findable by Ref
        fields = [{"id": ref_fid, "value": ref}]
        if run_fid:
            fields.append({"id": run_fid, "value": run_text})
        if sev_fid and row.get("severity"):
            opt = m.option_id(bid, sev_fid, str(row["severity"]).lower())
            if opt:
                fields.append({"id": sev_fid, "value": opt})
        body["custom_fields"] = fields

        def find(ts, ref=ref):
            return next((x for x in ts if str(m.live_field(x, ref_fid) or "") == ref
                         and not _is_closed(x, m.bug_closed)), None)
        kind = "create-again" if note else "create"
        r = m.write(kind, f"{ref}: {title}", m.safe_create(bid, body, find))
        if ctx.log.apply and not (r and r.get("id")):
            continue
        new = {"id": str(r["id"]) if r and r.get("id") else f"<new:{ref}>", "name": title,
               "custom_fields": r.get("custom_fields") if r else []}
        if ctx.log.apply:
            ctx.cache.put("bug", ref, new["id"], None)
        case_task = m.folder.by_tc.get(case_id) if case_id else None
        if case_task is None:
            m.log.skip("case-link", f"{ref}: no case task for {case_id or 'this check'}")
        elif case_fid:
            m.set_field(new, case_fid, {"add": [str(case_task["id"])], "rem": []},
                        f"{ref}: Case = {case_id}")


# -- update-retest


def update_retest(ctx) -> None:
    with _keep_cache(ctx):
        _update_retest(ctx)


def _update_retest(ctx) -> None:
    """Bugs in `retest`: when every linked case has a result in this run, set Retest result to
    passed (all pass) or still failing (any fail) and comment. Never changes a status."""
    m = _Mirror(ctx)
    bid = m.list_id(m.bugs_list)
    if bid is None:
        return
    case_fid = m.field_id(m.bugs_list, "Case")
    retest_fid = m.field_id(m.bugs_list, "Retest result")
    if case_fid is None or retest_fid is None:
        return
    for t in m.tasks_in(bid):
        if not same_status(_status_of(t), m.bug_retest):
            continue
        name = t.get("name") or t["id"]
        linked = m.live_field(t, case_fid) or []
        if not isinstance(linked, list) or not linked:
            m.log.skip("retest-no-case", f"{name}: no Case linked")
            continue
        cases, missing = [], []
        for tid in linked:
            mt = TC_RE.match((m.by_id.get(str(tid)) or {}).get("name") or "")
            if mt and mt.group(1) in m.results:
                cases.append(mt.group(1))
            else:
                missing.append(mt.group(1) if mt else str(tid))
        if missing:
            m.log.skip("retest-incomplete", f"{name}: no result in this run for {', '.join(missing)}")
            continue
        verdicts = {c: m.results[c]["verdict"] for c in cases}
        if all(v == "pass" for v in verdicts.values()):
            outcome = RETEST_PASSED
        elif any(v == "fail" for v in verdicts.values()) and \
                not any(v in ("error", "blocked", "deferred") for v in verdicts.values()):
            outcome = RETEST_FAILING
        else:
            detail = ", ".join(f"{c} {v}" for c, v in verdicts.items())
            m.log.skip("retest-inconclusive", f"{name}: {detail}")
            continue
        text = m.gen(str(t["id"]), f"Retest on {m.label}: {outcome}.")
        if text is None:
            continue
        opt = m.option_id(bid, retest_fid, outcome)
        if opt:
            m.set_field(t, retest_fid, opt, f"{name}: Retest result = {outcome}")
        if text not in m.comments(str(t["id"])):
            m.say_comment(t, text, f"{name}: {outcome}")
