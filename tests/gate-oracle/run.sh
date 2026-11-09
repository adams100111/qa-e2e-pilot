#!/usr/bin/env bash
# Dual-engine tests for checkpoint.sh's ORACLE GATE (Increment 2 Task 1, D1/D2).
# A high-confidence pass needs an oracle a human confirmed or a spec states:
# the gate applies when the checklist row carries fixture.expect.oracleSource,
# or when the run's effective profile is `ship` and the row's kind is
# computed-logic|business-rule. Outside those conditions behaviour is 0.11.0's.
set -uo pipefail
export QA_REQUIRE_SCREENSHOTS=false
unset QA_SESSION_LOG QA_NETWORK_LOG
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="$DIR/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
RE="$DIR/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: gate-oracle: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
BASH_BIN="$(command -v bash)"

# A jq-less PATH forces checkpoint.sh (and every script it shells out to) onto python3.
NOJQBIN=""
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  NOJQBIN="$(mktemp -d)"; TMPDIRS+=("$NOJQBIN")
  for tool in bash date mkdir cat mv rm dirname mktemp grep sort tr python3 node; do
    tp="$(command -v "$tool" 2>/dev/null)"; [ -n "$tp" ] && ln -sf "$tp" "$NOJQBIN/$tool"
  done
fi
engine_path() { if [ "$1" = python3 ] && [ -n "$NOJQBIN" ]; then printf '%s' "$NOJQBIN"; else printf '%s' "$PATH"; fi; }

# row <id> <kind> <oracleSource|-> : a read-only computing row; "-" omits oracleSource.
row() {
  local fx='{"expect":{"value":"1250.00 SAR"}}'
  [ "$3" = "-" ] || fx="{\"expect\":{\"value\":\"1250.00 SAR\",\"oracleSource\":\"$3\"}}"
  printf '[{"id":"%s","surface":"/budget","kind":"%s","tags":["read-only"],"action":"See the remaining budget total","requiredKinds":[],"assertedState":null,"humanAction":false,"fixture":%s}]' "$1" "$2" "$fx"
}

# setup <work> <run> <crit> <checklist-json> <profile|-> : run dir + computed evidence.
setup() {
  local W="$1" R="$2" C="$3" CL="$4" P="$5"
  mkdir -p "$W/.qa/runs/$R"
  printf '%s\n' "$CL" > "$W/.qa/runs/$R/checklist.json"
  [ "$P" = "-" ] || printf '{"profile":"%s","gates":{"oracle":"enforce"}}\n' "$P" > "$W/.qa/runs/$R/effective-config.json"
  (cd "$W" && bash "$RE" "$R" "$C" computed --oracle 1250 --observed 1250 --match true >/dev/null 2>&1)
}

RC=0; ERR=""
cp_run() { local E="$1" W="$2"; shift 2; ERR="$(cd "$W" && PATH="$(engine_path "$E")" "$BASH_BIN" "$CP" "$@" 2>&1 >/dev/null)"; RC=$?; }
has_line() { printf '%s\n' "$1" | grep -Fxq -- "$2" && echo yes || echo no; }
verdict_of() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(",".join(c["verdict"]+"/"+c["confidence"] for c in d["criteria"]))' "$1" 2>/dev/null; }

RESULTS_jq=""; RESULTS_python3=""
record() { local E="$1"; shift; if [ "$E" = jq ]; then RESULTS_jq+="$*;"; else RESULTS_python3+="$*;"; fi; }

run_engine() {
  local E="$1" W; W="$(mktemp -d)"; TMPDIRS+=("$W")

  # llm_suggested_high_refused
  setup "$W" r1 C1 "$(row C1 computed-logic llm-suggested)" -
  cp_run "$E" "$W" r1 C1 pass --kinds computed
  check "$E llm_suggested_high_refused rc" "$RC" "1"
  check "$E llm_suggested_high_refused msg" "$(has_line "$ERR" "ORACLE GATE: C1 oracleSource=llm-suggested cannot ground a high-confidence pass (allowed: human, spec)")" "yes"
  check "$E llm_suggested_high_refused nothing written" "$([ -f "$W/.qa/runs/r1/checkpoint.json" ] && echo yes || echo no)" "no"
  record "$E" "llm-high=$RC"

  # llm_suggested_low_allowed
  cp_run "$E" "$W" r1 C1 pass --kinds computed --confidence low
  check "$E llm_suggested_low_allowed rc" "$RC" "0"
  check "$E llm_suggested_low_allowed record" "$(verdict_of "$W/.qa/runs/r1/checkpoint.json")" "pass/low"
  check "$E llm_suggested_low_allowed no gate line" "$(printf '%s' "$ERR" | grep -c 'ORACLE GATE')" "0"
  record "$E" "llm-low=$RC"

  # human_high_allowed
  setup "$W" r2 C2 "$(row C2 business-rule human)" -
  cp_run "$E" "$W" r2 C2 pass --kinds computed
  check "$E human_high_allowed rc" "$RC" "0"
  check "$E human_high_allowed record" "$(verdict_of "$W/.qa/runs/r2/checkpoint.json")" "pass/high"
  record "$E" "human=$RC"

  # spec_high_allowed (ship profile too: spec is an allowed source either way)
  setup "$W" r3 C3 "$(row C3 computed-logic spec)" ship
  cp_run "$E" "$W" r3 C3 pass --kinds computed
  check "$E spec_high_allowed rc" "$RC" "0"
  record "$E" "spec=$RC"

  # ship_missing_source_refused
  setup "$W" r4 C4 "$(row C4 computed-logic -)" ship
  cp_run "$E" "$W" r4 C4 pass --kinds computed
  check "$E ship_missing_source_refused rc" "$RC" "1"
  check "$E ship_missing_source_refused msg" "$(has_line "$ERR" "ORACLE GATE: C4 oracleSource=missing cannot ground a high-confidence pass (allowed: human, spec)")" "yes"
  record "$E" "ship-missing=$RC"
  # ... business-rule is covered as well, case-insensitively
  setup "$W" r4b C4B "$(row C4B Business-Rule -)" ship
  cp_run "$E" "$W" r4b C4B pass --kinds computed
  check "$E ship_missing_source business-rule rc" "$RC" "1"
  # ... a ship row of another kind without a source is outside D1
  setup "$W" r4c C4C "$(row C4C loading-state -)" ship
  cp_run "$E" "$W" r4c C4C pass
  check "$E ship non-computing kind unaffected rc" "$RC" "0"
  check "$E ship non-computing kind no gate line" "$(printf '%s' "$ERR" | grep -c 'ORACLE GATE')" "0"
  # ... a --nonui-reason pass is forced low, so the gate never refuses it
  cp_run "$E" "$W" r4 C4 pass --kinds computed --nonui-reason "tool: number input coerces the value"
  check "$E ship missing source nonui (forced low) rc" "$RC" "0"

  # full_profile_missing_source_unchanged: no effective-config (=> full) and explicit full
  setup "$W" r5 C5 "$(row C5 computed-logic -)" -
  cp_run "$E" "$W" r5 C5 pass --kinds computed
  check "$E full_profile_missing_source_unchanged rc" "$RC" "0"
  check "$E full_profile_missing_source_unchanged stderr empty" "$ERR" ""
  check "$E full_profile_missing_source_unchanged record" "$(verdict_of "$W/.qa/runs/r5/checkpoint.json")" "pass/high"
  setup "$W" r5b C5B "$(row C5B computed-logic -)" full
  cp_run "$E" "$W" r5b C5B pass --kinds computed
  check "$E explicit full profile rc" "$RC" "0"
  check "$E explicit full profile stderr empty" "$ERR" ""
  record "$E" "full=$RC"

  # fail_verdict_unaffected
  setup "$W" r6 C6 "$(row C6 computed-logic llm-suggested)" ship
  cp_run "$E" "$W" r6 C6 fail --bug-ref B1
  check "$E fail_verdict_unaffected rc" "$RC" "0"
  check "$E fail_verdict_unaffected record" "$(verdict_of "$W/.qa/runs/r6/checkpoint.json")" "fail/high"
  cp_run "$E" "$W" r6 C6 blocked
  check "$E blocked_verdict_unaffected rc" "$RC" "0"
  record "$E" "fail=$RC"

  # an unknown source value is shown verbatim
  setup "$W" r7 C7 "$(row C7 computed-logic guessed)" -
  cp_run "$E" "$W" r7 C7 pass --kinds computed
  check "$E unknown source refused rc" "$RC" "1"
  check "$E unknown source msg" "$(has_line "$ERR" "ORACLE GATE: C7 oracleSource=guessed cannot ground a high-confidence pass (allowed: human, spec)")" "yes"
  record "$E" "unknown=$RC"

  # false_source_refused_parity — a present non-string oracleSource is not
  # grounded (jq used to read `false` as absent and let it through).
  setup "$W" r8 C8 '[{"id":"C8","surface":"/budget","kind":"display","tags":["read-only"],"action":"See the remaining budget total","requiredKinds":[],"assertedState":null,"humanAction":false,"fixture":{"expect":{"value":"1250.00 SAR","oracleSource":false}}}]' -
  cp_run "$E" "$W" r8 C8 pass --kinds computed
  check "$E false_source_refused rc" "$RC" "1"
  check "$E false_source_refused msg" "$(has_line "$ERR" "ORACLE GATE: C8 oracleSource=false cannot ground a high-confidence pass (allowed: human, spec)")" "yes"
  record "$E" "false=$RC"

  # malformed_row_refused — a control character in oracleSource or kind
  # refuses at any confidence (it used to split the kind/source lines).
  setup "$W" r9 C9 '[{"id":"C9","surface":"/budget","kind":"display","tags":["read-only"],"action":"See the remaining budget total","requiredKinds":[],"assertedState":null,"humanAction":false,"fixture":{"expect":{"oracleSource":"llm-suggested\nhuman"}}}]' -
  cp_run "$E" "$W" r9 C9 pass --kinds computed --confidence low
  check "$E malformed_source_refused rc" "$RC" "1"
  check "$E malformed_source_refused msg" "$(has_line "$ERR" "ORACLE GATE: C9 malformed checklist row (control character in kind or oracleSource) cannot ground a pass")" "yes"
  setup "$W" r10 C10 '[{"id":"C10","surface":"/budget","kind":"display\tcomputed-logic","tags":["read-only"],"action":"See the remaining budget total","requiredKinds":[],"assertedState":null,"humanAction":false}]' -
  cp_run "$E" "$W" r10 C10 pass --kinds computed
  check "$E malformed_kind_refused rc" "$RC" "1"
  check "$E malformed_kind_refused msg" "$(has_line "$ERR" "ORACLE GATE: C10 malformed checklist row (control character in kind or oracleSource) cannot ground a pass")" "yes"
  record "$E" "malformed=$RC"
}

engines=()
command -v jq >/dev/null 2>&1 && engines+=(jq)
command -v python3 >/dev/null 2>&1 && engines+=(python3)
for e in "${engines[@]}"; do run_engine "$e"; done

# parity: both engines reached the same outcome for every case.
if [ "${#engines[@]}" -eq 2 ]; then check "parity jq vs python3" "$RESULTS_jq" "$RESULTS_python3"; fi

echo "gate-oracle: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
