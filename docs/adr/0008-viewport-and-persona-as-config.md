# ADR-0008 — Viewport and persona are per-run configuration, applied via a real window

## Status

Proposed (2026-08-30). Part of the accuracy overhaul ([docs/plans/accuracy-overhaul.md](../plans/accuracy-overhaul.md)).

## Context

The objective-UX detectors (ADR-0007) — overflow/clipping, target-size, and layout-dependent
contrast — are **viewport-dependent**: a value clips at 390px that fits at 1440px; a tap target that
passes on desktop fails on mobile. Today the pipeline pins no viewport and exposes no viewport/persona
keys in `.qa/config.json`, so UX findings are non-reproducible and the responsive dimension is
invisible. "Human-like" testing is also easily mis-specified as fake pacing/delays, which add cost and
flakiness without adding recall.

## Decision

- Add per-run **viewport** configuration. Default **desktop 1440x900**. Settable per run; an opt-in
  **responsive matrix** (e.g. add mobile 390x844) is **off by default**. Applied in Pre-flight via the
  **`resize` capability** (`browser_resize`) after the session opens — which requires adding
  `browser_resize` to the agent tool allowlist (ADR-0009).
- Config schema delta (described in the plan; config edit is PLAN-ONLY this pass):
  ```jsonc
  "viewport": { "width": 1440, "height": 900 },
  "responsiveMatrix": [],           // e.g. [{ "id":"mobile", "width":390, "height":844 }]; empty = off
  "persona": { "readingOrder": "natural" }   // real window + natural reading order ONLY
  ```
- When `responsiveMatrix` is non-empty, viewport-sensitive UX criteria (overflow/target-size) run once
  per listed viewport; a defect records which viewport it reproduced at. Functional criteria are **not**
  multiplied across viewports (no recall value, real cost) unless explicitly tagged.
- **"Human-like" = a real window + natural reading/interaction order only.** No artificial typing
  delays, no randomized think-time, no fake pacing. Persona is about *where a real user's attention
  lands and at what size*, not about throttling the agent.

## Consequences

- UX findings become **reproducible** (a finding names its viewport) and the responsive axis becomes
  testable without inflating every run — it is opt-in.
- Cost is controlled: the matrix defaults empty, and it multiplies only viewport-sensitive UX criteria.
- `browser_resize` is safe on the managed Playwright driver in both headed and headless modes (the
  research confirms runtime viewport changes work in both); attended-CDP presets attach to a real
  window whose size the user controls — the matrix is advisory there and the run records the actual
  window size rather than forcing it.
- **Reversibility**: viewport/persona are config keys with safe defaults; removing them reverts to a
  single default-desktop run. The hard-to-reverse part is treating viewport as a first-class run input
  that UX verdicts cite — hence this ADR.
