"""SkillOpt rollout implementation for synthetic stack-profile tasks."""

from __future__ import annotations

import json
import os
import shutil
from collections import Counter
from pathlib import Path
from typing import Callable

from .scoring import extract_result, score_result


TargetRunner = Callable[[Path, str, str], str]


def _task_text(item: dict) -> str:
    return (
        f"{item['prompt'].strip()}\n\n"
        "The synthetic project is in `project/`. Follow the dynamic guidance in the installed "
        "skill. Return exactly one JSON object and also write the identical object to `result.json`. "
        "Do not use the network and do not inspect paths outside this workspace."
    )


def _default_target_runner(work_dir: Path, skill_md: str, task_text: str) -> str:
    from skillopt.model import get_target_backend, is_target_exec_backend
    from skillopt.model.codex_harness import run_target_exec

    if not is_target_exec_backend():
        raise RuntimeError(
            f"qa_stack_profile requires an exec target backend, got {get_target_backend()}"
        )
    from skillopt.model import azure_openai as model_state

    response, _raw = run_target_exec(
        work_dir=str(work_dir),
        prompt=(
            "Read task.md and .agents/skills/skillopt-target/SKILL.md. Inspect only the synthetic "
            "project/ directory. Complete the requested stack analysis, write result.json, and "
            "return only the same JSON object."
        ),
        model=model_state.TARGET_DEPLOYMENT,
        timeout=180,
        sandbox="workspace-write",
        allow_file_edits=True,
    )
    result_path = work_dir / "result.json"
    return result_path.read_text(encoding="utf-8") if result_path.is_file() else response


def _render_skill(skill_content: str) -> str:
    return (
        "---\n"
        'name: "skillopt-target"\n'
        'description: "Use when analyzing the synthetic stack-profile benchmark project."\n'
        "---\n\n"
        "# Stack-Profile Benchmark Guidance\n\n"
        "Inspect the local project and return the requested stack facts as JSON.\n\n"
        f"{skill_content.strip()}\n"
    )


def _prepare_workspace(work_dir: Path, skill_md: str, task_text: str) -> None:
    if work_dir.exists():
        shutil.rmtree(work_dir)
    skill_dir = work_dir / ".agents" / "skills" / "skillopt-target"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(skill_md, encoding="utf-8")
    (work_dir / "task.md").write_text(task_text, encoding="utf-8")


def process_one(
    item: dict,
    *,
    out_root: str,
    skill_content: str,
    target_runner: TargetRunner | None = None,
) -> dict:
    """Run and score one item while persisting reflection-compatible evidence."""
    item_id = str(item["id"])
    pred_dir = Path(out_root) / "predictions" / item_id
    work_dir = pred_dir / "workspace"
    pred_dir.mkdir(parents=True, exist_ok=True)
    task_text = _task_text(item)
    skill_md = _render_skill(skill_content)
    result = {
        "id": item_id,
        "hard": 0,
        "soft": 0.0,
        "predicted_answer": "",
        "response": "",
        "fail_reason": "",
        "agent_ok": False,
        "n_turns": 0,
        "task_description": item["prompt"],
        "task_type": item.get("task_type", "stack-profile"),
        "target_system_prompt": skill_md,
        "target_user_prompt": task_text,
        "reference_text": item.get("reference_text", ""),
    }

    try:
        _prepare_workspace(work_dir, skill_md, task_text)
        shutil.copytree(item["fixture_path"], work_dir / "project")
        runner = target_runner or _default_target_runner
        response = runner(work_dir, skill_md, task_text)
        parsed = extract_result(response)
        score = score_result(parsed, item["assertions"])
        result.update(
            hard=score.hard,
            soft=score.soft,
            predicted_answer=json.dumps(parsed, ensure_ascii=False, sort_keys=True),
            response=response,
            agent_ok=True,
            n_turns=1,
            fail_reason="; ".join(score.failures),
        )
        if not parsed:
            result["fail_reason"] = "invalid or missing JSON object in target response"
    except Exception as exc:  # target failures are scored rows unless every row fails
        result["fail_reason"] = f"target execution failed: {type(exc).__name__}: {exc}"

    conversation = [
        {"role": "system", "content": skill_md},
        {"role": "user", "content": task_text},
        {"role": "assistant", "content": result["response"]},
    ]
    (pred_dir / "conversation.json").write_text(
        json.dumps(conversation, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (pred_dir / "score.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return result


def run_batch(
    *,
    items: list[dict],
    skill_content: str,
    out_root: str,
    target_runner: TargetRunner | None = None,
    **_kwargs,
) -> list[dict]:
    """Run a deterministic sequential batch and reject systemic target failure."""
    os.makedirs(out_root, exist_ok=True)
    results = [
        process_one(
            item,
            out_root=out_root,
            skill_content=skill_content,
            target_runner=target_runner,
        )
        for item in items
    ]
    if results and all(not row["agent_ok"] for row in results):
        reasons = Counter(row["fail_reason"] for row in results)
        common, count = reasons.most_common(1)[0]
        raise RuntimeError(
            f"all {len(results)} stack-profile rollouts failed before scoring ({count}x): {common}"
        )
    Path(out_root, "rollouts.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return results
