# qa-kit increment 6a — TDQA data layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
>
> Design: `docs/superpowers/specs/2026-09-04-qa-kit-tdqa-data-layer-design.md` (grill-hardened 2026-09-05).
> Layout follows the dependencies model: qa-kit-owned scripts under `qa-kit/scripts/`, commands under
> `qa-kit/commands/`, called via `${CLAUDE_PLUGIN_ROOT}`; engine skills invoked by qualified slug.

**Goal:** Make qa-kit test-data-driven — declare a provenance-aware **data baseline** (`origin: seeded|created`,
tenant-`scope`d) + per-criterion **pinned input+expected fixtures**, enforce that computed criteria carry a
pinned expected, and fix the multiplicity-0-vs-seed bug — with the qa-e2e-pilot **engine byte-for-byte unchanged**.

**Architecture:** Two new pure dual-engine scripts (`data-baseline.sh`, `check-fixtures.sh`) + edits to the
qa-kit commands `/qa-spec`, `/qa-scenarios`, `/qa-analyze` (Claude-form) that author `data-baseline.json` and
the dual-written fixtures (prose oracle line the engine reads natively + a structured `fixture` field qa-kit
enforces). "Computes" is decided by the criterion's `kind` (`computed-logic`/`business-rule`) — the engine's
own definition, assigned by `generating-qa-checklist` at authoring time and reliably present in `checklist.json`;
`check-fixtures.sh` keys on `kind` and never reads `requiredKinds` (which the engine doesn't write there) and
never calls an engine script at runtime.

**Tech Stack:** Bash + `jq`-preferred/`python3`-fallback (repo idiom); dual-engine tests mirroring
`tests/spec-snapshot/run.sh` + `tests/qa-kit-enforcement/run.sh`.

## Global Constraints

- **Engine untouched.** No change to `core/`, root `commands/`/`skills/`/`scripts/`, or `qa-verify`. qa-kit
  scripts live under `qa-kit/scripts/` (called `${CLAUDE_PLUGIN_ROOT}/scripts/…`); engine skills invoked as
  `/qa-e2e-pilot:<skill>`. The `fixture` field is **additive** to `checklist.json` (verified: `validate-checklist-json.sh`
  ignores unknown keys). qa-kit scripts NEVER call an engine script at runtime.
- **Oracle invariant + confidence (Q1).** `expect` is spec/human-authored, never scraped from the backend.
  `expect.oracleSource ∈ {"human","llm-suggested"}`; only `"human"` (confirmed at `/qa-scenarios`'s HITL gate)
  earns `confidence: high` at run; `"llm-suggested"`/absent on a computed criterion → `confidence: low`.
- **ADR-0015.** `actionInput` values are typed through real UI affordances; only `seeded` preconditions may be
  written, and only on a disposable env (6b, not here). 6a is **declare-and-verify only — writes nothing**.
- **Terms (Q4):** the origin field is `origin` (values `seeded`|`created`), NOT `provenance` (that word is the
  engine's evidence-trust term, `provenance.sh`). The per-criterion artifact is a "fixture"; the accuracy
  harness is a "fixture project" — keep them distinct.
- **Value typing:** `expect.value` is a **string** for exact decimals/money (no float drift); `tolerance` is an
  absolute number (0 = exact).
- Deterministic + dual-engine (`jq`/`python3`, honor `QA_ENGINE`, die-if-neither); no `grep -P`/`perl`/`node`;
  no Claude/Anthropic attribution / `Co-Authored-By`; never commit `dist/`.
- **Docs are a first-class step in every task** (user requirement) — no retrofit.
- **6a scope:** declare-and-verify + fixtures + enforcement + multiplicity fix. **Auto-seed + stack-seed
  detection = 6b (a later plan).** `fixture.cleanup` is NOT in 6a.

## File Structure

- `qa-kit/scripts/data-baseline.sh` **(new)** — `validate` (shape) + `expected-count` (measured+delta). Pure.
- `tests/data-baseline/run.sh` **(new)** — dual-engine tests.
- `qa-kit/scripts/check-fixtures.sh` **(new)** — structural gate: a row requiring `computed` must carry a
  well-formed `fixture.expect`. Pure, dual-engine.
- `tests/check-fixtures/run.sh` **(new)** — dual-engine tests.
- `qa-kit/commands/qa-spec.md` **(modify)** + `qa-kit/templates/qa-spec-template.md` **(modify)** — author
  `data-baseline.json` + a Data-baseline spec section.
- `qa-kit/commands/qa-scenarios.md` **(modify)** — augment the engine checklist with fixtures (dual-write) + relative baseline+N counts.
- `qa-kit/commands/qa-analyze.md` **(modify)** + `qa-kit/templates/qa-analyze-template.md` **(modify)** —
  a Data-gaps section.
- `tests/qa-kit-phases/run.sh` **(modify)** — extend the integration test (origin→measured/scoped counts;
  check-fixtures gate; oracleSource→confidence).
- `docs/adr/0023-qa-kit-tdqa-data-layer.md` **(new)**; `CONTEXT.md`, `qa-kit/README.md`, `CLAUDE.md`,
  `docs/superpowers/plans/2026-09-04-qa-kit-roadmap.md`, the design spec status **(modify)** — docs.

## Task 1: `data-baseline.sh` — validate + expected-count

**Files:** Create `qa-kit/scripts/data-baseline.sh`, `tests/data-baseline/run.sh`.

**Interfaces:**
- `data-baseline.sh validate <data-baseline.json>` → exit 0 if valid, else nonzero + a JSON `{errors:[…]}` on
  stdout. Valid = a top-level **array**; each row an object with: `entity` (non-empty string); `origin` ∈
  `{"seeded","created"}`; `identity` (object or `null`); `scope` (object or `null`/absent). A `seeded` row
  SHOULD have a non-null `identity` (warn, not error, since some seeded rows aren't surface-readable). Unknown
  extra keys allowed (forward-compat).
- `data-baseline.sh expected-count <measured-int> <delta-int>` → prints `measured+delta` (integer). Dies on
  non-integer input. (Used by run-wiring to resolve `baseline+N` deterministically.)

- [ ] **Step 1: Write the failing tests** (`tests/data-baseline/run.sh`, dual-engine — mirror
  `tests/spec-snapshot/run.sh`'s `run_engine jq`/`run_engine python3` + a cross-engine block):

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/data-baseline.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' '[{"entity":"Category","origin":"seeded","identity":{"name":"Books"},"scope":null},{"entity":"Order","origin":"created","identity":null}]' > "$T/ok.json"
  QA_ENGINE=$E bash "$SH" validate "$T/ok.json" >/dev/null; check "$E valid passes" "$?" "0"
  printf '%s' '[{"entity":"X","origin":"bogus"}]' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" validate "$T/bad.json" >/dev/null 2>&1; check "$E bad origin fails" "$?" "1"
  printf '%s' '{"not":"array"}' > "$T/na.json"
  QA_ENGINE=$E bash "$SH" validate "$T/na.json" >/dev/null 2>&1; check "$E non-array fails" "$?" "1"
  printf '%s' '[{"origin":"seeded","identity":null}]' > "$T/noent.json"
  QA_ENGINE=$E bash "$SH" validate "$T/noent.json" >/dev/null 2>&1; check "$E missing entity fails" "$?" "1"
  check "$E expected-count sums" "$(QA_ENGINE=$E bash "$SH" expected-count 2 1)" "3"
  QA_ENGINE=$E bash "$SH" expected-count 2 x >/dev/null 2>&1; check "$E non-int delta dies" "$?" "1"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
echo "data-baseline: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (`bash tests/data-baseline/run.sh` → script missing).
- [ ] **Step 3: Implement `qa-kit/scripts/data-baseline.sh`** — copy the header/`die`/`has_jq`/`has_py`/`QA_ENGINE`
  idiom from `qa-kit/scripts/spec-snapshot.sh` verbatim. `validate`: assert top-level array; per row assert
  `entity` is a non-empty string, `origin ∈ {seeded,created}`, `identity` is object|null, `scope` is object|null
  when present; collect errors; nonzero + `{errors:[…]}` if any. `expected-count`: validate both args are
  integers (`case "$x" in (*[!0-9-]*) die ;; esac` or python int()); print the sum. Dual-engine (jq arithmetic
  or python).
- [ ] **Step 4: Run → `FAIL=0`**; `bash -n qa-kit/scripts/data-baseline.sh`.
- [ ] **Step 5: Commit** `feat(qa-kit): data-baseline.sh — validate data-baseline.json (origin/identity/scope) + expected-count (dual-engine)`

## Task 2: `check-fixtures.sh` — computed-criterion pinned-expect gate

**Files:** Create `qa-kit/scripts/check-fixtures.sh`, `tests/check-fixtures/run.sh`.

**Interfaces:**
- `check-fixtures.sh <checklist.json>` → for each row whose **`kind ∈ {"computed-logic","business-rule"}`**
  (case-insensitive) — this IS the engine's own definition of "computes" (`required-kinds.sh`'s
  `COMPUTED_KIND_RE`, rule 2; verified) — assert a well-formed **absolute** `fixture.expect`: `expect.path`
  (non-empty string), `expect.value` (present, string or number), `expect.tolerance` (number),
  `expect.oracleSource ∈ {"human","llm-suggested"}`. Prints `{ok, missing:[{id,reason}],
  sources:{human:<n>,llmSuggested:<n>}}`. Exit 0 iff every such row has a well-formed absolute `expect`; else
  exit 1 (offenders in `missing`). Non-computing rows are ignored (multiplicity rows derive `bake`, not
  `computed` — verified — so they are NOT gated here; their relative count form is asserted by the run, not by
  this gate).
  *(Rationale, verified: `generating-qa-checklist` does NOT write `requiredKinds` into `checklist.json`
  (Step 7 derives kinds later), so this gate keys on `kind` — a REQUIRED, reliably-present field — not on
  `requiredKinds`. Keying on `kind` is also no less powerful, since `required-kinds` derives `computed`
  from `kind` alone. A criterion that computes must be categorized `computed-logic`/`business-rule` by
  `/qa-scenarios` — the engine's generator already does this; a mis-categorized "computing happy-path" is an
  authoring error fixed by correct categorization, not by this gate. No engine script is called at runtime.)*

- [ ] **Step 1: Write the failing tests** (`tests/check-fixtures/run.sh`, dual-engine + cross-engine + a
  malformed case; mirror `tests/qa-kit-enforcement/run.sh`):

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/check-fixtures.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
OKROW='{"id":"C1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"actionInput":{"q":3},"expect":{"path":"total","value":"0.003","tolerance":0,"oracleSource":"human"}}}'
DISPLAY='{"id":"C2","surface":"/x","kind":"empty-state","tags":["read-only"],"action":"a"}'
MISSING='{"id":"C3","surface":"/x","kind":"computed-logic","tags":[],"action":"a"}'
BIZRULE='{"id":"C4","surface":"/x","kind":"business-rule","tags":[],"action":"a"}'
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '[%s,%s]' "$OKROW" "$DISPLAY" > "$T/ok.json"
  QA_ENGINE=$E bash "$SH" "$T/ok.json" >/dev/null; check "$E computed pinned + display exempt -> ok" "$?" "0"
  printf '[%s]' "$MISSING" > "$T/m.json"
  local out; out="$(QA_ENGINE=$E bash "$SH" "$T/m.json")"; local rc=$?
  check "$E computed-logic missing expect -> exit 1" "$rc" "1"
  check "$E missing lists C3" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(any(m["id"]=="C3" for m in json.load(sys.stdin)["missing"]))')" "True"
  printf '[%s]' "$BIZRULE" > "$T/br.json"
  QA_ENGINE=$E bash "$SH" "$T/br.json" >/dev/null 2>&1; check "$E business-rule missing expect -> exit 1 (kind trigger)" "$?" "1"
  printf '%s' '{"nope":1}' > "$T/na.json"
  QA_ENGINE=$E bash "$SH" "$T/na.json" >/dev/null 2>&1; check "$E non-array dies" "$?" "1"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '[%s,%s]' "$MISSING" "$OKROW" > "$X/c.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/c.json"; true)"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/c.json"; true)"
  check "cross-engine report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"; rm -rf "$X"
fi
echo "check-fixtures: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: Implement `qa-kit/scripts/check-fixtures.sh`** — idiom from `qa-kit/scripts/verify-plan.sh`.
  Parse the top-level array (die if not array). A row is "computing" iff
  `(.kind | ascii_downcase | IN("computed-logic","business-rule"))` — this is the ONLY trigger (matches the
  engine's `COMPUTED_KIND_RE`; do NOT read `requiredKinds`, which isn't written into `checklist.json`). For each
  computing row, the absolute `expect` is well-formed iff `fixture.expect.path` is a non-empty string,
  `fixture.expect.value` is present (string or number), `fixture.expect.tolerance` is a number, and
  `fixture.expect.oracleSource` ∈ `{"human","llm-suggested"}`. Build `missing` = `[{id, reason}]` for offenders;
  `sources` counts by oracleSource; `ok = (missing|length==0)`. Print the object (sorted for cross-engine
  byte-identity — jq `--sort-keys`, python `sort_keys=True`, `missing` sorted by id). Exit `0` iff ok else `1`.
- [ ] **Step 4: Run → `FAIL=0`**; `bash -n`.
- [ ] **Step 5: Commit** `feat(qa-kit): check-fixtures.sh — computed criteria (kind=computed-logic/business-rule) must carry a well-formed pinned expect (qa-verify untouched)`

## Task 3: `/qa-spec` authors `data-baseline.json` + template section

**Files:** Modify `qa-kit/commands/qa-spec.md`, `qa-kit/templates/qa-spec-template.md`.

- [ ] **Step 1: Template** — add a `## Data baseline` section to `qa-spec-template.md`: a table of the entities
  scenarios touch, columns `entity | origin (seeded|created) | identity (minimal) | scope (persona/tenant or —)`,
  with a note: "seeded = pre-existing (declare only the minimal identity to verify it exists — do NOT mirror the
  seeder); created = the run makes it via the UI (values live in the criterion's actionInput)."
- [ ] **Step 2: Command body** — in `qa-kit/commands/qa-spec.md`, add a step after the roles snapshot: author
  `.qa/specs/<target>/data-baseline.json` (the array in the design §3), then
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/data-baseline.sh" validate .qa/specs/<target>/data-baseline.json`
  (abort + surface errors on nonzero). State: declare-and-verify only (no writes in v1); `scope` reuses a
  `spec-roles.json` persona when the app is multi-tenant.
- [ ] **Step 3: Docs** — note the new artifact in the command's guardrails; nothing else ships yet.
- [ ] **Step 4: Gate** — `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh`
  exit 0 (engine untouched); `bash tests/data-baseline/run.sh` green.
- [ ] **Step 5: Commit** `feat(qa-kit): /qa-spec authors + validates data-baseline.json (origin/identity/scope); template Data-baseline section`

## Task 4: `/qa-scenarios` augments the checklist with fixtures + relative baseline+N

**Files:** Modify `qa-kit/commands/qa-scenarios.md`.

- [ ] **Step 1: Command body — AUGMENT the engine's checklist (do not write it from scratch).** `/qa-scenarios`
  first runs `/qa-e2e-pilot:generating-qa-checklist` (which writes `scenarios.md`/`checklist.md`/`checklist.json`
  and assigns each criterion's `kind`, including `computed-logic`/`business-rule` for computing criteria — that
  categorization IS the enforcement trigger, so a computing criterion must carry the computed kind, not
  `happy-path`). Then, for each criterion, `/qa-scenarios` **augments** that output: (a) **prose** — put the
  concrete `actionInput` values into the `action` text and the pinned expected on the criterion's oracle line
  (upgrading "the rule" to a concrete pinned value); (b) **struct** — add a `fixture` field to the `checklist.json`
  row. It does NOT set `requiredKinds` (the gate keys on `kind`, and the engine derives kinds itself).
  `expect.value` is a string for exact decimals. `fixture.dependsOn` is `[{entity, scope}]` (objects — same
  shape as `baselineOf` below), not `"Entity:key"` strings.
- [ ] **Step 2: HITL — confirm BOTH input and expected (design Q, this grill).** For any `computed-logic`/
  `business-rule` criterion, the command PROMPTS the operator to confirm/edit **both** the `actionInput` (the
  deliberately-tricky values — the LLM proposes defaults, the human owns the choice) **and** the pinned
  `expect.value`. Set `expect.oracleSource:"human"` (→ eligible for `confidence: high`) only when BOTH are
  human-confirmed; otherwise `"llm-suggested"` (→ `confidence: low` at run). State this plainly.
- [ ] **Step 3: Multiplicity via measured, scoped baseline (Q2/Q3) — RELATIVE expect form.** For
  empty-state/multiplicity criteria (`kind` derives `bake`, NOT `computed` — so they are not `check-fixtures`
  gated), write the RELATIVE expect: `fixture.expect = { "path":"count", "baselineOf":{"entity":"Category",
  "scope":<scope|null>}, "delta": N }` — empty-state `delta:0`, N-create `delta:N`. The concrete count is
  resolved at run start from the measured baseline (Task 6 via `data-baseline.sh expected-count`). This is a
  distinct expect shape from the absolute `{path,value,tolerance}` used by computed criteria.
- [ ] **Step 4: Enforcement call** — after writing `checklist.json`, run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-fixtures.sh" .qa/specs/<target>/checklist.json`; surface any
  `missing` to the operator (advisory unless `fixtures.hardBlock`).
- [ ] **Step 5: Docs** — update the command's guardrails (dual-write single-source; prose is the engine's input,
  struct is qa-kit's mirror).
- [ ] **Step 6: Gate + Commit** — build/validate exit 0; `bash tests/check-fixtures/run.sh` green.
  `feat(qa-kit): /qa-scenarios dual-writes fixtures (prose oracle + struct) + HITL-confirmed input+expected + relative baseline+N counts`

## Task 5: `/qa-analyze` data-gaps section

**Files:** Modify `qa-kit/commands/qa-analyze.md`, `qa-kit/templates/qa-analyze-template.md`.

- [ ] **Step 1: Template** — add a `## Data gaps` section to `qa-analyze-template.md`: computed criteria with no
  pinned expect (from `check-fixtures.sh`); `seeded` baseline rows no criterion `dependsOn`; `created` entities
  no scenario creates; a seeded row with no readable surface (assumed → low confidence).
- [ ] **Step 2: Command body** — `/qa-analyze` runs `check-fixtures.sh` + cross-checks `data-baseline.json`
  against `checklist.json` `dependsOn`, writing the Data-gaps section. Read-only + advisory (never blocks).
- [ ] **Step 3: Docs + Gate + Commit** — build/validate exit 0.
  `feat(qa-kit): /qa-analyze reports data gaps (unpinned computed, orphan baseline, unreadable seeded)`

## Task 6: run-wiring guidance — measured/scoped baseline + confidence

**Files:** Modify `qa-kit/commands/qa-spec.md` (the run note) + `qa-kit/README.md` (spine).

- [ ] **Step 1** — document, in the `/qa-spec` run note + README, how a run consumes the data layer against the
  UNMODIFIED engine `/qa-run`: at pre-flight the agent (1) reads each `seeded` row back within its `scope` and
  records the **measured** baseline count (readable surfaces only; unreadable → assumed, low confidence);
  (2) resolves each multiplicity fixture's concrete expected via
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/data-baseline.sh" expected-count <measured> <delta>`; (3) types each
  `actionInput` through the UI (ADR-0015); (4) records `confidence: low` for any computed criterion whose
  `expect.oracleSource != "human"`. A missing required `seeded` precondition → `defer` (never fake).
- [ ] **Step 2: Commit** `docs(qa-kit): run-wiring guidance — measured/scoped baseline, expected-count resolution, oracleSource confidence`

## Task 7: extend the phase integration test

**Files:** Modify `tests/qa-kit-phases/run.sh`.

- [ ] **Step 1** — append assertions to `tests/qa-kit-phases/run.sh` (reuse its `check` + tmp-dir pattern):
  `data-baseline.sh validate` accepts a seeded+created baseline; `check-fixtures.sh` flags a computed row with no
  `expect` and passes when pinned; `expected-count` gives measured 2 → empty-state 2 and after +1 → 3, and a
  second scope with measured 5 → 5 then 6; a `business-rule` row with no `expect` is flagged (kind trigger); an `oracleSource:"llm-suggested"` pin is present-but-flagged-low (assert `sources.llmSuggested>=1`).
- [ ] **Step 2: Run → green** (`bash tests/qa-kit-phases/run.sh`).
- [ ] **Step 3: Commit** `test(qa-kit): phase integration — origin baseline, check-fixtures gate, measured/scoped counts, oracleSource`

## Task 8: docs — ADR-0023 + CONTEXT.md + README + status

**Files:** Create `docs/adr/0023-qa-kit-tdqa-data-layer.md`; modify `CONTEXT.md`, `qa-kit/README.md`, `CLAUDE.md`,
`docs/superpowers/plans/2026-09-04-qa-kit-roadmap.md`, the design spec status line.

- [ ] **Step 1: ADR-0023** (house style, per ADR-0020/0022) — the data-layer decisions: layered baseline+fixtures;
  declare-and-verify (+ 6b auto-seed deferred); folded into spec/scenarios; enforcement for computed via
  `check-fixtures.sh` beside `verify-plan.sh` (engine untouched); the multiplicity-fix-via-pinned-counts; Q1
  human-confirmed-pin confidence rule; Q3 tenant scope; Q4 `origin` naming. Reference the design spec.
- [ ] **Step 2: CONTEXT.md** — add the "qa-kit process vocabulary" terms: **data-baseline**, **origin**
  (seeded|created — NOT provenance), **fixture** (per-criterion input+expected; distinct from the accuracy
  **fixture project**), **pinned expectation**, **oracleSource** (human|llm-suggested); extend the *Multiplicity*
  entry: "the 0-state count is the measured, scoped seeded baseline, not literally zero."
- [ ] **Step 3: qa-kit/README.md** — a `## Data (TDQA)` section (baseline + fixtures + the enforcement gate) and
  the updated helper list (`data-baseline.sh`, `check-fixtures.sh`).
- [ ] **Step 3b: config toggle** — add `"fixtures": { "hardBlock": false }` to `.qa/config.json.example` and document it (advisory by default; `true` makes an unpinned computed criterion block `/qa-scenarios`).
- [ ] **Step 4: CLAUDE.md** — extend the qa-kit invariant: "computed criteria carry a human-confirmed pinned
  expected (`check-fixtures.sh`); the `origin`/data-baseline concept fixes multiplicity; still engine-untouched."
- [ ] **Step 5: Status** — mark increment 6a in the roadmap + the design spec status; note 6b (auto-seed) pending.
- [ ] **Step 6: Gate + Commit** — build/validate exit 0; all five qa-kit test suites green.
  `docs(qa-kit): ADR-0023 + CONTEXT/README/CLAUDE + status — TDQA data layer (increment 6a) landed`

## Self-Review

**1. Spec coverage:** layered baseline+fixtures → Tasks 1/3/4; declare-and-verify → Tasks 3/6 (6b deferred);
folded into spec/scenarios/analyze → Tasks 3/4/5; enforcement (computed→pinned, keyed on `kind`) → Task 2/4;
multiplicity fix via measured/scoped pinned counts → Tasks 4/6/7; Q1 human-confirm confidence → Task 4 step 2 +
Task 6; Q3 scope → Tasks 3/4/6; Q4 origin naming → constraints + Task 1/8; docs → every task + Task 8. ✅
Engine-untouched + additive-field-safe are asserted in Task 3/4/5 gates.

**2. Placeholder scan:** test code is complete for Tasks 1/2/7; the implementation steps give the exact
derivation rule + field contracts + the sibling idiom to copy (`spec-snapshot.sh`/`verify-plan.sh`), matching this
repo's plan style. No TBD/"handle edge cases".

**3. Type consistency:** `origin ∈ {seeded,created}`, `expect:{path,value(string for decimals),tolerance(number),
oracleSource∈{human,llm-suggested}}`, `check-fixtures` trigger = `kind ∈ {computed-logic,business-rule}` (the engine's own computed definition), `expected-count <measured> <delta>` — identical across Tasks 1/2/4/6/7.

## Execution Handoff

SDD. **Depends on increments 1–5** (the qa-kit plugin + `/qa-spec`/`/qa-scenarios`/`/qa-analyze` + `verify-plan.sh`
sibling idiom). Tasks 1–2 (pure scripts + tests) are the low-risk core; 3–6 are command edits; 7 the integration
test; 8 the docs. **6b (opt-in auto-seed + `detecting-stack-profile` `seed:{}` extension) is a separate later
plan.** Apply the increment-1 discipline proactively (cross-engine + malformed-input symmetry in every script
suite) since independent review may be unavailable.
