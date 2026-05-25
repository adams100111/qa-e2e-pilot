# Driver capability map

The skills call browser tools **by capability**, never by a hard-coded server name. This table maps each capability to the concrete tool on each supported driver, so a new browser MCP drops in as a config entry (see [extending-drivers.md](../../../docs/extending-drivers.md)). When a driver lacks a capability, the step that needs it **falls back or records `blocked`** — it never fakes a pass.

## Capability → tool, per driver

| Capability (what a skill needs) | `playwright` / `playwright-cdp` | `stagehand` | `browser-use` |
|---|---|---|---|
| navigate to URL | `browser_navigate` | `stagehand_navigate` | `navigate` / `go_to_url` |
| navigate back | `browser_navigate_back` | act: "go back" | `go_back` |
| accessibility snapshot (refs) | `browser_snapshot` | `stagehand_observe` | `get_state` / `extract_content` |
| click | `browser_click` | `stagehand_act` ("click …") | `click_element` |
| type into field | `browser_type` | `stagehand_act` ("type …") | `input_text` |
| fill a whole form | `browser_fill_form` | `stagehand_act` (per field) | per-field `input_text` |
| press key | `browser_press_key` | `stagehand_act` ("press …") | `send_keys` |
| select option | `browser_select_option` | `stagehand_act` | `select_dropdown_option` |
| hover | `browser_hover` | `stagehand_act` ("hover …") | — |
| **run JS in page (`evaluate`)** | `browser_evaluate` | ⚠️ usually none | ⚠️ usually none |
| upload file | `browser_file_upload` | `stagehand_act` | `upload_file` |
| handle dialog | `browser_handle_dialog` | (auto) | (auto) |
| wait for condition | `browser_wait_for` | (built into act) | `wait` |
| **read console messages** | `browser_console_messages` | ⚠️ usually none | ⚠️ usually none |
| **list network requests** | `browser_network_requests` | ⚠️ usually none | ⚠️ limited |
| **read a network response body** | `browser_network_request` | ⚠️ usually none | ⚠️ usually none |
| screenshot | `browser_take_screenshot` | `screenshot` | `take_screenshot` |
| separate sessions / tabs | `browser_tabs` (+ contexts) | per-instance | per-instance |
| close | `browser_close` | `close` | `close` |

(Exact tool names vary by MCP version — confirm with the server's tool list; the point is to match by *capability*.)

## The capability tiers

- **Drive-UI tier** (navigate, snapshot/observe, click, type, screenshot, wait): every driver above supports it. Any driver can run `driving-browser-qa`'s basic act→wait→assert loop.
- **Diagnostic tier** (⚠️ rows: `evaluate`, console messages, network list + **response body**): this is what the *differentiators* depend on —
  - `probing-apis-through-browser` reads the network **response body** and runs an in-page authenticated fetch (`evaluate`).
  - `verifying-backend-persistence` / `verifying-computed-logic` read the **API response** to reconcile FE vs API, and inject `react-set-input.js` / `backend-probe.js` via `evaluate`.
  - `driving-browser-qa` reads **console messages** after each step to catch client exceptions (bug #1) and network status (bugs #2, #4–6, #10).

**Agentic drivers (Stagehand, browser-use) typically lack the diagnostic tier.** They're great at *driving* a UI but usually can't hand you the raw network body or run arbitrary in-page JS.

## Rule of thumb for driver selection

- Use **Playwright/CDP** (managed or attended) for any criterion whose verdict depends on **baking, computed-logic reconciliation against the API, or probing** — i.e. most differentiated criteria. These need the diagnostic tier.
- An **agentic driver** is fine for **drive-and-visually-verify** criteria, or as an extra driver on the narrow parallel `fanning-out-criteria` path for **read-only** checks.
- If a configured driver lacks a capability a criterion needs: prefer the network tab fallback (if any), else record the affected step's criterion as **`blocked`** with the reason ("driver `<id>` lacks network-response-body capability"), not a pass.
- Pre-flight (`scripts/preflight.sh`) detects cross-origin capability and pings each driver; it does **not** introspect per-tool capabilities — use this table to decide which driver a criterion belongs on.
