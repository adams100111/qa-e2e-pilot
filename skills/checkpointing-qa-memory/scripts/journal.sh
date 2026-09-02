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
#   journal.sh append --child <name> <run-id> <event-json>
#       Fan-out mode (ADR-0003 opt-in parallel path, Task 6 durable-substrate
#       plan). Same validation as above, but appends to
#       .qa/runs/<run-id>/journal.<name>.ndjson instead of the shared
#       journal.ndjson, stamping `childId:"<name>"` + a PER-CHILD `childSeq`
#       (that file's own counter) alongside `t` — NOT the global `seq`,
#       which is assigned once, later, by journal-merge.sh. See
#       journal-merge.sh for how sub-journals are folded back into the main
#       journal under a lock.
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

# QA_ENGINE (unset by default) lets a caller force which JSON engine this
# script uses, overriding the auto-detect below: QA_ENGINE=python3 forces
# the python3 branch even if jq is on PATH; QA_ENGINE=jq forces the jq
# branch. Unset/any other value = today's auto-detect (jq if present, else
# python3). This exists so checkpoint.sh — which shells out to this script
# with an augmented PATH that may re-expose a jq the caller deliberately
# hid — can force the SAME engine it itself detected on the caller's real,
# unaugmented PATH (see checkpoint.sh's ext_path/QA_ENGINE comment).
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

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
# child_journal_file <run-id> <child-name> → stdout path
#
# Task 6 (fan-out sub-journals): each fan-out child writes to its OWN
# journal.<name>.ndjson instead of the shared journal.ndjson, so parallel
# children never interleave writes into the same file. <child-name> is
# restricted to [A-Za-z0-9_-]+ (no '/', no '..') so it can't escape the run
# directory or collide with the main journal.ndjson / lock files.
# ---------------------------------------------------------------------------

child_journal_file() {
  local run_id="$1" child="$2"
  [[ "$child" =~ ^[A-Za-z0-9_-]+$ ]] || die "child_journal_file: invalid --child name '${child}' (expected [A-Za-z0-9_-]+)."
  echo "${QA_BASE}/${run_id}/journal.${child}.ndjson"
}

# ---------------------------------------------------------------------------
# next_seq_generic <file> <field-name> → stdout int
#
# Max existing `.<field-name>` (integer) across all lines in the file
# (skipping any line that fails to parse — e.g. a torn last line — rather
# than dying on it), plus 1; 0 (-> next is 1) if the file is absent/empty or
# has no parseable value for that field. Shared implementation behind
# next_seq (field "seq", the main journal's global sequence) and
# next_child_seq (field "childSeq", a fan-out child's own per-child
# sequence) — Task 6.
# ---------------------------------------------------------------------------

next_seq_generic() {
  local file="$1" field="$2"
  if [[ ! -s "$file" ]]; then
    echo 1
    return 0
  fi
  local max=0
  if has_jq; then
    # Read line-by-line in pure bash (no grep/sort/tail — those aren't in
    # this script's documented dependency list) and take the max parseable
    # value for $field, skipping any line that fails to parse (e.g. a torn
    # last line).
    local line val
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      val="$(jq -e --arg f "$field" '.[$f]' <<< "$line" 2>/dev/null)" || continue
      if [[ "$val" =~ ^[0-9]+$ ]] && (( val > max )); then
        max=$val
      fi
    done < "$file"
  elif has_py; then
    max="$(python3 - "$file" "$field" <<'PYEOF'
import json, sys
max_val = 0
field = sys.argv[2]
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        val = obj.get(field)
        if isinstance(val, int) and val > max_val:
            max_val = val
print(max_val)
PYEOF
)"
  else
    die "journal.sh needs either 'jq' or 'python3' to read the journal."
  fi
  [[ -z "$max" ]] && max=0
  echo $((max + 1))
}

# next_seq <journal-file> → stdout int -- the main journal's global `seq`.
next_seq() {
  next_seq_generic "$1" "seq"
}

# next_child_seq <child-journal-file> → stdout int -- a fan-out child's own
# `childSeq` (Task 6). Independent counter per child file; the global `seq`
# is assigned later, at journal-merge.sh merge time.
next_child_seq() {
  next_seq_generic "$1" "childSeq"
}

# ---------------------------------------------------------------------------
# journal_append <run-id> <event-json> [child-name]
#
# Validates <event-json> is a single JSON object with a non-empty string
# `event` field, stamps t (the ONLY place `date` is called in this system),
# and appends exactly one compact, newline-terminated line via `>>`. Dies
# (non-zero + message, nothing written) on malformed input.
#
# Default (no [child-name], the byte-identical Task 1 behaviour): appends to
# the main journal.ndjson, stamping the global monotonic `seq` (this
# journal's own next_seq) alongside `t`. The event carries NEITHER `childId`
# NOR `childSeq`.
#
# Fan-out mode (Task 6, [child-name] given — see child_journal_file): appends
# to journal.<child-name>.ndjson instead, stamping `childId:"<child-name>"`
# and a PER-CHILD `childSeq` (that child file's own next_child_seq) alongside
# `t`. It does NOT stamp a global `seq` — the global seq is assigned later,
# once, at journal-merge.sh merge time (so two children writing concurrently
# never race over the SAME counter). `childId`/`childSeq` are what
# journal-merge.sh dedups on (idempotent re-merge) and what fold's
# cross-child-duplicate rule keys on.
# ---------------------------------------------------------------------------

journal_append() {
  local run_id="$1" event_json="$2" child="${3:-}"
  local file
  if [[ -n "$child" ]]; then
    file="$(child_journal_file "$run_id" "$child")"
  else
    file="$(journal_file "$run_id")"
  fi
  local dir
  dir="$(dirname "$file")"

  local line
  if has_jq; then
    # `jq -e` alone is not enough: under multi-value / trailing-content
    # input, its exit status reflects only the LAST value in the stream, so
    # e.g. '{"foo":1} {"event":"a"}' would pass the object/event check below
    # on the trailing value while silently admitting the leading one too.
    # Guard first that the input parses to EXACTLY ONE JSON value.
    local value_count
    value_count="$(jq -c . <<< "$event_json" 2>/dev/null | wc -l)"
    if [[ "$value_count" -ne 1 ]] || \
       ! jq -e 'type == "object" and (has("event")) and ((.event | type) == "string") and (.event | length > 0)' \
         >/dev/null 2>&1 <<< "$event_json"; then
      die "journal_append: event JSON must be a single object with a non-empty string 'event' field: ${event_json}"
    fi
  elif has_py; then
    if ! python3 -c '
import json, sys
try:
    obj = json.loads(sys.stdin.read())
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
' <<< "$event_json" 2>&1 1>/dev/null; then
      die "journal_append: event JSON must be a single object with a non-empty string 'event' field: ${event_json}"
    fi
  else
    die "journal.sh needs either 'jq' or 'python3' to validate/append journal events."
  fi

  mkdir -p "$dir"

  local now
  now="$(ts)"

  if [[ -n "$child" ]]; then
    local child_seq
    child_seq="$(next_child_seq "$file")"
    if has_jq; then
      line="$(jq -c --arg t "$now" --arg cid "$child" --argjson cseq "$child_seq" \
                '. + {t: $t, childId: $cid, childSeq: $cseq}' <<< "$event_json")" \
        || die "journal_append: jq failed to stamp t/childId/childSeq onto the event."
    elif has_py; then
      line="$(python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
obj["t"] = sys.argv[1]
obj["childId"] = sys.argv[2]
obj["childSeq"] = int(sys.argv[3])
print(json.dumps(obj, separators=(",", ":")))
' "$now" "$child" "$child_seq" <<< "$event_json")" \
        || die "journal_append: python3 failed to stamp t/childId/childSeq onto the event."
    fi
  else
    local seq
    seq="$(next_seq "$file")"
    if has_jq; then
      line="$(jq -c --argjson seq "$seq" --arg t "$now" '. + {seq: $seq, t: $t}' <<< "$event_json")" \
        || die "journal_append: jq failed to stamp seq/t onto the event."
    elif has_py; then
      line="$(python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
obj["seq"] = int(sys.argv[1])
obj["t"] = sys.argv[2]
print(json.dumps(obj, separators=(",", ":")))
' "$seq" "$now" <<< "$event_json")" \
        || die "journal_append: python3 failed to stamp seq/t onto the event."
    fi
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
obj = json.loads(sys.stdin.read())
print(json.dumps(obj, sort_keys=True, separators=(",", ":")))
' <<< "$input" 2>/dev/null)"; then
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
  [[ $# -lt 1 ]] && die "Usage: journal.sh append [--child <name>] <run-id> <event-json>\n       journal.sh atomic_write <dest-path>\n       journal.sh canonical"

  case "$1" in
    append)
      shift
      local child=""
      if [[ "${1:-}" == "--child" ]]; then
        [[ $# -lt 2 ]] && die "append --child requires a name"
        child="$2"
        shift 2
      fi
      [[ $# -lt 2 ]] && die "append requires: [--child <name>] <run-id> <event-json>"
      journal_append "$1" "$2" "$child"
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
