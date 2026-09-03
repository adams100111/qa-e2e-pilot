#!/usr/bin/env bash
# qa-ci.sh — turnkey unattended qa-e2e-pilot run for CI.
#
# Chains:  pre-flight  ->  drive the agent headless  ->  qa-verify (out-of-agent
# re-check)  ->  export JUnit XML  ->  exit code.
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
#   QA_VERIFY_CMD     script to run for the out-of-agent re-check (default: scripts/qa-verify.sh),
#                      invoked as `bash "$QA_VERIFY_CMD" "$RUN_ID"`
#   QA_SKIP_VERIFY    set to 1 to skip qa-verify entirely — ALWAYS LOGGED (never silent); a run
#                      reported this way is unverified, not "verified clean"
#   QA_VERIFY_STRICT  forwarded to qa-verify.sh as-is (ordinary env inheritance — qa-ci.sh does not
#                      need to do anything special for this to reach the subprocess); see
#                      scripts/qa-verify.sh's header for what strict mode changes
#   QA_JUNIT_OUT      JUnit XML output path        (default: qa-results.xml)
#   QA_SKIP_PREFLIGHT set to 1 to skip pre-flight (when CI handles app/auth liveness itself)
#
# EXIT: non-zero if pre-flight fails, the agent command fails, no run is produced, qa-verify
#       overrides at least one recorded pass (and was not explicitly skipped), or the run has any
#       fail/error criterion (so CI fails the build). 0 only on a clean, verified pass.
#
# HONESTY NOTE (Plan H2 WS-3 / docs/running-in-ci.md): no CI workflow in this repo runs a full QA
# pass today (.github/workflows/adapters.yml only validates the generated adapters). qa-ci.sh is
# the turnkey chain an operator or a project's OWN CI wires up to actually drive + verify a run —
# see docs/running-in-ci.md for the honest current state and an example GitHub Actions step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_BASE=".qa/runs"

HARNESS="${QA_HARNESS:-claude}"
default_agent_cmd() {
  python3 -c "import json;print(json.load(open('$REPO_ROOT/harness-profiles.json'))['harnesses']['$HARNESS']['agentCmd'])"
}

# QA_PRINT_AGENT_CMD short-circuits before the TARGET usage check below (it needs no target) —
# but still resolve/print the same way a real run would, then exit.
if [ "${QA_PRINT_AGENT_CMD:-}" = 1 ]; then
  AGENT_CMD="${QA_AGENT_CMD:-$(default_agent_cmd)}"
  echo "$AGENT_CMD"; exit 0
fi

TARGET="${1:-}"
CHECKLIST="${2:-}"
[[ -n "$TARGET" ]] || { echo "Usage: qa-ci.sh <target> [checklist-path]" >&2; exit 2; }

# Resolved after the usage check so a bare/no-arg invocation fails fast on clean usage text
# instead of shelling out to python3 (default_agent_cmd) first.
AGENT_CMD="${QA_AGENT_CMD:-$(default_agent_cmd)}"

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

# 4. qa-verify: independent, out-of-agent re-check -----------------------------
# The authoritative pass (Plan H2 Task 4): re-derives required evidence kinds,
# re-validates each artifact, and binds provenance against the capture-hook's
# toolstream, OVERRIDING any recorded `pass` that doesn't survive. Runs BEFORE
# the JUnit export so a verifier override is reflected in $JUNIT_OUT (a pass
# overridden to fail renders as a JUnit failure with the verifier's reason —
# see report-to-junit.sh). QA_SKIP_VERIFY is an explicit, LOGGED opt-out, never
# a silent one — a skipped run's verdicts are the in-run agent's self-report
# only, unverified.
VERIFY_RC=0
if [[ "${QA_SKIP_VERIFY:-0}" == "1" ]]; then
  log "qa-verify SKIPPED (QA_SKIP_VERIFY=1) -- run $RUN_ID's evidence was NOT independently re-checked; its verdicts reflect the in-run agent's own self-report only, UNVERIFIED"
else
  VERIFY_CMD="${QA_VERIFY_CMD:-$REPO_ROOT/scripts/qa-verify.sh}"
  log "qa-verify: independently re-checking run $RUN_ID (QA_VERIFY_STRICT=${QA_VERIFY_STRICT:-<unset>})"
  set +e
  bash "$VERIFY_CMD" "$RUN_ID"
  VERIFY_RC=$?
  set -e
  if [[ "$VERIFY_RC" -ne 0 ]]; then
    echo "qa-ci: qa-verify overrode at least one recorded pass for run $RUN_ID -- see $QA_BASE/$RUN_ID/verification.json" >&2
  fi
fi

# 5. Export JUnit XML (exit code reflects fail/error, now including qa-verify
#    overrides — report-to-junit.sh reads verification.json itself) ----------
log "exporting JUnit XML -> $JUNIT_OUT"
set +e
bash "$REPO_ROOT/scripts/report-to-junit.sh" "$RUN_ID" "$JUNIT_OUT"
JUNIT_RC=$?
set -e

# 6. Final exit -----------------------------------------------------------------
# Gates on: the agent command itself failing, OR qa-verify overriding a
# recorded pass (unless explicitly QA_SKIP_VERIFY'd), OR the JUnit suite
# having any fail/error testcase.
if [[ "${AGENT_FAILED:-0}" == "1" ]]; then exit 1; fi
if [[ "${VERIFY_RC:-0}" != "0" ]]; then exit 1; fi
exit "$JUNIT_RC"
