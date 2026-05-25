---
name: analyzing-feature-ui
description: Use when starting a QA Run to build the UI surface map of a target feature — enumerating routes, interactive elements, dialogs, forms, fields, and per-surface states (empty/loading/error/populated/multi-row) via accessibility snapshots and static code analysis. Distinguishes app-shell chrome from the feature under test and cross-references the backend repo (by role) to map each surface/action to its endpoint, source-of-truth model, service, and migration. Emits surface-map.json that feeds generating-qa-checklist. v1.1 skill (auto-analysis); v1 ingested a hand-authored checklist instead.
---

# Analyzing Feature UI

## Overview

Build the UI surface map of the target feature before writing any criterion. The surface map is your contract: every route, every interactive element, every state a surface can be in, and the backend wiring behind each action. Without it you miss stale routes, legacy URLs in quick-actions, and state-dependent gates — exactly the class of bugs that appear invisible until the screen is in the wrong state.

This is a **v1.1 skill** (auto-analysis). v1 required a hand-authored checklist; v1.1 derives the checklist input from code + live snapshots.

Outputs: `.qa/runs/<run-id>/surface-map.json` — human-reviewable, consumed by generating-qa-checklist.

## When to Use

- At the start of every Run, before generating the checklist or executing any criterion.
- When re-running after a significant feature change that may have altered routes or endpoints.
- When the feature spans multiple routes or sub-tabs with distinct states.

## The Process

### Step 1 — Static Route + Selector Inventory

Run `scripts/index-routes.sh` against the frontend repo (and backend repo when configured):

```
bash skills/analyzing-feature-ui/scripts/index-routes.sh
```

The script reads `.qa/config.json` repos by role (`frontend`, `backend`, `reference`) and emits a compact JSON inventory to stdout. Redirect it:

```
bash skills/analyzing-feature-ui/scripts/index-routes.sh > .qa/runs/<run-id>/route-inventory.json
```

Review `route-inventory.json`:

- [ ] Identify every route path that belongs to the target feature (filter by prefix or module name).
- [ ] Flag any route that LOOKS removed but still appears in the index — these may still render under a legacy path (bug class: stale route, e.g. `/cap-table` redirecting nowhere → still showing old panel).
- [ ] Note backend endpoints discovered alongside frontend routes — seed the backend-mapping columns in the surface map.

### Step 2 — Navigate and Snapshot Every Surface

For each route in the feature scope:

1. Navigate to the route (browser_navigate).
2. Take an accessibility snapshot (browser_snapshot) — use accessibility refs for all subsequent interactions; they survive React re-renders better than CSS selectors.
3. Take a screenshot (browser_take_screenshot) for visual evidence.

For each snapshot:

- [ ] List every interactive element: buttons, links, form fields, selects, dialogs, tabs, pagination controls.
- [ ] Record each element's **label**, **role**, and **target** (href, route, or action). Missing or legacy targets catch quick-action bugs (bug class: element pointing to legacy URL, e.g. `/old-cap-table` instead of `/governance`).
- [ ] Note elements that belong to **app-shell chrome** (nav bar, global header, sidebar, breadcrumbs, notifications bell) vs elements that belong to the **feature under test**. Mark shell elements `"chrome": true` in the surface map — checklist generation will skip them.

### Step 3 — Enumerate Per-Surface States

For each surface (route + sub-tab combination):

- [ ] **empty** — no data rows, setup not completed, or tenant has no records; check if a gate or onboarding prompt appears.
- [ ] **loading** — trigger a slow network / observe the skeleton/spinner; confirm the surface doesn't crash during load.
- [ ] **error** — simulate or observe a 4xx/5xx; confirm an error state is rendered, not a blank screen.
- [ ] **populated** — at least one record exists; this is the happy path most tests run against.
- [ ] **multi-row** — multiple records to test ordering, pagination, aggregations, and computed totals.

State-dependent gates — features that behave differently depending on which state the surface is in — must each appear as a distinct surface entry in the map (bug class: setup gate hidden in empty state, visible in populated state).

To force states:

- Navigate to the route on an empty project (if the config provides one) and snapshot.
- Navigate on a populated project and snapshot.
- If direct API seeding is enabled (`allowApiWrites: true` in config, plus the disposable-env marker), use probing-apis-through-browser to seed and reset state.

### Step 4 — Separate Chrome from Feature

After snapshotting all surfaces, review the element lists and mark:

```
"chrome": true    // app-shell: nav, sidebar, header, help icon, account menu
"chrome": false   // feature: everything scoped to the feature route
```

Apply the mark in the surface-map.json `elements[]` array. The sibling skill generating-qa-checklist will filter `chrome: true` elements out of criterion generation — keep them in the map for completeness but do not generate criteria for them.

### Step 5 — Map Each Surface/Action to the Backend

For each non-chrome element that triggers a backend call (form submit, delete, status toggle, export, bulk action):

1. Open the network panel (browser_network_requests) during the action (or read from a prior network capture).
2. Record the HTTP method + path under `backend.endpoint`.
3. Cross-reference the backend repo (role: `backend`): search for the route definition and the model/service/migration it touches.
   - Grep the backend repo: `grep -r "<path-fragment>" <backend-path>/routes/`
   - Locate the controller method; note the model class name → `backend.model`.
   - Locate the most recent migration for that table → `backend.migration`.
4. Record these in the surface map entry. Mark `"confidence": "low"` if no network call was observable (e.g. local computed-only action).

### Step 6 — Emit surface-map.json

Write `.qa/runs/<run-id>/surface-map.json` with this exact shape:

```json
{
  "runId": "<run-id>",
  "feature": "<feature name>",
  "generatedAt": "<ISO-8601>",
  "surfaces": [
    {
      "route": "/governance",
      "kind": "list",
      "states": ["empty", "populated", "multi-row"],
      "chrome": false,
      "elements": [
        {
          "label": "Add Shareholder",
          "role": "button",
          "target": "/governance/shareholders/new",
          "chrome": false,
          "backend": {
            "endpoint": "POST /api/shareholders",
            "model": "Shareholder",
            "migration": "2024_01_15_create_shareholders_table",
            "confidence": "high"
          }
        },
        {
          "label": "Main Nav",
          "role": "navigation",
          "target": null,
          "chrome": true,
          "backend": null
        }
      ]
    }
  ],
  "legacyRoutes": [
    {
      "route": "/cap-table",
      "status": "stale — no redirect found; still renders old panel",
      "action": "flag for bug log"
    }
  ],
  "notes": []
}
```

Fields:
- `surfaces[].kind` — one of: `list`, `detail`, `form`, `dialog`, `tab`, `dashboard`.
- `surfaces[].states[]` — subset of: `empty`, `loading`, `error`, `populated`, `multi-row`.
- `elements[].backend` — null for chrome or purely navigational elements.
- `legacyRoutes[]` — routes found in static index that are not in the active nav; record disposition.

Save the file and confirm the path in your response. Pass the path to generating-qa-checklist.

## Checklist Summary

- [ ] Run `index-routes.sh`; review route inventory for stale/legacy paths.
- [ ] Navigate + snapshot every feature route; list interactive elements with labels, roles, targets.
- [ ] Enumerate empty / loading / error / populated / multi-row states per surface.
- [ ] Mark chrome vs feature elements on every surface.
- [ ] For each backend-triggering action, grep the backend repo and record endpoint + model + migration.
- [ ] Emit surface-map.json at `.qa/runs/<run-id>/surface-map.json`.
- [ ] Hand surface-map.json path to generating-qa-checklist.

## Mini-Evals

**Eval 1 — Stale legacy route (bug #13 class)**
Given: `index-routes.sh` emits `/cap-table` as a discovered route; the feature nav shows only `/governance`.
Catch: The script flags `/cap-table` in `legacyRoutes[]`. Step 1 review finds no redirect. The evaluator navigates to `/cap-table` (browser_navigate), takes a snapshot (browser_snapshot), confirms the old panel still renders, and logs a bug: "legacy route `/cap-table` renders stale panel — redirect missing."
Without the static route inventory this route is never visited and the bug is missed entirely.

**Eval 2 — Quick-action pointing to legacy URL (bug #14 class)**
Given: The governance overview surface has a "Manage Cap Table" quick-action button. Snapshot shows `href="/cap-table"` instead of `href="/governance"`.
Catch: Step 2 records `"target": "/cap-table"` for that element. The surface map flags it as a legacy target. The evaluator navigates the link (browser_navigate), confirms it lands on the wrong panel, and logs a bug: "quick-action links to legacy URL `/cap-table`."
Without recording element targets from the snapshot, the button looks correct visually but leads to the wrong destination.

**Eval 3 — State-dependent gate (bug #3 class)**
Given: The "Setup Governance" gate is only visible when the project has no shareholders. On a populated project the gate is hidden and the normal panel renders; on an empty project the gate appears and blocks the form.
Catch: Step 3 forces both states — snapshot on empty project, snapshot on populated project. The surface map records two entries for `/governance`: one with state `empty` (elements include `SetupGate` button) and one with state `populated` (elements include `AddShareholder` button). The checklist generator creates distinct criteria for each state. Without the state enumeration, only the populated happy path is tested and the gate behavior is never verified.

**Eval 4 — Backend endpoint mismatch**
Given: The "Transfer Shares" button on a shareholder detail surface triggers `POST /api/share-transfers`. The backend repo grep finds the route is handled by `ShareTransferController` but the model is `EquityTransfer`, with a migration named `2023_11_create_equity_transfers_table`.
Catch: Step 5 records `"model": "EquityTransfer"` and `"migration": "2023_11_create_equity_transfers_table"` in the surface map element. When verifying-backend-persistence later reads back the transfer, it knows which table to inspect and which column names the migration defined — preventing a false pass from reading the wrong model.
