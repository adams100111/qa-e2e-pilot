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

3. **Generate scenarios + criteria.** Invoke `{{SKILL_REF:generating-qa-checklist}}` (and, for
   independent/read-only criteria, `{{SKILL_REF:fanning-out-criteria}}`) scoped to the spec's target
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
     resolved at run start from the measured baseline (never hard-coded to 0). Unlike the computed shape
     above, `check-fixtures.sh` does **not** validate this shape (by design — its header documents that
     multiplicity criteria derive `bake`, not `computed`, so they fall outside its gate); a malformed
     `baselineOf`/`delta` is only caught later, when the run resolves it. Author it carefully.
   Do NOT set `requiredKinds` — the gate keys on `kind`, and the engine derives kinds itself.

5. **HITL — confirm BOTH input and expected (for computed criteria).** For each `computed-logic`/`business-rule`
   criterion, PROMPT the operator to confirm/edit **both** the `actionInput` (the deliberately-tricky values —
   propose defaults, but the human owns the choice: the sub-cent price, the exact boundary) **and** the pinned
   `expect.value`. Set `expect.oracleSource:"human"` only when BOTH are confirmed (→ eligible for
   `confidence: high` at run); otherwise `"llm-suggested"` (→ `confidence: low`, stated honestly).

5b. **Never author a criterion that expects the application to FAIL.** A criterion's expected answer is
   what the application does when it is *working*. A 3xx or 4xx may be asserted as correct — an
   authorization refusal, a validation rejection, a 404 on a deleted record are all the application
   working, and `"the save is expected to fail with a validation error"` is a sound oracle for an
   `error-state` criterion. A **5xx, an unhandled exception or a page crash never may**: that is the
   application failing, and pinning it as the expected value grades the crash correct. That is precisely
   what the originating incident did — `page.rendersWithoutServerError` pinned to the string `"false"`, so
   an HTTP 500 recorded `match: true`.
   - **What the engine's validator rejects** (`skills/generating-qa-checklist/scripts/validate-checklist-json.sh`,
     run by the checklist writer in step 3 before the checklist is presented): a `fixture.expect` or
     top-level `expect` whose `path` is in the reserved health namespace at a failing value —
     `page.rendersWithoutServerError` = false, `page.crashed` = true, `console.hasError` = true, or
     `http.status` ≥ 500 — in **any** spelling (the boolean, the string form, the `0`/`1` form). It also
     hard-rejects the phrase `deferred by design` in an oracle/expect field (`oracle`, `oracleNote`,
     `expected`, or a string member of `fixture.expect`/`expect`), and **never** inspects `action`. An
     `http.status` in the 3xx/4xx range stays legal, and domain paths (`counts.evaluators = 2`) are
     untouched.
   - **Instead of authoring one, write a registry entry.** Where you would have authored a criterion
     expecting a failure, file the defect in the project-level **`.qa/known-defects.json`** instead — see
     `/qa-spec` step 6c for the schema and the three rules (required `id`, `title`, `ticket`, `expiry`,
     `severity`, `observedClass`, `surface`, `observedBehaviour`; `observedClass ∈
     non-rendering | wrong-value | degraded` with a `high`/`critical` severity floor when it is
     `non-rendering`; `expiry` capped at 90 days; clearing needs a recorded 2xx navigation to the
     surface, and the absence of a finding never clears). The registry is **project-level** — never a
     per-spec copy under `.qa/specs/<target>/`. A known defect is never a verdict: it has no `pass`/`fail`
     and contributes nothing to the tally, so filing one does not buy the plan any coverage.
   - **For a criterion that is ALREADY in the plan, run the migration — do not hand-edit:**
     ```
     bash "{{PLUGIN_ROOT}}/scripts/migrate-inverted-criterion.sh" \
         .qa/specs/<target>/checklist.json <criterion-id>
     ```
     It removes every row with that id from the checklist, appends a registry entry with `ticket` and
     `expiry` **empty**, prints `REQUIRED-FIELDS: ticket expiry`, and then refuses to report success.
     > **READ THE EXIT CODE CAREFULLY. `2` is the SUCCESS path** — the migration is recorded (or was
     > already recorded) and human input is pending. **`1` is the failure path** — nothing was written.
     > **`0` is never returned**; there is no "done" state for this command. A caller or an operator that
     > treats any non-zero as "it failed" **silently loses a migration that actually landed**. Re-running
     > is idempotent, so the cost is confusion rather than corruption.
     Nothing under `.qa/runs/` is ever rewritten — a past run's record, including the original
     `match: true`, stays as recorded, and a target path under `.qa/runs/` is refused outright. Fill in
     `ticket` and `expiry` by hand, then validate the registry with the engine's
     `known-defects.sh validate .qa/known-defects.json` — an **engine** script, so it is not reachable
     through qa-kit's per-plugin `{{PLUGIN_ROOT}}` (ADR-0022); the migration script's closing line
     prints the exact command to run.
   - **The three demoted phrases.** `expected to fail`, `known defect` and `not a regression` are
     deliberately **not** validator rejections — they describe the application's behaviour and are often
     correct. `/qa-analyze` surfaces them as `plan-defect` flags above its verdict line instead. The
     governing line, applied when you author an oracle: **reject process language, never behaviour
     language.**

6. **Alignment check (deterministic, reject on failure).** Every role referenced by any scenario/criterion
   MUST be one of `spec-roles.json`'s `roles[].id`. If a scenario introduces a role not in the snapshot,
   **reject** it — either drop the criterion or send the operator back to `/qa-spec` to add that role via
   an override. The spec's snapshot is the authority; scenarios never invent roles.

7. **Enforce fixtures + the plan is the contract.** Run
   `bash "{{PLUGIN_ROOT}}/scripts/check-fixtures.sh" .qa/specs/<target>/checklist.json` — surface any
   `missing` (computed criteria lacking a well-formed pinned expect) to the operator (advisory unless
   `.qa/config.json`'s `fixtures.hardBlock` is true). Then state plainly: the `checklist.json` is the set of
   criteria the run may act on; after the run, `/qa-verify` runs `verify-plan.sh` and flags any act on a
   criterion NOT in this plan.

8. **Report:** the criterion count, the roles covered, criteria rejected by the alignment check, the
   check-fixtures result (pinned vs unpinned computed), any criterion migrated to
   `.qa/known-defects.json` (naming the `ticket`/`expiry` a human still owes — and stating that the
   migration script's exit **2** meant success), and the next step (`/qa-analyze <target>`).

Guardrails: reuse the engine's checklist writer (never fork the `checklist.json` schema); every scenario
role ∈ `spec-roles.json`; the plan you write is the contract the run is held to; **no criterion may
assert that the application failed** — a 5xx, an unhandled exception or a crash goes to
`.qa/known-defects.json`, never into an `expect`.
