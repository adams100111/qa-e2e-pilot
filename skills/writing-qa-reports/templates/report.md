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
- Recompute notes:   `evidence/{{CRITERION_ID}}/recompute.md`

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
