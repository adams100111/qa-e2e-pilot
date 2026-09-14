# SkillOpt benchmark — `detecting-stack-profile`

A first, deliberately small benchmark that lets [SkillOpt](https://github.com/microsoft/SkillOpt)
optimize the **prose of** `skills/detecting-stack-profile/SKILL.md`. It follows
SkillOpt's "add a new benchmark" contract (`EnvAdapter` + `SplitDataLoader` +
a scorer + a config). See `docs/skillopt-assessment.md` for the adoption plan
and safety rules this benchmark is built to honor.

## What it measures — and what it does NOT

SkillOpt edits **text**, so the thing under test must be text-driven. A rollout
gives the target model the SKILL.md prose as its skill and a raw fixture
(manifests, or captured runtime headers for the black-box case) as the task,
and asks it to emit a `stack-profile.json`. The produced profile is scored
against field-scoped ground truth; SkillOpt then proposes bounded edits to the
prose and keeps one only if it improves the held-out selection score.

- It measures: *how well the skill's writing + inline signatures lead a model
  to the correct stack profile* — including edge cases (black-box, ORM
  identification, server-bridge routing).
- It does **not** test `detect-stack.sh` directly. The bundled script is
  deterministic; SkillOpt cannot improve a bash script via prose edits. The
  script instead provides the **deterministic baseline** (see `sanity.py`) and
  the ground-truth oracle for the clean fixtures.

> Honesty note (from the assessment): a local prose win on one field can
> regress a shared invariant. This scaffold scores only `detecting-stack-profile`
> outputs. Before adopting any optimized skill, run the repo's full suite +
> adapter byte-oracle and review the diff through the normal PR flow. Never
> point training output at a `dist/` copy — optimize the canonical `skills/`
> source only.

## Layout

```
data/{train,val,test}/items.json   split items, each with inline `expected` ground truth
fixtures/<id>/repo/…               local-source fixtures (manifests)
fixtures/blackbox-laravel/…        black-box fixture (captured response headers, no repo)
scorer.py                          field-scoped profile comparison (hard + soft)
sanity.py                          ZERO-SPEND baseline: runs detect-stack.sh over all fixtures
env.py                             SkillOpt EnvAdapter (model rollout + scoring)
dataloader.py                      SkillOpt SplitDataLoader (reads items.json)
config/default.yaml                SkillOpt run config
install-into-skillopt.sh           copies this benchmark into a SkillOpt checkout
```

## Splits (7 fixtures — a starter set)

| split | fixtures | notes |
|-------|----------|-------|
| train | laravel-inertia, django-drf, dotnet-ef | clean, script-correct |
| val (selection gate) | rails-app, express-sequelize | sequelize ORM is a real detector gap |
| test (held-out) | nextjs-prisma, blackbox-laravel | prisma ORM gap + black-box env inference |

Ground truth pins a field **only when unambiguous** from the fixture; a missing
field is "not asserted", never "asserted empty".

## Run it

Zero-spend structure + baseline check (no API calls, run from anywhere):

```bash
python3 benchmarks/skillopt/detecting-stack-profile/sanity.py
```

Current deterministic baseline: **hard 5/7, mean-soft 0.93**. The two MISS rows
(`express-sequelize`, `nextjs-prisma` → ORM `unknown`) are the concrete headroom
a real optimization run would try to close.

Real (spending) optimization run:

```bash
SKILLOPT_REPO=~/.local/share/skillopt \
  bash benchmarks/skillopt/detecting-stack-profile/install-into-skillopt.sh
# paste the printed registry block into scripts/train.py + scripts/eval_only.py, then:
cd ~/.local/share/skillopt && skillopt-train --config configs/detecting_stack_profile/default.yaml
```

Use `--backend mock` semantics / a small `limit` first, keep `use_gate: true`,
and never auto-adopt: review `report.md`, the exact edits, and per-task scores
before promoting anything into `skills/`.

## Extending

Add a fixture dir + an item (with `expected`) to the right split. Prefer
fixtures with real headroom (drift, ambiguous primary component, i18n present,
API-only services) over more clean happy-path cases — those are where prose
edits actually earn their keep.
