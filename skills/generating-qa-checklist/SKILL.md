---
name: generating-qa-checklist
description: Use when a Run is ready to generate its set of criteria — after analyzing-feature-ui has produced surface-map.json, or when a hand-authored checklist or spec-kit artifacts (constitution.md, spec.md, tasks.md) are supplied. Turns the surface map, code, and optional spec inputs into a testable, human-editable checklist covering happy paths, multiplicity (0/1/N), edge/empty/error states, computed-logic assertions with explicit expected values, backend-baking assertions per write, cross-tenant isolation cases, and concurrency/race cases. Emits a filled checklist for human review before any verification begins.
---

# Generating QA Checklist

## Overview

Turn the feature's surface map and code into a testable set of **criteria** — one per end-to-end behavior — before touching the browser. Each criterion must carry its **oracle** (the expected value or rule), a **baking assertion** (what to read back and at what multiplicity), and **tags** (independent? read-only? race?) so the verifier knows what stays sequential and what may rarely fan out.

This is a **v1.1 skill** (auto-generation from surface-map.json + code). In v1 the checklist was either hand-authored by the team or ingested from a supplied spec — that path still applies when a checklist is given as input (see step 1c).

Output: `.qa/runs/<run-id>/checklist.md` — human-editable, consumed by driving-browser-qa. **Stop and request human review before proceeding to verification.**

## When to Use

- After analyzing-feature-ui emits `surface-map.json` for the current Run.
- When a hand-authored checklist or spec-kit artifacts are provided as input.
- When re-generating after a surface map update (feature changed scope).

## The Process

### Step 1 — Gather Inputs

Collect all available inputs before writing a single criterion.

**a. Surface map (required for auto-generation)**

Read `.qa/runs/<run-id>/surface-map.json`. For each `surface` entry with `"chrome": false`:

- [ ] List every write-triggering element (form submit, delete, finalize, approve, toggle).
- [ ] List every read-only or computed-display element (totals, percentages, status badges, date calculations).
- [ ] Note `backend.endpoint`, `backend.model`, `backend.migration` — these anchor the baking assertion.

**b. Code (required for oracle values)**

Read the backend repo (`repos[].role == "backend"` in `.qa/config.json`):

- [ ] For every repeatable entity, read the migration to identify NOT-NULL columns, decimal precision (`decimal(p,s)`), and enum values. These become the shape oracle for baking assertions.
- [ ] For every computed field, read the reference doc (role `reference`) or `constitution.md/spec.md` for the formula. Do NOT use the backend service formula as the oracle.
- [ ] Note business rules (gates, validation rules, approval chains) stated in spec-kit artifacts.

**c. Supplied spec or checklist (ingest path — do not regenerate from scratch)**

If the user supplies a checklist, spec, or spec-kit artifacts (constitution.md, spec.md, tasks.md):

- [ ] Treat each supplied acceptance criterion as a seed criterion — expand it into the full criterion block format (add oracle, baking assertion, tags).
- [ ] Merge with auto-generated criteria; deduplicate by `title`.
- [ ] Mark ingested criteria with `source: ingested` in notes.

---

### Step 2 — Derive Criteria Per Surface

For each non-chrome surface in the map, emit the following criterion types in order:

**Happy path**
One criterion per primary write action. Drive the UI, read the result back, confirm the oracle.

**Multiplicity — ordered, forced deliberately**

For every repeatable entity (entity that can exist 0, 1, or N times):

- [ ] **0-state** — assert the surface before any creates: empty list, zero count, correct empty-state copy. This criterion is ordered FIRST; it is only true before any create runs.
- [ ] **1-state** — assert after exactly one create.
- [ ] **N-state** — assert after N creates (N ≥ 2); check ordering, aggregations, and that totals update.

Example multiplicity schedule for a cap-table governance feature: `2 share classes / 3 founders / 2 board members`.

**Empty / loading / error states**

- [ ] Empty state: correct copy, no orphaned elements, gate not falsely open.
- [ ] Loading state: skeleton/spinner rendered (not a blank screen or crash).
- [ ] Error state: simulate or observe a 4xx/5xx; confirm error copy renders, not a silent blank.

---

### Step 3 — Attach the Oracle

Every criterion must state its expected value or rule before verification begins. A criterion with no oracle must be flagged `confidence-hint: low`.

**Computed-logic expected values (write out the arithmetic)**

- [ ] Money: `amount = shares × price` at full precision. Example: `4,000,000 × $0.001 = $4,000.000` — do NOT pre-round. A sub-cent truncation is a real bug (bug class: decimal precision, e.g. bug #9).
- [ ] Ownership %: `(entity shares / fully-diluted total) × 100`, rounded to spec precision.
- [ ] Vesting accrual: `(months elapsed / cliff or schedule length) × granted amount`, per spec schedule.
- [ ] ESOP pool: `pool shares / fully-diluted total`.
- [ ] Multi-entity totals: all holder percentages must sum to `100% ± tolerance`.

**Business-rule outcomes**

- [ ] State gate: what condition releases a locked surface? Assert the gate opens exactly when the rule says (bug class: setup gate, e.g. bug #3 — a finalized project must release a populated project view, not an empty or errored one).
- [ ] Validation rules: assert the rule fires on the boundary value and does NOT fire below it.
- [ ] Approval-chain transitions: assert status transitions to the correct next state.

**Downstream cascades**

- [ ] For every write, state the full cascade chain: `transaction → holdings → cap-table totals`. Each link is a step in the criterion, not a separate criterion.
- [ ] After finalize, assert every downstream entity updated (multiplicity and values).

---

### Step 4 — Add Backend-Baking Assertions

For every write criterion, extend it with an explicit baking section:

- [ ] Name the **entity** to read back and the **read-back path** (list VIEW, detail VIEW, or API GET).
- [ ] List every **NOT-NULL / required field** and its expected value or non-null assertion. A row that exists with a NULL in a required column is a real bug (bug class: NOT-NULL violation, e.g. bug #7 — finalize returned success but rows violated NOT-NULL constraints).
- [ ] State the **expected count** before and after the write (multiplicity delta).
- [ ] For finalize-class actions, bake ALL downstream entities (e.g. finalize must read back share classes, founders, and board members at the right counts — not just a success 200).

---

### Step 5 — Add Cross-Cutting Heuristics

These two categories are easy to omit and were missed in the real session until explicitly added as a generation heuristic. They are REQUIRED for every Run.

**Cross-tenant isolation (REQUIRED — do not skip)**

For every write criterion, add a sub-step: re-run the read-back authenticated as a **different tenant** and assert the data is **ABSENT**.

- [ ] Draft / unpublished records must NOT appear in another tenant's list (bug class: cross-tenant data leak, e.g. bug #12 — a draft leaked across tenants, missed until this heuristic was made explicit).
- [ ] If the tenant boundary is enforced only in the UI, the API read-back may still return the data — probe the API directly to catch this.
- [ ] Tag these criteria `cross-tenant: true`; they share the same sequential driver but authenticate as a second tenant.

**Concurrency / race cases (narrow parallel path)**

- [ ] Identify any criterion where two sessions hitting the same backend entity concurrently reveals a bug: double-create, double-finalize, simultaneous edit, optimistic-lock violation.
- [ ] For each race criterion, document the exact race: which two sessions, which operations, what the expected behavior is (last-write-wins, 409 conflict, idempotent, etc.).
- [ ] Tag these `race: true` — they are the ONLY criteria that may fan out across a second Driver. Everything else stays sequential (ADR 0003).

---

### Step 6 — Tag for Execution Order

Apply these tags to every criterion in the checklist:

| Tag | Meaning | Execution |
|---|---|---|
| (none) | Writes shared state; default | Sequential, single driver |
| `independent: true` | Does not affect shared state | May fan out (rarely) |
| `read-only: true` | No write to backend | May fan out (rarely) |
| `race: true` | Deliberate concurrency test | Fan out — two drivers, same backend entity |
| `cross-tenant: true` | Reads back as a second tenant | Sequential; second auth session on same driver |

Default everything sequential. Tag `independent` or `read-only` conservatively — if in doubt, leave untagged and run sequentially.

---

### Step 7 — Emit and Stop

1. Copy `templates/checklist.md` to `.qa/runs/<run-id>/checklist.md`.
2. Fill every criterion block (header + per-criterion fields).
3. **Stop. Output the checklist path and ask the human to review before any verification begins.**

Do not proceed to driving-browser-qa until the checklist has been reviewed. The checklist is the contract; premature verification against a wrong oracle wastes a full Run.

---

## Heuristics → Bug Classes (reference)

| Heuristic | Bug class caught |
|---|---|
| Per-surface happy path | Broken primary flows, wrong route, action wired to legacy endpoint |
| Multiplicity 0/1/N (ordered) | Silent drop on N-create; empty-state gate wrong; duplicate-write |
| Empty/loading/error states | Blank-screen crash on load; gate open when it shouldn't be |
| Backend baking + NOT-NULL fields | Successful-looking write that violates NOT-NULL (bug #7) |
| Computed oracle with full-precision arithmetic | Sub-cent truncation, wrong formula, rounding at wrong step (bug #9) |
| Business-rule gate / downstream cascade | Setup gate releases wrong state (bug #3); transaction doesn't update holdings |
| Cross-tenant isolation | Draft visible to another tenant (bug #12) — missed if not explicitly generated |
| Concurrency/race | Double-finalize, optimistic-lock missing |

---

## Mini-Evals

**Eval 1 — NOT-NULL baking (bug #7)**
Given: finalize governance wizard completes, a green "Success" toast appears.
Without this skill: criterion passes on the toast.
With this skill: the baking assertion for `finalize` names every NOT-NULL field on the `holdings` table. Read-back reveals rows exist but `issued_at` is NULL — pass → fail. The oracle was the migration schema, not the toast.

**Eval 2 — Decimal precision (bug #9)**
Given: SAFE note with `4,000,000 shares × $0.001 price`.
Without this skill: criterion reads the displayed `$4,000` and calls it correct (matches rounded display).
With this skill: the oracle states `4,000,000 × 0.001 = 4,000.000 — tolerance 0`. The API response body returns `3999.999` due to a `decimal(10,2)` column truncating the intermediate product. Divergence caught at the API layer; FE looked fine.

**Eval 3 — Cross-tenant isolation (bug #12)**
Given: a draft share class is created in Tenant A.
Without this skill: the checklist has no cross-tenant criterion; the draft is only verified in Tenant A.
With this skill: the cross-tenant heuristic generates a required sub-step — re-read the draft's list endpoint authenticated as Tenant B. The API returns the draft (tenant_id filter missing on the query). Caught only because the heuristic is mandatory, not optional.

**Eval 4 — Business-rule gate (bug #3)**
Given: governance setup wizard completes finalize step.
Without this skill: checklist asserts the wizard reaches the last step; stops there.
With this skill: oracle states "finalize must release a populated project view with share classes, founders, and board members visible." After finalize the baking step navigates to the project overview; the overview renders an empty cap table (downstream cascade did not fire). Gate bug caught because the oracle was the downstream state, not the wizard completion.
