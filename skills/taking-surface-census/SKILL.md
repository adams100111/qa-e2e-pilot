---
name: taking-surface-census
description: Use when a ship-profile or census run needs to know what each confirmed role can actually reach — after confirming-discovered-roles has written personas[] and before census.sh merges the stack adapter's routes with the crawl. Runs a read-only, breadth-first crawl per persona from that role's landing page (budget census.maxVisits, default 300; depth 4), recording each visited surface's load status, observed findings (classified by classify-finding.sh) and form constraints, and writes .qa/census/crawl/crawl-<personaId>.json. Clicks only elements crawl-safety.js classifies safe (English + Arabic destructive-label aware, unsafe always wins), closes every dialog it opens via Escape, never fills or submits a form, and records everything it would not touch as unexplored with a reason.
---

# Taking Surface Census

## Overview

The census answers "what does the app expose, and who reaches it". The stack adapter
(`adapters/census/<stack>.sh`) lists what the code declares; this skill adds what each role
**actually reaches** by crawling the running app in that role's session. `scripts/census.sh`
then merges both into `.qa/census.json` and diffs them (unreachable, overreach, crawl-only).

The crawl is **read-only on every environment**. It follows links, tabs, menu openers and
disclosure controls; it never presses an action button that is not classified safe, never types
into a field, never submits a form. A surface it cannot open safely is reported as `unexplored`,
never forced.

The crawl runs **before a run exists**, so it writes no journal and no verdict. Findings it sees
are stored in the crawl file; the generated `load-clean:<surfaceId>:<persona>` criteria re-verify
each surface × persona pair inside the later run, where the findings ledger applies.

## When to Use

- A `ship` profile run, or `/qa-spec` building a census, after `confirming-discovered-roles` has
  written `.qa/config.json` `personas[]` (and `.qa/authz-matrix.json`).
- Re-taking the census after navigation or permissions changed.

Do **not** use it to verify a criterion (that is `driving-browser-qa`), and do not use it to
create data. Skip a persona whose session cannot be established; record why (see Step 2).

## Inputs

| Input | Source | Default |
|---|---|---|
| `baseUrl`, `personas[]`, `crawlDenyPatterns` | `.qa/config.json` | `crawlDenyPatterns: []` |
| `census.maxVisits` | `.qa/config.json` (or the run's `effective-config.json`) | `300` per persona |
| depth limit | fixed | `4` link/click hops from the landing page |
| `environment`, `allowBlackboxCrawl` | `.qa/config.json` | see Step 1 |

## Output

One file per persona, `.qa/census/crawl/crawl-<personaId>.json` — exactly this shape (it is
`census.sh build --crawl .qa/census/crawl` input):

```json
{
  "personaId": "admin",
  "visits": [
    { "url": "https://app.example.sa/admin/hackathons", "routeMatch": "page:Admin/Hackathons/Index",
      "kind": "page", "status": 200,
      "findings": [ { "source": "network", "url": "…/api/stats", "status": 500,
                      "message": "", "originClass": "in-scope", "statusClass": "fatal" } ],
      "forms": [ { "formId": "filters", "action": "/admin/hackathons", "method": "GET",
                   "fields": [ { "name": "q", "type": "search", "required": false,
                                 "maxLength": null, "min": null, "max": null, "pattern": null } ] } ] }
  ],
  "unexplored": [ { "url": "https://app.example.sa/admin/hackathons", "reason": "unsafe-name: حذف (#row-3 button)" } ]
}
```

- `url` is the browser-reported, percent-encoded URL (never decoded). Strip the `#fragment`.
- `kind` is `page`, `tab`, `dialog` or `sheet`. A tab/dialog/sheet visit carries the URL of the
  page it opened on; only a URL change makes a new `page` visit.
- `status` is the document's HTTP status (from `browser_network_requests` for the navigation; a
  tab/dialog visit reuses its page's status).
- `routeMatch` is `page:<component>` when the page exposes its front-end component (Inertia
  `#app[data-page]` `.component`, Next.js `#__NEXT_DATA__` `.page`), and **omitted** otherwise.
  `census.sh` maps adapter `page:*` surfaces only through it — without it every page reports
  unreachable. Take it from `window.__qaRouteMatch` (Step 3.5); never guess one.
- Write the file with `node`/`python3` `json.dump(..., ensure_ascii=False)` — Arabic labels and
  URLs stay as-is. Never hand-assemble JSON with string concatenation.

## The Process

### Step 1 — Plan and gate

1. Read `.qa/config.json` (or the run's `effective-config.json` when one exists). Collect
   `personas[]`, `baseUrl`, `crawlDenyPatterns`, `census.maxVisits` (default 300).
2. **Production gate.** If the target resolves to production (`environment: production`, or
   `auto` inferring production) and `allowBlackboxCrawl` is not `true`, do not crawl. Write each
   persona's file with `visits: []` and one `unexplored` entry
   `{url: baseUrl, reason: "crawl-disabled-on-production"}` so the census degrades visibly to
   adapter-only, never to a silent "nothing reachable".
3. Run `driving-browser-qa`'s pre-flight (`scripts/preflight.sh`). App down → stop; nothing to
   crawl.

### Step 2 — Per persona: establish the session

Crawl personas **one at a time** (sequential, ADR-0003). For each persona:

1. Load the persona's session the way `driving-browser-qa` does (its `auth` convention:
   storageState or seeded-credential login). Never print a credential.
2. The **landing page** is wherever the app lands this role after login (or `baseUrl` when the
   session is pre-loaded). Record it as the first queue entry, depth 0.
3. If no session can be established, write the persona's file with `visits: []` and
   `unexplored: [{url: baseUrl, reason: "no-session: <short cause>"}]`, then go to the next one.

### Step 3 — Breadth-first visit loop

Keep a FIFO queue of `{url, depth}` and a visited set keyed by the URL without its fragment.
Before the first injection, set the options once per document:
`browser_evaluate` → `window.__qaCrawlOptions = { denyPatterns: <crawlDenyPatterns> }`.

For each dequeued entry, while `visits.length < census.maxVisits`:

1. **Navigate** (`browser_navigate`) and wait for the page to settle (`browser_wait_for`).
2. **Observe round.** Inject `driving-browser-qa/scripts/observe.js` as the first action on the
   new document (it is self-healing across navigations). Read `console[]` and `network[]`; for
   the document status and load-window errors, also read `browser_network_requests`.
3. **Classify each observed error** with
   `${CLAUDE_PLUGIN_ROOT}/scripts/classify-finding.sh .qa/config.json <url> <status>` (`<status>` = the HTTP status,
   or `unhandled-exception` for an uncaught console error). Store every one in the visit's
   `findings[]` as `{source, url, status, message, originClass, statusClass}` — copy the two
   class strings verbatim. Do not filter: `benign` and `third-party` findings are kept too.
4. **Forms.** Inject `scripts/form-inventory.js`; store the returned array as `forms`.
5. **Safety.** Inject `scripts/crawl-safety.js`; it returns `[{selector, label, safe, reason}]`.
   The same injection sets `window.__qaRouteMatch`; read it with one `browser_evaluate`
   (`() => window.__qaRouteMatch`) and set the visit's `routeMatch` when it is non-null.
   A tab/dialog/sheet visit reuses its page's `routeMatch`.
6. Push the visit record.
7. **Expand** (only when `depth < 4`):
   - Every `safe` entry with reason `same-origin-link`: resolve its `href`, enqueue at
     `depth + 1` unless already visited or queued.
   - Links are followed by `browser_navigate` to the resolved URL, never by clicking.
   - Every `safe` entry with reason `tab`, `disclosure`, `popup-opener` or `safe-name`:
     a. **Re-verify right before the click.** Re-inject `scripts/crawl-safety.js` and click only
        if an entry with the **same selector** is still `safe: true` with the **same label**. A
        re-render may have moved the selector onto another element; on any mismatch, skip it
        and record `{url, reason: "changed-before-click: <label>"}`.
     b. Click it (`browser_click`, by that selector), wait, re-observe.
     c. **Mutation watch.** Read the observe round's `network[]`. Any request whose method is not
        GET/HEAD/OPTIONS and whose origin is `baseUrl`'s (in-scope) means the click changed
        state (an Inertia `<Link method="post" as="button">` renders as a plain button). Stop
        clicking for this persona at once: record `{url, reason: "mutation-observed: <METHOD>
        <path>"}`, finish the persona with links only (navigation, no clicks), and report it.
     d. If the URL changed → enqueue the new URL as a page and navigate back. If a tab panel,
        dialog (`[role=dialog]`, `aria-modal`) or sheet appeared → record a `tab`/`dialog`/`sheet`
        visit (counts against the budget) with its own findings and `form-inventory.js` forms,
        then **close it** (Step 4). Do not click further controls inside an opened dialog.
     e. **Menus.** When a `popup-opener` expands a menu, re-scan with `crawl-safety.js` while it
        is open. Its items are new entries: each goes through this same rule (safe only,
        re-verified right before its click, mutation watch after it). Close the menu with
        `Escape` when done.
8. **Record every `safe: false` entry** in `unexplored` as
   `{url: <page url>, reason: "<reason>: <label> (<selector>)"}`, deduplicated by
   `(url, reason)`. Cross-origin links are recorded too (reason `cross-origin`).

When the budget runs out, record every URL still queued as `{url, reason: "budget-exhausted"}`.
URLs found at depth 4 that were not followed are recorded as `{url, reason: "depth-limit"}`.

### Step 4 — Closing what the crawl opened

A dialog the crawl opened is **always** closed without its primary action:

1. Press `Escape` (`browser_press_key`). Re-observe. Closed → done.
2. Still open → click its close control: an `aria-label`/text of `Close`/`إغلاق`, or a
   `[data-dismiss]`/`[data-bs-dismiss]` control. Re-observe. Closed → done.
3. Still open → a control named exactly `Cancel`/`إلغاء` that is not `type=submit`. This is the
   one place a `cancel`-named control may be pressed, and only inside a dialog the crawl itself
   opened. Apply the mutation watch (Step 3.7c) after it.
4. Still open → navigate to the page URL again (discards the dialog, submits nothing) and record
   `{url, reason: "dialog-not-dismissable: <label>"}`.

### Step 5 — Write and hand off

1. Write `.qa/census/crawl/crawl-<personaId>.json` per persona (shape above).
2. Validate each file parses (`python3 -c 'import json,sys; json.load(open(sys.argv[1]))' <file>`).
3. Hand off: `${CLAUDE_PLUGIN_ROOT}/scripts/census.sh build --adapter <adapter.json> --crawl .qa/census/crawl --out .qa/census.json`.

## Hard Rules

- **Native dialogs.** A `confirm()`, `alert()`, `prompt()` or `beforeunload` dialog is always
  answered with `browser_handle_dialog` `accept: false`, then the page is reloaded
  (`browser_navigate` to its URL). Never accept one: accepting a `confirm()` runs the action
  it guards. Record `{url, reason: "native-dialog: <message>"}`.
- Click only `safe: true` entries, re-verified right before the click (Step 3.7a). Never override `crawl-safety.js` because a label "looks
  harmless" — a false `safe` is a destroyed record on someone's environment.
- Never call `browser_type`, `browser_fill_form`, `browser_select_option` or `browser_file_upload`
  during a crawl. Never submit a form, including GET search forms.
- `browser_evaluate` is used only to inject the three read-only scripts and set
  `window.__qaCrawlOptions`; never to click, type or call `fetch`.
- No journal events, no verdicts, no `record-evidence.sh` — the crawl runs outside a run.

## Bundled Scripts

| Script | Purpose |
|---|---|
| `scripts/crawl-safety.js` | In-page: classifies every interactive element `[{selector, label, safe, reason}]`. Unsafe (EN+AR destructive names over every name source incl. `aria-label`/`title`, `type=submit`, form without an explicit GET method, `data-method`/`data-confirm`, unsafe verbs in the href path) wins over safe (same-origin link, tab, disclosure, popup opener, view/details-style button names minus state-change disqualifiers). Narrow status-word exception for tabs/links only. Non-unique selectors → `ambiguous-selector`. Default deny. Also sets `window.__qaRouteMatch` (`page:<component>` from Inertia `data-page` or Next.js `__NEXT_DATA__`). Exports `classify(descriptor, opts)` and `pageComponent(dataPageJson, nextDataJson)` for Node tests |
| `scripts/form-inventory.js` | In-page: `[{formId, action, method, fields:[{name, type, required, maxLength, min, max, pattern}]}]`; controls outside any `<form>` grouped as `formId: "page"`. Exports `inventoryForm(descriptor)` |
| `../driving-browser-qa/scripts/observe.js` | The observe round (console + network since last round) |
| `../../scripts/classify-finding.sh` | `originClass` / `statusClass` for one observed error |

Tests: `tests/crawl-safety/run.sh`.

## Checklist Summary

- [ ] Personas, budget, deny patterns read; production gate applied
- [ ] Per persona: session established (or `no-session` recorded)
- [ ] Each visit: observe round, findings classified, forms inventoried, safety classified
- [ ] Only `safe` entries clicked; every dialog closed via Escape / dismiss / re-navigate
- [ ] All `safe: false`, budget and depth leftovers in `unexplored` with reasons
- [ ] `crawl-<personaId>.json` written with `ensure_ascii=False`, parsed back, handed to `census.sh`

## Mini-Evals

### Eval 1 — Arabic icon-only delete (Review Focus #1)

**Situation:** The Arabic teams table has a trash-icon button per row with no visible text and
`aria-label="حذف"`.
**The skill should:** `crawl-safety.js` returns `safe: false, reason: "unsafe-name"` for it (the
aria-label is checked even with empty text). The crawl does not click it and records
`{url, reason: "unsafe-name: حذف (#row-3 button)"}` in `unexplored`. Clicking it because it "is
just an icon" is the failure.

### Eval 2 — "View" button inside a POST form

**Situation:** An idea review page wraps its toolbar in `<form method="post">`; one button reads
"View history".
**The skill should:** Classify it `inside-non-get-form` and leave it unexplored, even though the
name alone would be safe. Unsafe wins; the button may be a hidden submit that changes state (the
same class of hidden mutation as the wizard `saveStep` 422 bug).

### Eval 3 — Page crash on list load seen during the crawl (bug #1: `p.map` on bad envelope)

**Situation:** Visiting `/admin/templates` as the reviewer persona, the list renders empty and
`observe.js` `console[]` holds `TypeError: p.map is not a function`.
**The skill should:** Classify it with `classify-finding.sh` (`unhandled-exception` → `fatal`,
`in-scope`) and store it in that visit's `findings[]`. It writes no verdict and no journal event;
the generated `load-clean:<surfaceId>:reviewer` criterion re-verifies it inside the run. Dropping
the finding because "the crawl is not a test" is the failure.

### Eval 4 — Dialog opened by a menu

**Situation:** A safe `aria-haspopup` "Actions" button opens a menu; its "Edit" item opens an
edit dialog with "Save" and "Cancel".
**The skill should:** Record the dialog visit with its form inventory, press `Escape`, confirm it
closed, and move on. It never presses "Save", and presses "Cancel" only if `Escape` failed and the
control is not `type=submit`.

### Eval 5 — Wrong-route link to a legacy page (bug #14)

**Situation:** The overview's "Manage" quick action links to `/cap-table` instead of
`/governance`.
**The skill should:** Follow it like any same-origin link and record the visit (likely 404 or a
legacy page). `census.sh` then lists `/cap-table` under `crawlOnly` and `/governance` under
`unreachable` if nothing else reaches it, which surfaces the wrong link without the crawl having
to judge it.
