#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test -f "$root/core/persona-body.md"
test -f "$root/core/commands/qa-run.md"
test -f "$root/core/commands/qa-roles.md"
grep -q '{{TIER_HEAVY}}'   "$root/core/persona-body.md"
grep -q '{{TIER_DEFAULT}}' "$root/core/persona-body.md"
grep -q '{{DISPATCH}}'         "$root/core/commands/qa-run.md"
grep -q '{{GLOBAL_ROLES_DIR}}' "$root/core/commands/qa-roles.md"
# The persona body must NOT carry a hard model id or the old frontmatter
! grep -qiE '\bUse Opus\b' "$root/core/persona-body.md"
! grep -q '^---$' "$root/core/persona-body.md"   # frontmatter stays in the manifest.tmpl, not the body
echo "OK"
