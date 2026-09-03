# The generative critic — full prompt & rubric (layer 3, ADR-0019 §5)

Companion to [SKILL.md](../SKILL.md) Step 4 — this is the long prompt/rubric kept out of SKILL.md's
line budget. Read this immediately before running the critic (Step 4.4); SKILL.md carries the
procedure (when it runs, the vision contract, output routing) — this file carries what to actually
look for and how to say it.

## The prompt

Give the model, together, in one turn (never split across a subagent boundary — SKILL.md Step 4.2):

1. The screenshot (via the resolved disk-file binding — SKILL.md Step 4.2).
2. The interaction trace that produced this surface (the ordered click/type/submit/navigate
   sequence that got here).
3. The persona and locale the criterion is running as.

Then ask:

> Look at this screenshot as if you were **`<persona>`** doing **`<the interaction trace's stated
> goal>`**, in **`<locale>`**. What looks broken, wrong, confusing, or off? Call out anything you'd
> flag as a real tester — even if you're not sure it's a bug. Don't rate the app or give it a score;
> list concrete observations, each anchored to a specific element or region.

## What to look for (the rubric)

Not a checklist to march through mechanically — a set of reflexes, the same ones a human tester
carries. Each bullet below, if triggered, should become one `critic-<slug>` suspicion (SKILL.md
Step 4.5) with a `selector`/region and a one-line `rawSignal`. This rubric widens the original
ADR-0007 aesthetics-only read (last category below) to the full long tail (ADR-0019 §4 families 3,
6, 7, 8 plus the trace/locale reflexes families 1-2's static detectors can't see).

### Content & data
- Missing content where something should render (an empty cell/row/panel that shouldn't be empty
  given what the trace just did).
- Unexpected content — placeholder/lorem/debug text, a duplicated block, stale data that doesn't
  match the trace's most recent action.
- Content that's technically present but doesn't actually read — too small, too low-contrast to
  parse at a glance (Step 1's `contrast` detector already *measures* contrast; this is a judgment
  layer on top: does it read as a sentence, not just pass a ratio).

### Layout
- Overlapping or crowded elements that don't look intentional.
- Misaligned elements — labels/values/columns that should share an axis and visibly don't.
- Content that looks cut off, cramped, or squeezed even where no detector fired (Step 1's
  `overflow` detector catches `scrollWidth>clientWidth`; this catches "technically fits, but
  ugly/tight").

### Flow & interaction (uses the trace)
- Does the surface make sense given what the trace just did? (e.g. after "submit," does the result
  show, or does it look like nothing happened / like a different flow entirely?)
- Is there a moment in the trace where a reasonable persona would be visibly confused about what to
  do next?
- Does anything on screen contradict the action just taken (e.g. a "0 items" empty state right
  after adding an item — a sibling case to family 9's sheet-stack destruction, but observed from a
  single frame rather than a modeled overlay stack)?

### Locale & persona fit
- Layout that assumes LTR in an RTL locale — icon direction, alignment, reading order that doesn't
  flip.
- A date/number/currency format that doesn't match the locale (the family-2 static i18n detectors
  catch raw keys and catalog gaps; this catches format/layout choices a catalog lookup can't see).
- Copy, tone, or imagery that reads as aimed at a different persona/role than the one stated.

### Aesthetic (the original ADR-0007 read — still in scope, now one category among several)
- **Visual hierarchy** — is the primary action visually the most prominent element, or does a
  secondary control compete/win?
- **Alignment** — do related columns/labels share an axis, or do they visually misread as unrelated?
- **Spacing rhythm** — is spacing consistent, or erratic/cramped/uneven within one region?
- **Garishness / brand consistency** — do colors clash with the rest of the app's palette?
- **Affordance clarity** — does an interactive-looking element actually look clickable (and vice
  versa)?

## Suspicion shape

Every triggered observation becomes exactly this shape (SKILL.md Step 4.5 — feed straight into
Step 5, unchanged):

```json
{ "detector": "critic-<slug>", "axis": "ux-suspicion",
  "selector": "<best-effort selector/region>",
  "evidence": "<what in the screenshot/trace triggered this>",
  "rawSignal": "<the one-line observation, in your own words>" }
```

Pick `<slug>` to name the *kind* of thing observed, not the specific instance — reusable slugs like
`critic-layout-off`, `critic-flow-confusing`, `critic-illegible`, `critic-locale-mismatch`,
`critic-hierarchy-off`, `critic-affordance-unclear` are good; `critic-finalize-panel-orange` is not
(that specificity belongs in `selector`/`rawSignal`, not the detector id — `adjudicate.js` grades by
detector-id prefix, so a family of one-off slugs would each need its own `ORACLE_GRADES` entry for
no benefit; the bare `critic-` prefix already grades every one of them `heuristic`).

## What this rubric is not

- Not a pixel-diff / screenshot-regression baseline (ADR-0019 §12 — out of scope; this is semantic
  judgment, not image comparison).
- Not a design-system linter — consistency/aesthetic findings here stay advisory by construction
  (SKILL.md Step 4.5), same as everywhere else in this skill.
- Not a translation-quality grader — raw-key/script-mismatch/untranslated-fallback are Step 1's
  static `i18n-*` detectors' job (definite-oracle, can yield a verdict on their own); this rubric's
  locale category is about layout/format/audience fit a static DOM detector can't see, not
  machine-translation quality (ADR-0019 §12 rules out grading Arabic copy quality beyond
  catalog-presence).
- Never a place to click/type/submit "to see what happens" (SKILL.md Step 4.6, read-only
  discipline) — a mutation idea becomes a `human-action` checklist criterion, not an inline probe
  from inside this step.
