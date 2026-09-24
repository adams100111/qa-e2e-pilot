#!/usr/bin/env bash
# Audit-2 W1-1: the verdict-gating scripts must be bash-3.2-safe — macOS stock
# /bin/bash has no mapfile/readarray/declare -A, and under 3.2 those paths
# silently verified nothing (fail open). This suite is the structural gate:
# no bash-4-only builtin may appear on a gating path. (True 3.2 execution is
# not testable on this CI's bash 5; the grep gate + unchanged behavior on the
# functional suites is the enforced proxy.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# THE GATING LIST IS THE SCOPE OF THIS SUITE'S rc=0 — nothing else. An rc=0 here is evidence for
# the files named below and for no other file; citing it for an unlisted script is the exact
# "green signal that does not cover the change" error this project exists to remove (it happened
# twice in the error-honesty wave, once caught by the implementer itself). So every new script on a
# verdict-gating path must be ADDED here, not merely assumed covered.
GATING="scripts/qa-verify.sh
scripts/classify-finding.sh
scripts/known-defects.sh
qa-kit/scripts/migrate-inverted-criterion.sh
skills/checkpointing-qa-memory/scripts/required-kinds.sh
skills/checkpointing-qa-memory/scripts/mutation-flag.sh"

# GUARD ON THE LIST ITSELF. The claim "bash32-safety rc=0 covers <file>" is true only while <file>
# is named in GATING above -- and deleting a line from GATING fails NOTHING: the suite just quietly
# covers less (12 passed -> 10 passed, rc=0 either way). That is the same shape as
# check-suite-coverage.sh printing "each gated exactly once" over a python set() that cannot see a
# duplicate -- a green signal whose reach silently moved -- one level down, and it would undo the
# widening above. So EXPECTED is a deliberately SEPARATE literal: dropping a file now takes TWO
# edits, and the second is a visible act in a diff rather than an omission. Extra entries in GATING
# are never a failure (more coverage is fine); this pins the FLOOR. Each must appear EXACTLY once,
# so a duplicated line is caught here too.
EXPECTED="scripts/qa-verify.sh
scripts/classify-finding.sh
scripts/known-defects.sh
qa-kit/scripts/migrate-inverted-criterion.sh
skills/checkpointing-qa-memory/scripts/required-kinds.sh
skills/checkpointing-qa-memory/scripts/mutation-flag.sh"

while IFS= read -r want; do
  hit="$(printf '%s\n' "$GATING" | grep -cxF "$want" || true)"
  check "GATING list covers $want exactly once" "$hit" "1"
done <<< "$EXPECTED"

while IFS= read -r f; do
  n="$(grep -cE '^[^#]*\b(mapfile|readarray|declare -A)\b' "$HERE/../../$f" || true)"
  check "no bash-4 builtins in $f" "$n" "0"
  g="$(grep -cE 'BASH_VERSINFO' "$HERE/../../$f" || true)"
  check "temporary version gate removed from $f" "$g" "0"
done <<< "$GATING"

echo "---"; echo "bash32-safety: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
