"""The spec layout's one-time side: the `Ref` identity, the QA folder check and `spec-init`.

Nothing here needs a run or the scenario tickets; `clickup_spec` builds on it and re-exports the
public names. Dry run unless `--apply`; nothing is ever deleted; the config file is only changed
under `specs.<target>` and the `fields` keys `folder:<name>`.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from trackers import cards, clickup, wording
from trackers.clickup_api import ApiError, Transport
from trackers.core import CONFIG_REL, ConfigError, WordingError, norm, same_status

# ---------------------------------------------------------------- Ref (decision P5)

REF_PREFIX = "qk1"
OPEN = "open"
SUMMARY_ID = "summary"  # the local id of a list's Run summary ticket
KINDS = ("summary", "card", "check")
LETTERS = {"to_test": "t", "testing": "g", "failed": "f", "blocked": "b", "passed": "p", "skipped": "s"}
ROLE_OF = {v: k for k, v in LETTERS.items()}
_REF_RE = re.compile(r"^qk1-([0-9a-f]{12})-([tgfbps])(?:-([0-9a-f]{8}|open))?$")


def ref_key(target: str, n: int, kind: str, local_id: str) -> str:
    """`<key>`: the first 12 hex of sha256 of `<target>|<N>|<kind>|<local id>`."""
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    return hashlib.sha256(f"{target}|{n}|{kind}|{local_id}".encode("utf-8")).hexdigest()[:12]


def run_hash(run_id: Optional[str]) -> str:
    """`<run>`: the first 8 hex of sha256 of the run id, or `open` for a list no run is tied to."""
    return hashlib.sha256(str(run_id).encode("utf-8")).hexdigest()[:8] if run_id else OPEN


def check_id(card_id: str, criterion: str) -> str:
    """The local id of a check: its card and its criterion (a criterion may sit in two cards)."""
    return f"{card_id}/{criterion}"


def ref(target: str, n: int, kind: str, local_id: str, status_letter: str = "t",
        run: Optional[str] = None) -> str:
    """The `Ref` field value: `qk1-<key>-<s>`, and `qk1-<key>-<s>-<run>` for the Run summary
    ticket (`run` is the run id; None means `open`)."""
    if status_letter not in ROLE_OF:
        raise ValueError(f"status letter must be one of {''.join(ROLE_OF)}")
    value = f"{REF_PREFIX}-{ref_key(target, n, kind, local_id)}-{status_letter}"
    return f"{value}-{run_hash(run)}" if kind == "summary" else value


def parse_ref(value: Any) -> Optional[dict]:
    """`{"key", "letter", "role", "run"}` or None. `run` is None except on a Run summary ticket,
    where it is the run hash or `open`. `role` is the status role the tool last wrote."""
    m = _REF_RE.match(value.strip()) if isinstance(value, str) else None
    if not m:
        return None
    return {"key": m.group(1), "letter": m.group(2), "role": ROLE_OF[m.group(2)], "run": m.group(3)}


def reletter(value: str, role: str, run: Optional[str] = None) -> str:
    """`value` with the status letter of `role`; on a summary Ref `run` (a run id) rebinds it."""
    p = parse_ref(value)
    if p is None:
        raise ValueError("not a Ref value")
    out = f"{REF_PREFIX}-{p['key']}-{LETTERS[role]}"
    if p["run"] is None:
        return out
    return f"{out}-{run_hash(run) if run else p['run']}"


# ---------------------------------------------------------------- the QA folder (decision P7)

# (field name, how a person adds it, the API types that fit)
FOLDER_FIELDS = [
    ("Ref", "short text", ("short_text", "text")),
    ("Role", "short text", ("short_text", "text")),
    ("Needs a person's review", "checkbox", ("checkbox",)),
    ("Build", "short text", ("short_text", "text")),
]
FOLDER_PARENT_TYPE = 5  # a Doc whose parent is a folder
EVERY_LIST = "Add it at folder level so every list gets it."


def remote_id(value: Any, what: str) -> str:
    """An id from the config that goes into a request path: letters, digits, `-` and `_` only."""
    text = str(value)
    if not re.fullmatch(r"[\w-]+", text, flags=re.ASCII):
        raise ConfigError(f"{what} must be a ClickUp id (letters, digits, - and _ only)")
    return text


def folder_field_key(name: str) -> str:
    """Key of a folder-level field id in the config's `fields` map: `folder:<name>`."""
    return f"folder:{name}"


def check_folder(ctx, tr: Transport) -> Tuple[List[str], Dict[str, str], dict]:
    """Read the QA folder's statuses and custom fields. Returns the click steps for what is
    missing, the field ids found (by config key) and the folder as ClickUp returned it."""
    _, space, folder_id = clickup._ids(ctx)
    folder = tr.request("GET", f"/v2/folder/{folder_id}")
    live = [s.get("status") for s in folder.get("statuses") or []]
    if not live and space:  # a folder with no statuses of its own shows the space's
        live = [s.get("status") for s in tr.request("GET", f"/v2/space/{space}").get("statuses") or []]
    steps = [f'In the folder: add status "{st}". {EVERY_LIST}'
             for st in ctx.cfg["statuses"]["case"] if not any(same_status(st, x) for x in live)]
    have = {}
    for f in tr.request("GET", f"/v2/folder/{folder_id}/field").get("fields") or []:
        have.setdefault(norm(f.get("name")), f)
    found: Dict[str, str] = {}
    for name, how, types in FOLDER_FIELDS:
        f = have.get(norm(name))
        if f is None:
            steps.append(f'In the folder: add custom field "{name}" ({how}). {EVERY_LIST}')
        elif f.get("type") and f["type"] not in types:
            steps.append(f'In the folder: custom field "{name}" must be {how} '
                         f'(it is {str(f["type"]).replace("_", " ")} now).')
        else:
            found[folder_field_key(name)] = str(f["id"])
    return steps, found, folder


def report_folder_fields(ctx) -> List[str]:
    """What the spec layout still needs on the QA folder, as click steps (`tracker.sh init`
    prints them). Under --apply the field ids found are saved to the config."""
    steps, found, _ = check_folder(ctx, clickup.transport_for(ctx))
    if ctx.log.apply and found:
        save_spec(ctx, None, {}, found)
    return steps


# ---------------------------------------------------------------- the config file


def save_spec(ctx, target: Optional[str], values: Dict[str, str], fields: Dict[str, str]) -> bool:
    """Merge `values` into `specs.<target>` and `fields` into `fields` of
    docs/agents/qa-tracker.json. Every other key, the key order and the file mode are kept; the
    write is atomic. Returns False when nothing changed (the file is then not written)."""
    path = Path(ctx.project) / CONFIG_REL
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: expected a JSON object")
    before = json.dumps(data, sort_keys=True)
    if values and target:
        specs = data.setdefault("specs", {})
        entry = specs.setdefault(target, {})
        if not isinstance(specs, dict) or not isinstance(entry, dict):
            raise ConfigError(f"{path}: specs.{target} must be an object")
        entry.update({k: v for k, v in values.items() if v is not None})  # never an explicit null
    if fields:
        if not isinstance(data.setdefault("fields", {}), dict):
            raise ConfigError(f"{path}: fields must be an object")
        data["fields"].update(fields)
    if json.dumps(data, sort_keys=True) == before:
        return False
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


# ---------------------------------------------------------------- spec-init


def spec_title(ctx) -> str:
    """The spec's name in ClickUp: `specs.<target>.title`, else the cards file's title, else the
    target in plain words."""
    title = ctx.cfg.get("title")
    if isinstance(title, str) and title.strip():
        return title.strip()
    target = ctx.args.spec
    try:
        return cards.load(ctx.project, target).spec["title"].strip()
    except cards.CardsError:
        words = re.sub(r"[-_.]+", " ", target).strip()
        return words[:1].upper() + words[1:]


def _parent_id(folder: dict) -> str:
    parent = folder.get("parent_folder")
    if isinstance(parent, dict):
        parent = parent.get("id")
    return str(parent) if parent else ""


class _SpecInit:
    """One spec-init pass, after the QA folder check passed."""

    def __init__(self, ctx, tr: Transport, qa_folder: dict, found: Dict[str, str]):
        self.ctx, self.cfg, self.log, self.tr = ctx, ctx.cfg, ctx.log, tr
        self.ws, self.space, self.qa = clickup._ids(ctx)
        self.space = self.space or str((qa_folder.get("space") or {}).get("id") or "") or None
        self.qa_folder = qa_folder
        self.found = found
        self.target = ctx.args.spec

    def gone(self, key: str, path: str) -> Optional[dict]:
        """GET an id a person put in the config; a 4xx other than a token problem is reported."""
        try:
            return self.tr.request("GET", path)
        except ApiError as err:
            if err.status in (401, 403) or not 400 <= err.status < 500:
                raise
            self.log.skip("not-found", f"specs.{self.target}.{key}: ClickUp does not show it (HTTP {err.status})")
            return None

    def run(self) -> None:
        try:
            title = wording.clean(spec_title(self.ctx), "title", self.cfg)
        except WordingError as err:
            self.log.skip("wording", f"spec title: {err.word}")
            return
        placed = self.place(title)
        if placed is None:
            return
        folder_id, layout = placed
        doc_id = self.cfg.get("doc") or self.doc(title, folder_id if layout == "subfolder" else self.qa)
        values = {"layout": layout, "doc": doc_id,
                  "folder": folder_id if layout == "subfolder" and clickup._real(folder_id or "<") else None}
        values = {k: str(v) for k, v in values.items() if v and str(self.cfg.get(k) or "") != str(v)}
        fields = {k: v for k, v in self.found.items() if (self.cfg.get("fields") or {}).get(k) != v}
        if values or fields:
            what = ", ".join(sorted(values) + (["field ids"] if fields else []))
            self.log.act("save-config", f"specs.{self.target}: {what}",
                         lambda: save_spec(self.ctx, self.target, values, fields))

    def place(self, title: str) -> Optional[Tuple[Optional[str], str]]:
        """Where the spec's lists live: (subfolder id, "subfolder") or (None, "flat")."""
        pasted, folder_id = self.cfg.get("list"), self.cfg.get("folder")
        if pasted:  # a list the person pasted: the spec lives in that list's folder
            pasted = remote_id(pasted, f"specs.{self.target}.list")
            info = self.gone("list", f"/v2/list/{pasted}")
            if info is None:
                return None
            home = str((info.get("folder") or {}).get("id") or "")
            if not home:
                self.log.skip("not-found", f"specs.{self.target}.list: the list is not in a folder")
                return None
            return (None, "flat") if home == self.qa else (home, "subfolder")
        if folder_id:  # adopted by id, never by name
            folder_id = remote_id(folder_id, f"specs.{self.target}.folder")
            if str(folder_id) == self.qa:
                return None, "flat"
            return None if self.gone("folder", f"/v2/folder/{folder_id}") is None else (str(folder_id), "subfolder")
        if self.cfg.get("layout") == "flat":
            return None, "flat"
        if _parent_id(self.qa_folder):
            self.log.act("layout", "flat: the QA folder is itself a subfolder")
            return None, "flat"
        return self.create_subfolder(title)

    def find_subfolder(self, title: str) -> Optional[dict]:
        r = self.tr.request("GET", f"/v2/space/{self.space}/folder?archived=false")
        hits = [f for f in r.get("folders") or [] if f.get("name") == title and _parent_id(f) == self.qa]
        return hits[0] if len(hits) == 1 else None

    def create_subfolder(self, title: str) -> Optional[Tuple[Optional[str], str]]:
        if not self.space:
            raise ConfigError("ids.space must be set to create the spec's subfolder")
        if not self.log.apply:
            self.log.act("create-folder", title)
            return "<new>", "subfolder"
        try:
            r = self.log.act("create-folder", title, lambda: self.tr.request(
                "POST", f"/v2/space/{self.space}/folder", {"name": title, "parent_folder_id": self.qa}))
        except ApiError as err:
            if err.status in (401, 403, 404, 429):
                raise
            if not clickup._maybe_landed(err):  # P9: ClickUp refuses a subfolder here
                self.log.act("layout", "flat: ClickUp did not allow a subfolder in the QA folder")
                return None, "flat"
            r = self.find_subfolder(title)  # the create may have landed: look before any retry
            if r is None:
                self.log.skip("api-error", f"{title}: HTTP {err.status} (may have landed; "
                                           f"look in ClickUp before running spec-init again)")
                return None
            self.log.act("reconciled", f"{title}: the create had landed")
        folder_id = str((r or {}).get("id") or "")
        if not folder_id:
            self.log.skip("api-error", f"{title}: ClickUp returned no folder id")
            return None
        if _parent_id(r) != self.qa and _parent_id(self.tr.request("GET", f"/v2/folder/{folder_id}")) != self.qa:
            # the id is still saved, so a second run adopts this folder and never makes another
            self.log.skip("subfolder-not-nested", f"{title}: ClickUp made the folder outside the QA folder; "
                                                  f"move it into the QA folder by hand")
        return folder_id, "subfolder"

    def find_docs(self, title: str, parent: str) -> List[dict]:
        found, seen, cursor = [], set(), None
        while True:
            q = "deleted=false&archived=false&limit=100" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
            r = self.tr.request("GET", f"/v3/workspaces/{self.ws}/docs?{q}")
            for d in r.get("docs") or []:
                p = d.get("parent") or {}
                if (d.get("name") == title and str(p.get("id")) == parent
                        and str(p.get("type")) == str(FOLDER_PARENT_TYPE)
                        and not d.get("deleted") and not d.get("archived")
                        and str(d.get("id")) not in {str(x["id"]) for x in found}):
                    found.append(d)
            cursor = r.get("next_cursor")
            if not cursor or cursor in seen:
                return found
            seen.add(cursor)

    def doc(self, title: str, parent: str) -> Optional[str]:
        """The spec Doc in `parent`: the one already there by name, else a new one."""
        if not clickup._real(parent):  # dry run: the subfolder does not exist yet
            self.log.act("doc-create", title)
            return None
        docs = self.find_docs(title, parent)
        if len(docs) > 1:
            self.log.skip("doc-ambiguous", f"{title}: {len(docs)} docs with this name; set specs.{self.target}.doc")
            return None
        if docs:
            return str(docs[0]["id"])

        def go():
            try:
                return self.tr.request("POST", f"/v3/workspaces/{self.ws}/docs",
                                       {"name": title, "parent": {"id": parent, "type": FOLDER_PARENT_TYPE}})
            except ApiError as err:
                if not clickup._maybe_landed(err):
                    raise
                landed = self.find_docs(title, parent)
                if len(landed) != 1:
                    raise
                self.log.act("reconciled", f"{title}: the create had landed")
                return landed[0]
        try:
            r = self.log.act("doc-create", title, go)
        except ApiError as err:
            if err.status in (401, 403):
                raise
            why = "may have landed, re-run to reconcile" if clickup._maybe_landed(err) else "failed"
            self.log.skip("api-error", f"{title}: HTTP {err.status} ({why})")
            return None
        return str(r["id"]) if r and r.get("id") else None


def spec_init(ctx) -> None:
    """`tracker.sh spec-init`: check the QA folder, then create or adopt the spec's subfolder and
    Doc and save their ids under `specs.<target>`. Missing statuses or fields stop it (rc 1) with
    the click steps, before anything is written."""
    tr = clickup.transport_for(ctx)
    steps, found, folder = check_folder(ctx, tr)
    if steps:
        for i, step in enumerate(steps, 1):
            ctx.log.out.write(f"MANUAL\t{i}. {step}\n")
        ctx.log.counts["manual"] = len(steps)
        ctx.log.skip("folder-setup", f"{len(steps)} step(s) to do in ClickUp, then run spec-init again")
        return
    _SpecInit(ctx, tr, folder, found).run()
