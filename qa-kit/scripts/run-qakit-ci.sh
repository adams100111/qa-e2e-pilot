#!/usr/bin/env bash
# One command to gate qa-kit: the multi-harness byte-oracle + every qa-kit dual-engine suite.
# THIS list is the single source of truth — CI (.github/workflows/adapters.yml) calls this script, so adding
# a qa-kit suite here enrolls it in CI automatically, and developers get a one-command local gate.
# A blanket tests/*/run.sh glob is deliberately NOT used: the full corpus includes slow/engine suites that
# hang without a live app (measured: 2-min timeout) — see docs/doc-sync-todo.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITES=(constitution spec-snapshot qa-kit-enforcement runconfig-merge data-baseline
        check-fixtures detect-seed auto-seed qa-kit-phases qakit-adapters qakit-install)
bash "$ROOT/qa-kit/scripts/validate-qakit-adapters.sh"
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  bash "$ROOT/tests/$d/run.sh"
done
echo "run-qakit-ci: all green"
