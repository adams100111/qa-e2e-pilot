#!/usr/bin/env bash
# CI meta-check: every tests/<suite>/ dir must be gated by EXACTLY ONE CI list —
# scripts/run-engine-ci.sh (engine) or qa-kit/scripts/run-qakit-ci.sh (qa-kit).
# Catches the silent-omission failure mode a code review flagged: a new suite is
# added under tests/ but never enrolled, so it looks covered while running nowhere.
# Also flags stale entries (listed but no run.sh) and double-gated suites.
# Cross-plugin by nature, so it lives as repo-CI tooling, not inside either
# plugin's gate; it degrades to engine-only if qa-kit/ is absent.
#
# ALSO inventories scripts/tests/*.sh — the standalone functional tests that
# live outside the tests/<name>/run.sh convention (per-harness adapter render
# assertions, docs drift, etc.) — against their own enrollment surface: either
# invoked directly from scripts/validate-adapters.sh's `for t in ...` list, or
# referenced by name (`scripts/tests/<name>.sh`) from some tests/<name>/run.sh
# wrapper (the path test-validate.sh takes, via tests/validate-adapters/run.sh,
# to avoid validate-adapters.sh invoking itself). A scripts/tests/*.sh file
# enrolled nowhere is the exact orphan class audit-2 W3-6 found (9 of 11 ran
# in no CI list); this catches a future orphan structurally instead of relying
# on someone noticing.
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

# --- scripts/tests/*.sh inventory (audit-2 W3-6) ----------------------------
script_tests_dir = os.path.join(root, "scripts", "tests")
script_test_files = set()
if os.path.isdir(script_tests_dir):
    script_test_files = {f[:-3] for f in os.listdir(script_tests_dir) if f.endswith(".sh")}

def enrolled_script_tests():
    names = set()
    # 1) scripts/validate-adapters.sh's own `for t in \ ... do` enrollment list.
    va = os.path.join(root, "scripts", "validate-adapters.sh")
    if os.path.exists(va):
        text = open(va).read()
        m = re.search(r'for t in\s*\\(.*?)\bdo\b', text, re.S)
        if m:
            names |= set(re.findall(r'test-[A-Za-z0-9_-]+', m.group(1)))
    # 2) any tests/<name>/run.sh (or other script) that names a scripts/tests/
    #    file directly — the wrapper path (e.g. tests/validate-adapters/run.sh
    #    execs scripts/tests/test-validate.sh, which can't be called FROM
    #    validate-adapters.sh without recursing).
    for dirpath, _, filenames in os.walk(tests_dir):
        for fn in filenames:
            if not fn.endswith(".sh"):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                text = open(fp).read()
            except OSError:
                continue
            names |= set(re.findall(r'scripts/tests/([A-Za-z0-9_-]+)\.sh', text))
    return names

script_enrolled = enrolled_script_tests()
script_ungated = sorted(script_test_files - script_enrolled)
script_stale   = sorted(script_enrolled - script_test_files)

if script_ungated:
    fail = True
    print("UNENROLLED (scripts/tests/<name>.sh exists but is invoked by nothing): " + ", ".join(script_ungated), file=sys.stderr)
    print("  -> add each to scripts/validate-adapters.sh's `for t in ...` list, or wrap it as a", file=sys.stderr)
    print("     tests/<name>/run.sh suite that execs it and enroll THAT in run-engine-ci.sh.", file=sys.stderr)
if script_stale:
    fail = True
    print("STALE (enrollment references a scripts/tests/<name>.sh that no longer exists): " + ", ".join(script_stale), file=sys.stderr)

if fail:
    sys.exit(1)
print(f"suite-coverage: OK ({len(dirs)} suites, {len(script_test_files)} scripts/tests, each gated exactly once)")
PY
