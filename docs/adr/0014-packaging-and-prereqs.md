# ADR-0014 — Packaging, dependencies & install wiring

## Status

Accepted (2026-08-31). Phase 6 of [docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md).

## Context

The plugin must install self-contained and auto-wire its true prerequisites, failing loud if any are
missing — not silently break at runtime. Three verified plugin-system capabilities are available to do
this:

- `.mcp.json` at the plugin root → declared MCP servers become present/enabled with the plugin.
- `hooks.SessionStart` in `.claude-plugin/plugin.json` → a command hook runs each session; **exit 2
  blocks** the session with a stderr fix message, exit 0 proceeds.
- `dependencies` (plugin-to-plugin auto-install) exists but is **deliberately not used** — the plugin
  reimplements external patterns as bundled skills rather than depending on other plugins
  ([ADR-0001](./0001-reimplement-opslane-patterns-not-fork-or-vendor.md)).

The master plan's original Phase 6 draft (written before the visual-UX detection skill was
implemented) also called for a `package.json` pinning **axe-core** as an npm dependency, injected via
`browser_evaluate` for the accessibility/UX detection pass (see ADR-0009's original proposal). By the
time Phase 6 was implemented, `detecting-visual-ux` had already shipped as **dependency-free
browser-context JavaScript** (`skills/detecting-visual-ux/scripts/ux-detectors.js`) — it borrows axe-core's
*rule-naming conventions* (e.g. `button-name`, WCAG SC references) as its oracle vocabulary, but does not
inject or depend on the axe-core library itself. There is no `axe.min.js` anywhere in the repo.

## Decision

1. **Reimplement, don't depend** (reaffirms ADR-0001). No plugin-to-plugin `dependencies` entry for any
   external plugin's patterns; every reimplemented pattern (opslane/verify, grilling, superpowers,
   hallmark, ui-ux-pro-max — see README § Attribution) ships as this plugin's own skill code.
2. **Declare the Playwright MCP via `.mcp.json`** at the repo root, server key `playwright`, matching
   the tool prefix the skills already call (`mcp__plugin_playwright_playwright__browser_*`):
   ```json
   { "mcpServers": { "playwright": { "command": "npx", "args": ["-y", "@playwright/mcp@0.0.79"] } } }
   ```
   Pinned to `0.0.79` (confirmed via `npm view @playwright/mcp version`) rather than `@latest`, so a
   future breaking release of the MCP server doesn't silently change tool names/behavior underneath the
   skills.
3. **SessionStart preflight blocks on missing environment prerequisites.**
   `scripts/check-prereqs.sh` checks for `node`, `bash`, `curl`, and (`jq` OR `python3`) — the actual
   runtime prerequisites of the bundled scripts (`checkpoint.sh`, `preflight.sh`,
   `report-to-junit.sh`, `memory-sync.sh`) and browser-context JS injection. Missing anything → prints
   each gap to stderr and `exit 2` (blocks the session with a fix message); all present → `exit 0`.
4. **No npm dependency, no `package.json`, no axe-core.** This is a deliberate **simplification versus
   the earlier plan**: because `detecting-visual-ux` shipped dependency-free, there is nothing to
   `npm install` and therefore no auto-install step, no `node_modules` presence check, and no MPL-2.0
   third-party license to carry. The preflight script does **not** check for axe-core or run `npm
   install` — there is no `package.json` in this repo.
5. **Version bump to 0.5.0** across `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
   and `scripts/skills.json` — reflecting the cumulative state through Phase 6 (stack detection,
   config bootstrap, role discovery, visual-UX detection, and this packaging phase), not the 0.4.0 the
   original plan draft anticipated when Phase 6 was scoped mid-plan.

## Consequences

- **Zero-npm install surface.** `npm install`/`package-lock.json` never enter this repo's install path;
  one fewer moving part and no third-party license (axe-core, MPL-2.0) to carry or audit.
- **Fail loud, not silent.** A session without `node`/`bash`/`curl`/(`jq`|`python3`) is blocked at
  `SessionStart` with an explicit fix list, instead of failing confusingly mid-run inside
  `checkpoint.sh` or `preflight.sh`.
- **Pinned MCP version is a deliberate reversibility trade-off**: `@0.0.79` won't silently drift, but
  someone must bump it by hand to pick up upstream Playwright MCP fixes. Acceptable — this plugin
  already treats driver capability as config (`driver-capabilities.md`), so a version bump is a
  one-line, reviewable change.
- **`scripts/skills.json` drift is now closed and machine-checkable**: `comm -3` between the manifest's
  skill names and `ls skills/*/` is the durable regression check (README/CLAUDE.md "Validate before
  committing" can run it going forward) so a future added skill can't silently miss the marketplace/npx
  install path again.
- If `detecting-visual-ux` ever *does* need a real accessibility engine (axe-core or otherwise), that is
  a **new** ADR that reopens the npm-dependency question — this ADR only records why it isn't needed
  today.

## Provenance

`docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md` § Phase 6 (Tasks 6.1–6.5); revises that plan's
Task 6.1 (axe-core `package.json`) as not-applicable given the dependency-free `detecting-visual-ux`
implementation.
