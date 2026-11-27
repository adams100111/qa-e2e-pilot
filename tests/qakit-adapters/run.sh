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

# (a) 8 commands + agent per harness, right agent ext
# (constitution, spec, scenarios, analyze, verify, status, tracker, auto)
for h in claude pi codex opencode; do
  check "$h has 8 commands" "$(ls "$D/$h/commands" | wc -l | tr -d ' ')" "8"
done
check "claude agent md"   "$(ls "$D/claude/agent")"   "qa-kit.md"
check "pi agent md"       "$(ls "$D/pi/agent")"       "qa-kit.md"
check "codex agent toml"  "$(ls "$D/codex/agent")"    "qa-kit.toml"
check "opencode agent md" "$(ls "$D/opencode/agent")" "qa-kit.md"

# (b) skill refs render per harness (qa-spec references detecting-stack-profile)
# The expected occurrence count is derived independently of the rendered output:
# it's the number of {{SKILL_REF:detecting-stack-profile}} tokens in the CORE
# template (the un-rendered source), not a re-grep of the very file under test
# (that would be a tautology -- comparing a count to itself can never fail).
core_slug_count="$(grep -c '{{SKILL_REF:detecting-stack-profile}}' "$REPO/qa-kit/core/commands/qa-spec.md")"
check "claude slug count matches core template occurrences" \
  "$(grep -c '/qa-e2e-pilot:detecting-stack-profile' "$D/claude/commands/qa-spec.md")" "$core_slug_count"
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

# (h) ClickUp tracking guard sentence reaches every harness's render of each step command
for h in claude pi codex opencode; do
  for c in qa-spec qa-scenarios qa-analyze qa-verify qa-status qa-auto; do
    grep -qF 'Run it for every spec: the tracker says whether the spec is tracked.' "$D/$h/commands/$c.md" && grep -qF 'Any non-zero exit is a failure: stop and report its one-line error; do not continue the command, and never skip it silently.' "$D/$h/commands/$c.md"; check "$h $c has tracker guard" "$?" "0"
    check "$h $c guard does not read the settings file" "$(grep -c 'has specs.<target>.enabled: true' "$D/$h/commands/$c.md" 2>/dev/null || true)" "0"
  done
  grep -qF 'auto: the plan check did not pass for this run' "$D/$h/commands/qa-auto.md" && grep -q 'start nothing' "$D/$h/commands/qa-auto.md"; check "$h qa-auto carries the final-wave rules" "$?" "0"
done

# (i) /qa-auto (the unattended journey) renders on every harness; the second look follows dispatch
BANNER='SECOND LOOK UNAVAILABLE: this harness cannot start a fresh agent; every low-confidence decision is left for a person.'
for h in claude pi codex opencode; do
  f="$D/$h/commands/qa-auto.md"
  check "$h qa-auto rendered" "$([ -s "$f" ] && echo y)" "y"
  check "$h qa-auto no residual token" "$(grep -c '{{' "$f" 2>/dev/null || true)" "0"
  grep -q '^description: Drive the whole qa-kit process for a target with nobody present' "$f" 2>/dev/null; check "$h qa-auto frontmatter" "$?" "0"
  grep -qF "$BANNER" "$f" 2>/dev/null && grep -q 'auto.sh" second <target> --unavailable' "$f" 2>/dev/null; check "$h qa-auto has unavailable banner + verb" "$?" "0"
  for c in qa-constitution qa-spec qa-scenarios qa-analyze; do
    grep -qF 'shows `state: open`) counts as `autonomousSetup` on for this step. Record each answer you give in place of a person with `auto.sh decide`.' "$D/$h/commands/$c.md"; check "$h $c has open-journey line" "$?" "0"
  done
  grep -q 'unattended journey' "$D/$h/commands/qa-status.md"; check "$h qa-status mentions the journey" "$?" "0"
done
grep -q 'Start one fresh agent' "$D/claude/commands/qa-auto.md" 2>/dev/null && grep -q 'auto.sh" second <target> <decision-id> stands --reason' "$D/claude/commands/qa-auto.md" 2>/dev/null; check "claude qa-auto dispatches the second look" "$?" "0"
grep -q '${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" second' "$D/claude/commands/qa-auto.md" 2>/dev/null; check "claude second look plugin-root rendered" "$?" "0"
grep -q '/qa-e2e-pilot:qa-run' "$D/claude/commands/qa-auto.md" 2>/dev/null; check "claude qa-auto names the engine run" "$?" "0"
for h in pi codex opencode; do
  check "$h qa-auto has no dispatch instruction" "$(grep -c 'Start one fresh agent' "$D/$h/commands/qa-auto.md" 2>/dev/null || true)" "0"
  check "$h qa-auto leads the second look with the banner" "$(grep -c 'Print this line exactly' "$D/$h/commands/qa-auto.md" 2>/dev/null || true)" "1"
done


# (j) fix round 1: the token rule, the dry spec-init and the lint exception reach every harness
for h in claude pi codex opencode; do
  check "$h qa-tracker has no curl or API host" "$(grep -ci 'curl\|api\.clickup\.com' "$D/$h/commands/qa-tracker.md" 2>/dev/null || true)" "0"
  grep -Eq 'tracker\.sh"? spec-init --spec <target>$' "$D/$h/commands/qa-tracker.md" 2>/dev/null; check "$h qa-tracker has the dry spec-init" "$?" "0"
  grep -q '`lint` is the exception' "$D/$h/commands/qa-scenarios.md" 2>/dev/null; check "$h qa-scenarios has the lint exception" "$?" "0"
  grep -Eq 'tracker\.sh"? push-bug --spec <target> --run <run-id> --apply' "$D/$h/commands/qa-verify.md" 2>/dev/null; check "$h qa-verify push-bug names the run" "$?" "0"
  grep -Eq 'auto\.sh"? note <target> --kind' "$D/$h/commands/qa-auto.md" 2>/dev/null; check "$h qa-auto has the note verb" "$?" "0"
  check "$h no residual token in any command" "$(cat "$D/$h/commands/"*.md 2>/dev/null | grep -c '{{' || true)" "0"
done

# (k) fix round 2: F1-F6, the minors and the safety sentences reach every harness's render
M3='When a person runs this command while a journey is open for the target, tell them first that an unattended journey is open; `auto.sh status` exit 1 means no journey, and the command goes on as usual.'
for h in claude pi codex opencode; do
  f="$D/$h/commands/qa-auto.md"
  has(){ grep -qF -- "$1" "$f" 2>/dev/null; }
  has 'only appends' && has 'Never rewrite, remove, reorder or re-derive an existing row, its tags or its expected value' && has 'a row from the starting plan is gone'; check "$h F1 scenarios round only appends" "$?" "0"
  has "only after the engine's end-of-run order has completed" && has 'auto: that run started before this journey' && has 'never mark it done'; check "$h F2 run done only when finished" "$?" "0"
  has 'is not earlier than `startedAt` in `auto.sh status <target>`'; check "$h F3 resume only a run of this journey" "$?" "0"
  has 'This run was stopped before it finished. See the results page.' && has "<n> items need a person's review. See the results page." && has "Nothing needs a person's review." && has 'the stop reason is not `tracker`'; check "$h F5 three sentences and the no-comment rule" "$?" "0"
  check "$h F6 no unavailable call before the audit" "$(grep -ci 'once more just before the audit' "$f" 2>/dev/null || true)" "0"
  a="$(grep -n '^9\. \*\*Audit\.\*\*' "$f" 2>/dev/null | cut -d: -f1)"; b="$(grep -n '^10\. \*\*Handoff\.\*\*' "$f" 2>/dev/null | cut -d: -f1)"
  check "$h audit before handoff" "$([ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo y)" "y"
  has '(`step-start`, `next`, `signin`, `decide`)'; check "$h M1 unruled exit 1" "$?" "0"
  has 'The launch profile was not applied: the spec already had its own settings.'; check "$h M2 launch profile not applied" "$?" "0"
  has 'the same prefix as the run command above'; check "$h M4 resume wording" "$?" "0"
  has 'shows that step still `running`'; check "$h M5 redo count from status" "$?" "0"
  has -- '--detail "the known-defect registry is not valid"'; check "$h M6 registry on every invocation" "$?" "0"
  for c in qa-constitution qa-spec qa-scenarios qa-analyze; do
    grep -qF "$M3" "$D/$h/commands/$c.md" 2>/dev/null; check "$h $c M3 person told first" "$?" "0"
  done
  grep -qF 'only the tracker script talks to ClickUp' "$D/$h/commands/qa-tracker.md" 2>/dev/null; check "$h qa-tracker F7 token rule" "$?" "0"
  check "$h no bare autonomous in any command" "$(cat "$D/$h/commands/"*.md 2>/dev/null | grep -oi 'autonomous[A-Za-z]*' | grep -vc '^autonomousSetup$' || true)" "0"
done
# F4 + the safety sentences: the Claude prompt for the fresh agent
f="$D/claude/commands/qa-auto.md"
for s in 'You only read.' 'Change no file.' 'Run no script or command that writes.' 'Do not run auto.sh.' 'Do not correct or rewrite an answer.' 'Your whole reply is one line per decision id' \
         'allowed only when the tool for starting a fresh agent is absent or its call fails' 'never because of time, cost or the number of decisions' \
         'It never receives this conversation' 'do not review the decisions yourself' 'recorded as `ask` with the reason `no answer from the second look`'; do
  grep -qF -- "$s" "$f" 2>/dev/null; check "claude second look: $s" "$?" "0"
done
for h in pi codex opencode; do
  f="$D/$h/commands/qa-auto.md"
  check "$h F6 unavailable verb called once" "$(grep -c -- 'second <target> --unavailable' "$f" 2>/dev/null || true)" "1"
  grep -qF 'Run it only here, after `spec` and after `scenarios`' "$f" 2>/dev/null; check "$h F6 only after spec and scenarios" "$?" "0"
  check "$h F4 no fresh-agent prompt" "$(grep -c 'You only read\.' "$f" 2>/dev/null || true)" "0"
done

echo "qakit-adapters: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
