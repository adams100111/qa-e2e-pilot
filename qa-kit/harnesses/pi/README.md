# qa-kit on Pi

The step-gated QA process shell (`/qa-constitution → /qa-spec → /qa-scenarios → /qa-analyze → /qa-run`,
plus `/qa-status`) generated for Pi from the shared `qa-kit/core/` (ADR-0024). Claude stays the reference
build; Pi is generated to be behaviourally equivalent. Browser-driving and all verification are **deferred to
the qa-e2e-pilot engine** — qa-kit only orchestrates the steps.

## Prerequisites (the co-install contract)

1. **The engine Pi adapter installed FIRST** into the same project: `bash harnesses/pi/install-pi.sh <project>`.
   qa-kit reuses the engine's skills at `.pi/agents/skills/` **by bare name** — it never vendors or copies them
   (ADR-0001). `install-pi.sh` aborts if that skills dir is absent.
2. A Pi CLI/runtime with `pi-mcp-adapter` (the engine adapter wires the `playwright-qa` MCP server).
3. `python3` (the qa-kit scripts prefer `jq`, fall back to `python3`).

## Install

```bash
bash qa-kit/harnesses/pi/install-pi.sh <path-to-your-project>
```

Places: agent → `<project>/.pi/agents/qa-kit.md`; step prompts → `<project>/.pi/prompts/`; qa-kit's own scripts
+ templates → `<project>/.pi/qa-kit/` (this is the rendered `{{PLUGIN_ROOT}}` — the step prompts call
`.pi/qa-kit/scripts/*.sh`).

## How skill references resolve

qa-kit's step prompts reference engine skills as **"the `<name>` skill"** (bare name). The agent resolves each
by reading `.pi/agents/skills/<name>/SKILL.md`, installed by the engine adapter. This is the same mechanism the
engine's own persona uses on Pi — no plugin namespace, no path wiring.

## Manual accuracy run (honest boundary)

The generator + composition are unit-tested (`tests/qakit-adapters/run.sh`), but a live end-to-end qa-kit run
on Pi is **not** headlessly tested. Before trusting it, drive one real spec through the steps and confirm the
prompts resolve their skills and scripts. See `docs/harness-adapters.md`.
