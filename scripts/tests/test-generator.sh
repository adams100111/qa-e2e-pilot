#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
bash scripts/build-adapter.sh claude
# Oracle: generated Claude agent + commands equal the committed repo-root files.
diff -u agents/qa-e2e-pilot.md dist/claude/agent/qa-e2e-pilot.md
diff -u commands/qa-run.md     dist/claude/commands/qa-run.md
diff -u commands/qa-roles.md   dist/claude/commands/qa-roles.md
for h in codex pi opencode; do
  bash scripts/build-adapter.sh "$h"
  # No unrendered tokens in the harness's rendered output (agent manifest + commands).
  # (skills/scripts/docs/tools are copied verbatim and may contain unrelated {{...}} —
  # e.g. writing-qa-reports' own runtime report-template tokens.)
  if grep -rn '{{' "dist/$h/agent" "dist/$h/commands" ; then echo "residual token in dist/$h"; exit 1; fi
done
echo "OK"
