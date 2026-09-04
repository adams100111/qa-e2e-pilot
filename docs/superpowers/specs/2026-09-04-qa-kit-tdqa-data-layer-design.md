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
- There is **no seeded-vs-created provenance**, which produces a real latent bug: the engine's
  `multiplicity-0` oracle is *"empty list, zero count… only true before any create criterion runs"*
  (`CONTEXT.md`, `generating-qa-checklist`). That silently assumes the entity **starts at zero rows** —
  **wrong** in any app with seeded base data (seeded categories, a seeded admin). The run has no way to
  tell "seeded baseline" from "what my scenario created," so multiplicity, reconciliation deltas
  (`baseline + created = expected`), and teardown are all off.

Goal: make qa-kit **test-data-driven ("TDQA")** — *declare the data, pin the expected results, then the
run asserts* — while keeping the qa-e2e-pilot **engine byte-for-byte unchanged**.

## 2. Decisions (settled in brainstorming)

1. **Layered** — a spec-level **data baseline** (provenance) + **per-criterion fixtures** (input+expected).
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
  { "entity": "Category", "identity": {"name": "Books"}, "values": {"name": "Books"},
    "provenance": "seeded" },
  { "entity": "User", "identity": {"email": "admin@x"}, "values": {"role": "admin"},
    "provenance": "seeded" },
  { "entity": "Order", "identity": null, "provenance": "expected-created" }
]
```

- `provenance: "seeded"` — pre-existing baseline (declared with known values so the run can verify it and
  set the baseline count). `provenance: "expected-created"` — the run creates it through the UI during
  scenarios (no fixed identity/values here; the criterion's `actionInput` carries them).
- Scoped to entities scenarios touch — **not** a mirror of the DB schema (YAGNI).

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
    "expect": { "path": "total", "value": "0.003", "tolerance": 0, "oracleSource": "spec" },
    "dependsOn": ["Category:Books"]
  } }
```

The prose is the engine's native input (unchanged mechanism); the struct is qa-kit's enforcement mirror.
`/qa-scenarios` authors both from one source so they cannot drift.

## 4. Establishment flow (declare-and-verify + opt-in auto-seed)

At the run's pre-flight/analyze (the engine already bakes — reads persisted state):

1. **(opt-in) Auto-seed** — iff `allowApiWrites` AND `seedableEnvMarker` set AND the stack's seed
   mechanism is known (§7): apply the declared `seeded` rows via that mechanism. Otherwise skip.
2. **Verify baseline** — read each `seeded` row back; confirm it exists with its declared identity.
   Record the actual per-entity baseline count.
3. **Set multiplicity baseline** — the corrected count feeds §5. A **missing required `seeded`
   precondition** → the dependent criteria `defer` (honest — never fake), with a clear reason.
4. **Writes nothing** in the default path; never writes on a non-disposable env.

## 5. The multiplicity fix rides on pinned expectations — engine untouched

Provenance tells `/qa-scenarios` to write **correct pinned counts** into fixtures, which the engine's
bake then verifies against — so the fix is authored *into the data*, requiring **no engine change**:

- empty-state criterion → `expect { path:"count", value: <seeded baseline> }` (not naive `0`).
- multiplicity-1 → `expect { count: baseline + 1 }`; multiplicity-N → `expect { count: baseline + N }`.

The engine's `verifying-backend-persistence` reads the pinned expected count from the criterion's
oracle line (the `checklist.md` prose it already consumes — §3 mechanism 1) exactly as it reads any
oracle; the corrected count is just a normal pinned expectation. `data-baseline.json` and the
structured `fixture` field are qa-kit artifacts (§3 mechanism 2) used only by qa-kit's own
`check-fixtures.sh` and the count computation — the engine never needs to learn a new field.

## 6. Enforcement + confidence

- `qa-kit/scripts/check-fixtures.sh` (pure, dual-engine; beside `verify-plan.sh`) — given `checklist.json`,
  flags every `computed-logic`/`business-rule` criterion whose `fixture.expect` is absent/ill-formed.
  Exit nonzero listing them; a control with all pinned exits clean. Config
  `fixtures.hardBlock` (default `false`) decides block vs advisory.
- **Confidence:** `expect.oracleSource:"spec"` (human/spec-authored) → the criterion's verdict is
  `confidence: high` by construction, dodging the engine's "expected could only come from backend → low"
  trap. A missing pinned value on a computed criterion → `confidence: low` at run.
- `/qa-analyze` gains a **data-gap** section: computed criteria without a pinned expect; `seeded`
  baseline rows no criterion depends on; `expected-created` entities no scenario creates.

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

Every increment task bundles its doc update — not a retrofit. This increment updates:
`CONTEXT.md` (new terms: **data-baseline**, **provenance** = seeded|expected-created, **fixture**,
**pinned expectation**; extend the *multiplicity* entry to note the seeded baseline), `qa-kit/README.md`
(a Data section + the updated spine), a new **ADR-0023** (the data-layer decisions 1–4 + the
multiplicity-fix-via-pinned-counts rationale), and the roadmap/design status. If any invariant lands in
`CLAUDE.md`, add it there too.

## 10. Testing

- `tests/data-baseline/run.sh` — the baseline authoring/validation helper (dual-engine, cross-engine
  byte-identity, malformed-input symmetry — the increment-1 discipline).
- `tests/check-fixtures/run.sh` — the enforcement gate (computed w/o expect flagged; all-pinned clean;
  cross-engine).
- Extend `tests/qa-kit-phases/run.sh` — provenance → correct pinned counts (seeded baseline 2 →
  empty-state expects 2, after 1 create expects 3); a missing required seeded precondition → defer.
- The full phased≡one-shot verdict equivalence remains the **manual accuracy run**'s job (honest).

## 11. Scope / phasing

- **6a (build now):** `data-baseline.json` + fixtures folded into spec/scenarios + `check-fixtures.sh`
  enforcement + the multiplicity-fix-via-pinned-counts + declare-and-verify establishment + docs + tests.
  **Zero write risk, engine untouched** — delivers the entire TDQA value.
- **6b (follow-on):** opt-in auto-seed + the `detecting-stack-profile` `seed:{}` extension (the write
  path, disposable-env only).

## 12. Open questions (settle at plan time, not blockers)

- Exact `identity` matching grammar for verifying a `seeded` row (key subset vs dot-path) — reuse
  `check-action-trace.js`'s path grammar where possible.
- Whether `data-baseline.json` rows carry an explicit `entity`-to-surface hint or derive it from the
  criterion's `dependsOn` — lean derive.
- `expect.value` typing (string for exact decimals to avoid float drift, as `verifying-computed-logic`
  already insists — "compute exact `4000000*0.001`, never pre-round").
