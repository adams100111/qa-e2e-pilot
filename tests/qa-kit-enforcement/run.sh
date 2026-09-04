#!/usr/bin/env bash
# Round-trip test for qa-kit/scripts/verify-plan.sh — the qa-kit-owned enforcement
# seam that flags an act on a criterion NOT in the frozen plan (checklist.json).
# This proves "phases populate the gate's existing checklist.json" catches out-of-plan
# acts WITHOUT modifying qa-verify (seam B(ii); increment 4 Task 1 finding).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/verify-plan.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

# checklist.json is a top-level array of entries with .id (the frozen plan {C1,C2})
PLAN='[{"id":"C1","surface":"s","kind":"happy-path","tags":[]},{"id":"C2","surface":"s","kind":"business-rule","tags":[]}]'

run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' "$PLAN" > "$T/checklist.json"

  # control: all acts on planned criteria -> ok, exit 0
  printf '%s' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C2","verdict":"fail"}]}' > "$T/cp_ok.json"
  local out rc
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp_ok.json" "$T/checklist.json")"; rc=$?
  check "$E control exit 0" "$rc" "0"
  check "$E control ok true" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "True"

  # out-of-plan: an act on C3 (not in the plan) -> flagged, exit 1
  printf '%s' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C3","verdict":"pass"}]}' > "$T/cp_bad.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp_bad.json" "$T/checklist.json")"; rc=$?
  check "$E out-of-plan exit 1" "$rc" "1"
  check "$E out-of-plan lists C3" "$(printf '%s' "$out" | python3 -c 'import json,sys;print("C3" in json.load(sys.stdin)["outOfPlan"])')" "True"
  check "$E out-of-plan ok false" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "False"

  # multiple out-of-plan -> all listed
  printf '%s' '{"criteria":[{"criterion_id":"C3"},{"criterion_id":"C4"}]}' > "$T/cp_multi.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp_multi.json" "$T/checklist.json")"; rc=$?
  check "$E multi lists both" "$(printf '%s' "$out" | python3 -c 'import json,sys;o=sorted(json.load(sys.stdin)["outOfPlan"]);print(",".join(o))')" "C3,C4"

  # empty checkpoint criteria -> nothing acted -> ok, exit 0
  printf '%s' '{"criteria":[]}' > "$T/cp_empty.json"
  QA_ENGINE=$E bash "$SH" "$T/cp_empty.json" "$T/checklist.json" >/dev/null; rc=$?
  check "$E empty acted -> ok exit 0" "$rc" "0"

  # malformed: checkpoint without .criteria array -> die
  printf '%s' '{}' > "$T/cp_malformed.json"
  QA_ENGINE=$E bash "$SH" "$T/cp_malformed.json" "$T/checklist.json" >/dev/null 2>&1
  check "$E malformed checkpoint dies" "$?" "1"
  # malformed: checklist not an array -> die
  printf '%s' '{"nope":1}' > "$T/pl_malformed.json"
  QA_ENGINE=$E bash "$SH" "$T/cp_ok.json" "$T/pl_malformed.json" >/dev/null 2>&1
  check "$E malformed checklist dies" "$?" "1"
  rm -rf "$T"
}

command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3

# cross-engine byte-identity of the report
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' "$PLAN" > "$X/checklist.json"
  printf '%s' '{"criteria":[{"criterion_id":"C2"},{"criterion_id":"Cx"},{"criterion_id":"Cy"}]}' > "$X/cp.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/cp.json" "$X/checklist.json"; true)"
  vp="$(QA_ENGINE=python3 bash "$SH" "$X/cp.json" "$X/checklist.json"; true)"
  check "cross-engine report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  rm -rf "$X"
fi

echo "qa-kit-enforcement: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
