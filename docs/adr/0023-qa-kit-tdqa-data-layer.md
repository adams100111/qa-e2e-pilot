# ADR-0023 — qa-kit TDQA data layer: provenance-aware baseline + pinned fixtures

## Status

Accepted, 2026-09-05. Implements `docs/superpowers/specs/2026-09-04-qa-kit-tdqa-data-layer-design.md`
(twice grill-hardened). Increment **6a** of qa-kit — the pure helpers (`data-baseline.sh`,
`check-fixtures.sh`) + the `/qa-spec`/`/qa-scenarios`/`/qa-analyze` command augmentations — has landed;
**6b** (opt-in auto-seed + a `detecting-stack-profile` `seed:{}` extension) is a sequenced follow-on.
Builds on ADR-0022 (qa-kit process shell), ADR-0015 (human-interaction discipline), ADR-0011
(regenerate-not-reconcile), ADR-0020 (durable run state / `plan_frozen`).

## Context

qa-kit's spine pinned each criterion's oracle *rule* but not its *data*: input values were chosen by
the agent at run time and expected outputs recomputed live — so runs were non-deterministic, edge-case
values (sub-cent, boundaries) were left to chance, and there was **no seeded-vs-created distinction**.
That last gap is a real latent bug: the engine's `multiplicity-0` oracle asserts "empty list, zero
count… only true before any create," which silently assumes the entity starts at **zero rows** — wrong
in any app with seeded base data. The goal is to make qa-kit **test-data-driven** — declare the data,
pin the expected results, then assert — while keeping the qa-e2e-pilot **engine byte-for-byte unchanged**.

## Decision

1. **Layered, provenance-aware data.** `/qa-spec` authors `.qa/specs/<target>/data-baseline.json` — the
   entities scenarios touch, each `{entity, origin: "seeded"|"created", identity, scope}`. `seeded` =
   pre-existing (declare only the minimal `identity` to verify existence — never a mirror of the app
   seeder); `created` = the run makes it through the UI. `scope` ties the count to a tenant/persona via
   the `authz-matrix` `owningChain`. The field is **`origin`, not `provenance`** — `provenance` is the
   engine's evidence-trust term (`provenance.sh`).
2. **Pinned fixtures, dual-written.** `/qa-scenarios` **augments** the engine's checklist (it does not
   fork it): per criterion it writes the concrete `actionInput` + pinned expected into (a) the criterion's
   **prose oracle line** — the engine's agent reads and asserts this natively, so **no engine change** —
   and (b) a structured `fixture` field on the `checklist.json` row (additive; the validator ignores
   unknown keys) for qa-kit's own gate. `expect` has an **absolute** form `{path,value,tolerance,oracleSource}`
   (computed criteria) and a **relative** count form `{path,baselineOf,delta}` (multiplicity — resolved at
   run start from the measured baseline).
3. **The multiplicity fix rides on pinned counts — engine untouched.** `origin` + the measured, scoped
   baseline let `/qa-scenarios` write the correct count formula (empty-state = measured baseline, N-create =
   baseline + N), which the engine's bake verifies as any pinned expectation. `data-baseline.sh
   expected-count` does the arithmetic deterministically.
4. **Enforcement + honest confidence.** `check-fixtures.sh` (pure, dual-engine, beside `verify-plan.sh`)
   flags every **computing** criterion — `kind ∈ {computed-logic, business-rule}`, the engine's own
   definition of "computes" (`required-kinds.sh` derives `computed` from `kind`; `generating-qa-checklist`
   does not write `requiredKinds` into `checklist.json`, so the gate keys on the reliably-present `kind`) —
   whose pinned `expect` is absent/ill-formed. `.qa/config.json` `fixtures.hardBlock` (default false)
   chooses advisory vs block. A pinned expected earns `confidence: high` **only when human-confirmed**
   (`oracleSource:"human"`), and the human confirms **both** the tricky `actionInput` and the expected —
   an `"llm-suggested"` pin is `confidence: low` (moving the same-model computation earlier buys
   determinism, not independence — labeled honestly, preserving the oracle invariant).
5. **Declare-and-verify (6a); auto-seed deferred (6b).** 6a **writes nothing** to the app — it reads the
   baseline back and defers dependent criteria if a required `seeded` precondition is absent. Auto-applying
   seed data via the stack's mechanism (disposable env only) + detecting that mechanism is 6b.

## Consequences

- **Engine untouched, verified.** No change to `core/`, root `commands/`/`skills/`/`scripts/`, or
  `qa-verify`. The pinned expected is consumed via the prose oracle the engine already reads; the struct
  `fixture` field is qa-kit-only; `check-fixtures.sh`/`data-baseline.sh` are qa-kit-owned and never call an
  engine script at runtime (per-plugin `${CLAUDE_PLUGIN_ROOT}`, ADR-0022).
- **Grill trail.** Two grill rounds corrected the design: `provenance`→`origin`; `confidence: high` gated on
  human confirmation of input+expected; measured (not declared) baseline for idempotency; tenant `scope`;
  and — a correction of an earlier grill's own conclusion — the enforcement trigger is `kind`, not a
  `required-kinds` re-derivation (which is neither written into the checklist nor more powerful).
- **Honest limits.** The full "phased run's verdicts ≡ one-shot" equivalence needs a live agent and is the
  manual accuracy run's job. A seeded row with no readable surface is *assumed* → `confidence: low`.
  Non-Claude qa-kit + auto-seed remain deferred.
- **Reversibility.** Additive: two qa-kit scripts + command prose + an additive `checklist.json` field + one
  config key. Reverting removes them; the engine and the qa-kit spine are unaffected.
