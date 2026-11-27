#!/usr/bin/env bash
# Dual-engine tests for the limits of the step verbs of qa-kit/scripts/auto.sh (an unattended
# journey): the one machine-readable analysis verdict, what `step-done` asks of a run and of a
# verification, the time limit and `--until` in `step-start` and `step-done`, and what counts as a
# configured sign-in. (The walk through the steps is tested in tests/qa-auto-steps/; the two are
# separate so each stays well inside the CI time cap.)
# Every case runs under QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines'
# files and output byte for byte. No live tracker, model or browser. bash 3.2 safe.
#
# "Now" is injected with QA_AUTO_NOW (ISO-8601 UTC) so deadlines are deterministic.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-limits: python3 is needed to read results - suite cannot run" >&2; exit 1; }
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
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" bash "$SH" "$@"; }
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
snapshot() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3); }
steps() { jv "$1" '",".join(s["name"]+"="+s["state"] for s in d["steps"])'; }

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
                  printf '{"criteria":[{"criterion_id":"C-001","persona":"admin","verdict":"pass","confidence":"high"}]}\n' > "$R/checkpoint.json"; printf '# Report\n' > "$R/report.md" ;;
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

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
run_engine_limits() {
  E="$1"
  local P J R out rc before s Q

  # ---- H4: the analysis verdict is ONE machine-readable line, read failing closed ----
  Q="$(journey_at analyze)"; verdict_file "$Q" "Verdict: PASS (advisory)"
  auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
  check "$E the line 'Verdict: PASS (advisory)' lets analyze be done" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" '[d["analyzeRounds"],d["steps"][3]["state"]]')" '0|[0, "done"]'
  Q="$(journey_at analyze)"; verdict_file "$Q" "Verdict: BLOCKED"
  auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
  check "$E the line 'Verdict: BLOCKED' is a blocked round" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" '[d["analyzeRounds"],d["steps"][3]["state"]]')" '0|[1, "pending"]'
  # blanks at the end of the line are tolerated (spaces, a tab, a carriage return)
  for s in "Verdict: PASS (advisory)   " "Verdict: PASS (advisory)	" "Verdict: PASS (advisory)$(printf '\r')"; do
    Q="$(journey_at analyze)"; verdict_file "$Q" "$s"
    auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
    check "$E blanks after the verdict line are tolerated [$(printf '%s' "$s" | od -An -c | tr -s ' ' | tail -c 12)]" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["steps"][3]["state"]')" "0|done"
  done
  # nothing else is: every other first line is no result, never a pass
  for s in "**BLOCKED** when the Coverage gate blocks; otherwise **PASS (advisory)**." "**PASS (advisory)**. The next step is the run." \
           "verdict: pass (advisory)" "VERDICT: BLOCKED" "Verdict: Pass (Advisory)" " Verdict: PASS (advisory)" "Verdict: PASS (advisory)." \
           "Verdict: BLOCKED (no census)" "**Verdict: PASS (advisory)**" "Verdict:PASS (advisory)" "PASS (advisory)" "Advisory only; 2 oracle gaps." \
           "- Verdict: PASS (advisory)" "> Verdict: BLOCKED"; do
    Q="$(journey_at analyze)"; verdict_file "$Q" "$s"
    before="$(snapshot "$Q")"
    out="$(auto step-done checkout analyze --project "$Q" 2>&1)"; rc=$?
    check "$E the first line [$s] is no result" "$rc|$out" "1|auto: analyze has no result yet"
    check "$E the first line [$s] changes nothing" "$(snapshot "$Q")" "$before"
  done
  # a verdict written on the heading line, a missing heading, an empty section, a second heading
  Q="$(journey_at analyze)"
  printf '# Analysis\n\n## Verdict: PASS (advisory)\n\nThe next step is the run.\n' > "$Q/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$Q/.qa/specs/checkout/analysis.md"
  out="$(auto step-done checkout analyze --project "$Q" 2>&1)"; rc=$?
  check "$E a verdict on the heading line is no result" "$rc|$out" "1|auto: analyze has no result yet"
  printf '# Analysis\n\nVerdict: PASS (advisory)\n' > "$Q/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$Q/.qa/specs/checkout/analysis.md"
  out="$(auto step-done checkout analyze --project "$Q" 2>&1)"; rc=$?
  check "$E a verdict line without the heading is no result" "$rc|$out" "1|auto: analyze has no result yet"
  printf '# Analysis\n\n## Verdict\n\n## Notes\n\nVerdict: PASS (advisory)\n' > "$Q/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$Q/.qa/specs/checkout/analysis.md"
  out="$(auto step-done checkout analyze --project "$Q" 2>&1)"; rc=$?
  check "$E a heading as the first line under Verdict is no result" "$rc|$out" "1|auto: analyze has no result yet"
  printf '# Analysis\n\n## Verdict\n\nVerdict: PASS (advisory)\n\n## Verdict\n\nVerdict: BLOCKED\n' > "$Q/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$Q/.qa/specs/checkout/analysis.md"
  out="$(auto step-done checkout analyze --project "$Q" 2>&1)"; rc=$?
  check "$E two Verdict headings are no result" "$rc|$out" "1|auto: analyze has no result yet"
  printf '# Analysis\n\n## Verdict  \n\n\n   \nVerdict: BLOCKED\nVerdict: PASS (advisory)\n' > "$Q/.qa/specs/checkout/analysis.md"; touch -t "$T_MID" "$Q/.qa/specs/checkout/analysis.md"
  auto step-done checkout analyze --project "$Q" >/dev/null 2>&1
  check "$E only the first line that is not blank is read" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["analyzeRounds"]')" "0|1"

  # ---- H3: the run step wants a finished run of this spec; verify wants a result that parses ----
  Q="$(journey_at run)"; J="$Q/.qa/specs/checkout/auto/journey.json"; R="$Q/.qa/runs/r1"
  for s in in-progress In-Progress IN-PROGRESS; do
    artifact "$Q" run; printf '{"run_id":"r1","started_at":"2026-11-27T08:30:00Z","status":"%s"}\n' "$s" > "$R/run-manifest.json"
    before="$(snapshot "$Q")"
    out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
    check "$E a run whose status is $s is refused" "$rc|$out" "1|auto: that run is still in progress"
    check "$E a run whose status is $s changes nothing" "$(snapshot "$Q")" "$before"
  done
  artifact "$Q" run; printf '{"criteria":[]}\n' > "$R/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a run with no results at all is refused" "$rc|$out" "1|auto: that run has no results for this spec"
  printf '{"criteria":[{"criterion_id":"R-101","verdict":"pass","checkpointed_at":"2026-11-27T08:40:00Z"},{"criterion_id":"R-102","verdict":"pass"},"C-001",{"verdict":"pass"}]}\n' > "$R/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a run whose results are another spec's is refused" "$rc|$out|$(jv "$J" 'd["runId"]')" "1|auto: that run has no results for this spec|null"
  printf '[]\n' > "$R/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E an empty list of results is refused" "$rc|$out" "1|auto: that run has no results for this spec"
  printf '{"criteria":[{"criterion_id":"C-0' > "$R/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a checkpoint.json that does not parse is no result" "$rc|$out" "1|auto: run has no result yet"
  : > "$R/checkpoint.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E an empty checkpoint.json is no result" "$rc|$out" "1|auto: run has no result yet"
  artifact "$Q" run; printf '{"run_id":"r1","started_at":"2026-11-27T08:30:00Z"' > "$R/run-manifest.json"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E a run-manifest.json that does not parse is no result" "$rc|$out" "1|auto: run has no result yet"
  artifact "$Q" run; : > "$R/report.md"
  out="$(auto step-done checkout run --run r1 --project "$Q" 2>&1)"; rc=$?
  check "$E an empty report.md is no result" "$rc|$out|$(jv "$J" '[d["runId"],d["steps"][4]["state"]]')" '1|auto: run has no result yet|[null, "pending"]'
  # a list of rows, the other spellings of the row id, a status that says the run ended
  artifact "$Q" run; printf '[{"criterionId":"C-002","verdict":"fail"}]\n' > "$R/checkpoint.json"
  printf '{"run_id":"r1","started_at":"2026-11-27T08:30:00Z","status":"Complete"}\n' > "$R/run-manifest.json"
  auto step-done checkout run --run r1 --project "$Q" >/dev/null 2>&1
  check "$E a finished run with one result for this spec is accepted" "$?|$(jv "$J" '[d["runId"],d["steps"][4]["state"]]')" '0|["r1", "done"]'
  # verify
  : > "$R/verification.json"
  out="$(auto step-done checkout verify --project "$Q" 2>&1)"; rc=$?
  check "$E an empty verification.json is no result" "$rc|$out" "1|auto: verify has no result yet"
  printf '{"overrides":' > "$R/verification.json"
  out="$(auto step-done checkout verify --project "$Q" 2>&1)"; rc=$?
  check "$E a verification.json that does not parse is no result" "$rc|$out|$(jv "$J" 'd["steps"][5]["state"]')" "1|auto: verify has no result yet|pending"
  printf '[]\n' > "$R/verification.json"
  auto step-done checkout verify --project "$Q" >/dev/null 2>&1
  check "$E a verification.json that parses is a result" "$?|$(jv "$J" 'd["steps"][5]["state"]')" "0|done"

  # ---- H1: the time limit and --until hold for step-start and step-done, not only for next ----
  local UNTIL_LINE='{"detail":"stopped after scenarios, as asked","next":"stopped","reason":"until"}'
  local LATE_LINE='{"detail":"the deadline 2026-11-27T14:00:00Z has passed","next":"stopped","reason":"time-limit"}'
  P="$(journey_at analyze --until scenarios)"; J="$P/.qa/specs/checkout/auto/journey.json"
  out="$(NOW="2026-11-27T08:45:00Z" auto step-start checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E step-start past --until stops the journey" "$rc|$out" "1|$UNTIL_LINE"
  check "$E step-start past --until: journey stopped, step untouched" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["endedAt"],d["steps"][3]["state"],d["steps"][3]["attempts"]]')" '["stopped", "until", "2026-11-27T08:45:00Z", "pending", 0]'
  check "$E next repeats that stop" "$(nx "$P")" "$UNTIL_LINE"
  P="$(journey_at analyze --until scenarios)"; J="$P/.qa/specs/checkout/auto/journey.json"
  artifact "$P" analyze
  out="$(auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E step-done past --until stops the journey" "$rc|$out" "1|$UNTIL_LINE"
  check "$E step-done past --until: nothing is marked done" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["steps"][3]["state"]]')" '["stopped", "until", "pending"]'
  # the until step itself may still be started and finished
  P="$(journey_at scenarios --until scenarios)"
  auto step-start checkout scenarios --project "$P" >/dev/null 2>&1; rc=$?
  artifact "$P" scenarios; auto step-done checkout scenarios --project "$P" >/dev/null 2>&1
  check "$E the --until step itself is started and finished" "$rc|$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" '[d["state"],d["steps"][2]["state"]]')" '0|0|["open", "done"]'
  # the time limit, for each of the last three steps, a day late
  for s in analyze run verify; do
    P="$(journey_at "$s")"; J="$P/.qa/specs/checkout/auto/journey.json"
    out="$(NOW="2026-11-28T14:00:00Z" auto step-start checkout "$s" --project "$P" 2>&1)"; rc=$?
    check "$E step-start $s after the deadline stops the journey" "$rc|$out" "1|$LATE_LINE"
    check "$E step-start $s after the deadline: stopped, step untouched" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["endedAt"],[x["state"] for x in d["steps"] if x["name"]=="'"$s"'"][0]]')" '["stopped", "time-limit", "2026-11-28T14:00:00Z", "pending"]'
    P="$(journey_at "$s")"; J="$P/.qa/specs/checkout/auto/journey.json"
    artifact "$P" "$s"
    if [ "$s" = run ]; then out="$(NOW="2026-11-28T14:00:00Z" auto step-done checkout run --run r1 --project "$P" 2>&1)"; rc=$?
    else out="$(NOW="2026-11-28T14:00:00Z" auto step-done checkout "$s" --project "$P" 2>&1)"; rc=$?; fi
    check "$E step-done $s, never started, after the deadline stops the journey" "$rc|$out" "1|$LATE_LINE"
    check "$E step-done $s after the deadline: nothing is marked done" "$(jv "$J" '[d["state"],d["stop"]["reason"],d["runId"] if "'"$s"'"!="verify" else None,[x["state"] for x in d["steps"] if x["name"]=="'"$s"'"][0]]')" '["stopped", "time-limit", null, "pending"]'
  done
  # the deadline itself has not passed
  P="$(journey_at analyze)"
  NOW="2026-11-27T14:00:00Z" auto step-start checkout analyze --project "$P" >/dev/null 2>&1
  check "$E step-start at the deadline itself is allowed" "$?" "0"
  # a step started before the deadline and finished after it is recorded; the journey stops next
  artifact "$P" analyze; J="$P/.qa/specs/checkout/auto/journey.json"
  out="$(NOW="2026-11-27T14:20:00Z" auto step-done checkout analyze --project "$P" 2>&1)"; rc=$?
  check "$E a step started in time and finished late is still recorded" "$rc|$(js "$out" '[d["state"],d["steps"][3]["state"]]')" '0|["open", "done"]'
  out="$(NOW="2026-11-27T14:21:00Z" auto step-start checkout run --project "$P" 2>&1)"; rc=$?
  check "$E and the journey stops at the next step-start" "$rc|$out" "1|$LATE_LINE"
  P="$(journey_at analyze)"; artifact "$P" analyze
  NOW="2026-11-27T13:59:00Z" auto step-start checkout analyze --project "$P" >/dev/null 2>&1
  NOW="2026-11-27T14:20:00Z" auto step-done checkout analyze --project "$P" >/dev/null 2>&1
  check "$E or at the next next" "$?|$(NOW="2026-11-27T14:21:00Z" nx "$P")" "0|$LATE_LINE"
  # after a resume the limits are the new ones
  NOW="2026-11-27T15:00:00Z" auto resume checkout --project "$P" >/dev/null 2>&1
  NOW="2026-11-27T15:01:00Z" auto step-start checkout run --project "$P" >/dev/null 2>&1
  check "$E after a resume the step verbs work again" "$?" "0"
  # T1: the journey records when its steps last changed
  check "$E a step verb records when the steps last changed" "$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["stepsChangedAt"]')" "2026-11-27T15:01:00Z"

  # ---- m3: only a real way to sign in counts as configured ----
  P="$(mkproj '{"baseUrl":"http://localhost:3000","personas":[
    {"id":"p-todo","auth":"TODO"},{"id":"p-none","auth":"none"},{"id":"p-notconf","auth":"not configured"},{"id":"p-q","auth":"?"},
    {"id":"p-vague","auth":"capture a fresh storageState by logging in"},{"id":"p-at","auth":"@"},{"id":"p-blank","auth":"   "},
    {"id":"p-unknown","auth":"UNKNOWN: qa.owner@shop.test might exist"},{"id":"p-num","auth":7},
    {"id":"p-seeded","auth":"qa.admin@<host> (seeded credential loop; password via a named constant, not printed)"},
    {"id":"p-loginas","auth":"Login as the global-role account holding this team membership"},
    {"id":"p-anon","auth":"None needed"},
    {"id":"p-file","auth":"storageState at .qa/auth/Cashier.JSON."},{"id":"p-nofile","auth":".qa/auth/missing.json"},
    {"id":"p-up","auth":"../outside-state.json"},{"id":"p-abs","auth":"ABSPATH"},{"id":"p-link","auth":".qa/auth/linked.json"},
    {"id":"p-dirlink","auth":".qa/linkdir/state.json"},{"id":"p-absin","auth":"ABSIN"}]}')"
  mkdir -p "$P/.qa/auth" "$ROOT/elsewhere"
  printf '{"cookies":[]}\n' > "$P/.qa/auth/Cashier.JSON"; printf '{"cookies":[]}\n' > "$P/../outside-state.json"
  printf '{"cookies":[]}\n' > "$ROOT/elsewhere/state.json"
  ln -s "$ROOT/elsewhere/state.json" "$P/.qa/auth/linked.json"; ln -s "$ROOT/elsewhere" "$P/.qa/linkdir"
  "$PY" -c 'import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read().replace("ABSPATH",sys.argv[2]).replace("ABSIN",sys.argv[3]); open(p,"w",encoding="utf-8").write(s)' "$P/.qa/config.json" "$ROOT/elsewhere/state.json" "$P/.qa/auth/Cashier.JSON"
  auto start checkout --project "$P" >/dev/null 2>&1
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E signin counts only a real way to sign in" "$rc|$out" '0|{"missing":["p-todo","p-none","p-notconf","p-q","p-vague","p-at","p-blank","p-unknown","p-num","p-nofile","p-up","p-abs","p-link","p-dirlink"],"ok":["p-seeded","p-loginas","p-anon","p-file","p-absin"]}'
  rm -f "$P/../outside-state.json"
  # the project's one storageState must be inside the project too
  P="$(mkproj '{"baseUrl":"http://localhost:3000","auth":{"storageState":"../outside-state.json"}}')"
  printf '{"cookies":[]}\n' > "$P/../outside-state.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
  check "$E a storageState outside the project is not a sign-in" "$rc|$out" '0|{"missing":["default"],"ok":[]}'
  rm -f "$P/../outside-state.json"
}

command -v jq >/dev/null 2>&1 && run_engine_limits jq
run_engine_limits python3

# ---- both engines: byte-identical files and output ----
if command -v jq >/dev/null 2>&1; then
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
  # H1: the step verbs stop the journey the same way under both engines
  YJ="$(build_y analyze)"; YP="$(build_y analyze)"
  for v in "start checkout --until scenarios" "step-start checkout analyze" "status checkout" "resume checkout" "step-start checkout analyze" "step-done checkout analyze" "step-done checkout run --run r1" "status checkout"; do
    cross limits "$v"
  done
  oj="$(E=jq; NOW="2026-11-28T12:00:00Z" auto step-done checkout verify --project "$YJ" 2>&1; echo "rc=$?")"
  op="$(E=python3; NOW="2026-11-28T12:00:00Z" auto step-done checkout verify --project "$YP" 2>&1; echo "rc=$?")"
  check "cross-engine step-done after the deadline identical" "$oj" "$op"
  check "cross-engine step-done after the deadline journey.json identical" "$(cksum < "$YJ/.qa/specs/checkout/auto/journey.json")" "$(cksum < "$YP/.qa/specs/checkout/auto/journey.json")"
  # m8: a persona id that holds U+007F is printed the same way by both engines
  YJ="$(mkproj '{"baseUrl":"http://localhost:3000","personas":[{"id":"del\u007fete","auth":"qa.admin@shop.test"},{"id":"tab\tid","auth":"unknown"}]}')"
  YP="$(mkproj '{"baseUrl":"http://localhost:3000","personas":[{"id":"del\u007fete","auth":"qa.admin@shop.test"},{"id":"tab\tid","auth":"unknown"}]}')"
  for v in "start checkout" "signin checkout"; do
    cross del "$v"
  done
  check "signin prints U+007F as an escape under both engines" "$(E=python3; auto signin checkout --project "$YP" 2>&1)" '{"missing":["tab\tid"],"ok":["del\u007fete"]}'
fi

echo "qa-auto-limits: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
