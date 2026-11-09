#!/usr/bin/env bash
# Dual-engine tests for checkpoint.sh's STATE GATE (Increment 2 Task 2, D3).
# A pass on a mutating row (mutation-flag.sh on the checklist row) needs
# persisted-state evidence: `bake` or `probe` in --kinds. Read-only rows may
# pass on DOM evidence. --nonui-reason does not bypass the gate.
set -uo pipefail
export QA_REQUIRE_SCREENSHOTS=false
unset QA_SESSION_LOG QA_NETWORK_LOG
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="$DIR/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
RE="$DIR/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: gate-state: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: gate-state: node is required (human-action evidence check) - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
BASH_BIN="$(command -v bash)"

NOJQBIN=""
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  NOJQBIN="$(mktemp -d)"; TMPDIRS+=("$NOJQBIN")
  for tool in bash date mkdir cat mv rm dirname mktemp grep sort tr python3 node; do
    tp="$(command -v "$tool" 2>/dev/null)"; [ -n "$tp" ] && ln -sf "$tp" "$NOJQBIN/$tool"
  done
fi
engine_path() { if [ "$1" = python3 ] && [ -n "$NOJQBIN" ]; then printf '%s' "$NOJQBIN"; else printf '%s' "$PATH"; fi; }

# A mutating row whose kind adds no bake of its own (the gap this gate closes),
# and a read-only row.
CHECKLIST='[
  {"id":"M1","surface":"/registrations","kind":"error-state","tags":[],"action":"Submit the registration form","requiredKinds":["human-action"],"assertedState":null,"humanAction":true},
  {"id":"R1","surface":"/registrations","kind":"loading-state","tags":["read-only"],"action":"See the registrations list","requiredKinds":[],"assertedState":null,"humanAction":false}
]'

setup() {
  local W="$1" R="$2"
  mkdir -p "$W/.qa/runs/$R"
  printf '%s\n' "$CHECKLIST" > "$W/.qa/runs/$R/checklist.json"
  (cd "$W" && bash "$RE" "$R" M1 action-trace \
    --steps '[{"tool":"browser_click","target":"#submit","phase":"act"}]' \
    --session-calls '[{"class":"human-path","mutating":true,"code":"click"}]' \
    --fingerprint-before '0' --fingerprint-after '1' \
    --action "submit registration" >/dev/null 2>&1)
}

RC=0; ERR=""
cp_run() { local E="$1" W="$2"; shift 2; ERR="$(cd "$W" && PATH="$(engine_path "$E")" "$BASH_BIN" "$CP" "$@" 2>&1 >/dev/null)"; RC=$?; }
has_line() { printf '%s\n' "$1" | grep -Fxq -- "$2" && echo yes || echo no; }
verdict_of() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(",".join(c["criterion_id"]+":"+c["verdict"]+"/"+c["confidence"] for c in d["criteria"]))' "$1" 2>/dev/null; }

RESULTS_jq=""; RESULTS_python3=""
record() { local E="$1"; shift; if [ "$E" = jq ]; then RESULTS_jq+="$*;"; else RESULTS_python3+="$*;"; fi; }

run_engine() {
  local E="$1" W; W="$(mktemp -d)"; TMPDIRS+=("$W")

  # mutating_humanaction_only_refused
  setup "$W" s1
  cp_run "$E" "$W" s1 M1 pass --kinds human-action
  check "$E mutating_humanaction_only_refused rc" "$RC" "1"
  check "$E mutating_humanaction_only_refused msg" "$(has_line "$ERR" "STATE GATE: M1 is mutating; a pass needs bake or probe evidence (got: human-action)")" "yes"
  check "$E mutating_humanaction_only_refused nothing written" "$([ -f "$W/.qa/runs/s1/checkpoint.json" ] && echo yes || echo no)" "no"
  record "$E" "ha-only=$RC"

  # nonui_reason_no_bypass
  cp_run "$E" "$W" s1 M1 pass --kinds human-action --nonui-reason "tool: date picker cannot be typed into"
  check "$E nonui_reason_no_bypass rc" "$RC" "1"
  check "$E nonui_reason_no_bypass msg" "$(has_line "$ERR" "STATE GATE: M1 is mutating; a pass needs bake or probe evidence (got: human-action)")" "yes"
  record "$E" "nonui=$RC"

  # mutating_with_bake_allowed
  setup "$W" s2
  (cd "$W" && bash "$RE" s2 M1 bake --read-back '{"registrations":1}' --multiplicity 1 >/dev/null 2>&1)
  cp_run "$E" "$W" s2 M1 pass --kinds human-action,bake
  check "$E mutating_with_bake_allowed rc" "$RC" "0"
  check "$E mutating_with_bake_allowed record" "$(verdict_of "$W/.qa/runs/s2/checkpoint.json")" "M1:pass/high"
  record "$E" "bake=$RC"

  # mutating_with_probe_allowed
  setup "$W" s3
  (cd "$W" && bash "$RE" s3 M1 probe --status 200 --shape '{"id":"number"}' --ok true >/dev/null 2>&1)
  cp_run "$E" "$W" s3 M1 pass --kinds "human-action, probe"
  check "$E mutating_with_probe_allowed rc" "$RC" "0"
  record "$E" "probe=$RC"

  # readonly_dom_only_allowed
  setup "$W" s4
  cp_run "$E" "$W" s4 R1 pass
  check "$E readonly_dom_only_allowed rc" "$RC" "0"
  check "$E readonly_dom_only_allowed no gate line" "$(printf '%s' "$ERR" | grep -c 'STATE GATE')" "0"
  record "$E" "readonly=$RC"

  # non-pass verdicts and rows outside the plan are unaffected
  cp_run "$E" "$W" s4 M1 fail --bug-ref B2
  check "$E fail_on_mutating_unaffected rc" "$RC" "0"
  cp_run "$E" "$W" s4 M1 blocked
  check "$E blocked_on_mutating_unaffected rc" "$RC" "0"
  cp_run "$E" "$W" s4 NOROW pass
  check "$E no_checklist_row_unaffected rc" "$RC" "0"
  check "$E no_checklist_row no gate line" "$(printf '%s' "$ERR" | grep -c 'STATE GATE')" "0"
  record "$E" "nonpass=$RC"
}

engines=()
command -v jq >/dev/null 2>&1 && engines+=(jq)
command -v python3 >/dev/null 2>&1 && engines+=(python3)
for e in "${engines[@]}"; do run_engine "$e"; done

if [ "${#engines[@]}" -eq 2 ]; then check "parity jq vs python3" "$RESULTS_jq" "$RESULTS_python3"; fi

echo "gate-state: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
