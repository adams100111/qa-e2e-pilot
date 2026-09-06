#!/usr/bin/env bash
# One command to gate the ENGINE's self-contained test suites. THIS list is the single source of
# truth — CI (.github/workflows/adapters.yml) calls this script, so adding a suite here enrolls it,
# and developers get a one-command local gate. Mirrors qa-kit/scripts/run-qakit-ci.sh.
#
# A blanket tests/*/run.sh glob is NOT used: some suites need a live browser/app, and two are
# currently RED on a clean tree. Enrolled below = every non-qa-kit suite that passed standalone under
# `timeout 90` (probed 2026-09-06). Excluded, with reasons:
#   qa-reconcile — FAILS on a clean tree (state-machine "illegal edge: act_intent requires a prior
#                  criterion_started"; journal not written). Pre-existing on main@147e5a9 — a latent
#                  bug this CI gap was hiding. Fix separately, then enroll.
#   rebake       — FAILS on a clean tree for the same reconcile/journal reason (its classify half is
#                  green; the reconcile half errors). Pre-existing on main@147e5a9. Fix, then enroll.
# (The qa-kit suites are gated separately by qa-kit/scripts/run-qakit-ci.sh.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES=(
  action-trace block-hook capture-hook checkpoint critic-coverage detect-stack fold frontier
  init-config interaction-ux journal journal-emit journal-merge mutation-flag persona-identity
  portability provenance qa-ci-verify qa-resume qa-verify qa-verify-phase required-kinds
  resume-idempotency session-preflight session-to-toolstream state-machine toolstream
  ux-adjudicate ux-conventions ux-detectors validate-checklist-json vision-binding
  write-persona-config
)
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  bash "$ROOT/tests/$d/run.sh"
done
echo "run-engine-ci: all green"
