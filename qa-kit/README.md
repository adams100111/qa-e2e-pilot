# qa-kit — a step-gated QA process shell

`qa-kit` is a second plugin in this repo: a spec-kit-style, **step-gated** process shell layered over
the **qa-e2e-pilot** engine. Each step produces one human-reviewable artifact and populates the
engine's existing gate inputs; **qa-e2e-pilot stays the verification engine** (driving, baking, oracle
recomputation, probing, verdicts, evidence). qa-kit adds the *process*, not new verification logic.

## Install (Claude)

Enable the `qa-kit` entry from this repo's marketplace. Its `plugin.json` declares
`"dependencies": ["qa-e2e-pilot"]`, so the engine is co-installed. qa-kit reuses the engine's skills by
qualified slug (`/qa-e2e-pilot:<skill>`) and bundles its own scripts under `qa-kit/scripts/`. The engine
installs standalone and unchanged. **Non-Claude harnesses are not yet supported** (deferred — see ADR-0022).

## The spine

| Step | Command | Produces | Notes |
|------|---------|----------|-------|
| 1 | `/qa-constitution` | `.qa/constitution.state.json` (machine) + `.qa/constitution.md` (human) | Roles regenerate **wholesale** (ADR-0011) + a version/hash + an informational diff on re-run. Customization is per-spec, never here. |
| 2 | `/qa-spec <target>` | `.qa/specs/<target>/{qa-spec.md, spec-roles.json, run-config.json}` | Pins an **immutable, version-stamped** role snapshot from the constitution + per-spec overrides + run-config deltas. Surfaces a **drift advisory**. One spec → N runs. |
| 3 | `/qa-scenarios <target>` | `scenarios.md` + `checklist.json` | Compiles the frozen plan (reusing the engine's checklist writer) scoped to the spec's snapshot roles; every scenario role must be in the snapshot. **This `checklist.json` is the enforcement contract.** |
| 4 | `/qa-analyze <target>` | `analysis.md` | Read-only, **advisory** coverage/consistency gate. Never blocks. |
| 5 | `/qa-e2e-pilot:qa-run "<target>" .qa/specs/<target>/checklist.json` | `.qa/runs/<id>/…` | The engine's existing run — ingests the frozen `checklist.json` (it already accepts a checklist/spec path), freezes it (`plan_frozen`, ADR-0020), drives/bakes/verifies/reports. |

`/qa-status [<target>]` shows where you are + any constitution drift.

## The one enforcement seam (qa-verify unmodified)

The engine's `qa-verify` verifies recorded passes but does **not** reject an act on a criterion absent
from the plan (increment-4 finding — see ADR-0022). qa-kit closes that with a standalone
`qa-kit/scripts/verify-plan.sh` run **beside** `qa-verify`: it compares the run's acted
`checkpoint.json[].criterion_id` against the frozen `checklist.json[].id` and flags any out-of-plan act.
`qa-verify` itself is never modified.

## Bundled helpers (`qa-kit/scripts/`, pure + dual-engine)

- `constitution.sh` — `version` / `diff` / `state` / `render`.
- `spec-snapshot.sh` — `create` (copy+stamp+override) / `drift`.
- `verify-plan.sh` — out-of-plan-act enforcement.
- `runconfig-merge.sh` — effective run config = spec deltas over `.qa/config.json` (per-run, no mutation).
- `data-baseline.sh` — validate `data-baseline.json` (origin/identity/scope) + `expected-count` (measured + delta).
- `check-fixtures.sh` — computing criteria (`kind ∈ {computed-logic, business-rule}`) must carry a well-formed pinned expect.
- `detect-seed.sh` — (6b) propose the stack's seed command by READING the engine's `stack-profile.json` (backend component's `framework`/`orm.name`); never modifies `detecting-stack-profile`.
- `auto-seed.sh` — (6b) `decide` the opt-in write gate: `allowApiWrites` + non-empty `seedableEnvMarker` + `environment != production` (mirrors the engine's write gate). Decides only; never execs.

All are covered by dual-engine tests under `tests/{constitution,spec-snapshot,qa-kit-enforcement,runconfig-merge,data-baseline,check-fixtures,detect-seed,auto-seed,qa-kit-phases}/run.sh`
(cross-engine byte-identity + malformed-input symmetry). The full **phased ≡ one-shot** verdict
equivalence needs a live browser agent and is the **manual accuracy run**'s job (`docs/harness-adapters.md`),
not a headless test.

## Data (TDQA)

qa-kit is **test-data-driven**: declare the data, pin the expected results, then the run asserts.

- **`/qa-spec`** authors `.qa/specs/<target>/data-baseline.json` — the entities scenarios touch, each
  flagged **`origin: seeded`** (pre-existing baseline; declare a minimal identity to verify it) or
  **`created`** (the run makes it via the UI), optionally tenant/persona-`scope`d.
- **`/qa-scenarios`** pins each criterion's `actionInput` + expected into both the prose oracle (the engine
  reads it natively) and a structured `checklist.json` `fixture` field. For **computed/business-rule**
  criteria a human confirms **both** the tricky input and the expected at the HITL gate — that (and only
  that) earns `confidence: high`; an `llm-suggested` pin runs `confidence: low`.
- **The multiplicity fix:** because the baseline distinguishes seeded from created, empty-state expects the
  **measured seeded baseline** (not 0) and N-create expects `baseline + N` — authored into the fixtures, so
  the engine is untouched.
- **`check-fixtures.sh`** (beside `verify-plan.sh`) flags a computing criterion with no well-formed pinned
  expect; `.qa/config.json` `fixtures.hardBlock` (default false) chooses advisory vs block.

**Establishment: declare-and-verify by default (writes nothing)** — the run reads the baseline back and defers a
criterion whose required seeded precondition is absent. **Opt-in auto-seed (6b)** can first *establish* the
`seeded` baseline, disposable-env only: `/qa-spec` proposes the stack's seed command via `detect-seed.sh` (a
human confirms or edits it into `.qa/specs/<target>/seed.json`), and at pre-flight the run runs it **only** when
`auto-seed.sh decide` returns `seed:true` (writes allowed + disposable + not production) **and** a human
confirms — then falls through to the same declare-and-verify read-back to confirm the baseline landed. On a
non-disposable env qa-kit never writes. See [ADR-0023](../docs/adr/0023-qa-kit-tdqa-data-layer.md).

## Invariants qa-kit inherits (does not redefine)

Verdicts `pass|fail|blocked|deferred|error`; confidence `high|low`; the oracle is the spec/domain rule,
never the backend's formula; run state lives in `.qa/`; UI-only action-under-test (ADR-0015). See the
repo `CONTEXT.md` + ADR-0015/0018/0020.
