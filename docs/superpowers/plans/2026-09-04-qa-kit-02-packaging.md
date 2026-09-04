# qa-kit increment 2 — packaging as a second plugin (dependencies model) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
>
> **⚠️ MECHANISM CORRECTED (2026-09-04).** The original plan assumed **symlinks** + a `commands` **array** — both are wrong against current Claude Code docs. Verified facts (see memory `qa-kit-plugin-packaging-facts`): symlinks in a plugin are **undocumented/unreliable**; `commands` is a single **directory-path string**, not an array; **`${CLAUDE_PLUGIN_ROOT}` is per-plugin and CANNOT cross-reference another plugin's files**; skills are **namespaced per-plugin** (invoke the engine's as `/qa-e2e-pilot:<skill>`); `dependencies` + multi-`source` marketplace entries **are** supported. This plan uses the **dependencies model** the user chose.

**Goal:** Package qa-kit as its own installable **Claude** plugin (`qa-kit/`) that ships the `qa-*` step commands, declares `dependencies: ["qa-e2e-pilot"]` to reuse the engine's **skills** (by qualified name), and bundles its **own** new scripts (relocated from repo root) — with **no symlinks and no duplication of the engine's skills**. qa-e2e-pilot stays installable standalone and unchanged. Non-Claude harness builds for qa-kit are **deferred** (v1 is Claude-first — see the deferral note).

**Architecture (dependencies model):**
- `qa-kit/.claude-plugin/plugin.json` — own manifest; `dependencies: ["qa-e2e-pilot"]` (co-installs the engine so its skills resolve); its own `commands/` dir (default scan — NOT an array); no `hooks` (reuses the engine's, and enforcement is `qa-verify` post-hoc).
- `qa-kit/commands/qa-*.md` — the step commands, authored in **Claude form**: bundled scripts referenced as `${CLAUDE_PLUGIN_ROOT}/scripts/…`; engine skills invoked by **qualified** slug `/qa-e2e-pilot:<skill>`.
- `qa-kit/scripts/…` — qa-kit's **own** new scripts (constitution.sh now; spec-snapshot.sh, runconfig-merge.sh later). RELOCATED here from repo-root `scripts/qa-kit/` because `${CLAUDE_PLUGIN_ROOT}` can't reach the engine's tree.
- `qa-kit/templates/…` — qa-kit's templates (constitution-template.md now).
- `qa-kit/agents/qa-kit.md` — a thin phase-orchestrator persona (agents replace the default, so qa-kit needs its own).
- `.claude-plugin/marketplace.json` — a **second** `plugins[]` entry `{ "name": "qa-kit", "source": "./qa-kit" }`; the engine entry (`source: "./"`) untouched.

## Global Constraints

- **qa-e2e-pilot is untouched** — its `plugin.json`, root `commands/`/`agents/`/`skills/`/`scripts/`, and its byte-oracle stay exactly as-is. qa-kit is purely additive. (`build-adapter.sh`/`validate-adapters.sh` never reference qa-kit — confirmed — so the byte-oracle is unaffected by anything here.)
- **No symlinks.** Every script a qa-kit command calls MUST live under `qa-kit/` (referenced `${CLAUDE_PLUGIN_ROOT}/scripts/…`). Engine SKILLS are reused via `dependencies` + qualified `/qa-e2e-pilot:<skill>` invocation, never copied.
- **`commands` is a directory**, not an array — qa-kit ships its own `commands/` dir.
- **Relocation is behavior-preserving.** Moving `constitution.sh` under `qa-kit/` must not change its logic or its dual-engine `tests/constitution/run.sh` outcome (PASS=33). Only paths change.
- **Claude-first, non-Claude deferred.** v1 qa-kit authors commands directly under `qa-kit/` (Claude form). The ADR-0017 `core/`→`dist/<h>/` tokenization for codex/pi/opencode qa-kit is a **later increment** (documented deferral), not built here. Do NOT delete the engine's `core/` pipeline.
- **Correct the record.** ADR-0022's symlink/`commands`-array wording is now wrong — this increment corrects it to the dependencies model.
- No `grep -P`/`perl`/`node` in scripts; no Claude/Anthropic attribution / `Co-Authored-By` in commits; never commit `dist/`.

## File Structure

- `qa-kit/scripts/constitution.sh` **(git mv from `scripts/qa-kit/constitution.sh`)** — unchanged logic.
- `qa-kit/templates/constitution-template.md` **(git mv from `core/qa-kit/constitution-template.md`)**.
- `qa-kit/commands/qa-constitution.md` **(from `core/qa-kit/qa-constitution.command.md`, edited to Claude form)**.
- `qa-kit/commands/qa-status.md` **(new)** — the orchestration/next-step helper (Task 4).
- `qa-kit/.claude-plugin/plugin.json` **(new)**.
- `qa-kit/agents/qa-kit.md` **(new)**.
- `tests/constitution/run.sh` **(modify)** — `SH` path → `qa-kit/scripts/constitution.sh`.
- `.claude-plugin/marketplace.json` **(modify)** — add the 2nd entry.
- `docs/adr/0022-qa-kit-process-shell.md` **(modify)** — correct to the dependencies model + non-Claude deferral.
- Remove the now-migrated `core/qa-kit/` + `scripts/qa-kit/` (empty dirs) — via `git mv`, no stray copies.

## Task 1: relocate qa-kit's scripts/template under `qa-kit/` (behavior-preserving)

**Files:** `git mv scripts/qa-kit/constitution.sh qa-kit/scripts/constitution.sh`; `git mv core/qa-kit/constitution-template.md qa-kit/templates/constitution-template.md`; modify `tests/constitution/run.sh`.

- [ ] **Step 1:** `mkdir -p qa-kit/scripts qa-kit/templates`; `git mv scripts/qa-kit/constitution.sh qa-kit/scripts/constitution.sh`; `git mv core/qa-kit/constitution-template.md qa-kit/templates/constitution-template.md`.
- [ ] **Step 2:** edit `tests/constitution/run.sh` line 4: `SH="$DIR/../qa-kit/scripts/constitution.sh"` (from `$DIR/../../scripts/qa-kit/...`). Confirm no other path in the test references the old location.
- [ ] **Step 3:** run `bash tests/constitution/run.sh` → **PASS=33 FAIL=0** (proves the relocation is behavior-preserving); `bash -n qa-kit/scripts/constitution.sh`.
- [ ] **Step 4:** confirm `scripts/qa-kit/` is now empty (removed by git mv) and nothing else in-repo references `scripts/qa-kit/constitution.sh` or `core/qa-kit/constitution-template.md` (grep, excluding `docs/superpowers/` plan prose): `grep -rn 'scripts/qa-kit/constitution\|core/qa-kit/constitution-template' --include='*.sh' --include='*.md' --include='*.json' . | grep -vE 'docs/superpowers/'` → only the command body (fixed in Task 2).
- [ ] **Step 5: Commit** `refactor(qa-kit): relocate constitution.sh + template under qa-kit/ (dependencies model — CLAUDE_PLUGIN_ROOT is per-plugin)`

## Task 2: the qa-kit command (Claude form) + plugin manifest + agent

**Files:** `qa-kit/commands/qa-constitution.md` (from the staged command, edited); `qa-kit/.claude-plugin/plugin.json` (new); `qa-kit/agents/qa-kit.md` (new). Then `git rm` the staged `core/qa-kit/qa-constitution.command.md`.

- [ ] **Step 1: Author `qa-kit/commands/qa-constitution.md`** from `core/qa-kit/qa-constitution.command.md`, editing to **Claude form**:
  - every `scripts/qa-kit/constitution.sh` → `${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh` (quote it in shell: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh" …`);
  - the render template arg `core/qa-kit/constitution-template.md` → `${CLAUDE_PLUGIN_ROOT}/templates/constitution-template.md`;
  - the role-flow reference (currently "run the flow in `core/commands/qa-roles.md`") → invoke the engine's skills by **qualified** slug: `/qa-e2e-pilot:discovering-user-roles` then `/qa-e2e-pilot:confirming-discovered-roles` (these write `.qa/config.json` personas[] + authz-matrix). Keep the ADR-0011 wholesale-regen framing.
  - Keep frontmatter shape (`description`/`argument-hint`/`disable-model-invocation`) matching `core/commands/qa-roles.md`.
- [ ] **Step 2: `qa-kit/.claude-plugin/plugin.json`** — `name: "qa-kit"`, description, `version: "0.1.0"`, author/homepage/repository/license mirroring the engine, `keywords`, `"dependencies": ["qa-e2e-pilot"]`. NO `hooks`. NO `commands` field (default `commands/` scan is correct). Validate JSON.
- [ ] **Step 3: `qa-kit/agents/qa-kit.md`** — a thin phase-orchestrator persona (frontmatter `name: qa-kit`, `description`; body: the constitution→spec→scenarios→analyze→run spine at a high level, deferring verification to the engine). Minimal; it exists because `agents` replaces the default.
- [ ] **Step 4:** `git rm core/qa-kit/qa-constitution.command.md` (migrated). Confirm `core/qa-kit/` is now empty/gone. Confirm the engine build is untouched: `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` → exit 0.
- [ ] **Step 5: Validate** — `python3 -c "import json;json.load(open('qa-kit/.claude-plugin/plugin.json'))"`; grep the command body for any residual bare `scripts/qa-kit/` or `core/` path (must be none — all `${CLAUDE_PLUGIN_ROOT}` now); confirm every skill reference is qualified `/qa-e2e-pilot:`.
- [ ] **Step 6: Commit** `feat(qa-kit): qa-kit plugin manifest + /qa-constitution (Claude form: CLAUDE_PLUGIN_ROOT scripts, qualified engine skills) + thin agent`

## Task 3: register in the marketplace

- [ ] **Step 1:** add a 2nd `plugins[]` entry to `.claude-plugin/marketplace.json`: `{ "name": "qa-kit", "source": "./qa-kit", "description": "…", "version": "0.1.0", "author": {"name": "adams100111"}, "keywords": ["qa","e2e","process","constitution","spec"], "category": "testing", "strict": false }`. Leave the engine entry untouched. Valid JSON.
- [ ] **Step 2: Validate** — `python3 -c "import json;json.load(open('.claude-plugin/marketplace.json'))"`; `validate-adapters.sh` still green (engine byte-oracle unaffected).
- [ ] **Step 3: Commit** `feat(qa-kit): register qa-kit as a second plugin (source ./qa-kit) in the marketplace`

## Task 4: `/qa-status` — next-step/orchestration helper (R3-Q5)

- [ ] **Step 1:** author `qa-kit/commands/qa-status.md` — reads artifact presence under `.qa/` + `.qa/specs/<target>/` (constitution? spec? scenarios? analysis? runs?) and prints **which step is next** + a constitution **drift advisory** (drift needs increment 3's `spec-snapshot.sh drift`; until then, just step sequencing). Pure artifact-presence read — no new logic, no scripts. Claude form (`${CLAUDE_PLUGIN_ROOT}` if it reads any bundled file; it mostly just `ls`-checks `.qa/`). Lands in the default `commands/` scan automatically (no manifest edit needed).
- [ ] **Step 2: Commit** `feat(qa-kit): /qa-status — next-step + drift orchestration helper`

## Task 5: correct ADR-0022 + install docs + deferral note

- [ ] **Step 1: Correct `docs/adr/0022-qa-kit-process-shell.md`** decision #2 + its consequences: replace the "symlinks / `commands` array / dereferenced-at-install" wording with the **dependencies model** (2nd plugin, `dependencies: ["qa-e2e-pilot"]`, engine skills reused by qualified slug, qa-kit bundles its own scripts under `qa-kit/` referenced via per-plugin `${CLAUDE_PLUGIN_ROOT}`, no symlinks). Add a short "**Correction (2026-09-04)**" note stating the original symlink/array assumption was disproven against Claude Code docs (cite memory `qa-kit-plugin-packaging-facts`). Add a **deferral**: non-Claude (codex/pi/opencode) qa-kit build via the ADR-0017 `core/`→`dist/<h>/` tokenization is a later increment; v1 qa-kit is Claude-first.
- [ ] **Step 2:** `docs/harness-adapters.md` — a short "Installing qa-kit (Claude)" section: enable the `qa-kit` marketplace entry; it co-installs qa-e2e-pilot via `dependencies`. Note non-Claude qa-kit is not yet built.
- [ ] **Step 3: Gate + commit** — `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (exit 0). `docs(qa-kit): correct ADR-0022 to dependencies model + qa-kit(Claude) install docs + non-Claude deferral`

## Self-Review

**1. Coverage:** 2nd plugin manifest + dependencies + own `commands/` dir → Task 2; own bundled scripts (relocated, per-plugin CLAUDE_PLUGIN_ROOT) → Task 1+2; marketplace entry → Task 3; `/qa-status` → Task 4; engine untouched + byte-oracle green → constraints + Task 2/3/5 gates; record correction → Task 5. ✅ Non-Claude build explicitly deferred (documented), not silently dropped.

**2. Placeholder scan:** concrete — the mechanism is doc-confirmed (memory `qa-kit-plugin-packaging-facts`). The one residual undocumented edge (whether a command body's skill invocation crosses the plugin boundary by qualified slug) is mitigated by using the qualified form; note it in the ADR as the one place relying on documented-but-untested-here behavior, to re-verify on a real install.

**3. Type consistency:** `constitution.sh` interface unchanged (only its path moves); `tests/constitution/run.sh` still asserts PASS=33; `plugin.json`/`marketplace.json` shapes mirror the engine's existing files; command body references `${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh` (the relocated path) + qualified `/qa-e2e-pilot:` skills.

## Execution Handoff

SDD. **Depends on increment 1** (relocates its `constitution.sh` + command/template). After this, `/qa-constitution` (+ `/qa-status`) is installable as the qa-kit plugin on Claude. Later increments (3 `/qa-spec`, 4 `/qa-scenarios`+`/qa-analyze`, 5 `/qa-run` wiring) author their commands + bundled scripts **directly under `qa-kit/`** in the same Claude form (their plan path references — `core/qa-kit/…`, `scripts/qa-kit/…` — are superseded by this layout: `qa-kit/commands/…`, `qa-kit/scripts/…`, `qa-kit/templates/…`). The non-Claude qa-kit build is a deferred follow-on.
