# ADR-0022 — qa-kit process shell: second plugin, post-hoc-primary enforcement, regenerate-wholesale constitution

## Status

Accepted, 2026-09-04. Implements `docs/superpowers/specs/2026-09-04-qa-kit-design.md`. Increment 1 of
the roadmap (`docs/superpowers/plans/2026-09-04-qa-kit-roadmap.md`) has landed: `/qa-constitution`
(`constitution.sh` version/diff/state/render + the command body). Increment 2 (second-plugin
packaging, dependencies model), increment 3 (`/qa-spec` + `spec-snapshot.sh` copy/stamp/override +
drift), increment 4 (`/qa-scenarios` + `/qa-analyze` + the enforcement seam `verify-plan.sh`, with
`qa-verify` unmodified), and increment 5 (`runconfig-merge.sh` + `/qa-spec` run-config emission + the
spine terminating in the engine's existing `/qa-run <target> <checklist>` + phase integration tests)
have all landed. **The v1 spine is complete** (constitution → spec → scenarios → analyze → run) on
**Claude**. Deferred follow-ons: the non-Claude (codex/pi/opencode) qa-kit build, the remaining
constitution/spec enforcement compilations beyond the one seam, per-run auto-application of run-config
inside the run, and a per-run live constitution-block on Claude. This ADR records the decisions the
spine honors.

**Increment-5 note.** Because the engine's `/qa-run` already ingests a checklist/spec path (`$2`) and
freezes it, the spine terminates in the **unmodified** engine `/qa-run "<target>"
.qa/specs/<target>/checklist.json` — no engine edit was needed or made. `runconfig-merge.sh` computes
the effective per-run config (spec deltas over `.qa/config.json`) without mutating it; applying that
effective config *inside* the unmodified engine run is the documented deferral.

**Correction (2026-09-04, during increment 2).** Decision 2's original wording assumed qa-kit would
reuse the engine's files via **symlinks** and an explicit `commands` **array**. Both were disproven
against current Claude Code docs (verified via the claude-code-guide agent; captured in the
`qa-kit-plugin-packaging-facts` memory): plugin symlinks are undocumented/unreliable across install
paths; `commands` is a single directory-path string, not an array; **`${CLAUDE_PLUGIN_ROOT}` is
per-plugin and cannot reference another plugin's files**; skills are namespaced per-plugin. Decision 2
below is the corrected **dependencies model**.

## Context

qa-e2e-pilot runs a QA pass in one shot: `/qa-run <target>` analyzes, generates a checklist, and
verifies it end-to-end. That quick path is valuable but has no durable, project-level home for
*policy* — which roles this project has, which optional gates apply, what "correct" means for a
given target — and no staged review point before the (expensive) run. spec-kit demonstrates a
pattern for this: a sequence of steps, each producing a human-reviewable artifact, each checked for
alignment with the steps before it. But spec-kit's own enforcement is thin — file-existence
prerequisite checks plus LLM-prose "alignment" gates; its per-harness hook socket
(`events.py`) is real but plugged with **nothing** by default. qa-e2e-pilot already has the opposite
problem solved: `qa-verify` (ADR-0018) is a real out-of-agent, deterministic authority that reads
`checklist.json` and `.qa/config.json` after a run. The question this ADR answers is how to combine
spec-kit's staged-artifact pattern with qa-e2e-pilot's existing enforcement engine, without forking
spec-kit, without touching `qa-verify`, and without breaking the standalone quick path.

## Decision

1. **qa-kit is a process shell that borrows spec-kit's *patterns*, not its steps.** It reuses:
   staged commands, one human-reviewable artifact per step, prompt-driven prerequisite checks
   (spec-kit's `check-prerequisites.sh` idiom), and a per-harness command+hook installer shape. It
   does **not** reuse spec-kit's step names or bodies (`constitution → specify → plan → tasks →
   implement`). qa-kit's spine is QA-specific: **constitution → spec → scenarios → analyze → run**
   (`/qa-plan` was considered and folded into `/qa-spec`, since a standalone run-plan step would
   have mostly duplicated `.qa/config.json`'s existing drivers/budget/viewport fields). Every step
   is powered by an **existing** qa-e2e-pilot skill or script — no verification logic is
   reimplemented.

2. **qa-kit ships as a SECOND plugin in this repo (dependencies model).** It has its own
   `qa-kit/.claude-plugin/plugin.json` and a second `marketplace.json` entry (`source: "./qa-kit"`),
   and declares `"dependencies": ["qa-e2e-pilot"]` so enabling qa-kit co-installs the engine. qa-kit
   **reuses the engine's SKILLS by qualified slug** (`/qa-e2e-pilot:discovering-user-roles`, …) rather
   than copying them, and **bundles its own NEW scripts under `qa-kit/`** (e.g. `qa-kit/scripts/
   constitution.sh`), referenced from its commands via its own per-plugin `${CLAUDE_PLUGIN_ROOT}`
   (which cannot reach the engine's tree). No symlinks; no duplication of the engine's skills. For the
   **other harnesses** (codex/pi/opencode), a qa-kit build target over the ADR-0017 `core/`→`dist/<h>/`
   tokenization is **deferred** — v1 qa-kit is Claude-first (see the packaging-cost consequence).
   qa-e2e-pilot (the verification engine) stays installable standalone and **unchanged**; qa-kit is an
   additive product built on top of it, not a fork or a rewrite.

3. **Enforcement is `qa-verify`-post-hoc-primary.** `block-hook.sh` sees only a tool-call's shape at
   call time — it has no criterion, role, or plan context — so it can live-block only tool-*shape*
   absolutes (a mutating `browser_evaluate`/`run_code_unsafe`), exactly as it does today; it cannot
   live-enforce "only act on a planned criterion" or "only this role." qa-kit's phases instead
   **populate the gate's existing inputs** — `checklist.json` (criterion↔role, required-evidence-
   kinds, declared oracle) and `.qa/config.json` (`personas[].expectedSubject`) — which `qa-verify`
   already reads post-hoc, on every harness. `qa-verify` itself is **untouched**: qa-kit feeds it
   configuration, never modifies its logic. v1 lands exactly **one** such compilation end-to-end —
   scenarios' planned-criteria set written into `checklist.json`, with an **act on an out-of-plan
   criterion flagged** — proving the "phases populate the gate's existing shapes" seam works before
   the remaining compilations (constitution allowed-roles/required-kinds, spec oracle-binding) are
   built out.

   **Increment-4 investigation finding (2026-09-04), important correction:** `qa-verify` does **not**
   itself flag an act on an out-of-plan criterion. It iterates only the recorded passes in
   `checkpoint.json`; when a recorded criterion has no matching `checklist.json` row it *skips* the
   required-kinds re-derivation (see `qa-verify.sh` ~line 1030 + `checklist_row_for` ~line 481) — an
   unlisted acted criterion is verified on its own evidence, never rejected as out-of-plan. Since the
   escalation trigger ("the only honest fix modifies `qa-verify`") did **not** hold — a checker beside
   `qa-verify` works — the seam is a **qa-kit-owned standalone `qa-kit/scripts/verify-plan.sh`** run
   alongside `qa-verify` (the "sits beside the gate" pattern, like session-preflight). It compares the
   run's acted `checkpoint.json[].criterion_id` against the frozen `checklist.json[].id` and exits
   nonzero listing any out-of-plan act. `qa-verify` stays byte-for-byte unmodified.

   A per-run *live* constitution-block on Claude is deliberately
   deferred (a `block-hook` enhancement); `qa-verify` already covers the post-hoc floor on every
   harness in the meantime.

4. **The constitution regenerates roles WHOLESALE, never reconciles, aligned with
   [ADR-0011](./0011-roles-personas-discovery.md).** `/qa-constitution` reuses the existing role
   machinery unchanged (`discovering-user-roles`, `confirming-discovered-roles`,
   `write-persona-config.sh`), which already writes `.qa/config.json` `personas[]` +
   `.qa/authz-matrix.json`. Re-running it after the app changes regenerates that role state from
   scratch and prints an **informational diff** (`+added / −removed / scope-changed`, including
   `roleScope` value changes, not just key changes) for human awareness — it never merge-preserves
   a stale or drifted per-role edit. `constitution.md` adds a version/hash on top of that role
   state; it *references* the plugin-universal invariants (`CONTEXT.md`, the human-interaction and
   evidence-enforcement ADRs) rather than restating them, to avoid drift between two copies of the
   same rule. **All per-role customization is a per-spec concern**: `/qa-spec` copies the
   constitution's roles into a `spec-roles.json` snapshot, stamped with the constitution
   version/hash it was built from, and **frozen at `plan_frozen`** ([ADR-0020](./0020-durable-run-state-machine.md))
   for that run — a live reference from a running spec back to a mutating constitution would break
   the durable-resume and reproducibility guarantee ADR-0020 already depends on. One spec can drive
   N runs; each replays its spec's frozen snapshot, never re-pulling a changed constitution.

5. **`/qa-run` stays first-class standalone.** The phased shell is an additive branch, not a new
   requirement: a bare `/qa-run "<target>"` with no `.qa/specs/` present behaves exactly as it does
   today (self-discovers roles, generates and runs a checklist in one shot). `/qa-run` is also
   qa-kit's own "Implement" step at the end of the phased chain — the same command, two entry
   points, no divergent behavior.

## Consequences

- qa-e2e-pilot's invariants — verdict/confidence vocabulary, `qa-verify` as sole gate authority,
  ADR-0015's human-interaction discipline, ADR-0020's durable journal/`plan_frozen` — are inherited
  by qa-kit for free rather than re-specified, because qa-kit only orchestrates existing skills and
  scripts; it does not introduce a parallel verification path.
- **Enforcement is honestly tiered, not uniform.** Only the scenarios→planned-criteria compilation
  ships in v1; constitution allowed-roles/required-kinds and spec declared-oracle enforcement are
  later increments. Prose-only alignment checks (e.g. "prefer minimal scenarios") stay guidance,
  never a gate — qa-kit never claims a prose ideal is machine-enforced.
- **Packaging cost + Claude-first scope:** qa-kit needs its own plugin manifest + marketplace entry +
  a bundled copy of any script it calls (the engine's `${CLAUDE_PLUGIN_ROOT}` is unreachable from
  qa-kit). On **Claude** this is cheap — a manifest, a `commands/` dir, and qa-kit's own scripts, with
  the engine's skills reused via `dependencies`. On the **other harnesses** there is no plugin/skill
  namespacing to lean on, so a qa-kit `dist/<h>/` build (flattening qa-kit's commands + the engine's
  skills, per [ADR-0017](./0017-multi-harness-portability.md)) is required — that is **deferred** to a
  later increment; **v1 qa-kit is Claude-only**, and that limitation is documented rather than hidden.
  **(SUPERSEDED 2026-09-05 by [ADR-0024](./0024-qa-kit-multi-harness.md): increment 7 ships qa-kit on
  Codex/Pi/opencode, generated from `qa-kit/core/` — the "different composition" is per-harness skill
  references resolved from the engine adapter's co-installed shared skills dir; engine still untouched.)**
- **No mid-run mutation.** Roles and the frozen plan cannot be edited once `plan_frozen` fires —
  reproducibility is chosen over live-editing, matching ADR-0020's existing freeze-and-replay
  principle.
- **Reversibility:** qa-kit is additive — a second plugin and a set of commands/scripts layered on
  top of unmodified `core/`/`skills/`/`scripts/` and an unmodified `qa-verify`. Reverting means
  removing qa-kit's plugin manifest and command set; qa-e2e-pilot's standalone `/qa-run` path is
  unaffected either way. The hard-to-reverse calls this ADR fixes are the shape of the spine
  (QA-specific steps, not spec-kit's), the packaging boundary (second plugin vs. folding into
  qa-e2e-pilot), and the enforcement seam (`qa-verify` post-hoc via existing inputs, never a new
  rules file or a modified gate).
