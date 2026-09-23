---
description: Author a per-target QA spec that pins an immutable role snapshot from the constitution (spec-roles.json, stamped with its version), plus per-spec role overrides, run-config deltas, and oracle notes. Surfaces a constitution-drift advisory. One spec → N runs.
argument-hint: <target> [--overrides <file.json>]
disable-model-invocation: false
---

Author `.qa/specs/<target>/{qa-spec.md, spec-roles.json}` — the second qa-kit step. The spec copies
the constitution's roles into an **immutable, version-stamped snapshot** the run will later freeze
(`plan_frozen`, ADR-0020). Full input: `$ARGUMENTS` — the first token is `<target>` (a slug for this
feature/page/flow); an optional `--overrides <file.json>` narrows/patches roles for this spec only.

## What to do

1. **Prereq: constitution.** Require `.qa/constitution.state.json`.
   - Absent → tell the operator the project has no constitution yet and offer to run
     `/qa-constitution` first (recommended), OR to proceed with **per-spec-only roles** (author a
     `spec-roles.json` from a fresh role discovery with `constitutionVersion: null` — the
     no-constitution bootstrap, fully wired in a later increment). Never hard-block.
   - Present → read its `version` for the drift check below.

2. **Stack facts.** Invoke `{{SKILL_REF:detecting-stack-profile}}` (qa-kit depends on the engine, so
   invoke by qualified slug) to learn the stack (framework, routes, data layer). Do not reimplement it.

3. **Optional spec-kit ingest.** If a feature spec-kit (`spec.md`/`plan.md`/`tasks.md`) exists for
   this target, invoke `{{SKILL_REF:ingesting-spec-kit}}` to seed oracles/criteria + traceability.
   Record its source in the spec's "Ingested spec-kit" section. Skip if none.

4. **Roles snapshot.** Create the spec dir (`mkdir -p .qa/specs/<target>`). Decide, with the operator,
   which of the constitution's roles this spec needs and any per-spec overrides. Express overrides as a
   JSON file `{subset?:[ids], modify?:[{id,role?,plane?}], add?:[{id,role,plane}]}` (from
   `--overrides`, or author one), then:
   ```
   bash "{{PLUGIN_ROOT}}/scripts/spec-snapshot.sh" create \
       .qa/constitution.state.json .qa/specs/<target> [<overrides.json>]
   ```
   This writes `.qa/specs/<target>/spec-roles.json` = `{constitutionVersion, roles, overrides}`.
   **Never hand-author `spec-roles.json`** — always via `spec-snapshot.sh` (re-run with different
   overrides to change it).

5. **Drift advisory.** If the constitution existed, run
   `bash "{{PLUGIN_ROOT}}/scripts/spec-snapshot.sh" drift .qa/specs/<target>/spec-roles.json <current-version>`
   and print the result plainly (in sync, or "snapshotted from `<stamped>`, constitution now
   `<current>` — re-run `/qa-spec` to refresh"). Advisory only; never auto-migrate.

6. **Data baseline (TDQA).** Author `.qa/specs/<target>/data-baseline.json` — a JSON **array** of only the
   entities the scenarios will touch, each `{entity, origin, identity, scope}`:
   - `origin: "seeded"` = pre-existing baseline data. Declare only the **minimal `identity`** (a key subset,
     e.g. `{"name":"Books"}`) needed to verify the row exists at run time — do NOT mirror the app seeder's
     full values (that duplicates and drifts).
   - `origin: "created"` = the run creates it through the UI during scenarios (`identity: null`; its values
     live in the criterion's `actionInput`, authored by `/qa-scenarios`).
   - `scope` (optional) = the tenant/persona context the baseline count is measured within — a `spec-roles.json`
     persona id / the `authz-matrix` `owningChain`. `null`/omit for single-tenant.
   Then validate it:
   `bash "{{PLUGIN_ROOT}}/scripts/data-baseline.sh" validate .qa/specs/<target>/data-baseline.json`
   — abort and surface `{errors:[…]}` on nonzero. The run reads these back to set the multiplicity baseline.
   Establishment is **declare-and-verify by default (writes nothing)**; opt-in auto-seed (step 6b) may first
   apply the `seeded` rows, but only on a disposable env.

6b. **Seed command (opt-in auto-seed, increment 6b).** OPTIONAL — only if you want qa-kit to *establish* the
   declared `seeded` baseline instead of assuming it is already present. Propose the stack's seed command:
   - Locate a stack profile. The engine emits it **per-run** at `.qa/runs/<run-id>/stack-profile.json`
     (ADR-0002); at authoring time there is no run yet, so use the cache **`.qa/stack-profile.cache.json`** if
     present, else invoke `{{SKILL_REF:detecting-stack-profile}}` to emit one. Then:
     `bash "{{PLUGIN_ROOT}}/scripts/detect-seed.sh" propose <profile-path> .qa/config.json`
   - It prints `{mechanism, command, cwd}` — deriving `command` from the backend component's `framework`/`orm.name`
     **only where a genuine standard exists** (laravel `php artisan db:seed`, rails `bin/rails db:seed`, prisma
     `npx prisma db seed`). A `null` command (django, unknown ORM, generic) means **no auto-seed is available** —
     the operator may still type a `seedCommand` by hand, else stay with declare-and-verify.
   - **The proposal is never run blindly.** Show it; the operator confirms or edits it. Record the confirmed
     command in `qa-spec.md`'s Data baseline section **and** a machine copy
     `.qa/specs/<target>/seed.json = {command, cwd}`. If the operator declines, write no `seed.json` (declare-and-verify).

6c. **Known defects — NEVER an oracle (the project-level registry).** While authoring oracles, you will
   sometimes meet a real, known, unfixed application defect. **Do not write a criterion whose expected
   answer is that failure.** That is what the originating incident did: a criterion pinned
   `page.rendersWithoutServerError` to `"false"`, so an HTTP 500 graded `match: true` and the crash *was*
   the correct answer. The engine's `skills/generating-qa-checklist/scripts/validate-checklist-json.sh`
   now rejects that shape outright, so there is exactly one legal home for such a defect:
   **`.qa/known-defects.json`**.
   - **Start from the shipped example.** The engine ships `.qa/known-defects.json.example` with one fully
     worked entry and a long `_doc` key inside it (the registry is a single top-level array, so there is
     no room for a file-level `_doc` the way `.qa/config.json.example` has one). Copy it to
     `.qa/known-defects.json`, drop the `_doc` key, and edit. Unlike `.qa/config.json`, this file is
     **not** gitignored — keep it in version control, which is what makes a renewal or a removal visible
     in review.
   - **Project-level, not per-spec.** A defect is a property of the **application**, not of a QA target.
     One file at the project root's `.qa/`, shared by every target: two specs touching the broken surface
     share one entry, one ticket, one expiry. Per-spec copies drift, and whichever copy is most convenient
     gets renewed — which is how a waiver becomes permanent. Never write a per-target copy under
     `.qa/specs/<target>/`.
   - **Never a verdict.** A known defect has no `pass`/`fail`, contributes nothing to the tally, and
     cannot be counted as verification of anything. Do not give it a criterion id and do not reference it
     from `checklist.json` as though it were planned coverage.
   - **Schema.** A JSON **array** of entries. Required on every entry, each a non-blank, single-line
     string: `id`, `title`, `ticket`, `expiry`, `severity`, `observedClass`, `surface`,
     `observedBehaviour`. Optional: `observedStatus` (a number). Extra fields are tolerated —
     `migrate-inverted-criterion.sh` adds a `migratedFrom` carrying the criterion id it replaced, which
     is also what makes a re-run of that script idempotent. No string field may carry a control
     character (registry prose is single-line by contract). Enums:
     `observedClass ∈ non-rendering | wrong-value | degraded` and
     `severity ∈ low | medium | high | critical`.
     ```json
     [
       {
         "id": "KD-1",
         "title": "stage_gate_reviews.status='completed' rejected by StageGateReviewStatus",
         "ticket": "z8tvbhteuc",
         "expiry": "2026-10-07",
         "severity": "high",
         "observedClass": "non-rendering",
         "observedStatus": 500,
         "surface": "/admin/evaluations/challenges/{challenge}?tab=gates",
         "observedBehaviour": "HTTP 500, unhandled ValueError from the status enum cast"
       }
     ]
     ```
   - **The three rules that carry the weight** (all enforced by the engine's `scripts/known-defects.sh`.
     Note the packaging boundary from ADR-0022: `{{PLUGIN_ROOT}}` is **per-plugin** and resolves to
     qa-kit's own root, which does not contain that script — invoke it from the engine's checkout/plugin
     root. `migrate-inverted-criterion.sh` prints the exact `known-defects.sh validate <registry>` line to
     run when it finishes):
     - **Severity floor, on structure not prose.** `observedClass: "non-rendering"` forces
       `severity` to `high` or `critical`. The floor gates on the `observedClass` **enum**, never on
       `observedBehaviour` — a gate that greps prose is defeated by rewording. This is the check that
       rejects the originating incident's `severity: "low"`.
     - **`expiry` is capped at 90 days** from today. Without a cap, `2099-01-01` makes the rule a paper
       rule. Renewal needs an explicit new date — a deliberate act, visible in a diff and reviewable in a
       PR. An entry past its `expiry` is `expired`, and `expired` is decided **before** `cleared`.
     - **Clearing requires positive evidence.** An entry becomes `cleared` only when supplied evidence
       shows a **2xx navigation to its `surface`** and no fatal finding on that surface. **The absence of
       a finding never clears anything** — a run that never reached the surface produces exactly the same
       silence as a fixed defect. With no evidence supplied, every entry stays `outstanding`, and an entry
       that was not provably exercised is reported as not exercised this run. **Evidence urls must be
       ABSOLUTE**: a relative or path-less url proves nothing, so it is ignored on the navigation side and
       blocks clearing on the finding side. `surface` is matched against the url's path (and query only
       when the surface itself carries one), with a `{placeholder}` segment matching one-or-more
       characters that are not `/`, `?` or `&`.
   - **Commands** (engine-side, per the note above).
     `known-defects.sh validate .qa/known-defects.json [today]` exits `0` iff
     every entry is well-formed, else prints one `ERROR: entry[<i>].<field>: …` line per violation to
     **stderr** and exits `1` (`2` when the inputs themselves are unusable). `status` takes
     `<registry> <today-YYYY-MM-DD> [--evidence <file>]` and prints a JSON array of
     `{"id":…,"state":"outstanding"|"expired"|"cleared"}` in registry order. Run `validate` after every
     hand-edit; a registry that does not validate is not a home for anything.
   - **Migrating an EXISTING inverted criterion.** If a criterion expecting a failure is already in a
     `checklist.json`, do not hand-edit either file:
     ```
     bash "{{PLUGIN_ROOT}}/scripts/migrate-inverted-criterion.sh" \
         .qa/specs/<target>/checklist.json <criterion-id>
     ```
     It removes the criterion from the plan, appends a registry entry with `ticket` and `expiry` **empty**
     (it cannot invent an owner or a deadline), prints `REQUIRED-FIELDS: ticket expiry`, and refuses to
     report success.
     **EXIT 2 IS THE SUCCESS PATH. Exit 1 is the failure path. Exit 0 is never returned.** A caller — or
     an operator — treating any non-zero result as "the migration failed" silently loses a migration that
     in fact landed. Re-running is idempotent (the append is skipped once `migratedFrom` names the
     criterion), so the cost of the misread is confusion, not corruption. Nothing under `.qa/runs/` is
     ever rewritten: a past run's record, including the original `match: true`, stays as recorded, and a
     target path under `.qa/runs/` is refused outright. Fill in `ticket` and `expiry`, then re-run
     `known-defects.sh validate`.

7. **Write `qa-spec.md` + a machine run-config.** Copy `{{PLUGIN_ROOT}}/templates/qa-spec-template.md`
   to `.qa/specs/<target>/qa-spec.md` and fill in: Target, Scenario selection, Roles (referencing the
   `spec-roles.json` snapshot + the overrides summary), Run-config deltas (only what differs from
   `.qa/config.json`), Oracles & out-of-scope, and the optional Ingested-spec-kit note. **Also write the
   machine copy** `.qa/specs/<target>/run-config.json` — a JSON object of ONLY the run-config deltas
   (`{}` if none), so the run can compute its effective config deterministically (see step 8). In the
   **Oracles** section, state how "correct" is independently determined — never that a failure is
   correct. A known application defect belongs in `.qa/known-defects.json` (step 6c), not in an oracle,
   and not in the out-of-scope list either: "out of scope" says nothing was checked, whereas the registry
   carries an owner, a capped deadline and a severity.

8. **Report plainly:** the target, the stamped `constitutionVersion` + role count, any overrides
   applied, the drift result, the data-baseline entity count (seeded vs created), any known-defect entry
   you wrote or migrated (with the `ticket`/`expiry` fields still owed by a human), and the next step
   (`/qa-scenarios <target>`). State that **roles freeze
   when a run starts** (`plan_frozen`), not now — the snapshot is still soft while authoring. Note that
   the eventual run computes its effective config with
   `bash "{{PLUGIN_ROOT}}/scripts/runconfig-merge.sh" .qa/config.json .qa/specs/<target>/run-config.json`
   (deltas over defaults, per-run; `.qa/config.json` is not mutated) and then runs the engine's
   `{{ENGINE_RUN}} "<target>" .qa/specs/<target>/checklist.json` — which ingests the frozen plan.

   **Data-layer run consumption (TDQA, declare-and-verify):** at pre-flight the run (a) reads each `seeded`
   row of `data-baseline.json` back **within its `scope`** and records the **measured** baseline count
   (readable surfaces only — an unreadable seeded row is *assumed* and its dependent criteria run at
   `confidence: low`); (b) resolves each multiplicity fixture's concrete expected via
   `bash "{{PLUGIN_ROOT}}/scripts/data-baseline.sh" expected-count <measured> <delta>` (so empty-state
   expects the measured baseline, not 0); (c) types every `actionInput` through the UI (ADR-0015); (d) records
   `confidence: low` for any computed criterion whose `expect.oracleSource != "human"`. A missing required
   `seeded` precondition → `defer` (never fake).

   **Opt-in auto-seed exec (increment 6b) — gated, disposable-env only.** This is guidance the run follows; it
   is NOT a change to the engine. BEFORE the read-back verify above, iff a confirmed `.qa/specs/<target>/seed.json`
   exists, the run consults the pure gate
   `bash "{{PLUGIN_ROOT}}/scripts/auto-seed.sh" decide .qa/config.json`:
   - `seed:true` (⇔ `allowApiWrites==true` AND `seedableEnvMarker` non-empty and not the literal bootstrap
     sentinel `"QA_DISPOSABLE_ENV"` (never a deliberate opt-in) AND `environment != "production"` —
     the engine's own write gate) **AND** a human confirmed the exec → run `seed.json`'s `command` in its `cwd`
     (a `Bash` exec — the one write), then fall through to the declare-and-verify read-back to confirm the
     baseline actually landed.
   - `seed:false` → print the `reason` and take the **declare-and-verify path (writes nothing)**.
   The exec only ever runs on a disposable env, with writes allowed, and with explicit human confirmation. On a
   non-disposable env qa-kit never writes — it verifies what is already there.

Guardrails: `spec-roles.json` is a point-in-time COPY, never a live reference to the constitution
(design decision 6); run-config holds only DELTAS over `.qa/config.json`, not a restatement; the
drift check is advisory, never an auto-migrate; a known application defect goes in the project-level
`.qa/known-defects.json`, never into an oracle and never into a per-spec copy.
