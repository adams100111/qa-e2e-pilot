#!/usr/bin/env bash
# Install the qa-e2e-pilot Pi adapter into a project. Uses project-local .pi/, never global ~/.pi.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="${1:?usage: install-pi.sh <project-dir>}"
bash "$ROOT/scripts/build-adapter.sh" pi
mkdir -p "$PROJ/.pi/agents/skills" "$PROJ/.pi/agents" "$PROJ/.pi/prompts"
cp -R "$ROOT/dist/pi/skills/." "$PROJ/.pi/agents/skills/"
cp "$ROOT/dist/pi/agent/qa-e2e-pilot.md" "$PROJ/.pi/agents/"
cp "$ROOT/dist/pi/commands/qa-run.md"   "$PROJ/.pi/prompts/qa-run.md"
cp "$ROOT/dist/pi/commands/qa-roles.md" "$PROJ/.pi/prompts/qa-roles.md"
cp "$ROOT/dist/pi/mcp.snippet" "$PROJ/.pi/mcp.json"
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-e2e-pilot Pi adapter ($V) into $PROJ (.pi/ project-local)."
echo "Browser via pi-mcp-adapter proxy tool 'mcp'; server key playwright-qa."
