#!/usr/bin/env bash
# record-evidence.sh — write a structured, content-checkable evidence artifact
# for one criterion of a qa-e2e-pilot Run, so checkpoint.sh's evidence gate can
# be CONTENT-aware (not filename-theater).
#
# USAGE:
#   record-evidence.sh <run-id> <criterion-id> bake     [--persona <id>] --read-back <json-or-text> --multiplicity <0|1|N>
#   record-evidence.sh <run-id> <criterion-id> computed [--persona <id>] --oracle <val> --observed <val> --match <true|false>
#   record-evidence.sh <run-id> <criterion-id> probe    [--persona <id>] --status <code> --shape <json-or-text> --ok <true|false>
#   record-evidence.sh <run-id> <criterion-id> action-trace [--persona <id>] --steps <json-array> [--session-log <session.md> --session-from <N> | --session-calls <json-array>] [--action <desc>]
#     --session-log + --session-from  DERIVE sessionCalls from the REAL session.md
#       (independent ground truth) by running parse-session-log.js and slicing from
#       N. This OVERRIDES --session-calls and is the tamper-evident path; prefer it.
#
# kind -> artifact:
#   bake     -> bake-read-back.json   { readBack, multiplicity, ... }
#   computed -> recompute.json        { oracle, observed, match, ... }
#   probe    -> network-response.json { status, shape, ok, ... }
#   action-trace -> action-trace.json { actionUnderTest, steps, sessionCalls }
#
# `--ok` on kind 'probe' is the agent's own judgment that the probe CONFIRMED
# its expectation — it is NOT a raw status-code check. A cross-role ABSENCE
# probe that correctly gets 403/404 sets --ok true; checkpoint.sh's evidence
# gate requires `.ok == true` on a `pass`, deliberately never inspecting the
# raw status/range itself (that would reject legitimate 403/404 absence
# probes).
#
# Written under .qa/runs/<run-id>/evidence/<criterion-id>/ by default. When
# --persona <id> is given, written under
# .qa/runs/<run-id>/evidence/<persona>/<criterion-id>/ instead, so two
# personas' bakes for the same criterion never collide. Omitting --persona is
# back-compat: the no-persona path is byte-identical to today's.
#
# On success, prints ONE line to stdout: the artifact path RELATIVE TO THE RUN
# DIR (e.g. "evidence/C1/bake-read-back.json", or with --persona admin:
# "evidence/admin/C1/bake-read-back.json") — the exact shape checkpointing-
# qa-memory's `evidence_refs` (and checkpoint.sh's `--persona`-aware gate)
# expect, so the caller can pipe it straight in:
#   checkpoint.sh ... --persona <id> --evidence-refs "$(record-evidence.sh ... --persona <id> ...)"
#
# DEPENDENCIES: bash, coreutils (date, mkdir), and EITHER jq OR python3 for
#               safe JSON writing (jq preferred; python3 used as fallback).
#
# SECRETS: values passed via --key are written into the run dir's evidence
#          file but are NEVER echoed to stdout/stderr — only the artifact path
#          is printed on success; error paths never echo option values either.
#
# NOTE: All paths are relative to the current working directory (project root),
#       matching checkpoint.sh's convention.

set -euo pipefail

QA_BASE=".qa/runs"

# ---------------------------------------------------------------------------
# helpers (mirrors checkpoint.sh's idiom)
# ---------------------------------------------------------------------------

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Fix 28 — reject any run-id / criterion-id / persona value that could
# escape .qa/runs/<run-id>/evidence/... when interpolated into a path (e.g.
# --persona '../../../evil'). Mirrors checkpoint.sh's validate_token exactly
# — a persona/criterion/run id must be a simple token: no '/' or '\', no
# '..' anywhere in the value, and no leading '-'. Dies with a clear message
# BEFORE the value is ever used to build a path — this must run before
# evidence_dir()/evidence_dir_rel() see the value.
# ---------------------------------------------------------------------------
validate_token() {
  local value="$1" label="$2"
  [[ -z "$value" ]] && die "${label} must not be empty."
  case "$value" in
    */*|*\\*) die "${label} '${value}' contains a path separator ('/' or '\\') — must be a simple token." ;;
  esac
  case "$value" in
    *..*) die "${label} '${value}' contains '..' — must be a simple token." ;;
  esac
  # Fix 2728: a bare '.' (or an all-dots value not already caught by the
  # '..'-substring check above, e.g. a hypothetical future single-dot
  # variant) normalizes away when interpolated into a path — 'evidence/./
  # <crit>/...' collapses to 'evidence/<crit>/...' (the NO-persona path),
  # and '.qa/runs/.' collapses to '.qa/runs/' — silently escaping the
  # per-identity/per-run directory this token is supposed to scope. Reject
  # it here, before any path is built from it.
  if [[ "$value" =~ ^\.+$ ]]; then
    die "${label} '${value}' is '.' or consists only of dots — must be a simple token."
  fi
  case "$value" in
    -*) die "${label} '${value}' starts with '-' — must be a simple token." ;;
  esac
  return 0
}

run_dir() {
  local run_id="$1"
  echo "${QA_BASE}/${run_id}"
}

# $3 (persona) is OPTIONAL. Empty/omitted -> today's path, byte-identical:
#   evidence/<crit_id>
# Non-empty -> persona-scoped path (mirrors checkpoint.sh's gate lookup):
#   evidence/<persona>/<crit_id>
evidence_dir() {
  local run_id="$1" crit_id="$2" persona="${3:-}"
  if [[ -n "$persona" ]]; then
    echo "$(run_dir "$run_id")/evidence/${persona}/${crit_id}"
  else
    echo "$(run_dir "$run_id")/evidence/${crit_id}"
  fi
}

# relative-to-run-dir counterpart of evidence_dir(), used to build the
# stdout path and mirrors checkpoint.sh gate_pass's rel_path construction.
evidence_dir_rel() {
  local crit_id="$1" persona="${2:-}"
  if [[ -n "$persona" ]]; then
    echo "evidence/${persona}/${crit_id}"
  else
    echo "evidence/${crit_id}"
  fi
}

ensure_evidence_dir() {
  local run_id="$1" crit_id="$2" persona="${3:-}"
  mkdir -p "$(evidence_dir "$run_id" "$crit_id" "$persona")"
}

# artifact filename for a given kind
artifact_for_kind() {
  case "$1" in
    bake)     echo "bake-read-back.json" ;;
    computed) echo "recompute.json" ;;
    probe)    echo "network-response.json" ;;
    action-trace) echo "action-trace.json" ;;
    *)        die "Unknown kind '$1'. Must be one of: bake | computed | probe | action-trace" ;;
  esac
}

# ---------------------------------------------------------------------------
# write artifact using jq (preferred) — each value is stored as parsed JSON
# when it looks like JSON, otherwise as a raw string. Values are passed via
# --arg (never interpolated into the filter), so nothing is echoed or shelled.
# ---------------------------------------------------------------------------

write_jq() {
  local file="$1" run_id="$2" crit_id="$3" kind="$4"
  shift 4
  # remaining args: field_name value field_name value ...
  local jq_args=()
  local filter_fields=""
  while [[ $# -gt 0 ]]; do
    local field="$1" value="$2"
    shift 2
    jq_args+=(--arg "raw_${field}" "$value")
    if [[ -n "$filter_fields" ]]; then filter_fields+=", "; fi
    filter_fields+="${field}: (\$raw_${field} | try fromjson catch \$raw_${field})"
  done

  jq -n \
     --arg criterion_id "$crit_id" \
     --arg run_id "$run_id" \
     --arg kind "$kind" \
     --arg recorded_at "$(ts)" \
     "${jq_args[@]}" \
     "{criterion_id: \$criterion_id, run_id: \$run_id, kind: \$kind, recorded_at: \$recorded_at, ${filter_fields}}" \
     > "$file"
}

# multiplicity is always stored as a plain string (it's an enum 0|1|N, not a
# value to type-infer), so it gets its own jq/python writer path.
write_jq_bake() {
  local file="$1" run_id="$2" crit_id="$3" read_back="$4" multiplicity="$5"
  jq -n \
     --arg criterion_id "$crit_id" \
     --arg run_id "$run_id" \
     --arg kind "bake" \
     --arg recorded_at "$(ts)" \
     --arg read_back_raw "$read_back" \
     --arg multiplicity "$multiplicity" \
     '{criterion_id: $criterion_id, run_id: $run_id, kind: $kind, recorded_at: $recorded_at,
       readBack: ($read_back_raw | try fromjson catch $read_back_raw),
       multiplicity: $multiplicity}' \
     > "$file"
}

# ---------------------------------------------------------------------------
# write artifact using python3 (fallback, no jq)
# ---------------------------------------------------------------------------

write_py_bake() {
  local file="$1" run_id="$2" crit_id="$3" read_back="$4" multiplicity="$5"
  python3 - "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity" "$(ts)" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, read_back, multiplicity, now = sys.argv[1:7]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "bake",
    "recorded_at": now,
    "readBack": smart(read_back),
    "multiplicity": multiplicity,
}
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

write_py_computed() {
  local file="$1" run_id="$2" crit_id="$3" oracle="$4" observed="$5" match="$6"
  python3 - "$file" "$run_id" "$crit_id" "$oracle" "$observed" "$match" "$(ts)" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, oracle, observed, match, now = sys.argv[1:8]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "computed",
    "recorded_at": now,
    "oracle": smart(oracle),
    "observed": smart(observed),
    "match": smart(match),
}
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

write_py_probe() {
  local file="$1" run_id="$2" crit_id="$3" status="$4" shape="$5" ok="$6"
  python3 - "$file" "$run_id" "$crit_id" "$status" "$shape" "$ok" "$(ts)" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, status, shape, ok, now = sys.argv[1:8]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "probe",
    "recorded_at": now,
    "status": smart(status),
    "shape": smart(shape),
    "ok": smart(ok),
}
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# action-trace stores steps/sessionCalls as parsed JSON arrays and
# actionUnderTest as a plain string — mirrors write_py_bake/_computed/_probe's
# smart() dance so the python3 fallback path produces JSON byte-identical (up
# to key order, which json.dump preserves the same as the jq writer's field
# order) to the jq path (Fix #27 parity discipline).
write_py_action_trace() {
  local file="$1" run_id="$2" crit_id="$3" action="$4" steps="$5" session_calls="$6" fingerprints="${7:-}"
  python3 - "$file" "$run_id" "$crit_id" "$action" "$steps" "$session_calls" "$(ts)" "$fingerprints" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, action, steps, session_calls, now, fingerprints = sys.argv[1:9]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "action-trace",
    "recorded_at": now,
    "actionUnderTest": smart(action),
    "steps": smart(steps),
    "sessionCalls": smart(session_calls),
}
if fingerprints:
    data["fingerprints"] = smart(fingerprints)
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ---------------------------------------------------------------------------
# per-kind dispatch
# ---------------------------------------------------------------------------

cmd_bake() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local read_back="" multiplicity="" have_read_back=0 have_multiplicity=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --read-back)    read_back="$2";    have_read_back=1;    shift 2 ;;
      --multiplicity) multiplicity="$2"; have_multiplicity=1; shift 2 ;;
      *) die "Unknown option for kind 'bake': $1" ;;
    esac
  done
  [[ "$have_read_back" -eq 1 ]]    || die "kind 'bake' requires --read-back <json-or-text>"
  [[ "$have_multiplicity" -eq 1 ]] || die "kind 'bake' requires --multiplicity <0|1|N>"

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/bake-read-back.json"

  if has_jq; then
    write_jq_bake "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity"
  elif has_py; then
    write_py_bake "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/bake-read-back.json"
}

cmd_computed() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local oracle="" observed="" match=""
  local have_oracle=0 have_observed=0 have_match=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --oracle)   oracle="$2";   have_oracle=1;   shift 2 ;;
      --observed) observed="$2"; have_observed=1; shift 2 ;;
      --match)    match="$2";    have_match=1;    shift 2 ;;
      *) die "Unknown option for kind 'computed': $1" ;;
    esac
  done
  [[ "$have_oracle" -eq 1 ]]   || die "kind 'computed' requires --oracle <val>"
  [[ "$have_observed" -eq 1 ]] || die "kind 'computed' requires --observed <val>"
  [[ "$have_match" -eq 1 ]]    || die "kind 'computed' requires --match <true|false>"

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/recompute.json"

  if has_jq; then
    write_jq "$file" "$run_id" "$crit_id" "computed" oracle "$oracle" observed "$observed" match "$match"
  elif has_py; then
    write_py_computed "$file" "$run_id" "$crit_id" "$oracle" "$observed" "$match"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/recompute.json"
}

cmd_probe() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local status="" shape="" ok="" have_status=0 have_shape=0 have_ok=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) status="$2"; have_status=1; shift 2 ;;
      --shape)  shape="$2";  have_shape=1;  shift 2 ;;
      --ok)     ok="$2";     have_ok=1;     shift 2 ;;
      *) die "Unknown option for kind 'probe': $1" ;;
    esac
  done
  [[ "$have_status" -eq 1 ]] || die "kind 'probe' requires --status <code>"
  [[ "$have_shape" -eq 1 ]]  || die "kind 'probe' requires --shape <json-or-text>"
  [[ "$have_ok" -eq 1 ]]     || die "kind 'probe' requires --ok <true|false> — your judgment that the probe CONFIRMED its expectation (e.g. an absence probe expecting 403/404 passes --ok true when it gets 403/404; do not infer this from the raw status code alone)"

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/network-response.json"

  if has_jq; then
    write_jq "$file" "$run_id" "$crit_id" "probe" status "$status" shape "$shape" ok "$ok"
  elif has_py; then
    write_py_probe "$file" "$run_id" "$crit_id" "$status" "$shape" "$ok"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/network-response.json"
}

cmd_action_trace() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local steps="" session_calls="[]" action="" have_steps=0
  local session_log="" session_from="0"
  local fp_before="" fp_after="" have_fp=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --steps)              steps="$2";         have_steps=1; shift 2 ;;
      --session-calls)      session_calls="$2"; shift 2 ;;
      --session-log)        session_log="$2";   shift 2 ;;
      --session-from)       session_from="$2";  shift 2 ;;
      --fingerprint-before) fp_before="$2";     have_fp=1; shift 2 ;;
      --fingerprint-after)  fp_after="$2";      have_fp=1; shift 2 ;;
      --action)             action="$2";        shift 2 ;;
      *) die "Unknown option for kind 'action-trace': $1" ;;
    esac
  done
  [[ "$have_steps" -eq 1 ]] || die "kind 'action-trace' requires --steps <json-array>"

  # Optional before/after persisted-state fingerprints for Check 3 (the
  # tool-agnostic net that catches arbitrary non-UI mutators). Built into a
  # {before, after} object stored as `fingerprints`. Values are stored as parsed
  # JSON when they look like JSON, else as raw strings (same idiom as the rest).
  local fingerprints=""
  if [[ "$have_fp" -eq 1 ]]; then
    if has_jq; then
      fingerprints="$(jq -cn --arg b "$fp_before" --arg a "$fp_after" \
        '{before: ($b | try fromjson catch $b), after: ($a | try fromjson catch $a)}')"
    else
      fingerprints="$(FP_B="$fp_before" FP_A="$fp_after" python3 -c "import json,os
def smart(v):
    try: return json.loads(v)
    except Exception: return v
print(json.dumps({'before': smart(os.environ['FP_B']), 'after': smart(os.environ['FP_A'])}))")"
    fi
  fi

  # TAMPER-EVIDENCE: when --session-log is given, DERIVE sessionCalls by running
  # parse-session-log.js on the REAL server-written session.md and slicing from
  # --session-from N (the per-criterion delta boundary the driver recorded). This
  # is the independent ground truth — it overrides any agent-supplied
  # --session-calls, so an agent cannot pass by simply omitting a mutating call
  # from a hand-written JSON array (final-review finding #2).
  if [[ -n "$session_log" ]]; then
    [[ -f "$session_log" ]] || die "--session-log file not found: $session_log"
    [[ "$session_from" =~ ^[0-9]+$ ]] || die "--session-from must be a non-negative integer"
    local parse_js all
    parse_js="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../driving-browser-qa/scripts" && pwd)/parse-session-log.js"
    [[ -f "$parse_js" ]] || die "parse-session-log.js not found at $parse_js"
    all="$(node "$parse_js" "$session_log")" || die "parse-session-log.js failed on $session_log"
    # N1: bound --session-from against the ACTUAL parsed length. An agent-supplied
    # N past the end would silently yield an empty slice, neutralizing the whole
    # tamper-evidence (a concealed call would never be derived). Refuse it.
    local total
    if has_jq; then total="$(printf '%s' "$all" | jq 'length')"; else total="$(printf '%s' "$all" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")"; fi
    [[ "$session_from" -le "$total" ]] || die "--session-from ($session_from) exceeds the session.md call count ($total) — refusing to derive an empty (tamper-hiding) slice"
    if has_jq; then
      session_calls="$(printf '%s' "$all" | jq -c ".[${session_from}:]")" || die "failed to slice session calls from $session_from"
    else
      session_calls="$(printf '%s' "$all" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)[${session_from}:]))")" || die "failed to slice session calls from $session_from"
    fi
  fi

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/action-trace.json"

  if has_jq; then
    if [[ -n "$fingerprints" ]]; then
      write_jq "$file" "$run_id" "$crit_id" "action-trace" actionUnderTest "$action" steps "$steps" sessionCalls "$session_calls" fingerprints "$fingerprints"
    else
      write_jq "$file" "$run_id" "$crit_id" "action-trace" actionUnderTest "$action" steps "$steps" sessionCalls "$session_calls"
    fi
  elif has_py; then
    write_py_action_trace "$file" "$run_id" "$crit_id" "$action" "$steps" "$session_calls" "$fingerprints"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/action-trace.json"
}

# Scan the remaining args ($@, after run-id/criterion-id/kind) for an
# optional `--persona <id>` pair anywhere in the list, removing it and
# leaving the rest untouched (order-preserving) for the per-kind parsers.
# Sets globals PERSONA and STRIPPED_ARGS (an array) — a plain "return via
# echo" can't carry an array safely here, and this file has no other
# argument-stripping precedent to match, so a pair of globals scoped to this
# one call site is the simplest correct option.
PERSONA=""
STRIPPED_ARGS=()
strip_persona() {
  PERSONA=""
  STRIPPED_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --persona)
        [[ $# -ge 2 ]] || die "--persona requires <id>"
        PERSONA="$2"
        shift 2
        ;;
      *)
        STRIPPED_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -ge 3 ]] || die "Usage: record-evidence.sh <run-id> <criterion-id> <kind> [--persona <id>] [--key val ...]\n       kind: bake | computed | probe | action-trace"

  local run_id="$1" crit_id="$2" kind="$3"
  shift 3

  # Fix 28: reject a path-traversal run-id/criterion-id BEFORE it can reach
  # evidence_dir()'s path building.
  validate_token "$run_id" "run-id"
  validate_token "$crit_id" "criterion-id"

  # Validate kind up front (also used to name the artifact for error text).
  artifact_for_kind "$kind" >/dev/null

  strip_persona "$@"
  set -- "${STRIPPED_ARGS[@]}"

  # Fix 28: reject a path-traversal persona BEFORE it can reach
  # evidence_dir()'s persona-scoped path building. Empty persona
  # ("" / omitted) is fine — that's the back-compat no-persona case.
  [[ -n "$PERSONA" ]] && validate_token "$PERSONA" "--persona"

  case "$kind" in
    bake)     cmd_bake "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    computed) cmd_computed "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    probe)    cmd_probe "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    action-trace) cmd_action_trace "$run_id" "$crit_id" "$PERSONA" "$@" ;;
  esac
}

main "$@"
