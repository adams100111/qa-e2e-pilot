#!/usr/bin/env bash
# Dual-engine tests for the gatekeeper of qa-kit/scripts/auto.sh: what `start` and `resume` refuse
# (production, a shared environment without the data policy, an unreadable journey anywhere in the
# project, a target that is not a plain name), what a failed write does, and how arguments are
# read. (The state machine is tested in tests/qa-auto/, the decision verbs in
# tests/qa-auto-decisions/, the audit in tests/qa-auto-audit/; this suite is separate so each stays
# well inside the CI time cap.)
# Every case runs under QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines'
# files and output byte for byte. No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-gate: python3 is needed to read results - suite cannot run" >&2; exit 1; }
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
auto() { QA_ENGINE="$E" QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" bash "$SH" "$@"; }
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
snapshot() { (cd "$1" && find . \( -type f -o -type l -o -type d \) | LC_ALL=C sort | while IFS= read -r f; do if [ -f "$f" ]; then cksum "$f"; else echo "$f"; fi; done); }
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

run_engine() {
  E="$1"
  local P Q J B out rc before u v t

  # ---- start_refuses_production ----
  refused "start_refuses_production (explicit)" '{"baseUrl":"http://localhost:3000","environment":"production","seedableEnvMarker":"MATJAR_DISPOSABLE"}' "$L_PROD"
  refused "start_refuses_production (auto, non-local, empty marker)" '{"baseUrl":"https://app.example.sa","environment":"auto","seedableEnvMarker":""}' "$L_PROD"
  refused "start_refuses_production (bootstrap sentinel marker)" '{"baseUrl":"https://app.example.sa","environment":"auto","seedableEnvMarker":"QA_DISPOSABLE_ENV","gates":{"dataPolicy":"enforce"}}' "$L_PROD"
  refused "start_refuses_production (environment absent = auto)" '{"baseUrl":"https://app.example.sa","gates":{"dataPolicy":"enforce"}}' "$L_PROD"
  refused "a host that only contains 'localhost' is not local" '{"baseUrl":"https://localhost.example.sa","environment":"auto","seedableEnvMarker":""}' "$L_PROD"

  # ---- G1: the environment word is read in any letter case, and must be a known word ----
  refused "PRODUCTION in capitals is production" "{\"baseUrl\":\"$HOST\",\"environment\":\"PRODUCTION\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"enforce\"}}" "$L_PROD"
  refused "Production on localhost is production" '{"baseUrl":"http://localhost:3000","environment":"Production"}' "$L_PROD"
  refused "an unknown environment word is refused" '{"baseUrl":"http://localhost:3000","environment":"staging"}' "$L_ENV"
  refused "an unknown environment word is refused on a shared host too" "{\"baseUrl\":\"$HOST\",\"environment\":\"prod\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"enforce\"}}" "$L_ENV"
  for v in 5 true null '["production"]' '{"name":"auto"}' '""' '"auto "' '"production\n"'; do
    refused "an environment that is not one of the three words is refused: $v" "{\"baseUrl\":\"http://localhost:3000\",\"environment\":$v}" "$L_ENV"
  done
  allowed "a missing environment reads as auto" '{"baseUrl":"http://localhost:3000"}'
  allowed "AUTO in capitals is auto" '{"baseUrl":"http://localhost:3000","environment":"AUTO"}'
  P="$(mkproj "{\"baseUrl\":\"$HOST\",\"environment\":\"Disposable\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"enforce\"}}")"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E Disposable in mixed case is disposable; the baseline keeps the value as written" "$?|$(jv "$P/.qa/specs/checkout/auto/baseline.json" 'd["safety"]["environment"]')" "0|Disposable"

  # ---- start_allows_local_auto ----
  allowed "start_allows_local_auto (*.ddev.site)" '{"baseUrl":"http://shop.ddev.site","environment":"auto","seedableEnvMarker":""}'
  for u in "http://localhost:3000" "http://127.0.0.1:8000/app" "http://[::1]:5173" "http://[::1]" "https://shop.localhost" "http://matjar.test" "http://Matjar.LOCAL:8080" "http://user@shop.ddev.site/x" "HTTP://LOCALHOST:3000/?next=https://evil.example.sa" "localhost:3000"; do
    allowed "local host allowed: $u" "{\"baseUrl\":\"$u\",\"environment\":\"auto\"}"
  done

  # ---- M1: a host is local only when it is plainly one ----
  for u in 'http://evil.example.sa\\@localhost' 'http://evil.example.sa\\@localhost:3000/x' 'http://[::1]evil.example.sa' 'http://[::1].evil.example.sa:80' 'http://[::1' 'http://[::2]' 'http://localhost:3000@evil.example.sa' 'http://localhost@evil.example.sa/' 'http://localhost%00.evil.example.sa' 'http://local host' 'http://localhost:80a' 'http://localhost\\.evil.example.sa' 'http://user:p\\@ss@localhost' 'http://localhost.' 'http://' 'https:///localhost' 'http://متجر.test' 'http://shop_1.test' 'http://localhost\t'; do
    refused "not a local host: $u" "{\"baseUrl\":\"$u\",\"environment\":\"auto\"}" "$L_PROD"
  done
  # no baseUrl at all: production, unless the environment is disposable with a real marker
  for v in '' '"baseUrl":"",' '"baseUrl":"   ",' '"baseUrl":5,' '"baseUrl":null,'; do
    refused "no baseUrl [$v], auto" "{$v\"environment\":\"auto\"}" "$L_PROD"
    refused "no baseUrl [$v], auto with a marker and the data policy" "{$v\"environment\":\"auto\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"enforce\"}}" "$L_PROD"
    refused "no baseUrl [$v], disposable without a marker" "{$v\"environment\":\"disposable\",\"gates\":{\"dataPolicy\":\"enforce\"}}" "$L_PROD"
    refused "no baseUrl [$v], disposable with the bootstrap marker" "{$v\"environment\":\"disposable\",\"seedableEnvMarker\":\"QA_DISPOSABLE_ENV\",\"gates\":{\"dataPolicy\":\"enforce\"}}" "$L_PROD"
    refused "no baseUrl [$v], disposable with a marker, no data policy" "{$v\"environment\":\"disposable\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\"}" "$L_SHARED"
    allowed "no baseUrl [$v], disposable with a marker and the data policy" "{$v\"environment\":\"disposable\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"enforce\"}}"
  done
  # a marker made of blanks is no marker
  for v in '   ' '\t' ' QA_DISPOSABLE_ENV '; do
    refused "a blank or bootstrap marker [$v] is no marker" "{\"baseUrl\":\"$HOST\",\"environment\":\"auto\",\"seedableEnvMarker\":\"$v\",\"gates\":{\"dataPolicy\":\"enforce\"}}" "$L_PROD"
  done

  # ---- start_refuses_shared_without_data_policy ----
  refused "start_refuses_shared_without_data_policy" "{\"baseUrl\":\"$HOST\",\"environment\":\"auto\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\"}" "$L_SHARED"
  refused "shared with dataPolicy advise refused" "{\"baseUrl\":\"$HOST\",\"environment\":\"disposable\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"advise\"}}" "$L_SHARED"
  allowed "shared with dataPolicy enforce allowed" "$SHARED_OK"
  # the ship profile fills gates.dataPolicy when the project does not set it (profile.sh, ADR-0030)
  allowed "shared under the ship profile allowed (profile fills the gate)" "{\"baseUrl\":\"$HOST\",\"environment\":\"auto\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\"}" --profile ship
  refused "a set gates.dataPolicy wins over the ship profile" "{\"baseUrl\":\"$HOST\",\"environment\":\"auto\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\",\"gates\":{\"dataPolicy\":\"advise\"}}" "$L_SHARED" --profile ship
  allowed "local environment does not need the gate" '{"baseUrl":"http://shop.ddev.site","environment":"auto","gates":{"dataPolicy":"advise"}}'
  # known-defects registry rejected by the engine's validator (the command passes the flag)
  refused "start_refuses_invalid_known_defects" "$(cat "$FX/config-local.json")" "auto: .qa/known-defects.json is not valid" --known-defects-invalid

  # ---- G8: --max-hours between 0.1 and 72 ----
  P="$(mkproj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  for v in 0.09 0.0 0 00.05 72.01 72.5 73 100 7200 99999999999999999999 abc 1e1 -1 1. .5 ""; do
    check "$E start --max-hours [$v] is a usage error" "$(first auto start checkout --project "$P" --max-hours "$v")" "2|$L_HOURS"
  done
  check "$E a refused --max-hours writes nothing" "$([ -e "$P/.qa/specs" ] && echo wrote || echo clean)" "clean"
  while IFS='|' read -r v t; do
    Q="$(mkproj)"
    auto start checkout --project "$Q" --max-hours "$v" >/dev/null 2>&1
    check "$E start --max-hours $v is accepted" "$?|$(jv "$Q/.qa/specs/checkout/auto/journey.json" 'd["deadline"]')" "0|$t"
  done <<'EOT'
0.1|2026-11-27T08:06:00Z
0.10|2026-11-27T08:06:00Z
00.5|2026-11-27T08:30:00Z
72|2026-11-30T08:00:00Z
72.0|2026-11-30T08:00:00Z
071.5|2026-11-30T07:30:00Z
EOT
  P="$(tpl stopped)"; before="$(snapshot "$P")"
  for v in 0.05 72.1 73 soon 0; do
    check "$E resume --max-hours [$v] is a usage error" "$(first auto resume checkout --project "$P" --max-hours "$v")" "2|$L_HOURS"
  done
  check "$E a refused resume --max-hours writes nothing" "$(snapshot "$P")" "$before"
  auto resume checkout --project "$P" --max-hours 72 >/dev/null 2>&1
  check "$E resume --max-hours 72 is accepted" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["deadline"]')" "0|2026-11-30T08:00:00Z"
  P="$(tpl stopped)"
  auto resume checkout --project "$P" --max-hours 0.1 >/dev/null 2>&1
  check "$E resume --max-hours 0.1 is accepted" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["deadline"]')" "0|2026-11-27T08:06:00Z"

  # ---- G3: resume asks the same questions as start ----
  while IFS='|' read -r t v u; do
    P="$(tpl stopped)"; printf '%s' "$v" > "$P/.qa/config.json"; before="$(snapshot "$P")"
    out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
    check "$E resume refused: $t" "$rc|$out|$([ "$(snapshot "$P")" = "$before" ] && echo same || echo changed)" "1|$u|same"
  done <<EOT
the config now says production|{"baseUrl":"http://localhost:3000","environment":"production"}|$L_PROD
the config now says PRODUCTION|{"baseUrl":"http://localhost:3000","environment":"PRODUCTION"}|$L_PROD
the config now points at a real host|{"baseUrl":"https://app.example.sa","environment":"auto","seedableEnvMarker":""}|$L_PROD
the config has lost its baseUrl|{"environment":"auto"}|$L_PROD
the environment is now an unknown word|{"baseUrl":"http://localhost:3000","environment":"staging"}|$L_ENV
the config is now shared without the data policy|{"baseUrl":"$HOST","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE"}|$L_SHARED
the data policy is now only advise|{"baseUrl":"$HOST","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE","gates":{"dataPolicy":"advise"}}|$L_SHARED
the config no longer parses|{"baseUrl":|auto: .qa/config.json is not valid JSON
EOT
  P="$(tpl stopped)"; rm "$P/.qa/config.json"; before="$(snapshot "$P")"
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E resume refused: the config is gone" "$rc|$out|$([ "$(snapshot "$P")" = "$before" ] && echo same || echo changed)" "1|auto: no .qa/config.json; set the project up first|same"
  P="$(tpl stopped)"; before="$(snapshot "$P")"
  out="$(auto resume checkout --project "$P" --known-defects-invalid 2>&1)"; rc=$?
  check "$E resume refused: --known-defects-invalid" "$rc|$out|$([ "$(snapshot "$P")" = "$before" ] && echo same || echo changed)" "1|auto: .qa/known-defects.json is not valid|same"
  P="$(tpl stopped)"; mkdir -p "$P/.qa/specs/checkout"; printf '{"gates":{"coverage":"advise"}}\n' > "$P/.qa/specs/checkout/run-config.json"; printf '%s' "$SHARED_OK" > "$P/.qa/config.json"
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E resume refused: the run-config now drops the gate" "$rc|$out" "1|$L_SHARED"
  P="$(tpl stopped)"; printf '%s' "$SHARED_OK" > "$P/.qa/config.json"
  auto resume checkout --project "$P" >/dev/null 2>&1
  check "$E resume allowed on a shared host with the data policy" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "0|open"
  # the data policy is judged under the profile the journey was launched with
  P="$(mkproj "{\"baseUrl\":\"$HOST\",\"environment\":\"auto\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\"}")"
  auto start checkout --project "$P" --profile ship >/dev/null 2>&1
  auto stop checkout --project "$P" --reason time-limit --detail "paused" >/dev/null 2>&1
  auto resume checkout --project "$P" >/dev/null 2>&1
  check "$E resume of a ship journey keeps the gate the profile fills" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "0|open"
  # nothing to resume is still said first
  P="$(mkproj '{"baseUrl":"http://localhost:3000","environment":"production"}')"
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E resume without a journey says so before anything else" "$rc|$out" "1|auto: nothing to resume"

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
  # refusals: the same line and exit code under both engines
  RJ="$(E=jq; tpl stopped)"; RP="$(E=python3; tpl stopped)"
  while IFS='|' read -r c v; do
    printf '%s' "$c" > "$RJ/.qa/config.json"; printf '%s' "$c" > "$RP/.qa/config.json"
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$RJ" 2>&1; echo "rc=$?")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$RP" 2>&1; echo "rc=$?")"
    check "cross-engine refusal identical: $v on $c" "$oj" "$op"
    want="rc=1"; case "$v" in *max-hours*|*zzz*|*.hidden*) want="rc=2" ;; esac
    check "cross-engine refusal is a refusal: $v on $c" "$(printf '%s' "$oj" | sed -n '$p')" "$want"
  done <<EOT
{"baseUrl":"http://localhost:3000","environment":"PRODUCTION"}|resume checkout
{"baseUrl":"http://localhost:3000","environment":"staging"}|resume checkout
{"baseUrl":"http://localhost:3000","environment":7}|start returns
{"environment":"disposable"}|start returns
{"baseUrl":"http://evil.example.sa\\\\@localhost"}|start returns
{"baseUrl":"$HOST","environment":"auto","seedableEnvMarker":"  "}|resume checkout
{"baseUrl":"$HOST","environment":"auto","seedableEnvMarker":"MATJAR_DISPOSABLE"}|resume checkout
{"baseUrl":"http://localhost:3000"}|resume checkout --known-defects-invalid
{"baseUrl":"http://localhost:3000"}|resume checkout --max-hours 72.5
{"baseUrl":"http://localhost:3000"}|start returns --max-hours 0.01
{"baseUrl":"http://localhost:3000"}|start .hidden
{"baseUrl":"http://localhost:3000"}|status --zzz checkout
{"baseUrl":|resume checkout
EOT
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

echo "qa-auto-gate: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
