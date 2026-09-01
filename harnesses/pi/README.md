# qa-e2e-pilot on Pi

Runs the same 16 skills, 6-phase orchestrator, and human-interaction gate as the Claude Code
plugin, adapted for Pi's agent markdown + `pi-mcp-adapter` proxy tool. v1 is **sequential-only**
(ADR-0003/Task 10) — nothing here requires or assumes subagent dispatch.

## Prerequisites

- A Pi CLI/runtime with `pi-mcp-adapter` installed and configured to read a project-local
  `.pi/mcp.json`.
- `node`/`npx` on PATH (runs `@playwright/mcp` via `npx -y`).
- `python3` (3.11+ recommended — `checkpoint.sh`/`preflight.sh` fall back to it when `jq` is
  absent; the accuracy-harness scorer and CI gate use it too).

## Install

From this repo:

```bash
bash harnesses/pi/install-pi.sh <path-to-your-project>
```

This builds `dist/pi/` (via `scripts/build-adapter.sh pi`) and copies:

- skills → `<project>/.pi/agents/skills/`
- the plugin's grounding files, `CONTEXT.md` and `docs/adr/`, → `<project>/.pi/agents/`
  (alongside the skills, not the project's own root — the persona instructs the agent to read
  these, but the reference is unanchored, so see "Manual accuracy run" below)
- the agent manifest → `<project>/.pi/agents/qa-e2e-pilot.md`
- the `/qa-run` and `/qa-roles` prompts → `<project>/.pi/prompts/`
- the `mcpServers` fragment (from `harnesses/pi/mcp.snippet`) → `<project>/.pi/mcp.json`

The installer never writes to `~/.pi` or any other global Pi config; the `playwright-qa` server
is project-local, uniquely keyed, and pinned to `@playwright/mcp@0.0.79`.

## Proxy by default

The Pi agent manifest grants the `mcp` **proxy tool**, not per-capability browser tools — Pi's
`tools:` frontmatter lists `mcp` and the agent calls `playwright-qa`'s methods through that single
proxy (see `harness-profiles.json`'s `pi.grantStyle: "proxy"` and `pi.toolPrefix:
"mcp:playwright-qa/"`). This is the supported default and requires no extra configuration.

**Direct-tool mode is an opt-in.** If your Pi build exposes MCP server tools directly (bypassing
the `mcp` proxy), you may grant those tools instead of `mcp` in a locally-edited copy of the agent
manifest — this is not the shipped default, is not covered by the accuracy harness, and you take
on verifying it yourself.

## VERSION-PIN note

The `playwright-qa` server is pinned to `@playwright/mcp@0.0.79` — the version/session-log format
`parse-session-log.js` parses and the accuracy-harness scorer expects. The human-interaction gate
(Check 0) reads session logs **only from the pinned `playwright-qa` server** — it does not scan
other MCP servers. A coexisting user `playwright` server on `@latest` (or any other version) in
your own `.pi/mcp.json` is fine to keep for other work/driving, but its logs are **not** the
Check-0 evidence source; only `playwright-qa`'s session log is.

## R1 caveat: validate `--save-session` under the proxy

`mcp.snippet` launches `@playwright/mcp` with `--save-session --output-dir .playwright-mcp`,
which is expected to write `.playwright-mcp/session-*/session.md` per ADR-0015's driver-launch
contract. **Validate this on your Pi build before relying on Check 0**: some proxy layers may not
surface the underlying MCP server's `--save-session` output faithfully. If `session.md` is not
written (or not reconcilable) when driving through the `mcp` proxy, the human-interaction gate
degrades to **Check 1∧2∧3** (workaround lint + before/after state fingerprints) and flags
independent verification as unavailable, rather than failing the run — see
`skills/driving-browser-qa/references/interaction-discipline.md`.

## Manual accuracy run

Before trusting this adapter on your project, run it once against the bundled fixture and score
it — see `docs/harness-adapters.md` for the full procedure (serve
`tools/accuracy-harness/fixture/`, point `.qa/config.json` at it, run the agent end-to-end,
convert + score the bug-log against the 85%/100% gate).

The installer places `CONTEXT.md` and `docs/adr/` alongside the installed skills (see "Install"
above) because the persona instructs the agent to read them — but that reference is unanchored,
so whether Pi's runtime (and the `pi-mcp-adapter` proxy layer) actually resolves those paths from
its cwd/plugin-root depends on the Pi build, similar to the `--save-session` caveat above. This
is **not validated by `validate-adapters.sh`**; confirming the agent can actually read
`CONTEXT.md`/`docs/adr/` is part of this manual accuracy-acceptance run, not a claim made in
advance.
