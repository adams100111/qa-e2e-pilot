#!/usr/bin/env bash
# Install the qa-kit opencode adapter into a project (project-local .opencode/, never global).
# REQUIRES (1) the qa-e2e-pilot ENGINE opencode adapter already installed — qa-kit's skill refs
# resolve against the engine's co-installed .opencode/skills/; and (2) the community 'opencode-skills'
# plugin enabled in opencode.json (it exposes each SKILL.md as a skills_<name> tool — without it the
# skills are inert documents). See ADR-0024 co-install contract.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root (qa-kit/harnesses/opencode -> 3 up)
QAKIT="$ROOT/qa-kit"
PROJ="${1:?usage: install-opencode.sh <project-dir>}"
[ -d "$PROJ/.opencode/skills/detecting-stack-profile" ] || {
  echo "ERROR: engine opencode adapter not installed in $PROJ — run 'harnesses/opencode/install-opencode.sh $PROJ' first" >&2
  echo "       (qa-kit reuses the engine's skills at .opencode/skills/; it never vendors them)" >&2
  exit 1; }
bash "$QAKIT/scripts/build-qakit-adapter.sh" opencode
mkdir -p "$PROJ/.opencode/agent" "$PROJ/.opencode/command" "$PROJ/.opencode/qa-kit/scripts" "$PROJ/.opencode/qa-kit/templates"
cp "$QAKIT/dist/opencode/agent/qa-kit.md" "$PROJ/.opencode/agent/"
cp "$QAKIT/dist/opencode/commands/"*.md "$PROJ/.opencode/command/"
cp -R "$QAKIT/dist/opencode/scripts/." "$PROJ/.opencode/qa-kit/scripts/"
cp -R "$QAKIT/dist/opencode/templates/." "$PROJ/.opencode/qa-kit/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit opencode adapter ($V) into $PROJ."
echo "  agent -> .opencode/agent/qa-kit.md ; step commands -> .opencode/command/ ; qa-kit scripts -> .opencode/qa-kit/ ({{PLUGIN_ROOT}})."
echo "  REQUIRES the 'opencode-skills' plugin enabled in opencode.json (else skills_<name> tools are inert)."
echo "  Skill refs resolve to the engine's .opencode/skills/. Verify with a manual accuracy run (see README)."
