# Known issue — a plugin-bundled MCP server's tools don't resolve for the bundled agent

**Status:** open (Claude Code platform limitation). Worked around by depending on the
official `playwright` plugin + making `--save-session` (gate Check 0) opt-in (ADR-0015).

## Summary

`qa-e2e-pilot` wanted to be self-contained: bundle its own Playwright MCP server (running
`@playwright/mcp --save-session`, so the human-action gate's independent-log check works
out of the box) and have its bundled agent drive it. That does not work: **the bundled
server connects, but its tools never resolve for the bundled agent** (the agent receives
zero browser tools), so the plugin cannot use its own server.

## Reproduction (verified 2026-09-01, v0.6.1)

1. Plugin `qa-e2e-pilot` (note the HYPHENS in the name) ships a root `.mcp.json`:
   ```json
   { "mcpServers": { "playwright": { "command": "npx",
     "args": ["-y", "@playwright/mcp@0.0.79", "--save-session", "--output-dir", ".playwright-mcp"] } } }
   ```
2. The bundled agent (`agents/qa-e2e-pilot.md`) lists in frontmatter, per the documented
   naming `mcp__plugin_<plugin>_<server>__<tool>`:
   ```yaml
   tools: Read, Write, Bash, mcp__plugin_qa-e2e-pilot_playwright__browser_navigate, …
   ```
3. `claude mcp list` shows the server **healthy**:
   `plugin:qa-e2e-pilot:playwright: npx -y @playwright/mcp@0.0.79 --save-session … - ✔ Connected`
4. Dispatch the agent. It reports **only `Read`/`Write`/`Bash`** — every
   `mcp__plugin_qa-e2e-pilot_playwright__*` entry silently resolved to nothing and was dropped.
5. `ToolSearch` from the main loop also cannot find `mcp__plugin_qa-e2e-pilot_playwright__*`
   (nor the hyphens-as-underscores variant), while it DOES find the official
   `mcp__plugin_playwright_playwright__*`.

## What distinguishes the failing case

The **official** `playwright` plugin (server id `plugin:playwright:playwright`, plugin name has
NO hyphens) exposes its tools fine as `mcp__plugin_playwright_playwright__*`. The **only**
differences for our failing server are:
- the plugin name **has hyphens** (`qa-e2e-pilot`), and
- both servers run the **same `@playwright/mcp` package** (possible dedup by package/tools).

So the cause is one of: a hyphenated-plugin-name tool-resolution bug, or Claude Code de-duping
two servers that expose identically-named tools (keeping the official, dropping ours).

## Untested candidate fix (needs a restart cycle to verify)

Rename the bundled server to a UNIQUE name so it can't collide with the official one:
`.mcp.json` → server `playwright-qa`; agent tools → `mcp__plugin_qa-e2e-pilot_playwright-qa__*`.
If the cause is the dedup, this fixes it; if it's the hyphenated *plugin* name, it will not
(the plugin name still has hyphens). We did not run this experiment because it requires a
version bump + `claude plugin update` + Claude Code restart, and Option A (below) already ships
a working plugin.

## Current resolution (Option A — shipped in v0.6.2)

- The agent uses the official `playwright` plugin's tools (`mcp__plugin_playwright_playwright__*`),
  which resolve correctly. The plugin therefore **requires** the official `playwright` plugin
  (or any user-configured `playwright` MCP) — documented as a prerequisite in the README.
- `--save-session` (gate **Check 0**, the independent-log reconciliation) is **opt-in**: the
  operator adds `--save-session` to that Playwright MCP's args and sets
  `humanInteraction.saveSession: true`. Without it, the gate runs Check 1∧2∧3 (act-phase
  workaround lint + state fingerprints) and the report flags that independent verification was
  unavailable. See ADR-0015.

## If filing upstream

Report to Claude Code: "A plugin-bundled MCP server (root `.mcp.json`) whose plugin name
contains hyphens connects (`claude mcp list` shows ✔ Connected) but its tools do not resolve
for the plugin's bundled agent (agent receives zero of them), while an equivalent non-hyphenated
plugin's server resolves fine. Possibly a hyphenated-plugin-name tool-name resolution bug, or a
dedup between two servers exposing the same tool names." Include the reproduction above.
