#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/auto-seed.sh (decide) — the pure write gate.
# Mirrors the engine's scripted write gate: allowApiWrites + non-empty seedableEnvMarker
# (a config STRING, not an env-var name) + environment != production.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto-seed.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
seedval(){ python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])'; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  # writes on + non-empty marker + environment auto (not production) -> seed true
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":".qa/DISPOSABLE","environment":"auto"}' > "$T/c.json"
  check "$E writes+marker+auto -> seed true" "$(QA_ENGINE=$E bash "$SH" decide "$T/c.json" | seedval)" "True"
  # explicit disposable -> seed true
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"QA_DISPOSABLE_ENV","environment":"disposable"}' > "$T/cd.json"
  check "$E disposable -> seed true" "$(QA_ENGINE=$E bash "$SH" decide "$T/cd.json" | seedval)" "True"
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
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"","environment":"auto"}' > "$X/c.json"
  vj="$(QA_ENGINE=jq bash "$SH" decide "$X/c.json")"; vp="$(QA_ENGINE=python3 bash "$SH" decide "$X/c.json")"
  check "cross-engine decision identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"; rm -rf "$X"
fi
echo "auto-seed: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
