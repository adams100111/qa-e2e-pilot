# SkillOpt stack-profile pilot

This harness optimizes only `skills/detecting-stack-profile/SKILL.md` against committed synthetic projects. It never reads transcripts or writes over the canonical skill.

Committed benchmark items are validated with strict Pydantic v2 models. The small Bash entrypoint only resolves repository paths and dispatches the four lifecycle commands, matching this repository's existing Bash-first CI surface without adding Typer as a second CLI dependency.

Run from anywhere:

```bash
bash tools/skillopt-pilot/run.sh detect-baseline   # zero-spend: no codex/venv/model
bash tools/skillopt-pilot/run.sh verify
bash tools/skillopt-pilot/run.sh baseline
bash tools/skillopt-pilot/run.sh train
bash tools/skillopt-pilot/run.sh experiment
bash tools/skillopt-pilot/run.sh final
```

`baseline` intentionally evaluates validation and test before optimization to establish the initial score. `train` can access only train and validation because `evaluation.eval_test` is false. `experiment` runs seeds 42, 314, and 2718 with one bounded eight-item batch per seed, writes a strict `iteration-summary.json`, and never invokes the final evaluator. Run `final` once, only after a validation-gated candidate exists. Outputs are isolated under ignored `outputs/skillopt/`.

The candidate is never adopted automatically. Review its exact diff, per-item scores, and full repository gates before changing the canonical skill.

## Choosing the backend / model

The committed `config.yaml` defaults to **codex_exec + gpt-5.5**. Switch backend
or model for any `run.sh` mode (including `experiment`) via environment variables
— no committed file is edited, so CI and the offline gate stay unaffected:

| Variable | Effect |
|---|---|
| `SKILLOPT_BACKEND` | sets **both** optimizer & target backend |
| `SKILLOPT_MODEL` | sets **both** optimizer & target model |
| `SKILLOPT_OPTIMIZER_BACKEND` / `SKILLOPT_TARGET_BACKEND` | per-role backend (wins over `SKILLOPT_BACKEND`) |
| `SKILLOPT_OPTIMIZER_MODEL` / `SKILLOPT_TARGET_MODEL` | per-role model (wins over `SKILLOPT_MODEL`) |

Supported backends (from SkillOpt): `codex_exec`, `claude_code_exec`,
`cursor_exec`, `copilot_exec` (local-CLI exec), plus the chat backends
`openai_chat`, `claude_chat`, `qwen_chat`, `minimax_chat`, `openai_compatible`,
`copilot_chat`. `run.sh` requires the matching local CLI only for the selected
exec backend (`codex` / `claude` / `cursor-agent` / `copilot`).

```bash
# Use the local Claude Code subscription (claude CLI), model = sonnet:
SKILLOPT_BACKEND=claude_code_exec SKILLOPT_MODEL=sonnet bash tools/skillopt-pilot/run.sh experiment

# Mixed: optimize with opus, run the target as sonnet:
SKILLOPT_BACKEND=claude_code_exec \
  SKILLOPT_OPTIMIZER_MODEL=opus SKILLOPT_TARGET_MODEL=sonnet \
  bash tools/skillopt-pilot/run.sh train

# Explicit codex (the default), pinned model:
SKILLOPT_BACKEND=codex_exec SKILLOPT_MODEL=gpt-5.5 bash tools/skillopt-pilot/run.sh baseline
```

## Zero-spend deterministic baseline (`detect-baseline`)

`bash run.sh detect-baseline [--gate] [--split SPLIT]` (or directly
`python3 tools/skillopt-pilot/baseline_offline.py`) runs the skill's own
`detect-stack.sh` over every committed fixture and scores its output with the
same assertions the model path uses. It makes **no** model/codex calls and
needs neither the SkillOpt checkout nor its venv — only `python3` + `bash`.

Two jobs:

1. **Consistency gate** (`--gate`, wired into the `skillopt-pilot` CI suite):
   every committed item's assertions must match what the real detector emits.
   The model-based `baseline` cannot give this check cheaply.
2. **The deterministic baseline** the optimized skill must at least match — any
   MISS is concrete headroom (a stack the script mis-detects, e.g. an ORM it
   returns as `unknown`).

Fixtures with a top-level `headers.txt` and no code manifest (e.g.
`blackbox-laravel`) run through the detector's black-box path; the rest through
code detection. Current committed set: **8/8** deterministic.
