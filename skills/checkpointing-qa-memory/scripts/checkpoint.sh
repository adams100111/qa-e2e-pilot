#!/usr/bin/env bash
# checkpoint.sh — manage per-criterion checkpoint records for a qa-e2e-pilot Run.
#
# USAGE:
#   checkpoint.sh <run-id> <criterion-id> <verdict>
#       Upsert a checkpoint entry for one criterion.
#       verdict: pass | fail | blocked | deferred | error
#
#   checkpoint.sh --resume <run-id>
#       Print the last completed criterion + verdict for resume.
#       Exit 0 if at least one checkpoint exists; exit 1 if none (fresh run).
#
#   checkpoint.sh --list <run-id>
#       Print all checkpointed criteria and their verdicts (tsv: id verdict confidence).
#
# OPTIONS (upsert mode only):
#   --confidence <high|low>     Default: high
#   --phase <phase-label>       Default: verify
#   --last-action <text>        One-line description of the final action taken
#   --evidence-refs <a,b,c>     Comma-separated relative paths under .qa/runs/<run-id>/
#   --bug-ref <bug-id>          Bug log entry id if verdict is fail|error
#
# DEPENDENCIES: bash, coreutils (date, mkdir, mv, cat), and EITHER jq OR python3
#               for safe JSON updates (jq preferred; python3 used as fallback).
#
# NOTE: All paths are relative to the current working directory (project root).

set -euo pipefail

QA_BASE=".qa/runs"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

run_dir() {
  local run_id="$1"
  echo "${QA_BASE}/${run_id}"
}

checkpoint_file() {
  local run_id="$1"
  echo "$(run_dir "$run_id")/checkpoint.json"
}

ensure_run_dir() {
  local run_id="$1"
  local dir
  dir="$(run_dir "$run_id")"
  mkdir -p "$dir"
}

# ---------------------------------------------------------------------------
# init an empty checkpoint file if absent
# ---------------------------------------------------------------------------

init_checkpoint() {
  local run_id="$1"
  local file
  file="$(checkpoint_file "$run_id")"
  if [[ ! -f "$file" ]]; then
    cat > "$file" <<EOF
{
  "run_id": "${run_id}",
  "updated_at": "$(ts)",
  "criteria": []
}
EOF
  fi
}

# ---------------------------------------------------------------------------
# upsert one criterion using jq (preferred)
# ---------------------------------------------------------------------------

upsert_jq() {
  local file="$1" crit_id="$2" verdict="$3" confidence="$4" phase="$5"
  local last_action="$6" evidence_refs_json="$7" bug_ref="$8"
  local now
  now="$(ts)"

  local tmp
  tmp="${file}.tmp.$$"

  jq --arg cid "$crit_id" \
     --arg verdict "$verdict" \
     --arg confidence "$confidence" \
     --arg phase "$phase" \
     --arg last_action "$last_action" \
     --argjson evidence_refs "$evidence_refs_json" \
     --arg bug_ref "$bug_ref" \
     --arg now "$now" \
  '
    .updated_at = $now |
    if any(.criteria[]; .criterion_id == $cid) then
      .criteria = [
        .criteria[] |
        if .criterion_id == $cid then
          .verdict        = $verdict        |
          .confidence     = $confidence     |
          .phase          = $phase          |
          .last_action    = $last_action    |
          .evidence_refs  = $evidence_refs  |
          .bug_ref        = (if $bug_ref == "" then null else $bug_ref end) |
          .checkpointed_at = $now
        else . end
      ]
    else
      .criteria += [{
        "criterion_id":   $cid,
        "verdict":        $verdict,
        "confidence":     $confidence,
        "phase":          $phase,
        "last_action":    $last_action,
        "evidence_refs":  $evidence_refs,
        "bug_ref":        (if $bug_ref == "" then null else $bug_ref end),
        "checkpointed_at": $now
      }]
    end
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# upsert one criterion using python3 (fallback, no jq — robust JSON handling)
# ---------------------------------------------------------------------------

upsert_py() {
  local file="$1" crit_id="$2" verdict="$3" confidence="$4" phase="$5"
  local last_action="$6" evidence_refs_json="$7" bug_ref="$8"
  local now
  now="$(ts)"

  python3 - "$file" "$crit_id" "$verdict" "$confidence" "$phase" \
            "$last_action" "$evidence_refs_json" "$bug_ref" "$now" <<'PYEOF'
import json, sys
(file_path, cid, verdict, confidence, phase,
 last_action, evidence_refs_json, bug_ref, now) = sys.argv[1:10]
try:
    evidence_refs = json.loads(evidence_refs_json) if evidence_refs_json else []
except json.JSONDecodeError:
    evidence_refs = []
with open(file_path) as f:
    data = json.load(f)
entry = {
    "criterion_id":    cid,
    "verdict":         verdict,
    "confidence":      confidence,
    "phase":           phase,
    "last_action":     last_action,
    "evidence_refs":   evidence_refs,
    "bug_ref":         bug_ref or None,
    "checkpointed_at": now,
}
data["updated_at"] = now
criteria = data.setdefault("criteria", [])
for i, c in enumerate(criteria):
    if c.get("criterion_id") == cid:
        criteria[i] = entry
        break
else:
    criteria.append(entry)
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ---------------------------------------------------------------------------
# --resume: print last completed criterion
# ---------------------------------------------------------------------------

cmd_resume() {
  local run_id="$1"
  local file
  file="$(checkpoint_file "$run_id")"
  [[ -f "$file" ]] || { echo "No checkpoint file found for run: ${run_id}" >&2; exit 1; }

  if has_jq; then
    local count
    count=$(jq '.criteria | length' "$file")
    if [[ "$count" -eq 0 ]]; then
      echo "RESUME: no criteria checkpointed yet — start from the beginning."
      exit 1
    fi
    jq -r '
      .criteria |
      last |
      "RESUME cursor:\n  criterion_id:  \(.criterion_id)\n  verdict:       \(.verdict)\n  confidence:    \(.confidence)\n  phase:         \(.phase)\n  last_action:   \(.last_action)\n  checkpointed:  \(.checkpointed_at)"
    ' "$file"
    echo ""
    echo "Skip all criteria up to and including: $(jq -r '.criteria | last | .criterion_id' "$file")"
  elif has_py; then
    python3 - "$file" <<'PYEOF' || exit 1
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
criteria = data.get("criteria", [])
if not criteria:
    print("RESUME: no criteria checkpointed yet — start from the beginning.")
    sys.exit(1)
c = criteria[-1]
print("RESUME cursor:")
for k in ("criterion_id", "verdict", "confidence", "phase", "last_action", "checkpointed_at"):
    print(f"  {k}: {c.get(k)}")
print()
print(f"Skip all criteria up to and including: {c.get('criterion_id')}")
PYEOF
  else
    die "checkpoint.sh --resume needs either 'jq' or 'python3'."
  fi
}

# ---------------------------------------------------------------------------
# --list: print all checkpointed criteria
# ---------------------------------------------------------------------------

cmd_list() {
  local run_id="$1"
  local file
  file="$(checkpoint_file "$run_id")"
  [[ -f "$file" ]] || { echo "No checkpoint file found for run: ${run_id}" >&2; exit 1; }

  if has_jq; then
    echo "criterion_id	verdict	confidence	checkpointed_at"
    jq -r '.criteria[] | [.criterion_id, .verdict, .confidence, .checkpointed_at] | @tsv' "$file"
  elif has_py; then
    python3 - "$file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print("criterion_id\tverdict\tconfidence\tcheckpointed_at")
for c in data.get("criteria", []):
    print("\t".join(str(c.get(k, "")) for k in ("criterion_id", "verdict", "confidence", "checkpointed_at")))
PYEOF
  else
    die "checkpoint.sh --list needs either 'jq' or 'python3'."
  fi
}

# ---------------------------------------------------------------------------
# upsert mode
# ---------------------------------------------------------------------------

cmd_upsert() {
  local run_id="$1" crit_id="$2" verdict="$3"
  shift 3

  local confidence="high"
  local phase="verify"
  local last_action=""
  local evidence_refs="[]"
  local bug_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confidence)   confidence="$2";    shift 2 ;;
      --phase)        phase="$2";         shift 2 ;;
      --last-action)  last_action="$2";   shift 2 ;;
      --evidence-refs)
        # Accept comma-separated paths or JSON array
        if [[ "$2" == \[* ]]; then
          evidence_refs="$2"
        else
          evidence_refs="[$(echo "$2" | awk -F',' '{for(i=1;i<=NF;i++) printf "\"%s\"%s",$i,(i<NF?",":"")}')]"
        fi
        shift 2 ;;
      --bug-ref)      bug_ref="$2";       shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # Validate verdict
  case "$verdict" in
    pass|fail|blocked|deferred|error) ;;
    *) die "Invalid verdict '${verdict}'. Must be: pass | fail | blocked | deferred | error" ;;
  esac

  # Validate confidence
  case "$confidence" in
    high|low) ;;
    *) die "Invalid confidence '${confidence}'. Must be: high | low" ;;
  esac

  ensure_run_dir "$run_id"
  init_checkpoint "$run_id"

  local file
  file="$(checkpoint_file "$run_id")"

  if has_jq; then
    upsert_jq "$file" "$crit_id" "$verdict" "$confidence" "$phase" \
              "$last_action" "$evidence_refs" "$bug_ref"
  elif has_py; then
    upsert_py "$file" "$crit_id" "$verdict" "$confidence" "$phase" \
              "$last_action" "$evidence_refs" "$bug_ref"
  else
    die "checkpoint.sh needs either 'jq' or 'python3' to update JSON safely; neither was found on PATH."
  fi

  echo "Checkpointed: run=${run_id} criterion=${crit_id} verdict=${verdict} confidence=${confidence}"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: checkpoint.sh <run-id> <criterion-id> <verdict> [options]\n       checkpoint.sh --resume <run-id>\n       checkpoint.sh --list <run-id>"

  case "$1" in
    --resume)
      [[ $# -lt 2 ]] && die "--resume requires <run-id>"
      cmd_resume "$2"
      ;;
    --list)
      [[ $# -lt 2 ]] && die "--list requires <run-id>"
      cmd_list "$2"
      ;;
    -*)
      die "Unknown flag: $1"
      ;;
    *)
      [[ $# -lt 3 ]] && die "Upsert mode requires: <run-id> <criterion-id> <verdict>"
      cmd_upsert "$@"
      ;;
  esac
}

main "$@"
