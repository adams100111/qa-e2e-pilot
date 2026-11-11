"""Shared context and run helpers for the tracker CLI and every backend."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

from trackers.core import ActionLog, Catalog, MapCache


@dataclass
class Ctx:
    project: Path
    cfg: Any  # core.Config
    catalog: Optional[Catalog]
    log: ActionLog
    cache: MapCache
    args: Any  # argparse.Namespace


def run_dir_for(project: Path, run_id: Optional[str] = None) -> Path:
    """The run dir for `run_id`, else the newest `.qa/runs/*` that has a checkpoint.json."""
    runs = Path(project) / ".qa" / "runs"
    if run_id:
        d = runs / run_id
        if not d.is_dir():
            raise FileNotFoundError(f"{d}: run not found")
        return d
    best = None
    if runs.is_dir():
        for d in runs.iterdir():
            cp = d / "checkpoint.json"
            if d.is_dir() and cp.is_file():
                key = (cp.stat().st_mtime, d.name)
                if best is None or key > best[0]:
                    best = (key, d)
    if best is None:
        raise FileNotFoundError(f"{runs}: no run with a checkpoint.json")
    return best[1]


def _manifest(run_dir: Path) -> dict:
    try:
        with open(Path(run_dir) / "run-manifest.json", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _run_date(run_dir: Path, manifest: dict) -> str:
    for key in ("date", "started_at", "startedAt", "created_at", "createdAt"):
        v = manifest.get(key)
        if isinstance(v, str) and re.match(r"\d{4}-\d{2}-\d{2}", v):
            return v[:10]
    name = Path(run_dir).name
    m = re.search(r"(\d{4})-?(\d{2})-?(\d{2})", name)
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m else name


BUILD_KEYS = ("build", "build_id", "buildId", "version")


def build_token(value: Any) -> str:
    """Only the leading version token of a manifest build value: build ids often carry a branch,
    commit or note ("v1.4.46 (next@beb2492a7) - ...") that must not reach a tracker."""
    if not isinstance(value, (str, int)) or isinstance(value, bool):
        return ""
    return re.split(r"[\s(@/]", str(value).strip(), 1)[0]


def manifest_build(manifest: dict) -> str:
    """The build token from the first non-empty build key of run-manifest.json, else ""."""
    for key in BUILD_KEYS:
        build = build_token(manifest.get(key))
        if build:
            return build
    return ""


def run_label(run_dir: Path, args: Any = None) -> str:
    """`--label`, else `<YYYY-MM-DD> <build>` from run-manifest.json, else `<YYYY-MM-DD>`."""
    label = getattr(args, "label", None)
    if label:
        return str(label)
    manifest = _manifest(run_dir)
    date = _run_date(run_dir, manifest)
    build = manifest_build(manifest)
    return f"{date} {build}" if build else date
