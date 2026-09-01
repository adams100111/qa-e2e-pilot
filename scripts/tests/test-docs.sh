#!/usr/bin/env bash
# scripts/tests/test-docs.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
test -f docs/adr/0017-multi-harness-portability.md
grep -qi 'sequential-only'  docs/adr/0017-multi-harness-portability.md
grep -qi 'playwright-qa'     docs/harness-adapters.md
grep -qi 'accuracy'          docs/harness-adapters.md          # the manual acceptance procedure
grep -q  'harness-profiles.json' README.md
grep -q  'harnesses/'        CLAUDE.md
echo "OK"
