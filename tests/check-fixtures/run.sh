#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/check-fixtures.sh — computed criteria
# (kind ∈ {computed-logic, business-rule}) must carry a well-formed absolute pinned expect.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/check-fixtures.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
OKROW='{"id":"C1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"actionInput":{"q":3},"expect":{"path":"total","value":"0.003","tolerance":0,"oracleSource":"human"}}}'
DISPLAY='{"id":"C2","surface":"/x","kind":"empty-state","tags":["read-only"],"action":"a"}'
MISSING='{"id":"C3","surface":"/x","kind":"computed-logic","tags":[],"action":"a"}'
BIZRULE='{"id":"C4","surface":"/x","kind":"business-rule","tags":[],"action":"a"}'
ILLFORMED='{"id":"C5","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"total","value":"1","tolerance":0,"oracleSource":"bogus"}}}'
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '[%s,%s]' "$OKROW" "$DISPLAY" > "$T/ok.json"
  QA_ENGINE=$E bash "$SH" "$T/ok.json" >/dev/null; check "$E computed pinned + display exempt -> ok" "$?" "0"
  printf '[%s]' "$MISSING" > "$T/m.json"
  local out; out="$(QA_ENGINE=$E bash "$SH" "$T/m.json")"; local rc=$?
  check "$E computed-logic missing expect -> exit 1" "$rc" "1"
  check "$E missing lists C3" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(any(m["id"]=="C3" for m in json.load(sys.stdin)["missing"]))')" "True"
  printf '[%s]' "$BIZRULE" > "$T/br.json"
  QA_ENGINE=$E bash "$SH" "$T/br.json" >/dev/null 2>&1; check "$E business-rule missing expect -> exit 1 (kind trigger)" "$?" "1"
  printf '[%s]' "$ILLFORMED" > "$T/if.json"
  QA_ENGINE=$E bash "$SH" "$T/if.json" >/dev/null 2>&1; check "$E bad oracleSource -> exit 1" "$?" "1"
  # sources counts human pins
  printf '[%s]' "$OKROW" > "$T/src.json"
  check "$E sources.human counted" "$(QA_ENGINE=$E bash "$SH" "$T/src.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sources"]["human"])')" "1"
  printf '%s' '{"nope":1}' > "$T/na.json"
  QA_ENGINE=$E bash "$SH" "$T/na.json" >/dev/null 2>&1; check "$E non-array dies" "$?" "1"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '[%s,%s]' "$MISSING" "$OKROW" > "$X/c.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/c.json"; true)"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/c.json"; true)"
  check "cross-engine report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"; rm -rf "$X"
fi
echo "check-fixtures: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
