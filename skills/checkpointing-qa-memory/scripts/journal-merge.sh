#!/usr/bin/env bash
# journal-merge.sh — idempotently fold fan-out sub-journals
# (journal.<name>.ndjson) into the shared journal.ndjson under an advisory
# lock, re-stamping a monotonic global `seq` (ADR-0003 opt-in parallel path,
# Task 6 durable-substrate plan).
#
# USAGE: journal-merge.sh <run-id>
#
# Each fan-out child appends its own events via `journal.sh append --child
# <name> …`, landing them in `.qa/runs/<run-id>/journal.<name>.ndjson` with a
# PER-CHILD `childSeq` and a `childId` stamp — never touching the shared
# journal.ndjson, so parallel children never interleave writes into the same
# file. This script is the parent-side merge: under a lock on
# `.qa/runs/<run-id>/.journal.lock`, it reads every journal.<*>.ndjson
# (sorted by name), orders their events by (childId, childSeq) — a total,
# deterministic order — and appends the ones not already present in
# journal.ndjson, re-stamping a monotonic global `seq` continuing from the
# main journal's current max. Each event's original `t` is preserved
# UNCHANGED (never re-stamped).
#
# IDEMPOTENCY (the headline property): dedup is on (childId, childSeq), not
# on file presence. A child file is removed ONLY AFTER its events are
# confirmed present in journal.ndjson (append → verify-by-reading-the-file-
# back → rm), so a crash between the append and the rm just leaves the child
# file in place; the NEXT run re-derives the same (childId, childSeq) pairs,
# finds them already in journal.ndjson, skips re-appending them, and safely
# removes the file. Re-running this script after such a crash is therefore a
# no-op on the main journal (no duplicate lines, seq stays contiguous).
#
# LOCKING: prefers `flock -x` on a fd opened against .journal.lock (released
# automatically when this process exits, even on a crash/kill). If `flock`
# is not on PATH, degrades to a `mkdir`-based lock (.journal.lock.d — mkdir
# is atomic across processes) and prints a NOTE about the fallback.
#
# DEPENDENCIES: bash, coreutils (find, sort, basename, dirname, mkdir, rm,
# cat), and EITHER jq OR python3 (jq preferred; QA_ENGINE can force either —
# see has_jq below, same convention as journal.sh/fold.sh). No node, no
# `grep -P`/perl.
set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE override — see journal.sh's has_jq for the full rationale.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# compute_main_state <file> → stdout {"maxSeq":N,"pairs":{"<childId>|<childSeq>":true,...}}
#
# maxSeq: the highest integer `.seq` across all parseable lines (0 if the
# file is absent/empty/has none — matches journal.sh's next_seq convention).
# pairs: the set of (childId,childSeq) already durable in this file, keyed
# "<childId>|<childSeq>" — what journal-merge dedups a child's events
# against. Lines that fail to parse (e.g. a torn last line) are skipped, not
# fatal — same torn-last-line tolerance as journal.sh/fold.sh.
# ---------------------------------------------------------------------------

compute_main_state() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo '{"maxSeq":0,"pairs":{}}'
    return 0
  fi
  local out
  if has_jq; then
    out="$(jq -R -s '
      (split("\n") | map(select(length>0))) as $lines
      | reduce $lines[] as $l ({maxSeq:0, pairs:{}};
          (try ($l | fromjson) catch null) as $e
          | if ($e == null) or (($e|type) != "object") then .
            else
              (if (($e.seq|type) == "number") and ($e.seq > .maxSeq) then .maxSeq = $e.seq else . end)
              | (if ($e.childId != null) and ($e.childSeq != null) then
                   .pairs[(($e.childId|tostring) + "|" + ($e.childSeq|tostring))] = true
                 else . end)
            end
        )
    ' < "$file")" || die "journal-merge.sh: jq failed to compute main journal state for ${file} (broken/unusable jq on PATH?)."
  elif has_py; then
    out="$(python3 - "$file" <<'PYEOF'
import json, sys
max_seq = 0
pairs = {}
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(e, dict):
            continue
        seq = e.get("seq")
        if isinstance(seq, int) and seq > max_seq:
            max_seq = seq
        cid = e.get("childId")
        cseq = e.get("childSeq")
        if cid is not None and cseq is not None:
            pairs["{}|{}".format(cid, cseq)] = True
print(json.dumps({"maxSeq": max_seq, "pairs": pairs}))
PYEOF
)" || die "journal-merge.sh: python3 failed to compute main journal state for ${file}."
  else
    die "journal-merge.sh needs either 'jq' or 'python3'."
  fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# child_well_formed <child-file> → stdout "true"|"false"
#
# Every non-blank line must parse as a JSON object with a non-empty string
# `event`, a non-null `childId`, and an integer `childSeq` — the shape
# journal_append's --child mode stamps. Used to gate cleanup: a child file
# with even one malformed line is never rm'd (left for the operator/next
# run rather than silently dropping data).
# ---------------------------------------------------------------------------

child_well_formed() {
  local file="$1"
  local out
  if has_jq; then
    out="$(jq -R -s '
      (split("\n") | map(select(length>0))) as $lines
      | ($lines | map(
           (try (. | fromjson) catch null) as $e
           | ($e != null) and (($e|type)=="object") and (($e.event|type)=="string") and (($e.event|length)>0)
             and ($e.childId != null) and (($e.childSeq|type)=="number")
         ) | all)
    ' < "$file")" || die "journal-merge.sh: jq failed to check well-formedness of ${file} (broken/unusable jq on PATH?)."
  elif has_py; then
    out="$(python3 - "$file" <<'PYEOF'
import json, sys
ok = True
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            ok = False
            continue
        if (not isinstance(e, dict) or not isinstance(e.get("event"), str)
                or e.get("event") == "" or e.get("childId") is None
                or not isinstance(e.get("childSeq"), int)):
            ok = False
print("true" if ok else "false")
PYEOF
)" || die "journal-merge.sh: python3 failed to check well-formedness of ${file}."
  else
    die "journal-merge.sh needs either 'jq' or 'python3'."
  fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# compute_new_lines <child-file> <main-state-json> → stdout new NDJSON lines
#
# Parses the child file, orders its events by childSeq (ascending — the
# child's own append order, re-sorted defensively), drops any whose
# (childId,childSeq) is already in main-state's pairs (idempotent dedup),
# and stamps a fresh monotonic `seq` (continuing from main-state's maxSeq)
# onto each survivor. `t` is passed through unchanged. Prints nothing if
# every event is already merged.
# ---------------------------------------------------------------------------

compute_new_lines() {
  local child_file="$1" main_state="$2"
  local out
  if has_jq; then
    out="$(jq -R -s -r --argjson main "$main_state" '
      ($main.maxSeq) as $base
      | ($main.pairs) as $pairs
      | (split("\n") | map(select(length>0))) as $lines
      | [ $lines[] | (try (. | fromjson) catch null)
          | select(. != null and (type=="object") and (.childId != null) and (.childSeq != null)) ]
      | sort_by(.childSeq)
      | reduce .[] as $e ({next: $base, out: []};
          (($e.childId|tostring) + "|" + ($e.childSeq|tostring)) as $k
          | if ($pairs[$k] // false) then .
            else (.next += 1) | (.out += [ ($e + {seq: .next}) ])
            end
        )
      | .out[]
      | tojson
    ' < "$child_file")" || die "journal-merge.sh: jq failed to compute new lines for ${child_file} (broken/unusable jq on PATH?)."
  elif has_py; then
    out="$(python3 - "$child_file" "$main_state" <<'PYEOF'
import json, sys
main_state = json.loads(sys.argv[2])
base = main_state.get("maxSeq", 0)
pairs = main_state.get("pairs", {})
events = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(e, dict) or e.get("childId") is None or e.get("childSeq") is None:
            continue
        events.append(e)
events.sort(key=lambda e: e["childSeq"])
next_seq = base
for e in events:
    k = "{}|{}".format(e["childId"], e["childSeq"])
    if pairs.get(k):
        continue
    next_seq += 1
    e2 = dict(e)
    e2["seq"] = next_seq
    print(json.dumps(e2, separators=(",", ":")))
PYEOF
)" || die "journal-merge.sh: python3 failed to compute new lines for ${child_file}."
  else
    die "journal-merge.sh needs either 'jq' or 'python3'."
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# child_fully_present <child-file> <main-state-json> → stdout "true"|"false"
#
# Post-write verification: every (childId,childSeq) pair in the child file
# (that itself parses) must now be present in main-state's pairs. Called
# with a main-state computed by RE-READING journal.ndjson from disk after
# the append — this is the "verify" half of append→verify→rm, not a trust-
# the-in-memory-write assumption.
# ---------------------------------------------------------------------------

child_fully_present() {
  local child_file="$1" main_state="$2"
  local out
  if has_jq; then
    out="$(jq -R -s --argjson main "$main_state" '
      ($main.pairs) as $pairs
      | (split("\n") | map(select(length>0))) as $lines
      | ($lines | map(
           (try (. | fromjson) catch null) as $e
           | if ($e == null) or ($e.childId == null) or ($e.childSeq == null) then true
             else ($pairs[(($e.childId|tostring)+"|"+($e.childSeq|tostring))] // false)
             end
         ) | all)
    ' < "$child_file")" || die "journal-merge.sh: jq failed to verify presence for ${child_file} (broken/unusable jq on PATH?)."
  elif has_py; then
    out="$(python3 - "$child_file" "$main_state" <<'PYEOF'
import json, sys
main_state = json.loads(sys.argv[2])
pairs = main_state.get("pairs", {})
ok = True
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(e, dict) or e.get("childId") is None or e.get("childSeq") is None:
            continue
        k = "{}|{}".format(e["childId"], e["childSeq"])
        if not pairs.get(k):
            ok = False
print("true" if ok else "false")
PYEOF
)" || die "journal-merge.sh: python3 failed to verify presence for ${child_file}."
  else
    die "journal-merge.sh needs either 'jq' or 'python3'."
  fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# do_merge <run-dir> <main-file>
#
# The actual merge, assumed to run under the lock. Deterministic child order
# = lexicographic filename order (journal.a.ndjson before journal.b.ndjson,
# …), which — since childSeq is monotonic per file — is equivalent to the
# required total (childId, childSeq) order. Processes one child file fully
# (append its new lines → re-read main → verify → rm-if-clean) before moving
# to the next, so the append order across children is exactly that total
# order.
# ---------------------------------------------------------------------------

do_merge() {
  local run_dir="$1" main_file="$2"

  local child_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && child_files+=("$f")
  done < <(find "$run_dir" -maxdepth 1 -type f -name 'journal.*.ndjson' ! -name 'journal.ndjson' 2>/dev/null | LC_ALL=C sort)

  if [[ ${#child_files[@]} -eq 0 ]]; then
    echo "journal-merge.sh: no child journals found under ${run_dir} — nothing to merge."
    return 0
  fi

  local f bn name wf main_state new_lines post_state present
  for f in "${child_files[@]}"; do
    bn="$(basename "$f")"
    name="${bn#journal.}"
    name="${name%.ndjson}"

    # NOTE: each helper's own internal `die` (e.g. a broken/unusable jq)
    # only kills the SUBSHELL that a `$(...)` command substitution runs in
    # -- it does NOT by itself propagate to this script. The `|| die` here
    # is what actually surfaces that failure as a hard journal-merge.sh
    # failure instead of silently degrading to "treat everything as
    # malformed" (which would print a WARNING and exit 0 even though the
    # underlying engine never actually ran).
    wf="$(child_well_formed "$f")" || die "journal-merge.sh: failed to check well-formedness of ${f}."

    main_state="$(compute_main_state "$main_file")" || die "journal-merge.sh: failed to compute main journal state from ${main_file}."
    new_lines="$(compute_new_lines "$f" "$main_state")" || die "journal-merge.sh: failed to compute new lines for ${f}."

    if [[ -n "$new_lines" ]]; then
      printf '%s\n' "$new_lines" >> "$main_file"
    fi

    # verify: re-read journal.ndjson from disk (not the in-memory $new_lines)
    post_state="$(compute_main_state "$main_file")" || die "journal-merge.sh: failed to compute post-merge main journal state from ${main_file}."
    present="$(child_fully_present "$f" "$post_state")" || die "journal-merge.sh: failed to verify presence for ${f}."

    if [[ "$wf" == "true" && "$present" == "true" ]]; then
      rm -f "$f"
      echo "journal-merge.sh: merged child '${name}' (${bn}) — removed."
    else
      echo "journal-merge.sh: WARNING — child '${name}' (${bn}) not fully merged (well_formed=${wf} present=${present}); left in place for retry." >&2
    fi
  done

  return 0
}

main() {
  [[ $# -lt 1 ]] && die "Usage: journal-merge.sh <run-id>"
  local run_id="$1"
  local run_dir="${QA_BASE}/${run_id}"
  local main_file="${run_dir}/journal.ndjson"
  local lock_file="${run_dir}/.journal.lock"
  local mkdir_lock="${run_dir}/.journal.lock.d"

  has_jq || has_py || die "journal-merge.sh needs either 'jq' or 'python3' on PATH."

  mkdir -p "$run_dir"

  if command -v flock >/dev/null 2>&1; then
    # exec'd fd 200 is held for the life of this process; the lock releases
    # automatically when the process exits (normally OR via a crash/kill),
    # so no explicit unlock/trap is needed here.
    exec 200>"$lock_file"
    flock -x 200 || die "journal-merge.sh: failed to acquire flock on ${lock_file}."
  else
    echo "NOTE: 'flock' not found on PATH — falling back to a mkdir-based lock (${mkdir_lock})." >&2
    # rm -rf, not rmdir: rmdir is not in this script's documented dependency
    # list (only rm is) — using it here would silently no-op the cleanup
    # under a minimal PATH (masked by the `|| true`), leaving a stale lock
    # directory behind. rm -rf also tolerates the directory not being
    # perfectly empty, which rmdir would refuse.
    trap 'rm -rf "'"$mkdir_lock"'" 2>/dev/null || true' EXIT
    local waited=0
    until mkdir "$mkdir_lock" 2>/dev/null; do
      sleep 0.2
      waited=$((waited + 1))
      if (( waited > 150 )); then
        die "journal-merge.sh: timed out waiting for mkdir-lock ${mkdir_lock}."
      fi
    done
  fi

  do_merge "$run_dir" "$main_file"
}

main "$@"
