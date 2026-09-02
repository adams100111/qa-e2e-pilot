#!/usr/bin/env bash
# Tests for mutation-flag.sh — the deterministic, agent-untrusted mutation
# classifier (Task 5, durable Run substrate). Covers `derive`'s rule order
# (kinds > httpMethod > verb-match, word-boundary, case-insensitive) and
# `reconcile`'s absent-tolerant capture-hook cross-check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$HERE/../../skills/checkpointing-qa-memory/scripts/mutation-flag.sh"
PSL="$HERE/../../skills/driving-browser-qa/scripts/parse-session-log.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# derive — true cases
# ---------------------------------------------------------------------------

check "derive: human-action kinds wins over read verb" \
  "$(bash "$M" derive '{"kinds":["human-action"],"action":"view page"}')" "true"

check "derive: httpMethod delete (lowercase) -> true" \
  "$(bash "$M" derive '{"httpMethod":"delete"}')" "true"

check "derive: action verb 'Create' -> true" \
  "$(bash "$M" derive '{"action":"Create a new founder"}')" "true"

check "derive: title verb 'Submit' -> true" \
  "$(bash "$M" derive '{"title":"Submit the cap-table form"}')" "true"

# ---------------------------------------------------------------------------
# derive — false cases
# ---------------------------------------------------------------------------

check "derive: read verb 'View' + kinds bake -> false" \
  "$(bash "$M" derive '{"action":"View the dashboard","kinds":["bake"]}')" "false"

check "derive: read verb 'Filter' -> false" \
  "$(bash "$M" derive '{"action":"Filter deliverables by status"}')" "false"

check "derive: httpMethod GET -> false" \
  "$(bash "$M" derive '{"httpMethod":"GET"}')" "false"

# ---------------------------------------------------------------------------
# derive — word-boundary non-match cases (the trap: substring != word)
# ---------------------------------------------------------------------------

check "derive: 'settings' contains 'set' but is not the word 'set' -> false" \
  "$(bash "$M" derive '{"action":"Review the settings page"}')" "false"

check "derive: 'overview' contains no listed verb, 'Review' is not a verb -> false" \
  "$(bash "$M" derive '{"action":"Get an overview of the metrics"}')" "false"

check "derive: 'renew' does not match the standalone word 'new' -> false" \
  "$(bash "$M" derive '{"action":"Renew the lease display"}')" "false"

# ---------------------------------------------------------------------------
# derive — case-insensitivity (httpMethod and verb)
# ---------------------------------------------------------------------------

check "derive: httpMethod mixed-case 'Post' -> true" \
  "$(bash "$M" derive '{"httpMethod":"Post"}')" "true"

check "derive: verb mixed-case 'DELETE the record' -> true" \
  "$(bash "$M" derive '{"action":"DELETE the record"}')" "true"

# ---------------------------------------------------------------------------
# reconcile — missing toolstream path returns the derive result unchanged
# ---------------------------------------------------------------------------

check "reconcile: no toolstream arg -> derive result (false)" \
  "$(bash "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}')" "false"

check "reconcile: nonexistent toolstream path -> derive result (false)" \
  "$(bash "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}' "$WORK/does-not-exist.md")" "false"

touch "$WORK/empty.md"
check "reconcile: empty toolstream file -> derive result (false)" \
  "$(bash "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}' "$WORK/empty.md")" "false"

check "reconcile: no toolstream arg on a true-derived criterion -> true (unaffected)" \
  "$(bash "$M" reconcile '{"action":"Create a new founder"}')" "true"

# ---------------------------------------------------------------------------
# reconcile — capture-hook cross-check (only when node is present)
# ---------------------------------------------------------------------------

# A saved-session fixture matching @playwright/mcp --save-session's real
# format (parse-session-log.js's documented shape): one "### Tool call: X"
# section, whose "- Result" fenced ```json block carries the executed code.
cat > "$WORK/mutating-session.md" <<'EOF'
### Tool call: browser_click
- Params: {}
- Result
```json
{"code": "await page.locator('#save-btn').click();"}
```
EOF

cat > "$WORK/readonly-session.md" <<'EOF'
### Tool call: browser_snapshot
- Params: {}
- Result
```json
{"code": "await page.locator('#save-btn').textContent();"}
```
EOF

if command -v node >/dev/null 2>&1 && [[ -f "$PSL" ]]; then
  exec 9>"$WORK/fd3.out"
  RESULT="$(bash "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}' "$WORK/mutating-session.md" 3>&9)"
  exec 9>&-
  check "reconcile: mutating toolstream on false-derived criterion -> true" "$RESULT" "true"
  check "reconcile: fd3 carries mutation-observed-in-readonly note" \
    "$(cat "$WORK/fd3.out")" '{"rule":"mutation-observed-in-readonly"}'

  check "reconcile: read-only toolstream on false-derived criterion -> false (no strengthening)" \
    "$(bash "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}' "$WORK/readonly-session.md")" "false"

  check "reconcile: mutating toolstream on a TRUE-derived criterion stays true (never re-derives)" \
    "$(bash "$M" reconcile '{"action":"Create a new founder"}' "$WORK/mutating-session.md")" "true"

  echo "note - node cross-check sub-case: RAN (node present on this host)"
else
  echo "SKIP - node cross-check sub-case: node (or parse-session-log.js) not present on this host"
fi

# ---------------------------------------------------------------------------
# reconcile — node is NEVER a hard dependency: force a PATH with no node and
# confirm a mutating toolstream on a false-derived criterion is NOT
# strengthened (the absent-tolerant degrade). Real binaries only (grep is a
# shell FUNCTION in some interactive environments — `type -P` skips that and
# resolves the actual external binary, unlike `command -v`).
# ---------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(type -P bash)"
  FAKEBIN="$WORK/fakebin-no-node"
  mkdir -p "$FAKEBIN"
  for tool in bash jq python3 grep cat dirname basename mkdir; do
    TOOL_PATH="$(type -P "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done
  check "reconcile: node absent from PATH -> derive result unchanged (false), not strengthened" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}' "$WORK/mutating-session.md")" \
    "false"
  echo "note - node-absent degrade sub-case: RAN (PATH forced without node)"
else
  echo "SKIP - node-absent degrade sub-case: neither jq nor python3 present on this host"
fi

# ---------------------------------------------------------------------------
# python3-fallback pass: mask jq from PATH so has_jq() fails and has_py()
# succeeds, then re-assert representative derive/reconcile cases under the
# fallback. Modeled on tests/journal/run.sh's fakebin jq-masked pass.
# ---------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(type -P bash)"
  FAKEBIN="$WORK/fakebin-no-jq"
  mkdir -p "$FAKEBIN"
  # Deliberately exclude jq -- forces has_jq() to fail, has_py() to succeed.
  for tool in bash python3 grep cat dirname basename mkdir; do
    TOOL_PATH="$(type -P "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  check "py-fallback: derive human-action kinds wins" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" derive '{"kinds":["human-action"],"action":"view page"}')" "true"

  check "py-fallback: derive httpMethod delete -> true" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" derive '{"httpMethod":"delete"}')" "true"

  check "py-fallback: derive verb 'Create' -> true" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" derive '{"action":"Create a new founder"}')" "true"

  check "py-fallback: derive read verb 'Filter' -> false" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" derive '{"action":"Filter deliverables by status"}')" "false"

  check "py-fallback: derive httpMethod GET -> false" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" derive '{"httpMethod":"GET"}')" "false"

  check "py-fallback: word-boundary 'settings' does not match 'set' -> false" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" derive '{"action":"Review the settings page"}')" "false"

  check "py-fallback: reconcile missing toolstream -> derive result unchanged" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$M" reconcile '{"action":"View the dashboard","kinds":["bake"]}')" "false"

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# ---------------------------------------------------------------------------
# malformed input -> non-zero exit, no stray output
# ---------------------------------------------------------------------------

bash "$M" derive 'not json' >/dev/null 2>&1; rc=$?
check "derive: malformed JSON -> non-zero exit" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

bash "$M" derive '["not","an","object"]' >/dev/null 2>&1; rc2=$?
check "derive: non-object JSON -> non-zero exit" "$([[ $rc2 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
