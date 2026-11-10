#!/usr/bin/env python3
"""QA tracker entry point: parse the verb, load config and catalog, dispatch to the backend."""
from __future__ import annotations

import argparse
import importlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trackers import core  # noqa: E402
from trackers.ctx import Ctx, run_dir_for, run_label  # noqa: E402,F401

VERBS = ("validate", "results", "status", "init", "push-plan", "pull-plan",
         "push-run", "push-results", "push-bug", "update-retest")

# backend name -> module path, imported only when that backend is used
BACKENDS = {"local": "trackers.local", "clickup": "trackers.clickup"}


def load_backend(name: str):
    path = BACKENDS.get(name)
    if path is None:
        return None
    return importlib.import_module(path)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tracker.sh", description="QA tracker")
    p.add_argument("verb", choices=VERBS)
    p.add_argument("--project", default=".")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--run")
    p.add_argument("--label")
    p.add_argument("--only", nargs="+", default=[])
    p.add_argument("--overwrite", nargs="+", default=[])
    return p


def _print_json(obj: object) -> None:
    sys.stdout.write(json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n")


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    project = Path(args.project).resolve()
    try:
        cfg = core.load_config(project)
    except core.ConfigError as exc:
        sys.stderr.write(f"config error: {exc}\n")
        return 1

    if args.verb == "results":
        try:
            _print_json(core.case_results(run_dir_for(project, args.run)))
        except (core.RunError, FileNotFoundError) as exc:
            sys.stderr.write(f"error: {exc}\n")
            return 1
        return 0

    catalog = None
    try:
        catalog = core.load_catalog(project, cfg)
    except core.CatalogError as exc:
        if args.verb == "validate":
            _print_json({"errors": [{"file": None, "id": None, "reason": str(exc)}], "ok": False})
            return 1
        if args.verb not in ("status", "init"):
            sys.stderr.write(f"catalog error: {exc}\n")
            return 1

    if args.verb == "validate":
        errors = core.validate_catalog(catalog)
        _print_json({"errors": errors, "ok": not errors})
        return 0 if not errors else 1

    backend_name = cfg["backend"]
    module = load_backend(backend_name)
    handler = getattr(module, args.verb.replace("-", "_"), None) if module else None
    if handler is None:
        sys.stderr.write(f"{backend_name} does not support {args.verb}\n")
        return 2

    ctx = Ctx(project=project, cfg=cfg, catalog=catalog,
              log=core.ActionLog(apply=args.apply), cache=core.MapCache(project), args=args)
    try:
        handler(ctx)
    except core.ConfigError as exc:
        sys.stderr.write(f"config error: {exc}\n")
        return 1
    except (core.RunError, FileNotFoundError) as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1
    sys.stdout.write(ctx.log.summary() + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
