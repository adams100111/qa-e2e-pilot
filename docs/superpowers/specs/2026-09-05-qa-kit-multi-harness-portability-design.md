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
  `commandStyle`, and the per-harness install dirs for agent/commands). Shared harness facts (the harness list, agent-file extension) are
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

**D3 — Cross-plugin skill composition = reference the engine's skills the SAME per-harness way the engine's
OWN commands already do (the hard decision; corrected by grill-2 — see §8).** The 8 `/qa-e2e-pilot:<skill>`
calls tokenize to `{{SKILL_REF:<name>}}`, rendered per harness by a `skillRef` template:
- **claude** → `/qa-e2e-pilot:<name>` — the qualified slug; qa-kit is a *separate plugin*, so the cross-plugin
  reference needs the namespace + `dependencies`.
- **codex / pi** → "the `<name>` skill" — a **bare name**. These harnesses install engine skills into a fixed,
  **shared** dir (`.agents/skills/`, `.pi/agents/skills/`) and the agent resolves a skill by **reading that
  file** — which is exactly how the engine's own persona already references its skills, uniformly, today.
- **opencode** → the `skills_<name>` tool — opencode exposes each co-installed `SKILL.md` as a callable
  `skills_<name>` tool **via the community `opencode-skills` plugin** (a hard prerequisite the engine's own
  opencode adapter already requires; without it the skills are inert). Bare `<name>` in prose also works as a
  fallback read.

The engine **proves this composes**: it copies `skills/` verbatim into each `dist/<h>/skills/`
(build-adapter.sh:69), installs them into the harness's conventional **shared** skills dir, and its shared
`core/` references them by **bare name** on every non-Claude harness. qa-kit's only difference is the Claude
case (separate plugin → needs the slug); everywhere else it uses the same bare name against the same shared
dir. **No install-resolved paths, no vendoring, no fork** (ADR-0001). Rejected: **(B) vendor the 8 skills**
(violates ADR-0001, drift); **(C) one monolithic engine+qa-kit dist** (couples the two builds' cadence).

**D4 — `${CLAUDE_PLUGIN_ROOT}` → `{{PLUGIN_ROOT}}`**, rendered per harness to that harness's plugin/extension
root token (a `pluginRootToken` profile field). These stay qa-kit-relative (qa-kit's own scripts/templates) —
no cross-plugin path. (No `ENGINE_SKILLS_ROOT` token — grill-2 removed it; skill refs are bare names, D3.)

**D5 — Non-Claude qa-kit REQUIRES the engine adapter co-installed into the SAME project dirs.** Because
bare-name skill refs resolve against the engine's shared skills dir, the contract per `<h>` is: (1) install the
engine adapter first (it populates `.agents/skills/` / `.pi/agents/skills/` / `.opencode/skills/` + the
grounding files); (2) `qa-kit/harnesses/<h>/install-<h>.sh` installs qa-kit's commands + agent into the SAME
per-harness dirs the engine uses (e.g. pi: agent → `.pi/agents/`, commands → `.pi/prompts/`), so qa-kit's agent
shares that skills dir; (3) it preflights that the shared skills dir + the 8 referenced `<name>/` dirs exist
(and, for opencode, that `opencode-skills` is enabled), aborting with a clear message otherwise. Documented in
`qa-kit/harnesses/<h>/README.md`. On Claude this is the `dependencies:[qa-e2e-pilot]` model, unchanged.

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

| Harness | skill reference (`skillRef`) | resolves via | agent + command install dirs | command style | agent ext |
|---|---|---|---|---|---|
| claude | `/qa-e2e-pilot:<name>` | plugin namespace + `dependencies` | plugin (auto) | `/qa-spec` | md |
| codex | "the `<name>` skill" (bare) | agent reads file in shared `.agents/skills/` | agent `.codex/agents/`, cmds `.codex/prompts/` | `$qa-spec` or `/qa-spec` prompt | toml |
| pi | "the `<name>` skill" (bare) | agent reads file in shared `.pi/agents/skills/` | agent `.pi/agents/`, cmds `.pi/prompts/` | `/qa-spec` prompt-template | md |
| opencode | `skills_<name>` tool | `opencode-skills` plugin exposes shared `.opencode/skills/` | agent `.opencode/agent/`, cmds `.opencode/command/` | `/qa-spec` command (`agent: qa-kit`) | md |

*(Install dirs copied verbatim from each engine `harnesses/<h>/install-<h>.sh` — codex notably puts skills under
`.agents/skills/` while the agent goes under `.codex/agents/`. opencode requires the `opencode-skills` plugin.)*

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
  harness's convention (no residual token; claude→`/qa-e2e-pilot:<name>` slug, codex/pi→bare "the `<name>`
  skill", opencode→`skills_<name>`), (b) `{{PLUGIN_ROOT}}` rendered, (c) all 5 commands + agent emitted with
  the right extension, (d) the 8 skill names all resolve to a real `skills/<name>/` dir in the **engine**
  (catch a renamed/removed engine skill early — the composition's one fragility).
- The 7 qa-kit script suites are **unchanged and must stay green** (portability adds no script behavior).
- **Honest boundary:** a real end-to-end qa-kit run on codex/pi/opencode is a **manual accuracy run** per
  harness (like the engine's), not a headless test — the generator + composition are unit-tested; the live
  agent behavior is not scriptable here.

## 7. Scope / phasing / open items

- **In scope (increment 7):** `qa-kit/core/` extraction + `harness-profiles.qakit.json` + `build-qakit-adapter.sh`
  + `validate-qakit-adapters.sh` + Claude generated-and-committed conversion + codex/pi/opencode glue + install
  docs + the co-install/skills-path contract + tests. **Packaging/composition only — zero script behavior change.**
- **Phasing (revised post grill-2): Task 1 Claude byte-repro extraction → pi → codex → opencode.** Pi is the
  engine's validated-first harness; codex second (bare-name, same mechanism as pi, different install dirs);
  opencode last (carries the extra `opencode-skills` prerequisite + the `skills_<name>` tool form). Task 1
  changes no working behavior but underpins all four adapters.
- **Resolved by the grill-2 docs pass** (engine `harnesses/<h>/` + READMEs): install dirs per harness (§4
  table); codex skills are **read-as-files** (not a registry — my earlier assumption was wrong); **opencode**
  is the one skill-tool harness (`skills_<name>` via the required `opencode-skills` plugin); the engine already
  resolves skills by bare name from a shared dir, so no path token is needed.
- **Doc updates in scope:** `docs/harness-adapters.md`'s "Installing qa-kit (Claude only, for now)" section +
  its "Non-Claude qa-kit is not built yet" note must flip to the shipped multi-harness install; ADR-0022's
  "v1 Claude-only" gets a superseded note; a new **ADR-0024** records the increment-7 composition decision.
- **Open items for plan time (facts, not blockers):**
  1. The exact per-harness plugin-root token string for `{{PLUGIN_ROOT}}` (qa-kit's own scripts/templates root)
     — copy from each engine `install-<h>.sh` (e.g. how it references its own bundled files).
  2. Whether `qa-status` (read-only status) references any engine skill at all (likely none → no `SKILL_REF`).
  3. Confirm codex's prompt/skill dispatch sigil for `commandStyle` against the engine's codex adapter wording.
- **Deferred (YAGNI):** per-harness enforcement **hooks** (ADR-0022's block-hook) — qa-kit's prose-driven
  `verify-plan.sh` already ports; a hard pre-act block on non-Claude is a later, separate increment.

## 8. Grill-round resolutions

**Self-grill (grill-1, 2026-09-05):**
- **G1 (structural) — skill resolution differs per harness.** *(Superseded by grill-2 — see below.)*
- **G2/G9 — Claude generated-and-committed is the riskiest task and touches working files.** Fixed: Task 1 is a
  **byte-repro golden test** — `build ... claude` must reproduce the current committed Claude qa-kit files
  exactly (§6, §7 phasing).
- **G5 — DRY.** qa-kit's profile carries only new fields; shared harness facts are read **read-only** from the
  engine's `harness-profiles.json` (§D1). Engine still untouched (read ≠ modify).
- **G7 — phasing codex → pi → opencode** (§7).

**Docs grill (grill-2, 2026-09-05 — grounded in the engine's `harnesses/<h>/` adapters + READMEs):**
- **G1 was WRONG — corrected.** grill-1 assumed pi/opencode need an install-resolved `SKILL.md` **path** because
  "no shared registry." The engine's own adapters refute this: all three non-Claude harnesses install skills
  into a fixed **shared** dir (`.agents/skills/`, `.pi/agents/skills/`, `.opencode/skills/`) and the engine's
  shared `core/` already references them by **bare name**. So qa-kit uses bare names too — no path token; the
  `{{ENGINE_SKILLS_ROOT}}` idea is dropped (§D3/§D4). This is the "the grill overturned the prior grill's own
  conclusion" pattern — logged, not hidden.
- **codex/opencode roles were swapped.** codex skills are **read-as-files** (not a registry); **opencode** is
  the skill-*tool* harness (`skills_<name>`), and it **requires the `opencode-skills` community plugin** (else
  skills are inert) — now a documented prerequisite (§D3/§4/§5).
- **Install dirs pinned** from each `install-<h>.sh` (§4 table) — notably codex splits skills (`.agents/skills/`)
  from the agent (`.codex/agents/`). qa-kit co-installs into the SAME dirs so bare names resolve (§D5).
- **Doc/ADR updates added to scope** (§7): flip `docs/harness-adapters.md`'s "qa-kit Claude-only" section,
  supersede ADR-0022's v1 note, add ADR-0024.

**Phasing revised (post grill-2):** since codex is no longer the "easy registry" harness (all three are bare-name
except opencode's tool wrapper), phase by **validation maturity** instead — **pi → codex → opencode** (pi is the
engine's validated-first harness; opencode last as it carries the extra `opencode-skills` prerequisite). Task 1
remains the Claude byte-repro extraction.
