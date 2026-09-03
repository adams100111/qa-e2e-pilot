# opencode — optional live-hook hardening

> ⚠️ **Honesty banner.** This recipe is **documented, not runtime-verified** in this repo's CI —
> there is no access to a live opencode runtime here. The exact hook/plugin syntax is per **your**
> opencode version's own docs; verify it on your build before relying on it. The guaranteed,
> tested tier is the automatic `--save-session` → toolstream → `qa-verify` floor described below,
> which needs no plugin at all.

## The automatic floor (read this first — hooks are optional)

Every harness's bundled Playwright MCP server (`playwright-qa`, pinned to
`@playwright/mcp@0.0.79`, see `harnesses/opencode/mcp.snippet`) runs with `--save-session`.
`scripts/session-preflight.sh` derives `.qa/runs/<run>/toolstream.jsonl` from that session log
before `qa-verify` runs, so `qa-verify` binds provenance at **high confidence** with **no live
hook required**. The plugin wiring documented below is optional hardening that adds real-time
capture and a live pre-run block. If it doesn't wire up on your build, you lose only the live
block — the automatic floor still gives you a high-confidence `qa-verify` run.

## Mechanism

opencode plugins can hook `tool.execute.before` and `tool.execute.after` (see opencode's own
plugin docs for the exact plugin-file shape and how it's registered via `.opencode/` /
`opencode.json`'s `plugin` array — `harnesses/opencode/mcp.snippet` already registers the
`opencode-skills` plugin as a precedent for the wiring style):

- **`tool.execute.before`** — the block. Inspect the tool name/args; for a mutating
  `playwright-qa` `browser_evaluate` or `browser_run_code_unsafe` call, **throw** from the hook to
  deny the call before it executes. The thrown error is opencode's block mechanism — there is no
  separate "deny" return value, unlike Claude's `PreToolUse` JSON contract. A thin plugin wrapper
  can shell out to `scripts/block-hook.sh` (feed it a JSON payload shaped like
  `{tool_name, tool_input}`) and throw if the script's stdout carries a deny decision; consult
  opencode's plugin API docs for the exact call signature `tool.execute.before` receives.
- **`tool.execute.after`** — the capture. Record the call + result to
  `.qa/runs/<run>/toolstream.jsonl`, e.g. by shelling out to `scripts/capture-hook.sh` with the
  same `{tool_name, tool_input, tool_response}` shape it already expects on stdin.

**`deny task` too.** opencode's `task` tool spawns sub-agents; a sub-agent invoked via `task` can
call `browser_evaluate` through its own tool-execute path, which may not visibly compose with a
plugin hook registered against the top-level agent depending on how opencode threads plugin hooks
through sub-agent execution. Explicitly deny/gate the `task` tool itself (or verify the plugin
hook fires for sub-agent tool calls too) so a mutating `browser_evaluate` can't slip through via
an SDK/sub-agent bypass.

**Tamper-resistance:** a project-local `.opencode/` plugin is visible to (and in principle
editable by) the run's own agent process. The matrix's stronger option is a **root-owned**
`/etc/opencode/` `permission` map — outside the project directory the agent operates in — for
real tamper-resistance; a project-local plugin alone is best-effort only, the same caveat Claude's
own Tier A carries (see `docs/harness-adapters.md#the-claude-assurance-tier`).

## Manual-enforcement-run procedure (verify before trusting)

1. Wire the plugin per the mechanism above, on your installed opencode version.
2. Drive the qa-e2e-pilot agent (`/qa-run`) on a disposable app.
3. During the act phase, attempt a mutating `browser_evaluate` — a workaround the
   driving-browser-qa gate itself rejects, so you're deliberately testing the live block here, not
   asking the agent to do this normally.
4. Confirm:
   - (a) **the plugin's `before` hook threw** and the call did not run (opencode's own tool-call
     log/output should show the denial).
   - (b) **the plugin's `after` hook recorded** the surrounding `browser_*` calls to
     `.qa/runs/<run-id>/toolstream.jsonl` in real time.
5. If `tool.execute.before`/`after` don't fire the way you expect (or don't compose through
   `task` sub-agent calls), stop chasing it — the automatic `--save-session` →
   `session-preflight.sh` → toolstream floor (see above) still gives you a high-confidence
   `qa-verify` run from the saved session log alone. The live block is the only piece you lose.

## See also

- `docs/specs/harness-capability-matrix.md` — the Capture/Block/Tamper-resistance row this doc is
  sourced from.
- `docs/harness-adapters.md#the-claude-assurance-tier` — the framing for Claude's own live-hook
  tier (Tier A), which this opencode recipe mirrors in spirit but does not claim parity with.
- `scripts/capture-hook.sh`, `scripts/block-hook.sh` — the shipped hook scripts themselves
  (harness-agnostic; a thin plugin wrapper is what's opencode-specific here).
