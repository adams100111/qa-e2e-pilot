---
description: Expand a qa-kit spec into role storylines + verifiable criteria, compiling the frozen plan (checklist.json) scoped to the spec's snapshot roles. The planned-criteria set becomes what the run may act on.
argument-hint: <target>
disable-model-invocation: false
---

Turn `.qa/specs/<target>/qa-spec.md` into `scenarios.md` (human storylines) + `checklist.json` (the
machine plan the run freezes and `verify-plan.sh` enforces). Third qa-kit step. Full input:
`$ARGUMENTS` — the first token is `<target>`.

## What to do

1. **Prereq.** Require `.qa/specs/<target>/qa-spec.md` **and** `.qa/specs/<target>/spec-roles.json`.
   If either is missing, error and point the operator at `/qa-spec <target>`. Do not proceed.

2. **Read the frozen roles.** Load the spec's role snapshot `spec-roles.json` (`roles[].id`). These —
   and only these — are the roles scenarios may use.

3. **Generate scenarios + criteria.** Invoke `/qa-e2e-pilot:generating-qa-checklist` (and, for
   independent/read-only criteria, `/qa-e2e-pilot:fanning-out-criteria`) scoped to the spec's target
   and its snapshot roles. Do not reimplement checklist logic — reuse the engine's writer so the
   `checklist.json` schema is exactly what `qa-verify`/`required-kinds.sh` already read (a top-level
   array of entries with `id`, `surface`, `kind`, `tags`, role, …). Write `.qa/specs/<target>/scenarios.md`
   (the human storylines) and `.qa/specs/<target>/checklist.json` (the plan).

4. **Alignment check (deterministic, reject on failure).** Every role referenced by any scenario/criterion
   MUST be one of `spec-roles.json`'s `roles[].id`. If a scenario introduces a role not in the snapshot,
   **reject** it — either drop the criterion or send the operator back to `/qa-spec` to add that role via
   an override. The spec's snapshot is the authority; scenarios never invent roles.

5. **The plan is the enforcement contract.** State plainly: the `checklist.json` you just wrote is the
   set of criteria the run may act on. At run time, `verify-plan.sh` (beside `qa-verify`) flags any act
   on a criterion **not** in this plan — so scenarios must be complete before the run, and an unplanned
   act during the run is an out-of-plan violation, not a silent extra.

6. **Report:** the criterion count, the roles covered, any criteria rejected by the alignment check, and
   the next step (`/qa-analyze <target>`).

Guardrails: reuse the engine's checklist writer (never fork the `checklist.json` schema); every scenario
role ∈ `spec-roles.json`; the plan you write is the contract the run is held to.
