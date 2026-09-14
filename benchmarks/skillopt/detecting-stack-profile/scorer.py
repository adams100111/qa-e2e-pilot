"""Deterministic scorer for the detecting-stack-profile benchmark.

Compares a produced ``stack-profile.json`` (as emitted by the skill's
``detect-stack.sh`` or reconstructed by a model rollout) against a
field-scoped ground-truth ``expected`` dict.

Design choices (kept deliberately narrow and honest):

* Only fields **present in ``expected``** are checked. Ground truth pins a
  field only when it is unambiguously determinable from the fixture, so a
  missing field is "not asserted", never "asserted empty".
* Framework / ORM names are compared *normalized* (lowercased, punctuation
  stripped) so ``ef-core`` == ``EF Core`` == ``efcore``. Everything else is
  compared normalized-lower too.
* ``i18n_mechanisms`` is compared as a **set**.
* ``hard`` == 1 iff every checked field matches. ``soft`` == fraction of
  checked fields that match — the training signal that moves before ``hard``
  flips.

No SkillOpt imports here on purpose: this module is runnable standalone
(see ``sanity.py``) and is the single source of scoring truth.
"""
from __future__ import annotations

import re

# expected-key -> ("component" | "top", profile-path)
_COMPONENT_FIELDS = {
    "framework": ("framework",),
    "orm": ("orm", "name"),
    "migrationsPath": ("orm", "migrationsPath"),
    "auth": ("auth", "scheme"),
    "routing": ("frontend", "routing"),
}
_TOP_FIELDS = {
    "mode": ("mode",),
    "environment": ("environment",),
}


def _norm(value) -> str:
    """Lowercase and strip non-alphanumerics for lenient identity compare."""
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def _dig(obj: dict, path: tuple[str, ...]):
    cur = obj
    for key in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def _primary_backend(profile: dict) -> dict:
    comps = profile.get("components") or []
    if not comps:
        return {}
    idx = 0
    primary = profile.get("primary") or {}
    if isinstance(primary.get("backend"), int) and 0 <= primary["backend"] < len(comps):
        idx = primary["backend"]
    comp = comps[idx]
    return comp if isinstance(comp, dict) else {}


def score(profile: dict, expected: dict) -> dict:
    """Return {hard, soft, checks[], fail_reason} for one produced profile."""
    checks: list[dict] = []
    comp = _primary_backend(profile)

    def record(field: str, got, want, ok: bool) -> None:
        checks.append({"field": field, "expected": want, "got": got, "ok": bool(ok)})

    for field, want in expected.items():
        if field == "i18n_mechanisms":
            got = _dig(comp, ("i18n", "mechanisms")) or []
            got_set = {_norm(x) for x in got} if isinstance(got, list) else {"<non-list>"}
            want_set = {_norm(x) for x in want}
            record(field, sorted(got if isinstance(got, list) else [got]), list(want), got_set == want_set)
            continue

        if field in _TOP_FIELDS:
            got = _dig(profile, _TOP_FIELDS[field])
        elif field in _COMPONENT_FIELDS:
            got = _dig(comp, _COMPONENT_FIELDS[field])
        else:
            # Unknown expected key — treat as an authoring error, count as a miss.
            record(field, None, want, False)
            continue

        record(field, got, want, _norm(got) == _norm(want))

    total = len(checks)
    passed = sum(1 for c in checks if c["ok"])
    hard = 1 if total and passed == total else 0
    soft = (passed / total) if total else 0.0
    misses = [c["field"] for c in checks if not c["ok"]]
    fail_reason = "" if hard else f"missed: {', '.join(misses)}"
    return {"hard": hard, "soft": round(soft, 4), "checks": checks, "fail_reason": fail_reason}
