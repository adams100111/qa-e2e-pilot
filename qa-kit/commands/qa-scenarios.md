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

4. **Augment each criterion with a TDQA fixture (do NOT re-write the checklist).** The engine writer in
   step 3 already assigned each criterion's `kind` (`computed-logic`/`business-rule` for computing ones —
   that categorization IS the enforcement trigger). Now **augment** its output — for each criterion, write
   the fixture into **both** places from one source so they can't drift:
   - **prose** — put the concrete `actionInput` values into the `action` text and the pinned expected on the
     criterion's oracle line in `scenarios.md` (this is what the engine's agent reads + asserts at run time —
     no engine change);
   - **struct** — add a `fixture` field to the `checklist.json` row.
   Two `expect` shapes:
   - **computed** (`computed-logic`/`business-rule`): `fixture.expect = {path, value, tolerance, oracleSource}`.
     `value` is a **string** for exact decimals/money (never pre-round). `dependsOn` (if any) is
     `[{entity, scope}]` objects.
   - **multiplicity/empty-state** (derives `bake`, not `computed`): `fixture.expect = {path:"count",
     baselineOf:{entity,scope}, delta}` — empty-state `delta:0`, N-create `delta:N`. The concrete count is
     resolved at run start from the measured baseline (never hard-coded to 0).
   Do NOT set `requiredKinds` — the gate keys on `kind`, and the engine derives kinds itself.

5. **HITL — confirm BOTH input and expected (for computed criteria).** For each `computed-logic`/`business-rule`
   criterion, PROMPT the operator to confirm/edit **both** the `actionInput` (the deliberately-tricky values —
   propose defaults, but the human owns the choice: the sub-cent price, the exact boundary) **and** the pinned
   `expect.value`. Set `expect.oracleSource:"human"` only when BOTH are confirmed (→ eligible for
   `confidence: high` at run); otherwise `"llm-suggested"` (→ `confidence: low`, stated honestly).

6. **Alignment check (deterministic, reject on failure).** Every role referenced by any scenario/criterion
   MUST be one of `spec-roles.json`'s `roles[].id`. If a scenario introduces a role not in the snapshot,
   **reject** it — either drop the criterion or send the operator back to `/qa-spec` to add that role via
   an override. The spec's snapshot is the authority; scenarios never invent roles.

7. **Enforce fixtures + the plan is the contract.** Run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-fixtures.sh" .qa/specs/<target>/checklist.json` — surface any
   `missing` (computed criteria lacking a well-formed pinned expect) to the operator (advisory unless
   `.qa/config.json`'s `fixtures.hardBlock` is true). Then state plainly: the `checklist.json` is the set of
   criteria the run may act on; at run time `verify-plan.sh` (beside `qa-verify`) flags any act on a criterion
   NOT in this plan.

8. **Report:** the criterion count, the roles covered, criteria rejected by the alignment check, the
   check-fixtures result (pinned vs unpinned computed), and the next step (`/qa-analyze <target>`).

Guardrails: reuse the engine's checklist writer (never fork the `checklist.json` schema); every scenario
role ∈ `spec-roles.json`; the plan you write is the contract the run is held to.
