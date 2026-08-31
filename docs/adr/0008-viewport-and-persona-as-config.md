# ADR-0008 — Viewport and persona are per-run configuration, applied via a real window

## Status

Accepted (2026-08-31), now implemented. Part of the accuracy overhaul ([docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md), Phase 5 of the phased roadmap).

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
  **`resize` capability** (`browser_resize`) after the session opens, and before any criterion runs —
  which required adding `browser_resize` to the agent tool allowlist (ADR-0009); shipped in
  `agents/qa-e2e-pilot.md`'s tool list and phase-0 (Pre-flight) step.
- Config schema, as shipped in `.qa/config.json.example`:
  ```jsonc
  "viewport": { "width": 1440, "height": 900 },
  "responsiveMatrix": [],           // e.g. [{ "id":"mobile", "width":390, "height":844 }]; empty = off
  "persona": { "lens": "skeptical-auditor" },   // the LENS half of persona = role x lens (ADR-0011/0012
                                                 // own the ROLE half — personas[]/.qa/authz-matrix.json)
  "detection": { "ux": { "objective": true, "advisoryAesthetics": true } },  // ADR-0007's two streams
  "passGate": { "enforce": true },              // ADR-0010's evidence gate
  "criteriaBudget": 60                          // soft cost cap, not a coverage cut
  ```
  `persona.readingOrder` from the original proposal was folded into the broader `persona = role x lens`
  design that landed in Phase 2 (ADR-0011/0012) — "real window + natural reading order" is simply how
  the managed driver always behaves (no separate config knob turned out to be needed); `persona.lens`
  is the config surface this ADR actually ships, additive on top of the role axis Phase 2 confirms.
- When `responsiveMatrix` is non-empty, viewport-sensitive UX criteria (overflow/target-size) run once
  per listed viewport; a defect records which viewport it reproduced at. Functional criteria are **not**
  multiplied across viewports (no recall value, real cost) unless explicitly tagged. **Per-run
  selection of which viewport(s)/persona(s)/lens run is its own grilling frontier question** (see
  `bootstrapping-qa-config`'s references/hitl-rounds.md), recommended default "all discovered personas,
  default viewport only" — never a silent read of these config defaults with no confirmation.
- **"Human-like" = a real window + natural reading/interaction order only.** No artificial typing
  delays, no randomized think-time, no fake pacing. Persona is about *where a real user's attention
  lands and at what size*, not about throttling the agent.
- **Reconciled with what shipped in detection (Phase 3/4):** the objective-UX detectors
  (`skills/detecting-visual-ux/scripts/ux-detectors.js`) are **dependency-free in-page heuristics**
  (contrast/overflow/target-size/accessible-name), not an axe-core integration — ADR-0009's original
  axe-core adoption did not end up wired into the shipped detection stack, so `detection.ux.objective`
  above requires **no npm dependency and no vendoring**; it is pure `browser_evaluate`-injected
  JavaScript, consistent with the plugin's "self-contained browser JS" rule.

## Consequences

- UX findings become **reproducible** (a finding names its viewport) and the responsive axis becomes
  testable without inflating every run — it is opt-in.
- Cost is controlled: the matrix defaults empty, and it multiplies only viewport-sensitive UX criteria;
  `criteriaBudget` gives an additional soft cap independent of the viewport axis.
- `browser_resize` is safe on the managed Playwright driver in both headed and headless modes (the
  research confirms runtime viewport changes work in both); attended-CDP presets attach to a real
  window whose size the user controls — the matrix is advisory there and the run records the actual
  window size rather than forcing it.
- Detection stays dependency-free: no `package.json`/axe-core install is required to get objective UX
  verdicts, which keeps the zero-config managed-Playwright install path intact (a plugin, not an app,
  invariant from CLAUDE.md).
- **Reversibility**: viewport/persona are config keys with safe defaults; removing them reverts to a
  single default-desktop run. The hard-to-reverse part is treating viewport as a first-class run input
  that UX verdicts cite — hence this ADR.
