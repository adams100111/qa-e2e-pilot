#!/usr/bin/env bash
# fold.sh — dispatcher for fold(journal): journal.ndjson -> checkpoint.json
# (+ fold-anomalies.json). Plan A Task 2 (AC-1/AC-2 core).
#
# USAGE: fold.sh <run-id>
#
# Reads .qa/runs/<run-id>/journal.ndjson, parses+validates each line ITSELF
# (torn/malformed lines never reach the pure reducers fold.jq/fold.py),
# dispatches {events, skipped} to fold.jq (has_jq) or fold.py (has_py),
# atomic_write's the derived checkpoint.json, fold-anomalies.json, and
# cursor.json (Task 4 — the resumable {phase, criteria_total/done, personas,
# scenarios, cursor} projection) into the run dir, and echoes the checkpoint
# JSON to stdout. This script NEVER writes run-manifest.json or bug-log.json
# — those stay agent-authored (grill Q2/Q3); a fold overwrite would clobber
# their richer hand-filled fields.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3 (jq preferred). No
# node — same convention as journal.sh/checkpoint.sh. Whichever engine is
# available drives BOTH the line-parsing pass and the reduce pass, so a
# single fold.sh run never mixes engines.
#
# NOTE ON journal.sh REUSE: journal.sh ends with an unconditional `main "$@"`
# (no `[[ "${BASH_SOURCE[0]}" == "$0" ]]` sourcing guard), so `source`-ing it
# here would immediately re-dispatch journal.sh's OWN main() against fold.sh's
# `<run-id>` argument and `die` (exit) before fold.sh's own logic ever ran.
# This script therefore shells out to journal.sh as a subprocess for
# atomic_write — exactly the invocation pattern tests/journal/run.sh already
# uses (`bash "$J" atomic_write ...`) — rather than sourcing it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOURNAL_SH="$HERE/journal.sh"
FOLD_JQ="$HERE/fold.jq"
FOLD_PY="$HERE/fold.py"

QA_BASE="${QA_BASE:-.qa/runs}"

die() { echo "ERROR: $*" >&2; exit 1; }
# QA_ENGINE override — see journal.sh's has_jq for the full rationale.
# QA_ENGINE=python3 forces the python3 branch, QA_ENGINE=jq forces jq,
# unset/other = auto-detect (unchanged behavior).
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

# Event schema (journal.sh EVENT SCHEMA comment block) — a parsed line whose
# `event` value isn't in this set is a schema-unknown-event anomaly.
KNOWN_EVENTS_JSON='["run_started","phase_entered","phase_exited","plan_frozen","plan_amended","scenario_started","criterion_started","act_intent","act_committed","criterion_verdict","bug_logged","run_ended"]'

# ---------------------------------------------------------------------------
# parse_journal_jq/py <journal-file> -> stdout {"events":[...],"skipped":[...]}
#
# Line-by-line validation: a line must parse as JSON AND be an object with a
# non-empty string `event` field (the same envelope check journal_append
# itself enforces) to become a candidate event; if its `event` isn't in the
# known schema set it's an "unknown-event" anomaly instead. Anything that
# fails to parse at all (including a torn last line) is "unparseable-line".
# Blank lines are silently skipped (matches journal.sh's next_seq reader).
# ---------------------------------------------------------------------------

parse_journal_jq() {
  local file="$1"
  jq -R -s --argjson known "$KNOWN_EVENTS_JSON" '
    def is_valid_envelope:
      type == "object" and has("event") and (.event | type == "string") and (.event | length > 0);
    (split("\n")) as $lines
    | reduce range(0; ($lines | length)) as $i
        ({events: [], skipped: []};
          ($lines[$i]) as $raw
          | (($i) + 1) as $lineno
          | if ($raw | length) == 0 then .
            else
              (try ($raw | fromjson) catch "___PARSE_ERROR___") as $parsed
              | if ($parsed == "___PARSE_ERROR___") or (($parsed | is_valid_envelope) | not) then
                  .skipped += [{rule: "unparseable-line", line: $lineno}]
                elif ($known | index($parsed.event)) == null then
                  .skipped += [{rule: "unknown-event", line: $lineno, event: $parsed.event}]
                else
                  .events += [$parsed]
                end
            end
        )
  ' < "$file"
}

parse_journal_py() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import json, sys

known = {"run_started", "phase_entered", "phase_exited", "plan_frozen",
         "plan_amended", "scenario_started", "criterion_started", "act_intent",
         "act_committed", "criterion_verdict", "bug_logged", "run_ended"}

path = sys.argv[1]
events = []
skipped = []
with open(path) as f:
    for i, raw in enumerate(f, start=1):
        line = raw.rstrip("\n")
        if line == "":
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            skipped.append({"rule": "unparseable-line", "line": i})
            continue
        if not isinstance(parsed, dict) or not isinstance(parsed.get("event"), str) or parsed.get("event") == "":
            skipped.append({"rule": "unparseable-line", "line": i})
            continue
        if parsed["event"] not in known:
            skipped.append({"rule": "unknown-event", "line": i, "event": parsed["event"]})
            continue
        events.append(parsed)
print(json.dumps({"events": events, "skipped": skipped}))
PYEOF
}

main() {
  [[ $# -lt 1 ]] && die "Usage: fold.sh <run-id>"
  local run_id="$1"
  local run_dir="${QA_BASE}/${run_id}"
  local journal_file="${run_dir}/journal.ndjson"

  [[ -f "$journal_file" ]] || die "No journal found for run '${run_id}': ${journal_file}"

  local engine
  if has_jq; then
    engine="jq"
  elif has_py; then
    engine="py"
  else
    die "fold.sh needs either 'jq' or 'python3' on PATH."
  fi

  local wrapper_json engine_out
  if [[ "$engine" == "jq" ]]; then
    wrapper_json="$(parse_journal_jq "$journal_file")" || die "fold.sh: jq failed to parse the journal."
    engine_out="$(printf '%s' "$wrapper_json" | jq -f "$FOLD_JQ")" \
      || die "fold.sh: fold.jq failed to reduce the journal."
  else
    wrapper_json="$(parse_journal_py "$journal_file")" || die "fold.sh: python3 failed to parse the journal."
    engine_out="$(printf '%s' "$wrapper_json" | python3 "$FOLD_PY")" \
      || die "fold.sh: fold.py failed to reduce the journal."
  fi

  local checkpoint_json anomalies_json openacts_json cursor_json
  if [[ "$engine" == "jq" ]]; then
    checkpoint_json="$(jq -c '.checkpoint' <<< "$engine_out")"
    anomalies_json="$(jq -c '.anomalies' <<< "$engine_out")"
    openacts_json="$(jq -c '.openActs' <<< "$engine_out")"
    cursor_json="$(jq -c '.cursor' <<< "$engine_out")"
  else
    checkpoint_json="$(python3 -c 'import json,sys
d=json.load(sys.stdin); print(json.dumps(d["checkpoint"]))' <<< "$engine_out")"
    anomalies_json="$(python3 -c 'import json,sys
d=json.load(sys.stdin); print(json.dumps(d["anomalies"]))' <<< "$engine_out")"
    openacts_json="$(python3 -c 'import json,sys
d=json.load(sys.stdin); print(json.dumps(d["openActs"]))' <<< "$engine_out")"
    cursor_json="$(python3 -c 'import json,sys
d=json.load(sys.stdin); print(json.dumps(d["cursor"]))' <<< "$engine_out")"
  fi

  mkdir -p "$run_dir"

  # atomic_write checkpoint.json — capture a possible FSYNC_UNAVAILABLE
  # signal on fd 3 (journal.sh's atomic_write contract: jq-only hosts have
  # no portable fsync primitive) so it can be folded into the sibling
  # fold-anomalies.json as its own anomaly.
  local fsync_capture fsync_flag=""
  fsync_capture="$(mktemp)"
  if ! printf '%s' "$checkpoint_json" | bash "$JOURNAL_SH" atomic_write "${run_dir}/checkpoint.json" 3>"$fsync_capture"; then
    rm -f "$fsync_capture"
    die "fold.sh: atomic_write of checkpoint.json failed."
  fi
  grep -q FSYNC_UNAVAILABLE "$fsync_capture" 2>/dev/null && fsync_flag="1"
  rm -f "$fsync_capture"

  if [[ -n "$fsync_flag" ]]; then
    if [[ "$engine" == "jq" ]]; then
      anomalies_json="$(jq -c '. + [{"rule":"fsync-unavailable"}]' <<< "$anomalies_json")"
    else
      anomalies_json="$(python3 -c 'import json,sys
a=json.load(sys.stdin); a.append({"rule":"fsync-unavailable"}); print(json.dumps(a))' <<< "$anomalies_json")"
    fi
  fi

  local fold_anomalies_json
  if [[ "$engine" == "jq" ]]; then
    fold_anomalies_json="$(jq -cn --argjson anomalies "$anomalies_json" --argjson openActs "$openacts_json" \
      '{anomalies: $anomalies, openActs: $openActs}')"
  else
    fold_anomalies_json="$(python3 -c 'import json,sys
anomalies=json.loads(sys.argv[1]); openActs=json.loads(sys.argv[2])
print(json.dumps({"anomalies": anomalies, "openActs": openActs}))' "$anomalies_json" "$openacts_json")"
  fi

  # Second atomic_write: fold-anomalies.json. ACCEPTED BOUNDARY: if THIS
  # write itself signals FSYNC_UNAVAILABLE, that signal has nowhere left to
  # be recorded (the file describing anomalies is the one being written) —
  # note it to stderr rather than silently drop it.
  local fsync_capture2
  fsync_capture2="$(mktemp)"
  if ! printf '%s' "$fold_anomalies_json" | bash "$JOURNAL_SH" atomic_write "${run_dir}/fold-anomalies.json" 3>"$fsync_capture2"; then
    rm -f "$fsync_capture2"
    die "fold.sh: atomic_write of fold-anomalies.json failed."
  fi
  if grep -q FSYNC_UNAVAILABLE "$fsync_capture2" 2>/dev/null; then
    echo "NOTE: fsync unavailable while writing fold-anomalies.json itself (jq-only host, no portable fsync primitive) — not self-recorded." >&2
  fi
  rm -f "$fsync_capture2"

  # Third atomic_write: cursor.json (Task 4) — the resumable
  # {phase, criteria_total/done, personas, scenarios, cursor} projection.
  # ACCEPTED BOUNDARY (same shape as the fold-anomalies.json write above):
  # if THIS write itself signals FSYNC_UNAVAILABLE, note it to stderr rather
  # than silently drop it — there is no third file left to record it in.
  # run-manifest.json and bug-log.json are NEVER written here — they stay
  # agent-authored (grill Q2/Q3); this fold writes checkpoint.json,
  # fold-anomalies.json, and cursor.json only.
  local fsync_capture3
  fsync_capture3="$(mktemp)"
  if ! printf '%s' "$cursor_json" | bash "$JOURNAL_SH" atomic_write "${run_dir}/cursor.json" 3>"$fsync_capture3"; then
    rm -f "$fsync_capture3"
    die "fold.sh: atomic_write of cursor.json failed."
  fi
  if grep -q FSYNC_UNAVAILABLE "$fsync_capture3" 2>/dev/null; then
    echo "NOTE: fsync unavailable while writing cursor.json (jq-only host, no portable fsync primitive) — not self-recorded." >&2
  fi
  rm -f "$fsync_capture3"

  echo "$checkpoint_json"
}

main "$@"
