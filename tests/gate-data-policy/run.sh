#!/usr/bin/env bash
# Dual-engine tests for checkpoint.sh's DATA POLICY GATE (Increment 2 Task 3, D4).
# On a pass of a mutating row, the values the act TYPED (action-trace.json step
# text/value/values/fields[].value) must pass scripts/data-policy.sh check
# against the run's effective config — only when gates.dataPolicy == "enforce".
# input-validation rows type invalid values on purpose: date-window and
# email-domain violations are ignored there, forbidden markers still refuse.
set -uo pipefail
export QA_REQUIRE_SCREENSHOTS=false
unset QA_SESSION_LOG QA_NETWORK_LOG
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$DIR/../../skills/checkpointing-qa-memory/scripts"
CP="$SCRIPTS/checkpoint.sh"
RE="$SCRIPTS/record-evidence.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: gate-data-policy: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: gate-data-policy: node is required (human-action evidence check) - suite cannot run" >&2; exit 1; }
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

# An older install: checkpoint.sh present, scripts/data-policy.sh absent.
OLD="$(mktemp -d)"; TMPDIRS+=("$OLD")
cp -R "$DIR/../../skills" "$OLD/skills"
cp -R "$DIR/../../scripts" "$OLD/scripts"
rm -f "$OLD/scripts/data-policy.sh"
OLD_CP="$OLD/skills/checkpointing-qa-memory/scripts/checkpoint.sh"

CHECKLIST='[
  {"id":"M1","surface":"/challenges/new","kind":"happy-path","tags":[],"action":"Create a challenge","requiredKinds":["bake","human-action"],"assertedState":null,"humanAction":true},
  {"id":"V1","surface":"/challenges/new","kind":"input-validation","tags":[],"action":"Submit the challenge form with a past start date","requiredKinds":["bake","human-action"],"assertedState":null,"humanAction":true}
]'

# config <gate-value|-> : effective config with a dataPolicy; "-" omits gates.dataPolicy.
config() {
  local gates='"gates":{"coverage":"block","oracle":"enforce","dataPolicy":"'"$1"'"},'
  [ "$1" = "-" ] && gates=''
  printf '{"profile":"ship",%s"dataPolicy":{"market":"sa","forbiddenMarkers":["test","bot","dummy","fake","اختبار"],"emailDomain":"innovation-lab.co","dateWindow":{"from":"2026-11-09","to":"2027-12-31"}}}\n' "$gates"
}

# setup <work> <run> <crit> <steps-json> <gate-value|-> : run dir + action-trace + bake.
setup() {
  local W="$1" R="$2" C="$3" STEPS="$4" G="$5"
  mkdir -p "$W/.qa/runs/$R"
  printf '%s\n' "$CHECKLIST" > "$W/.qa/runs/$R/checklist.json"
  config "$G" > "$W/.qa/runs/$R/effective-config.json"
  (cd "$W" && bash "$RE" "$R" "$C" action-trace --steps "$STEPS" \
    --session-calls '[{"class":"human-path","mutating":true,"code":"type"}]' \
    --fingerprint-before '0' --fingerprint-after '1' \
    --action "create a challenge" >/dev/null 2>&1)
  (cd "$W" && bash "$RE" "$R" "$C" bake --read-back '{"challenges":1}' --multiplicity 1 >/dev/null 2>&1)
}
typed() { printf '[{"tool":"browser_type","target":"#title","text":"%s","phase":"act"},{"tool":"browser_click","target":"#save","phase":"act"}]' "$1"; }

RC=0; ERR=""
cp_run() { local E="$1" W="$2" S="$3"; shift 3; ERR="$(cd "$W" && PATH="$(engine_path "$E")" "$BASH_BIN" "$S" "$@" 2>&1 >/dev/null)"; RC=$?; }
has_line() { printf '%s\n' "$1" | grep -Fxq -- "$2" && echo yes || echo no; }

RESULTS_jq=""; RESULTS_python3=""
record() { local E="$1"; shift; if [ "$E" = jq ]; then RESULTS_jq+="$*;"; else RESULTS_python3+="$*;"; fi; }

run_engine() {
  local E="$1" W; W="$(mktemp -d)"; TMPDIRS+=("$W")

  # forbidden_marker_refused
  setup "$W" d1 M1 "$(typed "تحدي العدادات الذكية test")" enforce
  cp_run "$E" "$W" "$CP" d1 M1 pass --kinds human-action,bake
  check "$E forbidden_marker_refused rc" "$RC" "1"
  check "$E forbidden_marker_refused msg" "$(has_line "$ERR" "DATA POLICY GATE: M1 typed data violates dataPolicy: forbidden-marker=test")" "yes"
  check "$E forbidden_marker_refused nothing written" "$([ -f "$W/.qa/runs/d1/checkpoint.json" ] && echo yes || echo no)" "no"
  record "$E" "marker=$RC"

  # only the first 3 violations are listed; fill_form field values are typed data too
  setup "$W" d1b M1 '[{"tool":"browser_fill_form","phase":"act","fields":[{"name":"Title","type":"textbox","ref":"e1","value":"dummy bot"},{"name":"Owner","type":"textbox","ref":"e2","value":"fake.user@gmail.com"}]},{"tool":"browser_select_option","phase":"act","target":"#city","values":["test"]}]' enforce
  cp_run "$E" "$W" "$CP" d1b M1 pass --kinds human-action,bake
  check "$E first_three_violations rc" "$RC" "1"
  check "$E first_three_violations msg" "$(has_line "$ERR" "DATA POLICY GATE: M1 typed data violates dataPolicy: forbidden-marker=test, forbidden-marker=bot, forbidden-marker=dummy")" "yes"
  record "$E" "three=$RC"

  # clean_data_allowed — the run id and recorded_at metadata are not typed data
  setup "$W" qa-ship-1 M1 "$(typed "تحدي العدادات الذكية للمياه في الرياض - faisal.alharbi@innovation-lab.co - 2026-12-15")" enforce
  cp_run "$E" "$W" "$CP" qa-ship-1 M1 pass --kinds human-action,bake
  check "$E clean_data_allowed rc" "$RC" "0"
  check "$E clean_data_allowed no gate line" "$(printf '%s' "$ERR" | grep -c 'DATA POLICY GATE')" "0"
  record "$E" "clean=$RC"

  # gate_off_when_not_enforce — advise, and no gates.dataPolicy at all
  setup "$W" d3 M1 "$(typed "test bot")" advise
  cp_run "$E" "$W" "$CP" d3 M1 pass --kinds human-action,bake
  check "$E gate_off_when_not_enforce (advise) rc" "$RC" "0"
  setup "$W" d3b M1 "$(typed "test bot")" -
  cp_run "$E" "$W" "$CP" d3b M1 pass --kinds human-action,bake
  check "$E gate_off_when_not_enforce (unset) rc" "$RC" "0"
  check "$E gate_off no gate line" "$(printf '%s' "$ERR" | grep -c 'DATA POLICY GATE')" "0"
  record "$E" "off=$RC"

  # missing_script_degrades_with_note
  setup "$W" d4 M1 "$(typed "test bot")" enforce
  cp_run "$E" "$W" "$OLD_CP" d4 M1 pass --kinds human-action,bake
  check "$E missing_script_degrades_with_note rc" "$RC" "0"
  check "$E missing_script_degrades_with_note note" "$(printf '%s' "$ERR" | grep -c '^NOTE: data policy not checked for .M1. .* scripts/data-policy.sh not found')" "1"
  record "$E" "missing=$RC"

  # input_validation_past_date_allowed — past date + foreign email are the point of the row
  setup "$W" d5 V1 "$(typed "2020-01-01 someone@gmail.com")" enforce
  cp_run "$E" "$W" "$CP" d5 V1 pass --kinds human-action,bake
  check "$E input_validation_past_date_allowed rc" "$RC" "0"
  check "$E input_validation no gate line" "$(printf '%s' "$ERR" | grep -c 'DATA POLICY GATE')" "0"
  # ... but a forbidden marker still refuses on an input-validation row
  setup "$W" d5b V1 "$(typed "2020-01-01 اختبار")" enforce
  cp_run "$E" "$W" "$CP" d5b V1 pass --kinds human-action,bake
  check "$E input_validation marker refused rc" "$RC" "1"
  check "$E input_validation marker refused msg" "$(has_line "$ERR" "DATA POLICY GATE: V1 typed data violates dataPolicy: forbidden-marker=اختبار")" "yes"
  # ... while the same past date refuses on a non-validation row
  setup "$W" d5c M1 "$(typed "starts 2020-01-01")" enforce
  cp_run "$E" "$W" "$CP" d5c M1 pass --kinds human-action,bake
  check "$E past date on happy-path refused msg" "$(has_line "$ERR" "DATA POLICY GATE: M1 typed data violates dataPolicy: date-window=2020-01-01")" "yes"
  record "$E" "validation=$RC"

  # password_not_echoed — password/secret/token/otp/pin fields are skipped, so
  # a secret never reaches the checker or a refusal message.
  setup "$W" d6 M1 '[{"tool":"browser_fill_form","phase":"act","fields":[{"name":"Title","type":"textbox","ref":"e1","value":"تسجيل فريق الابتكار"},{"name":"Password","type":"textbox","ref":"e2","value":"test-Hunter2-fake"}]},{"tool":"browser_type","target":"#otpCode","text":"bot 4321","phase":"act"},{"tool":"browser_type","target":"#pin","inputType":"password","text":"dummy 99","phase":"act"}]' enforce
  cp_run "$E" "$W" "$CP" d6 M1 pass --kinds human-action,bake
  check "$E password_not_echoed rc" "$RC" "0"
  check "$E password_not_echoed no gate line" "$(printf '%s' "$ERR" | grep -c 'DATA POLICY GATE')" "0"
  check "$E password_not_echoed value absent" "$(printf '%s' "$ERR" | grep -c -e 'Hunter2' -e '4321')" "0"
  # ... while a non-secret field with the same value is still checked
  setup "$W" d6b M1 '[{"tool":"browser_fill_form","phase":"act","fields":[{"name":"Shipping notes","type":"textbox","ref":"e1","value":"test note"}]}]' enforce
  cp_run "$E" "$W" "$CP" d6b M1 pass --kinds human-action,bake
  check "$E non_secret_field_checked rc" "$RC" "1"
  record "$E" "password=$RC"

  # non-pass verdicts are unaffected
  cp_run "$E" "$W" "$CP" d1 M1 fail --bug-ref B3
  check "$E fail_unaffected rc" "$RC" "0"
  record "$E" "fail=$RC"
}

engines=()
command -v jq >/dev/null 2>&1 && engines+=(jq)
command -v python3 >/dev/null 2>&1 && engines+=(python3)
for e in "${engines[@]}"; do run_engine "$e"; done

if [ "${#engines[@]}" -eq 2 ]; then check "parity jq vs python3" "$RESULTS_jq" "$RESULTS_python3"; fi

# --- interrupted_check_leaves_no_temp_file ---------------------------------
# dp_check_text (checkpoint.sh + qa-verify.sh) holds typed values in a mode-600
# temp file; an interrupted data-policy.sh check must not leave it behind, and
# the caller's own EXIT trap must survive. The function is lifted verbatim from
# each script and pointed at a data-policy.sh stand-in that hangs; the whole
# process group is then signalled, as a Ctrl-C or a supervisor's TERM would.
interrupt_case() {
  local SRC="$1" SIG="$2" label="$3" T H pid i
  T="$(mktemp -d)"; TMPDIRS+=("$T"); mkdir -p "$T/tmp"
  printf ': > "%s/started"\nsleep 30\n' "$T" > "$T/hang.sh"
  printf '{}\n' > "$T/cfg.json"
  H="$T/harness.sh"
  {
    printf 'set -uo pipefail\n'
    printf 'has_jq() { command -v jq >/dev/null 2>&1; }\n'
    sed -n '/^dp_check_text() {/,/^}/p' "$SRC"
    printf 'trap '\''echo outer-exit-trap-ran > "%s/outer"'\'' EXIT\n' "$T"
    printf 'out="$(DP_SH_PATH="%s/hang.sh" dp_check_text "%s/cfg.json" "Riyadh smart water metering")"\n' "$T" "$T"
  } > "$H"
  set -m
  TMPDIR="$T/tmp" "$BASH_BIN" "$H" &
  pid=$!
  set +m
  # Ready marker: the stand-in writes "started" only after dp_check_text has
  # installed its traps and created the temp file. Wait (up to 60s, the box
  # may be loaded) for it before signalling.
  i=0
  while [ ! -f "$T/started" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i+1)); done
  check "$label ready marker seen" "$([ -f "$T/started" ] && echo y)" "y"
  check "$label temp file existed while checking" "$(ls "$T/tmp" | grep -c '^qa-dp\.')" "1"
  kill "-$SIG" -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # On TERM the harness shell dies at once while dp_check_text's subshell is
  # still reaping its child and running its EXIT trap (which removes the temp
  # file), so waiting for $pid alone is not enough: wait (up to 60s) until no
  # process of the signalled group is left, then check.
  i=0
  while kill -0 -- "-$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
  check "$label process group exited" "$(kill -0 -- "-$pid" 2>/dev/null && echo alive || echo gone)" "gone"
  check "$label no temp file left" "$(ls -A "$T/tmp" | wc -l | tr -d ' ')" "0"
  check "$label caller EXIT trap kept" "$(cat "$T/outer" 2>/dev/null)" "outer-exit-trap-ran"
}
for sig in INT TERM; do
  interrupt_case "$CP" "$sig" "checkpoint.sh $sig interrupted_check_leaves_no_temp_file"
  interrupt_case "$DIR/../../scripts/qa-verify.sh" "$sig" "qa-verify.sh $sig interrupted_check_leaves_no_temp_file"
done

echo "gate-data-policy: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
