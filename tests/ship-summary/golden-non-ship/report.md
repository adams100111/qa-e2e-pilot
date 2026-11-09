# QA report — Cap table — founders

**Run:** `fixture-run`  
**Started:** 2026-10-01T10:00:00Z  
**Ended:** 2026-10-01T10:05:00Z  
**Build:** abc1234  
**Target:** http://localhost:3000

---

## Summary

| Verdict | Count |
|---|---|
| pass | 4 |
| fail | 2 |
| blocked | 1 |
| deferred | 1 |
| error | 0 |
| **Total** | **8** |

> 2 verdict(s) carry confidence: low.

qa-verify re-checked 5 criterion record(s); 1 overridden.

Screenshots: 4 of 6 pass/fail criteria carry a recorded screenshot (6 image(s)).

**__screenshots__** (pass, confidence low):
- example run-level note

---

## Criteria

### C1 — Add a founder persists 1-of-N

| Field | Value |
|---|---|
| Verdict | **pass** |
| Confidence | high |
| Oracle | count(founders) = baseline + 1 |
| Result | Created founder via the Add dialog; read back /api/founders/2 |
| Verified via | bake |

![C1 · before](evidence/C1/screenshot-before.png)
![C1 · after · full page](evidence/C1/screenshot-after.png)

Evidence: [C1/bake-read-back.json](evidence/C1/bake-read-back.json)

### C2 — Issuance amount at sub-cent price

| Field | Value |
|---|---|
| Verdict | **fail** |
| Confidence | high |
| Oracle | 4,000,000 × $0.001 = $4,000.00 |
| Result | Total shows $4.00 instead of $4,000.00 |
| Bug | [BUG-1](#bug-1) |

![C2 · after](evidence/C2/screenshot-after.png)

### C3 — Admin totals (admin)

| Field | Value |
|---|---|
| Verdict | **pass** |
| Confidence | high |
| Oracle | sum(rows) = 42 |
| Result | Admin table sums match the oracle |
| Verified via | computed |

![C3 · admin · after (table)](evidence/admin/C3/screenshot-after-table.png)

### C4

| Field | Value |
|---|---|
| Verdict | **pass** |
| Confidence | low |
| Result | Legacy run: loose screenshot only |

Verifier notes:
- no screenshot evidence: no recorded screenshot under evidence/C4/ (report.requireScreenshots)

![C4 · after (not provenance-bound)](evidence/C4/legacy-after.png)

### C6

| Field | Value |
|---|---|
| Verdict | **pass** |
| Confidence | low |
| Result | Read-only count matches |
| Verified via | computed |

Verifier notes:
- no screenshot evidence: no recorded screenshot under evidence/C6/ (report.requireScreenshots)

_No screenshot recorded._

### C7

| Field | Value |
|---|---|
| Verdict | **fail** (in-run pass, overridden by qa-verify) |
| Confidence | high |
| Result | Its image was altered after recording |

Verifier notes:
- screenshot TAMPERED: 'evidence/C7/screenshot-after.json' — evidence/C7/screenshot-after.png no longer matches the sha256 recorded with it

![C7 · after (altered)](evidence/C7/screenshot-after.png)

### C8

| Field | Value |
|---|---|
| Verdict | **blocked** |
| Confidence | high |
| Result | Login wall <script>alert(1)</script> blocked the page |


---

## Deferred

### DEFERRED — C5

**Reason:** Round-close math requires a closed round — not available in this env.


---

## Bugs

### BUG-1 — Amount truncated

- **Severity:** high
- **Suspected layer:** migration
- **Criterion:** C2
- **Expected:** $4,000.00
- **Actual:** $4.00

Steps to reproduce:
1. Open issuance
2. Enter 4,000,000 shares at $0.001


---

_Rendered by qa-e2e-pilot render-report.js from the run's own record. Image links are relative to this run directory._

