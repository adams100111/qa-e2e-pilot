---
name: fanning-out-criteria
description: Use when the checklist produced by generating-qa-checklist contains criteria tagged independent/read-only or race, and you need to run those specific criteria in parallel across the driver pool. Implements the narrow opt-in fan-out path described in ADR-0003. Do NOT invoke for ordinary criteria — the vast majority run sequentially in driving-browser-qa without this skill. This is a v1.1 capability.
---

# Fanning Out Criteria

## Overview

**Default is sequential. Stop here and confirm you actually need this skill.**

Almost every criterion in a Run is ineligible for fan-out: criteria that write shared backend state, assert multiplicity (0/1/N), read back a prior write (baking), or form a multi-step flow are stateful and order-dependent. Running them in parallel across isolated sessions on a shared backend corrupts their results — the 0-state is only true before any create runs; baking reads back what a prior session wrote; downstream cascades are sequential by definition. ADR-0003 records this as deliberate, not an unfinished feature.

This skill applies only to the two narrow cases:
- Criteria tagged `independent: true` AND `read-only: true` in the checklist.
- Criteria tagged `race: true` (deliberate concurrency tests where shared-state contention is the point).

If none of the criteria in the current run carry those tags, use driving-browser-qa sequentially on one driver and skip this skill entirely.

## When to Use

- The checklist (from generating-qa-checklist) contains at least one criterion tagged `independent + read-only` or `race`.
- Pre-flight has already enumerated and pinged the driver pool (driving-browser-qa owns pre-flight).
- You need to decide which criteria fan out and which stay sequential before execution begins.

## Eligibility Decision List

Run this for every criterion before assigning it to a driver. Answer each question in order — stop at the first YES.

```
1. Does the criterion write ANYTHING to the shared backend?
   YES → INELIGIBLE. Keep sequential.

2. Does the criterion assert multiplicity (0, 1, or N count of an entity)?
   YES → INELIGIBLE. Keep sequential.
   (Multiplicity is ordered — 0-state is only true before any create.)

3. Does the criterion read back a result that a PRIOR criterion wrote?
   (Baking: the entity must exist before this criterion starts.)
   YES → INELIGIBLE. Keep sequential.

4. Is the criterion part of a multi-step flow or downstream cascade?
   YES → INELIGIBLE. Keep sequential.

5. Is the criterion tagged `race: true`?
   YES → ELIGIBLE (race path). Fan out deliberately — go to Step 5 below.

6. Is the criterion tagged BOTH `independent: true` AND `read-only: true`?
   YES → ELIGIBLE (read-only fan-out). Go to Step 3 below.

7. (None of the above matched, or you are uncertain.)
   → INELIGIBLE. Keep sequential. Correctness over speed.
```

**If in doubt on any question, the answer is INELIGIBLE.** The fallback is sequential. This is a gate, not a goal — most criteria will fail at question 1.

## The Process

### Step 1 — Audit the Checklist

- [ ] Read `.qa/runs/<run-id>/checklist.md`.
- [ ] For each criterion, apply the eligibility decision list above.
- [ ] Produce two lists:
  - `sequential-criteria`: everything that did not pass the eligibility test (the majority).
  - `fanned-criteria`: eligible criteria split into `read-only-pool` and `race-pool`.
- [ ] If `fanned-criteria` is empty, stop. Run all criteria sequentially via driving-browser-qa.

### Step 2 — Respect the Pool and Cap

- [ ] Read `drivers` and `maxParallel` from `.qa/config.json`.
- [ ] From the list of drivers, remove any that pre-flight marked unreachable.
- [ ] Count reachable drivers: `available = len(reachable_drivers)`.
- [ ] The concurrency cap is `min(maxParallel, available)`.
- [ ] Assign fanned criteria to drivers round-robin up to the cap. If eligible criteria outnumber the cap, queue the remainder and run them as earlier fanned criteria complete.
- [ ] Never assign more than one race-test pair to the same driver simultaneously — a race test already uses two sessions on coordinated drivers.

### Step 3 — Isolate Sessions (Read-Only Fan-Out)

For each `read-only` eligible criterion assigned to a driver:

- [ ] Open a **separate browser context** on that driver (use `browser_tabs` capability or the driver's session-spawn mechanism — each context is an isolated Session with its own cookies).
- [ ] Load the criterion's storageState into that context before navigating (same `auth.storageState` path as the sequential path — these are read-only sessions so sharing the auth file is safe).
- [ ] Run the criterion in its Session: navigate, snapshot (`browser_snapshot`), probe network (`browser_network_requests`), assert against the oracle.
- [ ] Do NOT write to backend state. If a step would write, stop: the criterion was mis-tagged. Mark it `error`, move it to `sequential-criteria`, and run it sequentially after the fan-out batch completes.
- [ ] After the criterion resolves, close the context and checkpoint the verdict via checkpointing-qa-memory. Evidence goes into the shared run dir: `.qa/runs/<run-id>/evidence/<criterion-id>/`.

### Step 4 — Sequential Criteria Run Normally

All criteria in `sequential-criteria` run after (or interleaved with, but never concurrent to) the fanned batch, using driving-browser-qa on the primary driver. The sequential path is the main path — do not let fan-out delay it.

### Step 5 — Run Race Tests Deliberately

A race test coordinates ≥2 sessions to act on the **same backend entity** at the same time. The goal is to prove the backend enforces a constraint — not to prove parallelism works.

- [ ] Identify the shared entity: the same record ID, same endpoint, same primary key.
- [ ] Open one Session per participant (at least 2), each with its own isolated browser context and its own storageState.
- [ ] Synchronize the trigger: both sessions must reach the "about to submit" state before either fires. Use a ready-gate approach — prepare each session independently (navigate, fill form, reach the final confirm/submit step), then trigger both within the same agent turn so they fire as close together as possible.
- [ ] Assert the correct outcome — pick exactly one from the criterion's oracle:
  - **Uniqueness / idempotency:** exactly one write succeeds; the duplicate is rejected (e.g. 409 Conflict, unique-constraint error, or idempotent no-op). Verify `browser_network_requests` on both sessions.
  - **Optimistic lock:** one session's write wins; the other receives a stale-version error or a conflict response.
  - **Last-write-wins:** both writes succeed but the final state reflects exactly one value (the later one). Bake the entity and assert the count/value is what the rule allows — not doubled, not torn.
- [ ] Bake the result. Hand the baking step to verifying-backend-persistence. Multiplicity must be exactly what the rule allows (e.g. count = 1, not 2). A duplicate entity is a fail, not a pass.
- [ ] Record which session "won" and which "lost" in the evidence. Both network responses are evidence.
- [ ] Checkpoint the verdict for the race criterion via checkpointing-qa-memory.

### Step 6 — Merge Results

After all fanned criteria and race tests complete:

- [ ] Collect every verdict (pass/fail/blocked/deferred/error) from fanned criteria.
- [ ] For each fanned criterion: confirm the verdict is internally consistent. If a read-only criterion returned data that implies a prior write existed when none should have, distrust the result — mark it `error` and re-run it sequentially.
- [ ] If any fanned criterion produced a verdict that contradicts a sequential criterion's oracle (e.g. a read-only criterion sees a count that a sequential criterion has not yet created), it ran at the wrong time or was mis-tagged. Re-run it sequentially after the sequential batch completes.
- [ ] Reconcile: the run's `checkpoint.json` must have one entry per criterion, regardless of which path it ran on. No criterion is allowed two entries.
- [ ] Update `run-manifest.json`: increment `criteria_done` for each resolved criterion.
- [ ] Hand all verdicts to writing-qa-reports at run close.

### Step 7 — Fall Back

At any point, if a fanned criterion's behavior is ambiguous:

- [ ] Stop the fanned session for that criterion.
- [ ] Move the criterion to `sequential-criteria`.
- [ ] Re-run it sequentially on the primary driver via driving-browser-qa.
- [ ] If it was already partially executed in the fanned session, discard that partial result — do not mix evidence from two execution paths.
- [ ] Checkpoint the verdict from the sequential run only.

Correctness over speed. A misclassified criterion that ran in parallel may have read stale state or produced a spuriously passing result. The sequential re-run is authoritative.

---

## Mini-Evals

### Eval 1 — Multiplicity criterion MUST stay sequential

**Given:** Criterion `C-003` is "assert 0 founders before any create, then 1 after one create, then 3 after three creates." The checklist has no `independent` or `read-only` tag on it (correctly — it writes via the UI).

**Do:** Apply the eligibility list. Question 1: writes backend state? YES (creates founders). INELIGIBLE. Question 2 (if you continued): asserts multiplicity? YES. INELIGIBLE.

Place `C-003` in `sequential-criteria`. Run it on the primary driver via driving-browser-qa: bake 0-state first (navigate to founders list, assert count = 0), then create, bake count = 1, then create two more, bake count = 3 exactly.

**Must not do:** fan `C-003` onto a second driver. A parallel session creating a founder would destroy the 0-state before the 0-state criterion runs, and would race the count to 2 or 4 instead of 3.

---

### Eval 2 — Legitimate read-only fan-out (2 drivers)

**Given:** Criteria `C-011` ("governance overview page renders correct share-class count badge, read-only") and `C-012` ("cap table PDF export link returns 200, no auth bypass, read-only") are both tagged `independent: true, read-only: true`. Two drivers are reachable; `maxParallel = 2`.

**Do:**
1. Apply the eligibility list to each: no writes, no multiplicity, no baking dependency, no multi-step flow, no race tag → both ELIGIBLE for read-only fan-out.
2. Assign `C-011` to Driver 1 and `C-012` to Driver 2.
3. Open an isolated Session (separate context) on each driver. Load `auth.storageState` into both.
4. Run each criterion in its own Session concurrently: `browser_snapshot` to capture the DOM, `browser_network_requests` to verify the HTTP status and response shape, assert against the oracle.
5. Neither session writes anything. Both sessions read from the shared backend simultaneously — fine because reads don't corrupt shared state.
6. Collect verdicts. Checkpoint both via checkpointing-qa-memory into the shared `.qa/runs/<run-id>/` directory.

**Must not do:** fan out `C-011` or `C-012` if either had a write step buried in its oracle (e.g. "click Export to generate the PDF" — that would be a write). If discovered mid-execution, stop and fall back to sequential.

---

### Eval 3 — Deliberate race test (double-submit / concurrent finalize)

**Given:** Criterion `C-015` is tagged `race: true`. Oracle: "Two sessions submit the governance finalize action simultaneously on the same project. Exactly one finalize succeeds (HTTP 200 + rows persisted). The second receives a 409 Conflict or an idempotent no-op (HTTP 200 with no duplicate rows). Final multiplicity: share classes = 2, founders = 3, board members = 2 — not doubled."

**Do:**
1. Eligibility: `race: true` → ELIGIBLE (race path). Proceed to Step 5.
2. Open Session A (Driver 1) and Session B (Driver 2). Each loads the same `auth.storageState` (both are the same user hitting the same project).
3. In Session A: navigate to the governance wizard final step. Do NOT click Finalize yet.
4. In Session B: navigate to the same wizard final step. Do NOT click Finalize yet.
5. Both sessions are now at the trigger point. Fire both finalize clicks in the same agent turn (back-to-back tool calls without waiting for responses between them).
6. Collect responses: call `browser_network_requests` on both sessions. Check status codes. One session must receive 200; the other must receive 409 (or an idempotent 200 with no additional rows).
7. Bake the result: navigate to the holdings/detail view and call verifying-backend-persistence. Assert share classes = 2, founders = 3, board members = 2 exactly. If the count is doubled (4, 6, 4) → fail, suspected layer: `service` (no idempotency guard or optimistic lock).
8. Record both network responses as evidence. Checkpoint `C-015` via checkpointing-qa-memory with the winning session's verdict.

**Correct outcome:** exactly one write wins; the second is rejected or idempotent; multiplicity is not doubled. A doubled count is a real bug, not a test artifact.

---

## Reference

| Sibling skill | What it owns |
|---|---|
| generating-qa-checklist | Emits the `independent`, `read-only`, `race` tags you consume here |
| driving-browser-qa | Per-session browser mechanics; pre-flight; sequential criterion execution |
| verifying-backend-persistence | Baking (read-back + multiplicity + cross-tenant) after any write, including race-test baking |
| checkpointing-qa-memory | One shared run dir (`.qa/runs/<run-id>/`); one checkpoint per criterion regardless of execution path |

| Browser capability | Used for |
|---|---|
| `browser_tabs` / separate session contexts | Opening an isolated Session per fanned criterion |
| `browser_snapshot` | Capturing DOM state as evidence in each session |
| `browser_network_requests` | Verifying HTTP status and response shape; race-test winner/loser evidence |
| `browser_wait_for` | Settling after mutations before reading responses |
