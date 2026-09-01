# Multi-harness portability — design

**Status:** design (awaiting review) · **Date:** 2026-09-01 · **Topic:** run `qa-e2e-pilot` on Codex, Pi, and opencode as well as Claude Code.

## Goal

Let the same QA methodology — the 16 skills, the 6-phase orchestrator, the evidence/human-interaction gate — run on **Codex**, **Pi**, and **opencode**, not only Claude Code, **without forking the plugin**. One canonical source of truth; each harness gets a thin adapter.

## Why this is feasible (grounding)

Three parallel research passes (Codex, Pi, opencode) established the make-or-break fact: **every target harness can drive a real browser through the Playwright MCP** — so none is relegated to a degraded "generate-a-checklist-and-hand-off" mode. Pi is already provisioned on this machine (`pi-mcp-adapter` + `@playwright/mcp` wired in `~/.pi/agent/mcp.json`; 102 skills installed incl. this plugin's).

| Concern | Claude Code (done) | Codex | Pi | opencode |
|---|---|---|---|---|
| Browser (Playwright MCP) | ✅ `mcp__plugin_playwright_playwright__browser_*` | ✅ `~/.codex/config.toml` `[mcp_servers.playwright]`; tools `playwright__browser_*` | ✅ `pi-mcp-adapter`, `mcp.json`; proxy tool or `mcp:playwright/browser_*` | ✅ `mcp` block; tools `playwright_browser_*` |
| `--save-session` gate (ADR-0015) | ✅ | ✅ server flag, ports as-is | ⚠️ re-verify under adapter proxy | ✅ server flag |
| Skills (`SKILL.md`) | ✅ native | ✅ Claude-compatible, `.agents/skills/` | ✅ near-verbatim (`pi.skills`) | ⚠️ community `opencode-skills` plugin → `skills_*` tools (no `allowed-tools` enforcement) |
| Subagent fan-out | `Agent`/`subagent_type` | `spawn_agent`/`wait_agent`/`send_message` | `pi-subagents` `subagent` tool | Task tool / `@mention`; `subagent_depth` cap |
| Session-start prereq | SessionStart hook | `[hooks]` `SessionStart` command | extension API or command-step | plugin `session.created` (guard resume) or command-step |
| Commands (`/qa-run`, `/qa-roles`) | `commands/*.md` | skill (preferred) or `~/.codex/prompts/*.md` | prompt-template → slash | `.opencode/command/*.md`, `$ARGUMENTS` |
| Bundled bash/node + `.qa/` state | ✅ | ✅ (sandbox git-handoff caveat) | ✅ | ✅ |

## Scope of v1 (locked in grilling review)

- **Sequential-only.** ADR-0003 makes verification sequential by default; fan-out is opt-in and buys nothing for a correct first port. v1 wires **no** subagent dispatch on any harness. `fanning-out-criteria` per-harness mapping (`spawn_agent`/`subagent`/`Task`) is **deferred to a later phase**, added only after the sequential path is validated. (Q1)
- **The persona body and all 16 skill bodies are shared verbatim**, needing only token substitution — the coupling grep proved the agent body has exactly two Claude-specific lines and skill bodies are prefix-clean. No per-harness body rewrites. (Q7)

## Architecture — shared core + hybrid adapters

Decisions taken: **all three harnesses in one effort**; **hybrid** production of the harness surface (shared core verbatim + hand-authored thin manifests + a *small generator scoped only to tool-naming and token substitution*).

### The shared core (verbatim across harnesses — no logic change)

Already ~90% harness-neutral, because skills call browser tools by **bare capability** (`browser_snapshot`), not by any host-specific prefix (CLAUDE.md convention). The core is:

- **16 skills** — `skills/*/SKILL.md` bodies + their `templates/`.
- **16 bundled skill scripts** (bash + node, dependency-free): `checkpoint.sh`, `record-evidence.sh`, `check-action-trace.js`, `parse-session-log.js`, `preflight.sh`, `observe.js`, `click-by-text.js`, `react-set-input.js`, `backend-probe.js`, `ux-detectors.js`, `frontier.js`, `write-persona-config.sh`, `detect-stack.sh`, `index-routes.sh`, `init-config.sh`, `find-spec-kit.sh`.
- **6 top-level scripts**: `check-prereqs.sh`, `report-to-junit.sh`, `qa-ci.sh`, `memory-sync.sh` (+ `install.sh`, `skills.json` are Claude-specific — see below).
- **`.qa/` file-state model** (ADR-0002), the **ADRs**, `CONTEXT.md`, the **accuracy harness** (`tools/accuracy-harness/`).
- **`driver-capabilities.md`** — the existing capability→tool map.

None of this is copied into per-harness folders in the repo; **the repo root stays the canonical Claude Code plugin AND the shared source of truth.** Adapters read from it.

### The single naming table — `harness-profiles.json`

The one thing that genuinely differs per harness, mechanically and pervasively, is **how a browser capability is named as a grantable tool**. Capture it once:

```jsonc
{
  "claude":   { "toolPrefix": "mcp__plugin_playwright_playwright__", "mcpServerKey": "playwright",
                "grantStyle": "frontmatter-list", "subagentVerb": "Agent/subagent_type",
                "model": { "default": "sonnet", "heavy": "opus" } },
  "codex":    { "toolPrefix": "playwright-qa__",  "mcpServerKey": "playwright-qa",
                "grantStyle": "toml-mcp-scope",   "subagentVerb": "spawn_agent",
                "model": { "default": "gpt-5.1-codex", "heavy": "gpt-5.1-codex" } },
  "pi":       { "toolPrefix": "mcp:playwright-qa/", "mcpServerKey": "playwright-qa",
                "grantStyle": "frontmatter-mcp",  "subagentVerb": "subagent", "mcpMode": "proxy",
                "model": { "default": "…", "heavy": "…" } },
  "opencode": { "toolPrefix": "playwright-qa_",   "mcpServerKey": "playwright-qa",
                "grantStyle": "tools-map",        "subagentVerb": "Task",
                "model": { "default": "…", "heavy": "…" } }
}
```

- The **19 browser capabilities** (`browser_navigate` … `browser_close`) are listed once; the generator produces each harness's tool-grant list by prefixing. (Q3: **server key is `playwright-qa`** everywhere — a unique key so the adapter's `--save-session` instance never collides with, or mutates, a user's pre-existing `playwright` server. On Claude the tool prefix reflects however the official plugin is keyed; the adapter documents using a project-local `playwright-qa` server.)
- **`model`** is a per-harness `{default, heavy}` map (Q2). The generator fills the manifest `model:` field and the two body tokens `{{MODEL_DEFAULT}}`/`{{MODEL_HEAVY}}` from it; the actual model ids for Codex/Pi/opencode are confirmed at implementation time (placeholders `…` above). This replaces the hard `model: sonnet` + "Use Opus…" prose the grep found.
- **`mcpMode`** (Pi only): **proxy** by default — the low-token `mcp` proxy tool, matching `pi-mcp-adapter`'s reason for existing; direct-tool mode is a documented opt-in.

This naming table + the three body tokens (`{{MODEL_DEFAULT}}`, `{{MODEL_HEAVY}}`, `{{SESSION_LOG_DIR}}`) are the *only* structured transforms the generator performs.

### The generator — `scripts/build-adapter.sh <harness>`

Scope is deliberately narrow: **naming and frontmatter only.** It:

1. Reads `harness-profiles.json` + the canonical browser-capability list.
2. Emits the harness's **agent manifest** in the harness's format, with the transformed `tools`/tool-grant list (this replaces the one hand-maintained place the full prefix lives today — `agents/qa-e2e-pilot.md` frontmatter).
3. Emits a harness row into a generated `driver-capabilities.<harness>.md` (or injects a per-harness column) so a skill reader sees the concrete names.
4. Assembles `dist/<harness>/` = **core (copied verbatim)** + **generated manifest** + **hand-authored adapter glue** (below).

`dist/` is git-ignored build output. It is **not** committed; `install-<harness>.sh` runs the build then places files. This keeps the repo drift-free (adapters are derived, not duplicated).

The generator does **not** rewrite skill bodies, scripts, ADRs, or prose — those are copied byte-for-byte, **except** for substituting the three body tokens (`{{MODEL_DEFAULT}}`, `{{MODEL_HEAVY}}`, `{{SESSION_LOG_DIR}}`) in the one shared persona body.

### Session-log directory as a core config value (Q8)

The `.playwright-mcp/session-*/session.md` path (the ADR-0015 Check-0 source) is assumed cwd-relative in `driving-browser-qa/SKILL.md`, the agent body, and `record-evidence.sh`. Since all four harnesses run the **same** `@playwright/mcp --save-session` server the **format is identical** — only the *location* can vary (Pi's `pi-mcp-adapter` may proxy). So promote the directory to one config field:

- `.qa/config.json` → `humanInteraction.sessionLogDir` (default `.playwright-mcp`).
- The scripts read it; the persona body references it via `{{SESSION_LOG_DIR}}`. The **format parser (`parse-session-log.js`) is unchanged** — it is `@playwright/mcp`-format-specific by nature and that format is stable across harnesses.
- **Fallback (Pi-proxy R1):** if no session log is found at `sessionLogDir`, the gate degrades to Check 1∧2∧3 + the "independent verification unavailable" flag — the existing no-`--save-session` degraded mode, no new code path.

### Per-harness hand-authored adapter glue (`harnesses/<h>/`)

Small, readable, reviewed by humans. Each holds only what the generator can't sensibly synthesize:

- **`manifest.tmpl`** — the agent-persona shell in the harness's format (system-prompt reference, model, hook wiring), with a placeholder the generator fills with the transformed tool list.
- **`mcp.snippet`** — the Playwright MCP server declaration for that harness's config (`config.toml` fragment / `mcp.json` entry / `opencode.json` `mcp` block), including `--save-session` + `--output-dir .playwright-mcp` as opt-in args.
- **`commands/`** — `/qa-run` + `/qa-roles` in the harness's command format.
- **`prereq.wiring`** — how `preflight.sh` / `check-prereqs.sh` runs at session start (hook vs command-step).
- **`install-<h>.sh`** — build + place into the harness's discovery dirs.
- **`README.md`** — install + prerequisites for that harness.

## Per-harness adapter specifications

### Codex (`harnesses/codex/`)

- **Skills** → `.agents/skills/*/SKILL.md` (Claude-compatible; port verbatim). Invocable `$skill-name` or by description.
- **Agent** → `~/.codex/agents/qa-e2e-pilot.toml` (`name`, `description`, `developer_instructions` = the persona body, `model`, `mcp_servers = ["playwright"]`). Tool scoping is by MCP-server scope, not a flat list — the generated tool list documents intent; the grant is "this agent gets the `playwright` server."
- **Browser** → **project-local** `.codex/config.toml` `[mcp_servers.playwright-qa]` `command="npx"`, `args=["-y","@playwright/mcp@latest","--save-session","--output-dir",".playwright-mcp"]`. Tools `playwright-qa__browser_*`. Never mutate the user's global `~/.codex/config.toml`.
- **Fan-out** → **deferred (v1 sequential-only, Q1).** Later phase maps to `spawn_agent`/`wait_agent`/`send_message` (no `close_agent`; path-based names); `maxParallel` → `agents.max_concurrent_threads_per_session`.
- **Prereq** → `[hooks]` `SessionStart` `command` runs `preflight.sh`.
- **Commands** → `/qa-run`, `/qa-roles` as **skills** (preferred, future-proof) or `~/.codex/prompts/*.md`.
- **Git finish (sandbox caveat)** → under `workspace-write` the sandbox has **no network** and treats `.git` read-only; `.qa/runs/` writes land fine (in workspace), but **commit/push must be an escalated/approved/CI step** — the adapter documents commit-and-handoff and never assumes the agent can push. Matches our existing "commit/push only when asked."

### Pi (`harnesses/pi/`)

- **Skills** → packaged via `package.json` `pi.skills`, or dropped in `~/.pi/agent/skills/` / `.pi/agents/skills/`. Port near-verbatim.
- **Agent** → `pi-subagents` agent markdown (`.pi/agents/qa-e2e-pilot.md`): frontmatter `name, description, model, skills, tools`. `tools:` may list `mcp:playwright/<tool>` (direct mode) **or** grant the low-token `mcp` proxy tool.
- **Browser** → **project-local** `.pi/mcp.json` `playwright-qa` entry (distinct from the machine's existing global `playwright` server; never mutate it). **Default to the proxy tool** (adapter's raison d'être — avoids MCP context bloat); direct-tool mode is a documented opt-in.
- **Fan-out** → **deferred (v1 sequential-only, Q1).** Later phase uses `pi-subagents` `subagent` tool (single/chain/parallel/async/forked/resume) with the `maxSubagentSpawnsPerRun` budget.
- **Prereq** → extension-API session-start hook **or** run `preflight.sh` as the first step of the `/qa-run` prompt-template. **Decision: command-step** (no extra extension dependency).
- **Commands** → prompt-templates → `/qa-run`, `/qa-roles`.
- **Gaps to design around:** no built-in todo → use `.qa/runs/` + `TODO.md` (already how run-state works, so minor). **`--save-session` reconciliation must be validated under the adapter's proxying before trusting `human-action` verdicts** (see validation bar).

### opencode (`harnesses/opencode/`)

- **Agent** → `.opencode/agent/qa-e2e-pilot.md` (`description`, `mode: primary`, `model`, `permission`, `tools` allow/deny map). Verification personas = `mode: subagent` files.
- **Browser** → **project-local** `opencode.json` `mcp.playwright-qa` (`type: "local"`, `command: ["npx","-y","@playwright/mcp@latest","--save-session","--output-dir",".playwright-mcp"]`). Tools `playwright-qa_browser_*`; agent allows via `tools: { "playwright-qa*": true }`.
- **Skills** → **soft spot**: no first-class skills; enable community `opencode-skills` plugin (`"plugin": ["opencode-skills"]`) → skills become `skills_<name>` tools. **`allowed-tools` is parsed but not enforced** — fine, because **we never relied on skill-level enforcement**: the ADR-0015 act-path gate is the **uniform post-hoc `checkpoint.sh` gate** (same as every harness), backed for free by the agent-level `permission`/`tools` deny map. (Q5: the earlier `tool.execute.before` live-intercept hook is **dropped from the requirement** — kept only as optional documented hardening.)
- **Fan-out** → **deferred (v1 sequential-only, Q1).** Later phase uses Task tool (`subagent_type`) / `@mention`; `subagent_depth` default 1 covers orchestrator→verifier.
- **Prereq** → **command-step** (run `preflight.sh` as the first step of the `/qa-run` command body), for parity with Pi and to avoid opencode's `session.created`-fires-on-resume-replay foot-gun.
- **Commands** → `.opencode/command/*.md` with `$ARGUMENTS`.

## The capability→tool abstraction (the load-bearing rename)

- **Skill bodies stay verbatim** — they already name capabilities, not prefixed tools.
- The **one** place with the full prefix (agent frontmatter) is **generated** per harness from `harness-profiles.json`.
- `driver-capabilities.md` gains a per-harness view (generated) so a reader can resolve a capability to the concrete tool on their harness.
- The `mates`/CDP and agentic-driver rows are unaffected — this adds a harness dimension orthogonal to the existing driver dimension.

## `--save-session` gate portability

`--save-session` is a **`@playwright/mcp` server flag**, not a host feature — so `checkpoint.sh` → `parse-session-log.js` → `check-action-trace.js` reconciliation (ADR-0015 Check 0) is host-agnostic and ports unchanged on Codex and opencode. **Pi is the one place to verify**, because `pi-mcp-adapter` may proxy the server: confirm the `.playwright-mcp/session-*/session.md` file is still written to the workspace and matches the format `parse-session-log.js` expects. If proxying changes the path/format, the Pi adapter documents Check 0 as unavailable (falls back to Check 1∧2∧3 + the "independent verification unavailable" flag, exactly as the no-`--save-session` degraded mode already does).

## Validation bar (definition of done, per harness)

Split into two layers, because they automate very differently (Q4):

1. **Deterministic layer — CI-enforced, per commit.** The generator runs; every emitted manifest is valid for its harness; every browser capability resolves to a real prefixed tool name; token substitution leaves no `{{…}}` behind; all core scripts pass `bash -n` / `node --check`; every JSON validates. This is fully scriptable and is the CI gate (Q4/R5).
2. **Accuracy-recall layer — manual, local, per-harness acceptance.** Serve the accuracy-harness fixture (`tools/accuracy-harness/fixture/`), run the adapter's agent end-to-end on that harness, convert + score the bug-log, and confirm it clears the same gate the Claude path clears (85% overall / 100% precision, blind) — **or** document the specific gap. Running a Codex/Pi/opencode agent headlessly in CI is out of reach, so this is a **documented manual procedure**, not a CI job.

**An adapter is "done" = CI-green (layer 1) AND at least one recorded manual accuracy run at/above gate (or a documented gap) (layer 2).** Pi's end-to-end run is cheapest (already provisioned) and is the first full validation.

## Remaining couplings — dispositions (Q9)

The grep found five coupling sites; all have cheap, decided dispositions:

- `commands/*.md` (`subagent_type` dispatch, `~/.claude/roles` path, slash shape) → **per-harness hand-authored glue** (already planned).
- `qa-ci.sh` default `claude -p "/qa-run …"` → the **default agent-command comes from `harness-profiles.json`**; still `QA_AGENT_CMD`-overridable.
- `init-config.sh` writes `server: "playwright"` → change the written default driver key to **`playwright-qa`** (matches Q3).
- `check-prereqs.sh` `CLAUDE_PLUGIN_ROOT` → **no change needed**; it already has a portable `BASH_SOURCE` fallback that resolves correctly when the var is unset.
- agent frontmatter `tools:`/`model:` + body `{{MODEL_*}}`/`{{SESSION_LOG_DIR}}` → **generator-filled** (above).

## Distribution & versioning (Q6)

- **v1: `install-<h>.sh` from a git clone/checkout for all three** — uniform, no per-harness packaging infrastructure. The installer builds `dist/<h>/`, places files into the harness's discovery dirs, and **reports the version it placed**.
- **Versioning is lockstep with the repo tag** (no independent adapter versions in v1).
- **Native packaging per harness is a documented fast-follow**, not built now: a Pi package (`package.json` `pi.skills`), an opencode `plugin` entry, etc. The install-script path works for all three today.

## Risks & open questions

- **R1 — Pi `--save-session` under proxy**: validate early; if the log isn't at `sessionLogDir` the gate auto-degrades to Check 1∧2∧3 (config-driven, Q8 — no code change).
- **R2 — opencode skill semantics**: `skills_*`-as-tools ≠ progressive disclosure, and `allowed-tools` isn't enforced — **accepted**, because the gate never relied on skill-level enforcement (uniform post-hoc `checkpoint.sh`, Q5). Validate that a mutating act-path `browser_evaluate` is still caught by `checkpoint.sh` on opencode.
- **R3 — Codex sandbox git**: never assume push; commit-and-handoff documented. `.qa/` writes are safe (in workspace).
- **R4 — tool-name drift across `@playwright/mcp` versions**: names vary by version; **pin a version** in each `mcp.snippet` and confirm the tool list on install.
- **R5 — maintenance**: the generator runs in CI as the deterministic gate (Q4 layer 1) so a core change that breaks a harness manifest is caught, not shipped.

## Out of scope (YAGNI)

- Harnesses beyond these four (Antigravity, Cursor, etc.) — the profile table makes them cheap later, but not now.
- Rewriting any skill logic, script, or ADR. The core is frozen for this effort.
- A unified installer that auto-detects the harness — each harness has its own `install-<h>.sh`; auto-detect is a possible later convenience.
- Changing the Claude Code plugin's layout or breaking existing installs — root stays canonical.

## Summary of decisions locked in this design

1. Scope: **Codex + Pi + opencode together**; core frozen; **v1 sequential-only — fan-out deferred** (Q1).
2. Architecture: **shared core at repo root (unchanged) + `harness-profiles.json` + a naming-and-token generator + thin hand-authored `harnesses/<h>/` glue**; adapters built into git-ignored `dist/<h>/`, placed by `install-<h>.sh` (Q6). Persona body + 16 skill bodies are **shared verbatim** with three body tokens (Q7).
3. Profile carries per-harness **model `{default, heavy}`** (Q2) and a **unique `playwright-qa` server key** used in **project-local** config, never mutating global (Q3). Pi browser mode: **proxy by default** (Q3). Prereq: **command-step** on Pi + opencode (Q5-adjacent).
4. Gate: `sessionLogDir` is a **config value** (Q8); `--save-session` ports as-is on Codex/opencode; on Pi it auto-degrades to Check 1∧2∧3 if the proxied log isn't found — no new code path. Act-path gate is the **uniform post-hoc `checkpoint.sh`**; opencode needs **no live hook** (Q5).
5. Done = **CI-green deterministic layer + ≥1 recorded manual accuracy run at/above gate** (or documented gap), per harness (Q4); Pi validated first.
