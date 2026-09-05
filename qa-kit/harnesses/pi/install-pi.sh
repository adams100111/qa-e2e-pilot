#!/usr/bin/env bash
# Install the qa-kit Pi adapter into a project (project-local .pi/, never global ~/.pi).
# REQUIRES the qa-e2e-pilot ENGINE Pi adapter already installed — qa-kit's bare-name skill refs
# resolve against the engine's co-installed skills dir (see ADR-0024 co-install contract).
# All install locations are READ from qa-kit/harness-profiles.qakit.json so they cannot drift from
# the {{PLUGIN_ROOT}}/agent/command dirs the generator rendered into the commands.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root (qa-kit/harnesses/pi -> 3 up)
QAKIT="$ROOT/qa-kit"
PROFILE="$QAKIT/harness-profiles.qakit.json"
PROJ="${1:?usage: install-pi.sh <project-dir>}"
field() { python3 -c "import json,sys;print(json.load(open('$PROFILE'))['harnesses']['pi'].get('$1',''))"; }
AGENT_DIR="$(field agentDir)"; CMD_DIR="$(field cmdDir)"; PLUGIN_ROOT="$(field pluginRoot)"; SKILLS_DIR="$(field engineSkillsDir)"

[ -d "$PROJ/$SKILLS_DIR/detecting-stack-profile" ] || {
  echo "ERROR: engine Pi adapter not installed in $PROJ ($SKILLS_DIR absent) — run 'harnesses/pi/install-pi.sh $PROJ' first" >&2
  echo "       (qa-kit reuses the engine's skills; it never vendors them)" >&2
  exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" pi
mkdir -p "$PROJ/$CMD_DIR" "$PROJ/$AGENT_DIR" "$PROJ/$PLUGIN_ROOT/scripts" "$PROJ/$PLUGIN_ROOT/templates"
cp "$QAKIT/dist/pi/agent/qa-kit.md" "$PROJ/$AGENT_DIR/"
cp "$QAKIT/dist/pi/commands/"*.md "$PROJ/$CMD_DIR/"
cp -R "$QAKIT/dist/pi/scripts/." "$PROJ/$PLUGIN_ROOT/scripts/"
cp -R "$QAKIT/dist/pi/templates/." "$PROJ/$PLUGIN_ROOT/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit Pi adapter ($V) into $PROJ."
echo "  agent -> $AGENT_DIR/qa-kit.md ; step prompts -> $CMD_DIR/ ; qa-kit scripts -> $PLUGIN_ROOT/ ({{PLUGIN_ROOT}})."
echo "  Skill refs resolve to the engine's $SKILLS_DIR/. Verify with a manual accuracy run (see README)."
