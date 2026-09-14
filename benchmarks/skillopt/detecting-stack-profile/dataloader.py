"""Data loader for the detecting-stack-profile benchmark.

Reads a pre-split ``train/ val/ test/`` layout, each holding one
``items.json`` array. Items carry their ground-truth ``expected`` inline
(see ``data/*/items.json``), so no separate answer key is needed.
"""
from __future__ import annotations

import json
from pathlib import Path

from skillopt.datasets.base import SplitDataLoader


def _normalize_item(raw: dict) -> dict:
    return {
        "id": str(raw.get("id") or ""),
        "task_type": str(raw.get("task_type") or "code"),
        "fixture": str(raw.get("fixture") or raw.get("id") or ""),
        "detect": dict(raw.get("detect") or {"mode": "code"}),
        "expected": dict(raw.get("expected") or {}),
    }


class DetectingStackProfileLoader(SplitDataLoader):
    """Loader for the detecting-stack-profile fixtures (``split_dir`` mode)."""

    def load_split_items(self, split_path: str) -> list[dict]:
        path = Path(split_path)
        files = sorted(path.glob("*.json"))
        if not files:
            raise FileNotFoundError(f"No items.json found in {split_path}")
        with files[0].open(encoding="utf-8") as fh:
            payload = json.load(fh)
        if not isinstance(payload, list):
            raise ValueError(f"Expected a JSON array at top level of {files[0]}")
        return [_normalize_item(row) for row in payload]
