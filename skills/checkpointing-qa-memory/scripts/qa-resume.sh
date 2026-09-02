#!/usr/bin/env bash
# qa-resume.sh — the operator-facing PORTABLE resume briefing (durable-resume
# Plan B, Task 5). Resolves a run (an explicit run-id, or the content of
# `.qa/runs/latest`), folds it (journal.ndjson -> checkpoint.json/
# fold-anomalies.json/cursor.json via fold.sh), and prints a single line of
# JSON: the resume briefing the `/qa-resume` command hands to the agent.
#
# USAGE:
#   qa-resume.sh [run-id]
#       run-id defaults to the (trimmed) content of `.qa/runs/latest` when
#       omitted. Dies clearly if neither an explicit run-id NOR a usable
#       `.qa/runs/latest` is available, and again if the resolved run has no
#       journal at all (nothing to resume).
#
#       Folds the run (fold.sh), then prints ONE line of JSON:
#         {
#           "run_id":   <string>,
#           "phase":    <string|null>,           -- cursor.json's phase
#           "cursor":   {"scenarioId","criterionId"} | null,
#                                                 -- cursor.json's cursor:
#                                                 the first (scenario,
#                                                 criterion) tuple that is
#                                                 started/planned but has NO
#                                                 criterion_verdict yet.
#           "openActs": [{key,scenarioId,criterionId,personaId,writeSet}, ...]
#                                                 -- qa-reconcile.sh plan's
#                                                 output verbatim: every
#                                                 act_intent with no matching
#                                                 act_committed. Empty array
#                                                 means nothing to reconcile.
#           "skip":     [{"scenarioId","criterionId"}, ...]
#                                                 -- every tuple that ALREADY
#                                                 has a criterion_verdict
#                                                 (checkpoint.json's
#                                                 `criteria[]`, which fold.jq/
#                                                 fold.py only ever populate
#                                                 for a verdicted tuple) --
#                                                 i.e. completed work the
#                                                 resumed Verify loop must
#                                                 SKIP. scenarioId is derived
#                                                 from checkpoint.json's
#                                                 `persona` field per the
#                                                 ADR-0012 identity
#                                                 convention journal-emit.sh
#                                                 documents (persona-scoped:
#                                                 scenarioId == personaId;
#                                                 shared: scenarioId ==
#                                                 "__shared__", personaId ==
#                                                 "") -- the SAME
#                                                 normalization fold.jq's own
#                                                 cursor pointer uses, so
#                                                 `skip` and `cursor` are
#                                                 built on one consistent
#                                                 rule and can never overlap
#                                                 (a verdicted tuple is never
#                                                 also the cursor; fold.jq's
#                                                 `criteria[]` only includes
#                                                 verdict != null, and the
#                                                 cursor is the first tuple
#                                                 with verdict == null).
#         }
#
#       This script does NOT drive the browser and does NOT reconcile
#       anything itself (`openActs` is read-only planning, via
#       `qa-reconcile.sh plan`, which never touches the journal either) --
#       the `/qa-resume` command is what instructs the agent to run
#       `qa-reconcile.sh apply` for each open act (fed real read-backs from
#       its OWN browser/probe capability) before continuing Verify at
#       `cursor`.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3 (jq preferred; no
# node). Honors QA_ENGINE the same way journal.sh/checkpoint.sh/fold.sh/
# journal-emit.sh/rebake.sh/qa-reconcile.sh do.
#
# NOTE: all paths are relative to the current working directory (project
# root), same convention as the rest of this script family.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

# ---------------------------------------------------------------------------
# helpers (has_jq/has_py/die/validate_token copied from qa-reconcile.sh's
# header — same QA_ENGINE-honoring contract)
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

has_py() { command -v python3 >/dev/null 2>&1; }

validate_token() {
  local value="$1" label="$2"
  [[ -z "$value" ]] && die "${label} must not be empty."
  case "$value" in
    */*|*\\*) die "${label} '${value}' contains a path separator ('/' or '\\') — must be a simple token." ;;
  esac
  case "$value" in
    *..*) die "${label} '${value}' contains '..' — must be a simple token." ;;
  esac
  if [[ "$value" =~ ^\.+$ ]]; then
    die "${label} '${value}' is '.' or consists only of dots — must be a simple token."
  fi
  case "$value" in
    -*) die "${label} '${value}' starts with '-' — must be a simple token." ;;
  esac
  return 0
}

# Locate fold.sh/qa-reconcile.sh relative to THIS script without depending
# on external `dirname` (pure bash parameter expansion — same trick the rest
# of this script family uses, so a restricted test PATH doesn't break
# self-location).
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
FOLD_SH="${SCRIPT_DIR}/fold.sh"
RECONCILE_SH="${SCRIPT_DIR}/qa-reconcile.sh"

# Resolve the engine ONCE, from THIS script's own has_jq (which already
# honors QA_ENGINE), then pass it explicitly to every fold.sh/qa-reconcile.sh
# subprocess call — same rationale as qa-reconcile.sh's/rebake.sh's ENGINE
# (a leaked jq on PATH can never silently switch engines mid-run).
ENGINE="python3"
has_jq && ENGINE="jq"

latest_file() { echo "${QA_BASE}/latest"; }
journal_file_for() { echo "${QA_BASE}/${1}/journal.ndjson"; }
checkpoint_file_for() { echo "${QA_BASE}/${1}/checkpoint.json"; }
cursor_file_for() { echo "${QA_BASE}/${1}/cursor.json"; }

# ---------------------------------------------------------------------------
# resolve_run_id [run-id] -> stdout the run-id to use. <run-id>, when
# non-empty, always wins over `.qa/runs/latest`. Dies clearly when neither is
# available.
# ---------------------------------------------------------------------------
resolve_run_id() {
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return 0
  fi
  local lf; lf="$(latest_file)"
  [[ -f "$lf" ]] \
    || die "qa-resume.sh: no run-id given and '${lf}' does not exist — nothing to resume. Pass an explicit run-id (qa-resume.sh <run-id>), or start a run first (a run's first journal event writes ${lf})."
  local rid
  rid="$(tr -d '\n\r' < "$lf")"
  [[ -n "$rid" ]] \
    || die "qa-resume.sh: '${lf}' exists but is empty — cannot resolve a run-id from it. Pass an explicit run-id (qa-resume.sh <run-id>)."
  echo "$rid"
}

# ---------------------------------------------------------------------------
# build_briefing_jq/py <cursor-json> <checkpoint-json> <openacts-json> ->
# stdout ONE line of JSON: {run_id, phase, cursor, openActs, skip}.
# ---------------------------------------------------------------------------

build_briefing_jq() {
  local cursor_json="$1" checkpoint_json="$2" openacts_json="$3"
  jq -cn --argjson cursor "$cursor_json" --argjson checkpoint "$checkpoint_json" --argjson openActs "$openacts_json" '
    ($checkpoint.criteria // []) as $criteria
    | [ $criteria[] | {
        scenarioId: (if (.persona // "") == "" then "__shared__" else .persona end),
        criterionId: .criterion_id
      } ] as $skip
    | { run_id: $cursor.run_id, phase: $cursor.phase, cursor: $cursor.cursor, openActs: $openActs, skip: $skip }
  ' || die "qa-resume.sh: jq failed to build the resume briefing."
}

build_briefing_py() {
  local cursor_json="$1" checkpoint_json="$2" openacts_json="$3"
  python3 -c '
import json, sys

cursor = json.loads(sys.argv[1])
checkpoint = json.loads(sys.argv[2])
open_acts = json.loads(sys.argv[3])

skip = []
for c in (checkpoint.get("criteria") or []):
    persona = c.get("persona") or ""
    scenario_id = "__shared__" if persona == "" else persona
    skip.append({"scenarioId": scenario_id, "criterionId": c.get("criterion_id")})

out = {
    "run_id": cursor.get("run_id"),
    "phase": cursor.get("phase"),
    "cursor": cursor.get("cursor"),
    "openActs": open_acts,
    "skip": skip,
}
print(json.dumps(out))
' "$cursor_json" "$checkpoint_json" "$openacts_json" \
    || die "qa-resume.sh: python3 failed to build the resume briefing."
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  local run_id
  run_id="$(resolve_run_id "${1:-}")"
  validate_token "$run_id" "run-id"

  local journal_file; journal_file="$(journal_file_for "$run_id")"
  [[ -f "$journal_file" ]] \
    || die "qa-resume.sh: no journal found for run '${run_id}' (${journal_file}) — nothing to resume."

  QA_ENGINE="$ENGINE" bash "$FOLD_SH" "$run_id" >/dev/null \
    || die "qa-resume.sh: fold.sh failed for run '${run_id}'."

  local cursor_file checkpoint_file
  cursor_file="$(cursor_file_for "$run_id")"
  checkpoint_file="$(checkpoint_file_for "$run_id")"
  [[ -f "$cursor_file" ]] || die "qa-resume.sh: no cursor.json for run '${run_id}' after fold — this should not happen."
  [[ -f "$checkpoint_file" ]] || die "qa-resume.sh: no checkpoint.json for run '${run_id}' after fold — this should not happen."

  local cursor_json checkpoint_json
  cursor_json="$(cat "$cursor_file")" || die "qa-resume.sh: failed to read ${cursor_file}."
  checkpoint_json="$(cat "$checkpoint_file")" || die "qa-resume.sh: failed to read ${checkpoint_file}."

  local openacts_json
  openacts_json="$(QA_ENGINE="$ENGINE" bash "$RECONCILE_SH" plan "$run_id")" \
    || die "qa-resume.sh: qa-reconcile.sh plan failed for run '${run_id}'."

  if has_jq; then
    build_briefing_jq "$cursor_json" "$checkpoint_json" "$openacts_json"
  elif has_py; then
    build_briefing_py "$cursor_json" "$checkpoint_json" "$openacts_json"
  else
    die "qa-resume.sh needs either 'jq' or 'python3' to build the resume briefing."
  fi
}

main "$@"
