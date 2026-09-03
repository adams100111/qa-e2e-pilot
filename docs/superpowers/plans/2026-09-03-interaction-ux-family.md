# Interaction/Behavioral UX Family (family 9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch the **sheet-stack behavioral bug class** — where opening a child overlay destroys its parent, dead-ends the user, or breaks focus-trap/return-to-context — by driving a real action sequence and holding an expectation across snapshots, then adjudicating the observed overlay-stack behavior into a `fail @ FE` verdict (confidence `low` on observation alone, `high` once the shared-state cause is localized in code) through the sub-plan-A classifier.

**Architecture:** A new skill `detecting-interaction-ux` builds on `walking-multistep-flows` to drive a multi-step UI sequence (open list → click add → submit) using human-path affordances, capturing the **overlay stack** (accessibility-tree `role=dialog`/`aria-modal`, high-z fixed/absolute panels, focus-trap boundaries + parentage) between steps via a new dependency-free `overlay-stack.js` DETECT function. Pure invariant-checker cores test the five behavioral invariants against before/after overlay-stack snapshots and emit suspicions; those route through the existing `adjudicate()` classifier, extended with one new oracle grade (`behavioral-observed`) so an observed invariant violation becomes `fail low` (→ `fail high` when the agent localizes the shared `open`/route state in code). The interaction-UX criterion is `human-action`-gated (ADR-0015) and rides the functional-create criterion's single driven session (two criteria, two verdicts — spec §7 Q3).

**Tech Stack:** Dependency-free browser/Node JavaScript (dual-mode module, `browser_evaluate`-injected + `require()`d in tests), bash test runners (plain-Node, no jsdom), markdown skill body. No new runtime dependency.

## Global Constraints

- **This is sub-plan B of the human-eye-UX design (ADR-0019).** Sub-plan A (adjudication + confidence-by-oracle) is merged (PR #42). Sub-plan C (generative critic layer 3 + accuracy-harness UI/UX taxonomy fixture + the ≥95%/≥90% measured gate) remains deferred — this plan does NOT build the fixture or claim the recall gate.
- **Verdicts are exactly `pass | fail | blocked | deferred | error`; confidence `high | low`; suspected layer exactly one of `FE | route | service | migration | DB`.** The interaction family emits only `fail @ FE` (a behavioral presentation fault is the frontend) or routes to advisory. No sixth verdict.
- **Confidence by oracle strength (spec §3), extended for behavioral observation:** an observed overlay-stack invariant violation is a **verdict** at `confidence: low` (the destruction is objectively observed, but could be intentional); it escalates to `confidence: high` only when the agent localizes the **shared `open`/route state both overlays bind to** in code (spec §7 adjudication tell). This is a NEW grade `behavioral-observed` — distinct from `heuristic` (which is advisory-until-corroborated): an observed invariant violation is a real fail, a heuristic is only a suspicion.
- **The interaction-UX criterion is `human-action`-gated (ADR-0015).** Its act phase performs the real affordance clicks (open list → open child → submit) via **UI-only** tools (`browser_click`/`type`/`fill_form`/`press_key`); a mutating `browser_evaluate` on the act path is a gate-rejected workaround. Overlay-stack snapshots are taken in the read-only **observe/assert** phase between act steps. It rides the same driven session as the functional-create criterion; the two roll to two separate verdicts (spec §7 Q3) — never one conflated verdict.
- **UI-impossible = `fail @ FE` (confidence high), never `blocked`, never a workaround** (ADR-0015 §2). A genuine tool limitation is a logged low-confidence `--nonui-reason` opt-out.
- **Honest coverage limit:** the overlay-identification heuristic (accessibility-tree roles + high-z fixed panels + focus-trap) **may miss non-semantic overlays** (a plain `<div>` with no role). Those are NOT silently passed — they fall through to the generative critic (layer 3, deferred sub-plan C). State this in the skill body.
- **Boundary vs baking/computed-logic (spec §8):** this family owns **presentation/behavior** faults (overlay destroyed, dead-end, focus lost, no return-to-context). Value correctness (did the deliverable persist at N+1) stays with the functional-create criterion via `verifying-backend-persistence`. No duplication.
- **Fully autonomous — no in-loop HITL (spec §6).** The agent judges deliberate-vs-bug by reading the code, recording a judged-intentional pattern to `.qa/ux-conventions.json` (via `ux-conventions.sh add`) so it isn't re-flagged; an ambiguous case is advisory, never a blocking prompt.
- Dependency-free JS (no require/import in `overlay-stack.js`); dual-mode (browser DETECT + node-exported pure cores) exactly like `ux-detectors.js`. No `grep -P`, `perl`, or new `node` dependency.
- **Portability:** all core (skill body + scripts, copied verbatim into `dist/<h>/`). `validate-adapters.sh` byte-oracle + the portability test stay green. A new skill needs BOTH the `install.sh` glob (automatic) AND an entry in `scripts/skills.json` (the npx path).
- **Skill frontmatter has only `name` + `description`.** `name` == directory name `detecting-interaction-ux` (lowercase-hyphen, gerund, ≤64 chars, no "claude"). `description` third-person, ≤1024 chars, starts "Use when …". Body **< 500 lines**, imperative, checklist-structured, references one level deep. ≥3 mini-evals.
- **No Claude/Anthropic attribution** in any commit; no `Co-Authored-By` trailer. Never commit `dist/`.

## Self-grilled decisions (my own recommended answers applied)

1. **New oracle grade vs. a separate verdict path** → add a `behavioral-observed` grade to `adjudicate.js` (`interaction-` prefix). Keeps ONE classifier contract (sub-plan A's whole point); the interaction family's verdicts flow through the same `adjudicate()`. *Applied (Task 2).*
2. **Observed-destruction = verdict-low, not advisory** → per spec §7 line 95, observed overlay destruction is a `fail` (confidence low), escalating to high on code-confirm — NOT an advisory suspicion. The `behavioral-observed` grade returns `failLow` by default, `failHigh` when `oracleInputs.corroborated` (shared-state cause localized). *Applied.*
3. **Overlay descriptor shape / identity** → `{id, role, ariaModal, zIndex, position, focusTrapped, parentId, present}`; `id` = a stable key `"<role>:<accessibleName>"` (refs churn across React renders; role+name is stable-ish). `parentId` = the overlay that was topmost when this one opened (the opener), tracked by the agent across the drive. *Applied (Task 1).*
4. **Invariant-1 (child destroys parent) detection** → compare the before-stack (parent present) to the after-open-child stack: if an overlay present before opening the child is ABSENT after the child opened (and the child is present), that is a stack-integrity violation. *Applied.*
5. **Confidence escalation mechanism** → the skill localizes the shared `open`/route state in code (read-only, in Arrange/observe); if a single shared state both overlays bind to is found, it passes `corroborated:true` to `adjudicate()` → `failHigh`. Else `failLow` (observed only). *Applied (Task 3).*
6. **Human-action gating** → the interaction-UX criterion is `human-action`-tagged and rides the functional-create criterion's driven session; overlay-stack snapshots are read-only observe-phase captures; the mutating act (submit) is fingerprinted for the functional-create criterion per ADR-0015. *Applied (Task 3).*
7. **Skill registration** → add a `scripts/skills.json` entry (category `verification`) in addition to the automatic `install.sh` glob. *Applied (Task 3).*
8. **Mini-evals source** → the canonical case is the held-out sheet-stack bug (fixture #1, ADR-0019); include it + two invariant-derived evals (focus-trap correctness, return-to-context). Note the held-out pair is excluded from the recall metric (measured in deferred sub-plan C). *Applied (Task 3).*

---

## File Structure

- `skills/detecting-interaction-ux/scripts/overlay-stack.js` **(new)** — dual-mode dependency-free module. Browser `DETECT()` extracts the overlay stack from the live DOM/accessibility tree; pure cores check the five invariants against before/after overlay-stack snapshot arrays and emit suspicions. Exports: `extractOverlayStack` (DETECT helper), `checkStackIntegrity`, `checkReturnToContext`, `checkNoDeadEnd`, `checkFocusTrap`, `checkNoDestructiveOnOpen`, `overlaySuspicion`.
- `tests/interaction-ux/run.sh` **(new)** — pure-core unit tests (bash runner, `require()`s the module), mirroring `tests/ux-detectors/run.sh`.
- `skills/detecting-visual-ux/scripts/adjudicate.js` **(modify)** — add the `behavioral-observed` grade to `ORACLE_GRADES` + the grade case in `adjudicate()`.
- `skills/detecting-visual-ux/references/adjudication.md` **(modify)** — document the new grade.
- `tests/ux-adjudicate/run.sh` **(modify)** — add the `behavioral-observed` cases.
- `skills/detecting-interaction-ux/SKILL.md` **(new)** — the skill body: drive-the-sequence procedure on `walking-multistep-flows`, overlay-stack snapshot cadence, the two-criteria boundary, human-action gating, adjudication + code-localization escalation, the five invariants, honest coverage limit, ≥3 mini-evals.
- `scripts/skills.json` **(modify)** — register the new skill (npx install path).
- `docs/adr/0019-human-eye-ux-detection-engine.md` **(modify)** — implementation note: sub-plan B landed; C still deferred.
- `CONTEXT.md` **(modify)** — add `overlay stack` + `interaction invariant` glossary terms.
- `CLAUDE.md` **(modify)** — bump the skill count + list to include `detecting-interaction-ux`.

---

## Task 1: Overlay-stack detector + five invariant checkers

**Files:**
- Create: `skills/detecting-interaction-ux/scripts/overlay-stack.js`
- Test: `tests/interaction-ux/run.sh`

**Interfaces:**
- An **overlay descriptor**: `{id:string, role:string, ariaModal:boolean, zIndex:number, position:string, focusTrapped:boolean, parentId:string|null, present:boolean}`. A **snapshot** is an array of descriptors (the overlays visible at one moment).
- Produces (Tasks 2–3 rely on these):
  - `overlaySuspicion(detector, descriptor, evidence, rawSignal) -> {detector, axis:'ux-suspicion', overlayId, role, evidence, rawSignal}` (mirrors `ux-detectors.js`'s `suspicion()` but keyed on `overlayId` since overlays aren't a single element).
  - `checkStackIntegrity(before, afterOpenChild, childId) -> suspicion|null` — invariant 1: an overlay present in `before` is absent in `afterOpenChild` while `childId` is present → `interaction-overlay-destroyed`.
  - `checkReturnToContext(afterAction, expectedParentId) -> suspicion|null` — invariant 2: after an action completes, the expected parent overlay (or base context) is present and topmost; else `interaction-no-return`.
  - `checkNoDeadEnd(afterClose) -> suspicion|null` — invariant 3: after closing the child, at least one overlay OR the base context is present (not an empty dead-end); else `interaction-dead-end`.
  - `checkFocusTrap(stack) -> suspicion|null` — invariant 4: the topmost `ariaModal` overlay must be `focusTrapped`; a modal that isn't focus-trapped → `interaction-focus-untrapped`.
  - `checkNoDestructiveOnOpen(before, afterOpenChild) -> suspicion|null` — invariant 5: opening the child must not remove a NON-parent sibling overlay (a side effect beyond stacking) → `interaction-destructive-on-open`.

- [ ] **Step 1: Write the failing tests** (`tests/interaction-ux/run.sh`)

Mirror `tests/ux-detectors/run.sh` helpers (`check`, and a `NODE="${NODE:-node}"`; `call`/`field` running `node -e` against the module). Assertions (use JSON snapshot fixtures inline):

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/detecting-interaction-ux/scripts/overlay-stack.js"
NODE="${NODE:-node}"
PASS=0; FAIL=0
check(){ if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
# fieldc <fn> <jsonArgsArray> <key> -> result[key], "null" if result null
fieldc(){ "$NODE" -e 'const m=require(process.argv[1]);const r=m[process.argv[2]].apply(null,JSON.parse(process.argv[3]));process.stdout.write(r==null?"null":String(r[process.argv[4]]))' "$MOD" "$1" "$2" "$3" 2>/dev/null; }
callc(){ "$NODE" -e 'const m=require(process.argv[1]);const r=m[process.argv[2]].apply(null,JSON.parse(process.argv[3]));process.stdout.write(r==null?"null":JSON.stringify(r))' "$MOD" "$1" "$2" 2>/dev/null; }

# module loads under Node without a DOM
check "module loads" "$("$NODE" -e 'require(process.argv[1]);process.stdout.write("ok")' "$MOD" 2>/dev/null)" "ok"

# --- invariant 1: the sheet-stack bug (fixture #1) ---
# before: the deliverables LIST sheet is open. afterOpenChild: the NEW-DELIVERABLE form replaced it (list gone).
BEFORE='[{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true}]'
AFTER='[{"id":"dialog:New Deliverable","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true}]'
check "sheet-stack: parent destroyed -> interaction-overlay-destroyed" \
  "$(fieldc checkStackIntegrity "[$BEFORE,$AFTER,\"dialog:New Deliverable\"]" detector)" "interaction-overlay-destroyed"
# negative control: child STACKS on top of parent (both present) -> null
AFTER_OK='[{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true},{"id":"dialog:New Deliverable","role":"dialog","ariaModal":true,"zIndex":110,"position":"fixed","focusTrapped":true,"parentId":"dialog:Deliverables","present":true}]'
check "stacked correctly -> null" "$(callc checkStackIntegrity "[$BEFORE,$AFTER_OK,\"dialog:New Deliverable\"]")" "null"

# --- invariant 2: return-to-context ---
# after submitting the child, we should land back on the parent list. Empty stack = no return.
check "no return-to-context -> interaction-no-return" \
  "$(fieldc checkReturnToContext '[[],"dialog:Deliverables"]' detector)" "interaction-no-return"
check "returned to parent -> null" \
  "$(callc checkReturnToContext "[$BEFORE,\"dialog:Deliverables\"]")" "null"

# --- invariant 3: no dead-end ---
check "dead-end (empty after close) -> interaction-dead-end" \
  "$(fieldc checkNoDeadEnd '[[]]' detector)" "interaction-dead-end"
check "base context present after close -> null" \
  "$(callc checkNoDeadEnd "[$BEFORE]")" "null"

# --- invariant 4: focus-trap ---
UNTRAPPED='[{"id":"dialog:New Deliverable","role":"dialog","ariaModal":true,"zIndex":110,"position":"fixed","focusTrapped":false,"parentId":null,"present":true}]'
check "modal not focus-trapped -> interaction-focus-untrapped" \
  "$(fieldc checkFocusTrap "[$UNTRAPPED]" detector)" "interaction-focus-untrapped"
check "trapped modal -> null" "$(callc checkFocusTrap "[$AFTER]")" "null"

# --- invariant 5: no destructive-on-open (a NON-parent sibling vanished) ---
BEFORE2='[{"id":"dialog:A","role":"dialog","ariaModal":false,"zIndex":90,"position":"fixed","focusTrapped":false,"parentId":null,"present":true},{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true}]'
AFTER2='[{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true},{"id":"dialog:Child","role":"dialog","ariaModal":true,"zIndex":110,"position":"fixed","focusTrapped":true,"parentId":"dialog:Deliverables","present":true}]'
check "sibling A destroyed on open -> interaction-destructive-on-open" \
  "$(fieldc checkNoDestructiveOnOpen "[$BEFORE2,$AFTER2]" detector)" "interaction-destructive-on-open"

echo "interaction-ux: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/interaction-ux/run.sh` — Expected: FAIL (module missing).

- [ ] **Step 3: Write `overlay-stack.js`** (dual-mode, dependency-free)

```javascript
// overlay-stack.js — the interaction/behavioral UX family (family 9, ADR-0019 sub-plan B).
// Dual-mode like ux-detectors.js: browser DETECT extracts the overlay stack; pure cores
// check the five behavioral invariants against before/after snapshots and emit suspicions
// (adjudicated by detecting-visual-ux/scripts/adjudicate.js's `behavioral-observed` grade).
// A SUSPICION carries no verdict/confidence — the classifier assigns those. NO I/O.
(function () {
  'use strict';

  function overlaySuspicion(detector, descriptor, evidence, rawSignal) {
    return {
      detector: detector,
      axis: 'ux-suspicion',
      overlayId: descriptor ? descriptor.id : null,
      role: descriptor ? descriptor.role : null,
      evidence: evidence,
      rawSignal: rawSignal
    };
  }

  function byId(stack, id) {
    for (var i = 0; i < stack.length; i++) { if (stack[i].id === id && stack[i].present !== false) return stack[i]; }
    return null;
  }
  function present(stack) { var out = []; for (var i = 0; i < stack.length; i++) { if (stack[i].present !== false) out.push(stack[i]); } return out; }
  function topmost(stack) {
    var p = present(stack), best = null;
    for (var i = 0; i < p.length; i++) { if (best === null || (p[i].zIndex || 0) >= (best.zIndex || 0)) best = p[i]; }
    return best;
  }

  // Invariant 1: opening `childId` must NOT remove an overlay that was present before.
  function checkStackIntegrity(before, afterOpenChild, childId) {
    if (!byId(afterOpenChild, childId)) return null; // child didn't actually open — not this invariant's call
    var b = present(before);
    for (var i = 0; i < b.length; i++) {
      var parent = b[i];
      if (parent.id === childId) continue;
      if (!byId(afterOpenChild, parent.id)) {
        return overlaySuspicion('interaction-overlay-destroyed', parent,
          'overlay "' + parent.id + '" was present before opening "' + childId + '" but is gone after — child destroyed parent instead of stacking',
          parent.id + ' -> (destroyed by ' + childId + ')');
      }
    }
    return null;
  }

  // Invariant 2: after an action completes, the expected parent/base must be present.
  function checkReturnToContext(afterAction, expectedParentId) {
    if (byId(afterAction, expectedParentId)) return null;
    return overlaySuspicion('interaction-no-return', { id: expectedParentId, role: null },
      'after the action, expected context "' + expectedParentId + '" is not present — no return-to-context',
      'missing-return:' + expectedParentId);
  }

  // Invariant 3: after closing the child, the surface must not be an empty dead-end.
  function checkNoDeadEnd(afterClose) {
    if (present(afterClose).length > 0) return null;
    return overlaySuspicion('interaction-dead-end', { id: null, role: null },
      'after closing the child overlay, no overlay or base context is present — dead-end',
      'dead-end:empty-stack');
  }

  // Invariant 4: the topmost aria-modal overlay must be focus-trapped.
  function checkFocusTrap(stack) {
    var top = topmost(stack);
    if (!top || !top.ariaModal) return null;
    if (top.focusTrapped) return null;
    return overlaySuspicion('interaction-focus-untrapped', top,
      'topmost modal "' + top.id + '" is not focus-trapped — focus can escape behind the overlay',
      'focus-untrapped:' + top.id);
  }

  // Invariant 5: opening the child must not remove a NON-parent sibling overlay.
  function checkNoDestructiveOnOpen(before, afterOpenChild) {
    var afterIds = {}; var pa = present(afterOpenChild);
    for (var i = 0; i < pa.length; i++) afterIds[pa[i].id] = true;
    // the parent is whichever before-overlay the new child declares as parentId
    var childParent = null;
    for (var j = 0; j < pa.length; j++) { if (pa[j].parentId) { childParent = pa[j].parentId; break; } }
    var b = present(before);
    for (var k = 0; k < b.length; k++) {
      var o = b[k];
      if (o.id === childParent) continue;       // the parent legitimately may be covered, not this invariant
      if (!afterIds[o.id]) {
        return overlaySuspicion('interaction-destructive-on-open', o,
          'sibling overlay "' + o.id + '" (not the opener parent) disappeared when the child opened — destructive side effect',
          'destroyed-sibling:' + o.id);
      }
    }
    return null;
  }

  // Browser-only: extract the current overlay stack from the live DOM/accessibility tree.
  // Overlay = [role=dialog] / [aria-modal=true] / a position:fixed|absolute panel with a
  // high z-index. focusTrapped ~ the overlay contains the active element AND declares
  // aria-modal or a focus-trap sentinel. May MISS non-semantic overlays (plain divs) —
  // those fall through to the generative critic (layer 3, deferred sub-plan C).
  function extractOverlayStack() {
    var out = [];
    if (typeof document === 'undefined') return out;
    var nodes = document.querySelectorAll('[role="dialog"],[aria-modal="true"],.modal,.dialog,.sheet,.drawer,[data-overlay]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var cs = (typeof getComputedStyle !== 'undefined') ? getComputedStyle(el) : {};
      var role = el.getAttribute('role') || 'dialog';
      var name = el.getAttribute('aria-label') || (el.textContent || '').trim().slice(0, 40);
      var z = parseInt((cs && cs.zIndex) || '0', 10); if (!Number.isFinite(z)) z = 0;
      var active = document.activeElement;
      out.push({
        id: role + ':' + name,
        role: role,
        ariaModal: el.getAttribute('aria-modal') === 'true',
        zIndex: z,
        position: (cs && cs.position) || 'static',
        focusTrapped: !!(active && el.contains(active)) && (el.getAttribute('aria-modal') === 'true'),
        parentId: null, // set by the agent across the drive (the opener), not inferable from one snapshot
        present: true
      });
    }
    return out;
  }

  var api = {
    overlaySuspicion: overlaySuspicion,
    checkStackIntegrity: checkStackIntegrity,
    checkReturnToContext: checkReturnToContext,
    checkNoDeadEnd: checkNoDeadEnd,
    checkFocusTrap: checkFocusTrap,
    checkNoDestructiveOnOpen: checkNoDestructiveOnOpen,
    extractOverlayStack: extractOverlayStack
  };
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
  else if (typeof window !== 'undefined') { window.__overlayStack = api; }
})();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/interaction-ux/run.sh` → `interaction-ux: PASS=<n> FAIL=0`. `node --check skills/detecting-interaction-ux/scripts/overlay-stack.js`.

- [ ] **Step 5: Commit**

```bash
git add skills/detecting-interaction-ux/scripts/overlay-stack.js tests/interaction-ux/run.sh
git commit -m "feat(ux): overlay-stack detector + five behavioral invariant checkers (family 9)"
```

---

## Task 2: Extend the classifier with the `behavioral-observed` oracle grade

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/adjudicate.js`
- Modify: `skills/detecting-visual-ux/references/adjudication.md`
- Test: `tests/ux-adjudicate/run.sh`

**Interfaces:**
- Consumes: the `interaction-*` suspicions from Task 1.
- Produces: `oracleGradeFor('interaction-overlay-destroyed') -> 'behavioral-observed'`; `adjudicate(suspicion, oracleInputs)` for a `behavioral-observed` grade returns `failLow` (observed only) or `failHigh` when `oracleInputs.corroborated` is true (shared-state cause localized in code). Known-deliberate still short-circuits to `null`.

- [ ] **Step 1: Write the failing tests** (append to `tests/ux-adjudicate/run.sh`)

```bash
# --- behavioral-observed grade (interaction family, sub-plan B) ---
check "grade interaction-overlay-destroyed" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("interaction-overlay-destroyed"))' "$MOD")" "behavioral-observed"
check "behavioral observed-only -> fail low"  "$(field adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x->destroyed"},{}]' 'confidence')" "low"
check "behavioral observed-only -> fail verdict" "$(field adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x"},{}]' 'verdict')" "fail"
check "behavioral corroborated -> fail high" "$(field adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x"},{"corroborated":true}]' 'confidence')" "high"
check "behavioral known-deliberate -> null" "$(call adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x"},{"knownDeliberate":[{"detector":"interaction-overlay-destroyed","rawSignal":"x"}]}]')" "null"
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash tests/ux-adjudicate/run.sh` — Expected: FAIL on the behavioral cases (grade unknown → currently falls to `heuristic` → advisory, so `confidence`/`verdict` are wrong).

- [ ] **Step 3: Implement the grade** in `adjudicate.js`:

Add to `ORACLE_GRADES` (before the `overlap`/heuristic fallback):
```javascript
    ['interaction-', 'behavioral-observed'],
```
Add the case to `adjudicate()`'s switch (after `standards`):
```javascript
      case 'behavioral-observed':
        // An observed overlay-stack invariant violation IS a fail (the destruction is
        // objectively observed), but confidence is low until the shared open/route state
        // both overlays bind to is localized in code (spec §7). Distinct from 'heuristic'
        // (a mere suspicion → advisory): this is a real observed defect.
        return oracleInputs.corroborated
          ? failHigh('interaction', 'observed overlay-stack invariant violation, shared-state cause localized in code: ' + suspicion.detector)
          : failLow('interaction', 'observed overlay-stack invariant violation (' + suspicion.detector + ') — confidence low until the shared open/route state is localized in code');
```

- [ ] **Step 4: Document the grade** in `references/adjudication.md` — add `behavioral-observed` to the grade list: an observed behavioral-invariant violation → `fail @ FE` low (observed) → high (shared-state cause code-localized); note it is a VERDICT, unlike `heuristic` (advisory). Note `interaction-*` detectors carry this grade.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/ux-adjudicate/run.sh` → `FAIL=0` (all prior 31 + the new behavioral cases). `node --check skills/detecting-visual-ux/scripts/adjudicate.js`.

- [ ] **Step 6: Commit**

```bash
git add skills/detecting-visual-ux/scripts/adjudicate.js skills/detecting-visual-ux/references/adjudication.md tests/ux-adjudicate/run.sh
git commit -m "feat(ux): behavioral-observed oracle grade (observed invariant violation -> fail low, high on code-confirm)"
```

---

## Task 3: The `detecting-interaction-ux` skill body + registration

**Files:**
- Create: `skills/detecting-interaction-ux/SKILL.md`
- Modify: `scripts/skills.json`

**Interfaces:**
- Consumes: `walking-multistep-flows` (drive the sequence), `overlay-stack.js` (Task 1), `adjudicate.js` (Task 2), `ux-conventions.sh` (known-deliberate), the `human-action` gate (`checkpoint.sh`/`check-action-trace.js`, ADR-0015), `verifying-backend-persistence` (the functional-create sibling criterion).
- Produces: the agent procedure that drives an overlay sequence, captures the overlay stack between human-path act steps, checks the five invariants, adjudicates, and localizes the shared-state cause for the confidence upgrade.

- [ ] **Step 1: Write `SKILL.md`** (frontmatter `name: detecting-interaction-ux`, gerund, no "claude"; description ≤1024 chars starting "Use when …" — e.g. "Use when a criterion covers an overlay/sheet/drawer/modal interaction sequence — driving open→child→submit→close and holding an expectation across snapshots to catch a child overlay that destroys its parent, dead-ends the user, breaks focus-trap, or loses return-to-context; adjudicates observed destruction into fail@FE (low, or high once the shared open/route state is localized in code)."). Body < 500 lines, checklist-structured:

  1. **Plan the overlay sequence + the two criteria (spec §7 Q3).** Driving "add a deliverable" is TWO criteria sharing ONE driven session: the *functional-create* criterion (persists at N+1 — `verifying-backend-persistence`) and the *interaction-UX* criterion (overlay stack survived / return-to-context). Each rolls to its OWN verdict; the report shows two findings. The interaction-UX criterion is `human-action`-gated.
  2. **Drive the sequence on `walking-multistep-flows`, capturing the overlay stack between act steps.** Sequence: observe base → **act:** `browser_click` "open list" → **observe:** inject `overlay-stack.js` DETECT via `browser_evaluate` (READ-ONLY) → record snapshot `S0` (parent present) → **act:** `browser_click` "add / open child" → **observe:** DETECT → `S1` → **act:** `fill_form` + `browser_click` submit → **observe:** DETECT → `S2` → **act:** `browser_click` close → **observe:** DETECT → `S3`. The act clicks are UI-only human affordances (ADR-0015); the DETECT snapshots are read-only observe-phase captures. Set each child descriptor's `parentId` to the overlay that was topmost when it opened (the opener), tracked across the drive.
  3. **Check the five invariants** (via the Task-1 cores): (1) `checkStackIntegrity(S0, S1, childId)`; (2) `checkReturnToContext(S2, parentId)` after submit; (3) `checkNoDeadEnd(S3)` after close; (4) `checkFocusTrap(S1)`; (5) `checkNoDestructiveOnOpen(S0, S1)`.
  4. **Adjudicate + localize for the confidence upgrade.** Read the known-deliberate list (`ux-conventions.sh read`). For each suspicion, localize the two overlays to their controlling state in code (read-only): the tell for the sheet-stack bug is a **single shared `open`/route state both overlays bind to**. If found → `corroborated:true`; else `corroborated:false`. Call `adjudicate(suspicion, {corroborated, knownDeliberate})` (via `node -e` requiring `adjudicate.js`) → a `fail @ FE` (confidence verbatim) with the `reason` as the message + a screenshot, or `null` (deliberate/correct). If the agent reads the code and judges the behavior intentional (e.g. a wizard that deliberately replaces panels), record it: `ux-conventions.sh add <detector> <rawSignal>` (autonomous, no prompt).
  5. **Honest coverage limit.** The overlay-identification heuristic catches semantic overlays (`role=dialog`/`aria-modal`/high-z fixed panels/focus-trap). A **non-semantic overlay** (a plain `<div>` with no role) may be missed — it is NOT silently passed; it falls through to the generative critic (layer 3, deferred sub-plan C). State this.
  6. **Boundary (spec §8).** This criterion owns overlay/behavior faults only. Whether the deliverable actually persisted is the functional-create criterion's job (`verifying-backend-persistence`) — do not conflate.

- [ ] **Step 2: ≥3 mini-evals** (from the held-out real bugs + invariants; note held-out pair excluded from the recall metric — measured in deferred sub-plan C):
  - **I1 — sheet-stack (fixture #1, ADR-0019):** deliverables list sheet; opening the new-deliverable form replaces the list (parent gone in `S1`). `checkStackIntegrity` → `interaction-overlay-destroyed`; localize finds a single shared `open` state both sheets bind to → `corroborated:true` → `fail @ FE, high`.
  - **I2 — return-to-context:** after submitting the child, the UI lands on an empty surface instead of the parent list (`S2` missing the parent). `checkReturnToContext` → `interaction-no-return`; no shared-state cause found → `fail @ FE, low`.
  - **I3 — focus-trap:** a modal opens but focus can tab to the page behind it (`ariaModal:true, focusTrapped:false`). `checkFocusTrap` → `interaction-focus-untrapped` → `fail @ FE, low`.
  - (Negative control) a child overlay that correctly STACKS on the parent (both present in `S1`) → zero findings → the interaction-UX criterion is `pass`.

- [ ] **Step 3: Register the skill** in `scripts/skills.json` — add an entry `{"name":"detecting-interaction-ux","path":"skills/detecting-interaction-ux","category":"verification"}` (match the existing entries' exact key shape — READ the file first to copy the schema). `install.sh` globs `skills/*/` so no change there.

- [ ] **Step 4: Validate + gates.**

Run: `wc -l skills/detecting-interaction-ux/SKILL.md` (< 500); `python3 -c "import json;json.load(open('scripts/skills.json'))"` (valid JSON); `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (exit 0); the portability test; and confirm the skill frontmatter has only `name`+`description` with `name: detecting-interaction-ux`.

- [ ] **Step 5: Commit**

```bash
git add skills/detecting-interaction-ux/SKILL.md scripts/skills.json
git commit -m "feat(ux): detecting-interaction-ux skill (overlay-stack sequence, two-criteria boundary, human-action gated)"
```

---

## Task 4: ADR-0019 note + CONTEXT terms + CLAUDE.md skill count

**Files:**
- Modify: `docs/adr/0019-human-eye-ux-detection-engine.md`
- Modify: `CONTEXT.md`
- Modify: `CLAUDE.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: ADR-0019 implementation note** — extend the dated note: sub-plan **B (behavioral/interaction family) landed** — `skills/detecting-interaction-ux/` (the skill), `overlay-stack.js` (the five-invariant detector), and the `behavioral-observed` adjudication grade. Sub-plan **C** (generative critic layer 3 + accuracy-harness UI/UX taxonomy fixture + the ≥95%/≥90% measured gate, §11) remains deferred — state the recall gate is STILL not measured.
- [ ] **Step 2: CONTEXT.md terms** — add in the house format (bold term + definition + `_Avoid_:`): **Overlay stack** (the ordered set of on-screen overlays — dialog/sheet/drawer/modal — with parentage, tracked across an action sequence; a child must stack on its parent, not replace it) and **Interaction invariant** (one of the five behavioral rules — overlay-stack integrity, return-to-context, no-dead-end, focus-trap, no-destructive-on-open — whose observed violation is a `fail @ FE`, low until the shared-state cause is code-localized). Keep verdict/confidence/layer vocab intact.
- [ ] **Step 3: CLAUDE.md skill count** — update "There are 16 skills" → 17 and add `detecting-interaction-ux` to the enumerated list (the interaction/behavioral family). Update the header if it enumerates skills.
- [ ] **Step 4: Gates + commit**

Run: `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (exit 0).

```bash
git add docs/adr/0019-human-eye-ux-detection-engine.md CONTEXT.md CLAUDE.md
git commit -m "docs(ux): ADR-0019 note (behavioral family landed) + CONTEXT overlay-stack/interaction-invariant terms + skill count"
```

---

## Self-Review

**1. Spec coverage (§7 + §4 family 9).**
- Overlay/surface-stack modeling across a real action sequence → Task 3 drive procedure + Task 1 `extractOverlayStack`. ✅
- Overlay-identification heuristic (roles + high-z fixed + focus-trap) + honest may-miss-non-semantic → Task 1 `extractOverlayStack` + Task 3 Step 5. ✅
- Five-invariant catalog (integrity, return-to-context, no-dead-end, focus-trap, no-destructive-on-open) → Task 1 five checkers. ✅
- Adjudicate: observed-destruction → fail low → high on shared-state code-confirm → Task 2 `behavioral-observed` grade + Task 3 Step 4 localization. ✅
- Criterion boundary (two criteria, one session, two verdicts; interaction-UX is human-action) → Task 3 Step 1 + human-action gating. ✅
- Cross-spec: the critic's free exploration is read-only Arrange/observe; any mutation is a gated criterion → covered by the human-action gating + boundary note (Task 3). ✅
- **Deliberately NOT here (sub-plan C):** the generative critic (layer 3) itself, the accuracy-harness UI/UX taxonomy fixture, and the ≥95%/≥90% measured gate (§11) — called out in Global Constraints + the ADR note.

**2. Placeholder scan.** None — every step has exact paths, complete `overlay-stack.js` + the classifier grade + both test blocks, exact commands, and exact detector-id/expected strings.

**3. Type consistency.** The overlay descriptor `{id,role,ariaModal,zIndex,position,focusTrapped,parentId,present}` is identical across `extractOverlayStack`, the five checkers, and the test fixtures. Suspicion detector ids (`interaction-overlay-destroyed`/`-no-return`/`-dead-end`/`-focus-untrapped`/`-destructive-on-open`) all share the `interaction-` prefix that Task 2's `ORACLE_GRADES` maps to `behavioral-observed`. `adjudicate` returns the same `{verdict,suspectedLayer,confidence,family,reason}` | `{advisory}` | `null` shapes sub-plan A defined; the new grade uses the existing `failLow`/`failHigh` helpers. Verdict/confidence/layer vocab unchanged (no sixth verdict; `FE` only).

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-03-interaction-ux-family.md`. Execution: **Subagent-Driven Development** (fresh implementer per task + task-scoped spec+quality review + fix loop; final whole-branch review on the most capable model), per the autonomous `/loop` directive.
