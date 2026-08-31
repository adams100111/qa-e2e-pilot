# ADR-0007 — Objective UX becomes a verdict at layer FE; subjective aesthetics become an advisory stream, not a sixth verdict

## Status

Proposed (2026-08-30). Part of the accuracy overhaul ([docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md)).

## Context

Detection today is purely functional: `driving-browser-qa` states "the surface is evidence, not the
oracle" and screenshots are a pixel fallback only. There is no layout/contrast/target-size/a11y
assertion anywhere, and no UX criterion is ever generated. Measured against the seeded-bug fixture,
UX recall is ~15–25%. Two different things get conflated under "UX":

1. **Objective** UX defects with a citable, machine-checkable oracle: color contrast (WCAG SC 1.4.3,
   4.5:1), overflow/clipping (`scrollWidth > clientWidth`), touch-target size (WCAG 2.2 SC 2.5.8,
   24x24), missing accessible name / thrown console errors (axe-core `button-name`, etc.).
2. **Subjective** aesthetics: visual polish, spacing rhythm, brand consistency — no objective oracle.

The invariant (CONTEXT.md / CLAUDE.md) is that verdicts are **exactly** `pass|fail|blocked|deferred|
error` and confidence is `high|low`; a defect must localize to exactly one of `FE|route|service|
migration|DB`. Adding a `warn`/`aesthetic` verdict is forbidden.

## Decision

- **Objective UX defects are first-class verdicts.** They are detected by dependency-free in-page
  detectors (`skills/detecting-visual-ux/scripts/ux-detectors.js`, the sole canonical copy — the
  formerly-duplicated `tools/accuracy-harness/detectors/ux-detectors.js` was deleted as a stale fork)
  plus **axe-core** (injected as
  `axe.min.js`, run via `window.axe.run()`), carried in the observe-round payload (ADR-0006). A
  confirmed objective defect yields `verdict: fail`, **suspected layer `FE`**, **confidence `low`**
  (low because there is no spec/domain *numeric* oracle — the threshold is a standard, and the run
  had no design spec to reconcile against). This reuses the existing verdict + layer + confidence
  vocabulary unchanged.
- **Subjective aesthetics go to a separate ADVISORY STREAM**, never a verdict. The report gains an
  `## Advisory (aesthetics)` section listing observations with no `pass/fail`. Advisory items are
  **not** counted in the pass/fail tally, never localize to a layer, and never block. No sixth
  verdict is introduced.

## Consequences

- UX recall rises without touching the verdict enum: objective UX is `fail @ FE confidence:low`;
  subjective is advisory. The accuracy-harness scorer models exactly this — subjective seed `S1` is
  scored in a separate advisory stream and excluded from the verdict-recall gate.
- **confidence:low is doing real work**: it signals "this is a standards violation, not a
  spec-reconciled correctness failure," so a consumer can triage FE polish separately from a wrong
  formula — while still being an honest `fail`, not a silently-dropped observation.
- axe-core (MPL-2.0) is bundled and injected via `browser_evaluate` only (never
  `browser_run_code_unsafe` — see ADR-0009).
- **Reversibility**: the advisory stream is additive report content; removing it loses UX polish
  reporting but changes no verdict semantics. Making objective-UX a `fail` is the load-bearing,
  harder-to-reverse call — hence this ADR.
