#!/usr/bin/env bash
# install.sh — manual fallback installer for qa-e2e-pilot.
# Symlinks the agent, the /qa-run command, and all skills into ~/.claude so Claude
# Code discovers them without going through the plugin marketplace or npx installer.
#
# Usage:   bash scripts/install.sh [--uninstall] [--copy]
#   --uninstall   remove the symlinks/copies this script created
#   --copy        copy files instead of symlinking (use when ~/.claude is on a
#                 filesystem that doesn't support symlinks)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MODE="link"
ACTION="install"

for arg in "$@"; do
  case "$arg" in
    --uninstall) ACTION="uninstall" ;;
    --copy) MODE="copy" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

link_one() {
  # link_one <src-abs> <dest-abs>
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ "$ACTION" = "uninstall" ]; then
    if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest"; echo "removed  $dest"; fi
    return
  fi
  rm -rf "$dest"
  if [ "$MODE" = "copy" ]; then cp -R "$src" "$dest"; echo "copied   $dest"; else ln -s "$src" "$dest"; echo "linked   $dest -> $src"; fi
}

echo "qa-e2e-pilot installer ($ACTION, mode=$MODE)"
echo "  repo:   $REPO_ROOT"
echo "  target: $CLAUDE_DIR"
echo

# Agent
link_one "$REPO_ROOT/agents/qa-e2e-pilot.md" "$CLAUDE_DIR/agents/qa-e2e-pilot.md"

# Command
link_one "$REPO_ROOT/commands/qa-run.md" "$CLAUDE_DIR/commands/qa-run.md"
link_one "$REPO_ROOT/commands/qa-roles.md" "$CLAUDE_DIR/commands/qa-roles.md"

# Skills (one symlink per skill directory)
for skill_dir in "$REPO_ROOT"/skills/*/; do
  name="$(basename "$skill_dir")"
  link_one "${skill_dir%/}" "$CLAUDE_DIR/skills/$name"
done

echo
if [ "$ACTION" = "install" ]; then
  echo "Done. Restart Claude Code (or run /agents) to pick up the agent, /qa-run command, and skills."
else
  echo "Uninstalled qa-e2e-pilot from $CLAUDE_DIR."
fi
