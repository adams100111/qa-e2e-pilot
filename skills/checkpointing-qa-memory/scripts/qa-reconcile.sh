#!/usr/bin/env bash
# qa-reconcile.sh — resume-time glue (durable-resume Plan B, Task 4): fold a
# run, find genuinely OPEN acts (an `act_intent` with no matching
# `act_committed` — fold.sh's `fold-anomalies.json.openActs`), join each open
# act's key back to its `writeSet` (from the journal's own `act_intent`
# event) and its tuple's `personaId` (from that (scenarioId,criterionId)
# tuple's LAST `criterion_started`/`criterion_verdict` event, "" when none),
# and drive `rebake.sh reconcile` to close it out.
#
# USAGE:
#   qa-reconcile.sh plan <run-id>
#       Folds the run, then prints the open acts as a JSON array:
#       [{key, scenarioId, criterionId, personaId, writeSet}, ...] in
#       fold's first-seen openActs order. Empty array ([]) means nothing to
#       reconcile. This is the work-list the agent must re-bake: read back
#       every write-set member for each entry, then call `apply`.
#
#   qa-reconcile.sh apply <run-id> <key> --readbacks <json>
#       Folds the run, verifies <key> is CURRENTLY an open act (dies with a
#       clear message if it is not — already committed, or never intended),
#       joins its writeSet/scenarioId/criterionId/personaId the same way
#       `plan` does, and calls:
#         rebake.sh reconcile <run> <scenarioId> <criterionId> <personaId> \
#           --write-set <joined writeSet> --readbacks <json>
#       Then maps rebake's outcome to this script's own return, with a
#       crash-safe RETRY-ESCALATION on top of rebake's `none` -> `retry`:
#         landed -> "done" (rebake already journaled act_committed).
#         partial -> "blocked" (rebake already journaled a blocked verdict
#                    naming the missing key(s)).
#         deferred -> "deferred: <reason>" passthrough (rebake journaled
#                    nothing; nothing to escalate — retrying won't help a
#                    write-only key with no read path).
#         none (rebake's "retry") ->
#           - FIRST consecutive retry for this key: prints "retry" (the
#             caller is expected to re-drive the act — Task 2's bracket
#             again — then call `apply` once more). Nothing is journaled;
#             the open act stays open (crash-safe: a caller that never
#             calls apply again simply leaves the act open for the NEXT
#             resume to re-plan).
#           - SECOND consecutive retry for the SAME key (attempt counter
#             already at 1): escalates — journals a `blocked`
#             criterion_verdict itself (via checkpoint.sh, same shape as
#             rebake's own partial-outcome journal call) naming the key and
#             that two consecutive re-bake attempts found nothing landed,
#             clears the attempt counter, and prints "blocked". This is the
#             loop-breaker: `apply` NEVER returns "retry" a second time in a
#             row for the same key.
#       Every branch prints the rebake classify-summary JSON line first,
#       then the (possibly escalated) outcome word as the final line —
#       mirrors rebake.sh reconcile's own two-line contract.
#
# RETRY-ESCALATION ATTEMPT COUNTER (crash-safe, per-key):
#   .qa/runs/<run-id>/.reconcile-attempts is a small JSON object
#   {"<key>": <consecutive-retry-count>, ...}, atomic-written (via
#   journal.sh atomic_write — temp-in-same-dir + rename, fsynced when
#   python3 is available) on every update. It is READ fresh at the top of
#   every `apply` call and WRITTEN fresh after rebake's outcome is known —
#   there is no in-memory state carried across invocations, so a crash at
#   ANY point (including between separate `apply` processes, or with a
#   `fold.sh` run interleaved by another tool) never corrupts it: the file
#   either reflects the last successfully-completed `apply` call's decision
#   or (if that update itself never landed) simply UNDER-counts by at most
#   one attempt — the accepted boundary is one extra retry cycle, never an
#   infinite loop, since count only advances forward from a file that always
#   parses (an absent/unreadable file reads as count 0, never an error). A
#   key's counter is CLEARED (removed from the map) the moment its act
#   reaches a terminal outcome for this cycle (done/blocked/deferred), so a
#   later, unrelated open act never inherits a stale count.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3 (jq preferred; no
# node). Honors QA_ENGINE the same way journal.sh/checkpoint.sh/fold.sh/
# journal-emit.sh/rebake.sh do. This script is NEVER a second journal
# writer — it drives fold.sh (read-only projection) and rebake.sh/
# checkpoint.sh (the only two things that append to the journal), plus its
# own `.reconcile-attempts` marker file (NOT the journal).
#
# NOTE: all paths are relative to the current working directory (project
# root), same convention as journal.sh/checkpoint.sh/fold.sh/rebake.sh.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

# ---------------------------------------------------------------------------
# helpers (has_jq/has_py/die/validate_token copied from rebake.sh's header —
# same QA_ENGINE-honoring contract)
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

# Locate fold.sh/rebake.sh/journal.sh/checkpoint.sh relative to THIS script
# without depending on external `dirname` (pure bash parameter expansion —
# same trick journal-emit.sh/rebake.sh use).
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
FOLD_SH="${SCRIPT_DIR}/fold.sh"
REBAKE_SH="${SCRIPT_DIR}/rebake.sh"
JOURNAL_SH="${SCRIPT_DIR}/journal.sh"
CHECKPOINT_SH="${SCRIPT_DIR}/checkpoint.sh"

# Resolve the engine ONCE, from THIS script's own has_jq (which already
# honors QA_ENGINE), then pass it explicitly to every fold.sh/rebake.sh/
# checkpoint.sh subprocess call — same rationale as rebake.sh's/journal-
# emit.sh's ENGINE/append_event (a leaked jq on PATH can never silently
# switch engines mid-run).
ENGINE="python3"
has_jq && ENGINE="jq"

run_dir_for() { echo "${QA_BASE}/${1}"; }
journal_file_for() { echo "${QA_BASE}/${1}/journal.ndjson"; }
anomalies_file_for() { echo "${QA_BASE}/${1}/fold-anomalies.json"; }
attempts_file_for() { echo "${QA_BASE}/${1}/.reconcile-attempts"; }

# ---------------------------------------------------------------------------
# fold_run <run-id> — refresh checkpoint.json/fold-anomalies.json/cursor.json
# from the journal. Dies with a clear message (nothing printed) if fold.sh
# itself fails (e.g. no journal for this run at all).
# ---------------------------------------------------------------------------
fold_run() {
  local run_id="$1"
  QA_ENGINE="$ENGINE" bash "$FOLD_SH" "$run_id" >/dev/null \
    || die "qa-reconcile.sh: fold.sh failed for run '${run_id}' (does ${QA_BASE}/${run_id}/journal.ndjson exist?)."
}

read_openacts() {
  local run_id="$1"
  local f; f="$(anomalies_file_for "$run_id")"
  [[ -f "$f" ]] || die "qa-reconcile.sh: no fold-anomalies.json for run '${run_id}' after fold — this should not happen."
  if has_jq; then
    jq -c '.openActs // []' "$f" || die "qa-reconcile.sh: failed to read openActs from ${f}."
  elif has_py; then
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d.get("openActs") or []))
' "$f" || die "qa-reconcile.sh: failed to read openActs from ${f}."
  else
    die "qa-reconcile.sh needs either 'jq' or 'python3' to read fold-anomalies.json."
  fi
}

# ---------------------------------------------------------------------------
# join_openacts_jq/py <run-id> <journal-file> <openacts-json> -> stdout ONE
# line of JSON: [{key,scenarioId,criterionId,personaId,writeSet}, ...] in
# the SAME order as <openacts-json>.
#
# JOIN RULES:
#   - key splits as "<run-id>:<scenarioId>:<criterionId>" (run-id is the
#     KNOWN prefix — stripped first; the remainder splits on its FIRST
#     ':' into scenarioId/criterionId, matching how journal-emit.sh builds
#     the key: "${run_id}:${scenario_id}:${criterion_id}").
#   - writeSet: the write-set of the LAST act_intent event in the journal
#     whose key matches (last-wins — a key can in principle be re-emitted
#     across a retry cycle; the most recent intent is authoritative).
#     Missing -> [] (should not happen for a genuinely open act, but never
#     crash the join over it).
#   - personaId: the personaId of the LAST criterion_started OR
#     criterion_verdict event (whichever is later in the journal) sharing
#     this tuple's (scenarioId,criterionId). Missing -> "" (a shared
#     criterion with no persona context yet, or a bare act-intent call with
#     no preceding started/verdict event at all).
#
# Malformed/unparseable journal lines are silently skipped (never abort the
# join) — same discipline as fold.sh's own line-by-line parse.
# ---------------------------------------------------------------------------

join_openacts_jq() {
  local run_id="$1" journal_file="$2" openacts_json="$3"
  jq -R -s --arg runId "$run_id" --argjson openActs "$openacts_json" '
    (split("\n") | map(select(length > 0))
       | map(try fromjson catch null)
       | map(select(. != null and type == "object" and (has("event")) and ((.event|type)=="string")))
    ) as $events
    | (reduce $events[] as $e ({};
        if $e.event == "act_intent" then .[($e.key // "")] = ($e.writeSet // [])
        else . end
      )) as $intentMap
    | (reduce $events[] as $e ({};
        if $e.event == "criterion_started" or $e.event == "criterion_verdict" then
          (( $e.scenarioId // "") + "|" + ($e.criterionId // "")) as $tk
          | .[$tk] = ($e.personaId // "")
        else . end
      )) as $personaMap
    | [ $openActs[] as $key
        | ($key | ltrimstr($runId + ":")) as $rest
        | ($rest | index(":")) as $idx
        | (if $idx == null then $rest else $rest[0:$idx] end) as $scenarioId
        | (if $idx == null then "" else $rest[($idx+1):] end) as $criterionId
        | (($scenarioId + "|" + $criterionId)) as $tk
        | { key: $key, scenarioId: $scenarioId, criterionId: $criterionId,
            personaId: ($personaMap[$tk] // ""), writeSet: ($intentMap[$key] // []) }
      ]
  ' < "$journal_file" || die "qa-reconcile.sh: jq failed to join openActs for run '${run_id}'."
}

join_openacts_py() {
  local run_id="$1" journal_file="$2" openacts_json="$3"
  python3 -c '
import json, sys

run_id = sys.argv[1]
journal_file = sys.argv[2]
open_acts = json.loads(sys.argv[3])

events = []
try:
    with open(journal_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and isinstance(obj.get("event"), str):
                events.append(obj)
except FileNotFoundError:
    pass

intent_map = {}
persona_map = {}
for e in events:
    if e.get("event") == "act_intent":
        intent_map[e.get("key", "")] = e.get("writeSet") or []
    elif e.get("event") in ("criterion_started", "criterion_verdict"):
        tk = (e.get("scenarioId", "") or "") + "|" + (e.get("criterionId", "") or "")
        persona_map[tk] = e.get("personaId", "") or ""

out = []
prefix = run_id + ":"
for key in open_acts:
    rest = key[len(prefix):] if key.startswith(prefix) else key
    if ":" in rest:
        scenario_id, criterion_id = rest.split(":", 1)
    else:
        scenario_id, criterion_id = rest, ""
    tk = scenario_id + "|" + criterion_id
    out.append({
        "key": key,
        "scenarioId": scenario_id,
        "criterionId": criterion_id,
        "personaId": persona_map.get(tk, ""),
        "writeSet": intent_map.get(key, []),
    })
print(json.dumps(out))
' "$run_id" "$journal_file" "$openacts_json" || die "qa-reconcile.sh: python3 failed to join openActs for run '${run_id}'."
}

join_openacts() {
  local run_id="$1" journal_file="$2" openacts_json="$3"
  if has_jq; then
    join_openacts_jq "$run_id" "$journal_file" "$openacts_json"
  elif has_py; then
    join_openacts_py "$run_id" "$journal_file" "$openacts_json"
  else
    die "qa-reconcile.sh needs either 'jq' or 'python3' to join openActs."
  fi
}

# ---------------------------------------------------------------------------
# attempt counter — .qa/runs/<run-id>/.reconcile-attempts, a JSON object
# {"<key>": <int>}. Read-fresh / write-fresh every call (no cached state) —
# see the header doc-comment's crash-safety note.
# ---------------------------------------------------------------------------

read_attempts_map() {
  local run_id="$1"
  local f; f="$(attempts_file_for "$run_id")"
  if [[ ! -f "$f" ]]; then
    echo "{}"
    return 0
  fi
  if has_jq; then
    jq -c '.' "$f" 2>/dev/null || echo "{}"
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
print(json.dumps(d))
' "$f" 2>/dev/null || echo "{}"
  else
    echo "{}"
  fi
}

get_attempt() {
  local run_id="$1" key="$2"
  local map; map="$(read_attempts_map "$run_id")"
  if has_jq; then
    jq -r --arg k "$key" '.[$k] // 0' <<< "$map"
  else
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(int(d.get(sys.argv[2], 0)))
' "$map" "$key"
  fi
}

write_attempts_map() {
  local run_id="$1" map_json="$2"
  local f; f="$(attempts_file_for "$run_id")"
  printf '%s' "$map_json" | QA_ENGINE="$ENGINE" bash "$JOURNAL_SH" atomic_write "$f" 3>/dev/null \
    || die "qa-reconcile.sh: failed to write attempt marker for run '${run_id}'."
}

set_attempt() {
  local run_id="$1" key="$2" count="$3"
  local map; map="$(read_attempts_map "$run_id")"
  local new_map
  if has_jq; then
    new_map="$(jq -c --arg k "$key" --argjson c "$count" '.[$k] = $c' <<< "$map")"
  else
    new_map="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d[sys.argv[2]] = int(sys.argv[3])
print(json.dumps(d))
' "$map" "$key" "$count")"
  fi
  write_attempts_map "$run_id" "$new_map"
}

clear_attempt() {
  local run_id="$1" key="$2"
  local map; map="$(read_attempts_map "$run_id")"
  local new_map
  if has_jq; then
    new_map="$(jq -c --arg k "$key" 'del(.[$k])' <<< "$map")"
  else
    new_map="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d.pop(sys.argv[2], None)
print(json.dumps(d))
' "$map" "$key")"
  fi
  write_attempts_map "$run_id" "$new_map"
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

cmd_plan() {
  [[ $# -eq 1 ]] || die "plan requires: <run-id>"
  local run_id="$1"
  validate_token "$run_id" "run-id"

  fold_run "$run_id"

  local openacts_json
  openacts_json="$(read_openacts "$run_id")"

  local count
  if has_jq; then
    count="$(jq 'length' <<< "$openacts_json")"
  else
    count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$openacts_json")"
  fi
  if [[ "$count" -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  join_openacts "$run_id" "$(journal_file_for "$run_id")" "$openacts_json"
}

cmd_apply() {
  local readbacks=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --readbacks)
        [[ $# -lt 2 ]] && die "apply: --readbacks requires a value."
        readbacks="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ "${#positional[@]}" -eq 2 ]] \
    || die "apply requires: <run-id> <key> --readbacks <json>"
  local run_id="${positional[0]}" key="${positional[1]}"
  validate_token "$run_id" "run-id"
  [[ -n "$key" ]] || die "apply: <key> must not be empty."
  [[ -n "$readbacks" ]] || die "apply requires --readbacks <json>"

  fold_run "$run_id"

  local openacts_json
  openacts_json="$(read_openacts "$run_id")"

  local is_open
  if has_jq; then
    is_open="$(jq -r --arg k "$key" 'any(.[]; . == $k)' <<< "$openacts_json")"
  else
    is_open="$(python3 -c '
import json, sys
acts = json.loads(sys.argv[1])
print("true" if sys.argv[2] in acts else "false")
' "$openacts_json" "$key")"
  fi
  [[ "$is_open" == "true" ]] \
    || die "apply: key '${key}' is not an open act for run '${run_id}' (already committed, or never intended) — nothing to reconcile."

  local joined
  joined="$(join_openacts "$run_id" "$(journal_file_for "$run_id")" "[\"${key}\"]")"

  local scenario_id criterion_id persona_id write_set
  if has_jq; then
    scenario_id="$(jq -r '.[0].scenarioId' <<< "$joined")"
    criterion_id="$(jq -r '.[0].criterionId' <<< "$joined")"
    persona_id="$(jq -r '.[0].personaId' <<< "$joined")"
    write_set="$(jq -c '.[0].writeSet' <<< "$joined")"
  else
    scenario_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["scenarioId"])' "$joined")"
    criterion_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["criterionId"])' "$joined")"
    persona_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["personaId"])' "$joined")"
    write_set="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[0]["writeSet"]))' "$joined")"
  fi

  local recon_out
  recon_out="$(QA_ENGINE="$ENGINE" bash "$REBAKE_SH" reconcile "$run_id" "$scenario_id" "$criterion_id" "$persona_id" \
                 --write-set "$write_set" --readbacks "$readbacks")" \
    || die "apply: rebake.sh reconcile failed for run '${run_id}' key '${key}'."

  local summary_line raw_outcome
  summary_line="$(head -n1 <<< "$recon_out")"
  raw_outcome="$(tail -n1 <<< "$recon_out")"

  local final_outcome
  case "$raw_outcome" in
    done|blocked)
      # rebake already journaled the terminal event (act_committed for
      # done, a blocked criterion_verdict for partial->blocked) — this
      # cycle is over for this key regardless of any prior retries.
      clear_attempt "$run_id" "$key"
      final_outcome="$raw_outcome"
      ;;
    deferred:*)
      # rebake journaled nothing (no write-set to verify, or an
      # unconfirmable write-only key) — retrying will not change the
      # outcome, so this is terminal for this cycle too.
      clear_attempt "$run_id" "$key"
      final_outcome="$raw_outcome"
      ;;
    retry)
      local prev_count
      prev_count="$(get_attempt "$run_id" "$key")"
      if [[ "$prev_count" -ge 1 ]]; then
        # SECOND consecutive retry for this key: escalate — journal a
        # blocked verdict ourselves (rebake's "none" outcome journals
        # nothing) naming the key and that re-bake found nothing landed
        # twice in a row. Never loop: apply never returns "retry" twice
        # running for the same key.
        local last_action="qa-reconcile: retry escalated to blocked — two consecutive re-bake attempts found nothing landed for key ${key}"
        local -a ckpt_args=("$run_id" "$criterion_id" "blocked" "--last-action" "$last_action")
        [[ -n "$persona_id" ]] && ckpt_args+=(--persona "$persona_id")
        QA_ENGINE="$ENGINE" bash "$CHECKPOINT_SH" "${ckpt_args[@]}" >/dev/null \
          || die "apply: failed to journal the escalated blocked verdict for run '${run_id}' key '${key}'."
        clear_attempt "$run_id" "$key"
        final_outcome="blocked"
      else
        set_attempt "$run_id" "$key" 1
        final_outcome="retry"
      fi
      ;;
    *)
      die "apply: rebake.sh reconcile returned an unexpected outcome '${raw_outcome}' for run '${run_id}' key '${key}' — refusing to reconcile."
      ;;
  esac

  echo "$summary_line"
  echo "$final_outcome"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: qa-reconcile.sh plan <run-id>
       qa-reconcile.sh apply <run-id> <key> --readbacks <json>"
  local cmd="$1"; shift
  case "$cmd" in
    plan)  cmd_plan "$@" ;;
    apply) cmd_apply "$@" ;;
    *) die "Unknown subcommand '${cmd}' (expected: plan|apply)." ;;
  esac
}

main "$@"
