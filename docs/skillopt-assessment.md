# SkillOpt assessment and adoption plan

## Executive assessment

SkillOpt is useful for improving agent instruction files, but it does not train
model weights. It treats a Markdown skill as mutable external state: a frozen
target agent attempts scored tasks, a separate optimizer reflects on outcomes,
proposed edits are bounded, and a held-out validation gate decides whether a
candidate replaces the current skill.

Use its two workflows for different purposes:

| Workflow | Evidence source | Recommended use |
|---|---|---|
| Research engine (`skillopt-train`, `skillopt-eval`) | Explicit train, selection, and test datasets with executable scorers | Rigorous optimization of canonical QA skills |
| SkillOpt-Sleep (`skillopt-sleep`) | Archived coding-agent transcripts | Discover repeated friction and stage conservative proposals |

Use Sleep to discover candidate failure modes, then turn stable examples into
reviewed, version-controlled benchmark cases for the research engine. Do not
bulk-optimize all skills from transcripts, enable automatic adoption, or treat
the optimizer's self-judgment as proof of correctness.

## Fit with this repository

This repository's canonical skills live under `skills/`; generated copies under
`dist/` are not optimization targets. The skills are interdependent and
stateful, so a gate must score both the target behavior and shared lifecycle and
safety invariants.

The first pilot therefore targets `detecting-stack-profile`, whose structured
output can be scored deterministically. It uses committed synthetic fixtures,
separate train/validation/test splits, isolated target workspaces, disabled
target network access, bounded edits, and no automatic adoption. A candidate is
eligible for final evaluation only if it improves the held-out validation hard
score without per-item regression.

## Security and data integrity

Transcript disclosure is the principal Sleep risk. Redaction is defense in
depth, not a guarantee; private source, credentials, customer data, security
findings, and personal information can survive pattern matching.

Operating policy:

- Prefer synthetic or deliberately curated tasks over raw transcripts.
- Use the mock backend for installation and workflow checks.
- Before a real Sleep run, harvest to a task file, review and redact it, and mark
  it reviewed.
- Keep automatic adoption disabled and review every exact skill diff.
- Do not schedule runs until sources, targets, retention, spend limits, and
  adoption behavior are explicitly configured.
- Record the installed source revision instead of silently following a moving
  branch.
- Bind the optional Web UI to localhost unless remote access is protected.

## Installation performed

The current upstream revision was installed because the published package lags
newer Codex/Sleep integration work.

| Item | Installed value |
|---|---|
| Source checkout | `/home/dev/.local/share/skillopt` |
| Installed revision | `79124b37e9a6371e13b753f8bcd7adb1e493ade1` |
| Isolated global tool | `uv tool` package `skillopt 0.2.0` |
| Commands | `skillopt-train`, `skillopt-eval`, `skillopt-sleep` |
| Installed skill | `/home/dev/.agents/skills/skillopt-sleep/SKILL.md` |
| Shell discovery | `SKILLOPT_SLEEP_REPO=/home/dev/.local/share/skillopt` in `~/.bashrc` |
| Scheduling | Not enabled |
| Automatic adoption | Not enabled |

Verification covered all command help surfaces, status, a mock dry-run, and the
relevant upstream suite: 391 tests passed, 2 skipped, and 6 subtests passed. The
mock dry-run found no archived sessions and changed no repository or persistent
SkillOpt state.

## Pilot result

The first bounded run produced a plausible candidate clarification but rejected
it correctly. Validation hard score remained `0.0000`; therefore the candidate
was not promoted, the sealed final test was not run, and the canonical skill was
not modified. The result shows that the harness and gate work while also showing
that one two-item, one-epoch run is insufficient evidence for enhancement.

The next research iteration should add representative training cases, run
multiple seeds, and investigate why target executions sometimes improvise a
manifest instead of invoking the bundled detector. Keep the existing final test
sealed until a candidate clears validation.

## Sources

1. [Microsoft Research: SkillOpt](https://microsoft.github.io/SkillOpt/)
2. [Training loop](https://github.com/microsoft/SkillOpt/blob/main/docs/guide/training-loop.md)
3. [SkillOpt-Sleep documentation](https://github.com/microsoft/SkillOpt/blob/main/docs/sleep/README.md)
4. [SkillOpt-Sleep results](https://github.com/microsoft/SkillOpt/blob/main/docs/sleep/RESULTS.md)
5. [Installation guide](https://github.com/microsoft/SkillOpt/blob/main/docs/guide/installation.md)
6. [MIT license](https://github.com/microsoft/SkillOpt/blob/main/LICENSE)
