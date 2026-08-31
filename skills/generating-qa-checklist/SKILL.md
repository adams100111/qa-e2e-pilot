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

### Step 3 — Edge-Case Coverage Catalog (REQUIRED — emit or defer-with-reason)

A re-measurement showed the plugin's recall is limited by **coverage**, not verification quality: bugs F3/J1/J3/J4/F4 were missed because no criterion tested them at all. This step closes that gap. It is **required output**, not optional prose — the generator MUST walk this catalog for every write-bearing surface.

Note the distinction from Step 2: Step 2's empty/loading/error states test what a surface *renders* before any write happens. This catalog tests the *values submitted during a write* (and the aggregate state after a delete) — a different axis of coverage, and the one the re-measurement showed was missing.

A surface is **write-bearing** if Step 1a listed at least one write-triggering element on it (create/update/delete/toggle/finalize).

For every write-bearing surface, walk this table top to bottom and emit one criterion per row:

| Edge type | What it tests | Seed it would catch | `Kind` to assign | `Tags` to set |
|---|---|---|---|---|
| empty / 0-value input | a 0/empty write that may falsely "succeed" without persisting | J4 | `business-rule` | `probe-needed` |
| negative / out-of-range value | missing validation → invalid state (use the driving-browser-qa read-back rule for numeric entry — confirm the field actually holds the out-of-range value via `scripts/react-set-input.js` before trusting a "rejected" outcome) | F4 | `business-rule` | `probe-needed` |
| every-Nth repetition (N≥3) | a silent drop on the Nth repeated write (bake count == N, not N-1) | J3 | `multiplicity-N` | (none required — sequential default) |
| named / boundary / reserved-looking value | a specific input that silently isn't persisted despite a success indicator | J1 | `happy-path` | `probe-needed` |
| delete-then-reconcile | aggregate re-reconciliation after a delete — totals/counts must re-sum, not go stale | F3 | `downstream-cascade` | (none required; add `probe-needed` if the total is rendered from a cached/optimistic value) |
| cross-role / cross-tenant absence (when roles or tenants exist) | another persona must NOT see the entity, walked via its authz-matrix `owningChain` (see Step 6 — generalizes the old single-`tenant_id` check to relational FK-ownership chains) | authz | `business-rule` | `cross-role-fk-chain` (or `cross-tenant` for the chain-length-1 flat-column case), `role-sensitive` |
| idempotent / repeat action on a terminal or locked state | re-invoke a finalize/submit/lock/complete action (or click it again) AFTER the entity is already terminal/locked — the repeat must be an idempotent no-op or an explicit rejection, never a silent "success" that strands/corrupts state and never a permanent lockout with no recovery path | BUG-004 | `business-rule` | `probe-needed` |
| input-boundary: oversized / decimal-boundary / unicode / whitespace-only | a numeric value that overflows the column/type, a value sitting exactly on a rounding/decimal boundary, unicode/RTL/bidi text (see driving-browser-qa's RTL-safe click helper), or a whitespace-only string that a naive `if(!name)` check would accept as non-empty | (no seed — closes an untested input-type gap, not tied to one prior bug) | `business-rule` | `probe-needed` |

- [ ] Set `Kind`/`Tags` per the table above and let Step 7 **derive** `Kinds`/`probeNeeded` from them — do not hand-set `Kinds` here; this reuses the existing Phase-1 mapping instead of duplicating it.
- [ ] **If a row doesn't apply to a surface** (e.g. the surface has no delete action, so delete-then-reconcile can't run; or the project is single-role/single-tenant, so the cross-role row has nothing to probe), still emit the criterion — set its verdict-to-be to `deferred` and state the reason in EXPECTED (e.g. "deferred — surface has no delete action"). Never drop the row silently; a reviewer must be able to see the gap was considered, not missed. `deferred` is one of the five existing verdicts — do not invent a sixth for this.
- [ ] For **every-Nth**, use the concrete N already set in Step 2's multiplicity schedule (N≥3) — bake the count immediately after the Nth add specifically, not just after "N items."
- [ ] For **named/boundary/reserved-looking value**, pick an input drawn from the domain: a value colliding with a UI label/placeholder, a reserved word, a boundary-length string, or a value equal to an adjacent field — anything that risks silent normalization or a swallowed write.
- [ ] For **cross-role/cross-tenant absence**, this row is satisfied by Step 6's generalized isolation heuristic: read `.qa/authz-matrix.json` (from `confirming-discovered-roles`) for the entity's `owningChain` and `roleScope`, and emit one `cross-role-fk-chain` criterion per other persona whose scope is `"none"` or `"read-scoped"`. A flat single-`tenant_id` project is the chain-length-1 special case, tagged `cross-tenant` instead. A single-user, single-tenant surface (no authz-matrix row, or the matrix is empty) always defers this row with reason "single-role app — no second role/tenant to probe."
- [ ] For **idempotent/repeat action on a terminal or locked state**, identify the surface's terminal/locked status (COMPLETE, finalized, submitted, locked) and re-invoke the SAME action once the entity already holds that status (e.g. click Finalize again post-COMPLETE). Bake the entity afterward — a `Kinds: bake` read-back — to confirm the repeat neither silently succeeded-and-corrupted state nor permanently disabled the legitimate write path (the BUG-004 pattern: a silent no-op that locked out all future holdings creation). Do NOT accept a green toast or disabled button alone as evidence either way. If the surface has no terminal/locked state at all, defer with reason "surface has no terminal/locked state — nothing to re-invoke."
- [ ] For **input-boundary**, treat oversized/decimal-boundary/unicode/whitespace-only as independent sub-cases and emit one criterion per applicable sub-case (or fold into sub-bullets of a single block if the checklist template's per-criterion format is preferred) — each is a distinct failure mode, not interchangeable:
  - *Oversized* — a numeric value beyond the column's/type's max (e.g. a `bigint`-sized share count into an `int` field); expect a rejection or safe clamp, never silent overflow/wraparound.
  - *Decimal-boundary* — a value exactly on a rounding boundary for the field's declared precision (e.g. `0.005` into a `decimal(p,2)`); expect the documented rounding rule (round-half-up/even per spec), not silent truncation.
  - *Unicode/RTL* — bidi/Arabic/emoji text in a free-text field; expect correct storage and re-render (use `scripts/click-by-text.js`'s bidi-stripping approach as the model for comparison), not mojibake or a swallowed write.
  - *Whitespace-only* — a string of only spaces/tabs; expect the same rejection a fully-empty value would get, not a falsely "non-empty" persisted row.
  - Any sub-case whose input type doesn't apply to the surface's field types (e.g. no numeric field present) still gets a criterion, deferred with reason naming the missing field type — never dropped silently.

**Criteria budget guard (REQUIRED — run this after the catalog walk above, before finalizing)**

The 8-row catalog above, multiplied across every write-bearing surface (and, once role/persona discovery lands, again per `role-sensitive` row × discovered persona), can produce hundreds of criteria under ADR-0003's sequential-by-default execution. This sub-step stops that from silently shipping.

- [ ] After walking the catalog for all write-bearing surfaces (Step 2's happy-path/multiplicity/empty-loading-error criteria plus Step 3's catalog rows, and, once persona multiplication applies, each `role-sensitive` row repeated per persona), **count the total emitted criteria** across the whole checklist — not per-surface, the grand total.
- [ ] Read **BUDGET** from `.qa/config.json`'s `criteriaBudget` if present; otherwise default **BUDGET = 60**.
- [ ] If the total is `<= BUDGET`, proceed — no prompt needed, note the count in the checklist's `Criteria Budget` header field (see `templates/checklist.md`) as "confirmed: full (under budget)".
- [ ] If the total `> BUDGET`, **STOP before finalizing the checklist.** Do not silently emit all of them. Present a numbered confirm/prioritize prompt showing:
  1. The total emitted count vs. BUDGET.
  2. A breakdown by edge-case type × surface (× persona, once applicable) — e.g. a table of counts per catalog row per surface.
  3. A **recommended priority order**, highest first: (a) write-bearing happy-path/multiplicity criteria, (b) `role-sensitive` and cross-role/cross-tenant rows, (c) rows tied to a previously-missed-bug-class (F3/J1/J3/J4/F4/BUG-004 in the Heuristics → Bug Classes table below), (d) everything else, (e) read-only/cosmetic edge rows (e.g. pure-display empty/loading states with no write) last.
  4. The RECOMMENDED trimmed subset: the highest-priority criteria that fit within BUDGET, applying the order above.
- [ ] Ask the human to pick one of three options — do not proceed until they answer: **(1)** confirm the full (over-budget) set anyway, **(2)** confirm the recommended trimmed subset, or **(3)** hand-pick a different subset from the numbered breakdown.
- [ ] Record the outcome in the checklist's `Criteria Budget` header field: computed count, BUDGET used, and whether the human confirmed `full` or `trimmed (N of M)`. Criteria dropped by a `trimmed` confirmation are not deleted from consideration — list them in Checklist Summary as `Status: deferred`, reason `"trimmed by criteria-budget guard — below priority cutoff"`, so a re-run or a later Run can pick them back up.
- [ ] This is a **simple threshold-and-confirm** (one prompt) — it does not require the multi-round frontier-recompute HITL pattern (that pattern, once built, is a later optional upgrade for this same prompt; do not block this guard on it).

---

### Step 4 — Attach the Oracle

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

### Step 5 — Add Backend-Baking Assertions

For every write criterion, extend it with an explicit baking section:

- [ ] Name the **entity** to read back and the **read-back path** (list VIEW, detail VIEW, or API GET).
- [ ] List every **NOT-NULL / required field** and its expected value or non-null assertion. A row that exists with a NULL in a required column is a real bug (bug class: NOT-NULL violation, e.g. bug #7 — finalize returned success but rows violated NOT-NULL constraints).
- [ ] State the **expected count** before and after the write (multiplicity delta).
- [ ] For finalize-class actions, bake ALL downstream entities (e.g. finalize must read back share classes, founders, and board members at the right counts — not just a success 200).

---

### Step 6 — Add Cross-Cutting Heuristics

These two categories are easy to omit and were missed in the real session until explicitly added as a generation heuristic. They are REQUIRED for every Run.

**Cross-role isolation via FK-ownership chains (REQUIRED — do not skip; generalizes the old single-`tenant_id` heuristic, ADR-0012 Decision 2)**

Isolation is not always a single `tenant_id` column. Read `.qa/authz-matrix.json` (written by `confirming-discovered-roles`): one row per protected entity, `{ entity, owningChain: [fk1, fk2, ...], roleScope: { <personaId>: "owns"|"read-scoped"|"none" } }`. `owningChain` is the ordered FK hops from the entity back to its ultimate owning record — e.g. `innovation`'s `submission` has no `tenant_id` at all; ownership is `team_id → team → hackathon_id → hackathon`. A flat single-column tenant filter is the **chain-length-1 special case** (`owningChain: ["tenant_id"]`) — existing single-tenant projects are unaffected and keep using it.

For every write criterion whose entity appears in the authz matrix, add a sub-step per OTHER persona whose `roleScope` for that entity is `"none"` or `"read-scoped"`:

- [ ] Re-run the read-back authenticated as that other persona and assert the entity is **ABSENT** (`"none"`) or that only that persona's own scoped subset is visible, never the entity owned by the persona under test (`"read-scoped"` — e.g. an evaluator sees their assigned submissions but not a teammate's).
- [ ] Assert absence at the **correct hop** in `owningChain` — walk the chain from the entity outward to the hop where the persona's scope actually cuts off. Asserting at the wrong (too-shallow or too-deep) hop is not a valid probe, and fail-open is not acceptable just because there's no single `tenant_id` column to check.
- [ ] **A `pass` REQUIRES a `probe` bake showing absence** — an authenticated fetch/read-back as the other persona confirming the *backend itself* withholds the entity (ADR-0010's evidence-gate content requirements apply unchanged). A UI that merely fails to render a link to the entity is not evidence of absence.
- [ ] Tag these criteria `cross-role-fk-chain: true` and record the specific `owningChain` asserted; `cross-tenant: true` remains valid as the chain-length-1 alias (a genuine flat `tenant_id` filter) — both tags derive the same `Kinds` in Step 7 (`probe` required for either).
- [ ] Draft/unpublished records must NOT appear in another persona's list at any hop (bug class: cross-tenant/cross-role data leak, e.g. bug #12 — a draft leaked across tenants, missed until this heuristic was made explicit; the same failure mode recurs at any FK hop, not just `tenant_id`).
- [ ] If `.qa/authz-matrix.json` is missing or empty (no discovered roles, no protected entities), defer per Step 3's rule: reason "single-role app — no second role/tenant to probe."

**Role-sensitive tagging + per-persona multiplication (REQUIRED — cost containment, ADR-0012 Decision 1)**

A criterion is **role-sensitive** when its outcome plausibly depends on the acting persona's permissions/ownership — i.e. the authz matrix marks its entity as anything other than uniformly `"owns"` across every confirmed persona (permission-gated actions, role-scoped list/detail views; every `cross-role-fk-chain`/`cross-tenant` criterion above is role-sensitive by construction). Tag it `role-sensitive: true`.

- [ ] **Only `role-sensitive` criteria and the cross-role-fk-chain/cross-tenant negative tests multiply per persona.** Every other criterion — the vast majority; most functional/computed-logic checks behave identically regardless of who is logged in — runs **ONCE**, as the single **most-privileged** confirmed persona.
- [ ] **Most-privileged ordering is a selection convenience, not a permission lattice.** When the role source has an obvious naming hint (e.g. `super-admin`/`admin`), order `super-admin > admin > evaluator ≈ jury > user` (the `innovation` `UserType` shape). Lateral, scope-limited roles (`≈` — e.g. `evaluator`/`jury`, each seeing only their own assigned rows) are NOT strict supersets of `user`, and this ordering does **not** exempt them from an explicit `cross-role-fk-chain` pair tested against each other. Contextual team roles are ordered only WITHIN their own team — never across teams (a team-A role has no privilege relationship to a team-B role; that gap is `cross-role-fk-chain` isolation, not ordering). A project with no discoverable ordering hint defaults to declaring every role tied and requires a Round-1 human confirmation (`confirming-discovered-roles`) before the order is used to pick a shared-criterion runner.
- [ ] This is what keeps the 8-row edge-case catalog × N surfaces × up to ~8 discovered personas from becoming a full cross-product — the criteria-budget guard above already counts persona multiplication of `role-sensitive` rows in its total.
- [ ] `.qa/authz-matrix.json` is the source of truth for which entities are role-sensitive and their `owningChain`s — do not re-derive ownership chains independently in this skill.

**Concurrency / race cases (narrow parallel path)**

- [ ] Identify any criterion where two sessions hitting the same backend entity concurrently reveals a bug: double-create, double-finalize, simultaneous edit, optimistic-lock violation.
- [ ] For each race criterion, document the exact race: which two sessions, which operations, what the expected behavior is (last-write-wins, 409 conflict, idempotent, etc.).
- [ ] Tag these `race: true` — they are the ONLY criteria that may fan out across a second Driver. Everything else stays sequential (ADR 0003).

---

### Step 7 — Tag for Execution Order

Apply these tags to every criterion in the checklist:

| Tag | Meaning | Execution |
|---|---|---|
| (none) | Writes shared state; default | Sequential, single driver |
| `independent: true` | Does not affect shared state | May fan out (rarely) |
| `read-only: true` | No write to backend | May fan out (rarely) |
| `race: true` | Deliberate concurrency test | Fan out — two drivers, same backend entity |
| `cross-tenant: true` | Reads back as a second tenant (flat `tenant_id`, chain-length-1) | Sequential; second auth session on same driver |
| `cross-role-fk-chain: true` | Reads back as another persona; asserts absence at a specific `owningChain` hop (general relational case) | Sequential; second auth session on same driver |
| `role-sensitive: true` | Outcome depends on the acting persona's permissions/ownership (authz matrix marks the entity non-uniform across personas) | Runs once per persona, not once for the whole checklist — see Step 6 |
| `probe-needed: true` | Expected state cannot be confirmed through the visible UI alone | Sequential; `probing-apis-through-browser` invoked, evidence required |

Default everything sequential. Tag `independent` or `read-only` conservatively — if in doubt, leave untagged and run sequentially.

**Setting `probe-needed` (generation-time rule, mechanical)**

Set `probe-needed: true` when the criterion's expected state cannot be confirmed through the visible UI alone — i.e. either condition holds:

- [ ] The oracle value lives only server-side (a computed/derived field, an internal ID, a timestamp, or a status the UI never displays).
- [ ] The UI renders a value that could mask the real state (a generic "Success" toast, a rounded/truncated display value, or an error banner that could hide a 2xx-with-wrong-body response).

If neither holds, leave `probe-needed` unset — the criterion is confirmable from the UI/bake read-back alone.

**Derive `Kinds` — the evidence the gate will require**

Every criterion also carries a derived **`Kinds`** field: a CSV subset of `bake|computed|probe`, computed deterministically from its `Kind` + `Tags` above. This is not optional metadata — `checkpoint.sh ... --kinds <csv>` refuses to record a `pass` unless each listed kind's artifact (written by `record-evidence.sh`) exists and validates (see `checkpointing-qa-memory`). Derive it with this table:

| Criterion `Kind` / `Tag` | Required evidence kind(s) | Artifact |
|---|---|---|
| `computed-logic`, `business-rule` | `computed` | `evidence/<crit>/recompute.json` |
| `multiplicity-0/1/N`, `happy-path`, `downstream-cascade`, or any criterion NOT tagged `read-only` | `bake` | `evidence/<crit>/bake-read-back.json` |
| `Tag: cross-tenant` OR `Tag: cross-role-fk-chain` OR `Tag: probe-needed` | `probe` | `evidence/<crit>/network-response.json` |

A criterion may match several rows — union the kinds (e.g. a computed write is `bake,computed`). A criterion tagged `read-only` with no computed logic and no probe-needed tag (pure-display, e.g. `empty-state`, `loading-state`, an error-state that renders but doesn't write) derives `Kinds: none` and is legitimately un-gated.

`Kinds` is always **derived from tags**, never the reverse: `probe-needed` (set at generation time, per the rule above) is the INPUT; `Kinds: probe` is the OUTPUT the table derives from it. The same direction applies to `cross-tenant`/`cross-role-fk-chain`. Do not treat `Kinds` as something you inspect to decide whether probing was needed — decide `probe-needed` first, from the criterion itself, then let the table derive `Kinds`.

- [ ] Set `Kinds` to the union of matched rows, as CSV, in the order `bake,computed,probe`.
- [ ] Set `probeNeeded: true` whenever `Tag: probe-needed`, `Tag: cross-tenant`, or `Tag: cross-role-fk-chain` is set (i.e. whenever the `probe` kind was derived), so the verifier knows to invoke `probing-apis-through-browser` rather than relying on the UI alone.
- [ ] Record both fields in the criterion's summary row — the verifier reads `Kinds` straight into `checkpoint.sh --kinds` at pass time; do not leave it to be inferred later.

---

### Step 8 — Emit and Stop

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
| Cross-role isolation (FK-ownership chain, generalizes cross-tenant) | Draft/entity visible to another persona at any `owningChain` hop, not just a flat `tenant_id` (bug #12) — missed if not explicitly generated |
| Concurrency/race | Double-finalize, optimistic-lock missing |
| Edge-case catalog: empty/0-value input | False "success" on a 0/empty write that never persists (J4) |
| Edge-case catalog: negative/out-of-range value | Missing server-side validation on an invalid value (F4) |
| Edge-case catalog: every-Nth repetition | Silent drop on the Nth repeated write (J3) |
| Edge-case catalog: named/boundary value | "Ghost" write — success indicator fires, nothing persists (J1) |
| Edge-case catalog: delete-then-reconcile | Stale aggregate/total after a delete (F3) |
| Edge-case catalog: cross-role/tenant absence | Cross-role authz leak — deferred with reason when no second role exists |
| Edge-case catalog: terminal/locked-state repeat action | Silent no-op that corrupts or permanently locks out a surface on re-invoking a finalize/submit/lock action (BUG-004) |
| Edge-case catalog: input-boundary (oversized/decimal/unicode/whitespace) | Overflow/wraparound, silent rounding-boundary truncation, unicode/RTL mojibake, or whitespace-only bypassing a naive emptiness check |

---

## Mini-Evals

**Eval 1 — NOT-NULL baking (bug #7)**
Given: finalize governance wizard completes, a green "Success" toast appears.
Without this skill: criterion passes on the toast.
With this skill: the baking assertion for `finalize` names every NOT-NULL field on the `holdings` table; `Kind: downstream-cascade` derives `Kinds: bake`. Read-back reveals rows exist but `issued_at` is NULL — pass → fail. The oracle was the migration schema, not the toast. Because `Kinds: bake` was set, `checkpoint.sh` would have refused a `pass` without `evidence/<crit>/bake-read-back.json` on file anyway.

**Eval 2 — Decimal precision (bug #9)**
Given: SAFE note with `4,000,000 shares × $0.001 price`.
Without this skill: criterion reads the displayed `$4,000` and calls it correct (matches rounded display).
With this skill: `Kind: computed-logic` derives `Kinds: computed`. The oracle states `4,000,000 × 0.001 = 4,000.000 — tolerance 0`. The API response body returns `3999.999` due to a `decimal(10,2)` column truncating the intermediate product. Divergence caught at the API layer; FE looked fine, and the gate would have rejected a `pass` without a `recompute.json` showing `match: false` resolved to `fail`.

**Eval 3 — Cross-tenant isolation (bug #12)**
Given: a draft share class is created in Tenant A.
Without this skill: the checklist has no cross-tenant criterion; the draft is only verified in Tenant A.
With this skill: the cross-tenant heuristic generates a required sub-step — re-read the draft's list endpoint authenticated as Tenant B; `Tag: cross-tenant` derives `Kinds: bake,probe` and `probeNeeded: true`. The API returns the draft (tenant_id filter missing on the query). Caught only because the heuristic is mandatory, not optional, and the derived `probe` kind forced a `network-response.json` read-back rather than trusting the UI.

**Eval 4 — Business-rule gate (bug #3)**
Given: governance setup wizard completes finalize step.
Without this skill: checklist asserts the wizard reaches the last step; stops there.
With this skill: oracle states "finalize must release a populated project view with share classes, founders, and board members visible." After finalize the baking step navigates to the project overview; the overview renders an empty cap table (downstream cascade did not fire). Gate bug caught because the oracle was the downstream state, not the wizard completion.

**Eval 5 — Edge-case coverage set on a founders surface (F3/F4/J3/J4/J1)**
Given: the founders surface (write-bearing: create, edit, delete) has only a happy-path create criterion in the checklist.
Without this skill: F3/F4/J3/J4/J1 have no criterion at all — the re-measurement showed these are pure coverage gaps, not verification failures. A "0-share" founder create, a negative-share create, the 3rd add in a row, a founder named to collide with UI copy, and a post-delete total are never exercised.
With this skill: Step 3 walks the catalog for this surface and emits, alongside the happy path:
- `C-FOUNDERS-EDGE-01` (0-share input) — create a founder with `shares = 0`. `Kind: business-rule`, `Tags: probe-needed` → `Kinds: bake,probe`. Oracle: a 0-share founder must be rejected or persist visibly at 0% — a "Success" toast with no row created is a `fail` (catches J4).
- `C-FOUNDERS-EDGE-02` (negative-share input) — create a founder with `shares = -500`, entered via `scripts/react-set-input.js` per driving-browser-qa's numeric read-back rule so a swallowed keystroke can't masquerade as a rejection. `Kind: business-rule`, `Tags: probe-needed` → `Kinds: bake,probe`. Oracle: negative shares must be rejected server-side, not silently coerced into a valid 0-share row (catches F4).
- `C-FOUNDERS-EDGE-03` (every-3rd add) — add founders 1, 2, 3 in sequence (N=3 from the Step 2 multiplicity schedule). `Kind: multiplicity-N` → `Kinds: bake`. Oracle: the read-back count after founder #3 is exactly 3, not 2 (catches J3).
- `C-FOUNDERS-EDGE-04` (named/boundary value) — create a founder named literally "Founder" (collides with the form's own placeholder). `Kind: happy-path`, `Tags: probe-needed` → `Kinds: bake,probe`. Oracle: the founder is present in the read-back list, not just in the success toast (catches J1).
- `C-FOUNDERS-EDGE-05` (delete-then-reconcile) — delete one of the 3 founders. `Kind: downstream-cascade` → `Kinds: bake`. Oracle: the founders count badge and ownership-percentage sum re-reconcile to 2 founders summing to 100%, not a stale total left over from 3 (catches F3).
- `C-FOUNDERS-EDGE-06` (cross-role/tenant absence) — this fixture is single-role, single-tenant. Instead of a silent omission, emit `deferred`: reason "single-role app — no second role/tenant to probe."
Each row's `Kind`/`Tags` came straight from the Step 3 table; `Kinds`/`probeNeeded` were derived by Step 7, not hand-set. None of these five bugs required a new verification technique — only a criterion that existed to point verification at them.

**Eval 6 — Terminal-state idempotency (BUG-004, unseeded)**
Given: the governance setup wizard's Finalize step has already been clicked once; `roundStatus` reads COMPLETE. A measured run clicked Finalize a second time and found holdings creation permanently disabled afterward — a real bug the checklist had never generated a criterion for, because every existing criterion only exercised finalize from a pre-COMPLETE state.
Without this skill: the checklist has no criterion that re-invokes Finalize once already COMPLETE; the wizard is only ever tested going into its terminal state, never already in it. The regression ships silently.
With this skill: Step 3's terminal/locked-state row emits `C-FINALIZE-EDGE-07` — click Finalize again while `roundStatus=COMPLETE`. `Kind: business-rule`, `Tags: probe-needed` → not tagged `read-only`, so `Kinds` derives `bake` (plus `probe` from the `probe-needed` tag). Oracle: the repeat is an idempotent no-op (roundStatus stays COMPLETE, holdings unchanged) OR an explicit rejection surfaced to the user — it must NEVER be a silent "success" that then blocks all future holdings creation with no recovery path. The baking step re-reads holdings-creation availability after the repeat click; finding it permanently disabled with no error shown is a `fail`, suspected layer `FE` (matches BUG-004 exactly). Caught only because the row forces a second finalize invocation from the terminal state — the same click sequence a real user eventually performs by mis-click or double-submit.

**Eval 7 — Criteria budget guard caps a would-be-120-criteria checklist**
Given: a feature has 3 write-bearing surfaces (founders, share classes, board members) and, once role discovery has run, 5 discovered personas (`super-admin/admin/evaluator/user/jury`). Walking the 8-row edge-case catalog across all 3 surfaces, with every `role-sensitive` row multiplied per persona, emits 120 criteria (8 rows × 3 surfaces × 5 personas) before any happy-path/multiplicity criteria are even counted.
Without this skill: the generator emits all 120+ criteria straight into the checklist. Under ADR-0003's sequential-by-default execution, a single Run now has to walk 120 criteria one at a time — combinatorial explosion goes unnoticed until the human opens the checklist.
With this skill: after the catalog walk, the budget-guard sub-step counts the total (120) against BUDGET (default 60, or `.qa/config.json`'s `criteriaBudget`). 120 > 60, so the generator STOPS before finalizing and presents a numbered prompt: total 120 vs. budget 60; a breakdown table (edge-type × surface × persona counts); and a recommended priority order putting write-bearing + role-sensitive + previously-missed-bug-class rows (F3/J1/J3/J4/F4/BUG-004) first and read-only/cosmetic edge rows last. The recommendation trims to 45 criteria — the highest-priority subset that fits comfortably under 60. The human is asked to confirm the full 120, confirm the recommended 45, or hand-pick; they confirm the recommended trimmed subset. The checklist's `Criteria Budget` header records `computed: 120, budget: 60, confirmed: trimmed (45 of 120)`, and the 75 dropped criteria appear in the Checklist Summary as `Status: deferred, reason: trimmed by criteria-budget guard — below priority cutoff` — visible for a later Run, not silently lost.

**Eval 8 — Role-sensitive + cross-role-fk-chain criterion on a relational-ownership app (no `tenant_id` column)**
Given: a hackathon platform (`innovation`-shaped) with confirmed personas `super-admin/admin/evaluator/jury/user` and `.qa/authz-matrix.json` carrying the row `{ entity: "submission", owningChain: ["team_id", "hackathon_id"], roleScope: { "team-member": "owns", "evaluator": "read-scoped", "jury": "read-scoped", "admin": "owns", "user": "none" } }`. The `submission` detail surface is write-bearing (a team creates/edits its submission); there is no `tenant_id` column anywhere in the schema.
Without this skill: the old heuristic assumes a single `tenant_id` filter, finds no such column, and either fails to generate a cross-role criterion at all or generates one that checks the wrong (nonexistent) field — an evaluator seeing another team's unpublished submission would go undetected because nothing was ever probed at the `team_id`/`hackathon_id` hops.
With this skill: Step 6 reads the authz-matrix row directly. `submission` is not uniformly `"owns"` across personas, so the happy-path create/edit criteria for it are tagged `role-sensitive: true` but still run ONCE, as the most-privileged persona present (`admin`, per the `super-admin > admin > evaluator ≈ jury > user` ordering) — no need to repeat the plain create/edit flow per persona. Separately, Step 6 emits a `cross-role-fk-chain: true` criterion `C-SUBMISSION-XROLE-01`: authenticate as `jury` (whose `roleScope` is `"read-scoped"`), and assert that a submission belonging to a DIFFERENT team is absent at the `team_id` hop (jury may see submissions assigned to them, never an arbitrary other team's) — the probe reads the submission-list API response as `jury` and confirms the other team's `submission_id` is not present in the payload, not merely absent from the rendered UI list. `Kind: business-rule`, `Tags: cross-role-fk-chain, role-sensitive` → `Kinds: bake,probe`. A second criterion `C-SUBMISSION-XROLE-02` does the same for `user` (`roleScope: "none"`) at the same hop. Oracle for both: absence at `team_id`/`hackathon_id`, sourced from the authz matrix, not a `tenant_id` guess. Per Step 6's most-privileged-ordering caveat, `evaluator`-vs-`jury` isolation (two lateral, equally-scoped roles) still gets its own explicit `cross-role-fk-chain` pair rather than being assumed safe because neither outranks the other.
