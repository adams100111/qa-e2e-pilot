# QA analysis — {{TARGET}}

> Authored by `/qa-analyze`. **Advisory only** — this review does not block the run and changes no
> artifact. Remediation is applied by re-running the relevant earlier step (`/qa-scenarios` or
> `/qa-spec`), at the operator's discretion.

## Coverage gaps

<!-- Surfaces/affordances (from the UI surface map) or spec items with no covering criterion.
     One line each, with a suggested remediation. "(none)" if clean. -->

## Role gaps

<!-- spec-roles.json roles no scenario exercises; or a criterion whose role is not in the snapshot. -->

## Oracle gaps

<!-- computed/business-rule criteria whose "correct" is not independently pinned in qa-spec.md's
     Oracles section (i.e. the oracle would default to the backend's own formula — not allowed). -->

## Risk gaps

<!-- high-stakes paths (cross-tenant, destructive, money/permissions) with no criterion. -->

## Data gaps (TDQA)

<!-- From check-fixtures.sh: computed criteria with no well-formed pinned expect (must fix for
     confidence:high), and llm-suggested pins that run at confidence:low. From data-baseline.json vs
     dependsOn: dead seeded rows, uncreated 'created' entities, seeded rows with no readable surface
     (assumed at run → low confidence). -->

## Verdict

Advisory only — the run is **not** blocked. {{GAP_SUMMARY}}
