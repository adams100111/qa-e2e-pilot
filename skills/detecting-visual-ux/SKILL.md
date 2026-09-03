---
name: detecting-visual-ux
description: Use when a checklist criterion is tagged visual-UX (one is emitted per surface by analyzing-feature-ui) or when driving-browser-qa reaches a UX criterion — runs dependency-free objective detectors (contrast, overflow/clipping, touch-target size, missing accessible name / console error on click) that yield a real fail@FE/confidence:low verdict, and a vision-gated multimodal generative critic (screenshot + interaction trace + persona/locale) that reads the long tail — layout, flow, locale fit, aesthetics — as advisory suspicions only, never a verdict directly. Also adjudicates the detectors' and critic's content/i18n/asset/critic ux-suspicion findings (detect→localize→adjudicate→classify) into fail@FE (confidence by oracle strength), advisory, or dropped. Implements ADR-0007/ADR-0019's split so UX recall rises without adding a sixth verdict.
---

# Detecting Visual UX

## Overview

"UX" conflates two different things. **Objective** defects — contrast, clipping, undersized touch
targets, missing accessible names, elements that throw on click — have a citable, machine-checkable
oracle (WCAG 2.2 / axe conventions). **Subjective/long-tail** defects — garish colors, erratic
spacing, poor visual hierarchy, confusing flow, wrong-for-locale layout — have no single machine-
checkable oracle; they're what a trained eye (or a multimodal read of one) catches, however
well-founded.

Per ADR-0007 ([docs/adr/0007-ux-detection-objective-verdict-subjective-advisory.md](../../docs/adr/0007-ux-detection-objective-verdict-subjective-advisory.md))
and ADR-0019 ([docs/adr/0019-human-eye-ux-detection-engine.md](../../docs/adr/0019-human-eye-ux-detection-engine.md)),
this skill keeps that split load-bearing:

- **Objective -> a real verdict.** A confirmed objective defect is `verdict: fail`, `suspectedLayer:
  FE`, `confidence: low` — low because the threshold is a standard, not a spec-reconciled numeric
  oracle, but it is still an honest fail, not a downgraded observation.
- **Subjective/long-tail -> the advisory stream, never a verdict directly.** No `warn`/`aesthetic`/
  sixth verdict is ever introduced (CLAUDE.md invariant). This covers both the DOM-detector
  `ux-suspicion` families (Step 1) and the generative critic's `critic-*` suspicions (Step 4) — both
  are adjudicated by Step 5, which routes each into the report's `## Advisory (ux-suspicions)`
  section (anchored to a selector/region so they're checkable) *unless* a definite oracle
  corroborates one, in which case it promotes to a real `fail`. Either way, nothing in this stream
  is ever counted in a pass/fail tally on its own say-so.

## When to Use

- `analyzing-feature-ui` emits one visual-UX criterion per surface in the checklist. When
  `driving-browser-qa`'s per-step loop reaches that criterion, invoke this skill.
- Any time a criterion's step type is `visual-ux` or the checklist row cites contrast/overflow/
  target-size/accessible-name/aesthetics.

## The Process

### Step 1 — Run the objective detectors (read-only, no side effects)

Inject `scripts/ux-detectors.js` via `browser_evaluate` against the current surface (after the
normal snapshot-and-wait — see driving-browser-qa's per-step loop). It returns a JSON array of
findings, each already shaped as:

```json
{ "detector": "contrast", "selector": "[data-testid=...]", "text": "...",
  "suspectedLayer": "FE", "confidence": "low",
  "message": "Contrast 1.92:1 below WCAG AA 4.5:1 (SC 1.4.3)" }
```

Four detectors, each citing its WCAG success criterion:

| Detector | Threshold | Cite | Seed class |
|---|---|---|---|
| `contrast` | < 4.5:1 normal text / 3:1 large text (>=24px, or >=18.66px+bold) | SC 1.4.3 | U1 |
| `overflow` | `scrollWidth > clientWidth` (or Y) while not `overflow:auto/scroll` | (clipping, no SC number — is a functional-display defect but classed ux-objective per ADR-0007) | U2 |
| `target-size` | interactive element's rendered box < 24x24 CSS px | SC 2.5.8 (AA) | U3 |
| `accessible-name` | no text / `aria-label` / `aria-labelledby` / `title` / `alt` on a button/link/`role=button` | SC 4.1.2 (axe `button-name` analog) | U4 (static half) |

A fifth entry, `accessible-name-probe`, is not a finding — it is a **hint** (`probeClick: true`)
marking symbol-only labels (e.g. a bare `"?"` button) that need Step 2's dynamic check. It carries
no verdict on its own.

**Suspicion entries are not verdicts by construction (`axis:"ux-suspicion"`).** Alongside the four
objective detectors, `ux-detectors.js` may return entries whose `axis` is `"ux-suspicion"` (the
content/i18n/assets/invisible-text/overlap families). These carry **no** `verdict`,
`suspectedLayer`, or `confidence` straight out of the detector — do **not** apply Step 3 to them
directly. They become a verdict, an advisory entry, or nothing at all only via **Step 5's
adjudication pipeline** below (detect → localize → adjudicate → classify); never hand-wave one
straight into a `fail`.

### Step 2 — Click-probe for U4's dynamic half (console error on click)

U4 is genuinely two independent signals that both localize to the same class: a missing accessible
name (static, Step 1) **and/or** a thrown console error on click (dynamic — a static evaluate
snapshot cannot see a runtime exception). **This step is REQUIRED, not optional — a blind
re-measurement missed U4 precisely because the static detectors (contrast, size) ran but the icon
button was never CLICKED. A visual-UX sweep is incomplete until every icon-only / symbol-label
control has been click-probed.** For every element Step 1 flagged with `probeClick: true`, AND
every icon-only / single-symbol-label / ambiguous control on the surface (a `?`, a gear, an `x`, a
bare-glyph button/link), do ALL of:

1. Read `browser_console_messages` first to get a baseline (so a pre-existing error isn't misattributed).
2. Click the element (`browser_click`, or `scripts/click-by-text.js` per driving-browser-qa if text-based).
3. Read `browser_console_messages` again. A new `type: "error"` entry (or `Uncaught`/`TypeError`/
   `ReferenceError`) that appeared only after the click is a U4-class finding: `fail`, `suspectedLayer:
   FE`, `confidence: low`, message = the console error verbatim + "thrown on click (WCAG SC 4.1.2 /
   axe button-name analog — control is not a functional, addressable interactive element)".

This reuses driving-browser-qa's existing "Checking for Client-Side Exceptions" step — no new
browser capability is introduced, only the direction to run it specifically for UX-flagged controls.

### Step 3 — Objective finding -> criterion verdict

*(applies only to `axis:"ux-objective"` findings from the four detectors above; `axis:"ux-suspicion"`
entries are handled by the Step 1 rule and never reach a verdict).*

Each confirmed Step 1 or Step 2 finding becomes (or fails) the surface's visual-UX criterion:

- `verdict: fail`
- `suspectedLayer: FE` (always — these are rendering/markup defects, never route/service/migration/DB)
- `confidence: low` (per ADR-0007 — no spec/domain numeric oracle backs a WCAG threshold)
- Evidence: the finding's `selector`, `message` (with its WCAG cite), and a screenshot
  (`browser_take_screenshot`) of the flagged region.

If Step 1 and Step 2 produce zero findings, the criterion is `pass` — do not infer a fail from the
subjective read in Step 4; that stream never sets a verdict.

### Step 4 — The generative critic (layer 3, multimodal, advisory-only)

Generalizes what was originally an aesthetics-only screenshot read (ADR-0007) into the full
**generative critic** (ADR-0019 §5) — a multimodal read of the whole surface that reaches for the
long tail Steps 1–3's invariants don't enumerate. It keeps the same advisory-only guarantee the
original read had: **it never emits a verdict.** Every observation becomes a `critic-<slug>`
suspicion that is adjudicated by **Step 5**, exactly like a Step 1 `ux-suspicion`.

#### 4.1 — Cost ceiling: when the critic runs

Steps 1–3 run on every visual-UX criterion; layer 3 is gated (ADR-0019 §10) — running it on every
surface isn't the goal, honest sampling is. Run the critic on a surface **iff**:

- the surface just carried an **interaction-heavy** sequence — a driven multi-step/overlay flow ran
  (`walking-multistep-flows` / `driving-browser-qa`'s per-step loop drove more than a single static
  load), OR
- Steps 1–3 (or a prior Step 5 adjudication) already produced **≥1 finding or suspicion** on this
  surface,

bounded by the run's `criteriaBudget`. Log every disposition via `critic-coverage.sh` (built in
Task 3 of this effort — the sampled-vs-skipped logging mechanism referenced here):

```bash
bash skills/detecting-visual-ux/scripts/critic-coverage.sh log <run-id> <surface> ran
bash skills/detecting-visual-ux/scripts/critic-coverage.sh log <run-id> <surface> skipped <reason>
```

A capped run is **not** "the critic ran everywhere" — `critic-coverage.json` is the honest record
of what was actually sampled vs. skipped. State that plainly in the report; never imply full
coverage.

#### 4.2 — The vision contract (portable, disk-file only) + never-split rule

Resolve the harness's read binding before taking the screenshot:

```bash
bash skills/detecting-visual-ux/scripts/vision-binding.sh resolve
```

- `Read` (Claude, opencode) / `localImage` (Codex) / `adapter` (Pi) — consume the screenshot via
  **that** disk-file mechanism, **never** the raw MCP image content-block (forwarding differs across
  harnesses; ADR-0019 §5).
- `absent` → **skip the critic entirely.** Run layers 1–2 only (Steps 1–3), and emit the honest
  degrade banner into the report:
  ```bash
  bash skills/detecting-visual-ux/scripts/vision-binding.sh banner
  ```
  This is an honest degrade, never a silent omission — the report must say layer 3 didn't run, and
  why.

**Never-split rule.** The screenshot **take** (`browser_take_screenshot` to a `--output-dir` PNG)
and the screenshot **judge** (the multimodal read) MUST happen in the same agent context/turn —
never split across a subagent `task` boundary. opencode drops image parts across `task`, so a
subagent handed only the PNG path cannot see the image; only the agent that just took the
screenshot can read it back.

#### 4.3 — Inputs

When vision resolves (not `absent`, 4.2) and the cost-ceiling gate (4.1) says run:

1. Take one full-surface `browser_take_screenshot` to a `--output-dir` PNG (reuse Step 3's evidence
   screenshot when the surface already has an objective finding — don't double-shoot).
2. Read it via the resolved binding (4.2).
3. Gather the **interaction trace** — the driven step sequence that produced this surface (from
   `walking-multistep-flows`/`driving-browser-qa`'s snapshot-act-wait log: what was clicked/typed/
   submitted, in order).
4. Gather the **persona/locale** the criterion is running as (checklist row / `discovering-user-
   roles` / the i18n `expectedLocale`).

#### 4.4 — The prompt (full rubric in references/)

Ask, of the screenshot + trace + persona/locale together: **"what looks broken, wrong, confusing,
or off for this persona/locale?"** — the long tail Steps 1–3 don't enumerate: missing/overlapping/
mis-aligned/illegible/unexpected content, a confusing flow (given the trace), anything
wrong-for-locale, plus the original hierarchy/spacing/garishness aesthetic read (now one category
among several). The full prompt text and per-category rubric lives in
[references/generative-critic.md](references/generative-critic.md) — read it before running the
critic; this section carries only the procedure.

#### 4.5 — Output: `critic-<slug>` suspicions, routed through Step 5, never a verdict

Every observation becomes a suspicion, same shape as a Step 1 `ux-suspicion`:

```json
{ "detector": "critic-layout-off", "axis": "ux-suspicion",
  "selector": "[data-testid=finalize-panel]",
  "evidence": "screenshot region + interaction trace step 3",
  "rawSignal": "primary CTA visually subordinate to a secondary ghost button" }
```

`detector` is `critic-<slug>` — a short kebab-case label for the *kind* of thing observed
(`critic-layout-off`, `critic-flow-confusing`, `critic-illegible`, `critic-locale-mismatch`, ...).
Feed every one into **Step 5** exactly like a Step 1 suspicion (Step 5.1's Detect bullet covers both
sources). `adjudicate.js`'s `ORACLE_GRADES` table already grades any `critic-`-prefixed detector
`heuristic`, so Step 5.3/5.4 routes it:

- No corroborating definite oracle → `{advisory:true, ...}` → the `## Advisory (ux-suspicions)`
  stream. No verdict, no `suspectedLayer`, no `confidence`, never counted in the pass/fail tally —
  the same guarantee ADR-0007 established for the original aesthetics-only read.
- A definite oracle on the same element (a `content-*`/`i18n-*`/`broken-image`/`invisible-text`
  finding, or a `behavioral-observed` interaction-family finding) corroborates it →
  `adjudicate()`'s heuristic-corroborated path promotes it to `fail @ FE, confidence: high`.

**The critic never emits a verdict directly, under any circumstance** — even an observation that
looks unambiguously broken to the model's eye is a suspicion, not a fail, until Step 5 adjudicates
it. This is what keeps a wider net from eroding precision.

#### 4.6 — Read-only discipline

The critic's look is **read-only Arrange/observe** (ADR-0019 §5/§7's cross-spec integration) — it
may inspect whatever is already on screen (including hovering/scrolling to see more of a scrollable
region), but it never clicks/types/submits "to test a theory." Any mutation the critic wants to try
becomes a proper checklist criterion, tagged `human-action` and run through the normal gated
act-phase (ADR-0015) — never ad-hoc clicking from inside this step.

#### 4.7 — Estimated, not measured

The critic's long-tail coverage is **estimated, never measured** (ADR-0019 §11) — recall can't be
computed against bugs that were never seeded. Its advisory items are excluded from the C1
accuracy-harness's measured recall gate (`tools/accuracy-harness/`), which scores only layers 1–2's
definite-oracle + code-adjudicated findings. Report the critic's contribution as "additional
advisory observations," never as a recall percentage.

### Step 5 — Adjudicate ux-suspicions (detect → localize → adjudicate → classify)

`axis:"ux-suspicion"` entries — from Step 1 (content/i18n/asset/invisible-text/overlap families) OR
from Step 4's generative critic (`critic-*`) — are not verdicts on their own; they are unresolved
leads. This step runs the full pipeline (design §1) that resolves each one to a real finding, an
advisory, or nothing. The oracle-grade table and the classifier live in `scripts/adjudicate.js`; the
doctrine behind the table is `references/adjudication.md` (ADR-0019) — read that reference for the
full grade/table rationale, this section only carries the procedure.

1. **Detect** — already done: the `ux-suspicion` entries came either out of Step 1's
   `ux-detectors.js` injection, unchanged, or out of Step 4's generative critic. Each is
   `{detector, axis:'ux-suspicion', selector, evidence, rawSignal}` regardless of source — Step 5
   treats a `critic-*` suspicion identically to a `content-*`/`i18n-*`/`overlap` one from here on.

2. **Localize** — for each suspicion, map its `selector` to a source: component, style rule,
   i18n key, or data field. Use `analyzing-feature-ui`'s surface→endpoint map, extended the same
   way to surface→component/style/catalog (same file, same cross-reference discipline — grep the
   frontend repo for the selector/class/testid to find the owning component or stylesheet rule).
   For an `i18n-*` suspicion specifically, resolve the key against the catalog located by
   `detecting-stack-profile`'s `components[].i18n` mechanism map (`catalogs[].path`) into the
   record `{presentInTarget, targetValue, enValue, isTechnical}` — `presentInTarget` is whether the
   key exists in the target-locale catalog file, `targetValue`/`enValue` are the raw catalog
   strings, `isTechnical` is true when the value is a legitimate proper-noun/brand/URL/code token.
   Also compute `catalogCompleteness`: the fraction of target-locale keys in that catalog file that
   are non-empty/translated (0..1) — read the whole catalog file once per run, not per-suspicion.

3. **Adjudicate** — read the known-deliberate list **once per run** (not per suspicion):

   ```bash
   bash skills/detecting-visual-ux/scripts/ux-conventions.sh read
   ```

   This prints the `knownDeliberate` JSON array (`[]` if none yet). Then, for each suspicion, call
   the classifier via `node -e` requiring `scripts/adjudicate.js`:

   ```bash
   node -e '
     const { adjudicate, deriveCatalogResult } = require("./skills/detecting-visual-ux/scripts/adjudicate.js");
     const suspicion = { detector: "i18n-raw-key", selector: "[data-testid=deliverables-title]", rawSignal: "deliverables.title" };
     const record = { presentInTarget: false };            // from Step 5.2 localize (catalog lookup)
     const knownDeliberate = JSON.parse(process.argv[1]);   // from ux-conventions.sh read, above
     const result = adjudicate(suspicion, {
       catalogResult: deriveCatalogResult(record),
       catalogCompleteness: 0.93,
       knownDeliberate,
       corroborated: false
     });
     console.log(JSON.stringify(result));
   ' '[]'
   ```

   `catalogResult` is only meaningful for `i18n-*` suspicions — pass `deriveCatalogResult(record)`
   from Step 5.2's localized record; for non-i18n suspicions omit `catalogResult`/
   `catalogCompleteness`. `corroborated: true` only when a second, independent definite-oracle
   signal (e.g. a `definite-dom` finding on the same element) backs a `heuristic`-grade suspicion
   like `overlap` or `critic-*`.

4. **Classify/route** — `adjudicate()` returns exactly one of three shapes; route accordingly:
   - **A verdict object** `{verdict:'fail', suspectedLayer:'FE', confidence, family, reason}` → a
     real `fail @ FE` visual-UX criterion finding. Carry `confidence` (`high`/`low`) **verbatim** —
     never re-derive or downgrade it — and use `reason` as the finding's message. Attach a
     `browser_take_screenshot` of the flagged region as evidence, same as Step 3.
   - **An advisory object** `{advisory:true, reason}` → append to the `## Advisory
     (ux-suspicions)` stream — the single destination for every unresolved-but-not-dropped
     suspicion, whether it came from Step 1's DOM detectors or Step 4's generative critic. Never a
     verdict, never gated, never counted in the pass/fail tally.
   - **`null`** → drop it. This means the classifier judged it deliberate or correct (known-
     deliberate match, `present-latin-legit`, `present-translated`) — no finding, nothing reported.

   When **you** (the agent), reading the code during localize, judge a flagged pattern intentional
   — a brand name that's correctly Latin-script in an `ar` catalog, a deliberate `overlap` by
   design — record it immediately so it is not re-flagged next run. This is autonomous: no
   operator prompt (spec §6):

   ```bash
   bash skills/detecting-visual-ux/scripts/ux-conventions.sh add <detector> <rawSignal>
   ```

#### Confidence-by-oracle-strength

Confidence tracks how strong the backing oracle is, not a vibe call:

- **`high`** — a definite oracle: content fault (`content-*` — `NaN`/`undefined`/`[object Object]`),
  a raw i18n key printed on the page, a resolved catalog gap (`missing`/`empty`) or an
  otherwise-complete-catalog convention violation, invisible text (fg≈bg), a modal painted behind
  its own backdrop, a broken image, or a heuristic corroborated by one of those. The DOM/screenshot
  itself is sufficient proof.
- **`low`** — a standards threshold, not this app's own spec/domain rule: WCAG contrast /
  target-size (`standards` grade, retained from ADR-0007's original objective-detector verdicts).

This is one unified `confidence:low` meaning across the whole skill (see
[CONTEXT.md](../../CONTEXT.md)'s confidence definition) — low whenever the expected value traces to
a general standard or backend-derived value rather than this feature's own oracle, whether the
finding came from Step 3's four detectors or Step 5's adjudication.

**Black-box degrade.** A `definite-dom` finding returns `fail high` unconditionally, even on a
black-box target with no repo/source access — the rendered DOM/screenshot itself IS the evidence
(`i18n-raw-key`, `content-*`, `broken-image`, etc. are graded from the finding alone, with no
source-availability input to the classifier at all). Only `definite-catalog`-grade findings
(i18n script-mismatch resolved via the catalog) and any adjudication that depends on reading source
degrade to `advisory` when the source/catalog cannot be located (`catalogResult: 'no-catalog'`) —
never silently promoted to a `fail` without the oracle that backs it.

See `references/adjudication.md` for the full oracle-grade table, the i18n catalog-result table,
and the known-deliberate short-circuit rationale — this section is the procedure only.

### Step 6 — Precision discipline (do not flag clean controls)

An objective detector that fires on a control that actually passes WCAG AA is a false positive that
becomes a false `fail` in a real run — worse than a missed catch, because it erodes trust in every
other finding. Before trusting a `contrast` or `target-size` finding:

- Re-derive the ratio/size from the same computed-style values the detector used; don't take the
  detector's word without spot-checking the arithmetic on at least one finding per run.
- A negative-control element (a clean, AA-passing primary button; a full-size control; a
  non-clipping cell) must produce **zero** findings. If it does, the detector's threshold — not the
  page — is wrong; fix the detector, don't downgrade a real fail to make the count look better.

## Checklist Summary

- [ ] Inject `scripts/ux-detectors.js` via `browser_evaluate` on the surface's UX criterion.
- [ ] For any `probeClick: true` hint (or other icon-only control), baseline console, click, re-read console.
- [ ] Every confirmed objective finding -> `fail @ FE, confidence:low`, evidence = selector + message + screenshot.
- [ ] Zero objective findings -> criterion `pass` (subjective read never overrides this).
- [ ] Take one screenshot; read it multimodally for hierarchy/alignment/spacing/garishness/affordance.
- [ ] Gate the critic: run only on an interaction-heavy surface OR one where layers 1-2 already
      found ≥1 finding/suspicion, within `criteriaBudget`; log ran/skipped via `critic-coverage.sh`.
- [ ] Resolve vision via `vision-binding.sh resolve` first; `absent` -> skip the critic, run layers
      1-2 only, emit `vision-binding.sh banner` into the report.
- [ ] Take the screenshot and read it in the SAME agent context — never split take/judge across a
      subagent `task` boundary.
- [ ] Every critic observation -> a `critic-<slug>` suspicion, fed into Step 5 — never a verdict
      directly, no matter how obvious it looks.
- [ ] Spot-check at least one objective finding's arithmetic before trusting the batch.
- [ ] Confirm no finding fired on a known-clean/negative-control element.
- [ ] For every `ux-suspicion` entry (Step 1 DOM detector OR Step 4 critic): localize its selector
      to component/style/i18n-key/data-field.
- [ ] Read the known-deliberate list once per run (`ux-conventions.sh read`).
- [ ] Call `adjudicate()` per suspicion; route the result: verdict object -> `fail @ FE` (confidence
      verbatim), `{advisory:true}` -> `## Advisory (ux-suspicions)`, `null` -> drop, no finding.
- [ ] When you judge a flagged pattern deliberate, record it (`ux-conventions.sh add <detector>
      <rawSignal>`) — autonomous, no operator prompt.

## Bundled Scripts

| Script | Purpose |
|---|---|
| `scripts/ux-detectors.js` | Dependency-free, read-only in-page objective UX detectors (contrast/overflow/target-size/accessible-name), plus read-only ux-suspicion families (content/data-rendering, i18n script-mismatch + raw-key, broken-image, invisible-text, overlap/z-index) — inject via `browser_evaluate` |
| `scripts/adjudicate.js` | Pure, DOM-free classifier (Step 5): `adjudicate(suspicion, oracleInputs)` -> a verdict object, `{advisory:true}`, or `null`; `deriveCatalogResult(record)` turns a localized i18n record into the catalog-result enum. See `references/adjudication.md` |
| `scripts/ux-conventions.sh` | `read`/`add` helper for `.qa/ux-conventions.json`'s `knownDeliberate` list — feeds `adjudicate()`'s known-deliberate short-circuit (Step 5.4) |
| `scripts/vision-binding.sh` | `resolve [<harness>]` prints the per-harness screenshot read binding (`Read`/`localImage`/`adapter`/`absent`); `banner` prints the fixed honest-degrade line — Step 4.2 |
| `scripts/critic-coverage.sh` | `log <run-id> <surface> ran\|skipped <reason>` — the sampled-vs-skipped record for the cost-ceiling gate (Step 4.1). *Not yet bundled as of this change — ships in a follow-up task; referenced here so Step 4.1's procedure is written against its final interface.* |

## Mini-Evals

### Eval 1 — Objective set: contrast + overflow + target-size (U1/U2/U3)

**Situation:** A surface has helper text at `#b9b9b9` on white (~1.9:1), a `td.amount` cell with
`max-width:90px; overflow:hidden` whose computed value is wider than the cell, and a 16x16 icon
button.
**The skill should:** Inject `ux-detectors.js`. It returns three findings: `contrast` on the helper
text ("Contrast 1.92:1 below WCAG AA 4.5:1 (SC 1.4.3)"), `overflow` on the amount cell ("Content
clipped: scroll Nx.. > client 90x.. with overflow:hidden"), and `target-size` on the icon button
("Target 16x16 below WCAG AA 24x24 (SC 2.5.8)"). Each becomes a separate `fail @ FE, confidence:low`
criterion with its own selector and WCAG cite — not one merged "UX is bad" finding.

### Eval 2 — U4's two halves: missing name + console error on click

**Situation:** A `?` icon button (`data-testid="fin-help"`) has visible text `"?"` — a real,
non-empty accessible name — so Step 1's static `accessible-name` detector does not fire. But the
symbol-only-label heuristic tags it `probeClick: true`.
**The skill should:** Not stop at the static pass. Per Step 2, baseline `browser_console_messages`,
click the button, re-read console. A new `ReferenceError: undefinedHelpHandler is not defined`
appears. Record a U4-class finding: `fail @ FE, confidence:low`, message includes the verbatim
error + "thrown on click (WCAG SC 4.1.2 / axe button-name analog)". Without the click-probe step,
this control looks fine (it has a label) and the bug is missed entirely.

### Eval 3 — Generative critic advisory example (never a verdict)

**Situation:** A "Finalize" panel uses garish orange/magenta accents and letter-spaced, erratic
heading spacing inconsistent with the rest of the app. The objective detectors find nothing on this
panel (colors pass contrast; nothing is clipped; targets are full-size). Layer 1-2 already found one
`overflow` finding elsewhere on the same surface, so the cost-ceiling gate (Step 4.1) says run the
critic here.
**The skill should:** Report the panel's visual-UX criterion as `pass` (objective — zero findings).
Vision resolves `Read` for this harness, so Step 4 takes and reads the screenshot in the same
context. It emits a suspicion: `{detector:"critic-hierarchy-off", axis:"ux-suspicion",
selector:"#finalize", rawSignal:"garish orange/magenta accent palette and erratic heading
letter-spacing, inconsistent with the rest of the app's neutral palette"}`. Step 5 grades
`critic-hierarchy-off` as `heuristic` (the `critic-` prefix), finds no corroborating definite oracle
on `#finalize`, and returns `{advisory:true, reason:"heuristic-only suspicion (critic-hierarchy-off)
— advisory unless a definite oracle corroborates"}`. Step 5.4 routes it into `## Advisory
(ux-suspicions)`. This entry never flips the criterion's `pass`, is never counted in the pass/fail
tally, and never gets a `suspectedLayer` or `confidence`.

### Eval 4 — Negative control NOT flagged (precision discipline)

**Situation:** A primary "Add founder" button renders `#1a1a1a` text on `#ffffff` background
(~17:1 contrast) at a normal, full-size button box (well over 24x24).
**The skill should:** Run the same detectors as Eval 1 against this element. `contrastRatio`
computes ~17:1, well above the 4.5:1 minimum -> no `contrast` finding. The bounding box is >24x24
-> no `target-size` finding. It has non-empty text and is not symbol-only -> no `accessible-name`
finding and no `probeClick` hint. Zero findings on this element. Per Step 6, this is confirmed by
spot-checking the ratio arithmetic by hand before trusting the batch — a detector that flagged this
clean AA-passing control would be a bug in the detector, not evidence of a real UX defect.

### Eval 5 — U-adj-1: raw i18n key -> fail @ FE, high (spec §11)

**Situation:** A "Deliverables" panel heading renders the literal string `deliverables.title`
instead of translated text — the i18n lookup missed and the raw key leaked into the DOM.
**The skill should:** Step 1 emits a suspicion `{detector:"i18n-raw-key", axis:"ux-suspicion",
selector:"[data-testid=deliverables-title]", rawSignal:"deliverables.title"}`. Step 5.2 localizes
it (a dotted-key-shaped string is definite-DOM evidence on its own — no catalog lookup is even
required to know a raw key rendered). Step 5.3 calls `adjudicate()`; `oracleGradeFor("i18n-raw-key")`
is `definite-dom`, so it returns `fail high` unconditionally — even on a black-box target with no
repo/source, because the rendered DOM/screenshot IS the evidence (the black-box degrade for
catalog/code-adjudication findings instead flows through `catalogResult:'no-catalog'` → advisory —
there is no separate black-box-detection input to the classifier). Step 5.4 routes it to a real
`fail @ FE, confidence:high` visual-UX finding,
reason = "definite DOM oracle: i18n-raw-key (deliverables.title)", screenshot attached.

### Eval 6 — U-adj-2: intentionally-Latin catalog value -> no finding (spec §11)

**Situation:** An `ar`-locale label renders `GitHub` (Latin script) where the surrounding text is
Arabic — a brand name that is correctly left untranslated by convention.
**The skill should:** Step 1's script-mismatch heuristic flags it as an `i18n-script-mismatch`
suspicion. Step 5.2 localizes the key against the `ar` catalog and records
`{presentInTarget:true, targetValue:"GitHub", enValue:"GitHub", isTechnical:true}` (a brand
token, not translatable prose). `deriveCatalogResult()` returns `present-latin-legit` because
`isTechnical` is true. Step 5.3's `adjudicateI18n('present-latin-legit', ...)` returns `null`.
Step 5.4 drops it — no finding, nothing reported. (If the agent independently also judges this
pattern deliberate while reading the code, it may additionally record it via `ux-conventions.sh
add i18n-script-mismatch GitHub` so a *future* occurrence short-circuits at Step 5.3 without
re-deriving `isTechnical`.)

### Eval 7 — U-adj-3: untranslated fallback in an otherwise-complete catalog -> fail @ FE, high (spec §11)

**Situation:** The `ar` catalog is 93% translated (`catalogCompleteness: 0.93`), but one label's
`ar` entry still reads `"Export"` — identical to the `en` value — reading as prose, not a brand.
**The skill should:** Step 1 flags `i18n-script-mismatch`. Step 5.2 localizes:
`{presentInTarget:true, targetValue:"Export", enValue:"Export", isTechnical:false}`.
`deriveCatalogResult()` sees a Latin value equal to `enValue` reading as prose ->
`present-latin-eq-en`. Step 5.3's `adjudicateI18n('present-latin-eq-en', 0.93)` sees
`catalogCompleteness >= 0.9` -> `fail high` ("untranslated fallback ... in an otherwise-complete
catalog"). Step 5.4 routes it to a real `fail @ FE, confidence:high` finding. (Had the catalog been
only 40% translated, the same observation would route to Step 5.4's advisory branch instead — the
app may simply not have reached this string yet.)

### Eval 8 — U-adj-4: generic overlap with no corroborating oracle -> advisory only (spec §11)

**Situation:** Two `<div>`s in a summary card visually overlap by a few pixels at one viewport
width — no console error, no clipped/invisible text, nothing else wrong on either element.
**The skill should:** Step 1 flags a heuristic `overlap` suspicion. Step 5.3 calls `adjudicate()`
with `corroborated: false` (no other `definite-*` finding landed on either element). `overlap`
grades as `heuristic`, and with no corroboration `adjudicate()` returns `{advisory:true, reason:
"heuristic-only suspicion (overlap) — advisory unless a definite oracle corroborates"}`. Step 5.4
routes it into `## Advisory (ux-suspicions)` — never a verdict, never gated, never counted in the
pass/fail tally, exactly like a Step 4 critic observation (Eval 3).
