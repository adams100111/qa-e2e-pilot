#!/usr/bin/env bash
# Install the qa-e2e-pilot Pi adapter into a project. Uses project-local .pi/, never global ~/.pi.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="${1:?usage: install-pi.sh <project-dir>}"

# --- .pi/mcp.json: merge (never clobber) ---
# Done FIRST, before build-adapter.sh below (which hard-requires python3 to render the
# adapter), so a project with neither jq nor python3 on PATH still gets a safe print-and-ask
# instead of losing its existing config mid-build. harnesses/pi/mcp.snippet is copied
# byte-identical into dist/pi/mcp.snippet by build-adapter.sh (no templating applies to it),
# so reading the harnesses/ source here is equivalent to reading the rendered dist copy.
SNIPPET="$ROOT/harnesses/pi/mcp.snippet"
MCP_DEST="$PROJ/.pi/mcp.json"
mkdir -p "$PROJ/.pi"
if [ -f "$MCP_DEST" ]; then
  if command -v jq >/dev/null 2>&1; then
    cp "$MCP_DEST" "$MCP_DEST.bak-qa-e2e-pilot"
    jq -s '.[0] * .[1]' "$MCP_DEST" "$SNIPPET" > "$MCP_DEST.tmp-qa-e2e-pilot" && mv "$MCP_DEST.tmp-qa-e2e-pilot" "$MCP_DEST"
    echo "Merged qa-e2e-pilot's playwright-qa MCP server into existing $MCP_DEST (jq; backup at $MCP_DEST.bak-qa-e2e-pilot)."
  elif command -v python3 >/dev/null 2>&1; then
    cp "$MCP_DEST" "$MCP_DEST.bak-qa-e2e-pilot"
    python3 - "$MCP_DEST" "$SNIPPET" <<'PY'
import json, sys
dest, snippet = sys.argv[1], sys.argv[2]
existing = json.load(open(dest))
add = json.load(open(snippet))
existing.setdefault("mcpServers", {}).update(add["mcpServers"])
json.dump(existing, open(dest, "w"), indent=2)
PY
    echo "Merged qa-e2e-pilot's playwright-qa MCP server into existing $MCP_DEST (python3; backup at $MCP_DEST.bak-qa-e2e-pilot)."
  else
    echo "== No jq or python3 found; could not auto-merge. Merge this into $PROJ/.pi/mcp.json yourself:"
    cat "$SNIPPET"
  fi
else
  cp "$SNIPPET" "$MCP_DEST"
fi

bash "$ROOT/scripts/build-adapter.sh" pi
mkdir -p "$PROJ/.pi/agents/skills" "$PROJ/.pi/agents/docs/adr" "$PROJ/.pi/prompts"
cp -R "$ROOT/dist/pi/skills/." "$PROJ/.pi/agents/skills/"
# the persona (see core/persona-body.md) instructs the agent to read CONTEXT.md and docs/adr/ —
# ship them alongside the installed skills so a project that has its own CONTEXT.md/docs at its
# root isn't collided with; see harnesses/pi/README.md for the resolution-path caveat.
cp "$ROOT/dist/pi/CONTEXT.md" "$PROJ/.pi/agents/CONTEXT.md"
cp -R "$ROOT/dist/pi/docs/adr/." "$PROJ/.pi/agents/docs/adr/"
cp "$ROOT/dist/pi/agent/qa-e2e-pilot.md" "$PROJ/.pi/agents/"
cp "$ROOT/dist/pi/commands/"*.md "$PROJ/.pi/prompts/"
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-e2e-pilot Pi adapter ($V) into $PROJ (.pi/ project-local)."
echo "Browser via pi-mcp-adapter proxy tool 'mcp'; server key playwright-qa."
echo "Grounding files (CONTEXT.md, docs/adr/) placed under $PROJ/.pi/agents/ alongside skills —"
echo "confirming the agent can read them is part of the manual accuracy-acceptance step (see"
echo "harnesses/pi/README.md and docs/harness-adapters.md)."
echo "Automatic enforcement floor: --save-session -> session-preflight -> qa-verify (high-confidence). Optional live-hook hardening: see harnesses/pi/hooks.md (verify on your build)."
