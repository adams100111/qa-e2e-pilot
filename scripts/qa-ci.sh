#!/usr/bin/env bash
# qa-ci.sh — turnkey unattended qa-e2e-pilot run for CI.
#
# Chains:  pre-flight  ->  drive the agent headless  ->  export JUnit XML  ->  exit code.
# Designed for the managed (zero-config) driver and a checklist already committed to the repo.
#
# USAGE:
#   qa-ci.sh <target> [checklist-path]
#
# ENV (all optional — overridable so this works across Claude Code CI setups and is testable):
#   QA_HARNESS        harness key into harness-profiles.json's agentCmd (default: claude)
#   QA_PREFLIGHT_CMD  command to run pre-flight   (default: the bundled preflight.sh)
#   QA_AGENT_CMD      command to drive the agent  (default: the $QA_HARNESS profile's agentCmd)
#                     QA_TARGET and QA_CHECKLIST are exported for a custom command to use.
#   QA_PRINT_AGENT_CMD set to 1 to print the resolved AGENT_CMD and exit (no target required)
#   QA_JUNIT_OUT      JUnit XML output path        (default: qa-results.xml)
#   QA_SKIP_PREFLIGHT set to 1 to skip pre-flight (when CI handles app/auth liveness itself)
#
# EXIT: non-zero if pre-flight fails, the agent command fails, no run is produced, or the
#       run has any fail/error criterion (so CI fails the build). 0 only on a clean pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_BASE=".qa/runs"

HARNESS="${QA_HARNESS:-claude}"
default_agent_cmd() {
  python3 -c "import json;print(json.load(open('$REPO_ROOT/harness-profiles.json'))['harnesses']['$HARNESS']['agentCmd'])"
}
AGENT_CMD="${QA_AGENT_CMD:-$(default_agent_cmd)}"
if [ "${QA_PRINT_AGENT_CMD:-}" = 1 ]; then echo "$AGENT_CMD"; exit 0; fi

TARGET="${1:-}"
CHECKLIST="${2:-}"
[[ -n "$TARGET" ]] || { echo "Usage: qa-ci.sh <target> [checklist-path]" >&2; exit 2; }

JUNIT_OUT="${QA_JUNIT_OUT:-qa-results.xml}"
PREFLIGHT_CMD="${QA_PREFLIGHT_CMD:-bash "$REPO_ROOT/skills/driving-browser-qa/scripts/preflight.sh"}"

log() { printf '\n=== qa-ci: %s ===\n' "$*"; }

# 1. Pre-flight ---------------------------------------------------------------
if [[ "${QA_SKIP_PREFLIGHT:-0}" == "1" ]]; then
  log "pre-flight skipped (QA_SKIP_PREFLIGHT=1)"
else
  log "pre-flight"
  if ! eval "$PREFLIGHT_CMD"; then
    echo "qa-ci: pre-flight failed — aborting before spending tokens" >&2
    exit 1
  fi
fi

# 2. Drive the agent headless -------------------------------------------------
log "driving agent for target: $TARGET${CHECKLIST:+ (checklist: $CHECKLIST)}"
export QA_TARGET="$TARGET"
export QA_CHECKLIST="$CHECKLIST"
if ! eval "$AGENT_CMD"; then
  echo "qa-ci: agent command exited non-zero" >&2
  # Continue to export whatever run state exists, then fail.
  AGENT_FAILED=1
fi

# 3. Locate the run produced --------------------------------------------------
[[ -d "$QA_BASE" ]] || { echo "qa-ci: no $QA_BASE/ produced — the agent did not start a run" >&2; exit 1; }
RUN_ID="$(ls -t "$QA_BASE" 2>/dev/null | grep -v '^\.' | head -1 || true)"
[[ -n "$RUN_ID" && -f "$QA_BASE/$RUN_ID/checkpoint.json" ]] || {
  echo "qa-ci: no run with a checkpoint.json found under $QA_BASE/ — nothing to report" >&2; exit 1; }
log "run: $RUN_ID"

# 4. Export JUnit XML (exit code reflects fail/error) -------------------------
log "exporting JUnit XML -> $JUNIT_OUT"
set +e
bash "$REPO_ROOT/scripts/report-to-junit.sh" "$RUN_ID" "$JUNIT_OUT"
JUNIT_RC=$?
set -e

# 5. Final exit ---------------------------------------------------------------
if [[ "${AGENT_FAILED:-0}" == "1" ]]; then exit 1; fi
exit "$JUNIT_RC"
