"""ClickUp backend: push the catalog (and guide) into the QA folder, pull drafts back.

A generalised port of Innovation's `docs/qa/sync_clickup.py`. Dry run unless `--apply`.
Never deletes anything. Case status is only ever set to `skipped`, for retired or orphaned cases.

Remote identity is what a person sees (P2): a case is found by the `TC-… · ` prefix of its task
name, a list by name, the guide Doc by name, a page by name. `.qa/tracker-map.json` only caches
remote ids and the last-pushed description hash (used to tell a human edit from a catalog change).

The transport comes from `transport_for(ctx)`: `ctx.transport` or `ctx.args.transport` when set
(tests inject a fake there), else an `HttpTransport` with `CLICKUP_API_TOKEN`.
"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from trackers.clickup_api import ApiError, HttpTransport, Transport, token_from_env
from trackers.core import (ConfigError, WordingError, case_index, content_hash, norm,
                           outbound)

try:  # optional, only for writing pulled drafts as YAML
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None  # type: ignore

TC_RE = re.compile(r"^(TC-[A-Z]+-\d+) · ")
PRIORITY = {"P1": 1, "P2": 2, "P3": 3}  # urgent / high / normal
PRIORITY_BACK = {v: k for k, v in PRIORITY.items()}
STATUS_RETIRED = "skipped"
STATUS_NEW = "to test"
TAG_RETIRED = "retired"
LEVELS = {"beginner": "Beginner", "needs-setup": "Needs setup", "technical": "Technical"}
MANAGED_TAGS = {"beginner", "needs setup", "technical", "run last"}
DEFAULT_GUIDE_LIST = "00 – Guide & Sign-off"
GUIDE_DOC = "QA Guide"
GUIDE_TASK_PREFIX = "Guide · "
SIGNOFF_PREFIX = "Sign-off · "
GUIDE_RETIRED_COMMENT = 'This guide now lives in the "QA Guide" doc.'
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


# ---------------------------------------------------------------- live state


@dataclass
class Folder:
    lists: Dict[str, str]
    tasks: List[dict]
    by_tc: Dict[str, dict] = field(default_factory=dict)
    by_name: Dict[str, dict] = field(default_factory=dict)
    list_info: Dict[str, dict] = field(default_factory=dict)  # list id -> GET /v2/list/{id}


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
    for t in tasks:
        m = TC_RE.match(t.get("name") or "")
        if m and m.group(1) not in by_tc:
            by_tc[m.group(1)] = t
    by_name = {}
    for t in tasks:
        by_name.setdefault(t.get("name"), t)
    return Folder(lists=lists, tasks=tasks, by_tc=by_tc, by_name=by_name)


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


def intro_body(intro: dict, guide_list: str) -> str:
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
    parts.append(f"New to the platform? Read \"Guide · Start Here\" in the {guide_list} list first, then pick cases tagged beginner.")
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
                  pushed: Optional[str] = None) -> Callable[[], Any]:
        def go():
            self.tr.request("PUT", f"/v2/task/{t['id']}", body)
            if cache_key and pushed is not None:
                self.ctx.cache.put(CACHE_KIND, cache_key, t["id"], content_hash(pushed))
            if comment:
                self.comment(t["id"], comment)
            return True
        return go

    def create_fn(self, lid: str, body: dict, cache_key: Optional[str] = None) -> Callable[[], Any]:
        def go():
            r = self.tr.request("POST", f"/v2/list/{lid}/task", body)
            if cache_key and r and r.get("id"):
                self.ctx.cache.put(CACHE_KIND, cache_key, r["id"], content_hash(body["markdown_content"]))
            return r
        return go

    def move(self, t: dict, lid: str, detail: str) -> None:
        if lid.startswith("<"):
            return
        self.write("move", detail, lambda: self.tr.request(
            "PUT", f"/v3/workspaces/{self.ws}/tasks/{t['id']}/home_list/{lid}"))

    def retire(self, t: dict, label: str, detail: str, comment_text: str) -> None:
        """Tag `retired` + one comment (once), then status `skipped` when the list has it."""
        tagged = any(x.get("name") == TAG_RETIRED for x in t.get("tags") or [])
        if not tagged:
            text = self.text(label, comment_text, source="generated")
            if text is None:
                return
            def go(t=t, text=text):
                self.tr.request("POST", f"/v2/task/{t['id']}/tag/{TAG_RETIRED}")
                self.comment(t["id"], text)
            self.write("retire", detail, go)
        if (t.get("status") or {}).get("status") != STATUS_RETIRED:
            if STATUS_RETIRED in self.list_statuses(str(t["list"]["id"])):
                self.write("skip", label, lambda t=t: self.tr.request(
                    "PUT", f"/v2/task/{t['id']}", {"status": STATUS_RETIRED}))
            else:
                self.log.act("skip-pending", f"{label} (list has no '{STATUS_RETIRED}' status yet)")

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

    # -- areas

    def sync_intro(self, lid: str, list_name: str, intro: dict) -> None:
        body = self.text(f"intro {list_name}", intro_body(intro, self.guide_list))
        if body is None:
            return
        current = "" if lid.startswith("<") else self.get_list(lid).get("content", "") or ""
        if norm(current) != norm(body):
            self.write("intro", list_name, lambda: self.tr.request(
                "PUT", f"/v2/list/{lid}", {"markdown_content": body}))

    def sync_case(self, area, lid: str, case: dict) -> None:
        cid = case["id"]
        name = self.text(cid, f"{cid} · {case['title']}")
        desc = self.text(cid, describe(case)) if name is not None else None
        if name is None or desc is None:
            return
        want_tags = case_tags(case)
        t = self.folder.by_tc.get(cid)
        if case.get("retired"):
            if not t:
                return
            if str(t["list"]["id"]) != lid:
                self.move(t, lid, f"{cid}: {t['list'].get('name')} → {area.list}")
            if stale(t, desc) or t["name"] != name:
                if self.is_drift(cid, t, desc):
                    self.log.act("drift", cid)
                else:
                    self.write("update", f"{cid} [retired content]",
                               self.update_fn(t, {"name": name, "markdown_content": desc}, None, cid, desc))
            else:
                self.remember(cid, t, desc)
            self.retire(t, cid, f"{cid} ({area.list})",
                        f"Retired from the catalog on {self.today}: {case.get('retired_reason', '')}")
            return
        if not t:
            if lid.startswith("<skipped"):
                return
            body = {"name": name, "markdown_content": desc, "priority": PRIORITY[case["priority"]],
                    "status": STATUS_NEW, "tags": sorted(want_tags)}
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
            if {"title", "description"} & set(changed) and (t.get("status") or {}).get("status") != STATUS_NEW:
                comment = self.text(cid, f"Updated from the catalog on {self.today} — re-verify if already passed.",
                                    source="generated")
                if comment is None:
                    return
            self.write("update", f"{cid} [{','.join(changed)}]", self.update_fn(t, body, comment, cid, desc))
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

    def retire_orphans(self, catalog) -> None:
        known = case_index(catalog)
        for cid in sorted(self.folder.by_tc):
            if cid in known:
                continue
            t = self.folder.by_tc[cid]
            self.retire(t, cid, f"{cid} (orphan, {t['list'].get('name')})",
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
                self.write("update", name, self.update_fn(t, {"name": name, "markdown_content": sec}, None))

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
                self.write("update", name, self.update_fn(t, {"markdown_content": safe}, None))

    def find_doc(self) -> Optional[dict]:
        """The `QA Guide` Doc in the folder's space, by name (v3 Search for Docs, paginated)."""
        cursor = None
        while True:
            q = "deleted=false&archived=false&limit=100" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
            r = self.tr.request("GET", f"/v3/workspaces/{self.ws}/docs?{q}")
            for d in r.get("docs") or []:
                parent = d.get("parent") or {}
                in_space = not self.space or not parent.get("id") or str(parent.get("id")) == self.space
                if d.get("name") == GUIDE_DOC and in_space and not d.get("deleted") and not d.get("archived"):
                    return d
            cursor = r.get("next_cursor")
            if not cursor:
                return None

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
        doc = self.find_doc()
        doc_id = str(doc["id"]) if doc else None
        pages = self.doc_pages(doc_id) if doc_id else {}
        if not doc_id:
            r = self.write("doc-create", GUIDE_DOC, lambda: self.tr.request(
                "POST", f"/v3/workspaces/{self.ws}/docs",
                {"name": GUIDE_DOC, "parent": {"id": self.space, "type": 4}}))
            doc_id = str(r["id"]) if r and r.get("id") else None
        pushed: set = set()
        glid = None
        for fname, h1, body in files:
            if fname.startswith("07"):
                glid = self.ensure_list(self.guide_list)
                if not glid.startswith("<skipped"):
                    self.sync_signoff(glid, body)
                continue
            name = self.text(f"guide {fname}", h1)
            content = self.text(f"guide {fname}", body) if name is not None else None
            if name is None or content is None:
                continue
            pushed.add(h1)
            page = pages.get(name)
            if page is None:
                if self.log.apply and not doc_id:
                    self.log.skip("api-error", f"page {name}: the doc was not created")
                    continue
                self.write("page-create", name, lambda name=name, content=content: self.tr.request(
                    "POST", f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages",
                    {"name": name, "content": content, "content_format": "text/md"}))
            elif norm(page.get("content")) != norm(content):
                self.write("page-update", name, lambda page=page, name=name, content=content: self.tr.request(
                    "PUT", f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages/{page['id']}",
                    {"name": name, "content": content, "content_format": "text/md",
                     "content_edit_mode": "replace"}))
        # retire the old `Guide · …` tasks whose page is in the Doc (or being put there now)
        for t in self.folder.tasks:
            tname = t.get("name") or ""
            if not tname.startswith(GUIDE_TASK_PREFIX):
                continue
            if tname[len(GUIDE_TASK_PREFIX):] not in pushed:
                continue
            self.retire(t, tname, tname, GUIDE_RETIRED_COMMENT)


_FAILED = object()


def _push(ctx, folder: Optional[Folder] = None) -> "_Sync":
    if ctx.catalog is None:
        raise ConfigError("this verb needs a catalog")
    s = _Sync(ctx, folder)
    s.sync_areas(ctx.catalog)
    if not s.only:
        s.retire_orphans(ctx.catalog)
        if ctx.cfg.get("guideAs") == "doc":
            s.sync_guide_doc()
        else:
            s.sync_guide_tasks()
    return s


def push_plan(ctx) -> None:
    _push(ctx)
    if ctx.log.apply:
        ctx.cache.save()


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
