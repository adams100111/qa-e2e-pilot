# Configuration is per-project, in `.qa/config.json`

All run-time configuration lives in a per-project `.qa/config.json` (committable, travels with the repo): the **driver pool** (each entry carries a platform preset — `managed` | `windows+wsl` | `windows` | `wsl` | `linux` | `mac` — that resolves its CDP endpoint), `baseUrl`, the auth/storageState path, `maxParallel`, the **repos under test by role** (`frontend` / `backend` / `reference`, all optional — single-repo still works), and the **gated-write controls** (`allowApiWrites`, default off, plus a disposable/seedable env marker).

## Consequences

Per-project rather than global so one machine can QA several apps — different backends, repos, auth, base URLs — without collision, and so the config is reviewable alongside the code it tests. The **default driver is the managed Playwright-MCP browser**, so the tool works zero-config on install; attended CDP (including Windows-Chrome-from-WSL) is opt-in via a preset. Skills read repos **by role**, so cross-repo reconciliation (FE shape vs backend route, displayed value vs migration precision) is a config field, not bespoke orchestration. New browser MCPs drop in as additional driver entries because skills call browser tools by capability, not by hard-coded server name.
