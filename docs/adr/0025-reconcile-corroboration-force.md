# ADR-0025 — reconcile force-journals `act_committed` for corroborations

## Status

Accepted, 2026-09-06. Implements the reconcile/rebake repair in PR #70 and the code-review follow-up in
`fix/code-review-followups`. Builds on the Run FSM Enforcement (the `criterion_started → act_intent →
act_committed` transition guard in `journal-emit.sh`) and ADR-0020/0021 (durable run state machine + its
enforcement).

## Context

`journal-emit.sh` carries a **cooperative FSM guard** (Run FSM Enforcement Task 4): it declines to append
`act_intent` unless the tuple already has a `criterion_started` (`arranging → acting`), and declines
`act_committed` unless the tuple is in `acting` (a prior `act_intent`). `--force` bypasses with a logged
stderr NOTE; a missing/unreadable `state-machine.json` skips the guard entirely. The guard's authority is the
**live agent path** (catching an act emitted without an arrange); the real backstop is `qa-verify`'s
phase-surface pass, not this guard.

`rebake.sh reconcile` is the **out-of-band recovery tool**: after a crash mid-act, it re-bakes the write-set
against read-backs and, on a `landed` outcome, journals `act_committed` to close the open act. Two distinct
situations reach that `landed` branch:

1. **Normal close** — an open act (`act_intent`, no commit). Transition `acting → baking`: guard-legal.
2. **Corroboration** — a key **already** committed (the confirming case: re-running reconcile on a landed
   act with all-found read-backs). Transition `baking → baking`: the guard **rejects** it without `--force`.

Before the guard existed, case 2 silently appended a second `act_committed`. When the guard landed, case 2
started failing — and because `rebake`/`qa-reconcile` were not in CI, it went unnoticed until the 2026-09-06
audit enrolled them (they were RED on `main@147e5a9`).

## Decision

`reconcile`'s `landed` branch **detects whether the key is already committed** (`key_already_committed`, a
dual-engine scan of the run's journal for an `act_committed{key}`) and passes `--force` to `journal-emit.sh
act-commit` **only in that corroboration case**. The normal close still goes through the guard unforced.

- A corroborating `act_committed` is a legitimate reconciliation record ("re-confirmed landed at T2"), not an
  illegal transition — forcing it is correct, and the logged NOTE keeps it auditable.
- Scoping `--force` to the already-committed case (rather than always-forcing) keeps the guard active on the
  common open-act close, so a genuinely illegal reconcile (e.g. `act_committed` with no prior `act_intent`)
  is still caught.
- The tests emit `criterion_started` before each `act_intent` (mirroring the live pipeline). The one case
  that deliberately exercises "an `act_intent` with no persona context" uses the guard's sanctioned `--force`
  bypass — the legitimate way a scripted/resumed caller brackets an act without a fresh `criterion_started`.

## Consequences

- Reconcile is idempotent-friendly: confirming an already-landed act appends a corroborating `act_committed`
  without dying, and the normal open-act close is unchanged.
- The FSM guard remains a **live-path** safety check, not a cage on the recovery tool — consistent with its
  own design comment ("best-effort, never a hard cage; the real authority is qa-verify's phase-surface pass").
- `reconcile` now reads the journal once more per `landed` call (`key_already_committed`). Cheap relative to
  the classify + journal-emit subprocess it already runs.
- All 35 self-contained engine suites (including `rebake` + `qa-reconcile`) are green and gated in
  `scripts/run-engine-ci.sh`; the guard/recovery interaction is covered by the confirming-case tests.
