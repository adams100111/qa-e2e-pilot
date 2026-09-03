#!/usr/bin/env bash
# Tests for skills/driving-browser-qa/scripts/session-to-toolstream.js — the
# session-log -> toolstream converter (H4/T-13, portable-enforcement).
#
# Covers:
#   1. Shape/mapping unit tests: a REAL `--save-session` session.md fixture
#      (### Tool call: <name> / - Result / ```json {"code":...}```) with a
#      human-path click, a read-only evaluate, and a navigate ("other") ->
#      sessionToEvents yields 3 events whose `.tool` is the FULL MCP tool
#      name and CONTAINS the class-appropriate short name provenance.sh
#      binds on (browser_click / browser_evaluate / browser_navigate).
#   2. The provenance round-trip (the integration proof): the converter's
#      events are piped through toolstream.sh append to build a REAL
#      toolstream.jsonl, an action-trace artifact is built via
#      record-evidence.sh --session-log/--session-from (deriving sessionCalls
#      from the SAME fixture, independent ground truth), and provenance.sh
#      check is run against it -> must print "bound". This proves a
#      converted human-path event actually binds a human-path sessionCall.
#   3. Negative: a toolstream containing ONLY a converted browser_navigate
#      (class "other") event must NOT bind a forged class:"human-path"
#      sessionCall -> "unbound" (mirrors provenance.sh's own Fix 1/Fix 2
#      anti-forgery regression, exercised here through the new converter's
#      real output instead of a hand-crafted event).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CONV="$ROOT/skills/driving-browser-qa/scripts/session-to-toolstream.js"
TOOLSTREAM="$ROOT/scripts/toolstream.sh"
PROV="$ROOT/scripts/provenance.sh"
REC="$ROOT/skills/checkpointing-qa-memory/scripts/record-evidence.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { case "$2" in *"$3"*) echo "ok   - $1"; PASS=$((PASS+1));; *) echo "FAIL - $1 ('$2' does not contain '$3')"; FAIL=$((FAIL+1));; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a REAL @playwright/mcp --save-session session.md. Each call is a
# "### Tool call: <name>" section whose "- Result" fenced ```json block
# carries the executed Playwright code under a `code` field — the format
# parse-session-log.js's own header comment documents as VERIFIED against
# the real saved file (NOT the interactive "Ran Playwright code" js block).
# ---------------------------------------------------------------------------
FIXTURE="$WORK/session.md"
cat > "$FIXTURE" <<'EOF'
# Session log

### Tool call: browser_click
- Params: {"element":"Add founder button","ref":"e12"}
- Result
```json
{"code":"await page.locator('#add').click();"}
```

### Tool call: browser_evaluate
- Params: {"function":"() => document.title"}
- Result
```json
{"code":"await page.evaluate(() => document.title);"}
```

### Tool call: browser_navigate
- Params: {"url":"https://example.test/founders"}
- Result
```json
{"code":"await page.goto('https://example.test/founders');"}
```
EOF

[[ -f "$CONV" ]] || { echo "FAIL - session-to-toolstream.js does not exist yet at $CONV"; echo "---"; echo "PASS=$PASS FAIL=$((FAIL+1))"; exit 1; }

node --check "$CONV" && echo "ok   - node --check session-to-toolstream.js" && PASS=$((PASS+1)) \
  || { echo "FAIL - node --check session-to-toolstream.js"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# 1. Shape/mapping unit tests (CLI ndjson output).
# ---------------------------------------------------------------------------
NDJSON="$(node "$CONV" "$FIXTURE" 2>"$WORK/stderr.log")"
LINECOUNT="$(printf '%s\n' "$NDJSON" | grep -c .)"
check "CLI emits exactly 3 ndjson lines (one per parsed call)" "$LINECOUNT" "3"

L1="$(printf '%s\n' "$NDJSON" | sed -n 1p)"
L2="$(printf '%s\n' "$NDJSON" | sed -n 2p)"
L3="$(printf '%s\n' "$NDJSON" | sed -n 3p)"

check "each line is valid JSON (L1)" "$(jq -e . >/dev/null 2>&1 <<<"$L1"; echo $?)" "0"
check "each line is valid JSON (L2)" "$(jq -e . >/dev/null 2>&1 <<<"$L2"; echo $?)" "0"
check "each line is valid JSON (L3)" "$(jq -e . >/dev/null 2>&1 <<<"$L3"; echo $?)" "0"

T1="$(jq -r '.tool' <<<"$L1")"; T2="$(jq -r '.tool' <<<"$L2")"; T3="$(jq -r '.tool' <<<"$L3")"
contains "human-path click -> tool contains browser_click" "$T1" "browser_click"
contains "evaluate -> tool contains browser_evaluate" "$T2" "browser_evaluate"
contains "navigate/other -> tool contains browser_navigate" "$T3" "browser_navigate"

check "no seq field on the emitted event (toolstream.sh append stamps it)" "$(jq -e 'has("seq")' <<<"$L1")" "false"
check "no ts field on the emitted event (toolstream.sh append stamps it)" "$(jq -e 'has("ts")' <<<"$L1")" "false"
check "args.code carries the parsed code (L1)" "$(jq -r '.args.code' <<<"$L1")" "await page.locator('#add').click();"
check "responseBody is null" "$(jq -r '.responseBody' <<<"$L1")" "null"
check "resultDigest is present and non-empty (L1)" "$(jq -e '(.resultDigest | tostring | length) > 0' <<<"$L1")" "true"

# sessionToEvents export usable directly (not just via CLI).
EXPORT_CHECK="$(node -e '
const { sessionToEvents } = require("'"$CONV"'");
const fs = require("fs");
const md = fs.readFileSync("'"$FIXTURE"'", "utf8");
const events = sessionToEvents(md);
console.log(events.length === 3 && events.every(e => typeof e.tool === "string" && e.args && typeof e.args.code === "string") ? "ok" : "fail:" + JSON.stringify(events));
')"
check "sessionToEvents(md) exported and returns 3 well-shaped events" "$EXPORT_CHECK" "ok"

# ---------------------------------------------------------------------------
# 2. Provenance round-trip (the integration proof).
# ---------------------------------------------------------------------------
RUN1="rt1"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  ( cd "$WORK" && bash "$TOOLSTREAM" append "$RUN1" "$line" >/dev/null ) \
    || { echo "FAIL - toolstream.sh append failed for: $line"; FAIL=$((FAIL+1)); }
done <<<"$NDJSON"

TS_LINES="$(wc -l < "$WORK/.qa/runs/$RUN1/toolstream.jsonl" | tr -d ' ')"
check "toolstream.jsonl has 3 captured events after append" "$TS_LINES" "3"

# action-trace artifact whose sessionCalls are DERIVED from the same session.md
# (independent ground truth) via record-evidence.sh --session-log/--session-from.
ACTION_ARTIFACT="$( cd "$WORK" && bash "$REC" "$RUN1" C1 action-trace \
  --steps '[{"tool":"browser_click","phase":"act"}]' \
  --session-log "$FIXTURE" --session-from 0 )"
[[ -n "$ACTION_ARTIFACT" ]] || { echo "FAIL - record-evidence.sh produced no artifact path"; FAIL=$((FAIL+1)); }

check "action-trace sessionCalls include a human-path entry" \
  "$(jq -e '[.sessionCalls[] | select(.class=="human-path")] | length > 0' "$WORK/.qa/runs/$RUN1/$ACTION_ARTIFACT")" "true"

BOUND_RESULT="$( cd "$WORK" && bash "$PROV" check "$RUN1" ".qa/runs/$RUN1/$ACTION_ARTIFACT" )"
check "ROUND-TRIP: converter events -> toolstream -> provenance check -> bound" "$BOUND_RESULT" "bound"

# same check under the python3 fallback engine, for parity with the rest of
# the provenance/toolstream suite.
if command -v python3 >/dev/null 2>&1; then
  BOUND_RESULT_PY="$( cd "$WORK" && QA_ENGINE=python3 bash "$PROV" check "$RUN1" ".qa/runs/$RUN1/$ACTION_ARTIFACT" )"
  check "ROUND-TRIP (python3 engine): bound" "$BOUND_RESULT_PY" "bound"
fi

# ---------------------------------------------------------------------------
# 3. Negative: a converted browser_navigate ("other"/route) event ALONE must
#    NOT bind a forged class:"human-path" sessionCall. Proves the mapping
#    isn't over-permissive (mirrors provenance.sh's Fix 1/Fix 2 regression).
# ---------------------------------------------------------------------------
RUN2="rt2"
NAV_ONLY_EVENT="$L3"
( cd "$WORK" && bash "$TOOLSTREAM" append "$RUN2" "$NAV_ONLY_EVENT" >/dev/null )

FORGED_ARTIFACT="$( cd "$WORK" && bash "$REC" "$RUN2" F1 action-trace \
  --steps '[{"tool":"browser_click","phase":"act"}]' \
  --session-calls '[{"class":"human-path","mutating":true,"code":"forged -- never actually captured"}]' )"

UNBOUND_RESULT="$( cd "$WORK" && bash "$PROV" check "$RUN2" ".qa/runs/$RUN2/$FORGED_ARTIFACT" )"
check "NEGATIVE: navigate-only toolstream + forged human-path sessionCall -> unbound" "$UNBOUND_RESULT" "unbound"

if command -v python3 >/dev/null 2>&1; then
  UNBOUND_RESULT_PY="$( cd "$WORK" && QA_ENGINE=python3 bash "$PROV" check "$RUN2" ".qa/runs/$RUN2/$FORGED_ARTIFACT" )"
  check "NEGATIVE (python3 engine): unbound" "$UNBOUND_RESULT_PY" "unbound"
fi

echo "---"
echo "session-to-toolstream: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
