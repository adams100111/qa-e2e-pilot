#!/usr/bin/env python3
"""QA tracker entry point: parse the verb, load config and catalog, dispatch to the backend."""
from __future__ import annotations

import argparse
import importlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trackers import core  # noqa: E402
from trackers.clickup_api import DEFAULT_TOKEN_ENV, ApiError, token_env_name  # noqa: E402
from trackers.ctx import Ctx, run_dir_for, run_label  # noqa: E402,F401

VERBS = ("validate", "results", "status", "init", "push-plan", "pull-plan",
         "push-run", "push-results", "push-bug", "update-retest")

# backend name -> module path, imported only when that backend is used
BACKENDS = {"local": "trackers.local", "clickup": "trackers.clickup"}

# spec verb -> "module:function", imported only when that verb runs on a spec that is set up.
# Each handler is fn(ctx) -> None; see _spec_verb for what ctx carries.
SPEC_VERBS = {
    "lint": "trackers.cards:lint_verb",
    "spec-init": "trackers.clickup_spec:spec_init",
    "push-scenarios": "trackers.clickup_spec:push_scenarios",
    "sync-run": "trackers.clickup_spec:sync_run",
    "push-docs": "trackers.clickup_spec:push_docs",
    "spec-note": "trackers.clickup_spec:spec_note",
    "spec-status": "trackers.clickup_spec:spec_status",
}
SPEC_BACKEND = "clickup"
NO_BACKEND_VERBS = ("lint",)  # reads local files only: no backend, no token
NO_SUMMARY_VERBS = ("spec-status",)  # the handler's own JSON line is all of stdout: no summary line
SPEC_OPTIONAL_CATALOG = ("push-bug", "update-retest")  # run without a catalog when --spec is given
_SPEC_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def _spec_name_ok(value) -> bool:
    """`--spec` is a plain name: it is used in paths, so no separators and no `..`."""
    return isinstance(value, str) and bool(_SPEC_NAME_RE.match(value)) and ".." not in value


def load_backend(name: str):
    path = BACKENDS.get(name)
    if path is None:
        return None
    return importlib.import_module(path)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tracker.sh", description="QA tracker")
    p.add_argument("verb", choices=VERBS + tuple(SPEC_VERBS))
    p.add_argument("--project", default=".")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--run")
    p.add_argument("--label")
    p.add_argument("--only", nargs="+", default=[])
    p.add_argument("--overwrite", nargs="+", default=[])
    p.add_argument("--spec", metavar="TARGET", help="the spec a spec verb works on")
    p.add_argument("--retest", action="store_true", help="sync-run: reuse the spec's newest list")
    p.add_argument("--file", metavar="PATH", help="spec-note: the file holding the note's text")
    p.add_argument("--blocked", action="store_true", help="spec-note: also mark the run blocked")
    return p


def api_hints(token_env: str = DEFAULT_TOKEN_ENV) -> dict:
    """Hints per HTTP status. They name the variable the token is read from, never its value."""
    token = f"check {token_env} (a personal token with access to this workspace)"
    return {401: token, 403: token,
            404: f"check ids.workspace / ids.folder in {core.CONFIG_REL.as_posix()}"}


API_HINTS = api_hints()


def _token_env(cfg) -> str:
    try:
        return token_env_name(cfg)
    except core.ConfigError:
        return "tokenEnv"  # not a variable name (maybe a pasted token): never echo it


def _api_error(exc: ApiError, token_env: str = DEFAULT_TOKEN_ENV) -> None:
    """One line naming the failed call (never the response body or the token), plus a hint."""
    sys.stderr.write(f"clickup error: HTTP {exc.status} {exc.method} {exc.path}\n")
    hint = api_hints(token_env).get(exc.status)
    if hint:
        sys.stderr.write(f"hint: {hint}\n")


def _print_json(obj: object) -> None:
    sys.stdout.write(json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n")


def _spec_target(cfg, named):
    """The spec a spec verb works on: `--spec`, else the only enabled one under `specs`. Returns
    (target, None), or (None, "many") when it cannot be told without guessing (several enabled,
    or none listed while `specDefaults.enabled` makes any spec an enabled one), or (None, "none")
    when no spec can be enabled at all."""
    if named:
        return named, None
    enabled = core.enabled_specs(cfg)
    if len(enabled) == 1:
        return enabled[0], None
    defaults = cfg.get("specDefaults")
    by_default = isinstance(defaults, dict) and defaults.get("enabled") is True
    return None, ("many" if enabled or by_default else "none")


def _spec_verb(args, project: Path, cfg) -> int:
    """Run one SPEC_VERBS handler. Exit 0 ok or not set up, 1 error or any skipped item, 2 backend.
    Without `--spec` on a project where a spec is or can be enabled but cannot be told: exit 1.

    The handler gets a Ctx with: `args.spec` = the resolved target, `cfg` =
    `core.spec_settings(cfg, target)` (so `cfg["target"]` and `cfg["enabled"] is True`),
    `catalog` = None (spec verbs never load it), a fresh ActionLog (`--apply` or dry run) and
    the project's MapCache. It prints nothing but log lines; the summary is printed here, except
    after a NO_SUMMARY_VERBS handler, whose one JSON line is all that goes to stdout.
    """
    log = core.ActionLog(apply=args.apply)
    target, why = _spec_target(cfg, args.spec)
    if why == "many":
        sys.stderr.write("error: name the spec with --spec\n")
        return 1
    settings = core.spec_settings(cfg, target) if target else None
    if settings is None or settings.get("enabled") is not True:
        log.skip("not-set-up", target or "no spec is set up for the tracker")
        sys.stdout.write(log.summary() + "\n")
        return 0
    if args.verb not in NO_BACKEND_VERBS and settings.get("backend") != SPEC_BACKEND:
        sys.stderr.write(f"{settings.get('backend')} does not support {args.verb}\n")
        return 2

    mod_name, func = SPEC_VERBS[args.verb].split(":")
    handler = getattr(importlib.import_module(mod_name), func)
    args.spec = target
    ctx = Ctx(project=project, cfg=settings, catalog=None, log=log,
              cache=core.MapCache(project), args=args)
    summary = args.verb not in NO_SUMMARY_VERBS
    try:
        handler(ctx)
    except core.ConfigError as exc:
        sys.stderr.write(f"config error: {exc}\n")
        return 1
    except ApiError as exc:
        _api_error(exc, _token_env(settings))
        if summary:
            sys.stdout.write(log.summary() + "\n")
        return 1
    except (core.RunError, OSError) as exc:  # OSError: a file to read or upload is missing or unreadable
        sys.stderr.write(f"error: {exc}\n")
        return 1
    except Exception as exc:
        # an error class a tracker module defines itself (cards.CardsError, say) is a message
        # for the person; anything else is a defect and keeps its traceback
        if not type(exc).__module__.startswith("trackers."):
            raise
        sys.stderr.write(f"error: {exc}\n")
        return 1
    if summary:
        sys.stdout.write(log.summary() + "\n")
    return 1 if log.counts.get("skip") else 0


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    if args.spec is not None and not _spec_name_ok(args.spec):
        sys.stderr.write("error: --spec must be a spec name\n")  # the value is never echoed
        return 2
    project = Path(args.project).resolve()
    try:
        cfg = core.load_config(project)
    except core.ConfigError as exc:
        sys.stderr.write(f"config error: {exc}\n")
        return 1
    if not (project / core.CONFIG_REL).exists():
        sys.stderr.write(f"no {core.CONFIG_REL.as_posix()}: using the local backend\n")

    if args.verb in SPEC_VERBS:
        try:
            return _spec_verb(args, project, cfg)
        except core.ConfigError as exc:  # a malformed specs entry
            sys.stderr.write(f"config error: {exc}\n")
            return 1

    if args.verb == "results":
        try:
            _print_json(core.case_results(run_dir_for(project, args.run)))
        except (core.RunError, FileNotFoundError) as exc:
            sys.stderr.write(f"error: {exc}\n")
            return 1
        return 0

    if args.verb in SPEC_OPTIONAL_CATALOG and args.spec:
        # the spec's own settings (its tokenEnv, say) apply; a spec that is not set up is skipped
        try:
            cfg = core.spec_settings(cfg, args.spec)
        except core.ConfigError as exc:
            sys.stderr.write(f"config error: {exc}\n")
            return 1
        if cfg.get("enabled") is not True:
            log = core.ActionLog(apply=args.apply)
            log.skip("not-set-up", args.spec)
            sys.stdout.write(log.summary() + "\n")
            return 0

    catalog = None
    try:
        catalog = core.load_catalog(project, cfg)
    except core.CatalogError as exc:
        if args.verb == "validate":
            _print_json({"errors": [{"file": None, "id": None, "reason": str(exc)}], "ok": False})
            return 1
        if args.verb != "init" and not (args.verb in SPEC_OPTIONAL_CATALOG and args.spec):
            sys.stderr.write(f"catalog error: {exc}\n")
            return 1

    if args.verb == "validate":
        errors = core.validate_catalog(catalog)
        _print_json({"errors": errors, "ok": not errors})
        return 0 if not errors else 1

    if args.verb in ("push-bug", "update-retest") and cfg.get("bugsTo") == "issue-tracker":
        log = core.ActionLog(apply=args.apply)
        log.skip("bugs-elsewhere", "bugs are tracked in the project's issue tracker (docs/agents/issue-tracker.md)")
        sys.stdout.write(log.summary() + "\n")
        return 0

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
    except OSError as exc:
        if not (args.verb in SPEC_OPTIONAL_CATALOG and args.spec):
            raise  # verbs without --spec keep their behaviour
        sys.stderr.write(f"error: {exc}\n")
        return 1
    except ApiError as exc:
        _api_error(exc, _token_env(cfg))
        sys.stdout.write(ctx.log.summary() + "\n")
        return 1
    sys.stdout.write(ctx.log.summary() + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
