#!/usr/bin/env bash
# tests/session-preflight/run.sh — scripts/session-preflight.sh (H4/T-13,
# portable-enforcement Task 2): the preflight that derives
# .qa/runs/<run-id>/toolstream.jsonl from a Playwright MCP --save-session
# log BEFORE qa-verify runs, so non-Claude harnesses (with no live
# capture-hook) still get high-confidence provenance binding instead of
# qa-verify's honest no-toolstream confidence:low degrade.
#
# Covers:
#   1. Derives from session log: a run with NO toolstream.jsonl + a
#      .playwright-mcp/session.md fixture (a real @playwright/mcp
#      --save-session shape, same fixture idiom as
#      tests/session-to-toolstream/run.sh) containing a .click() call ->
#      toolstream.jsonl is created, non-empty, valid ndjson, and (bonus)
#      `toolstream.sh read` shows an event whose `.tool` ends with
#      browser_click.
#   2. Idempotent / never clobbers a live toolstream: a run with an
#      EXISTING toolstream.jsonl (a sentinel line, standing in for a live
#      capture-hook's output) -> preflight is a byte-exact no-op, exit 0.
#   3. No session log -> no-op: a run with neither toolstream nor session
#      log resolvable -> exit 0, no toolstream.jsonl created.
#   4. Bad run-id -> non-zero (validate_token, mirrors journal-emit.sh's
#      Fix 28 path-escape guard).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PREFLIGHT="$ROOT/scripts/session-preflight.sh"
TOOLSTREAM="$ROOT/scripts/toolstream.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "$PREFLIGHT" ]] || { echo "FAIL - session-preflight.sh does not exist yet at $PREFLIGHT"; echo "---"; echo "session-preflight: PASS=$PASS FAIL=$((FAIL+1))"; exit 1; }

bash -n "$PREFLIGHT" && echo "ok   - bash -n session-preflight.sh" && PASS=$((PASS+1)) \
  || { echo "FAIL - bash -n session-preflight.sh"; FAIL=$((FAIL+1)); }

# ===========================================================================
# 1. Derives a toolstream.jsonl from a session log fixture.
# ===========================================================================
WORK1="$(mktemp -d)"; trap 'rm -rf "$WORK1"' EXIT
RUN1="run-derive"
mkdir -p "$WORK1/.qa/runs/$RUN1" "$WORK1/.playwright-mcp"

cat > "$WORK1/.playwright-mcp/session.md" <<'EOF'
# Session log

### Tool call: browser_click
- Params: {"element":"Add founder button","ref":"e12"}
- Result
```json
{"code":"await page.locator('#add').click();"}
```

### Tool call: browser_navigate
- Params: {"url":"https://example.test/founders"}
- Result
```json
{"code":"await page.goto('https://example.test/founders');"}
```
EOF

TS_FILE1="$WORK1/.qa/runs/$RUN1/toolstream.jsonl"
[[ ! -f "$TS_FILE1" ]] || { echo "FAIL - fixture sanity: toolstream.jsonl must not pre-exist for case 1"; FAIL=$((FAIL+1)); }

OUT1="$( cd "$WORK1" && QA_BASE=".qa/runs" bash "$PREFLIGHT" "$RUN1" )"; RC1=$?
check "case 1: preflight exits 0" "$RC1" "0"
check_contains "case 1: prints 'derived' with an event count" "$OUT1" "derived"

check "case 1: toolstream.jsonl now exists" "$([[ -f "$TS_FILE1" ]] && echo yes)" "yes"
check "case 1: toolstream.jsonl is non-empty" "$([[ -s "$TS_FILE1" ]] && echo yes)" "yes"

# valid ndjson: every non-empty line parses as a JSON object.
NDJSON_OK1="$(python3 -c '
import json, sys
ok = True
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            ok = False
            break
        if not isinstance(obj, dict):
            ok = False
            break
print("yes" if ok else "no")
' "$TS_FILE1")"
check "case 1: toolstream.jsonl is valid ndjson (one JSON object per line)" "$NDJSON_OK1" "yes"

# bonus: toolstream.sh read shows an event whose .tool ends with browser_click.
READ1="$( cd "$WORK1" && QA_BASE=".qa/runs" bash "$TOOLSTREAM" read "$RUN1" )"
CLICK_TOOL="$(printf '%s\n' "$READ1" | jq -r 'select(.tool != null) | .tool' | grep -c 'browser_click$' || true)"
check "case 1 (bonus): toolstream read shows an event whose .tool ends with browser_click" "$([[ "$CLICK_TOOL" -ge 1 ]] && echo yes)" "yes"

# ===========================================================================
# 2. Idempotent — never clobbers an existing (live-hook) toolstream.
# ===========================================================================
WORK2="$(mktemp -d)"; trap 'rm -rf "$WORK1" "$WORK2"' EXIT
RUN2="run-idempotent"
mkdir -p "$WORK2/.qa/runs/$RUN2" "$WORK2/.playwright-mcp"
TS_FILE2="$WORK2/.qa/runs/$RUN2/toolstream.jsonl"
printf '{"tool":"live-capture-hook","seq":1,"ts":"2026-01-01T00:00:00Z"}\n' > "$TS_FILE2"
cp "$TS_FILE2" "$TS_FILE2.orig"

# Also drop a session log fixture, to prove presence of a toolstream wins
# over a resolvable session log (never overwrite a live-hook capture).
cat > "$WORK2/.playwright-mcp/session.md" <<'EOF'
# Session log

### Tool call: browser_click
- Params: {"element":"Some button","ref":"e1"}
- Result
```json
{"code":"await page.locator('#x').click();"}
```
EOF

OUT2="$( cd "$WORK2" && QA_BASE=".qa/runs" bash "$PREFLIGHT" "$RUN2" )"; RC2=$?
check "case 2: preflight exits 0 (no-op)" "$RC2" "0"
check_contains "case 2: prints 'already present' / 'skipping'" "$OUT2" "already present"

if cmp -s "$TS_FILE2" "$TS_FILE2.orig"; then
  echo "ok   - case 2: toolstream.jsonl is byte-unchanged after preflight"; PASS=$((PASS+1))
else
  echo "FAIL - case 2: toolstream.jsonl was modified by preflight (must never clobber a live capture)"; FAIL=$((FAIL+1))
fi

# ===========================================================================
# 3. No session log resolvable -> no-op, no toolstream.jsonl created.
# ===========================================================================
WORK3="$(mktemp -d)"; trap 'rm -rf "$WORK1" "$WORK2" "$WORK3"' EXIT
RUN3="run-nolog"
mkdir -p "$WORK3/.qa/runs/$RUN3"
TS_FILE3="$WORK3/.qa/runs/$RUN3/toolstream.jsonl"

OUT3="$( cd "$WORK3" && QA_BASE=".qa/runs" bash "$PREFLIGHT" "$RUN3" )"; RC3=$?
check "case 3: preflight exits 0 (no-op, honest degrade)" "$RC3" "0"
check_contains "case 3: prints 'no session log'" "$OUT3" "no session log"
check "case 3: no toolstream.jsonl was created" "$([[ ! -f "$TS_FILE3" ]] && echo yes)" "yes"

# ===========================================================================
# 4. Bad run-id -> non-zero.
# ===========================================================================
WORK4="$(mktemp -d)"; trap 'rm -rf "$WORK1" "$WORK2" "$WORK3" "$WORK4"' EXIT
( cd "$WORK4" && QA_BASE=".qa/runs" bash "$PREFLIGHT" 'bad/id' >/dev/null 2>"$WORK4/stderr.log" ); RC4=$?
check "case 4: bad run-id ('bad/id') -> non-zero exit" "$([[ "$RC4" -ne 0 ]] && echo yes)" "yes"

( cd "$WORK4" && QA_BASE=".qa/runs" bash "$PREFLIGHT" '../escape' >/dev/null 2>"$WORK4/stderr2.log" ); RC4B=$?
check "case 4b: bad run-id ('../escape') -> non-zero exit" "$([[ "$RC4B" -ne 0 ]] && echo yes)" "yes"

echo "---"
echo "session-preflight: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
