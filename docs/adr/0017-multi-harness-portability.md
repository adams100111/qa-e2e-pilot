# 0017. Multi-harness portability — shared core + generated adapters

Status: Accepted
Date: 2026-09-01

## Context

`qa-e2e-pilot` was Claude-Code-only: the 16 skills, the 6-phase orchestrator, and the human-interaction
gate (ADR-0015) all lived as repo-root files Claude installs directly (`agents/qa-e2e-pilot.md`,
`commands/*.md`, `skills/*/SKILL.md`). Other agent harnesses — Codex, Pi, opencode — run the same kind
of methodology but each has an incompatible agent-manifest format (YAML+Markdown frontmatter vs. TOML
`developer_instructions` vs. glob tool grants), a different MCP tool-naming/grant scheme
(per-tool list vs. server-scope vs. a `mcp` proxy tool vs. a tool-name glob), and different
model-selection conventions (Claude pins `model: sonnet`; the others inherit the caller's default).

Hand-authoring and hand-maintaining four parallel copies of the persona body, the `/qa-run` and
`/qa-roles` command bodies, and the tool grant would drift the moment any one copy was edited —
exactly the failure mode this project's own `checkpointing-qa-memory`/`driving-browser-qa` skills exist
to prevent in QA runs themselves. We needed one source of truth per piece of content, with the
per-harness differences isolated to naming/format, not prose.

## Decision

1. **Shared core stays at the repo root.** The 16 skills, bundled scripts, ADRs, and the `.qa/` state
   model are unchanged and un-forked (frozen for this effort) — Claude Code continues to install from
   them directly, exactly as before.
2. **`harness-profiles.json`** is the single naming/model/dispatch table: one `Profile` per harness
   (`toolPrefix`, `serverKey`, `grantStyle ∈ {list,scope,proxy,glob}`, `modelField`, `tierDefault`,
   `tierHeavy`, `dispatch`, `globalRolesDir`, `agentCmd`) plus the one ordered list of 20 browser
   capabilities every harness must grant.
3. **A naming/token generator, `scripts/build-adapter.sh <harness>`**, assembles `dist/<harness>/` by
   combining copied-verbatim core (skills/scripts/docs/tools/`CONTEXT.md`) with detokenized content
   rendered from `core/persona-body.md` + `core/commands/qa-run.md` + `core/commands/qa-roles.md`
   (the shared, token-bearing sources) through a thin per-harness `harnesses/<h>/manifest.tmpl` +
   `mcp.snippet` + `install-<h>.sh` + `README.md` (the harness-specific glue).
4. **Adapters are generated into `dist/`, which is git-ignored.** `dist/` is build scratch, never
   committed — a fresh checkout regenerates it via `build-adapter.sh`.
5. **The three repo-root Claude-facing files are generated-and-committed, with a byte-oracle.**
   `agents/qa-e2e-pilot.md`, `commands/qa-run.md`, and `commands/qa-roles.md` remain the files Claude
   installs directly (unchanged install path), but their content now originates from `core/` +
   `harnesses/claude/manifest.tmpl` through the same generator. `build-adapter.sh claude`'s output MUST
   byte-match the committed root files — that equality is the generator's own correctness oracle, and
   `scripts/validate-adapters.sh` (the CI gate, `.github/workflows/adapters.yml`) enforces it on every
   push/PR via `diff -q`.
6. **v1 is sequential-only — fan-out is deferred.** No adapter wires subagent dispatch; nothing here
   requires or assumes multi-agent features on any harness (Codex `[features] multi_agent`, or
   equivalent). This reaffirms ADR-0003's sequential-by-default posture rather than extending it; the
   per-harness `fanning-out-criteria` dispatch mapping is out of scope for this effort and left for a
   follow-up.
7. **A unique, project-local `playwright-qa` server key on Codex/Pi/opencode.** Claude keeps the
   official `playwright` MCP server key (installed alongside the plugin, per README). The other three
   harnesses' installers write a project-local MCP config fragment keyed `playwright-qa` — never
   mutating the harness's global config — pinned to `@playwright/mcp@0.0.79`, the exact version/session-log
   format `parse-session-log.js` and the accuracy-harness scorer expect. A user's own `@latest`-pinned
   `playwright` server may coexist for driving, but the human-interaction gate's Check 0 (ADR-0015)
   reads session logs **only** from the pinned `playwright-qa` server.
8. **`humanInteraction.sessionLogDir` config field.** `.qa/config.json.example` and
   `init-config.sh`-written configs now carry a documented, forward-looking `sessionLogDir` (default
   `.playwright-mcp`) alongside a `QA_DRIVER_SERVER` env override that lets `init-config.sh` write
   `playwright-qa` as the driver's `server` key instead of `playwright`. No script plumbing was added
   to `checkpoint.sh`/`record-evidence.sh` — both already take `--session-log` as an explicit caller
   argument, so a config-reading default would be dead code today.
9. **The act-path gate is uniform and post-hoc across all four harnesses.** `checkpoint.sh` +
   `check-action-trace.js` (and, when `--save-session` is enabled, `parse-session-log.js`) inspect what
   was actually done — before/after state fingerprints, the recorded action trace, and the independent
   MCP session log where available — regardless of which harness or tool-grant style produced it. No
   harness relies on its own per-skill/per-tool enforcement as the safety mechanism (opencode's
   `allowed-tools` non-enforcement, documented in `harnesses/opencode/README.md`, is the sharpest
   example of why this had to be true).

## Consequences

- **One source of truth per piece of content; drift is caught in CI, not discovered at review time.**
  Editing the persona body or a command's prose happens once, in `core/`; `validate-adapters.sh` fails
  loudly (byte-oracle diff, or a residual `{{token}}` in rendered output) if a template or profile edit
  breaks any harness's build. This is the same "verify independently, don't trust self-report" posture
  ADR-0015 applies to a QA run, applied here to the build itself.
- **Per-harness manual accuracy acceptance is required, not just the CI gate.** `validate-adapters.sh`
  proves the adapters *build correctly* (structurally valid, byte-identical where it matters, no
  unrendered tokens) — it does not prove an adapter's agent *behaves* correctly end-to-end on its
  harness. Each harness must separately clear the accuracy-harness's 85%/100% (recall/precision) gate
  by actually running its agent against the bundled fixture — see `docs/harness-adapters.md`. Pi is
  validated first because it was already provisioned; Codex and opencode follow the same procedure.
  This same manual step is also where **grounding-file resolution** is checked: each non-Claude
  installer ships `CONTEXT.md`/`docs/adr/` alongside the installed skills because the persona
  instructs the agent to read them, but that reference is unanchored, so whether a given harness's
  runtime actually resolves those paths from its cwd/plugin-root is a per-harness acceptance check,
  not something `validate-adapters.sh` verifies.
- **Pi's `--save-session`-under-a-proxy behavior is the one runtime unknown this decision leaves
  open.** Pi drives the Playwright MCP through the `pi-mcp-adapter` proxy tool rather than granting
  per-capability tools directly; whether that proxy layer faithfully surfaces the underlying
  `@playwright/mcp` server's `--save-session` output (`session.md`) has not been verified against a
  live Pi build at ADR time. If it does not, Check 0 (the independent session-log reconciliation) is
  unavailable and the human-interaction gate degrades gracefully to **Check 1 ∧ Check 2 ∧ Check 3**
  (the act-phase workaround lint + before/after state fingerprints), flagging in the report that
  independent verification was unavailable — the same degraded-but-safe path ADR-0015 already defines
  for the case where `--save-session` is simply not enabled. This is documented as an explicit R1
  caveat in `harnesses/pi/README.md`, not silently assumed to work.
- **The shared-core freeze holds.** No skill logic, script logic, or existing ADR was rewritten to
  enable this; the only additive edits to the frozen core are the `sessionLogDir`/`QA_DRIVER_SERVER`
  config plumbing (item 8 above) and one clarifying note in `driving-browser-qa`'s SKILL.md.
- **`dist/` being git-ignored means a fresh clone has no adapters until `build-adapter.sh`/`install-<h>.sh`
  is run once** — a documented step (`docs/harness-adapters.md`), not a surprise, and consistent with
  treating `dist/` as build output rather than a tracked artifact.
