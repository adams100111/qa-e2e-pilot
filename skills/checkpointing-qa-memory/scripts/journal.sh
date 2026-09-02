#!/usr/bin/env bash
# journal.sh — append-only Run journal + shared atomic-write/canonical-serialize
# helpers (ADR-0017 durable substrate, Plan A Task 1).
#
# USAGE:
#   journal.sh append <run-id> <event-json>
#       Validate <event-json> is a single JSON object with a non-empty string
#       `event` field, stamp `seq` (max existing seq in the journal + 1, or 1
#       if the journal is empty/absent) and `t` (current UTC time), and
#       append exactly one compact, newline-terminated line to the journal.
#       Non-zero + message on malformed input; nothing is written.
#
#   journal.sh atomic_write <dest-path>
#       Read JSON from stdin, write it atomically to <dest-path> (temp file
#       in the same directory, then rename over the destination). See the
#       atomic_write doc-comment below for the fsync contract.
#
#   journal.sh canonical
#       Read JSON from stdin, emit canonical JSON to stdout: recursively
#       sorted object keys, compact separators. Array order is preserved
#       (canonicalization sorts keys only, never reorders array elements).
#
# DEPENDENCIES: bash, coreutils (date, mkdir, mv, rm, cat, dirname), and
#               EITHER jq OR python3 for safe JSON handling (jq preferred;
#               python3 used as fallback). Deliberately does NOT depend on
#               node.
#
# NOTE: All paths are relative to the current working directory (project
# root), same convention as checkpoint.sh.
#
# ---------------------------------------------------------------------------
# EVENT SCHEMA (the contract)
# ---------------------------------------------------------------------------
# journal.ndjson is one JSON object per line (newline-delimited JSON). Every
# event ALWAYS carries:
#   seq   (int)     monotonic, starts at 1, increments by 1 per event in the
#                    journal (assigned by journal_append — never supplied by
#                    the caller).
#   t     (string)   ISO-8601 UTC timestamp, "%Y-%m-%dT%H:%M:%SZ" (assigned
#                    by journal_append — the ONLY place a wall-clock time
#                    enters the system; a later `fold` is a pure function of
#                    the journal and never calls `date` itself).
#   event (string)   one of the event types below; determines which other
#                    fields the object carries.
#
# Event types (`event` field value -> its other fields):
#   run_started       { runId, baseUrl?, mode? }
#   phase_entered     { phase }
#   phase_exited      { phase }
#   plan_frozen       { criteria: [{criterionId, scenarioId, personaId,
#                        mutates, writeSet?}], order: [criterionId] }
#   plan_amended      { criterionId, scenarioId, personaId, mutates }
#   scenario_started  { scenarioId, personaId }
#   criterion_started { scenarioId, criterionId, personaId }
#   act_intent        { key, writeSet }
#   act_committed     { key, outcome }
#   criterion_verdict { scenarioId, criterionId, personaId, verdict,
#                        confidence, layer?, evidenceRefs, kinds, bugRef?,
#                        lastAction?, nonUiActionReason? }
#   bug_logged        { bugId, criterionId, title, suspectedLayer, expected,
#                        actual, axis? }
#   run_ended         {}
#
# (Plan A journals + folds these. `act_*`/`plan_*` reconciliation and resume
# semantics beyond the raw journal record are Plan B's concern — this task
# only ships the append-only writer + shared write helpers.)
#
# ---------------------------------------------------------------------------
# APPEND ATOMICITY CAVEAT (PIPE_BUF, 4 KB)
# ---------------------------------------------------------------------------
# journal_append opens the journal file with a shell `>>` redirect, which
# uses the O_APPEND write path. POSIX guarantees a `write()` of up to
# PIPE_BUF bytes (4096 on Linux) to a file opened O_APPEND is atomic with
# respect to other writers/readers — but this script emits one JSON object
# per event, and an event serialized ABOVE 4096 bytes is NOT guaranteed to
# land torn-free if the process crashes mid-write (e.g. a `plan_frozen`
# event listing hundreds of criteria). This is an ACCEPTED boundary, not a
# bug to engineer around: a later `fold(journal)` implements a torn-last-line
# rule — if the final line in the journal fails to parse as JSON, fold treats
# it as an in-flight write that never completed, drops it, and the caller
# (whoever was appending that event) is expected to retry. Do not "fix" this
# by switching to a heavier locking/write scheme; the torn-last-line recovery
# is the intended design for this boundary.
# ---------------------------------------------------------------------------

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

# ---------------------------------------------------------------------------
# helpers (pattern copied from checkpoint.sh:69-71)
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ---------------------------------------------------------------------------
# journal_file <run-id> → stdout path
# ---------------------------------------------------------------------------

journal_file() {
  local run_id="$1"
  echo "${QA_BASE}/${run_id}/journal.ndjson"
}

# ---------------------------------------------------------------------------
# next_seq <journal-file> → stdout int
#
# Max existing `.seq` across all lines in the file (skipping any line that
# fails to parse — e.g. a torn last line — rather than dying on it), plus 1;
# 0 (-> next is 1) if the file is absent/empty or has no parseable seq.
# ---------------------------------------------------------------------------

next_seq() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo 1
    return 0
  fi
  local max=0
  if has_jq; then
    # Read line-by-line in pure bash (no grep/sort/tail — those aren't in
    # this script's documented dependency list) and take the max parseable
    # `.seq`, skipping any line that fails to parse (e.g. a torn last line).
    local line seq
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      seq="$(jq -e '.seq' <<< "$line" 2>/dev/null)" || continue
      if [[ "$seq" =~ ^[0-9]+$ ]] && (( seq > max )); then
        max=$seq
      fi
    done < "$file"
  elif has_py; then
    max="$(python3 - "$file" <<'PYEOF'
import json, sys
max_seq = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        seq = obj.get("seq")
        if isinstance(seq, int) and seq > max_seq:
            max_seq = seq
print(max_seq)
PYEOF
)"
  else
    die "journal.sh needs either 'jq' or 'python3' to read the journal."
  fi
  [[ -z "$max" ]] && max=0
  echo $((max + 1))
}

# ---------------------------------------------------------------------------
# journal_append <run-id> <event-json>
#
# Validates <event-json> is a single JSON object with a non-empty string
# `event` field, stamps seq + t (the ONLY place `date` is called in this
# system), and appends exactly one compact, newline-terminated line via `>>`.
# Dies (non-zero + message, nothing written) on malformed input.
# ---------------------------------------------------------------------------

journal_append() {
  local run_id="$1" event_json="$2"
  local file
  file="$(journal_file "$run_id")"
  local dir
  dir="$(dirname "$file")"

  local line
  if has_jq; then
    if ! jq -e 'type == "object" and (has("event")) and ((.event | type) == "string") and (.event | length > 0)' \
         >/dev/null 2>&1 <<< "$event_json"; then
      die "journal_append: event JSON must be a single object with a non-empty string 'event' field: ${event_json}"
    fi
  elif has_py; then
    if ! python3 -c '
import json, sys
try:
    obj = json.loads(sys.argv[1])
except json.JSONDecodeError as e:
    print(f"not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(obj, dict):
    print("not a JSON object", file=sys.stderr)
    sys.exit(1)
ev = obj.get("event")
if not isinstance(ev, str) or len(ev) == 0:
    print("missing non-empty string \"event\" field", file=sys.stderr)
    sys.exit(1)
' "$event_json" 2>&1 1>/dev/null; then
      die "journal_append: event JSON must be a single object with a non-empty string 'event' field: ${event_json}"
    fi
  else
    die "journal.sh needs either 'jq' or 'python3' to validate/append journal events."
  fi

  mkdir -p "$dir"

  local seq now
  seq="$(next_seq "$file")"
  now="$(ts)"

  if has_jq; then
    line="$(jq -c --argjson seq "$seq" --arg t "$now" '. + {seq: $seq, t: $t}' <<< "$event_json")" \
      || die "journal_append: jq failed to stamp seq/t onto the event."
  elif has_py; then
    line="$(python3 -c '
import json, sys
obj = json.loads(sys.argv[1])
obj["seq"] = int(sys.argv[2])
obj["t"] = sys.argv[3]
print(json.dumps(obj, separators=(",", ":")))
' "$event_json" "$seq" "$now")" \
      || die "journal_append: python3 failed to stamp seq/t onto the event."
  fi

  echo "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# atomic_write <dest-path>
#
# Reads JSON from stdin, canonicalizes it (sorted keys, compact separators —
# same contract as `canonical`), and writes the canonical form to a temp file
# in the SAME directory as <dest-path>, then renames it over <dest-path>
# (temp-in-same-dir + rename is POSIX-atomic on a single filesystem
# regardless of fsync availability).
#
# When python3 is available: fsyncs the temp file's contents to disk BEFORE
# the rename, renames, then fsyncs the parent directory (so the rename itself
# is durable across a crash) — the full durability contract.
#
# When only jq is available (no python3): the two fsyncs are skipped (there
# is no portable fsync primitive in pure bash/coreutils) — the write is still
# temp-in-same-dir + rename (so it is still atomic w.r.t. concurrent
# readers), just not crash-durable. In that case the token FSYNC_UNAVAILABLE
# is echoed on fd 3, so a caller that maintains a fold-anomalies log can
# capture it.
#
# The temp file is trap-cleaned on any failure so a `.tmp.$$` is never left
# behind (mirrors checkpoint.sh:220-228).
# ---------------------------------------------------------------------------

atomic_write() {
  local dest="$1"
  local dir tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$"

  # Fail closed on stdin that isn't valid JSON, rather than write garbage.
  # Canonicalize (sorted keys, compact separators) here too — the same
  # contract as `canonical` — so every caller of atomic_write gets a
  # deterministic on-disk byte layout for free (fold/checkpoint diffs stay
  # stable across writers).
  local input canon
  input="$(cat)"
  if has_jq; then
    if ! canon="$(jq -S -c . <<< "$input" 2>/dev/null)"; then
      die "atomic_write: input on stdin is not valid JSON."
    fi
  elif has_py; then
    if ! canon="$(python3 -c '
import json, sys
obj = json.loads(sys.argv[1])
print(json.dumps(obj, sort_keys=True, separators=(",", ":")))
' "$input" 2>/dev/null)"; then
      die "atomic_write: input on stdin is not valid JSON."
    fi
  else
    die "journal.sh needs either 'jq' or 'python3' to validate JSON before an atomic write."
  fi

  # Trap-clean the temp file on any failure from here on (mirrors
  # checkpoint.sh:220-228: die() calls `exit`, which a `trap ... RETURN`
  # would NOT catch on this codepath, so cleanup is explicit — rm -f before
  # every die — rather than relying on a bash trap that would not fire).
  if ! printf '%s' "$canon" > "$tmp"; then
    rm -f "$tmp"
    die "atomic_write: failed to write temp file ${tmp}."
  fi

  if has_py; then
    if ! python3 -c '
import os, sys
path = sys.argv[1]
fd = os.open(path, os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$tmp"; then
      rm -f "$tmp"
      die "atomic_write: fsync of temp file ${tmp} failed."
    fi
  else
    # jq-only box: no portable fsync primitive here — signal it on fd 3.
    echo "FSYNC_UNAVAILABLE" >&3 2>/dev/null || true
  fi

  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    die "atomic_write: failed to move ${tmp} -> ${dest} (disk full or permission error?) — cleaned up the temp file, nothing changed."
  fi

  if has_py; then
    if ! python3 -c '
import os, sys
dirpath = sys.argv[1]
fd = os.open(dirpath, os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$dir"; then
      die "atomic_write: fsync of parent directory ${dir} failed after rename (destination was written)."
    fi
  else
    echo "FSYNC_UNAVAILABLE" >&3 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# canonical
#
# Reads JSON from stdin, emits canonical JSON to stdout: recursively sorted
# object keys, compact separators. Array element order is preserved.
# ---------------------------------------------------------------------------

canonical() {
  if has_jq; then
    jq -S -c . || die "canonical: jq failed to parse/serialize stdin as JSON."
  elif has_py; then
    python3 -c '
import json, sys
obj = json.load(sys.stdin)
print(json.dumps(obj, sort_keys=True, separators=(",", ":")))
' || die "canonical: python3 failed to parse/serialize stdin as JSON."
  else
    die "journal.sh needs either 'jq' or 'python3' to canonicalize JSON."
  fi
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: journal.sh append <run-id> <event-json>\n       journal.sh atomic_write <dest-path>\n       journal.sh canonical"

  case "$1" in
    append)
      [[ $# -lt 3 ]] && die "append requires: <run-id> <event-json>"
      journal_append "$2" "$3"
      ;;
    atomic_write)
      [[ $# -lt 2 ]] && die "atomic_write requires: <dest-path>"
      atomic_write "$2"
      ;;
    canonical)
      canonical
      ;;
    *)
      die "usage: journal.sh {append|atomic_write|canonical} …"
      ;;
  esac
}

main "$@"
