# Extending qa-e2e-pilot: new browser drivers & memory backends

Two extension points are designed in from the start so the plugin can adopt new tooling without rewrites. Both are **optional** — the defaults (managed Playwright + plain-file run state) need none of this.

---

## Adding a new browser MCP as a driver

The skills call browser tools **by capability** (navigate, snapshot, click, type, evaluate, read console, read network response body, screenshot, wait), not by a hard-coded server name. So a new browser MCP — [Stagehand](https://github.com/browserbase/stagehand), [browser-use](https://github.com/browser-use/browser-use), or anything that exposes equivalent capabilities — drops in as another **driver** entry.

### 1. Make the MCP available to Claude Code

Install/configure the MCP server so its tools are reachable (e.g. `stagehand:*` or `browser-use:*`). Confirm it exposes the capabilities above.

### 2. Add a driver entry to `.qa/config.json`

```jsonc
{
  "drivers": [
    { "id": "managed", "server": "playwright", "preset": "managed" },
    { "id": "stagehand", "server": "stagehand", "preset": "managed" },
    { "id": "mine", "server": "playwright-cdp", "preset": "windows+wsl",
      "cdpEndpoint": "http://localhost:9222" }
  ],
  "maxParallel": 3
}
```

- `id` — the label shown in pre-flight output.
- `server` — the MCP server providing the browser tools for this driver.
- `preset` — `managed | windows+wsl | windows | wsl | linux | mac` (resolves a CDP endpoint for attached browsers; `managed` for a built-in one).
- `cdpEndpoint` — optional explicit override of the preset-resolved endpoint.

### 3. Grant the agent the new server's tools

The agent (`agents/qa-e2e-pilot.md`) lists its `tools`. Add the new server's browser tools (fully-qualified, e.g. `mcp__stagehand__*` equivalents) to that list — or run the agent without a restrictive `tools` list so it inherits whatever browser MCP is configured.

### 4. That's it

Pre-flight enumerates and pings every configured driver. Verification still runs **sequentially on one driver by default** (ADR-0003); a second driver only earns its keep on the narrow parallel path — see the `fanning-out-criteria` skill. New drivers are usable there immediately because the skills never named a server directly.

> **Capability gaps:** if a new MCP lacks a capability a skill relies on (e.g. it can't read a network **response body**), that skill's probing/baking step falls back or records `blocked` for that criterion rather than faking a pass. Prefer a driver that can read the network and run in-page `evaluate` for the full differentiated flow. The exact per-driver capability table (Playwright/CDP vs Stagehand vs browser-use, with the diagnostic-tier gaps marked) lives in [`skills/driving-browser-qa/references/driver-capabilities.md`](../skills/driving-browser-qa/references/driver-capabilities.md) — consult it to decide which criteria a new driver can carry.

---

## Swapping the memory backend (Mem0 / vector store)

By default the **memory-spec** artifacts (`run-manifest`, `checkpoint`, `bug-log`, `traceability`) are plain files under `.qa/runs/<run-id>/` (ADR-0002). This is deliberate: per-criterion run state is transient and resumable, not a durable fact, so it does **not** belong in Claude Code's personal memory. The file backend has no dependencies and makes runs trivially inspectable and resumable.

A **vector / long-term backend** (e.g. [Mem0](https://github.com/mem0ai/mem0)-shaped) is **shipped and config-gated, off by default** — [`scripts/memory-sync.sh`](../scripts/memory-sync.sh) — not a v1 dependency you have to build yourself. It becomes interesting when you want cross-run recall ("what was flaky last month?", "have we seen this bug shape before?") rather than within-run resume. The script does not implement the Mem0 SDK/API itself; it POSTs a JSON payload (bearer-token auth) to whatever endpoint you configure, so any Mem0-compatible or generic ingestion endpoint works.

### How the swap slots in (shipped)

The `checkpointing-qa-memory` skill is the only writer/reader of run state, and the **memory-spec schema is the contract**. `scripts/memory-sync.sh` replaces *where* durable artifacts additionally live, without touching that schema:

1. **Keep the typed schema** — `run-manifest` / `checkpoint` / `bug-log` / `traceability` stay exactly as defined (the templates are the source of truth); `memory-sync.sh` only *reads* them.
2. **Write-through, don't replace resume.** The file checkpoint stays the authoritative resume cursor (cheap, local, crash-safe); `memory-sync.sh` *additionally* upserts each bug + advisory finding + one per-project pointer into the vector store. Resume still reads the local checkpoint; the vector store is for cross-run queries.
3. **Index the durable, not the transient.** It pushes `bug-log` entries (enriched with persona + a compact bake/computed/probe evidence excerpt), `advisory.json` items, and one per-project pointer (latest run id/status/known-flaky areas/personas exercised) into the store; it deliberately does **not** flood it with every per-criterion checkpoint — that's transient noise (same reasoning as ADR-0002).
4. **Config-gated, shipped.** `.qa/config.json`'s `memory.backend: "file" | "mem0"` field selects it (`memory.mem0.{endpoint,apiKeyEnv,userId}` configures the target); absent → `"file"` (the default, and `memory-sync.sh` is then a no-op). Run it as `bash scripts/memory-sync.sh <run-id> [--dry-run]` — `--dry-run` prints the payload and the would-be request with the key redacted, sending nothing.

### What stays true regardless of backend

- Run state is never written to the agent's personal memory `MEMORY.md` (ADR-0002).
- The checklist's **oracle** is the spec/domain rule — a memory backend never becomes the oracle.
- Resume must work offline from the local `.qa/runs/<run-id>/checkpoint.json` even if the vector store is unreachable.

This keeps the swap additive: the differentiated QA behavior is unchanged; you've only added cross-run recall on top of the same artifacts.
