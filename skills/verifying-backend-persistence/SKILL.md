---
name: verifying-backend-persistence
description: Use after ANY UI write in a criterion to prove the data actually persisted — "a green toast is not a pass." Read the written entity back from the backend (a list/detail VIEW snapshot, an API response body, or an in-page authenticated fetch), confirm every required/NOT-NULL field saved non-null and at the right shape, force multiplicity 0/1/N on repeatable entities (ordered — the 0-state runs first), reconcile counts, and read back as a DIFFERENT tenant to assert cross-tenant absence. Baking, not optimistic UI. Hand numeric recompute to verifying-computed-logic.
---

# Verifying Backend Persistence

## Overview
A green toast is not a pass. **Baking** = reading persisted state back out of the **backend** after a UI write, to confirm it actually saved with the right **shape** (every required field non-null) and **multiplicity** (the count). Optimistic UI and a cached list are NOT a read-back — you must hit the backend again.

## When to Use
- A criterion includes any write: create, edit, delete, finalize, approve, submit.
- A repeatable entity needs a 0/1/N count forced and verified.
- You must prove cross-tenant isolation (a write in tenant A must be ABSENT in tenant B).
- Any time the only evidence so far is a toast, a spinner that resolved, or an optimistic row.

This is a **STEP** inside a criterion — it rolls into the single verdict and names the suspected layer on failure. Pairs with **driving-browser-qa** (does the write), **probing-apis-through-browser** (the under-the-UI read path), and **verifying-computed-logic** (owns the math; hand numeric recompute there).

## What counts as a real read-back (and what does NOT)
| NOT a read-back | A real read-back (baking) |
|---|---|
| Success toast / green flash | Navigate AWAY then to the list/detail VIEW and `browser_snapshot` |
| Optimistic row that appeared instantly | Read the API response body for a list/detail GET (`browser_network_request`) |
| The same cached list you already had open | In-page authenticated read with session cookies (`browser_evaluate` fetch, READ-ONLY) |
| The mutation's own 200 response | A *separate* GET that re-fetches from the DB |

Rule of thumb: if the bytes you are reading never left the browser, it is not baking. Force a fresh fetch — reload the route, or issue a new GET. A 200 on the *write* tells you the request was accepted, not that the row persisted with valid columns (bug #7 returned a clean-looking flow yet rows violated NOT-NULL).

## The Checklist: plan → read-back → reconcile (turn each into a todo)

### 1. Plan (before the write)
- [ ] Name the **entity** and the **fields** that must persist — including every **NOT-NULL / required** column. Get these from the **oracle** (the checklist's expected shape) and, where you need exact column names/precision, from the **backend repo** (`.qa/config.json` → `repos[].role == "backend"`): read the migration/schema for required columns, enums, `decimal(p,s)` scale.
- [ ] State the **expected count delta** (e.g. +1 founder; finalize → 2 share classes, 3 founders, 2 board members).
- [ ] Decide the **read-back path** up front: which VIEW (list/detail route) or which API GET, and how you'll authenticate it (storageState cookies).
- [ ] If a 0-state applies, schedule it FIRST (multiplicity is ordered — see below).

### 2. Read-back (after the write + a wait)
- [ ] Wait for the write to settle (`browser_wait_for`), then re-fetch from the backend by at least one of:
  - **VIEW:** navigate to the list/detail route and `browser_snapshot` (forces a fresh page load + GET).
  - **API body:** read the list/detail GET response (`browser_network_request` to read a response body) — catches a UI that hides what the API actually returned.
  - **In-page read:** `browser_evaluate` to `fetch()` the read endpoint with the session's cookies (`credentials: 'include'`), READ-ONLY. Never use a write verb here. Cross-origin reads need the CORS/credentials capability detected at preflight; if unavailable, fall back to the VIEW path.
- [ ] Capture the read-back as evidence (snapshot ref or response JSON). This is the proof, not the toast.

### 3. Reconcile (judge against the oracle)
- [ ] **Shape:** the entity exists AND every required field is non-null and well-typed. A row that exists but has a NULL in a NOT-NULL column is the exact way **bug #7** hid. Check each required field explicitly, not just "a row came back."
- [ ] **Multiplicity:** the count matches — 0 before any create, exactly 1 after one create, exactly N after N creates. N must be **exactly N** — not N−1 (a silent drop), not N+1 (a duplicate write). Verify the related/nested counts too (finalize must read back 2 share classes / 3 founders / 2 board members — all of them).
- [ ] **Feed/coverage:** when a write should fan out to a log or feed, bake the feed and confirm it covers every expected entity type (the activity log had to read back **7 entity types**).
- [ ] **Counts + numbers:** confirm counts here; for numeric math (ownership %, vesting accrual, `amount = shares × price` within tolerance) hand the recompute to **verifying-computed-logic** — this skill proves it PERSISTED and at the right COUNT.
- [ ] **Cross-tenant:** re-run the read-back as a DIFFERENT tenant's session and assert the data is **ABSENT** (bug #12: a draft leaked across tenants). Absence in tenant B is part of the pass, not a separate nicety.

## Multiplicity is ORDERED (ADR 0003 — do not fan out)
The 0-state is only true **before** any create criterion runs. Run the sweep **sequentially on one driver**, in order:
`assert 0 → create 1 → read back == 1 → create more → read back == N`.
Never fan 0/1/N across drivers/sessions — a parallel create destroys the 0-state and races the count. Baking and 0-1-N criteria stay sequential by default.

## Verdict: fail vs blocked vs error vs deferred
- **fail** — you read the backend and the data is wrong: missing row, NULL in a required column, count off (N−1 / dup), or it leaked cross-tenant. This is a real bug → bug-log entry with the **suspected layer**.
- **blocked** — a precondition outside this step stopped the read-back: env/app down, auth/storageState missing or expired, a prerequisite create criterion failed so there's nothing to bake. Re-runnable; not a bug.
- **error** — our tooling broke mid-read (the read endpoint path was misconfigured in our harness, the MCP read call threw). Our fault, not the app's.
- **deferred** — you deliberately did not perform a read-back you'd planned (e.g. no API read route this run, cross-tenant session unavailable, allowApiWrites off so you couldn't set up the N case). State the reason. **deferred ≠ blocked ≠ error.** Never fake a pass from a toast — defer honestly instead.

## Writes for setup are gated
You bake by READING. If you must seed the N case via a direct API write, that is gated behind `allowApiWrites: true` AND the `seedableEnvMarker` (disposable env). Default OFF — prefer creating through the UI. Probing/baking itself is read-only.

## Worked micro-examples

### Flagship: finalize → NOT-NULL violation (bug #7)
- **Plan:** finalize persists holdings rows; required columns include `shareClass` and `ownershipPercentage` (both NOT-NULL per the backend migration). Expected: 2 share classes, 3 founders, 2 board members all read back with those fields set.
- **Write:** click Finalize. UI shows a clean, green-ish flow — no error.
- **Read-back:** navigate to the holdings/detail VIEW (`browser_snapshot`) and read the holdings GET body (`browser_network_request`).
- **Reconcile:** rows are MISSING (or present with NULL `shareClass`/`ownershipPercentage`). Persistence did NOT happen despite the happy UI. → **fail**, suspected layer: `DB` (NOT-NULL constraint violation on write). The toast lied.

### Multiplicity sweep: founders 0 → 3 (ordered)
- **0:** before any create, bake the founders list → assert exactly 0 (empty state). Run this FIRST.
- **1:** create one founder, wait, re-fetch the list → assert exactly 1, required fields non-null.
- **N:** create two more, re-fetch → assert exactly **3** — not 2 (a silent drop = fail @ persistence), not 4 with a repeated name (a duplicate write = fail). Verify shape on each.
- Stay sequential on one driver — fanning these out would race the count and destroy the 0-state.

### Activity log coverage (7 entity types)
- **Plan:** after the governance actions, the activity feed must log all 7 entity types.
- **Read-back:** load the feed VIEW and snapshot, and/or read the feed API body.
- **Reconcile:** count distinct entity types in the feed; if only 5 appear, two writes never logged → **fail**, suspected layer depends on where the type is dropped (read the backend to localize). A subset is not a pass.

### Cross-tenant isolation (bug #12)
- **Write:** create a draft in tenant A; confirm it bakes in A (present, shape correct).
- **Read-back as tenant B:** switch to tenant B's session/storageState and re-fetch the same list/route.
- **Reconcile:** tenant A's draft MUST be absent in B. If it appears → **fail**, suspected layer: `service` (missing tenant filter on the query). The tenant leak is in the query/service, not the schema. Presence-in-A AND absence-in-B together make the pass.

### Optimistic UI is not a pass
- **Write:** create an entity; the row appears instantly (optimistic) and a toast fires.
- **Trap:** asserting on that instant row = no backend was hit.
- **Do:** reload the route (fresh GET) or issue a separate read; if the row vanishes on reload, the write silently failed → **fail**, not pass.

## Mini-Evals (given → catch)

1. **Given** a Finalize action that returns a clean, green-ish flow, **catch** bug #7 by baking the holdings VIEW + API body and finding the rows missing / NULL in NOT-NULL `shareClass` & `ownershipPercentage` → fail @ `DB`. (NOT caught if you accept the toast or the write's own 200.)
2. **Given** "create 3 founders" after a 0-state, **catch** a silent drop or duplicate by reading back the list and asserting the count is **exactly 3** — flag 2 (drop) or 4-with-a-repeat (dup) as fail; and run the 0→1→N sweep sequentially so the ordered 0-state isn't destroyed by a parallel create.
3. **Given** a draft created in tenant A, **catch** bug #12 by re-fetching the same route as tenant B and asserting the draft is ABSENT → fail @ tenant scoping if it shows.
4. **Given** an activity feed that should cover 7 entity types, **catch** a 2-type gap by baking the feed and counting distinct types (5 ≠ 7) → fail; a partial feed is not a pass.
5. **Given** an optimistic row + toast on create, **catch** a silent write failure by forcing a fresh backend GET (reload route / new fetch) — if the row disappears it never persisted → fail, not pass.
6. **Given** the app is down or storageState is expired when you go to read back, **do not** call it fail — record **blocked** (re-runnable); and if you simply have no read route this run, record **deferred** with a reason rather than faking a pass from the toast.
