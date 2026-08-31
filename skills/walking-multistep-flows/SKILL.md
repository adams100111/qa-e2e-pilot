---
name: walking-multistep-flows
description: Use when a criterion covers a wizard, multi-step form, or state-machine flow — mapping its steps and gate conditions, filling only required fields, verifying per-step persistence before advancing, confirming the terminal state transition, and testing resume-from-draft. Catches save failures, silent step-ID loss, and finalize actions that advance the UI without actually persisting the backend state.
---

# Walking Multistep Flows

## Overview

A multi-step wizard is ONE criterion. Its steps are the verification units, but they roll into a single verdict. Never let a successful HTTP status or a "next screen" count as proof — the step saved, the state advanced, and the destination view is populated from the backend must all be confirmed independently.

Pair with **driving-browser-qa** for browser mechanics (snapshot-act-wait loop, React input handling, network reading), **verifying-backend-persistence** for every per-step baking call, and **verifying-computed-logic** for any gate predicate or business-rule outcome.

## When to Use

- Executing any criterion that drives a wizard, stepped form, or named-state machine from start to terminal action.
- Re-entering a partially-completed flow to verify resume-from-draft behavior.
- Confirming a finalize/submit action truly transitions the backend state (not just the UI).

---

## The Process

### Step 1 — Map the flow before touching the browser

Before opening the browser, enumerate in your criterion notes:

1. List every **step** (named states, e.g. `BUSINESS_INFO → SHARE_CLASSES → FINALIZE`).
2. For each step, record **required** vs optional fields. Do not fill optional fields unless the criterion explicitly tests them.
3. Identify the **gate** that enables the "Next / Continue" button or route transition for each step. State what the gate checks (field not empty, API response flag, backend `status`, etc.).
4. Name the **terminal action** (finalize, submit, publish) and the **expected outcome**: the state the backend must be in, the route the user must land on, and the data the destination view must display.
5. Note any **idempotency constraint** (re-submitting a step must not duplicate a record).

This map is the oracle for the rest of the walk. Write it down; do not keep it in working memory.

### Step 2 — Fill required-only, then advance; watch gates, toasts, and diagnostics after every step

Use the **observe-round** from driving-browser-qa (ADR-0006) for each step — one structured observe call per round, not six. `scripts/observe.js` (driving-browser-qa) is installed once per session; do not re-derive a separate loop per wizard step.

For each step in order:

1. Observe (`browser_evaluate` → `__qaObserve(...)`) to identify the current step from `domDigest` and get selectors (`data-testid`/label) for the fields and gate control.
2. Fill **required fields only** using React-safe input mechanics (see driving-browser-qa) — a separate act call per field. Verify the returned value matches what you passed before proceeding.
3. Click the gate control (Next / Continue / Save) — a separate act call. After clicking, call `browser_wait_for` for the expected next state — still a separate call.
4. Re-observe (`__qaObserve`) immediately after the wait. The returned payload already carries everything since step 1's round:
   - `console[]`: a JS error is a finding even if the UI looks fine.
   - `network[]`: find the save/advance mutation. Check:
     - **Status code.** 4xx = client/validation bug; 5xx = server bug. Both are findings. Record the path and status verbatim.
     - **Route path.** Confirm the request landed on the expected endpoint (e.g. `/initialize` not `/init`). A mismatch is itself the finding.
     - **Response body.** `network[]` carries method/url/status/ok only — if the status is unexpected, read the body with the separate, targeted `browser_network_request` call. It often names the exact failing field or constraint. This targeted read is not optional just because the round is consolidated — see driving-browser-qa's no-evidence-regression guard.
5. If the step returned a non-2xx, record a finding (bug, suspected layer), mark the step failed, and stop here — do not advance. The criterion verdict is `fail`; name the step.
6. If 2xx, proceed to Step 3 before marking the step done or advancing to the next step.

> **Toasts are not verdicts.** A green toast signals a request was sent; it does not prove the backend persisted the data. Do not count a toast as a pass.

### Step 3 — Verify per-step persistence (bake before advancing)

After every step that writes data, hand off to **verifying-backend-persistence** before moving to the next step:

1. Read the persisted state from the backend at the correct multiplicity (0/1/N).
2. Confirm the step's data is present in the response, including any **ID or foreign key** the next step will rely on (e.g. `setupId`, `shareClassId`).
3. Confirm the flow's **state machine marker** advanced (e.g. `status: "BUSINESS_INFO_COMPLETE"`, or the next step is now unlocked). A 201 with the right shape but a missing or null `id` is a silent failure — the next step will use a stale or null reference and stall later.

If persistence fails here, mark the step `fail` and stop advancing. The criterion verdict is `fail`; name the step and the missing field.

### Step 4 — Execute the terminal action and verify the real state transition

The finalize/submit action is the riskiest step: the UI almost always advances first.

1. Execute the terminal action via the browser. Wait for the expected redirect or success state (`browser_wait_for`).
2. Read network diagnostics as in Step 2.
3. **Do not stop here.** Even a 201 on the terminal action is not a pass. You must verify:
   - [ ] The **backend state flag** flipped to the terminal value (e.g. `status: "COMPLETE"`, `is_setup: true`). Bake it via **verifying-backend-persistence**.
   - [ ] Any **gate** that the terminal state should open or close now reflects the new state (e.g. the setup gate no longer traps the user; the governance module is unlocked).
   - [ ] The **redirect** actually happened — the URL or route changed to the expected destination.
   - [ ] The **destination view** is populated from backend data (re-observe; confirm `domDigest` key fields are not empty, default, or stale from the previous run). A blank or error state on the destination is a finding.
   - [ ] Dependent entities that the terminal action should have created are present (e.g. holdings, share positions). A NOT-NULL violation or missing dependent record means the finalize did not fully persist — even though the state flag flipped.
4. If all four sub-checks pass, record the criterion verdict `pass`.
5. If any sub-check fails, verdict is `fail`; name the step (`terminal action — holdings not persisted`).

### Step 5 — Resume-from-draft and idempotency

After the forward walk, verify two behaviors in a second browser pass:

**Resume:**
1. Navigate to the wizard URL for a partially-completed draft (stop after any non-terminal step during the forward walk, note the URL/ID).
2. Confirm the wizard reopens at the correct step, with previously-entered data pre-populated.
3. Confirm advancing again from that step does not corrupt prior steps.

**Idempotency:**
1. Re-submit a completed step (or replay the save network request using `browser_network_request`).
2. Bake the backend again. Confirm the record count did not change (no duplicate created) and the data was not corrupted.
3. If re-submission duplicates a record, verdict is `fail`; name the step and multiplicity (`step 2 — re-submit creates duplicate share class`).

If these paths were not walked this run, mark them **deferred** with reason. `deferred` is honest non-verification. Do not fake a pass.

---

## Verdict Assignment

The entire wizard is **one criterion**; all steps roll into one verdict.

| Situation | Verdict |
|---|---|
| All steps saved, state transition confirmed, destination populated | `pass` |
| Any step returns 4xx/5xx, data not saved, or state did not advance | `fail` — name the step |
| Terminal action 2xx but dependent entities missing / gate did not flip | `fail` — name step as `terminal action` |
| Environment blocked progress (app down, auth lost, driver unreachable) | `blocked` |
| Our tooling broke (MCP timeout, snapshot failed, script error) | `error` |
| Path deliberately not walked this run | `deferred` (state the reason) |

**Stalled wizard:** If the wizard is stuck on a step with no error shown (spinner, no transition, no console error, no network request), treat it as `blocked` if the environment is the likely cause, or `fail` if a prior baking check showed the step ID/state never advanced. Record the last `domDigest`, last `console[]`, and last `network[]` from the observe-round as evidence. Do not loop more than three times without a new observable state change (see driving-browser-qa iteration cap).

On `fail`, always name the suspected step and the suspected layer — one of the canonical set `FE | route | service | migration | DB` (see CONTEXT.md).

---

## Checklist (copy per run)

```
[ ] 1. Mapped steps, required fields, gates, terminal action, expected outcome
[ ] 2. Step N — filled required-only; gate clicked; console clean; network 2xx; route correct
    (repeat for each step)
[ ] 3. Step N — baked; ID/state present; state marker advanced
    (repeat for each step)
[ ] 4. Terminal action — 2xx; state flag flipped; gate updated; redirect happened; destination populated; dependent entities present
[ ] 5. Resume-from-draft confirmed (or deferred: <reason>)
[ ] 6. Idempotency confirmed (or deferred: <reason>)
[ ] Criterion verdict: pass | fail | blocked | deferred | error
[ ] On fail: step name + suspected layer recorded
```

---

## Mini-Evals

### Eval 1 — Step returns 2xx but no setupId in the response (bug #11: silent stall)

**Given:** The wizard's `/initialize` endpoint returns HTTP 201 with a response body, the UI advances to step 2, and no error appears in the console or as a toast.

**Catch it:** After the 201, hand off to **verifying-backend-persistence**. Read the persisted record from the backend and check for `setupId` (or the equivalent FK the next step needs). If `setupId` is null or absent, the step silently failed to link its record. The next step's save will 422 or 500 on a missing required relation. Record finding: `step 1 — setupId null after 201`; verdict `fail`, suspected layer `DB`. Do not advance to step 2.

### Eval 2 — Finalize returns 201, UI redirects, but dependent entities were not created (bug #7: holdings NOT-NULL violation)

**Given:** The terminal finalize action returns HTTP 201, the UI redirects to the governance overview, and the state flag reads `COMPLETE`.

**Catch it:** Even though the redirect happened, bake the dependent entities (e.g. initial holdings, share positions). If the holdings table is empty or the query returns a NOT-NULL constraint error, the finalize only partially committed. Record finding: `terminal action — holdings not persisted`; verdict `fail`, suspected layer `DB`. A 201 on the terminal action is not a pass until dependents are confirmed.

### Eval 3 — Save step returns 422 because React input was not committed (bug #6: saveStep 422)

**Given:** The agent fills a business-area field in the wizard via a standard type call, the UI shows the value, and clicking Next triggers a POST that returns 422 (field required).

**Catch it:** On the failing step, use `browser_evaluate` to inject `react-set-input.js` (see driving-browser-qa). Verify the script's returned `.value` matches the intended input. If the returned value was empty, the React-controlled input discarded the native keystroke — the 422 was caused by an empty field reaching the backend despite the visible text. Re-fill using the script, confirm the returned value, then re-submit. If 422 persists after confirmed value, re-observe and find the entry in `network[]`; read the response body via the separate `browser_network_request` call and record the exact failing field.

### Eval 4 — Wrong route causes 500 on wizard init (bugs #5 and #10: `/init` vs `/initialize`)

**Given:** The wizard's first save (or a business-area bind call) shows a spinner that never resolves and no explicit error toast.

**Catch it:** Re-observe (`__qaObserve`) immediately after the wait timeout. Find the POST entry in `network[]`. If the url is `/init` instead of `/initialize`, or any variant that returns 404/500, record finding: route mismatch; verdict `fail`, suspected layer `route`. Do not retry; record the exact path and status code in the bug log and stop the criterion.

### Eval 5 — Re-submitting a completed step creates a duplicate share class (idempotency)

**Given:** The agent re-enters the wizard on step 2 (share classes) after completing it and clicks Save again (simulating a double-submit or browser back+forward).

**Catch it:** After the re-submission, hand off to **verifying-backend-persistence** and read the share classes with multiplicity N. If the count increased from 1 to 2, the endpoint is not idempotent. Record finding: `step 2 — re-submit duplicates share class, count = 2`; verdict `fail`, suspected layer `DB`. Note the multiplicity in the bug log.
