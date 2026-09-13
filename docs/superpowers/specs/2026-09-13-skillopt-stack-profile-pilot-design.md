# SkillOpt Stack-Profile Pilot Design

## Goal

Add a reproducible, repository-local SkillOpt benchmark that measures and optimizes `skills/detecting-stack-profile/SKILL.md` without changing the canonical skill during training. The pilot must use synthetic fixtures, deterministic scoring, a held-out validation gate, and an untouched test split.

## Scope

The pilot covers only `detecting-stack-profile`. It does not train all 17 skills, read Codex transcripts, schedule SkillOpt-Sleep, alter `CLAUDE.md`, or auto-adopt generated text. It uses the globally installed SkillOpt source revision recorded in the assessment and Codex CLI for optimizer and target calls.

## Architecture

`tools/skillopt-pilot/stack_profile/` is a standalone Python benchmark package loaded by thin train/eval launchers. The launchers import SkillOpt's official CLI modules, register the local adapter in their in-process environment registries, and then delegate to the upstream CLI. This avoids modifying or forking the global SkillOpt checkout.

Each benchmark item contains a minimal synthetic project description and a requested analysis outcome. During rollout, the target receives the current skill plus a task asking it to inspect a copied fixture and emit a single `result.json`. The adapter runs the target through SkillOpt's Codex harness in an isolated per-item workspace. No network access is required.

The deterministic scorer compares normalized semantic fields rather than prose. Required fields include framework, routing model, environment, signal, playbook, and safety behavior. A task can also declare forbidden outcomes. Hard score is 1 only when every required/forbidden assertion passes. Soft score is the fraction of assertions passed. Invalid or missing JSON scores zero.

## Dataset and split integrity

Fixtures are derived from the repository's existing hermetic detector cases but expressed as agent tasks rather than direct shell tests. The committed dataset has three directories:

- `train/`: representative Laravel, unknown-stack, and localization cases used for reflection.
- `valid/`: distinct Next.js/runtime ambiguity and production-safety cases used only by SkillOpt's selection gate.
- `test/`: distinct mixed-stack and no-runtime-tool cases used only in baseline/final evaluation.

Every item ID is globally unique. The loader rejects duplicate IDs, malformed assertions, missing fixtures, and overlapping content hashes across splits. Training configuration keeps `eval_test: false`; final test evaluation is a separate explicit command.

## Safety and data integrity

- Only committed synthetic fixture content is sent to Codex.
- Target workspaces are copies under the experiment output tree.
- Codex target execution uses workspace-write sandboxing, never dangerous full access.
- Network access and web search are disabled.
- Canonical `SKILL.md` is read as the seed and never used as an output path.
- Outputs live under `outputs/skillopt/`, which is git-ignored.
- No auto-adoption exists in this harness. Adoption remains a reviewed manual repository change.
- The final report records installed SkillOpt commit, config, seed-skill hash, split hashes, baseline/final per-item scores, selected checkpoint, and exact diff.

## Commands

`bash tools/skillopt-pilot/run.sh baseline` evaluates the canonical skill on validation and test before training. `bash tools/skillopt-pilot/run.sh train` runs the bounded optimization with Codex and does not evaluate test. `bash tools/skillopt-pilot/run.sh final` evaluates the selected best skill once on the sealed test split and generates a comparison report. `bash tools/skillopt-pilot/run.sh verify` runs harness unit/integration tests without model calls.

## Acceptance criteria

1. The harness works from any current directory and fails clearly when SkillOpt or Codex is unavailable.
2. Unit tests prove scoring, JSON extraction, loader validation, split overlap rejection, and registry injection.
3. A hermetic fake-target integration test proves a rollout writes the exact trajectory files SkillOpt reflection consumes.
4. Baseline and final results retain per-item evidence and immutable run metadata.
5. Training cannot read the test split through configuration or reflection artifacts.
6. No command edits the canonical skill or generated `dist/` files.
7. A candidate is recommended only when validation improves, no validation item regresses, final test does not regress, and repository tests remain green.

