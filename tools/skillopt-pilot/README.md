# SkillOpt stack-profile pilot

This harness optimizes only `skills/detecting-stack-profile/SKILL.md` against committed synthetic projects. It never reads transcripts or writes over the canonical skill.

Committed benchmark items are validated with strict Pydantic v2 models. The small Bash entrypoint only resolves repository paths and dispatches the four lifecycle commands, matching this repository's existing Bash-first CI surface without adding Typer as a second CLI dependency.

Run from anywhere:

```bash
bash tools/skillopt-pilot/run.sh detect-baseline   # zero-spend: no codex/venv/model
bash tools/skillopt-pilot/run.sh verify
bash tools/skillopt-pilot/run.sh baseline
bash tools/skillopt-pilot/run.sh train
bash tools/skillopt-pilot/run.sh final
```

`baseline` intentionally evaluates validation and test before optimization to establish the initial score. `train` can access only train and validation because `evaluation.eval_test` is false. Run `final` once, only after a validation-gated candidate exists. Outputs are isolated under ignored `outputs/skillopt/`.

The candidate is never adopted automatically. Review its exact diff, per-item scores, and full repository gates before changing the canonical skill.

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
