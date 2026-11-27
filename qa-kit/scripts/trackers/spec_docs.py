"""The markdown of the ClickUp Docs pages (A9). Pure: values in, text out; no network, no files.

Spec Doc: an Overview page, one page per scenario and one Results page per run. The project's
"QA overview" Doc is the dashboard. Task 9 pushes these pages, whole, on every `push-docs`.

Pages are read by admins, testers and customers: plain short sentences, the project's own status
names, ClickUp links the caller passes in. Nothing here builds a URL or prints an id, a run id or
a file name. Output is deterministic: cards keep their file order, checks theirs, bugs are sorted
by severity then title.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from . import cards as cards_mod
from . import core
from . import spec_runs

PAGE_OVERVIEW = "Overview"
PAGE_SCENARIOS = "Scenarios"
PAGE_RESULTS = "Results"
PROJECT_DOC = "QA overview"

NO_RUN = "No run yet."
RETIRED = "No longer part of the plan."
NO_BUGS = "No open bugs."

PRIORITY_WORD = {"P1": "High", "P2": "Medium", "P3": "Low"}
SEVERITY_ORDER = ("critical", "high", "medium", "low")


def _cell(text) -> str:
    return " ".join(str(text if text is not None else "").replace("|", "/").split())


def _table(header: List[str], rows: List[List[str]]) -> List[str]:
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    out += ["| " + " | ".join(_cell(c) for c in row) + " |" for row in rows]
    return out


def _link(text: str, url: Optional[str]) -> str:
    return f"[{_cell(text)}]({url})" if url else _cell(text)


def _status(cfg: dict, role: Optional[str]) -> str:
    return core.status_name(cfg, "case", role or "to_test")


def _join(lines: List[str]) -> str:
    return "\n".join(lines).rstrip("\n") + "\n"


def _bugs_section(bugs: List[dict]) -> List[str]:
    out = ["## Open bugs", ""]
    rows = sorted(bugs or [], key=lambda b: (
        SEVERITY_ORDER.index(str(b.get("severity", "")).lower()) if str(b.get("severity", "")).lower() in SEVERITY_ORDER
        else len(SEVERITY_ORDER), str(b.get("title", ""))))
    if not rows:
        return out + [NO_BUGS, ""]
    if len(rows) == 1:
        b = rows[0]
        return out + [f"{_link(b.get('title', ''), b.get('url'))}, {_cell(b.get('severity', '')) or 'severity not set'}.", ""]
    return out + _table(["Bug", "Severity"], [[_link(b.get("title", ""), b.get("url")), b.get("severity", "")]
                                               for b in rows]) + [""]


def _counts_text(counts: Dict[str, int], cfg: dict) -> str:
    parts = [f"{counts[r]} {_status(cfg, r)}" for r in core.CASE_ROLES if counts.get(r)]
    return ", ".join(parts)


# ---------------------------------------------------------------- spec Doc


def overview_page(c: cards_mod.Cards) -> str:
    spec = c.spec
    lines = [f"# {spec.get('title', '')}", "", str(spec.get("overview", "")).strip(), ""]
    if c.cards:
        lines += ["## What is covered", ""]
        if len(c.cards) > 1:
            lines += _table(["Role", "Scenario", "Priority"],
                            [[k.roleName, k.title, PRIORITY_WORD.get(k.priority, k.priority)] for k in c.cards])
        else:
            k = c.cards[0]
            lines.append(f"{k.roleName}: {k.title}. Priority: {PRIORITY_WORD.get(k.priority, k.priority).lower()}.")
        lines.append("")
    out_scope = [x for x in spec.get("outOfScope", []) if str(x).strip()]
    if out_scope:
        lines += ["## Left out", ""] + [f"- {x}" for x in out_scope] + [""]
    return _join(lines)


def scenario_page(card: cards_mod.Card, history: List[dict], cfg: dict, retired: bool = False) -> str:
    lines: List[str] = []
    if retired:
        lines += [RETIRED, ""]
    lines += [f"# {card.title}", ""]
    if card.storyline.strip():
        lines += [card.storyline.strip(), ""]
    if card.checks:
        lines += ["## Checks", ""]
        for i, ch in enumerate(card.checks, 1):
            lines += [f"{i}. **{ch.title}**", f"   - Do: {ch.do}", f"   - Expect: {ch.expect}"]
        lines.append("")
    lines += ["## Results by run", ""]
    rows = [[h.get("run", ""), _status(cfg, h.get("result"))] for h in history or []]
    if not rows:
        lines.append(NO_RUN)
    elif len(rows) == 1:
        lines.append(f"{_cell(rows[0][0])}: {rows[0][1]}")
    else:
        lines += _table(["Run", "Result"], rows)
    lines.append("")
    return _join(lines)


def results_page(label: str, states: List[spec_runs.CheckState], c: cards_mod.Cards, links: Dict[str, str],
                 bugs: List[dict], ready: Tuple[Optional[bool], List[str]], report_url: Optional[str],
                 cfg: dict) -> str:
    total = spec_runs.counts(states)
    lines = [f"# {label}", ""]
    n = len(states)
    summary = f"{n} {'check' if n == 1 else 'checks'}"
    detail = _counts_text(total, cfg)
    lines.append(f"{summary}: {detail}." if detail else f"{summary}.")
    review = total.get("needs_review", 0)
    if review:
        lines.append(f"A person needs to confirm {review} {'result' if review == 1 else 'results'}.")
    is_ready, reasons = ready if ready else (None, [])
    if is_ready is True:
        lines.append("Ready to ship.")
    elif is_ready is False:
        lines += ["Not ready to ship."] + ([""] + [f"- {r}" for r in reasons] if reasons else [])
    if report_url:
        lines += ["", f"Full report: {report_url}"]
    lines.append("")

    by_card: Dict[str, List[spec_runs.CheckState]] = {}
    for s in states:
        by_card.setdefault(s.card_id, []).append(s)
    lines += ["## Scenarios", ""]
    rows = [[k.title, _status(cfg, spec_runs.card_role(by_card.get(k.id, []))),
             _link("Open ticket", links.get(k.id)) if links.get(k.id) else ""] for k in c.cards]
    if len(rows) > 1:
        lines += _table(["Scenario", "Result", "Ticket"], rows)
    elif rows:
        lines.append(f"{rows[0][0]}: {rows[0][1]}." + (f" {rows[0][2]}" if rows[0][2] else ""))
    lines.append("")

    attention: List[str] = []
    for k in c.cards:
        by_crit = {}
        for s in by_card.get(k.id, []):
            by_crit.setdefault(s.criterion, s)
        for ch in k.checks:
            s = by_crit.get(ch.criterion)
            if s and (s.role in ("failed", "blocked") or s.needs_review):
                text = f"- {k.title}, {ch.title}: {_status(cfg, s.role)}."
                attention.append(text + (f" {s.note}" if s.note else ""))
    if attention:
        lines += ["## Needs attention", ""] + attention + [""]

    lines += _bugs_section(bugs)
    return _join(lines)


# ---------------------------------------------------------------- project Doc


def project_page(specs: List[dict], bugs: List[dict], cfg: dict) -> str:
    lines = [f"# {PROJECT_DOC}", "", "## Specs", ""]
    rows = []
    for sp in sorted(specs or [], key=lambda s: str(s.get("title", ""))):
        title = _link(sp.get("title", ""), sp.get("url"))
        if not sp.get("latestRun"):
            rows.append([title, NO_RUN, "", ""])
            continue
        ok = sp.get("ready")
        rows.append([title, sp["latestRun"], _counts_text(sp.get("counts") or {}, cfg),
                     "Yes" if ok is True else "No" if ok is False else "Not known"])
    if not rows:
        lines.append("No specs yet.")
    elif len(rows) == 1:
        r = rows[0]
        lines.append(f"{r[0]}. " + (r[1] if r[1] == NO_RUN else f"Latest run: {r[1]}. {r[2]}. Ready to ship: {r[3].lower()}."))
    else:
        lines += _table(["Spec", "Latest run", "Results", "Ready to ship"], rows)
    lines.append("")
    lines += _bugs_section(bugs)
    return _join(lines)
