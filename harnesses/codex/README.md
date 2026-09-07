# qa-e2e-pilot on Codex

Runs the same 17 skills, 6-phase orchestrator, and human-interaction gate as the Claude Code
plugin, adapted for Codex's `developer_instructions` agent + `[mcp_servers]` config. v1 is
**sequential-only** (ADR-0003/Task 10) — nothing here requires or assumes `[features]
multi_agent`; no subagent dispatch is wired for Codex in this version.

## Prerequisites

- `node`/`npx` on PATH (runs `@playwright/mcp` via `npx -y`).
- `python3` (3.11+ recommended — `checkpoint.sh`/`preflight.sh` fall back to it when `jq` is
  absent; the accuracy-harness scorer and CI gate use `tomllib`).
- A Codex CLI that supports project-local `.codex/agents/*.toml`, `.codex/prompts/*.md`, and a
  project-local `.codex/config.toml` `[mcp_servers]` block.

## Install

From this repo:

```bash
bash harnesses/codex/install-codex.sh <path-to-your-project>
```

This builds `dist/codex/` (via `scripts/build-adapter.sh codex`) and copies:

- skills → `<project>/.agents/skills/`
- the plugin's grounding files, `CONTEXT.md` and `docs/adr/`, → `<project>/.agents/` (alongside
  the skills, not the project's own root — the persona instructs the agent to read these, but
  the reference is unanchored, so see "Manual accuracy run" below)
- the agent manifest → `<project>/.codex/agents/qa-e2e-pilot.toml`
- the `/qa-run`, `/qa-roles`, and `/qa-resume` prompts → `<project>/.codex/prompts/`

It then prints the `mcp_servers.playwright-qa` fragment (from `harnesses/codex/mcp.snippet`) —
**add that block to `<project>/.codex/config.toml` yourself**. The installer never writes to
`~/.codex/config.toml` or any other global Codex config; the `playwright-qa` server is
project-local, uniquely keyed, and pinned to `@playwright/mcp@0.0.79` (the version
`parse-session-log.js` and the accuracy-harness scorer expect). A pre-existing global or
`@latest`-pinned `playwright` server in your own config is fine to keep for other work — it is
simply not the server this gate reads session logs from.

## Sandbox / git handoff

Codex's default sandbox can be **no-network, read-only-`.git`**. This plugin never assumes it can
`git commit` or `git push` on your behalf. Runs write their evidence and reports to `.qa/runs/`
and leave your working tree with the change staged/ready; **commit and push are an explicit,
escalated step you (or your CI) take afterward** — not something the agent does automatically
mid-run. If you routinely grant Codex network/write access for this project, that's a per-project
choice outside this adapter's scope.

## Manual accuracy run

**accuracy-unvalidated on this harness — see docs/harness-adapters.md (manual accuracy run
required).** No `measured-codex` findings file exists yet under
`tools/accuracy-harness/findings/`; treat this adapter's output as unverified until that run
lands (see `docs/harness-adapters.md`'s manual-accuracy-run section for status).

Before trusting this adapter on your project, run it once against the bundled fixture and score
it — see `docs/harness-adapters.md` for the full procedure (serve
`tools/accuracy-harness/fixture/`, point `.qa/config.json` at it, run the agent end-to-end,
convert + score the bug-log against the acceptance gate). The enforced gate
(`tools/accuracy-harness/seeds.json`'s `gate` block) is **functional recall ≥ 70%, ux-objective
recall ≥ 75%, overall verdict recall ≥ 70%, precision ≥ 80%** — the "78% functional / 100%
ux-objective / 85% overall / 100% precision" figure quoted in `tools/accuracy-harness/README.md`
is the *measured* reference number from the Claude harness run, not the enforced threshold; a
harness only needs to clear the gate above, not match that number.

The installer places `CONTEXT.md` and `docs/adr/` alongside the installed skills (see "Install"
above) because the persona instructs the agent to read them — but that reference is unanchored,
so whether Codex's runtime actually resolves those paths from its cwd/plugin-root depends on the
Codex build. This is **not validated by `validate-adapters.sh`**; confirming the agent can
actually read `CONTEXT.md`/`docs/adr/` is part of this manual accuracy-acceptance run, not a
claim made in advance.
