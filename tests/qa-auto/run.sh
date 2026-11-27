#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/auto.sh — the state machine of an unattended journey.
# Every case runs under QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines'
# files and output byte for byte. No live tracker, model or browser. bash 3.2 safe.
#
# "Now" is injected with QA_AUTO_NOW (ISO-8601 UTC) so deadlines are deterministic.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto: python3 is needed to read results - suite cannot run" >&2; exit 1; }
# The real interpreter, not a version-manager shim (a shim adds ~0.1s to each of the thousands of
# python3 starts in this suite): used to read values here, and put first on PATH for the script.
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; [ -x "$PY" ] || PY=python3
case "$PY" in */python3) PATH="${PY%/python3}:$PATH"; export PATH ;; esac
pass=0; fail=0
# Every fixture project lives under one root: mkproj runs inside $(…), so a list kept in a
# variable would be lost with the subshell and the directories would stay behind.
ROOT="$(mktemp -d)"
TMPDIRS=("$ROOT")
cleanup() { for d in "${TMPDIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
# auto <args…> — run the script under the current engine with an injected clock.
auto() { QA_ENGINE="$E" QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" bash "$SH" "$@"; }
# jv <file> <python expr over d> — read one value out of a JSON file.
jv() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
# js <json text> <python expr over d>
js() { printf '%s' "$1" | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
v=eval(sys.argv[1])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null || echo "<unreadable>"; }
# mkproj [config json] — a project with .qa/config.json (the local fixture by default).
mkproj() {
  local P; P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa"
  if [ "$#" -ge 1 ]; then printf '%s' "$1" > "$P/.qa/config.json"; else cp "$FX/config-local.json" "$P/.qa/config.json"; fi
  printf '%s' "$P"
}
# snapshot <project> — a listing of every file with its checksum, to prove a verb wrote nothing.
snapshot() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done); }
steps() { jv "$1" '",".join(s["name"]+"="+s["state"] for s in d["steps"])'; }

SHARED_OK='{"baseUrl":"https://staging.matjar.example.sa","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE","gates":{"dataPolicy":"enforce"}}'

run_engine() {
  E="$1"
  local P J B out rc before after

  # ---- start_writes_journey_and_baseline ----
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"; B="$P/.qa/specs/checkout/auto/baseline.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_writes_journey_and_baseline rc" "$rc" "0"
  check "$E start writes journey.json" "$([ -f "$J" ] && echo yes || echo no)" "yes"
  check "$E start writes baseline.json" "$([ -f "$B" ] && echo yes || echo no)" "yes"
  check "$E six steps in order, all pending" "$(steps "$J")" "constitution=pending,spec=pending,scenarios=pending,analyze=pending,run=pending,verify=pending"
  check "$E state open" "$(jv "$J" 'd["state"]')" "open"
  check "$E version 1" "$(jv "$J" 'd["version"]')" "1"
  check "$E target" "$(jv "$J" 'd["target"]')" "checkout"
  check "$E profile defaults to the config's" "$(jv "$J" 'd["profile"]')" "full"
  check "$E startedAt is the injected now" "$(jv "$J" 'd["startedAt"]')" "$NOW_DEFAULT"
  check "$E deadline is six hours later" "$(jv "$J" 'd["deadline"]')" "2026-11-27T14:00:00Z"
  check "$E J3 keys exactly" "$(jv "$J" '",".join(sorted(d.keys()))')" "analyzeRounds,baselineHash,deadline,endedAt,profile,runId,startedAt,state,steps,stop,target,until,version"
  check "$E J3 nulls and zero" "$(jv "$J" '[d["until"],d["runId"],d["stop"],d["endedAt"],d["analyzeRounds"]]')" "[null, null, null, null, 0]"
  check "$E start prints the journey" "$(js "$out" 'd["state"]+"/"+str(d["needsPerson"])')" "open/0"
  check "$E baseline safety keys" "$(jv "$B" '",".join(sorted(d["safety"].keys()))')" "allowApiWrites,allowBlackboxCrawl,environment,gates,humanInteraction.enforce,humanInteraction.maxOptOutRate,profile,seedableEnvMarker"
  check "$E baseline safety values" "$(jv "$B" '[d["safety"]["allowApiWrites"],d["safety"]["environment"],d["safety"]["gates"],d["safety"]["humanInteraction.enforce"],d["safety"]["humanInteraction.maxOptOutRate"],d["safety"]["seedableEnvMarker"]]')" '[false, "auto", null, true, 0.2, ""]'
  check "$E baseline on an empty spec" "$(jv "$B" '[d["humanOracleIds"],d["seedExists"],d["exclusions"],d["knownDefectsHash"],d["runConfigSafety"],d["profile"],d["target"],d["version"]]')" '[[], false, [], null, {}, "full", "checkout", 1]'
  check "$E nothing written outside auto/" "$(cd "$P" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" "./.qa/config.json ./.qa/specs/checkout/auto/baseline.json ./.qa/specs/checkout/auto/journey.json "

  # options: --profile, --until, --max-hours
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto start checkout --project "$P" --profile ship --until scenarios --max-hours 1.5 >/dev/null 2>&1; rc=$?
  check "$E start with options rc" "$rc" "0"
  check "$E options recorded" "$(jv "$J" '[d["profile"],d["until"],d["deadline"]]')" '["ship", "scenarios", "2026-11-27T09:30:00Z"]'
  check "$E launch profile in the baseline" "$(jv "$P/.qa/specs/checkout/auto/baseline.json" 'd["profile"]')" "ship"
  # --project defaults to the current directory
  P="$(mkproj)"
  (cd "$P" && auto start checkout >/dev/null 2>&1); rc=$?
  check "$E --project defaults to ." "$rc/$([ -f "$P/.qa/specs/checkout/auto/journey.json" ] && echo yes || echo no)" "0/yes"

  # usage errors are exit 2
  P="$(mkproj)"
  auto start --project "$P" >/dev/null 2>&1;                              check "$E start without a target is usage" "$?" "2"
  auto start checkout --project "$P" --profile fast >/dev/null 2>&1;      check "$E unknown profile is usage" "$?" "2"
  auto start checkout --project "$P" --until deploy >/dev/null 2>&1;      check "$E unknown --until step is usage" "$?" "2"
  auto start checkout --project "$P" --max-hours soon >/dev/null 2>&1;    check "$E non-numeric --max-hours is usage" "$?" "2"
  auto start checkout --project "$P" --max-hours 0 >/dev/null 2>&1;       check "$E zero --max-hours is usage" "$?" "2"
  auto start ../escape --project "$P" >/dev/null 2>&1;                    check "$E a target with a slash is usage" "$?" "2"
  auto launch checkout --project "$P" >/dev/null 2>&1;                    check "$E unknown verb is usage" "$?" "2"
  auto >/dev/null 2>&1;                                                   check "$E no verb is usage" "$?" "2"
  check "$E usage errors write nothing" "$([ -d "$P/.qa/specs" ] && echo yes || echo no)" "no"

  # no config
  P="$(mktemp -d)"; TMPDIRS+=("$P")
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_missing_config" "$rc|$out" "1|auto: no .qa/config.json; set the project up first"
  check "$E missing config writes nothing" "$([ -e "$P/.qa" ] && echo yes || echo no)" "no"

  # (what `start` and `resume` refuse about the environment is tested in tests/qa-auto-gate/)

  # ---- start_refuses_second_journey ----
  P="$(mkproj)"
  auto start checkout --project "$P" >/dev/null 2>&1
  out="$(auto start returns --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_second_journey" "$rc|$out" "1|auto: another journey is open for checkout"
  check "$E second journey writes nothing" "$([ -e "$P/.qa/specs/returns" ] && echo yes || echo no)" "no"
  out="$(auto start returns --project "$P" --restart 2>&1)"; rc=$?
  check "$E --restart does not override another target's journey" "$rc|$out" "1|auto: another journey is open for checkout"

  # ---- start_refuses_open_same_target_without_restart ----
  before="$(snapshot "$P")"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_open_same_target_without_restart" "$rc|$out" "1|auto: a journey is already open for checkout; continue it or pass --restart"
  check "$E the refusal leaves the open journey untouched" "$(snapshot "$P")" "$before"

  # ---- restart_moves_to_history ----
  NOW="2026-11-27T10:00:00Z" auto start checkout --project "$P" --restart >/dev/null 2>&1; rc=$?
  check "$E restart_moves_to_history rc" "$rc" "0"
  check "$E old journey in history/1" "$(jv "$P/.qa/specs/checkout/auto/history/1/journey.json" 'd["startedAt"]')" "$NOW_DEFAULT"
  check "$E old baseline in history/1" "$([ -f "$P/.qa/specs/checkout/auto/history/1/baseline.json" ] && echo yes || echo no)" "yes"
  check "$E new journey is open and fresh" "$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]+" "+d["startedAt"]')" "open 2026-11-27T10:00:00Z"
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E a second restart goes to history/2" "$([ -f "$P/.qa/specs/checkout/auto/history/2/journey.json" ] && echo yes || echo no)" "yes"
  check "$E history/1 is kept" "$(jv "$P/.qa/specs/checkout/auto/history/1/journey.json" 'd["startedAt"]')" "$NOW_DEFAULT"
  # other files of the journey move with it
  printf '[]\n' > "$P/.qa/specs/checkout/auto/decisions.json"; printf 'handoff\n' > "$P/.qa/specs/checkout/auto/handoff.md"
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E decisions and handoff move to history/3" "$(ls "$P/.qa/specs/checkout/auto/history/3" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json decisions.json handoff.md journey.json "
  check "$E auto/ holds only the new journey" "$(ls "$P/.qa/specs/checkout/auto" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json history journey.json "

  # ---- existing_spec_marks_steps_done ----
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  mkdir -p "$P/.qa/specs/checkout"
  printf '# QA spec\n' > "$P/.qa/specs/checkout/qa-spec.md"; printf '{"roles":[]}\n' > "$P/.qa/specs/checkout/spec-roles.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E existing_spec_marks_steps_done" "$(steps "$J")" "constitution=pending,spec=done,scenarios=pending,analyze=pending,run=pending,verify=pending"
  # half an artifact is not done
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  mkdir -p "$P/.qa/specs/checkout"; printf '# QA spec\n' > "$P/.qa/specs/checkout/qa-spec.md"; printf '# Scenarios\n' > "$P/.qa/specs/checkout/scenarios.md"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E half an artifact is not done" "$(steps "$J")" "constitution=pending,spec=pending,scenarios=pending,analyze=pending,run=pending,verify=pending"
  # everything present: the first three are done, the last three are always pending
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  mkdir -p "$P/.qa/specs/checkout" "$P/.qa/runs/r1"
  printf '{}\n' > "$P/.qa/constitution.state.json"
  printf '# QA spec\n' > "$P/.qa/specs/checkout/qa-spec.md"; printf '{"roles":[]}\n' > "$P/.qa/specs/checkout/spec-roles.json"
  printf '# Scenarios\n' > "$P/.qa/specs/checkout/scenarios.md"; cp "$FX/checklist.json" "$P/.qa/specs/checkout/checklist.json"
  printf '# Analysis\n' > "$P/.qa/specs/checkout/analysis.md"; printf '{}\n' > "$P/.qa/runs/r1/verification.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E analyze, run and verify always start pending" "$(steps "$J")" "constitution=done,spec=done,scenarios=done,analyze=pending,run=pending,verify=pending"

  # ---- baseline_records_existing_human_rows_and_exclusions ----
  P="$(mkproj "$SHARED_OK")"; B="$P/.qa/specs/checkout/auto/baseline.json"
  mkdir -p "$P/.qa/specs/checkout"
  cp "$FX/checklist.json" "$P/.qa/specs/checkout/checklist.json"
  cp "$FX/coverage-exclusions.json" "$P/.qa/specs/checkout/coverage-exclusions.json"
  cp "$FX/known-defects.json" "$P/.qa/known-defects.json"
  printf '{"command":"php artisan db:seed","cwd":"."}\n' > "$P/.qa/specs/checkout/seed.json"
  printf '{"profile":"smoke","criteriaBudget":40,"humanInteraction":{"enforce":true},"allowBlackboxCrawl":false}\n' > "$P/.qa/specs/checkout/run-config.json"
  before="$(snapshot "$P")"
  auto start checkout --project "$P" >/dev/null 2>&1; rc=$?
  check "$E baseline_records_existing_human_rows_and_exclusions rc" "$rc" "0"
  check "$E human oracle rows recorded" "$(jv "$B" 'd["humanOracleIds"]')" '["C-001", "C-004"]'
  check "$E exclusions recorded as they are" "$(jv "$B" 'd["exclusions"]')" "$(jv "$FX/coverage-exclusions.json" 'd')"
  check "$E seed recorded" "$(jv "$B" 'd["seedExists"]')" "true"
  check "$E known-defects hash recorded" "$(jv "$B" 'd["knownDefectsHash"]')" "$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$FX/known-defects.json")"
  check "$E run-config safety keys recorded (present ones only)" "$(jv "$B" 'd["runConfigSafety"]')" '{"allowBlackboxCrawl": false, "humanInteraction.enforce": true, "profile": "smoke"}'
  check "$E launch profile comes from the run-config" "$(jv "$B" 'd["profile"]')" "smoke"
  check "$E config safety values recorded" "$(jv "$B" '[d["safety"]["gates"],d["safety"]["seedableEnvMarker"],d["safety"]["profile"]]')" '[{"dataPolicy": "enforce"}, "MATJAR_DISPOSABLE", null]'
  check "$E takenAt recorded" "$(jv "$B" 'd["takenAt"]')" "$NOW_DEFAULT"
  after="$(snapshot "$P" | grep -v '/auto/')"
  check "$E start changes no file outside auto/" "$after" "$before"
  # the spec's run-config replaces the whole gates key (runconfig-merge), so it can remove the gate
  P="$(mkproj "$SHARED_OK")"; mkdir -p "$P/.qa/specs/checkout"
  printf '{"gates":{"coverage":"advise"}}\n' > "$P/.qa/specs/checkout/run-config.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E a run-config that drops the gate is refused" "$rc|$out" "1|auto: the environment is shared and gates.dataPolicy is not enforce"
  # a broken input file is a refusal, not a silent empty baseline
  P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"; printf '[{"id":' > "$P/.qa/specs/checkout/checklist.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E a broken checklist.json is refused" "$rc|$out" "1|auto: .qa/specs/checkout/checklist.json is not valid JSON"
  check "$E a refused start leaves no journey" "$([ -e "$P/.qa/specs/checkout/auto/journey.json" ] && echo yes || echo no)" "no"
  P="$(mkproj '{"baseUrl":"http://localhost:3000"} {"environment":"production"}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E a config holding two documents is refused" "$rc|$out" "1|auto: .qa/config.json is not valid JSON"
  P="$(mkproj '{"baseUrl":')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E a broken config is refused" "$rc|$out" "1|auto: .qa/config.json is not valid JSON"

  # ---- stop + status ----
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  out="$(auto status checkout --project "$P" 2>&1)"; rc=$?
  check "$E status without a journey" "$rc|$out" "1|auto: no journey for checkout"
  out="$(auto stop checkout --project "$P" --reason time-limit --detail "six hours passed" 2>&1)"; rc=$?
  check "$E stop without a journey" "$rc|$out" "1|auto: no open journey for checkout"
  auto start checkout --project "$P" >/dev/null 2>&1
  before="$(snapshot "$P")"
  out="$(auto status checkout --project "$P" 2>/dev/null)"; rc=$?
  check "$E status rc" "$rc" "0"
  check "$E status is one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
  check "$E status prints the journey plus needsPerson" "$(js "$out" '[d["target"],d["state"],d["needsPerson"],len(d["steps"])]')" '["checkout", "open", 0, 6]'
  check "$E status writes nothing" "$(snapshot "$P")" "$before"
  # A decision needs a person when it is marked so, or when it was made at low confidence and no
  # second look let it stand (D4); a second look that stands (D5) or high confidence (D6) does not.
  printf '[{"id":"D1","needsPerson":true},{"id":"D2","needsPerson":false},{"id":"D3","needsPerson":true},{"id":"D4","needsPerson":false,"confidence":"low","second":null},{"id":"D5","needsPerson":false,"confidence":"low","second":"stands"},{"id":"D6","needsPerson":false,"confidence":"high","second":null}]\n' > "$P/.qa/specs/checkout/auto/decisions.json"
  check "$E status counts decisions that need a person" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "3"
  rm -f "$P/.qa/specs/checkout/auto/decisions.json"

  # ---- stop_rejects_unknown_reason ----
  before="$(snapshot "$P")"
  auto stop checkout --project "$P" --reason tired --detail "x" >/dev/null 2>&1
  check "$E stop_rejects_unknown_reason" "$?" "2"
  auto stop checkout --project "$P" --detail "x" >/dev/null 2>&1;            check "$E stop without --reason is usage" "$?" "2"
  auto stop checkout --project "$P" --reason time-limit >/dev/null 2>&1;     check "$E stop without --detail is usage" "$?" "2"
  check "$E a rejected stop writes nothing" "$(snapshot "$P")" "$before"
  local r
  for r in time-limit step-failed until blocked audit no-sign-in tracker; do
    local Q; Q="$(mkproj)"
    auto start checkout --project "$Q" >/dev/null 2>&1
    NOW="2026-11-27T09:15:00Z" auto stop checkout --project "$Q" --reason "$r" --detail "السبب: $r \"quoted\"" >/dev/null 2>&1; rc=$?
    check "$E stop accepts $r" "$rc|$(jv "$Q/.qa/specs/checkout/auto/journey.json" '[d["state"],d["stop"]["reason"],d["stop"]["detail"],d["endedAt"]]')" "0|[\"stopped\", \"$r\", \"السبب: $r \\\"quoted\\\"\", \"2026-11-27T09:15:00Z\"]"
  done
  auto stop checkout --reason step-failed --detail --project --project "$P" >/dev/null 2>&1
  check "$E a --detail value that looks like a flag is kept as text" "$?|$(jv "$J" 'd["stop"]["detail"]')" "0|--project"
  out="$(auto stop checkout --project "$P" --reason audit --detail "again" 2>&1)"; rc=$?
  check "$E stopping a stopped journey is refused" "$rc|$out" "1|auto: no open journey for checkout"
  check "$E the first stop is kept" "$(jv "$J" 'd["stop"]["reason"]')" "step-failed"

  # ---- resume_only_after_resumable_stop ----
  out="$(NOW="2026-11-27T12:00:00Z" auto resume checkout --project "$P" --max-hours 2 2>&1)"; rc=$?
  check "$E resume after a resumable stop rc" "$rc" "0"
  check "$E resume reopens with a new deadline" "$(jv "$J" '[d["state"],d["stop"],d["endedAt"],d["deadline"],d["startedAt"]]')" '["open", null, null, "2026-11-27T14:00:00Z", "2026-11-27T08:00:00Z"]'
  check "$E resume prints the journey" "$(js "$out" 'd["state"]')" "open"
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E resume on an open journey" "$rc|$out" "1|auto: nothing to resume"
  for r in blocked audit no-sign-in tracker; do
    local Q; Q="$(mkproj)"
    auto start checkout --project "$Q" >/dev/null 2>&1
    auto stop checkout --project "$Q" --reason "$r" --detail "a person must act" >/dev/null 2>&1
    before="$(snapshot "$Q")"
    out="$(auto resume checkout --project "$Q" 2>&1)"; rc=$?
    check "$E resume refused after $r" "$rc|$out" "1|auto: nothing to resume"
    check "$E refused resume after $r writes nothing" "$(snapshot "$Q")" "$before"
  done
  for r in time-limit until; do
    local Q; Q="$(mkproj)"
    auto start checkout --project "$Q" --until scenarios >/dev/null 2>&1
    auto stop checkout --project "$Q" --reason "$r" --detail "paused" >/dev/null 2>&1
    NOW="2026-11-28T08:00:00Z" auto resume checkout --project "$Q" >/dev/null 2>&1; rc=$?
    check "$E resume allowed after $r (default six hours)" "$rc|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["state"]+" "+d["deadline"]')" "0|open 2026-11-28T14:00:00Z"
  done
  check "$E resume after an until stop clears until" "$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["until"]')" "null"
  P="$(mkproj)"
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E resume without a journey" "$rc|$out" "1|auto: nothing to resume"
  auto resume checkout --project "$P" --max-hours -1 >/dev/null 2>&1;  check "$E resume with a bad --max-hours is usage" "$?" "2"
  # a resumable stop does not hold the project lock, but resuming it must respect the lock
  auto start checkout --project "$P" >/dev/null 2>&1
  auto stop checkout --project "$P" --reason time-limit --detail "paused" >/dev/null 2>&1
  auto start returns --project "$P" >/dev/null 2>&1
  check "$E a stopped journey does not block another target" "$?" "0"
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E resume refused while another journey is open" "$rc|$out" "1|auto: another journey is open for returns"
  # start on a journey that can be resumed
  P="$(mkproj)"
  auto start checkout --project "$P" >/dev/null 2>&1
  auto stop checkout --project "$P" --reason time-limit --detail "paused" >/dev/null 2>&1
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start on a resumable stop is refused" "$rc|$out" "1|auto: a journey for checkout is stopped (time-limit); resume it or pass --restart"
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E --restart replaces a resumable stop" "$?|$(jv "$P/.qa/specs/checkout/auto/history/1/journey.json" 'd["state"]')" "0|stopped"

  # ---- finished_journey_archived_on_next_start ----
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  auto stop checkout --project "$P" --reason audit --detail "safety-setting-changed:allowApiWrites" >/dev/null 2>&1
  NOW="2026-11-28T08:00:00Z" auto start checkout --project "$P" >/dev/null 2>&1; rc=$?
  check "$E finished_journey_archived_on_next_start (stopped, not resumable)" "$rc|$(jv "$P/.qa/specs/checkout/auto/history/1/journey.json" 'd["state"]+"/"+d["stop"]["reason"]')" "0|stopped/audit"
  check "$E the new journey is open" "$(jv "$J" 'd["state"]+" "+d["startedAt"]')" "open 2026-11-28T08:00:00Z"
  # a journey that reached done (written here as Task 13's `next` will leave it)
  python3 -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["state"]="done"; d["endedAt"]="2026-11-28T09:00:00Z"
for s in d["steps"]: s["state"]="done"
json.dump(d,open(p,"w"))' "$J"
  NOW="2026-11-29T08:00:00Z" auto start checkout --project "$P" >/dev/null 2>&1; rc=$?
  check "$E finished_journey_archived_on_next_start (done)" "$rc|$(jv "$P/.qa/specs/checkout/auto/history/2/journey.json" 'd["state"]')" "0|done"
  check "$E the journey after a done one starts fresh" "$(jv "$J" 'd["state"]+" "+d["startedAt"]')$(steps "$J")" "open 2026-11-29T08:00:00Zconstitution=pending,spec=pending,scenarios=pending,analyze=pending,run=pending,verify=pending"
  auto start returns --project "$P" >/dev/null 2>&1
  check "$E the new open journey holds the project lock again" "$?" "1"
}

command -v jq >/dev/null 2>&1 && run_engine jq
run_engine python3

# ---------------------------------------------------------------------------------------------
# next, step-start, step-done, signin
# ---------------------------------------------------------------------------------------------
T_OLD=202611270700; T_MID=202611270710; T_NEW=202611270720
# artifact <project> <step> [run id] [run start] — put a step's result on disk, as its command would.
# `blocked` is an analysis whose verdict is BLOCKED.
artifact() {
  local P="$1" S="$1/.qa/specs/checkout" R="$1/.qa/runs/${3:-r1}"
  mkdir -p "$S"
  case "$2" in
    constitution) printf '{"version":"c1"}\n' > "$P/.qa/constitution.state.json" ;;
    spec)         printf '# QA spec\n' > "$S/qa-spec.md"; printf '{"roles":[]}\n' > "$S/spec-roles.json" ;;
    scenarios)    printf '# Scenarios\n' > "$S/scenarios.md"; cp "$FX/checklist.json" "$S/checklist.json"; touch -t "$T_OLD" "$S/checklist.json" ;;
    analyze)      cp "$FX/analysis-pass.md" "$S/analysis.md"; touch -t "$T_MID" "$S/analysis.md" ;;
    blocked)      cp "$FX/analysis-blocked.md" "$S/analysis.md"; touch -t "$T_MID" "$S/analysis.md" ;;
    run)          mkdir -p "$R"
                  printf '{"run_id":"%s","target_feature":"checkout","started_at":"%s","status":"complete"}\n' "${3:-r1}" "${4-2026-11-27T08:30:00Z}" > "$R/run-manifest.json"
                  printf '{"criteria":[]}\n' > "$R/checkpoint.json"; printf '# Report\n' > "$R/report.md" ;;
    verify)       mkdir -p "$R"; printf '{"overrides":[]}\n' > "$R/verification.json" ;;
  esac
}
# done_step <project> <step> — put the artifact on disk and mark the step done.
done_step() {
  artifact "$1" "$2"
  if [ "$2" = run ]; then auto step-done checkout run --run r1 --project "$1" >/dev/null 2>&1
  else auto step-done checkout "$2" --project "$1" >/dev/null 2>&1; fi
}
# upto <project> <step>… — mark those steps done, in order.
upto() { local P="$1" s; shift; for s in "$@"; do done_step "$P" "$s" || return 1; done; }
# journey_at <next step|end> [start flags…] — a project whose open journey has every step before
# <next step> done (`end`: all six). The first three are on disk before `start`, which takes them as done.
journey_at() {
  local want="$1" P s tpl; shift
  # Built once per engine and shape, then copied (with file times): `start` is the slow verb.
  tpl="$ROOT/tpl-$E-$want$(printf '%s' "$*" | tr -c 'a-z0-9' '-')"
  if [ ! -d "$tpl" ]; then
    P="$(mkproj)"
    for s in constitution spec scenarios; do [ "$s" = "$want" ] && break; artifact "$P" "$s"; done
    auto start checkout --project "$P" "$@" >/dev/null 2>&1
    case "$want" in run|verify|end) done_step "$P" analyze ;; esac
    case "$want" in verify|end) done_step "$P" run ;; esac
    [ "$want" = end ] && done_step "$P" verify
    mv "$P" "$tpl"
  fi
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; rmdir "$P"; cp -Rp "$tpl" "$P"
  printf '%s' "$P"
}
nx() { auto next checkout --project "$1" 2>&1; }
verdict_file() { printf '# Analysis\n\n## Coverage\n\nx\n\n## Verdict\n\n%s\n\n## After\n\nBLOCKED is a word here too.\n' "$2" > "$1/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$1/.qa/specs/checkout/analysis.md"; }

run_engine_steps() {
  E="$1"
  local P J out rc before s Q

  # ---- next_walks_six_steps ----
  P="$(journey_at constitution)"; J="$P/.qa/specs/checkout/auto/journey.json"
  check "$E start gives every step an attempts count of 0" "$(jv "$J" '[s.get("attempts") for s in d["steps"]]')" "[0, 0, 0, 0, 0, 0]"
  for s in constitution spec scenarios analyze run verify; do
    out="$(nx "$P")"; rc=$?
    check "$E next_walks_six_steps: next is $s" "$rc|$out" "0|{\"next\":\"$s\"}"
    out="$(auto step-start checkout "$s" --project "$P" 2>&1)"; rc=$?
    check "$E step-start $s marks it running" "$rc|$(js "$out" '[[x["state"],x["attempts"]] for x in d["steps"] if x["name"]=="'"$s"'"][0]')" "0|[\"running\", 1]"
    check "$E next still names the running step $s" "$(nx "$P")" "{\"next\":\"$s\"}"
    artifact "$P" "$s"
    if [ "$s" = run ]; then out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
    else out="$(auto step-done checkout "$s" --project "$P" 2>&1)"; rc=$?; fi
    check "$E step-done $s" "$rc|$(js "$out" '[x["state"] for x in d["steps"] if x["name"]=="'"$s"'"][0]+"/"+str(d["needsPerson"])')" "0|done/0"
  done
  check "$E every step done" "$(steps "$J")" "constitution=done,spec=done,scenarios=done,analyze=done,run=done,verify=done"
  check "$E step-done run records the run id" "$(jv "$J" 'd["runId"]')" "r1"
  check "$E the journey is still open until next is asked" "$(jv "$J" 'd["state"]')" "open"

  # ---- all_done_sets_state_done ----
  out="$(NOW="2026-11-27T09:00:00Z" nx "$P")"; rc=$?
  check "$E all_done_sets_state_done: next says done" "$rc|$out" '0|{"next":"done"}'
  check "$E all_done_sets_state_done: journey state" "$(jv "$J" '[d["state"],d["endedAt"],d["stop"]]')" '["done", "2026-11-27T09:00:00Z", null]'
  before="$(snapshot "$P")"
  out="$(NOW="2026-11-27T23:00:00Z" nx "$P")"; rc=$?
  check "$E next on a done journey repeats done" "$rc|$out" '0|{"next":"done"}'
  check "$E next on a done journey writes nothing" "$(snapshot "$P")" "$before"
  out="$(auto step-start checkout verify --project "$P" 2>&1)"; rc=$?
  check "$E step-start on a done journey" "$rc|$out" "1|auto: no open journey for checkout"
  out="$(auto step-done checkout verify --project "$P" 2>&1)"; rc=$?
  check "$E step-done on a done journey" "$rc|$out" "1|auto: no open journey for checkout"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin on a done journey" "$rc|$out" "1|auto: no open journey for checkout"
  # all steps done wins over a passed deadline: nothing is left to do
  P="$(journey_at end)"; J="$P/.qa/specs/checkout/auto/journey.json"
  check "$E done wins over a passed deadline" "$(NOW="2026-11-28T08:00:00Z" nx "$P")/$(jv "$J" 'd["state"]')" '{"next":"done"}/done'

  # ---- no journey ----
  P="$(mkproj)"
  out="$(nx "$P")"; rc=$?
  check "$E next without a journey" "$rc|$out" "1|auto: no journey for checkout"
  out="$(auto step-start checkout spec --project "$P" 2>&1)"; rc=$?
  check "$E step-start without a journey" "$rc|$out" "1|auto: no open journey for checkout"
  out="$(auto step-done checkout spec --project "$P" 2>&1)"; rc=$?
  check "$E step-done without a journey" "$rc|$out" "1|auto: no open journey for checkout"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin without a journey" "$rc|$out" "1|auto: no open journey for checkout"
  check "$E verbs without a journey write nothing" "$([ -e "$P/.qa/specs" ] && echo yes || echo no)" "no"

  # ---- usage ----
  auto start checkout --project "$P" >/dev/null 2>&1
  before="$(snapshot "$P")"
  auto next checkout extra --project "$P" >/dev/null 2>&1;                 check "$E next with an extra word is usage" "$?" "2"
  auto step-start checkout --project "$P" >/dev/null 2>&1;                 check "$E step-start without a step is usage" "$?" "2"
  auto step-start checkout deploy --project "$P" >/dev/null 2>&1;          check "$E step-start with an unknown step is usage" "$?" "2"
  auto step-done checkout --project "$P" >/dev/null 2>&1;                  check "$E step-done without a step is usage" "$?" "2"
  auto step-done checkout deploy --project "$P" >/dev/null 2>&1;           check "$E step-done with an unknown step is usage" "$?" "2"
  auto step-done checkout spec --run r1 --project "$P" >/dev/null 2>&1;    check "$E --run on a step other than run is usage" "$?" "2"
  auto step-done checkout run --project "$P" >/dev/null 2>&1;              check "$E step-done run without --run is usage" "$?" "2"
  auto step-done checkout run --run ../r1 --project "$P" >/dev/null 2>&1;  check "$E a run id with a slash is usage" "$?" "2"
  auto signin checkout extra --project "$P" >/dev/null 2>&1;               check "$E signin with an extra word is usage" "$?" "2"
  check "$E usage errors of the step verbs write nothing" "$(snapshot "$P")" "$before"

  # ---- step_done_requires_artifact ----
  P="$(journey_at constitution)"; J="$P/.qa/specs/checkout/auto/journey.json"
  before="$(snapshot "$P")"
  out="$(auto step-done checkout scenarios --project "$P" 2>&1)"; rc=$?
  check "$E a step out of order is refused (step-done)" "$rc|$out" "1|auto: scenarios is not the next step; next is constitution"
  out="$(auto step-start checkout run --project "$P" 2>&1)"; rc=$?
  check "$E a step out of order is refused (step-start)" "$rc|$out" "1|auto: run is not the next step; next is constitution"
  out="$(auto step-done checkout constitution --project "$P" 2>&1)"; rc=$?
  check "$E step_done_requires_artifact: constitution" "$rc|$out" "1|auto: constitution has no result yet"
  check "$E refused step verbs write nothing" "$(snapshot "$P")" "$before"
  done_step "$P" constitution
  out="$(auto step-done checkout constitution --project "$P" 2>&1)"; rc=$?
  check "$E a done step is not done twice" "$rc|$out" "1|auto: constitution is already done"
  out="$(auto step-start checkout constitution --project "$P" 2>&1)"; rc=$?
  check "$E a done step is not started again" "$rc|$out" "1|auto: constitution is already done"
  mkdir -p "$P/.qa/specs/checkout"; printf '# QA spec\n' > "$P/.qa/specs/checkout/qa-spec.md"
  out="$(auto step-done checkout spec --project "$P" 2>&1)"; rc=$?
  check "$E step_done_requires_artifact: half a spec" "$rc|$out" "1|auto: spec has no result yet"
  done_step "$P" spec
  printf '# Scenarios\n' > "$P/.qa/specs/checkout/scenarios.md"
  out="$(auto step-done checkout scenarios --project "$P" 2>&1)"; rc=$?
  check "$E step_done_requires_artifact: scenarios without a checklist" "$rc|$out" "1|auto: scenarios has no result yet"
  done_step "$P" scenarios
  out="$(auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E step_done_requires_artifact: analyze" "$rc|$out" "1|auto: analyze has no result yet"
  printf '# Analysis\n\nNothing decided.\n' > "$P/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$P/.qa/specs/checkout/analysis.md"
  out="$(auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E an analysis without a Verdict section is no result" "$rc|$out" "1|auto: analyze has no result yet"
  done_step "$P" analyze
  out="$(auto step-done checkout verify --project "$P" 2>&1)"; rc=$?
  check "$E verify before the run is refused" "$rc|$out" "1|auto: verify is not the next step; next is run"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E step_done_requires_artifact: run without files" "$rc|$out" "1|auto: run has no result yet"
  artifact "$P" run; rm -f "$P/.qa/runs/r1/report.md"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E a run without report.md has no result" "$rc|$out" "1|auto: run has no result yet"
  artifact "$P" run; rm -f "$P/.qa/runs/r1/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E a run without checkpoint.json has no result" "$rc|$out" "1|auto: run has no result yet"
  artifact "$P" run; rm -f "$P/.qa/runs/r1/run-manifest.json"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E a run without run-manifest.json has no result" "$rc|$out" "1|auto: run has no result yet"
  # the run must have started inside this journey (startedAt 08:00:00Z)
  artifact "$P" run r1 "2026-11-27T07:59:59Z"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E a run from before the journey is refused" "$rc|$out" "1|auto: that run started before this journey"
  artifact "$P" run r1 "2026-11-27T10:30:00+03:00"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E a start time with an offset is compared in UTC" "$rc|$out" "1|auto: that run started before this journey"
  artifact "$P" run r1 "2026-11-26T23:30:00-09:00"
  out="$(auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
  check "$E an offset that moves the run into the journey is accepted" "$rc|$(jv "$J" 'd["runId"]')" "0|r1"
  for s in "" "yesterday" "2026-11-27T08:30:00" "2026-11-27"; do
    Q="$(journey_at run)"
    artifact "$Q" run r1 "$s"
    out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
    check "$E a run with the start time [$s] is refused" "$rc|$out|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["runId"]')" "1|auto: that run has no start time|null"
  done
  Q="$(journey_at run)"
  artifact "$Q" run; printf '{"run_id":"r1","started_at":null}\n' > "$Q/.qa/runs/r1/run-manifest.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a manifest with a null start time is refused" "$rc|$out" "1|auto: that run has no start time"
  printf '{"run_id":' > "$Q/.qa/runs/r1/run-manifest.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a manifest that is not JSON is refused" "$rc|$out" "1|auto: that run has no start time"
  for s in "2026-11-27T08:00:00Z" "2026-11-27T08:30:00.250Z" "2026-11-27 11:30:00+0300"; do
    Q="$(journey_at run)"
    artifact "$Q" run r1 "$s"
    auto step-done checkout run --run r1 --project "$Q" >/dev/null 2>&1
    check "$E a run with the start time [$s] is accepted" "$?" "0"
  done
  # a manifest start time without a zone cannot be compared: the first checkpoint stands in for it
  # (the engine's checkpoint.sh writes `checkpointed_at` in UTC with Z)
  Q="$(journey_at run)"
  artifact "$Q" run r1 "2026-11-27T07:30:00"
  printf '{"criteria":[{"criterion_id":"C-002","checkpointed_at":"2026-11-27T09:10:00Z"},{"criterion_id":"C-001","checkpointed_at":"2026-11-27T08:40:00Z"}]}\n' > "$Q/.qa/runs/r1/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a zone-less manifest with a later first checkpoint is accepted" "$rc|$(jv "$Q/.qa/specs/checkout/auto/journey.json" '[d["runId"],d["steps"][4]["state"]]')" '0|["r1", "done"]'
  Q="$(journey_at run)"
  artifact "$Q" run r1 "2026-11-27T11:30:00"
  printf '{"criteria":[{"criterion_id":"C-002","checkpointed_at":"2026-11-27T09:10:00Z"},{"criterion_id":"C-001","checkpointed_at":"2026-11-27T07:40:00Z"},{"criterion_id":"C-003","checkpointed_at":"2026-11-27T08:40:00Z"}]}\n' > "$Q/.qa/runs/r1/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a zone-less manifest with an earlier first checkpoint is refused" "$rc|$out|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["runId"]')" "1|auto: that run started before this journey|null"
  printf '{"criteria":[{"criterion_id":"C-001","checkpointed_at":"soon"},{"criterion_id":"C-002"},"x"]}\n' > "$Q/.qa/runs/r1/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a zone-less manifest and no readable checkpoint time is refused" "$rc|$out" "1|auto: that run has no start time"
  printf '{"criteria":[' > "$Q/.qa/runs/r1/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a zone-less manifest and a broken checkpoint.json is refused" "$rc|$out" "1|auto: that run has no start time"
  # a manifest that names its zone is the start time, whatever the checkpoints say
  Q="$(journey_at run)"
  artifact "$Q" run r1 "2026-11-27T07:59:59Z"
  printf '{"criteria":[{"criterion_id":"C-001","checkpointed_at":"2026-11-27T08:40:00Z"}]}\n' > "$Q/.qa/runs/r1/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a manifest start time with a zone is not replaced by the checkpoints" "$rc|$out" "1|auto: that run started before this journey"
  out="$(auto step-done checkout verify --project "$P" 2>&1)"; rc=$?
  check "$E step_done_requires_artifact: verify" "$rc|$out" "1|auto: verify has no result yet"
  # the verify result is looked for in the recorded run only
  artifact "$P" verify r2
  out="$(auto step-done checkout verify --project "$P" 2>&1)"; rc=$?
  check "$E another run's verification.json does not count" "$rc|$out" "1|auto: verify has no result yet"
  # a journey whose run step is done with no run id recorded
  Q="$(journey_at verify)"
  artifact "$Q" verify
  "$PY" -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["runId"]=None; json.dump(d,open(p,"w"))' "$Q/.qa/specs/checkout/auto/journey.json"
  out="$(auto step-done checkout verify --project "$Q" 2>&1)"; rc=$?
  check "$E verify without a recorded run id is refused" "$rc|$out" "1|auto: no run is recorded for this journey"

  # ---- step-start counts attempts ----
  P="$(journey_at constitution)"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto step-start checkout constitution --project "$P" >/dev/null 2>&1
  out="$(auto step-start checkout constitution --project "$P" 2>&1)"; rc=$?
  check "$E starting a running step again is a redo" "$rc|$(jv "$J" '[d["steps"][0]["state"],d["steps"][0]["attempts"],d["steps"][1]["attempts"]]')" '0|["running", 2, 0]'
  check "$E status prints the attempts" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["steps"][0]["attempts"]')" "2"
  done_step "$P" constitution
  check "$E a done step keeps its attempts" "$(jv "$J" '[d["steps"][0]["state"],d["steps"][0]["attempts"]]')" '["done", 2]'
  done_step "$P" spec
  check "$E step-done without step-start leaves attempts at 0" "$(jv "$J" '[d["steps"][1]["state"],d["steps"][1]["attempts"]]')" '["done", 0]'

  # ---- stale_analysis_is_not_done ----
  P="$(journey_at analyze)"; J="$P/.qa/specs/checkout/auto/journey.json"
  artifact "$P" analyze; touch -t "$T_NEW" "$P/.qa/specs/checkout/checklist.json"
  out="$(auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E stale_analysis_is_not_done" "$rc|$out" "1|auto: analyze has no result yet"
  check "$E a stale analysis leaves the step as it was" "$(steps "$J")" "constitution=done,spec=done,scenarios=done,analyze=pending,run=pending,verify=pending"
  touch -t "$T_NEW" "$P/.qa/specs/checkout/analysis.md"
  auto step-done checkout analyze --project "$P" >/dev/null 2>&1
  check "$E an analysis as new as the checklist is done" "$?|$(jv "$J" 'd["steps"][3]["state"]')" "0|done"

  # ---- blocked_analysis_reopens_scenarios_once ----
  P="$(journey_at analyze)"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto step-start checkout analyze --project "$P" >/dev/null 2>&1
  artifact "$P" blocked
  out="$(auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E blocked_analysis_reopens_scenarios_once rc" "$rc" "0"
  check "$E blocked: scenarios and analyze go back to pending" "$(steps "$J")" "constitution=done,spec=done,scenarios=pending,analyze=pending,run=pending,verify=pending"
  check "$E blocked: one round counted, journey open" "$(jv "$J" '[d["analyzeRounds"],d["state"],d["stop"]]')" '[1, "open", null]'
  check "$E blocked: step-done prints the journey" "$(js "$out" '[d["analyzeRounds"],d["state"]]')" '[1, "open"]'
  check "$E blocked: next goes back to scenarios" "$(nx "$P")" '{"next":"scenarios"}'
  # a second analysis that passes lets the journey go on
  Q="$(journey_at analyze)"
  artifact "$Q" blocked; auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
  upto "$Q" scenarios analyze
  check "$E an analysis that passes in the second round goes on to the run" "$(nx "$Q")/$(jv "$Q/.qa/specs/checkout/auto/journey.json" '[d["analyzeRounds"],d["state"]]')" '{"next":"run"}/[1, "open"]'

  # ---- blocked_twice_stops_blocked ----
  done_step "$P" scenarios
  artifact "$P" blocked
  out="$(NOW="2026-11-27T09:40:00Z" auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E blocked_twice_stops_blocked rc" "$rc" "0"
  check "$E blocked twice: journey stopped" "$(jv "$J" '[d["analyzeRounds"],d["state"],d["stop"]["reason"],d["stop"]["detail"],d["endedAt"]]')" '[2, "stopped", "blocked", "the analysis is still BLOCKED after 2 rounds", "2026-11-27T09:40:00Z"]'
  check "$E blocked twice: next repeats the stop" "$(nx "$P")" '{"detail":"the analysis is still BLOCKED after 2 rounds","next":"stopped","reason":"blocked"}'
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E a blocked journey cannot be resumed" "$rc|$out" "1|auto: nothing to resume"

  # ---- how the Verdict is read ----
  for s in "**BLOCKED** when the Coverage gate blocks; otherwise **PASS (advisory)**." "Verdict: BLOCKED (no census)" "The gate reads \`BLOCKED\`: 3 uncovered pairs."; do
    Q="$(journey_at analyze)"
    verdict_file "$Q" "$s"
    auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
    check "$E verdict line [$s] is BLOCKED" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["analyzeRounds"]')" "0|1"
  done
  for s in "**PASS (advisory)**" "PASS (advisory). The coverage gate is not BLOCKED." "Advisory only; 2 oracle gaps."; do
    Q="$(journey_at analyze)"
    verdict_file "$Q" "$s"
    auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
    check "$E verdict line [$s] is not BLOCKED" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" '[d["analyzeRounds"],d["steps"][3]["state"]]')" '0|[0, "done"]'
  done

  # ---- deadline_stops_time_limit ----
  P="$(journey_at spec)"; J="$P/.qa/specs/checkout/auto/journey.json"
  check "$E the deadline itself has not passed" "$(NOW="2026-11-27T14:00:00Z" nx "$P")" '{"next":"spec"}'
  out="$(NOW="2026-11-27T14:00:01Z" nx "$P")"; rc=$?
  check "$E deadline_stops_time_limit" "$rc|$out" '0|{"detail":"the deadline 2026-11-27T14:00:00Z has passed","next":"stopped","reason":"time-limit"}'
  check "$E deadline: journey stopped" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["endedAt"]]')" '["stopped", "time-limit", "2026-11-27T14:00:01Z"]'
  check "$E deadline: steps untouched" "$(steps "$J")" "constitution=done,spec=pending,scenarios=pending,analyze=pending,run=pending,verify=pending"
  NOW="2026-11-27T15:00:00Z" auto resume checkout --project "$P" >/dev/null 2>&1
  check "$E after resume the journey continues from the same step" "$(NOW="2026-11-27T15:00:01Z" nx "$P")" '{"next":"spec"}'

  # ---- until_scenarios_stops_before_analyze ----
  P="$(journey_at scenarios --until scenarios)"; J="$P/.qa/specs/checkout/auto/journey.json"
  check "$E until: the until step itself is still next" "$(nx "$P")" '{"next":"scenarios"}'
  done_step "$P" scenarios
  out="$(NOW="2026-11-27T08:45:00Z" nx "$P")"; rc=$?
  check "$E until_scenarios_stops_before_analyze" "$rc|$out" '0|{"detail":"stopped after scenarios, as asked","next":"stopped","reason":"until"}'
  check "$E until: journey stopped" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["endedAt"]]')" '["stopped", "until", "2026-11-27T08:45:00Z"]'
  auto resume checkout --project "$P" >/dev/null 2>&1
  check "$E until: resumed, the journey goes on to analyze" "$(nx "$P")" '{"next":"analyze"}'
  # the asked-for stop wins over the time limit when both hold
  Q="$(mkproj)"; artifact "$Q" constitution; artifact "$Q" spec; artifact "$Q" scenarios
  auto start checkout --project "$Q" --until scenarios >/dev/null 2>&1
  check "$E until wins over a passed deadline" "$(NOW="2026-11-28T08:00:00Z" nx "$Q")" '{"detail":"stopped after scenarios, as asked","next":"stopped","reason":"until"}'

  # ---- next_after_stop_does_not_advance ----
  P="$(journey_at scenarios)"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto stop checkout --project "$P" --reason step-failed --detail 'تعذر إكمال الخطوة "scenarios"' >/dev/null 2>&1
  before="$(snapshot "$P")"
  out="$(nx "$P")"; rc=$?
  check "$E next_after_stop_does_not_advance" "$rc|$out" '0|{"detail":"تعذر إكمال الخطوة \"scenarios\"","next":"stopped","reason":"step-failed"}'
  check "$E next after a stop, asked again" "$(NOW="2026-11-29T08:00:00Z" nx "$P")" "$out"
  check "$E next after a stop writes nothing" "$(snapshot "$P")" "$before"
  out="$(auto step-start checkout scenarios --project "$P" 2>&1)"; rc=$?
  check "$E step-start on a stopped journey" "$rc|$out" "1|auto: no open journey for checkout"
  artifact "$P" scenarios
  out="$(auto step-done checkout scenarios --project "$P" 2>&1)"; rc=$?
  check "$E step-done on a stopped journey" "$rc|$out" "1|auto: no open journey for checkout"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin on a stopped journey" "$rc|$out" "1|auto: no open journey for checkout"
  check "$E a stopped journey keeps its steps" "$(steps "$J")" "constitution=done,spec=done,scenarios=pending,analyze=pending,run=pending,verify=pending"

  # ---- signin_partial_lists_missing ----
  P="$(mkproj "$(cat "$FX/config-personas.json")")"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  before="$(snapshot "$P")"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin_partial_lists_missing" "$rc|$out" '0|{"missing":["cashier","branch-manager","accountant"],"ok":["admin","visitor"]}'
  check "$E signin with some personas ready writes nothing" "$(snapshot "$P")" "$before"
  mkdir -p "$P/.qa/auth"; printf '{"cookies":[]}\n' > "$P/.qa/auth/cashier.json"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E a persona whose named file now exists is ready" "$rc|$out" '0|{"missing":["branch-manager","accountant"],"ok":["admin","cashier","visitor"]}'
  check "$E the journey stays open" "$(jv "$J" 'd["state"]')" "open"

  # ---- signin_none_stops ----
  P="$(mkproj '{"baseUrl":"http://localhost:3000","personas":[{"id":"admin","role":"admin","plane":"global","auth":"unknown"},{"id":"cashier","role":"cashier","plane":"global","auth":"Unknown: no seeded login found"},{"id":"auditor","role":"auditor","plane":"global","auth":".qa/auth/auditor.json"}]}')"; J="$P/.qa/specs/checkout/auto/journey.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  out="$(NOW="2026-11-27T08:20:00Z" auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin_none_stops" "$rc|$out" '0|{"missing":["admin","cashier","auditor"],"ok":[]}'
  check "$E signin none: journey stopped no-sign-in" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["stop"]["detail"],d["endedAt"]]')" '["stopped", "no-sign-in", "no persona has sign-in configured", "2026-11-27T08:20:00Z"]'
  check "$E signin none: next repeats the stop" "$(nx "$P")" '{"detail":"no persona has sign-in configured","next":"stopped","reason":"no-sign-in"}'
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E a no-sign-in stop cannot be resumed" "$rc|$out" "1|auto: nothing to resume"
  # a project with no personas has one sign-in: auth.storageState
  P="$(journey_at constitution)"; J="$P/.qa/specs/checkout/auto/journey.json"
  mkdir -p "$P/.qa/auth"; printf '{"cookies":[]}\n' > "$P/.qa/auth/storageState.json"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E no personas: the project's storageState file is the sign-in" "$rc|$out|$(jv "$J" 'd["state"]')" '0|{"missing":[],"ok":["default"]}|open'
  rm -f "$P/.qa/auth/storageState.json"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E no personas and no storageState file stops" "$rc|$out|$(jv "$J" 'd["state"]+"/"+d["stop"]["reason"]')" '0|{"missing":["default"],"ok":[]}|stopped/no-sign-in'
  P="$(journey_at constitution)"
  printf '{"baseUrl":' > "$P/.qa/config.json"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin on a broken config" "$rc|$out" "1|auto: .qa/config.json is not valid JSON"
  rm -f "$P/.qa/config.json"
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin without a config" "$rc|$out" "1|auto: no .qa/config.json; set the project up first"
  check "$E a refused signin leaves the journey open" "$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "open"
}

command -v jq >/dev/null 2>&1 && run_engine_steps jq
run_engine_steps python3

# ---- both engines: byte-identical files and output ----
if command -v jq >/dev/null 2>&1; then
  build_x() {
    # number spellings the two engines would print differently if they were not normalised
    local P; P="$(mkproj '{"baseUrl":"https://staging.matjar.example.sa","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE","gates":{"dataPolicy":"enforce","weight":1.0,"limit":1E+3},"humanInteraction":{"enforce":true,"maxOptOutRate":0.20}}')"
    mkdir -p "$P/.qa/specs/checkout"
    printf '{}\n' > "$P/.qa/constitution.state.json"
    cp "$FX/checklist.json" "$P/.qa/specs/checkout/checklist.json"
    cp "$FX/coverage-exclusions.json" "$P/.qa/specs/checkout/coverage-exclusions.json"
    cp "$FX/known-defects.json" "$P/.qa/known-defects.json"
    printf '{"profile":"ship","humanInteraction":{"maxOptOutRate":0.1}}\n' > "$P/.qa/specs/checkout/run-config.json"
    printf '%s' "$P"
  }
  XJ="$(build_x)"; XP="$(build_x)"
  for v in "start checkout --until scenarios --max-hours 2.5" "status checkout" "stop checkout --reason until --detail توقف-قبل-التشغيل" "status checkout" "resume checkout" "status checkout" "stop checkout --reason blocked --detail coverage" "start checkout"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine output identical: $v" "$oj" "$op"
    check "cross-engine journey.json identical after: $v" "$(cksum < "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/journey.json")"
    check "cross-engine baseline.json identical after: $v" "$(cksum < "$XJ/.qa/specs/checkout/auto/baseline.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/baseline.json")"
  done
  check "numbers are written one way" "$(grep -c '"humanInteraction.maxOptOutRate": 0.2,$' "$XJ/.qa/specs/checkout/auto/baseline.json")/$(grep -c '"weight": 1$' "$XP/.qa/specs/checkout/auto/baseline.json")" "1/1"
  check "cross-engine history identical" "$(cksum < "$XJ/.qa/specs/checkout/auto/history/1/journey.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/history/1/journey.json")"
  for v in "start" "start checkout --profile fast" "stop checkout --reason tired --detail x" "status nothing-here" "resume nothing-here"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine refusal identical: $v" "$oj" "$op"
  done

  # the step verbs: one journey walked to the end, one blocked twice, one without sign-in
  build_y() {
    local P; P="$(mkproj "$(cat "$FX/config-personas.json")")"
    artifact "$P" constitution; artifact "$P" spec; artifact "$P" scenarios; artifact "$P" "$1"
    artifact "$P" run; artifact "$P" verify
    printf '%s' "$P"
  }
  cross() {
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $2 --project "$YJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $2 --project "$YP" 2>&1; echo "rc=$?")"
    check "cross-engine $1 output identical: $2" "$oj" "$op"
    check "cross-engine $1 journey.json identical after: $2" "$(cat "$YJ/.qa/specs/checkout/auto/journey.json" 2>/dev/null | cksum)" "$(cat "$YP/.qa/specs/checkout/auto/journey.json" 2>/dev/null | cksum)"
  }
  YJ="$(build_y analyze)"; YP="$(build_y analyze)"
  for v in "next checkout" "start checkout --max-hours 2" "signin checkout" "next checkout" "step-done checkout run --run r1" "step-start checkout analyze" "step-start checkout analyze" "status checkout" "step-done checkout analyze" "next checkout" "step-done checkout run" "step-done checkout run --run r9" "step-start checkout run" "step-done checkout run --run r1" "step-done checkout verify" "status checkout" "next checkout" "next checkout" "step-start checkout verify" "signin checkout"; do
    cross walk "$v"
  done
  YJ="$(build_y blocked)"; YP="$(build_y blocked)"
  for v in "start checkout" "step-done checkout analyze" "next checkout" "step-start checkout scenarios" "step-done checkout scenarios" "step-done checkout analyze" "next checkout" "status checkout"; do
    cross blocked "$v"
  done
  YJ="$(mkproj '{"baseUrl":"http://localhost:3000","personas":[{"id":"مدير","role":"admin","plane":"global","auth":"unknown"},{"id":"cash\"ier","role":"cashier","plane":"global"}]}')"
  YP="$(mkproj '{"baseUrl":"http://localhost:3000","personas":[{"id":"مدير","role":"admin","plane":"global","auth":"unknown"},{"id":"cash\"ier","role":"cashier","plane":"global"}]}')"
  for v in "start checkout --until spec" "signin checkout" "next checkout" "status checkout"; do
    cross no-sign-in "$v"
  done
  YJ="$(build_y analyze)"; YP="$(build_y analyze)"
  for v in "start checkout --until scenarios --max-hours 0.5" "next checkout" "resume checkout --max-hours 0.5" "next checkout"; do
    cross until "$v"
  done
  oj="$(E=jq; NOW="2026-11-27T12:00:00Z" auto next checkout --project "$YJ" 2>&1; echo "rc=$?")"
  op="$(E=python3; NOW="2026-11-27T12:00:00Z" auto next checkout --project "$YP" 2>&1; echo "rc=$?")"
  check "cross-engine time-limit output identical" "$oj" "$op"
  check "cross-engine time-limit journey.json identical" "$(cksum < "$YJ/.qa/specs/checkout/auto/journey.json")" "$(cksum < "$YP/.qa/specs/checkout/auto/journey.json")"
fi

echo "qa-auto: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
