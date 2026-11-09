# QA analysis — {{TARGET}}

> Authored by `/qa-analyze`. **Advisory only, except the Coverage gate** — under the `ship` profile an
> uncovered surface x role pair makes the Verdict `BLOCKED`; every other section does not block the run.
> This review changes no artifact. Remediation is applied by re-running the relevant earlier step (`/qa-scenarios` or
> `/qa-spec`), at the operator's discretion.

## Coverage

<!-- From coverage.sh (mode from the effective config's gates.coverage): "<covered>/<total> pairs, <percent>%,
     excluded <n>, mode <block|advise>". Then one line per `uncovered` pair (surface x role) and per
     `covered-unscoped` pair (covered only by a row with no role; counts as uncovered under block), each with
     the remediation (add a criterion via /qa-scenarios, or record an exclusion with a reason), plus any
     journeys.sh validate errors. "(none)" if clean; "(no census)" when no census exists. -->

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

## Plan defects

<!-- Criteria whose ORACLE ASSERTS THE APPLICATION FAILED — a wrong criterion, not a missing one.
     One line each: criterion id, the signal that flagged it (structural: a reserved health-namespace
     expect pinned to a failing value, e.g. page.rendersWithoutServerError=false, page.crashed=true,
     console.hasError=true, http.status >= 500 — a 3xx/4xx is legal and never a plan defect; or prose:
     "expected to fail" / "known defect" / "not a regression" in an oracle/expect field, never in
     `action`), and the remediation — migrate-inverted-criterion.sh, which files the defect in the
     project-level `.qa/known-defects.json` (exit 2 is its SUCCESS path). Never "loosen the criterion".
     "(none)" if clean — this heading is PRE-PRINTED and is never deleted. An empty section is the
     point: the originating incident's inverted criterion was folded into *Risk gaps* under an
     analysis whose own summary read "oracle gaps: 0", and an absent heading is what let it vanish. -->

## Verdict

**BLOCKED** when the Coverage gate blocks (ship profile, uncovered pairs > 0, an empty or uncrawled census); otherwise **PASS (advisory)**. Set from `coverage.sh`'s exit code, never from a manual count.

Apart from the Coverage gate this review is advisory only — the run is **not** blocked by it; this does not extend to plan defects. {{GAP_SUMMARY}}
