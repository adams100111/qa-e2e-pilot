#!/usr/bin/env bash
# Shared qa-kit install flow. SOURCED by qa-kit/harnesses/<h>/install-<h>.sh, which sets HARNESS first.
# All install locations are READ from the profile (QAKIT_PROFILE overrides the committed default, for tests),
# so they cannot drift from the {{PLUGIN_ROOT}}/agent/command dirs the generator rendered into the commands.
# REQUIRES the qa-e2e-pilot ENGINE adapter for HARNESS already installed (its skills feed qa-kit's bare-name
# refs); each install aborts if the engine skills dir is absent — ADR-0024 co-install contract.
set -euo pipefail
: "${HARNESS:?_install-common.sh: caller must set HARNESS}"
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # qa-kit/harnesses
QAKIT="$(cd "$COMMON_DIR/.." && pwd)"                            # qa-kit
ROOT="$(cd "$QAKIT/.." && pwd)"                                  # repo root
PROFILE="${QAKIT_PROFILE:-$QAKIT/harness-profiles.qakit.json}"
PROJ="${1:?usage: $0 <project-dir>}"                             # $0 = the wrapper (source keeps it)

field() {
  python3 -c "
import json,sys
try:
    print(json.load(open('$PROFILE'))['harnesses']['$HARNESS']['$1'])
except KeyError:
    sys.stderr.write('ERROR: missing harnesses.$HARNESS.$1 in $PROFILE\n'); sys.exit(1)"
}
AGENT_DIR="$(field agentDir)"         || exit 1
CMD_DIR="$(field cmdDir)"             || exit 1
PLUGIN_ROOT="$(field pluginRoot)"     || exit 1
SKILLS_DIR="$(field engineSkillsDir)" || exit 1
AGENT_EXT="$(field agentExt)"         || exit 1

[ -d "$PROJ/$SKILLS_DIR/detecting-stack-profile" ] || {
  echo "ERROR: engine $HARNESS adapter not installed in $PROJ ($SKILLS_DIR absent) — run harnesses/$HARNESS/install-$HARNESS.sh first" >&2
  echo "       (qa-kit reuses the engine's skills; it never vendors them)" >&2
  exit 1; }

bash "$QAKIT/scripts/build-qakit-adapter.sh" "$HARNESS"
mkdir -p "$PROJ/$AGENT_DIR" "$PROJ/$CMD_DIR" "$PROJ/$PLUGIN_ROOT/scripts" "$PROJ/$PLUGIN_ROOT/templates"
cp "$QAKIT/dist/$HARNESS/agent/qa-kit.$AGENT_EXT" "$PROJ/$AGENT_DIR/"
cp "$QAKIT/dist/$HARNESS/commands/"*.md "$PROJ/$CMD_DIR/"
cp -R "$QAKIT/dist/$HARNESS/scripts/." "$PROJ/$PLUGIN_ROOT/scripts/"
cp -R "$QAKIT/dist/$HARNESS/templates/." "$PROJ/$PLUGIN_ROOT/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit $HARNESS adapter ($V) into $PROJ."
echo "  agent -> $AGENT_DIR/qa-kit.$AGENT_EXT ; step commands -> $CMD_DIR/ ; qa-kit scripts -> $PLUGIN_ROOT/ ({{PLUGIN_ROOT}})."
[ "$HARNESS" = opencode ] && echo "  REQUIRES the 'opencode-skills' plugin enabled in opencode.json (else skills_<name> tools are inert)."
echo "  Skill refs resolve to the engine's $SKILLS_DIR/. Verify with a manual accuracy run (see README)."
