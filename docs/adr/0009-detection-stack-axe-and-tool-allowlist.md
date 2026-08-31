# ADR-0009 — Detection stack: keep Playwright MCP, add axe-core + `browser_resize`; `browser_run_code_unsafe` stays out of the default allowlist

## Status

Proposed (2026-08-30). Part of the accuracy overhaul ([docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md)). Evidence-backed; sources in the plan §tooling.

## Context

The overhaul needs (a) an accessibility engine, (b) a runtime-viewport capability, and possibly (c) a
different driver. The orchestrator tool allowlist (`agents/qa-e2e-pilot.md:10`) currently includes
`browser_evaluate` and `browser_take_screenshot` but **not** `browser_resize` or
`browser_run_code_unsafe` — yet `probing-apis-through-browser` and `driver-capabilities.md` already
*name* `browser_run_code_unsafe` as an evaluate fallback. A driver swap is permitted via the
`drivers[]` / `driver-capabilities.md` seam (config, not code).

Research findings (2026, cited in the plan):
- **Playwright MCP** (`@playwright/mcp`, ~v0.0.79) exposes all needed tools incl. `browser_evaluate`,
  `browser_resize`, `browser_snapshot`, `browser_console_messages`, `browser_network_requests`.
- **`browser_run_code_unsafe`** runs a snippet **in the MCP server (Node) process** with the `page`
  object. It was renamed `browser_run_code` -> `browser_run_code_unsafe` (~v0.0.72) to make the risk
  explicit; it is **RCE-equivalent, has a filed critical sandbox-escape (issue #1495), and is NOT
  gated** by capability config. `browser_evaluate` runs in the **page/DOM context** and is the safe
  injection primitive.
- **axe-core** 4.13.0 (MPL-2.0): inject `axe.min.js`, call `window.axe.run()` -> `{ violations[] }`
  with `id/impact/nodes[]`. Injectable through `browser_evaluate`.
- **Pixel-diff** (`toHaveScreenshot`/pixelmatch/odiff) **fails by design on a first run with no
  baseline** — unusable for the overhaul's baseline-free objective-UX detection; absolute in-page
  heuristics are required instead.
- **Chrome DevTools MCP** (~v0.25.0) has the strongest network-body/console/perf diagnostic tier.

## Decision

1. **Keep Playwright MCP as the primary driver** — richest UI-driving toolset, already wired.
2. **Add `browser_resize` to the allowlist** (needed for ADR-0008 viewport control).
3. **Adopt axe-core** as the a11y engine, injected via `browser_evaluate`, alongside the hand-rolled
   `ux-detectors.js` for contrast/overflow/target-size.
4. **`browser_run_code_unsafe` stays OUT of the default allowlist.** This *revises* the task's initial
   assumption (it asked to add it): the evidence shows it is an ungated RCE hole. The observe-round
   and all probing use `browser_evaluate` (page context) instead. `browser_run_code_unsafe` may be
   enabled **only** hard-gated behind the existing disposable-env markers (`allowApiWrites: true`
   **and** `seedableEnvMarker` present) and never in production mode — mirroring the repo's own
   "probing is read-only unless disposable env" invariant. The dangling references in
   `probing-apis-through-browser` / `driver-capabilities.md` are re-worded to "gated fallback" (plan).
5. **Chrome DevTools MCP is an optional, read-only additional driver** via the `drivers[]` seam, for
   criteria that need true network **response-body** reads beyond in-page `fetch()`. Config, not code.

## Consequences

- No mandatory driver swap; zero-config install still works on managed Playwright.
- UX detection gains a citable engine (axe-core) without introducing a network/CDN dependency
  (bundled, injected in-page) — consistent with the plugin's "self-contained browser JS" rule.
- **Security invariant strengthened**: the plugin never exposes an ungated RCE tool by default; the
  one dangerous capability is bound to the same disposable-env gate that already guards writes.
- **Reversibility**: allowlist/driver entries are config; the hard-to-reverse call is the *stance* on
  `browser_run_code_unsafe` (default-off, gated) — recorded here so it reads as deliberate, not an
  oversight, and so a future reviewer does not "helpfully" add it to the allowlist.
