# ADR-0019 — Human-eye UX detection: a generic expectation-reconciliation engine, with confidence by oracle strength

## Status

Proposed (2026-09-02). Implements `docs/specs/2026-09-02-human-eye-ux-detection-design.md`. **Supersedes ADR-0007's confidence clause** (retains its objective→verdict / subjective→advisory split).

## Context

`detecting-visual-ux` (ADR-0007) catches four DOM defect classes (contrast, overflow, target-size, accessible-name) against a **standards** oracle (WCAG), with everything else pushed to a subjective advisory read. It has no "confirm against the code that it's a real bug, not deliberate" step, and it can only catch the classes it enumerates. Two real defects on one screen of the innovate-lab app illustrate the gap: a **sheet-stack behavioral bug** (opening a child side-sheet destroys the parent list; no snapshot reveals it — you must drive the sequence and hold an expectation) and a **`mm/dd/yyyy` date field in an Arabic RTL form** (a localization defect). The installed agent caught neither: it was in functional/machine mode, not human-look-and-feel mode.

A finite list of detectors only ever catches enumerated bugs. A human QA carries a few **expectation-forming reflexes** applied to anything on screen. And a detection that fires without confirming intent produces false fails — itself a honesty failure.

The invariants: verdicts are exactly `pass|fail|blocked|deferred|error`; confidence is `high|low`; layer is one of `FE|route|service|migration|DB`; **the oracle is the spec/domain rule, never the implementation itself** (CONTEXT.md). ADR-0007 forced all objective UX to `confidence: low`.

## Decision

Generalize UI/UX detection into an **expectation-reconciliation engine**: `detect → localize → adjudicate → classify`. Form an expectation of what should happen, observe what does, adjudicate every gap against the code/component, and classify.

1. **Oracle vs heuristic (the circularity fix).** Expectations come from two grades of source. **Definite oracles** (content-never-valid; the i18n catalog; WCAG; spec/design tokens) may yield a **verdict**. **Expectation heuristics** — app-self-consistency, cross-state comparison, convention priors, and the multimodal **generative critic** — yield only a **suspicion**, which becomes a verdict *only* when corroborated by a definite oracle or confirmed in HITL; otherwise it is **advisory**. This keeps "oracle = ground truth" intact: a uniformly-buggy app is self-consistent, so self-consistency alone can never ground a fail.

2. **Confidence by oracle strength.** A finding confirmed against a *definite* oracle (raw i18n key, `NaN`/`undefined`, `ar`-catalog *gap*, spec/token divergence) is `confidence: high`; a *standards-threshold* finding (WCAG contrast, target-size) stays `confidence: low`. Confidence stays `high|low`, layer stays `FE`. This supersedes ADR-0007's blanket-low so the report separates "definitely broken" from "polish." The `confidence:low` definition is **unified** with computed-logic's: "the expectation is not grounded in a spec/domain oracle" covers both the backend-code-only case and the bare-standard case (CONTEXT.md updated). Note the i18n catalog is a definite oracle for *key presence* only; a present-but-Latin value is adjudicated by a deliberateness heuristic, not certified by catalog membership.

3. **Nine detector families**, all running the four-step pipeline: content-rendering, localization/i18n, layout, contrast/typography, assets, affordance/state, consistency (advisory-first), aesthetic (advisory), and **interaction/behavioral** (the sheet-stack class, built on `walking-multistep-flows` with a five-invariant catalog: overlay-stack integrity, return-to-context, no-dead-end, focus-trap, no-destructive-on-open).

4. **Deliberate-vs-bug adjudication is first-class and fully autonomous.** A finding is a `fail` only when code/catalog/oracle confirms it is not intended (e.g., an `ar` catalog value that is a proper-noun/brand is not a bug). The agent learns conventions **from the code itself** into `.qa/ux-conventions.json` (+ a known-deliberate list) so intentional patterns aren't re-flagged across runs — **no human-in-the-loop**; a case the code can't resolve is advisory, never a prompt. The goal is an agent that tests *like* a human, not *with* one.

5. **Cross-spec discipline (ADR-0018/0015).** An interaction-UX criterion that performs an action is a `human-action` criterion under the honesty gate (real affordances, gated, fingerprinted). The generative critic's free exploration is read-only Arrange/observe; any mutation becomes a proper gated criterion.

6. **Portable vision.** Layer-3's screenshot critic consumes images via **disk-file + the harness's read mechanism** (not the raw MCP content-block); it is a per-harness capability flag — vision-absent harnesses degrade to layers 1–2 + an honest banner.

7. **"95%" is a measured gate, honestly scoped.** Definition of done: **≥95% recall on a UI/UX taxonomy fixture AND 100% on a held-out set of the real found bugs, at precision ≥90%.** Scope = *objective/observable* defects; subjective aesthetics stay advisory. Long-tail coverage (via the generative critic) is *estimated, not guaranteed* — you cannot measure recall on unseeded bugs.

## Consequences

- UX recall rises generically (novel bugs fall out of invariants + the critic) without a sixth verdict; precision is protected because heuristic-only suspicions can never become a verdict.
- The report distinguishes definitely-broken (high) from polish (low), and never false-fails on deliberate design (adjudication + suppression memory).
- New skills: `detecting-interaction-ux`, `confirming-ux-conventions`; `detecting-visual-ux` restructured; `detecting-stack-profile` emits an i18n mechanism map. Nearly all core (portable).
- **Boundary:** the UX engine owns presentation faults; value correctness stays with baking + `verifying-computed-logic`.
- **Reversibility:** the engine is additive detection + an evolved confidence rule. The hard-to-reverse call is allowing `confidence: high` on UX verdicts (superseding ADR-0007) — hence this ADR. The oracle-vs-heuristic split is the load-bearing soundness decision.
