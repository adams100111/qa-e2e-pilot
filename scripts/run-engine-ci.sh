#!/usr/bin/env bash
# One command to gate the ENGINE's self-contained test suites. THIS list is the single source of
# truth — CI (.github/workflows/adapters.yml) calls this script, so adding a suite here enrolls it,
# and developers get a one-command local gate. Mirrors qa-kit/scripts/run-qakit-ci.sh.
#
# A blanket tests/*/run.sh glob is NOT used: some suites need a live browser/app. Enrolled below =
# every non-qa-kit suite that passes standalone under `timeout 90`. (The qa-kit suites are gated
# separately by qa-kit/scripts/run-qakit-ci.sh.) All 35 self-contained engine suites are enrolled —
# rebake + qa-reconcile were RED on main@147e5a9 (their act_intent/act_committed emissions predated
# the FSM guard's criterion_started requirement) and were fixed in the audit-remediation branch.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES=(
  action-trace block-hook capture-hook checkpoint critic-coverage detect-stack fold frontier
  init-config interaction-ux journal journal-emit journal-merge mutation-flag persona-identity
  portability provenance qa-ci-verify qa-reconcile qa-resume qa-verify qa-verify-phase rebake
  required-kinds resume-idempotency session-preflight session-to-toolstream state-machine toolstream
  ux-adjudicate ux-conventions ux-detectors validate-checklist-json vision-binding
  write-persona-config
)
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  bash "$ROOT/tests/$d/run.sh"
done
echo "run-engine-ci: all green"
