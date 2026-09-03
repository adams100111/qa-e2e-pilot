#!/usr/bin/env bash
# tests/critic-coverage/run.sh — log/read smoke tests for critic-coverage.sh
# (skills/detecting-visual-ux/scripts/critic-coverage.sh), exercised against
# both the jq and python3 engines (whichever is available on this host).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../skills/detecting-visual-ux/scripts/critic-coverage.sh"
pass=0; fail=0
check(){ local d="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d got=[$g] want=[$w]"; fi; }
check_nonzero(){ local d="$1" rc="$2"; if [ "$rc" -ne 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d expected non-zero exit, got 0"; fi; }

jlen() {
  # reads JSON array from stdin, prints its length
  command -v jq >/dev/null 2>&1 && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'
}

run_engine() {
  local ENG="$1"; local T; T="$(mktemp -d)"; local RUN="run-1"

  # missing-file read -> []
  check "$ENG missing-file read -> []" "$(QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" read "$RUN")" "[]"

  # log ran with reason -> records length 1
  QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" log "$RUN" surfaceA ran "interaction-heavy" >/dev/null
  check "$ENG after ran log -> len 1" "$(QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" read "$RUN" | jlen)" "1"

  local rec1
  rec1="$(QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" read "$RUN" | ( command -v jq >/dev/null 2>&1 && jq -c '.[0]' || python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)[0], separators=(",", ":")))'))"
  check "$ENG rec1 decision" "$(echo "$rec1" | ( command -v jq >/dev/null 2>&1 && jq -r '.decision' || python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["decision"])'))" "ran"
  check "$ENG rec1 surface" "$(echo "$rec1" | ( command -v jq >/dev/null 2>&1 && jq -r '.surface' || python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["surface"])'))" "surfaceA"
  check "$ENG rec1 reason" "$(echo "$rec1" | ( command -v jq >/dev/null 2>&1 && jq -r '.reason' || python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["reason"])'))" "interaction-heavy"

  # log skipped -> records length 2
  QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" log "$RUN" surfaceB skipped "budget" >/dev/null
  check "$ENG after skipped log -> len 2" "$(QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" read "$RUN" | jlen)" "2"

  # log with invalid decision -> non-zero exit, records unchanged
  QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" log "$RUN" surfaceC bogus "x" >/dev/null 2>&1
  check_nonzero "$ENG invalid decision -> non-zero exit" "$?"
  check "$ENG invalid decision -> records unchanged (len 2)" "$(QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" read "$RUN" | jlen)" "2"

  # log with path-separator run-id -> non-zero exit (validate_token)
  QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" log "bad/run-id" surfaceD ran "x" >/dev/null 2>&1
  check_nonzero "$ENG bad run-id -> non-zero exit" "$?"

  # valid JSON throughout
  check "$ENG file is valid JSON" "$(QA_ENGINE=$ENG QA_BASE="$T" bash "$SH" read "$RUN" | ( command -v jq >/dev/null 2>&1 && jq -e '.' >/dev/null 2>&1 && echo valid || echo invalid ))" "valid"

  rm -rf "$T"
}

if command -v jq >/dev/null 2>&1; then run_engine jq; fi
if command -v python3 >/dev/null 2>&1; then run_engine python3; fi
echo "critic-coverage: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
