#!/usr/bin/env bash
# Dual-engine tests for the settings the gate of qa-kit/scripts/auto.sh judges: `start` and
# `resume` look at the MERGED settings (the project config with the spec's run-config on top, as
# the engine resolves a run's effective config), and `start` refuses a number the two engines
# could not compare alike. (The rest of the gate is tested in tests/qa-auto-gate/; the two are
# separate so each stays well inside the CI time cap.)
# Every case runs under QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines'
# files and output byte for byte. No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-settings: python3 is needed to read results - suite cannot run" >&2; exit 1; }
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
  local P J out rc before v c k

  # ---- H2: the gate judges the MERGED settings: the config with the spec's run-config on top ----
  # rcstart <label> <config json> <run-config text> <refusal line, or empty for allowed> [start flags…]
  rcstart() {
    local label="$1" P out rc; P="$(mkproj "$2")"; local want="$4"
    mkdir -p "$P/.qa/specs/checkout"; printf '%s' "$3" > "$P/.qa/specs/checkout/run-config.json"; shift 4
    out="$(auto start checkout --project "$P" "$@" 2>&1)"; rc=$?
    if [ -n "$want" ]; then check "$E $label" "$rc|$out|$([ -e "$P/.qa/specs/checkout/auto" ] && echo wrote || echo clean)" "1|$want|clean"
    else check "$E $label" "$rc|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "0|open"; fi
  }
  LOCAL='{"baseUrl":"http://localhost:3000","environment":"auto"}'
  L_RC="auto: .qa/specs/checkout/run-config.json is not valid JSON"
  L_RCOBJ="auto: .qa/specs/checkout/run-config.json is not a JSON object"
  rcstart "a run-config that says production is production" "$LOCAL" '{"environment":"production"}' "$L_PROD"
  rcstart "a run-config that says Production is production" "$LOCAL" '{"environment":"Production"}' "$L_PROD"
  rcstart "a run-config address on a shared host makes a local project production" "$LOCAL" '{"baseUrl":"https://app.example.sa"}' "$L_PROD"
  rcstart "a run-config address of null leaves the project without an address" "$LOCAL" '{"baseUrl":null}' "$L_PROD"
  rcstart "a run-config that empties the marker of a shared project" "$SHARED_OK" '{"seedableEnvMarker":""}' "$L_PROD"
  rcstart "a run-config environment that is not one of the three words" "$LOCAL" '{"environment":"staging"}' "$L_ENV"
  rcstart "a run-config environment of null is not a word" "$LOCAL" '{"environment":null}' "$L_ENV"
  rcstart "a run-config that replaces gates without the data policy" "$SHARED_OK" '{"gates":{"coverage":"advise"}}' "$L_SHARED"
  rcstart "a run-config gates of null drops the data policy" "$SHARED_OK" '{"gates":null}' "$L_SHARED"
  rcstart "a run-config data policy other than enforce" "$SHARED_OK" '{"gates":{"dataPolicy":"advise"}}' "$L_SHARED"
  rcstart "a run-config gates that is not an object" "$SHARED_OK" '{"gates":"enforce"}' "$L_SHARED" --profile ship
  rcstart "gates of null under ship: the profile fills the data policy" "$SHARED_OK" '{"gates":null}' "" --profile ship
  rcstart "a run-config may add the data policy to a shared project" "{\"baseUrl\":\"$HOST\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\"}" '{"gates":{"dataPolicy":"enforce"}}' ""
  rcstart "a run-config profile of ship fills the data policy" "{\"baseUrl\":\"$HOST\",\"seedableEnvMarker\":\"MATJAR_DISPOSABLE\"}" '{"profile":"ship"}' ""
  rcstart "a run-config without safety keys changes nothing" "$LOCAL" '{"criteriaBudget":40}' ""
  rcstart "the merged settings are what is judged, also when the run-config is the stricter one" '{"baseUrl":"https://app.example.sa"}' '{"baseUrl":"http://shop.test"}' ""
  rcstart "a run-config that does not parse" "$LOCAL" '{"environment":' "$L_RC"
  rcstart "an empty run-config" "$LOCAL" '' "$L_RC"
  rcstart "a run-config holding two documents" "$LOCAL" '{} {"environment":"production"}' "$L_RC"
  rcstart "a run-config that is a list" "$LOCAL" '["environment","production"]' "$L_RCOBJ"
  rcstart "a run-config that is a text" "$LOCAL" '"production"' "$L_RCOBJ"
  rcstart "a run-config with a byte order mark is read" "$LOCAL" "$(printf '\357\273\277{"environment":"production"}')" "$L_PROD"
  # resume asks the same of the merged settings
  while IFS='|' read -r v c; do
    P="$(tpl stopped)"; J="$P/.qa/specs/checkout/auto/journey.json"
    printf '%s' "$v" > "$P/.qa/specs/checkout/run-config.json"; before="$(snapshot "$P")"
    out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
    check "$E resume refused on the merged settings [$v]" "$rc|$out" "1|$c"
    check "$E the refused resume wrote nothing [$v]" "$(snapshot "$P")" "$before"
  done <<EOT
{"environment":"production"}|$L_PROD
{"baseUrl":"https://app.example.sa"}|$L_PROD
{"environment":"prod"}|$L_ENV
{"baseUrl":"$HOST","seedableEnvMarker":"MATJAR_DISPOSABLE"}|$L_SHARED
["x"]|$L_RCOBJ
{"baseUrl":|$L_RC
EOT
  P="$(tpl stopped)"; printf '{"criteriaBudget":12}' > "$P/.qa/specs/checkout/run-config.json"
  auto resume checkout --project "$P" >/dev/null 2>&1
  check "$E resume with a run-config that has no safety key" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "0|open"

  # ---- m6: a number the two engines cannot compare alike is refused at the start ----
  L_NUM="auto: a number in the safety settings cannot be compared; write a plain number"
  for v in 1e16 12345678901234567890 9007199254740993000 1e-7 1e400; do
    refused "a safety setting of $v is refused" "{\"baseUrl\":\"http://localhost:3000\",\"humanInteraction\":{\"maxOptOutRate\":$v}}" "$L_NUM"
    rcstart "a run-config safety value of $v is refused" "$LOCAL" "{\"gates\":{\"limit\":$v}}" "$L_NUM"
  done
  for v in 0.2000000000000000001 2E-1 0.20 1000000000000000 0.0001 -3; do
    P="$(mkproj "{\"baseUrl\":\"http://localhost:3000\",\"humanInteraction\":{\"maxOptOutRate\":$v},\"criteriaBudget\":1e30}")"
    auto start checkout --project "$P" >/dev/null 2>&1
    check "$E a safety setting of $v is a plain number" "$?|$(jv "$P/.qa/specs/checkout/auto/journey.json" 'd["state"]')" "0|open"
  done
  check "$E 0.2 with more digits than a number holds is recorded as 0.2" "$(P="$(mkproj '{"baseUrl":"http://localhost:3000","humanInteraction":{"maxOptOutRate":0.2000000000000000001}}')"; auto start checkout --project "$P" >/dev/null 2>&1; grep -c '"humanInteraction.maxOptOutRate": 0.2$' "$P/.qa/specs/checkout/auto/baseline.json")" "1"
  P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"
  printf '[{"id":"C-001","fixture":{"expect":{"value":12345678901234567890,"oracleSource":"human"}}}]\n' > "$P/.qa/specs/checkout/checklist.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E a person-confirmed expected value that holds such a number is refused" "$rc|$out|$([ -e "$P/.qa/specs/checkout/auto" ] && echo wrote || echo clean)" "1|auto: a number in a person-confirmed expected value of .qa/specs/checkout/checklist.json cannot be compared; write it as text|clean"
  printf '[{"id":"C-001","fixture":{"expect":{"value":12345678901234567890,"oracleSource":"llm-suggested"}},"weight":1e16}]\n' > "$P/.qa/specs/checkout/checklist.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E such a number in a row nobody confirmed is not looked at" "$?" "0"
  P="$(mkproj)"; mkdir -p "$P/.qa/specs/checkout"
  printf '[{"surfaceId":"page:Orders/Refund","personaId":"*","weight":1e16}]\n' > "$P/.qa/specs/checkout/coverage-exclusions.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E an exclusion that holds such a number is refused" "$rc|$out" "1|auto: a number in .qa/specs/checkout/coverage-exclusions.json cannot be compared; write it as text"
}

command -v jq >/dev/null 2>&1 && run_engine jq
run_engine python3

# ---- both engines: the same answers ----
if command -v jq >/dev/null 2>&1; then
  # H2: the merged settings are judged the same way by both engines
  while IFS='|' read -r c v; do
    for k in start resume; do
      if [ "$k" = start ]; then XJ="$(E=jq; mkproj)"; XP="$(E=python3; mkproj)"; mkdir -p "$XJ/.qa/specs/checkout" "$XP/.qa/specs/checkout"
      else XJ="$(E=jq; tpl stopped)"; XP="$(E=python3; tpl stopped)"; fi
      printf '%s' "$c" > "$XJ/.qa/specs/checkout/run-config.json"; printf '%s' "$c" > "$XP/.qa/specs/checkout/run-config.json"
      oj="$(E=jq; auto $k checkout --project "$XJ" 2>&1; echo "rc=$?")"; op="$(E=python3; auto $k checkout --project "$XP" 2>&1; echo "rc=$?")"
      check "cross-engine $k identical on the run-config $c" "$oj" "$op"
      check "cross-engine $k on the run-config $c is $v" "$(printf '%s' "$oj" | sed -n '$p')" "$v"
      check "cross-engine files identical after $k on the run-config $c" "$(cat "$XJ"/.qa/specs/checkout/auto/*.json 2>/dev/null | cksum)" "$(cat "$XP"/.qa/specs/checkout/auto/*.json 2>/dev/null | cksum)"
    done
  done <<'EOT'
{"environment":"production"}|rc=1
{"baseUrl":"https://app.example.sa"}|rc=1
{"humanInteraction":null,"gates":{"limit":1E+2,"weight":1.0}}|rc=0
{"humanInteraction":{"maxOptOutRate":0.2000000000000000001}}|rc=0
["production"]|rc=1
EOT
fi

echo "qa-auto-settings: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
