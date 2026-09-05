#!/usr/bin/env bash
# validate-qakit-adapters.sh — CI gate for qa-kit's multi-harness adapters (ADR-0024), mirroring
# scripts/validate-adapters.sh. Builds all four adapters, enforces the Claude BYTE-ORACLE (the committed
# qa-kit/commands + qa-kit/agents/qa-kit.md must equal `build-qakit-adapter.sh claude` output), and fails
# on any residual {{token}} in a rendered agent/commands tree. Never touches the engine.
set -euo pipefail
QAKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$QAKIT/scripts/build-qakit-adapter.sh"

for h in claude pi codex opencode; do bash "$B" "$h" >/dev/null; done

# Claude byte-oracle: committed == generated (commands + agent)
if ! diff -rq "$QAKIT/commands" "$QAKIT/dist/claude/commands" >/dev/null; then
  echo "byte-oracle FAIL: qa-kit/commands drift from generated dist/claude/commands" >&2
  diff -ru "$QAKIT/commands" "$QAKIT/dist/claude/commands" >&2 || true
  exit 1
fi
if ! diff -q "$QAKIT/agents/qa-kit.md" "$QAKIT/dist/claude/agent/qa-kit.md" >/dev/null; then
  echo "byte-oracle FAIL: qa-kit/agents/qa-kit.md drift from generated dist/claude/agent/qa-kit.md" >&2
  exit 1
fi

# no residual tokens in any rendered agent/commands
if grep -rn '{{' "$QAKIT"/dist/*/agent "$QAKIT"/dist/*/commands 2>/dev/null; then
  echo "FAIL: unrendered {{token}} above" >&2; exit 1
fi

echo "validate-qakit-adapters: OK"
