#!/usr/bin/env bash
# rebake.sh — the D-5 write-set re-bake classifier + reconciler (durable-
# resume Plan B, Task 3). Given a criterion's declared write-set and the
# READ-BACK results a caller already gathered (from the resumed session's
# own browser/probe capability — this script never fetches anything
# itself), classifies the write-set as all-landed / none-landed / partial /
# deferred and, for `reconcile`, journals the outcome. NEVER a silent
# "done" — every non-landed outcome is an explicit retry/blocked/deferred.
#
# USAGE:
#   rebake.sh classify --write-set <json> --readbacks <json>
#       PURE function, no journaling. <write-set>  = a JSON array of
#       write-set members: [{"entity":..,"key":..,"writeOnly"?:bool}, ...].
#       <readbacks> = a JSON array with ONE entry per write-set member:
#       [{"entity":..,"key":..,"found":bool,"value"?:..}, ...] — matched to
#       its write-set member by (entity,key). Prints ONE line of JSON to
#       stdout: {outcome, missing:[...], writeSetSize, foundCount,
#       deferredKeys:[...]}  where `outcome` is exactly one of:
#         landed   — every write-set member's readback has found:true.
#         none     — no write-set member's readback has found:true, and
#                    there are no unconfirmable (writeOnly-unfound) members
#                    either — nothing landed at all, caller should retry.
#         partial  — at least one non-writeOnly ("normal") member is
#                    NOT found; `missing` lists the exact keys of those
#                    NOT-found normal members (a `partial` outcome ALWAYS
#                    has a non-empty `missing`). This fires even when some
#                    writeOnly members are ALSO unconfirmable — the hard
#                    failure (a normal key genuinely missing) always wins
#                    over "can't confirm" (`deferredKeys` is still included
#                    in the output when present).
#         deferred — writeSetSize == 0 (nothing to verify — an empty
#                    write-set must never vacuously read as `landed`), OR
#                    every normal member is found/absent-none AND at least
#                    one write-set member is `writeOnly:true` with its
#                    readback showing found:false (or no matching readback
#                    at all) — i.e. we could not, even in principle,
#                    confirm that member's landing via a read path. Its
#                    key(s) are listed in `deferredKeys`.
#
#       PRECEDENCE (deliberate, first match wins):
#         1. writeSetSize == 0            -> deferred ("no write-set to
#                                             verify"); NEVER `landed`.
#         2. normalMissing != [] AND
#            foundCount == 0 AND
#            deferredKeys == []           -> none (nothing landed at all).
#         3. normalMissing != []          -> partial (a genuinely-missing
#                                             normal key surfaces even if a
#                                             writeOnly member is also
#                                             unconfirmable — the hard
#                                             failure wins over "can't
#                                             confirm").
#         4. deferredKeys != []           -> deferred (only writeOnly
#                                             members are unconfirmable; no
#                                             normal key is missing).
#         5. else                         -> landed (every member found).
#       A writeOnly member whose readback DOES show found:true is NOT
#       deferred-triggering — it counts as a normal found member (a
#       writeOnly member that IS found still counts as landed for that
#       member). `missing` (used by `partial`) never includes a writeOnly
#       key — that key's story is told by `deferredKeys`, not `missing`,
#       because "deferred" and "confirmed missing via a read" are different
#       claims (writeOnly members have no read path to confirm absence
#       with).
#
#   rebake.sh reconcile <run-id> <scenarioId> <criterionId> <personaId> --write-set <json> --readbacks <json>
#       Calls `classify` on the same write-set/readbacks, then:
#         landed   -> journals `act_committed{key,outcome:"landed"}` via
#                     `journal-emit.sh act-commit` (closes the open act —
#                     see Task 2); prints the classify summary, then `done`.
#         none     -> journals NOTHING; prints the classify summary, then
#                     `retry` — the caller is expected to re-drive the act
#                     once (Task 2's bracket again) and call reconcile again.
#         partial  -> journals a `blocked` `criterion_verdict` via
#                     `checkpoint.sh <run> <criterionId> blocked
#                     --last-action "...missing keys..."` (+ `--persona`
#                     when personaId is non-empty) NAMING the exact missing
#                     key(s) in last_action; prints the classify summary,
#                     then `blocked`.
#         deferred -> journals NOTHING; prints the classify summary, then
#                     `deferred: <reason>` — either "no write-set to
#                     verify" (writeSetSize == 0) or a reason naming the
#                     unconfirmable writeOnly key(s).
#       Every branch prints an EXPLICIT outcome word as its final line —
#       there is no code path that reconciles a non-landed write-set and
#       silently returns `done`.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3 (jq preferred; no
# node). Honors QA_ENGINE the same way journal.sh/checkpoint.sh/fold.sh/
# journal-emit.sh do. `reconcile` shells out to journal-emit.sh (act-commit)
# and checkpoint.sh (blocked verdict) ONLY — this script is NEVER a second
# journal writer.
#
# NOTE: all paths are relative to the current working directory (project
# root), same convention as journal.sh/checkpoint.sh/journal-emit.sh.

set -uo pipefail

# ---------------------------------------------------------------------------
# helpers (has_jq/has_py/die/validate_token copied from journal-emit.sh's
# header — same QA_ENGINE-honoring contract)
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

# Fix 28 (mirrors checkpoint.sh's/journal-emit.sh's validate_token exactly):
# reject a run-id that could escape .qa/runs/<run-id>/ when interpolated
# into a path by the scripts this one shells out to.
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

# Locate journal-emit.sh/checkpoint.sh relative to THIS script without
# depending on external `dirname` (pure bash parameter expansion — same
# trick journal-emit.sh/checkpoint.sh use).
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
JOURNAL_EMIT_SH="${SCRIPT_DIR}/journal-emit.sh"
CHECKPOINT_SH="${SCRIPT_DIR}/checkpoint.sh"

# Resolve the engine ONCE, from THIS script's own has_jq (which already
# honors QA_ENGINE), then pass it explicitly to journal-emit.sh/checkpoint.sh
# subprocess calls — same rationale as journal-emit.sh's ENGINE/append_event
# (a leaked jq on PATH can never silently switch engines mid-run). Note
# checkpoint.sh's OWN has_jq does not honor QA_ENGINE for its own JSON
# building (only for the journal.sh/fold.sh subprocesses it drives) — true
# dual-engine parity for the `partial` path therefore requires jq to be
# genuinely absent from PATH (as tests/rebake/run.sh's dual-engine sub-case
# does), not merely QA_ENGINE=python3.
ENGINE="python3"
has_jq && ENGINE="jq"

# ---------------------------------------------------------------------------
# shape validation — dies (nothing computed/journaled) before any classify
# or journal write, same "fail before any write" discipline as journal-
# emit.sh's validate_plan_json.
# ---------------------------------------------------------------------------

validate_write_set_shape() {
  local write_set="$1"
  if has_jq; then
    jq -e '
      type == "array"
      and all(.[];
        type == "object"
        and (has("entity") and (.entity | type == "string") and (.entity | length > 0))
        and (has("key") and (.key | type == "string") and (.key | length > 0))
      )
    ' >/dev/null 2>&1 <<< "$write_set" \
      || die "--write-set must be a JSON array of {entity,key,writeOnly?} objects (non-empty string entity+key): ${write_set}"
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)
if not isinstance(d, list):
    sys.exit(1)
for m in d:
    if not isinstance(m, dict):
        sys.exit(1)
    if not isinstance(m.get("entity"), str) or not m.get("entity"):
        sys.exit(1)
    if not isinstance(m.get("key"), str) or not m.get("key"):
        sys.exit(1)
sys.exit(0)
' "$write_set" \
      || die "--write-set must be a JSON array of {entity,key,writeOnly?} objects (non-empty string entity+key): ${write_set}"
  else
    die "rebake.sh needs either 'jq' or 'python3' to validate --write-set."
  fi
}

validate_readbacks_shape() {
  local readbacks="$1"
  if has_jq; then
    jq -e '
      type == "array"
      and all(.[];
        type == "object"
        and (has("entity") and (.entity | type == "string") and (.entity | length > 0))
        and (has("key") and (.key | type == "string") and (.key | length > 0))
        and (has("found") and (.found | type == "boolean"))
      )
    ' >/dev/null 2>&1 <<< "$readbacks" \
      || die "--readbacks must be a JSON array of {entity,key,found:bool,value?} objects: ${readbacks}"
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)
if not isinstance(d, list):
    sys.exit(1)
for r in d:
    if not isinstance(r, dict):
        sys.exit(1)
    if not isinstance(r.get("entity"), str) or not r.get("entity"):
        sys.exit(1)
    if not isinstance(r.get("key"), str) or not r.get("key"):
        sys.exit(1)
    if not isinstance(r.get("found"), bool):
        sys.exit(1)
sys.exit(0)
' "$readbacks" \
      || die "--readbacks must be a JSON array of {entity,key,found:bool,value?} objects: ${readbacks}"
  else
    die "rebake.sh needs either 'jq' or 'python3' to validate --readbacks."
  fi
}

# ---------------------------------------------------------------------------
# classify_jq/classify_py <write-set-json> <readbacks-json> -> stdout ONE
# line of JSON: {outcome, missing, writeSetSize, foundCount, deferredKeys}.
# Both implementations MUST stay semantically identical (dual-engine
# equivalence is a binding constraint) — see the precedence note in the
# header comment above.
# ---------------------------------------------------------------------------

classify_jq() {
  local write_set="$1" readbacks="$2"
  jq -cn --argjson ws "$write_set" --argjson rb "$readbacks" '
    ($ws | length) as $writeSetSize
    | ($ws | map(
        . as $m
        | ($rb | map(select(.entity == $m.entity and .key == $m.key)) | first) as $match
        | { key: $m.key,
            writeOnly: ($m.writeOnly // false),
            found: (if $match == null then false else ($match.found // false) end) }
      )) as $joined
    | ($joined | map(select(.found == true)) | length) as $foundCount
    | ($joined | map(select(.found == false and .writeOnly == false) | .key)) as $normalMissing
    | ($joined | map(select(.found == false and .writeOnly == true) | .key)) as $deferredKeys
    | if $writeSetSize == 0 then
        # Rule 1: an empty write-set has nothing to verify — deferred,
        # NEVER landed (never vacuously completes an unverified mutation).
        { outcome: "deferred", missing: [], writeSetSize: 0, foundCount: 0, deferredKeys: [] }
      elif ($normalMissing | length) > 0 and $foundCount == 0 and ($deferredKeys | length) == 0 then
        # Rule 2: nothing landed at all (no found, no unconfirmable either).
        { outcome: "none", missing: $normalMissing, writeSetSize: $writeSetSize, foundCount: 0, deferredKeys: [] }
      elif ($normalMissing | length) > 0 then
        # Rule 3: a genuinely-missing normal key wins over "cannot confirm".
        { outcome: "partial", missing: $normalMissing, writeSetSize: $writeSetSize, foundCount: $foundCount, deferredKeys: $deferredKeys }
      elif ($deferredKeys | length) > 0 then
        # Rule 4: only writeOnly-unfound members remain unconfirmable.
        { outcome: "deferred", missing: [], writeSetSize: $writeSetSize, foundCount: $foundCount, deferredKeys: $deferredKeys }
      else
        # Rule 5: every member found.
        { outcome: "landed", missing: [], writeSetSize: $writeSetSize, foundCount: $foundCount, deferredKeys: [] }
      end
  ' || die "classify: jq failed to classify --write-set/--readbacks."
}

classify_py() {
  local write_set="$1" readbacks="$2"
  python3 -c '
import json, sys

ws = json.loads(sys.argv[1])
rb = json.loads(sys.argv[2])

def find_match(m):
    for r in rb:
        if r.get("entity") == m.get("entity") and r.get("key") == m.get("key"):
            return r
    return None

joined = []
for m in ws:
    match = find_match(m)
    found = bool(match.get("found", False)) if match else False
    joined.append({"key": m.get("key"), "writeOnly": bool(m.get("writeOnly", False)), "found": found})

write_set_size = len(ws)
found_count = sum(1 for j in joined if j["found"])
normal_missing = [j["key"] for j in joined if (not j["found"]) and (not j["writeOnly"])]
deferred_keys = [j["key"] for j in joined if (not j["found"]) and j["writeOnly"]]

if write_set_size == 0:
    # Rule 1: an empty write-set has nothing to verify — deferred, NEVER
    # landed (never vacuously completes an unverified mutation).
    outcome = "deferred"
    missing = []
    found_count = 0
    deferred_keys = []
elif normal_missing and found_count == 0 and not deferred_keys:
    # Rule 2: nothing landed at all (no found, no unconfirmable either).
    outcome = "none"
    missing = normal_missing
elif normal_missing:
    # Rule 3: a genuinely-missing normal key wins over "cannot confirm".
    outcome = "partial"
    missing = normal_missing
elif deferred_keys:
    # Rule 4: only writeOnly-unfound members remain unconfirmable.
    outcome = "deferred"
    missing = []
else:
    # Rule 5: every member found.
    outcome = "landed"
    missing = []

print(json.dumps({
    "outcome": outcome,
    "missing": missing,
    "writeSetSize": write_set_size,
    "foundCount": found_count,
    "deferredKeys": deferred_keys,
}))
' "$write_set" "$readbacks" || die "classify: python3 failed to classify --write-set/--readbacks."
}

classify_summary() {
  local write_set="$1" readbacks="$2"
  if has_jq; then
    classify_jq "$write_set" "$readbacks"
  elif has_py; then
    classify_py "$write_set" "$readbacks"
  else
    die "rebake.sh needs either 'jq' or 'python3' to classify."
  fi
}

# ---------------------------------------------------------------------------
# small readers over a classify summary blob (used by reconcile)
# ---------------------------------------------------------------------------

summary_field() {
  local summary="$1" field="$2"
  if has_jq; then
    jq -r --arg f "$field" '.[$f]' <<< "$summary"
  else
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(d.get(sys.argv[2], ""))
' "$summary" "$field"
  fi
}

summary_missing_csv() {
  local summary="$1"
  if has_jq; then
    jq -r '.missing | join(", ")' <<< "$summary"
  else
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(", ".join(d.get("missing") or []))
' "$summary"
  fi
}

summary_deferred_keys_csv() {
  local summary="$1"
  if has_jq; then
    jq -r '.deferredKeys | join(", ")' <<< "$summary"
  else
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(", ".join(d.get("deferredKeys") or []))
' "$summary"
  fi
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

cmd_classify() {
  local write_set="" readbacks=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --write-set)
        [[ $# -lt 2 ]] && die "classify: --write-set requires a value."
        write_set="$2"; shift 2 ;;
      --readbacks)
        [[ $# -lt 2 ]] && die "classify: --readbacks requires a value."
        readbacks="$2"; shift 2 ;;
      *) die "classify: unknown option: $1" ;;
    esac
  done
  [[ -n "$write_set" ]] || die "classify requires --write-set <json>"
  [[ -n "$readbacks" ]] || die "classify requires --readbacks <json>"
  validate_write_set_shape "$write_set"
  validate_readbacks_shape "$readbacks"

  classify_summary "$write_set" "$readbacks"
}

cmd_reconcile() {
  local write_set="" readbacks=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --write-set)
        [[ $# -lt 2 ]] && die "reconcile: --write-set requires a value."
        write_set="$2"; shift 2 ;;
      --readbacks)
        [[ $# -lt 2 ]] && die "reconcile: --readbacks requires a value."
        readbacks="$2"; shift 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ "${#positional[@]}" -eq 4 ]] \
    || die "reconcile requires: <run-id> <scenarioId> <criterionId> <personaId> --write-set <json> --readbacks <json>"
  local run_id="${positional[0]}" scenario_id="${positional[1]}" criterion_id="${positional[2]}" persona_id="${positional[3]}"
  validate_token "$run_id" "run-id"
  [[ -n "$scenario_id" ]] || die "scenarioId must not be empty."
  [[ -n "$criterion_id" ]] || die "criterionId must not be empty."
  [[ -n "$write_set" ]] || die "reconcile requires --write-set <json>"
  [[ -n "$readbacks" ]] || die "reconcile requires --readbacks <json>"
  validate_write_set_shape "$write_set"
  validate_readbacks_shape "$readbacks"

  local summary
  summary="$(classify_summary "$write_set" "$readbacks")" || die "reconcile: classify failed."

  local outcome
  outcome="$(summary_field "$summary" outcome)"

  echo "$summary"

  case "$outcome" in
    landed)
      QA_ENGINE="$ENGINE" bash "$JOURNAL_EMIT_SH" act-commit "$run_id" "$scenario_id" "$criterion_id" "$persona_id" --outcome landed >/dev/null \
        || die "reconcile: failed to journal act_committed for the landed outcome (run=${run_id} scenario=${scenario_id} criterion=${criterion_id})."
      echo "done"
      ;;
    none)
      # Journal NOTHING: the caller (Task 4's qa-reconcile.sh) is expected to
      # re-drive the act once (Task 2's act-intent/act-commit bracket again)
      # and call reconcile a second time — a second `none` is THAT caller's
      # escalate-to-blocked decision, not this script's.
      echo "retry"
      ;;
    partial)
      local missing_csv
      missing_csv="$(summary_missing_csv "$summary")"
      local last_action="re-bake: partial landing — missing key(s): ${missing_csv}"
      local -a ckpt_args=("$run_id" "$criterion_id" "blocked" "--last-action" "$last_action")
      [[ -n "$persona_id" ]] && ckpt_args+=(--persona "$persona_id")
      QA_ENGINE="$ENGINE" bash "$CHECKPOINT_SH" "${ckpt_args[@]}" >/dev/null \
        || die "reconcile: failed to journal the blocked verdict for the partial outcome (run=${run_id} criterion=${criterion_id})."
      echo "blocked"
      ;;
    deferred)
      # Journal NOTHING: either there was no write-set to verify at all, or
      # a deferred write-set member has no read path — either way there is
      # nothing new to record — the criterion's own verdict (already logged
      # with --nonui-reason if applicable) stands.
      local write_set_size
      write_set_size="$(summary_field "$summary" writeSetSize)"
      if [[ "$write_set_size" == "0" ]]; then
        echo "deferred: no write-set to verify"
      else
        local deferred_csv
        deferred_csv="$(summary_deferred_keys_csv "$summary")"
        echo "deferred: write-only key(s) with no read path could not be confirmed: ${deferred_csv}"
      fi
      ;;
    *)
      die "reconcile: classify returned an unexpected outcome '${outcome}' for run=${run_id} criterion=${criterion_id} — refusing to reconcile."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: rebake.sh classify --write-set <json> --readbacks <json>
       rebake.sh reconcile <run-id> <scenarioId> <criterionId> <personaId> --write-set <json> --readbacks <json>"
  local cmd="$1"; shift
  case "$cmd" in
    classify)  cmd_classify "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    *) die "Unknown subcommand '${cmd}' (expected: classify|reconcile)." ;;
  esac
}

main "$@"
