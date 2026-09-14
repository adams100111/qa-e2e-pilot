#!/usr/bin/env python3
"""Zero-spend sanity harness for the detecting-stack-profile benchmark.

Runs the skill's *deterministic* detector (``detect-stack.sh``) against every
fixture and scores its output with the shared :mod:`scorer`. This makes NO
model calls — it validates three things at once:

  1. the fixtures are well-formed and the detector runs on them,
  2. the ground-truth ``expected`` values are internally consistent, and
  3. the deterministic BASELINE — the score to beat. Fields the script gets
     wrong here (e.g. Prisma/Sequelize ORM -> ``unknown``) are the concrete
     headroom a SkillOpt run would try to close via prose edits.

Usage:
    python3 benchmarks/skillopt/detecting-stack-profile/sanity.py
Exit code is 0 always (this is a report, not a gate); parse the summary.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import scorer  # same directory

BENCH_ROOT = Path(__file__).resolve().parent
REPO_ROOT = BENCH_ROOT.parents[2]
DETECTOR = REPO_ROOT / "skills" / "detecting-stack-profile" / "scripts" / "detect-stack.sh"
FIXTURES = BENCH_ROOT / "fixtures"
SPLITS = ("train", "val", "test")


def _run_detector(item: dict) -> dict:
    fixture = FIXTURES / item["fixture"]
    detect = item.get("detect", {})
    with tempfile.NamedTemporaryFile("r", suffix=".json", delete=False) as tmp:
        out = tmp.name
    if detect.get("mode") == "blackbox":
        args = ["--no-code", "--headers-file", str(fixture / "headers.txt"),
                "--base-url", detect.get("base_url", "https://app.example.com"), "--out", out]
    else:
        # detect.repos is an optional list of fixture-relative repo roots
        # (multi-component). Comma-separated — space-separated collapses to generic.
        repos = detect.get("repos") or ["repo"]
        repo_arg = ",".join(str(fixture / rel) for rel in repos)
        args = ["--no-runtime", "--repos", repo_arg, "--out", out]
    subprocess.run(["bash", str(DETECTOR), *args], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return json.loads(Path(out).read_text(encoding="utf-8"))


def main() -> int:
    total_hard = total = 0
    soft_sum = 0.0
    print(f"detector: {DETECTOR.relative_to(REPO_ROOT)}\n")
    for split in SPLITS:
        items = json.loads((BENCH_ROOT / "data" / split / "items.json").read_text())
        print(f"=== {split} ({len(items)} items) ===")
        for item in items:
            try:
                profile = _run_detector(item)
                res = scorer.score(profile, item["expected"])
            except Exception as exc:  # noqa: BLE001
                res = {"hard": 0, "soft": 0.0, "fail_reason": f"error: {exc}"}
            total += 1
            total_hard += res["hard"]
            soft_sum += res["soft"]
            mark = "PASS" if res["hard"] else "MISS"
            detail = "" if res["hard"] else f"  ({res['fail_reason']})"
            print(f"  [{mark}] {item['id']:<20} soft={res['soft']:.2f}{detail}")
        print()
    print(f"BASELINE  hard={total_hard}/{total} ({total_hard/total:.0%})  "
          f"mean-soft={soft_sum/total:.3f}")
    print("Non-PASS rows above are the headroom a SkillOpt prose-optimization run targets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
