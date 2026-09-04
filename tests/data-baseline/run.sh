#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/data-baseline.sh (validate / expected-count).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/data-baseline.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' '[{"entity":"Category","origin":"seeded","identity":{"name":"Books"},"scope":null},{"entity":"Order","origin":"created","identity":null}]' > "$T/ok.json"
  QA_ENGINE=$E bash "$SH" validate "$T/ok.json" >/dev/null; check "$E valid passes" "$?" "0"
  printf '%s' '[{"entity":"X","origin":"bogus"}]' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" validate "$T/bad.json" >/dev/null 2>&1; check "$E bad origin fails" "$?" "1"
  printf '%s' '{"not":"array"}' > "$T/na.json"
  QA_ENGINE=$E bash "$SH" validate "$T/na.json" >/dev/null 2>&1; check "$E non-array fails" "$?" "1"
  printf '%s' '[{"origin":"seeded","identity":null}]' > "$T/noent.json"
  QA_ENGINE=$E bash "$SH" validate "$T/noent.json" >/dev/null 2>&1; check "$E missing entity fails" "$?" "1"
  check "$E expected-count sums" "$(QA_ENGINE=$E bash "$SH" expected-count 2 1)" "3"
  QA_ENGINE=$E bash "$SH" expected-count 2 x >/dev/null 2>&1; check "$E non-int delta dies" "$?" "1"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
# cross-engine byte-identity of the error report on the same malformed input
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' '[{"entity":"X","origin":"bogus"},{"origin":"seeded"}]' > "$X/b.json"
  vj="$(QA_ENGINE=jq bash "$SH" validate "$X/b.json"; true)"
  vp="$(QA_ENGINE=python3 bash "$SH" validate "$X/b.json"; true)"
  check "cross-engine error report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  rm -rf "$X"
fi
echo "data-baseline: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
