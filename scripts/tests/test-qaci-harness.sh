#!/usr/bin/env bash
# test-qaci-harness.sh — qa-ci.sh picks its default agent command from harness-profiles.json,
# keyed by QA_HARNESS (defaulting to "claude"), still overridable by QA_AGENT_CMD.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
# With QA_HARNESS=codex and no QA_AGENT_CMD, the resolved default must be codex's profile agentCmd.
out="$(QA_HARNESS=codex QA_PRINT_AGENT_CMD=1 bash scripts/qa-ci.sh 2>/dev/null || true)"
echo "$out" | grep -q 'codex exec'
out2="$(QA_HARNESS=claude QA_PRINT_AGENT_CMD=1 bash scripts/qa-ci.sh 2>/dev/null || true)"
echo "$out2" | grep -q 'claude -p'
echo "OK"
