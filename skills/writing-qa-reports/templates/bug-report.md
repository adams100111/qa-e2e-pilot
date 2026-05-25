---
title: Bug Report
---

### BUG-{{BUG_N}}

**Title:** {{BUG_TITLE}}

**Criterion:** {{CRITERION_ID}} — {{CRITERION_TITLE}}

**Environment:** {{ENVIRONMENT}}
**Build / Deploy ID:** {{BUILD_ID}}

---

#### Steps to Reproduce

1. Log in as {{ROLE}} (e.g. admin / founder / investor).
2. Navigate to {{ROUTE_OR_SCREEN}}.
3. {{STEP_3}}
4. {{STEP_4}}
5. {{STEP_5_OBSERVE}}

> Start from a logged-in state. Include any required preconditions (existing records, specific config values).

---

#### Expected (from oracle)

{{EXPECTED_DESCRIPTION}}

> If computed logic is involved, show the arithmetic explicitly:
> `{{FORMULA}} = {{COMPUTED_EXPECTED}}`
> e.g. `4,000,000 shares × $0.001/share = $4,000.00`

---

#### Actual

{{ACTUAL_DESCRIPTION}}

> e.g. `$4.00 stored and displayed — value truncated`

---

#### Severity

{{SEVERITY}}

> One of: `critical` | `high` | `medium` | `low`
> critical = data corruption or security; high = wrong stored value, visible to users; medium = UI-only cosmetic; low = minor/edge case.

---

#### Suspected Layer

{{SUSPECTED_LAYER}}

> One of: `FE` | `route` | `service` | `migration` | `DB`
> This is a localization hypothesis, not a confirmed root cause.
> Localise by reconciling: recomputed-expected vs FE display vs API response vs DB row/migration.

---

#### Suggested Fix

{{SUGGESTED_FIX}}

> One concrete, actionable suggestion. Examples:
> - "Alter `issuances.amount` column to `decimal(15,4)` and add a migration test asserting no truncation at price < $0.01/share."
> - "Move the rounding call from the FE formatter to the service layer so all consumers agree."
> - "Add a DB constraint `CHECK (amount = shares * price_per_share)` within tolerance."

---

#### Evidence

- Screenshot before: `evidence/{{CRITERION_ID}}/screenshot-before.png`
- Screenshot after:  `evidence/{{CRITERION_ID}}/screenshot-after.png`
- Bake read-back:    `evidence/{{CRITERION_ID}}/bake-read-back.json`
- Network response:  `evidence/{{CRITERION_ID}}/network-response.json`
- Recompute notes:   `evidence/{{CRITERION_ID}}/recompute.md`

> Remove lines for evidence files that do not exist for this criterion.
