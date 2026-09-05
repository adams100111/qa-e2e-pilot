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

## Installing qa-kit (all four harnesses since increment 7)

`qa-kit` is a **second plugin** in this same repo/marketplace — a spec-kit-style, step-gated QA
process shell (`/qa-constitution` → `/qa-spec` → `/qa-scenarios` → `/qa-analyze` → `/qa-run`, plus
`/qa-status`) layered over the qa-e2e-pilot **engine**.

**On Claude** it ships as a plugin via the **dependencies model** (see
[ADR-0022](./adr/0022-qa-kit-process-shell.md) + the `qa-kit-plugin-packaging-facts` memory):

- Enable the `qa-kit` entry from this marketplace. Its `plugin.json` declares
  `"dependencies": ["qa-e2e-pilot"]`, so Claude co-installs/enables the engine plugin — qa-kit reuses
  the engine's skills by qualified slug (`/qa-e2e-pilot:<skill>`) and bundles its own scripts under
  `qa-kit/` (reached via qa-kit's own `${CLAUDE_PLUGIN_ROOT}`).
- No symlinks and no file duplication of the engine's skills.

**On Codex, Pi, and opencode** (since increment 7, [ADR-0024](./adr/0024-qa-kit-multi-harness.md))
qa-kit is generated from the shared `qa-kit/core/` — the same ADR-0017 pattern as the engine,
qa-kit-owned — into git-ignored `qa-kit/dist/<h>/`, then installed by a per-harness script. **The
engine adapter for that harness must be installed FIRST** (the co-install contract): qa-kit's step
commands reference the engine's skills, and each installer aborts if the engine's skills dir is absent.

```bash
# 1) engine adapter first (populates the shared skills dir)
bash harnesses/pi/install-pi.sh <project>            # or codex/opencode
# 2) then qa-kit
bash qa-kit/harnesses/pi/install-pi.sh <project>     # or codex/opencode
```

Skill references render per harness — Claude uses the `/qa-e2e-pilot:<skill>` slug; **Pi and Codex**
use a bare `` the `<name>` skill `` (the agent reads `.pi/agents/skills/<name>/` resp. `.agents/skills/<name>/`);
**opencode** uses the `skills_<name>` tool and therefore **requires the community `opencode-skills`
plugin** enabled in `opencode.json` (else the skills are inert). See each
`qa-kit/harnesses/<h>/README.md`. A live end-to-end qa-kit run per non-Claude harness is the **manual
accuracy run** — the generator + composition are unit-tested (`tests/qakit-adapters/run.sh`), the live
agent behaviour is not.

---

## The Claude assurance tier

`qa-e2e-pilot`'s evidence gate (`checkpoint.sh` + `check-action-trace.js`) is a **post-hoc, uniform check** every harness runs — it inspects what the run's own agent claims to have done, after the fact. Plan H2 (WS-3, "sound core") adds a second, independent layer on Claude Code specifically: live hooks that record and, for the narrowest cases, block — plus `qa-verify`, the deterministic out-of-agent re-check that is the actual authority (`scripts/qa-verify.sh`, see [`docs/running-in-ci.md`](./running-in-ci.md#qa-verify-the-out-of-agent-authority)).

**Tier A — Claude Code (live, best-effort):**

- **`PostToolUse` capture-hook** (`scripts/capture-hook.sh`) appends every `Bash` and `browser_*` tool call to `.qa/runs/<run-id>/toolstream.jsonl`, secret-redacted, resolved via `.qa/runs/latest`. It's wired inline in `.claude-plugin/plugin.json`'s bundled `hooks` object — no per-project config step, it ships with the plugin.
- **`PreToolUse` block-hook** (`scripts/block-hook.sh`) denies the narrow, phase-independent absolutes: a mutating `browser_evaluate` (via the same `mutates()` classifier `parse-session-log.js` uses) and `browser_run_code_unsafe`. It does **not** attempt to block anything nuanced (provenance, persona-identity, required-kinds) — those stay record-only, checked later by `qa-verify`, because live-blocking a false positive is worse than a late catch.
- **The caveat, stated plainly:** both hooks are **best-effort and tamper-*evident*, not tamper-proof**. An agent with `Bash` access can, in principle, edit the hook scripts themselves or the `toolstream.jsonl` file on an unhardened install — there is no hash-chain (deliberately cut; a hash an agent can recompute is false assurance, not real protection) and no sandboxing at this tier. Real tamper-*resistance* needs a hardened tier (a managed/sandboxed execution environment the run's own agent process cannot write into) — documented as a future direction, not built here.
- **Script-integrity is the open residual.** Nothing in Tier A proves `capture-hook.sh`/`block-hook.sh` themselves haven't been modified before a run starts. This is exactly why `qa-verify` — run out-of-agent, by the operator or CI, never by the run's own process — is the piece actually trusted for a "verified" claim, not the live hooks.

**`qa-verify` is the universal floor.** Unlike the hooks, `scripts/qa-verify.sh` has no harness-specific dependency — it's a plain jq/python3 script that re-derives required evidence, re-validates artifacts, and binds provenance against whatever toolstream exists (or degrades honestly to `confidence: low` when none does). It runs the same way regardless of which harness produced the run. **The authoritative verdict is always `qa-verify`'s, never the live hooks' mere presence** — a run with Tier A hooks enabled is not "trusted" because the hooks ran; it's trusted (to the extent it is) because `qa-verify` independently corroborated the evidence against what those hooks captured.

**Other three adapters — no live hooks yet (Plan H3), but they are no longer toolstream-blind
(Plan H4/T-13).** Codex, Pi, and opencode still have no `PostToolUse`/`PreToolUse` (or equivalent)
*live* capture/block mechanism wired up by default — that piece is documented, optional hardening,
covered below. What changed: they're no longer left with **nothing** for `qa-verify` to corroborate
against either. Don't read "the adapter builds and passes `validate-adapters.sh`" as "this harness
has the same assurance tier as Claude" — it doesn't — but do read it as "this harness's high-stakes
passes bind provenance at high confidence by default," which is new.

---

## The automatic enforcement floor (all harnesses)

Every harness profile's `playwright-qa` MCP server runs with `--save-session` (see each
`mcp.snippet` below). That session log, `.playwright-mcp/session-*/session.md`, was previously only
consumed by the human-interaction gate's Check 0 (`parse-session-log.js`) inside a single run. Since
portable-enforcement H4/T-13, it's also the input to a second path:

1. **`skills/driving-browser-qa/scripts/session-to-toolstream.js`** converts the saved session log
   into the same event shape (`{tool, args, resultDigest, responseBody}`) the Claude capture-hook
   writes — reusing `parse-session-log.js` as the single source of truth for parsing, so both paths
   classify calls identically.
2. **`scripts/session-preflight.sh <run-id>`** runs that converter before `qa-verify` and appends
   its output to `.qa/runs/<run-id>/toolstream.jsonl` via `toolstream.sh append`. It's
   **idempotent and non-destructive**: a no-op if a toolstream already exists (it never clobbers a
   live-hook capture) and a no-op if no session log is resolvable (the honest no-toolstream degrade
   still applies). It's wired **non-fatally** into `scripts/qa-ci.sh` — a preflight failure logs and
   the run still proceeds to `qa-verify` as before (`QA_SKIP_SESSION_PREFLIGHT=1` to skip it
   entirely).
3. **`qa-verify`** then binds provenance against that toolstream exactly as it would against a
   live-hook capture — the check doesn't know or care which of the two produced the file.

**Net effect:** this is the **tested, guaranteed tier on every harness** — no per-harness hook
config, no runtime dependency on Codex/opencode/Pi hook support. A `human-action`/cross-tenant
`pass` on any of the four harnesses now binds provenance at **high confidence** by default, as long
as `--save-session` produced a log for `qa-verify` to convert.

**Honest residuals, stated plainly:**
- The converted toolstream is **`browser_*` only** — `session.md` has no visibility into `Bash`
  calls. Claude's live capture-hook remains the only source that captures `Bash` into the
  toolstream; a converted toolstream never corroborates a `Bash`-evidenced artifact.
- The live **block** (denying a mutating call *before* it runs) is not part of this floor — see
  "Per-harness tiers" below. Without the optional live-hook recipe, a mutating call on
  Codex/opencode/Pi is caught by `qa-verify`'s post-hoc override, not prevented up front.
- The session log is **agent-side** — the same trust level as the capture-hook's toolstream on an
  unhardened install (tamper-*evident*, not tamper-*proof*; see the Claude tier above). This floor
  doesn't claim a new, stronger trust tier — it extends the existing one to harnesses that
  previously had none.

## Per-harness tiers

| Harness | Automatic floor | Live hooks |
|---|---|---|
| Claude | `--save-session` → toolstream → `qa-verify` (high confidence) | **Built-in** — capture + block, plugin-bundled (see "The Claude assurance tier" above) |
| Codex | `--save-session` → toolstream → `qa-verify` (high confidence) | Optional, documented recipe (`harnesses/codex/hooks.md`), verify-on-build |
| opencode | `--save-session` → toolstream → `qa-verify` (high confidence) | Optional, documented recipe (`harnesses/opencode/hooks.md`), verify-on-build |
| Pi | `--save-session` → toolstream → `qa-verify` (high confidence) | Optional, documented recipe (`harnesses/pi/hooks.md`), verify-on-build |

The live **block** — denying a mutating `browser_evaluate`/`browser_run_code_unsafe` before it
executes — stays a Claude-only guarantee unless you wire the optional recipe for your harness;
`qa-verify`'s post-hoc override (a captured mutating call with no artifact accounting for it fails
the gate) covers the same case everywhere else, just after the fact rather than before. None of the
three recipes are runtime-verified in this repo — no live Codex/opencode/Pi runtime is available
here — each `hooks.md` carries its own honesty banner and asks you to confirm the exact hook syntax
against your pinned version before relying on it.

## Manual live-hook enforcement run (optional, after wiring a recipe)

If you wire one of the `harnesses/<h>/hooks.md` recipes, confirm it actually works before trusting
it as more than documentation:

1. Wire the hook config per your harness's `hooks.md` (Codex: `.codex/config.toml` or a managed
   `requirements.toml`; opencode: its `permission`/hook config; Pi: its cooperative config +
   optional container).
2. Drive the adapter's agent on a disposable app (the accuracy-harness fixture from the "Manual
   accuracy procedure" below works fine for this too).
3. Attempt a mutating `browser_evaluate` (or ask the agent to attempt one) mid-run and confirm the
   call is **denied before it executes** — not merely flagged afterward.
4. Inspect `.qa/runs/<run-id>/toolstream.jsonl` and confirm the attempted call (and the surrounding
   `browser_*` activity) was **captured in real time**, not only reconstructed later by
   `session-preflight.sh` from the saved session log.

If either check fails, the recipe didn't wire up on your build — fall back to the automatic floor
above, which still gives you a high-confidence `qa-verify` run without the live hook.

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
- **Resume is the same portable `/qa-resume` on every harness — there is no session hook.** A run's
  resume path (ADR-0020 Plan B) is `/qa-resume [run-id]` + `.qa/runs/latest`, identical across Claude,
  Codex, Pi, and opencode. Auto-rehydrate mid-run (landing on the same cursor after an *induced*
  context compaction, with no explicit `/qa-resume` call) is a **protocol step**, not a hook: the
  agent's own prose re-reads `fold(journal)` at every phase entry. `harness-profiles.json` has no
  hooks field today — there is no Claude/Codex/Pi SessionStart hook wired up for resume, and opencode has no
  session-hook mechanism at all to wire one into. A harness-specific hook is a possible future
  accelerant on top of the protocol step; it is not built, and no harness should be assumed to have
  one.

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
