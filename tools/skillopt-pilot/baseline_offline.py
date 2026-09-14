#!/usr/bin/env python3
"""Zero-spend deterministic baseline for the stack-profile pilot.

Runs the skill's own detector (`skills/detecting-stack-profile/scripts/
detect-stack.sh`) against every committed benchmark fixture and scores its
output with the pilot's `score_result` assertions. Makes NO model/codex calls
and needs neither the SkillOpt checkout nor its venv — only `python3` + `bash`.

Two jobs:
  1. A CI-able **consistency gate** (`--gate`): every committed item's
     assertions must match what the real detector actually emits. This is the
     check the model-based `run.sh baseline` cannot give cheaply.
  2. The **deterministic baseline** the optimized skill must at least match:
     any MISS here is concrete headroom (a stack the script mis-detects).

Fixtures containing a top-level `headers.txt` (and no code manifest) are run
through the detector's black-box path; all others through code detection.

Usage:
    python3 tools/skillopt-pilot/baseline_offline.py [--gate] [--split SPLIT]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

PILOT = Path(__file__).resolve().parent
ROOT = PILOT.parents[1]
DETECTOR = ROOT / "skills" / "detecting-stack-profile" / "scripts" / "detect-stack.sh"
FIXTURES = PILOT / "fixtures"
DATA = PILOT / "data"
SPLITS = ("train", "val", "test")
BLACKBOX_BASE_URL = "https://app.example.com"


def _load_scoring():
    """Import the pilot's dependency-free scoring module by path.

    Loaded by file (not `from stack_profile...`) so this stays runnable without
    the `skillopt` package that the package __init__ pulls in.
    """
    spec = importlib.util.spec_from_file_location(
        "stack_profile_scoring", PILOT / "stack_profile" / "scoring.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # py3.12+ slotted dataclass needs this
    spec.loader.exec_module(module)
    return module


def _detect(fixture: Path) -> dict:
    """Run detect-stack.sh over one fixture and return the parsed profile."""
    out = tempfile.mktemp(suffix=".json")
    headers = fixture / "headers.txt"
    has_manifest = any(
        p.is_file() and p.name != "headers.txt" for p in fixture.rglob("*")
    )
    if headers.is_file() and not has_manifest:
        args = ["--no-code", "--headers-file", str(headers),
                "--base-url", BLACKBOX_BASE_URL, "--out", out]
    else:
        args = ["--no-runtime", "--repos", str(fixture), "--out", out]
    proc = subprocess.run(["bash", str(DETECTOR), *args],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"detector failed: {proc.stderr.strip()[:300]}")
    return json.loads(Path(out).read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gate", action="store_true",
                    help="exit non-zero if any committed item misses")
    ap.add_argument("--split", choices=SPLITS, help="restrict to one split")
    args = ap.parse_args()

    if not DETECTOR.is_file():
        print(f"detector not found: {DETECTOR}", file=sys.stderr)
        return 2
    scoring = _load_scoring()

    splits = (args.split,) if args.split else SPLITS
    total = hard = 0
    soft_sum = 0.0
    misses: list[str] = []
    print(f"detector: {DETECTOR.relative_to(ROOT)}\n")
    for split in splits:
        items = json.loads((DATA / split / "items.json").read_text(encoding="utf-8"))
        print(f"=== {split} ({len(items)} items) ===")
        for item in items:
            fixture = FIXTURES / item["fixture"]
            try:
                profile = _detect(fixture)
                score = scoring.score_result(profile, item["assertions"])
                ok, soft, reason = score.hard, score.soft, "; ".join(score.failures)
            except Exception as exc:  # noqa: BLE001
                ok, soft, reason = 0, 0.0, f"error: {exc}"
            total += 1
            hard += ok
            soft_sum += soft
            if not ok:
                misses.append(item["id"])
            mark = "PASS" if ok else "MISS"
            tail = "" if ok else f"  ({reason})"
            print(f"  [{mark}] {item['id']:<26} soft={soft:.2f}{tail}")
        print()

    print(f"BASELINE  hard={hard}/{total} "
          f"({(hard / total if total else 0):.0%})  mean-soft={soft_sum / total if total else 0:.3f}")
    if misses:
        print("MISS (deterministic headroom): " + ", ".join(misses))
    if args.gate and misses:
        print("\nGATE FAILED: committed assertions disagree with the real detector.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
