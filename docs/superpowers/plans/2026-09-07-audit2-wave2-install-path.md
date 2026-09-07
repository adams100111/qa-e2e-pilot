# Audit-2 Wave 2 — Installed-User Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five confirmed installed-user-path defects from the 2026-09-06 audit (spec items
W2-1…W2-5, `docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md`): `/qa-resume`
shipped and resolvable everywhere, Pi installer merges instead of clobbering, opencode binds the
agent, qa-kit's out-of-plan gate polices the spec's frozen plan, and qa-kit's persona speaks each
harness's skill-invocation dialect.

**Architecture:** Six tasks on branch `fix/audit2-w2-install-path`. T1→T2 are sequential (both
touch `harness-profiles.json`, `scripts/build-adapter.sh`'s token set, `core/commands/*`, and
regenerate the committed byte-oracle files). T3 (installers), T4 (qa-kit verify-plan), T5 (qa-kit
persona token) are file-disjoint and run as parallel worktree subagents. T6 is the wave gate +
version bump (engine 0.6.4, qa-kit 0.1.2) + PR.

**Tech Stack:** Bash (dual-engine jq/python3 where JSON is touched), the ADR-0017 generator
(`build-adapter.sh` token substitution via RENDER_PY literal replace), qa-kit's ADR-0024 generator
(`build-qakit-adapter.sh`), `tests/<name>/run.sh` suite conventions.

## Global Constraints

- **Generated-and-committed discipline:** engine `agents/qa-e2e-pilot.md` + `commands/*.md` and
  qa-kit's Claude `commands/*.md` + `agents/qa-kit.md` are build outputs. Edit `core/` /
  `qa-kit/core/` sources + profiles, regenerate (`bash scripts/build-adapter.sh claude` /
  `bash qa-kit/scripts/build-qakit-adapter.sh claude`), commit the regenerated files; both
  byte-oracles (`validate-adapters.sh`, `validate-qakit-adapters.sh`) must stay green. Never
  hand-edit committed generated files. `dist/` stays git-ignored — never commit it.
- **qa-kit never modifies engine files** in qa-kit tasks (T4/T5); engine tasks never touch qa-kit.
- **Dual-engine idiom** for any script doing JSON work: jq preferred, python3 fallback, identical
  behavior, clear error when neither exists. No `grep -P`/perl.
- **Never weaken a gate.** New suites enrolled in `scripts/run-engine-ci.sh` SUITES (strictly
  alphabetical position) and green under `check-suite-coverage.sh`.
- **No destructive git**, ever. Commit per task; push only at T6.
- Commit messages: conventional, **no Claude/Anthropic attribution, no Co-Authored-By trailer**.

---

## File Structure

- T1 modify: `harness-profiles.json` (new per-harness `engineSkillsDir`),
  `scripts/build-adapter.sh` (token `{{ENGINE_SKILLS_DIR}}`), `core/commands/qa-resume.md`
  (portable script paths), regenerated `commands/qa-resume.md`,
  `scripts/tests/test-core-sources.sh`
- T2 modify: `harness-profiles.json` (new `commandAgentLine`, rewritten non-Claude `dispatch`),
  `scripts/build-adapter.sh` (token `{{COMMAND_AGENT_LINE}}`),
  `core/commands/{qa-run,qa-roles,qa-resume}.md` (frontmatter token line), regenerated
  `commands/{qa-run,qa-roles,qa-resume}.md`, `scripts/tests/test-opencode.sh`
- T3 modify: `scripts/install.sh`, `scripts/skills.json`,
  `harnesses/{codex,pi,opencode}/install-{codex,pi,opencode}.sh`, `scripts/run-engine-ci.sh`;
  create: `tests/installers/run.sh`
- T4 modify: `qa-kit/core/commands/qa-verify.md`, regenerated `qa-kit/commands/qa-verify.md`,
  `tests/qa-kit-enforcement/run.sh`, `tests/qa-kit-phases/run.sh`
- T5 modify: `harness-profiles.qakit.json` (new `skillRefGeneric`),
  `qa-kit/scripts/build-qakit-adapter.sh` (token `{{SKILL_REF_GENERIC}}`),
  `qa-kit/core/persona-body.md`, regenerated `qa-kit/agents/qa-kit.md`,
  `tests/qakit-adapters/run.sh`
- T6 modify: the 4 version files

---

### Task 1: `/qa-resume` portable script resolution (W2-1c)

**Files:** as listed above.

**Interfaces:**
- Produces: `harness-profiles.json` per-harness key `engineSkillsDir` and generator token
  `{{ENGINE_SKILLS_DIR}}`, available to later tasks/waves. T2 builds on the regenerated state.

- [ ] **Step 1: Add `engineSkillsDir` to each harness in `harness-profiles.json`** (beside
  `globalRolesDir`; values mirror where each installer actually puts the skills — pi/codex/opencode
  values must match `harness-profiles.qakit.json`'s `engineSkillsDir` for those harnesses):

```json
"claude":   "engineSkillsDir": "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/skills",
"codex":    "engineSkillsDir": ".agents/skills",
"pi":       "engineSkillsDir": ".pi/agents/skills",
"opencode": "engineSkillsDir": ".opencode/skills",
```

The claude value covers both install modes: marketplace sets `CLAUDE_PLUGIN_ROOT` (plugin root
contains `skills/`), manual/npx installs symlink skills into `~/.claude/skills/`.

- [ ] **Step 2: Register the token in `scripts/build-adapter.sh`'s RENDER_PY set** (lines 41-50):
  add `"{{ENGINE_SKILLS_DIR}}": os.environ["QA_ENGINE_SKILLS_DIR"],` to the replacement dict and
  export `QA_ENGINE_SKILLS_DIR="$(read_field engineSkillsDir)"` beside the existing exports
  (line ~55), mirroring how `{{GLOBAL_ROLES_DIR}}` is wired.

- [ ] **Step 3: Fix `core/commands/qa-resume.md` lines 17-18** — replace the two bare script paths:

```markdown
1. Run `bash "{{ENGINE_SKILLS_DIR}}/checkpointing-qa-memory/scripts/qa-resume.sh" $1`
```

and in line 18 the reconcile invocation becomes
`` `bash "{{ENGINE_SKILLS_DIR}}/checkpointing-qa-memory/scripts/qa-reconcile.sh" apply <run_id> <key> --readbacks <json>` ``.
Sweep the file for any other bare `skills/` script path and tokenize it the same way.

- [ ] **Step 4: Extend `scripts/tests/test-core-sources.sh`** (mirroring its existing checks):

```bash
test -f "$ROOT/core/commands/qa-resume.md"
grep -q '{{DISPATCH}}' "$ROOT/core/commands/qa-resume.md"
grep -q '{{ENGINE_SKILLS_DIR}}' "$ROOT/core/commands/qa-resume.md"
# no committed/core command may reference scripts by a bare repo-relative skills/ path
! grep -nE '`bash skills/' "$ROOT"/core/commands/*.md
```

(Adapt variable names to the file's existing style.) Run it: `bash scripts/tests/test-core-sources.sh` — must pass only AFTER Step 3.

- [ ] **Step 5: Regenerate + validate**

```bash
bash scripts/build-adapter.sh claude && cp dist/claude/commands/qa-resume.md commands/qa-resume.md
bash scripts/validate-adapters.sh   # byte-oracle + residual-token check must be green
grep -n 'ENGINE_SKILLS_DIR' commands/qa-resume.md && exit 1 || true   # no residual tokens
grep -n 'CLAUDE_PLUGIN_ROOT' commands/qa-resume.md                    # claude value rendered
```

Note: `validate-adapters.sh` builds all four adapters and diffs the committed files — if it flags
qa-run/qa-roles/agent as differing, you regenerated wrong; only qa-resume.md content changes here.

- [ ] **Step 6: Commit**

```bash
git add harness-profiles.json scripts/build-adapter.sh core/commands/qa-resume.md commands/qa-resume.md scripts/tests/test-core-sources.sh
git commit -m "fix(portability): /qa-resume resolves its scripts per harness via {{ENGINE_SKILLS_DIR}} (audit-2 W2-1c)"
```

---

### Task 2: opencode agent binding + honest `{{DISPATCH}}` strings (W2-3)

**Files:** as listed above. **Depends on T1 (same files).**

**Interfaces:**
- Consumes: T1's regenerated state.
- Produces: token `{{COMMAND_AGENT_LINE}}` + profile key `commandAgentLine`; rewritten `dispatch`
  strings for codex/pi/opencode.

- [ ] **Step 1: Write the failing assertion in `scripts/tests/test-opencode.sh`** (mirror its
  existing build-then-grep style):

```bash
grep -q '^agent: qa-e2e-pilot$' "$ROOT/dist/opencode/commands/qa-run.md"
grep -q '^agent: qa-e2e-pilot$' "$ROOT/dist/opencode/commands/qa-resume.md"
# claude render must NOT carry the opencode-only key
! grep -q '^agent:' "$ROOT/dist/claude/commands/qa-run.md"
```

Run `bash scripts/tests/test-opencode.sh` — the new lines must FAIL now (RED).

- [ ] **Step 2: Add the `commandAgentLine` key to `harness-profiles.json`** — opencode:
  `"commandAgentLine": "agent: qa-e2e-pilot\n"`, claude/codex/pi: `"commandAgentLine": ""`.
  Register `{{COMMAND_AGENT_LINE}}` in build-adapter.sh's RENDER_PY dict + export, exactly like T1
  Step 2 (the JSON `\n` must survive into the substitution — verify RENDER_PY reads it via the
  profile, mirroring how `{{MODEL_FIELD_LINE}}` handles its embedded newline in manifest.tmpl).

- [ ] **Step 3: Insert the token into all three `core/commands/*.md` frontmatters** — the line
  `{{COMMAND_AGENT_LINE}}` immediately before the closing `---`, with NO newline of its own
  (i.e. `{{COMMAND_AGENT_LINE}}---` as the closing line, the `MODEL_FIELD_LINE` idiom), so an
  empty value renders zero bytes and the claude render is byte-identical to a frontmatter without
  the key.

- [ ] **Step 4: Rewrite the three non-Claude `dispatch` values in `harness-profiles.json`** to
  describe the real mechanism instead of pointing back at `/qa-run` (the current values are
  circular: the command's own body says "dispatch via the /qa-run command"). Before writing them,
  read `harnesses/<h>/README.md` for each harness's actual agent-loading mechanism and make the
  strings consistent with those docs. Starting points (adjust to what the READMEs describe):
  - codex: `as the qa-e2e-pilot agent profile (.codex/agents/qa-e2e-pilot.toml) — you are that persona when this prompt runs; proceed directly`
  - pi: `as the qa-e2e-pilot persona (.pi/agents/) — you are that persona when this prompt-template runs; proceed directly`
  - opencode: `` under the `qa-e2e-pilot` agent (bound by this command's `agent:` frontmatter) ``
  Claude's dispatch stays untouched.

- [ ] **Step 5: Regenerate + validate + RED→GREEN**

```bash
bash scripts/build-adapter.sh claude
cp dist/claude/commands/qa-run.md commands/qa-run.md
cp dist/claude/commands/qa-roles.md commands/qa-roles.md
cp dist/claude/commands/qa-resume.md commands/qa-resume.md
cp dist/claude/agent/qa-e2e-pilot.md agents/qa-e2e-pilot.md 2>/dev/null || true  # only if changed
bash scripts/validate-adapters.sh
bash scripts/tests/test-opencode.sh   # new assertions now GREEN
# no rendered non-Claude command instructs running /qa-run from within itself:
! grep -l 'via the `/qa-run` command' dist/codex/commands/qa-run.md dist/pi/commands/qa-run.md dist/opencode/commands/qa-run.md
```

Expected: claude committed files are byte-identical EXCEPT any file whose frontmatter gained the
(empty-rendering) token — verify with `git diff --stat` that committed claude outputs show no
content change beyond what T1 already made; if the empty token renders extra bytes, fix Step 3.

- [ ] **Step 6: Commit**

```bash
git add harness-profiles.json scripts/build-adapter.sh core/commands/ commands/ scripts/tests/test-opencode.sh
git commit -m "fix(opencode): bind /qa-run + /qa-resume to the qa-e2e-pilot agent; de-circularize non-Claude dispatch strings (audit-2 W2-3)"
```

---

### Task 3: Installers ship every command; Pi merges mcp.json (W2-1a/b + W2-2)

**Files:** as listed above. **Parallel-safe** (disjoint from T1/T2/T4/T5).

**Interfaces:**
- Produces: `tests/installers` suite; installers glob-copy `dist/<h>/commands/*.md`.

- [ ] **Step 1: Write the failing suite `tests/installers/run.sh`** (mode 755; repo conventions —
  `set -uo pipefail`, `check()` helper, `mktemp -d` + trap, PASS/FAIL, exit 1 on FAIL). Cases:

```bash
# For each harness codex|pi|opencode: run its installer into a scratch project and
# assert the installed command set equals dist/<h>/commands/*.md (glob compare):
#   codex   -> .codex/prompts/       pi -> .pi/prompts/    opencode -> .opencode/command/
# (today FAILS: qa-resume.md is missing everywhere)
# install.sh case: HOME=$SCRATCH_HOME CLAUDE_DIR override if supported (read install.sh);
#   assert ~/.claude/commands contains every repo commands/*.md (FAILS today for qa-resume)
# pi-merge case 1: pre-existing .pi/mcp.json with a foreign server "foo" ->
#   after install, BOTH "foo" and the playwright-qa entry present; a .bak backup exists
# pi-merge case 2: no pre-existing mcp.json -> file equals the snippet content (modulo formatting)
# pi-merge case 3 (no-engine fallback): PATH masked of jq AND python3 -> installer does NOT
#   overwrite the existing file; prints the snippet + a merge-it-yourself message (mirror the
#   codex/opencode print-and-ask wording)
```

Write real assertions (compare sorted basename lists; `jq -e '.mcpServers|has("foo") and has("playwright-qa")'`
— adapt the key names to what `harnesses/pi/mcp.snippet` actually contains, read it first).
Run: expected RED on the command-set cases and pi-merge case 1.

- [ ] **Step 2: Glob-copy commands in all three harness installers** — replace the two hardcoded
  `cp` lines in each with (mirroring qa-kit's `_install-common.sh:37`):

```bash
cp "$ROOT/dist/<h>/commands/"*.md "$PROJ/<cmd-dir>/"
```

- [ ] **Step 3: `scripts/install.sh`** — replace the two hardcoded `link_one` command lines with a
  glob loop (mirroring its own skills loop at lines 51-54):

```bash
for cmd_file in "$REPO_ROOT"/commands/*.md; do
  link_one "$cmd_file" "$CLAUDE_DIR/commands/$(basename "$cmd_file")"
done
```

- [ ] **Step 4: `scripts/skills.json`** — add `{ "name": "qa-resume", "path": "commands/qa-resume.md" }`
  to the commands array.

- [ ] **Step 5: Pi mcp.json merge in `harnesses/pi/install-pi.sh`** — replace the blind
  `cp mcp.snippet .pi/mcp.json` with dual-engine merge: if `.pi/mcp.json` exists and jq or python3
  is available, back it up to `.pi/mcp.json.bak-qa-e2e-pilot` then deep-merge the snippet's
  `mcpServers` entries into it (existing foreign keys preserved; the snippet's key overwrites only
  its own entry); if it exists but NO engine is available, do NOT touch it — print the snippet with
  a "merge this into .pi/mcp.json yourself" message (same posture as codex/opencode); if it doesn't
  exist, copy the snippet as before. jq leg: `jq -s '.[0] * .[1]' existing snippet`. python3 leg:
  `json.load` both, `existing["mcpServers"].update(snippet["mcpServers"])`, dump with
  `indent=2`.

- [ ] **Step 6: Enrol the suite** — add `installers` to `scripts/run-engine-ci.sh` SUITES
  (strictly alphabetical: between `init-config` and `interaction-ux`).

- [ ] **Step 7: GREEN + gates**

```bash
bash tests/installers/run.sh
bash -n scripts/install.sh harnesses/*/install-*.sh
bash scripts/check-suite-coverage.sh
```

- [ ] **Step 8: Commit**

```bash
git add scripts/install.sh scripts/skills.json harnesses/codex/install-codex.sh harnesses/pi/install-pi.sh harnesses/opencode/install-opencode.sh tests/installers/run.sh scripts/run-engine-ci.sh
git commit -m "fix(install): every installer ships all rendered commands; pi merges mcp.json instead of clobbering (audit-2 W2-1/W2-2)"
```

---

### Task 4: qa-kit `/qa-verify` polices the spec's frozen plan (W2-4)

**Files:** as listed above. **Parallel-safe.** qa-kit-scoped — touch no engine file.

**Interfaces:**
- Consumes: `verify-plan.sh <checkpoint.json> <checklist.json>` CLI (unchanged);
  the resolution ladder already in `qa-kit/core/commands/qa-verify.md:13-26`.

- [ ] **Step 1: Failing test additions.** (a) In `tests/qa-kit-enforcement/run.sh` (mirror its
  `$SH`/`check`/`run_engine` idioms): a case proving the laundering scenario is caught when the
  SPEC plan is the second arg — checkpoint has acted ids C1,C3; SPEC checklist has only C1; a
  run-local checklist file containing C1,C3 exists beside it but is NOT passed; assert exit 1 and
  `outOfPlan == ["C3"]` under both engines. (b) In `tests/qa-kit-phases/run.sh` (grep-style command
  assertions — mirror its idiom): assert the committed `qa-kit/commands/qa-verify.md` invokes
  `verify-plan.sh` with `.qa/specs/` in the second argument, and contains the weaker-mode banner
  text `run-local plan only` (exact string per Step 2). RED: (b) fails now; (a) may already pass at
  script level — that's fine, it pins the contract the command text now depends on.

- [ ] **Step 2: Edit `qa-kit/core/commands/qa-verify.md` step 2** so the plan argument depends on
  spec resolvability:
  - When the run resolved to a `<target>` with a frozen `.qa/specs/<target>/checklist.json`
    (ladder tiers 1-3): run
    `bash "{{PLUGIN_ROOT}}/scripts/verify-plan.sh" .qa/runs/<id>/checkpoint.json .qa/specs/<target>/checklist.json`
    — the FROZEN plan, never the run copy. Additionally instruct: diff the id sets of the frozen
    plan vs `.qa/runs/<id>/checklist.json`; any id present in the run copy but absent from the
    frozen plan is reported as a **plan-divergence finding** (list the ids, criteria added
    in-run), never silently accepted.
  - Only when NO spec target is resolvable (engine-solo run, ladder tier 4): fall back to the run
    copy as today, but the report MUST carry the banner: `⚠ out-of-plan check ran against the
    run-local plan only (no frozen spec plan resolved) — weaker guarantee: an amended in-run
    checklist cannot be detected.`
  Keep the step's existing output-parsing text; renumber nothing.

- [ ] **Step 3: Regenerate + validate**

```bash
bash qa-kit/scripts/build-qakit-adapter.sh claude
cp qa-kit/dist/claude/commands/qa-verify.md qa-kit/commands/qa-verify.md
bash qa-kit/scripts/validate-qakit-adapters.sh
bash tests/qa-kit-enforcement/run.sh && bash tests/qa-kit-phases/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add qa-kit/core/commands/qa-verify.md qa-kit/commands/qa-verify.md tests/qa-kit-enforcement/run.sh tests/qa-kit-phases/run.sh
git commit -m "fix(qa-kit/verify): out-of-plan gate polices the spec's frozen checklist; run-local fallback banners the weaker mode (audit-2 W2-4)"
```

---

### Task 5: qa-kit persona speaks each harness's skill dialect (W2-5)

**Files:** as listed above. **Parallel-safe.** qa-kit-scoped.

**Interfaces:**
- Produces: profile key `skillRefGeneric` + token `{{SKILL_REF_GENERIC}}` in the qa-kit generator.

- [ ] **Step 1: Failing test.** In `tests/qakit-adapters/run.sh` (mirror its build-then-grep
  style on `qa-kit/dist/<h>/`):

```bash
# the Claude-only qualified slug must not leak into non-Claude agent renders
for h in pi codex opencode; do
  check "no /qa-e2e-pilot: literal in $h agent" "$(grep -c '/qa-e2e-pilot:' "$QAKIT/dist/$h/agent/"* || true)" "0"
done
check "claude agent keeps the qualified slug" "$(grep -c '/qa-e2e-pilot:<skill>' "$QAKIT/dist/claude/agent/qa-kit.md")" "1"
```

(Adapt variable names; the agent file extension differs per harness — glob it.) RED now.

- [ ] **Step 2: Add `skillRefGeneric` per harness to `harness-profiles.qakit.json`** (beside
  `skillRef`, same dialect):
  - claude: `` its qualified slug (`/qa-e2e-pilot:<skill>`) ``
  - pi: `` its bare name (read the `<skill>` skill from the engine's skills dir) ``
  - codex: `` its bare name (the `<skill>` skill) ``
  - opencode: `` its `skills_<skill>` tool ``

- [ ] **Step 3: Register `{{SKILL_REF_GENERIC}}`** in `qa-kit/scripts/build-qakit-adapter.sh`'s
  render (a literal replace beside `{{ENGINE_RUN}}`/`{{PLUGIN_ROOT}}` at lines 31-32, value read
  from the profile like its siblings).

- [ ] **Step 4: Edit `qa-kit/core/persona-body.md`** — replace the literal qualified-slug phrase
  (the sentence spanning lines 22-24, "invoke the engine's skill by its qualified slug
  (`/qa-e2e-pilot:<skill>`)") with `invoke the engine's skill by {{SKILL_REF_GENERIC}}`, keeping
  the rest of the sentence ("— never reimplement it here"). Sweep qa-kit/core/ for any OTHER
  untokenized `/qa-e2e-pilot:` literal outside `{{SKILL_REF:…}}` tokens; tokenize or report each.

- [ ] **Step 5: Regenerate + validate + GREEN**

```bash
bash qa-kit/scripts/build-qakit-adapter.sh claude
cp qa-kit/dist/claude/agent/qa-kit.md qa-kit/agents/qa-kit.md
bash qa-kit/scripts/validate-qakit-adapters.sh
bash tests/qakit-adapters/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add harness-profiles.qakit.json qa-kit/scripts/build-qakit-adapter.sh qa-kit/core/persona-body.md qa-kit/agents/qa-kit.md tests/qakit-adapters/run.sh
git commit -m "fix(qa-kit/portability): persona skill-invocation instruction rendered per harness dialect (audit-2 W2-5)"
```

---

### Task 6: Wave gate, version bump, PR (controller)

- [ ] **Step 1:** Full gate: `run-engine-ci.sh`, `run-qakit-ci.sh`, both validate-adapters, `check-suite-coverage.sh`, repo JSON sweep (excluding dist/ and worktrees) — all green.
- [ ] **Step 2:** Bump engine → **0.6.4** (plugin.json, marketplace.json ×2, skills.json), qa-kit → **0.1.2** (qa-kit plugin.json, marketplace entry). Commit `chore(release): engine 0.6.4, qa-kit 0.1.2 — audit-2 wave 2 (installed-user path)`.
- [ ] **Step 3:** Final whole-branch review (merge-base main..HEAD package), then push + `gh pr create` + `gh pr merge --merge --delete-branch`.

---

## Self-review notes

- Spec coverage: W2-1a→T3 (install.sh/skills.json), W2-1b→T3 (glob installers), W2-1c→T1
  (token + test-core-sources), W2-2→T3 (pi merge + backup + fallback), W2-3→T2 (frontmatter token
  + dispatch rewrite + test-opencode), W2-4→T4, W2-5→T5. Acceptance "no committed command
  references a bare skills/ path" → T1 Step 4 grep; "installers ship every rendered command" →
  T3 Step 1; byte-oracles green → T1/T2/T4/T5 validate steps.
- Known judgment points left to implementers deliberately: exact dispatch wording (verified
  against harness READMEs, T2 Step 4), pi mcp.snippet key name (read the snippet, T3 Step 1),
  suite variable-name mirroring. All contracts (assertions, paths, tokens) are pinned here.
- T1→T2 strictly sequential; T3/T4/T5 parallel worktrees; controller merges + reviews per task.
