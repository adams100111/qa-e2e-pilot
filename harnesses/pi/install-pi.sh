#!/usr/bin/env bash
# Install the qa-e2e-pilot Pi adapter into a project. Uses project-local .pi/, never global ~/.pi.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="${1:?usage: install-pi.sh <project-dir>}"
bash "$ROOT/scripts/build-adapter.sh" pi
mkdir -p "$PROJ/.pi/agents/skills" "$PROJ/.pi/agents/docs/adr" "$PROJ/.pi/prompts"
cp -R "$ROOT/dist/pi/skills/." "$PROJ/.pi/agents/skills/"
# the persona (see core/persona-body.md) instructs the agent to read CONTEXT.md and docs/adr/ —
# ship them alongside the installed skills so a project that has its own CONTEXT.md/docs at its
# root isn't collided with; see harnesses/pi/README.md for the resolution-path caveat.
cp "$ROOT/dist/pi/CONTEXT.md" "$PROJ/.pi/agents/CONTEXT.md"
cp -R "$ROOT/dist/pi/docs/adr/." "$PROJ/.pi/agents/docs/adr/"
cp "$ROOT/dist/pi/agent/qa-e2e-pilot.md" "$PROJ/.pi/agents/"
cp "$ROOT/dist/pi/commands/qa-run.md"   "$PROJ/.pi/prompts/qa-run.md"
cp "$ROOT/dist/pi/commands/qa-roles.md" "$PROJ/.pi/prompts/qa-roles.md"
cp "$ROOT/dist/pi/mcp.snippet" "$PROJ/.pi/mcp.json"
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-e2e-pilot Pi adapter ($V) into $PROJ (.pi/ project-local)."
echo "Browser via pi-mcp-adapter proxy tool 'mcp'; server key playwright-qa."
echo "Grounding files (CONTEXT.md, docs/adr/) placed under $PROJ/.pi/agents/ alongside skills —"
echo "confirming the agent can read them is part of the manual accuracy-acceptance step (see"
echo "harnesses/pi/README.md and docs/harness-adapters.md)."
