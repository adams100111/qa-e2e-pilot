#!/usr/bin/env bash
# MCP-isolated wrapper around the real `claude` CLI, for use as SkillOpt's
# CLAUDE_CODE_EXEC_PATH when target/optimizer backend = claude_code_exec.
#
# Why: a headless `claude -p` run loads the user's configured MCP servers and
# sends every server's tool schema to the Anthropic API. If ANY connected
# server (e.g. a claude.ai connector) exposes a tool whose input_schema
# property key violates Anthropic's '^[a-zA-Z0-9_.-]{1,64}$' rule, the API
# rejects the whole request with HTTP 400 and the rollout produces no output.
# The stack-profile target only needs Read/Bash to inspect the fixture, so we
# force a clean MCP config (zero servers) to make runs hermetic + reproducible.
#
# Opt out (use your ambient MCP config) with SKILLOPT_CLAUDE_ALLOW_MCP=1.
set -euo pipefail

# Resolve the real claude binary, skipping this wrapper (any name/dir).
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
real=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  [ "$(readlink -f "$cand" 2>/dev/null || echo "$cand")" = "$self" ] && continue
  real="$cand"; break
done < <(type -aP claude 2>/dev/null || true)

if [ -z "$real" ]; then
  echo "claude-clean.sh: real 'claude' CLI not found on PATH" >&2
  exit 127
fi

if [ "${SKILLOPT_CLAUDE_ALLOW_MCP:-0}" = "1" ]; then
  exec "$real" "$@"
fi
exec "$real" --strict-mcp-config --mcp-config '{"mcpServers":{}}' "$@"
