#!/usr/bin/env bash
# Install the qa-kit Codex adapter into a project (project-local .codex/ + .agents/, never global).
# REQUIRES the qa-e2e-pilot ENGINE Codex adapter already installed — qa-kit's bare-name skill refs
# resolve against the engine's co-installed .agents/skills/ (codex's split layout: skills under
# .agents/skills/, agents under .codex/agents/). See ADR-0024 co-install contract.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root (qa-kit/harnesses/codex -> 3 up)
QAKIT="$ROOT/qa-kit"
PROJ="${1:?usage: install-codex.sh <project-dir>}"
[ -d "$PROJ/.agents/skills/detecting-stack-profile" ] || {
  echo "ERROR: engine Codex adapter not installed in $PROJ — run 'harnesses/codex/install-codex.sh $PROJ' first" >&2
  echo "       (qa-kit reuses the engine's skills at .agents/skills/; it never vendors them)" >&2
  exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" codex
mkdir -p "$PROJ/.codex/agents" "$PROJ/.codex/prompts" "$PROJ/.codex/qa-kit/scripts" "$PROJ/.codex/qa-kit/templates"
cp "$QAKIT/dist/codex/agent/qa-kit.toml" "$PROJ/.codex/agents/"
cp "$QAKIT/dist/codex/commands/"*.md "$PROJ/.codex/prompts/"
cp -R "$QAKIT/dist/codex/scripts/." "$PROJ/.codex/qa-kit/scripts/"
cp -R "$QAKIT/dist/codex/templates/." "$PROJ/.codex/qa-kit/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit Codex adapter ($V) into $PROJ."
echo "  agent -> .codex/agents/qa-kit.toml ; step prompts -> .codex/prompts/ ; qa-kit scripts -> .codex/qa-kit/ ({{PLUGIN_ROOT}})."
echo "  Skill refs resolve to the engine's .agents/skills/. Verify with a manual accuracy run (see README)."
