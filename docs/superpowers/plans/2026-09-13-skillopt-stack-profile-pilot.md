# SkillOpt Stack-Profile Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run a safe, deterministic SkillOpt pilot for `detecting-stack-profile`.

**Architecture:** A repository-local adapter and dataset are injected into SkillOpt's existing CLI registries by thin launchers. Codex executes fixture tasks in isolated workspaces; a pure deterministic scorer gates structured results, and the final test split is invoked only after training.

**Tech Stack:** Python 3.12, Pydantic v2, SkillOpt `main`, Codex CLI, a thin Bash lifecycle dispatcher, JSON, YAML.

**Spec:** `docs/superpowers/specs/2026-09-13-skillopt-stack-profile-pilot-design.md`

## Global Constraints

- Target only `skills/detecting-stack-profile/SKILL.md`.
- Use committed synthetic inputs; never harvest transcripts.
- Disable target network access and web search.
- Never auto-adopt or write training output over a canonical skill.
- Keep the test split out of training and selection.
- Require validation improvement and no per-item validation regression before recommending a candidate.

---

### Task 1: Deterministic benchmark core

**Files:**
- Create: `tools/skillopt-pilot/stack_profile/__init__.py`
- Create: `tools/skillopt-pilot/stack_profile/scoring.py`
- Create: `tools/skillopt-pilot/stack_profile/dataloader.py`
- Create: `tests/skillopt-pilot/test_core.py`

**Interfaces:**
- Produces: `extract_result(text: str) -> dict`, `score_result(result: dict, assertions: list[dict]) -> Score`, and `StackProfileDataLoader`.

- [ ] Write tests with literal expectations for fenced/plain JSON extraction, required and forbidden assertions, malformed responses, duplicate IDs, missing fixtures, and cross-split hash overlap.
- [ ] Run `python3 -m unittest tests/skillopt-pilot/test_core.py -v`; verify failures identify missing modules.
- [ ] Implement the minimal pure scorer and `SplitDataLoader` subclass.
- [ ] Re-run the unit tests and verify they pass.
- [ ] Commit with `feat(skillopt): add deterministic stack-profile benchmark core`.

### Task 2: Rollout adapter and CLI integration

**Files:**
- Create: `tools/skillopt-pilot/stack_profile/rollout.py`
- Create: `tools/skillopt-pilot/stack_profile/adapter.py`
- Create: `tools/skillopt-pilot/train.py`
- Create: `tools/skillopt-pilot/eval.py`
- Create: `tests/skillopt-pilot/test_integration.py`

**Interfaces:**
- Consumes: Task 1's loader and scorer.
- Produces: `process_one`, `run_batch`, `StackProfileAdapter`, and registry-injecting CLI entrypoints.

- [ ] Write integration tests using a fake target executor to prove isolated fixture copying, structured scoring, conversation persistence, systemic failure handling, and local adapter registration.
- [ ] Run `python3 -m unittest tests/skillopt-pilot/test_integration.py -v`; verify expected failures.
- [ ] Implement Codex/chat rollout paths using SkillOpt's public model routing and isolated workspace helpers.
- [ ] Implement adapter lifecycle and CLI registry injection.
- [ ] Re-run core and integration tests and verify they pass.
- [ ] Commit with `feat(skillopt): integrate stack-profile rollouts with SkillOpt`.

### Task 3: Dataset, configuration, and sealed workflow

**Files:**
- Create: `tools/skillopt-pilot/data/{train,valid,test}/items.json`
- Create: `tools/skillopt-pilot/fixtures/**`
- Create: `tools/skillopt-pilot/config.yaml`
- Create: `tools/skillopt-pilot/run.sh`
- Create: `tools/skillopt-pilot/README.md`
- Create: `tests/skillopt-pilot/run.sh`
- Modify: `scripts/run-engine-ci.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: Tasks 1–2 launchers.
- Produces: `verify`, `baseline`, `train`, and `final` operator commands.

- [ ] Write a shell acceptance test proving path independence, dependency preflight, output isolation, config test-sealing, and exact mode dispatch.
- [ ] Enroll the suite in `scripts/run-engine-ci.sh` and confirm suite coverage rejects no directory.
- [ ] Run `bash tests/skillopt-pilot/run.sh`; verify it fails before the workflow exists.
- [ ] Add distinct synthetic fixtures/items, bounded configuration, runner, ignore rule, and operator documentation.
- [ ] Re-run the new suite, `bash scripts/check-suite-coverage.sh`, and `bash scripts/run-engine-ci.sh`.
- [ ] Commit with `feat(skillopt): add sealed stack-profile pilot workflow`.

### Task 4: Execute pilot and review candidate

**Files:**
- Create ignored artifacts under `outputs/skillopt/` only.
- Modify canonical skill only after a separate explicit adoption decision.

**Interfaces:**
- Consumes: Task 3 commands.
- Produces: baseline, training, final evaluation, and comparison report.

- [ ] Run `bash tools/skillopt-pilot/run.sh baseline`; retain validation/test results and metadata.
- [ ] Run `bash tools/skillopt-pilot/run.sh train`; inspect the selected checkpoint and ensure test data was not accessed.
- [ ] If validation did not improve without regression, stop and report no candidate.
- [ ] If validation passed, run `bash tools/skillopt-pilot/run.sh final` exactly once.
- [ ] Inspect the exact canonical-to-candidate diff and final per-item results; do not adopt.
- [ ] Run all repository gates and record results in the comparison report.
- [ ] Commit only reproducible harness/docs changes; keep model outputs ignored.
