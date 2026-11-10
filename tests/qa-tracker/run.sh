#!/usr/bin/env bash
# QA tracker suite: python3 unittest over tests/qa-tracker/test_*.py (later tasks add files that
# are discovered automatically). Prints "qa-tracker: PASS=<n> FAIL=<m>" and exits non-zero on any
# failure or error. bash 3.2 safe.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$(mktemp "${TMPDIR:-/tmp}/qa-tracker-run.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

cd "$ROOT" || exit 1
python3 -m unittest discover -s tests/qa-tracker -p 'test_*.py' -v > "$OUT" 2>&1
rc=$?
cat "$OUT"

ran="$(sed -n 's/^Ran \([0-9][0-9]*\) tests\{0,1\}.*/\1/p' "$OUT" | tail -1)"
failures="$(sed -n 's/.*failures=\([0-9][0-9]*\).*/\1/p' "$OUT" | tail -1)"
errors="$(sed -n 's/.*errors=\([0-9][0-9]*\).*/\1/p' "$OUT" | tail -1)"
skipped="$(sed -n 's/.*skipped=\([0-9][0-9]*\).*/\1/p' "$OUT" | tail -1)"
[ -n "$ran" ] || ran=0
[ -n "$failures" ] || failures=0
[ -n "$errors" ] || errors=0
[ -n "$skipped" ] || skipped=0
fail=$((failures + errors))
pass=$((ran - fail - skipped))
[ "$pass" -ge 0 ] || pass=0
if [ "$rc" -ne 0 ] && [ "$fail" -eq 0 ]; then fail=1; fi
echo "qa-tracker: PASS=$pass FAIL=$fail"
if [ "$rc" -ne 0 ] || [ "$fail" -ne 0 ] || [ "$ran" -eq 0 ]; then exit 1; fi
exit 0
