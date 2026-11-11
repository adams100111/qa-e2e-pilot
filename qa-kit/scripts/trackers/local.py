"""Local files backend: `.qa/tracker/runs/<run-id>.md` and `.qa/tracker/bugs/NNN-slug.md`."""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from trackers import core
from trackers.ctx import Ctx, run_dir_for, run_label

NOTHING = "nothing to do: cases live in the catalog"


def _tracker(ctx: Ctx) -> Path:
    return ctx.project / ".qa" / "tracker"


def _write(path: Path, text: str) -> None:
    """Atomic: temp file in the same directory, then os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tracker.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, str(path))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _create(path: Path, text: str) -> None:
    """Create a new file; an existing one raises FileExistsError instead of being overwritten."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(path), "x", encoding="utf-8") as fh:
        fh.write(text)


def _cell(text: str) -> str:
    return " ".join(str(text).split()).replace("|", "\\|")


def _label(ctx: Ctx, run_dir: Path) -> str:
    return run_label(run_dir, ctx.args)


def init(ctx: Ctx) -> None:
    for sub in ("runs", "bugs"):
        d = _tracker(ctx) / sub
        ctx.log.act("mkdir", str(d.relative_to(ctx.project)), lambda d=d: d.mkdir(parents=True, exist_ok=True))


def push_plan(ctx: Ctx) -> None:
    ctx.log.act("info", NOTHING)


pull_plan = push_plan


def status(ctx: Ctx) -> None:
    def count(sub: str) -> int:
        d = _tracker(ctx) / sub
        return len(list(d.glob("*.md"))) if d.is_dir() else 0

    cases = sum(len(a.cases) for a in ctx.catalog.areas) if ctx.catalog else 0
    ctx.log.act("info", json.dumps({"bugs": count("bugs"), "cases": cases, "runs": count("runs")}, sort_keys=True))


# ---------------------------------------------------------------- runs


def push_run(ctx: Ctx) -> None:
    run_dir = run_dir_for(ctx.project, getattr(ctx.args, "run", None))
    label = _label(ctx, run_dir)
    results = core.case_results(run_dir)
    index = core.case_index(ctx.catalog) if ctx.catalog else {}
    try:
        heading = core.outbound(f"# Run {label}", ctx.cfg, source="generated")
    except core.WordingError as exc:
        ctx.log.skip("wording", f"{run_dir.name}: {exc.word}")
        return
    lines = [heading, "", "| Case | Title | Result | Criteria |", "|---|---|---|---|"]
    for case_id in sorted(results):
        entry = results[case_id]
        title = ""
        if case_id in index:
            try:
                title = core.outbound(str(index[case_id][1].get("title", "")), ctx.cfg, source="catalog")
            except core.WordingError as exc:
                ctx.log.skip("wording", f"{case_id}: {exc.word}")
                continue
        crit = ", ".join(f"{c['id']} {c['verdict']}" for c in entry["criteria"])
        lines.append(f"| {case_id} | {_cell(title)} | {entry['verdict']} | {_cell(crit)} |")
    text = "\n".join(lines) + "\n"
    path = _tracker(ctx) / "runs" / f"{run_dir.name}.md"
    rel = str(path.relative_to(ctx.project))
    if not path.is_file():
        ctx.log.act("create", rel, lambda: _write(path, text))
    elif core.content_hash(path.read_text(encoding="utf-8")) != core.content_hash(text):
        ctx.log.act("update", rel, lambda: _write(path, text))


push_results = push_run


# ---------------------------------------------------------------- bugs


def _split(text: str) -> Tuple[Dict[str, str], str]:
    """Front matter dict and the body of a bug file. Tolerates a BOM, CRLF and trailing spaces."""
    text = text.lstrip("\ufeff").replace("\r\n", "\n")
    m = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n(.*))?$", text, re.DOTALL)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip()
    return meta, m.group(2) or ""


def _status(meta: Dict[str, str]) -> str:
    return meta.get("status", "").strip().strip("\"'").lower()


def _bug_files(ctx: Ctx) -> List[Tuple[Path, Dict[str, str]]]:
    d = _tracker(ctx) / "bugs"
    out = []
    if d.is_dir():
        for f in sorted(d.glob("*.md")):
            out.append((f, _split(f.read_text(encoding="utf-8"))[0]))
    return out


def _append(path: Path, line: str) -> None:
    text = path.read_text(encoding="utf-8")
    if not text.endswith("\n"):
        text += "\n"
    _write(path, text + line + "\n")


def _next_number(ctx: Ctx, reserved: List[int]) -> int:
    numbers = list(reserved)
    d = _tracker(ctx) / "bugs"
    if d.is_dir():
        for f in d.glob("*.md"):
            m = re.match(r"^(\d+)-", f.name)
            if m:
                numbers.append(int(m.group(1)))
    return max(numbers) + 1 if numbers else 1


def _case_of(results: Dict[str, dict], criterion: Optional[str]) -> str:
    for case_id, entry in results.items():
        if any(c["id"] == criterion for c in entry["criteria"]):
            return case_id
    return ""


def _slug(title: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:50].strip("-")
    return s or "bug"


def _bug_text(row: dict, ctx: Ctx) -> Dict[str, object]:
    out = lambda t: core.outbound(str(t), ctx.cfg, source="generated")  # noqa: E731
    return {
        "title": out(row.get("title", "")),
        "steps": [out(s) for s in row.get("steps") or []],
        "expected": out(row.get("expected") or ""),
        "actual": out(row.get("actual") or ""),
    }


def push_bug(ctx: Ctx) -> None:
    run_dir = run_dir_for(ctx.project, getattr(ctx.args, "run", None))
    label = _label(ctx, run_dir)
    bugs_json = run_dir / "bugs" / "bugs.json"
    if not bugs_json.is_file():
        ctx.log.act("info", "no bugs to push")
        return
    try:
        with open(bugs_json, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise core.RunError(f"{bugs_json}: cannot read bugs ({exc})") from exc
    rows = data if isinstance(data, list) else (data.get("bugs") or []) if isinstance(data, dict) else []
    results = core.case_results(run_dir)
    existing = _bug_files(ctx)
    created: set = set()
    reserved: List[int] = []
    line = f"- Still happens on {label}"
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("duplicateOf"):
            ctx.log.skip("duplicate-of", f"{row.get('title') or 'untitled'}: the export marks it a duplicate")
            continue
        case_id = _case_of(results, row.get("criterionId") or row.get("criterion_id"))
        key = case_id or str(row.get("criterionId") or row.get("criterion_id") or row.get("id") or "")
        ref = core.fingerprint(key, str(row.get("persona") or ""), str(row.get("title") or ""))
        if ref in created:
            continue
        if not str(row.get("title") or "").strip():
            ctx.log.skip("no-title", f"{ref}: the export row has no title")
            continue
        try:
            text = _bug_text(row, ctx)
        except core.WordingError as exc:
            ctx.log.skip("wording", f"{ref}: {exc.word}")
            continue
        match = next((f for f, m in existing if m.get("ref") == ref and _status(m) != "closed"), None)
        if match is not None:
            content = match.read_text(encoding="utf-8")
            meta, body = _split(content)
            if meta.get("found_in") == label or line in [l.strip() for l in body.splitlines()]:
                continue
            ctx.log.act("update", f"{match.name} {line[2:]}", lambda p=match: _append(p, line))
            continue
        number = _next_number(ctx, reserved)
        reserved.append(number)
        name = f"{number:03d}-{_slug(str(text['title']))}.md"
        path = _tracker(ctx) / "bugs" / name
        body_lines = [
            "---", "status: open", f"severity: {row.get('severity') or ''}", f"case: {case_id}",
            f"ref: {ref}", f"found_in: {label}", "---", f"# {text['title']}", "",
        ]
        if text["steps"]:
            body_lines.append("Steps:")
            body_lines += [f"{i}. {s}" for i, s in enumerate(text["steps"], 1)]
            body_lines.append("")
        if text["expected"]:
            body_lines += [f"Expected: {text['expected']}", ""]
        if text["actual"]:
            body_lines += [f"Actual: {text['actual']}", ""]
        created.add(ref)
        ctx.log.act("create", name, lambda p=path, c="\n".join(body_lines): _create(p, c))


def update_retest(ctx: Ctx) -> None:
    """Bugs in `retest`: when the linked case has a clear result in this run, add a line saying
    passed (pass) or still failing (fail). The same rules as ClickUp: blocked, deferred or error is
    inconclusive, no result is incomplete. Never changes a status."""
    run_dir = run_dir_for(ctx.project, getattr(ctx.args, "run", None))
    label = _label(ctx, run_dir)
    results = core.case_results(run_dir)
    for path, meta in _bug_files(ctx):
        if _status(meta) != "retest":
            continue
        case_id = meta.get("case", "").strip().strip("\"'")
        if not case_id:
            ctx.log.skip("retest-no-case", f"{path.name}: no case linked")
            continue
        if case_id not in results:
            ctx.log.skip("retest-incomplete", f"{path.name}: no result in this run for {case_id}")
            continue
        verdict = results[case_id]["verdict"]
        if verdict == "pass":
            outcome = "passed"
        elif verdict == "fail":
            outcome = "still failing"
        else:
            ctx.log.skip("retest-inconclusive", f"{path.name}: {case_id} {verdict}")
            continue
        line = f"- Retest on {label}: {outcome}"
        if line in [l.strip() for l in _split(path.read_text(encoding="utf-8"))[1].splitlines()]:
            continue
        ctx.log.act("update", f"{path.name} {line[2:]}", lambda p=path, l=line: _append(p, l))
