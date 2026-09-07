#!/usr/bin/env bash
# tests/validate-adapters/run.sh — thin wrapper enrolling
# scripts/tests/test-validate.sh (the TDD self-test for
# scripts/validate-adapters.sh: clean tree -> exit 0, plus two negative
# controls -- a residual {{token}} and a dirtied byte-oracle file must each
# make the gate fail) into scripts/run-engine-ci.sh.
#
# NOT invoked from validate-adapters.sh itself: test-validate.sh shells out
# to `bash scripts/validate-adapters.sh`, so calling it FROM
# validate-adapters.sh would recurse. This wrapper is the suite
# check-suite-coverage.sh's scripts/tests/*.sh inventory expects for it
# (audit-2 W3-6).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$HERE/../.."
exec bash "$REPO/scripts/tests/test-validate.sh"
