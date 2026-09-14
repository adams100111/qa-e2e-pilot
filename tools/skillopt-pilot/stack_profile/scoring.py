"""Pure response extraction and deterministic semantic scoring."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any


_JSON_FENCE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL | re.IGNORECASE)
_MISSING = object()


@dataclass(frozen=True, slots=True)
class Score:
    hard: int
    soft: float
    passed: int
    total: int
    failures: tuple[str, ...]


def extract_result(text: str) -> dict[str, Any]:
    """Extract one JSON object from a plain or fenced target response."""
    source = str(text or "").strip()
    match = _JSON_FENCE.search(source)
    if match:
        source = match.group(1)
    try:
        value = json.loads(source)
    except (json.JSONDecodeError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def _resolve_path(value: Any, path: str) -> Any:
    current = value
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        elif isinstance(current, list) and part.isdigit() and int(part) < len(current):
            current = current[int(part)]
        else:
            return _MISSING
    return current


def score_result(result: dict[str, Any], assertions: list[dict[str, Any]]) -> Score:
    """Score equality/inequality assertions against dotted JSON paths."""
    if not isinstance(assertions, list) or not assertions:
        raise ValueError("assertions must be a non-empty list")

    failures: list[str] = []
    for assertion in assertions:
        path = str(assertion.get("path") or "").strip()
        operators = [name for name in ("equals", "not_equals") if name in assertion]
        if not path:
            raise ValueError("assertion path must be non-empty")
        if len(operators) != 1:
            raise ValueError("assertion must contain exactly one of equals or not_equals")

        actual = _resolve_path(result, path)
        expected = assertion[operators[0]]
        passed = actual == expected if operators[0] == "equals" else actual != expected
        if not passed:
            shown = "<missing>" if actual is _MISSING else repr(actual)
            relation = "expected" if operators[0] == "equals" else "must not equal"
            failures.append(f"{path}: {relation} {expected!r}, got {shown}")

    total = len(assertions)
    passed_count = total - len(failures)
    soft = passed_count / total
    return Score(
        hard=int(not failures),
        soft=soft,
        passed=passed_count,
        total=total,
        failures=tuple(failures),
    )

