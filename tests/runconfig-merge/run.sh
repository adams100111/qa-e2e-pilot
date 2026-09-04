#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/runconfig-merge.sh — computes the effective
# run config by shallow-merging a spec's run-config deltas over .qa/config.json
# defaults (delta wins), for one run. Does NOT mutate config.json.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/runconfig-merge.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

CONFIG='{"baseUrl":"http://localhost","maxParallel":1,"criteriaBudget":50,"viewport":"desktop","allowApiWrites":false}'

run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' "$CONFIG" > "$T/config.json"

  # a delta overrides its key; untouched keys keep defaults
  printf '%s' '{"maxParallel":4,"viewport":"mobile"}' > "$T/d1.json"
  local out; out="$(QA_ENGINE=$E bash "$SH" "$T/config.json" "$T/d1.json")"
  check "$E delta overrides maxParallel" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["maxParallel"])')" "4"
  check "$E delta overrides viewport" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["viewport"])')" "mobile"
  check "$E untouched key kept" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["criteriaBudget"])')" "50"
  check "$E base key kept" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["baseUrl"])')" "http://localhost"

  # empty delta -> effective == config (same keys/values)
  printf '%s' '{}' > "$T/d0.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/config.json" "$T/d0.json")"
  check "$E empty delta keeps maxParallel" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["maxParallel"])')" "1"
  check "$E empty delta same key count" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "5"

  # a delta may add a new key
  printf '%s' '{"drivers":["chromium"]}' > "$T/d2.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/config.json" "$T/d2.json")"
  check "$E delta adds drivers" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["drivers"][0])')" "chromium"

  # malformed delta (not an object) -> die
  printf '%s' '[1,2]' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" "$T/config.json" "$T/bad.json" >/dev/null 2>&1
  check "$E malformed delta dies" "$?" "1"
  rm -rf "$T"
}

command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3

# cross-engine byte-identity
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' "$CONFIG" > "$X/config.json"
  printf '%s' '{"maxParallel":8,"criteriaBudget":10,"newKey":"z"}' > "$X/d.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/config.json" "$X/d.json")"
  vp="$(QA_ENGINE=python3 bash "$SH" "$X/config.json" "$X/d.json")"
  check "cross-engine effective config identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  rm -rf "$X"
fi

echo "runconfig-merge: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
