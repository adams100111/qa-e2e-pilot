#!/usr/bin/env bash
# cost-summary.sh — per-run cost telemetry (audit-2 W4-3).
#
# USAGE:
#   cost-summary.sh <run-id> [--tokens <n>]
#       Derive a cost summary for .qa/runs/<run-id> and print ONE compact
#       JSON object to stdout. READ-ONLY — never writes any file (mirrors
#       fold.sh's own boundary: run-manifest.json stays agent-authored, see
#       fold.sh's header comment and tests/fold's "fold does NOT create
#       run-manifest.json" case; this script does not either). The caller
#       (per checkpointing-qa-memory/SKILL.md) folds the printed fields into
#       run-manifest.json's own "cost" object as part of its normal
#       agent-authored manifest upkeep, and writing-qa-reports renders them
#       into report.md/report.html's cost block.
#
# WHAT IT COMPUTES:
#   toolCalls               total events in toolstream.jsonl (torn-last-line
#                            tolerant — same convention as fold.sh's journal
#                            parse).
#   criteria                count of DISTINCT criterionId values seen across
#                            journal.ndjson's criterion_started events.
#   toolCallsByCriterion    {criterionId: count} — see ATTRIBUTION below.
#   unattributedToolCalls   tool calls that occurred before the first
#                            criterion_started event (e.g. stack-profile
#                            detection, config bootstrap) or when no journal
#                            exists at all.
#   startedAt / finishedAt  passed through from run-manifest.json's
#                            started_at / ended_at (null if the manifest is
#                            absent or the field isn't set yet — ended_at is
#                            null until the run finishes).
#   tokens                  null unless --tokens <n> is passed (the Claude
#                            harness fills this when usage is exposed to it
#                            — spec W4-3's grill-Q7 decision: tool-calls is
#                            the portable proxy metric, tokens is optional).
#   criteriaBudget           .qa/config.json's criteriaBudget, or the same
#                            default (60) generating-qa-checklist's Step 3
#                            budget guard uses when the config doesn't set
#                            one (docs/adr/0008, ADR-0012).
#   criteriaDone             run-manifest.json's criteria_done, or null if
#                            the manifest is absent.
#   budgetWarn                true when criteriaDone/criteriaBudget >= 0.8,
#                            false when both are known and under 0.8, null
#                            when criteriaDone is unknown (no manifest yet).
#            criteriaBudget is a SOFT cap (ADR-0008: "soft cost cap, not a
#            coverage cut") — budgetWarn is advisory, never a gate.
#
# ATTRIBUTION (honest-measurement discipline — read before trusting the
# per-criterion breakdown): the toolstream (scripts/toolstream.sh,
# capture-hook.sh) does NOT tag each call with a criterion id — it only
# knows {tool, args, resultDigest, responseBody, seq, ts}. journal.ndjson
# DOES mark criterion boundaries (`criterion_started{criterionId,...}` at
# `t`, journal-emit.sh). toolCallsByCriterion is therefore a TIME-WINDOWED
# proxy: each toolstream event is attributed to the LAST criterion_started
# boundary at-or-before its `ts`. Two honest caveats:
#   1. Both journal.sh's `t` and toolstream.sh's `ts` are second-resolution
#      ("%Y-%m-%dT%H:%M:%SZ", no sub-second component) — several calls
#      landing in the same wall-clock second as a boundary attribute to
#      that boundary optimistically; this is a real but small proxy error,
#      not a bug.
#   2. Under fanning-out-criteria's opt-in PARALLEL execution (ADR-0003's
#      narrow exception), multiple criteria's windows can overlap in real
#      time — the windowing model assumes ADR-0003's sequential-by-default
#      execution and degrades to an approximation (not a hard failure) for
#      the parallel case; a call in that window is still attributed to
#      SOME criterion (the last one journaled), just not necessarily the
#      one that issued it.
# `attribution` in the output is "time-windowed" whenever journal.ndjson
# exists (even with zero boundaries so far — a legitimately "nothing
# started yet" run), or "unavailable" when journal.ndjson doesn't exist at
# all (nothing to window against — ALL calls land in unattributedToolCalls
# and toolCallsByCriterion is empty; this is the honest degrade the W4-3
# task brief calls for rather than a fabricated per-criterion number).
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred, same
# QA_ENGINE override contract as toolstream.sh/journal.sh/fold.sh). No node.
#
# NOTE: all paths are relative to the current working directory (project
# root), same convention as the rest of this plugin's scripts.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"
CONFIG_FILE="${QA_CONFIG_FILE:-.qa/config.json}"
DEFAULT_CRITERIA_BUDGET=60

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# validate_run_id — byte-for-byte the same guard toolstream.sh/checkpoint.sh
# carry under their own name (this codebase's convention: small
# self-contained helpers duplicated per script rather than `source`d).
validate_run_id() {
  local value="$1"
  [[ -z "$value" ]] && die "run-id must not be empty."
  case "$value" in
    */*|*\\*) die "run-id '${value}' contains a path separator — must be a simple token." ;;
  esac
  case "$value" in
    *..*) die "run-id '${value}' contains '..' — must be a simple token." ;;
  esac
  if [[ "$value" =~ ^\.+$ ]]; then
    die "run-id '${value}' is '.' or consists only of dots — must be a simple token."
  fi
  case "$value" in
    -*) die "run-id '${value}' starts with '-' — must be a simple token." ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# parse_boundaries_jq/py <journal-file> -> stdout: JSON array of
# {"t":..., "criterionId":...} for every criterion_started event, sorted
# ascending by t. Torn/malformed lines are silently skipped (fold.sh's own
# "unparseable-line" tolerance — via `jq -R -s` raw-slurp-then-split rather
# than `jq -s`, which would abort the whole slurp on one bad line).
# ---------------------------------------------------------------------------
parse_boundaries_jq() {
  local file="$1"
  jq -R -s '
    (split("\n")) as $lines
    | [ range(0; ($lines | length)) as $i
        | ($lines[$i]) as $raw
        | select(($raw | length) > 0)
        | (try ($raw | fromjson) catch null) as $parsed
        | select($parsed != null and ($parsed | type) == "object")
        | select(($parsed.event? // "") == "criterion_started")
        | select(($parsed.t? // "") != "" and ($parsed.criterionId? // "") != "")
        | {t: $parsed.t, criterionId: $parsed.criterionId}
      ]
    | sort_by(.t)
  ' < "$file"
}

parse_boundaries_py() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import json, sys
path = sys.argv[1]
out = []
with open(path) as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        if parsed.get("event") != "criterion_started":
            continue
        t = parsed.get("t")
        cid = parsed.get("criterionId")
        if not t or not cid:
            continue
        out.append({"t": t, "criterionId": cid})
out.sort(key=lambda b: b["t"])
print(json.dumps(out))
PYEOF
}

# ---------------------------------------------------------------------------
# parse_event_timestamps_jq/py <toolstream-file> -> stdout: JSON array of
# ts strings, sorted ascending. Same torn-line tolerance as above.
# ---------------------------------------------------------------------------
parse_event_timestamps_jq() {
  local file="$1"
  jq -R -s '
    (split("\n")) as $lines
    | [ range(0; ($lines | length)) as $i
        | ($lines[$i]) as $raw
        | select(($raw | length) > 0)
        | (try ($raw | fromjson) catch null) as $parsed
        | select($parsed != null and ($parsed | type) == "object")
        | select(($parsed.ts? // "") != "")
        | $parsed.ts
      ]
    | sort
  ' < "$file"
}

parse_event_timestamps_py() {
  local file="$1"
  python3 - "$file" <<'PYEOF'
import json, sys
path = sys.argv[1]
out = []
with open(path) as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line:
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        t = parsed.get("ts")
        if not t:
            continue
        out.append(t)
out.sort()
print(json.dumps(out))
PYEOF
}

# ---------------------------------------------------------------------------
# extract_field_jq/py <json-file> <field> -> stdout: raw string/number value
# of top-level <field>, or empty when the file is absent/invalid/the field
# is null/absent. Best-effort; never dies.
# ---------------------------------------------------------------------------
extract_field_jq() {
  local file="$1" field="$2"
  [[ -f "$file" ]] || return 0
  jq -r --arg f "$field" '(.[$f] // "") | if type == "object" or type == "array" then "" else tostring end' \
    < "$file" 2>/dev/null
}

extract_field_py() {
  local file="$1" field="$2"
  [[ -f "$file" ]] || return 0
  python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if v is None or isinstance(v, (dict, list)):
    print("")
else:
    print(v)
' "$file" "$field" 2>/dev/null
}

# ---------------------------------------------------------------------------
# attribute_jq/py <bounds-json> <timestamps-json> -> stdout:
# {"criteria":N,"toolCalls":N,"toolCallsByCriterion":{...},
#  "unattributedToolCalls":N}
# For each timestamp, attribute to the LAST boundary at-or-before it (both
# arrays pre-sorted ascending by parse_boundaries_*/parse_event_timestamps_*
# above); no boundary satisfies -> unattributed. See the ATTRIBUTION header
# comment for the honest caveats (second-resolution ties, parallel fan-out).
# ---------------------------------------------------------------------------
attribute_jq() {
  local bounds_json="$1" ts_json="$2"
  jq -n --argjson bounds "$bounds_json" --argjson timestamps "$ts_json" '
    ($bounds | map(.criterionId) | unique | length) as $criteria
    | ($timestamps | length) as $toolCalls
    | reduce $timestamps[] as $t
        ({byCrit: {}, unattributed: 0};
          ( [$bounds[] | select(.t <= $t)] | last ) as $b
          | if $b == null then .unattributed += 1
            else .byCrit[$b.criterionId] = ((.byCrit[$b.criterionId] // 0) + 1)
            end
        ) as $acc
    | {criteria: $criteria, toolCalls: $toolCalls,
       toolCallsByCriterion: $acc.byCrit, unattributedToolCalls: $acc.unattributed}
  '
}

attribute_py() {
  local bounds_json="$1" ts_json="$2"
  python3 -c '
import json, sys
bounds = json.loads(sys.argv[1])
timestamps = json.loads(sys.argv[2])
criteria = len({b["criterionId"] for b in bounds})
by_crit = {}
unattributed = 0
for t in timestamps:
    current = None
    for b in bounds:
        if b["t"] <= t:
            current = b
        else:
            break
    if current is None:
        unattributed += 1
    else:
        cid = current["criterionId"]
        by_crit[cid] = by_crit.get(cid, 0) + 1
print(json.dumps({
    "criteria": criteria,
    "toolCalls": len(timestamps),
    "toolCallsByCriterion": by_crit,
    "unattributedToolCalls": unattributed,
}))
' "$bounds_json" "$ts_json"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: cost-summary.sh <run-id> [--tokens <n>]"
  local run_id="$1"; shift
  validate_run_id "$run_id"

  local tokens="null"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tokens)
        [[ $# -lt 2 ]] && die "--tokens requires a value"
        [[ "$2" =~ ^[0-9]+$ ]] || die "--tokens must be a non-negative integer, got '$2'"
        tokens="$2"
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  if ! has_jq && ! has_py; then
    die "cost-summary.sh needs either 'jq' or 'python3'."
  fi

  local run_dir="${QA_BASE}/${run_id}"
  local journal_file="${run_dir}/journal.ndjson"
  local toolstream_file="${run_dir}/toolstream.jsonl"
  local manifest_file="${run_dir}/run-manifest.json"

  local attribution="unavailable"
  local bounds_json="[]"
  [[ -f "$journal_file" ]] && attribution="time-windowed"
  if [[ "$attribution" == "time-windowed" ]]; then
    if has_jq; then
      bounds_json="$(parse_boundaries_jq "$journal_file")"
    else
      bounds_json="$(parse_boundaries_py "$journal_file")"
    fi
    [[ -z "$bounds_json" ]] && bounds_json="[]"
  fi

  local ts_json="[]"
  if [[ -f "$toolstream_file" ]]; then
    if has_jq; then
      ts_json="$(parse_event_timestamps_jq "$toolstream_file")"
    else
      ts_json="$(parse_event_timestamps_py "$toolstream_file")"
    fi
    [[ -z "$ts_json" ]] && ts_json="[]"
  fi

  local attributed_json
  if [[ "$attribution" == "time-windowed" ]]; then
    if has_jq; then
      attributed_json="$(attribute_jq "$bounds_json" "$ts_json")"
    else
      attributed_json="$(attribute_py "$bounds_json" "$ts_json")"
    fi
  else
    # No journal at all -> nothing to window against; every tool call (if
    # any) is unattributed. Still report a real toolCalls count.
    local n
    if has_jq; then
      n="$(jq -r 'length' <<< "$ts_json")"
    else
      n="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$ts_json")"
    fi
    attributed_json="$(printf '{"criteria":0,"toolCalls":%s,"toolCallsByCriterion":{},"unattributedToolCalls":%s}' "$n" "$n")"
  fi

  local started_at ended_at criteria_done criteria_budget
  if has_jq; then
    started_at="$(extract_field_jq "$manifest_file" "started_at")"
    ended_at="$(extract_field_jq "$manifest_file" "ended_at")"
    criteria_done="$(extract_field_jq "$manifest_file" "criteria_done")"
    criteria_budget="$(extract_field_jq "$CONFIG_FILE" "criteriaBudget")"
  else
    started_at="$(extract_field_py "$manifest_file" "started_at")"
    ended_at="$(extract_field_py "$manifest_file" "ended_at")"
    criteria_done="$(extract_field_py "$manifest_file" "criteria_done")"
    criteria_budget="$(extract_field_py "$CONFIG_FILE" "criteriaBudget")"
  fi
  [[ -z "$criteria_budget" || ! "$criteria_budget" =~ ^[0-9]+$ ]] && criteria_budget="$DEFAULT_CRITERIA_BUDGET"

  local budget_warn="null"
  if [[ -n "$criteria_done" && "$criteria_done" =~ ^[0-9]+$ ]]; then
    # integer-only threshold check: criteria_done*100 / criteriaBudget >= 80
    # avoids depending on a floating-point-capable awk/bc on every host.
    if (( criteria_done * 100 >= criteria_budget * 80 )); then
      budget_warn="true"
    else
      budget_warn="false"
    fi
  fi

  local criteria_done_num="null"
  [[ -n "$criteria_done" && "$criteria_done" =~ ^[0-9]+$ ]] && criteria_done_num="$criteria_done"

  # NOTE: startedAt/endedAt/tokens/criteriaDone/budgetWarn are passed as
  # RAW strings (--arg, never --argjson) and null-coalesced INSIDE each
  # engine below — never hand-built as JSON string literals (a value
  # containing a stray quote/backslash would otherwise corrupt the emitted
  # JSON; this mirrors the rest of this codebase's "never string-concat
  # JSON" discipline, e.g. checkpoint.sh's build_*_event functions).
  if has_jq; then
    jq -n \
      --arg runId "$run_id" \
      --arg startedAtRaw "$started_at" \
      --arg endedAtRaw "$ended_at" \
      --argjson attributed "$attributed_json" \
      --arg attribution "$attribution" \
      --arg tokensRaw "$tokens" \
      --argjson criteriaBudget "$criteria_budget" \
      --arg criteriaDoneRaw "$criteria_done_num" \
      --arg budgetWarnRaw "$budget_warn" \
      --arg asOf "$(ts)" \
      '{
        runId: $runId,
        startedAt: (if $startedAtRaw == "" then null else $startedAtRaw end),
        finishedAt: (if $endedAtRaw == "" then null else $endedAtRaw end),
        criteria: $attributed.criteria,
        toolCalls: $attributed.toolCalls,
        toolCallsByCriterion: $attributed.toolCallsByCriterion,
        unattributedToolCalls: $attributed.unattributedToolCalls,
        attribution: $attribution,
        tokens: (if $tokensRaw == "null" then null else ($tokensRaw | tonumber) end),
        criteriaBudget: $criteriaBudget,
        criteriaDone: (if $criteriaDoneRaw == "null" then null else ($criteriaDoneRaw | tonumber) end),
        budgetWarn: (if $budgetWarnRaw == "null" then null elif $budgetWarnRaw == "true" then true else false end),
        asOf: $asOf
      }'
  else
    python3 -c '
import json, sys
run_id, started_at, ended_at, attributed_json, attribution, tokens_raw, budget, done_raw, warn_raw, as_of = sys.argv[1:11]
attributed = json.loads(attributed_json)
out = {
    "runId": run_id,
    "startedAt": started_at if started_at != "" else None,
    "finishedAt": ended_at if ended_at != "" else None,
    "criteria": attributed["criteria"],
    "toolCalls": attributed["toolCalls"],
    "toolCallsByCriterion": attributed["toolCallsByCriterion"],
    "unattributedToolCalls": attributed["unattributedToolCalls"],
    "attribution": attribution,
    "tokens": None if tokens_raw == "null" else int(tokens_raw),
    "criteriaBudget": int(budget),
    "criteriaDone": None if done_raw == "null" else int(done_raw),
    "budgetWarn": None if warn_raw == "null" else (warn_raw == "true"),
    "asOf": as_of,
}
print(json.dumps(out))
' "$run_id" "$started_at" "$ended_at" "$attributed_json" "$attribution" "$tokens" "$criteria_budget" "$criteria_done_num" "$budget_warn" "$(ts)"
  fi
}

main "$@"
