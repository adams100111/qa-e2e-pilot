# Running qa-e2e-pilot on other harnesses

`qa-e2e-pilot` was built as a Claude Code plugin. Since [ADR-0017](./adr/0017-multi-harness-portability.md),
the same 16 skills, 6-phase orchestrator, and human-interaction gate (ADR-0015) can also run on
**Codex**, **Pi**, and **opencode** — generated from one shared core (`core/` + `skills/` + `scripts/`)
via `harness-profiles.json` and `scripts/build-adapter.sh` into thin, per-harness adapters under
`harnesses/<h>/`. v1 is **sequential-only** on every harness — no adapter wires subagent fan-out
(`fanning-out-criteria` dispatch is deferred; see ADR-0017 and ADR-0003).

Each adapter is generated into git-ignored `dist/<h>/`; nothing under `dist/` is committed. Run the
install script to build and place it into your target project.

**Pi is validated first** (already provisioned) — if you're choosing which harness to bring up and
verify first, start there. Codex and opencode follow the identical procedure below.

---

## Common ground across all three non-Claude harnesses

- **Project-local only.** No installer writes to a harness's global config (`~/.codex`, `~/.pi`, the
  user-level opencode config). Everything lands under the target project's own directory.
- **A unique `playwright-qa` MCP server key.** Claude keeps the official `playwright` server key
  (installed alongside the Claude Code plugin). Codex, Pi, and opencode each add a **project-local**
  server keyed `playwright-qa` — never overwriting or mutating a global config, and never colliding
  with a `playwright` server you may already have configured for other work.
- **Pinned to `@playwright/mcp@0.0.79`.** The `playwright-qa` server in every non-Claude
  `mcp.snippet` is pinned to this exact version — the session-log format `parse-session-log.js` and
  the accuracy-harness scorer both expect. **The human-interaction gate's Check 0 reads session logs
  only from the pinned `playwright-qa` server.** A coexisting `playwright` server on `@latest` (or any
  other version) is completely fine to keep around for *driving* the browser on other work — it is
  simply not the server this gate treats as evidence.
- **The uniform post-hoc gate.** Regardless of tool-grant style (per-tool list, server-scope, proxy
  tool, or glob), the same `checkpoint.sh` + `check-action-trace.js` (+ `parse-session-log.js` when
  `--save-session` is enabled) inspects what was actually done after the fact. No harness relies on its
  own tool-enforcement mechanism as the safety boundary.

---

## Codex

**Prerequisites:** `node`/`npx` on PATH (runs `@playwright/mcp` via `npx -y`); `python3`
(3.11+ recommended); a Codex CLI that supports project-local `.codex/agents/*.toml`,
`.codex/prompts/*.md`, and a project-local `.codex/config.toml` `[mcp_servers]` block.

**Install:**

```bash
bash harnesses/codex/install-codex.sh <path-to-your-project>
```

This builds `dist/codex/` (via `scripts/build-adapter.sh codex`) and copies skills into
`<project>/.agents/skills/`, the agent manifest into `<project>/.codex/agents/qa-e2e-pilot.toml`, and
the `/qa-run` + `/qa-roles` prompts into `<project>/.codex/prompts/`.

**Project-local config to add:** the installer prints the `mcp_servers.playwright-qa` fragment (from
`harnesses/codex/mcp.snippet`) — add it to `<project>/.codex/config.toml` yourself:

```toml
[mcp_servers.playwright-qa]
command = "npx"
args = ["-y", "@playwright/mcp@0.0.79", "--save-session", "--output-dir", ".playwright-mcp"]
```

The installer never touches `~/.codex/config.toml`. Note also that Codex's default sandbox can be
no-network/read-only-`.git` — this adapter never assumes it can commit/push on your behalf; see
`harnesses/codex/README.md` for the sandbox/git-handoff note.

---

## Pi

**Prerequisites:** a Pi CLI/runtime with `pi-mcp-adapter` installed and configured to read a
project-local `.pi/mcp.json`; `node`/`npx` on PATH; `python3` (3.11+ recommended).

**Install:**

```bash
bash harnesses/pi/install-pi.sh <path-to-your-project>
```

This builds `dist/pi/` (via `scripts/build-adapter.sh pi`) and copies skills into
`<project>/.pi/agents/skills/`, the agent manifest into `<project>/.pi/agents/qa-e2e-pilot.md`, the
`/qa-run` + `/qa-roles` prompts into `<project>/.pi/prompts/`, and the `mcpServers` fragment straight
into `<project>/.pi/mcp.json`:

```json
{
  "mcpServers": {
    "playwright-qa": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@0.0.79", "--save-session", "--output-dir", ".playwright-mcp"]
    }
  }
}
```

**Proxy grant.** Pi's agent manifest grants the `mcp` proxy tool (not per-capability browser tools);
the agent calls `playwright-qa`'s methods through that single proxy (`harness-profiles.json`'s
`pi.grantStyle: "proxy"`, `pi.toolPrefix: "mcp:playwright-qa/"`). This is the supported default.
Direct-tool mode (if your Pi build exposes MCP tools without the proxy) is an unsupported, unscored
opt-in — see `harnesses/pi/README.md`.

**R1 caveat.** Validate that `--save-session` actually writes `.playwright-mcp/session-*/session.md`
under your Pi build's proxy layer before relying on Check 0 — some proxies may not surface the
underlying server's `--save-session` output faithfully. If it doesn't, the gate degrades to
**Check 1 ∧ Check 2 ∧ Check 3** and the report flags independent verification as unavailable, rather
than failing the run. This is the one runtime unknown ADR-0017 leaves open.

---

## opencode

**Prerequisites:** the community **`opencode-skills`** plugin installed and enabled
(`"plugin": ["opencode-skills"]` in `opencode.json`) — without it the copied `SKILL.md` files are
inert documents opencode never loads; `node`/`npx` on PATH; `python3`; an opencode CLI that supports
project-local `.opencode/agent/*.md`, `.opencode/command/*.md`, `.opencode/skills/`, and a
project-local `opencode.json` `mcp` block.

**Install:**

```bash
bash harnesses/opencode/install-opencode.sh <path-to-your-project>
```

This builds `dist/opencode/` (via `scripts/build-adapter.sh opencode`) and copies skills into
`<project>/.opencode/skills/`, the agent manifest into `<project>/.opencode/agent/qa-e2e-pilot.md`, and
the `/qa-run` + `/qa-roles` commands into `<project>/.opencode/command/`.

**Project-local config to add:** the installer prints the `mcp` + `plugin` fragment (from
`harnesses/opencode/mcp.snippet`) — merge it into `<project>/opencode.json` yourself:

```json
{
  "mcp": {
    "playwright-qa": {
      "type": "local",
      "command": ["npx", "-y", "@playwright/mcp@0.0.79", "--save-session", "--output-dir", ".playwright-mcp"],
      "enabled": true
    }
  },
  "plugin": ["opencode-skills"]
}
```

**`allowed-tools` is not enforced under opencode.** A skill exposed as a `skills_*` tool can, in
principle, reach any tool the *agent* is granted — opencode does not enforce a skill's own
`allowed-tools` frontmatter the way Claude Code does. This is acceptable here because the binding
control is the uniform post-hoc `checkpoint.sh` gate (see "Common ground" above), not per-skill tool
enforcement; the agent-level glob grant (`"playwright-qa*": true` + `read`/`write`/`bash`/`grep`/`glob`)
is defense-in-depth on top of that, not the primary mechanism.

---

## Manual accuracy procedure (required per harness before trusting an adapter)

`scripts/validate-adapters.sh` (the CI gate) only proves an adapter **builds** correctly — structurally
valid output, the Claude byte-oracle, no residual `{{tokens}}`, every capability resolved to a
prefixed tool. It does not prove an adapter's agent **behaves** correctly end-to-end. Before relying on
a harness for real QA work, run its agent once against the bundled accuracy fixture and score the
result:

1. **Serve the fixture:**
   ```bash
   cd tools/accuracy-harness
   ./run-baseline.sh --serve         # serves fixture/ at http://localhost:8099
   ```
2. **Point `.qa/config.json` at it** — `baseUrl: "http://localhost:8099"`, single-repo (the fixture is
   black-box; no backend repo needed since `seeds.json` supplies the oracle).
3. **Run the adapter's agent end-to-end** against that config using the harness's own dispatch (e.g.
   Codex: `codex exec "/qa-run ..."`; Pi: the `/qa-run` prompt-template; opencode: the `/qa-run`
   command with `agent: qa-e2e-pilot`) — see each harness's section above for the install path and
   `harness-profiles.json`'s `dispatch`/`agentCmd` fields for the exact invocation shape.
4. **Convert the run's bug-log:**
   ```bash
   node tools/accuracy-harness/scorer/convert-buglog.js <run>/bug-log.json > \
     tools/accuracy-harness/findings/measured-<harness>-run.json
   ```
5. **Score against the acceptance gate:**
   ```bash
   node tools/accuracy-harness/scorer/score.js \
     tools/accuracy-harness/findings/measured-<harness>-run.json --gate
   ```
   `score.js --gate` exits non-zero if the run falls below the configured thresholds in
   `tools/accuracy-harness/seeds.json` — currently **functional recall ≥ 70%, ux-objective recall ≥ 75%,
   overall verdict recall ≥ 70%, precision ≥ 80%**. (For calibration context, the reference Claude run
   measured 78% functional / 100% ux-objective / 85% overall / 100% precision — well clear of the gate;
   see `tools/accuracy-harness/README.md`'s "What this harness proves" table. Those are the *measured*
   numbers, not the enforced minimums.)
6. **Record the result.** If the harness clears the gate, note the measured numbers (recall per axis,
   precision) alongside the run in your own tracking. If it doesn't, document the gap — which axis
   missed and why — rather than silently shipping a below-gate adapter as validated.

Repeat this once per harness before treating that harness's adapter as accuracy-validated. Pi should be
the first one run through this procedure.

**Also confirm grounding-file resolution as part of this run.** Each non-Claude installer places the
plugin's grounding files — `CONTEXT.md` and `docs/adr/` — alongside the installed skills (Codex:
`<project>/.agents/`; Pi: `<project>/.pi/agents/`; opencode: `<project>/.opencode/`), because the
shared persona (`core/persona-body.md`) instructs the agent to read them. That reference is
*unanchored* — whether the agent's cwd/plugin-root at runtime actually resolves those relative paths
is harness- and build-specific and is **not** checked by `validate-adapters.sh`. Confirming the agent
can actually open `CONTEXT.md`/`docs/adr/` from within a real run is part of this manual
accuracy-acceptance step, not something to assume works from the install step alone.
