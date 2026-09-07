#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/auto-seed.sh (decide) — the pure write gate.
# Mirrors the engine's scripted write gate: allowApiWrites + non-empty seedableEnvMarker
# (a config STRING, not an env-var name) + environment != production.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto-seed.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: auto-seed: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
seedval(){ python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])'; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
  # writes on + non-empty marker + environment auto (not production) -> seed true
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":".qa/DISPOSABLE","environment":"auto"}' > "$T/c.json"
  check "$E writes+marker+auto -> seed true" "$(QA_ENGINE=$E bash "$SH" decide "$T/c.json" | seedval)" "True"
  # explicit disposable -> seed true (uses a real custom marker, not the never-opted-in bootstrap sentinel)
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"MY_DISPOSABLE","environment":"disposable"}' > "$T/cd.json"
  check "$E disposable -> seed true" "$(QA_ENGINE=$E bash "$SH" decide "$T/cd.json" | seedval)" "True"
  # audit-2 W1-5: the verbatim bootstrap sentinel is never a deliberate opt-in -> seed false
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"QA_DISPOSABLE_ENV","environment":"auto"}' > "$T/csent.json"
  check "$E bootstrap sentinel marker -> seed false" "$(QA_ENGINE=$E bash "$SH" decide "$T/csent.json" | seedval)" "False"
  # sibling: a real custom marker still opts in (existing seed:true behavior)
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"MY_DISPOSABLE","environment":"auto"}' > "$T/ccust.json"
  check "$E custom marker -> seed true" "$(QA_ENGINE=$E bash "$SH" decide "$T/ccust.json" | seedval)" "True"
  # empty marker -> seed false
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"","environment":"auto"}' > "$T/cm.json"
  check "$E empty marker -> seed false" "$(QA_ENGINE=$E bash "$SH" decide "$T/cm.json" | seedval)" "False"
  # allowApiWrites false -> seed false
  printf '%s' '{"allowApiWrites":false,"seedableEnvMarker":".qa/DISPOSABLE","environment":"disposable"}' > "$T/c2.json"
  check "$E writes false -> seed false" "$(QA_ENGINE=$E bash "$SH" decide "$T/c2.json" | seedval)" "False"
  # environment production -> seed false even with writes+marker
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":".qa/DISPOSABLE","environment":"production"}' > "$T/cp.json"
  check "$E production -> seed false" "$(QA_ENGINE=$E bash "$SH" decide "$T/cp.json" | seedval)" "False"
  # missing environment defaults to non-production -> seed true
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":".qa/DISPOSABLE"}' > "$T/cno.json"
  check "$E missing environment -> seed true" "$(QA_ENGINE=$E bash "$SH" decide "$T/cno.json" | seedval)" "True"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"","environment":"auto"}' > "$X/c.json"
  vj="$(QA_ENGINE=jq bash "$SH" decide "$X/c.json")"; vp="$(QA_ENGINE=python3 bash "$SH" decide "$X/c.json")"
  check "cross-engine decision identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
fi
echo "auto-seed: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
