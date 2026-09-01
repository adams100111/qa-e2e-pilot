# qa-e2e-pilot on opencode

Runs the same 16 skills, 6-phase orchestrator, and human-interaction gate as the Claude Code
plugin, adapted for opencode's agent markdown + `mcp` server config + skill-as-tool plugin. v1 is
**sequential-only** (ADR-0003/Task 10) — nothing here requires or assumes multi-agent dispatch.

## Prerequisites

- The community **`opencode-skills`** plugin installed and enabled (`"plugin": ["opencode-skills"]`
  in `opencode.json`) — it is what turns each bundled `SKILL.md` into a callable `skills_*` tool.
  Without it, the skills copied into `.opencode/skills/` are inert documents opencode never loads.
- `node`/`npx` on PATH (runs `@playwright/mcp` via `npx -y`).
- `python3` (3.11+ recommended — `checkpoint.sh`/`preflight.sh` fall back to it when `jq` is
  absent; the accuracy-harness scorer and CI gate use `python3`/`jq` similarly).
- An opencode CLI that supports project-local `.opencode/agent/*.md`, `.opencode/command/*.md`,
  `.opencode/skills/`, and a project-local `opencode.json` `mcp` block.

## Install

From this repo:

```bash
bash harnesses/opencode/install-opencode.sh <path-to-your-project>
```

This builds `dist/opencode/` (via `scripts/build-adapter.sh opencode`) and copies:

- skills → `<project>/.opencode/skills/`
- the agent manifest → `<project>/.opencode/agent/qa-e2e-pilot.md`
- the `/qa-run` and `/qa-roles` commands → `<project>/.opencode/command/`

It then prints the `mcp` + `plugin` fragment (from `harnesses/opencode/mcp.snippet`) —
**merge that into `<project>/opencode.json` yourself**. The installer never writes to any global
opencode config; the `playwright-qa` server is project-local, uniquely keyed, and pinned to
`@playwright/mcp@0.0.79` (the version `parse-session-log.js` and the accuracy-harness scorer
expect). A pre-existing global or `@latest`-pinned `playwright` server in your own config is fine
to keep for other work — it is simply not the server this gate reads session logs from.

## Skills become `skills_*` tools — `allowed-tools` is not enforced (Q5)

With `opencode-skills` enabled, each bundled `SKILL.md` is exposed to the agent as a callable
`skills_<name>` tool rather than an inline instruction block the agent merely reads. opencode does
**not** enforce a skill's own `allowed-tools` frontmatter the way Claude Code does — a skill
invoked this way can, in principle, reach any tool the *agent* (not the skill) is granted.

This is acceptable for qa-e2e-pilot because skill-level tool enforcement was never the thing this
plugin relies on for safety. The binding control is the **uniform post-hoc act-path gate**
(`checkpoint.sh` + `check-action-trace.js`, and — with `--save-session` — `parse-session-log.js`)
described in ADR-0015: it inspects *what was actually done* (before/after state fingerprints, the
recorded action trace, and, when available, the independent MCP session log) after the fact,
regardless of which skill or tool path produced it. That gate is harness-agnostic and does not
depend on any per-skill tool allowlist being honored.

The agent-level `permission`/`tools` deny map in `harnesses/opencode/manifest.tmpl` (the
`"playwright-qa*": true` glob plus `read`/`write`/`bash`/`grep`/`glob`) is **defense-in-depth** on
top of that — it bounds what the agent process itself can reach — not the primary safety
mechanism. Do not rely on a skill's `allowed-tools` line to constrain behavior under opencode.

See `docs/harness-adapters.md` for the full cross-harness comparison and the manual accuracy-run
procedure (serve `tools/accuracy-harness/fixture/`, point `.qa/config.json` at it, run the agent
end-to-end, convert + score the bug-log against the 85%/100% gate).
