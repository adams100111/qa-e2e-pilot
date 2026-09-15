#!/usr/bin/env python3
"""Run and summarize a sealed, multi-seed SkillOpt experiment."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


def _model_cfg_options() -> list[str]:
    """Backend/model cfg-options from env, mirroring run.sh.

    Single source of truth so `run.sh experiment` and a direct `experiment.py`
    invocation select the same backend/model. Empty when nothing is overridden,
    leaving the committed config.yaml defaults (codex_exec + gpt-5.5) in force.
    """
    env = os.environ.get
    opt_backend = env("SKILLOPT_OPTIMIZER_BACKEND") or env("SKILLOPT_BACKEND")
    tgt_backend = env("SKILLOPT_TARGET_BACKEND") or env("SKILLOPT_BACKEND")
    opt_model = env("SKILLOPT_OPTIMIZER_MODEL") or env("SKILLOPT_MODEL")
    tgt_model = env("SKILLOPT_TARGET_MODEL") or env("SKILLOPT_MODEL")
    opts: list[str] = []
    if opt_backend:
        opts.append(f"model.optimizer_backend={opt_backend}")
    if tgt_backend:
        opts.append(f"model.target_backend={tgt_backend}")
    if opt_model:
        opts.append(f"model.optimizer={opt_model}")
        os.environ["OPTIMIZER_DEPLOYMENT"] = opt_model
    if tgt_model:
        opts.append(f"model.target={tgt_model}")
        os.environ["TARGET_DEPLOYMENT"] = tgt_model
    return opts


class TrainingSummary(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    baseline_selection_hard: float = Field(ge=0.0, le=1.0)
    best_selection_hard: float = Field(ge=0.0, le=1.0)
    best_step: int = Field(ge=0)


class RolloutScore(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=True)

    id: str = Field(min_length=1)
    hard: int = Field(ge=0, le=1)
    soft: float = Field(ge=0.0, le=1.0)


class SeedAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    seed: int
    baseline_hard: float
    candidate_hard: float
    candidate_soft: float
    best_step: int
    candidate_hash: str
    regressed_items: list[str]
    eligible: bool


class IterationSummary(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    status: str
    seeds: list[SeedAssessment]
    eligible_seeds: list[int]


def assess_run(
    *,
    seed: int,
    summary: dict[str, Any],
    baseline_rollouts: list[dict[str, Any]],
    candidate_rollouts: list[dict[str, Any]],
    candidate_hash: str,
) -> SeedAssessment:
    training = TrainingSummary.model_validate(summary)
    baseline = {row.id: row for row in map(RolloutScore.model_validate, baseline_rollouts)}
    candidate = {row.id: row for row in map(RolloutScore.model_validate, candidate_rollouts)}
    if set(baseline) != set(candidate):
        raise ValueError("candidate rollout IDs differ from baseline rollout IDs")
    if len(baseline) != len(baseline_rollouts) or len(candidate) != len(candidate_rollouts):
        raise ValueError("duplicate rollout IDs")

    regressed = sorted(
        item_id for item_id, score in baseline.items()
        if candidate[item_id].hard < score.hard
    )
    candidate_soft = sum(score.soft for score in candidate.values()) / len(candidate) if candidate else 0.0
    eligible = (
        training.best_step > 0
        and training.best_selection_hard > training.baseline_selection_hard
        and not regressed
    )
    return SeedAssessment(
        seed=seed,
        baseline_hard=training.baseline_selection_hard,
        candidate_hard=training.best_selection_hard,
        candidate_soft=candidate_soft,
        best_step=training.best_step,
        candidate_hash=candidate_hash,
        regressed_items=regressed,
        eligible=eligible,
    )


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid or missing experiment artifact: {path}") from exc


def _candidate_metadata(run_root: Path, best_step: int) -> tuple[list[dict[str, Any]], str]:
    baseline = _read_json(run_root / "selection_eval_baseline" / "rollouts.json")
    if best_step == 0:
        return baseline, "initial-skill"
    candidate = _read_json(
        run_root / "steps" / f"step_{best_step:04d}" / "selection_eval" / "rollouts.json"
    )
    history = _read_json(run_root / "history.json")
    record = next((row for row in history if row.get("step") == best_step), None)
    if not record or not isinstance(record.get("candidate_hash"), str):
        raise ValueError(f"candidate metadata missing for step {best_step}")
    return candidate, record["candidate_hash"]


def _write_atomic(path: Path, payload: BaseModel) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(payload.model_dump_json(indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_experiment(args: argparse.Namespace) -> IterationSummary:
    assessments: list[SeedAssessment] = []
    for seed in args.seeds:
        run_root = args.output / f"seed-{seed}"
        command = [
            str(args.python), str(args.pilot / "train.py"),
            "--config", str(args.pilot / "config.yaml"), "--cfg-options",
            f"env.split_dir={args.pilot / 'data'}",
            f"env.fixtures_dir={args.pilot / 'fixtures'}",
            f"env.runtime_dir={args.root / 'skills/detecting-stack-profile'}",
            f"env.skill_init={args.root / 'skills/detecting-stack-profile/SKILL.md'}",
            f"env.out_root={run_root}",
            f"train.seed={seed}",
            "train.batch_size=8",
            "gradient.minibatch_size=4",
            "gradient.merge_batch_size=4",
            *_model_cfg_options(),
        ]
        subprocess.run(command, check=True)
        summary = _read_json(run_root / "summary.json")
        baseline = _read_json(run_root / "selection_eval_baseline" / "rollouts.json")
        best_step = TrainingSummary.model_validate(summary).best_step
        candidate, candidate_hash = _candidate_metadata(run_root, best_step)
        assessments.append(assess_run(
            seed=seed,
            summary=summary,
            baseline_rollouts=baseline,
            candidate_rollouts=candidate,
            candidate_hash=candidate_hash,
        ))

    eligible = [assessment.seed for assessment in assessments if assessment.eligible]
    result = IterationSummary(
        status="candidate" if eligible else "no-candidate",
        seeds=assessments,
        eligible_seeds=eligible,
    )
    _write_atomic(args.output / "iteration-summary.json", result)
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--pilot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seeds", type=int, nargs="+", default=[42, 314, 2718])
    return parser.parse_args()


def main() -> None:
    result = run_experiment(parse_args())
    print(result.model_dump_json(indent=2))


if __name__ == "__main__":
    main()
