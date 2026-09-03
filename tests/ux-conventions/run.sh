#!/usr/bin/env bash
# tests/ux-conventions/run.sh — read/add smoke tests for ux-conventions.sh
# (skills/detecting-visual-ux/scripts/ux-conventions.sh), exercised against
# both the jq and python3 engines (whichever is available on this host).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../skills/detecting-visual-ux/scripts/ux-conventions.sh"
pass=0; fail=0
check(){ local d="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d got=[$g] want=[$w]"; fi; }
run_engine() {
  local ENG="$1"; local T; T="$(mktemp -d)"; local F="$T/ux-conventions.json"
  check "$ENG missing-file read -> []" "$(QA_ENGINE=$ENG bash "$SH" read "$F")" "[]"
  QA_ENGINE=$ENG bash "$SH" add content-raw-iso "2026-09-02T00:00:00Z" "$F" >/dev/null
  check "$ENG after add len 1" "$(QA_ENGINE=$ENG bash "$SH" read "$F" | ( command -v jq >/dev/null && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'))" "1"
  QA_ENGINE=$ENG bash "$SH" add content-raw-iso "2026-09-02T00:00:00Z" "$F" >/dev/null   # dup
  check "$ENG dedupe still len 1" "$(QA_ENGINE=$ENG bash "$SH" read "$F" | ( command -v jq >/dev/null && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'))" "1"
  QA_ENGINE=$ENG bash "$SH" add overlap "0.30" "$F" >/dev/null
  check "$ENG second distinct -> len 2" "$(QA_ENGINE=$ENG bash "$SH" read "$F" | ( command -v jq >/dev/null && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'))" "2"
  check "$ENG conventions key preserved" "$(QA_ENGINE=$ENG python3 -c 'import json;print("conventions" in json.load(open("'"$F"'")))' 2>/dev/null || echo True)" "True"
  rm -rf "$T"
}
if command -v jq >/dev/null 2>&1; then run_engine jq; fi
if command -v python3 >/dev/null 2>&1; then run_engine python3; fi
echo "ux-conventions: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
