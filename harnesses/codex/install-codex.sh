#!/usr/bin/env bash
# Install the qa-e2e-pilot Codex adapter into a project. Never mutates global ~/.codex.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="${1:?usage: install-codex.sh <project-dir>}"
bash "$ROOT/scripts/build-adapter.sh" codex
mkdir -p "$PROJ/.agents/skills" "$PROJ/.agents/docs/adr" "$PROJ/.codex/agents" "$PROJ/.codex/prompts"
cp -R "$ROOT/dist/codex/skills/." "$PROJ/.agents/skills/"
# the persona (see core/persona-body.md) instructs the agent to read CONTEXT.md and docs/adr/ —
# ship them alongside the installed skills so a project that has its own CONTEXT.md/docs at its
# root isn't collided with; see harnesses/codex/README.md for the resolution-path caveat.
cp "$ROOT/dist/codex/CONTEXT.md" "$PROJ/.agents/CONTEXT.md"
cp -R "$ROOT/dist/codex/docs/adr/." "$PROJ/.agents/docs/adr/"
cp "$ROOT/dist/codex/agent/qa-e2e-pilot.toml" "$PROJ/.codex/agents/"
cp "$ROOT/dist/codex/commands/qa-run.md"   "$PROJ/.codex/prompts/qa-run.md"
cp "$ROOT/dist/codex/commands/qa-roles.md" "$PROJ/.codex/prompts/qa-roles.md"
echo "== Add this to $PROJ/.codex/config.toml (project-local; do not edit ~/.codex/config.toml):"
cat "$ROOT/dist/codex/mcp.snippet"
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-e2e-pilot Codex adapter ($V) into $PROJ"
echo "Grounding files (CONTEXT.md, docs/adr/) placed under $PROJ/.agents/ alongside skills —"
echo "confirming the agent can read them is part of the manual accuracy-acceptance step (see"
echo "harnesses/codex/README.md and docs/harness-adapters.md)."
echo "Automatic enforcement floor: --save-session -> session-preflight -> qa-verify (high-confidence). Optional live-hook hardening: see harnesses/codex/hooks.md (verify on your build)."
