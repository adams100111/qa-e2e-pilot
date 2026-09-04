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

7. **Write `qa-spec.md` + a machine run-config.** Copy `{{PLUGIN_ROOT}}/templates/qa-spec-template.md`
   to `.qa/specs/<target>/qa-spec.md` and fill in: Target, Scenario selection, Roles (referencing the
   `spec-roles.json` snapshot + the overrides summary), Run-config deltas (only what differs from
   `.qa/config.json`), Oracles & out-of-scope, and the optional Ingested-spec-kit note. **Also write the
   machine copy** `.qa/specs/<target>/run-config.json` — a JSON object of ONLY the run-config deltas
   (`{}` if none), so the run can compute its effective config deterministically (see step 7).

8. **Report plainly:** the target, the stamped `constitutionVersion` + role count, any overrides
   applied, the drift result, the data-baseline entity count (seeded vs created), and the next step
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
   - `seed:true` (⇔ `allowApiWrites==true` AND `seedableEnvMarker` non-empty AND `environment != "production"` —
     the engine's own write gate) **AND** a human confirmed the exec → run `seed.json`'s `command` in its `cwd`
     (a `Bash` exec — the one write), then fall through to the declare-and-verify read-back to confirm the
     baseline actually landed.
   - `seed:false` → print the `reason` and take the **declare-and-verify path (writes nothing)**.
   The exec only ever runs on a disposable env, with writes allowed, and with explicit human confirmation. On a
   non-disposable env qa-kit never writes — it verifies what is already there.

Guardrails: `spec-roles.json` is a point-in-time COPY, never a live reference to the constitution
(design decision 6); run-config holds only DELTAS over `.qa/config.json`, not a restatement; the
drift check is advisory, never an auto-migrate.
