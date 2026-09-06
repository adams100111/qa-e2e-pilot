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
# Each suite is self-contained and finishes in seconds; the 120s cap is a hang
# backstop (a runaway suite fails CI loudly with exit 124 instead of stalling the
# job until its global timeout). `timeout` is coreutils, present on the runner.
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  timeout 120 bash "$ROOT/tests/$d/run.sh" || {
    rc=$?; [ "$rc" -eq 124 ] && echo "TIMEOUT: tests/$d exceeded 120s" >&2; exit "$rc";
  }
done
echo "run-engine-ci: all green"
