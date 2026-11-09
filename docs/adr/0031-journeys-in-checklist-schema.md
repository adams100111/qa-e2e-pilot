# ADR-0031 — Journeys live in the engine's checklist schema

## Status

Accepted (2026-11-09). Ship QA increment 1; released with increment 2 (engine and qa-kit together).
Design: [`docs/superpowers/specs/2026-11-09-ship-grade-qa-design.md`](../superpowers/specs/2026-11-09-ship-grade-qa-design.md)
§1c and "Settled after builder review" #7. Companion to
[ADR-0030](./0030-surface-census-and-ship-profile.md). Builds on
[ADR-0029](./0029-criterion-level-supersession-and-record-time-identity.md) (one authoritative
verdict per criterion). Adds no verdict: a journey's state is computed from its steps' verdicts.

## Context

A module ships when its mainstream end-to-end flows work for every role: an admin creates a
hackathon, opens registration, a participant registers, a team forms, an idea is submitted, judges
score it, winners are announced. Until now a checklist was a flat list of criteria. Nothing said
which criteria form a chain, which chains are the mainstream (P1) bar, or that step N's created ids
feed step N+1, so a run could pass 180 criteria and still never prove the main flow end to end.

Two consumers need the chain: the report (a journey shown as a strip of step verdicts, passing only
when every step passes) and the increment 3 compiler (a journey compiles into one serial
`test.describe` sharing created ids). qa-kit authors journeys, but qa-kit may not change the engine
([ADR-0022](./0022-qa-kit-process-shell.md)); a qa-kit-only field would be invisible to the engine's
validator, checkpoint and report. So the schema change belongs in the engine.

## Decision

**A. Journey metadata is its own file, rows point back.** `journeys.json` is an array of
`{id, title, priority: P1|P2|P3, roles[], steps: [criterionId, ...]}`. qa-kit writes it beside the
spec (`.qa/specs/<target>/journeys.json`); the agent copies it into `.qa/runs/<run-id>/journeys.json`.
A step row carries `journey: {id, step}` (1-based). The frozen-plan model is unchanged: a journey
step is an ordinary criterion with its own id, persona and verdict.

**B. Checklist rows gain four optional fields** (D1), validated by `validate-checklist-json.sh` in
both engines with `null` treated as absent, so every existing checklist validates byte for byte as
before: `surfaceId` (string or non-empty string array, the census surfaces a row covers),
`priority` (`P1|P2|P3`), `journey` (`{id, step >= 1}`) and `variant` (`{viewport, locale,
colorScheme: light|dark}`, unknown keys allowed). Errors name the field and the row id. The kind
enum gains `load-clean`, `deny`, `input-validation` (see ADR-0030 E).

**C. `scripts/journeys.sh`** (dual-engine, byte parity):
- `validate <journeys.json> <checklist.json>`: priority is `P1|P2|P3`; every step id exists; each step
  row's `journey.id`/`journey.step` match; no step id repeats.
- `status <run-dir>`: per journey, each step's authoritative verdict after ADR-0029 supersession
  (several persona verdicts on one step: any `fail|error` → fail, all `pass` → pass, else
  incomplete). A journey with any failed step is `fail`, even if other steps are incomplete; it is
  `pass` only when every step passed; otherwise `incomplete`.
- `expand-variant ... --journey <id> --viewport <WxH> --locale <code> [--color-scheme]` prints **only
  the new rows**: the journey's steps duplicated with ids and `journey.id` suffixed
  `@<viewport>-<locale>[-<scheme>]` and `variant` set. The caller appends them to the run's checklist
  and adds the matching journey entry.

**D. How a ship run uses them.** P1 journeys run first, sequentially, at the primary variant, never
fanned out (journey rows never carry `independent`). Exactly one P1 journey — the first P1 entry —
is expanded to the second viewport and the first RTL locale; every other surface a journey touched
is revisited read-only per variant through generated `ux-revisit` rows instead of re-running writes.
Without a spec, the agent drafts journeys from the census and project docs and a human approves
them and marks P1 in `/qa-spec`; the plugin never decides what is mainstream.

## Consequences

- Journeys are additive: a checklist without journeys, and a run without `journeys.json`, behave as
  before.
- A journey verdict is derived, never recorded, so it cannot drift from its steps and needs no new
  verdict value. Increment 2's renderer shows the strip; until then the agent relays
  `journeys.sh status` in its summary.
- Created-id hand-off between steps rides on the existing run state (evidence and the data-policy
  created-records list); a resumed run continues the chain from the frozen cursor.
- `validate-checklist-json.sh` now honours `QA_ENGINE=jq|python3`, which its schema doc had claimed
  all along.
