# QA spec — {{TARGET}}

> Authored by `/qa-spec`. This spec **pins** an immutable role snapshot (`spec-roles.json`) copied
> from the constitution and stamped with its version. A run freezes and replays that snapshot
> (`plan_frozen`, ADR-0020); the constitution changing later does not affect this spec until you
> re-run `/qa-spec`. One spec → N runs.

## Target

<!-- What is under test: the feature/page/flow, its URL(s), and the entry point. -->

## Scenario selection

<!-- Which scenarios/behaviors this run covers, and which it explicitly does NOT.
     `/qa-scenarios` expands these into role storylines + criteria (checklist.json). -->

## Roles

<!-- Which of the constitution's roles this spec uses, plus any per-spec overrides
     (subset / modify / add). The authoritative machine copy is spec-roles.json in
     this directory, stamped with `constitutionVersion`. Do NOT hand-edit spec-roles.json —
     re-run `/qa-spec` with different overrides instead. -->

- Snapshot: `spec-roles.json` (constitutionVersion: {{CONSTITUTION_VERSION}})
- Overrides applied: {{OVERRIDES_SUMMARY}}

## Run-config

<!-- Per-spec DELTAS over `.qa/config.json` defaults only (drivers, maxParallel,
     criteriaBudget, viewport). Store only what this spec changes — NOT a full restatement.
     A run applies these over config.json for that run (increment 5); config.json is not mutated. -->

## Data baseline (TDQA)

<!-- The entities scenarios touch, machine-mirrored in data-baseline.json. seeded = pre-existing
     (declare only the minimal identity to verify it exists; NOT a mirror of the app seeder).
     created = the run makes it via the UI (values live in the criterion's actionInput). scope =
     the tenant/persona the count is measured within (or —). declare-and-verify only in v1. -->

| entity | origin (seeded/created) | identity (minimal) | scope (persona/tenant or —) |
|--------|-------------------------|--------------------|-----------------------------|
|        |                         |                    |                             |

## Oracles & out-of-scope

<!-- What "correct" means for this target — the spec/domain rules the run recomputes
     independently (never the backend's own formula). And what is explicitly NOT tested here. -->

## Ingested spec-kit (optional)

<!-- If a feature spec-kit (spec.md / plan.md / tasks.md) was ingested, note its source +
     which oracles/criteria were seeded from it. Omit if none. -->
