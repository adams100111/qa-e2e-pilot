---
name: detecting-interaction-ux
description: Use when a criterion covers an overlay/sheet/drawer/modal interaction sequence — driving open→child→submit→close and holding an expectation across snapshots to catch a child overlay that destroys its parent, dead-ends the user, breaks focus-trap, or loses return-to-context; adjudicates observed destruction into fail@FE (low, or high once the shared open/route state is localized in code).
---

# Detecting Interaction UX

## Overview

Some UX defects are not visible in a single screenshot — they only show up as a **broken
expectation held across a sequence**: a child overlay that silently kills its parent instead
of stacking on it, a submit that strands the user on an empty surface instead of returning
them to context, a modal that lets focus escape behind it. `scripts/overlay-stack.js`
extracts the overlay stack at each point in the sequence and checks five invariants against
it; this skill is the agent procedure that drives the sequence, runs those checks, and
adjudicates what they find into a verdict.

This skill builds ON **walking-multistep-flows** (drive-the-sequence mechanics, the
consolidated observe-round) and reuses **detecting-visual-ux**'s adjudication pipeline
(`adjudicate.js`, `ux-conventions.sh`) and its `behavioral-observed` oracle grade. It does not
duplicate either — read them first.

## When to Use

- A checklist criterion drives an overlay/sheet/drawer/modal sequence: open a panel, open a
  child overlay from inside it, submit, close.
- Any time a write flow is UI-mediated through a stacked overlay (a "add X" form opened from
  inside a list panel) — this is the companion criterion to that write's functional-create
  check, never a replacement for it.

## The Process

### Step 1 — Plan the overlay sequence + the two criteria (spec §7 Q3)

Driving "add a deliverable" from inside a list sheet is **two criteria sharing one driven
session**, not one:

- The **functional-create** criterion — the write persists at multiplicity N+1. Hand this to
  **verifying-backend-persistence**.
- The **interaction-UX** criterion — the overlay stack survived the sequence (parent not
  destroyed, focus trapped, return-to-context, no dead-end). This is what this skill owns.

Each rolls to its **own** verdict. The report shows two findings, never one conflated
verdict — a UI bug and a persistence bug are different suspected layers and different fixes,
even when they were caught in the same drive. The interaction-UX criterion is
`human-action`-gated (ADR-0015): its `pass` requires the act-phase workaround lint +
before/after fingerprints, and — when `--save-session` is on — the independent toolstream
reconciliation. See `skills/driving-browser-qa/references/interaction-discipline.md`.

### Step 2 — Drive the sequence on `walking-multistep-flows`, capturing the overlay stack between act steps

Use `walking-multistep-flows`'s per-step observe-round mechanics for the drive itself. Between
every **act** step, inject `scripts/overlay-stack.js`'s `extractOverlayStack()` via
`browser_evaluate` to capture a stack snapshot. The sequence:

| # | Phase | Action | Capture |
|---|---|---|---|
| 0 | observe | — | base state |
| 1 | **act** | `browser_click` — open the list/parent | — |
| 1 | observe (read-only) | `browser_evaluate(extractOverlayStack)` | `S0` (parent present) |
| 2 | **act** | `browser_click` — open the child overlay | — |
| 2 | observe (read-only) | `browser_evaluate(extractOverlayStack)` | `S1` |
| 3 | **act** | `browser_fill_form` + `browser_click` — submit | — |
| 3 | observe (read-only) | `browser_evaluate(extractOverlayStack)` | `S2` |
| 4 | **act** | `browser_click` — close | — |
| 4 | observe (read-only) | `browser_evaluate(extractOverlayStack)` | `S3` |

The act clicks (`browser_click`/`browser_fill_form`) are UI-only human affordances per
ADR-0015 — **never** a mutating `browser_evaluate` on the act path. The
`extractOverlayStack()` calls are pure DOM reads (no write), so they are always legal
observe-phase captures, on any phase.

`extractOverlayStack()` cannot infer `parentId` from a single snapshot (it says so in its own
comment) — **the agent tracks it across the drive**. When a new overlay appears in a
snapshot that wasn't in the previous one, set its `parentId` to the overlay that was topmost
(highest `zIndex`, still `present`) in the *previous* snapshot — i.e. the overlay that was on
top when the open-child click fired.

### Step 3 — Check the five invariants

Run the Task-1 cores from `scripts/overlay-stack.js` against the captured snapshots. Call
them via `node -e` requiring the module (same idiom as `detecting-visual-ux`'s
`adjudicate.js` calls):

```bash
node -e '
  const m = require("./skills/detecting-interaction-ux/scripts/overlay-stack.js");
  const S0 = JSON.parse(process.argv[1]), S1 = JSON.parse(process.argv[2]);
  console.log(JSON.stringify(m.checkStackIntegrity(S0, S1, "dialog:New Deliverable")));
' "$S0_JSON" "$S1_JSON"
```

| # | Invariant | Call | Checked between |
|---|---|---|---|
| 1 | Opening the child must not destroy the parent | `checkStackIntegrity(S0, S1, childId)` | `S0` → `S1` |
| 2 | After submit, the expected parent/context is back | `checkReturnToContext(S2, parentId)` | `S2` |
| 3 | After close, the surface is not an empty dead-end | `checkNoDeadEnd(S3)` | `S3` |
| 4 | The topmost `aria-modal` overlay is focus-trapped | `checkFocusTrap(S1)` | `S1` |
| 5 | Opening the child must not destroy an unrelated sibling | `checkNoDestructiveOnOpen(S0, S1)` | `S0` → `S1` |

Each returns either `null` (invariant held — no finding) or an `overlaySuspicion(...)` object
(`axis: 'ux-suspicion'`, detector one of `interaction-overlay-destroyed`,
`interaction-no-return`, `interaction-dead-end`, `interaction-focus-untrapped`,
`interaction-destructive-on-open`). A suspicion carries no verdict or confidence by itself —
that is Step 4's job, exactly as `detecting-visual-ux` treats its own `ux-suspicion` entries.

### Step 4 — Adjudicate + localize for the confidence upgrade

Read the known-deliberate list **once per run** (a wizard that deliberately replaces one
panel with another is a legitimate pattern, not a bug):

```bash
bash skills/detecting-visual-ux/scripts/ux-conventions.sh read
```

For each suspicion returned by Step 3, **localize** the two overlays involved to their
controlling state in code (read-only — grep the frontend repo for the component/testid). The
tell for the sheet-stack bug specifically is a **single shared `open`/route state that both
overlays bind to** (e.g. one `activeSheet` variable, or both mounted on the same route param) —
if you find it, `corroborated: true`; otherwise `corroborated: false`.

Then call the classifier — the SAME `adjudicate()` used by `detecting-visual-ux`, because
`interaction-*` detectors already resolve to its `behavioral-observed` oracle grade (see
`skills/detecting-visual-ux/scripts/adjudicate.js`'s `ORACLE_GRADES` table):

```bash
node -e '
  const { adjudicate } = require("./skills/detecting-visual-ux/scripts/adjudicate.js");
  const suspicion = JSON.parse(process.argv[1]);      // from Step 3
  const knownDeliberate = JSON.parse(process.argv[2]); // from ux-conventions.sh read
  const corroborated = process.argv[3] === "true";     // from localize, above
  console.log(JSON.stringify(adjudicate(suspicion, { corroborated, knownDeliberate })));
' "$SUSPICION_JSON" "$KNOWN_DELIBERATE_JSON" "$CORROBORATED"
```

Route the result:

- **A verdict object** — `{verdict:'fail', suspectedLayer:'FE', confidence, reason}`.
  `behavioral-observed` returns `confidence:'high'` when `corroborated:true` (shared-state
  cause localized) and `confidence:'low'` otherwise — carry it **verbatim**, never re-derive
  it. Record the finding with `reason` as the message plus a `browser_take_screenshot` of the
  flagged overlay(s).
- **`null`** — the classifier judged it deliberate (a `knownDeliberate` match) or the
  invariant simply held — no finding.

If **you** (the agent), while localizing, judge the observed behavior intentional — a wizard
that deliberately replaces one panel with the next, by design, not a bug — record it
immediately so it is not re-flagged next run. This is **autonomous: no operator prompt**
(spec §6):

```bash
bash skills/detecting-visual-ux/scripts/ux-conventions.sh add <detector> <rawSignal>
```

If Step 3 produced zero suspicions across all five invariants, the interaction-UX criterion
is `pass`.

### Step 5 — Honest coverage limit

`extractOverlayStack()`'s overlay-identification heuristic catches **semantic** overlays:
`role=dialog`, `aria-modal`, or a `.modal`/`.dialog`/`.sheet`/`.drawer`/`[data-overlay]` node
with a high `z-index` and fixed/absolute position. A **non-semantic overlay** — a plain
`<div>` with none of those markers — may be missed by this heuristic entirely. This is not a
silent pass: an undetected overlay is not adjudicated as "correct," it simply falls through
this skill's coverage and is left to the generative critic (layer 3, deferred sub-plan C).
State this limitation plainly in the report when a surface uses unconventional overlay
markup you cannot otherwise confirm was checked.

### Step 6 — Boundary (spec §8)

This criterion owns **overlay/behavior faults only** — the stack, focus-trap, and
return-to-context invariants. Whether the deliverable submitted through the child overlay
actually **persisted** is the functional-create criterion's job
(**verifying-backend-persistence**), driven in the same session but verdicted separately.
Do not conflate a `pass` on one into a `pass` on the other, and do not let a `fail` on one
suppress reporting the other.

## Checklist Summary

```
[ ] 1. Two criteria planned for this driven session: functional-create + interaction-UX (own verdicts)
[ ] 2. Sequence driven: observe base -> act open -> S0 -> act open child -> S1 -> act submit -> S2 -> act close -> S3
[ ] 3. parentId tracked across the drive (topmost overlay at open time)
[ ] 4. All five invariants checked: checkStackIntegrity, checkReturnToContext, checkNoDeadEnd, checkFocusTrap, checkNoDestructiveOnOpen
[ ] 5. Known-deliberate list read once per run (ux-conventions.sh read)
[ ] 6. Each suspicion localized (shared open/route state?) -> corroborated true/false
[ ] 7. adjudicate() called per suspicion; confidence carried verbatim; screenshot attached on fail
[ ] 8. Agent-judged-intentional cases recorded via ux-conventions.sh add (autonomous)
[ ] 9. Non-semantic-overlay coverage limit stated when markup is unconventional
[ ] 10. Interaction-UX verdict kept separate from the functional-create verdict
```

## Bundled Scripts

| Script | Purpose |
|---|---|
| `scripts/overlay-stack.js` | Dependency-free: browser-side `extractOverlayStack()` (read-only DOM capture) plus five pure invariant checkers (`checkStackIntegrity`, `checkReturnToContext`, `checkNoDeadEnd`, `checkFocusTrap`, `checkNoDestructiveOnOpen`) that emit `interaction-*` `ux-suspicion` entries — no DOM required for the checkers, so they run under plain `node`. |

## Mini-Evals

### I1 — sheet-stack (fixture #1, ADR-0019): child overlay destroys its parent

**Situation:** A deliverables list opens in a sheet (`S0`: `dialog:Deliverables` present).
Clicking "Add deliverable" opens the new-deliverable form — but it renders in place of the
list sheet: `S1` shows only `dialog:New Deliverable`, `dialog:Deliverables` is gone.

**The skill should:** `checkStackIntegrity(S0, S1, "dialog:New Deliverable")` returns an
`interaction-overlay-destroyed` suspicion. Localize finds both sheets bound to a single
shared `open`/route state (one `activeSheet` variable toggled, not two independent booleans)
→ `corroborated: true`. `adjudicate()` (grade `behavioral-observed`, corroborated) →
`fail @ FE, confidence: high`, reason "observed overlay-stack invariant violation, shared-
state cause localized in code: interaction-overlay-destroyed". Screenshot attached. This
finding is reported separately from the functional-create criterion for the same submit.

### I2 — return-to-context: submit strands the user on an empty surface

**Situation:** After filling and submitting the child form, `S2` is captured — expecting the
parent list (`dialog:Deliverables`) to be back. Instead the stack is empty; the user lands on
a blank surface with no visible way back to the list.

**The skill should:** `checkReturnToContext(S2, "dialog:Deliverables")` returns an
`interaction-no-return` suspicion. Localize: no single shared state variable found — the
child's close handler simply never re-opens the parent (two independent, uncoupled overlay
states) → `corroborated: false`. `adjudicate()` → `fail @ FE, confidence: low`, reason
"observed overlay-stack invariant violation (interaction-no-return) — confidence low until
the shared open/route state is localized in code."

### I3 — focus-trap: focus escapes an open modal

**Situation:** A modal opens (`S1`: `dialog:New Deliverable`, `ariaModal: true`) but tabbing
moves focus to elements behind it in the DOM — `focusTrapped: false` in the captured
descriptor.

**The skill should:** `checkFocusTrap(S1)` returns an `interaction-focus-untrapped`
suspicion (the topmost `aria-modal` overlay is not focus-trapped). No shared-state
localization applies to a focus-trap defect specifically, so `corroborated: false`.
`adjudicate()` → `fail @ FE, confidence: low`.

### Negative control — child correctly stacks on its parent

**Situation:** The same "Add deliverable" flow, but the child overlay renders on top of the
list (`S1` shows both `dialog:Deliverables` and `dialog:New Deliverable`, the child's
`parentId` set to the parent's id, both `present: true`).

**The skill should:** All five invariant checks return `null` across the whole sequence —
`checkStackIntegrity` sees the parent still present in `S1`, `checkReturnToContext` finds the
parent back in `S2`, `checkNoDeadEnd` finds a non-empty `S3`, `checkFocusTrap` finds the
modal trapped, `checkNoDestructiveOnOpen` finds no unrelated sibling destroyed. Zero
suspicions → the interaction-UX criterion is `pass`. (The held-out sheet-stack/date pair used
for I1 is excluded from the recall metric — that metric is measured separately in deferred
sub-plan C, not asserted by this skill.)
