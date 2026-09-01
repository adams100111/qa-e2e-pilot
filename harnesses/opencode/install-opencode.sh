#!/usr/bin/env bash
# Install the qa-e2e-pilot opencode adapter into a project (.opencode/, project-local).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="${1:?usage: install-opencode.sh <project-dir>}"
bash "$ROOT/scripts/build-adapter.sh" opencode
mkdir -p "$PROJ/.opencode/agent" "$PROJ/.opencode/command" "$PROJ/.opencode/skills" "$PROJ/.opencode/docs/adr"
cp -R "$ROOT/dist/opencode/skills/." "$PROJ/.opencode/skills/"
# the persona (see core/persona-body.md) instructs the agent to read CONTEXT.md and docs/adr/ —
# ship them alongside the installed skills (not at the QA'd project's own root, to avoid
# colliding with that project's own CONTEXT.md/docs); see harnesses/opencode/README.md for the
# resolution-path caveat.
cp "$ROOT/dist/opencode/CONTEXT.md" "$PROJ/.opencode/CONTEXT.md"
cp -R "$ROOT/dist/opencode/docs/adr/." "$PROJ/.opencode/docs/adr/"
cp "$ROOT/dist/opencode/agent/qa-e2e-pilot.md" "$PROJ/.opencode/agent/"
cp "$ROOT/dist/opencode/commands/qa-run.md"   "$PROJ/.opencode/command/qa-run.md"
cp "$ROOT/dist/opencode/commands/qa-roles.md" "$PROJ/.opencode/command/qa-roles.md"
echo "== Merge this into $PROJ/opencode.json (mcp block + opencode-skills plugin):"
cat "$ROOT/dist/opencode/mcp.snippet"
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-e2e-pilot opencode adapter ($V) into $PROJ"
echo "Grounding files (CONTEXT.md, docs/adr/) placed under $PROJ/.opencode/ alongside skills —"
echo "confirming the agent can read them is part of the manual accuracy-acceptance step (see"
echo "harnesses/opencode/README.md and docs/harness-adapters.md)."
