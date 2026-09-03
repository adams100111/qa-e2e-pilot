#!/usr/bin/env bash
# critic-coverage.sh — the sampled-vs-skipped coverage log for the visual-UX
# critic's cost ceiling (SKILL.md Step 4.1). A capped run is NOT "the critic
# ran everywhere" — this file is the honest record of what was actually
# sampled vs. skipped, feeding the report's honest coverage section.
# Mirrors the header idioms (die/has_jq/has_py/QA_ENGINE, validate_token,
# atomic temp-then-rename write) used by
# skills/checkpointing-qa-memory/scripts/journal-emit.sh and
# skills/detecting-visual-ux/scripts/ux-conventions.sh.
#
# USAGE:
#   critic-coverage.sh log <run-id> <surface> <ran|skipped> <reason>
#       Appends {"surface":<surface>,"decision":<ran|skipped>,"reason":<reason>}
#       to `.qa/runs/<run-id>/critic-coverage.json` (relative to the current
#       working directory, or under QA_BASE if set) — creating the file as
#       {"records":[...]} if absent. <ran|skipped> must be EXACTLY "ran" or
#       "skipped" (dies, nothing appended, otherwise). Atomic write (temp
#       file in the same directory, then rename). Prints a one-line
#       confirmation to stdout.
#
#   critic-coverage.sh read <run-id>
#       Prints the `records` JSON array to stdout — `[]` when the file is
#       missing OR has no `records` key.
#
# DEPENDENCIES: bash, coreutils (mkdir, mv, cat), and EITHER jq OR python3
#               for safe JSON handling (jq preferred; python3 fallback).
#               No node, no perl, no grep -P. Honors QA_ENGINE the same way
#               journal.sh/checkpoint.sh/journal-emit.sh/ux-conventions.sh do.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE (unset by default): python3 forces the python3 branch even if
# jq is on PATH; jq forces the jq branch; unset/anything else = auto-detect
# (jq if present, else python3) — same contract as journal.sh/journal-emit.sh.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

has_py() { command -v python3 >/dev/null 2>&1; }

# validate_token (copied from journal-emit.sh's validate_token exactly): a
# run-id is interpolated into `.qa/runs/<run-id>/`, so it must not escape.
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

coverage_path_for() {
  echo "${QA_BASE}/${1}/critic-coverage.json"
}

# ---------------------------------------------------------------------------
# atomic_write_file <dest-path> <content>
#
# Writes <content> to a temp file in the SAME directory as <dest-path>, then
# renames it over <dest-path> (temp-in-same-dir + rename is POSIX-atomic on
# a single filesystem) — never a partial in-place edit. mkdir -p's the
# parent directory first.
# ---------------------------------------------------------------------------
atomic_write_file() {
  local dest="$1" content="$2"
  local dir
  dir="$(dirname -- "$dest")"
  mkdir -p -- "$dir" || die "atomic_write_file: failed to create directory '${dir}'."
  local tmp="${dest}.tmp.$$"
  printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; die "atomic_write_file: failed to write temp file '${tmp}'."; }
  mv -- "$tmp" "$dest" || { rm -f "$tmp"; die "atomic_write_file: failed to move '${tmp}' -> '${dest}' (disk full or permission error?)."; }
}

# ---------------------------------------------------------------------------
# cmd_read <run-id>
# ---------------------------------------------------------------------------
cmd_read() {
  [[ $# -eq 1 ]] || die "read requires: <run-id>"
  local run_id="$1"
  validate_token "$run_id" "run-id"
  local path; path="$(coverage_path_for "$run_id")"

  if [[ ! -s "$path" ]]; then
    echo "[]"
    return 0
  fi

  if has_jq; then
    jq -c '.records // []' "$path" 2>/dev/null \
      || die "read: '${path}' is not valid JSON."
  elif has_py; then
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
print(json.dumps(d.get("records") or [], separators=(",", ":")))
' "$path" || die "read: '${path}' is not valid JSON."
  else
    die "critic-coverage.sh needs either 'jq' or 'python3' to read '${path}'."
  fi
}

# ---------------------------------------------------------------------------
# cmd_log <run-id> <surface> <ran|skipped> <reason>
# ---------------------------------------------------------------------------
cmd_log() {
  [[ $# -eq 4 ]] || die "log requires: <run-id> <surface> <ran|skipped> <reason>"
  local run_id="$1" surface="$2" decision="$3" reason="$4"
  validate_token "$run_id" "run-id"
  [[ -n "$surface" ]] || die "log: <surface> must not be empty."
  case "$decision" in
    ran|skipped) ;;
    *) die "log: <ran|skipped> must be exactly 'ran' or 'skipped' (got '${decision}')." ;;
  esac

  local path; path="$(coverage_path_for "$run_id")"

  local new_json
  if has_jq; then
    new_json="$(jq -cn \
      --arg surface "$surface" \
      --arg decision "$decision" \
      --arg reason "$reason" \
      --slurpfile existing <(if [[ -s "$path" ]]; then cat "$path"; else echo '{}'; fi) \
      '
      ($existing[0] // {}) as $doc
      | ($doc.records // []) as $records
      | {records: ($records + [{surface: $surface, decision: $decision, reason: $reason}])}
      ')" || die "log: failed to build the updated JSON via jq (is '${path}' valid JSON?)."
  elif has_py; then
    new_json="$(python3 -c '
import json, sys

surface, decision, reason, path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

doc = {}
try:
    with open(path) as f:
        content = f.read()
    if content.strip():
        doc = json.loads(content)
        if not isinstance(doc, dict):
            sys.exit(1)
except FileNotFoundError:
    doc = {}
except json.JSONDecodeError:
    sys.exit(1)

records = doc.get("records") or []
records = records + [{"surface": surface, "decision": decision, "reason": reason}]

print(json.dumps({"records": records}, separators=(",", ":")))
' "$surface" "$decision" "$reason" "$path")" || die "log: failed to build the updated JSON via python3 (is '${path}' valid JSON?)."
  else
    die "critic-coverage.sh needs either 'jq' or 'python3' to log to '${path}'."
  fi

  atomic_write_file "$path" "$new_json"
  echo "critic-coverage: logged run=${run_id} surface='${surface}' decision=${decision} reason='${reason}' -> ${path}"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: critic-coverage.sh log <run-id> <surface> <ran|skipped> <reason>\n       critic-coverage.sh read <run-id>"
  local cmd="$1"; shift
  case "$cmd" in
    log)  cmd_log "$@" ;;
    read) cmd_read "$@" ;;
    *) die "Unknown subcommand '${cmd}' (expected: log|read)." ;;
  esac
}

main "$@"
