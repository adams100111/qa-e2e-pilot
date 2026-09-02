# Comprehensive human-eye UX detection — design

**Status:** design (awaiting review) · **Date:** 2026-09-02 · **Topic:** a *generic* engine that catches the full range of UI/UX defects a real human tester's eye would catch — and **confirms each against the code/component so it's a genuine bug, not a deliberate choice** — extending `detecting-visual-ux` (ADR-0007) from four DOM detectors to an expectation-reconciliation engine.

Companion effort: QA honesty hardening (`2026-09-02-qa-honesty-hardening-design.md`) — that one stops *faking a pass*; this stops *faking a fail*. Shared harness grounding: `harness-capability-matrix.md`. New record: **ADR-0019**.

---

## 0. Goal

A human QA doesn't carry a 500-item bug checklist; they carry a few **expectation-forming reflexes** applied to whatever's on screen. So the generic solution isn't "more detectors" — it's an **expectation-reconciliation engine**: form an expectation of what *should* happen, observe what *does*, and every gap is a candidate finding. This is the plugin's existing **oracle-vs-observation** discipline (today used for backend correctness) generalized to the UI/UX plane. Localization is one worked family, not the whole.

## 1. The core pattern — `detect → localize → adjudicate → classify`

Every family runs the same four steps; the innovation is **where the expectation comes from when there's no spec** (§2).

1. **Detect** (read-only, in-page via `browser_evaluate`; screenshot via disk-file + Read for layer 3): a detector emits a *suspicion* `{family, selector, evidence, rawSignal}` — never a verdict.
2. **Localize**: map to source — component, style rule, i18n key, data field, API response field — reusing `analyzing-feature-ui`'s surface→endpoint→model map, extended to surface→component/style/catalog.
3. **Adjudicate (deliberate vs bug)** — the anti-false-positive step. See §2 for the oracle-vs-heuristic distinction.
4. **Classify** — see §3 (confidence by oracle strength).

**Degrade when there's no source (black-box target).** `detecting-stack-profile` supports a bare production URL with no repo, so localize/adjudicate may have nothing to read. Then: findings from a **definite DOM oracle** (`NaN`/`undefined`/raw-key/broken-image/contrast) need no source — the DOM/screenshot *is* the evidence → full confidence. Findings needing **code/catalog adjudication** (deliberate-vs-bug, untranslated-i18n, a behavioral shared-state cause) degrade to **suspicion → advisory / `confidence:low`** (observed-only) — never silently dropped. This mirrors `signal:weak`.

## 2. Where expectations come from — oracle vs heuristic (Q2: the circularity fix)

Three expectation sources feed the pipeline, but they are **not equal**. To keep "oracle = ground truth" (CONTEXT.md invariant — *never the implementation itself*) and avoid circularity, we split:

**Definite oracles → may yield a VERDICT:**
- **Content oracle** — `undefined`/`null`/`NaN`/`Invalid Date`/`[object Object]`/`$NaN`/raw `{{interp}}` is never valid content.
- **i18n-catalog oracle (presence only)** — a key *missing/empty* in the target locale is a definite gap. But a key *present* with a Latin value is **not** self-certifying: the catalog is the implementation's own data, so "in the catalog" is a **deliberateness heuristic**, not proof of correctness (a mistakenly-untranslated English value is also "in the catalog"). See §4.
- **Standards oracle** — WCAG (contrast, target-size, a11y).
- **Spec / design-token oracle** — a value diverging from a named spec/design token.

**Expectation heuristics → yield only a SUSPICION (advisory unless corroborated):**
- **App-self-consistency** — the app's own conventions (it stacks sheets everywhere else → the one screen that doesn't is *suspect*). **This is a heuristic, not an oracle** — a uniformly-buggy app is self-consistent, so self-consistency alone cannot ground a verdict. It produces suspicions to adjudicate, never a standalone fail.
- **Cross-state comparison** — same component across en/ar, desktop/mobile, empty/populated, before/after an action.
- **Convention priors** — Nielsen/HIG heuristics.
- **Generative critic (§5)** — the multimodal model's trained eye.

A heuristic-only suspicion becomes a verdict **only** when corroborated by a definite oracle; otherwise it stays **advisory** (ADR-0007 stream). This is the soundness spine — and it is **fully autonomous**: no human is ever asked to confirm a finding. Heuristic-only suspicions stay advisory and are **excluded from the recall metric** (§11).

## 3. Confidence model (evolves ADR-0007) — confidence by oracle strength

ADR-0007 forces all objective UX to `confidence: low`. This supersedes that with **confidence by oracle strength** (confidence stays `high|low`, layer stays `FE`):
- **high** — confirmed against a *definite* oracle (raw i18n key, `NaN`/`undefined`, `ar`-catalog gap, spec/design-token divergence). The expected value comes from the domain/design contract, not backend code.
- **low** — a *standards threshold* with no spec reconciliation (WCAG contrast, target-size).

This is **one unified `confidence:low` definition** (Q7) — "the expectation is not grounded in a spec/domain oracle" — subsuming both this UX standards-threshold case and computed-logic's backend-code-only case; CONTEXT.md's `Confidence` entry is updated to match (no dual meaning). Lets the report separate *"definitely broken"* from *"polish."* Recorded in ADR-0019, which supersedes ADR-0007's confidence clause and **retains** its objective→verdict / subjective→advisory split.

## 4. Detector taxonomy — 9 families

Families 1–5 are the high-value static additions; 6 extends existing probes; 7–8 stay advisory-first; **9 is the behavioral family** (the sheet-stack class).

1. **Content/data-rendering** — `undefined`·`null`·`NaN`·`Invalid Date`·`[object Object]`·`$NaN`·raw `{{}}`·empty required labels·raw ISO timestamps. *(content oracle → high)*
2. **Localization/i18n** — raw keys · language mismatch vs locale · untranslated fallback · RTL correctness. Locale from persona `i18n.expectedLocale` → in-app preference → `<html lang>`; exercises the locale *switch*. Adjudication table:

   | Code/catalog shows | Verdict | Conf |
   |---|---|---|
   | key-pattern text, no catalog value | `fail @ FE` | high |
   | key in `en`, missing/empty in `ar` | `fail @ FE` | high |
   | hard-coded, never through i18n | `fail @ FE` (or advisory if bare proper-noun) | high/— |
   | `ar` value Latin but proper-noun/brand/email/URL/code/number (heuristic) | not a bug (deliberate) | — |
   | `ar` value Latin, `== en`, reads as translatable prose | **suspected-untranslated → suspicion** (advisory, or `fail` where the app's convention is full-translation) | low→ |
   | mixed label, all parts locale-correct in catalog | `pass` | — |

   *"In the `ar` catalog" is not self-certifying (Q1): a Latin value only clears as deliberate if it passes the proper-noun/technical heuristic; a Latin value that equals the `en` string and reads as prose is a suspected untranslated string, not an automatic pass.*

   `detecting-stack-profile` emits an **i18n mechanism map** (Laravel `lang/{ar,en}` + JSON, and/or JS/Inertia catalog); degrades to `signal: weak` (advisory) when no catalog found.
3. **Layout/visual** — overlap/collision · clipping/truncation · off-viewport · z-index (modal behind overlay) · horizontal scroll · responsive breakage.
4. **Contrast/readability/typography** — existing `contrast` + invisible text (fg≈bg) · font-not-loaded/FOUT · absurd sizes.
5. **Assets** — broken images (`naturalWidth==0`/404) · missing icons · leftover placeholders.
6. **Affordance/state** — disabled-looking-but-enabled (& vice-versa) · missing focus ring · stuck spinner · no-feedback-on-click.
7. **Consistency** — inconsistent button styles · mixed date/number formats · mixed casing. *(advisory unless a design-token oracle confirms)*
8. **Aesthetic/brand** — hierarchy · spacing · garishness (existing ADR-0007 advisory read).
9. **Interaction/behavioral** — §7.

## 5. The generative critic (layer 3 — long tail toward the 95%)

For novel edge cases the invariants miss: the **multimodal model** reads screenshot + interaction trace + persona/locale → *"what looks broken, wrong, confusing, or off?"* Every suspicion is forced through §1's adjudication. It can emit **advisory** items *only*; a suspicion becomes a verdict solely when it passes deductive adjudication (definite oracle). Verdicts stay reproducible; the critic raises recall without polluting precision.

**Vision contract (portable — from the harness research):** consume screenshots via **disk-file + Read**, not the raw MCP image content-block (forwarding differs across harnesses — Codex `#10334`, opencode/Pi unconfirmed). Screenshot → `--output-dir` PNG → the harness's disk-image mechanism (Read on Claude/opencode; `localImage` on Codex; adapter-`ImageContent`/Read on Pi). Layer 3 is a **per-harness capability flag**: vision-capable → full engine; vision-absent → engine degrades to layers 1–2 + honest banner. Never split screenshot-take from screenshot-judge across a subagent boundary (opencode discards image parts across `task`).

## 6. Autonomous convention learning + false-positive memory

**Operator-interruption discipline (the governing rule for this whole effort).** Asking the operator is allowed **only in the setup phases** (pre-flight / analyze / generate) — e.g. `confirming-discovered-roles` confirms which roles/credentials to test *before* any criterion runs. Once **Verify** (the QA test loop) starts, the agent detects, adjudicates, and renders verdicts **with no user interruption** — it never stops to ask "is this a bug?". (This is a *different* axis from ADR-0015's "act like a human user" discipline; this rule is about *not interrupting the operator* mid-test.)

So the UX engine has **no in-loop HITL.** The agent learns the app's conventions **itself**, from the same code/oracle it already adjudicates against, and writes them to `.qa/ux-conventions.json` (durable reference data, ADR-0002-clean — not per-run state): learned **conventions** (so deviations are flaggable) and a **known-deliberate list** (so a pattern the agent already judged intentional *by reading the code* isn't re-flagged every run). A genuinely ambiguous case the code can't resolve is **advisory**, never a blocking prompt. Cross-run regression flows through the existing bug-log. Optional human curation of the file is possible but **never required**; headless/CI runs are unaffected. This is what makes it *this app's* tester — autonomously.

## 7. Interaction/behavioral family (family 9) — the sheet-stack class

The originating real bug: a deliverables **list** side-sheet; opening the **new-deliverable form** (also a sheet) **replaces** the list instead of stacking, and closing dumps you out of both. No single snapshot reveals it — you must *drive the sequence and hold an expectation*.

- **Built on `walking-multistep-flows`** + multiplicity 0/1/N baking. Model the **overlay/surface stack** across a real action sequence (open list → click add → snapshot stack → submit → snapshot stack). **Overlay-identification heuristic (Q4):** accessibility-tree `role=dialog`/`aria-modal`, `position:fixed|absolute` high-z panels, and focus-trap boundaries; track each overlay's presence + parentage across snapshots. Honestly **may miss non-semantic overlays** — those fall through to the generative critic (layer 3), not silently passed.
- **Invariant catalog (all five, Q2-genericround):** (1) overlay-stack integrity (child doesn't destroy parent), (2) return-to-context after an action (land back with result visible — ties to N+1 baking), (3) no unexpected full-dismiss / dead-end, (4) focus-trap correctness, (5) no destructive-on-open.
- **Adjudicate:** the tell for the sheet-stack bug is a single shared `open`/route state both sheets bind to; confirmed in code → bug (confidence high once localized), else observed-destruction alone is a `fail` (confidence low → high on code-confirm, Q4-genericround).
- **Criterion boundary (Q3-thisround):** one criterion = one verdict. Driving "add a deliverable" is **two separate criteria that share one driven session** — the *functional* create criterion (persists at N+1?) and the *interaction-UX* criterion (overlay stack survived / return-to-context?), each rolling to its own verdict. The interaction-UX criterion is the `human-action`-gated one (real affordances, fingerprinted). The report shows two findings, not one conflated verdict.
- **Cross-spec integration:** the generative critic's free exploration is **read-only Arrange/observe** — any mutation it wants becomes a proper gated criterion, never ad-hoc clicking.

## 8. Boundary vs baking/computed-logic (Q7)

The UX engine owns **presentation** faults (missing/malformed/unreadable/wrong-format/lost-in-UI — `NaN`, raw key, `mm/dd/yyyy`, sheet-stack). **Baking + verifying-computed-logic keep *value correctness*** (is the number *right* per the oracle). The UX "Integrity" check asserts "not `undefined`/malformed," never "arithmetically correct." No duplication.

## 9. What changes, where
- `skills/detecting-visual-ux/SKILL.md` — restructured around the 4-step pipeline + the 9-family taxonomy + adjudication; < 500 lines via references.
- `skills/detecting-visual-ux/scripts/ux-detectors.js` — new static families (content, i18n-script, assets, invisible-text, overlap/z-index).
- `skills/detecting-visual-ux/references/adjudication.md` (new) — oracle-vs-heuristic rules + per-family oracle table.
- `skills/detecting-interaction-ux/` (new skill, Q1-genericround) — the behavioral family; invokes `walking-multistep-flows`.
- `skills/detecting-visual-ux/` — **autonomously** learns/reads/writes `.qa/ux-conventions.json` (conventions + known-deliberate list) as part of adjudication; no separate HITL skill.
- `skills/detecting-stack-profile/` — emit the i18n mechanism map.
- `skills/analyzing-feature-ui/` — extend source map with component/style/catalog targets.
- `writing-qa-reports` — surface confidence-by-oracle split.
- `tools/accuracy-harness/` — **new UI/UX taxonomy fixture** (a first-class deliverable, Q6): seeded bugs across the 9 families, with the two real innovate-lab bugs as fixture #1; the recall/precision gate (§11) runs against it.
- **ADR-0019** — the engine + confidence-by-oracle-strength.

*Portability:* almost all **core** (skill bodies + scripts, copied verbatim into `dist/<h>/`); only layer-3's "show screenshot to model" needs a per-harness binding (matrix). Collision with merged portability: 🟢 low.

## 10. Cost ceiling
Layers 1–2 run everywhere (cheap, in-page); the generative critic (layer 3) runs on interaction-heavy surfaces + wherever layers 1–2 already flagged, capped by `criteriaBudget` and the run-level ceiling. Log sampled-vs-skipped — no silent coverage caps.

## 11. Acceptance criteria — 95%, honestly (Q3)
The hard gate is **≥95% recall on a UI/UX taxonomy fixture AND 100% on a held-out set of the real innovate-lab bugs the user found** (the two screenshots = fixture #1: the sheet-stack behavioral bug + the `mm/dd/yyyy` i18n bug), at **precision ≥ 90%**. The metric is scored on **definite-oracle + code-adjudicated findings only** — heuristic-only suspicions are advisory and **excluded** from the recall count (the gate must be headless-reproducible; the engine is fully autonomous, no HITL). The generative critic *reaches for* the unknown long tail, but that coverage is **estimated, not guaranteed** (you cannot measure recall on bugs you didn't seed) — stated plainly. Real bugs caught in the wild feed back into the fixture.
1. Raw key `deliverables.title` → `fail @ FE`, high, localized.
2. `ar` label whose catalog value is intentionally Latin → no finding (or advisory "intentional per catalog").
3. Untranslated fallback (`ar` renders `en`) → `fail @ FE`, high.
4. `undefined`/`NaN`/`[object Object]` in a cell → `fail @ FE`, high; legitimately-empty optional field → no finding.
5. Sheet-stack bug → `fail @ FE` via family 9 (observed-destruction; high once shared-state cause localized).
6. Confidence split honored (WCAG contrast = low; code-confirmed = high).
7. Self-consistency circularity: a uniformly-styled but wrong pattern is **not** auto-failed on self-consistency alone (advisory unless a definite oracle corroborates).
8. Precision discipline (ADR-0007 Step 5 retained): clean negative-control surface → zero findings; arithmetic/oracle spot-checked.

## 12. Out of scope (YAGNI)
- Pixel-diff / screenshot-regression baselines (this is semantic detection).
- A full design-system linter (consistency/aesthetic stay advisory).
- Auto-fixing findings.
- Machine-translation quality grading of Arabic copy beyond catalog-presence (native-judgment; advisory).

## 13. Decisions locked
1. Generic **expectation-reconciliation engine**; localization is one family (§1, §4).
2. **Oracle vs heuristic** split kills circularity — only definite oracles yield verdicts; heuristics (incl. self-consistency + generative critic) yield suspicions, advisory-until-corroborated (§2).
3. **Confidence by oracle strength**; ADR-0019 supersedes ADR-0007's blanket-low; objective/advisory split retained (§3).
4. Behavioral family (§7) on `walking-multistep-flows`; action-bearing interaction criteria are `human-action` under the honesty gate.
5. **Fully autonomous — no HITL.** The agent learns conventions from the code into `.qa/ux-conventions.json` (+ known-deliberate list); ambiguous → advisory, never a prompt. Tests *like* a human, not *with* one (§6).
6. **95% is a *measured* gate** on a taxonomy fixture + held-out real bugs at ≥90% precision; long-tail coverage estimated, not claimed (§11).
7. Portable vision = disk-file + per-harness read binding; layer 3 is a capability flag (§5).
