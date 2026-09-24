# ADR-0026 — Engine invariants outrank the frozen plan

## Status

Accepted (2026-09-23). Companion decision record for
`docs/superpowers/specs/2026-09-23-error-honesty-invariants-design.md` (authored as Task 1 of that
design's implementation plan, per the spec's front matter). Narrows the scope of [ADR-0020](./0020-durable-run-state-machine.md)'s
`plan_frozen` semantics; extends [ADR-0018](./0018-out-of-agent-evidence-enforcement.md)'s out-of-agent evidence enforcement to a
new axis — an application-failure disposition — that ADR-0018 did not cover.

## Context

A QA run against a Laravel app (`innovation`, spec `evaluation-counters`, run
`eval-counters-20260922b`) authored a criterion, `EC10`, with a pinned expectation:

```json
"expect": {
  "path": "page.rendersWithoutServerError",
  "value": "false",
  "tolerance": 0,
  "oracleSource": "human"
}
```

The page under test returned HTTP 500 — an unhandled `ValueError` from an enum cast rejecting a
legacy database value, taking down the whole gates surface for an authorized admin. The run
observed exactly that, and its `recompute.json` recorded:

```json
{ "oracle": false, "observed": false, "match": true }
```

The comparison **succeeded**. `EC10` was logged as `BUG-1` with `severity: "low"` and
`fix: "Deferred by design … Not actionable within this QA pass's scope"`, and `/qa-analyze` filed
it under *Risk gaps* as "Known live defect acknowledged" while reporting **oracle gaps: 0**. Nothing
in the pipeline malfunctioned. The plan said a crash was the correct answer, so a crash was graded
correct.

`plan_frozen` (ADR-0020 Decision §5) exists to make Verify replay a plan that cannot drift mid-run —
it fixes *what is checked* so a resumed or re-driven run doesn't silently re-scope itself. Nothing in
ADR-0020, or in ADR-0018's evidence/provenance layers, ever asked whether a criterion's own recorded
*expectation* was one the engine should honor. `EC10`'s `expect` was internally consistent, evidence
was captured faithfully, and the comparison matched — every check in the existing stack passed
because none of them was checking the one thing that mattered: that the criterion asserted an
application failure was the correct outcome, and the plan being frozen let that assertion stand
unexamined for the length of the run.

## Decision

**`plan_frozen` scopes what is checked; it never grants a criterion the power to declare an
application failure correct.** A frozen plan is a commitment to *stability of scope* across
resume/replay, not a grant of authority over the engine's own invariants about what "correct"
means. Engine invariants outrank the frozen plan.

Concretely: a criterion's `expect` may not pin a whole-page or transport-health signal (e.g.
`page.rendersWithoutServerError`, `http.status >= 500`) to a failing value and have that treated as
a legitimate, matched oracle. This is enforced structurally, ahead of Verify, by
`validate-checklist-json.sh` rejecting such an `expect` at authoring time (§4.1/I3 of the
2026-09-23 design), and independently re-checked, out of agent, by `qa-verify.sh`'s new run-scoped
checks (§5 of the same design) — the same two-layer pattern ADR-0018 established for evidence
kinds and provenance, applied here to disposition instead.

## Consequences

- `qa-verify.sh`'s new checks (findings-ledger recomputation, `classify-finding.sh` disposition,
  load-window coverage, and the known-defect gate) are **run-scoped**: they apply to the whole run's
  observed findings and may override or fail a run regardless of what verdict any individual
  criterion recorded for itself. A `pass` with `match: true` is no longer sufficient by
  construction — the run-scoped checks can still fail it.
- The **reserved-health-namespace rejection** is *not* one of those run-scoped checks: it is an
  **authoring-time** gate in `skills/generating-qa-checklist/scripts/validate-checklist-json.sh`,
  as stated earlier in this record. It stops the criterion being written; the run-scoped checks
  catch what the run then observes. Conflating the two was an error in an earlier draft of this
  section.
- This is a real behavior change, not a restatement. Today `qa-verify.sh` only re-checks records
  whose `verdict == "pass"` — which is exactly why `EC10`, recorded as a matched, low-severity
  "deferred by design" bug rather than a `pass`, was never re-examined by anything downstream.
  The run-scoped checks this ADR authorizes must not inherit that `verdict == "pass"` filter; they
  evaluate the run's findings ledger independently of what any one criterion's own verdict says.
- `plan_frozen`'s original guarantee is untouched: scope still cannot drift mid-run, and resume/
  replay still replays the same frozen plan. This ADR adds a ceiling above it, not a replacement.
- A criterion authored before this decision, with an `expect` in the reserved health namespace
  pinned to a failing value, needs migration (structural rejection + assisted migration, per the
  design's §4.1) rather than silent continuation — an existing frozen plan does not grandfather
  the old behavior past a re-validation.
- **Reversibility:** the enforcement is additive at two layers (authoring-time validation,
  run-scoped `qa-verify.sh` checks) over the existing frozen-plan and evidence machinery; removing
  either layer reverts to today's behavior, where a well-formed but dishonest `expect` can pass
  undetected. The hard-to-reverse call is the principle itself — that the frozen plan's authority
  is bounded by the engine's own invariants — hence this ADR.
