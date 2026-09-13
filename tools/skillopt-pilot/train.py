#!/usr/bin/env python3
"""Register the local adapter and delegate to SkillOpt's training CLI."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _load_upstream():
    source = Path(os.environ.get("SKILLOPT_SLEEP_REPO", "/home/dev/.local/share/skillopt"))
    if not (source / "scripts" / "train.py").is_file():
        raise SystemExit(f"SkillOpt source checkout not found: {source}")
    sys.path.insert(0, str(source))
    from scripts import train as upstream

    return upstream


def register_adapter(upstream) -> None:
    from stack_profile.adapter import StackProfileAdapter

    upstream._ENV_REGISTRY["qa_stack_profile"] = StackProfileAdapter


def main() -> None:
    upstream = _load_upstream()
    register_adapter(upstream)
    upstream.main()


if __name__ == "__main__":
    main()

