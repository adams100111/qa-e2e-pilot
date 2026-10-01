#!/usr/bin/env bash
# tests/preflight/run.sh — skills/driving-browser-qa/scripts/preflight.sh.
#
# 0.9.0 (ADR-0027): the up-front --save-session detection (section 7c). Two
# real runs set humanInteraction.saveSession:true, never got a session log,
# and degraded Check 0 silently. Preflight now says so before the run starts.
# A throwaway local HTTP server stands in for the app (preflight aborts on a
# dead app by design); HOME is a temp dir so no real MCP config is read.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PF="$HERE/../../skills/driving-browser-qa/scripts/preflight.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected output to contain '$3')"; FAIL=$((FAIL+1)); fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected output NOT to contain '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
( cd "$WORK" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SRV_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

mkdir -p "$WORK/proj/.qa" "$WORK/home"
cfg() { printf '%s' "$1" > "$WORK/proj/.qa/config.json"; }
pf() { ( cd "$WORK/proj" && env -u PLAYWRIGHT_MCP_SAVE_SESSION HOME="$WORK/home" "$@" bash "$PF" 2>&1 ); }

BASE="\"baseUrl\":\"http://127.0.0.1:$PORT/\",\"drivers\":[{\"id\":\"pw\",\"preset\":\"managed\"}]"

cfg "{$BASE,\"humanInteraction\":{\"saveSession\":true}}"
OUT="$(pf)"; RC=$?
check "app live -> preflight exits 0" "$RC" "0"
contains "saveSession on + no --save-session anywhere -> warns 'save-session: absent'" "$OUT" "save-session: absent"
contains "the warning says how to enable it" "$OUT" "PLAYWRIGHT_MCP_SAVE_SESSION=true"
contains "the warning names the opt-out" "$OUT" "humanInteraction.saveSession:false"

OUT="$(pf PLAYWRIGHT_MCP_SAVE_SESSION=true)"
contains "PLAYWRIGHT_MCP_SAVE_SESSION=true -> detected" "$OUT" "save-session: detected (PLAYWRIGHT_MCP_SAVE_SESSION)"
not_contains "PLAYWRIGHT_MCP_SAVE_SESSION=true -> no absent warning" "$OUT" "save-session: absent"

printf '%s' '{"mcpServers":{"pw":{"command":"npx","args":["@playwright/mcp@latest","--save-session","--output-dir",".playwright-mcp"]}}}' > "$WORK/proj/.mcp.json"
OUT="$(pf)"
contains "a project .mcp.json Playwright server with --save-session -> detected" "$OUT" "save-session: detected (.mcp.json)"
rm -f "$WORK/proj/.mcp.json"

mkdir -p "$WORK/home/.claude/plugins/cache/x/playwright/1"
printf '%s' '{"playwright":{"command":"npx","args":["@playwright/mcp@latest"]}}' > "$WORK/home/.claude/plugins/cache/x/playwright/1/.mcp.json"
OUT="$(pf)"
contains "the stock plugin .mcp.json (no flag) -> still absent" "$OUT" "save-session: absent"

cfg "{$BASE,\"humanInteraction\":{\"saveSession\":false}}"
OUT="$(pf)"
not_contains "saveSession:false (degrade accepted) -> no save-session line at all" "$OUT" "save-session:"

cfg "{$BASE}"
OUT="$(pf)"
contains "saveSession unset defaults to on -> absent warning" "$OUT" "save-session: absent"

kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
OUT="$(pf)"; RC=$?
check "dead app -> preflight aborts non-zero" "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
