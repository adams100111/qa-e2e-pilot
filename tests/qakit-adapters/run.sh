#!/usr/bin/env bash
# Cross-harness render assertions for qa-kit's multi-harness adapters (ADR-0024, increment 7).
# Builds all 4 adapters and asserts: 6 commands + agent per harness with the right agent ext; skill refs
# rendered to each harness's convention; no residual tokens; the Claude byte-oracle; and every referenced
# engine skill exists under the engine's skills/<name>/ (the composition's one fragility).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$DIR/../.."
B="$REPO/qa-kit/scripts/build-qakit-adapter.sh"
D="$REPO/qa-kit/dist"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

for h in claude pi codex opencode; do bash "$B" "$h" >/dev/null || { echo "build $h failed"; exit 1; }; done

# (a) 6 commands + agent per harness, right agent ext
# (constitution, spec, scenarios, analyze, verify, status)
for h in claude pi codex opencode; do
  check "$h has 6 commands" "$(ls "$D/$h/commands" | wc -l | tr -d ' ')" "6"
done
check "claude agent md"   "$(ls "$D/claude/agent")"   "qa-kit.md"
check "pi agent md"       "$(ls "$D/pi/agent")"       "qa-kit.md"
check "codex agent toml"  "$(ls "$D/codex/agent")"    "qa-kit.toml"
check "opencode agent md" "$(ls "$D/opencode/agent")" "qa-kit.md"

# (b) skill refs render per harness (qa-spec references detecting-stack-profile)
check "claude slug"  "$(grep -c '/qa-e2e-pilot:detecting-stack-profile' "$D/claude/commands/qa-spec.md")" "$(grep -c '/qa-e2e-pilot:detecting-stack-profile' "$D/claude/commands/qa-spec.md")"
grep -q '/qa-e2e-pilot:detecting-stack-profile' "$D/claude/commands/qa-spec.md"       ; check "claude slug present"  "$?" "0"
grep -q 'the `detecting-stack-profile` skill'  "$D/pi/commands/qa-spec.md"            ; check "pi bare present"      "$?" "0"
grep -q 'the `detecting-stack-profile` skill'  "$D/codex/commands/qa-spec.md"         ; check "codex bare present"   "$?" "0"
grep -q 'the `skills_detecting-stack-profile` tool' "$D/opencode/commands/qa-spec.md" ; check "opencode tool present" "$?" "0"

# (c) plugin-root rendered per harness (no {{PLUGIN_ROOT}} left; correct prefix)
grep -q '${CLAUDE_PLUGIN_ROOT}/scripts' "$D/claude/commands/qa-spec.md" ; check "claude plugin-root" "$?" "0"
grep -q '.pi/qa-kit/scripts'            "$D/pi/commands/qa-spec.md"     ; check "pi plugin-root"     "$?" "0"
grep -q '.codex/qa-kit/scripts'         "$D/codex/commands/qa-spec.md"  ; check "codex plugin-root"  "$?" "0"
grep -q '.opencode/qa-kit/scripts'      "$D/opencode/commands/qa-spec.md"; check "opencode plugin-root" "$?" "0"

# (d0) the Claude-only qualified slug must not leak into non-Claude agent renders (persona
# skill-invocation instruction must speak each harness's dialect, not hardcode the Claude slug)
for h in pi codex opencode; do
  check "no /qa-e2e-pilot: literal in $h agent" "$(grep -c '/qa-e2e-pilot:' "$D/$h/agent/"* || true)" "0"
done
check "claude agent keeps the qualified slug" "$(grep -c '/qa-e2e-pilot:<skill>' "$D/claude/agent/qa-kit.md")" "1"

# (d) no residual tokens anywhere in rendered agent/commands
for h in claude pi codex opencode; do
  if grep -rq '{{' "$D/$h/commands" "$D/$h/agent"; then check "$h no residual" residual none; else check "$h no residual" none none; fi
done

# (e) Claude byte-oracle: committed == generated
diff -rq "$REPO/qa-kit/commands" "$D/claude/commands" >/dev/null; check "claude cmd byte-oracle" "$?" "0"
diff -q "$REPO/qa-kit/agents/qa-kit.md" "$D/claude/agent/qa-kit.md" >/dev/null; check "claude agent byte-oracle" "$?" "0"

# (f) every referenced engine skill exists (composition fragility guard)
for s in detecting-stack-profile ingesting-spec-kit discovering-user-roles confirming-discovered-roles fanning-out-criteria generating-qa-checklist analyzing-feature-ui; do
  check "engine skill $s exists" "$([ -d "$REPO/skills/$s" ] && echo y)" "y"
done

# (g) repo-dev-only tooling never ships into a harness's scripts payload (audit-2 W3-7b):
# run-qakit-ci.sh references $ROOT/tests/... paths that only exist inside this repo, so it
# would be a broken command in an installed user project.
for h in claude pi codex opencode; do
  check "$h scripts exclude run-qakit-ci.sh" "$([ -f "$D/$h/scripts/run-qakit-ci.sh" ] && echo present || echo absent)" "absent"
  check "$h scripts exclude build-qakit-adapter.sh" "$([ -f "$D/$h/scripts/build-qakit-adapter.sh" ] && echo present || echo absent)" "absent"
  check "$h scripts exclude validate-qakit-adapters.sh" "$([ -f "$D/$h/scripts/validate-qakit-adapters.sh" ] && echo present || echo absent)" "absent"
done

echo "qakit-adapters: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
