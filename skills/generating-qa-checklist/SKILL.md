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
| cross-role / cross-tenant absence (when roles or tenants exist) | another role/tenant must NOT see the entity | authz | `cross-tenant` | `cross-tenant` |

- [ ] Set `Kind`/`Tags` per the table above and let Step 7 **derive** `Kinds`/`probeNeeded` from them — do not hand-set `Kinds` here; this reuses the existing Phase-1 mapping instead of duplicating it.
- [ ] **If a row doesn't apply to a surface** (e.g. the surface has no delete action, so delete-then-reconcile can't run; or the project is single-role/single-tenant, so the cross-role row has nothing to probe), still emit the criterion — set its verdict-to-be to `deferred` and state the reason in EXPECTED (e.g. "deferred — surface has no delete action"). Never drop the row silently; a reviewer must be able to see the gap was considered, not missed. `deferred` is one of the five existing verdicts — do not invent a sixth for this.
- [ ] For **every-Nth**, use the concrete N already set in Step 2's multiplicity schedule (N≥3) — bake the count immediately after the Nth add specifically, not just after "N items."
- [ ] For **named/boundary/reserved-looking value**, pick an input drawn from the domain: a value colliding with a UI label/placeholder, a reserved word, a boundary-length string, or a value equal to an adjacent field — anything that risks silent normalization or a swallowed write.
- [ ] For **cross-role/cross-tenant absence**, this row is satisfied by Step 6's cross-tenant heuristic when only tenants exist; when the project has discovered roles (2B, `discovering-user-roles`), expand it per role. A single-user, single-tenant surface always defers this row with reason "single-role app — no second role/tenant to probe."

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

### Step 7 — Tag for Execution Order

Apply these tags to every criterion in the checklist:

| Tag | Meaning | Execution |
|---|---|---|
| (none) | Writes shared state; default | Sequential, single driver |
| `independent: true` | Does not affect shared state | May fan out (rarely) |
| `read-only: true` | No write to backend | May fan out (rarely) |
| `race: true` | Deliberate concurrency test | Fan out — two drivers, same backend entity |
| `cross-tenant: true` | Reads back as a second tenant | Sequential; second auth session on same driver |
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
| `Tag: cross-tenant` OR `Tag: probe-needed` | `probe` | `evidence/<crit>/network-response.json` |

A criterion may match several rows — union the kinds (e.g. a computed write is `bake,computed`). A criterion tagged `read-only` with no computed logic and no probe-needed tag (pure-display, e.g. `empty-state`, `loading-state`, an error-state that renders but doesn't write) derives `Kinds: none` and is legitimately un-gated.

`Kinds` is always **derived from tags**, never the reverse: `probe-needed` (set at generation time, per the rule above) is the INPUT; `Kinds: probe` is the OUTPUT the table derives from it. The same direction applies to `cross-tenant`. Do not treat `Kinds` as something you inspect to decide whether probing was needed — decide `probe-needed` first, from the criterion itself, then let the table derive `Kinds`.

- [ ] Set `Kinds` to the union of matched rows, as CSV, in the order `bake,computed,probe`.
- [ ] Set `probeNeeded: true` whenever `Tag: probe-needed` or `Tag: cross-tenant` is set (i.e. whenever the `probe` kind was derived), so the verifier knows to invoke `probing-apis-through-browser` rather than relying on the UI alone.
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
| Cross-tenant isolation | Draft visible to another tenant (bug #12) — missed if not explicitly generated |
| Concurrency/race | Double-finalize, optimistic-lock missing |
| Edge-case catalog: empty/0-value input | False "success" on a 0/empty write that never persists (J4) |
| Edge-case catalog: negative/out-of-range value | Missing server-side validation on an invalid value (F4) |
| Edge-case catalog: every-Nth repetition | Silent drop on the Nth repeated write (J3) |
| Edge-case catalog: named/boundary value | "Ghost" write — success indicator fires, nothing persists (J1) |
| Edge-case catalog: delete-then-reconcile | Stale aggregate/total after a delete (F3) |
| Edge-case catalog: cross-role/tenant absence | Cross-role authz leak — deferred with reason when no second role exists |

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
