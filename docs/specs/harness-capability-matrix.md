# Harness capability matrix — enforcement + vision + build primitives

**Status:** reference (2026-09-02) · Grounds both `2026-09-02-qa-honesty-hardening-design.md` (ADR-0018) and `2026-09-02-human-eye-ux-detection-design.md` (ADR-0019). Informs (does **not** override) the already-merged `harness-profiles.json`. Sourced from live API research (Claude Code docs; openai/codex source + docs; anomalyco/opencode source + docs; `@earendil-works/pi-coding-agent` local install + docs). **Model ids churn quarterly — pin at implementation against each harness's live model catalog; the load-bearing facts are the capability flags.**

## The matrix

| Axis | **Claude Code** | **Codex** | **opencode** | **Pi** |
|---|---|---|---|---|
| **Capture** (post-hook — records call **+ result**) | `PostToolUse` | `PostToolUse` (⚠️ MCP-hook coverage version-dependent) | `tool.execute.**after**` | `tool_result` |
| **Block** (pre-hook — deny **before** running) | `PreToolUse` deny | `PreToolUse` deny (⚠️ version-dependent) | **throw** in `tool.execute.**before**` | `tool_call` → `{block:true}` |
| **Tamper-resistance** | plugin-bundled hook **config** (undisable-able via settings); **script-integrity needs hardening** | ✅✅ managed `requirements.toml` outside sandbox + `allow_managed_hooks_only` + `.codex/` read-only + no-net (enterprise) | root-owned `/etc/opencode/` `permission` map (+ must `deny task` — SDK/sub-agent bypass) | cooperative (no built-in sandbox) → `path`-deny on own config + OS container (Gondolin/Docker) |
| **Vision** | ✅ MCP-img **+** Read-PNG | ✅ MCP-img (PR#5600); ⚠️ `#10334` drops `content[]` if `structuredContent` present; `localImage`/`--image` disk fallback | ✅ Read-PNG (disk, source-confirmed); MCP-block **unconfirmed** | ✅ core+model support; ⚠️ depends on `pi-mcp-adapter` mapping the image block to `ImageContent` (**verify**) |
| **Model** default / heavy | Sonnet / Opus (all vision) | `gpt-5.6-sol`@medium / @high·xhigh (avoid text-only `gpt-5.3-codex-spark`) | Sonnet-4.5 / Opus-4.5·GPT-5.2 (vision per `capabilities.input.image`) | `gpt-5.5`@thinking / @xhigh (no distinct heavy tier) |
| **Reasoning/effort** | `effort: low..max` | `model_reasoning_effort: none..xhigh` | per-model `reasoningEffort`/`thinking` | `thinkingLevel: off..max` |
| **Skills** | native; `.claude/skills`; no tool-scope in frontmatter | `$name`/SKILL.md; `allow_implicit_invocation` toggle | **native now**; reads `.claude/skills` directly | native; reads `.claude`+`.codex` skills; name≠dir OK |
| **Memory (portable)** | `.qa/` files (native memory is Claude-only) | `.qa/` files (AGENTS.md static) | `.qa/` files (AGENTS.md) | `.qa/` files + `appendEntry` pointer |
| **Subagents** | 20 concurrent; `SendMessage` | `spawn_agent`/`wait_agent`/`send_message`; **no concurrency cap** | `task`, depth 1, **text-only results** | example ext: 8 tasks / 4 concurrent (or `pi-subagents` pkg) |
| **MCP** | native (plugin `.mcp.json`) | `config.toml` `[mcp_servers]` | `opencode.json` `mcp` block | **no native MCP** → `pi-mcp-adapter` extension |
| **`--save-session`** | ✅ native | ✅ (avoid a `structuredContent`-enriching proxy) | ✅ (`--output-dir`) | ✅ passes through the adapter to the workspace, standard format (resolves ADR-0017 R1) |
| **Ship idiom** | plugin.json + hooks.json + skills/ + agents/ | `~/.codex/config.toml` + `$name` skills + AGENTS.md | `.opencode/agent/*.md` + `opencode.json` + `.opencode/command/*.md` (`$ARGUMENTS`) | extension factory + `package.json` `pi.skills` + adapter config |

## Portable design contracts (both specs honor these)

1. **Vision = disk-file + per-harness read binding.** Screenshot → `--output-dir` PNG → the harness's disk-image mechanism (Read on Claude/opencode; `localImage` on Codex; adapter-`ImageContent`/Read on Pi). Sidesteps every MCP-content-block quirk. Free — `--output-dir` is already set for `--save-session`.
2. **Core + thin adapter, capability-by-name.** Enforcement, vision, and skills all follow ADR-0017's shape: logic once in `core/`, a ~20-line per-harness adapter binds the native primitive.
3. **`.qa/` files are the universal state layer** (ADR-0002 holds on all four).
4. **Skills load cross-harness** — all four read `SKILL.md`; opencode + Pi read `.claude/skills` directly. **opencode has native skills now** → supersedes ADR-0017's "opencode soft-spot" premise.
5. **Enforcement floor = out-of-agent `qa-verify`**; native hooks are the live tier, strongest-per-harness.
6. **Never split screenshot-take from screenshot-judge across a subagent boundary** (opencode discards image parts across `task`; sequential-by-default v1 sidesteps it).
7. **The core loop never blocks on a human — fully autonomous** (tests *like* a human, not *with* one). No HITL row is needed: interactive-prompt mechanics are out of scope for the core; the agent adjudicates deliberate-vs-bug from the code itself (UX spec §6). Optional human curation of `.qa/*` files is never required and never gates a run.

## Open verification items (become plan tasks, not blockers)
- **Pi:** confirm `pi-mcp-adapter` forwards the MCP image block as `ImageContent` (not stringified). If not, Pi layer-3 uses disk-file + `read`.
- **Codex:** avoid `structuredContent`-enriched screenshot results (`#10334`); pin vision via `model/list` `inputModalities`; **verify `PreToolUse`/`PostToolUse` actually fire on MCP `playwright-qa__browser_*` — some builds restrict hooks to Bash-only; pin a Codex version and test.**
- **opencode:** prefer the Read-PNG path (MCP-block forwarding unconfirmed).
- **All:** pin model ids at implementation via each harness's live catalog.

## `harness-profiles.json` — reconciled with the merged file (do not conflict)

The file **already exists** (merged, ADR-0017). Its real schema per harness is `modelField` + `tierDefault`/`tierHeavy` **prose** (e.g. Claude `"sonnet"`/`"Sonnet"`/`"Opus"`; non-Claude `modelField: ""`, `tierDefault: "the default"`, `tierHeavy: "the most-capable"`) — **not** a `{default, heavy}` id-map. The other session **deliberately left non-Claude models generic**, which our own "ids churn quarterly" caveat vindicates. **So: do not write concrete non-Claude ids into `harness-profiles.json`.** Keep the prose tiers.

The researched ids below are **reference only** — vision-capable as of 2026-09, useful *if* a user opts to pin a model in their own harness config, never values to hardcode in the shared file:
- `claude`: default Sonnet, heavy Opus (already set).
- `codex`: `gpt-5.6-sol` (effort = escalation axis); avoid text-only `gpt-5.3-codex-spark`.
- `opencode`: `anthropic/claude-sonnet-4-5` / `-opus-4-5` (or GPT-5.x); vision per `capabilities.input.image`.
- `pi`: `openai-codex/gpt-5.5` (thinking `xhigh` = heavy).
