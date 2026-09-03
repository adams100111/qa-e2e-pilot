#!/usr/bin/env bash
# journal-emit.sh — the single emission entrypoint for the start/plan events
# Plan A's journal/fold substrate defined but left unfed (durable-resume Plan
# B, Task 1). Every subcommand below builds one event JSON blob and appends
# it via `journal.sh append` — this script NEVER writes journal.ndjson
# itself (no second journal writer).
#
# USAGE:
#   journal-emit.sh started <run-id> <scenarioId> <criterionId> <personaId>
#       Journals a `criterion_started{scenarioId,criterionId,personaId}`
#       event. Caller convention (matches checkpoint.sh's ADR-0012 identity):
#       for a persona-scoped criterion, scenarioId == personaId; for a
#       shared criterion, scenarioId == "__shared__" and personaId == "" —
#       so this tuple's key matches the criterion_verdict checkpoint.sh will
#       later journal for the SAME (criterion, persona) pair.
#
#   journal-emit.sh freeze <run-id> <plan-json> [--force]
#       Journals a `plan_frozen{criteria:[{criterionId,scenarioId,personaId,
#       mutates,writeSet?}], order:[criterionId,...]}` event — <plan-json>
#       must be a JSON object with `criteria` (array of objects) and `order`
#       (array). IDEMPOTENT GUARD: if a `plan_frozen` already exists in this
#       run's journal, this call does NOT append a second one (that would be
#       fold.jq's duplicate-plan-frozen anomaly) — instead it emits one
#       `plan_amended` event per criterion tuple in <plan-json> that isn't
#       already part of the frozen plan (or a prior amendment). Pass
#       --force to append a second plan_frozen anyway (deliberately
#       reproduces the duplicate-plan-frozen anomaly — an escape hatch, not
#       the default path).
#
#   journal-emit.sh amend <run-id> <criterionId> <scenarioId> <personaId> <mutates>
#       Journals a `plan_amended{criterionId,scenarioId,personaId,mutates}`
#       event directly. <mutates> must be the literal string "true" or
#       "false".
#
#   journal-emit.sh act-intent <run-id> <scenarioId> <criterionId> <personaId> --criterion <criterion-json> --write-set <json> [--force]
#       DERIVE-GATED (durable-resume Plan B, Task 2): runs
#       `mutation-flag.sh derive <criterion-json>` (Plan A's deterministic,
#       agent-untrusted mutation classifier — see mutation-flag.sh). Only
#       when it prints "true" does this journal
#       `act_intent{key:"<run-id>:<scenarioId>:<criterionId>",writeSet:<json>}`
#       — the composite key is ALWAYS `runId:scenarioId:criterionId` (never
#       per-attempt), matching the SAME key `act-commit` below must use for
#       this tuple. When derive prints "false" this is a NO-OP: nothing is
#       journaled, exit 0, and "SKIP non-mutating: ..." is printed (so a
#       non-mutating criterion's act phase never becomes an open act for
#       Task 4's resume reconciliation to trip over). Call this immediately
#       BEFORE the criterion's act (the human-path UI interaction).
#       Run FSM Enforcement Task 4: a cooperative, best-effort transition
#       guard (see guard_transition below) declines this call (nothing
#       appended, non-zero exit) unless a `criterion_started` already exists
#       for this exact scenario/criterion/persona tuple; pass --force to
#       bypass (logged NOTE on stderr). Not a hard cage — qa-verify's
#       phase-surface pass (Task 3) is the real authority.
#
#   journal-emit.sh act-commit <run-id> <scenarioId> <criterionId> <personaId> --outcome <landed|failed|unknown> [--force]
#       Journals `act_committed{key:"<run-id>:<scenarioId>:<criterionId>",outcome}`
#       unconditionally — NO derive gate here: the caller only ever calls
#       act-commit for a tuple whose act-intent it already emitted (derive
#       already gated at intent time), so a matching commit must always be
#       emittable. Call this immediately AFTER the act completes. A crash
#       between act-intent and act-commit leaves the intent's key in
#       fold.sh's `openActs` (an intent with no matching commit) — that is
#       precisely the durable resume signal Task 4's reconciliation
#       consumes.
#       Run FSM Enforcement Task 4: the same cooperative guard declines this
#       call (nothing appended, non-zero exit) unless a matching `act_intent`
#       already exists for this tuple's `runId:scenarioId:criterionId` key;
#       pass --force to bypass (logged NOTE on stderr). Best-effort only.
#
# `.qa/runs/latest`: whichever of the subcommands above turns out to be the
# FIRST event of a run (the journal did not exist/was empty before this
# call) also (a) journals a `run_started{runId}` event BEFORE its own
# event, and (b) atomic-writes `.qa/runs/latest` — a one-line file holding
# the run-id — via the write_latest helper below. checkpoint.sh's own
# run_started branch does both identically, so checkpoint.json/cursor.json's
# `run_id` and `.qa/runs/latest` are both set correctly regardless of
# whether a run starts verdict-first (checkpoint.sh) or emit-first
# (journal-emit.sh freeze/started/amend/act-intent/act-commit — the common
# live-run case, since `freeze` runs at the Generate->Verify boundary, well
# before any criterion's first checkpoint.sh call).
#
# DEPENDENCIES: bash, coreutils (mkdir, mv, cat), and EITHER jq OR python3
# for safe JSON handling (jq preferred; python3 used as fallback). No node.
# Honors QA_ENGINE the same way journal.sh/checkpoint.sh/fold.sh do.
#
# NOTE: all paths are relative to the current working directory (project
# root), same convention as journal.sh/checkpoint.sh/fold.sh.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

# ---------------------------------------------------------------------------
# helpers (has_jq/has_py/die copied from journal.sh's header — same
# QA_ENGINE-honoring contract)
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

# Fix 28 (mirrors checkpoint.sh's validate_token exactly): reject a run-id
# that could escape .qa/runs/<run-id>/ when interpolated into a path.
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

# Locate journal.sh relative to THIS script without depending on external
# `dirname` (pure bash parameter expansion — same trick checkpoint.sh uses,
# so a restricted test PATH doesn't break self-location).
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
JOURNAL_SH="${SCRIPT_DIR}/journal.sh"
MUTATION_FLAG_SH="${SCRIPT_DIR}/mutation-flag.sh"
# Run FSM Enforcement Task 4: state-machine.json (Task 1's statechart-as-
# data), resolved relative to THIS script like JOURNAL_SH/MUTATION_FLAG_SH
# above — but, unlike fold.sh's identical-looking constant, OVERRIDABLE via
# the STATE_MACHINE_JSON env var (tests use this to point at a temp copy
# with an edited legalSubStateEdges, proving the guard below is genuinely
# data-driven, and to simulate "file absent" without touching the real
# shipped reference file). See guard_transition's header comment for the
# absent-file posture (skip, never die — deliberately DIFFERENT from
# fold.sh's die-on-missing, because this guard is best-effort, not the
# authority).
STATE_MACHINE_JSON="${STATE_MACHINE_JSON:-${SCRIPT_DIR}/../references/state-machine.json}"

# Resolve the engine ONCE, from checkpoint.sh's/journal.sh's own has_jq
# (which already honors QA_ENGINE) — then pass it explicitly to every
# journal.sh subprocess call, so a leaked jq on PATH can never silently
# switch engines mid-run (same rationale as checkpoint.sh's ext_path/eng).
ENGINE="python3"
has_jq && ENGINE="jq"

journal_path_for() {
  echo "${QA_BASE}/${1}/journal.ndjson"
}

append_event() {
  local run_id="$1" event_json="$2"
  QA_ENGINE="$ENGINE" "$BASH" "$JOURNAL_SH" append "$run_id" "$event_json" \
    || die "journal-emit.sh: failed to append event to the journal for run '${run_id}': ${event_json}"
}

# ---------------------------------------------------------------------------
# write_latest <run-id> — atomic-write .qa/runs/latest (a ONE-LINE plain
# text file, NOT JSON) holding the run-id. temp-in-same-dir + rename is
# POSIX-atomic w.r.t. concurrent readers; fsync the temp file when python3
# is available (same durability posture as journal.sh's atomic_write, minus
# the JSON canonicalization step — this file is deliberately plain text).
#
# PATH note: mv/rm need to be reachable even under a deliberately
# restricted test PATH — append (never prepend) the real bash binary's own
# directory as a fallback for just this function's duration (mirrors
# checkpoint.sh's identical ext_path technique for its journal.sh/fold.sh
# subprocess calls).
# ---------------------------------------------------------------------------
write_latest() {
  local run_id="$1"
  local saved_path="$PATH"
  PATH="${PATH}:${BASH%/*}"
  mkdir -p "$QA_BASE"
  local dest="${QA_BASE}/latest"
  local tmp="${dest}.tmp.$$"
  if ! printf '%s\n' "$run_id" > "$tmp"; then
    rm -f "$tmp"
    PATH="$saved_path"
    die "write_latest: failed to write temp file ${tmp}."
  fi
  if has_py; then
    python3 -c '
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$tmp" 2>/dev/null || true
  fi
  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    PATH="$saved_path"
    die "write_latest: failed to move ${tmp} -> ${dest} (disk full or permission error?)."
  fi
  PATH="$saved_path"
}

# ---------------------------------------------------------------------------
# event builders
# ---------------------------------------------------------------------------

build_run_started_event() {
  local run_id="$1"
  if has_jq; then
    jq -cn --arg runId "$run_id" '{event: "run_started", runId: $runId}' \
      || die "Failed to build the run_started event via jq."
  elif has_py; then
    python3 -c '
import json, sys
print(json.dumps({"event": "run_started", "runId": sys.argv[1]}))
' "$run_id" || die "Failed to build the run_started event via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to build journal events."
  fi
}

build_criterion_started_event() {
  local scenario="$1" crit="$2" persona="$3"
  if has_jq; then
    jq -cn --arg scenarioId "$scenario" --arg criterionId "$crit" --arg personaId "$persona" \
      '{event: "criterion_started", scenarioId: $scenarioId, criterionId: $criterionId, personaId: $personaId}' \
      || die "Failed to build the criterion_started event via jq."
  elif has_py; then
    python3 -c '
import json, sys
print(json.dumps({"event": "criterion_started", "scenarioId": sys.argv[1], "criterionId": sys.argv[2], "personaId": sys.argv[3]}))
' "$scenario" "$crit" "$persona" || die "Failed to build the criterion_started event via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to build journal events."
  fi
}

build_plan_frozen_event() {
  local plan="$1"
  if has_jq; then
    jq -cn --argjson plan "$plan" '{event: "plan_frozen", criteria: $plan.criteria, order: $plan.order}' \
      || die "Failed to build the plan_frozen event via jq."
  elif has_py; then
    python3 -c '
import json, sys
plan = json.loads(sys.argv[1])
print(json.dumps({"event": "plan_frozen", "criteria": plan.get("criteria"), "order": plan.get("order")}))
' "$plan" || die "Failed to build the plan_frozen event via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to build journal events."
  fi
}

build_plan_amended_event() {
  local scenario="$1" crit="$2" persona="$3" mutates="$4"
  if has_jq; then
    jq -cn --arg scenarioId "$scenario" --arg criterionId "$crit" --arg personaId "$persona" --argjson mutates "$mutates" \
      '{event: "plan_amended", criterionId: $criterionId, scenarioId: $scenarioId, personaId: $personaId, mutates: $mutates}' \
      || die "Failed to build the plan_amended event via jq."
  elif has_py; then
    python3 -c '
import json, sys
print(json.dumps({"event": "plan_amended", "criterionId": sys.argv[1], "scenarioId": sys.argv[2], "personaId": sys.argv[3], "mutates": sys.argv[4] == "true"}))
' "$crit" "$scenario" "$persona" "$mutates" || die "Failed to build the plan_amended event via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to build journal events."
  fi
}

build_act_intent_event() {
  local key="$1" write_set="$2"
  if has_jq; then
    jq -cn --arg key "$key" --argjson writeSet "$write_set" \
      '{event: "act_intent", key: $key, writeSet: $writeSet}' \
      || die "Failed to build the act_intent event via jq."
  elif has_py; then
    python3 -c '
import json, sys
write_set = json.loads(sys.argv[2])
print(json.dumps({"event": "act_intent", "key": sys.argv[1], "writeSet": write_set}))
' "$key" "$write_set" || die "Failed to build the act_intent event via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to build journal events."
  fi
}

build_act_committed_event() {
  local key="$1" outcome="$2"
  if has_jq; then
    jq -cn --arg key "$key" --arg outcome "$outcome" \
      '{event: "act_committed", key: $key, outcome: $outcome}' \
      || die "Failed to build the act_committed event via jq."
  elif has_py; then
    python3 -c '
import json, sys
print(json.dumps({"event": "act_committed", "key": sys.argv[1], "outcome": sys.argv[2]}))
' "$key" "$outcome" || die "Failed to build the act_committed event via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to build journal events."
  fi
}

# ---------------------------------------------------------------------------
# validate_write_set_json <json> — dies (nothing appended) unless <json>
# parses as valid JSON. Same "fail before any write" discipline as
# validate_plan_json. Deliberately permissive on shape beyond "valid JSON"
# (the documented shape is an array of {entity,key,...} objects, but this
# script's job is passthrough, not schema enforcement of the write-set
# contents — rebake.sh, Task 3, is where write-set member shape matters).
# ---------------------------------------------------------------------------
validate_write_set_json() {
  local write_set="$1"
  if has_jq; then
    jq -e '.' >/dev/null 2>&1 <<< "$write_set" \
      || die "act-intent: --write-set must be valid JSON: ${write_set}"
  elif has_py; then
    python3 -c '
import json, sys
try:
    json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)
' "$write_set" \
      || die "act-intent: --write-set must be valid JSON: ${write_set}"
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to validate --write-set."
  fi
}

# ---------------------------------------------------------------------------
# plan-json validation — {criteria:[{criterionId,scenarioId,personaId,
# mutates,writeSet?}], order:[...]}. Dies (nothing appended) on a malformed
# shape, same "fail before any write" discipline as journal.sh's own event
# envelope check.
# ---------------------------------------------------------------------------
validate_plan_json() {
  local plan="$1"
  if has_jq; then
    jq -e '
      type == "object"
      and (has("criteria") and (.criteria | type == "array"))
      and (has("order") and (.order | type == "array"))
      and (.criteria | all(type == "object" and has("criterionId") and has("scenarioId") and has("personaId") and has("mutates")))
    ' >/dev/null 2>&1 <<< "$plan" \
      || die "freeze: plan-json must be {criteria:[{criterionId,scenarioId,personaId,mutates,writeSet?}],order:[criterionId,...]}: ${plan}"
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
if not isinstance(d.get("criteria"), list) or not isinstance(d.get("order"), list):
    sys.exit(1)
for c in d["criteria"]:
    if not isinstance(c, dict):
        sys.exit(1)
    for k in ("criterionId", "scenarioId", "personaId", "mutates"):
        if k not in c:
            sys.exit(1)
sys.exit(0)
' "$plan" \
      || die "freeze: plan-json must be {criteria:[{criterionId,scenarioId,personaId,mutates,writeSet?}],order:[criterionId,...]}: ${plan}"
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to validate plan-json."
  fi
}

# true (exit 0) iff run <run-id>'s journal already contains a plan_frozen
# event. Line-by-line (never a single-slurp parse) so one torn/malformed
# line can't abort the whole scan — mirrors journal.sh's own next_seq_generic
# reader.
plan_frozen_exists() {
  local run_id="$1"
  local journal_path; journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || return 1
  local line
  if has_jq; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      jq -e 'type == "object" and .event == "plan_frozen"' >/dev/null 2>&1 <<< "$line" && return 0
    done < "$journal_path"
    return 1
  elif has_py; then
    python3 -c '
import json, sys
found = False
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and obj.get("event") == "plan_frozen":
            found = True
            break
sys.exit(0 if found else 1)
' "$journal_path"
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to scan the journal."
  fi
}

# Every (scenarioId,criterionId,personaId) tuple ALREADY covered by this
# run's frozen plan(s) or a prior amendment — "scenarioId|criterionId|personaId"
# strings, deduped. Used by emit_amendments_for_new_criteria to decide which
# tuples in a re-supplied plan-json are genuinely NEW.
known_plan_tuples() {
  local run_id="$1"
  local journal_path; journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || { echo "[]"; return 0; }
  local line acc="[]"
  if has_jq; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      acc="$(jq -c --argjson acc "$acc" '
        ($acc) as $a
        | if .event == "plan_frozen" then
            $a + [ (.criteria // [])[] | (.scenarioId // "") + "|" + (.criterionId // "") + "|" + (.personaId // "") ]
          elif .event == "plan_amended" then
            $a + [ (.scenarioId // "") + "|" + (.criterionId // "") + "|" + (.personaId // "") ]
          else $a end
      ' <<< "$line" 2>/dev/null)" || continue
    done < "$journal_path"
    jq -c 'unique' <<< "$acc"
  elif has_py; then
    python3 - "$journal_path" <<'PYEOF'
import json, sys
tuples = set()
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        if obj.get("event") == "plan_frozen":
            for c in (obj.get("criteria") or []):
                tuples.add("%s|%s|%s" % (c.get("scenarioId", ""), c.get("criterionId", ""), c.get("personaId", "")))
        elif obj.get("event") == "plan_amended":
            tuples.add("%s|%s|%s" % (obj.get("scenarioId", ""), obj.get("criterionId", ""), obj.get("personaId", "")))
print(json.dumps(sorted(tuples)))
PYEOF
  else
    echo "[]"
  fi
}

# For every tuple in <plan-json>.criteria NOT already in known_plan_tuples,
# append a plan_amended event.
emit_amendments_for_new_criteria() {
  local run_id="$1" plan_json="$2"
  local known; known="$(known_plan_tuples "$run_id")"

  local events_ndjson
  if has_jq; then
    events_ndjson="$(jq -c --argjson known "$known" '
      (.criteria // [])[]
      | select( ( (.scenarioId // "") + "|" + (.criterionId // "") + "|" + (.personaId // "") ) as $t | ($known | index($t)) == null )
      | {event: "plan_amended", criterionId: (.criterionId // ""), scenarioId: (.scenarioId // ""), personaId: (.personaId // ""), mutates: (.mutates // false)}
    ' <<< "$plan_json")" || die "freeze: failed to compute amendments via jq."
  elif has_py; then
    events_ndjson="$(python3 -c '
import json, sys
plan = json.loads(sys.argv[1])
known = set(json.loads(sys.argv[2]))
for c in (plan.get("criteria") or []):
    t = "%s|%s|%s" % (c.get("scenarioId", ""), c.get("criterionId", ""), c.get("personaId", ""))
    if t in known:
        continue
    print(json.dumps({"event": "plan_amended", "criterionId": c.get("criterionId", ""), "scenarioId": c.get("scenarioId", ""), "personaId": c.get("personaId", ""), "mutates": c.get("mutates", False)}))
' "$plan_json" "$known")" || die "freeze: failed to compute amendments via python3."
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to compute amendments."
  fi

  if [[ -z "$events_ndjson" ]]; then
    echo "NOTE: freeze: plan_frozen already exists for run '${run_id}' and every criterion in this plan-json is already known — nothing amended." >&2
    return 0
  fi

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    append_event "$run_id" "$line"
  done <<< "$events_ndjson"
}

# ---------------------------------------------------------------------------
# Run FSM Enforcement Task 4: cooperative transition guard (best-effort — the
# real authority is qa-verify's phase-surface pass, Task 3; this only makes
# journal-emit DECLINE TO APPEND an obviously-illegal sub-state edge before
# act-intent/act-commit). Never a hard cage, never a hard-coded edge table —
# every check below reads legalSubStateEdges/guards from STATE_MACHINE_JSON.
#
# infer_tuple_substate <run-id> <scenarioId> <criterionId> <personaId> --
# mirrors fold.sh/fold.jq/fold.py's OWN sub-state inference exactly (see
# their "cursor subState" / illegal-edge blocks): a tuple with a
# criterion_verdict event anywhere is "verdict"; else, if it has a
# criterion_started event (matched on the full scenarioId+criterionId+
# personaId triple, same match fold's tuple_key uses), its state is "baking"
# when an act_committed exists for the persona-blind act key
# "runId:scenarioId:criterionId", else "acting" when an act_intent exists for
# that key, else "arranging"; a tuple with NEITHER a criterion_started NOR a
# criterion_verdict event is "pending" (fold's cursor computes the identical
# default for "not present in groups"). All four existence checks are
# order-insensitive full-journal scans (a key/tuple "seen anywhere" counts,
# exactly like fold's intent_set/committed_set, never merely "seen so far")
# and, like plan_frozen_exists/known_plan_tuples above, read the journal
# line-by-line so one torn/malformed line can't abort the scan. A run with no
# journal file at all is "pending" (no scan needed).
# ---------------------------------------------------------------------------
infer_tuple_substate() {
  local run_id="$1" scenario_id="$2" criterion_id="$3" persona_id="$4"
  local journal_path; journal_path="$(journal_path_for "$run_id")"
  local ak="${run_id}:${scenario_id}:${criterion_id}"

  if [[ ! -s "$journal_path" ]]; then
    echo "pending"
    return 0
  fi

  local has_started=0 has_verdict=0 has_intent=0 has_committed=0 line flag
  if has_jq; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      flag="$(jq -r --arg sid "$scenario_id" --arg cid "$criterion_id" --arg pid "$persona_id" --arg ak "$ak" '
        if type != "object" then "skip"
        elif .event == "criterion_started" and (.scenarioId // "") == $sid and (.criterionId // "") == $cid and (.personaId // "") == $pid then "started"
        elif .event == "criterion_verdict" and (.scenarioId // "") == $sid and (.criterionId // "") == $cid and (.personaId // "") == $pid then "verdict"
        elif .event == "act_intent" and (.key // "") == $ak then "intent"
        elif .event == "act_committed" and (.key // "") == $ak then "committed"
        else "skip" end
      ' <<< "$line" 2>/dev/null)" || flag="skip"
      case "$flag" in
        started) has_started=1 ;;
        verdict) has_verdict=1 ;;
        intent) has_intent=1 ;;
        committed) has_committed=1 ;;
      esac
    done < "$journal_path"
  elif has_py; then
    local py_out
    py_out="$(python3 -c '
import json, sys
path, sid, cid, pid, ak = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
has_started = has_verdict = has_intent = has_committed = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        ev = obj.get("event")
        if ev == "criterion_started" and obj.get("scenarioId", "") == sid and obj.get("criterionId", "") == cid and obj.get("personaId", "") == pid:
            has_started = 1
        elif ev == "criterion_verdict" and obj.get("scenarioId", "") == sid and obj.get("criterionId", "") == cid and obj.get("personaId", "") == pid:
            has_verdict = 1
        elif ev == "act_intent" and obj.get("key", "") == ak:
            has_intent = 1
        elif ev == "act_committed" and obj.get("key", "") == ak:
            has_committed = 1
print(has_started, has_verdict, has_intent, has_committed)
' "$journal_path" "$scenario_id" "$criterion_id" "$persona_id" "$ak")" || py_out="0 0 0 0"
    read -r has_started has_verdict has_intent has_committed <<< "$py_out"
  else
    die "journal-emit.sh needs either 'jq' or 'python3' to infer sub-state for the transition guard."
  fi

  if [[ "$has_verdict" -eq 1 ]]; then
    echo "verdict"
  elif [[ "$has_started" -eq 1 ]]; then
    if [[ "$has_committed" -eq 1 ]]; then
      echo "baking"
    elif [[ "$has_intent" -eq 1 ]]; then
      echo "acting"
    else
      echo "arranging"
    fi
  else
    echo "pending"
  fi
}

# legal_predecessors_for <to-substate> <guard-requires-label> -- prints, one
# per line, every `from` sub-state that is BOTH (a) a member of
# STATE_MACHINE_JSON's legalSubStateEdges as [from,<to-substate>], AND (b)
# the `edge` of a `guards` entry whose `requires` equals <guard-requires-
# label>. Intersecting on the guard label (not just "any edge to
# <to-substate>") matters because legalSubStateEdges can legally reach the
# SAME <to-substate> via more than one guarded edge for different reasons —
# e.g. "baking" is reachable both via [arranging,baking] (guard: not-mutates
# — the non-mutating criterion's read-back path, which never journals
# act_intent/act_committed at all) and [acting,baking] (guard: act_committed
# — the mutating path this file's cmd_act_commit implements). Filtering by
# guard label is what correctly excludes "arranging" as a legal predecessor
# for an act_committed event while still reading the edge list from JSON
# (never a hard-coded "arranging"/"acting" literal divorced from it) —
# editing legalSubStateEdges to drop an edge changes this function's output.
# Returns rc 1 (empty output) when STATE_MACHINE_JSON is missing/unreadable/
# invalid JSON — the caller (guard_transition) treats that as "cannot judge,
# skip the guard entirely", never as "no predecessor is legal".
legal_predecessors_for() {
  local to_state="$1" guard_label="$2"
  [[ -r "$STATE_MACHINE_JSON" ]] || return 1
  if has_jq; then
    jq -e -r --arg to "$to_state" --arg label "$guard_label" '
      [(.legalSubStateEdges // [])[] | select(type=="array" and length==2 and .[1]==$to) | .[0]] as $edge_froms
      | [(.guards // [])[] | select(type=="object" and (.edge|type=="array") and (.edge|length)==2 and .edge[1]==$to and .requires==$label) | .edge[0]] as $guard_froms
      | $edge_froms[] | select(. as $x | $guard_froms | index($x) != null)
    ' "$STATE_MACHINE_JSON" 2>/dev/null
    local rc=$?
    # jq -e's documented exit codes: 0 = last output truthy, 1 = last output
    # false/null, 4 = NO output was ever produced (jq(1): "--exit-status ...
    # or 4 if no valid result was ever produced") — that last one is exactly
    # the LEGITIMATE "no legal predecessor" answer (e.g. test (f)'s edited
    # legalSubStateEdges), NOT a failure. 2/3 (usage error / compile error —
    # e.g. malformed JSON input) are genuine "cannot judge" failures. So
    # 0, 1, and 4 all mean "judged successfully" (with or without output);
    # anything else means the guard cannot judge and must be skipped.
    case "$rc" in
      0|1|4) return 0 ;;
      *) return 1 ;;
    esac
  elif has_py; then
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        sm = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)
to_state, label = sys.argv[2], sys.argv[3]
edges = sm.get("legalSubStateEdges") or []
guards = sm.get("guards") or []
edge_froms = {e[0] for e in edges if isinstance(e, list) and len(e) == 2 and e[1] == to_state}
guard_froms = {
    g["edge"][0] for g in guards
    if isinstance(g, dict) and isinstance(g.get("edge"), list) and len(g["edge"]) == 2
    and g["edge"][1] == to_state and g.get("requires") == label
}
for f in (edge_froms & guard_froms):
    print(f)
' "$STATE_MACHINE_JSON" "$to_state" "$guard_label" 2>/dev/null
  else
    return 1
  fi
}

# guard_transition <run-id> <scenarioId> <criterionId> <personaId>
#   <to-substate> <guard-requires-label> <event-label> <force-flag> <decline-msg>
# Best-effort pre-append guard (Task 4). <decline-msg> may contain the
# literal placeholder "{current}", substituted with the tuple's inferred
# current sub-state. On a legal edge this is a silent no-op (return 0) — the
# caller's append proceeds exactly as before this task. On an illegal edge:
# with --force (force-flag == 1), prints a NOTE to stderr and returns 0
# (bypass, logged); otherwise calls `die` with <decline-msg> — matching this
# file's existing "fail before any write" convention, so nothing is ever
# appended on a decline (not even run_started). When STATE_MACHINE_JSON is
# missing/unreadable (legal_predecessors_for returns rc 1), the guard CANNOT
# judge and is skipped entirely — journal-emit keeps appending exactly as it
# did before this task in that environment (a fold-anomaly path or any other
# context without the reference file present is unaffected).
# ---------------------------------------------------------------------------
guard_transition() {
  local run_id="$1" scenario_id="$2" criterion_id="$3" persona_id="$4"
  local to_state="$5" guard_label="$6" event_label="$7" force="$8" decline_msg="$9"
  local key="${run_id}:${scenario_id}:${criterion_id}"

  local predecessors
  predecessors="$(legal_predecessors_for "$to_state" "$guard_label")" || return 0

  local current; current="$(infer_tuple_substate "$run_id" "$scenario_id" "$criterion_id" "$persona_id")"

  local from_line
  while IFS= read -r from_line; do
    [[ -z "$from_line" ]] && continue
    [[ "$from_line" == "$current" ]] && return 0
  done <<< "$predecessors"

  if [[ "$force" -eq 1 ]]; then
    echo "NOTE: --force: bypassing cooperative transition guard for ${key} (${current}->${event_label})" >&2
    return 0
  fi

  die "${decline_msg//\{current\}/$current}"
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

cmd_started() {
  [[ $# -eq 4 ]] || die "started requires: <run-id> <scenarioId> <criterionId> <personaId>"
  local run_id="$1" scenario_id="$2" criterion_id="$3" persona_id="$4"
  validate_token "$run_id" "run-id"
  [[ -n "$scenario_id" ]] || die "scenarioId must not be empty."
  [[ -n "$criterion_id" ]] || die "criterionId must not be empty."

  local journal_path creating=0
  journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || creating=1

  # This may be the very first thing to touch the journal in a live run
  # (Verify's per-criterion loop can start before checkpoint.sh ever runs a
  # verdict) — emit run_started first, exactly like checkpoint.sh's own
  # run_started branch, so checkpoint.json/cursor.json's run_id is never
  # left null just because journal-emit got there first.
  [[ "$creating" -eq 1 ]] && append_event "$run_id" "$(build_run_started_event "$run_id")"

  local event_json
  event_json="$(build_criterion_started_event "$scenario_id" "$criterion_id" "$persona_id")"
  append_event "$run_id" "$event_json"

  [[ "$creating" -eq 1 ]] && write_latest "$run_id"

  echo "Journaled: criterion_started run=${run_id} scenario=${scenario_id} criterion=${criterion_id} persona=${persona_id}"
}

cmd_freeze() {
  local force=0
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [[ "${#args[@]}" -eq 2 ]] || die "freeze requires: <run-id> <plan-json> [--force]"
  local run_id="${args[0]}" plan_json="${args[1]}"
  validate_token "$run_id" "run-id"
  validate_plan_json "$plan_json"

  local journal_path creating=0
  journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || creating=1

  if [[ "$force" -eq 0 ]] && plan_frozen_exists "$run_id"; then
    # plan_frozen_exists only returns true for a non-empty journal, so
    # creating is guaranteed 0 on this branch — no run_started needed.
    echo "NOTE: freeze: a plan_frozen already exists for run '${run_id}' — emitting plan_amended for any new criteria instead (pass --force to append a second plan_frozen)." >&2
    emit_amendments_for_new_criteria "$run_id" "$plan_json"
  else
    # This is typically the FIRST thing to touch the journal in a live run
    # (freeze runs at the Generate->Verify boundary) — emit run_started
    # first, exactly like checkpoint.sh's own run_started branch, so
    # checkpoint.json/cursor.json's run_id is never left null just because
    # journal-emit got there first.
    [[ "$creating" -eq 1 ]] && append_event "$run_id" "$(build_run_started_event "$run_id")"
    local event_json
    event_json="$(build_plan_frozen_event "$plan_json")"
    append_event "$run_id" "$event_json"
    echo "Journaled: plan_frozen run=${run_id}"
  fi

  [[ "$creating" -eq 1 ]] && write_latest "$run_id"
  return 0
}

cmd_amend() {
  [[ $# -eq 5 ]] || die "amend requires: <run-id> <criterionId> <scenarioId> <personaId> <mutates>"
  local run_id="$1" criterion_id="$2" scenario_id="$3" persona_id="$4" mutates_raw="$5"
  validate_token "$run_id" "run-id"
  [[ -n "$criterion_id" ]] || die "criterionId must not be empty."
  [[ -n "$scenario_id" ]] || die "scenarioId must not be empty."
  local mutates_bool
  case "$mutates_raw" in
    true|false) mutates_bool="$mutates_raw" ;;
    *) die "mutates must be 'true' or 'false' (got '${mutates_raw}')." ;;
  esac

  local journal_path creating=0
  journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || creating=1

  [[ "$creating" -eq 1 ]] && append_event "$run_id" "$(build_run_started_event "$run_id")"

  local event_json
  event_json="$(build_plan_amended_event "$scenario_id" "$criterion_id" "$persona_id" "$mutates_bool")"
  append_event "$run_id" "$event_json"

  [[ "$creating" -eq 1 ]] && write_latest "$run_id"

  echo "Journaled: plan_amended run=${run_id} criterion=${criterion_id} scenario=${scenario_id} persona=${persona_id} mutates=${mutates_bool}"
}

cmd_act_intent() {
  local criterion_json="" write_set_json="" force=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --criterion)
        [[ $# -lt 2 ]] && die "act-intent: --criterion requires a value."
        criterion_json="$2"; shift 2 ;;
      --write-set)
        [[ $# -lt 2 ]] && die "act-intent: --write-set requires a value."
        write_set_json="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ "${#positional[@]}" -eq 4 ]] \
    || die "act-intent requires: <run-id> <scenarioId> <criterionId> <personaId> --criterion <criterion-json> --write-set <json> [--force]"
  local run_id="${positional[0]}" scenario_id="${positional[1]}" criterion_id="${positional[2]}" persona_id="${positional[3]}"
  validate_token "$run_id" "run-id"
  [[ -n "$scenario_id" ]] || die "scenarioId must not be empty."
  [[ -n "$criterion_id" ]] || die "criterionId must not be empty."
  [[ -n "$criterion_json" ]] || die "act-intent requires --criterion <criterion-json>."
  [[ -n "$write_set_json" ]] || die "act-intent requires --write-set <json>."
  validate_write_set_json "$write_set_json"

  # DERIVE-GATED: the mutation flag is decided ONLY by mutation-flag.sh
  # derive's rules (action shape — kinds/httpMethod/verb match), never an
  # agent-supplied boolean. persona_id is unused by derive but kept in the
  # signature for symmetry with started/act-commit and future call sites.
  local mutates
  mutates="$(bash "$MUTATION_FLAG_SH" derive "$criterion_json")" \
    || die "act-intent: mutation-flag.sh derive failed on the supplied --criterion: ${criterion_json}"

  if [[ "$mutates" != "true" ]]; then
    echo "SKIP non-mutating: run=${run_id} scenario=${scenario_id} criterion=${criterion_id} persona=${persona_id}"
    return 0
  fi

  local key="${run_id}:${scenario_id}:${criterion_id}"

  # Run FSM Enforcement Task 4: cooperative transition guard — declines to
  # append act_intent (nothing appended, not even run_started) unless this
  # tuple's inferred sub-state is a legal, [*, "acting"]-guarded ("mutates")
  # predecessor per STATE_MACHINE_JSON's legalSubStateEdges (today, that's
  # only "arranging" — i.e. a prior criterion_started for this exact
  # scenario/criterion/persona). --force bypasses with a logged NOTE. A
  # missing/unreadable STATE_MACHINE_JSON skips this guard entirely (see
  # guard_transition's header comment) — best-effort, never a hard cage; the
  # real authority is qa-verify's phase-surface pass (Task 3).
  guard_transition "$run_id" "$scenario_id" "$criterion_id" "$persona_id" \
    "acting" "mutates" "act_intent" "$force" \
    "illegal edge: act_intent requires a prior criterion_started (tuple is '{current}')"

  local journal_path creating=0
  journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || creating=1

  # act-intent can in principle be the first thing to touch a fresh run's
  # journal (e.g. a resumed/scripted caller), so it follows the same
  # run_started-first convention as started/freeze/amend above.
  [[ "$creating" -eq 1 ]] && append_event "$run_id" "$(build_run_started_event "$run_id")"

  local event_json
  event_json="$(build_act_intent_event "$key" "$write_set_json")"
  append_event "$run_id" "$event_json"

  [[ "$creating" -eq 1 ]] && write_latest "$run_id"

  echo "Journaled: act_intent run=${run_id} key=${key}"
}

cmd_act_commit() {
  local outcome="" force=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --outcome)
        [[ $# -lt 2 ]] && die "act-commit: --outcome requires a value."
        outcome="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ "${#positional[@]}" -eq 4 ]] \
    || die "act-commit requires: <run-id> <scenarioId> <criterionId> <personaId> --outcome <landed|failed|unknown> [--force]"
  local run_id="${positional[0]}" scenario_id="${positional[1]}" criterion_id="${positional[2]}" persona_id="${positional[3]}"
  validate_token "$run_id" "run-id"
  [[ -n "$scenario_id" ]] || die "scenarioId must not be empty."
  [[ -n "$criterion_id" ]] || die "criterionId must not be empty."
  case "$outcome" in
    landed|failed|unknown) ;;
    *) die "act-commit: --outcome must be one of landed|failed|unknown (got '${outcome}')." ;;
  esac

  local key="${run_id}:${scenario_id}:${criterion_id}"

  # Run FSM Enforcement Task 4: cooperative transition guard — declines to
  # append act_committed (nothing appended, not even run_started) unless
  # this tuple's inferred sub-state is a legal, [*, "baking"]-guarded
  # ("act_committed") predecessor per STATE_MACHINE_JSON's
  # legalSubStateEdges (today, that's only "acting" — i.e. a prior
  # act_intent for this SAME run:scenario:criterion key). Note this
  # deliberately excludes "arranging" even though [arranging,baking] is
  # ALSO in legalSubStateEdges — that edge is guarded "not-mutates" (the
  # non-mutating read-back path that never journals act_intent/act_committed
  # at all), a different edge from the "act_committed"-guarded
  # [acting,baking] this subcommand implements; legal_predecessors_for's
  # guard-label filter is what tells them apart (see its header comment).
  # --force bypasses with a logged NOTE. A missing/unreadable
  # STATE_MACHINE_JSON skips this guard entirely — best-effort, never a hard
  # cage; the real authority is qa-verify's phase-surface pass (Task 3).
  guard_transition "$run_id" "$scenario_id" "$criterion_id" "$persona_id" \
    "baking" "act_committed" "act_committed" "$force" \
    "illegal edge: act_committed requires a prior act_intent"

  local journal_path creating=0
  journal_path="$(journal_path_for "$run_id")"
  [[ -s "$journal_path" ]] || creating=1

  # No derive gate here (see the header doc-comment): act-commit is called
  # only for a tuple whose act-intent already ran, but it stays defensively
  # self-contained (own run_started-first handling) rather than assuming
  # the journal is non-empty.
  [[ "$creating" -eq 1 ]] && append_event "$run_id" "$(build_run_started_event "$run_id")"

  local event_json
  event_json="$(build_act_committed_event "$key" "$outcome")"
  append_event "$run_id" "$event_json"

  [[ "$creating" -eq 1 ]] && write_latest "$run_id"

  echo "Journaled: act_committed run=${run_id} key=${key} outcome=${outcome} persona=${persona_id}"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: journal-emit.sh started <run-id> <scenarioId> <criterionId> <personaId>\n       journal-emit.sh freeze <run-id> <plan-json> [--force]\n       journal-emit.sh amend <run-id> <criterionId> <scenarioId> <personaId> <mutates>\n       journal-emit.sh act-intent <run-id> <scenarioId> <criterionId> <personaId> --criterion <criterion-json> --write-set <json> [--force]\n       journal-emit.sh act-commit <run-id> <scenarioId> <criterionId> <personaId> --outcome <landed|failed|unknown> [--force]"
  local cmd="$1"; shift
  case "$cmd" in
    started)    cmd_started "$@" ;;
    freeze)     cmd_freeze "$@" ;;
    amend)      cmd_amend "$@" ;;
    act-intent) cmd_act_intent "$@" ;;
    act-commit) cmd_act_commit "$@" ;;
    *) die "Unknown subcommand '${cmd}' (expected: started|freeze|amend|act-intent|act-commit)." ;;
  esac
}

main "$@"
