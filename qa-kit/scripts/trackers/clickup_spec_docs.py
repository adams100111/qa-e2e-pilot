"""`push-docs`, `spec-note` and `spec-status`: the Docs of a tracked spec, a note on its run, and
whether ClickUp is behind the local files (A5, A9).

`push-docs` writes the spec Doc (Overview, a Scenarios page with one page per card, a Results
page with one page per run that has a list) and the project's "QA overview" Doc in the QA folder.
The text of every page comes from `spec_docs`; nothing here words a result. A page is sent only
when its text is not what ClickUp holds now (read back and compared without layout), so a second
machine with no cache rewrites nothing. What a scenario did in each run and the latest run of
each spec are read from the tickets in ClickUp, so they are right on any machine; a Results page
needs the run's own files and is left as it is where they are not. A spec is shown as ready only
when its Run summary says so and every scenario ticket of that list stands passed (or skipped)
now, with none missing.

A run's Results page is the page remembered for its list number (`.qa/tracker-map.json`), else
the one page under Results whose name starts with `Run <N> · `: a changed label renames it. The
cache also keeps the text last written to a scenario page, which is what a retired page is
rebuilt from while ClickUp still holds that text.

`spec-note` adds one linted note as a comment on a Run summary ticket, once; `--blocked` also
moves that ticket to the blocked status the way a sync moves a ticket (`SpecSync.set_role`), so
the next sync reads it as the tool's own status and moves it on to the run's.

`spec-status` only reads: it prints one JSON line and nothing else (the CLI adds no summary line
to it) and runs the other verbs' own dry run against a log nobody sees to tell whether anything
would be written.

Dry run unless `--apply`. Nothing is deleted: the page of a scenario that left the plan stays and
says so, and a page under Scenarios that was not made here is left as it is. Links: the one
ClickUp returned (`url`), else the standard form built by `link_of` from ids that hold plain id
characters only. Every string sent passes the wording lint and the redaction; a page that does
not pass is not written and fails the step (a bug title that does not pass is shown as
`Open bug`). A person is mentioned only when `notify` names who, for a verified run (its folder
holds `verification.json` and the rendered `report.md`), once per run; every comment goes with
`notify_all: false`. A Doc or page create that may have landed is looked for again, by name and
parent, before anything is sent a second time.
"""
from __future__ import annotations

import io
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable, Dict, List, Optional

from trackers import cards, clickup, core, spec_docs, spec_runs, wording
from trackers.clickup import _is_closed, _keep_cache, _real, _status_of
from trackers.clickup_api import ApiError
from trackers.clickup_spec import OPEN, SUMMARY_ID, SpecSync, ref_key, remote_id, run_hash, save_spec
from trackers.clickup_spec_setup import FOLDER_PARENT_TYPE, _SpecInit
from trackers.clickup_spec_sync import RESULTS_PREFIX, REVIEW_FIELD, RunSync, _TICKED
from trackers.core import CONFIG_REL, ConfigError, WordingError, content_hash, same_status, status_name
from trackers.ctx import VERSION_RE, Ctx, run_dir_for

PAGES_QUERY = "max_page_depth=-1&content_format=text%2Fmd"
NOTIFY_ON = "verified"
NOTIFY_TEXT = "The results of {run} are ready to read."
NOT_KNOWN = "Not known"
# the two sentences `spec_docs.results_page` (and so the Run summary ticket) says a verdict with
SAID_READY, SAID_NOT_READY = "Ready to ship.", "Not ready to ship."
SEVERITY_OF_PRIORITY = {v: k for k, v in clickup.SEVERITY_PRIORITY.items()}
RUN_NOT_HERE = "its results are not on this machine; its page is left as it is"
NO_LINK = "ClickUp gave no link to the Results page; the Run summary has no link to it"
NOT_VERIFIED = "this run is not verified yet; no one was mentioned"
VERIFIED_FILES = ("verification.json", spec_runs.REPORT_NAME)   # what a verified run's folder holds
OPEN_BUG = "Open bug"            # shown in place of a bug title that does not pass the writing rules
BUG_TITLE = "a bug title does not follow the writing rules; the pages show it as Open bug"
NOT_OURS = "a page under Scenarios that was not made here; it is left as it is"
SCENARIO_MARK = "Results by run"  # a heading every scenario page the tool writes holds
DOC_CACHE = "spec-doc"           # .qa/tracker-map.json: `<target>:results:<n>` and `<target>:page:<page id>`
COMMENT_PAGE, COMMENT_PAGES = 25, 40   # ClickUp gives 25 comments a read; at most 1000 are looked through
LINK_BASE = "https://app.clickup.com"
LINK_FORMS = {"task": "{base}/t/{id}", "list": "{base}/{ws}/v/li/{id}", "folder": "{base}/{ws}/v/f/{id}",
              "doc": "{base}/{ws}/v/dc/{id}", "page": "{base}/{ws}/v/dc/{doc}/{id}"}
# spec-status: why ClickUp is behind, in plain phrases
R_NOT_SET_UP = "the spec is not set up in ClickUp yet"
R_CARDS_FILE = "the cards file cannot be read"
R_NO_LIST = "there is no run list yet"
R_CARDS = "the scenario tickets do not match the cards file"
R_RUN_NOT_SYNCED = "the newest run's results are not in ClickUp yet"
R_RESULTS = "the newest run's results differ from the tickets"
R_DOCS = "a Doc page is not up to date"
R_RUN_UNREADABLE = "the latest run could not be read"
# log lines that say something without standing for a write
INFO_KINDS = {"evidence-missing", "item-left", "bug-not-found", "bug-unlinked", "bugs-not-linked", "reconciled",
              "stale-cache", "info", "changed-by-person", "list-unused", "no-results", "run-not-here",
              "no-results-link", "not-verified", "bug-title", "page-not-ours"}


def page_norm(text: Optional[str]) -> str:
    """A page's text without its layout: letters and digits only, link targets included. ClickUp
    gives markdown back in its own layout, so only this is compared."""
    return re.sub(r"[\W_]+", "", text or "", flags=re.UNICODE).lower()


def plain_id(value: Any) -> Optional[str]:
    """`value` as an id that may stand in a link or a query: plain id characters only (the guard
    of `remote_id`), else None."""
    if value is None or isinstance(value, (bool, dict, list)) or str(value) == "":
        return None
    try:
        return remote_id(value, "id")
    except ConfigError:
        return None


def link_of(obj: Any, kind: Optional[str] = None, ws: Any = None, doc: Any = None) -> Optional[str]:
    """The link of a task, list, folder, Doc or page (`kind`): the `url` ClickUp returned with it,
    else ClickUp's standard form built from its id (`obj` is what ClickUp returned, or the id), the
    workspace id for all but a task, and the Doc's id for a page. Every id put in a link passes
    `plain_id`; None when one is missing or refused, or no `kind` is named."""
    url = obj.get("url") if isinstance(obj, dict) else None
    if isinstance(url, str) and url.startswith("https://"):
        return url
    form = LINK_FORMS.get(kind or "")
    if form is None:
        return None
    ids = {"id": plain_id(obj.get("id") if isinstance(obj, dict) else obj)}
    for name, value in (("ws", ws), ("doc", doc)):
        if "{" + name + "}" in form:
            ids[name] = plain_id(value)
    return None if None in ids.values() else form.format(base=LINK_BASE, **ids)


def verified(run_dir: Path) -> bool:
    """The run was verified and its report rendered: its folder holds both files."""
    return all((Path(run_dir) / name).is_file() for name in VERIFIED_FILES)


def save_overview_doc(ctx, doc_id: str) -> bool:
    """Write `ids.overviewDoc` to docs/agents/qa-tracker.json, the way `save_spec` writes a
    spec's ids: every other key, the key order and the file mode are kept; the write is atomic.
    False when it is already there (the file is then not written)."""
    path = Path(ctx.project) / CONFIG_REL
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.setdefault("ids", {}), dict):
        raise ConfigError(f"{path}: ids must be an object")
    if data["ids"].get("overviewDoc") == doc_id:
        return False
    data["ids"]["overviewDoc"] = doc_id
    mode = path.stat().st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(prefix=".qa-tracker.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return True


def notify_user(cfg: dict) -> Optional[int]:
    """The user id `notify` names for a verified run, or None when no one is to be mentioned.
    Anything else than `{"user": <id>, "on": "verified"}` (or nothing) is refused, never guessed."""
    notify = cfg.get("notify")
    if notify is None:
        return None
    user = notify.get("user") if isinstance(notify, dict) else None
    if isinstance(user, str) and user.isdigit():
        user = int(user)
    if isinstance(user, bool) or not isinstance(user, int) or notify.get("on") != NOTIFY_ON:
        raise ConfigError(f'notify must be {{"user": <ClickUp user id>, "on": "{NOTIFY_ON}"}}')
    return user


class DocSync(SpecSync):
    """The spec's Doc, the project's Doc and the Run summary notes of one spec."""

    bugs_home = RunSync.bugs_home    # (Bugs list id, its Ref field id), or None
    find_docs = _SpecInit.find_docs  # the Docs with this name in this folder

    def __init__(self, ctx, c: Optional[cards.Cards] = None):
        super().__init__(ctx, c)
        self._pages: Dict[str, List[dict]] = {}
        self._folder: Optional[dict] = None
        self._lists: Optional[List[dict]] = None
        self._open_bugs: Optional[List[dict]] = None
        self._versions: set = set()
        self._lint_cfg: Optional[core.Config] = None
        self._runs: Optional[Dict[str, Path]] = None
        self._no_link = False
        self._bug_title_said = False

    # -- text

    def allow(self, label: str) -> None:
        """Let the build number of a run label through the lint, as a sync does for the list's
        name: it is the version the reader knows the build by, not an internal id."""
        found = {w.rstrip(".") for w in re.split(r"[\s()]+", label or "")
                 if VERSION_RE.match(w) and ("." in w or w[:1] == "v")}
        if not found <= self._versions:
            self._versions |= found
            self._lint_cfg = None

    def page_rules(self) -> core.Config:
        """The settings a page is linted with: the project's, plus the build numbers let through."""
        if self._lint_cfg is None:
            cfg = core.Config(self.cfg)
            cfg.project = getattr(self.cfg, "project", None)
            rules = dict(cfg.get("wording") or {})
            rules["allow"] = list(rules.get("allow") or []) + sorted(self._versions)
            cfg["wording"] = rules
            self._lint_cfg = cfg
        return self._lint_cfg

    def lint(self, item: str, value: str) -> Optional[str]:
        """`wording.clean` for a page's name or text; None after the skip is logged."""
        try:
            return wording.clean(value, "body", self.page_rules())
        except WordingError as err:
            self.log.skip("wording", f"{item}: {err.word}")
            return None

    def link(self, obj: Any, kind: str, doc: Any = None) -> Optional[str]:
        """`link_of` in this workspace."""
        return link_of(obj, kind, self.ws, doc)

    def recent(self, task_id: str) -> List[str]:
        """The ticket's comment texts, newest first. ClickUp gives the newest 25; older ones are
        asked for with the `date` and `id` of the last one read, up to `COMMENT_PAGES` reads."""
        if not _real(task_id):
            return []
        path = f"/v2/task/{task_id}/comment"
        page = list(self.tr.request("GET", path).get("comments") or [])
        rows, seen = list(page), {str(c.get("id")) for c in page}
        for _ in range(COMMENT_PAGES - 1):
            if len(page) < COMMENT_PAGE:
                break
            start, start_id = str(page[-1].get("date") or ""), plain_id(page[-1].get("id"))
            if not start.isdigit() or start_id is None:
                break
            older = self.tr.request("GET", f"{path}?start={start}&start_id={start_id}").get("comments") or []
            page = [c for c in older if str(c.get("id")) not in seen]
            if not page:
                break
            seen |= {str(c.get("id")) for c in page}
            rows += page
        if all(str(c.get("date") or "").isdigit() for c in rows):
            rows = sorted(rows, key=lambda c: int(c["date"]), reverse=True)
        return [str(c.get("comment_text") or "").strip() for c in rows]

    # -- what this machine wrote last (.qa/tracker-map.json; only a cache)

    def remembered(self, key: str) -> Optional[dict]:
        return self.ctx.cache.get(DOC_CACHE, f"{self.target}:{key}")

    def remember_page(self, key: str, page: Optional[dict], keep_text: bool = False) -> None:
        """Remember a page just written or found up to date: its id, and with `keep_text` the text
        the tool wrote. Under `--apply` only: a dry run and `spec-status` leave the cache alone."""
        text = (page or {}).get("sent")
        if not self.log.apply or page is None or text is None or not _real(page["id"]):
            return
        entry = {"id": page["id"], "hash": content_hash(text)}
        if keep_text:
            entry["text"] = text
        self.ctx.cache.bucket(DOC_CACHE)[f"{self.target}:{key}"] = entry

    # -- reading the spec's lists and tickets

    def folder_info(self) -> dict:
        if self._folder is None:
            self._folder = self.tr.request("GET", f"/v2/folder/{self.spec_folder}")
        return self._folder

    def folder_lists(self) -> List[dict]:
        """As `SpecSync.folder_lists`, plus the archived lists (marked): what a scenario did in a
        run stays in its history after the run's list was archived. Read once."""
        if self._lists is not None:
            return self._lists
        out = [{"id": str(l["id"]), "name": l.get("name") or ""} for l in self.folder_info().get("lists") or []]
        if self.pasted and self.pasted not in {l["id"] for l in out}:
            out.append({"id": self.pasted, "name": self.get_list(self.pasted).get("name") or ""})
        try:
            rows = self.tr.request("GET", f"/v2/folder/{self.spec_folder}/list?archived=true").get("lists") or []
        except ApiError as err:
            if err.status in (401, 403) or not 400 <= err.status < 500:
                raise
            rows = []
        have = {l["id"] for l in out}
        self._lists = out + [{"id": str(l["id"]), "name": l.get("name") or "", "archived": True}
                             for l in rows if str(l["id"]) not in have]
        return self._lists

    def bound(self) -> List[dict]:
        """The run lists a run is tied to, oldest first."""
        return [e for e in self.run_lists() if e["run"] != OPEN and e["summary"] is not None]

    def run_name(self, entry: dict) -> str:
        """What a run is called on a page: `Run <N> · <label>`."""
        return f"Run {entry['n']} · {self.label_of(entry)}"

    def shown(self, t: dict) -> Optional[str]:
        """The status role a ticket shows: the one the tool left it in, else the role of the
        status a person gave it; None for a status that is none of the project's six."""
        role = self.standing(t)
        if role is None:
            live = _status_of(t)
            role = next((r for r in core.CASE_ROLES if same_status(live, status_name(self.cfg, "case", r))), None)
        return role

    def ticket_links(self, list_id: str) -> Dict[str, str]:
        """As `SpecSync.ticket_links`, with the standard link where ClickUp returned none."""
        n = next((e["n"] for e in self.run_lists() if e["id"] == list_id), None)
        if n is None:
            return {}
        have = self.tickets(list_id)
        out = {}
        for card in self.cards.cards:
            url = self.link(have.get(ref_key(self.target, n, "card", card.id)), "task")
            if url:
                out[card.id] = url
        return out

    def local_run(self, entry: dict) -> Optional[Path]:
        """The folder of the run a list is tied to, when that run was made on this machine."""
        if self._runs is None:
            root = Path(self.ctx.project) / ".qa" / "runs"
            self._runs = {run_hash(d.name): d for d in sorted(root.iterdir()) if d.is_dir()} if root.is_dir() else {}
        return self._runs.get(entry["run"])

    # -- bugs (the project's Bugs list; decision P10)

    def open_bugs(self) -> List[dict]:
        """The open bugs of the Bugs list that carry a `Ref`, as push-bug files them; none when
        the project keeps its bugs in its issue tracker or the list is not set up."""
        if self._open_bugs is None:
            self._open_bugs = []
            home = None if self.cfg.get("bugsTo") == "issue-tracker" else self.bugs_home()
            if home is not None:
                bid, self._bug_ref = home
                closed = status_name(self.cfg, "bug", "closed")
                self._open_bugs = [b for b in self.reread(bid)
                                   if self.live_field(b, self._bug_ref) and not _is_closed(b, closed)]
        return self._open_bugs

    def bug_row(self, b: dict) -> dict:
        severity = ""
        name = (self.cfg.get("lists") or {}).get("bugs") or clickup.BUGS_LIST
        fid = str((self.cfg.get("fields") or {}).get(clickup.field_key(name, "Severity")) or "")
        for f in b.get("custom_fields") or []:
            if fid and str(f.get("id")) == fid and f.get("value") is not None:
                for o in (f.get("type_config") or {}).get("options") or []:
                    if str(f["value"]) in (str(o.get("orderindex")), str(o.get("id"))):
                        severity = str(o.get("name") or "")
        priority = str((b.get("priority") or {}).get("id") or "")
        if not severity and priority.isdigit():
            severity = SEVERITY_OF_PRIORITY.get(int(priority), "")
        title = b.get("name") or ""
        try:
            wording.clean(title, "body", self.page_rules())
        except WordingError:
            # a bug is filed under weaker rules than a page is written with: its title must not
            # keep a page from being written, and is not put on one
            title = OPEN_BUG
            if not self._bug_title_said:
                self._bug_title_said = True
                self.left("bug-title", BUG_TITLE)
        return {"title": title, "severity": severity, "url": self.link(b, "task")}

    def run_bugs(self, run_dir: Path) -> List[dict]:
        """The open bugs of one run: its exported bugs, found in the Bugs list by the `Ref`
        fingerprint push-bug wrote (the way a sync finds them to link)."""
        if self.cfg.get("bugsTo") == "issue-tracker":
            return []
        rows = [r for r in clickup._bug_rows(run_dir) if not r.get("duplicateOf")]
        if not rows or not self.open_bugs():
            return []
        results = core.case_results(run_dir)
        marks = set()
        for r in rows:
            criterion = str(r.get("criterionId") or r.get("criterion_id") or "")
            title = str(r.get("title") or "").strip()
            if title:
                marks.add(core.fingerprint(clickup._case_of(results, criterion) or criterion or str(r.get("id") or ""),
                                           str(r.get("persona") or ""), title))
        return [self.bug_row(b) for b in self.open_bugs() if str(self.live_field(b, self._bug_ref)) in marks]

    # -- Docs and pages

    def read_pages(self, doc_id: str) -> List[dict]:
        """Every page of a Doc, read once: `{"id", "name", "content", "parent", "url"}`."""
        if not _real(doc_id):
            return []
        if doc_id not in self._pages:
            r = self.tr.request("GET", f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages?{PAGES_QUERY}")
            out: List[dict] = []

            def walk(items, parent):
                for p in items or []:
                    out.append({"id": str(p.get("id")), "name": p.get("name") or "", "content": p.get("content") or "",
                                "parent": str(p["parent_page_id"]) if p.get("parent_page_id") else parent,
                                "url": self.link(p, "page", doc_id)})
                    walk(p.get("pages"), str(p.get("id")))
            walk(r if isinstance(r, list) else (r.get("pages") or []), None)
            self._pages[doc_id] = out
        return self._pages[doc_id]

    def page(self, doc_id: str, name: str, content: Optional[str], parent: Optional[str] = None,
             first: bool = False, known: Optional[Callable[[], Optional[dict]]] = None) -> Optional[dict]:
        """Make a page say `content` (None: a page that only holds others, its text is left).
        Found by name under its parent, else it is the page `known` gives (which then takes this
        name); `first` lets the empty page ClickUp makes with a new Doc become this one. Sent only
        when its name or text differs from what ClickUp holds. Returns the page (`sent` is the
        text it was given), or None when it could not be written (reported)."""
        safe = self.lint(f"page {name}", name)
        text = self.lint(f"page {name}", content) if safe is not None and content is not None else content
        if safe is None or (content is not None and text is None):
            return None
        if parent is not None and not _real(parent) and self.log.apply:
            return None  # its parent page could not be made, and that is reported
        path = f"/v3/workspaces/{self.ws}/docs/{doc_id}/pages"

        def find():
            return next((p for p in self.read_pages(doc_id) if p["name"] == safe and p["parent"] == parent), None)
        found = find()
        if found is None and known is not None:
            found = known()
        if found is None and first:
            found = next((p for p in self.read_pages(doc_id)
                          if p["parent"] is None and not p["name"].strip() and not p["content"].strip()), None)
        if found is None:
            body: Dict[str, Any] = {"name": safe, "content": text or "", "content_format": "text/md"}
            if parent is not None:
                body["parent_page_id"] = parent

            def landed():
                self._pages.pop(doc_id, None)
                return find()
            r = self.write("page-create", safe, self._landed(lambda: self.tr.request("POST", path, body), landed, safe))
            if not (r and r.get("id")):
                return None if self.log.apply else {"id": f"<new:{safe}>", "name": safe, "parent": parent, "url": None,
                                                    "sent": text}
            made = find()
            if made is None or made["id"] != str(r["id"]):
                made = {"id": str(r["id"]), "name": safe, "content": text or "", "parent": parent,
                        "url": self.link(r, "page", doc_id)}
                self.read_pages(doc_id).append(made)
            made["sent"] = text
            return made
        if text is not None and (found["name"] != safe or page_norm(found["content"]) != page_norm(text)):
            body = {"name": safe, "content": text, "content_format": "text/md", "content_edit_mode": "replace"}
            done = self.write("page-update", safe, lambda: self.tr.request("PUT", f"{path}/{found['id']}", body) or True)
            if not done and self.log.apply:
                return None
            found.update(name=safe, content=text)
        found["sent"] = text
        return found

    def ensure_doc(self, title: str, parent: str, saved: str, save: Callable[[str], Any]) -> Optional[str]:
        """The id of the Doc named `title` in folder `parent`: the one there by name, else a new
        one; its id is saved as `saved`. None when there are two, or the create failed."""
        name = self.lint(f"doc {title}", title)
        if name is None:
            return None
        docs = self.find_docs(name, parent)
        if len(docs) > 1:
            self.log.skip("doc-ambiguous", f"{name}: {len(docs)} docs with this name; set {saved}")
            return None
        doc = docs[0] if docs else None
        if doc is None:
            def landed():
                again = self.find_docs(name, parent)
                return again[0] if len(again) == 1 else None
            doc = self.write("doc-create", name, self._landed(lambda: self.tr.request(
                "POST", f"/v3/workspaces/{self.ws}/docs",
                {"name": name, "parent": {"id": parent, "type": FOLDER_PARENT_TYPE}}), landed, name))
            if not (doc and doc.get("id")):
                return None if self.log.apply else f"<new:{name}>"
        doc_id = str(doc["id"])
        self.log.act("save-config", saved, lambda: save(doc_id))
        return doc_id

    def spec_doc(self) -> Optional[str]:
        """The spec's Doc: `specs.<target>.doc` (spec-init saves it), else found or made."""
        if self.cfg.get("doc"):
            return remote_id(self.cfg["doc"], f"specs.{self.target}.doc")
        return self.ensure_doc(self.title, self.spec_folder, f"specs.{self.target}.doc",
                               lambda doc_id: save_spec(self.ctx, self.target, {"doc": doc_id}, {}))

    def project_doc(self) -> Optional[str]:
        """The project's "QA overview" Doc in the QA folder: `ids.overviewDoc`, else found or
        made on first use."""
        known = (self.cfg.get("ids") or {}).get("overviewDoc")
        if known:
            return remote_id(known, "ids.overviewDoc")
        return self.ensure_doc(spec_docs.PROJECT_DOC, self.folder_id, "ids.overviewDoc",
                               lambda doc_id: save_overview_doc(self.ctx, doc_id))

    def doc_link(self) -> Optional[str]:
        """The link of the spec's Doc: the one ClickUp gives with it, else the standard one."""
        doc = self.cfg.get("doc")
        if not doc:
            return None
        doc = remote_id(doc, f"specs.{self.target}.doc")
        try:
            return self.link(dict(self.tr.request("GET", f"/v3/workspaces/{self.ws}/docs/{doc}") or {}, id=doc), "doc")
        except ApiError as err:
            if err.status in (401, 403) or not 400 <= err.status < 500:
                raise
            return self.link(doc, "doc")

    # -- the spec Doc

    def history(self, card: cards.Card) -> List[dict]:
        """A card's result in every run that has a list, from its ticket there (oldest first)."""
        out = []
        for e in self.bound():
            t = self.tickets(e["id"]).get(ref_key(self.target, e["n"], "card", card.id))
            if t is not None:
                out.append({"run": self.run_name(e), "result": self.shown(t)})
        return out

    def scenario_pages(self, doc_id: str, parent: Optional[dict]) -> None:
        if parent is None:
            return
        names = set()
        for card in self.cards.cards:
            if card.title in names:
                self.log.skip("page-name", f"{card.title}: two scenarios have this title; one page cannot hold both")
                continue
            names.add(card.title)
            page = self.page(doc_id, card.title, spec_docs.scenario_page(card, self.history(card), self.cfg),
                             parent["id"])
            if page is not None:
                names.add(page["name"])
                self.remember_page(f"page:{page['id']}", page, keep_text=True)
        mark = page_norm(spec_docs.RETIRED)
        for p in list(self.read_pages(doc_id)):
            if p["parent"] != parent["id"] or p["name"] in names:
                continue
            held = page_norm(p["content"])
            if held.startswith(mark):
                continue  # said already
            last = self.remembered(f"page:{p['id']}")
            ours = last is not None and str(last.get("id")) == p["id"]
            if not ours and not (held.startswith(page_norm(p["name"])) and page_norm(SCENARIO_MARK) in held):
                # neither remembered nor in the shape of a scenario page: a person's page
                self.left("page-not-ours", f"{core.redact(p['name'], self.cfg)}: {NOT_OURS}")
                continue
            # the page of a scenario that left the plan stays and says so: the text the tool wrote
            # last while ClickUp still holds it (in its own layout), else what ClickUp holds now
            text = last.get("text") if ours else None
            if not isinstance(text, str) or page_norm(text) != held:
                text = p["content"]
            self.page(doc_id, p["name"], f"{spec_docs.RETIRED}\n\n{text.rstrip()}\n", parent["id"])

    def results_page(self, doc_id: str, parent: Optional[dict], entry: dict) -> Optional[dict]:
        """The Results page of one run, from its own files; None where they are not here."""
        name = self.run_name(entry)
        run_dir = self.local_run(entry)
        try:
            states = spec_runs.states(run_dir, self.cards, self.cfg) if run_dir is not None else None
        except core.RunError:
            states = None
        if states is None:
            self.left("run-not-here", f"{name}: {RUN_NOT_HERE}")
            return None
        if parent is None:
            return None
        text = spec_docs.results_page(name, states, self.cards, self.ticket_links(entry["id"]), self.run_bugs(run_dir),
                                      spec_runs.ready(run_dir), self.cfg.get("reportUrl") or None, self.cfg)
        key = f"results:{entry['n']}"
        page = self.page(doc_id, name, text, parent["id"], known=lambda: self.run_page(doc_id, parent["id"], entry["n"], key))
        self.remember_page(key, page)
        return page

    def run_page(self, doc_id: str, parent: str, n: int, key: str) -> Optional[dict]:
        """The Results page of run list `n` when none has the run's name now (its label changed):
        the page remembered for it, else the one whose name starts with `Run <N> · ` (the first,
        should there be several). The caller gives it the new name."""
        under = [p for p in self.read_pages(doc_id) if p["parent"] == parent]
        last = self.remembered(key)
        if last is not None:
            found = next((p for p in under if p["id"] == str(last.get("id"))), None)
            if found is not None:
                return found
        return next((p for p in under if p["name"].startswith(f"Run {n} · ")), None)

    def link_results(self, entry: dict, page: dict) -> None:
        """The `Full results:` line of the run's summary ticket (every sync keeps it)."""
        if not _real(page["id"]):
            return
        url = page.get("url")
        if not url:
            self._no_link = True
            return
        line = self.clean("run summary", f"{RESULTS_PREFIX} {url}")
        if line is None:
            return
        t = entry["summary"]
        live = t.get("markdown_description") or ""
        if line in live.splitlines():
            return
        rest = "\n".join(ln for ln in live.splitlines() if not ln.startswith(RESULTS_PREFIX)).rstrip()
        desc = f"{rest}\n\n{line}" if rest else line

        def go():
            self.tr.request("PUT", f"/v2/task/{t['id']}", {"markdown_content": desc})
            return True
        if self.write("update", f"{t.get('name') or ''} [results link]", go) or not self.log.apply:
            t["markdown_description"] = desc

    def spec_pages(self, doc_id: str) -> None:
        entries = self.bound()
        for e in entries:
            self.allow(self.label_of(e))
        self.page(doc_id, spec_docs.PAGE_OVERVIEW, spec_docs.overview_page(self.cards), first=True)
        self.scenario_pages(doc_id, self.page(doc_id, spec_docs.PAGE_SCENARIOS, None))
        results = self.page(doc_id, spec_docs.PAGE_RESULTS, None)
        for e in entries:
            page = self.results_page(doc_id, results, e)
            if page is not None and not e.get("archived"):
                self.link_results(e, page)
        if self._no_link:
            self.left("no-results-link", NO_LINK)

    # -- the project Doc

    def row(self) -> dict:
        """This spec's row of the project page, from ClickUp: its newest run that has a list,
        how many scenario tickets stand in each status, and what its Run summary says."""
        out: Dict[str, Any] = {"title": self.title,
                               "url": self.doc_link() or self.link(self.folder_info(), "folder"),
                               "latestRun": None, "counts": {}, "ready": None}
        entries = self.bound()
        if not entries:
            return out
        e = entries[-1]
        counts = dict({r: 0 for r in core.CASE_ROLES}, needs_review=0)
        review = self.fid(REVIEW_FIELD)
        have = set()
        for t in self.list_tasks(e["id"]):
            p = self.ref_of(t)
            if p is None:
                continue
            if review and self.live_field(t, review) in _TICKED:
                counts["needs_review"] += 1
            if p["run"] is None and not t.get("parent"):  # a scenario ticket: not the summary, not a check
                counts[self.shown(t) or "to_test"] += 1
                have.add(p["key"])
        # a scenario of the cards file with no ticket in the list (a fill that stopped half way)
        # is still to be tested: it is counted, so a half-filled list never reads as complete
        try:
            missing: Optional[int] = sum(1 for card in self.cards.cards
                                         if ref_key(self.target, e["n"], "card", card.id) not in have)
        except (cards.CardsError, OSError):
            missing = None  # the cards are not on this machine: whether the list is whole is not known
        counts["to_test"] += missing or 0
        said = [ln.strip() for ln in (e["summary"].get("markdown_description") or "").splitlines()]
        ready = False if SAID_NOT_READY in said else True if SAID_READY in said else None
        # the summary's word is as old as the last sync; the tickets are read now. Ready stands
        # only while every scenario ticket stands passed (or skipped), at least one passed, and no
        # result waits for a person's review.
        if missing:
            ready = None
        elif ready is True and missing is None:
            ready = None
        elif ready is True and (any(counts[k] for k in ("to_test", "testing", "failed", "blocked", "needs_review"))
                                or not counts["passed"]):
            ready = False
        out.update(latestRun=self.run_name(e), counts=counts, ready=ready)
        return out

    def project_rows(self) -> List[dict]:
        """A row for every spec that has a folder, a list or a layout under `specs`. One whose
        data cannot be read is listed as not known; it does not fail the page."""
        base = core.load_config(self.ctx.project)
        rows = []
        for target in sorted(t for t, e in (base.get("specs") or {}).items()
                             if isinstance(e, dict) and (e.get("folder") or e.get("list") or e.get("layout"))):
            title = None
            try:
                if target == self.target:
                    s = self
                else:
                    args = SimpleNamespace(**dict(vars(self.ctx.args), spec=target, run=None, overwrite=[]))
                    s = DocSync(Ctx(project=self.ctx.project, cfg=core.spec_settings(base, target), catalog=None,
                                    log=self.log, cache=self.ctx.cache, args=args))
                title = s.title
                row = s.row()
            except (ApiError, ConfigError, cards.CardsError, core.RunError, OSError) as err:
                if isinstance(err, ApiError) and err.status in (401, 403) and target == self.target:
                    raise
                words = re.sub(r"[-_.]+", " ", target).strip()
                row = {"title": title or words[:1].upper() + words[1:], "url": None, "latestRun": NOT_KNOWN,
                       "counts": {}, "ready": None}
            if row.get("latestRun") and row["latestRun"] != NOT_KNOWN:
                self.allow(row["latestRun"])
            rows.append(row)
        return rows

    def project_page(self) -> None:
        doc_id = self.project_doc()
        if doc_id is None:
            return
        text = spec_docs.project_page(self.project_rows(), [self.bug_row(b) for b in self.open_bugs()], self.cfg)
        self.page(doc_id, spec_docs.PROJECT_DOC, text, first=True)

    # -- the verbs

    def run_entry(self, run_id: str) -> Optional[dict]:
        """The list a named run is tied to; None after the skip is logged."""
        entry = next((e for e in self.bound() if e["run"] == run_hash(run_id)), None)
        if entry is None:
            self.log.skip("run-not-synced", "this run has no list in ClickUp yet; run sync-run first")
        return entry

    def push(self) -> None:
        doc_id = self.spec_doc()
        if doc_id is not None:
            self.spec_pages(doc_id)
        self.project_page()

    def notify(self, entry: dict, user: int) -> None:
        """One comment that mentions `user` on the run's summary ticket, once per run."""
        name = self.run_name(entry)
        self.allow(self.label_of(entry))
        text = self.lint("notify", NOTIFY_TEXT.format(run=name))
        tid = str(entry["summary"]["id"])
        if text is None or any(row.startswith(text) for row in self.recent(tid)):
            return
        body = {"comment": [{"text": f"{text} "}, {"type": "tag", "user": {"id": user}}], "notify_all": False}
        self.write("notify", name, lambda: self.tr.request("POST", f"/v2/task/{tid}/comment", body) or True)

    def note_entry(self, run_id: Optional[str]) -> Optional[dict]:
        """The list whose Run summary takes a note: the named run's, else the open list, else
        the newest one. None after the skip is logged."""
        if run_id:
            return self.run_entry(run_id)
        live = [e for e in self.run_lists() if e["summary"] is not None and not e.get("archived")]
        entry = next((e for e in reversed(live) if e["run"] == OPEN), live[-1] if live else None)
        if entry is None:
            self.log.skip("no-run-summary", "there is no Run summary ticket yet; run push-scenarios first")
        return entry


def push_docs(ctx) -> None:
    """`tracker.sh push-docs [--run <id>]`: the spec's Doc and the project's Doc. With `--run`
    the run must have its list; `notify`, when set, mentions its person once, and only for a run
    that was verified (`verified`). One that is not is said in a line that is not a failure."""
    run_id = getattr(ctx.args, "run", None)
    # a run that is not there is an error, before anything is sent
    run_dir = run_dir_for(ctx.project, run_id) if run_id else None
    user = notify_user(ctx.cfg)
    s = DocSync(ctx, cards.load(ctx.project, ctx.args.spec))
    if not s.ready():
        return
    entry = s.run_entry(run_id) if run_id else None
    if run_id and entry is None:
        return
    with _keep_cache(ctx):
        s.push()
    if entry is None or user is None:
        return
    if not verified(run_dir):
        s.left("not-verified", f"{s.run_name(entry)}: {NOT_VERIFIED}")
    elif not ctx.log.counts.get("skip"):
        s.notify(entry, user)


def spec_note(ctx) -> None:
    """`tracker.sh spec-note --file <path> [--blocked] [--run <id>]`: the file's text as one
    comment on a Run summary ticket, not posted twice; `--blocked` also sets that ticket to the
    blocked status. A text that breaks the writing rules stops it before ClickUp is contacted."""
    path = getattr(ctx.args, "file", None)
    if not path:
        raise core.RunError("spec-note needs --file <path>")
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except ValueError as exc:
        raise core.RunError("the note file is not text") from exc
    s = DocSync(ctx)
    text = s.clean("note", raw.strip())
    if text is None or not s.ready():
        return
    entry = s.note_entry(getattr(ctx.args, "run", None))
    if entry is None:
        return
    t = entry["summary"]
    title = t.get("name") or ""
    if core.norm(text) not in {core.norm(row) for row in s.recent(str(t["id"]))}:
        s.say_comment(t, text, f"{title}: note")  # notify_all: false
    if getattr(ctx.args, "blocked", False):
        s.set_role(t, "blocked", title)


def _wrote(log: core.ActionLog, before: Dict[str, int]) -> bool:
    """Something was logged since `before` that stands for a write (or a failure)."""
    return any(n > before.get(kind, 0) for kind, n in log.counts.items() if kind not in INFO_KINDS)


def _run_behind(qctx, c: cards.Cards, reasons: List[str]) -> None:
    """The newest run made here (or the named one) against its list: a sync's own dry run. No
    run is nothing to compare; a run that is there and cannot be read is a reason of its own."""
    try:
        run_dir_for(qctx.project, getattr(qctx.args, "run", None))
    except FileNotFoundError:
        return  # no run here (or the named one is not): nothing to compare
    try:
        rs = RunSync(qctx, c)
        states = spec_runs.states(rs.run_dir, c, rs.cfg)
    except (OSError, core.RunError):
        reasons.append(R_RUN_UNREADABLE)
        return
    if not any(state.role for state in states):
        return
    entry = next((e for e in rs.run_lists() if e["run"] == run_hash(rs.run_id) and e["summary"] is not None), None)
    if entry is None:
        reasons.append(R_RUN_NOT_SYNCED)
        return
    lid, n, log = entry["id"], entry["n"], qctx.log
    before = dict(log.counts)
    rs.fill(lid, n, retire=not spec_runs.unjoined(rs.run_dir, c))
    if _wrote(log, before):
        reasons.append(R_CARDS)
    have = rs.tickets(lid)
    before = dict(log.counts)
    rs.report(states)
    if not rs.lacking(have, n) and rs.tie(entry, have):
        rs.show_all(states, lid, n, have)
        rs.summarise(states, have[ref_key(rs.target, n, "summary", SUMMARY_ID)])
        rs.link_bugs(n, have)
    if _wrote(log, before):
        reasons.append(R_RESULTS)


def spec_status(ctx) -> None:
    """`tracker.sh spec-status`: one JSON line, `{"spec", "setUp": true, "folderUrl", "docUrl",
    "list": {"n", "url", "bound"}, "behind", "reasons"}` (for a spec that is not tracked the CLI
    prints `{"setUp": false, "target"}` and this is not called). It only reads: the other verbs' dry runs go to a log
    of its own, so nothing is written to ClickUp, the config or the cache, and being behind is an
    answer, not a failure."""
    target = ctx.args.spec
    quiet = core.ActionLog(apply=False, out=io.StringIO())
    qctx = Ctx(project=ctx.project, cfg=ctx.cfg, catalog=None, log=quiet, cache=ctx.cache, args=ctx.args)
    reasons: List[str] = []
    out: Dict[str, Any] = {"spec": target, "setUp": True, "folderUrl": None, "docUrl": None, "list": None,
                           "behind": True, "reasons": reasons}
    try:
        c: Optional[cards.Cards] = cards.load(ctx.project, target)
    except cards.CardsError:
        c = None
    s = DocSync(qctx, c)
    if not s.ready():
        reasons.append(R_NOT_SET_UP)
    else:
        out["folderUrl"], out["docUrl"] = s.link(s.folder_info(), "folder"), s.doc_link()
        entries = [e for e in s.run_lists() if not e.get("archived")]
        if entries:
            e = entries[-1]
            out["list"] = {"n": e["n"], "url": s.link(s.get_list(e["id"]), "list") or s.link(e["summary"], "task"),
                           "bound": e["run"] != OPEN}
        if c is None:
            reasons.append(R_CARDS_FILE)
        else:
            if not entries:
                reasons.append(R_NO_LIST)
            else:
                if entries[-1]["run"] == OPEN:  # the list push-scenarios fills
                    before = dict(quiet.counts)
                    s.fill(entries[-1]["id"], entries[-1]["n"])
                    if _wrote(quiet, before):
                        reasons.append(R_CARDS)
                _run_behind(qctx, c, reasons)
            before = dict(quiet.counts)
            DocSync(qctx, c).push()
            if _wrote(quiet, before):
                reasons.append(R_DOCS)
    out["reasons"] = list(dict.fromkeys(reasons))
    out["behind"] = bool(out["reasons"])
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
