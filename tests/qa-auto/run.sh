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
TMPDIRS=()
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
  local P; P="$(mktemp -d)"; TMPDIRS+=("$P"); mkdir -p "$P/.qa"
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
  check "$E J3 keys exactly" "$(jv "$J" '",".join(sorted(d.keys()))')" "analyzeRounds,deadline,endedAt,profile,runId,startedAt,state,steps,stop,target,until,version"
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

  # ---- start_refuses_production ----
  P="$(mkproj '{"baseUrl":"http://localhost:3000","environment":"production","seedableEnvMarker":"MATJAR_DISPOSABLE"}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_production (explicit)" "$rc|$out" "1|auto: this environment is production; an unattended journey does not run there"
  check "$E production writes nothing" "$([ -e "$P/.qa/specs" ] && echo yes || echo no)" "no"
  P="$(mkproj '{"baseUrl":"https://app.example.sa","environment":"auto","seedableEnvMarker":""}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_production (auto, non-local, empty marker)" "$rc|$out" "1|auto: this environment is production; an unattended journey does not run there"
  P="$(mkproj '{"baseUrl":"https://app.example.sa","environment":"auto","seedableEnvMarker":"QA_DISPOSABLE_ENV","gates":{"dataPolicy":"enforce"}}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_production (bootstrap sentinel marker)" "$rc|$out" "1|auto: this environment is production; an unattended journey does not run there"
  P="$(mkproj '{"baseUrl":"https://app.example.sa","gates":{"dataPolicy":"enforce"}}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_production (environment absent = auto)" "$rc|$out" "1|auto: this environment is production; an unattended journey does not run there"
  P="$(mkproj '{"baseUrl":"https://localhost.example.sa","environment":"auto","seedableEnvMarker":""}')"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E a host that only contains 'localhost' is not local" "$?" "1"

  # ---- start_allows_local_auto ----
  P="$(mkproj '{"baseUrl":"http://shop.ddev.site","environment":"auto","seedableEnvMarker":""}')"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E start_allows_local_auto (*.ddev.site)" "$?" "0"
  local u
  for u in "http://localhost:3000" "http://127.0.0.1:8000/app" "http://[::1]:5173" "https://shop.localhost" "http://matjar.test" "http://Matjar.LOCAL:8080" "http://user@shop.ddev.site/x"; do
    P="$(mkproj "{\"baseUrl\":\"$u\",\"environment\":\"auto\"}")"
    auto start checkout --project "$P" >/dev/null 2>&1
    check "$E local host allowed: $u" "$?" "0"
  done

  # ---- start_refuses_shared_without_data_policy ----
  P="$(mkproj '{"baseUrl":"https://staging.matjar.example.sa","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE"}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start_refuses_shared_without_data_policy" "$rc|$out" "1|auto: the environment is shared and gates.dataPolicy is not enforce"
  check "$E shared refusal writes nothing" "$([ -e "$P/.qa/specs" ] && echo yes || echo no)" "no"
  P="$(mkproj '{"baseUrl":"https://staging.matjar.example.sa","environment":"disposable","seedableEnvMarker":"MATJAR_DISPOSABLE","gates":{"dataPolicy":"advise"}}')"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E shared with dataPolicy advise refused" "$rc|$out" "1|auto: the environment is shared and gates.dataPolicy is not enforce"
  P="$(mkproj "$SHARED_OK")"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E shared with dataPolicy enforce allowed" "$?" "0"
  # the ship profile fills gates.dataPolicy when the project does not set it (profile.sh, ADR-0030)
  P="$(mkproj '{"baseUrl":"https://staging.matjar.example.sa","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE"}')"
  auto start checkout --project "$P" --profile ship >/dev/null 2>&1
  check "$E shared under the ship profile allowed (profile fills the gate)" "$?" "0"
  P="$(mkproj '{"baseUrl":"https://staging.matjar.example.sa","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE","gates":{"dataPolicy":"advise"}}')"
  auto start checkout --project "$P" --profile ship >/dev/null 2>&1
  check "$E a set gates.dataPolicy wins over the ship profile" "$?" "1"
  # a local environment needs no data policy gate
  P="$(mkproj '{"baseUrl":"http://shop.ddev.site","environment":"auto","gates":{"dataPolicy":"advise"}}')"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E local environment does not need the gate" "$?" "0"

  # known-defects registry rejected by the engine's validator (the command passes the flag)
  P="$(mkproj)"
  out="$(auto start checkout --project "$P" --known-defects-invalid 2>&1)"; rc=$?
  check "$E start_refuses_invalid_known_defects" "$rc|$out" "1|auto: .qa/known-defects.json is not valid"

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
  printf '[{"id":"D1","needsPerson":true},{"id":"D2","needsPerson":false},{"id":"D3","needsPerson":true}]\n' > "$P/.qa/specs/checkout/auto/decisions.json"
  check "$E status counts decisions that need a person" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "2"
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
    printf '[{"id":"D1","needsPerson":true}]\n' > "$P/.qa/specs/checkout/decisions.seed"
    printf '%s' "$P"
  }
  XJ="$(build_x)"; XP="$(build_x)"
  for v in "start checkout --until scenarios --max-hours 2.5" "status checkout" "stop checkout --reason until --detail توقف-قبل-التشغيل" "status checkout" "resume checkout" "status checkout" "stop checkout --reason blocked --detail coverage" "start checkout"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine output identical: $v" "$oj" "$op"
    check "cross-engine journey.json identical after: $v" "$(cat "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cat "$XP/.qa/specs/checkout/auto/journey.json")"
    check "cross-engine baseline.json identical after: $v" "$(cat "$XJ/.qa/specs/checkout/auto/baseline.json")" "$(cat "$XP/.qa/specs/checkout/auto/baseline.json")"
  done
  check "numbers are written one way" "$(grep -c '"humanInteraction.maxOptOutRate": 0.2,$' "$XJ/.qa/specs/checkout/auto/baseline.json")/$(grep -c '"weight": 1$' "$XP/.qa/specs/checkout/auto/baseline.json")" "1/1"
  check "cross-engine history identical" "$(cat "$XJ/.qa/specs/checkout/auto/history/1/journey.json")" "$(cat "$XP/.qa/specs/checkout/auto/history/1/journey.json")"
  for v in "start" "start checkout --profile fast" "stop checkout --reason tired --detail x" "status nothing-here" "resume nothing-here"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine refusal identical: $v" "$oj" "$op"
  done
fi

echo "qa-auto: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
