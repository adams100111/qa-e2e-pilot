# Pi — optional live-hook hardening

> ⚠️ **Honesty banner.** This recipe is **documented, not runtime-verified** in this repo's CI —
> there is no access to a live Pi runtime here. The exact extension-config syntax is per **your**
> Pi/`@earendil-works/pi-coding-agent` version's own docs; verify it on your build before relying
> on it. The guaranteed, tested tier is the automatic `--save-session` → toolstream → `qa-verify`
> floor described below, which needs no extension at all.

## The automatic floor (read this first — hooks are optional)

Every harness's bundled Playwright MCP server (`playwright-qa`, pinned to
`@playwright/mcp@0.0.79`, see `harnesses/pi/mcp.snippet`) runs with `--save-session`, passed
through Pi's `pi-mcp-adapter` proxy to the workspace in the standard session-log format.
`scripts/session-preflight.sh` derives `.qa/runs/<run>/toolstream.jsonl` from that session log
before `qa-verify` runs, so `qa-verify` binds provenance at **high confidence** with **no live
hook required**. The extension wiring documented below is optional hardening that adds real-time
capture and a live pre-run block. If it doesn't wire up on your build, you lose only the live
block — the automatic floor still gives you a high-confidence `qa-verify` run.

## Mechanism

Pi has **no native MCP support** — the `playwright-qa` server is reached through the
`pi-mcp-adapter` extension's proxy tool (see `harnesses/pi/README.md` for the "browser via
`pi-mcp-adapter` proxy tool `mcp`" note), and Pi has no built-in `PreToolUse`/`PostToolUse` hook
concept the way Claude/Codex do. Instead, Pi supports an **extension-factory handler** pattern —
an extension registers callbacks against Pi's own tool lifecycle events (consult Pi's extension
docs for the exact factory-registration shape and how it's wired into the project's adapter
config, e.g. alongside `pi-mcp-adapter` in `.pi/mcp.json` or a sibling extension config):

- **`tool_call`** — the block. An extension handler observing `tool_call` events can return
  `{block: true}` (plus a reason) to deny a call before it executes — the mechanism doc'd in the
  capability matrix. For the `playwright-qa` `browser_evaluate` / `browser_run_code_unsafe` calls
  (reached via the `mcp` proxy tool — note the tool name your handler sees may be the proxy tool
  name with the underlying MCP tool name nested in its args, not a flat
  `playwright-qa__browser_evaluate` id; **confirm the exact shape on your build**), shell out to
  `scripts/block-hook.sh` with a `{tool_name, tool_input}` payload and translate its deny decision
  into `{block: true}`.
- **`tool_result`** — the capture. Record the call + result to
  `.qa/runs/<run>/toolstream.jsonl` by shelling out to `scripts/capture-hook.sh` with the same
  `{tool_name, tool_input, tool_response}` shape it already expects on stdin.

**Cooperative caveat.** Pi has **no built-in sandbox** — an extension-factory handler is a
cooperative gate: it only holds if nothing else in the agent's own tool access can bypass it (e.g.
by editing the extension's own config, or calling the underlying MCP server through a path the
extension doesn't intercept). For real tamper-resistance, pair the extension with a `path`-deny on
its own config file (so the run's own agent process can't edit it) **and** run Pi itself inside an
OS-level container (the matrix names Gondolin/Docker as options) — the extension alone is
best-effort, not a sandboxed boundary.

## Manual-enforcement-run procedure (verify before trusting)

1. Wire the extension per the mechanism above, on your installed Pi version.
2. Drive the qa-e2e-pilot agent (`/qa-run`) on a disposable app.
3. During the act phase, attempt a mutating `browser_evaluate` — a workaround the
   driving-browser-qa gate itself rejects, so you're deliberately testing the live block here, not
   asking the agent to do this normally.
4. Confirm:
   - (a) **the `tool_call` handler returned `{block: true}`** and the call did not run (Pi's own
     tool-call log/output should show the denial).
   - (b) **the `tool_result` handler recorded** the surrounding `browser_*` calls to
     `.qa/runs/<run-id>/toolstream.jsonl` in real time.
5. If the extension-factory handlers don't fire the way you expect (or the `mcp` proxy tool
   shape doesn't match what `block-hook.sh`/`capture-hook.sh` expect), stop chasing it — the
   automatic `--save-session` → `session-preflight.sh` → toolstream floor (see above) still gives
   you a high-confidence `qa-verify` run from the saved session log alone. The live block is the
   only piece you lose.

## See also

- `docs/specs/harness-capability-matrix.md` — the Capture/Block/Tamper-resistance row this doc is
  sourced from, including the open verification item on `pi-mcp-adapter`'s image/tool-call
  forwarding.
- `docs/harness-adapters.md#the-claude-assurance-tier` — the framing for Claude's own live-hook
  tier (Tier A), which this Pi recipe mirrors in spirit but does not claim parity with.
- `scripts/capture-hook.sh`, `scripts/block-hook.sh` — the shipped hook scripts themselves
  (harness-agnostic; a thin extension wrapper is what's Pi-specific here).
