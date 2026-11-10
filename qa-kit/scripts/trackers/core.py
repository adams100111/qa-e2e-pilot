"""Pure helpers shared by every QA tracker backend.

Config, catalog loading and validation, per-case result roll-up, content hashes, bug
fingerprints, the outbound filter (redaction + wording) and the two pieces of state every
verb uses: the remote-id cache (`MapCache`) and the dry-run/apply action log (`ActionLog`).

Python >= 3.9, stdlib only. PyYAML is used when importable; without it the catalog must be JSON.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

try:  # optional
    import yaml  # type: ignore
except Exception:  # pragma: no cover - depends on the machine
    yaml = None  # type: ignore

QA_KIT = Path(__file__).resolve().parents[2]
CONFIG_TEMPLATE = QA_KIT / "templates" / "qa-tracker-config.json"
CATALOG_SCHEMA = QA_KIT / "templates" / "catalog-schema.json"
CONFIG_REL = Path("docs") / "agents" / "qa-tracker.json"
MAP_REL = Path(".qa") / "tracker-map.json"

BACKENDS = ("local", "clickup", "github", "other")
STATUS_CEILINGS = ("none", "testing")
GUIDE_AS = ("tasks", "doc")
BUGS_TO = ("same", "issue-tracker")

# P4: worst verdict wins. Unknown verdicts rank as "error" so they never hide behind a pass.
VERDICT_RANK = {"pass": 0, "deferred": 1, "blocked": 2, "error": 3, "fail": 4}
CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}

SHARED_PASSWORD_TEXT = "the shared QA password"
TOKEN_RE = re.compile(r"pk_[A-Za-z0-9_]{20,}")
# Copied verbatim from scripts/bug-export.sh (DEFAULT_PATTERNS, AUTH_PATTERNS); matched case-insensitively.
DEFAULT_PATTERNS = ["(password|passwd|secret|token|api[_-]?key|apikey|authorization|bearer|access[_-]?key|private[_-]?key|client[_-]?secret)\\s*[=:]\\s*\\S+"]
AUTH_PATTERNS = ["authorization\\s*[=:]\\s*((bearer|basic)\\s+)?\\S+", "bearer\\s+[A-Za-z0-9._~+/=-]+", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"]
SECRET_RES = [re.compile(p, re.IGNORECASE) for p in AUTH_PATTERNS + DEFAULT_PATTERNS]
OUTBOUND_SOURCES = ("generated", "catalog")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


class ConfigError(Exception):
    """The tracker config is unreadable or invalid. The message names the file."""


class CatalogError(Exception):
    """The catalog cannot be loaded at all (no manifest, unparseable file)."""


class RunError(Exception):
    """A run directory is missing what the roll-up needs."""


class WordingError(Exception):
    """Outbound text contains a forbidden word or pattern. `.word` is what matched."""

    def __init__(self, word: str) -> None:
        super().__init__(word)
        self.word = word


# ---------------------------------------------------------------- config


class Config(dict):
    """A plain dict of config values that also remembers the project root (`.project`).

    Equality is dict equality, so a config compares equal to the template it was built from.
    """

    project: Optional[Path] = None


def _merge(base: Any, over: Any) -> Any:
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = _merge(base[k], v) if k in base else copy.deepcopy(v)
        return out
    return copy.deepcopy(over)


def _read_json(path: Path, err: type) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise err(f"{path}: {exc}") from exc


def load_config(project: Path) -> Config:
    """Read `docs/agents/qa-tracker.json` and fill every missing key from the template."""
    project = Path(project)
    defaults = _read_json(CONFIG_TEMPLATE, ConfigError)
    path = project / CONFIG_REL
    merged = defaults
    if path.exists():
        data = _read_json(path, ConfigError)
        if not isinstance(data, dict):
            raise ConfigError(f"{path}: expected a JSON object")
        merged = _merge(defaults, data)
    problems = []
    if merged.get("backend") not in BACKENDS:
        problems.append(f"backend must be one of {', '.join(BACKENDS)}")
    if merged.get("statusCeiling") not in STATUS_CEILINGS:
        problems.append(f"statusCeiling must be one of {', '.join(STATUS_CEILINGS)}")
    if merged.get("guideAs") not in GUIDE_AS:
        problems.append(f"guideAs must be one of {', '.join(GUIDE_AS)}")
    if merged.get("bugsTo") not in BUGS_TO:
        problems.append(f"bugsTo must be one of {', '.join(BUGS_TO)}")
    if not isinstance(merged.get("secrets"), list):
        problems.append("secrets must be a list")
    wording = merged.get("wording")
    if not isinstance(wording, dict) or not isinstance(wording.get("forbidden"), list) \
            or not isinstance(wording.get("patterns"), list) or not isinstance(wording.get("allow"), list):
        problems.append("wording.forbidden, wording.allow and wording.patterns must be lists")
    else:
        for p in wording["patterns"]:
            try:
                re.compile(p)
            except (re.error, TypeError) as exc:
                problems.append(f"wording.patterns: bad regex {p!r}: {exc}")
    if problems:
        raise ConfigError(f"{path}: " + "; ".join(problems))
    cfg = Config(merged)
    cfg.project = project
    return cfg


# ---------------------------------------------------------------- catalog


def _schema() -> dict:
    return _read_json(CATALOG_SCHEMA, CatalogError)


_SCHEMA_CACHE: Dict[str, Any] = {}


def _case_rules() -> dict:
    if "case" not in _SCHEMA_CACHE:
        case = _schema()["$defs"]["case"]
        props = case["properties"]
        _SCHEMA_CACHE["case"] = {
            "required": list(case["required"]),
            "allowed": set(props),
            "id_re": re.compile(props["id"]["pattern"]),
            "priority": list(props["priority"]["enum"]),
            "level": list(props["level"]["enum"]),
            "lists": [k for k, v in props.items() if v.get("type") == "array"],
            "nonempty": [k for k, v in props.items() if v.get("minItems")],
            "bools": [k for k, v in props.items() if v.get("type") == "boolean"],
            "strings": [k for k, v in props.items() if v.get("type") == "string"],
        }
    return _SCHEMA_CACHE["case"]


@dataclass
class Area:
    file: str
    prefix: str
    list: str
    order: Any
    intro: dict
    cases: List[dict]
    also_prefixes: List[str] = field(default_factory=list)
    counts: Optional[dict] = None
    name: Optional[str] = None
    file_prefix: Optional[str] = None
    missing: bool = False


@dataclass
class Catalog:
    root: Path
    manifest_file: str
    areas: List[Area]
    unlisted: List[str] = field(default_factory=list)


def _load_data(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    if path.suffix in (".yaml", ".yml"):
        if yaml is not None:
            try:
                return yaml.safe_load(text)
            except Exception as exc:
                raise CatalogError(f"{path}: {exc}") from exc
        try:  # JSON is a YAML subset
            return json.loads(text)
        except ValueError as exc:
            raise CatalogError(f"{path}: PyYAML is not installed; use .json catalog files or install PyYAML") from exc
    try:
        return json.loads(text)
    except ValueError as exc:
        raise CatalogError(f"{path}: {exc}") from exc


def _catalog_root(project: Path, cfg: dict) -> Path:
    return Path(project) / cfg.get("catalog", ".qa/catalog")


def load_catalog(project: Path, cfg: dict) -> Catalog:
    """Load the manifest and every area file it lists, in manifest `order`."""
    root = _catalog_root(project, cfg)
    manifest = None
    for name in ("manifest.yaml", "manifest.yml", "manifest.json"):
        if (root / name).is_file():
            manifest = root / name
            break
    if manifest is None:
        raise CatalogError(f"{root}: no manifest.yaml or manifest.json")
    man = _load_data(manifest)
    if not isinstance(man, dict) or not isinstance(man.get("areas"), list):
        raise CatalogError(f"{manifest}: expected an object with an 'areas' list")
    areas: List[Area] = []
    listed = set()
    for entry in sorted(man["areas"], key=lambda a: (a.get("order") is None, a.get("order") or 0)):
        fname = str(entry.get("file", ""))
        listed.add(fname)
        path = root / fname
        data: dict = {}
        missing = not (fname and path.is_file())
        if not missing:
            loaded = _load_data(path)
            data = loaded if isinstance(loaded, dict) else {"cases": loaded}
        cases = data.get("cases") if isinstance(data.get("cases"), list) else []
        areas.append(Area(
            file=fname,
            prefix=str(entry.get("prefix", "")),
            list=str(entry.get("list", "")),
            order=entry.get("order"),
            intro=data.get("intro") if isinstance(data.get("intro"), dict) else {},
            cases=cases,
            also_prefixes=list(entry.get("also_prefixes") or []),
            counts=entry.get("counts") if isinstance(entry.get("counts"), dict) else None,
            name=data.get("area"),
            file_prefix=data.get("prefix"),
            missing=missing,
        ))
    unlisted = sorted(
        p.name for p in root.iterdir()
        if p.is_file() and p.suffix in (".yaml", ".yml", ".json")
        and p.name != manifest.name and p.name not in listed
    )
    return Catalog(root=root, manifest_file=manifest.name, areas=areas, unlisted=unlisted)


def _id_prefix(case_id: str) -> Optional[str]:
    m = re.match(r"^TC-([A-Z]+)-", case_id or "")
    return m.group(1) if m else None


def _validate_case(case: Any, rules: dict) -> List[str]:
    if not isinstance(case, dict):
        return ["case is not an object"]
    out = []
    for key in rules["required"]:
        if key not in case:
            out.append(f"missing required key: {key}")
    for key in case:
        if key not in rules["allowed"]:
            out.append(f"unknown key: {key}")
    cid = case.get("id")
    if "id" in case and not (isinstance(cid, str) and rules["id_re"].match(cid)):
        out.append(f"id must match {rules['id_re'].pattern}")
    if "priority" in case and case["priority"] not in rules["priority"]:
        out.append(f"priority must be one of {'|'.join(rules['priority'])}")
    if "level" in case and case["level"] not in rules["level"]:
        out.append(f"level must be one of {'|'.join(rules['level'])}")
    for key in rules["lists"]:
        if key in case:
            val = case[key]
            if not isinstance(val, list) or not all(isinstance(x, str) for x in val):
                out.append(f"{key} must be a list of strings")
            elif key in rules["nonempty"] and not val:
                out.append(f"{key} must be a non-empty list")
    for key in rules["bools"]:
        if key in case and not isinstance(case[key], bool):
            out.append(f"{key} must be true or false")
    for key in rules["strings"]:
        if key in case and key != "id" and not isinstance(case[key], str):
            out.append(f"{key} must be text")
    if case.get("title") == "":
        out.append("title must not be empty")
    return out


def validate_catalog(cat: Catalog) -> List[dict]:
    """Return every problem as `{file, id, reason}`; an empty list means the catalog is clean."""
    rules = _case_rules()
    errors: List[dict] = []

    def err(file: str, cid: Optional[str], reason: str) -> None:
        errors.append({"file": file, "id": cid, "reason": reason})

    seen: Dict[str, str] = {}
    for area in cat.areas:
        if area.missing:
            err(area.file, None, "missing file listed in the manifest")
            continue
        if area.file_prefix is not None and area.file_prefix != area.prefix:
            err(area.file, None, f"file prefix {area.file_prefix} does not match manifest prefix {area.prefix}")
        prefixes = [area.prefix] + list(area.also_prefixes)
        tally = {p: 0 for p in rules["priority"]}
        retired = 0
        for case in area.cases:
            cid = case.get("id") if isinstance(case, dict) else None
            cid = cid if isinstance(cid, str) else None
            for reason in _validate_case(case, rules):
                err(area.file, cid, reason)
            if cid:
                if cid in seen:
                    err(area.file, cid, f"duplicate id (also in {seen[cid]})")
                else:
                    seen[cid] = area.file
                pref = _id_prefix(cid)
                if pref is not None and pref not in prefixes:
                    err(area.file, cid, f"id prefix {pref} does not match area prefix {'/'.join(prefixes)}")
            if not isinstance(case, dict):
                continue
            if case.get("retired") is True:
                retired += 1
            if case.get("priority") in tally:
                tally[case["priority"]] += 1
        if area.counts is not None:
            for key in rules["priority"] + ["retired"]:
                if key == "retired" and key not in area.counts:
                    continue
                want = area.counts.get(key, 0)
                got = retired if key == "retired" else tally[key]
                if want != got:
                    err(area.file, None, f"counts {key}: manifest {want}, catalog {got}")
    for name in cat.unlisted:
        err(name, None, "file is not listed in the manifest")
    return errors


def case_index(cat: Catalog) -> Dict[str, Tuple[Area, dict]]:
    """Map every case id (retired ones included) to its area and case. First occurrence wins."""
    idx: Dict[str, Tuple[Area, dict]] = {}
    for area in cat.areas:
        for case in area.cases:
            if isinstance(case, dict) and isinstance(case.get("id"), str) and case["id"] not in idx:
                idx[case["id"]] = (area, case)
    return idx


# ---------------------------------------------------------------- hashes


def norm(s: Optional[str]) -> str:
    """The sync_clickup.py `norm`: markdown links → their text, drop non-word chars, lowercase."""
    s = re.sub(r"\[([^\]]*)\]\((?:https?://|mailto:)[^)]*\)", r"\1", s or "")
    return re.sub(r"[\W_]+", "", s, flags=re.UNICODE).lower()


def content_hash(text: str) -> str:
    return hashlib.sha1(norm(text).encode("utf-8")).hexdigest()


def _norm_title(title: str) -> str:
    t = (title or "").lower()
    t = re.sub(r"\d+", "", t)
    t = re.sub(r"[\W\d_]+", " ", t, flags=re.UNICODE)
    return t.strip()


def fingerprint(key: str, persona: str, title: str) -> str:
    """P5: sha1("<case-or-criterion>|<persona>|<normalised title>")[:12]."""
    raw = f"{key or ''}|{persona or ''}|{_norm_title(title)}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------- run roll-up


def _rows(data: Any, *keys: str) -> List[dict]:
    if isinstance(data, list):
        return [r for r in data if isinstance(r, dict)]
    if isinstance(data, dict):
        for k in keys:
            if isinstance(data.get(k), list):
                return [r for r in data[k] if isinstance(r, dict)]
    return []


def _cid(row: dict) -> Optional[str]:
    for k in ("criterion_id", "criterionId", "id"):
        v = row.get(k)
        if isinstance(v, str) and v:
            return v
    return None


def _case_refs(row: dict) -> List[str]:
    """P3: `case:<TC-id>` tags and `catalogRef` (string or list)."""
    out: List[str] = []
    tags = row.get("tags")
    if isinstance(tags, list):
        for t in tags:
            if isinstance(t, str) and t.startswith("case:") and t[5:].strip():
                out.append(t[5:].strip())
    ref = row.get("catalogRef")
    if isinstance(ref, str) and ref.strip():
        out.append(ref.strip())
    elif isinstance(ref, list):
        out.extend(r.strip() for r in ref if isinstance(r, str) and r.strip())
    seen = set()
    return [r for r in out if not (r in seen or seen.add(r))]


def _worst(verdicts: List[str]) -> str:
    return max(verdicts, key=lambda v: VERDICT_RANK.get(v, VERDICT_RANK["error"]))


def case_results(run_dir: Path) -> Dict[str, dict]:
    """Per case: `{verdict, criteria: [{id, verdict, persona}], confidence}` (P3, P4).

    Rows come from `checkpoint.json` (the last row per criterion+persona wins). A
    `verification.json` row for the same criterion and persona overrides the verdict and
    confidence. Rows that join no case are ignored. A missing verification.json is fine.
    """
    run_dir = Path(run_dir)
    cp_path = run_dir / "checkpoint.json"
    if not cp_path.is_file():
        raise RunError(f"{cp_path}: not found")
    checkpoint = _rows(_read_json(cp_path, RunError), "criteria")

    refs: Dict[str, List[str]] = {}
    cl_path = run_dir / "checklist.json"
    if cl_path.is_file():
        for row in _rows(_read_json(cl_path, RunError), "criteria", "items"):
            cid = _cid(row)
            if cid:
                refs.setdefault(cid, [])
                for r in _case_refs(row):
                    if r not in refs[cid]:
                        refs[cid].append(r)

    overrides: Dict[Tuple[str, str], dict] = {}
    vf_path = run_dir / "verification.json"
    if vf_path.is_file():
        for row in _rows(_read_json(vf_path, RunError), "rows", "criteria"):
            cid = _cid(row)
            if cid and isinstance(row.get("verifierVerdict"), str):
                overrides[(cid, str(row.get("persona") or ""))] = row

    latest: Dict[Tuple[str, str], dict] = {}
    for row in checkpoint:
        cid = _cid(row)
        if cid:
            latest[(cid, str(row.get("persona") or ""))] = row
    # A persona-less row is superseded by a strictly later persona-scoped row for the same
    # criterion (scripts/qa-verify.sh list_pass_records); a timestamp tie keeps both.
    for (cid, persona), row in list(latest.items()):
        if persona:
            continue
        at = str(row.get("checkpointed_at") or "")
        if any(c == cid and p and str(r.get("checkpointed_at") or "") > at
               for (c, p), r in latest.items()):
            del latest[(cid, persona)]

    out: Dict[str, dict] = {}
    for (cid, persona), row in latest.items():
        cases = list(refs.get(cid, []))
        for r in _case_refs(row):
            if r not in cases:
                cases.append(r)
        if not cases:
            continue
        raw = str(row.get("verdict") or "").lower()
        verdict = raw if raw in VERDICT_RANK else "error"
        confidence = row.get("confidence")
        ov = overrides.get((cid, persona))
        # scripts/render-report.js: the verifier row applies only when it checked this verdict.
        if ov is not None and ov.get("inRunVerdict") == verdict:
            if ov["verifierVerdict"] in VERDICT_RANK:
                verdict = ov["verifierVerdict"]
            if ov.get("confidence"):
                confidence = ov["confidence"]
        for case_id in cases:
            entry = out.setdefault(case_id, {"verdict": None, "criteria": [], "confidence": None, "_conf": []})
            entry["criteria"].append({"id": cid, "verdict": verdict, "persona": persona})
            entry["_conf"].append(confidence)
    for entry in out.values():
        entry["verdict"] = _worst([c["verdict"] for c in entry["criteria"]])
        confs = [c for c in entry.pop("_conf") if c in CONFIDENCE_RANK]
        entry["confidence"] = min(confs, key=lambda c: CONFIDENCE_RANK[c]) if confs else None
    return {k: out[k] for k in sorted(out)}


# ---------------------------------------------------------------- outbound filter


def _project_of(cfg: dict) -> Path:
    project = getattr(cfg, "project", None)
    return Path(project) if project is not None else Path.cwd()


def _guide_shared_passwords(cfg: dict) -> List[str]:
    """Every line of each fenced block that follows a line mentioning "same password"."""
    path = _project_of(cfg) / cfg.get("guideDir", ".qa/guide") / "02-test-accounts.md"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    values: List[str] = []
    i = 0
    while i < len(lines):
        if "same password" in lines[i].lower():
            j = i + 1
            while j < len(lines) and not FENCE_RE.match(lines[j]):
                j += 1
            j += 1
            while j < len(lines) and not FENCE_RE.match(lines[j]):
                v = lines[j].strip()
                if v:
                    values.append(v)
                j += 1
            i = j
        i += 1
    return values


# Secret key name -> how its values are found. Unknown names resolve to nothing.
SECRET_RESOLVERS: Dict[str, Callable[[dict], List[str]]] = {
    "sharedPassword": _guide_shared_passwords,
}
SECRET_REPLACEMENTS: Dict[str, str] = {
    "sharedPassword": SHARED_PASSWORD_TEXT,
}


def redact(text: str, cfg: dict) -> str:
    out = text or ""
    # bug-export patterns first, so they never consume the guide-value replacement text
    for rx in SECRET_RES:
        out = rx.sub("[redacted]", out)
    for key in cfg.get("secrets") or []:
        resolver = SECRET_RESOLVERS.get(key)
        if resolver is None:
            continue
        repl = SECRET_REPLACEMENTS.get(key, "[redacted]")
        for value in sorted(set(resolver(cfg)), key=len, reverse=True):
            out = out.replace(value, repl)
    return TOKEN_RE.sub("[redacted]", out)


def outbound(text: str, cfg: dict, source: str = "generated") -> str:
    """Redact, then refuse the text if it holds a forbidden word or pattern.

    `source="catalog"` is human-authored case, intro or guide text: redaction and the regex
    patterns apply, the forbidden-word list does not. `source="generated"` (comments, run and
    result text, bug text from the engine export) runs every check. Phrases in
    `wording.allow` are exempt from the forbidden-word check.
    """
    if source not in OUTBOUND_SOURCES:
        raise ValueError(f"source must be one of {', '.join(OUTBOUND_SOURCES)}")
    out = redact(text, cfg)
    wording = cfg.get("wording") or {}
    if source == "generated":
        probe = out
        for phrase in wording.get("allow") or []:
            if phrase:
                probe = re.sub(re.escape(phrase), " ", probe, flags=re.IGNORECASE)
        for word in wording.get("forbidden") or []:
            if re.search(r"(?<!\w)" + re.escape(word) + r"(?!\w)", probe, flags=re.IGNORECASE):
                raise WordingError(word)
    for pattern in wording.get("patterns") or []:
        m = re.search(pattern, out)
        if m:
            raise WordingError(m.group(0).strip())
    return out


# ---------------------------------------------------------------- state


class MapCache:
    """`.qa/tracker-map.json`: per kind, local key -> {id, hash}. Only a cache (P2)."""

    def __init__(self, project: Path) -> None:
        self.path = Path(project) / MAP_REL
        self.data: Dict[str, Any] = {"version": 1}
        if self.path.is_file():
            try:
                with open(self.path, encoding="utf-8") as fh:
                    loaded = json.load(fh)
            except (OSError, ValueError) as exc:
                loaded = None
                reason = str(exc)
            else:
                reason = "not a JSON object"
            if isinstance(loaded, dict):
                self.data = loaded
                self.data.setdefault("version", 1)
            else:
                sys.stderr.write(f"warning: {self.path}: {reason}; starting with an empty cache\n")

    def get(self, kind: str, key: str) -> Optional[dict]:
        bucket = self.data.get(kind)
        if isinstance(bucket, dict):
            entry = bucket.get(key)
            return dict(entry) if isinstance(entry, dict) else None
        return None

    def put(self, kind: str, key: str, remote_id: Any, hash: Optional[str]) -> None:  # noqa: A002
        self.data.setdefault(kind, {})[key] = {"id": remote_id, "hash": hash}

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".tracker-map.", suffix=".tmp", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(self.data, fh, indent=2, sort_keys=True, ensure_ascii=False)
                fh.write("\n")
            os.replace(tmp, self.path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise


class ActionLog:
    """Prints `DRY|APPLY\\t<kind>\\t<detail>` per action and counts them for `summary()`."""

    def __init__(self, apply: bool, out: Any = None) -> None:
        self.apply = bool(apply)
        self.out = out if out is not None else sys.stdout
        self.counts: Dict[str, int] = {}

    def _emit(self, line: str) -> None:
        self.out.write(line + "\n")

    def act(self, kind: str, detail: str, fn: Optional[Callable[[], Any]] = None) -> Any:
        self._emit(f"{'APPLY' if self.apply else 'DRY'}\t{kind}\t{detail}")
        self.counts[kind] = self.counts.get(kind, 0) + 1
        if self.apply and fn is not None:
            return fn()
        return None

    def skip(self, kind: str, detail: str) -> None:
        """`SKIP\\t<kind>\\t<detail>`, e.g. a wording hit; counted under "skip"."""
        self._emit(f"SKIP\t{kind}\t{detail}")
        self.counts["skip"] = self.counts.get("skip", 0) + 1

    def summary(self) -> str:
        return f"SUMMARY {json.dumps(self.counts, sort_keys=True)} {'apply' if self.apply else 'dry-run'}"
