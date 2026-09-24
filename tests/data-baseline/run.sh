#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/data-baseline.sh (validate / expected-count).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/data-baseline.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: data-baseline: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
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
  # audit-2 W3-7b: is_int used a char-class `*[!0-9-]*` test that let any digit/hyphen
  # MIX through (e.g. "1-2" has no char outside [0-9-], so it slipped past as "valid").
  QA_ENGINE=$E bash "$SH" expected-count "1-2" 1 >/dev/null 2>&1; check "$E measured 1-2 dies" "$?" "1"
  QA_ENGINE=$E bash "$SH" expected-count 1 "3-4" >/dev/null 2>&1; check "$E delta 3-4 dies" "$?" "1"
  QA_ENGINE=$E bash "$SH" expected-count "--1" 1 >/dev/null 2>&1; check "$E double-leading-hyphen dies" "$?" "1"
  check "$E expected-count with negative delta" "$(QA_ENGINE=$E bash "$SH" expected-count 5 -2)" "3"

  # Task 12 (error-honesty-invariants, Lane G): validate's exit code must reflect
  # whether the reported `errors` array is non-empty — the documented `/qa-spec` step 6
  # contract ("abort and surface {errors:[...]} on nonzero") restored/locked here.
  printf '%s' '[{"entity":"X","origin":"bogus"}]' > "$T/t12_errors.json"
  QA_ENGINE=$E bash "$SH" validate "$T/t12_errors.json" >/dev/null 2>&1
  check "$E test_validate_exits_nonzero_when_errors_present" "$?" "1"

  printf '%s' '[{"entity":"Category","origin":"seeded","identity":{"name":"Books"},"scope":null},{"entity":"Order","origin":"created","identity":null}]' > "$T/t12_clean.json"
  QA_ENGINE=$E bash "$SH" validate "$T/t12_clean.json" >/dev/null 2>&1
  check "$E test_validate_exits_zero_when_clean" "$?" "0"

  # Printed JSON shape (the {"errors":[...]} envelope, sorted-key compact form) must be
  # byte-identical to before this task — only the exit code changes.
  out="$(QA_ENGINE=$E bash "$SH" validate "$T/t12_errors.json" 2>/dev/null; true)"
  check "$E test_error_json_shape_unchanged" "$out" '{"errors":["row[0].origin: must be \"seeded\" or \"created\""]}'

  # The pre-existing rule that a baseline row's `scope` must be an object (or null when
  # present) stays enforced exactly as it was — this task changes the exit code only.
  printf '%s' '[{"entity":"X","origin":"seeded","scope":"not-an-object"}]' > "$T/t12_scope_bad.json"
  QA_ENGINE=$E bash "$SH" validate "$T/t12_scope_bad.json" >/dev/null 2>&1
  check "$E test_scope_object_requirement_still_enforced (non-object rejected)" "$?" "1"

  scope_out="$(QA_ENGINE=$E bash "$SH" validate "$T/t12_scope_bad.json" 2>/dev/null; true)"
  check "$E test_scope_object_requirement_still_enforced (message)" "$scope_out" '{"errors":["row[0].scope: must be an object or null"]}'

  printf '%s' '[{"entity":"X","origin":"seeded","scope":{"tenant":"t1"}}]' > "$T/t12_scope_ok.json"
  QA_ENGINE=$E bash "$SH" validate "$T/t12_scope_ok.json" >/dev/null 2>&1
  check "$E test_scope_object_requirement_still_enforced (object accepted)" "$?" "0"

  printf '%s' '[{"entity":"X","origin":"seeded","scope":null}]' > "$T/t12_scope_null.json"
  QA_ENGINE=$E bash "$SH" validate "$T/t12_scope_null.json" >/dev/null 2>&1
  check "$E test_scope_object_requirement_still_enforced (null accepted)" "$?" "0"

  # Every pre-existing data-baseline case (valid/bad-origin/non-array/missing-entity/
  # expected-count arithmetic) above in this function must still pass unmodified — this
  # is a re-assertion, not a new fixture, so a regression here means task 12 broke
  # something it wasn't supposed to touch.
  QA_ENGINE=$E bash "$SH" validate "$T/ok.json" >/dev/null; check "$E test_existing_data_baseline_cases_unchanged (valid)" "$?" "0"
  QA_ENGINE=$E bash "$SH" validate "$T/bad.json" >/dev/null 2>&1; check "$E test_existing_data_baseline_cases_unchanged (bad origin)" "$?" "1"
  QA_ENGINE=$E bash "$SH" validate "$T/na.json" >/dev/null 2>&1; check "$E test_existing_data_baseline_cases_unchanged (non-array)" "$?" "1"
  QA_ENGINE=$E bash "$SH" validate "$T/noent.json" >/dev/null 2>&1; check "$E test_existing_data_baseline_cases_unchanged (missing entity)" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
# cross-engine byte-identity of the error report on the same malformed input
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  printf '%s' '[{"entity":"X","origin":"bogus"},{"origin":"seeded"}]' > "$X/b.json"
  vj="$(QA_ENGINE=jq bash "$SH" validate "$X/b.json"; true)"
  vp="$(QA_ENGINE=python3 bash "$SH" validate "$X/b.json"; true)"
  check "cross-engine error report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
fi
echo "data-baseline: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
