#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/scripts/capture-hook.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to contain '$3')"; FAIL=$((FAIL+1)); fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to NOT contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

setup_run() {
  # a fresh, minimal .qa/ inside $WORK with an active run "r1" and an
  # explicit enforcement config (deterministic, independent of whatever
  # the repo's real .qa/config.json.example happens to contain). $WORK is
  # reused across cases, so wipe any toolstream.jsonl a prior case left
  # behind -- each case that calls setup_run expects to start clean.
  rm -rf "$WORK/.qa/runs"
  mkdir -p "$WORK/.qa/runs/r1"
  printf 'r1\n' > "$WORK/.qa/runs/latest"
  cat > "$WORK/.qa/config.json" <<'EOF'
{
  "enforcement": {
    "captureHook": true,
    "secretPatterns": ["(?i)(password|token|secret|api[_-]?key)\\s*[=:]\\s*\\S+"],
    "redactedKeys": ["s3cr3t-cred-value"]
  }
}
EOF
}

TF() { echo "$WORK/.qa/runs/r1/toolstream.jsonl"; }

# ===========================================================================
# Case 1: Bash call with a secret in the command -> toolstream line has the
# secret redacted (args), full tool name preserved.
# ===========================================================================
setup_run
BASH_EVENT='{"tool_name":"Bash","tool_input":{"command":"curl --data '"'"'password=Sup3rSecret!'"'"' https://api.example.com/x"},"tool_response":{"stdout":"ok","stderr":"","exitCode":0},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$BASH_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook1.err" ); rc1=$?
check "case1: hook exit 0" "$rc1" "0"
check "case1: toolstream written" "$([[ -f "$(TF)" ]] && echo yes || echo no)" "yes"
LINE1="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case1: line is valid json" "$(echo "$LINE1" | jq -e . >/dev/null 2>&1 && echo valid || echo invalid)" "valid"
check "case1: tool == Bash" "$(echo "$LINE1" | jq -r '.tool')" "Bash"
not_contains "case1: secret redacted out of the line" "$LINE1" "Sup3rSecret!"
contains "case1: redacted marker present" "$(echo "$LINE1" | jq -r '.args.command')" "<redacted>"
check "case1: has seq" "$(echo "$LINE1" | jq -r '.seq')" "1"
check "case1: has ts" "$(echo "$LINE1" | jq -r '.ts | test("^[0-9]{4}-")')" "true"
check "case1: has resultDigest.len" "$(echo "$LINE1" | jq -r '.resultDigest.len | type')" "number"

# ===========================================================================
# Case 2: browser_* call -> args recorded IN FULL (no redaction) + a bounded
# responseBody is present.
# ===========================================================================
setup_run
BIG_SNAPSHOT="$(head -c 20000 /dev/zero | tr '\0' 'a')"
BROWSER_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_navigate","tool_input":{"url":"https://example.com/login?token=not-a-real-secret"},"tool_response":{"snapshot":"'"$BIG_SNAPSHOT"'"},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$BROWSER_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook2.err" ); rc2=$?
check "case2: hook exit 0" "$rc2" "0"
LINE2="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case2: tool == browser_navigate" "$(echo "$LINE2" | jq -r '.tool')" "mcp__plugin_playwright_playwright__browser_navigate"
check "case2: url arg kept IN FULL (not redacted)" "$(echo "$LINE2" | jq -r '.args.url')" "https://example.com/login?token=not-a-real-secret"
RESPLEN="$(echo "$LINE2" | jq -r '.responseBody | length')"
check "case2: responseBody present" "$([[ "$RESPLEN" -gt 0 ]] && echo yes || echo no)" "yes"
check "case2: responseBody bounded (<= 4200 chars incl. JSON overhead)" "$([[ "$RESPLEN" -le 4200 ]] && echo yes || echo no)" "yes"
check "case2: full response NOT stored verbatim (was truncated)" "$([[ "$RESPLEN" -lt ${#BIG_SNAPSHOT} ]] && echo yes || echo no)" "yes"

# ===========================================================================
# Case 3: no .qa/runs/latest -> no-op, no file written, exit 0.
# ===========================================================================
NOLATEST_WORK="$(mktemp -d)"
( cd "$NOLATEST_WORK" && printf '%s' "$BASH_EVENT" | bash "$HOOK" >/dev/null 2>"$NOLATEST_WORK/hook3.err" ); rc3=$?
check "case3: hook exit 0 with no active run" "$rc3" "0"
check "case3: no toolstream dir created at all" "$([[ -d "$NOLATEST_WORK/.qa/runs" ]] && echo exists || echo none)" "none"
rm -rf "$NOLATEST_WORK"

# ===========================================================================
# Case 4: empty stdin -> no-op, exit 0, no crash.
# ===========================================================================
EMPTY_WORK="$(mktemp -d)"
( cd "$EMPTY_WORK" && printf '' | bash "$HOOK" >/dev/null 2>"$EMPTY_WORK/hook4.err" ); rc4=$?
check "case4: empty stdin exit 0" "$rc4" "0"
rm -rf "$EMPTY_WORK"

# ===========================================================================
# Case 5: malformed (non-JSON) stdin -> no-op, exit 0, no crash.
# ===========================================================================
BAD_WORK="$(mktemp -d)"; mkdir -p "$BAD_WORK/.qa/runs/r1"; printf 'r1\n' > "$BAD_WORK/.qa/runs/latest"
( cd "$BAD_WORK" && printf '{not valid json' | bash "$HOOK" >/dev/null 2>"$BAD_WORK/hook5.err" ); rc5=$?
check "case5: malformed stdin exit 0" "$rc5" "0"
check "case5: no toolstream file written" "$([[ -f "$BAD_WORK/.qa/runs/r1/toolstream.jsonl" ]] && echo exists || echo none)" "none"
rm -rf "$BAD_WORK"

# ===========================================================================
# Case 6: enforcement.captureHook == false -> no-op even with an active run.
# ===========================================================================
setup_run
python3 -c "
import json
p='$WORK/.qa/config.json'
c=json.load(open(p))
c['enforcement']['captureHook']=False
json.dump(c, open(p,'w'))
"
( cd "$WORK" && printf '%s' "$BASH_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook6.err" ); rc6=$?
check "case6: hook exit 0 when captureHook=false" "$rc6" "0"
check "case6: no NEW line appended (still just the case1/2 lines... but this is a fresh setup_run, so file must not exist)" \
  "$([[ -f "$(TF)" ]] && echo exists || echo none)" "none"

# ===========================================================================
# Case 7: an unrecognized/absent tool_name -> no-op, exit 0.
# ===========================================================================
setup_run
NO_TOOLNAME_EVENT='{"tool_input":{"command":"ls"},"tool_response":{},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$NO_TOOLNAME_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook7.err" ); rc7=$?
check "case7: hook exit 0 with no tool_name" "$rc7" "0"
check "case7: no toolstream file written" "$([[ -f "$(TF)" ]] && echo exists || echo none)" "none"

# ===========================================================================
# Case 8: python3-fallback re-run of case 1 + case 2 (mask jq from PATH).
# ===========================================================================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  setup_run
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  # includes 'bash' itself -- capture-hook.sh shells out to `bash
  # "$TOOLSTREAM"` internally, and that nested invocation is looked up on
  # this same (restricted) PATH once it's forced below.
  for tool in bash date mkdir mv rm cat dirname sed wc python3 tr head awk sha256sum shasum; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  ( cd "$WORK" && printf '%s' "$BASH_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook8.err" ); rc8=$?
  check "py-fallback case1: hook exit 0" "$rc8" "0"
  PYLINE1="$(tail -n1 "$(TF)" 2>/dev/null)"
  check "py-fallback case1: tool == Bash" "$(echo "$PYLINE1" | jq -r '.tool')" "Bash"
  not_contains "py-fallback case1: secret redacted" "$PYLINE1" "Sup3rSecret!"

  ( cd "$WORK" && printf '%s' "$BROWSER_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook9.err" ); rc9=$?
  check "py-fallback case2: hook exit 0" "$rc9" "0"
  PYLINE2="$(tail -n1 "$(TF)" 2>/dev/null)"
  check "py-fallback case2: url arg kept in full" "$(echo "$PYLINE2" | jq -r '.args.url')" "https://example.com/login?token=not-a-real-secret"
  PYRESPLEN="$(echo "$PYLINE2" | jq -r '.responseBody | length')"
  check "py-fallback case2: responseBody bounded" "$([[ "$PYRESPLEN" -le 4200 ]] && echo yes || echo no)" "yes"

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
