#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/scripts/block-hook.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to contain '$3')"; FAIL=$((FAIL+1)); fi; }

# Build a stdin hook-JSON payload: tool_name + a tool_input object literal
# (caller supplies the tool_input JSON body, e.g. '{"function":"..."}').
evt() {
  local tool="$1" input_json="$2"
  printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$input_json"
}

EVAL_TOOL="mcp__plugin_playwright_playwright__browser_evaluate"
UNSAFE_TOOL="mcp__plugin_playwright_playwright__browser_run_code_unsafe"
NAV_TOOL="mcp__plugin_playwright_playwright__browser_navigate"

run_hook() {
  # $1 = stdin body; writes stdout to $OUT, stderr to $ERR, sets $RC
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$HERE/.err")"; RC=$?
  ERR="$(cat "$HERE/.err" 2>/dev/null || true)"
}

deny_json_ok() {
  # $1 = OUT — verify it is a valid JSON deny payload with the expected shape.
  echo "$1" | jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|length>0)' >/dev/null 2>&1
}

# ===========================================================================
# §3-#3 mutating evaluate payload classes -- each must DENY (exit 2 + valid
# deny JSON on stdout).
# ===========================================================================
declare -a CLASS_NAMES=(
  "fetch method:'POST'"
  "fetch backtick-template method"
  "page.request.post"
  "axios.post"
  "XHR open('POST')"
  "sendBeacon"
  ".setItem("
)
declare -a CLASS_PAYLOADS=(
  '() => { return fetch("/api/items", {method:"POST", body: "{}"}); }'
  '() => { return fetch("/api/items", {method: `POST`}); }'
  '() => { return page.request.post("/api/items", {data: {}}); }'
  '() => { return axios.post("/api/items", {}); }'
  '() => { const x = new XMLHttpRequest(); x.open("POST", "/api/items"); x.send(); }'
  '() => { navigator.sendBeacon("/api/items", "{}"); }'
  '() => { localStorage.setItem("k", "v"); }'
)

for i in "${!CLASS_NAMES[@]}"; do
  name="${CLASS_NAMES[$i]}"
  payload_js="${CLASS_PAYLOADS[$i]}"
  input_json="$(jq -n --arg f "$payload_js" '{function:$f}')"
  run_hook "$(evt "$EVAL_TOOL" "$input_json")"
  check "mutating evaluate [$name]: exit 2" "$RC" "2"
  check "mutating evaluate [$name]: deny JSON valid+shaped" "$(deny_json_ok "$OUT" && echo yes || echo no)" "yes"
done

# ===========================================================================
# read-only evaluate -> exit 0, no deny JSON required.
# ===========================================================================
run_hook "$(evt "$EVAL_TOOL" '{"function":"() => document.querySelector(\"#total\").textContent"}')"
check "read-only evaluate (querySelector): exit 0" "$RC" "0"

run_hook "$(evt "$EVAL_TOOL" '{"function":"() => fetch(\"/api/items\").then(r => r.json())"}')"
check "read-only evaluate (GET fetch): exit 0" "$RC" "0"

# ===========================================================================
# browser_run_code_unsafe -> ALWAYS exit 2, regardless of payload (even a
# read-only-looking one -- the tool itself is the absolute, not its content).
# ===========================================================================
run_hook "$(evt "$UNSAFE_TOOL" '{"code":"async (page) => { return await page.title(); }"}')"
check "run_code_unsafe (read-only-looking payload): exit 2" "$RC" "2"
check "run_code_unsafe: deny JSON valid+shaped" "$(deny_json_ok "$OUT" && echo yes || echo no)" "yes"

run_hook "$(evt "$UNSAFE_TOOL" '{"code":"async (page) => { await page.request.post(\"/api/items\"); }"}')"
check "run_code_unsafe (mutating payload): exit 2" "$RC" "2"

# ===========================================================================
# browser_navigate -> NEVER blocked, exit 0 (record-only is the capture-hook's
# job; live-block false-positives here must be zero).
# ===========================================================================
run_hook "$(evt "$NAV_TOOL" '{"url":"https://example.com/dashboard"}')"
check "browser_navigate: exit 0 (never blocked)" "$RC" "0"

# ===========================================================================
# Any other tool (e.g. Bash, a human-path act tool) -> not matched, exit 0.
# ===========================================================================
run_hook "$(evt "Bash" '{"command":"ls"}')"
check "Bash: exit 0 (not this hook's concern)" "$RC" "0"

run_hook "$(evt "mcp__plugin_playwright_playwright__browser_click" '{"target":"#submit"}')"
check "browser_click: exit 0 (human-path, not this hook's concern)" "$RC" "0"

# ===========================================================================
# fallback arg names -- `code` / `expression` are also inspected (defensive,
# in case of a differently-shaped harness/tool-version payload).
# ===========================================================================
run_hook "$(evt "$EVAL_TOOL" '{"code":"() => { localStorage.setItem(\"k\",\"v\"); }"}')"
check "evaluate via 'code' arg name: mutating -> exit 2" "$RC" "2"

run_hook "$(evt "$EVAL_TOOL" '{"expression":"() => { localStorage.setItem(\"k\",\"v\"); }"}')"
check "evaluate via 'expression' arg name: mutating -> exit 2" "$RC" "2"

# ===========================================================================
# fail-OPEN cases -- must ALLOW (exit 0), never crash, never wrongly deny.
# ===========================================================================
run_hook ""
check "empty stdin: fail-open exit 0" "$RC" "0"

run_hook '{not valid json'
check "malformed stdin: fail-open exit 0" "$RC" "0"

run_hook '{"tool_input":{"function":"() => localStorage.setItem(\"k\",\"v\")"}}'
check "missing tool_name: fail-open exit 0" "$RC" "0"

run_hook "$(evt "$EVAL_TOOL" '{"filename":"/tmp/does-not-exist-qa-block-hook.js"}')"
check "evaluate with only filename (no inspectable payload): fail-open exit 0" "$RC" "0"

run_hook "$(evt "$EVAL_TOOL" '{}')"
check "evaluate with empty tool_input: fail-open exit 0" "$RC" "0"

rm -f "$HERE/.err"

# ===========================================================================
# python3-fallback re-run of the load-bearing cases (mask jq from PATH).
# node stays on PATH -- the classifier itself is node-based, only the stdin
# JSON parse falls back to python3 here.
# ===========================================================================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$HERE/.fakebin-py"
  rm -rf "$FAKEBIN"; mkdir -p "$FAKEBIN"
  for tool in bash cat node python3; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  run_hook_restricted() {
    # CLAUDE_PLUGIN_ROOT pinned explicitly -- the restricted fakebin PATH
    # deliberately excludes `dirname`, so block-hook.sh's own
    # dirname-based ROOT fallback can't run; this sidesteps that (the
    # ROOT-resolution mechanics aren't what this sub-case is testing).
    OUT="$(printf '%s' "$1" | PATH="$FAKEBIN" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" "$HOOK" 2>"$HERE/.err2")"; RC=$?
  }

  in1="$(jq -n --arg f '() => { return page.request.post("/api/items", {}); }' '{function:$f}')"
  run_hook_restricted "$(evt "$EVAL_TOOL" "$in1")"
  check "py-fallback: mutating evaluate exit 2" "$RC" "2"
  check "py-fallback: deny JSON valid+shaped" "$(deny_json_ok "$OUT" && echo yes || echo no)" "yes"

  run_hook_restricted "$(evt "$EVAL_TOOL" '{"function":"() => document.title"}')"
  check "py-fallback: read-only evaluate exit 0" "$RC" "0"

  run_hook_restricted "$(evt "$UNSAFE_TOOL" '{"code":"async (page) => page.title()"}')"
  check "py-fallback: run_code_unsafe exit 2" "$RC" "2"

  run_hook_restricted "$(evt "$NAV_TOOL" '{"url":"https://example.com"}')"
  check "py-fallback: browser_navigate exit 0" "$RC" "0"

  run_hook_restricted ""
  check "py-fallback: empty stdin fail-open exit 0" "$RC" "0"

  rm -rf "$FAKEBIN" "$HERE/.err2"
  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq, python3, or node not present on this host, cannot exercise fallback"
fi

# ===========================================================================
# node-absent -> fail-open (allow), even for a payload that WOULD have been
# denied had node been available. The live hook is best-effort; qa-verify is
# the authority when the classifier itself cannot run.
# ===========================================================================
BASH_BIN="$(command -v bash)"
FAKEBIN_NONODE="$HERE/.fakebin-nonode"
rm -rf "$FAKEBIN_NONODE"; mkdir -p "$FAKEBIN_NONODE"
for tool in bash cat jq python3; do
  TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN_NONODE/$tool"
done
in2="$(jq -n --arg f '() => { localStorage.setItem("k","v"); }' '{function:$f}')"
OUT="$(printf '%s' "$(evt "$EVAL_TOOL" "$in2")" | PATH="$FAKEBIN_NONODE" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" "$HOOK" 2>"$HERE/.err3")"; RC=$?
check "node absent: fail-open exit 0 even for a would-be-mutating payload" "$RC" "0"
rm -rf "$FAKEBIN_NONODE" "$HERE/.err3"

# ===========================================================================
# classifier CRASH (e.g. a broken parse-session-log.js) -> fail-open (allow),
# NOT a wrongful deny. node's default exit code on an uncaught exception is
# 1 -- the SAME code block-hook.sh uses for "mutates() said true" -- so this
# proves the crash path is disambiguated (try/catch -> exit 2) rather than
# accidentally aliasing a crash into a deny.
# ===========================================================================
FAKEROOT="$HERE/.fakeroot-crash"
rm -rf "$FAKEROOT"
mkdir -p "$FAKEROOT/skills/driving-browser-qa/scripts"
printf 'throw new Error("boom");\nmodule.exports = { mutates: function(){ return true; } };\n' \
  > "$FAKEROOT/skills/driving-browser-qa/scripts/parse-session-log.js"
in3="$(jq -n --arg f '() => { localStorage.setItem("k","v"); }' '{function:$f}')"
OUT="$(printf '%s' "$(evt "$EVAL_TOOL" "$in3")" | CLAUDE_PLUGIN_ROOT="$FAKEROOT" bash "$HOOK" 2>"$HERE/.err4")"; RC=$?
check "classifier crash (require throws): fail-open exit 0, not a wrongful deny" "$RC" "0"
rm -rf "$FAKEROOT" "$HERE/.err4"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
