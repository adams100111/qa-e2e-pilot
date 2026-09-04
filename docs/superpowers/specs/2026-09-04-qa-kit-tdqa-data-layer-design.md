# qa-kit TDQA data/fixtures layer — design

> **Status:** design approved 2026-09-04 (brainstorming). Feeds `writing-plans`. This is increment **6**
> of qa-kit (the spine — increments 1–5 — is complete on Claude; see ADR-0022).

## 1. Problem

qa-kit today pins the **oracle rule** per criterion but not the **data**. Concretely:

- The concrete **input data** is not pinned — a criterion's `action` is prose ("Fill the founder form
  (name, shares) and submit"); the agent picks values at run time. Non-deterministic; edge-case values
  (sub-cent, boundaries, specific N) are left to chance.
- The concrete **expected output** is recomputed live from the rule, not pinned or enforced — the
  `checklist.json` schema has no expected-value field, only `assertedState:{entity,readBackPath,expectChange:bool}`.
- There is **no seeded-vs-created origin** distinction, which produces a real latent bug: the engine's
  `multiplicity-0` oracle is *"empty list, zero count… only true before any create criterion runs"*
  (`CONTEXT.md`, `generating-qa-checklist`). That silently assumes the entity **starts at zero rows** —
  **wrong** in any app with seeded base data (seeded categories, a seeded admin). The run has no way to
  tell "seeded baseline" from "what my scenario created," so multiplicity, reconciliation deltas
  (`baseline + created = expected`), and teardown are all off.

Goal: make qa-kit **test-data-driven ("TDQA")** — *declare the data, pin the expected results, then the
run asserts* — while keeping the qa-e2e-pilot **engine byte-for-byte unchanged**.

## 2. Decisions (settled in brainstorming)

1. **Layered** — a spec-level **data baseline** (origin: seeded/created) + **per-criterion fixtures** (input+expected).
   Not either/or: the baseline fixes multiplicity/reachability; the fixtures give TDD-style pinned
   assertions. Both are what "define users/products/categories… then expect the results" describes.
2. **Establishment = declare-and-verify (default) + opt-in auto-seed (disposable env only).** Default
   writes nothing: read the baseline back, verify, set the multiplicity baseline from reality. On a
   disposable env (`allowApiWrites` + `seedableEnvMarker`) qa-kit *may* first apply the declared seed via
   the stack's seeding mechanism.
3. **Folded into existing steps, no new command.** `/qa-spec` authors `data-baseline.json`;
   `/qa-scenarios` authors each criterion's fixture into `checklist.json`; `/qa-analyze` flags data gaps.
   Spine stays at 5 steps.
4. **Enforcement: required for computed/business-rule, exempt pure-display.** A computed/business-rule
   criterion with no pinned `expect` → run verdict `confidence: low` + `/qa-analyze` flags it; a
   `check-fixtures.sh` (beside `verify-plan.sh`) validates presence/shape. A hard-block-until-pinned
   toggle exists in config, **off by default**. Empty-state/display/loading are exempt (the baseline
   already supplies their expected count).

## 3. Artifacts

**`/qa-spec` → `.qa/specs/<target>/data-baseline.json`** (new). Only the entities scenarios touch:

```json
[
  { "entity": "Category", "identity": {"name": "Books"}, "origin": "seeded",
    "scope": null },
  { "entity": "User", "identity": {"email": "admin@x"}, "origin": "seeded",
    "scope": {"persona": "tenantA-admin"} },
  { "entity": "Order", "identity": null, "origin": "created" }
]
```

- `origin: "seeded"` — pre-existing baseline. Declare only the **minimal `identity`** needed to verify the
  row exists (a key subset, e.g. `{name}` / `{email}`) — **not** a full mirror of the seeder's values
  (that would duplicate and drift from the app's own seeder). `origin: "created"` — the run creates it
  through the UI during scenarios; its values live in the criterion's `actionInput`, not here.
- `scope` (optional) — the tenant/persona context the baseline count is measured **within** (Q3), keyed to
  a `spec-roles.json` persona / the `authz-matrix` `owningChain`. `null`/omitted = global (single-tenant).
- Scoped to entities scenarios touch — **not** a mirror of the DB schema (YAGNI).
- **`origin`, not `provenance`** — `provenance` is already the engine's word for evidence-to-trust-domain
  binding (`provenance.sh`); reusing it would collide (grill Q4).

**`/qa-scenarios` writes each criterion's fixture into TWO places (the key mechanism):**

1. **The criterion's `checklist.md` prose** — the pinned `actionInput` values go into the `action`
   text ("Create an order: **qty=3, unitPrice=0.001**") and the pinned expected into the criterion's
   **oracle line** (where `generating-qa-checklist` *already* records "expected value or rule" and the
   engine's agent *already* reads it). This is how the pinned expectation is **actually used at run
   time — natively, with no engine change**: the agent types the exact inputs through the UI (ADR-0015)
   and `verifying-computed-logic` compares against the pinned expected as its oracle.
2. **A structured `fixture` field in the `checklist.json` row** — additive; `qa-verify`/`required-kinds.sh`
   read only their known fields and ignore this one, so the engine gate is unaffected. This structured
   mirror is what **qa-kit's own `check-fixtures.sh` enforces** and what carries the multiplicity counts:

```json
{ "id": "C-ORDER-01", "surface": "/orders", "kind": "computed-logic", "tags": ["human-action"],
  "action": "Create an order: qty=3, unitPrice=0.001",
  "fixture": {
    "actionInput": { "qty": 3, "unitPrice": 0.001 },
    "expect": { "path": "total", "value": "0.003", "tolerance": 0, "oracleSource": "human" },
    "dependsOn": [ { "entity": "Category", "scope": null } ] } }
```

**`expect` has two forms** (grill-2): an **absolute** form `{path, value, tolerance, oracleSource}` for computed
criteria (what `check-fixtures.sh` gates), and a **relative count** form `{path, baselineOf:{entity,scope},
delta}` for multiplicity criteria (empty-state `delta:0`, N-create `delta:N`) — resolved at run start from the
measured baseline (`data-baseline.sh expected-count`). Multiplicity criteria derive `bake`, not `computed`, so
they are NOT `check-fixtures`-gated; only the run consumes their relative form. `dependsOn` is `[{entity,scope}]`
(objects, same shape as `baselineOf`), not `"Entity:key"` strings.

- The prose is the engine's native input (unchanged mechanism); the struct is qa-kit's enforcement mirror.
  `/qa-scenarios` authors both from one source so they cannot drift.
- **`expect.value`** is a **string for exact decimals/money** (no float drift — `verifying-computed-logic`
  insists "compute exact `4000000*0.001`, never pre-round"); `tolerance` is absolute (0 = exact).
- **`expect.oracleSource`** is `"human"` or `"llm-suggested"` (Q1). At `/qa-scenarios`'s HITL gate a human
  confirms/edits **BOTH** the `actionInput` (the deliberately-tricky values — e.g. the sub-cent `0.001`) **and**
  the pinned expected, for computed criteria (grill-2: the input choice is what catches the edge-case bug, so
  the human must own it, not just the answer). `"human"` (both confirmed) → eligible for `confidence: high`;
  `"llm-suggested"`/absent → `confidence: low` — no more independent than run-time recompute, labeled honestly.
- **`expect.path` aligns with the engine's existing `assertedState.readBackPath`**; `fixture.expect` adds
  the concrete **value** that `assertedState.expectChange` (a bool) lacks — the two are complementary, not
  parallel (the fold-in from grill).

## 4. Establishment flow (declare-and-verify + opt-in auto-seed)

At the run's pre-flight/analyze (the engine already bakes — reads persisted state):

1. **(opt-in) Auto-seed** — iff `allowApiWrites` AND `seedableEnvMarker` set AND the stack's seed
   mechanism is known (§7): apply the declared `seeded` rows via that mechanism. Otherwise skip.
2. **Verify baseline** — read each `seeded` row back **within its `scope`** (the acting persona's tenant
   context, Q3); confirm it exists by its minimal `identity`. Record the **measured** per-entity,
   per-scope baseline count. Verification only works for entities with a **readable surface** (a UI
   list/detail, or an allowed probe); a non-surfaced seeded row is **assumed present + flagged
   low-confidence**, never silently trusted.
3. **Set multiplicity baseline from the MEASURED count** (Q2) — not the declared number, so
   scenario-created data accumulated by prior runs on a non-reset env is absorbed (`expect =
   measured + N`). A **missing required `seeded` precondition** → the dependent criteria `defer`
   (honest — never fake), with a clear reason.
4. **Writes nothing** in the default path; never writes on a non-disposable env. **Idempotency (Q2):**
   on a disposable env, rely on env reset between runs; on a non-disposable env, scenario `created`
   rows use **unique identities** (a run-id/timestamp in `actionInput`) to avoid unique-constraint
   collisions. (Hard teardown/`cleanup` is a **6b** concern — not in 6a.)

## 5. The multiplicity fix rides on pinned expectations — engine untouched

Provenance tells `/qa-scenarios` to write **correct pinned counts** into fixtures, which the engine's
bake then verifies against — so the fix is authored *into the data*, requiring **no engine change**:

- empty-state criterion → `expect { path:"count", value: <measured scoped baseline> }` (not naive `0`).
- multiplicity-1 → `expect { count: measured-baseline + 1 }`; multiplicity-N → `expect { count:
  measured-baseline + N }` — all within the acting persona's `scope` (Q2/Q3). The count is resolved at
  run start from the measured baseline, so `/qa-scenarios` writes the *formula* (`baseline + N`) and the
  run resolves the concrete number.

The engine's `verifying-backend-persistence` reads the pinned expected count from the criterion's
oracle line (the `checklist.md` prose it already consumes — §3 mechanism 1) exactly as it reads any
oracle; the corrected count is just a normal pinned expectation. `data-baseline.json` and the
structured `fixture` field are qa-kit artifacts (§3 mechanism 2) used only by qa-kit's own
`check-fixtures.sh` and the count computation — the engine never needs to learn a new field.

## 6. Enforcement + confidence

- `qa-kit/scripts/check-fixtures.sh` (pure, dual-engine; beside `verify-plan.sh`) — flags every criterion
  whose **`kind ∈ {computed-logic, business-rule}`** whose `fixture.expect` is absent/ill-formed. *(Grill-2
  correction: this IS the engine's own definition of "computes" — `required-kinds.sh` derives `computed`
  from `kind` alone, and `generating-qa-checklist` does NOT write `requiredKinds` into `checklist.json`; so
  keying on the reliably-present `kind` is both correct and the only workable trigger. A criterion that
  computes must be categorized `computed-logic`/`business-rule` by `/qa-scenarios` — the engine's generator
  already does this; a "computing happy-path" is a mis-categorization, not a gate gap.)* Exit nonzero listing
  offenders; all-pinned control clean. Config `fixtures.hardBlock` (default `false`) decides block vs advisory.
- **Confidence (Q1):** a **human-confirmed** pin (`expect.oracleSource:"human"`) → the criterion may
  record `confidence: high` (the oracle is genuinely spec-derived, dodging the "expected could only come
  from backend → low" trap). An **`"llm-suggested"`** or **absent** pin on a computed criterion →
  `confidence: low` at run — pinning without human review only buys determinism, not independence, and we
  label that honestly rather than inflate confidence.
- `/qa-analyze` gains a **data-gap** section: computed criteria without a pinned expect; `seeded`
  baseline rows no criterion depends on; `created` entities no scenario actually creates.

## 7. Stack-seed detection (opt-in auto-seed only)

Extend `detecting-stack-profile` to emit `seed:{mechanism, command}` per stack — Laravel
`php artisan db:seed`, Prisma `prisma db seed`, Rails `rails db:seed`, Django `manage.py loaddata`,
generic → `null` (auto-seed unavailable → declare-and-verify only). This is the one bigger lift and is
**6b** (below); it never runs on a non-disposable env.

## 8. Invariants honored (do not break)

- **Oracle invariant** — `expect` is spec/human-authored, never scraped from the backend's own formula.
- **ADR-0015** — `actionInput` is typed through real UI affordances; only `seeded` *preconditions* may
  be written, and only on a disposable env.
- **Engine untouched** — no change to `core/`, root `commands/`/`skills/`/`scripts/`, or `qa-verify`.
  The fix rides on pinned expectations the engine already reads + qa-kit-owned scripts + additive,
  ignored `checklist.json` fields.
- Dual-engine (`jq`/`python3`), no `grep -P`/`perl`/`node`; no attribution; never commit `dist/`.

## 9. Documentation is in-scope (first-class, per this session's lesson)

Every increment task bundles its doc update — not a retrofit (this session's lesson). This increment
updates: `CONTEXT.md` — new terms **data-baseline**, **origin** (= seeded | created; NOT "provenance",
which is the evidence-trust term), **fixture** (per-criterion input+expected — and disambiguate it from
the accuracy **"fixture project"**), **pinned expectation**, plus the **oracleSource** human/llm-suggested
distinction; and extend the *multiplicity* entry to note the measured, scoped seeded baseline.
`qa-kit/README.md` (a Data section + the updated spine); a new **ADR-0023** (decisions 1–4 + the grill
refinements Q1–Q4 + the multiplicity-fix-via-pinned-counts rationale + the confidence/independence rule);
roadmap/design status. If any invariant lands in `CLAUDE.md`, add it there too.

## 10. Testing

- `tests/data-baseline/run.sh` — the baseline authoring/validation helper (dual-engine, cross-engine
  byte-identity, malformed-input symmetry — the increment-1 discipline).
- `tests/check-fixtures/run.sh` — the enforcement gate: a criterion whose `required-kinds` includes
  `computed` (incl. a `happy-path` that computes) with no `expect` is flagged; a `human`-sourced pin
  passes; an `llm-suggested`/absent pin on a computed row is flagged; all-pinned clean; cross-engine.
- Extend `tests/qa-kit-phases/run.sh` — `origin` → correct **measured, scoped** counts (measured baseline
  2 → empty-state expects 2; after 1 create expects 3; a second scope with baseline 5 → expects 5 then 6);
  a missing required `seeded` precondition → defer; `oracleSource:"llm-suggested"` → confidence:low.
- The full phased≡one-shot verdict equivalence remains the **manual accuracy run**'s job (honest).

## 11. Scope / phasing

- **6a (build now):** `data-baseline.json` + fixtures folded into spec/scenarios + `check-fixtures.sh`
  enforcement + the multiplicity-fix-via-pinned-counts + declare-and-verify establishment + docs + tests.
  **Zero write risk, engine untouched** — delivers the entire TDQA value.
- **6b (follow-on):** opt-in auto-seed + the `detecting-stack-profile` `seed:{}` extension (the write
  path, disposable-env only).

## 12. Grill-round resolutions (2026-09-05) + remaining plan-time detail

**Resolved by the grill (folded into the sections above):**
- **Q1 independence** — a pinned expected earns `confidence: high` only when **human-confirmed**
  (`oracleSource:"human"`); `"llm-suggested"` → `confidence: low` (§6). Preserves the oracle invariant.
- **Q2 idempotency** — multiplicity uses the **measured** baseline (`baseline + N`), disposable env resets,
  non-disposable env uses unique identities for `created` rows; `fixture.cleanup` dropped from 6a (§4/§5).
- **Q3 tenant scope** — baseline is measured **within the acting persona's `scope`** via `authz-matrix`
  `owningChain` (§3/§4).
- **Q4 terms** — `provenance`→`origin` (avoids `provenance.sh` collision); keep "fixture" but disambiguate
  from the accuracy "fixture project" (§3/§9).
- **Enforcement trigger** — `kind ∈ {computed-logic, business-rule}` (the engine's own computed definition;
  grill-2 corrected the earlier "via required-kinds derive" — required-kinds derives computed from kind, and
  requiredKinds isn't written into checklist.json) (§6). **Additive `fixture` field verified safe** — `validate-checklist-json.sh` ignores unknown
  keys (no reject-additional clause).
- **Seeded-row verification** limited to entities with a readable surface/probe; else assumed + low
  confidence (§4). **Minimal `identity`** declared, not a full seeder mirror (§3).

**Remaining detail for plan time (not blockers):**
- Exact `identity` matching grammar (key subset vs dot-path) — reuse `check-action-trace.js`'s path grammar.
- Whether a baseline row's surface is derived from the criterion's `dependsOn` — lean derive.
- The exact shape of the run-start "resolve `baseline + N` → concrete count" step in the qa-kit run wiring.
