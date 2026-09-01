#!/usr/bin/env bash
# check-prereqs.sh — SessionStart preflight for qa-e2e-pilot.
#
# Checks the environment prerequisites this plugin needs (Node, a JSON tool,
# bash, curl). The Playwright MCP server is provided by the official `playwright`
# Claude Code plugin (or a user-configured playwright server), not bundled here,
# and is wired/managed by the plugin system, so it is not checked here. The plugin's
# visual-UX detection is dependency-free (no axe-core / no npm deps), so
# there is nothing to `npm install` and nothing to check for that.
#
# exit 2 = block the session with a fix message; exit 0 = proceed.
set -u
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
missing=()

command -v node >/dev/null 2>&1 || missing+=("Node.js (node) — needed to run bundled browser-context scripts")
command -v bash >/dev/null 2>&1 || missing+=("bash — needed to run the plugin's scripts/*.sh")
command -v curl >/dev/null 2>&1 || missing+=("curl — needed by memory-sync.sh and preflight app-liveness checks")

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  missing+=("jq OR python3 — needed by checkpoint.sh/preflight.sh/report-to-junit.sh")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "qa-e2e-pilot: missing prerequisites:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo "Install the above, then reload the plugin." >&2
  exit 2
fi

exit 0
