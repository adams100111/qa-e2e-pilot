#!/usr/bin/env bash
# scripts/tests/test-validate.sh — TDD test for the deterministic CI gate.
set -euo pipefail
: "${TMPDIR:=/tmp}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"

bash scripts/validate-adapters.sh            # clean tree -> exit 0

# Save/restore via cp (never git checkout — respects the no-destructive-git rule).
# An EXIT trap guarantees both files are restored even if the script dies mid-mutation.
cp core/persona-body.md   "$TMPDIR/persona-body.bak"
cp agents/qa-e2e-pilot.md "$TMPDIR/agent.bak"
restore() { cp "$TMPDIR/persona-body.bak" core/persona-body.md 2>/dev/null || true
            cp "$TMPDIR/agent.bak" agents/qa-e2e-pilot.md 2>/dev/null || true; }
trap restore EXIT

# Negative control 1: a deliberate residual token must make the gate fail.
printf '\n{{OOPS}}\n' >> core/persona-body.md
if bash scripts/validate-adapters.sh >/dev/null 2>&1; then
  echo "validate did NOT catch residual token"; exit 1
fi
cp "$TMPDIR/persona-body.bak" core/persona-body.md

# Negative control 2: a dirtied repo-root Claude file must fail the byte-oracle.
printf '\n<!-- drift -->\n' >> agents/qa-e2e-pilot.md
if bash scripts/validate-adapters.sh >/dev/null 2>&1; then
  echo "validate did NOT catch byte-oracle drift"; exit 1
fi
cp "$TMPDIR/agent.bak" agents/qa-e2e-pilot.md
echo "OK"
