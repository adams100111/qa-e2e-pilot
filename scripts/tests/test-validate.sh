#!/usr/bin/env bash
# scripts/tests/test-validate.sh — TDD test for the deterministic CI gate.
set -euo pipefail
: "${TMPDIR:=/tmp}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"

bash scripts/validate-adapters.sh            # clean tree -> exit 0

# Negative control: a deliberate residual token must make it fail.
# Save/restore via cp (never git checkout — respects the no-destructive-git rule).
cp core/persona-body.md "$TMPDIR/persona-body.bak"
printf '\n{{OOPS}}\n' >> core/persona-body.md
if bash scripts/validate-adapters.sh >/dev/null 2>&1; then
  cp "$TMPDIR/persona-body.bak" core/persona-body.md; echo "validate did NOT catch residual token"; exit 1
fi
cp "$TMPDIR/persona-body.bak" core/persona-body.md
echo "OK"
