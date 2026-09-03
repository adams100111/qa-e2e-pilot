---
name: detecting-visual-ux
description: Use when a checklist criterion is tagged visual-UX (one is emitted per surface by analyzing-feature-ui) or when driving-browser-qa reaches a UX criterion — runs dependency-free objective detectors (contrast, overflow/clipping, touch-target size, missing accessible name / console error on click) that yield a real fail@FE/confidence:low verdict, and a separate multimodal screenshot read for subjective aesthetics (visual hierarchy, spacing, garishness) that is reported ONLY as advisory, never a verdict. Also adjudicates the detectors' content/i18n/asset ux-suspicion findings (detect→localize→adjudicate→classify) into fail@FE (confidence by oracle strength), advisory, or dropped. Implements ADR-0007's split so UX recall rises without adding a sixth verdict.
---

# Detecting Visual UX

## Overview

"UX" conflates two different things. **Objective** defects — contrast, clipping, undersized touch
targets, missing accessible names, elements that throw on click — have a citable, machine-checkable
oracle (WCAG 2.2 / axe conventions). **Subjective** defects — garish colors, erratic spacing, poor
visual hierarchy — have no objective oracle; they are a trained eye's opinion, however well-founded.

Per ADR-0007 ([docs/adr/0007-ux-detection-objective-verdict-subjective-advisory.md](../../docs/adr/0007-ux-detection-objective-verdict-subjective-advisory.md)),
this skill keeps that split load-bearing:

- **Objective -> a real verdict.** A confirmed objective defect is `verdict: fail`, `suspectedLayer:
  FE`, `confidence: low` — low because the threshold is a standard, not a spec-reconciled numeric
  oracle, but it is still an honest fail, not a downgraded observation.
- **Subjective -> the advisory stream, never a verdict.** No `warn`/`aesthetic`/sixth verdict is
  ever introduced (CLAUDE.md invariant). Subjective findings go into the report's
  `## Advisory (aesthetics)` section, anchored to a selector/region so they're checkable, and are
  excluded from every pass/fail tally.

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

### Step 4 — Subjective advisory read (multimodal, separate stream)

Take a `browser_take_screenshot` of the full surface. Read it directly (multimodal) for:

- **Visual hierarchy** — is the primary action visually the most prominent element, or does a
  secondary control compete/win?
- **Alignment** — do related columns/labels share an axis, or do they visually misread as unrelated?
- **Spacing rhythm** — is spacing consistent, or erratic/cramped/uneven within one region?
- **Garishness / brand consistency** — do colors clash with the rest of the app's palette?
- **Affordance clarity** — does an interactive-looking element actually look clickable (and vice versa)?

Each observation goes into the report's `## Advisory (aesthetics)` section as:

```
- [selector/region] <observation>. (advisory — not a verdict, not localized to a layer)
```

Never assign `suspectedLayer` or `verdict` to an advisory item. Never let it affect the criterion's
pass/fail tally, even if the objective detectors also found nothing on that surface — a surface can
legitimately be `pass` (objective) with a garish-but-functional advisory note attached.

### Step 5 — Adjudicate ux-suspicions (detect → localize → adjudicate → classify)

`axis:"ux-suspicion"` entries from Step 1 (content/i18n/asset/invisible-text/overlap families) are
not verdicts on their own — they are unresolved leads. This step runs the full pipeline
(design §1) that resolves each one to a real finding, an advisory, or nothing. The oracle-grade
table and the classifier live in `scripts/adjudicate.js`; the doctrine behind the table is
`references/adjudication.md` (ADR-0019) — read that reference for the full grade/table rationale,
this section only carries the procedure.

1. **Detect** — already done: the `ux-suspicion` entries came out of Step 1's `ux-detectors.js`
   injection, unchanged. Each is `{detector, axis:'ux-suspicion', selector, evidence, rawSignal}`.

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
       hasSource: true,
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
   like `overlap`.

4. **Classify/route** — `adjudicate()` returns exactly one of three shapes; route accordingly:
   - **A verdict object** `{verdict:'fail', suspectedLayer:'FE', confidence, family, reason}` → a
     real `fail @ FE` visual-UX criterion finding. Carry `confidence` (`high`/`low`) **verbatim** —
     never re-derive or downgrade it — and use `reason` as the finding's message. Attach a
     `browser_take_screenshot` of the flagged region as evidence, same as Step 3.
   - **An advisory object** `{advisory:true, reason}` → append to the `## Advisory
     (ux-suspicions)` stream (a sibling of Step 4's `## Advisory (aesthetics)`, kept separate since
     one stream is subjective-read and the other is adjudicated-but-unresolved). Never a verdict,
     never gated, never counted in the pass/fail tally.
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
  its own backdrop, or a heuristic corroborated by one of those. The DOM/screenshot itself is
  sufficient proof.
- **`low`** — a standards threshold, not this app's own spec/domain rule: WCAG contrast /
  target-size (`standards` grade, retained from ADR-0007's original objective-detector verdicts).

This is one unified `confidence:low` meaning across the whole skill (see
[CONTEXT.md](../../CONTEXT.md)'s confidence definition) — low whenever the expected value traces to
a general standard or backend-derived value rather than this feature's own oracle, whether the
finding came from Step 3's four detectors or Step 5's adjudication.

**Black-box degrade.** A `definite-dom` finding needs no source access to stay confidence `high` —
the rendered DOM/screenshot already is the evidence (`adjudicate(..., {hasSource:false})` still
returns `high` for `i18n-raw-key`, `content-*`, etc.). Only `definite-catalog`-grade findings
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
- [ ] Subjective findings -> `## Advisory (aesthetics)` only — no verdict, no suspected layer, never gated.
- [ ] Spot-check at least one objective finding's arithmetic before trusting the batch.
- [ ] Confirm no finding fired on a known-clean/negative-control element.
- [ ] For every `ux-suspicion` entry: localize its selector to component/style/i18n-key/data-field.
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

### Eval 3 — Subjective advisory example (never a verdict)

**Situation:** A "Finalize" panel uses garish orange/magenta accents and letter-spaced, erratic
heading spacing inconsistent with the rest of the app. The objective detectors find nothing on this
panel (colors pass contrast; nothing is clipped; targets are full-size).
**The skill should:** Report the panel's visual-UX criterion as `pass` (objective — zero findings).
Separately, Step 4's screenshot read produces an advisory entry: `[#finalize] Garish orange/magenta
accent palette and erratic heading letter-spacing, inconsistent with the rest of the app's neutral
palette. (advisory — not a verdict, not localized to a layer)`. This entry never flips the
criterion's `pass`, is never counted in the pass/fail tally, and never gets a `suspectedLayer`.

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
is `definite-dom`, so it returns `fail high` unconditionally — even `hasSource:false` (black-box)
per the degrade rule. Step 5.4 routes it to a real `fail @ FE, confidence:high` visual-UX finding,
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
pass/fail tally, exactly like a Step 4 aesthetic observation.
