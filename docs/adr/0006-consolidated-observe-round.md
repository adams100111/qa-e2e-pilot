# ADR-0006 — Consolidated observe-round replaces the per-step 6-call loop

## Status

Proposed (2026-08-30). Part of the accuracy overhaul ([docs/plans/accuracy-overhaul.md](../plans/accuracy-overhaul.md)).

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
`fill_form`/`select`) stay separate calls; **waits** stay separate. The observe call is injected via
the **`evaluate` capability** (`browser_evaluate`) and, on first injection, installs read-only
buffering interceptors on `console.error/warn`, `window.onerror`, `fetch`, and `XMLHttpRequest`, so
each later round drains everything that happened **since the previous round** without extra MCP
calls. Reference implementation: `tools/accuracy-harness/detectors/observe.js`.

This takes a step from **~6 calls to ~2** (observe + act, plus a wait when needed). The diagnostic
tier (console + network) is no longer optional or skippable — it is *in the same payload* the agent
must read to see the DOM, so "green toast, moved on" stops being cheaper than doing it right.

`console_messages` / `network_requests` / `network_request` (response-body reads for probing) remain
available as capabilities for the cases the in-page buffer cannot cover (opaque cross-origin bodies,
pre-injection traffic); the observe-round is the default per-round observation, not the only one.

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
