#!/usr/bin/env bash
# Dual-engine tests for the lock and the writes of qa-kit/scripts/auto.sh (an unattended journey):
# an unreadable journey or folder anywhere in the project, a target that is not a plain name, what
# a failed write does, a journey folder that is a link, and how arguments are read. (What `start`
# and `resume` refuse about the settings is tested in tests/qa-auto-gate/; the two are separate so
# each stays well inside the CI time cap.)
# Every case runs under QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines'
# files and output byte for byte. No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-lock: python3 is needed to read results - suite cannot run" >&2; exit 1; }
# The real interpreter, not a version-manager shim (see tests/qa-auto/run.sh).
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; [ -x "$PY" ] || PY=python3
case "$PY" in */python3) PATH="${PY%/python3}:$PATH"; export PATH ;; esac
pass=0; fail=0
ROOT="$(mktemp -d)"
# Some cases take the write permission off a directory; give it back before removing the tree.
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" bash "$SH" "$@"; }
jv() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
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
snapshot() { (cd "$1" && { find . \( -type l -o -type d \); find . -type f -exec cksum {} + 2>&1; } | LC_ALL=C sort); }
# tpl <open|stopped> — a project whose journey for `checkout` is open, or stopped at the time
# limit. Built once per engine, then copied: `start` is the slow verb.
tpl() {
  local want="$1" t="$ROOT/tpl-$E-$1" P
  if [ ! -d "$t" ]; then
    P="$(mkproj)"
    auto start checkout --project "$P" >/dev/null 2>&1
    [ "$want" = stopped ] && auto stop checkout --project "$P" --reason time-limit --detail "the deadline has passed" >/dev/null 2>&1
    mv "$P" "$t"
  fi
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; rmdir "$P"; cp -Rp "$t" "$P"
  printf '%s' "$P"
}
# first <command…> — exit code, then the first line of what the command printed.
first() { local out rc; out="$("$@" 2>&1)"; rc=$?; printf '%s|%s' "$rc" "$(printf '%s\n' "$out" | sed -n '1p')"; }
# refused <label> <config json> <line> [start flags…] — `start` on that config is refused with
# exactly that line and writes nothing.
refused() {
  local label="$1" P out rc; P="$(mkproj "$2")"; local want="$3"; shift 3
  out="$(auto start checkout --project "$P" "$@" 2>&1)"; rc=$?
  check "$E $label" "$rc|$out|$([ -e "$P/.qa/specs" ] && echo wrote || echo clean)" "1|$want|clean"
}
# allowed <label> <config json> [start flags…]
allowed() {
  local label="$1" P; P="$(mkproj "$2")"; shift 2
  auto start checkout --project "$P" "$@" >/dev/null 2>&1
  check "$E $label" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "0|open"
}
L_PROD="auto: this environment is production; an unattended journey does not run there"
L_SHARED="auto: the environment is shared and gates.dataPolicy is not enforce"
L_ENV="auto: environment must be auto, production or disposable"
L_HOURS="auto: --max-hours must be between 0.1 and 72"
L_NAME="auto: the target must be a plain name"
HOST="https://staging.matjar.example.sa"
SHARED_OK="{\"baseUrl\":\"$HOST\",\"environment\":\"auto\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"enforce\"}}"
ROOTUSER=0; [ "$(id -u)" = 0 ] && ROOTUSER=1

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
run_engine() {
  E="$1"
  local P J B Q A out rc before v k

  # ---- G4: the one-journey lock fails closed ----
  # another target's journey that cannot be read
  for v in '{"state":' '' '[]' '"open"' '{"state":"paused"}' '{"state":5}' '{"target":"checkout"}'; do
    P="$(tpl stopped)"; J="$P/.qa/specs/checkout/auto/journey.json"
    mkdir -p "$P/.qa/specs/returns/auto"; cp "$J" "$P/.qa/specs/returns/auto/journey.json"
    printf '%s' "$v" > "$J"; before="$(snapshot "$P")"
    out="$(auto start orders --project "$P" 2>&1)"; rc=$?
    check "$E start refused while another journey cannot be read [$v]" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    out="$(auto resume returns --project "$P" 2>&1)"; rc=$?
    check "$E resume refused while another journey cannot be read [$v]" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
    check "$E start refused on a journey of its own that cannot be read [$v]" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    out="$(auto start checkout --project "$P" --restart 2>&1)"; rc=$?
    check "$E --restart does not replace a journey that cannot be read [$v]" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
    check "$E resume refused on a journey of its own that cannot be read [$v]" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    check "$E a journey that cannot be read is left as it is [$v]" "$(snapshot "$P")" "$before"
  done
  P="$(tpl stopped)"; rm "$P/.qa/specs/checkout/auto/journey.json"; mkdir "$P/.qa/specs/checkout/auto/journey.json"
  out="$(auto start returns --project "$P" 2>&1)"; rc=$?
  check "$E a journey.json that is a directory cannot be read" "$rc|$out" "1|auto: the journey for checkout cannot be read"
  P="$(tpl stopped)"; rm "$P/.qa/specs/checkout/auto/journey.json"; ln -s "$P/nowhere.json" "$P/.qa/specs/checkout/auto/journey.json"
  out="$(auto start returns --project "$P" 2>&1)"; rc=$?
  check "$E a journey.json that is a link leading nowhere cannot be read" "$rc|$out" "1|auto: the journey for checkout cannot be read"
  if [ "$ROOTUSER" -eq 0 ]; then
    P="$(tpl open)"; chmod 000 "$P/.qa/specs/checkout/auto/journey.json"
    out="$(auto start returns --project "$P" 2>&1)"; rc=$?
    check "$E a journey.json without read permission cannot be read" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    chmod 644 "$P/.qa/specs/checkout/auto/journey.json"
  fi
  # a journey under a directory whose name starts with a dot still holds the lock
  P="$(tpl open)"; mv "$P/.qa/specs/checkout" "$P/.qa/specs/.hidden"
  out="$(auto start returns --project "$P" 2>&1)"; rc=$?
  check "$E an open journey in a dot directory holds the lock" "$rc|$out|$([ -e "$P/.qa/specs/returns" ] && echo wrote || echo clean)" "1|auto: another journey is open for .hidden|clean"
  P="$(tpl open)"; mv "$P/.qa/specs/checkout" "$P/.qa/specs/..x"
  out="$(auto start returns --project "$P" 2>&1)"; rc=$?
  check "$E an open journey in a two-dot directory holds the lock" "$rc|$out" "1|auto: another journey is open for ..x"
  # the target must be a plain name, for every verb
  P="$(tpl open)"; before="$(snapshot "$P")"
  for t in .hidden ..x a..b . .. a/b ../checkout -x "a b" "متجر" "check;out" 'a$b' "a
b" "" "_x"; do
    check "$E start: the target [$t] is not a plain name" "$(first auto start "$t" --project "$P")" "2|$L_NAME"
  done
  for v in resume status next signin audit; do
    check "$E $v: a target that is not a plain name is usage" "$(first auto "$v" .hidden --project "$P")" "2|$L_NAME"
  done
  check "$E stop: a target that is not a plain name is usage" "$(first auto stop a..b --project "$P" --reason until --detail x)" "2|$L_NAME"
  check "$E step-start: a target that is not a plain name is usage" "$(first auto step-start .hidden spec --project "$P")" "2|$L_NAME"
  check "$E step-done: a target that is not a plain name is usage" "$(first auto step-done 'a b' spec --project "$P")" "2|$L_NAME"
  check "$E decide: a target that is not a plain name is usage" "$(first auto decide .hidden --project "$P" --step spec --class scope --question q --answer a --evidence e --confidence high)" "2|$L_NAME"
  check "$E second: a target that is not a plain name is usage" "$(first auto second .hidden --unavailable --project "$P")" "2|$L_NAME"
  check "$E note: a target that is not a plain name is usage" "$(first auto note .hidden --project "$P" --kind seed-not-run --text x)" "2|$L_NAME"
  check "$E a refused target writes nothing" "$(snapshot "$P")" "$before"
  P="$(mkproj)"
  auto start Shop.v2_x-1 --project "$P" >/dev/null 2>&1
  check "$E letters, digits, dot, underscore and dash make a plain name" "$?|$(jv "$P/.qa/specs/Shop.v2_x-1/auto/journey.json" 'd["target"]')" "0|Shop.v2_x-1"
  P="$(mkproj)"
  auto start 9lives --project "$P" >/dev/null 2>&1
  check "$E a plain name may start with a digit" "$?" "0"

  # ---- G7: a restart of an open journey is recorded ----
  P="$(tpl open)"; J="$P/.qa/specs/checkout/auto/journey.json"
  check "$E a first journey has no restartedFrom" "$(jv "$J" '"restartedFrom" in d')" "false"
  out="$(auto start checkout --project "$P" --restart 2>&1)"; rc=$?
  check "$E restart of an open journey records restartedFrom" "$rc|$(jv "$J" 'd["restartedFrom"]')|$(js "$out" 'd["restartedFrom"]')" "0|1|1"
  check "$E the restarted journey went to that history number" "$(jv "$P/.qa/specs/checkout/auto/history/1/journey.json" 'd["state"]')" "open"
  check "$E status prints restartedFrom" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["restartedFrom"]')" "1"
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E a second restart names the second history number" "$(jv "$J" 'd["restartedFrom"]')" "2"
  auto stop checkout --project "$P" --reason time-limit --detail "paused" >/dev/null 2>&1
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E restart of a stopped journey records nothing" "$?|$(jv "$J" '"restartedFrom" in d')|$([ -d "$P/.qa/specs/checkout/auto/history/3" ] && echo yes || echo no)" "0|false|yes"
  auto stop checkout --project "$P" --reason blocked --detail "a person must act" >/dev/null 2>&1
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E a new journey after a finished one records nothing" "$?|$(jv "$J" '"restartedFrom" in d')" "0|false"

  # ---- M2: a byte order mark in front of a file changes nothing ----
  P="$(mkproj)"; B="$P/.qa/specs/checkout/auto/baseline.json"; mkdir -p "$P/.qa/specs/checkout"
  { printf '\357\273\277'; cat "$FX/config-local.json"; } > "$P/.qa/config.json"
  { printf '\357\273\277'; cat "$FX/checklist.json"; } > "$P/.qa/specs/checkout/checklist.json"
  { printf '\357\273\277'; printf '{"profile":"smoke","allowBlackboxCrawl":false}\n'; } > "$P/.qa/specs/checkout/run-config.json"
  { printf '\357\273\277'; cat "$FX/coverage-exclusions.json"; } > "$P/.qa/specs/checkout/coverage-exclusions.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start reads a config and a plan that begin with a byte order mark" "$rc|$(jv "$B" '[d["humanOracleIds"],d["planRowIds"],d["profile"],d["safety"]["environment"],len(d["exclusions"])]')" '0|[["C-001", "C-004"], ["C-001", "C-002", "C-003", "C-004", "C-005"], "smoke", "auto", 2]'
  { printf '\357\273\277'; printf '{"baseUrl":"http://localhost:3000","environment":"production"}'; } > "$P/.qa/config.json"
  auto stop checkout --project "$P" --reason time-limit --detail "paused" >/dev/null 2>&1
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E a byte order mark does not hide a production config" "$rc|$out" "1|$L_PROD"
  refused "a byte order mark does not hide a production config at start" "$(printf '\357\273\277{"baseUrl":"https://app.example.sa","environment":"auto"}')" "$L_PROD"

  # ---- M3: a plan that is not a list, decisions that do not parse ----
  for v in "{\"criteria\":$(cat "$FX/checklist.json")}" '"rows"' '7' 'null'; do
    P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"; printf '%s\n' "$v" > "$P/.qa/specs/checkout/checklist.json"
    out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
    check "$E start refuses a plan that is not a list of rows [${v:0:12}]" "$rc|$out|$([ -e "$P/.qa/specs/checkout/auto" ] && echo wrote || echo clean)" "1|auto: .qa/specs/checkout/checklist.json is not a list of rows|clean"
  done
  P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"; : > "$P/.qa/specs/checkout/checklist.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start refuses an empty plan file" "$rc|$out" "1|auto: .qa/specs/checkout/checklist.json is not valid JSON"
  P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"; printf '[]\n' > "$P/.qa/specs/checkout/checklist.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E a plan with no rows yet is a list" "$?|$(jv "$P/.qa/specs/checkout/auto/baseline.json" '[d["planRowIds"],d["humanOracleIds"],d["humanOracleHashes"]]')" '0|[[], [], {}]'
  for v in '[{"id":"D1",' '{"decisions":[]}' '[] []' '"x"'; do
    P="$(tpl open)"; printf '%s\n' "$v" > "$P/.qa/specs/checkout/auto/decisions.json"; before="$(snapshot "$P")"
    out="$(auto status checkout --project "$P" 2>&1)"; rc=$?
    check "$E status refuses decisions it cannot read [$v]" "$rc|$out|$([ "$(snapshot "$P")" = "$before" ] && echo same || echo changed)" "1|auto: decisions.json for checkout is not readable|same"
  done
  P="$(tpl open)"; : > "$P/.qa/specs/checkout/auto/decisions.json"
  check "$E an empty decisions file still reads as no decisions" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "0"
  printf '[{"id":"D1","needsPerson":true},"x",{"id":"D2","needsPerson":"true"},{"id":"D3","needsPerson":true}]\n' > "$P/.qa/specs/checkout/auto/decisions.json"
  check "$E status still counts the decisions that need a person" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "2"

  # ---- M4: a relative --project that starts with a dash ----
  Q="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$Q/-proj/.qa" "$Q/-proj/.qa/specs/checkout"; cp "$FX/config-local.json" "$Q/-proj/.qa/config.json"
  cp "$FX/checklist.json" "$Q/-proj/.qa/specs/checkout/checklist.json"; cp "$FX/known-defects.json" "$Q/-proj/.qa/known-defects.json"
  out="$(cd "$Q" && auto start checkout --project -proj 2>&1)"; rc=$?
  check "$E start with --project -proj" "$rc|$(js "$out" 'd["state"]')|$(jv "$Q/-proj/.qa/specs/checkout/auto/baseline.json" 'len(d["knownDefectsHash"])')" "0|open|64"
  out="$(cd "$Q" && auto stop checkout --project -proj --reason time-limit --detail "paused" 2>&1)"; rc=$?
  check "$E stop with --project -proj" "$rc|$(js "$out" 'd["state"]')" "0|stopped"
  out="$(cd "$Q" && auto resume checkout --project -proj/ 2>&1)"; rc=$?
  check "$E resume with --project -proj/" "$rc|$(js "$out" 'd["state"]')" "0|open"
  out="$(cd "$Q" && auto decide checkout --project -proj --step spec --class scope --question q --answer a --evidence e --confidence high 2>&1)"; rc=$?
  check "$E decide with --project -proj" "$rc|$out" "0|D1"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/trk-args.txt"\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\n' "$Q" > "$Q/trk.sh"
  out="$(cd "$Q" && QA_AUTO_TRACKER_CMD="bash $Q/trk.sh" auto audit checkout --project -proj 2>&1)"; rc=$?
  check "$E audit with --project -proj" "$rc|$out|$(cat "$Q/trk-args.txt" 2>/dev/null)" '0|{"ok":true,"violations":[]}|spec-status --spec checkout --project ./-proj'

  # ---- M6: an option nobody registered is a usage error, never the target ----
  P="$(tpl open)"; before="$(snapshot "$P")"
  for v in start resume stop status next step-start step-done signin decide second note audit; do
    check "$E $v --zzz is a usage error" "$(first auto "$v" --zzz --project "$P")" "2|auto: $v does not take: --zzz"
    check "$E $v --zzz before the target is a usage error" "$(first auto "$v" --zzz returns checkout --project "$P")" "2|auto: $v does not take: --zzz"
  done
  check "$E an option with = is not known either" "$(first auto status checkout --project="$P")" "2|auto: status does not take: --project=$P"
  check "$E a bare -- is not the target" "$(first auto status -- checkout --project "$P")" "2|auto: status does not take: --"
  check "$E unknown options write nothing" "$(snapshot "$P")|$([ -e "$P/.qa/specs/returns" ] && echo wrote || echo clean)" "$before|clean"
  check "$E a known option of another verb is still refused by the verb" "$(first auto status checkout --restart --project "$P")" "2|auto: status does not take: --restart"

  # ---- G2: a write that fails stops the verb ----
  if [ "$ROOTUSER" -eq 0 ]; then
    P="$(tpl open)"; J="$P/.qa/specs/checkout/auto/journey.json"; chmod 555 "$P/.qa/specs/checkout/auto"; before="$(snapshot "$P")"
    out="$(auto stop checkout --project "$P" --reason step-failed --detail "the application did not answer" 2>&1)"; rc=$?
    check "$E stop on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    check "$E the failed stop changed nothing" "$(snapshot "$P")|$(jv "$J" 'd["state"]')" "$before|open"
    out="$(NOW="2026-11-28T08:00:00Z" auto next checkout --project "$P" 2>&1)"; rc=$?
    check "$E next that cannot record the time limit" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    mkdir -p "$P/.qa/auth"
    out="$(auto signin checkout --project "$P" 2>&1)"; rc=$?
    check "$E signin that cannot record the stop" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    out="$(auto step-start checkout constitution --project "$P" 2>&1)"; rc=$?
    check "$E step-start on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    printf '{"version":"c1"}\n' > "$P/.qa/constitution.state.json"
    out="$(auto step-done checkout constitution --project "$P" 2>&1)"; rc=$?
    check "$E step-done on a journey directory it cannot write" "$rc|$out|$(jv "$J" 'd["steps"][0]["state"]')" "1|auto: could not write .qa/specs/checkout/auto/journey.json|pending"
    out="$(auto start checkout --project "$P" --restart 2>&1)"; rc=$?
    check "$E a restart that cannot move the earlier journey" "$rc|$out|$(jv "$J" 'd["state"]')" "1|auto: could not write .qa/specs/checkout/auto/history/1|open"
    check "$E no temp file is left behind" "$(ls -A "$P/.qa/specs/checkout/auto" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json journey.json "
    chmod 755 "$P/.qa/specs/checkout/auto"
    P="$(tpl stopped)"; J="$P/.qa/specs/checkout/auto/journey.json"; chmod 555 "$P/.qa/specs/checkout/auto"; before="$(snapshot "$P")"
    out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
    check "$E resume on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    check "$E the failed resume changed nothing" "$(snapshot "$P")|$(jv "$J" 'd["state"]')" "$before|stopped"
    chmod 755 "$P/.qa/specs/checkout/auto"
    P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout/auto"; chmod 555 "$P/.qa/specs/checkout/auto"
    out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
    check "$E start whose baseline cannot be written writes no journey" "$rc|$out|$(ls -A "$P/.qa/specs/checkout/auto" | tr '\n' ' ')" "1|auto: could not write .qa/specs/checkout/auto/baseline.json|"
    chmod 755 "$P/.qa/specs/checkout/auto"
    P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"; chmod 555 "$P/.qa/specs/checkout"
    out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
    check "$E start that cannot make the journey directory" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto"
    chmod 755 "$P/.qa/specs/checkout"
  else
    echo "SKIP: $E the permission cases (running as root)"
  fi

  # ---- m1: the journey folder must be a real folder; a folder where a file goes is a failed write ----
  L_REAL="auto: the journey folder must be a real folder"
  # lnk <open|stopped> <auto|spec> — a project whose journey folder (or spec folder) is a link to
  # a real folder kept elsewhere; the journey in it is readable through the link.
  lnk() {
    local P; P="$(tpl "$1")"
    mkdir -p "$P/elsewhere"
    if [ "$2" = auto ]; then mv "$P/.qa/specs/checkout/auto" "$P/elsewhere/auto"; ln -s "$P/elsewhere/auto" "$P/.qa/specs/checkout/auto"
    else mv "$P/.qa/specs/checkout" "$P/elsewhere/checkout"; ln -s "$P/elsewhere/checkout" "$P/.qa/specs/checkout"; fi
    printf '%s' "$P"
  }
  for k in auto spec; do
    P="$(lnk open "$k")"; mkdir -p "$P/.qa/auth"; printf '{"version":"c1"}\n' > "$P/.qa/constitution.state.json"; before="$(snapshot "$P")"
    check "$E stop through a linked $k folder" "$(first auto stop checkout --project "$P" --reason step-failed --detail x)" "1|$L_REAL"
    check "$E step-start through a linked $k folder" "$(first auto step-start checkout constitution --project "$P")" "1|$L_REAL"
    check "$E step-done through a linked $k folder" "$(first auto step-done checkout constitution --project "$P")" "1|$L_REAL"
    check "$E next that has to write through a linked $k folder" "$(NOW="2026-11-28T08:00:00Z" first auto next checkout --project "$P")" "1|$L_REAL"
    check "$E signin that has to write through a linked $k folder" "$(first auto signin checkout --project "$P")" "1|$L_REAL"
    check "$E decide through a linked $k folder" "$(first auto decide checkout --project "$P" --step spec --class scope --question q --answer a --evidence e --confidence high)" "1|$L_REAL"
    check "$E note through a linked $k folder" "$(first auto note checkout --project "$P" --kind seed-not-run --text "php artisan db:seed")" "1|$L_REAL"
    check "$E second --unavailable through a linked $k folder" "$(first auto second checkout --unavailable --project "$P")" "1|$L_REAL"
    check "$E audit through a linked $k folder" "$(QA_AUTO_TRACKER_CMD="printf SKIP\\tnot-set-up\\tcheckout\\n%.0s%.0s%.0s%.0s%.0s" first auto audit checkout --project "$P")" "1|$L_REAL"
    check "$E handoff through a linked $k folder" "$(first auto handoff checkout --project "$P")" "1|$L_REAL"
    check "$E start --restart through a linked $k folder" "$(first auto start checkout --restart --project "$P")" "1|$L_REAL"
    check "$E nothing was written through the linked $k folder" "$(snapshot "$P")" "$before"
    check "$E reading through a linked $k folder still works" "$(first auto next checkout --project "$P")" '0|{"next":"constitution"}'
    P="$(lnk stopped "$k")"; before="$(snapshot "$P")"
    check "$E resume through a linked $k folder" "$(first auto resume checkout --project "$P")|$([ "$(snapshot "$P")" = "$before" ] && echo same)" "1|$L_REAL|same"
  done
  P="$(mkproj)"; mkdir -p "$P/elsewhere/checkout" "$P/.qa/specs"; ln -s "$P/elsewhere/checkout" "$P/.qa/specs/checkout"
  check "$E start into a linked spec folder" "$(first auto start checkout --project "$P")|$(ls -A "$P/elsewhere/checkout" | wc -l | tr -d ' ')" "1|$L_REAL|0"
  P="$(mkproj)"; mkdir -p "$P/elsewhere/auto" "$P/.qa/specs/checkout"; ln -s "$P/elsewhere/auto" "$P/.qa/specs/checkout/auto"
  check "$E start into a linked journey folder" "$(first auto start checkout --project "$P")|$(ls -A "$P/elsewhere/auto" | wc -l | tr -d ' ')" "1|$L_REAL|0"
  P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"; ln -s "$P/nowhere" "$P/.qa/specs/checkout/auto"
  check "$E start into a journey folder that is a link leading nowhere" "$(first auto start checkout --project "$P")" "1|$L_REAL"
  # a folder at the path of a journey file: the write fails, it does not vanish into the folder
  P="$(tpl open)"; A="$P/.qa/specs/checkout/auto"; mkdir "$A/decisions.json" "$A/notes.json" "$A/handoff.md"
  out="$(auto decide checkout --project "$P" --step spec --class scope --question q --answer a --evidence e --confidence high 2>&1)"; rc=$?
  check "$E decide when decisions.json is a folder" "$rc|$out|$(ls -A "$A/decisions.json" | wc -l | tr -d ' ')" "1|auto: could not write .qa/specs/checkout/auto/decisions.json|0"
  out="$(auto note checkout --project "$P" --kind seed-not-run --text "php artisan db:seed" 2>&1)"; rc=$?
  check "$E note when notes.json is a folder" "$rc|$out|$(ls -A "$A/notes.json" | wc -l | tr -d ' ')" "1|auto: could not write .qa/specs/checkout/auto/notes.json|0"
  out="$(auto handoff checkout --project "$P" 2>&1)"; rc=$?
  check "$E handoff when handoff.md is a folder" "$rc|$out|$(ls -A "$A/handoff.md" | wc -l | tr -d ' ')" "1|auto: could not write .qa/specs/checkout/auto/handoff.md|0"
  check "$E no temp file is left beside the folders" "$(ls -A "$A" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json decisions.json handoff.md journey.json notes.json "

  # ---- m2: a spec folder or journey folder that cannot be looked into holds the lock ----
  if [ "$ROOTUSER" -eq 0 ]; then
    for k in spec auto empty; do
      P="$(tpl stopped)"; mkdir -p "$P/.qa/specs/returns/auto"
      case "$k" in
        spec)  cp "$P/.qa/specs/checkout/auto/journey.json" "$P/.qa/specs/returns/auto/journey.json"; chmod 000 "$P/.qa/specs/returns" ;;
        auto)  cp "$P/.qa/specs/checkout/auto/journey.json" "$P/.qa/specs/returns/auto/journey.json"; chmod 000 "$P/.qa/specs/returns/auto" ;;
        empty) rmdir "$P/.qa/specs/returns/auto"; chmod 000 "$P/.qa/specs/returns" ;;
      esac
      out="$(auto start orders --project "$P" 2>&1)"; rc=$?
      check "$E start refused while another target's $k folder cannot be looked into" "$rc|$out|$([ -e "$P/.qa/specs/orders" ] && echo wrote || echo clean)" "1|auto: the journey for returns cannot be read|clean"
      out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
      check "$E resume refused while another target's $k folder cannot be looked into" "$rc|$out|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "1|auto: the journey for returns cannot be read|stopped"
      out="$(auto start checkout --restart --project "$P" 2>&1)"; rc=$?
      check "$E a restart is refused too [$k]" "$rc|$out" "1|auto: the journey for returns cannot be read"
      chmod 755 "$P/.qa/specs/returns"; chmod 755 "$P/.qa/specs/returns/auto" 2>/dev/null
    done
    P="$(tpl stopped)"; chmod 000 "$P/.qa/specs/checkout/auto"
    out="$(auto start checkout --restart --project "$P" 2>&1)"; rc=$?
    check "$E start refused when its own journey folder cannot be looked into" "$rc|$out" "1|auto: the journey for checkout cannot be read"
    chmod 755 "$P/.qa/specs/checkout/auto"
    P="$(tpl stopped)"; mkdir -p "$P/.qa/specs/.hidden/auto"; chmod 000 "$P/.qa/specs/.hidden"
    out="$(auto start orders --project "$P" 2>&1)"; rc=$?
    check "$E a dot folder that cannot be looked into holds the lock too" "$rc|$out" "1|auto: the journey for .hidden cannot be read"
    chmod 755 "$P/.qa/specs/.hidden"
    P="$(tpl stopped)"; mkdir -p "$P/.qa/specs/returns/auto"; chmod 500 "$P/.qa/specs/returns" "$P/.qa/specs/returns/auto"
    auto start orders --project "$P" >/dev/null 2>&1
    check "$E a folder that can be read but not written does not hold the lock" "$?" "0"
    chmod 755 "$P/.qa/specs/returns" "$P/.qa/specs/returns/auto"
  else
    echo "SKIP: $E the unreadable folder cases (running as root)"
  fi
}

command -v jq >/dev/null 2>&1 && run_engine jq
run_engine python3

# ---- both engines: byte-identical files and output ----
if command -v jq >/dev/null 2>&1; then
  # same_file <label> <file under auto/> — the two engines' files, compared byte for byte
  same_file() { check "cross-engine $2 identical: $1" "$(cksum < "$XJ/.qa/specs/checkout/auto/$2" 2>&1)" "$(cksum < "$XP/.qa/specs/checkout/auto/$2" 2>&1)"; }
  build_x() {
    # a byte order mark, number spellings the engines would print differently, and expected
    # values whose canonical form has to come out the same under both
    local P; P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa/specs/checkout"
    printf '\357\273\277{"baseUrl":"HTTPS://Staging.Matjar.example.sa:8443/متجر?x=\\"1\\"","environment":"Disposable","seedableEnvMarker":"MATJAR_DISPOSABLE","gates":{"dataPolicy":"enforce","weight":1.0,"limit":1E+3},"humanInteraction":{"enforce":true,"maxOptOutRate":0.20}}' > "$P/.qa/config.json"
    printf '\357\273\277[{"id":"C-001","fixture":{"expect":{"value":"115.00","oracleSource":"human"}}},\n {"id":"معيار-٧ \\"مقتبس\\" \\\\ $HOME\\n`x`","fixture":{"expect":{"z":[1.0,2.50,1E+2,{"b":null,"a":true}],"oracleSource":"human","value":"١١٥٫٠٠ ريال \\u007f </script>","citation":"docs/pricing.md:12"}}},\n {"id":"C-003","fixture":{"expect":{"value":"3","oracleSource":"spec"}}},\n {"id":"C-001","fixture":{"expect":{"value":"second row with the same id","oracleSource":"human"}}},\n {"id":"C-004","fixture":{"expect":{"oracleSource":"human"}}}, "not a row", {"fixture":{"expect":{"oracleSource":"human"}}}]\n' > "$P/.qa/specs/checkout/checklist.json"
    cp "$FX/coverage-exclusions.json" "$P/.qa/specs/checkout/coverage-exclusions.json"
    cp "$FX/known-defects.json" "$P/.qa/known-defects.json"
    printf '%s' "$P"
  }
  XJ="$(build_x)"; XP="$(build_x)"
  for v in "start checkout --max-hours 0.1" "status checkout" "start checkout --restart --max-hours 72" "stop checkout --reason time-limit --detail توقف" "resume checkout --max-hours 71.5" "start checkout --restart --until spec" "status checkout" "stop checkout --reason blocked --detail coverage" "start checkout"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine output identical: $v" "$oj" "$op"
    same_file "after $v" journey.json; same_file "after $v" baseline.json
  done
  check "the journeys really ran" "$(jv "$XP/.qa/specs/checkout/auto/journey.json" '[d["state"],d["target"]]')|$(ls "$XJ/.qa/specs/checkout/auto/history" | tr '\n' ' ')" '["open", "checkout"]|1 2 3 '
  check "the baseline holds one hash per person-confirmed row" "$(jv "$XJ/.qa/specs/checkout/auto/baseline.json" '[sorted(len(v) for v in d["humanOracleHashes"].values()),sorted(d["humanOracleHashes"].keys())==d["humanOracleIds"],len(d["humanOracleIds"])]')" "[[64, 64, 64], true, 3]"
  check "the hash is the SHA-256 of the expected value in canonical form" "$(jv "$XP/.qa/specs/checkout/auto/baseline.json" 'd["humanOracleHashes"]["C-001"]')" "$(printf '%s' '{"oracleSource":"human","value":"115.00"}' | "$PY" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  check "the baseline keeps the address as written" "$(jv "$XJ/.qa/specs/checkout/auto/baseline.json" 'd["baseUrl"]')" 'HTTPS://Staging.Matjar.example.sa:8443/متجر?x="1"'
  for n in 1 2 3; do
    check "cross-engine history/$n identical" "$(cat "$XJ/.qa/specs/checkout/auto/history/$n/journey.json" "$XJ/.qa/specs/checkout/auto/history/$n/baseline.json" | cksum)" "$(cat "$XP/.qa/specs/checkout/auto/history/$n/journey.json" "$XP/.qa/specs/checkout/auto/history/$n/baseline.json" | cksum)"
  done
  RJ="$(E=jq; tpl stopped)"; RP="$(E=python3; tpl stopped)"
  printf '{"state":' > "$RJ/.qa/specs/checkout/auto/journey.json"; printf '{"state":' > "$RP/.qa/specs/checkout/auto/journey.json"
  cp "$FX/config-local.json" "$RJ/.qa/config.json"; cp "$FX/config-local.json" "$RP/.qa/config.json"
  for v in "start returns" "resume checkout" "start checkout --restart"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$RJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$RP" 2>&1; echo "rc=$?")"
    check "cross-engine lock refusal identical: $v" "$oj" "$op"
  done
fi

echo "qa-auto-lock: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
