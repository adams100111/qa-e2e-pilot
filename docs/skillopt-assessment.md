# SkillOpt assessment and adoption plan

## Executive assessment

SkillOpt is a credible, useful framework for improving agent instruction files, but it does not train model weights. It treats a Markdown skill as mutable external state: a frozen target agent attempts scored tasks, a separate optimizer reflects on failures and successes, proposed add/delete/replace edits are bounded, and a held-out validation gate decides whether a candidate replaces the current skill. The deployed result is a compact Markdown artifact and adds no model call at inference time.^1

The project offers two related but operationally different workflows:

| Workflow | Evidence source | Best use here | Confidence |
|---|---|---|---|
| Research engine (`skillopt-train`, `skillopt-eval`) | Explicit train, selection, and test datasets with executable scorers | Rigorous optimization of the 17 canonical QA skills | High, once representative benchmarks exist |
| SkillOpt-Sleep (`skillopt-sleep`) | Past coding-agent transcripts mined into recurring tasks | Discover repeated friction and stage conservative proposals | Medium; useful as an evidence generator, not a substitute for a purpose-built benchmark |

The recommendation is to use both, in sequence. Use Sleep to mine candidate failure modes and operational preferences, then turn stable examples into checked, version-controlled benchmark cases for the research engine. Do not bulk-optimize all skills from transcripts, do not enable automatic adoption, and do not treat the optimizer's self-judgment as proof of correctness.

## What SkillOpt actually does

The core loop resembles optimization but operates entirely in text space:

1. The target model executes minibatches using the current skill.
2. Scorers capture task outcomes and trajectory evidence.
3. The optimizer reflects separately on successful and failed executions.
4. It proposes structured additions, deletions, or replacements under an edit budget—the textual analogue of a learning rate.
5. Conflicting edits are aggregated and ranked.
6. A candidate must improve a held-out selection split before becoming the current best skill.
7. Rejected edits and slower-running optimizer memory discourage repeated regressions.^2

This design is materially stronger than asking a model to “improve this prompt.” Its useful controls are the independent held-out gate, bounded edits, rejected-edit memory, and separation of optimizer and target roles. Microsoft reports that ablations removing these controls reduce results on several included benchmarks.^1

The reported results are promising but should not be over-generalized. The authors report best or tied-best results across 52 evaluated model/benchmark/harness cells and sizable average gains for several target configurations.^1 These are author-reported results on six benchmark families; they do not establish that an arbitrary procedural skill, a private QA workflow, or mined session tasks will improve. The project itself describes SkillOpt-Sleep as a preview and documents a much narrower recorded Codex experiment.^3

## Fit with qa-e2e-pilot

This repository has 17 canonical skills under `skills/`, with generated copies under `dist/`. Optimization must target canonical sources only. Generated distributions should continue to be produced by the repository's existing build/sync path; training a `dist/` copy would create drift and likely be overwritten.

The skills are interdependent and stateful. Several govern role discovery, checklist generation, browser execution, persistence verification, and reporting. A local improvement in one skill can create a cross-skill regression—for example, a more aggressive browser driver could violate a role-confirmation or persistence-verification contract. Therefore a gate for this project must score both the target behavior and invariant behaviors shared across the pipeline.

Recommended pilot order:

1. Start with one bounded skill that has observable outputs, such as `detecting-stack-profile`.
2. Define train cases, a selection split used only for candidate acceptance, and a final test split that remains untouched until the experiment ends.
3. Score structural requirements deterministically where possible: required artifacts, schemas, evidence links, command safety, phase ordering, and absence of prohibited writes.
4. Use model judging only for dimensions that cannot be checked mechanically, and blind the judge to which candidate produced the output.
5. Run multiple seeds and retain per-task results, not only an average.
6. Review and merge the selected `best_skill.md` through the normal repository workflow, then regenerate distributions.
7. Expand to another skill only after the first pilot demonstrates held-out improvement without invariant regressions.

For this repository, the default Sleep setting `gate_no_regression: false` is too permissive for eventual adoption. Set it to `true` for serious trials, keep `gate_mode: on`, retain a small edit budget, disable memory evolution if `CLAUDE.md` is not an intended target, and always specify an exact canonical `--target-skill-path`.

## Security and data-integrity analysis

The most important risk is transcript disclosure. The Codex integration reads archived sessions and removes known secret-shaped strings, developer instructions, and raw tool payloads, but the maintainers explicitly state that redaction is defense in depth and not a guarantee. A real backend can receive truncated transcript or task content.^4 Private source, credentials, customer data, security findings, and incidental personal information can survive pattern matching.

Safe operating policy:

- Use `--backend mock` for installation and workflow checks. It makes no provider calls.
- For real runs, use `harvest --output reviewed-tasks.json`, manually inspect and redact it, then set `"reviewed": true`; real backends reject unreviewed task files.^4
- Prefer synthetic or deliberately curated benchmark tasks over raw transcripts for high-sensitivity projects.
- Keep `--auto-adopt` disabled. A normal run stages proposals; explicit adoption is the live-file mutation boundary and creates backups.^4
- Never schedule a run until source, target path, backend, retention policy, spend limits, and adoption mode are explicitly configured. The scheduler does not persist every CLI selector, including all source and target options.^4
- Pin or record the installed commit. `main` is required for Codex improvements not present in the current PyPI release, but following a moving branch without review creates supply-chain and reproducibility risk.^5
- Do not launch the optional WebUI on its documented default `0.0.0.0` bind in an untrusted network; use `127.0.0.1` unless remote access is deliberately protected.^1

SkillOpt's MIT license permits internal use and modification.^6 Its `SECURITY.md` points vulnerability reports to Microsoft's standard private reporting channel, but that is not an independent security audit. The local review found subprocess-based integrations for coding-agent CLIs, as expected; the selected backend therefore inherits the permissions, authentication, and data policy of that CLI.

## Installation performed

The current `main` revision was installed because the official documentation says the PyPI 0.2.0 release lacks newer Codex/Sleep integration features.^5

| Item | Installed value |
|---|---|
| Source checkout | `/home/dev/.local/share/skillopt` |
| Audited/installed revision | `79124b37e9a6371e13b753f8bcd7adb1e493ade1` |
| Isolated global tool | `uv tool` package `skillopt 0.2.0` |
| Commands | `skillopt-train`, `skillopt-eval`, `skillopt-sleep` |
| Codex skill | `/home/dev/.agents/skills/skillopt-sleep/SKILL.md` |
| Shell discovery | `SKILLOPT_SLEEP_REPO=/home/dev/.local/share/skillopt` in `~/.bashrc` |
| Scheduling | Not enabled |
| Auto-adoption | Not enabled |

Installation verification included all three command help surfaces, a `status` call, a mock-backed dry-run against `skills/detecting-stack-profile/SKILL.md`, and 391 relevant upstream tests (2 skipped, 6 subtests passed). The mock dry-run reported zero sessions and zero tasks, proposed no edits, and changed no repository or persistent SkillOpt state.

The reason is specific: the current Codex source reads `~/.codex/archived_sessions`. This environment currently has no archived sessions, although it has active session files elsewhere. Moving or rewriting session data merely to satisfy harvesting is not appropriate. Archive sessions naturally or build curated tasks instead.

## Practical operating procedure

### Safe discovery run

After relevant Codex sessions have been archived:

```bash
skillopt-sleep harvest \
  --project /home/dev/repos/qa-e2e-pilot \
  --source codex \
  --target-skill-path skills/detecting-stack-profile/SKILL.md \
  --max-sessions 5 \
  --max-tasks 3 \
  --output reviewed-tasks.json
```

Review and redact `reviewed-tasks.json`, mark it reviewed, then use the provider-backed dry run. Do not commit the task file if it contains transcript-derived private material.

```bash
skillopt-sleep dry-run \
  --project /home/dev/repos/qa-e2e-pilot \
  --backend codex \
  --target-skill-path skills/detecting-stack-profile/SKILL.md \
  --tasks-file reviewed-tasks.json \
  --progress --json
```

A dry-run evaluates the flow but does not stage or adopt. A later `run` should still omit `--auto-adopt`; inspect its `report.md`, exact edits, per-task trials, baseline/candidate scores, and gate decision before explicitly adopting anything.

### Rigorous training track

The research engine is the appropriate long-term route. Add a repository-specific benchmark adapter and scorer following SkillOpt's documented benchmark contract, with a deterministic workspace fixture for each task. Optimize a copied seed skill into a dedicated output directory. Never point experimental output directly at the canonical skill. Compare the final selection-best artifact once against the untouched test split, then subject any proposed repository change to existing tests and distribution consistency checks.

Success should mean more than a positive average. Require:

- improvement on the held-out primary metric;
- zero regression on safety and lifecycle invariants;
- no test-task contamination in optimizer context;
- stable improvement across multiple seeds or a confidence interval that excludes a trivial effect;
- bounded complexity growth in the skill document;
- human review showing the edit is general rather than benchmark-specific;
- full repository tests and generated-artifact checks passing after integration.

## Decision

Adopt SkillOpt as an experimental optimization and evidence-mining tool, not as an autonomous trainer. The installation is ready. The next useful work is benchmark design and task curation; running a real backend now would have no evidence to consume and would provide no justified skill enhancement.

## Sources

1. Microsoft Research, “[SkillOpt project page](https://microsoft.github.io/SkillOpt/),” 2026.
2. Microsoft, “[Training Loop](https://github.com/microsoft/SkillOpt/blob/main/docs/guide/training-loop.md),” SkillOpt documentation.
3. Microsoft, “[SkillOpt-Sleep Results](https://github.com/microsoft/SkillOpt/blob/main/docs/sleep/RESULTS.md),” SkillOpt repository.
4. Microsoft, “[SkillOpt-Sleep](https://github.com/microsoft/SkillOpt/blob/main/docs/sleep/README.md),” safety, privacy, staging, and adoption documentation.
5. Microsoft, “[Installation](https://github.com/microsoft/SkillOpt/blob/main/docs/guide/installation.md),” SkillOpt documentation.
6. Microsoft, “[MIT License](https://github.com/microsoft/SkillOpt/blob/main/LICENSE),” SkillOpt repository.

