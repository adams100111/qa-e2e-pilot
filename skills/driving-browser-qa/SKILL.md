---
name: driving-browser-qa
description: Use when executing a QA criterion that requires driving the browser — navigating pages, filling forms, clicking elements, and reading the resulting DOM, network responses, and console output to produce a verdict with evidence. Covers driver selection (managed Playwright vs. attended CDP), the snapshot-act-wait loop, React input mechanics, RTL/Arabic text interaction, and the pre-flight gate. Pairs with verifying-backend-persistence for baking steps and probing-apis-through-browser for network probing.
---

# Driving Browser QA

## Overview

Drive the browser as a controlled instrument: snapshot before every act, wait after every mutation, and treat console exceptions and unexpected HTTP errors as findings — not noise. The browser surface is evidence, not the oracle.

## When to Use

- Executing any criterion step that requires navigating, clicking, typing, or reading the UI.
- Setting up a session before a baking or probing step hands off.
- Any time a UI action precedes a backend verification.

## Pre-Flight Gate (run once per Run)

Run `scripts/preflight.sh` before the first criterion. It reads `.qa/config.json` and:

1. Checks app liveness at `baseUrl` (aborts if unreachable or non-2xx/3xx).
2. Verifies `auth.storageState` file exists and warns if older than 30 minutes.
3. Enumerates every driver in the pool; resolves its platform-preset CDP endpoint and pings it; warns on unreachable (does not abort — the criterion that needs it will be blocked).
4. Detects a cross-origin `apiOrigin` and notes that CORS+credentials will be needed for probing.
5. Captures the running build/deploy ID (Vercel `x-vercel-deployment-id` header, Next.js `buildId`, or ETag) and compares to the previous run — warns if unchanged so you know whether a fix is actually live.

**Abort conditions:** app down, `baseUrl` missing, `auth.storageState` path configured but file absent.  
**Never print secrets.** Sessions persist via `storageState`, not credentials in logs.

## Driver Selection

Read `drivers` from `.qa/config.json`. Default driver is the **managed Playwright MCP browser** (preset `managed`; zero-config, any OS). Attended CDP — attaching to your logged-in Chrome — is opt-in via a platform preset:

| Preset | CDP endpoint resolved |
|---|---|
| `managed` | Managed Playwright (no CDP) |
| `windows+wsl` | `http://host.docker.internal:9222` |
| `windows` | `http://localhost:9222` |
| `wsl` | nameserver IP from `/etc/resolv.conf`:9222 |
| `linux` | `http://localhost:9222` |
| `mac` | `http://localhost:9222` |

**Sequential by default.** Only criteria tagged `independent`/`read-only` in the checklist, or deliberate race tests, fan out across the pool. Never parallelize write criteria.

Reference browser tools by **capability** — the Playwright MCP tool name is in parentheses so a new driver drops in by changing only the config.

## Session Lifecycle

1. Load `auth.storageState` into the session context before the first navigation.
2. Run all steps for one criterion inside a single isolated browser context.
3. Persist the final `storageState` back to disk after the last criterion that modifies auth.
4. Close the context (take snapshot, close tab — `browser_close`) after the criterion resolves.

## The Per-Step Loop

For **every** step inside a criterion, follow this exact sequence:

1. **Snapshot first.** Take an accessibility snapshot (`browser_snapshot`) to get live element refs. Use refs for all interactions — refs survive React re-renders better than CSS selectors in a long flow. Fall back to screenshot (`browser_take_screenshot`) only for visual/layout/math checks where pixel evidence is needed.
2. **Act.** Click (`browser_click`), type (`browser_type`), fill form (`browser_fill_form`), select (`browser_select_option`), or inject a script (`browser_evaluate`) using the ref or selector from step 1.
3. **Wait.** After every mutation, wait for the expected next state before asserting (`browser_wait_for`). Never assert immediately after an act — React renders are async.
4. **Read diagnostics.** After the wait resolves:
   - Read console messages (`browser_console_messages`). A JavaScript exception is a **finding** — record it immediately (catches bug class: page crash on load, e.g. `p.map` on a bad envelope).
   - Read network requests (`browser_network_requests`). An unexpected 4xx or 5xx on any mutation request is a **finding** (catches bug class: endpoint 400/422/500 on wizard steps, wrong route names).
5. **Assert.** Compare what you observe to the oracle (the checklist's expected value/rule), not to what the backend code says.
6. **Snapshot again** to capture post-act DOM state as evidence.

## React Controlled Inputs

Typing directly into a React-managed `<input>` often does not update component state — the value appears in the DOM but React discards it on the next render. Use `scripts/react-set-input.js` instead:

```
// Inject via browser_evaluate, passing (selector, value):
// Returns the element's resulting .value for immediate verification.
```

The script uses the native HTMLInputElement/HTMLTextAreaElement/HTMLSelectElement prototype value setter to bypass React's synthetic tracking, then dispatches bubbling `input` and `change` events. Verify the returned value equals what you passed before proceeding.

## Finding Clickable Elements by Text (RTL/Arabic)

`scripts/click-by-text.js` finds a `button`, `a`, or `[role=button/link/menuitem/option]` by trimmed visible text, stripping Unicode bidi control characters (U+200B–U+200F, U+202A–U+202E, U+2066–U+2069) so Arabic/RTL labels match correctly. Inject via `browser_evaluate`.

**Critical: verify where a click lands, not just that it succeeded.** The script returns `{ href, role, textContent, landed }` before and after the click. Check `href` against the expected URL path — a button that looks correct but links to a legacy route is a finding (bug class: quick-action links to `/cap-table` instead of `/governance`).

## Checking for Client-Side Exceptions

After every act+wait cycle, call `browser_console_messages` and scan for entries with `type: "error"` or messages containing `Uncaught`, `TypeError`, `cannot read`, or `undefined is not`. Treat any such entry as a criterion **finding** with suspected layer `FE`, record the message verbatim, and include it in the bug log. Do not dismiss an exception because the UI "looks fine."

## Checking Network Responses

After every mutation (form submit, wizard step, save), call `browser_network_requests` and find the matching XHR/fetch request. Check:

- Status code: 4xx = likely a client/validation bug; 5xx = likely a server bug. Both are findings.
- Response body: read it with `browser_network_request` if the status is unexpected. The body often names the exact field or constraint that failed.
- Route path: confirm the request went to the expected endpoint. A 404 or a request to the wrong path (e.g. `/init` vs `/initialize`) is itself the finding.

## Iteration Cap

If a criterion does not resolve after **three UI iterations** (snapshot → act → wait cycle), stop. Record verdict `blocked` if the environment is preventing progress, or `error` if the tooling broke. Write what you observed (last snapshot ref, last console messages, last network status) as evidence. Do not loop forever — a stuck criterion costs more tokens than it saves.

## Multiplicity Discipline

When a criterion requires a 0/1/N multiplicity check:
- **0-state:** assert before any create criterion runs (ordering matters — once records exist, 0-state is gone).
- **1:** create exactly one entity, bake it (read back from backend), assert count = 1.
- **N:** create additional entities, bake the list, assert count = N and correct ordering/shape.

Do not rely on a "success toast" as evidence of persistence. That is not a pass.

## Build Freshness Check

When a fix is expected to be deployed, compare the build ID captured in pre-flight to the previous run's recorded ID (`.qa/runs/.last-build-id`). If unchanged, warn the team before spending tokens on a retest — the fix may not be live. The preflight script does this automatically; surface the warning in the run report.

---

## Bundled Scripts

| Script | Purpose |
|---|---|
| `scripts/react-set-input.js` | Set value on React-controlled input; dispatches native events |
| `scripts/click-by-text.js` | Find + click by visible text; LTR/RTL-safe; returns href for route verification |
| `scripts/preflight.sh` | App liveness + driver ping + auth check + build-ID capture |

---

## Mini-Evals

### Eval 1 — Page crash on list load (bug #1: `p.map` on bad envelope)

**Situation:** The agent navigates to the templates list page and the page appears to load but the list is empty.  
**The skill should:** After the navigation + wait, call `browser_console_messages` and find `TypeError: p.map is not a function` (or similar). Record it as a finding with suspected layer `FE`, verdict `fail`, and note that the envelope shape from the API did not match the component's expected array. Do not mark the criterion pass because the list is visually empty — that absence is not a confirmed 0-state until the console is clean.

### Eval 2 — Wrong route name causes 500 (bug #5: `/init` vs `/initialize`)

**Situation:** The agent submits the wizard's first step and the UI shows a generic error or spinner that never resolves.  
**The skill should:** Call `browser_network_requests` after the submit wait. Find the POST request. Read its status (500) and path (`/init`). Record a finding: suspected layer `route`, the request landed on a non-existent or wrong route. Include the path and status in the bug log. Do not retry the step — record `fail` and move on.

### Eval 3 — Legacy URL quick-action (bug #14: overview links to wrong page)

**Situation:** The agent is verifying that the overview's "Manage" quick-action navigates to the governance module.  
**The skill should:** Inject `scripts/click-by-text.js` via `browser_evaluate` with label "Manage". Before calling `.click()` on the element, inspect the returned `href`. If it resolves to `/cap-table` instead of `/governance`, record a finding immediately — the link is wrong regardless of where it navigates. If navigation happens, check `landed` as secondary evidence. Verdict: `fail`, suspected layer `FE`.

### Eval 4 — React input value not retained (bug class: wizard saveStep 422)

**Situation:** The agent fills a business-area field in the wizard, proceeds to the next step, and the backend returns 422 (validation error: field required).  
**The skill should:** On the previous step, inject `scripts/react-set-input.js` for the business-area input, verify the returned value matches the intended input. If the returned value is empty or stale, note that the native-setter approach was needed and retry. If the 422 persists after confirming the value was set, record the network response body as evidence and mark the finding at suspected layer `service` (the backend validation rule).

### Eval 5 — Stale build, fix not deployed (build-freshness check)

**Situation:** A sub-cent precision bug (bug #9: `decimal(…,2)` truncation) was patched and deployed. The agent is re-running the precision criterion.  
**The skill should:** In pre-flight, compare the build ID from the `x-vercel-deployment-id` header to `.qa/runs/.last-build-id`. If they match, warn in the run report that the build ID is unchanged and the fix may not be live before running the criterion. If the criterion then passes, note the build ID in the evidence; if it fails despite the same build ID, that is expected (fix not deployed).
