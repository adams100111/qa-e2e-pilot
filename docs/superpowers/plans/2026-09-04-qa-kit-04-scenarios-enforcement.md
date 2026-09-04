# qa-kit increment 4 — `/qa-scenarios` + `/qa-analyze` + the enforcement seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
> **⚠️ LAYOUT SUPERSEDED (2026-09-04, dependencies model).** qa-kit is a 2nd Claude plugin (`dependencies:[qa-e2e-pilot]`); it bundles its OWN scripts/commands/templates UNDER `qa-kit/` and reuses the engine's SKILLS by qualified slug `/qa-e2e-pilot:<skill>`. So wherever this plan says `scripts/qa-kit/X.sh` read `qa-kit/scripts/X.sh` (called `${CLAUDE_PLUGIN_ROOT}/scripts/X.sh` from a command); `core/qa-kit/*.command.md` → `qa-kit/commands/*.md` (Claude form); `core/qa-kit/*-template.md` → `qa-kit/templates/*.md`. "Register in the qa-kit manifest commands array" is obsolete — `commands` is a DIRECTORY (default scan): just place the file in `qa-kit/commands/`. See `2026-09-04-qa-kit-02-packaging.md` + memory `qa-kit-plugin-packaging-facts`.
>
>
> **⚠️ THE CRUX INCREMENT — carries a genuine OPEN QUESTION that MUST be resolved as Task 1 before the rest is pinned (see below). This plan is firmer on the two commands than on the enforcement compiler, precisely because the enforcement mechanism depends on a fact about `qa-verify` not yet verified.**
>
> **PROVISIONAL DEPENDENCIES:** consumes increment 3's `spec-roles.json` (frozen roles) + the **existing** `checklist.json` schema that `generating-qa-checklist` produces and `qa-verify`/`required-kinds.sh` read. Pin that schema (Task 1) before writing the compiler.

**Goal:** Build `/qa-scenarios` (expand the spec into role storylines + criteria → `checklist.json`) and `/qa-analyze` (a read-only consistency+coverage gate before the run), and prove **one end-to-end enforcement seam**: the scenarios' planned-criteria set, written into `checklist.json` (the shape `qa-verify` already reads), causes `qa-verify` to **flag an act on an out-of-plan criterion** — with `qa-verify` unmodified. This proves the "steps populate the gate's existing inputs" thesis.

**Architecture:** `/qa-scenarios` reuses `generating-qa-checklist` + `fanning-out-criteria` to produce `scenarios.md` + `checklist.json` scoped to the spec's frozen roles. `/qa-analyze` reuses `analyzing-feature-ui`'s surface map + `ingesting-spec-kit`'s traceability to flag coverage gaps (LLM-reasoned, spec-kit `analyze` pattern — advisory, read-only). The enforcement seam is the criteria written into `checklist.json`; how `qa-verify` consumes it to catch an out-of-plan act is **Task 1's open question**.

## ⚠️ Task 1: RESOLVE the enforcement mechanism (open question — do this FIRST)

**The question:** does the *existing* `qa-verify.sh` detect **an act (in the journal) on a criterion that is NOT in `checklist.json`** — i.e. does it enforce "only-planned-criteria-may-act" today, or does it only verify the criteria that ARE listed (ignoring extras)?

- [ ] **Step 1: Investigate.** Read `scripts/qa-verify.sh` + `skills/checkpointing-qa-memory/scripts/fold.*` + the journal event model (ADR-0020). Determine: when the journal records `criterion_started`/`act_committed` for a `criterionId` absent from `checklist.json`, does `qa-verify` (or `fold`'s anomalies) surface it? Confirm the exact `checklist.json` row schema `qa-verify`/`required-kinds.sh` parse (id, kinds, tags like `human-action`/`cross-tenant`, role).
- [ ] **Step 2: Decide the seam, per the finding:**
  - **(A) `qa-verify` already flags out-of-plan acts** → the seam is *just* "write the planned criteria into `checklist.json`"; the compiler (Task 2) is the whole job. Best case.
  - **(B) It does NOT** → the enforcement needs a check that does NOT modify `qa-verify` (design constraint). Options, in preference order: (i) a `fold` anomaly (`act-for-unlisted-criterion`) surfaced in `fold-anomalies.json` that `qa-ci.sh` gates on — reuses the durable-state layer; (ii) a small standalone `qa-kit-verify-plan.sh` run alongside `qa-verify` (like `session-preflight` sits beside it); NOT modifying `qa-verify`.
  - **Record the decision + rationale**; it repins Task 2. **If the only honest option turns out to require touching `qa-verify`, STOP and escalate** — that violates a binding design constraint and is the human's call.
- [ ] **Step 3: Commit the investigation note** (a short `docs/` note or an ADR-0022 addendum) `docs(qa-kit): enforcement-seam mechanism decided (increment 4 Task 1)`

## Task 2: the scenarios → `checklist.json` planned-criteria compiler + round-trip test

*(Pinned by Task 1's outcome. The contract below assumes seam (A) or (B); the round-trip test is identical either way — it asserts the out-of-plan act is CAUGHT.)*

- [ ] **Step 1: Failing round-trip test** (`tests/qa-kit-enforcement/run.sh`): build a tiny run — a `checklist.json` with criteria `{C1,C2}` (the compiler's output) + a journal (or action-trace) recording an act on `C3` (NOT in the plan) → run the resolved seam (`qa-verify` per (A), or the `fold`-anomaly/`qa-kit-verify-plan.sh` per (B)) → assert it **flags/overrides** (non-zero / an anomaly / a `verifierVerdict` override) for the out-of-plan `C3`; and a control where all acts are on `{C1,C2}` → clean. Dual-engine.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement the compiler** — `/qa-scenarios`'s output step writes the planned criteria into `checklist.json` in the exact schema Task 1 pinned (id + kinds + role + tags), plus (per seam B, if chosen) the `qa-kit-verify-plan.sh` checker. Reuse `generating-qa-checklist`'s existing writer where possible — do not fork the checklist schema.
- [ ] **Step 4:** run → `FAIL=0`; confirm no `qa-verify.sh` modification (`git diff` empty on it).
- [ ] **Step 5: Commit** `feat(qa-kit): scenarios->checklist planned-criteria compiler + out-of-plan-act enforcement (qa-verify unmodified)`

## Task 3: `/qa-scenarios` + `/qa-analyze` command bodies (staged)

**Files (author into the qa-kit plugin, R3-Q3):** `qa-kit/commands/qa-scenarios.md`, `qa-kit/commands/qa-analyze.md`, `qa-kit/qa-analyze-template.md`. **Register both** in the qa-kit manifest `commands` array + the non-Claude build (as Task 3's final step).

- [ ] **Step 1: `/qa-scenarios`** — prereq: `qa-spec.md` + `spec-roles.json` exist (else error). Reuse `generating-qa-checklist` + `fanning-out-criteria` scoped to the spec's frozen roles; **alignment check (deterministic):** every scenario role ∈ `spec-roles.json` (reject otherwise). Write `scenarios.md` + `checklist.json` (Task 2 compiler).
- [ ] **Step 2: `/qa-analyze`** — prereq: `scenarios.md` exists. Reuse `analyzing-feature-ui` surface map + `ingesting-spec-kit` traceability → `analysis.md` flagging coverage gaps (spec item with no scenario, unaddressed risk). **Read-only + advisory** (spec-kit `analyze` pattern — reports, offers remediation the human approves; does not block).
- [ ] **Step 3: Register in qa-kit (R3-Q3) + gate** — add `./commands/qa-scenarios.md` + `./commands/qa-analyze.md` to the qa-kit manifest `commands` array; extend the non-Claude qa-kit build. `build-adapter.sh claude` + `validate-adapters.sh` exit 0; re-run the tests.
- [ ] **Step 4: Commit** `feat(qa-kit): /qa-scenarios + /qa-analyze command bodies (staged; alignment checks + coverage gate)`

## Task 4: docs

- [ ] ADR-0022 note (increment 4 landed: the enforcement seam mechanism + `/qa-scenarios`/`/qa-analyze`); update design/roadmap status. Commit `docs(qa-kit): ADR-0022 note — increment 4 (enforcement seam + scenarios/analyze) landed`.

## Self-Review

**1. Coverage:** the enforcement seam (design §5 layer 3, R2) → Task 1 (mechanism) + Task 2 (compiler + round-trip); `/qa-scenarios` alignment (§2.7) → Task 3 step 1; `/qa-analyze` coverage gate (§2.11) → Task 3 step 2. ✅

**2. Placeholder scan — HONEST:** Task 2's compiler code is *intentionally* not fully pinned here because it depends on Task 1's finding (does `qa-verify` catch out-of-plan acts?) + the exact `checklist.json` schema. This is the one increment where upfront full-detail is genuinely blocked on a fact — Task 1 exists precisely to resolve it before Task 2. The round-trip *test contract* (out-of-plan act must be caught) IS pinned and drives whichever mechanism Task 1 picks.

**3. Type consistency:** `checklist.json` schema is whatever `generating-qa-checklist` already emits + `qa-verify`/`required-kinds.sh` read (pinned in Task 1 — not re-invented); scenario roles checked ⊆ `spec-roles.json` (increment 3's shape). Vocabulary: "step", "run-config"; no `qa-verify` modification.

## Execution Handoff

SDD. **Depends on increment 3** (`spec-roles.json`) + the existing `checklist.json`/`qa-verify`. **Task 1 is a hard gate** — resolve the enforcement mechanism (and escalate if it can only be done by modifying `qa-verify`) before pinning Task 2. Next: increment 5 (`/qa-run` wiring + fixture tests + quick-path/bootstrap).
