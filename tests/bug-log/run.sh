#!/usr/bin/env bash
# Dual-engine tests for skills/checkpointing-qa-memory/scripts/bug-log.sh — the bug-log writer:
# add (alias mapping, required fields, severity, duplicate ids), normalize (old key styles,
# original kept once, nothing invented) and validate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../skills/checkpointing-qa-memory/scripts/bug-log.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: bug-log: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
q(){ printf '%s' "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(eval(sys.argv[1]),sort_keys=True,separators=(",",":"),ensure_ascii=False))' "$2"; }

# A camelCase entry as runs before the writer produced them (v3 hackathons run).
LEGACY='{"id":"v3-bug-01","severity":"medium","criterionId":"HLC-C02","persona":"anonymous","title":"الأوقات تظهر بتوقيت UTC","suspectedLayer":"FE/route","observed":"12:30 PM","expected":"3:30 PM","status":"open","observedAt":"2026-11-09T13:40:00Z"}'
CANON='{"bug_id":"B-2","criterion_id":"C-2","title":"Total off by one","severity":"high","suspected_layer":"service","expected":"5","actual":"4","steps":["Open the cart"]}'

run_engine() {
  local E="$1" T out rc; T="$(mktemp -d)"; TMPDIRS+=("$T")
  mkdir -p "$T/r1"
  out="$(printf '%s' "$LEGACY" | QA_ENGINE=$E bash "$SH" add "$T/r1" -)"; rc=$?
  check "$E add_legacy exit" "$rc" "0"
  check "$E add_legacy out" "$(q "$out" 'd')" '{"added":"v3-bug-01"}'
  check "$E add_legacy canonical keys" "$(q "$(cat "$T/r1/bug-log.json")" '[sorted(d["entries"][0]),d["run_id"]]')" '[["actual","bug_id","criterion_id","expected","logged_at","persona","severity","status","suspected_layer","title"],"r1"]'
  check "$E add keeps utf-8" "$(q "$(cat "$T/r1/bug-log.json")" 'd["entries"][0]["title"]')" '"الأوقات تظهر بتوقيت UTC"'
  printf '%s' "$CANON" > "$T/e.json"
  QA_ENGINE=$E bash "$SH" add "$T/r1" "$T/e.json" >/dev/null; check "$E add_second exit" "$?" "0"
  check "$E add_second appended" "$(q "$(cat "$T/r1/bug-log.json")" '[e["bug_id"] for e in d["entries"]]')" '["v3-bug-01","B-2"]'
  QA_ENGINE=$E bash "$SH" add "$T/r1" "$T/e.json" >/dev/null 2>"$T/err"; check "$E add_duplicate exit" "$?" "1"
  check "$E add_duplicate reason" "$(grep -c 'already exists: B-2' "$T/err")" "1"
  printf '%s' '{"bug_id":"B-3","criterion_id":"C-3","title":"x","severity":"blocker","suspected_layer":"DB","expected":"a","actual":"b"}' | QA_ENGINE=$E bash "$SH" add "$T/r1" - >/dev/null 2>&1
  check "$E add_bad_severity exit" "$?" "1"
  printf '%s' '{"bug_id":"B-4","criterion_id":"C-4","severity":"low","suspected_layer":"DB","expected":"a"}' | QA_ENGINE=$E bash "$SH" add "$T/r1" - >/dev/null 2>"$T/err"
  check "$E add_missing exit" "$?" "1"
  check "$E add_missing names fields" "$(grep -c 'missing title, actual' "$T/err")" "1"
  check "$E add refused writes nothing" "$(q "$(cat "$T/r1/bug-log.json")" 'len(d["entries"])')" "2"
  out="$(QA_ENGINE=$E bash "$SH" validate "$T/r1")"; rc=$?
  check "$E validate_written ok" "$rc:$(q "$out" 'd')" '0:{"errors":[],"ok":true}'

  # normalize an old log in place: aliases mapped, original kept once, gaps listed not filled.
  mkdir -p "$T/r2"
  printf '{"run_id":"r2","entries":[%s,{"id":"v3-bug-02","criterionId":"C-9","title":"t","severity":"low","layer":"DB","observed":"o"}]}' "$LEGACY" > "$T/r2/bug-log.json"
  out="$(QA_ENGINE=$E bash "$SH" validate "$T/r2")"; rc=$?
  check "$E validate_legacy fails" "$rc" "1"
  out="$(QA_ENGINE=$E bash "$SH" normalize "$T/r2")"; rc=$?
  check "$E normalize exit" "$rc" "0"
  check "$E normalize summary" "$(q "$out" 'd')" '{"entries":2,"invalid":[{"bugId":"v3-bug-02","missing":["expected"]}],"renamed":{"criterionId":2,"id":2,"layer":1,"observed":2,"observedAt":1,"suspectedLayer":1}}'
  check "$E normalize kept original" "$(q "$(cat "$T/r2/bug-log.pre-normalize.json")" 'd["entries"][0]["criterionId"]')" '"HLC-C02"'
  check "$E normalize rewrote" "$(q "$(cat "$T/r2/bug-log.json")" '[[e.get("criterion_id"),e.get("suspected_layer"),e.get("actual")] for e in d["entries"]]')" '[["HLC-C02","FE/route","12:30 PM"],["C-9","DB","o"]]'
  out="$(QA_ENGINE=$E bash "$SH" validate "$T/r2")"
  check "$E validate_after_normalize" "$(q "$out" 'd')" '{"errors":[{"bugId":"v3-bug-02","reason":"missing expected"}],"ok":false}'
  echo '{"entries":[]}' > "$T/r2/bug-log.pre-normalize.json.keep"; cp "$T/r2/bug-log.pre-normalize.json" "$T/r2/keep.json"
  QA_ENGINE=$E bash "$SH" normalize "$T/r2" >/dev/null
  check "$E normalize second run keeps first original" "$(cmp -s "$T/r2/bug-log.pre-normalize.json" "$T/r2/keep.json" && echo same)" "same"
  mkdir -p "$T/r3"; printf '[%s]' "$CANON" > "$T/r3/bug-log.json"
  QA_ENGINE=$E bash "$SH" normalize "$T/r3" >/dev/null
  check "$E normalize bare array wraps" "$(q "$(cat "$T/r3/bug-log.json")" '[sorted(d),d["run_id"]]')" '[["entries","run_id"],null]'
  QA_ENGINE=$E bash "$SH" validate "$T/nope" >/dev/null 2>&1; check "$E missing run dir exit" "$?" "1"
}

if command -v jq >/dev/null 2>&1; then run_engine jq; else echo "SKIP: jq engine (jq not installed)"; fi
if command -v python3 >/dev/null 2>&1; then run_engine python3; else echo "SKIP: python3 engine (python3 not installed)"; fi

# parity: both engines write byte-identical files and print byte-identical output.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  P="$(mktemp -d)"; TMPDIRS+=("$P")
  for E in jq python3; do
    mkdir -p "$P/$E/a" "$P/$E/n"
    o1="$(printf '%s' "$LEGACY" | QA_ENGINE=$E bash "$SH" add "$P/$E/a" -; echo "rc=$?")"
    o2="$(printf '%s' "$CANON" | QA_ENGINE=$E bash "$SH" add "$P/$E/a" -; echo "rc=$?")"
    printf '{"run_id":"n","entries":[%s,{"id":"x","layer":"DB"}]}' "$LEGACY" > "$P/$E/n/bug-log.json"
    o3="$(QA_ENGINE=$E bash "$SH" normalize "$P/$E/n"; echo "rc=$?")"
    o4="$(QA_ENGINE=$E bash "$SH" validate "$P/$E/n"; echo "rc=$?")"
    printf '%s\n%s\n%s\n%s\n' "$o1" "$o2" "$o3" "$o4" > "$P/$E.out"
  done
  check "parity stdout" "$(cmp -s "$P/jq.out" "$P/python3.out" && echo same || echo diff)" "same"
  check "parity add file" "$(cmp -s "$P/jq/a/bug-log.json" "$P/python3/a/bug-log.json" && echo same || echo diff)" "same"
  check "parity normalize file" "$(cmp -s "$P/jq/n/bug-log.json" "$P/python3/n/bug-log.json" && echo same || echo diff)" "same"
fi
echo "bug-log: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
