# ADR-0029 — One authoritative verdict per criterion; identity refused at record time; phase windows end on their own

## Status

Accepted (2026-10-01). Engine 0.11.0. Extends [ADR-0012](./0012-per-role-scope-and-cross-role-tests.md)
(the `(criterion, persona)` identity), [ADR-0020](./0020-durable-run-state-machine.md) (journal →
fold), [ADR-0021](./0021-run-fsm-enforcement.md) (phase-surface pass) and
[ADR-0027](./0027-fail-fast-record-time-and-real-driver-shapes.md) (refuse at record time what can
never be corrected). Adds no verdict, confidence level or suspected layer; the journal stays
append-only.

## Context

A real 0.10.0 run (`register-choose-later`, 61 criteria, one resume) ended with a `checkpoint.json` of
**100 rows for 61 criteria** and a report that tallied `deferred=39 total=100`:

1. **Resume duplicated rows.** The first pass checkpointed 38 criteria `deferred` without `--persona`
   (tuple `__shared__ / ""`). The resume ran them correctly as `participant`/`admin` (tuple
   `participant / participant`, …). The fold keys rows by `(scenarioId, criterionId, personaId)`, so
   the placeholder and the real verdict became two rows; the report and qa-verify counted both. The
   resume briefing listed the deferred placeholders under `skip`, which pushed the agent onto a
   different tuple to re-run them at all.
2. **`__phase-surface__` was always `low`.** 84 reasons: 77 human-path clicks/typing (logins between
   personas, opening sheets) that fell outside the narrow `act_intent → act_committed` windows while
   Verify was the active phase, and 7 before the first `phase_entered` — which checkpoint.sh only
   writes at the first verdict, minutes after the first login. Agents were blamed for "forgetting
   `phase_exited`", but no rule ever read it.
3. **Shared-criterion identity slip.** `journal-emit.sh started <run> admin <crit> admin` followed by
   `checkpoint.sh <run> <crit> pass` (no `--persona`) — two identities for one criterion: a
   `verdict-without-started` anomaly and a resume cursor pointing at finished work.
4. **Batch slip.** A shell loop passed twenty ids as one argument; `checkpoint.sh` recorded one
   criterion whose id was all twenty. It is permanent — editing the journal would be tampering.
5. **Unjournaled finding.** An in-scope 500 was observed mid-run but journaled as `finding_observed`
   only after qa-verify's ledger check failed at the very end.
6. **Persona identity stayed low** for a persona bucket (`participant`) that maps to many fixture
   accounts: `expectedSubject` holds one subject, and the bare persona-id comparison cannot match
   `qa.rcl.p2@…`.

## Decision

**A. Supersession — the latest authoritative verdict per criterion.** In both fold engines, a
**persona-less** row (`personaId ""`) is *superseded* when the same `criterionId` later (higher
verdict `seq`) receives a verdict under a persona. The superseded row leaves `criteria[]` and is
listed under a new `checkpoint.superseded[]` (`{criterion_id, persona, verdict, checkpointed_at,
superseded_by: {persona, verdict, checkpointed_at}}`, present only when non-empty) plus a
`superseded-row` fold anomaly. It is deliberately **asymmetric**: a persona-scoped row is never
superseded — not by another persona (two personas are two cases, ADR-0012) and not by a persona-less
row (one shared record must not erase every persona's result). This adds no forgery path the
existing last-wins-per-tuple rule does not already have. The journal is untouched.
`render-report` and `qa-verify` apply the same rule to a `checkpoint.json` folded by an older engine
(timestamp-ordered; a same-second tie keeps both rows), report the number of superseded rows
(`render-report`: summary + "Process anomalies"; `qa-verify`: `criteria=<n> superseded=<n>` in its
summary line), and `render-report` excludes rows whose id is not in the journal's frozen plan
(`plan_frozen` ∪ `plan_amended`) from the tally, listing them as out-of-plan. The resume briefing
moves `deferred` tuples out of `skip` into a new `retry` list, to be re-run under exactly their
recorded identity.

**B. Identity is refused at record time** (`plan-guard.sh`, called by `checkpoint.sh` before any gate
and by `journal-emit.sh started`): a criterion id containing whitespace — always; once a plan is
frozen, an id the plan does not name, or a persona the plan does not name for that criterion (the
message names the planned personas and `journal-emit.sh amend` as the sanctioned way to add one);
for `started`, a scenarioId that is not the one checkpoint.sh will record (`= personaId`, or
`__shared__` with `""`); for a verdict, an identity different from the criterion's open
`criterion_started`. Runs without a plan keep the legacy behaviour except for whitespace and the
started-identity pairing.

**C. Phase windows end implicitly.** qa-verify builds the phase timeline from the run's structure: a
`phase_entered` opens its phase and implicitly closes the previous one; `plan_frozen` and
`criterion_started` open Verify; a `phase_exited` closes a window only when it names the open one. No
caller ever has to emit `phase_exited`; `journal-emit.sh phase <run> <phase>` exists for explicit
transitions (e.g. Report) and writes the closing `phase_exited` itself. A human-path
`browser-mutation` while Verify is open is the sanctioned surface (ADR-0015 — the act and its
arranging go through real UI affordances) and is no longer flagged; a mutating `browser_evaluate`
outside every acting window, and any human-path mutation outside Verify, still are.
`state-machine.json` lists `browser-mutation` among Verify's allowed classes.

**D. Live nudge for unjournaled findings.** The capture hook reminds the agent, N captured calls
after it observed an in-scope fatal network row (per `classify-finding.sh`) or an `error` console row,
and again at 2N and 3N, while no matching `finding_observed` is in the journal (N =
`enforcement.findingNudgeAfter`, default 3, 0 disables). Advisory only; qa-verify's ledger check stays
the authority.

**E. `personas[].expectedSubjects`.** A list of ground-truth subjects per persona; an entry with `*` or
`?` is a case-insensitive glob over the whole captured subject (`qa.rcl.p*@innovation.test`), a plain
entry keeps `expectedSubject`'s substring rule. Any entry matching verifies; configured but none
matching overrides to `fail`, exactly like `expectedSubject`. `write-persona-config.sh` preserves it
across role regeneration. Without either key, the multi-account case still degrades to `low` — by
design (spec §5.5); the reason now says how to configure it.

## Consequences

- Behaviour changes: `checkpoint.sh` and `journal-emit.sh started` refuse the identities above;
  `checkpoint.json` may carry `superseded[]` and has fewer `criteria[]` rows on a resumed run;
  `fold-anomalies.json` may carry `superseded-row`; the resume briefing gains `retry` and `skip` no
  longer lists `deferred` tuples; `__phase-surface__` no longer flags human-path acts during Verify;
  `render-report`'s tally excludes superseded and out-of-plan rows (its summary line gains
  `criteria= superseded= out_of_plan=`); qa-verify's summary line gains `criteria= superseded=`.
- An existing run is corrected by re-folding a copy (`fold.sh`), then `qa-verify.sh` and
  `render-report.sh` — the journal is never edited.
