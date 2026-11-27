"""The markdown of the ClickUp Docs pages (A9). Pure: values in, text out; no network, no files.

Spec Doc: an Overview page, one page per scenario and one Results page per run. The project's
"QA overview" Doc is the dashboard. Task 9 pushes these pages, whole, on every `push-docs`.

Pages are read by admins, testers and customers: plain short sentences, the project's own status
names, ClickUp links the caller passes in. Nothing here builds a URL or prints an id, a run id or
a file name. Output is deterministic: cards keep their file order, checks theirs, bugs are sorted
by severity then title.

A page never reads better than the counts it shows: it says ready to ship only when the caller's
flag is `True`, at least one check exists and none is failed, blocked, open, in testing or
waiting for a person's review. A result outside the six status roles reads as not tested yet.

Text from the cards file and the caller is kept from changing the page's shape: `[`, `]` in link
text and `|` in table cells are escaped, headings and list items are one line, and a storyline or
overview line that starts with `#` is escaped so it stays text.
"""
from __future__ import annotations

import re
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
NO_SCENARIOS = "No scenarios."
NOT_FINISHED = "Some checks are not finished or need a person's review."
FIXED_SENTENCES: Tuple[str, ...] = (NO_RUN, RETIRED, NO_BUGS, NO_SCENARIOS, NOT_FINISHED)

PRIORITY_WORD = {"P1": "High", "P2": "Medium", "P3": "Low"}
SEVERITY_ORDER = ("critical", "high", "medium", "low")


# What a count must be zero in for a page to say ready.
_OPEN_KEYS = ("failed", "blocked", "to_test", "testing", "needs_review")
_PIPE_RE = re.compile(r"(?<!\\)\|")
_BRACKET_RE = re.compile(r"(?<!\\)([\[\]])")
_HASH_RE = re.compile(r"^(\s*)#")


def _text(text) -> str:
    """One trimmed line: for headings, list items and sentences."""
    return " ".join(str(text if text is not None else "").split())


def _cell(text) -> str:
    """One line for a table cell; a `|` is escaped (once), never replaced."""
    return _PIPE_RE.sub(r"\\|", _text(text))


def _para(text) -> str:
    """Free text with its line breaks; a line that starts with `#` is escaped so it stays text."""
    return "\n".join(_HASH_RE.sub(r"\1\\#", line) for line in str(text if text is not None else "").strip().splitlines())


def _count(counts, key: str) -> Optional[int]:
    value = counts.get(key, 0) if isinstance(counts, dict) else 0
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _all_done(counts) -> bool:
    """Whether these counts allow "ready": a check exists and none is failed, blocked, open, in
    testing or waiting for a review. A count that is not a number never allows it."""
    if any(_count(counts, key) != 0 for key in _OPEN_KEYS):
        return False
    done = [_count(counts, key) for key in ("passed", "skipped")]
    return None not in done and sum(done) >= 1


def _table(header: List[str], rows: List[List[str]]) -> List[str]:
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    out += ["| " + " | ".join(_cell(c) for c in row) + " |" for row in rows]
    return out


def _link(text: str, url: Optional[str]) -> str:
    if not url:
        return _text(text)
    label = _BRACKET_RE.sub(lambda m: chr(92) + m.group(1), _text(text))
    if (len(label) - len(label.rstrip(chr(92)))) % 2:
        label += chr(92)  # a lone backslash at the end would escape the bracket that closes the text
    return f"[{label}]({url})"


def _status(cfg: dict, role) -> str:
    """The project's name for a status role; anything outside the six roles reads as `to_test`."""
    known = isinstance(role, str) and role in core.CASE_ROLES
    return core.status_name(cfg, "case", role if known else "to_test")


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
        return out + [f"{_link(b.get('title', ''), b.get('url'))}, {_text(b.get('severity', '')) or 'severity not set'}.", ""]
    return out + _table(["Bug", "Severity"], [[_link(b.get("title", ""), b.get("url")), b.get("severity", "")]
                                               for b in rows]) + [""]


def _counts_text(counts: Dict[str, int], cfg: dict) -> str:
    counts = counts if isinstance(counts, dict) else {}
    parts = [f"{_text(counts[r])} {_status(cfg, r)}" for r in core.CASE_ROLES if counts.get(r)]
    return ", ".join(parts)


# ---------------------------------------------------------------- spec Doc


def overview_page(c: cards_mod.Cards) -> str:
    spec = c.spec
    lines = [f"# {_text(spec.get('title', ''))}", "", _para(spec.get("overview", "")), ""]
    if c.cards:
        lines += ["## What is covered", ""]
        if len(c.cards) > 1:
            lines += _table(["Role", "Scenario", "Priority"],
                            [[k.roleName, k.title, PRIORITY_WORD.get(k.priority, k.priority)] for k in c.cards])
        else:
            k = c.cards[0]
            lines.append(f"{_text(k.roleName)}: {_text(k.title)}. "
                         f"Priority: {_text(PRIORITY_WORD.get(k.priority, k.priority)).lower()}.")
        lines.append("")
    out_scope = [x for x in spec.get("outOfScope", []) if str(x).strip()]
    if out_scope:
        lines += ["## Left out", ""] + [f"- {_text(x)}" for x in out_scope] + [""]
    return _join(lines)


def scenario_page(card: cards_mod.Card, history: List[dict], cfg: dict, retired: bool = False) -> str:
    lines: List[str] = []
    if retired:
        lines += [RETIRED, ""]
    lines += [f"# {_text(card.title)}", ""]
    if str(card.storyline or "").strip():
        lines += [_para(card.storyline), ""]
    if card.checks:
        lines += ["## Checks", ""]
        for i, ch in enumerate(card.checks, 1):
            lines += [f"{i}. **{_text(ch.title)}**", f"   - Do: {_text(ch.do)}", f"   - Expect: {_text(ch.expect)}"]
        lines.append("")
    lines += ["## Results by run", ""]
    rows = [[h.get("run", ""), _status(cfg, h.get("result"))] for h in history or []]
    if not rows:
        lines.append(NO_RUN)
    elif len(rows) == 1:
        lines.append(f"{_text(rows[0][0])}: {rows[0][1]}")
    else:
        lines += _table(["Run", "Result"], rows)
    lines.append("")
    return _join(lines)


def results_page(label: str, states: List[spec_runs.CheckState], c: cards_mod.Cards, links: Dict[str, str],
                 bugs: List[dict], ready: Tuple[Optional[bool], List[str]], report_url: Optional[str],
                 cfg: dict) -> str:
    total = spec_runs.counts(states)
    lines = [f"# {_text(label)}", ""]
    n = len(states)
    summary = f"{n} {'check' if n == 1 else 'checks'}"
    detail = _counts_text(total, cfg)
    lines.append(f"{summary}: {detail}." if detail else f"{summary}.")
    review = total.get("needs_review", 0)
    if review:
        lines.append(f"A person needs to confirm {review} {'result' if review == 1 else 'results'}.")
    is_ready, reasons = ready if ready else (None, [])
    if is_ready is True and not _all_done(total):
        # The flag says ready and the counts on this page do not: the counts win.
        is_ready, reasons = False, [NOT_FINISHED]
    if is_ready is True:
        lines.append("Ready to ship.")
    elif is_ready is False:
        reasons = [_text(r) for r in reasons or [] if _text(r)]
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
        lines.append(f"{_text(rows[0][0])}: {rows[0][1]}." + (f" {rows[0][2]}" if rows[0][2] else ""))
    else:
        lines.append(NO_SCENARIOS)
    lines.append("")

    attention: List[str] = []
    for k in c.cards:
        by_crit = {}
        for s in by_card.get(k.id, []):
            by_crit.setdefault(s.criterion, s)
        for ch in k.checks:
            s = by_crit.get(ch.criterion)
            if s and (s.role in ("failed", "blocked") or s.needs_review):
                text = f"- {_text(k.title)}, {_text(ch.title)}: {_status(cfg, s.role)}."
                attention.append(text + (f" {_text(s.note)}" if s.note else ""))
    if attention:
        lines += ["## Needs attention", ""] + attention + [""]

    lines += _bugs_section(bugs)
    return _join(lines)


# ---------------------------------------------------------------- project Doc


def project_page(specs: List[dict], bugs: List[dict], cfg: dict) -> str:
    lines = [f"# {PROJECT_DOC}", "", "## Specs", ""]
    rows = []  # [spec, latest run, results, ready word, reason sentence or ""]
    for sp in sorted(specs or [], key=lambda s: str(s.get("title", ""))):
        title = _link(sp.get("title", ""), sp.get("url"))
        if not sp.get("latestRun"):
            rows.append([title, NO_RUN, "", "", ""])
            continue
        counts = sp.get("counts")
        ok = sp.get("ready")
        if ok is True and _all_done(counts):
            word, why = "Yes", ""
        elif ok is True:
            # The flag says ready and the counts shown beside it do not: the counts win.
            word, why = "No", NOT_FINISHED
        else:
            word, why = ("No" if ok is False else "Not known"), ""
        rows.append([title, _text(sp["latestRun"]), _counts_text(counts, cfg), word, why])
    if not rows:
        lines.append("No specs yet.")
    elif len(rows) == 1:
        r = rows[0]
        if r[1] == NO_RUN:
            lines.append(f"{r[0]}. {NO_RUN}")
        else:
            parts = [f"{r[0]}.", f"Latest run: {r[1]}."] + ([f"{r[2]}."] if r[2] else [])
            parts.append(f"Ready to ship: {r[3].lower()}." + (f" {r[4]}" if r[4] else ""))
            lines.append(" ".join(parts))
    else:
        lines += _table(["Spec", "Latest run", "Results", "Ready to ship"],
                        [[r[0], r[1], r[2], f"{r[3]}. {r[4]}" if r[4] else r[3]] for r in rows])
    lines.append("")
    lines += _bugs_section(bugs)
    return _join(lines)
