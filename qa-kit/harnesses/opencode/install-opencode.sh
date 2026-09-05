#!/usr/bin/env bash
# Install the qa-kit opencode adapter into a project (project-local .opencode/, never global).
# REQUIRES (1) the qa-e2e-pilot ENGINE opencode adapter already installed — qa-kit's skill refs
# resolve against the engine's co-installed skills dir; and (2) the community 'opencode-skills'
# plugin enabled in opencode.json (it exposes each SKILL.md as a skills_<name> tool — without it the
# skills are inert documents). See ADR-0024 co-install contract.
# Install locations are READ from qa-kit/harness-profiles.qakit.json (no drift from the rendered dirs).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root (qa-kit/harnesses/opencode -> 3 up)
QAKIT="$ROOT/qa-kit"
PROFILE="$QAKIT/harness-profiles.qakit.json"
PROJ="${1:?usage: install-opencode.sh <project-dir>}"
field() { python3 -c "import json,sys;print(json.load(open('$PROFILE'))['harnesses']['opencode'].get('$1',''))"; }
AGENT_DIR="$(field agentDir)"; CMD_DIR="$(field cmdDir)"; PLUGIN_ROOT="$(field pluginRoot)"; SKILLS_DIR="$(field engineSkillsDir)"

[ -d "$PROJ/$SKILLS_DIR/detecting-stack-profile" ] || {
  echo "ERROR: engine opencode adapter not installed in $PROJ ($SKILLS_DIR absent) — run 'harnesses/opencode/install-opencode.sh $PROJ' first" >&2
  echo "       (qa-kit reuses the engine's skills; it never vendors them)" >&2
  exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" opencode
mkdir -p "$PROJ/$AGENT_DIR" "$PROJ/$CMD_DIR" "$PROJ/$PLUGIN_ROOT/scripts" "$PROJ/$PLUGIN_ROOT/templates"
cp "$QAKIT/dist/opencode/agent/qa-kit.md" "$PROJ/$AGENT_DIR/"
cp "$QAKIT/dist/opencode/commands/"*.md "$PROJ/$CMD_DIR/"
cp -R "$QAKIT/dist/opencode/scripts/." "$PROJ/$PLUGIN_ROOT/scripts/"
cp -R "$QAKIT/dist/opencode/templates/." "$PROJ/$PLUGIN_ROOT/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit opencode adapter ($V) into $PROJ."
echo "  agent -> $AGENT_DIR/qa-kit.md ; step commands -> $CMD_DIR/ ; qa-kit scripts -> $PLUGIN_ROOT/ ({{PLUGIN_ROOT}})."
echo "  REQUIRES the 'opencode-skills' plugin enabled in opencode.json (else skills_<name> tools are inert)."
echo "  Skill refs resolve to the engine's $SKILLS_DIR/. Verify with a manual accuracy run (see README)."
