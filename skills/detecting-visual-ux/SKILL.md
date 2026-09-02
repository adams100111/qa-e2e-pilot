---
name: detecting-visual-ux
description: Use when a checklist criterion is tagged visual-UX (one is emitted per surface by analyzing-feature-ui) or when driving-browser-qa reaches a UX criterion — runs dependency-free objective detectors (contrast, overflow/clipping, touch-target size, missing accessible name / console error on click) that yield a real fail@FE/confidence:low verdict, and a separate multimodal screenshot read for subjective aesthetics (visual hierarchy, spacing, garishness) that is reported ONLY as advisory, never a verdict. Implements ADR-0007's split so UX recall rises without adding a sixth verdict.
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

**Suspicion entries are NEVER verdicts (`axis:"ux-suspicion"`).** Alongside the four objective
detectors, `ux-detectors.js` may return entries whose `axis` is `"ux-suspicion"` (the new
content/i18n/assets/invisible-text/overlap families). These carry **no** `verdict`,
`suspectedLayer`, or `confidence`. Do **not** apply Step 3 to them — an `axis:"ux-suspicion"`
entry never becomes a `fail` and is never counted in the pass/fail tally. Route each into the
report's advisory stream as `- [selector] <evidence> (ux-suspicion — not a verdict; awaiting
adjudication)`, exactly like the `overflow-ellipsis-hint` / `accessible-name-probe` hint carve-out.
Turning suspicions into verdicts (adjudication — design §1 steps 2–4) is a separate, later effort.

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

### Step 5 — Precision discipline (do not flag clean controls)

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

## Bundled Scripts

| Script | Purpose |
|---|---|
| `scripts/ux-detectors.js` | Dependency-free, read-only in-page objective UX detectors (contrast/overflow/target-size/accessible-name), plus read-only ux-suspicion families (content/data-rendering, i18n script-mismatch + raw-key, broken-image, invisible-text, overlap/z-index) — inject via `browser_evaluate` |

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
finding and no `probeClick` hint. Zero findings on this element. Per Step 5, this is confirmed by
spot-checking the ratio arithmetic by hand before trusting the batch — a detector that flagged this
clean AA-passing control would be a bug in the detector, not evidence of a real UX defect.
