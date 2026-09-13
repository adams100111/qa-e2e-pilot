"""Validated split loader for the stack-profile SkillOpt pilot."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from skillopt.datasets.base import SplitDataLoader


class StackProfileDataLoader(SplitDataLoader):
    """Load benchmark items and reject split contamination before training."""

    def __init__(self, *args: Any, fixtures_dir: str = "", **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.fixtures_dir = str(fixtures_dir)

    def setup(self, cfg: dict) -> None:
        if not self.fixtures_dir:
            self.fixtures_dir = str(cfg.get("fixtures_dir") or "")
        if not self.fixtures_dir:
            raise ValueError("StackProfileDataLoader requires fixtures_dir")
        self.fixtures_dir = str(Path(self.fixtures_dir).resolve())
        super().setup(cfg)
        self._validate_all_splits()

    def load_split_items(self, split_path: str) -> list[dict]:
        path = Path(split_path) / "items.json"
        if not path.is_file():
            raise FileNotFoundError(f"No items.json found in {split_path}")
        raw = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(raw, list):
            raise ValueError(f"Expected JSON array in {path}")
        return [self._normalize_item(item, path) for item in raw]

    def _normalize_item(self, item: Any, source: Path) -> dict:
        if not isinstance(item, dict):
            raise ValueError(f"Every item in {source} must be an object")
        normalized = dict(item)
        item_id = str(normalized.get("id") or "").strip()
        fixture = str(normalized.get("fixture") or "").strip()
        prompt = str(normalized.get("prompt") or "").strip()
        assertions = normalized.get("assertions")
        if not item_id or not fixture or not prompt:
            raise ValueError(f"Item in {source} requires non-empty id, fixture, and prompt")
        if not isinstance(assertions, list) or not assertions:
            raise ValueError(f"Item '{item_id}' requires non-empty assertions")
        for assertion in assertions:
            if not isinstance(assertion, dict) or not str(assertion.get("path") or "").strip():
                raise ValueError(f"Item '{item_id}' has malformed assertion")
            operators = [name for name in ("equals", "not_equals") if name in assertion]
            if len(operators) != 1:
                raise ValueError(
                    f"Item '{item_id}' assertion must contain exactly one of equals or not_equals"
                )
        fixture_path = (Path(self.fixtures_dir) / fixture).resolve()
        try:
            fixture_path.relative_to(Path(self.fixtures_dir))
        except ValueError as exc:
            raise ValueError(f"Item '{item_id}' fixture escapes fixtures_dir") from exc
        if not fixture_path.is_dir():
            raise ValueError(f"Item '{item_id}' fixture does not exist: {fixture_path}")
        normalized["id"] = item_id
        normalized["fixture_path"] = str(fixture_path)
        normalized["task_type"] = str(normalized.get("task_type") or "stack-profile")
        return normalized

    @staticmethod
    def _fixture_digest(path: Path) -> str:
        digest = hashlib.sha256()
        for child in sorted(entry for entry in path.rglob("*") if entry.is_file()):
            digest.update(str(child.relative_to(path)).encode())
            digest.update(b"\0")
            digest.update(child.read_bytes())
            digest.update(b"\0")
        return digest.hexdigest()

    def _content_digest(self, item: dict) -> str:
        semantic = {
            "fixture": self._fixture_digest(Path(item["fixture_path"])),
            "prompt": item["prompt"],
            "assertions": item["assertions"],
            "task_type": item["task_type"],
        }
        encoded = json.dumps(semantic, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        return hashlib.sha256(encoded.encode()).hexdigest()

    def _validate_all_splits(self) -> None:
        ids: dict[str, str] = {}
        content: dict[str, str] = {}
        for split in ("train", "val", "test"):
            for item in self._splits[split]:
                item_id = item["id"]
                if item_id in ids:
                    raise ValueError(f"duplicate item id '{item_id}' across splits {ids[item_id]} and {split}")
                ids[item_id] = split
                digest = self._content_digest(item)
                if digest in content:
                    raise ValueError(f"item content overlaps splits {content[digest]} and {split}")
                content[digest] = split
