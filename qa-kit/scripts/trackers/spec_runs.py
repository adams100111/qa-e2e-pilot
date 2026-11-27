"""A run's recorded results as ticket states (A6). Pure: reads run files, calls nothing.

`states` gives one `CheckState` per check of the cards file: the status role, whether a person
has to review it, a plain note, and the screenshots to attach. `card_role` rolls a card's checks
up, `counts` totals them, `missing_evidence` lists the checks whose recorded screenshot is not on
disk (P11) and `ready` reads the run's ship verdict.

Nothing here makes a result look better than the engine recorded it (ADR-0032, ADR-0033): a
non-pass never maps to `passed`, and a pass whose confidence is not exactly `high` stays in
`testing` until a person confirms it.

Screenshots are located the way `scripts/render-report.js` `collectEvidence` does (ADR-0028):
the folder `evidence/<persona>/<criterion>` (`evidence/<criterion>` for a row without a persona)
of the run, its `screenshot-*.json` records (each names its image in `image`), any other image in
that folder, and the image paths in the row's `evidence_refs`; ordered before, after, other.

`ready` does not work a ship verdict out. It reads the one the engine rendered into the run's
`report.md` ("## Ship readiness"), and gives `None` when that is not there.
"""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import cards as cards_mod
from . import core

VERDICT_ROLE = {"pass": "passed", "fail": "failed", "blocked": "blocked", "error": "blocked",
                "deferred": "skipped"}
# Card roll-up, worst first.
ROLLUP_ORDER = ("failed", "blocked", "testing", "to_test", "skipped", "passed")

NOTE_ERROR = "Could not be checked on this run."
NOTE_REVIEW = "Passed on this run. A person needs to confirm the expected result."
NOTE_DEFERRED = "Not checked on this run. It was left for a later run."

REASON_UNKNOWN = "Another condition is not met; see the Results page."
# The engine's ship conditions (scripts/render-report.js buildShip) in plain words. First match
# wins; the engine's text itself is never shown.
REASON_TABLE: Tuple[Tuple[str, str], ...] = (
    (r"census surface\(s\) uncovered$", "Some screens have not been checked yet."),
    (r"^census (is empty|coverage unknown|adapter failed)$", "The list of screens to check is not complete."),
    (r"^no P1 journeys declared$", "No main user journey is listed for this run."),
    (r"^P1 journey ", "A main user journey did not pass."),
    (r"^(coding-layer fail on P1|fail on P1 with unknown layer) ", "A top priority check failed."),
    (r"^not independently verified$", "The results have not had their second check yet."),
    (r"^verifier override on P1 ", "The second check did not confirm a top priority result."),
    (r"^verification out of date on P1 ", "The second check is out of date for a top priority result."),
    (r"^verifier disputed P1 ", "A reviewer did not confirm a top priority result."),
    (r"P1 low-confidence pass\(es\) (not re-judged|unreviewed)", "A top priority result still needs a person to confirm it."),
    (r"^re-adjudication decision on P1 .* was not applied$", "A review of a top priority result was not recorded."),
    (r"^adjudication/decisions\.json is not a JSON array$", "The review of the results could not be read."),
)
_REASON_RES = tuple((re.compile(p), text) for p, text in REASON_TABLE)

FIXED_SENTENCES: Tuple[str, ...] = (NOTE_ERROR, NOTE_REVIEW, NOTE_DEFERRED, REASON_UNKNOWN) + tuple(
    text for _, text in REASON_TABLE)

REPORT_NAME = "report.md"
SHIP_HEADING = "## Ship readiness"
_IMAGE_RE = re.compile(r"\.(png|jpe?g|webp|gif)$", re.IGNORECASE)
_SIDECAR_RE = re.compile(r"^screenshot-.*\.json$")
_PHASE_ORDER = {"before": 0, "after": 1, "image": 2}
DEFAULT_CAP = 3


@dataclass
class CheckState:
    card_id: str
    criterion: str
    persona: str  # the recorded row's persona ("" for a row without one); the card's role if not run
    role: Optional[str]  # a status role, or None when the check has not run yet (counts as to_test)
    needs_review: bool = False
    note: Optional[str] = None
    evidence: List[Path] = field(default_factory=list)
    raised: bool = False


# ---------------------------------------------------------------- screenshots


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _screenshots(run_dir: Path, criterion: str, persona: str, row: dict) -> Tuple[List[Path], bool]:
    """`(files that exist, in the report's order; whether a recorded screenshot is unusable)`.

    Unusable = a screenshot record or an `evidence_refs` image whose file is not there, or a
    recorded image whose content no longer matches its record.
    """
    rel_dir = f"evidence/{persona}/{criterion}" if persona else f"evidence/{criterion}"
    abs_dir = run_dir / rel_dir
    try:
        names = sorted(p.name for p in abs_dir.iterdir())
    except OSError:
        names = []

    shots: List[Tuple[int, str, Path]] = []  # (phase order, path relative to the run, file)
    missing = False
    claimed = set()
    for n in names:
        if not _SIDECAR_RE.match(n):
            continue
        try:
            sc = json.loads((abs_dir / n).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        image = sc.get("image") if isinstance(sc, dict) else None
        if not isinstance(image, str) or not image or re.search(r"[/\\]|\.\.", image):
            continue
        claimed.add(image)
        img = abs_dir / image
        if not img.is_file():
            missing = True
            continue
        try:
            intact = _sha256(img) == sc.get("sha256")
        except OSError:
            intact = False
        if not intact:
            missing = True
            continue
        phase = sc.get("phase") if sc.get("phase") in ("before", "after") else "image"
        shots.append((_PHASE_ORDER[phase], f"{rel_dir}/{image}", img))

    loose = [f"{rel_dir}/{n}" for n in names if _IMAGE_RE.search(n) and n not in claimed]
    known = {rel for _, rel, _ in shots} | set(loose) | {f"{rel_dir}/{n}" for n in claimed}
    refs = row.get("evidence_refs") if isinstance(row, dict) else None
    for ref in refs if isinstance(refs, list) else []:
        if not isinstance(ref, str) or not _IMAGE_RE.search(ref) or ".." in ref or ref.startswith("/"):
            continue
        if ref in known:
            continue
        known.add(ref)
        if (run_dir / ref).is_file():
            loose.append(ref)
        else:
            missing = True
    for rel in loose:
        img = run_dir / rel
        if not img.is_file():
            continue
        base = rel.rsplit("/", 1)[-1].lower()
        phase = "before" if "before" in base else ("after" if "after" in base else "image")
        shots.append((_PHASE_ORDER[phase], rel, img))
    shots.sort(key=lambda s: (s[0], s[1]))
    return [img for _, _, img in shots], missing


def _wanted(role: Optional[str], mode: str, found: int) -> int:
    """How many of a check's screenshots its ticket gets, before the cap."""
    if mode not in ("standard", "failures"):
        return 0
    if role in ("failed", "blocked"):
        return found
    if role in ("passed", "testing") and mode == "standard":
        return min(found, 1)
    return 0


def _cap(cfg: dict) -> int:
    cap = (cfg or {}).get("evidenceCap", DEFAULT_CAP)
    if isinstance(cap, bool) or not isinstance(cap, int):
        return DEFAULT_CAP
    return max(cap, 0)


def _mode(cfg: dict) -> str:
    mode = (cfg or {}).get("evidence", "standard")
    return mode if mode in core.EVIDENCE_LEVELS else "none"


# ---------------------------------------------------------------- states


def _row_for(rows: Dict[Tuple[str, str], dict], c: cards_mod.Cards, card: cards_mod.Card,
             criterion: str) -> Optional[Tuple[str, dict]]:
    """The recorded row of `criterion` that belongs to `card`: the one recorded as the card's
    role, else the one recorded without a persona when this is the only card holding it."""
    got = rows.get((criterion, card.role))
    if got is not None:
        return card.role, got
    got = rows.get((criterion, ""))
    if got is not None and cards_mod.card_for(c, criterion, "") is card:
        return "", got
    return None


def _build(run_dir: Path, c: cards_mod.Cards, cfg: dict) -> Tuple[List[CheckState], List[Tuple[str, str]]]:
    run_dir = Path(run_dir)
    rows = core.criterion_rows(run_dir)
    mode, cap = _mode(cfg), _cap(cfg)
    out: List[CheckState] = []
    missing: List[Tuple[str, str]] = []
    for card in c.cards:
        for ck in card.checks:
            hit = _row_for(rows, c, card, ck.criterion)
            if hit is None:
                out.append(CheckState(card_id=card.id, criterion=ck.criterion, persona=card.role, role=None))
                continue
            persona, got = hit
            verdict = got["verdict"] if got["verdict"] in VERDICT_ROLE else "error"
            role = VERDICT_ROLE[verdict]
            needs_review, note = False, None
            if verdict == "pass" and got["confidence"] != "high":
                role, needs_review, note = "testing", True, NOTE_REVIEW
            elif verdict == "error":
                note = NOTE_ERROR
            elif verdict == "deferred":
                note = NOTE_DEFERRED
            evidence: List[Path] = []
            if mode != "none":
                found, lost = _screenshots(run_dir, ck.criterion, persona, got["row"])
                evidence = found[:min(_wanted(role, mode, len(found)), cap)]
                if lost and _wanted(role, mode, 1) and (ck.criterion, persona) not in missing:
                    missing.append((ck.criterion, persona))
            raised = card.as_ == "checklist" and (role in ("failed", "blocked") or needs_review)
            out.append(CheckState(card_id=card.id, criterion=ck.criterion, persona=persona, role=role,
                                  needs_review=needs_review, note=note, evidence=evidence, raised=raised))
    return out, missing


def states(run_dir: Path, c: cards_mod.Cards, cfg: dict) -> List[CheckState]:
    """One state per check, in the cards file's order. Raises `core.RunError` when the run has
    no `checkpoint.json`."""
    return _build(run_dir, c, cfg)[0]


def missing_evidence(run_dir: Path, c: cards_mod.Cards, cfg: dict) -> List[Tuple[str, str]]:
    """`(criterion, persona)` of each check that would get screenshots and has a recorded one
    that is not on disk or no longer matches its record. Reported, never an error (P11)."""
    return _build(run_dir, c, cfg)[1]


def card_role(states_of_card: List[CheckState]) -> str:
    """The status role of a card: the worst of its checks, and `testing` while some checks have
    a result and others are still open or wait for a review."""
    roles = [s.role or "to_test" for s in states_of_card]
    if not roles:
        return "to_test"
    for bad in ("failed", "blocked"):
        if bad in roles:
            return bad
    if "testing" in roles:
        return "testing"
    if "to_test" in roles:
        return "to_test" if all(r == "to_test" for r in roles) else "testing"
    return "skipped" if "skipped" in roles else "passed"


def counts(states: List[CheckState]) -> Dict[str, int]:
    out = {role: 0 for role in core.CASE_ROLES}
    out["needs_review"] = 0
    for s in states:
        out[s.role or "to_test"] += 1
        if s.needs_review:
            out["needs_review"] += 1
    return out


# ---------------------------------------------------------------- ship verdict


def plain_reason(condition: str) -> str:
    for rx, text in _REASON_RES:
        if rx.search(condition):
            return text
    return REASON_UNKNOWN


def ready(run_dir: Path) -> Tuple[Optional[bool], List[str]]:
    """The run's ship verdict as the engine rendered it, and why not in plain words.

    Read from the "## Ship readiness" section of the run's `report.md`: `(True, [])` for
    SHIP-READY, `(False, reasons)` for NOT SHIP-READY, `(None, [])` when the report or the
    section is absent or cannot be read. Never worked out here.
    """
    try:
        lines = (Path(run_dir) / REPORT_NAME).read_text(encoding="utf-8").splitlines()
    except (OSError, ValueError):
        return None, []
    try:
        at = next(i for i, line in enumerate(lines) if line.strip() == SHIP_HEADING)
    except StopIteration:
        return None, []
    body = [line.strip() for line in lines[at + 1:]]
    body = body[next((i for i, line in enumerate(body) if line), len(body)):]
    if not body or body[0] not in ("**SHIP-READY**", "**NOT SHIP-READY**"):
        return None, []
    conditions: List[str] = []
    for line in body[1:]:
        if not line:
            if conditions:
                break
            continue
        if not line.startswith("- "):
            break
        conditions.append(line[2:].strip())
    reasons: List[str] = []
    for cond in conditions:
        text = plain_reason(cond)
        if text not in reasons:
            reasons.append(text)
    if body[0] == "**SHIP-READY**" and not conditions:
        return True, []
    return False, reasons
