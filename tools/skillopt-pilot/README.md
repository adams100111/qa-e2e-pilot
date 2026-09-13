# SkillOpt stack-profile pilot

This harness optimizes only `skills/detecting-stack-profile/SKILL.md` against committed synthetic projects. It never reads transcripts or writes over the canonical skill.

Committed benchmark items are validated with strict Pydantic v2 models. The small Bash entrypoint only resolves repository paths and dispatches the four lifecycle commands, matching this repository's existing Bash-first CI surface without adding Typer as a second CLI dependency.

Run from anywhere:

```bash
bash tools/skillopt-pilot/run.sh verify
bash tools/skillopt-pilot/run.sh baseline
bash tools/skillopt-pilot/run.sh train
bash tools/skillopt-pilot/run.sh experiment
bash tools/skillopt-pilot/run.sh final
```

`baseline` intentionally evaluates validation and test before optimization to establish the initial score. `train` can access only train and validation because `evaluation.eval_test` is false. `experiment` runs seeds 42, 314, and 2718 with one bounded eight-item batch per seed, writes a strict `iteration-summary.json`, and never invokes the final evaluator. Run `final` once, only after a validation-gated candidate exists. Outputs are isolated under ignored `outputs/skillopt/`.

The candidate is never adopted automatically. Review its exact diff, per-item scores, and full repository gates before changing the canonical skill.
