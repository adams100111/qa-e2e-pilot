#!/usr/bin/env bash
# Dual-engine tests for qa-verify.sh's mirrors of the 0.12.0 record-time gates
# (Increment 2 Task 4): 3.6 oracle, 3.7 state, 3.8 data policy. Records are
# written by checkpoint.sh BEFORE checklist.json / effective-config.json exist
# (so the live gates cannot fire), the same idiom tests/qa-verify uses to model
# a record written by an older checkpoint or a bypassed gate. qa-verify must
# then override each ungrounded pass to fail/high with reason prefix
# oracle-ungrounded | no-state-evidence | data-policy-violation, and must not
# print the typed values themselves.
#
# verify_legacy_full_run_unchanged replays tests/render-report/fixture-run (a
# 0.11.0-shaped run, profile full, no oracleSource, no effective config) with
# extra checklist rows and compares verification.json to a golden captured
# with the pre-Task-4 qa-verify.sh. The ruled behaviour change (D3 applies in
# every profile) is pinned separately in verify_state_gate_applies_in_full_profile.
#
# Regenerate the golden (only when an intended change to that run's output
# lands): VSG_WRITE_GOLDEN=1 bash tests/verify-ship-gates/run.sh
set -uo pipefail
export QA_REQUIRE_SCREENSHOTS=false
unset QA_SESSION_LOG QA_NETWORK_LOG QA_VERIFY_STRICT QA_VERIFY_REDRIVE_CMD
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$DIR/../.."
QV="$ROOT/scripts/qa-verify.sh"
CP="$ROOT/skills/checkpointing-qa-memory/scripts/checkpoint.sh"
RE="$ROOT/skills/checkpointing-qa-memory/scripts/record-evidence.sh"
LEGACY_SRC="$ROOT/tests/render-report/fixture-run"
GOLDEN="$DIR/fixtures/legacy-full-run.verification.json"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: verify-ship-gates: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: verify-ship-gates: node is required (human-action evidence check) - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
BASH_BIN="$(command -v bash)"

NOJQBIN=""
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  NOJQBIN="$(mktemp -d)"; TMPDIRS+=("$NOJQBIN")
  for tool in bash date mkdir cat mv rm dirname mktemp grep sort tr python3 node shasum sha256sum awk sed cut head wc cp ls find env; do
    tp="$(command -v "$tool" 2>/dev/null)"; [ -n "$tp" ] && ln -sf "$tp" "$NOJQBIN/$tool"
  done
fi
engine_path() { if [ "$1" = python3 ] && [ -n "$NOJQBIN" ]; then printf '%s' "$NOJQBIN"; else printf '%s' "$PATH"; fi; }

# canonical <file> — one-line, key-sorted JSON (identical from jq -cS and python3).
canonical() {
  if command -v jq >/dev/null 2>&1; then jq -cS . "$1"
  else python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1],encoding="utf-8")),sort_keys=True,ensure_ascii=False,separators=(",",":")))' "$1"; fi
}
# vrec <verification.json> <crit> -> "verdict/confidence"
vrec() {
  python3 -c '
import json,sys
for r in json.load(open(sys.argv[1],encoding="utf-8")):
    if r.get("criterionId")==sys.argv[2]:
        print(r["verifierVerdict"]+"/"+r["confidence"]); break
else:
    print("absent")' "$1" "$2" 2>/dev/null || echo "unreadable"
}
# vreasons <verification.json> <crit> -> reasons, one per line
vreasons() {
  python3 -c '
import json,sys
for r in json.load(open(sys.argv[1],encoding="utf-8")):
    if r.get("criterionId")==sys.argv[2]:
        print("\n".join(r.get("reasons") or []))' "$1" "$2" 2>/dev/null
}
count_prefix() { printf '%s\n' "$1" | grep -c "^$2" ; }

RC=0
qv_run() { local E="$1" W="$2" R="$3"; (cd "$W" && PATH="$(engine_path "$E")" "$BASH_BIN" "$QV" "$R" >/dev/null 2>&1); RC=$?; }
vf() { echo "$1/.qa/runs/$2/verification.json"; }

RESULTS_jq=""; RESULTS_python3=""
record() { local E="$1"; shift; if [ "$E" = jq ]; then RESULTS_jq+="$*;"; else RESULTS_python3+="$*;"; fi; }

CHECKLIST='[
  {"id":"O1","surface":"/challenges/1/scores","kind":"computed-logic","tags":["read-only"],"action":"See the weighted score","requiredKinds":["computed"],"assertedState":null,"humanAction":false,"fixture":{"expect":{"oracleSource":"llm-suggested"}}},
  {"id":"O2","surface":"/challenges/1/scores","kind":"business-rule","tags":["read-only"],"action":"See the ranking rule applied","requiredKinds":["computed"],"assertedState":null,"humanAction":false},
  {"id":"O3","surface":"/challenges/1/scores","kind":"computed-logic","tags":["read-only"],"action":"See the total","requiredKinds":["computed"],"assertedState":null,"humanAction":false,"fixture":{"expect":{"oracleSource":"human"}}},
  {"id":"M1","surface":"/registrations","kind":"error-state","tags":[],"action":"Submit the registration form","requiredKinds":["human-action"],"assertedState":null,"humanAction":true},
  {"id":"M2","surface":"/registrations","kind":"error-state","tags":[],"action":"Submit the registration form","requiredKinds":["human-action"],"assertedState":null,"humanAction":true},
  {"id":"R1","surface":"/registrations","kind":"loading-state","tags":["read-only"],"action":"See the registrations list","requiredKinds":[],"assertedState":null,"humanAction":false},
  {"id":"D1","surface":"/challenges/new","kind":"happy-path","tags":[],"action":"Create a challenge","requiredKinds":["bake","human-action"],"assertedState":null,"humanAction":true},
  {"id":"V1","surface":"/challenges/new","kind":"input-validation","tags":[],"action":"Submit the challenge form with a past start date","requiredKinds":["bake","human-action"],"assertedState":null,"humanAction":true}
]'

# effective <profile> <dataPolicy-gate|-> -> effective-config.json body
effective() {
  local gates='"gates":{"coverage":"block","oracle":"enforce","dataPolicy":"'"$2"'"},'
  [ "$2" = "-" ] && gates=''
  printf '{"profile":"%s",%s"dataPolicy":{"market":"sa","forbiddenMarkers":["test","bot","dummy","fake","اختبار"],"emailDomain":"innovation-lab.co","dateWindow":{"from":"2026-11-09","to":"2027-12-31"}}}\n' "$1" "$gates"
}
# finish <work> <run> <profile> <gate|-|none> — written AFTER the checkpoints.
finish() {
  printf '%s\n' "$CHECKLIST" > "$1/.qa/runs/$2/checklist.json"
  [ "$4" = none ] || effective "$3" "$4" > "$1/.qa/runs/$2/effective-config.json"
}
re_in() { local W="$1"; shift; (cd "$W" && bash "$RE" "$@" >/dev/null 2>&1); }
cp_in() { local W="$1"; shift; (cd "$W" && bash "$CP" "$@" >/dev/null 2>&1); }
computed_ev() { re_in "$1" "$2" "$3" computed --oracle '{"rule":"sum"}' --observed 42 --match true; }
action_ev() { # <work> <run> <crit> <steps-json>
  re_in "$1" "$2" "$3" action-trace --steps "$4" \
    --session-calls '[{"class":"human-path","mutating":true,"code":"type"}]' \
    --fingerprint-before '0' --fingerprint-after '1' --action "submit the form"
}
bake_ev() { re_in "$1" "$2" "$3" bake --read-back '{"rows":1}' --multiplicity 1; }
typed() { printf '[{"tool":"browser_type","target":"#title","text":"%s","phase":"act"},{"tool":"browser_click","target":"#save","phase":"act"}]' "$1"; }

run_engine() {
  local E="$1" W V; W="$(mktemp -d)"; TMPDIRS+=("$W")

  # --- verify_overrides_llm_high_pass (D1) --------------------------------
  for c in O1 O2 O3; do computed_ev "$W" o1 "$c"; done
  cp_in "$W" o1 O1 pass --kinds computed
  cp_in "$W" o1 O2 pass --kinds computed
  cp_in "$W" o1 O3 pass --kinds computed
  finish "$W" o1 ship -
  qv_run "$E" "$W" o1; V="$(vf "$W" o1)"
  check "$E verify_overrides_llm_high_pass rc" "$RC" "1"
  check "$E verify_overrides_llm_high_pass O1" "$(vrec "$V" O1)" "fail/high"
  check "$E verify_overrides_llm_high_pass O1 reason" "$(vreasons "$V" O1 | grep -c '^oracle-ungrounded: oracleSource=llm-suggested cannot ground a high-confidence pass (allowed: human, spec)')" "1"
  check "$E ship_business_rule_missing_source O2" "$(vrec "$V" O2)" "fail/high"
  check "$E ship_business_rule_missing_source O2 reason" "$(vreasons "$V" O2 | grep -c '^oracle-ungrounded: oracleSource=missing ')" "1"
  check "$E human_source_grounded O3" "$(vreasons "$V" O3 | grep -c '^oracle-ungrounded')" "0"
  record "$E" "oracle=$RC/$(vrec "$V" O1)/$(vrec "$V" O2)/$(vrec "$V" O3)"

  # low-confidence pass is the honest downgrade; full profile + no source is 0.11.0
  for c in O1 O2; do computed_ev "$W" o2 "$c"; done
  cp_in "$W" o2 O1 pass --kinds computed --confidence low
  cp_in "$W" o2 O2 pass --kinds computed
  finish "$W" o2 full none
  qv_run "$E" "$W" o2; V="$(vf "$W" o2)"
  check "$E low_confidence_not_overridden O1" "$(vreasons "$V" O1 | grep -c '^oracle-ungrounded')" "0"
  check "$E full_profile_no_source_unaffected O2" "$(vreasons "$V" O2 | grep -c '^oracle-ungrounded')" "0"
  check "$E low/full rc" "$RC" "0"
  record "$E" "oracle-off=$RC"

  # --- verify_overrides_mutating_without_state (D3) ------------------------
  action_ev "$W" s1 M1 '[{"tool":"browser_click","target":"#submit","phase":"act"}]'
  action_ev "$W" s1 M2 '[{"tool":"browser_click","target":"#submit","phase":"act"}]'
  bake_ev "$W" s1 M2
  cp_in "$W" s1 M1 pass --kinds human-action
  cp_in "$W" s1 M2 pass --kinds human-action,bake
  cp_in "$W" s1 R1 pass
  finish "$W" s1 ship -
  qv_run "$E" "$W" s1; V="$(vf "$W" s1)"
  check "$E verify_overrides_mutating_without_state rc" "$RC" "1"
  check "$E verify_overrides_mutating_without_state M1" "$(vrec "$V" M1)" "fail/high"
  check "$E verify_overrides_mutating_without_state M1 reason" "$(vreasons "$V" M1 | grep -c '^no-state-evidence: M1 is mutating; a pass needs bake or probe evidence (got: human-action)')" "1"
  check "$E mutating_with_bake M2" "$(vreasons "$V" M2 | grep -c '^no-state-evidence')" "0"
  check "$E read_only_exempt R1" "$(vreasons "$V" R1 | grep -c '^no-state-evidence')" "0"
  record "$E" "state=$RC/$(vrec "$V" M1)/$(vrec "$V" M2)/$(vrec "$V" R1)"

  # verify_state_gate_applies_in_full_profile — the ruled behaviour change: D3
  # has no profile condition, so a 0.11.0 full-profile run (no effective
  # config) whose mutating error-state row passed on human-action alone is
  # now overridden too.
  action_ev "$W" s2 M1 '[{"tool":"browser_click","target":"#submit","phase":"act"}]'
  cp_in "$W" s2 M1 pass --kinds human-action
  finish "$W" s2 full none
  qv_run "$E" "$W" s2; V="$(vf "$W" s2)"
  check "$E verify_state_gate_applies_in_full_profile M1" "$(vrec "$V" M1)" "fail/high"
  check "$E verify_state_gate_applies_in_full_profile reason" "$(vreasons "$V" M1 | grep -c '^no-state-evidence: M1 is mutating')" "1"
  record "$E" "state-full=$RC"

  # --- verify_overrides_policy_violation (D4) ------------------------------
  action_ev "$W" p1 D1 '[{"tool":"browser_fill_form","phase":"act","fields":[{"name":"Title","type":"textbox","ref":"e1","value":"dummy entry"},{"name":"Owner","type":"textbox","ref":"e2","value":"saeed.alotaibi@gmail.com"}]},{"tool":"browser_click","target":"#save","phase":"act"}]'
  bake_ev "$W" p1 D1
  action_ev "$W" p1 V1 "$(typed "2020-01-01 someone@gmail.com")"
  bake_ev "$W" p1 V1
  cp_in "$W" p1 D1 pass --kinds human-action,bake
  cp_in "$W" p1 V1 pass --kinds human-action,bake
  finish "$W" p1 ship enforce
  qv_run "$E" "$W" p1; V="$(vf "$W" p1)"
  local d1r; d1r="$(vreasons "$V" D1)"
  check "$E verify_overrides_policy_violation rc" "$RC" "1"
  check "$E verify_overrides_policy_violation D1" "$(vrec "$V" D1)" "fail/high"
  check "$E verify_overrides_policy_violation D1 reason" "$(count_prefix "$d1r" "data-policy-violation: typed values in 'evidence/D1/action-trace.json' break dataPolicy rule(s): forbidden-marker, email-domain")" "1"
  check "$E policy reason hides typed values" "$(printf '%s' "$d1r" | grep -c -i -e 'gmail' -e 'saeed' -e 'dummy')" "0"
  check "$E input_validation_date_email_ignored V1" "$(vreasons "$V" V1 | grep -c '^data-policy-violation')" "0"
  record "$E" "policy=$RC/$(vrec "$V" D1)"

  # forbidden marker still applies to input-validation rows; advise mode is off
  action_ev "$W" p2 V1 "$(typed "2020-01-01 اختبار")"
  bake_ev "$W" p2 V1
  action_ev "$W" p2 D1 "$(typed "test bot")"
  bake_ev "$W" p2 D1
  cp_in "$W" p2 V1 pass --kinds human-action,bake
  cp_in "$W" p2 D1 pass --kinds human-action,bake
  finish "$W" p2 ship enforce
  qv_run "$E" "$W" p2; V="$(vf "$W" p2)"
  check "$E input_validation_marker_overridden V1" "$(vrec "$V" V1)" "fail/high"
  check "$E input_validation_marker reason" "$(vreasons "$V" V1 | grep -c "^data-policy-violation: typed values in 'evidence/V1/action-trace.json' break dataPolicy rule(s): forbidden-marker ")" "1"
  check "$E policy reason hides arabic marker" "$(vreasons "$V" V1 | grep -c 'اختبار')" "0"
  finish "$W" p2 ship advise
  qv_run "$E" "$W" p2; V="$(vf "$W" p2)"
  check "$E advise_mode_not_enforced D1" "$(vreasons "$V" D1 | grep -c '^data-policy-violation')" "0"
  check "$E advise_mode_not_enforced V1" "$(vreasons "$V" V1 | grep -c '^data-policy-violation')" "0"
  record "$E" "policy-more=$RC"

  # unreadable policy config under enforce -> override, never a silent pass
  action_ev "$W" p3 D1 "$(typed "تسجيل فريق الابتكار")"
  bake_ev "$W" p3 D1
  cp_in "$W" p3 D1 pass --kinds human-action,bake
  finish "$W" p3 ship enforce
  printf '{"profile":"ship","gates":{"dataPolicy":"enforce"},"dataPolicy":5}\n' > "$W/.qa/runs/p3/effective-config.json"
  qv_run "$E" "$W" p3; V="$(vf "$W" p3)"
  check "$E bad_policy_config_overridden" "$(vrec "$V" D1)" "fail/high"
  check "$E bad_policy_config reason" "$(vreasons "$V" D1 | grep -c "^data-policy-violation: typed values in 'evidence/D1/action-trace.json' could not be checked against dataPolicy (data-policy.sh exit 2")" "1"
  record "$E" "policy-bad=$RC"

  # --- verify_legacy_full_run_unchanged (golden) ---------------------------
  local L="$W/legacy"; mkdir -p "$L/.qa/runs"
  cp -R "$LEGACY_SRC" "$L/.qa/runs/legacy-run"
  rm -f "$L/.qa/runs/legacy-run/verification.json"
  cat > "$L/.qa/runs/legacy-run/checklist.json" <<'JSON'
[
  {"id":"C1","title":"Create a founder","kind":"happy-path","tags":[],"humanAction":true},
  {"id":"C3","title":"Admin totals","oracle":"sum(rows) = 42","tags":["role-sensitive"]},
  {"id":"C4","title":"See the founders list","kind":"loading-state","tags":["read-only"],"humanAction":false},
  {"id":"C6","title":"Equity totals add up","kind":"computed-logic","tags":["read-only"],"humanAction":false}
]
JSON
  (cd "$L" && env -u QA_REQUIRE_SCREENSHOTS PATH="$(engine_path "$E")" "$BASH_BIN" "$QV" legacy-run >/dev/null 2>&1); RC=$?
  if [ "${VSG_WRITE_GOLDEN:-}" = 1 ] && [ "$E" = jq ]; then
    mkdir -p "$(dirname "$GOLDEN")"; canonical "$L/.qa/runs/legacy-run/verification.json" > "$GOLDEN"
    echo "wrote golden $GOLDEN"
  fi
  check "$E verify_legacy_full_run_unchanged rc" "$RC" "1"
  check "$E verify_legacy_full_run_unchanged golden" "$(canonical "$L/.qa/runs/legacy-run/verification.json")" "$(cat "$GOLDEN" 2>/dev/null)"
  check "$E legacy run has no new gate reasons" "$(grep -c -e 'oracle-ungrounded' -e 'no-state-evidence' -e 'data-policy-violation' "$L/.qa/runs/legacy-run/verification.json")" "0"
  record "$E" "legacy=$RC"
}

engines=()
command -v jq >/dev/null 2>&1 && engines+=(jq)
command -v python3 >/dev/null 2>&1 && engines+=(python3)
for e in "${engines[@]}"; do run_engine "$e"; done

if [ "${#engines[@]}" -eq 2 ]; then check "parity jq vs python3" "$RESULTS_jq" "$RESULTS_python3"; fi

echo "verify-ship-gates: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
