# Codex — optional live-hook hardening

> ⚠️ **Honesty banner.** This recipe is **documented, not runtime-verified** in this repo's CI —
> there is no access to a live Codex runtime here. The exact hook-config syntax is per **your**
> Codex CLI's own docs and **your pinned version**; verify it on your build before relying on it.
> The guaranteed, tested tier is the automatic `--save-session` → toolstream → `qa-verify` floor
> described below, which needs no hook at all.

## The automatic floor (read this first — hooks are optional)

Every harness's bundled Playwright MCP server (`playwright-qa`, pinned to
`@playwright/mcp@0.0.79`, see `harnesses/codex/mcp.snippet`) runs with `--save-session`.
`scripts/session-preflight.sh` derives `.qa/runs/<run>/toolstream.jsonl` from that session log
before `qa-verify` runs, so `qa-verify` binds provenance at **high confidence** with **no live
hook required**. The live hooks documented below are optional hardening that add real-time
capture (as the run happens, not reconstructed afterward) and a live pre-run block (denying a
mutating call before it executes, not just catching it after the fact). If they don't wire up on
your build, you lose only the live block — the automatic floor still gives you a high-confidence
`qa-verify` run.

## Mechanism

Codex supports `PreToolUse`/`PostToolUse` hook wiring in its config — project-local
`.codex/config.toml` or (stronger) a managed `requirements.toml` applied outside the sandbox.
The mechanism, matched against the `playwright-qa` MCP server's `browser_*` tool ids (Codex tool
ids for an MCP server typically take a `<server>__<tool>` shape, e.g.
`playwright-qa__browser_evaluate` — **confirm the exact id format your Codex build produces**,
e.g. via its tool-listing/trace output, since this is exactly the kind of naming detail that
churns across versions):

- **`PreToolUse`** → invoke `scripts/block-hook.sh` on `playwright-qa__browser_evaluate` and
  `playwright-qa__browser_run_code_unsafe` (or the widest `playwright-qa__browser_*` matcher your
  config syntax supports — `block-hook.sh` itself only denies those two tool names, everything
  else is a fast allow). Deny semantics: the hook reads the same PreToolUse JSON contract Claude
  uses (`tool_name`/`tool_input` on stdin) and, on a mutating `browser_evaluate`, must cause Codex
  to refuse the call before it runs.
- **`PostToolUse`** → invoke `scripts/capture-hook.sh` on `playwright-qa__browser_*` (and
  optionally `Bash`) to append each call to `.qa/runs/<run>/toolstream.jsonl` in real time.

Consult Codex's own hook documentation for the exact `config.toml`/`requirements.toml` table
shape, matcher syntax, and how it passes tool-call JSON to an external command — that contract is
Codex's to define and is not restated here as if this repo were authoritative on it.

**Caveat (from `docs/specs/harness-capability-matrix.md`):** some Codex builds restrict hooks to
Bash-only tool calls and do **not** fire `PreToolUse`/`PostToolUse` on MCP tools at all. **You
must verify Pre/PostToolUse actually fire on the MCP `playwright-qa__browser_*` tools on your
pinned Codex version** before trusting the live block — don't assume it from this doc.

**Strongest tier:** a managed `requirements.toml` applied **outside the sandbox** (with
`allow_managed_hooks_only` and a read-only `.codex/`, per the matrix) is the agent-proof
configuration (rated `A+` in the capability matrix) — the run's own agent process cannot edit or
disable it, unlike a project-local `config.toml` hook the agent can see and potentially rewrite.
Prefer the managed tier over project-local `config.toml` wherever your Codex deployment supports
it.

## Manual-enforcement-run procedure (verify before trusting)

1. Wire the hooks per the mechanism above, on your pinned Codex build.
2. Drive the qa-e2e-pilot agent (`/qa-run`) on a disposable app.
3. During the act phase, attempt a mutating `browser_evaluate` (e.g. one that writes to the DOM
   or calls a mutating fetch) — this is a workaround the driving-browser-qa gate itself rejects,
   so you're deliberately testing the live block, not asking the agent to do this normally.
4. Confirm:
   - (a) **block-hook denied it** — the call did not run, and the hook's deny reason appears in
     Codex's own tool-call log/output.
   - (b) **capture-hook recorded** the surrounding `browser_*` calls to
     `.qa/runs/<run-id>/toolstream.jsonl` in real time (inspect the file while the run is still
     in progress, not just after).
5. If Pre/PostToolUse do **not** fire on MCP tools on your build, stop chasing it — the automatic
   `--save-session` → `session-preflight.sh` → toolstream floor (see above) still gives you a
   high-confidence `qa-verify` run from the saved session log alone. The live block is the only
   piece you lose; there is no silent degrade to worry about.

## See also

- `docs/specs/harness-capability-matrix.md` — the Capture/Block/Tamper-resistance row this doc is
  sourced from.
- `docs/harness-adapters.md#the-claude-assurance-tier` — the framing for Claude's own live-hook
  tier (Tier A), which this Codex recipe mirrors in spirit but does not claim parity with.
- `scripts/capture-hook.sh`, `scripts/block-hook.sh` — the shipped hook scripts themselves
  (harness-agnostic; they read the same PreToolUse/PostToolUse-shaped JSON contract on stdin).
