---
name: verifying-computed-logic
description: Use when a criterion involves a calculation, report, aggregation, or business-rule outcome (vesting, ownership %, pool sizing, anti-dilution, amount = shares × price, waterfall, validation gates, approval chains) — recompute the expected value INDEPENDENTLY from the spec/domain oracle, compare to UI and API within an explicit tolerance, localize any divergence by reading the backend (FE format vs API serialization vs service formula vs DB precision), and trace downstream impact onto dependent entities. Verify the logic, not the screen. Reading the backend's own formula is a mirror, not a verification.
---

# Verifying Computed Logic

## Overview
A green number is not a correct number. Recompute the expected value yourself from the **oracle** (the checklist's stated rule or a reference design doc), compare it to what the UI and API show, and confirm the action's downstream cascade. The backend's own formula is NEVER the oracle — recomputing against it only mirrors its bug.

## When to Use
- A criterion's expected value is a **calculation, report, or aggregation** (vesting accrual, fully-diluted %, ESOP pool, anti-dilution, `amount = shares × price`, waterfall/HHI).
- A criterion asserts a **business-RULE outcome**: a validation gate, a violation rule, an approval-chain transition.
- An action should **cascade** onto dependent entities (transaction → holdings → cap-table).
- Anytime a number on screen could be wrong even though nothing turned red.

Pair with **driving-browser-qa** (to read the screen) and **verifying-backend-persistence** (baking). This skill owns the math; this is a STEP inside a criterion, not its own criterion — it rolls into the one verdict and names the suspected layer on failure.

## The Loop (turn each into a todo per criterion)

### 1. Recompute (from the oracle, not the backend)
- [ ] Find the rule in the **oracle**: the checklist's expected value, or the reference repo's design doc (e.g. `GOVERNANCE_*.md`). NOT a backend service/migration.
- [ ] Derive the expected value/outcome **by hand** and write the arithmetic into the criterion notes. Keep full precision — do not round yet.
- [ ] If the only available source for the expectation is backend code, you may still proceed, but tag the verdict **confidence: low** (see below).

### 2. Compare (UI + API, within explicit tolerance)
- [ ] Read the displayed value off the page snapshot (`browser_snapshot`).
- [ ] Where possible, read the raw value from the API response body (`browser_network_request` → the tRPC/REST response that fed the screen) — this catches FE-only formatting bugs.
- [ ] State the **tolerance** before comparing:
  - **Money / exact decimals**: tolerance `0` on the exact decimal. Compute exact (`4000000 * 0.001 = 4000.000`); never pre-round inputs. A sub-cent truncation is a real bug, not noise.
  - **Floats / %**: a small absolute or relative tolerance (e.g. `abs(diff) <= 1e-6`, or ≤ 0.01 percentage points for displayed %). Justify the tolerance from the spec's stated precision.
- [ ] Compare recomputed-expected vs FE display vs API value. All agree → likely pass (still do step 4). Any disagree → step 3.

### 3. Localize (only on divergence — read backend by role)
Reconciliation: walk the **same quantity** across layers to pin where it breaks. Read the backend repo (`.qa/config.json` → role `backend`) ONLY to localize, never as the oracle.

| Layer | What to read | Smell |
|---|---|---|
| FE format | the component/formatter | right API value, wrong display (rounding, locale, units) |
| API serialization | the response shape (`browser_network_request`) | DB right, response truncated/cast |
| Service formula | the service/computed method | formula differs from the spec rule → **wrong formula** |
| DB precision | the migration / column type | `decimal(p, 2)`, integer cast, lost scale |

- [ ] Record the **suspected layer** on the verdict. That string is the deliverable of a fail.
- [ ] If the divergence is the backend formula disagreeing with the spec rule, that is the bug — the spec wins.

### 4. Trace (downstream cascade)
A criterion passes only when **FE shows X AND backend stored/constrained X AND X equals the independent expected value.**
- [ ] Perform the action (create/edit/approve) via the browser.
- [ ] Bake the dependent entities at the right multiplicity (0/1/N) and confirm each updated correctly: transaction → holdings → cap-table totals still reconcile (e.g. ownership % across all holders sums to 100% ± tolerance).
- [ ] A broken cascade is a fail even if the directly-edited row looks right.

## Confidence: when to mark LOW
- **low** = the expected value could ONLY be derived from backend code; you had no spec/domain oracle. You can still catch **precision and propagation** bugs (a value that doesn't reconcile across layers), but you CANNOT catch a **wrong formula** — both sides would share it.
- **high** = you derived the expectation from the spec/domain rule independent of the implementation.
- Confidence is orthogonal to the verdict. A `pass` can be `confidence: low`; say so honestly.

## Deferred: honest non-verification
Mark **deferred** (with a reason) for math you deliberately did not verify this run rather than faking a pass. Real examples to defer when the oracle or env isn't ready: round-close math, scenario/what-if modeling, concurrency/race outcomes. `deferred` ≠ `blocked` (env stopped us) ≠ `error` (our tooling broke).

## Worked micro-examples

### Flagship: `amount = shares × price` precision (bug #9)
- **Recompute (oracle = rule)**: `4,000,000 shares × $0.001 = $4,000.000` exactly. Tolerance `0` (money).
- **Compare**: UI/API shows `$3,999,xxx` or a truncated figure → diverges.
- **Localize**: FE format fine; API matches DB; service formula matches the rule → read the migration: column is `decimal(precision, 2)`. 2-dp scale truncates `0.001` before the multiply. **Suspected layer: DB precision.**
- **Verdict**: fail, confidence: high, suspected layer = DB column precision. This is the bug the plugin exists to catch.

### Fully-diluted ownership %
- **Recompute**: holder's FD% = `holder_shares / fully_diluted_total`, where FD total = issued + options + unissued ESOP pool, per the spec. e.g. `250,000 / 5,000,000 = 5.000%`. Sum across all holders must = 100%.
- **Compare**: FD% on the cap-table snapshot and in the tRPC response, tolerance ≤ 0.01pp. If the page shows 5.26% it used issued-only (`250k/4.75M`) as the denominator → wrong denominator.
- **Localize**: service uses issued total, spec says fully-diluted → **service formula**, fail, confidence: high.
- **Trace**: after issuing new options, re-bake every holder's FD% and confirm they still sum to 100%.

### Vesting accrual (cliff + monthly)
- **Recompute**: 48-month schedule, 12-month cliff, 4,800 total. At month 13: cliff releases `12/48 = 1,200`, plus 1 month = `1,300`. Tolerance: exact share count `0`.
- **Compare**: vested-to-date on screen vs API. If it shows `1,200` at month 13 it forgot the post-cliff monthly accrual; if `0` it mis-handled the cliff boundary.
- **Localize / trace**: read the accrual service to pin off-by-one vs cliff logic; then confirm vested shares cascade into the holder's exercisable count.

### Business-rule outcome: setup gate (bug #3)
- **Recompute the OUTCOME**: rule says "setup gate blocks ONLY an unconfigured project." Project is already populated → expected outcome: **gate does not trap; user proceeds.**
- **Compare**: gate traps the populated project anyway → wrong rule outcome (fail-open / fail-closed inversion).
- **Verdict**: fail, suspected layer = gate predicate in the service. A rule outcome is verified exactly like a number: derive expected from the spec, compare to actual.

## Mini-evals (given → catch)
1. **Given** `4,000,000 × $0.001` rendered as a green saved toast and a plausible total, **catch** the sub-cent truncation by recomputing `$4,000.000` exactly (tolerance 0) and reconciling to the `decimal(p,2)` migration → fail @ DB-precision layer. (NOT caught if you "recompute" using the backend's own column-typed value.)
2. **Given** an ownership % that looks reasonable (5.26%), **catch** the wrong denominator by recomputing FD% from the spec's fully-diluted total (5.000%) → fail @ service-formula layer, confidence high.
3. **Given** a populated project that the setup gate refuses to release, **catch** the inverted business-rule outcome by deriving "gate releases a configured project" from the spec → fail @ gate predicate.
4. **Given** a share transaction that updates the holding but leaves the cap-table total stale, **catch** it by tracing the cascade and re-summing ownership to ≠100% → fail @ aggregation, even though the edited row was correct.
5. **Given** round-close math with no spec oracle available this run, **do not** fake a pass — mark **deferred** with reason, or if you must use backend-only values, mark `pass/fail` **confidence: low** (catches propagation, not a wrong formula).
