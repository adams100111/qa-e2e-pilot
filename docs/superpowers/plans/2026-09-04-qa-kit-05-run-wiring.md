# qa-kit increment 5 — `/qa-run` wiring + fixture tests + quick-path/bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
>
> **⚠️ PROVISIONAL DEPENDENCIES:** consumes increments 1–4's outputs — `.qa/constitution.md` + version, `spec-roles.json`, `scenarios.md`/`checklist.json`, and the increment-4 enforcement seam. **Pin the exact `checklist.json` / `spec-roles.json` shapes from the landed increments before writing the wiring code.** The fixture-test contracts below are firm; the wiring code steps are provisional on those shapes.

**Goal:** Complete the qa-kit spine — wire `/qa-run` to consume the phased artifacts as its Implement input (and freeze `spec-roles.json` at `plan_frozen`), while **keeping `/qa-run` first-class standalone** (the quick path); add the `/qa-spec` **bootstrap** when there's no constitution; and land the **fixture-project phase tests** (design §10), including the decisive one: **a full phased run's findings ≡ a one-shot `/qa-run`'s findings** (the phased shell changes orchestration, not verdicts).

**Architecture:** `/qa-run`, when a `.qa/specs/<target>/` exists, reads its `scenarios.md`/`checklist.json` as the plan to freeze (`plan_frozen`, ADR-0020) — replaying the spec's frozen roles + criteria. When invoked WITHOUT a spec (the quick path), it behaves exactly as today (self-discovers roles, generates its own checklist). `/qa-spec` with no constitution offers bootstrap (`/qa-constitution` first) or per-spec-only roles. This increment is wiring + tests — no new verification logic (the engine is unchanged).

## Global Constraints

- **The quick path is sacred (design decision 10).** `/qa-run "<target>" [checklist]` with no `.qa/specs/` and no constitution MUST behave byte-for-behavior as today (self-discovery, no constitution required). The phased input is an *additive* branch, never a new requirement. A regression here breaks every existing user.
- **Phased run ≡ one-shot findings.** Feeding `/qa-run` the phased `checklist.json` must produce the SAME verdicts as a one-shot run over the same target — the shell reorganizes *when* things are decided, not *what*. This is the increment's decisive test.
- **Freeze at `plan_frozen` (ADR-0020), reproducible.** When `/qa-run` consumes a spec, it freezes that spec's `spec-roles.json` + `checklist.json` into the run journal; a re-run replays the frozen plan (1 spec → N runs, R2-Q5). No mid-run mutation.
- **No engine changes.** `/qa-run`'s wiring reads the phased artifacts and hands them to the existing pipeline; it does not modify the verification skills, `qa-verify`, or the durable-journal logic.
- Deterministic tests, dual-engine where JSON; no attribution; never commit `dist/`.

## File Structure

- `core/qa-kit/qa-run.wiring.md` **(new/modify, staged)** OR an edit to the existing `core/commands/qa-run.md` — the phased-input branch + the standalone-preservation. *(Pin at execution: is `/qa-run` the existing command extended, or a qa-kit wrapper? Leaning: extend the existing `qa-run` body with an "if a `.qa/specs/<target>/` exists, consume it; else quick path" branch, so there's ONE `/qa-run`.)*
- `core/qa-kit/qa-spec.command.md` **(modify)** — add the no-constitution bootstrap branch (increment 3 authored the base).
- `tests/qa-kit-phases/run.sh` **(new)** — the fixture-project phase tests (design §10).

## Task 1: `/qa-run` phased-input wiring + standalone preservation

- [ ] **Step 1: Pin the shapes** — read the landed increment 3 `spec-roles.json` + increment 4 `checklist.json` outputs; confirm exactly what `/qa-run`'s Implement phase needs to consume (the frozen criteria + roles).
- [ ] **Step 2: Wire the phased branch** — in the `/qa-run` command body: if `.qa/specs/<target>/scenarios.md`+`checklist.json` exist, consume them as the plan to freeze (`plan_frozen`), replaying the spec's `spec-roles.json`; else the existing quick path (self-discovery). One command, two branches.
- [ ] **Step 3: Standalone regression** — confirm (in Task 3's tests) the no-spec path is unchanged behavior.
- [ ] **Step 4: Register /qa-run in qa-kit (R3-Q3)** — add `./commands/qa-run.md` (a symlink/shared reference to the existing qa-run command, since /qa-run is shared with qa-e2e-pilot) to the qa-kit manifest `commands` array so the spine ends in `/qa-run` under qa-kit too. `build-adapter.sh claude` + `validate-adapters.sh` exit 0. Commit `feat(qa-kit): /qa-run consumes phased spec artifacts (freeze+replay); quick path preserved; registered in qa-kit`

## Task 1b: consume the spec's run-config at run time (R3-Q2 — close the folded-in `/qa-plan` loop)

`/qa-spec` authors a `## Run-config` deltas section (increment 3) but nothing applies it. This task makes `/qa-run`, when consuming a spec, **merge the spec's run-config deltas over `.qa/config.json`** for that run (drivers/`maxParallel`/`criteriaBudget`/`viewport`).

- [ ] **Step 1:** a small `scripts/qa-kit/runconfig-merge.sh <config.json> <spec-run-config.json>` → prints the effective run config (config.json defaults with the spec's deltas applied); dual-engine; tests (a delta overrides a default; absent delta → default kept; empty → config unchanged).
- [ ] **Step 2:** `/qa-run`'s phased branch calls it and uses the merged config for the run (does not mutate `.qa/config.json` on disk — the merge is per-run). **Register in qa-kit** if it becomes a new command surface (it's a helper, not a command).
- [ ] **Step 3: Commit** `feat(qa-kit): /qa-run applies the spec's run-config deltas over config.json (per-run, closes the /qa-plan fold)`

## Task 2: `/qa-spec` bootstrap (no-constitution path)

- [ ] **Step 1:** extend `/qa-spec`'s prereq handling (increment 3): when `.qa/constitution.md` is absent, offer to bootstrap (`/qa-constitution` first) OR proceed with per-spec-only roles (author `spec-roles.json` from a fresh discovery, no stamped constitution version — mark it `constitutionVersion: null` / "adhoc"). Never hard-block the quick path.
- [ ] **Step 2: Commit** `feat(qa-kit): /qa-spec bootstrap when no constitution (offer or per-spec-only roles)`

## Task 3: fixture-project phase tests (design §10)

- [ ] **Step 1: Write `tests/qa-kit-phases/run.sh`** asserting, against a seeded fixture (reuse `tools/accuracy-harness/fixture/` or a small dedicated one):
  - each step command produces its artifact (`constitution.md`, `qa-spec.md`+`spec-roles.json`, `scenarios.md`+`checklist.json`, `analysis.md`);
  - **prereq gates fire:** missing `qa-spec.md` → `/qa-scenarios` errors (non-zero); a scenario role ∉ `spec-roles.json` → rejected;
  - **the compiled `checklist.json` is the exact shape `qa-verify`/`required-kinds.sh` consume** (schema round-trip — feed it to `qa-verify`, confirm it reads it + the increment-4 out-of-plan-act enforcement fires);
  - **the decisive test — phased ≡ one-shot:** a full phased run on the fixture yields the same finding set (verdicts per criterion) as a one-shot `/qa-run` over the same fixture. *(Where a live agent run isn't scriptable headlessly, assert the equivalence at the checklist/plan level — the phased `checklist.json` ≡ the one-shot's generated checklist for the same target — and note the full end-to-end equivalence is the manual accuracy-run's job, honestly.)*
  - **stateful path:** `/qa-constitution` re-run after a fixture role change → the informational diff is correct (regenerate-wholesale, no merge); an existing spec's `spec-roles.json` stays frozen (its stamped version now shows `drift:stale`).
- [ ] **Step 2:** run → green; dual-engine where JSON.
- [ ] **Step 3: Commit** `test(qa-kit): fixture phase tests — artifacts, gates, checklist round-trip, phased≡one-shot, stateful drift`

## Task 4: final whole-effort review + docs

- [ ] **Step 1:** ADR-0022 final note (all 5 increments landed; the full spine + the enforcement seam + the quick-path preservation). Update the design/roadmap status to "complete."
- [ ] **Step 2:** the SDD final whole-branch review across the qa-kit effort (opus) — confirm: quick path unregressed, phased≡one-shot, `qa-verify` unmodified, no engine changes, vocabulary consistent, both plugins install.
- [ ] **Step 3: Commit + finish** `docs(qa-kit): ADR-0022 — qa-kit spine complete (all 5 increments)`

## Self-Review

**1. Coverage (design §9 v1 remainder + §10 tests):** phased-input wiring + freeze → Task 1; quick-path + bootstrap (decision 10) → Tasks 1/2; fixture phase tests incl. phased≡one-shot → Task 3; final review → Task 4. ✅

**2. Placeholder scan — honest:** the wiring code (Task 1 Step 2) is provisional on increments 3/4's exact `spec-roles.json`/`checklist.json` shapes (Step 1 pins them). The test *contracts* are firm. The phased≡one-shot end-to-end has a documented honesty caveat (headless-scriptability limit → assert at the checklist level + defer full equivalence to the manual accuracy run) rather than over-claiming a headless full-agent comparison.

**3. Type consistency:** consumes `spec-roles.json` (increment 3) + `checklist.json` (increment 4, = `qa-verify`'s shape); freezes via `plan_frozen` (ADR-0020, unchanged); quick path = today's `/qa-run` behavior. Vocabulary: "step", "run-config", freeze/replay.

## Execution Handoff

SDD, **last increment — depends on 1–4.** Pin the consumed shapes (Task 1 Step 1) before wiring. Task 4's final review closes the whole qa-kit effort. After this, the spine (constitution → spec → scenarios → analyze → run) is complete; optional gates + live-block enhancements remain the deferred follow-on efforts (design §9 "later").
