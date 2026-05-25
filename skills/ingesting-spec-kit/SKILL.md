---
name: ingesting-spec-kit
description: Use when spec-kit artifacts (constitution.md, spec.md, tasks.md) are available and should be ingested into the QA pipeline to build a traceability matrix. Discovers spec-kit files across configured repos, turns acceptance criteria and constitutional constraints into oracle-carrying criteria via generating-qa-checklist, populates checkpointing-qa-memory's traceability artifact, and enables the traceability column in writing-qa-reports. Spec-kit is never required — the pipeline runs fine without it.
---

# Ingesting Spec-Kit

## Overview

A **later-phase capability**: the pipeline works without any spec. When spec-kit artifacts exist, ingesting them makes the oracle explicit, raises confidence, and adds a traceability column (criterion ↔ spec section / constitution rule / task id ↔ verdict) to the run report.

This skill reads files — it does **not** require spec-kit to be installed. The artifacts are plain markdown. You import them; nothing runs.

**Inputs:** `constitution.md`, `spec.md`, `tasks.md` (all optional individually).
**Outputs:** populated `traceability.json` (owned by checkpointing-qa-memory), enriched checklist handed to generating-qa-checklist, traceability column rendered by writing-qa-reports.

---

## When to Use

- spec-kit artifacts are present in the repo (or supplied by the user).
- You want the oracle to come from the spec rather than only from backend code.
- You need a traceability matrix: requirement → criterion → verdict.
- Generating-qa-checklist was called without spec-kit inputs and you want to re-enrich it.

Do NOT block the run or error when spec-kit artifacts are absent — log "no spec-kit artifacts found" and continue with hand-authored or auto-generated checklist.

---

## The Process

### Step 1 — Discover Artifacts

Run the bundled discovery script:

```bash
bash skills/ingesting-spec-kit/scripts/find-spec-kit.sh
```

The script reads `.qa/config.json` to find configured repo paths (by role), searches each repo plus the current working directory, and prints an inventory: `path | artifact-type | title`. It exits 0 always — absence is not an error.

**If the inventory is empty:**
- Log: "No spec-kit artifacts found. Proceeding with hand-authored or auto-generated checklist."
- Do NOT create `traceability.json`.
- Hand off to generating-qa-checklist without spec inputs.
- Stop this skill here.

**If artifacts are found**, note which of the three file types exist (`constitution.md`, `spec.md`, `tasks.md`). You can proceed with any subset — all three are optional individually.

---

### Step 2 — Read the Oracle Sources

Parse each discovered file. These files ARE the oracle. Their stated requirements and constraints become the expected values that criteria carry.

**`spec.md` — requirements + acceptance criteria**

- [ ] Identify every stated acceptance criterion (look for `- [ ]` checklists, `## Acceptance Criteria` sections, or numbered requirement lists).
- [ ] For each criterion, record: the section heading, the requirement text, and any explicit expected value (formula, boundary, state name, count).
- [ ] Note criteria that state NO expected value — these are candidates for `confidence: low`.
- [ ] Assign each a provisional reference key: `SPEC-§<section>-<n>` (e.g. `SPEC-§3-AC2`).

**`constitution.md` — durable constraints / non-negotiable rules**

- [ ] Identify every business rule, constraint, or invariant (e.g. "fully-diluted ownership percentages must always sum to 100%", "a share class cannot be deleted once a transaction is recorded against it", "vesting cliff is a minimum 12 months").
- [ ] Assign each a key: `CONST-<rule-slug>` (e.g. `CONST-ownership-sum`, `CONST-cliff-minimum`).
- [ ] These rules are HIGH-confidence oracles — they are stated by the domain, not derived from code.

**`tasks.md` — implementation task IDs**

- [ ] Extract every task ID (e.g. `T001`, `T-12`, `#GOV-03`) and its one-line title.
- [ ] These are used only for traceability mapping — they are not oracle sources.
- [ ] Build a lookup: `task-id → title`.

---

### Step 3 — Map to Criteria

Hand the parsed acceptance criteria and constitution rules to **generating-qa-checklist** so each input EXPANDS into concrete criteria. One spec acceptance criterion typically yields:

| Expansion | Example |
|---|---|
| Happy path | Primary behavior succeeds end-to-end |
| Multiplicity (0/1/N) | Correct at 0, 1, and N instances |
| Edge / error | Boundary value, rejection, failure state |
| Backend baking | Persisted shape and NOT-NULL fields match |
| Computed logic | Arithmetic / formula matches oracle at full precision |

A constitution rule typically yields **one** criterion — a business-rule assertion — because it is already specific and non-negotiable.

**For each generated criterion, record the expansion mapping:**

```
generated-criterion-id:
  source_type: acceptance_criterion | constitution_rule
  source_ref:  SPEC-§3-AC2 | CONST-ownership-sum
  task_refs:   [T007, T008]      ← from tasks.md lookup; empty [] if no match
  expansion:   happy_path | multiplicity_0 | multiplicity_1 | multiplicity_N |
               edge | baking | computed_logic | business_rule
```

Keep this mapping in memory — it becomes the seed for `traceability.json` in Step 5.

---

### Step 4 — Flag Confidence

Assign `confidence` to every generated criterion BEFORE verification begins. Be honest.

| Situation | Confidence |
|---|---|
| Expected value explicitly stated in spec.md or constitution.md | `high` |
| Expected value derivable from spec formula with arithmetic | `high` |
| Expected value only derivable from backend code (no spec oracle) | `low` |
| Criterion cannot be verified this run (env missing, prerequisite unavailable) | verdict: `deferred`, state reason |

**Rules:**
- `confidence` is orthogonal to verdict — a `pass` can be `low`-confidence.
- `low` confidence means: "can catch precision/propagation bugs, not formula correctness."
- A `low`-confidence criterion still runs — it is not skipped or deferred automatically.
- Do NOT elevate confidence by reading backend code as the oracle. That is reconciliation, not specification.

Mark deferred criteria immediately with a plain-English reason (e.g. "requires a completed funding round — not available in this env", "concurrency scenario needs two simultaneous sessions — deferred to load-test suite").

---

### Step 5 — Build Traceability

Populate checkpointing-qa-memory's `traceability.json`. Call checkpointing-qa-memory to copy `templates/traceability.md` → `.qa/runs/<run-id>/traceability.json` and fill it.

**Schema for each row:**

```jsonc
{
  "criterion_id":       "GOV-04",
  "title":              "Founder ownership % persists with correct value",
  "source_type":        "acceptance_criterion",
  "source_ref":         "SPEC-§4-AC1",
  "constitution_refs":  ["CONST-ownership-sum"],
  "task_refs":          ["T007"],
  "expansion":          "computed_logic",
  "oracle":             "(founder_shares / fully_diluted_total) × 100, rounded to 2dp per spec §4",
  "confidence":         "high",
  "verdict":            null
}
```

- Leave `verdict` as `null` until the criterion resolves.
- Update the row after every criterion completes (checkpointing-qa-memory Step 2 calls this).
- The file's existence is the signal to writing-qa-reports to render the traceability column.

---

### Step 6 — Render

Writing-qa-reports detects `traceability.json` in the run dir and adds a `## Traceability` section: a table mapping `criterion-id | spec-section | constitution-rule | task-id | verdict | confidence`. No action needed here — this is automatic.

If `traceability.json` is absent (no spec-kit artifacts), writing-qa-reports omits the section. Do NOT fabricate references.

---

## Artifact Locations (Common Patterns)

The discovery script covers these; listed here for manual inspection:

| Location | Notes |
|---|---|
| Repo root (`./constitution.md`, `./spec.md`, `./tasks.md`) | Most common |
| `.specify/` | spec-kit default output dir |
| `specs/` | Common alternative |
| `docs/` | Occasional |
| Separate `specs` repo (`repos[].role == "specs"` in config) | Multi-repo setups |

---

## Mini-Evals

### Eval 1 — Acceptance criterion expands into multiple criteria

**Given:** `spec.md §4` contains: "Founders can be added to the cap table. Each founder must display the correct ownership percentage."

**Do:**
1. Parse as acceptance criterion `SPEC-§4-AC1`.
2. Hand to generating-qa-checklist. It expands into:
   - `GOV-04a` happy path: add one founder, bake, verify stored.
   - `GOV-04b` multiplicity-0: cap table shows zero founders before any create. Ordered first.
   - `GOV-04c` multiplicity-N: add 3 founders; verify each ownership % = `(founder_shares / fully_diluted_total) × 100` at 2dp; verify percentages sum to 100% ± 0.01%.
   - `GOV-04d` edge: attempt to add a founder with 0 shares; assert rejection.
3. All four carry `source_ref: SPEC-§4-AC1`, `confidence: high` (formula is in the spec).
4. `traceability.json` has 4 rows, all linked to `SPEC-§4-AC1`.

**Must not do:** collapse all four into one criterion. Each must carry exactly one verdict.

---

### Eval 2 — Constitution rule → business-rule criterion, high confidence

**Given:** `constitution.md` states: "Fully-diluted ownership percentages must always sum to 100%. This invariant holds at every state: after each founder create, after vesting cliff events, and after any share-class modification."

**Do:**
1. Parse as `CONST-ownership-sum`.
2. Generate criterion `GOV-INV-01`: "Ownership percentages sum to 100% after each create/modify."
   - oracle: `SUM(all_holder_shares / fully_diluted_total × 100) = 100.00 ± 0.01%`
   - confidence: `high` (stated by constitution — no backend derivation needed)
   - expansion: `business_rule`
3. The criterion runs as a check step inside every write criterion — it is NOT a separate browser flow. It shares sequence position with `GOV-04c`.
4. traceability row: `constitution_refs: ["CONST-ownership-sum"]`, `task_refs: []`.

**Must not do:** lower confidence because the formula looks like arithmetic. The constitution stated it — that is a high-confidence oracle.

---

### Eval 3 — Vesting accrual: expected value NOT derivable from spec → confidence low, then deferred

**Given:** `spec.md §7` states: "Vesting schedules are displayed correctly." No formula, no cliff duration, no accrual frequency. The backend service computes accrual internally.

**Do:**
1. Parse as `SPEC-§7-AC1`. Note: no expected value in spec.
2. Generate criterion `GOV-07a` (vesting display matches accrual computation).
   - oracle: `(months_elapsed / schedule_length) × granted_amount` — but schedule_length is NOT in spec.
   - confidence: `low` (expected value only derivable from backend code).
3. Record `confidence: low` in traceability. Add note: "Accrual formula not stated in spec — oracle derived from backend service. Can catch propagation/display bugs, not formula correctness."
4. Additionally: this run's env has no vesting events triggered (cliff not reached). Verdict: `deferred`, reason: "Vesting cliff requires 12 months elapsed — not reproducible in this env. Verify in staging with a backdated grant."
5. `traceability.json` row: `confidence: low`, `verdict: deferred`, `deferred_reason: "cliff not reachable in test env"`.

**Must not do:** elevate confidence to `high` by reading the backend formula. Must not skip the deferred entry from the report.

---

### Eval 4 — Cap-table governance: multi-artifact ingest (constitution + spec + tasks)

**Given:** A cap-table governance feature. `constitution.md` has `CONST-cliff-minimum`: "Vesting cliff must be ≥ 12 months." `spec.md §2-AC3`: "Share classes can be created with a name, authorized shares, and price per share; once a transaction is recorded, the share class cannot be deleted." `tasks.md` has `T009`: "Add delete-guard on share-class if transactions exist."

**Do:**
1. `CONST-cliff-minimum` → criterion `GOV-CLF-01`: attempt to create a vesting schedule with an 11-month cliff; assert the UI rejects it with a validation message. Oracle: rejection at < 12 months. Confidence: `high`. Task refs: `[]` (no matching task).
2. `SPEC-§2-AC3` → two criteria:
   - `GOV-SC-01` happy path: create share class, bake name/authorized-shares/price.
   - `GOV-SC-02` delete-guard: record a transaction against the share class; attempt delete; assert the delete is blocked. Oracle: delete blocked when transaction exists. Confidence: `high`. Task refs: `[T009]`.
3. traceability rows link `GOV-SC-02` to both `SPEC-§2-AC3` and `T009`.
4. After `GOV-SC-02` resolves `pass`, checkpointing-qa-memory updates the row: `verdict: pass`, `confidence: high`.

---

## Sibling Skills

| Skill | Role |
|---|---|
| generating-qa-checklist | Receives the parsed requirements; expands each acceptance criterion into concrete criteria |
| checkpointing-qa-memory | Owns `traceability.json`; update its rows after every criterion resolves |
| writing-qa-reports | Renders the traceability column when `traceability.json` exists |
