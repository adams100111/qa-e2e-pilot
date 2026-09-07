# QA Run Report

**Run ID:** {{RUN_ID}}
**Date:** {{DATE}}
**Feature / Target:** {{FEATURE}}
**Build / Deploy ID:** {{BUILD_ID}}
**Detected stack:** {{STACK}}  (playbook tier: {{STACK_TIER}}, detection signal: {{STACK_SIGNAL}})

{{STACK_DRIFT_NOTE}}

> Replace `{{STACK}}` from the run's `stack-profile.json` (e.g. "laravel + inertia (server-bridge)").
> `{{STACK_TIER}}` = the playbook used (laravel / openapi-generic / generic).
> `{{STACK_SIGNAL}}` = strong | weak. If weak or `mode`/`environment` warrant it, replace
> `{{STACK_DRIFT_NOTE}}` with a line like "> **Note:** black-box production target, no local
> source — code-derived facts are signal: weak." Otherwise remove the line.

---

## Summary

| Verdict   | Count |
|-----------|-------|
| pass      | {{TALLY_PASS}} |
| fail      | {{TALLY_FAIL}} |
| blocked   | {{TALLY_BLOCKED}} |
| deferred  | {{TALLY_DEFERRED}} |
| error     | {{TALLY_ERROR}} |
| **Total** | **{{TALLY_TOTAL}}** |

{{LOW_CONFIDENCE_NOTE}}

> Replace `{{LOW_CONFIDENCE_NOTE}}` with a sentence like:
> "> **Note:** 2 verdict(s) carry confidence: low — expected value derived from backend code only."
> Or remove the line if no low-confidence verdicts exist.

---

## Cost

| Field | Value |
|---|---|
| Started | {{COST_STARTED_AT}} |
| Finished | {{COST_FINISHED_AT}} |
| Criteria | {{COST_CRITERIA}} |
| tool-calls | {{COST_TOOL_CALLS}} |
| tool-calls by criterion | {{COST_TOOL_CALLS_BY_CRITERION}} |
| Budget | {{COST_BUDGET_NOTE}} |

{{COST_TOKENS_ROW}}

> Fill from `run-manifest.json`'s `cost` object (`scripts/cost-summary.sh`'s output — audit-2
> W4-3; never hand-computed). `{{COST_TOOL_CALLS_BY_CRITERION}}` renders the
> `toolCallsByCriterion` map as `id: N, id: N, …` plus, when `unattributedToolCalls > 0`, a
> trailing `unattributed: N`; when `attribution` is `"unavailable"` (no `journal.ndjson` yet)
> replace the whole row's value with `not derivable this run — see cost-summary.sh's ATTRIBUTION
> note`. `{{COST_BUDGET_NOTE}}` reads `criteriaDone/criteriaBudget` (e.g. "48 / 60") plus
> `⚠ ≥80% consumed (soft cap — not a coverage cut)` appended only when `budgetWarn` is `true`.
> `{{COST_TOKENS_ROW}}` is `| tokens | {{COST_TOKENS}} |` when the manifest's `cost.tokens` is
> non-null (the Claude harness fills it when usage is exposed), otherwise remove the row
> entirely — never render a fabricated token count. If `run-manifest.json.cost` is still `null`
> (cost-summary.sh was never run), replace this whole section with `_Cost telemetry unavailable
> for this run._` rather than leaving placeholders unfilled.

---

## Criteria

<!-- One section per criterion. Replace placeholders and remove this comment. -->

<!--
### {{CRITERION_ID}} — {{CRITERION_TITLE}}

| Field           | Value |
|-----------------|-------|
| Verdict         | {{VERDICT}} |
| Confidence      | {{CONFIDENCE}} |
| Oracle          | {{ORACLE}} |
| Expected        | {{EXPECTED}} |
| Actual          | {{ACTUAL}} |
| Suspected layer | {{SUSPECTED_LAYER}} |
| Bug report      | {{BUG_REF}} |

**Evidence:**
- Screenshot before: `evidence/{{CRITERION_ID}}/screenshot-before.png`
- Screenshot after:  `evidence/{{CRITERION_ID}}/screenshot-after.png`
- Bake read-back:    `evidence/{{CRITERION_ID}}/bake-read-back.json`
- Network response:  `evidence/{{CRITERION_ID}}/network-response.json`
- Recompute notes:   `evidence/{{CRITERION_ID}}/recompute.json`

Remove rows that do not apply (suspected layer / bug-ref on a pass; recompute when no math is involved).
-->

{{CRITERIA_SECTIONS}}

---

## Deferred

<!-- Every deferred criterion MUST appear here with a plain-English reason.
     Never silently drop a criterion. Never record pass for something not verified.
     If this section is empty, write: _No criteria were deferred this run._ -->

<!--
### DEFERRED — {{CRITERION_ID}}: {{CRITERION_TITLE}}

**Reason:** {{DEFERRED_REASON}}

Valid reason examples:
- "Round-close math requires a completed round — not available in this env. Verify in staging after round close."
- "Concurrency test requires two simultaneous sessions — deferred to load-test suite."
- "Scenario modeling covers future projections — out of scope for this run."
-->

{{DEFERRED_ENTRIES}}

---

## Bugs

<!-- One filled bug-report block per failing criterion.
     Copy and fill templates/bug-report.md for each.
     Use anchor format ### BUG-N so verdict cards can link to it. -->

{{BUG_APPENDIX}}
