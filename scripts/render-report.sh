#!/usr/bin/env bash
# render-report.sh — render report.html + report.md for one run (engine 0.10.0,
# ADR-0028). A thin wrapper over render-report.js (the one implementation), so
# every harness and the docs invoke the renderer the same way:
#
#   bash scripts/render-report.sh .qa/runs/<run-id> [--embed]
#   bash scripts/render-report.sh <run-id> [--embed]        (from the project root)
#
# --embed inlines every screenshot as base64 (one portable report.html).
# Run it after scripts/qa-verify.sh so verdicts carry the verifier's overrides;
# re-run it any time — on any run, old or new — to regenerate the report.
# Writes through the filesystem, so it works when the pipeline runs as a
# subagent (whose Write tool may not create report files). Needs node.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "render-report: node is required (render-report.js is dependency-free node)" >&2; exit 1; }
exec node "$HERE/render-report.js" "$@"
