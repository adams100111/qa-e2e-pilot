"""SkillOpt environment adapter for the stack-profile pilot."""

from __future__ import annotations

from skillopt.datasets.base import BatchSpec
from skillopt.envs.base import EnvAdapter

from .dataloader import StackProfileDataLoader
from .rollout import run_batch


class StackProfileAdapter(EnvAdapter):
    def __init__(
        self,
        split_dir: str = "",
        fixtures_dir: str = "",
        runtime_dir: str = "",
        split_mode: str = "split_dir",
        workers: int = 1,
        analyst_workers: int = 1,
        failure_only: bool = False,
        minibatch_size: int = 2,
        edit_budget: int = 2,
        seed: int = 42,
        limit: int = 0,
        **_kwargs,
    ) -> None:
        self.workers = 1
        self.analyst_workers = analyst_workers
        self.failure_only = failure_only
        self.minibatch_size = minibatch_size
        self.edit_budget = edit_budget
        self.runtime_dir = runtime_dir
        self.dataloader = StackProfileDataLoader(
            split_dir=split_dir,
            split_mode=split_mode,
            fixtures_dir=fixtures_dir,
            seed=seed,
            limit=limit,
        )

    def setup(self, cfg: dict) -> None:
        super().setup(cfg)
        if not self.runtime_dir:
            self.runtime_dir = str(cfg.get("runtime_dir") or "")
        self.dataloader.setup(cfg)
        if self.runtime_dir:
            from pathlib import Path

            runtime = Path(self.runtime_dir).resolve()
            if not (runtime / "scripts" / "detect-stack.sh").is_file():
                raise ValueError(f"invalid stack-profile runtime_dir: {runtime}")
            for split in (self.dataloader.train_items, self.dataloader.val_items, self.dataloader.test_items):
                for item in split:
                    item["runtime_path"] = str(runtime)

    def get_dataloader(self) -> StackProfileDataLoader:
        return self.dataloader

    def build_env_from_batch(self, batch: BatchSpec, **_kwargs) -> list[dict]:
        return list(batch.payload or [])

    def build_train_env(self, batch_size: int, seed: int, **kwargs) -> list[dict]:
        return self.build_env_from_batch(
            self.dataloader.build_train_batch(batch_size=batch_size, seed=seed, **kwargs)
        )

    def build_eval_env(self, env_num: int, split: str, seed: int, **kwargs) -> list[dict]:
        return self.build_env_from_batch(
            self.dataloader.build_eval_batch(env_num=env_num, split=split, seed=seed, **kwargs)
        )

    def rollout(self, env_manager, skill_content: str, out_dir: str, **kwargs) -> list[dict]:
        return run_batch(
            items=list(env_manager),
            skill_content=skill_content,
            out_root=out_dir,
            **kwargs,
        )

    def get_task_types(self) -> list[str]:
        seen: list[str] = []
        for item in self.dataloader.train_items + self.dataloader.val_items + self.dataloader.test_items:
            task_type = str(item.get("task_type") or "stack-profile")
            if task_type not in seen:
                seen.append(task_type)
        return seen or ["stack-profile"]
