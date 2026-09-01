#!/usr/bin/env bash
# Install the qa-e2e-pilot Codex adapter into a project. Never mutates global ~/.codex.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJ="${1:?usage: install-codex.sh <project-dir>}"
bash "$ROOT/scripts/build-adapter.sh" codex
mkdir -p "$PROJ/.agents/skills" "$PROJ/.codex/agents" "$PROJ/.codex/prompts"
cp -R "$ROOT/dist/codex/skills/." "$PROJ/.agents/skills/"
cp "$ROOT/dist/codex/agent/qa-e2e-pilot.toml" "$PROJ/.codex/agents/"
cp "$ROOT/dist/codex/commands/qa-run.md"   "$PROJ/.codex/prompts/qa-run.md"
cp "$ROOT/dist/codex/commands/qa-roles.md" "$PROJ/.codex/prompts/qa-roles.md"
echo "== Add this to $PROJ/.codex/config.toml (project-local; do not edit ~/.codex/config.toml):"
cat "$ROOT/dist/codex/mcp.snippet"
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-e2e-pilot Codex adapter ($V) into $PROJ"
