# qa-kit — "spec-kit for QA" (idea / vision)

**Status: idea / vision — NOT yet brainstormed or approved; captured for later.** This document
records an idea for later brainstorming. It commits to nothing, changes no code, and supersedes no
existing ADR, skill, or plan in this repo.

## 1. One-paragraph pitch

`qa-kit` would be a **separate new plugin** that reimagines QA as a spec-kit-style, phase-gated,
artifact-producing pipeline: `constitution → spec/qa → analyse → plan → scenarios → implement`, with
optional pluggable gates (sanitization, guarantee/assurance-tier, performance, security, ui/ux, …).
It is architecturally modeled on `github/spec-kit` — the same idea of turning a workflow into a small
set of slash commands that each read/write a human-reviewable Markdown artifact and gate progression
on the previous artifact's completeness — but applied to *quality assurance* instead of *feature
development*. The split is: **qa-e2e-pilot is the QA engine/logic** (baking, oracles, multiplicity,
suspected-layer localization, the honesty gate, durable run state, role/persona discovery) — **qa-kit
would be the spec-kit-style process shell** that orchestrates that logic through named phases, each
producing a durable, human-reviewable artifact before the next phase may start. Where qa-e2e-pilot
today runs mostly as one continuous `/qa-run` invocation, qa-kit would expose the same underlying
capabilities as discrete, resumable, checkpoint-gated commands — closer to how spec-kit turns feature
delivery into `/specify → /plan → /tasks → /implement` rather than one big "build the feature" prompt.

## 2. Architectural reference (spec-kit)

Researched via web search and `WebFetch` against `github/spec-kit`'s README and `spec-driven.md`
(2026-09-02). Key facts, with the specific phrasing spec-kit uses:

- **Command sequence.** `/speckit.constitution` (run once per project — "project principles and
  development guidelines that will guide all subsequent development") → `/speckit.specify` (the
  **what and why**, not the tech stack) → `/speckit.clarify` (optional, "recommended before
  `/speckit.plan`") → `/speckit.plan` (tech stack + architecture choices) → `/speckit.tasks`
  (actionable, dependency-ordered task list, independent tasks marked `[P]`) → `/speckit.analyze`
  (cross-artifact consistency & coverage gate, "run after `/speckit.tasks`, before
  `/speckit.implement`") → `/speckit.implement` (executes the plan) → `/speckit.converge` (assesses
  the codebase against spec/plan/tasks and appends remaining work as new tasks).
- **Artifacts live on disk per feature**, in a predictable structure:
  `specs/<NNN-feature-name>/{spec.md, plan.md, data-model.md, contracts/, research.md,
  quickstart.md, tasks.md}` — auto-numbered, one directory per feature, one branch per feature.
  `constitution.md` lives at the project level (`.specify/constitution.md`), not per-feature.
- **Core inversion / spec-as-source-of-truth**: "Specifications don't serve code — code serves
  specifications." Maintaining software means evolving specifications; debugging means fixing the
  spec/plan that generated wrong code; a requirement change is meant to regenerate the affected plan,
  not be hand-patched into code.
- **Phase gates** (spec-kit's "Phase -1" gates inside `/plan`): a Simplicity Gate (≤3 projects, no
  future-proofing), an Anti-Abstraction Gate (use the framework directly, single model
  representation), and an Integration-First Gate (contracts + contract tests exist before
  implementation) — over-engineering must be justified in a "Complexity Tracking" section, not
  silently done.
- **Plugin/package shape**: templates resolved at runtime with priority stacking, extensions that add
  new commands/templates, presets that override templates, bundles that package curated component
  sets — i.e. spec-kit itself is "commands + templates + a constitution," not a monolithic app.
- Sources: [github/spec-kit](https://github.com/github/spec-kit),
  [spec-kit spec-driven.md](https://github.com/github/spec-kit/blob/main/spec-driven.md),
  [zread.ai command walkthrough](https://zread.ai/github/spec-kit/5-core-commands-constitution-specify-plan-tasks-and-implement).

## 3. Logic reference (qa-e2e-pilot)

Grounded in this repo's own vocabulary (`CONTEXT.md`) and its ADRs/skills — qa-kit's phases would
*reuse*, not reimplement, this logic:

- **Criterion / step / verdict / suspected layer** — the atomic unit of QA work and its fixed outcome
  vocabulary (`pass|fail|blocked|deferred|error`, confidence `high|low`, layer
  `FE|route|service|migration|DB`). qa-kit's "implement" phase would still bottom out in these.
- **Oracle, never the backend's own formula** — `verifying-computed-logic` recomputes independently
  from the spec/domain rule; reading backend code only localizes a divergence. This is the load-bearing
  invariant qa-kit's "spec/qa" phase would have to preserve when defining what "correct" means.
- **Baking** (`verifying-backend-persistence`) — a green toast is not a pass; persisted state is read
  back at multiplicity 0/1/N.
- **Roles/personas & scenarios** — `discovering-user-roles` + `confirming-discovered-roles`
  (ADR-0011: two-plane discovery, frontier-round HITL, regenerate-not-reconcile) and ADR-0012
  (role-sensitive vs. shared criteria, most-privileged ordering, cross-role-fk-chain isolation tests).
  A **Scenario** (per CONTEXT.md) is one role's ordered storyline of criteria — the natural unit for a
  qa-kit "scenarios" phase.
- **Criteria fan-out** — `generating-qa-checklist` (surface map + code + optional spec → a
  human-editable checklist) and `fanning-out-criteria` (opt-in parallel path for
  independent/read-only or race-tagged criteria, ADR-0003).
- **Human-interaction discipline / honesty gate** (ADR-0015, ADR-0018) — Act phase is UI-only; a
  UI-impossible action is `fail@FE` confidence high, never a workaround; enforcement has moved
  out-of-agent via capture-hook / block-hook / `qa-verify` so the gate isn't grading the agent's own
  homework. A qa-kit "constitution" phase would encode exactly these non-negotiables.
- **Durable run state** (ADR-0020) — append-only `journal.ndjson` as source of truth, `fold()` to
  compute current state, idempotent acts, portable `/qa-resume`. This is the substrate a multi-command,
  multi-session qa-kit pipeline would need even more than qa-e2e-pilot's single-invocation `/qa-run`
  does today, since each qa-kit phase is its own checkpoint-gated command.
- **UX detection engine** (ADR-0019) — the `detect → localize → adjudicate → classify` pipeline, oracle
  vs. expectation-heuristic split, would supply the optional "ui/ux" gate.
- **Stack profile & spec-kit ingestion** — `detecting-stack-profile` (dual-source stack detection) and
  `ingesting-spec-kit` (already discovers `constitution.md`/`spec.md`/`tasks.md` from a *feature*
  spec-kit and turns acceptance criteria into oracle-carrying criteria + a traceability matrix) are the
  closest existing bridge between the two worlds — qa-kit would generalize this bridge into its own
  first-class pipeline rather than an optional ingestion path.
- **Multi-harness portability** (ADR-0017) — the `core/` + `harnesses/<h>/` + generated `dist/<h>/`
  shape with the Claude byte-oracle, which any new plugin in this family would presumably need to
  answer for too (see Open Questions).

## 4. Proposed qa-kit pipeline

| Phase | Purpose | Output artifact | qa-pilot logic reused |
|---|---|---|---|
| Constitution | Fix QA's non-negotiables for this project | `constitution.md` | Verdict/confidence/layer vocabulary (CONTEXT.md); oracle-not-implementation rule; honesty gate; no-HITL-in-loop invariants (ADR-0015/0018) |
| Spec/QA | Define what "correct" means for the target feature | `qa-spec.md` | `detecting-stack-profile`, oracle definition, acceptance-criteria shape from `ingesting-spec-kit` |
| Analyse | Consistency/coverage gate before planning a run | `analysis.md` | Cross-checks spec ↔ scenarios ↔ risk; akin to `generating-qa-checklist`'s criteria-budget guard and traceability |
| Plan | The run plan | `run-plan.md` | Personas/drivers/budget — `discovering-user-roles`, `confirming-discovered-roles`, driver pool config |
| Scenarios | Role storylines / criteria fan-out | `scenarios.md` | ADR-0011/0012 roles/personas; `generating-qa-checklist`; `fanning-out-criteria`; the `Scenario` term (ADR-0020) |
| Implement | Execute the run | `.qa/runs/<id>/` + `report.md` | The 9 verification skills, `driving-browser-qa`, `verifying-backend-persistence`, `verifying-computed-logic`, `walking-multistep-flows`, `probing-apis-through-browser`, `checkpointing-qa-memory`, `writing-qa-reports`, durable journal (ADR-0020) |

### Constitution
**Purpose:** fix, once per project, the QA invariants that every later phase must respect — the fixed
verdict enum, "oracle is the spec/domain rule, never the backend's own formula," the honesty/act-phase
discipline, and that no phase quietly asks a human mid-loop (Round-based HITL only at defined gates,
per ADR-0011's frontier pattern). **Inputs:** none (or a prior run's constitution to carry forward).
**Output:** `constitution.md`. **Reused logic:** CONTEXT.md's verdict/oracle/suspected-layer
definitions; ADR-0015/0018's UI-only act discipline and out-of-agent enforcement stance.

### Spec/QA
**Purpose:** the quality spec — what "correct" looks like for this feature: which oracles apply, what
acceptance means, what's explicitly out of scope. **Inputs:** target feature, stack profile, optional
ingested spec-kit `spec.md`/`tasks.md`. **Output:** `qa-spec.md`. **Reused logic:**
`detecting-stack-profile` (first-action stack detection), `ingesting-spec-kit` (acceptance criteria →
oracle-carrying criteria), the oracle/expectation-heuristic split (ADR-0019).

### Analyse
**Purpose:** a consistency/coverage gate — does the qa-spec actually cover the surface, do proposed
scenarios trace back to spec items, is anything risky left unaddressed — before committing to a run
plan. **Inputs:** `qa-spec.md` + surface map. **Output:** `analysis.md` (gaps/risks flagged). **Reused
logic:** `analyzing-feature-ui`'s surface-map, `generating-qa-checklist`'s criteria-budget /
prioritized-trim behavior, `ingesting-spec-kit`'s traceability matrix.

### Plan
**Purpose:** the run plan — which personas, which criteria, which drivers, what budget (time,
criteria-budget, parallelism). **Inputs:** `analysis.md`, confirmed roles. **Output:** `run-plan.md`.
**Reused logic:** ADR-0011/0012's persona/role model and criteria-budget mechanism; driver pool /
platform-preset config (`driving-browser-qa`).

### Scenarios
**Purpose:** expand the plan into concrete role storylines — one **Scenario** per confirmed role
(CONTEXT.md), each an ordered set of criteria, including cross-role isolation and race criteria.
**Inputs:** `run-plan.md`. **Output:** `scenarios.md` / `checklist.json`. **Reused logic:**
`discovering-user-roles`, `confirming-discovered-roles`, `generating-qa-checklist`,
`fanning-out-criteria` for the opt-in parallel subset.

### Implement
**Purpose:** actually execute the run — drive the UI, bake, recompute, probe, localize failures to a
suspected layer, and produce the evidence-backed, resumable report. **Inputs:** `scenarios.md` /
checklist. **Output:** `.qa/runs/<run-id>/` (journal, checkpoint, bug-log, traceability) + `report.md`
/ `report.html`. **Reused logic:** essentially the whole existing pipeline —
`driving-browser-qa`, `verifying-backend-persistence`, `verifying-computed-logic`,
`walking-multistep-flows`, `probing-apis-through-browser`, `checkpointing-qa-memory` (durable state,
ADR-0020), `writing-qa-reports`.

### Optional phases

- **Sanitization.** An opt-in gate that checks the target's seed/fixture data and any writes made
  during a run are properly isolated/disposable (ties to `probing-apis-through-browser`'s
  read-only-by-default + gated write-path rules) — for projects where a QA run must never leave residue
  in a shared environment.
- **Guarantee / assurance-tier.** Surfaces ADR-0018's per-harness assurance tiers (Codex `A+`, Claude/
  opencode `A`, Pi `B→A`) and `qa-verify`'s out-of-agent re-drive/re-bake as an explicit, opt-in
  "how strong is this run's proof" gate, rather than an implicit property of the report.
- **Performance.** An opt-in budget/regression gate (response-time, payload-size, or Core-Web-Vitals-
  style thresholds) layered onto criteria already being driven, not a separate crawl.
- **Security.** An opt-in gate for authz/isolation-flavored checks beyond ADR-0012's cross-role-fk-chain
  tests — e.g. injection/IDOR-shaped probes — kept optional because it changes the risk profile of
  probing (still read-only by default, same gated-write rule).
- **UI/UX.** The `detect → localize → adjudicate → classify` engine (ADR-0019) as an optional phase
  layered on top of Implement — objective detectors can yield a real `fail@FE`, subjective aesthetics
  stay advisory-only, never a verdict.

All optional phases are **opt-in gates that plug into Implement (or run alongside it)**, not required
stops on the constitution → … → implement spine.

## 5. Open questions

- Is qa-kit a fork/rewrite of qa-e2e-pilot's skills, or a thin process shell that calls the existing
  skills as-is, phase by phase?
- What is its relationship to qa-e2e-pilot's existing `/qa-run` command and `agents/qa-e2e-pilot.md`
  orchestrator — does `/qa-run` become qa-kit's "Implement" phase, or do the two stay independent?
- One repo or two — does qa-kit live in this repo alongside qa-e2e-pilot, or as a genuinely separate
  plugin/repo that depends on qa-e2e-pilot?
- How do qa-kit's phase artifacts map onto `.qa/`? Does each phase get its own file under
  `.qa/runs/<run-id>/`, or does qa-kit define its own artifact root (mirroring spec-kit's
  `specs/<feature>/`) that only the Implement phase hands off into `.qa/`?
- Does qa-kit inherit ADR-0017's multi-harness portability shape (`core/` + `harness-profiles.json` +
  generated `dist/<h>/` + the Claude byte-oracle), or does it start Claude-only and backfill
  portability later?
- Does qa-kit reuse qa-e2e-pilot's durable journal/fold model (ADR-0020) directly, or does a multi-
  command pipeline need its own, coarser-grained durability story across phases (vs. within a single
  Implement run)?
- Where does `ingesting-spec-kit` sit once qa-kit exists — does it get subsumed into qa-kit's own
  Spec/QA and Analyse phases, or remain a separate ingestion path for *feature* spec-kit artifacts feeding
  into a qa-kit run?
- How much of spec-kit's actual phase-gate machinery (Simplicity/Anti-Abstraction/Integration-First
  gates, `[P]`-marked parallel tasks, auto-numbered feature branches) is worth mirroring literally vs.
  reinterpreting for QA, where the "artifact" is a checklist/report rather than code?

## 6. Explicit non-goals for the idea stage

- No code is written or planned in detail here — this is capture, not design.
- No commitment is made to build qa-kit, on any timeline.
- This document supersedes no existing ADR, skill, plan, or spec in this repo.
- No decision is made on repo layout, naming beyond the working title `qa-kit`, or scope boundaries —
  those are exactly what a future brainstorm would resolve.
