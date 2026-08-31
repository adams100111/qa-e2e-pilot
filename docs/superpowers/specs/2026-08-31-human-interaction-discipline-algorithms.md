# Algorithms — Human-Interaction Discipline (companion to the design)

Precise decision procedures behind the design. Each algorithm is deterministic where it can be, and every judgment-based step carries a **precision guard** (it must not fire on a clean/negative-control case). Feeds writing-plans.

---

## A1. Staying in the human-tester role — Workaround Detection (the core algorithm)

**Guarantee:** the *action-under-test* was performed only through genuine human affordances. Enforced by **three independent checks, ANDed** (defense in depth — no single check can be fooled into a false green).

### Inputs
`action-trace` = ordered `[{tool, target, phase, payload?}]` for the criterion (**agent-authored** — supplies phase tags), plus **state fingerprints** captured at each observation point, plus **`session.md`** = Playwright MCP's `--save-session` transcript (**server-authored, independent** — the ground truth of which tool calls actually ran; the agent cannot omit from it).

### Check 0 — Independent session-log reconciliation (closes the self-report hole)
Before the trace-based checks, reconcile the agent's `action-trace` against `session.md` for the criterion's act-window (bounded independently by the first-observation timestamp, so a mislabeled phase can't shrink the window):
```
calls_gt   = tool calls in session.md within [act_window_start, act_window_end]
calls_self = act-phase entries in action-trace
for c in calls_gt:
    if c is a mutating/workaround call (evaluate-set / run_code_unsafe / route / direct write)
       and c not in calls_self:
        → "concealed workaround" → violation   # took a shortcut, then didn't record it
```
Check 0 makes Checks 1–3 tamper-evident: the agent can no longer pass by *omitting* the shortcut from its own trace, because `session.md` records it regardless. Checks 1–2 then classify the calls that ARE present; Check 3 catches mutations with no attributable call at all.

### Check 1 — Tool-class gate (syntactic, cheap)
Partition the tool set:
```
ACT_UI      = {click, type, fill_form, press_key, select_option, hover, drag, file_upload}
OBSERVE     = {snapshot, console_messages, network_request(s), take_screenshot, evaluate[read-only]}
MUTATE_NONUI= {run_code_unsafe, direct-API/DB-write, evaluate[mutating],
               route[intercepting the backend-under-test]}   # stubbing the tested backend fakes a pass
```
For every call with `phase == "act"`: if `class ∈ MUTATE_NONUI` → **violation** (unless the criterion carries `nonUiActionReason`). A `browser_route` that intercepts the **backend-under-test** is a violation (it manufactures the response the oracle should judge); a route that stubs only a **non-under-test** third-party/CDN dependency is allowed (and is additionally caught if misused by the bake read-back showing real state ≠ the faked UI — see A2/A6).

### Check 2 — Evaluate-payload static lint (classify dual-use `browser_evaluate`)
`browser_evaluate` is read XOR mutate. Lint the injected source for **mutation signatures**; presence of any ⇒ MUTATE:
```
assignment to  .value | .checked | .selectedIndex | .innerHTML | .textContent  (on a control/input)
call to        .click() | .submit() | .dispatchEvent( | .setSelectionRange(
storage write  localStorage.setItem|removeItem|clear ; sessionStorage.set* ; document.cookie =
network write  fetch(… method∈{POST,PUT,PATCH,DELETE}) | XMLHttpRequest.open(<write>)
framework      store.dispatch( | setState( | app-global mutators
```
Otherwise (only `getComputedStyle`, `*.getItem`, `querySelector*` reads, `return <expr>`) ⇒ READ (OBSERVE, allowed). A MUTATE evaluate in the act phase → **violation**. (This is a whitelist-of-reads / blacklist-of-writes lint over the trace's recorded payloads — deterministic.)

### Check 3 — Differential state-change attribution (semantic backstop — catches a mislabeled trace)
The strongest, tool-agnostic check; defeats an agent that mutates via evaluate but *labels* it "observe".
```
fingerprint S = hash{ persisted backend read-back (localStorage/API), current route, key DOM signals }
for each interval [obs_i → obs_{i+1}]:
    Δ = diff(S_i, S_{i+1})                     # a real mutation happened iff Δ ≠ ∅
    if Δ ≠ ∅ and no ACT_UI call in the interval whose target/effect plausibly explains Δ:
        → "unattributed mutation" → violation   # state changed with no genuine UI action
```
State changed without a human action ⇒ it came from a non-UI path ⇒ workaround, regardless of how the trace was labeled.

### Verdict
`pass` on a `human-action` criterion is valid **iff `Check0 ∧ Check1 ∧ Check2 ∧ Check3`** (or a logged `nonUiActionReason`, which flips confidence→low and records the reason). Check 0 reconciles against the independent `session.md` (ground truth of what ran); Checks 1–2 are static lints over the calls; Check 3 is the semantic net for unattributed mutations. Check 0 is what makes the rest tamper-evident — without it the agent grades its own homework. This quartet is *the algorithm that keeps the agent in role.*

---

## A2. UI-impossible decision procedure (→ verdict)

To perform action `A` needing affordance-spec `⟨role, label|testid, expected-effect⟩`:
```
E = visible interactive elements (from observe-round domDigest.interactive)
a = match(E, affordance-spec)
if a == ∅                              → UI-IMPOSSIBLE(missing)        → fail @ FE (high)
if a.disabled and no human unlock here → UI-IMPOSSIBLE(disabled)       → fail @ FE (high)
perform A via ACT_UI on a
if interaction throws / no-ops AND spec expects an effect
                                       → BROKEN-HANDLER (console err)  → fail @ FE (high)
if state changed (A completed):
       oracle_satisfied(observed) ?   → pass  :  fail @ localized-layer
if control REJECTED the input:
       spec_expects_rejection ?        → pass (correct-rejection) : fail @ FE (should-accept)
```
Every leaf is a verdict. The **oracle** distinguishes *UI-impossible* (bug) from *correct-rejection* (pass) — the agent never decides that itself.

---

## A3. Human-eye objective detectors (deterministic + precision-guarded)

**Contrast (WCAG 2.x SC 1.4.3/1.4.11).** For each visible text node with non-empty trimmed text:
```
fg = resolved color ; bg = alpha-composite of ancestor backgrounds up to first opaque
L(c) = 0.2126·f(R)+0.7152·f(G)+0.0722·f(B)   # f = sRGB→linear
ratio = (max(Lfg,Lbg)+0.05)/(min(Lfg,Lbg)+0.05)
large = fontSize≥24px or (≥18.66px and bold) ; threshold = large ? 3.0 : 4.5
flag if ratio < threshold
guard: skip hidden/0-size/opacity-0 text and fg==bg  → N2's ~17:1 clean button passes untouched
```
**Overflow/clipping.** el with `overflow∈{hidden,clip}` or fixed max-dim AND data-bearing text:
`clipped = scrollWidth>clientWidth+ε ∨ scrollHeight>clientHeight+ε`. Guard: a truncated *value* (number) is a bug; a labeled control with a `title` tooltip is a lesser/advisory finding.

**Target-size (WCAG 2.2 SC 2.5.8).** interactive+visible el: `r=getBoundingClientRect(); flag if r.width<24 ∨ r.height<24`. Guard: inline-in-sentence-link exception; default strict otherwise.

**Accessible-name + console-probe.**
`name = first-nonempty[aria-labelledby→text, aria-label, <label>, alt, title, trimmed textContent]`.
interactive el with empty `name` and not `aria-hidden`/decorative → missing-name. Icon-only control → **click-probe** then re-observe `console[]` for a thrown error (U4's dynamic half).

Every detector emits `{selector, wcagRef, measured, threshold}` → `fail @ FE, confidence:low`. **Precision is a gate metric:** the negative-control seeds must yield zero findings.

---

## A4. Subjective human-eye — multimodal scored audit (advisory only)

```
screenshot(surface @ viewport) [+ each responsiveMatrix entry for viewport-sensitive dims]
for D in {visual-hierarchy, alignment/grid, spacing-rhythm, color-harmony,
          affordance-clarity, empty/error-state-quality, cross-surface-consistency}:
    (score∈1..5, evidence-anchor selector/region) = multimodal_read(screenshot, D)
    if score < 3 and anchor ≠ ∅:  emit ADVISORY{D, score, anchor}
    if anchor == ∅:               discard            # precision guard — no vibes, must point at pixels
```
Never a verdict/layer (ADR-0007). Same threshold+evidence discipline as A3, applied to judgment dimensions.

---

## A5. Frontier/round engine — HITL topological rounds (the "grilling" algorithm, made exact)

Decision graph `G=(nodes=decisions, edges=prereqs)`. Kahn-style waves with human confirmation:
```
settled = ∅
loop:
    frontier = { n ∈ G : prereqs(n) ⊆ settled ∧ n ∉ settled }
    if frontier == ∅: break
    present frontier as NUMBERED items, each with recommendedDefault(n) = strongest auto-signal + source
    answers = wait()                       # facts auto-discovered; only decisions asked
    settled ∪= answers
    if an answer edits a settled node: unsettle its dependents        # recompute
    if rounds > budget: settled ∪= recommendedDefault(remaining); log-assumption; break   # never block
```
Role case: wave 1 = roles → wave 2 (unblocked) = credentials → wave 3 = scope. **Testable properties** (the design's §2F tests): (a) credentials never surface before roles settle; (b) every frontier item has a default; (c) editing recomputes; (d) budget-exceeded auto-settles + logs, never blocks.

---

## A6. Verification algorithms (existing — referenced, unchanged)
- **Baking:** UI-write → observe read-back → assert NOT-NULL shape → multiplicity {0,1,N} (ordered, 0 first) → reconcile counts → cross-tenant read-back = absence.
- **Independent recompute:** oracle value (spec/domain, never the backend formula) vs {UI, API, DB} within tolerance → localize divergence across FE-format / API-serialization / service-formula / DB-precision.
- **Scoring:** strict `seedId`/judge attribution (keyword never credits); `recall = caught⁺/planted⁺`; `precision = TP/(TP+FP-over-negative-controls)`; gate = per-axis thresholds. This is what proves the above actually work.

---

## A7. How the algorithms compose per criterion
```
arrange()                                  # setup (not under test)
act():   perform action via ACT_UI only    # A1 records the trace
observe(): bake + recompute + A3 detectors + A4 audit    # read-only
verdict = A2 decision procedure            # UI-impossible? correct-rejection? downstream?
record-evidence(bake|computed|probe|action-trace)
checkpoint … pass --kinds …,human-action   # gate runs A1's Check0∧1∧2∧3 (Check0 = session.md reconciliation) → reject if workaround
```
The invariant "act like a human, observe like a machine" is not a slogan — it is A1 (enforcement) + A2 (verdict) + A3/A4 (human eye) + A5 (how roles/scenarios are chosen), each with an explicit precision guard, all provable on the fixture.
