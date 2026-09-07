#!/usr/bin/env bash
# run-baseline2.sh — one-command driver for the accuracy harness's SECOND, generator-untuned
# fixture (fixture2/index.html, InvoicePad Mini). Thin copy of run-baseline.sh pointed at
# fixture2/seeds2.json instead of fixture/seeds.json — see README.md's "Second fixture (fixture2)"
# section for why this fixture exists and the firewall discipline it was authored under.
#
# This script orchestrates a real measurement; it never fakes one. It cannot drive the
# Playwright MCP itself, so the middle step (actually QA-ing the fixture) is done by an
# operator dispatching the qa-e2e-pilot agent in an agent session that has Playwright MCP
# configured. This script's job is: serve the fixture, tell the operator exactly what to run,
# wait for that run to finish, then convert + score the resulting bug-log.json. Teardown of
# the fixture server always runs on exit (normal completion, error, or Ctrl-C).
#
#   ./run-baseline2.sh                                    # serve -> print agent invocation -> wait -> convert -> score --gate
#   ./run-baseline2.sh --serve                             # just serve the fixture at http://localhost:8199 (Ctrl-C to stop)
#   ./run-baseline2.sh --score <findings.json> [--gate]    # score an already-converted findings file
#
# Env:
#   QA_FIXTURE2_PORT   port to serve the fixture on (default 8199; distinct from run-baseline.sh's
#                       8099 default so both fixtures can be served side by side)
#   QA_DRYRUN=1         skip the "wait for the agent run" step entirely (and the convert/score that
#                       needs a real bug-log.json) — used to exercise the serve/teardown path only.
#
# See README.md ("Second fixture (fixture2)") for the full walkthrough and the fixture's seeded bugs.
set -euo pipefail
cd "$(dirname "$0")"
PORT="${QA_FIXTURE2_PORT:-8199}"

usage() {
  echo "usage: run-baseline2.sh [--serve | --score <findings.json> [--gate]]" >&2
}

SERVER_PID=""
cleanup() {
  if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}

# Starts the fixture server in the background and arms teardown on any exit path.
start_server() {
  python3 -m http.server "${PORT}" --directory fixture2 >/tmp/qa-fixture2-http-"${PORT}".log 2>&1 &
  SERVER_PID=$!
  trap cleanup EXIT INT TERM

  for _ in $(seq 1 40); do
    if curl -sf -o /dev/null "http://localhost:${PORT}/"; then
      return 0
    fi
    sleep 0.25
  done
  echo "fixture2 server did not come up on port ${PORT} (see /tmp/qa-fixture2-http-${PORT}.log)" >&2
  exit 1
}

case "${1:-}" in
  --serve)
    echo "Serving fixture2 at http://localhost:${PORT}  (Ctrl-C to stop)"
    exec python3 -m http.server "${PORT}" --directory fixture2
    ;;
  --score)
    shift
    [ -n "${1:-}" ] || { usage; exit 2; }
    exec node scorer/score.js "$@" --seeds seeds2.json
    ;;
  "")
    echo "### Accuracy-harness MEASURED run (fixture2) ###"
    start_server
    echo "Fixture2 serving at: http://localhost:${PORT}"
    echo ""
    echo "This script cannot drive the Playwright MCP itself. In an agent session that has"
    echo "Playwright MCP configured, dispatch the qa-e2e-pilot agent against the fixture:"
    echo ""
    echo "  1. Point .qa/config.json 'baseUrl' at http://localhost:${PORT} (single-repo; no"
    echo "     backend repo needed — the fixture is black-box; do NOT show the agent seeds2.json)."
    echo "  2. Run:  /qa-run \"accuracy-harness fixture2\""
    echo "     (equivalently: dispatch subagent_type qa-e2e-pilot at http://localhost:${PORT})"
    echo "  3. Let the run finish; it writes .qa/runs/<run-id>/bug-log.json"
    echo ""

    if [ "${QA_DRYRUN:-0}" = "1" ]; then
      echo "QA_DRYRUN=1 — skipping the agent wait and convert/score (serve/teardown path only)."
      exit 0
    fi

    read -rp "Press Enter once the agent run has finished... " _
    read -rp "Path to that run's bug-log.json: " BUGLOG
    [ -n "${BUGLOG}" ] && [ -f "${BUGLOG}" ] || { echo "not found: ${BUGLOG}" >&2; exit 1; }

    RUN_ID="$(basename "$(dirname "${BUGLOG}")")"
    mkdir -p findings
    OUT="findings/measured-fixture2-${RUN_ID}.json"
    node scorer/convert-buglog.js "${BUGLOG}" > "${OUT}"
    echo "Wrote ${OUT}"
    node scorer/score.js "${OUT}" --seeds seeds2.json --gate
    ;;
  *)
    usage; exit 2 ;;
esac
