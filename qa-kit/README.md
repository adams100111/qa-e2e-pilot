# qa-kit — a step-gated QA process shell

`qa-kit` is a second plugin in this repo: a spec-kit-style, **step-gated** process shell layered over
the **qa-e2e-pilot** engine. Each step produces one human-reviewable artifact and populates the
engine's existing gate inputs; **qa-e2e-pilot stays the verification engine** (driving, baking, oracle
recomputation, probing, verdicts, evidence). qa-kit adds the *process*, not new verification logic.

## Install (Claude)

Enable the `qa-kit` entry from this repo's marketplace. Its `plugin.json` declares
`"dependencies": [{ "name": "qa-e2e-pilot", "version": "~0.12.0" }]`, so the engine is co-installed
at the highest `qa-e2e-pilot--v0.12.x` git tag (qa-kit 0.3.0 relies on the engine's 0.12 gates,
census and journeys; the constraint resolves only against those release tags). qa-kit reuses the engine's skills by
qualified slug (`/qa-e2e-pilot:<skill>`) and bundles its own scripts under `qa-kit/scripts/`. The engine
installs standalone and unchanged.

## Running on other harnesses (Codex · Pi · opencode)

Since increment 7 ([ADR-0024](../docs/adr/0024-qa-kit-multi-harness.md)) qa-kit runs on all four harnesses.
Claude is the reference build; the others are generated from the shared `qa-kit/core/` (a qa-kit-owned copy of
the engine's ADR-0017 pipeline) into git-ignored `qa-kit/dist/<h>/` and installed per harness. **Install the
engine adapter for that harness FIRST** (the co-install contract — qa-kit's step commands reference the
engine's skills; each installer aborts if the engine's skills dir is absent):

```bash
bash harnesses/pi/install-pi.sh <project>          # engine first  (or codex / opencode)
bash qa-kit/harnesses/pi/install-pi.sh <project>   # then qa-kit
```

Skill references render per harness — Claude `/qa-e2e-pilot:<name>`; **Pi/Codex** a bare `` the `<name>` skill ``
(read from the engine's `.pi/agents/skills/` / `.agents/skills/`); **opencode** the `skills_<name>` tool, which
**requires the community `opencode-skills` plugin** enabled in `opencode.json`. Per-harness details:
`qa-kit/harnesses/<h>/README.md`. Generator + composition are covered by `tests/qakit-adapters/run.sh`; a live
end-to-end run per non-Claude harness is the **manual accuracy run**.

## The spine

| Step | Command | Produces | Notes |
|------|---------|----------|-------|
| 1 | `/qa-constitution` | `.qa/constitution.state.json` (machine) + `.qa/constitution.md` (human) | Roles regenerate **wholesale** (ADR-0011) + a version/hash + an informational diff on re-run. Customization is per-spec, never here. |
| 2 | `/qa-spec <target>` | `.qa/specs/<target>/{qa-spec.md, spec-roles.json, run-config.json}` | Pins an **immutable, version-stamped** role snapshot from the constitution + per-spec overrides + run-config deltas. Surfaces a **drift advisory**. One spec → N runs. |
| 3 | `/qa-scenarios <target>` | `scenarios.md` + `checklist.json` | Compiles the frozen plan (reusing the engine's checklist writer) scoped to the spec's snapshot roles; every scenario role must be in the snapshot. **This `checklist.json` is the enforcement contract.** |
| 4 | `/qa-analyze <target>` | `analysis.md` (+ `oracle-confirm.html` when needed) | Read-only coverage/consistency gate, advisory except the census coverage gate, which **blocks** a `ship` run while any role × surface pair is uncovered. Renders the oracle confirmation page for unconfirmed computed rows (step 4c). |
| 5 | `/qa-e2e-pilot:qa-run "<target>" .qa/specs/<target>/checklist.json` | `.qa/runs/<id>/…` | The engine's existing run — ingests the frozen `checklist.json` (it already accepts a checklist/spec path), freezes it (`plan_frozen`, ADR-0020), drives/bakes/verifies/reports. |
| 6 | `/qa-verify <target> [<run-id>]` | `.qa/specs/<target>/verification.md` | Post-run verification: the out-of-plan-act check (`verify-plan.sh` — the one enforcement seam below) plus a qa-kit-flow-native restatement of the engine's deterministic overrides (`verification.json`). Reports; the script results are the gate. |

`/qa-status [<target>]` shows where you are + any constitution drift. For run-level detail (progress, ETA, verdicts, bugs, ship readiness, trends) use the engine's `/qa-dashboard`.

## The one enforcement seam (qa-verify unmodified)

The engine's `qa-verify` verifies recorded passes but does **not** reject an act on a criterion absent
from the plan (increment-4 finding — see ADR-0022). qa-kit closes that with a standalone
`qa-kit/scripts/verify-plan.sh` run **beside** `qa-verify`: it compares the run's acted
`checkpoint.json[].criterion_id` against the frozen `checklist.json[].id` and flags any out-of-plan act.
`qa-verify` itself is never modified.

## Tracking cases, runs and bugs

`/qa-tracker` picks where the QA work is tracked: local files, GitHub or ClickUp. It writes
`docs/agents/qa-tracker.{md,json}`. After that, `qa-kit/scripts/tracker.sh <verb>` keeps the
tracker in step with the catalog and the runs, as a dry run unless you pass `--apply`. The design
is `docs/superpowers/specs/2026-11-10-qa-tracker-design.md`.

## Bundled helpers (`qa-kit/scripts/`, pure + dual-engine)

- `constitution.sh` — `version` / `diff` / `state` / `render`.
- `spec-snapshot.sh` — `create` (copy+stamp+override) / `drift`.
- `verify-plan.sh` — out-of-plan-act enforcement.
- `runconfig-merge.sh` — effective run config = spec deltas over `.qa/config.json` (per-run, no mutation).
- `data-baseline.sh` — validate `data-baseline.json` (origin/identity/scope) + `expected-count` (measured + delta).
- `check-fixtures.sh` — computing criteria (`kind ∈ {computed-logic, business-rule}`) must carry a well-formed pinned expect.
- `detect-seed.sh` — (6b) propose the stack's seed command by READING the engine's `stack-profile.json` (backend component's `framework`/`orm.name`); never modifies `detecting-stack-profile`.
- `auto-seed.sh` — (6b) `decide` the opt-in write gate: `allowApiWrites` + non-empty `seedableEnvMarker` (excluding the literal bootstrap sentinel `"QA_DISPOSABLE_ENV"`, never a deliberate opt-in) + `environment != production` (mirrors the engine's write gate). Decides only; never execs.
- `migrate-inverted-criterion.sh` — lift a criterion that asserts an application failure into `.qa/known-defects.json`; exits 2 on success until a human fills `ticket`/`expiry`.
- `surface-access.sh` — `derive` / `confirm-table` / `apply [--assume]` / `personas`: who SHOULD reach each census surface (`.qa/surface-access.json`). Crawl reach on a hinted surface without a matching permission hint is never `allowed` until a human confirms it; `--assume` (autonomous setup) marks entries `assumption:true` and never denies.
- `generate-ship-criteria.sh` — census + access + authz matrix → generated rows: load-clean sweep, deny rows only where permission evidence exists, same-role ownership isolation, form input edge cases (with a sampled URL and an action that reaches the form), UX revisits per viewport × locale × color scheme. Token-safe ids; overflow past `criteriaBudget` reported, never dropped.
- `coverage.sh` — role × surface coverage (`covered` / `covered-sweep` / `excluded` / `uncovered`); `--mode block` exits 1 on any uncovered pair, an empty census, or a failed adapter without `--accept-crawl-only`. `--scope` / `--roles` / exclusion globs scope it.
- `oracle-confirm.sh` — `render <checklist> <out.html>`: an offline page (works from `file://`, no network) grouping unconfirmed expected values by business rule, with accept / edit / unknown per row or per group, saving `oracle-decisions.json`; `apply <checklist> <decisions>`: accepted and edited values become `oracleSource: "human"` (backup `checklist.json.bak`), unknown stays as it was. `check-fixtures.sh` also accepts `oracleSource: "spec"` with a contained `citation` `<path>:<line>`. Only `human`/`spec` can ground a high-confidence pass (the engine's ORACLE GATE, ADR-0032).

All are covered by dual-engine tests under `tests/{constitution,spec-snapshot,qa-kit-enforcement,runconfig-merge,data-baseline,check-fixtures,detect-seed,auto-seed,qa-kit-phases,surface-access,ship-criteria,coverage-gate,oracle-confirm}/run.sh`
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
  criteria a human confirms **both** the tricky input and the expected at the HITL gate (or on
  `/qa-analyze`'s oracle confirmation page) — that, or a `spec` citation, earns `confidence: high`; an
  `llm-suggested` pin runs `confidence: low`. Since engine 0.12.0 this is enforced: `checkpoint.sh`
  refuses a high-confidence pass on a row whose `oracleSource` is not `human`/`spec`.
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

qa-kit inherits the engine's usage boundary as-is — see [the engine README's "When NOT to use
this"](../README.md#when-not-to-use-this) (per-commit gating: no; shared staging: degraded; a green
run is measured recall, never "verified correct").

## Invariants qa-kit inherits (does not redefine)

Verdicts `pass|fail|blocked|deferred|error`; confidence `high|low`; the oracle is the spec/domain rule,
never the backend's formula; run state lives in `.qa/`; UI-only action-under-test (ADR-0015). See the
repo `CONTEXT.md` + ADR-0015/0018/0020.
