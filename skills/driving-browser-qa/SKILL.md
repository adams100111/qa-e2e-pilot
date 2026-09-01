---
name: driving-browser-qa
description: Use when executing a QA criterion that requires driving the browser — navigating pages, filling forms, clicking elements, and reading the resulting DOM, network responses, and console output to produce a verdict with evidence. Covers driver selection (managed Playwright vs. attended CDP), the snapshot-act-wait loop, React input mechanics, RTL/Arabic text interaction, and the pre-flight gate. Pairs with verifying-backend-persistence for baking steps and probing-apis-through-browser for network probing.
---

# Driving Browser QA

## Overview

Drive the browser as a controlled instrument: observe before every act, wait after every mutation, and treat console exceptions and unexpected HTTP errors — both surfaced automatically in the observe payload — as findings, not noise. The browser surface is evidence, not the oracle.

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

Reference browser tools by **capability** — the Playwright MCP tool name is in parentheses so a new driver drops in by changing only the config. For the exact capability→tool mapping per driver (Playwright/CDP, Stagehand, browser-use) and which drivers lack the **diagnostic tier** (`evaluate`, console, network response body) the differentiators need, see [`references/driver-capabilities.md`](./references/driver-capabilities.md). Put any criterion whose verdict depends on baking / API reconciliation / probing on a driver with the diagnostic tier (Playwright/CDP); if a configured driver lacks a needed capability, record that step `blocked` — never a faked pass.

## Interaction Discipline (ADR-0015)

The agent acts as a human tester and never works around the UI to pass a criterion — see
[`references/interaction-discipline.md`](./references/interaction-discipline.md) for the
full Arrange/Act/Assert tool matrix, the UI-impossible→`fail@FE` decision procedure, the
reconciliations of `react-set-input.js`/`click-by-text.js`/the F4 opt-out, and the driver
rules (locator fallback order, `browser_route` governance, origin lists, web-first
waiting). In one paragraph: on the **act** phase, only human-path tools
(`browser_click`/`type`/`fill_form`/`press_key`/`select_option`/`hover`/`drag`/
`file_upload` + real navigation) or a **read-only** `browser_evaluate` are allowed — a
`browser_evaluate` that mutates (`.value =`, `.click()`, `.dispatchEvent(`, a storage/API
write) on the act path is a workaround, gate-rejected by `checkpointing-qa-memory`'s
`human-action` evidence kind unless the criterion carries a `nonUiActionReason`.
Read-only `browser_evaluate` is always OBSERVE and always allowed, on any phase — baking,
the observe-round, and the UX detectors all depend on it and are never flagged.

### Driver launch + per-criterion delta-slice

Launch the managed Playwright MCP driver with **`--save-session`**. It writes generated
Playwright code to a SINGLE per-run `session.md` in the MCP output dir (default
`./.playwright-mcp/session.md`) — every criterion's calls are appended to the same file.
**`session.md` records Playwright CODE, not MCP tool names** (e.g.
`await page.locator('#add').click();`), so `scripts/parse-session-log.js` classifies each
block by code pattern into `{class, mutating, code}` — the classifier that bridges the two
representations (agent-reported tool calls vs. the independent code log).

Because the file is per-run, not per-criterion, each criterion must be **sliced out of it**:

1. **Before** a `human-action` criterion's act phase, snapshot the baseline:
   `N = parse-session-log.js(session.md).length`.
2. **After** the act, this criterion's calls are the delta:
   `sessionCalls = parse-session-log.js(session.md).slice(N)`.
3. Under ADR-0003 sequential execution exactly one criterion acts at a time, so the delta
   is exactly this criterion's calls.
4. Pass that slice — plus the phase-tagged `steps` (including each evaluate step's
   `payload`) — to `record-evidence.sh action-trace --steps <json> --session-calls <json>`,
   and copy `session.md` into the run dir for audit.

For a **tagged-parallel fan-out criterion** (the rare non-sequential case, see
`fanning-out-criteria`), launch that criterion with its OWN `--output-dir` so its
`session.md` is naturally scoped instead of delta-sliced.

## Session Lifecycle

1. Load `auth.storageState` into the session context before the first navigation.
2. Run all steps for one criterion inside a single isolated browser context.
3. Persist the final `storageState` back to disk after the last criterion that modifies auth.
4. Close the context (take snapshot, close tab — `browser_close`) after the criterion resolves.

## The Observe-Round

Per ADR-0006, the old six-call-per-step sequence (`browser_snapshot` → act → `browser_wait_for` →
`browser_console_messages` → `browser_network_requests` → `browser_snapshot`) is replaced by **one
structured observe call per round**. Acts stay separate calls; waits stay separate calls. Target
**~2 calls per step** (observe + act, plus a wait when the act mutates state) instead of ~6.

**Install once per session.** Right after loading `auth.storageState` and the first navigation,
inject `scripts/observe.js` via `browser_evaluate`. It is idempotent (`window.__qaObserveInstalled`
guard) — re-injecting it at the top of every criterion is a safe no-op. On install it patches
`console.error`/`warn`, `window.onerror`, `unhandledrejection`, `fetch`, and `XMLHttpRequest` to
buffer entries; it is read-only and never issues a request of its own.

**REQUIRED — after ANY navigation, re-inject before re-observing (binding).** The interceptors
`observe.js` installs live on the current document's `window`. A full-page `browser_navigate`, a
click that triggers a full page load (not a same-document SPA `pushState`), a reload, or a
server-side redirect all give the new document a **fresh `window`** — the previous interceptors,
`window.__qaObserveInstalled`, and `window.__qaObserve` are gone. A round called against the new
document without re-injecting throws `__qaObserve is not defined`, and — worse — every console
error and every network request that fired **during the load itself** (before any interceptor
could re-attach) is captured by nothing: a 4xx/5xx on the navigating request or a load-time crash
is silently lost. SPA in-page routing (`pushState`/`replaceState`, no full load) does not reset
`window` and is unaffected. After any qualifying navigation, in this order:
1. **Re-inject `scripts/observe.js` as the FIRST action on the new document**, before any other
   observe/act. It is self-healing — the tail of the script checks
   `typeof window.__qaObserve !== 'function'` and re-runs the (idempotent) installer before
   invoking the round, so this call both re-installs and returns the first post-nav round payload
   in one `browser_evaluate` call. It never throws on a document it has never run on.
2. **Immediately also call the driver-backed `browser_console_messages` and
   `browser_network_requests` MCP tools** — these are backed by the Playwright driver itself, not
   in-page JS, so they **survive navigation** and are the **source of truth for the load window**:
   every console error and every request (including the navigating document request and anything
   fired by inline `<script>`/early page code) that happened before step 1's interceptor could
   possibly attach. The in-page `observe.js` buffer is per-document and can only ever see what
   happened *after* it (re-)installs; it is not a substitute for these two calls immediately after
   a navigation. Treat findings from either source identically (finding, suspected layer, etc.) —
   do not discount a 4xx/5xx or console error just because it came from the driver-backed call
   instead of `console[]`/`network[]`.

**Per round, for every step inside a criterion:**

1. **Observe.** Call `browser_evaluate` with `return __qaObserve({ digestSelector: 'body', runUx: true })`. This ONE call returns:
   ```
   { round, domDigest: { liveText, interactive[] }, console[], network[], ux[], axe }
   ```
   - `domDigest.interactive` lists visible buttons/links/inputs with `data-testid`/label/href — this is the snapshot substitute for finding what to act on next. It does not carry a Playwright ref, so build a selector from it (prefer `[data-testid="…"]`) and pass that as the act call's `target` — `browser_click`/`browser_evaluate` accept a unique CSS selector, not only a snapshot ref. Fall back to `scripts/click-by-text.js` for RTL/label-only targeting, or a one-off `browser_snapshot` only when no stable selector exists.
   - `console[]` and `network[]` are DRAINED since the previous round — every console error/warning, `window.onerror`, unhandled rejection, and fetch/XHR that happened between rounds is already in this payload.
2. **Act.** Click (`browser_click`), type (`browser_type`), fill form (`browser_fill_form`), or select (`browser_select_option`) using the selector from step 1 — a SEPARATE call from the observe. Per the interaction discipline (ADR-0015, [`references/interaction-discipline.md`](./references/interaction-discipline.md)), the act itself is UI-only; `browser_evaluate` on this path is reserved for the logged `nonUiActionReason` opt-out (§ below), never a routine substitute for typing/clicking.
3. **Wait.** After every mutation, wait for the expected next state before asserting (`browser_wait_for`) — still a separate call. Never assert immediately after an act — React renders are async.
4. **Re-observe.** Call `__qaObserve` again. Its `console[]`/`network[]` now cover everything since step 1's round, so a JavaScript exception (catches bug class: page crash on load, e.g. `p.map` on a bad envelope) or an unexpected 4xx/5xx on a mutation request (catches bug class: endpoint 400/422/500 on wizard steps, wrong route names) surfaces here exactly as it did under the old separate calls — carried in one payload instead of two extra round-trips. Treat any such entry as a **finding**, not noise, regardless of whether the DOM digest looks clean.
5. **Assert.** Compare the fresh `domDigest`/`console`/`network` to the oracle (the checklist's expected value/rule), not to what the backend code says.

**Pixel fallback stays separate.** `browser_take_screenshot` remains the tool for visual/layout/math checks needing pixel evidence — `domDigest` is a text/structure digest, not a screenshot, and does not replace it. Screenshot calls are not counted against the ~2-calls-per-step budget.

**No-evidence-regression guard (binding).** The observe-round is a CONSOLIDATION of calls, never a reduction of evidence:
- Console and network status/method/URL are carried directly in every observe payload — read them every round, even when the DOM digest looks unchanged.
- A deeper read the old loop could also reach — a network **response body**, a cross-origin request the in-page buffer can't see, or a backend read-back — is still made as a separate, targeted call: `browser_network_request` for a body, or hand off to `verifying-backend-persistence` / `probing-apis-through-browser`. The observe-round removes the *redundant* per-step console/network/snapshot calls the old loop paid for even when nothing changed; it does not remove a diagnostic a step genuinely needs.
- If the configured driver's `evaluate` capability is absent (see `references/driver-capabilities.md`), the observe-round cannot run at all on that driver — record the affected step `blocked`, never silently fall back to a reduced-diagnostic loop.

## React Controlled Inputs

Typing directly into a React-managed `<input>` often does not update component state — the value appears in the DOM but React discards it on the next render. Value entry on the act path uses `browser_type`/`browser_fill_form` (per ADR-0015, act is UI-only). If a prior entry is suspected of not landing, use `scripts/react-set-input.js` to **read the field's current `.value` back for assertion** — the script is read-only (it no longer sets a value or dispatches events; see its header comment). A readback that does not match the intended value means the entry did not land and must be redone via `browser_type`/`browser_fill_form`, not patched in by the script.

### Out-of-Range / Negative Numeric Inputs (`type="number"`)

`browser_type`/fill on an `<input type="number">` sends the value keystroke-by-keystroke through the browser's native number parser. A value the input rejects mid-entry — `-500` (many browsers accept the leading `-` only once a digit follows, some reject it entirely), a bare `-`, a leading `.`, or a value colliding with `min`/`max`/`step` — can silently coerce to an **empty string**, not to `-500`. The app then reads `Number('')` → `NaN` or falls through to `0`, and a criterion asserting "negative share count is rejected" wrongly passes: the agent never actually entered a negative value, it entered nothing, and the missing validation bug is masked as a pass (see bug F4: negative share count accepted as 0-share ownership).

This is a genuine **tool limitation**, not a routine act-path substitution — per the interaction discipline (§3 reconciliations in `references/interaction-discipline.md`), it is handled through the **logged `nonUiActionReason` opt-out**, not `react-set-input.js` (which is read-only and cannot set the value):

1. Record the criterion's `nonUiActionReason: "tool: browser_type coerces -500 on type=number"` — this permits a mutating `browser_evaluate` for this one act step and forces confidence `low`.
2. Set `.value` through the native prototype setter and dispatch `input`+`change` events, then read `el.value` back — **assert it equals the value you intended** before doing anything else. If it comes back empty or truncated, the input rejected the value at the DOM level and you have not yet tested the scenario.
3. Only once the readback confirms the field holds `-500` (not `''`, not `0`) should you submit and assert the app's behavior (reject vs. accept) against the oracle, noting confidence `low` and the reason in the report.

**Rule:** for any criterion testing an out-of-range numeric (negative, zero, decimal-where-integer-expected, huge value), the verdict is unverified until you have read the field's value back and confirmed it holds the intended input — a "rejected" or "zero" outcome observed without that readback is not evidence of validation, it may just be evidence of a swallowed keystroke. And it is only reachable via the logged opt-out, not a silent workaround.

## Finding Clickable Elements by Text (RTL/Arabic)

`scripts/click-by-text.js` finds a `button`, `a`, or `[role=button/link/menuitem/option]` by trimmed visible text, stripping Unicode bidi control characters (U+200B–U+200F, U+202A–U+202E, U+2066–U+2069) so Arabic/RTL labels match correctly. It uses real geometry (`getBoundingClientRect` + computed style), so it also finds `position:fixed`/sticky controls. Inject via `browser_evaluate` to **resolve** the target — the script is resolve-only (it no longer calls `.click()` in-evaluate; see its header comment) and returns the matched element's selector/metadata for the caller to act on via `browser_click`. **When MULTIPLE visible elements share the text it returns `{ambiguous:true, count, candidates:[…]}` instead of resolving** — do NOT act on a guess: disambiguate with a more specific `[data-testid]`/container selector (or the active/topmost candidate) and re-target before clicking.

**Critical: verify where a click lands, not just that it succeeded.** The script returns `{ href, role, textContent }` for the resolved element before you click it. Check `href` against the expected URL path, then click via `browser_click` and re-observe (`domDigest`/URL) to confirm where it landed — a button that looks correct but links to a legacy route is a finding (bug class: quick-action links to `/cap-table` instead of `/governance`).

## Checking for Client-Side Exceptions

The re-observe call after every act+wait cycle already drains buffered console errors/warnings into the payload's `console[]` array. Scan it for entries containing `Uncaught`, `TypeError`, `cannot read`, or `undefined is not`. Treat any such entry as a criterion **finding** with suspected layer `FE`, record the message verbatim, and include it in the bug log. Do not dismiss an exception because the UI "looks fine" — `console[]` is diagnostic evidence, not visual evidence, and reading it is not optional just because the round otherwise looked clean.

`browser_console_messages` remains available as a direct, separate read — use it if you need console history from before `observe.js` was installed, or on a driver that lacks `evaluate` (see `references/driver-capabilities.md`).

On the visual-UX criterion specifically, inject `detecting-visual-ux/scripts/ux-detectors.js` via its own `browser_evaluate` call (outside the observe-round's per-step budget) and follow its click-probe step for icon-only controls, then re-observe for `console[]` to confirm whether the probe click threw — see detecting-visual-ux for the full objective-fail/subjective-advisory split.

## Checking Network Responses

The same re-observe call after every mutation (form submit, wizard step, save) drains matching fetch/XHR entries into the payload's `network[]` array (`{method, url, status, ok}`). Check:

- Status code: 4xx = likely a client/validation bug; 5xx = likely a server bug. Both are findings.
- Response body: if the status is unexpected, `network[]` does not carry the body — read it with the separate `browser_network_request` call. The body often names the exact field or constraint that failed. This targeted follow-up is the no-evidence-regression guard in practice: consolidation removes the redundant per-step call, not the diagnostic a failing status demands.
- Route path: confirm the request went to the expected endpoint. A 404 or a request to the wrong path (e.g. `/init` vs `/initialize`) is itself the finding.

## Iteration Cap

If a criterion does not resolve after **three UI iterations** (observe → act → wait cycle), stop. Record verdict `blocked` if the environment is preventing progress, or `error` if the tooling broke. Write what you observed (last `domDigest`, last `console[]`, last `network[]`) as evidence. Do not loop forever — a stuck criterion costs more tokens than it saves.

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
| `scripts/observe.js` | Install-once observe-round: drains console + network since last round, returns compact `domDigest` (ADR-0006) |
| `scripts/react-set-input.js` | Read-only (ADR-0015): reads a React-controlled input's current value/validity back for assertion |
| `scripts/click-by-text.js` | Resolve-only (ADR-0015): finds an element by visible text (LTR/RTL-safe), returns its selector/href; act via `browser_click` |
| `scripts/parse-session-log.js` | Classifies `session.md` (`--save-session`) Playwright code into `{class, mutating, code}` — bridges tool calls to code |
| `scripts/preflight.sh` | App liveness + driver ping + auth check + build-ID capture |

---

## Mini-Evals

### Eval 1 — Page crash on list load (bug #1: `p.map` on bad envelope)

**Situation:** The agent navigates to the templates list page and the page appears to load but the list is empty.  
**The skill should:** After the navigation + wait, re-observe (`__qaObserve`) and find `TypeError: p.map is not a function` (or similar) in the payload's `console[]`. Record it as a finding with suspected layer `FE`, verdict `fail`, and note that the envelope shape from the API did not match the component's expected array. Do not mark the criterion pass because the list is visually empty — that absence is not a confirmed 0-state until `console[]` is clean.

### Eval 2 — Wrong route name causes 500 (bug #5: `/init` vs `/initialize`)

**Situation:** The agent submits the wizard's first step and the UI shows a generic error or spinner that never resolves.  
**The skill should:** Re-observe after the submit wait. Find the matching entry in `network[]`. Read its status (500) and url (`/init`). Record a finding: suspected layer `route`, the request landed on a non-existent or wrong route. Include the path and status in the bug log. Do not retry the step — record `fail` and move on.

### Eval 3 — Legacy URL quick-action (bug #14: overview links to wrong page)

**Situation:** The agent is verifying that the overview's "Manage" quick-action navigates to the governance module.  
**The skill should:** Inject `scripts/click-by-text.js` via `browser_evaluate` with label "Manage" to RESOLVE the element (the script never clicks in-evaluate). Before clicking, inspect the returned `href`. If it resolves to `/cap-table` instead of `/governance`, record a finding immediately — the link is wrong regardless of where it navigates. Then click via `browser_click` on the resolved selector and re-observe to confirm where it landed as secondary evidence. Verdict: `fail`, suspected layer `FE`.

### Eval 4 — React input value not retained (bug class: wizard saveStep 422)

**Situation:** The agent fills a business-area field in the wizard via `browser_type`/`browser_fill_form`, proceeds to the next step, and the backend returns 422 (validation error: field required).  
**The skill should:** On the previous step, inject `scripts/react-set-input.js` (read-only) for the business-area input to read its current value back and check it matches what was typed. If the returned value is empty or stale, the `browser_type`/`browser_fill_form` entry did not land — redo entry via `browser_type`/`browser_fill_form` (never patch the value in via the script, which no longer sets) and re-check the readback. If the 422 persists after confirming the value was set, record the network response body as evidence and mark the finding at suspected layer `service` (the backend validation rule).

### Eval 5 — Stale build, fix not deployed (build-freshness check)

**Situation:** A sub-cent precision bug (bug #9: `decimal(…,2)` truncation) was patched and deployed. The agent is re-running the precision criterion.  
**The skill should:** In pre-flight, compare the build ID from the `x-vercel-deployment-id` header to `.qa/runs/.last-build-id`. If they match, warn in the run report that the build ID is unchanged and the fix may not be live before running the criterion. If the criterion then passes, note the build ID in the evidence; if it fails despite the same build ID, that is expected (fix not deployed).

### Eval 6 — Negative numeric input silently emptied (bug F4: negative share count accepted)

**Situation:** The criterion asserts that entering a negative share count (`-500`) into a `type="number"` field is rejected. The agent types `-500` via `browser_type`, submits, and the app accepts it with a 0-share ownership record — the agent is about to conclude "verdict: pass, negative rejected (coerced to 0)."  
**The skill should:** Before trusting that outcome, inject `scripts/react-set-input.js` (read-only) for the field and check the returned value. If it shows `''`/`0` instead of `-500`, the `browser_type` attempt was coerced — this is the genuine tool-limitation case in `references/interaction-discipline.md` §3: record `nonUiActionReason: "tool: browser_type coerces -500 on type=number"`, redo entry via a mutating `browser_evaluate` (native setter + `input`/`change` events, confidence forced to `low`), and read back `el.value` to confirm it now holds `-500`. Only after that readback confirms the value should the agent submit and assert against the oracle (negative share count must be rejected). If the app still accepts it as a valid write with a confirmed `-500` in the field, record a `fail` with suspected layer `service` (missing server-side validation) — not a `pass`.
