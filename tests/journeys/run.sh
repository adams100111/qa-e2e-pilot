#!/usr/bin/env bash
# Dual-engine tests for scripts/journeys.sh — journey validation, status from a checkpoint
# (after ADR-0029 supersession) and viewport/locale variant expansion.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../scripts/journeys.sh"
VAL="$DIR/../../skills/generating-qa-checklist/scripts/validate-checklist-json.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: journeys: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
q(){ printf '%s' "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(eval(sys.argv[1]),sort_keys=True,separators=(",",":"),ensure_ascii=False))' "$2"; }
jv(){ q "$1" '[d[0]["verdict"],[s["verdict"] for s in d[0]["steps"]]]'; }

run_engine() {
  local E="$1" T out rc; T="$(mktemp -d)"; TMPDIRS+=("$T")

  out="$(QA_ENGINE=$E bash "$SH" validate "$FX/journeys.json" "$FX/checklist.json")"; rc=$?
  check "$E validate_ok exit" "$rc" "0"
  check "$E validate_ok body" "$(q "$out" '[d["ok"],d["errors"]]')" '[true,[]]'

  out="$(QA_ENGINE=$E bash "$SH" validate "$FX/journeys-missing-step.json" "$FX/checklist.json")"; rc=$?
  check "$E validate_missing_step exit" "$rc" "1"
  check "$E validate_missing_step errors" "$(q "$out" '[d["ok"],d["errors"]]')" '[false,[{"journeyId":"J-SUBMIT","reason":"unknown step criterion: J1-S9"}]]'

  out="$(QA_ENGINE=$E bash "$SH" validate "$FX/journeys-bad.json" "$FX/checklist.json")"; rc=$?
  check "$E validate_bad exit" "$rc" "1"
  check "$E validate_bad reasons" "$(q "$out" '[e["reason"] for e in d["errors"]]')" '["invalid priority: \"P0\"","step J1-S2: journey.step is 2, expected 1","step J1-S1: journey.step is 1, expected 2","duplicate step id: J1-S1"]'

  out="$(QA_ENGINE=$E bash "$SH" status "$FX/run-all-pass")"; rc=$?
  check "$E status_all_pass" "$(jv "$out")" '["pass",["pass","pass","pass"]]'
  check "$E status_all_pass shape" "$(q "$out" '[d[0]["id"],d[0]["priority"],d[0]["steps"][0]["criterionId"]]')" '["J-SUBMIT","P1","J1-S1"]'
  out="$(QA_ENGINE=$E bash "$SH" status "$FX/run-one-fail")"
  check "$E status_one_fail" "$(jv "$out")" '["fail",["pass","fail","pass"]]'
  out="$(QA_ENGINE=$E bash "$SH" status "$FX/run-incomplete")"
  check "$E status_incomplete" "$(jv "$out")" '["incomplete",["pass","pass","incomplete"]]'
  out="$(QA_ENGINE=$E bash "$SH" status "$FX/run-superseded")"
  check "$E superseded_verdict_used" "$(jv "$out")" '["pass",["pass","pass","pass"]]'
  out="$(QA_ENGINE=$E bash "$SH" status "$FX/run-multi-persona")"
  check "$E status_multi_persona any fail" "$(jv "$out")" '["fail",["pass","fail","pass"]]'
  out="$(QA_ENGINE=$E bash "$SH" status "$FX/run-deferred")"
  check "$E status_deferred not pass" "$(jv "$out")" '["incomplete",["pass","incomplete","pass"]]'
  QA_ENGINE=$E bash "$SH" status "$T/nope" >/dev/null 2>&1; check "$E status missing run-dir exit" "$?" "1"

  out="$(QA_ENGINE=$E bash "$SH" expand-variant "$FX/journeys.json" "$FX/checklist.json" --journey J-SUBMIT --viewport 390x844 --locale ar --color-scheme dark)"; rc=$?
  check "$E expand_variant exit" "$rc" "0"
  check "$E expand_variant_ids_and_fields ids" "$(q "$out" '[r["id"] for r in d]')" '["J1-S1@390x844-ar-dark","J1-S2@390x844-ar-dark","J1-S3@390x844-ar-dark"]'
  check "$E expand_variant_ids_and_fields variant" "$(q "$out" 'd[1]["variant"]')" '{"colorScheme":"dark","locale":"ar","viewport":"390x844"}'
  check "$E expand_variant_ids_and_fields journey" "$(q "$out" 'd[1]["journey"]')" '{"id":"J-SUBMIT@390x844-ar-dark","step":2}'
  check "$E expand_variant keeps utf-8 action" "$(q "$out" 'd[0]["action"]')" '"سجّل الفكرة"'
  printf '%s' "$out" > "$T/v.json"
  bash "$VAL" "$T/v.json" >/dev/null 2>&1; check "$E expand_variant output validates" "$?" "0"
  out="$(QA_ENGINE=$E bash "$SH" expand-variant "$FX/journeys.json" "$FX/checklist.json" --journey J-SUBMIT --viewport 1440x900 --locale en)"
  check "$E expand_variant no scheme" "$(q "$out" '[d[0]["id"],d[0]["variant"]]')" '["J1-S1@1440x900-en",{"locale":"en","viewport":"1440x900"}]'
  QA_ENGINE=$E bash "$SH" expand-variant "$FX/journeys.json" "$FX/checklist.json" --journey NOPE --viewport 390x844 --locale ar >/dev/null 2>&1
  check "$E expand_variant unknown journey exit" "$?" "1"
  QA_ENGINE=$E bash "$SH" expand-variant "$FX/journeys.json" "$FX/checklist.json" --journey J-SUBMIT --viewport wide --locale ar >/dev/null 2>&1
  check "$E expand_variant bad viewport exit" "$?" "1"
}

if command -v jq >/dev/null 2>&1; then run_engine jq; else echo "SKIP: jq engine (jq not installed)"; fi
if command -v python3 >/dev/null 2>&1; then run_engine python3; else echo "SKIP: python3 engine (python3 not installed)"; fi

# parity: both engines byte-identical (stdout and exit code).
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for args in \
    "validate $FX/journeys.json $FX/checklist.json" \
    "validate $FX/journeys-missing-step.json $FX/checklist.json" \
    "validate $FX/journeys-bad.json $FX/checklist.json" \
    "status $FX/run-all-pass" "status $FX/run-one-fail" "status $FX/run-incomplete" \
    "status $FX/run-superseded" "status $FX/run-multi-persona" "status $FX/run-deferred" \
    "expand-variant $FX/journeys.json $FX/checklist.json --journey J-SUBMIT --viewport 390x844 --locale ar --color-scheme dark" \
    "expand-variant $FX/journeys.json $FX/checklist.json --journey J-SUBMIT --viewport 1440x900 --locale en"; do
    # shellcheck disable=SC2086
    vj="$(QA_ENGINE=jq bash "$SH" $args; echo "rc=$?")"; vp="$(QA_ENGINE=python3 bash "$SH" $args; echo "rc=$?")"
    check "parity byte-identical: ${args%% *} ${args##*/}" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  done
fi
echo "journeys: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
