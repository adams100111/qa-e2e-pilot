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

GATING="scripts/qa-verify.sh
skills/checkpointing-qa-memory/scripts/required-kinds.sh
skills/checkpointing-qa-memory/scripts/mutation-flag.sh"

while IFS= read -r f; do
  n="$(grep -cE '^[^#]*\b(mapfile|readarray|declare -A)\b' "$HERE/../../$f" || true)"
  check "no bash-4 builtins in $f" "$n" "0"
  g="$(grep -cE 'BASH_VERSINFO' "$HERE/../../$f" || true)"
  check "temporary version gate removed from $f" "$g" "0"
done <<< "$GATING"

echo "---"; echo "bash32-safety: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
