#!/usr/bin/env bash
# qa-dashboard.sh — the project-level QA state dashboard (engine 0.12.2). A thin
# wrapper over qa-dashboard.js (the one implementation), so every harness and the
# docs invoke it the same way:
#
#   bash scripts/qa-dashboard.sh html [--project <dir>] [--out <file>] [--refresh <sec>] [--watch <sec>] [--open]
#   bash scripts/qa-dashboard.sh tui  [--project <dir>] [--watch <sec>]
#   bash scripts/qa-dashboard.sh json [--project <dir>]
#
# html writes one self-contained page (default <project>/.qa/dashboard.html; no
# external requests, light + dark, works from file://; --refresh adds a meta
# refresh). tui prints a terminal view (colour only on a TTY, never with NO_COLOR;
# --watch redraws every N seconds until Ctrl-C). json prints the model.
# Read-only over .qa/; never reads .qa/auth; strings are redacted like bug-export.sh.
# Per-run verdicts, supersession and ship readiness come from render-report.js.
# Needs node.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "qa-dashboard: node is required (qa-dashboard.js is dependency-free node)" >&2; exit 1; }
exec node "$HERE/qa-dashboard.js" "$@"
