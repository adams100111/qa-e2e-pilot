# ADR-0032 — Trusted-verdict gates: oracle, state and data policy at record time; a computed ship verdict

## Status

Accepted (2026-11-09). Ship QA increment 2, engine 0.12.0 + qa-kit 0.3.0 (released together with
increment 1). Design: [`docs/superpowers/specs/2026-11-09-ship-grade-qa-design.md`](../superpowers/specs/2026-11-09-ship-grade-qa-design.md)
§2a, 2b, 2d and its "Settled" sections (#3, #8, the grilling additions). Extends
[ADR-0010](./0010-execution-enforcement-evidence-gate.md) (evidence gate),
[ADR-0018](./0018-out-of-agent-evidence-enforcement.md) (`qa-verify.sh` as the out-of-agent authority),
[ADR-0023](./0023-qa-kit-tdqa-data-layer.md) (pinned fixtures and `oracleSource`),
[ADR-0027](./0027-fail-fast-record-time-and-real-driver-shapes.md) (fail at record time) and
[ADR-0030](./0030-surface-census-and-ship-profile.md) (profiles, `dataPolicy`). The independent
second judge is [ADR-0033](./0033-independent-re-adjudication.md). Adds no verdict, confidence level,
suspected layer or evidence kind.

## Context

Increment 1 made a run say what it covered. It did not make a `pass` mean more than it did in 0.11.0.
Three holes remained, all seen on the hackathons module run:

- **The oracle could be the model's guess.** `oracleSource` existed (ADR-0023), and "`confidence:
  high` needs a human-confirmed oracle" was an authoring rule the agent was asked to follow. Nothing
  enforced it, so an `llm-suggested` expected value could ground a high-confidence pass.
- **A write could pass on what the screen said.** A mutating criterion whose kind derives no `bake`
  (error-state, deny, business-rule) could pass on `human-action` alone: a toast and a screenshot,
  with no read-back of what was persisted.
- **Generated data could carry test markers.** The data policy (forbidden markers, email domain,
  date window) was a script the agent was asked to run, not a condition of a pass.

A run's headline was also a tally, not a decision: nothing said "ship" or "don't ship", and a reader
had to work out from 180 cards whether the P1 flows held.

## Decision

**A. Three new record-time gates in `checkpoint.sh`, on `pass` only.** They run after the
required-kinds gate, in this order, and each refuses with exit 1 and one line prefixed by its name
(the `EVIDENCE GATE:` style):

1. **ORACLE GATE** (D1/D2). Applies when the row has `fixture.expect.oracleSource`, or the effective
   profile is `ship` and the kind is `computed-logic|business-rule`. A `confidence: high` pass needs
   `oracleSource` `human` or `spec`; anything else (`llm-suggested`, missing, a non-string) is refused:
   `ORACLE GATE: <id> oracleSource=<value|missing> cannot ground a high-confidence pass (allowed: human, spec)`.
   `pass` + `confidence: low` is always allowed — the honest downgrade. A row whose kind or source
   holds a control character is refused at any confidence as malformed. `spec` is only valid with a
   `citation` `<path>:<line>` that qa-kit's `check-fixtures.sh` resolves inside the checklist dir or
   the git root (no absolute paths, no `..`, symlinks resolved and contained).
2. **STATE GATE** (D3). In **every** profile, a `pass` on a mutating row (per `mutation-flag.sh`)
   needs `bake` or `probe` in `--kinds`:
   `STATE GATE: <id> is mutating; a pass needs bake or probe evidence (got: <kinds|none>)`.
   `--nonui-reason` does not bypass it. Read-only rows are exempt; a row absent from the checklist is
   unaffected. A rejected write passes on a bake read-back at multiplicity 0 that shows nothing
   persisted.
3. **DATA POLICY GATE** (D4). Only when `effective-config.json` has `gates.dataPolicy: "enforce"` (the
   `ship` default) and the row is mutating. It checks the **typed values** in the row's
   `action-trace.json` (each step's `text`, `value`, `values`, `fields[].value`) with
   `scripts/data-policy.sh check`, never record metadata (run id, timestamps, selectors) and never a
   field whose label looks like a password/secret/token/OTP/PIN. The text goes through a mode-600 temp
   file passed as `@file`, removed on exit or interrupt. `input-validation` rows skip date-window and
   email-domain (their values are meant to be rejected); forbidden markers still apply.
   `DATA POLICY GATE: <id> typed data violates dataPolicy: <rule>=<match>[, ...]` (first 3). A bad
   policy config (exit 2) is a refusal; a missing `data-policy.sh` (older install) is a stderr NOTE.

**B. `qa-verify.sh` mirrors them** (checks 3.6, 3.7, 3.8), so a record written by an older
checkpoint or a bypassed gate still ends as an override to `fail`/`high` with reason
`oracle-ungrounded`, `no-state-evidence` or `data-policy-violation`. The mirror fails closed: the
oracle check applies to any in-run confidence other than exactly `low`, and a confidence outside
`high|low` is its own override (`invalid-confidence`). Data-policy reasons name rules only, never the
matched values. With `enforce` and no `data-policy.sh`, qa-verify overrides ("checker unavailable")
where checkpoint only notes. A new run check, `effectiveConfigMissing`, fails the run when
`.qa/config.json` or the spec's `run-config.json` asks for `ship` or `gates.dataPolicy: enforce` but
the run has no `effective-config.json` — otherwise deleting that file would switch the gates off.
The `verification.json` shape is unchanged; the key appears only when the check fires.

**C. Gates only refuse or downgrade.** Nothing here turns a non-pass into a pass or raises a
confidence. A plain `/qa-run` with no `oracleSource` on its rows and profile `full` passes exactly
what 0.11.0 passed, **except the state gate** (E).

**D. The ship verdict is computed, not written.** `render-report.js` opens the report with
**Ship readiness** when the run has `coverage.json` or `journeys.json`, or the profile is `ship`.
`SHIP-READY` only when: census coverage has no uncovered pair; every P1 journey passed (same rule as
`journeys.sh status`); no P1 criterion failed or errored at a coding layer
(`route|service|migration|DB`); and `qa-verify` overrode no P1 criterion. A pass the re-adjudicator
disputed is `blocked`, so its journey is not `pass` and the verdict blocks through the journey rule. Otherwise
`NOT SHIP-READY` with each failing condition listed. It fails closed: a missing `coverage.json`
(unknown), no P1 journey declared, a failed adapter, an empty census, a missing or out-of-date
`verification.json` on P1 criteria, and a P1 fail with an unknown layer all block. An FE fail on a P1
criterion is listed but does not block. Low-confidence passes and flaky criteria are counted; the
regression line reads `not yet available` until increment 3. A run with none of the inputs renders
byte for byte as before.

**E. The bug export is tracker-neutral.** `scripts/bug-export.sh <run-dir> --out <dir>` writes
`bugs.json` and one plain-language `<id>.md` per new bug (What happened, What should happen, Steps,
Evidence) from `bug-log.json` and every verifier override without a bug entry. A bug matching an
`outstanding` known defect on the same surface (and criterion, or observed class when the defect
names none) gets `duplicateOf` and no `.md`. Severity defaults to `high` for coding layers, else
`medium`. Secrets are redacted before anything is written. Tracker adapters stay outside the core.

## Consequences

- **Behaviour change vs 0.11.0: the state gate applies in all profiles.** A mutating pass needs
  persisted or network evidence; that is the honesty invariant, not a ship-only rule. Legacy flows
  that passed a rejected write (an `error-state` row that "adds a duplicate to trigger a validation
  error") on `human-action` alone are now refused at record time and overridden by qa-verify. The fix
  is a bake at multiplicity 0, never `mutates:false` on a row that does attempt a write.
- Under `ship`, every `computed-logic`/`business-rule` pass at high confidence needs a confirmed
  oracle. qa-kit's oracle confirmation page (`oracle-confirm.sh`, `/qa-analyze` step 4c) is how
  rows get `oracleSource: human`; under `autonomousSetup` they stay low and the report counts them.
- Agents must record more to pass: the bake/probe artifact on every mutating row, a confirmed
  oracle on gated computed rows, and clean, realistic typed data when the policy is enforced.
- The gates and their mirror are duplicated code in two scripts (the existing convention); a parity
  suite (`tests/verify-ship-gates`) asserts that each checkpoint refusal has a matching qa-verify
  override on the same row, record and config.
- Suites: `gate-oracle`, `gate-state`, `gate-data-policy`, `verify-ship-gates`, `ship-summary`,
  `bug-export` (engine), `oracle-confirm` (qa-kit).
