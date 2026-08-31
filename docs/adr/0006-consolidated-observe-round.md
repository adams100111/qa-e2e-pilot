# ADR-0006 — Consolidated observe-round replaces the per-step 6-call loop

## Status

Accepted (2026-08-31), now implemented. Part of the accuracy overhaul ([docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md)).

## Context

`driving-browser-qa` mandates a six-call sequence for **every** step inside a criterion
(`browser_snapshot` -> act -> `browser_wait_for` -> `browser_console_messages` ->
`browser_network_requests` -> `browser_snapshot`), repeated per step in `walking-multistep-flows`.
On a multi-step flow this is ~6 tool calls x N steps, dominating token/time cost. Worse, the cost
pressure is a **recall** problem, not only an efficiency one: under a long run the agent skips the
diagnostic reads (console/network) to save budget and declares a pass on the snapshot alone — one of
the execution-discipline false-greens the overhaul targets. The reads are cheap in principle
(they are page-observable state) but expensive as separate MCP round-trips.

## Decision

Introduce **one structured observe call per round** — the *observe-round* — that returns a single
JSON payload: `{ round, domDigest, console[], network[], ux[], axe }`. Acts (`click`/`type`/
`fill_form`/`select`/an `evaluate`-injected script like `react-set-input.js`) stay separate calls;
**waits** stay separate. The observe call is injected via the **`evaluate` capability**
(`browser_evaluate`) and, on first injection, installs read-only buffering interceptors on
`console.error`/`warn`, `window.onerror`, `unhandledrejection`, `fetch`, and `XMLHttpRequest`, so
each later round drains everything that happened **since the previous round** without extra MCP
calls. Implementation: `skills/driving-browser-qa/scripts/observe.js` — the sole canonical copy the
agent actually injects. (A duplicated `tools/accuracy-harness/detectors/observe.js` fork existed for
offline scoring but had diverged from this canonical copy and was deleted; the accuracy harness now
references `skills/driving-browser-qa/scripts/observe.js` directly instead of maintaining a second
copy.)

This takes a step from **~6 calls to ~2** per step (observe + act, plus a wait when the act mutates
state). Both `driving-browser-qa` (the per-step loop) and `walking-multistep-flows` (the per-wizard-
step loop) were rewritten to the observe-round — the wizard loop was the second, nested instance of
the old six-call sequence and is now the same one-observe-per-round pattern, not a separate loop. The
diagnostic tier (console + network) is no longer optional or skippable — it is *in the same payload*
the agent must read to see the DOM, so "green toast, moved on" stops being cheaper than doing it
right.

`console_messages` / `network_requests` / `network_request` (response-body reads for probing) remain
available as capabilities for the cases the in-page buffer cannot cover (opaque cross-origin bodies,
pre-injection traffic, a response **body** — `network[]` only carries method/url/status/ok); the
observe-round is the default per-round observation, not the only one. Both rewritten skills state this
explicitly as a binding **no-evidence-regression guard**: the observe-round consolidates the
*redundant* per-step console/network/snapshot calls the old loop always paid for, it does not drop a
diagnostic (bake read-back, response body, cross-origin read) a step genuinely needs — that is still a
separate, targeted call or a hand-off to `verifying-backend-persistence`/`probing-apis-through-browser`.
A driver without the `evaluate` capability cannot run the observe-round at all; the affected step is
recorded `blocked`, never silently downgraded to fewer diagnostics.

## Consequences

- **Efficiency**: ~6->~2 calls/step; fewer large accessibility snapshots (the `domDigest` is a
  compact live-text + interactive-inventory, not a full a11y dump every round).
- **Recall guard (binding)**: the efficiency change may **not** lower fixture recall — the observe
  payload carries console + network + UX assertions precisely so consolidation cannot drop the
  diagnostics that catch bug classes #1 (`p.map` crash) and #2/#4–6/#10 (4xx/5xx). The accuracy
  harness gate (`score.js --gate`) is the regression check.
- **Read-only invariant intact**: `observe.js` never issues requests; it only patches to observe.
- **Reversible**: it is an observation *shape*, not a structural change to verdicts or run state;
  the legacy loop remains valid for a driver whose `evaluate` capability is absent (that driver
  records the affected step `blocked`, per `driver-capabilities.md`).
