# qa-kit on opencode

The step-gated QA process shell generated for opencode from the shared `qa-kit/core/` (ADR-0024). Claude is the
reference build. Browser-driving and all verification are **deferred to the qa-e2e-pilot engine**.

## Prerequisites (the co-install contract)

1. **The engine opencode adapter installed FIRST**: `bash harnesses/opencode/install-opencode.sh <project>`
   (puts skills under `<project>/.opencode/skills/`). qa-kit reuses those skills; it never vendors them
   (ADR-0001). `install-opencode.sh` aborts if that dir is absent.
2. **The community `opencode-skills` plugin enabled** in `opencode.json` (`"plugin": ["opencode-skills"]`) — it
   exposes each `SKILL.md` as a callable `skills_<name>` tool. **Without it the skills are inert documents** and
   qa-kit's step commands cannot invoke them. (Same requirement as the engine's opencode adapter.)
3. `python3`.

## Install

```bash
bash qa-kit/harnesses/opencode/install-opencode.sh <path-to-your-project>
```

Places: agent → `<project>/.opencode/agent/qa-kit.md`; step commands → `<project>/.opencode/command/`; qa-kit
scripts + templates → `<project>/.opencode/qa-kit/` (the rendered `{{PLUGIN_ROOT}}`).

## How skill references resolve

opencode is the one harness with a real skill-tool mechanism: qa-kit's step commands reference engine skills as
the **`skills_<name>` tool** (exposed by `opencode-skills` from `.opencode/skills/<name>/`). This differs from
Pi/Codex (bare-name file reads) and is why the `opencode-skills` prerequisite is mandatory.

## Manual accuracy run (honest boundary)

Generator + composition are unit-tested; a live end-to-end qa-kit run on opencode — with `opencode-skills`
enabled — is the manual acceptance step. See `docs/harness-adapters.md`.
