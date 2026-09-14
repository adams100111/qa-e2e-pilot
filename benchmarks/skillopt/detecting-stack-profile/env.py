"""SkillOpt environment adapter for the detecting-stack-profile skill.

What is being optimized: the **prose of** ``skills/detecting-stack-profile/
SKILL.md``. In a rollout the target model is given that prose as its system
skill and the raw fixture (manifests, or captured runtime headers for the
black-box case) as the task, and must emit a ``stack-profile.json``. The
produced profile is scored by :mod:`scorer` against field-scoped ground
truth. SkillOpt then reflects on failures and proposes bounded edits to the
prose, keeping an edit only if it improves the held-out selection score.

Why the model — not ``detect-stack.sh`` — does the work: SkillOpt edits
*text*, so the thing under test must be text-driven. A chat rollout cannot
execute the bundled script, so it exercises exactly what the prose + the
inline signatures teach a model to conclude. That is the honest target: "how
well does this skill's writing lead an agent to the correct profile?"
"""
from __future__ import annotations

import json
import os
import re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from skillopt.envs.base import EnvAdapter
from skillopt.model import chat_target

from .dataloader import DetectingStackProfileLoader
from . import scorer

_BENCH_ROOT = Path(__file__).resolve().parent
_FIXTURES = _BENCH_ROOT / "fixtures"

_SYSTEM_FRAME = """You are detecting the technology stack of a target application.
Follow the skill below exactly.

## Skill
{skill}

## Output contract
Emit ONLY a single fenced ```json block containing a stack-profile object with:
  mode: "local-matched" | "source-drift" | "black-box"
  environment: "production" | "disposable"
  components: [ {{ role, language, framework, orm: {{name, migrationsPath}},
                  auth: {{scheme}}, frontend: {{routing}},
                  i18n: {{present, mechanisms}} }} ]
  primary: {{ backend: <index>, frontend: <index> }}
Do not include prose outside the JSON block.
"""


def _read_fixture(item: dict) -> str:
    """Render the fixture into the task text the model reasons over."""
    fixture = _FIXTURES / item["fixture"]
    mode = item.get("detect", {}).get("mode", "code")
    if mode == "blackbox":
        headers = (fixture / "headers.txt").read_text(encoding="utf-8")
        base_url = item.get("detect", {}).get("base_url", "")
        return (
            f"## Black-box target\nbaseUrl: {base_url}\nNo source repository is available.\n\n"
            f"## Captured runtime response headers\n```\n{headers.strip()}\n```"
        )
    repos = item.get("detect", {}).get("repos") or ["repo"]
    parts = ["## Local source manifests"]
    for rel in repos:
        root = fixture / rel
        for manifest in sorted(root.rglob("*")):
            if manifest.is_file():
                body = manifest.read_text(encoding="utf-8", errors="replace").strip()
                rel_name = manifest.relative_to(fixture)
                parts.append(f"### {rel_name}\n```\n{body}\n```")
    return "\n\n".join(parts)


def _extract_json(text: str) -> dict:
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    blob = fence.group(1) if fence else None
    if blob is None:
        brace = re.search(r"(\{.*\})", text, re.DOTALL)
        blob = brace.group(1) if brace else None
    if not blob:
        raise ValueError("no JSON object found in model output")
    return json.loads(blob)


class DetectingStackProfileEnv(EnvAdapter):
    """EnvAdapter that optimizes the detecting-stack-profile skill prose."""

    def __init__(
        self,
        split_dir: str = "",
        data_path: str = "",
        split_mode: str = "split_dir",
        split_ratio: str = "2:1:7",
        split_seed: int = 42,
        split_output_dir: str = "",
        workers: int = 4,
        analyst_workers: int = 8,
        failure_only: bool = False,
        minibatch_size: int = 8,
        edit_budget: int = 4,
        seed: int = 42,
        limit: int = 0,
        max_completion_tokens: int = 4096,
        **_ignored,
    ) -> None:
        self.workers = int(workers)
        self.analyst_workers = int(analyst_workers)
        self.failure_only = failure_only
        self.minibatch_size = int(minibatch_size)
        self.edit_budget = int(edit_budget)
        self.max_completion_tokens = int(max_completion_tokens)
        self.dataloader = DetectingStackProfileLoader(
            split_dir=split_dir,
            data_path=data_path,
            split_mode=split_mode,
            split_ratio=split_ratio,
            split_seed=split_seed,
            split_output_dir=split_output_dir,
            seed=seed,
            limit=limit,
        )

    # ── lifecycle ──────────────────────────────────────────────────────
    def setup(self, cfg: dict) -> None:
        super().setup(cfg)
        self.dataloader.setup(cfg)

    def get_dataloader(self):
        return self.dataloader

    # ── batch → env ────────────────────────────────────────────────────
    def build_env_from_batch(self, batch, **kwargs):
        return list(batch.payload or [])

    def build_train_env(self, batch_size: int, seed: int, **kwargs):
        return self.build_env_from_batch(
            self.dataloader.build_train_batch(batch_size=batch_size, seed=seed, **kwargs)
        )

    def build_eval_env(self, env_num: int, split: str, seed: int, **kwargs):
        return self.build_env_from_batch(
            self.dataloader.build_eval_batch(env_num=env_num, split=split, seed=seed, **kwargs)
        )

    # ── rollout ────────────────────────────────────────────────────────
    def _process_one(self, item: dict, out_dir: str, skill_content: str) -> dict:
        item_id = str(item["id"])
        pred_dir = os.path.join(out_dir, "predictions", item_id)
        os.makedirs(pred_dir, exist_ok=True)
        result = {
            "id": item_id,
            "task_type": item.get("task_type", "code"),
            "hard": 0,
            "soft": 0.0,
            "fail_reason": "",
        }
        system = _SYSTEM_FRAME.format(skill=skill_content.strip())
        user = _read_fixture(item)
        try:
            response, _usage = chat_target(
                system=system,
                user=user,
                max_completion_tokens=self.max_completion_tokens,
                retries=5,
                stage="rollout",
            )
        except Exception as exc:  # target-model failure — score 0, keep the run alive
            result["fail_reason"] = f"target call failed: {exc}"
            self._persist(pred_dir, system, user, "", result)
            return result

        try:
            profile = _extract_json(response)
        except Exception as exc:
            result["fail_reason"] = f"unparseable profile: {exc}"
            self._persist(pred_dir, system, user, response, result)
            return result

        scored = scorer.score(profile, item["expected"])
        result["hard"] = scored["hard"]
        result["soft"] = scored["soft"]
        result["fail_reason"] = scored["fail_reason"]
        result["checks"] = scored["checks"]
        self._persist(pred_dir, system, user, response, result)
        return result

    @staticmethod
    def _persist(pred_dir: str, system: str, user: str, response: str, result: dict) -> None:
        # The inherited reflect() reads predictions/<id>/conversation.json.
        conversation = [
            {"type": "system", "content": system},
            {"type": "user", "content": user},
            {"type": "message", "turn": 1, "content": response},
        ]
        with open(os.path.join(pred_dir, "conversation.json"), "w", encoding="utf-8") as fh:
            json.dump(conversation, fh, indent=2)
        with open(os.path.join(pred_dir, "result.json"), "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2)

    def rollout(self, env_manager, skill_content: str, out_dir: str, **kwargs) -> list[dict]:
        items: list[dict] = env_manager
        if not items:
            return []
        workers = max(1, min(self.workers, len(items)))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            return list(pool.map(lambda it: self._process_one(it, out_dir, skill_content), items))

    # ── stratification hint ────────────────────────────────────────────
    def get_task_types(self) -> list[str]:
        seen: list[str] = []
        for item in (
            self.dataloader.train_items
            + self.dataloader.val_items
            + self.dataloader.test_items
        ):
            tt = str(item.get("task_type") or "code")
            if tt not in seen:
                seen.append(tt)
        return seen or ["code"]
