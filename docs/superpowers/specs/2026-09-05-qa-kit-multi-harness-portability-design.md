# qa-kit multi-harness portability (Codex · Pi · opencode) — design

> **Status:** design draft 2026-09-05. Increment **7** of qa-kit. Follows ADR-0017 (engine multi-harness
> portability), ADR-0022 (qa-kit process shell, "v1 Claude-only" — this increment lifts that limitation),
> ADR-0023 (TDQA data layer). **Engine stays byte-for-byte untouched throughout.**

## 1. Problem

The **verification engine** (`qa-e2e-pilot`) already runs on all four harnesses — `claude`, `codex`, `pi`,
`opencode` — via ADR-0017: one tokenized `core/` + `harness-profiles.json` + `scripts/build-adapter.sh` render
per-harness adapters into `dist/<h>/`, with a Claude byte-oracle guarding drift.

**qa-kit — the step-gated process shell** (`/qa-constitution → /qa-spec → /qa-scenarios → /qa-analyze →
/qa-run`) — is **Claude-only** (ADR-0022, documented not hidden). That is the gap the user is pointing at:
non-Claude users get the engine but not the process shell.

**What is actually Claude-locked is small.** qa-kit's *logic* is already portable:

- **All 7 qa-kit scripts** (`constitution.sh`, `spec-snapshot.sh`, `verify-plan.sh`, `runconfig-merge.sh`,
  `data-baseline.sh`, `check-fixtures.sh`, `detect-seed.sh`, `auto-seed.sh`) are **pure dual-engine bash** —
  they run identically on any harness, no change.
- Locked is only the **thin orchestration + packaging layer**: the 5 command markdowns + `agents/qa-kit.md`,
  which use two Claude-specific idioms:
  1. **`${CLAUDE_PLUGIN_ROOT}`** — 11 references, all pointing at **qa-kit's OWN** bundled scripts/templates
     (per-plugin root). Purely a path token.
  2. **`/qa-e2e-pilot:<skill>`** — **8** distinct qualified-slug calls into the *engine's* skills. This is the
     only genuine **cross-plugin** coupling, and it exists only because Claude has a plugin/skill-namespace +
     `dependencies` model. Codex/Pi/opencode have **no plugin dependency model** (ADR-0022 §135–137).

Goal: generate qa-kit adapters for codex/pi/opencode from a single tokenized source — reusing the engine's
proven ADR-0017 machinery **without modifying any engine file** — and solve the cross-plugin skill-composition
problem those harnesses' lack-of-plugin-model creates.

## 2. Decisions (recommended; open for the spec-review gate)

**D1 — Mirror ADR-0017 exactly, but qa-kit-owned.** Introduce `qa-kit/core/` (tokenized command bodies +
persona), a qa-kit-owned profile table, and a qa-kit-owned generator + validator. The engine's
`harness-profiles.json` and `scripts/build-adapter.sh` are **engine files** — qa-kit must not touch them
(engine-untouched). So qa-kit ships **parallel** artifacts under `qa-kit/`:
- `qa-kit/core/{persona-body.md, commands/*.md}` — the single source of truth.
- `qa-kit/harness-profiles.qakit.json` — **only the NEW qa-kit-specific fields** (`skillRef`, `pluginRootToken`,
  `engineSkillsRoot`, `commandStyle`). Shared harness facts (the harness list, agent-file extension) are
  **read READ-ONLY from the engine's `harness-profiles.json`** at build time (grill G5 — DRY; reading is not
  modifying, so engine-untouched holds). Same four harness keys.
- `qa-kit/scripts/build-qakit-adapter.sh <h>` — renders `qa-kit/dist/<h>/` (git-ignored).
- `qa-kit/scripts/validate-qakit-adapters.sh` — builds all four; enforces the **Claude byte-oracle**
  (Claude dist ≡ committed `qa-kit/commands/` + `qa-kit/agents/`); fails on residual `{{tokens}}`.

**D2 — Claude qa-kit becomes generated-and-committed (like the engine's root files).** Today
`qa-kit/commands/*.md` + `qa-kit/agents/qa-kit.md` are hand-authored. After D1 they originate from
`qa-kit/core/` via `build-qakit-adapter.sh claude` and must stay byte-identical (the byte-oracle). Editing
moves to `qa-kit/core/`, then regenerate. This is the engine's exact discipline, extended to qa-kit — one
source, four harnesses, drift-guarded.

**D3 — Cross-plugin skill composition = per-harness skill reference, resolved by how that harness ACTUALLY
finds a skill (the hard decision; sharpened by grill G1).** The 8 `/qa-e2e-pilot:<skill>` calls tokenize to
`{{SKILL_REF:<name>}}`, rendered per harness from a `skillRef` template — but the three non-Claude harnesses
resolve skills by **different mechanisms**, so a single "bare name" is wrong:
- **claude** → `/qa-e2e-pilot:<name>` — the qualified slug; the plugin namespace + `dependencies` resolves it.
- **codex** → `$<name>` — codex has a real **skill registry** that ingests co-installed skills, so a
  registry invocation works (confirm the exact sigil against the engine's own codex adapter at plan time).
- **pi / opencode** → "apply the skill at `{{ENGINE_SKILLS_ROOT}}/<name>/SKILL.md`" — **an install-resolved
  PATH, not a bare name.** These harnesses have **no shared skill registry**; a skill reference is a prose
  pointer the agent honors by **reading the file**. If qa-kit installs to a different extension dir than the
  engine, a bare name resolves to nothing — so qa-kit must point at the engine's *actual* skills location.
  `{{ENGINE_SKILLS_ROOT}}` is filled at **install time** (D5), not baked at build time.

This composes on top of the engine's existing skill bundling — build-adapter.sh:69 already copies `skills/`
verbatim into `dist/<h>/skills/` — with **no vendoring, no fork** (honors ADR-0001). Rejected alternatives:
**(B) vendor the 8 engine skills into qa-kit's dist** — violates ADR-0001 + drift risk; **(C) one monolithic
engine+qa-kit dist** — couples the two builds' release cadence and forces qa-kit changes to rebuild the engine.

**D4 — `${CLAUDE_PLUGIN_ROOT}` → `{{PLUGIN_ROOT}}`**, rendered per harness to that harness's plugin/extension
root token (a `pluginRootToken` profile field). These stay qa-kit-relative (qa-kit's own scripts/templates) —
no cross-plugin path. Distinct from `{{ENGINE_SKILLS_ROOT}}` (D3), which points at the *engine's* install.

**D5 — Non-Claude qa-kit REQUIRES the engine adapter co-installed, and the installer WIRES the skills path.**
Install contract per `<h>`: (1) install the engine adapter first (drops `skills/` + engine commands under the
engine's root); (2) `qa-kit/harnesses/<h>/install-<h>.sh` installs qa-kit's commands+agent AND resolves
`{{ENGINE_SKILLS_ROOT}}` to where the engine's `skills/` actually landed (a flag/auto-detected sibling
default), rendering the final skill paths at install time; (3) it preflights that the engine `skills/` dir +
the 8 referenced `<name>/SKILL.md` files exist, aborting with a clear message otherwise. Documented in
`qa-kit/harnesses/<h>/README.md`. On Claude this is the `dependencies:[qa-e2e-pilot]` model, unchanged (no
path wiring — the namespace handles it).

**D6 — Scope: the shell only; scripts unchanged; hooks stay prose-driven.** qa-kit's out-of-plan-act
enforcement is a **command-prose `verify-plan.sh` call**, not a Claude hook — so it ports with the commands,
no per-harness hook socket needed (ADR-0022's hook enhancement stays deferred, orthogonal). The 7 scripts are
copied verbatim into each dist. No new qa-kit behavior — this increment is **packaging + composition only**.

## 3. Architecture

```
qa-kit/
  core/                              NEW — single source of truth (tokenized)
    persona-body.md                    → agents/qa-kit.md   (per harness)
    commands/
      qa-constitution.md  qa-spec.md  qa-scenarios.md  qa-analyze.md  qa-status.md
  harness-profiles.qakit.json        NEW — {claude,codex,pi,opencode} × {pluginRootToken, skillRef, cmdExt, agentExt, commandStyle}
  scripts/
    build-qakit-adapter.sh           NEW — render qa-kit/dist/<h>/ from core + profile + harnesses/<h>/
    validate-qakit-adapters.sh       NEW — build all 4 + Claude byte-oracle + residual-token check
  harnesses/<codex|pi|opencode>/     NEW — install-<h>.sh + README.md (co-install contract, D5)
  dist/<h>/                          BUILD OUTPUT (git-ignored) — commands/ + agent/ + scripts/ + templates/
  commands/*.md   agents/qa-kit.md   GENERATED-AND-COMMITTED (Claude) — byte-identical to build ... claude
  scripts/*.sh    templates/*        unchanged (copied verbatim into every dist)
```

**Tokens** (rendered by `build-qakit-adapter.sh`, mirroring the engine's `render()`):
`{{PERSONA_BODY}}`, `{{PLUGIN_ROOT}}`, `{{SKILL_REF:<name>}}`, `{{COMMAND_STYLE}}` (how one qa-kit step names
the next: `/qa-spec` slash vs `$qa-spec` vs prompt-template), plus the agent frontmatter shape per harness
(md frontmatter for claude/pi/opencode, toml for codex — reuse the engine's `EXT` switch).

**Build flow** (identical shape to `scripts/build-adapter.sh`):
`core/ + harness-profiles.qakit.json + harnesses/<h>/glue → detokenize → qa-kit/dist/<h>/`. `validate` builds
all four, diffs Claude dist against the committed `qa-kit/commands` + `qa-kit/agents` (byte-oracle), and greps
for residual `{{` in the rendered `agent/`+`commands/`.

## 4. Per-harness specifics

| Harness | plugin-root token | skill reference | resolves via | command style | agent file |
|---|---|---|---|---|---|
| claude | `${CLAUDE_PLUGIN_ROOT}` | `/qa-e2e-pilot:<name>` | plugin namespace + `dependencies` | `/qa-spec` | `agents/qa-kit.md` (md) |
| codex | codex plugin dir token | `$<name>` | codex skill registry (co-installed) | `$qa-spec` or `/qa-spec` prompt | `agent/qa-kit.toml` |
| pi | pi extension root | `{{ENGINE_SKILLS_ROOT}}/<name>/SKILL.md` (install-resolved path) | agent reads the file | `/qa-spec` prompt-template | `agent/qa-kit.md` |
| opencode | opencode plugin root | `{{ENGINE_SKILLS_ROOT}}/<name>/SKILL.md` (install-resolved path) | agent reads the file | `/qa-spec` command (`agent: qa-kit`) | `agent/qa-kit.md` |

(The exact plugin-root tokens per non-Claude harness are a **plan-time fact-find** — read each harness's
adapter install to copy the engine's convention verbatim; see §7 Open items.)

## 5. Invariants honored

- **Engine untouched** — no change to `core/` (engine), root `commands/`/`skills/`/`scripts/`,
  `harness-profiles.json`, `build-adapter.sh`, `qa-verify.sh`, the engine byte-oracle. qa-kit brings parallel,
  qa-kit-owned `core/`, profile table, generator, validator.
- **No fork/vendor (ADR-0001)** — the 8 engine skills are referenced (flattened), never copied into qa-kit.
- **`qa-verify` untouched (ADR-0022)** — qa-kit's enforcement stays a separate prose-driven `verify-plan.sh`.
- Dual-engine scripts unchanged; no `grep -P`/`perl`/`node`; no attribution; never commit `dist/`.
- **Byte-oracle parity** — a qa-kit Claude byte-oracle mirrors the engine's, so the committed Claude qa-kit
  files can never silently drift from `qa-kit/core/`.

## 6. Testing

- `qa-kit/scripts/validate-qakit-adapters.sh` in CI: builds all four adapters; **Claude byte-oracle** (dist ≡
  committed); residual-`{{token}}` check — exactly the engine's `validate-adapters.sh` gates.
- **Claude byte-repro golden test (grill G2 — highest-risk task).** Before converting Claude qa-kit to
  generated-and-committed, snapshot the current committed `qa-kit/commands/*` + `agents/qa-kit.md` as the
  **golden**; the `qa-kit/core/` extraction is done when `build-qakit-adapter.sh claude` reproduces that golden
  **byte-for-byte**. This is the one task that touches *working* Claude files — it must change nothing.
- A `tests/qakit-adapters/run.sh`: for each harness, assert (a) every `{{SKILL_REF:*}}` rendered to that
  harness's convention (no residual token; claude→slug, codex→`$name`, pi/opencode→a path ending
  `/<name>/SKILL.md`), (b) `{{PLUGIN_ROOT}}` + `{{ENGINE_SKILLS_ROOT}}` rendered, (c) all 5 commands + agent
  emitted with the right extension, (d) the 8 skill names all resolve to a real `skills/<name>/` dir in the
  engine (catch a renamed/removed engine skill early — the composition's one fragility).
- The 7 qa-kit script suites are **unchanged and must stay green** (portability adds no script behavior).
- **Honest boundary:** a real end-to-end qa-kit run on codex/pi/opencode is a **manual accuracy run** per
  harness (like the engine's), not a headless test — the generator + composition are unit-tested; the live
  agent behavior is not scriptable here.

## 7. Scope / phasing / open items

- **In scope (increment 7):** `qa-kit/core/` extraction + `harness-profiles.qakit.json` + `build-qakit-adapter.sh`
  + `validate-qakit-adapters.sh` + Claude generated-and-committed conversion + codex/pi/opencode glue + install
  docs + the co-install/skills-path contract + tests. **Packaging/composition only — zero script behavior change.**
- **Phasing (grill G7): codex → pi → opencode.** Codex has a real skill registry (cleanest composition — a
  registry invocation, no path wiring), so prove the generator + Claude byte-repro + codex composition first;
  then pi and opencode, which share the install-resolved `{{ENGINE_SKILLS_ROOT}}` path mechanism. Task 1 is
  always the Claude byte-repro extraction (it changes nothing but underpins all four).
- **Open items for plan time (facts, not blockers):**
  1. The exact plugin-root token + command/agent file layout each non-Claude harness expects — **read the
     engine's `harnesses/<h>/install-<h>.sh` + manifest.tmpl and copy the convention verbatim** (don't invent).
  2. Whether codex's skill mechanism wants `$<name>` invocation vs a prose "apply the `<name>` skill" — confirm
     against the engine's own codex adapter wording.
  3. Whether `qa-status` (read-only status) needs any engine skill at all (likely none → no `SKILL_REF`).
- **Deferred (YAGNI):** per-harness enforcement **hooks** (ADR-0022's block-hook) — qa-kit's prose-driven
  `verify-plan.sh` already ports; a hard pre-act block on non-Claude is a later, separate increment.

## 8. Grill-round resolutions (self-grill 2026-09-05)

- **G1 (structural) — skill resolution differs per harness.** "Flatten to bare name" was wrong for pi/opencode:
  they have no shared skill registry, so a skill ref is a prose pointer the agent honors by **reading the
  file**. Fixed: pi/opencode use an **install-resolved path** `{{ENGINE_SKILLS_ROOT}}/<name>/SKILL.md`; codex
  uses its registry (`$<name>`); claude keeps the slug (§D3, §4).
- **G2/G9 — Claude generated-and-committed is the riskiest task and touches working files.** Fixed: Task 1 is a
  **byte-repro golden test** — `build ... claude` must reproduce the current committed Claude qa-kit files
  exactly (§6, §7 phasing).
- **G5 — DRY.** qa-kit's profile carries only new fields; shared harness facts are read **read-only** from the
  engine's `harness-profiles.json` (§D1). Engine still untouched (read ≠ modify).
- **G7 — phasing codex → pi → opencode** (§7): validate composition on the harness with a real skill registry
  first, then the path-based two.

**Still open for plan-time fact-find (not blockers):** exact per-harness plugin-root token + agent/command file
layout (copy the engine's `harnesses/<h>/` convention verbatim); codex's exact skill-invocation sigil; whether
`qa-status` references any engine skill (likely none → no `SKILL_REF`); where each harness's engine adapter
installs `skills/` (sets the `{{ENGINE_SKILLS_ROOT}}` default).
