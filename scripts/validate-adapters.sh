#!/usr/bin/env bash
# scripts/validate-adapters.sh — the deterministic CI gate (Q4 layer 1).
#
# Exits 0 iff:
#   1) the profile + core-source sanity tests pass,
#   2) all four adapters (claude, codex, pi, opencode) build cleanly,
#   3) the Claude build byte-matches the repo-root agent + commands (the "byte-oracle"),
#   4) no unrendered {{...}} tokens remain in any adapter's RENDERED output
#      (dist/*/agent + dist/*/commands — copied-verbatim skills/docs/scripts may
#      legitimately contain unrelated {{...}} runtime-report templates and are
#      deliberately NOT scanned here),
#   5) every capability in harness-profiles.json resolves to a prefixed tool name
#      in the Claude agent manifest (grantStyle:list is the only style with a
#      per-tool listing to check; codex/pi/opencode use server-scope/proxy/glob),
#   6) every core .sh/.js/.json file passes its static check (dist/ and .git/ excluded).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
fail(){ echo "FAIL: $*" >&2; exit 1; }

# 1) profiles + core-sources sanity
bash scripts/tests/test-profiles.sh >/dev/null || fail "profiles"
bash scripts/tests/test-core-sources.sh >/dev/null || fail "core sources"

# 2) build all four; byte-oracle for claude
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h" >/dev/null || fail "build $h"; done
diff -q agents/qa-e2e-pilot.md dist/claude/agent/qa-e2e-pilot.md >/dev/null || fail "claude agent oracle"
diff -q commands/qa-run.md     dist/claude/commands/qa-run.md     >/dev/null || fail "claude qa-run oracle"
diff -q commands/qa-roles.md   dist/claude/commands/qa-roles.md   >/dev/null || fail "claude qa-roles oracle"

# 3) no residual {{...}} tokens in RENDERED output only.
# NOTE: a blanket `grep -rn '{{' dist/` would false-positive — build-adapter.sh copies
# skills/scripts/docs/tools into dist/<h>/ verbatim (see build-adapter.sh's own comment),
# and some of those (e.g. writing-qa-reports' runtime report templates) legitimately
# contain {{...}} placeholders meant to be filled by the agent at run time, not by the
# build step. Scope the scan to what build-adapter.sh actually templates: agent/ + commands/.
if grep -rln '{{' dist/*/agent dist/*/commands 2>/dev/null; then fail "residual token in rendered output"; fi

# 4) every capability resolves to a prefixed tool for grantStyle:list (claude only —
# codex/pi/opencode use server-scope/proxy/glob and have no per-tool list to check)
python3 - <<'PY' || exit 1
import json
p=json.load(open('harness-profiles.json')); caps=p['capabilities']
agent=open('dist/claude/agent/qa-e2e-pilot.md').read()
pref=p['harnesses']['claude']['toolPrefix']
missing=[c for c in caps if pref+c not in agent]
assert not missing, f"claude agent missing tools: {missing}"
print("caps OK")
PY

# 5) static checks on every core script + json (skills/, scripts/, harnesses/ — the
# directories this multi-harness effort actually authored/modified; dist/ is build
# scratch and excluded from every sweep below).
find skills scripts harnesses -name '*.sh' -print0 | xargs -0 -I{} bash -n {} || fail "bash -n"
find skills scripts harnesses -name '*.js' -print0 | xargs -0 -I{} node --check {} || fail "node --check"
find . -name '*.json' -not -path './.git/*' -not -path './dist/*' -not -path './node_modules/*' -print0 \
  | xargs -0 -I{} python3 -c "import json,sys;json.load(open('{}'))" || fail "json"

echo "validate-adapters: OK"
