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

2. **Stack facts.** Invoke `/qa-e2e-pilot:detecting-stack-profile` (qa-kit depends on the engine, so
   invoke by qualified slug) to learn the stack (framework, routes, data layer). Do not reimplement it.

3. **Optional spec-kit ingest.** If a feature spec-kit (`spec.md`/`plan.md`/`tasks.md`) exists for
   this target, invoke `/qa-e2e-pilot:ingesting-spec-kit` to seed oracles/criteria + traceability.
   Record its source in the spec's "Ingested spec-kit" section. Skip if none.

4. **Roles snapshot.** Create the spec dir (`mkdir -p .qa/specs/<target>`). Decide, with the operator,
   which of the constitution's roles this spec needs and any per-spec overrides. Express overrides as a
   JSON file `{subset?:[ids], modify?:[{id,role?,plane?}], add?:[{id,role,plane}]}` (from
   `--overrides`, or author one), then:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/spec-snapshot.sh" create \
       .qa/constitution.state.json .qa/specs/<target> [<overrides.json>]
   ```
   This writes `.qa/specs/<target>/spec-roles.json` = `{constitutionVersion, roles, overrides}`.
   **Never hand-author `spec-roles.json`** — always via `spec-snapshot.sh` (re-run with different
   overrides to change it).

5. **Drift advisory.** If the constitution existed, run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/spec-snapshot.sh" drift .qa/specs/<target>/spec-roles.json <current-version>`
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
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/data-baseline.sh" validate .qa/specs/<target>/data-baseline.json`
   — abort and surface `{errors:[…]}` on nonzero. **6a is declare-and-verify only — this writes nothing to the
   app;** the run reads these back to set the multiplicity baseline (auto-seeding is a later increment, 6b).

7. **Write `qa-spec.md` + a machine run-config.** Copy `${CLAUDE_PLUGIN_ROOT}/templates/qa-spec-template.md`
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
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/runconfig-merge.sh" .qa/config.json .qa/specs/<target>/run-config.json`
   (deltas over defaults, per-run; `.qa/config.json` is not mutated) and then runs the engine's
   `/qa-e2e-pilot:qa-run "<target>" .qa/specs/<target>/checklist.json` — which ingests the frozen plan.

Guardrails: `spec-roles.json` is a point-in-time COPY, never a live reference to the constitution
(design decision 6); run-config holds only DELTAS over `.qa/config.json`, not a restatement; the
drift check is advisory, never an auto-migrate.
