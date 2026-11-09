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
     `ticket` and `expiry` by hand, then validate the registry with
     `known-defects.sh validate .qa/known-defects.json`.
     **You have to supply the path yourself.** `known-defects.sh` is an **engine** script and qa-kit
     cannot address it: `{{PLUGIN_ROOT}}` is per-plugin and resolves to qa-kit's own root, which does not
     contain it (ADR-0022). The migration script's last line prints
     `Fill both fields in, then: known-defects.sh validate <registry>` — a **bare script name with no
     `bash` and no path**, i.e. a reminder of *which* command to run, not a runnable one. Resolve it
     against the engine's checkout or plugin root before running it. This gap is a known packaging
     limitation, not something to paper over with a guessed path.
   - **The three demoted phrases.** `expected to fail`, `known defect` and `not a regression` are
     deliberately **not** validator rejections — they describe the application's behaviour and are often
     correct. `/qa-analyze` surfaces them as `plan-defect` flags above its verdict line instead. The
     governing line, applied when you author an oracle: **reject process language, never behaviour
     language.**

5c. **UX rows (the UX detectors run only on them).** The engine's run invokes `detecting-visual-ux` only on a
   row tagged `visual-ux` or `ux-revisit`, and `detecting-interaction-ux` only on a row tagged
   `interaction-ux` or on a `#dialog:`/`#sheet:` surface; an always-on sweep finding becomes a `fail@FE`
   only through such a row. When you author criteria by hand (not through `generate-ship-criteria.sh`):
   - **every surface in scope gets a `visual-ux` criterion**, one per surface, the way
     `{{SKILL_REF:analyzing-feature-ui}}` emits it (`surfaceId` set, tag `visual-ux`, plus `interaction-ux`
     on a `#dialog:`/`#sheet:` surface);
   - **every locale and viewport in the profile gets a `ux-revisit` row** for those surfaces: tags
     `ux-revisit` + `visual-ux` + `read-only`, and a `variant` `{viewport, locale, colorScheme}` for each
     non-primary combination (the generator's `ux:<surface>:<persona>@<viewport>-<locale>-<scheme>` rows
     are the model). An Arabic page is only checked for English text by a row at locale `ar`.
   `/qa-analyze` blocks a ship plan with a surface lacking a `visual-ux` row (`coverage.sh
   --require-visual-ux`).

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

7b. **Ship criteria from the census (only when the effective profile is `ship` or `smoke`).** Resolve the
   effective config with the engine's `profile.sh resolve .qa/config.json --run-config
   .qa/specs/<target>/run-config.json --stack-profile <stack-profile.json>` (an engine script: resolve it
   against the engine's checkout or plugin root, ADR-0022; qa-kit cannot path-reference it). The stack
   profile is `.qa/stack-profile.cache.json` when present, else the latest run's
   `.qa/runs/<run-id>/stack-profile.json`, else invoke `{{SKILL_REF:detecting-stack-profile}}` to write one;
   without it the app's locales are unknown and the Arabic/RTL revisits silently vanish. If the resolved
   `locales` is empty, fill it from the adapter output's `locales` (`.qa/census/adapter.json`) in the
   effective-config temp file; still empty means the app default, one pass. If `profile.sh` cannot be
   resolved or fails, stop and report it — do not generate from a guessed config. Skip this step under
   `full`.
   - **Census.** If `.qa/census.json` is missing or older than the last role/permission change, invoke
     `{{SKILL_REF:taking-surface-census}}` first (read-only crawl, then the engine's `census.sh build`).
     `.qa/surface-access.json` must exist (the `/qa-constitution` confirmation round).
   - **Personas.** Use `.qa/specs/<target>/personas-for-generation.json` (written by `/qa-spec`; if it is
     missing, write it now with `surface-access.sh personas .qa/specs/<target>/spec-roles.json
     .qa/config.json`). It holds the spec's roles with the constitution's `permissions`, so generated rows
     use only this spec's roles.
   - **Generate.** Write the effective config to a temp file, then:
     ```
     bash "{{PLUGIN_ROOT}}/scripts/generate-ship-criteria.sh" --census .qa/census.json \
         --access .qa/surface-access.json --matrix .qa/authz-matrix.json \
         --personas .qa/specs/<target>/personas-for-generation.json \
         --config <effective-config.json> --journeys .qa/specs/<target>/journeys.json \
         --checklist .qa/specs/<target>/checklist.json
     ```
     It prints append-ready rows with token-safe ids (`<prefix>-<slug>-<hash>`, which the engine's
     checkpoint and evidence scripts accept) and the readable id in `title` (`load-clean:<surface>:<persona>`,
     `deny:<surface>:<persona>`, `iso:…`, `input:…`, per-surface UX checks `ux:<surface>`, UX revisits `ux:…@<viewport>-<locale>-<scheme>`), each
     carrying `role`, and `url` when the census sampled a concrete URL. UX revisits carry `ux-revisit` +
     `visual-ux`, and rows on a `#dialog:`/`#sheet:` surface carry `interaction-ux`, so the run sends them to
     the UX detectors. It also emits one `visual-ux` row per surface a spec role reached (`ux:<surface>`,
     kind `happy-path`, at the primary variant), so a generated plan passes `--require-visual-ux` without
     hand-authoring; step 5c is for plans written by hand. **Append them to `checklist.json`**
     (merge into the existing top-level array, never a second file), then re-run the alignment check (step 6)
     and `check-fixtures.sh` (step 7) on the merged plan. Never rename the generated ids. A `deny` row tagged
     `needs-confirmation` rests on an unconfirmed access entry; list those for the operator, together with
     the surface-access entries the generator reports as assumptions. Deny rows exist only from positive
     evidence of who is not allowed; never author one by hand to pad coverage.
   - **Journeys.** Now that step rows exist, run `journeys.sh validate .qa/specs/<target>/journeys.json
     .qa/specs/<target>/checklist.json` (engine script); fix every error (priority, missing step id,
     `journey.id`/`journey.step` on the step row) by editing the journeys or the plan before moving on.
   - **Fill gaps.** Run `bash "{{PLUGIN_ROOT}}/scripts/coverage.sh" .qa/census.json
     .qa/specs/<target>/checklist.json --mode advise --roles .qa/specs/<target>/spec-roles.json
     [--scope "<regex from .qa/specs/<target>/coverage-scope.txt>"] --defer-channels` (add `--exclusions
     .qa/specs/<target>/coverage-exclusions.json` if the operator has approved exclusions, each with a
     reason; an exclusion `surfaceId` may use `*`/`?` globs). `--defer-channels` stays on until Increment 4
     ships the mail/notification/job checks; its reason is "channel checks arrive in increment 4". For every
     `uncovered`, `covered-unscoped` or `covered-sweep` row, draft a functional criterion for that surface x
     role pair through the engine's checklist writer (`{{SKILL_REF:generating-qa-checklist}}`), with `role`
     set to the pair's persona (any spec role for a `"*"` pair) and `surfaceId` set — a generated load /
     deny / revisit row (tag `sweep`) proves the surface loads or refuses, not that it works, so it never
     closes a pair under the ship gate. Re-run until `uncovered` is 0 or the operator explicitly excludes
     the pair (with a reason). Under `ship` add `--require-visual-ux` and draft a `visual-ux` row (step 5c)
     for every surface it lists in `uxMissing`. This step drafts; the blocking gate is `/qa-analyze`.

8. **Report:** the criterion count, the roles covered, criteria rejected by the alignment check, the
   check-fixtures result (pinned vs unpinned computed), the generated ship rows (load-clean / deny / needs-confirmation counts) and the coverage percent (functional vs sweep), uncovered pairs left, any criterion migrated to
   `.qa/known-defects.json` (naming the `ticket`/`expiry` a human still owes — and stating that the
   migration script's exit **2** meant success), and the next step (`/qa-analyze <target>`).

Guardrails: reuse the engine's checklist writer (never fork the `checklist.json` schema); every scenario
role ∈ `spec-roles.json`; the plan you write is the contract the run is held to; **no criterion may
assert that the application failed** — a 5xx, an unhandled exception or a crash goes to
`.qa/known-defects.json`, never into an `expect`.
