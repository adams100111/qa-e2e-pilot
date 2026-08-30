#!/usr/bin/env bash
# record-evidence.sh — write a structured, content-checkable evidence artifact
# for one criterion of a qa-e2e-pilot Run, so checkpoint.sh's evidence gate can
# be CONTENT-aware (not filename-theater).
#
# USAGE:
#   record-evidence.sh <run-id> <criterion-id> bake     --read-back <json-or-text> --multiplicity <0|1|N>
#   record-evidence.sh <run-id> <criterion-id> computed --oracle <val> --observed <val> --match <true|false>
#   record-evidence.sh <run-id> <criterion-id> probe    --status <code> --shape <json-or-text>
#
# kind -> artifact (written under .qa/runs/<run-id>/evidence/<criterion-id>/):
#   bake     -> bake-read-back.json   { readBack, multiplicity, ... }
#   computed -> recompute.json        { oracle, observed, match, ... }
#   probe    -> network-response.json { status, shape, ... }
#
# On success, prints ONE line to stdout: the artifact path RELATIVE TO THE RUN
# DIR (e.g. "evidence/C1/bake-read-back.json") — the exact shape checkpointing-
# qa-memory's `evidence_refs` expects, so the caller can pipe it straight in:
#   checkpoint.sh ... --evidence-refs "$(record-evidence.sh ... )"
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

run_dir() {
  local run_id="$1"
  echo "${QA_BASE}/${run_id}"
}

evidence_dir() {
  local run_id="$1" crit_id="$2"
  echo "$(run_dir "$run_id")/evidence/${crit_id}"
}

ensure_evidence_dir() {
  local run_id="$1" crit_id="$2"
  mkdir -p "$(evidence_dir "$run_id" "$crit_id")"
}

# artifact filename for a given kind
artifact_for_kind() {
  case "$1" in
    bake)     echo "bake-read-back.json" ;;
    computed) echo "recompute.json" ;;
    probe)    echo "network-response.json" ;;
    *)        die "Unknown kind '$1'. Must be one of: bake | computed | probe" ;;
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
  local file="$1" run_id="$2" crit_id="$3" status="$4" shape="$5"
  python3 - "$file" "$run_id" "$crit_id" "$status" "$shape" "$(ts)" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, status, shape, now = sys.argv[1:7]
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
}
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ---------------------------------------------------------------------------
# per-kind dispatch
# ---------------------------------------------------------------------------

cmd_bake() {
  local run_id="$1" crit_id="$2"
  shift 2
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

  ensure_evidence_dir "$run_id" "$crit_id"
  local file
  file="$(evidence_dir "$run_id" "$crit_id")/bake-read-back.json"

  if has_jq; then
    write_jq_bake "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity"
  elif has_py; then
    write_py_bake "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "evidence/${crit_id}/bake-read-back.json"
}

cmd_computed() {
  local run_id="$1" crit_id="$2"
  shift 2
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

  ensure_evidence_dir "$run_id" "$crit_id"
  local file
  file="$(evidence_dir "$run_id" "$crit_id")/recompute.json"

  if has_jq; then
    write_jq "$file" "$run_id" "$crit_id" "computed" oracle "$oracle" observed "$observed" match "$match"
  elif has_py; then
    write_py_computed "$file" "$run_id" "$crit_id" "$oracle" "$observed" "$match"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "evidence/${crit_id}/recompute.json"
}

cmd_probe() {
  local run_id="$1" crit_id="$2"
  shift 2
  local status="" shape="" have_status=0 have_shape=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) status="$2"; have_status=1; shift 2 ;;
      --shape)  shape="$2";  have_shape=1;  shift 2 ;;
      *) die "Unknown option for kind 'probe': $1" ;;
    esac
  done
  [[ "$have_status" -eq 1 ]] || die "kind 'probe' requires --status <code>"
  [[ "$have_shape" -eq 1 ]]  || die "kind 'probe' requires --shape <json-or-text>"

  ensure_evidence_dir "$run_id" "$crit_id"
  local file
  file="$(evidence_dir "$run_id" "$crit_id")/network-response.json"

  if has_jq; then
    write_jq "$file" "$run_id" "$crit_id" "probe" status "$status" shape "$shape"
  elif has_py; then
    write_py_probe "$file" "$run_id" "$crit_id" "$status" "$shape"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "evidence/${crit_id}/network-response.json"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -ge 3 ]] || die "Usage: record-evidence.sh <run-id> <criterion-id> <kind> [--key val ...]\n       kind: bake | computed | probe"

  local run_id="$1" crit_id="$2" kind="$3"
  shift 3

  # Validate kind up front (also used to name the artifact for error text).
  artifact_for_kind "$kind" >/dev/null

  case "$kind" in
    bake)     cmd_bake "$run_id" "$crit_id" "$@" ;;
    computed) cmd_computed "$run_id" "$crit_id" "$@" ;;
    probe)    cmd_probe "$run_id" "$crit_id" "$@" ;;
  esac
}

main "$@"
