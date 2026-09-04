# qa-kit increment 2 — packaging as a second plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
>
> **Mechanism RESOLVED** (from the Claude Code plugin/marketplace docs, `code.claude.com/docs/en/plugin-marketplaces` + `plugins-reference`): a repo can ship multiple plugins via multiple `marketplace.json` `plugins[]` entries whose `source` points at subdirs; a plugin can share files with others in the same marketplace via **symlinks that Claude dereferences-and-copies at install**; a plugin's `commands` field is an **explicit array override** (so qa-kit lists only its own commands). No investigation task needed — this plan is concrete.

**Goal:** Package qa-kit as its **own installable plugin** in this repo — a sibling plugin dir + a second marketplace entry + symlinks into the shared engine — that ships the `qa-*` step commands (staged by increments 1/3/4) while reusing `core/`/`skills/`/`scripts/` with **zero duplication**. qa-e2e-pilot stays installable standalone and unchanged.

**Architecture (option (a)+(b) from the packaging investigation):**
- `qa-kit/.claude-plugin/plugin.json` — its own manifest; `"commands"` = an explicit array of the `qa-*` step command files (so it does NOT auto-scan qa-e2e-pilot's `commands/`); `"dependencies": ["qa-e2e-pilot"]` so enabling qa-kit co-installs the engine plugin.
- `.claude-plugin/marketplace.json` — add a **second** `plugins[]` entry `{ "name": "qa-kit", "source": "./qa-kit" }` (the existing qa-e2e-pilot entry `source: "./"` is untouched; repo root remains both the marketplace root and the qa-e2e-pilot plugin root — allowed).
- **Symlinks inside `qa-kit/`** into the shared engine (dereferenced-and-copied at install): `qa-kit/skills → ../skills` (or per-skill links if qa-kit wants a subset), `qa-kit/scripts → ../scripts`, `qa-kit/core → ../core`. The staged command bodies (`core/qa-kit/*.command.md`) become `qa-kit/commands/qa-*.md`.
- Non-Claude harnesses: `build-adapter.sh` gains a plugin-id axis (its own task) to emit a qa-kit dist for codex/pi/opencode. `dist/` stays git-ignored (no byte-oracle churn there).

## Global Constraints

- **qa-e2e-pilot is untouched** — its `plugin.json`, root `commands/`/`agents/`/`skills/`, and its byte-oracle stay exactly as-is. qa-kit is purely additive.
- **Zero file duplication** — qa-kit reuses the engine via symlinks (Claude) + the parameterized build (other harnesses), never copies skills/scripts into git.
- **Symlink targets stay INSIDE the marketplace root** (the repo) — the docs skip symlinks pointing outside for security; all qa-kit symlinks target repo-internal paths.
- **The `qa-*` command files are the ones staged in increments 1/3/4** (`core/qa-kit/*.command.md`) — this increment moves/links them into `qa-kit/commands/`; it authors no new command logic.
- Both marketplace entries must remain valid JSON; `validate-adapters.sh` (byte-oracle for qa-e2e-pilot) stays green; add validation covering the qa-kit manifest.
- No attribution; never commit `dist/`.

## File Structure

- `qa-kit/.claude-plugin/plugin.json` **(new)** — the qa-kit manifest (explicit `commands` array + `dependencies`).
- `qa-kit/commands/qa-*.md` **(new)** — the step commands (from the staged `core/qa-kit/*.command.md`).
- `qa-kit/skills`, `qa-kit/scripts`, `qa-kit/core` **(new symlinks)** → `../skills`, `../scripts`, `../core`.
- `qa-kit/agents/qa-kit.md` **(new)** — a thin phase-orchestrator persona (agents `replaces` default, so qa-kit needs its own; can be minimal / reference `core/persona-body.md`).
- `.claude-plugin/marketplace.json` **(modify)** — add the 2nd entry.
- `scripts/build-adapter.sh` **(modify)** — parameterize by plugin id for the non-Claude qa-kit dist.
- `docs/harness-adapters.md`, `harnesses/*/README.md` **(modify)** — qa-kit install per harness.

## Task 1: the qa-kit plugin manifest + commands + symlinks (Claude)

- [ ] **Step 1: Create `qa-kit/.claude-plugin/plugin.json`** — `name: "qa-kit"`, description, version, author/license mirroring qa-e2e-pilot, `"commands"` = explicit array listing `./commands/qa-constitution.md` (+ the others as increments land: qa-spec, qa-scenarios, qa-analyze, qa-run), `"dependencies": ["qa-e2e-pilot"]`. (No `hooks` — qa-kit reuses the engine's; the enforcement is qa-verify post-hoc.)
- [ ] **Step 2: Place the commands + symlinks** — move the staged `core/qa-kit/qa-constitution.command.md` → `qa-kit/commands/qa-constitution.md` (and the template to a location the command references); create the symlinks `qa-kit/skills → ../skills`, `qa-kit/scripts → ../scripts`, `qa-kit/core → ../core` so the command bodies' `bash skills/.../constitution.sh` / `core/qa-kit/...template` paths resolve inside the installed plugin. **Confirm the command bodies' relative paths work when qa-kit is the plugin root** (adjust the command bodies' script paths to the symlinked layout — this may re-touch increments 1/3/4's staged files).
- [ ] **Step 3: A thin `qa-kit/agents/qa-kit.md`** — a phase-orchestrator persona (or a minimal one) since `agents` replaces the default.
- [ ] **Step 4: Validate** — `python3 -c "import json;json.load(open('qa-kit/.claude-plugin/plugin.json'))"`; confirm each symlink target exists + is repo-internal; a smoke test that a symlinked script (`qa-kit/scripts/.../constitution.sh`) is reachable via the qa-kit path.
- [ ] **Step 5: Commit** `feat(qa-kit): qa-kit plugin manifest + commands + engine symlinks (Claude)`

## Task 2: register in the marketplace

- [ ] **Step 1:** add `{ "name": "qa-kit", "source": "./qa-kit", "description": ..., "version": ..., "category": "testing" }` to `.claude-plugin/marketplace.json` `plugins[]` (leave the qa-e2e-pilot entry untouched). Valid JSON.
- [ ] **Step 2: Validate** — JSON parse; `validate-adapters.sh` still green (qa-e2e-pilot byte-oracle unaffected).
- [ ] **Step 3: Commit** `feat(qa-kit): register qa-kit as a second plugin in the marketplace`

## Task 3: non-Claude harness build target

- [ ] **Step 1:** parameterize `scripts/build-adapter.sh` with a plugin id (default `qa-e2e-pilot` = today's behavior; `qa-kit` = a smaller command list + a qa-kit manifest template) so it emits `dist/<h>-qa-kit/` (or `dist/qa-kit/<h>/`) for codex/pi/opencode. Preserve the existing default path byte-for-byte (regression: `validate-adapters.sh` unchanged output for qa-e2e-pilot).
- [ ] **Step 2:** add `harnesses/qa-kit-manifest.tmpl` (or per-harness) + the qa-kit command list; extend the build to render qa-kit's `qa-*` commands.
- [ ] **Step 3: Validate** — build both plugins for all harnesses; confirm qa-e2e-pilot's dist is byte-identical to before (no regression); qa-kit's dist contains only the `qa-*` commands.
- [ ] **Step 4: Commit** `feat(qa-kit): build-adapter plugin-id axis — qa-kit dist for codex/pi/opencode (qa-e2e-pilot dist byte-unchanged)`

## Task 4: install docs + ADR note

- [ ] **Step 1:** `docs/harness-adapters.md` + `harnesses/*/README.md` — how to install qa-kit per harness (Claude marketplace entry; the parameterized build for others). ADR-0022 note: increment 2 landed (sibling plugin + symlinks + marketplace + build axis).
- [ ] **Step 2: Commit** `docs(qa-kit): install docs + ADR-0022 note — packaging (increment 2) landed`

## Self-Review

**1. Coverage (design decision 9 — 2nd plugin reusing core):** sibling manifest + explicit `commands` array → Task 1; marketplace entry → Task 2; zero-duplication sharing via symlinks (Claude) + build axis (others) → Tasks 1+3; qa-e2e-pilot untouched → constraints + Task 2/3 regression checks. ✅

**2. Placeholder scan:** concrete (the mechanism is doc-confirmed). The one thing that may re-touch earlier increments: the command bodies' script paths under the symlinked layout (Task 1 Step 2) — flagged.

**3. Type consistency:** `marketplace.json` gains a 2nd `plugins[]` entry of the same shape as the existing one; `plugin.json` `commands` array + `dependencies` per the plugins-reference; symlinks target repo-internal shared dirs. qa-e2e-pilot's byte-oracle inputs unchanged.

## Execution Handoff

SDD. **Depends on increment 1** (the staged `core/qa-kit/qa-constitution.command.md` to package); can run after 1, alongside 3. It's the increment that makes `/qa-constitution` (and later steps) actually installable as qa-kit. **Sequencing note:** since each later increment stages more `qa-*.command.md` files, either (i) run increment 2 after all step-commands are staged, or (ii) run it after increment 1 and re-run its Task 1 Step 1 (extend the `commands` array) as each later increment lands. Leaning (ii) — package early, extend the manifest per increment.
