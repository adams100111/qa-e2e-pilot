#!/usr/bin/env bash
# Install the qa-kit Pi adapter into a project (project-local .pi/, never global ~/.pi).
# REQUIRES the qa-e2e-pilot ENGINE Pi adapter already installed — qa-kit's bare-name skill refs
# resolve against the engine's co-installed .pi/agents/skills/ (see ADR-0024 co-install contract).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root (qa-kit/harnesses/pi -> 3 up)
QAKIT="$ROOT/qa-kit"
PROJ="${1:?usage: install-pi.sh <project-dir>}"
[ -d "$PROJ/.pi/agents/skills/detecting-stack-profile" ] || {
  echo "ERROR: engine Pi adapter not installed in $PROJ — run 'harnesses/pi/install-pi.sh $PROJ' first" >&2
  echo "       (qa-kit reuses the engine's skills at .pi/agents/skills/; it never vendors them)" >&2
  exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" pi
mkdir -p "$PROJ/.pi/prompts" "$PROJ/.pi/agents" "$PROJ/.pi/qa-kit/scripts" "$PROJ/.pi/qa-kit/templates"
cp "$QAKIT/dist/pi/agent/qa-kit.md" "$PROJ/.pi/agents/"
cp "$QAKIT/dist/pi/commands/"*.md "$PROJ/.pi/prompts/"
cp -R "$QAKIT/dist/pi/scripts/." "$PROJ/.pi/qa-kit/scripts/"
cp -R "$QAKIT/dist/pi/templates/." "$PROJ/.pi/qa-kit/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit Pi adapter ($V) into $PROJ (.pi/ project-local)."
echo "  agent -> .pi/agents/qa-kit.md ; step prompts -> .pi/prompts/ ; qa-kit scripts -> .pi/qa-kit/ ({{PLUGIN_ROOT}})."
echo "  Skill refs resolve to the engine's .pi/agents/skills/. Verify with a manual accuracy run (see README)."
