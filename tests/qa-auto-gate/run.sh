#!/usr/bin/env bash
# Dual-engine tests for the gatekeeper of qa-kit/scripts/auto.sh: what `start` and `resume` refuse
# about the environment (production, a host that is not plainly local, a shared environment
# without the data policy), the bounds of `--max-hours`, and `resume` asking the same questions as
# `start`. (The merged settings are tested in tests/qa-auto-settings/, the lock and the writes in
# tests/qa-auto-lock/; the suites are separate so each stays well inside the CI time cap.)
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
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" QA_AUTO_VERIFY_PLAN_CMD="${VP-true}" bash "$SH" "$@"; }
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


}

command -v jq >/dev/null 2>&1 && run_engine jq
run_engine python3

# ---- both engines: the same refusals ----
if command -v jq >/dev/null 2>&1; then
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
fi

echo "qa-auto-gate: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
