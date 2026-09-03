#!/usr/bin/env bash
# ux-conventions.sh — read/append helper for .qa/ux-conventions.json's
# knownDeliberate list, feeding adjudicate.js's
# `adjudicate(..., {knownDeliberate})` (skills/detecting-visual-ux/scripts/
# adjudicate.js). Mirrors the header idioms (die/has_jq/has_py/QA_ENGINE,
# atomic temp-then-rename write) used by
# skills/checkpointing-qa-memory/scripts/journal.sh and journal-emit.sh.
#
# USAGE:
#   ux-conventions.sh read [<path>]
#       Prints the `knownDeliberate` JSON array to stdout — `[]` when
#       <path> is missing OR has no such key. Default <path> is
#       `.qa/ux-conventions.json` (relative to the current working
#       directory, same convention as journal.sh/checkpoint.sh).
#
#   ux-conventions.sh add <detector> <rawSignal> [<path>]
#       Appends {"detector":<detector>,"rawSignal":<rawSignal>} to
#       `knownDeliberate`, IDEMPOTENTLY — deduped by the key
#       `<detector>` + U+241F (␟, SYMBOL FOR UNIT SEPARATOR) + `<rawSignal>`,
#       the exact same key adjudicate.js's deliberateKey() computes, so an
#       entry written here is recognized by adjudicate() on the next run.
#       Creates <path> (and its parent directory) as
#       {"knownDeliberate":[...],"conventions":[]} if absent. An existing
#       `conventions` value is preserved untouched. Prints a one-line
#       confirmation to stdout.
#
# DEPENDENCIES: bash, coreutils (mkdir, mv, cat), and EITHER jq OR python3
#               for safe JSON handling (jq preferred; python3 fallback).
#               No node, no perl, no grep -P. Honors QA_ENGINE the same way
#               journal.sh/checkpoint.sh/journal-emit.sh do.

set -uo pipefail

DEFAULT_PATH=".qa/ux-conventions.json"

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE (unset by default): python3 forces the python3 branch even if
# jq is on PATH; jq forces the jq branch; unset/anything else = auto-detect
# (jq if present, else python3) — same contract as journal.sh's has_jq.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

has_py() { command -v python3 >/dev/null 2>&1; }

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
# cmd_read [<path>]
# ---------------------------------------------------------------------------
cmd_read() {
  local path="${1:-$DEFAULT_PATH}"

  if [[ ! -s "$path" ]]; then
    echo "[]"
    return 0
  fi

  if has_jq; then
    jq -c '.knownDeliberate // []' "$path" 2>/dev/null \
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
print(json.dumps(d.get("knownDeliberate") or [], separators=(",", ":")))
' "$path" || die "read: '${path}' is not valid JSON."
  else
    die "ux-conventions.sh needs either 'jq' or 'python3' to read '${path}'."
  fi
}

# ---------------------------------------------------------------------------
# cmd_add <detector> <rawSignal> [<path>]
# ---------------------------------------------------------------------------
cmd_add() {
  [[ $# -ge 2 ]] || die "add requires: <detector> <rawSignal> [<path>]"
  local detector="$1" raw_signal="$2" path="${3:-$DEFAULT_PATH}"
  [[ -n "$detector" ]] || die "add: <detector> must not be empty."

  local new_json
  if has_jq; then
    new_json="$(jq -cn \
      --arg detector "$detector" \
      --arg rawSignal "$raw_signal" \
      --slurpfile existing <(if [[ -s "$path" ]]; then cat "$path"; else echo '{}'; fi) \
      '
      ($existing[0] // {}) as $doc
      | ($doc.knownDeliberate // []) as $known
      | ($doc.conventions // []) as $conventions
      | ($detector + "␟" + $rawSignal) as $newKey
      | ([$known[] | (.detector // "") + "␟" + (.rawSignal // "")]) as $keys
      | if ($keys | index($newKey)) != null
        then $doc + {knownDeliberate: $known, conventions: $conventions}
        else $doc + {knownDeliberate: ($known + [{detector: $detector, rawSignal: $rawSignal}]), conventions: $conventions}
        end
      ')" || die "add: failed to build the updated JSON via jq (is '${path}' valid JSON?)."
  elif has_py; then
    new_json="$(python3 -c '
import json, sys

detector, raw_signal, path = sys.argv[1], sys.argv[2], sys.argv[3]

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

known = doc.get("knownDeliberate") or []
conventions = doc.get("conventions") or []

SEP = "␟"


def key(entry):
    return str(entry.get("detector", "")) + SEP + str(entry.get("rawSignal", "") if entry.get("rawSignal") is not None else "")


new_key = detector + SEP + (raw_signal if raw_signal is not None else "")
existing_keys = {key(e) for e in known}

if new_key not in existing_keys:
    known = known + [{"detector": detector, "rawSignal": raw_signal}]

doc["knownDeliberate"] = known
doc["conventions"] = conventions

print(json.dumps(doc, separators=(",", ":")))
' "$detector" "$raw_signal" "$path")" || die "add: failed to build the updated JSON via python3 (is '${path}' valid JSON?)."
  else
    die "ux-conventions.sh needs either 'jq' or 'python3' to add an entry to '${path}'."
  fi

  atomic_write_file "$path" "$new_json"
  echo "ux-conventions: added detector='${detector}' rawSignal='${raw_signal}' -> ${path}"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: ux-conventions.sh read [<path>]\n       ux-conventions.sh add <detector> <rawSignal> [<path>]"
  local cmd="$1"; shift
  case "$cmd" in
    read) cmd_read "$@" ;;
    add)  cmd_add "$@" ;;
    *) die "Unknown subcommand '${cmd}' (expected: read|add)." ;;
  esac
}

main "$@"
