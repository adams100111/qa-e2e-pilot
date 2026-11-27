"""Lint for one string of text that will be pushed to a tracker (A8 writing rules).

Pure: no I/O, no network. `lint_text` returns reasons (stable strings); `clean` runs the lint and
then `core.outbound`, raising `core.WordingError` with the first reason.
"""
from __future__ import annotations

import re
from typing import List

from . import core

KINDS = ("title", "body")
TITLE_MAX = 90

# Emoji and pictograph ranges, including the status symbols (check mark, cross, warning sign).
EMOJI_RE = re.compile(
    "["
    "\U0001F000-\U0001FAFF"  # mahjong, cards, flags, pictographs, symbols and emoticons
    "☀-➿"          # misc symbols and dingbats (includes the check, cross, warning signs)
    "⭐⭕⬛⬜"  # star, circle, squares
    "⌀-⏿"          # misc technical (watch, hourglass, play buttons)
    "️‍"           # emoji variation selector and zero-width joiner
    "]"
)

ID_RES = [
    # criterion or rule id: 1-5 capitals, optional hyphen, digits (C-012, J1, AC12)
    re.compile(r"(?<![A-Za-z0-9])[A-Z]{1,5}-?\d+(?![A-Za-z0-9])"),
    # commit hash: 7-40 lowercase hex characters holding at least one digit and one letter a-f
    re.compile(r"(?<![A-Za-z0-9])(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![A-Za-z0-9])"),
    # pull request or issue number: #123
    re.compile(r"#\d+\b"),
    # version: v1.2.3 or v2 style with a v prefix, or three dotted numbers
    re.compile(r"(?<![A-Za-z0-9])(?:v\d+(?:\.\d+)*|\d+\.\d+\.\d+)(?![A-Za-z0-9])"),
    # snake_case identifier: lowercase words joined by underscores
    re.compile(r"(?<![A-Za-z0-9_])[a-z][a-z0-9]*(?:_[a-z0-9]+)+(?![A-Za-z0-9_])"),
    # camelCase identifier: lowercase start, then at least one capitalised hump
    re.compile(r"(?<![A-Za-z0-9_])[a-z]+(?:[A-Z][a-z0-9]+)+(?![A-Za-z0-9_])"),
]
# a person mention: @ directly followed by a letter (any script)
PERSON_RE = re.compile(r"@[^\W\d_]")


def _wording(cfg: dict) -> dict:
    w = (cfg or {}).get("wording")
    return w if isinstance(w, dict) else {}


def _strip_allowed(text: str, allow) -> str:
    out = text
    for phrase in allow or []:
        if phrase:
            out = re.sub(re.escape(phrase), " ", out, flags=re.IGNORECASE)
    return out


def _headline_case(title: str) -> bool:
    words = title.split()
    if len(words) < 4:
        return False
    # only words that are wholly Latin letters (after trimming punctuation) count
    long_words = [w for w in (x.strip(".,;:!?()[]\"'") for x in words) if re.fullmatch(r"[A-Za-z]{4,}", w)]
    return bool(long_words) and all(w[0].isupper() for w in long_words)


def lint_text(text: str, kind: str, cfg: dict) -> List[str]:
    """Return the reasons `text` breaks the writing rules; empty when clean. `kind` is title|body."""
    if kind not in KINDS:
        raise ValueError(f"kind must be one of {', '.join(KINDS)}")
    text = text or ""
    if not text.strip():
        return ["empty"]
    wording = _wording(cfg)
    probe = _strip_allowed(text, wording.get("allow"))
    reasons: List[str] = []
    if EMOJI_RE.search(text):
        reasons.append("emoji")
    for word in wording.get("forbidden") or []:
        if re.search(r"(?<!\w)" + re.escape(word) + r"(?!\w)", probe, flags=re.IGNORECASE):
            reasons.append(f"forbidden word: {word}")
    seen = set()
    patterns = list(ID_RES)
    for p in wording.get("patterns") or []:
        try:
            patterns.append(re.compile(p))
        except re.error:
            continue
    for rx in patterns:
        for m in rx.finditer(probe):
            token = m.group(0).strip()
            if token and token not in seen:
                seen.add(token)
                reasons.append(f"looks like an id: {token}")
    if kind == "title":
        if len(text.strip()) > TITLE_MAX:
            reasons.append(f"title too long (max {TITLE_MAX})")
        if (cfg or {}).get("language", "en") == "en" and _headline_case(probe.strip()):
            reasons.append("title in headline case")
    if PERSON_RE.search(text):
        reasons.append("mentions a person")
    return reasons


def clean(text: str, kind: str, cfg: dict) -> str:
    """`core.outbound(text, cfg)` when the text lints clean; else raise `core.WordingError`
    carrying the first reason."""
    reasons = lint_text(text, kind, cfg)
    if reasons:
        raise core.WordingError(reasons[0])
    return core.outbound(text, cfg)
