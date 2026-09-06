#!/usr/bin/env bash
# CI meta-check: every tests/<suite>/ dir must be gated by EXACTLY ONE CI list —
# scripts/run-engine-ci.sh (engine) or qa-kit/scripts/run-qakit-ci.sh (qa-kit).
# Catches the silent-omission failure mode a code review flagged: a new suite is
# added under tests/ but never enrolled, so it looks covered while running nowhere.
# Also flags stale entries (listed but no run.sh) and double-gated suites.
# Cross-plugin by nature, so it lives as repo-CI tooling, not inside either
# plugin's gate; it degrades to engine-only if qa-kit/ is absent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]

def suites(rel):
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        return set()
    m = re.search(r'SUITES=\((.*?)\)', open(path).read(), re.S)
    return set(re.findall(r'[A-Za-z0-9._-]+', m.group(1))) if m else set()

engine = suites("scripts/run-engine-ci.sh")
qakit  = suites("qa-kit/scripts/run-qakit-ci.sh")
enrolled = engine | qakit

tests_dir = os.path.join(root, "tests")
dirs = {d for d in os.listdir(tests_dir)
        if os.path.isfile(os.path.join(tests_dir, d, "run.sh"))}

ungated = sorted(dirs - enrolled)
stale   = sorted(enrolled - dirs)
both    = sorted(engine & qakit)

fail = False
if ungated:
    fail = True
    print("UNGATED (tests/<name>/run.sh exists but is in no CI list): " + ", ".join(ungated), file=sys.stderr)
    print("  -> add each to scripts/run-engine-ci.sh or qa-kit/scripts/run-qakit-ci.sh.", file=sys.stderr)
if stale:
    fail = True
    print("STALE (CI list names a suite with no tests/<name>/run.sh): " + ", ".join(stale), file=sys.stderr)
if both:
    fail = True
    print("DOUBLE-GATED (present in BOTH CI lists — pick one): " + ", ".join(both), file=sys.stderr)

if fail:
    sys.exit(1)
print(f"suite-coverage: OK ({len(dirs)} suites, each gated exactly once)")
PY
