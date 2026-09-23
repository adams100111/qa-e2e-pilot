#!/usr/bin/env bash
# One command to gate qa-kit: the multi-harness byte-oracle + every qa-kit dual-engine suite.
# THIS list is the single source of truth — CI (.github/workflows/adapters.yml) calls this script, so adding
# a qa-kit suite here enrolls it in CI automatically, and developers get a one-command local gate.
# A blanket tests/*/run.sh glob is deliberately NOT used: the full corpus includes slow/engine suites that
# hang without a live app (measured: 2-min timeout) — see docs/doc-sync-todo.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# `data-baseline` and `qa-kit-enforcement` are enrolled here and NOWHERE else: this list and
# scripts/run-engine-ci.sh's are SEPARATE, and check-suite-coverage.sh rejects a suite that appears
# in both. The error-honesty work added no qa-kit suite, so nothing was appended below.
SUITES=(constitution spec-snapshot qa-kit-enforcement runconfig-merge data-baseline
        check-fixtures detect-seed auto-seed qa-kit-phases qakit-adapters qakit-install)

# SELF-CHECK on the enrolment surface, mirroring scripts/run-engine-ci.sh: check-suite-coverage.sh
# reads this array into a python SET, so a name listed TWICE is invisible to it. Checked here.
dupes="$(printf '%s\n' "${SUITES[@]}" | sort | uniq -d | tr '\n' ' ')"
if [ -n "${dupes% }" ]; then
  echo "run-qakit-ci: DUPLICATE entries in SUITES: ${dupes% }" >&2
  exit 2
fi

bash "$ROOT/qa-kit/scripts/validate-qakit-adapters.sh"
# 120s per-suite hang backstop (coreutils timeout; runaway -> exit 124, CI fails
# loudly rather than stalling). Mirrors scripts/run-engine-ci.sh.
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  timeout 120 bash "$ROOT/tests/$d/run.sh" || {
    rc=$?; [ "$rc" -eq 124 ] && echo "TIMEOUT: tests/$d exceeded 120s" >&2; exit "$rc";
  }
done
echo "run-qakit-ci: all green"
