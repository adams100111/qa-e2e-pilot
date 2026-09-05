#!/usr/bin/env bash
# Install the qa-kit Codex adapter into a project (project-local .codex/ + .agents/, never global).
# REQUIRES the qa-e2e-pilot ENGINE Codex adapter already installed — qa-kit's bare-name skill refs
# resolve against the engine's co-installed skills dir (codex's split layout: skills under
# .agents/skills/, agents under .codex/agents/). See ADR-0024 co-install contract.
# Install locations are READ from qa-kit/harness-profiles.qakit.json (no drift from the rendered dirs).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root (qa-kit/harnesses/codex -> 3 up)
QAKIT="$ROOT/qa-kit"
PROFILE="$QAKIT/harness-profiles.qakit.json"
PROJ="${1:?usage: install-codex.sh <project-dir>}"
field() { python3 -c "import json,sys;print(json.load(open('$PROFILE'))['harnesses']['codex'].get('$1',''))"; }
AGENT_DIR="$(field agentDir)"; CMD_DIR="$(field cmdDir)"; PLUGIN_ROOT="$(field pluginRoot)"; SKILLS_DIR="$(field engineSkillsDir)"

[ -d "$PROJ/$SKILLS_DIR/detecting-stack-profile" ] || {
  echo "ERROR: engine Codex adapter not installed in $PROJ ($SKILLS_DIR absent) — run 'harnesses/codex/install-codex.sh $PROJ' first" >&2
  echo "       (qa-kit reuses the engine's skills; it never vendors them)" >&2
  exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" codex
mkdir -p "$PROJ/$AGENT_DIR" "$PROJ/$CMD_DIR" "$PROJ/$PLUGIN_ROOT/scripts" "$PROJ/$PLUGIN_ROOT/templates"
cp "$QAKIT/dist/codex/agent/qa-kit.toml" "$PROJ/$AGENT_DIR/"
cp "$QAKIT/dist/codex/commands/"*.md "$PROJ/$CMD_DIR/"
cp -R "$QAKIT/dist/codex/scripts/." "$PROJ/$PLUGIN_ROOT/scripts/"
cp -R "$QAKIT/dist/codex/templates/." "$PROJ/$PLUGIN_ROOT/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit Codex adapter ($V) into $PROJ."
echo "  agent -> $AGENT_DIR/qa-kit.toml ; step prompts -> $CMD_DIR/ ; qa-kit scripts -> $PLUGIN_ROOT/ ({{PLUGIN_ROOT}})."
echo "  Skill refs resolve to the engine's $SKILLS_DIR/. Verify with a manual accuracy run (see README)."
