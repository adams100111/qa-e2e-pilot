"""A run's recorded results as ticket states (A6). Pure: reads run files, calls nothing.

`states` gives one `CheckState` per check of the cards file: the status role, whether a person
has to review it, a plain note, and the screenshots to attach. `card_role` rolls a card's checks
up, `counts` totals them, `missing_evidence` lists the checks whose recorded screenshot cannot be
used (P11), `unjoined` lists the recorded rows that belong to no card and `ready` reads the run's
ship verdict.

Nothing here makes a result look better than the engine recorded it (ADR-0032, ADR-0033): a
non-pass never maps to `passed`, and a pass stays in `testing` until a person confirms it unless
both its recorded confidence and its confidence after verification are exactly `high`. When a
card is the only holder of a criterion and the run has both a row for the card's role and a live
row without a persona, the worse of the two is shown.

Screenshots are located the way `scripts/render-report.js` `collectEvidence` does (ADR-0028):
the folder `evidence/<persona>/<criterion>` (`evidence/<criterion>` for a row without a persona)
of the run, its `screenshot-*.json` records (each names its image in `image`), any other image in
that folder, and the image paths in the row's `evidence_refs`; ordered before, after, other.
The ids are joined as they are, so an id with `:` is one folder and an id with `/` is nested
folders. Unlike the report, which only shows files, these picks are uploaded: every file is
resolved and kept only when it is an image inside the run folder. A link that leaves the run, a
persona or criterion id with `..` or an absolute path, and a recorded file that is not an image
are dropped and reported by `missing_evidence`.

`ready` does not work a ship verdict out. It reads the one the engine rendered into the run's
`report.md` ("## Ship readiness"), and gives `None` when that is not there or not in the engine's
shape. A section that says NOT SHIP-READY anywhere is never read as ready.
"""
from __future__ import annotations

import hashlib
import json
import os
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
# The two verdict lines scripts/render-report.js mdShip writes, at column 0.
SHIP_READY_LINE = "**SHIP-READY**"
SHIP_NOT_READY_LINE = "**NOT SHIP-READY**"
SHIP_NOT_READY_MARK = "NOT SHIP-READY"
_HEADING_RE = re.compile(r"^#{1,6}(\s|$)")
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


_HASHES: Dict[Tuple[str, int, int], str] = {}
_HASHES_MAX = 4096


def _hash_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _sha256(path: Path) -> str:
    """The file's digest, read once per file state (path, change time, size), so `states` and
    `missing_evidence` of one sync do not read every image twice."""
    st = path.stat()
    key = (str(path), st.st_mtime_ns, st.st_size)
    got = _HASHES.get(key)
    if got is None:
        if len(_HASHES) >= _HASHES_MAX:
            _HASHES.clear()
        got = _HASHES[key] = _hash_file(path)
    return got


def _unsafe_segment(value: str) -> bool:
    """A persona or criterion id that must not be joined into a path."""
    return ".." in value or os.path.isabs(value)


def _inside(root: Path, path: Path) -> Optional[Path]:
    """`path` with every link followed, when that is a file inside `root` (already resolved)."""
    try:
        real = path.resolve()
        real.relative_to(root)
    except (OSError, ValueError, RuntimeError):
        return None
    return real if real.is_file() else None


def _screenshots(run_dir: Path, criterion: str, persona: str, row: dict) -> Tuple[List[Tuple[str, Path]], bool]:
    """`((phase, file) of each usable image, in the report's order; whether one is unusable)`.

    Every file returned is an image inside the run folder, with links followed. Unusable = a
    screenshot record or an `evidence_refs` image whose file is not there, is not an image, is
    outside the run, or no longer matches its record; or an id that cannot be a folder name.
    """
    root = Path(run_dir).resolve()
    if _unsafe_segment(criterion) or (persona and _unsafe_segment(persona)):
        return [], True
    rel_dir = f"evidence/{persona}/{criterion}" if persona else f"evidence/{criterion}"
    abs_dir = root / rel_dir
    missing = False
    names: List[str] = []
    try:
        abs_dir.resolve().relative_to(root)
        names = sorted(p.name for p in abs_dir.iterdir())
    except ValueError:
        missing = True  # the evidence folder is a link that leaves the run
    except (OSError, RuntimeError):
        pass

    shots: List[Tuple[int, str, str, Path]] = []  # (phase order, path relative to the run, phase, file)
    claimed = set()
    for n in names:
        if not _SIDECAR_RE.match(n):
            continue
        sidecar = _inside(root, abs_dir / n)
        if sidecar is None:
            missing = True
            continue
        try:
            sc = json.loads(sidecar.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        image = sc.get("image") if isinstance(sc, dict) else None
        if not isinstance(image, str) or not image:
            continue
        if re.search(r"[/\\]|\.\.", image) or not _IMAGE_RE.search(image):
            missing = True
            continue
        claimed.add(image)
        img = _inside(root, abs_dir / image)
        if img is None:
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
        shots.append((_PHASE_ORDER[phase], f"{rel_dir}/{image}", phase, img))

    loose = [f"{rel_dir}/{n}" for n in names if _IMAGE_RE.search(n) and n not in claimed]
    known = {rel for _, rel, _, _ in shots} | set(loose) | {f"{rel_dir}/{n}" for n in claimed}
    refs = row.get("evidence_refs") if isinstance(row, dict) else None
    for ref in refs if isinstance(refs, list) else []:
        if not isinstance(ref, str) or not _IMAGE_RE.search(ref):
            continue
        if ".." in ref or os.path.isabs(ref):
            missing = True
            continue
        if ref in known:
            continue
        known.add(ref)
        loose.append(ref)
    for rel in loose:
        img = _inside(root, root / rel)
        if img is None:
            missing = True
            continue
        base = rel.rsplit("/", 1)[-1].lower()
        phase = "before" if "before" in base else ("after" if "after" in base else "image")
        shots.append((_PHASE_ORDER[phase], rel, phase, img))
    shots.sort(key=lambda s: (s[0], s[1]))
    out: List[Tuple[str, Path]] = []
    for _, _, phase, img in shots:
        if all(img != seen for _, seen in out):
            out.append((phase, img))
    return out, missing


def _wants(role: Optional[str], needs_review: bool, mode: str) -> bool:
    """Whether a check's ticket gets screenshots at all."""
    if mode not in ("standard", "failures"):
        return False
    if needs_review or role in ("failed", "blocked"):
        return True
    return role == "passed" and mode == "standard"


def _pick(shots: List[Tuple[str, Path]], role: Optional[str], needs_review: bool, mode: str, cap: int) -> List[Path]:
    """A failed, blocked or waiting-for-review check gets its screenshots up to the cap. A passed
    check gets one in `standard` mode: the first after-state image, else the first image."""
    if not _wants(role, needs_review, mode):
        return []
    if needs_review or role in ("failed", "blocked"):
        return [img for _, img in shots][:cap]
    after = [img for phase, img in shots if phase == "after"]
    return (after or [img for _, img in shots])[:min(cap, 1)]


def _cap(cfg: dict) -> int:
    cap = (cfg or {}).get("evidenceCap", DEFAULT_CAP)
    if isinstance(cap, bool) or not isinstance(cap, int):
        return DEFAULT_CAP
    return max(cap, 0)


def _mode(cfg: dict) -> str:
    mode = (cfg or {}).get("evidence", "standard")
    return mode if mode in core.EVIDENCE_LEVELS else "none"


# ---------------------------------------------------------------- states


def _judge(got: dict) -> Tuple[str, bool, Optional[str]]:
    """`(status role, needs review, note)` of one recorded row."""
    verdict = got["verdict"] if got["verdict"] in VERDICT_ROLE else "error"
    if verdict == "pass":
        row = got.get("row")
        recorded = row.get("confidence") if isinstance(row, dict) else None
        # The lower of the recorded confidence and the one after verification: both must be high.
        if recorded == "high" and got["confidence"] == "high":
            return "passed", False, None
        return "testing", True, NOTE_REVIEW
    note = NOTE_ERROR if verdict == "error" else NOTE_DEFERRED if verdict == "deferred" else None
    return VERDICT_ROLE[verdict], False, note


def _candidates(rows: Dict[Tuple[str, str], dict], c: cards_mod.Cards, card: cards_mod.Card,
                criterion: str) -> List[Tuple[str, dict]]:
    """The recorded rows of `criterion` that belong to `card`: the one recorded as the card's
    role, and the one recorded without a persona when this is the only card holding it."""
    out: List[Tuple[str, dict]] = []
    got = rows.get((criterion, card.role))
    if got is not None:
        out.append((card.role, got))
    if card.role:
        got = rows.get((criterion, ""))
        if got is not None and cards_mod.card_for(c, criterion, "") is card:
            out.append(("", got))
    return out


def _joined(run_dir: Path, c: cards_mod.Cards):
    """`(per check: (card, check, None or (persona, row, role, needs review, note)), rows, used keys)`.

    With two rows for one check the worse one is taken, by `ROLLUP_ORDER`; equal rows keep the
    one recorded as the card's role.
    """
    rows = core.criterion_rows(Path(run_dir))
    used = set()
    out = []
    for card in c.cards:
        for ck in card.checks:
            best = None
            for persona, got in _candidates(rows, c, card, ck.criterion):
                used.add((ck.criterion, persona))
                role, needs_review, note = _judge(got)
                if best is None or ROLLUP_ORDER.index(role) < ROLLUP_ORDER.index(best[2]):
                    best = (persona, got, role, needs_review, note)
            out.append((card, ck, best))
    return out, rows, used


def _build(run_dir: Path, c: cards_mod.Cards, cfg: dict) -> Tuple[List[CheckState], List[Tuple[str, str]]]:
    run_dir = Path(run_dir)
    mode, cap = _mode(cfg), _cap(cfg)
    out: List[CheckState] = []
    missing: List[Tuple[str, str]] = []
    for card, ck, hit in _joined(run_dir, c)[0]:
        if hit is None:
            out.append(CheckState(card_id=card.id, criterion=ck.criterion, persona=card.role, role=None))
            continue
        persona, got, role, needs_review, note = hit
        evidence: List[Path] = []
        if _wants(role, needs_review, mode):
            found, lost = _screenshots(run_dir, ck.criterion, persona, got["row"])
            evidence = _pick(found, role, needs_review, mode, cap)
            if lost and (ck.criterion, persona) not in missing:
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
    that cannot be used: not on disk, not an image, outside the run folder, or no longer matching
    its record. Reported, never an error (P11)."""
    return _build(run_dir, c, cfg)[1]


def unjoined(run_dir: Path, c: cards_mod.Cards) -> List[Tuple[str, str, str]]:
    """`(criterion, persona, verdict)` of each recorded row that belongs to no card, sorted, so
    the sync can report them. Raises `core.RunError` when the run has no `checkpoint.json`."""
    _, rows, used = _joined(run_dir, c)
    return sorted((cid, persona, got["verdict"]) for (cid, persona), got in rows.items()
                  if (cid, persona) not in used)


def card_role(states_of_card: List[CheckState]) -> str:
    """The status role of a card: the worst of its checks, and `testing` while some checks have
    a result and others are still open or wait for a review."""
    roles = [s.role if s.role in ROLLUP_ORDER else "to_test" for s in states_of_card]
    if not roles:
        return "to_test"
    worst = min(roles, key=ROLLUP_ORDER.index)
    if worst == "to_test" and any(r != "to_test" for r in roles):
        return "testing"
    return worst


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


def _ship_section(section: List[str]) -> Tuple[Optional[bool], List[str]]:
    """The verdict of one "## Ship readiness" section (the lines under its heading)."""
    said_not = any(SHIP_NOT_READY_MARK in line for line in section)
    body = section[next((i for i, line in enumerate(section) if line.strip()), len(section)):]
    if not body or body[0].rstrip() not in (SHIP_READY_LINE, SHIP_NOT_READY_LINE):
        return (False, []) if said_not else (None, [])
    conditions: List[str] = []
    for line in body[1:]:
        line = line.rstrip()
        if not line:
            if conditions:
                break
            continue
        if not conditions and line in (SHIP_READY_LINE, SHIP_NOT_READY_LINE):
            continue
        if not line.startswith("- "):
            break
        conditions.append(line[2:].strip())
    reasons: List[str] = []
    for cond in conditions:
        text = plain_reason(cond)
        if text not in reasons:
            reasons.append(text)
    if said_not or conditions:
        return False, reasons
    return True, []


def ready(run_dir: Path) -> Tuple[Optional[bool], List[str]]:
    """The run's ship verdict as the engine rendered it, and why not in plain words.

    Read from the "## Ship readiness" section of the run's `report.md`, whose heading and verdict
    line are matched at the start of the line as `scripts/render-report.js` writes them:
    `(True, [])` only when the one section's verdict line is the engine's ready line, it lists no
    condition and no line of it says NOT SHIP-READY; `(False, reasons)` when a section says NOT
    SHIP-READY anywhere; `(None, [])` when the report or the section is absent, cannot be read,
    appears more than once without saying not ready, or is not in the engine's shape. Never
    worked out here.
    """
    try:
        lines = (Path(run_dir) / REPORT_NAME).read_text(encoding="utf-8").splitlines()
    except (OSError, ValueError):
        return None, []
    starts = [i for i, line in enumerate(lines) if line.rstrip() == SHIP_HEADING]
    if not starts:
        return None, []
    found: List[Tuple[Optional[bool], List[str]]] = []
    for at in starts:
        end = next((j for j in range(at + 1, len(lines)) if _HEADING_RE.match(lines[j])), len(lines))
        found.append(_ship_section(lines[at + 1:end]))
    if any(ok is False for ok, _ in found):
        reasons: List[str] = []
        for ok, why in found:
            for text in why if ok is False else []:
                if text not in reasons:
                    reasons.append(text)
        return False, reasons
    return found[0] if len(found) == 1 else (None, [])
