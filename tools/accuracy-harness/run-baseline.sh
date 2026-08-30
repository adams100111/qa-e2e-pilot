#!/usr/bin/env bash
# run-baseline.sh — one-command driver for the accuracy harness.
#
#   ./run-baseline.sh            # serve fixture + score bundled baseline & after-fixed projections
#   ./run-baseline.sh --serve    # just serve the fixture at http://localhost:8099 (Ctrl-C to stop)
#   ./run-baseline.sh --score <findings.json> [--gate]   # score a specific findings file
#
# To produce MEASURED numbers (not the bundled ESTIMATED projections):
#   1. ./run-baseline.sh --serve            (leave running)
#   2. Point .qa/config.json baseUrl at http://localhost:8099 and run the qa-e2e-pilot agent
#      against the fixture (see README "Measuring a real run").
#   3. Convert the run's .qa/runs/<id>/bug-log.json into a findings.json (README shows the shape)
#      and: ./run-baseline.sh --score path/to/findings.json --gate
set -euo pipefail
cd "$(dirname "$0")"
PORT="${QA_FIXTURE_PORT:-8099}"

case "${1:-}" in
  --serve)
    echo "Serving fixture at http://localhost:${PORT}  (Ctrl-C to stop)"
    exec python3 -m http.server "${PORT}" --directory fixture
    ;;
  --score)
    shift
    [ -n "${1:-}" ] || { echo "usage: run-baseline.sh --score <findings.json> [--gate]"; exit 2; }
    exec node scorer/score.js "$@"
    ;;
  "")
    echo "### Baseline (current pipeline — ESTIMATED) ###"
    node scorer/score.js findings/baseline.json || true
    echo ""
    echo "### After overhaul (designed pipeline — ESTIMATED) — enforcing acceptance gate ###"
    node scorer/score.js findings/after-fixed.json --gate
    ;;
  *)
    echo "usage: run-baseline.sh [--serve | --score <findings.json> [--gate]]"; exit 2 ;;
esac
