# qa-kit on Codex

The step-gated QA process shell generated for Codex from the shared `qa-kit/core/` (ADR-0024). Claude is the
reference build. Browser-driving and all verification are **deferred to the qa-e2e-pilot engine**.

## Prerequisites (the co-install contract)

1. **The engine Codex adapter installed FIRST**: `bash harnesses/codex/install-codex.sh <project>`. Note
   Codex's **split layout** — the engine puts skills under `<project>/.agents/skills/` while agents live under
   `<project>/.codex/agents/`. qa-kit's skill refs resolve against `.agents/skills/` **by bare name**; it never
   vendors the skills (ADR-0001). `install-codex.sh` aborts if that dir is absent.
2. A Codex CLI supporting project-local `.codex/agents/*.toml`, `.codex/prompts/*.md`.
3. `python3`.

## Install

```bash
bash qa-kit/harnesses/codex/install-codex.sh <path-to-your-project>
```

Places: agent → `<project>/.codex/agents/qa-kit.toml` (TOML, persona in a `'''…'''` literal — the generator
aborts if the persona body contains `'''`); step prompts → `<project>/.codex/prompts/`; qa-kit scripts +
templates → `<project>/.codex/qa-kit/` (the rendered `{{PLUGIN_ROOT}}`).

## How skill references resolve

Step prompts reference engine skills as **"the `<name>` skill"** (bare name); the agent reads
`.agents/skills/<name>/SKILL.md` (installed by the engine adapter) — the same mechanism the engine's own Codex
persona uses.

## Manual accuracy run (honest boundary)

Generator + composition are unit-tested; a live end-to-end qa-kit run on Codex is the manual acceptance step —
see `docs/harness-adapters.md`.
