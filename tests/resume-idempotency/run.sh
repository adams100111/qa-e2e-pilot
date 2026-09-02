#!/usr/bin/env bash
# tests/resume-idempotency/run.sh — the D-7 end-to-end integration proof for
# durable-resume Plan B (portable, harness-agnostic bash — the per-harness
# accuracy run is the manual procedure in docs/harness-adapters.md, not this
# test). Drives the ACTUAL Plan B scripts (journal-emit.sh, checkpoint.sh,
# fold.sh, qa-resume.sh, qa-reconcile.sh) through a realistic kill-mid-act
# scenario and asserts:
#   (a) fold lands on the right (scenario,criterion) tuple after a resume.
#   (b) a completed criterion is never re-run (its verdict stays durable
#       across resume/reconcile — the skip-list, not a re-run).
#   (c) the open act (an act_intent with no matching act_committed — the
#       "kill mid-act" signature) is reconciled by full-write-set re-bake:
#       all-landed -> done (no double-create: exactly one act_intent, one
#       act_committed); partial -> blocked naming the missing key (no
#       silent done); none -> retry, then a second apply on the SAME key
#       escalates to blocked (no infinite retry loop, no silent done).
# Plus the rehydrate-without-explicit-resume protocol: folding the SAME
# journal twice (simulating a mid-run compaction where the agent just
# re-reads the fold, not /qa-resume) yields an identical cursor both times
# — compaction-safe by construction, since fold(journal) is a pure
# projection with no fold-time-of-day state.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EMIT="$HERE/../../skills/checkpointing-qa-memory/scripts/journal-emit.sh"
CHECKPOINT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
FOLD="$HERE/../../skills/checkpointing-qa-memory/scripts/fold.sh"
RESUME="$HERE/../../skills/checkpointing-qa-memory/scripts/qa-resume.sh"
RECON="$HERE/../../skills/checkpointing-qa-memory/scripts/qa-reconcile.sh"
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0

check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
get() { jq -r "$2" "$1" 2>/dev/null; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# fixtures: a two-criterion plan — AC1 read-only (never mutates), AC2 a
# "Create founder" criterion (mutation-flag.sh derive -> true via its
# kinds:["human-action"]) with a declared write-set.
# ---------------------------------------------------------------------------
CRIT_AC2='{"criterionId":"AC2","kinds":["human-action"],"action":"Create founder","title":"Create founder"}'
WS_TWO='[{"entity":"founder","key":"F1"},{"entity":"founder","key":"F2"}]'
WS_ONE='[{"entity":"founder","key":"F1"}]'
RB_ALL='[{"entity":"founder","key":"F1","found":true},{"entity":"founder","key":"F2","found":true}]'
RB_PARTIAL='[{"entity":"founder","key":"F1","found":true},{"entity":"founder","key":"F2","found":false}]'
RB_NONE_ONE='[{"entity":"founder","key":"F1","found":false}]'

# build_plan_json <write-set-json> -> stdout the plan_frozen plan-json for a
# 2-criterion plan (AC1 non-mutating, AC2 mutating with the given write-set).
build_plan_json() {
  local write_set="$1"
  jq -cn --argjson ws "$write_set" '
    { criteria: [
        {criterionId:"AC1", scenarioId:"admin", personaId:"admin", mutates:false},
        {criterionId:"AC2", scenarioId:"admin", personaId:"admin", mutates:true, writeSet:$ws}
      ],
      order: ["AC1","AC2"] }
  '
}

# build_killed_scenario <run-id> <write-set-json> — builds the "simulate a
# kill mid-act on a create criterion" scenario purely from real script
# calls: freeze the 2-criterion plan (Generate->Verify boundary) -> AC1
# started+verdicted pass (a completed, non-mutating criterion) -> AC2
# started+act-intent'd (a mutating criterion's act phase begins) -> STOP.
# No act-commit, no verdict for AC2 — this IS the crash: the journal now
# holds an open act (act_intent with no matching act_committed) for AC2.
build_killed_scenario() {
  local run_id="$1" write_set="$2"
  local plan_json; plan_json="$(build_plan_json "$write_set")"
  ( cd "$WORK" \
      && bash "$EMIT" freeze "$run_id" "$plan_json" >/dev/null \
      && bash "$EMIT" started "$run_id" admin AC1 admin >/dev/null \
      && bash "$CHECKPOINT" "$run_id" AC1 pass --persona admin --last-action "viewed the founder list" >/dev/null \
      && bash "$EMIT" started "$run_id" admin AC2 admin >/dev/null \
      && bash "$EMIT" act-intent "$run_id" admin AC2 admin --criterion "$CRIT_AC2" --write-set "$write_set" >/dev/null )
}

# ===========================================================================
# Step 1 — build the scenario; assert the qa-resume.sh briefing lands on the
# right (scenario,criterion) tuple: cursor = AC2 (open act, no verdict),
# skip = [AC1] (the completed, durable criterion), openActs = [AC2's key].
# ===========================================================================
RUN1="killA"
build_killed_scenario "$RUN1" "$WS_TWO"

BRIEF1="$( cd "$WORK" && bash "$RESUME" "$RUN1" )"
check "(a) briefing run_id" "$(jq -r '.run_id' <<< "$BRIEF1")" "$RUN1"
check "(a) cursor scenarioId == admin" "$(jq -r '.cursor.scenarioId' <<< "$BRIEF1")" "admin"
check "(a) cursor criterionId == AC2 (the open-act tuple, not AC1)" "$(jq -r '.cursor.criterionId' <<< "$BRIEF1")" "AC2"
check "(b) skip has exactly one entry" "$(jq '.skip | length' <<< "$BRIEF1")" "1"
check "(b) skip[0] names the completed criterion AC1" "$(jq -r '.skip[0].criterionId' <<< "$BRIEF1")" "AC1"
check "(b) skip[0] scenarioId == admin" "$(jq -r '.skip[0].scenarioId' <<< "$BRIEF1")" "admin"
check "(c) openActs has exactly one entry (the crash signature)" "$(jq '.openActs | length' <<< "$BRIEF1")" "1"
check "(c) openActs[0] key == ${RUN1}:admin:AC2" "$(jq -r '.openActs[0].key' <<< "$BRIEF1")" "${RUN1}:admin:AC2"
check "(c) openActs[0] writeSet == the declared write-set" "$(jq -c '.openActs[0].writeSet' <<< "$BRIEF1")" "$WS_TWO"

# ===========================================================================
# Step 2 — reconcile the open act three ways, each in its own fresh run (the
# same kill-mid-act scenario replayed) so one variant's outcome never leaks
# into another's assertions.
# ===========================================================================

# ---------------------------------------------------------------------------
# (c) all-landed -> "done": act_committed journaled, re-fold -> openActs
# empty, but the criterion itself STILL has no verdict yet (only the act
# landed — the agent would now finish grading the criterion), so the
# resumed briefing's cursor is STILL AC2 and skip is STILL only [AC1] — no
# double-create (exactly one act_intent, one act_committed for the key) and
# no re-run of the completed criterion AC1 (still exactly one
# criterion_started for it).
# ---------------------------------------------------------------------------
RUN_DONE="killDone"
build_killed_scenario "$RUN_DONE" "$WS_TWO"
KEY_DONE="${RUN_DONE}:admin:AC2"

APPLY_DONE="$( cd "$WORK" && bash "$RECON" apply "$RUN_DONE" "$KEY_DONE" --readbacks "$RB_ALL" )"
check "(c) all-landed: last line == done" "$(tail -n1 <<< "$APPLY_DONE")" "done"

JF_DONE="$WORK/.qa/runs/${RUN_DONE}/journal.ndjson"
check "(c) all-landed: exactly ONE act_intent for the key (no double-create)" \
  "$(jq -s --arg k "$KEY_DONE" '[.[] | select(.event=="act_intent" and .key==$k)] | length' "$JF_DONE")" "1"
check "(c) all-landed: exactly ONE act_committed for the key (no double-create)" \
  "$(jq -s --arg k "$KEY_DONE" '[.[] | select(.event=="act_committed" and .key==$k)] | length' "$JF_DONE")" "1"
check "(b) all-landed: exactly ONE criterion_started for AC1 (not re-run)" \
  "$(jq -s '[.[] | select(.event=="criterion_started" and .criterionId=="AC1")] | length' "$JF_DONE")" "1"

( cd "$WORK" && bash "$FOLD" "$RUN_DONE" >/dev/null )
check "(c) all-landed: re-fold openActs empty" "$(get "$WORK/.qa/runs/${RUN_DONE}/fold-anomalies.json" '.openActs | length')" "0"

BRIEF_DONE="$( cd "$WORK" && bash "$RESUME" "$RUN_DONE" )"
check "(c) all-landed: post-reconcile cursor still AC2 (started, not yet verdicted)" \
  "$(jq -r '.cursor.criterionId' <<< "$BRIEF_DONE")" "AC2"
check "(b) all-landed: post-reconcile skip is STILL only [AC1] (no phantom AC2 skip, no re-run)" \
  "$(jq '.skip | length' <<< "$BRIEF_DONE")" "1"
check "(c) all-landed: post-reconcile openActs empty (nothing left to reconcile)" \
  "$(jq '.openActs | length' <<< "$BRIEF_DONE")" "0"

# ---------------------------------------------------------------------------
# (c) partial-landed -> "blocked" naming the missing key: no silent done.
# ---------------------------------------------------------------------------
RUN_PARTIAL="killPartial"
build_killed_scenario "$RUN_PARTIAL" "$WS_TWO"
KEY_PARTIAL="${RUN_PARTIAL}:admin:AC2"

APPLY_PARTIAL="$( cd "$WORK" && bash "$RECON" apply "$RUN_PARTIAL" "$KEY_PARTIAL" --readbacks "$RB_PARTIAL" )"
check "(c) partial-landed: last line == blocked" "$(tail -n1 <<< "$APPLY_PARTIAL")" "blocked"

CKPT_PARTIAL="$WORK/.qa/runs/${RUN_PARTIAL}/checkpoint.json"
check "(c) partial-landed: checkpoint verdict for AC2 == blocked" \
  "$(get "$CKPT_PARTIAL" '.criteria[] | select(.criterion_id=="AC2") | .verdict')" "blocked"
LA_PARTIAL="$(get "$CKPT_PARTIAL" '.criteria[] | select(.criterion_id=="AC2") | .last_action')"
check "(c) partial-landed: last_action names the missing key F2 (no silent done)" \
  "$([[ "$LA_PARTIAL" == *F2* ]] && echo yes || echo no)" "yes"

JF_PARTIAL="$WORK/.qa/runs/${RUN_PARTIAL}/journal.ndjson"
check "(c) partial-landed: NO act_committed for the key (never silently landed)" \
  "$(jq -s --arg k "$KEY_PARTIAL" '[.[] | select(.event=="act_committed" and .key==$k)] | length' "$JF_PARTIAL")" "0"

( cd "$WORK" && bash "$FOLD" "$RUN_PARTIAL" >/dev/null )
check "(c) partial-landed: the open act itself is still counted (not silently closed)" \
  "$(get "$WORK/.qa/runs/${RUN_PARTIAL}/fold-anomalies.json" '.openActs | length')" "1"

# ---------------------------------------------------------------------------
# (c) none-landed -> "retry" first, then a SECOND apply on the SAME key
# escalates to "blocked" (the crash-safe loop-breaker: apply never returns
# "retry" twice in a row for the same key) — no silent done, no infinite
# retry, no double-create anywhere along the way.
# ---------------------------------------------------------------------------
RUN_NONE="killNone"
build_killed_scenario "$RUN_NONE" "$WS_ONE"
KEY_NONE="${RUN_NONE}:admin:AC2"
JF_NONE="$WORK/.qa/runs/${RUN_NONE}/journal.ndjson"
LINES_BEFORE_RETRY="$(wc -l < "$JF_NONE" | tr -d ' ')"

APPLY_RETRY1="$( cd "$WORK" && bash "$RECON" apply "$RUN_NONE" "$KEY_NONE" --readbacks "$RB_NONE_ONE" )"
check "(c) none-landed (1st): last line == retry" "$(tail -n1 <<< "$APPLY_RETRY1")" "retry"
check "(c) none-landed (1st): journals nothing (no silent done, no premature blocked)" \
  "$(wc -l < "$JF_NONE" | tr -d ' ')" "$LINES_BEFORE_RETRY"

APPLY_RETRY2="$( cd "$WORK" && bash "$RECON" apply "$RUN_NONE" "$KEY_NONE" --readbacks "$RB_NONE_ONE" )"
check "(c) none-landed (2nd/escalation): last line == blocked (never a second consecutive retry)" \
  "$(tail -n1 <<< "$APPLY_RETRY2")" "blocked"
CKPT_NONE="$WORK/.qa/runs/${RUN_NONE}/checkpoint.json"
check "(c) none-landed (2nd/escalation): checkpoint verdict for AC2 == blocked" \
  "$(get "$CKPT_NONE" '.criteria[] | select(.criterion_id=="AC2") | .verdict')" "blocked"
LA_NONE="$(get "$CKPT_NONE" '.criteria[] | select(.criterion_id=="AC2") | .last_action')"
check "(c) none-landed (2nd/escalation): last_action names the open act's key" \
  "$([[ "$LA_NONE" == *"$KEY_NONE"* ]] && echo yes || echo no)" "yes"
check "(c) none-landed: NEVER an act_committed for the key (no silent done anywhere in the ladder)" \
  "$(jq -s --arg k "$KEY_NONE" '[.[] | select(.event=="act_committed" and .key==$k)] | length' "$JF_NONE")" "0"
check "(c) none-landed: exactly ONE act_intent for the key throughout (no double-create via retry)" \
  "$(jq -s --arg k "$KEY_NONE" '[.[] | select(.event=="act_intent" and .key==$k)] | length' "$JF_NONE")" "1"

# ===========================================================================
# Step 3 — rehydrate-without-explicit-resume: a mid-run compaction is
# nothing more than the agent re-reading fold(journal) — NOT calling
# /qa-resume. Folding the SAME journal twice must yield an identical
# cursor.json both times (compaction-safe by construction: fold is a pure
# projection over the journal's content, with no fold-time-of-day state).
# Uses RUN1 (still has its open act, untouched by Step 2's separate runs).
# ===========================================================================
( cd "$WORK" && bash "$FOLD" "$RUN1" >/dev/null )
CURSOR_FOLD1="$(cat "$WORK/.qa/runs/${RUN1}/cursor.json")"
( cd "$WORK" && bash "$FOLD" "$RUN1" >/dev/null )
CURSOR_FOLD2="$(cat "$WORK/.qa/runs/${RUN1}/cursor.json")"
check "rehydrate: re-folding the same journal twice yields byte-identical cursor.json" "$CURSOR_FOLD1" "$CURSOR_FOLD2"
check "rehydrate: cursor still points at AC2 both times" "$(jq -r '.cursor.criterionId' <<< "$CURSOR_FOLD2")" "AC2"
check "rehydrate: criteria_done unchanged across the two folds" \
  "$(jq -r '.criteria_done' <<< "$CURSOR_FOLD1")" "$(jq -r '.criteria_done' <<< "$CURSOR_FOLD2")"

echo "---"; echo "PASS=$PASS FAIL=$FAIL (jq default engine)"

# ===========================================================================
# Dual-engine: replay the full kill-mid-act -> resume -> all-landed-reconcile
# scenario under jq (default) and python3 (jq masked from PATH), and confirm
# the resume briefing + the rehydrate double-fold are canonically identical
# across engines.
# ===========================================================================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin-resume-idempotency"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash head tail tr; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  WORK_JQ="$WORK/dual-jq"; WORK_PY="$WORK/dual-py"
  mkdir -p "$WORK_JQ" "$WORK_PY"

  run_full_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    local run_id="dual" plan_json
    plan_json="$(build_plan_json "$WS_TWO")"
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" freeze "$run_id" "$plan_json" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" started "$run_id" admin AC1 admin >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$CHECKPOINT" "$run_id" AC1 pass --persona admin --last-action "viewed the founder list" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" started "$run_id" admin AC2 admin >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent "$run_id" admin AC2 admin --criterion "$CRIT_AC2" --write-set "$WS_TWO" >/dev/null )
  }
  run_full_scenario "$WORK_JQ"
  run_full_scenario "$WORK_PY" --py

  DUAL_BRIEF_JQ="$( cd "$WORK_JQ" && bash "$RESUME" dual )"
  DUAL_BRIEF_PY="$( cd "$WORK_PY" && PATH="$FAKEBIN" "$BASH_BIN" "$RESUME" dual )"
  canon_brief_jq="$(bash "$JOURNAL" canonical <<< "$DUAL_BRIEF_JQ")"
  canon_brief_py="$(bash "$JOURNAL" canonical <<< "$DUAL_BRIEF_PY")"
  check "dual-equiv: kill-mid-act resume briefing canonically equal across engines" "$canon_brief_jq" "$canon_brief_py"
  check "dual-equiv: py-side cursor criterionId == AC2" "$(jq -r '.cursor.criterionId' <<< "$DUAL_BRIEF_PY")" "AC2"
  check "dual-equiv: py-side skip[0] criterionId == AC1" "$(jq -r '.skip[0].criterionId' <<< "$DUAL_BRIEF_PY")" "AC1"
  check "dual-equiv: py-side openActs[0] key == dual:admin:AC2" "$(jq -r '.openActs[0].key' <<< "$DUAL_BRIEF_PY")" "dual:admin:AC2"

  # all-landed reconcile, both engines
  DUAL_APPLY_JQ="$( cd "$WORK_JQ" && bash "$RECON" apply dual "dual:admin:AC2" --readbacks "$RB_ALL" )"
  DUAL_APPLY_PY="$( cd "$WORK_PY" && PATH="$FAKEBIN" "$BASH_BIN" "$RECON" apply dual "dual:admin:AC2" --readbacks "$RB_ALL" )"
  check "dual-equiv: jq-side all-landed apply -> done" "$(tail -n1 <<< "$DUAL_APPLY_JQ")" "done"
  check "dual-equiv: py-side all-landed apply -> done" "$(tail -n1 <<< "$DUAL_APPLY_PY")" "done"

  jq_journal_canon="$(jq -c 'del(.t)' "$WORK_JQ/.qa/runs/dual/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  py_journal_canon="$(jq -c 'del(.t)' "$WORK_PY/.qa/runs/dual/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  check "dual-equiv: post-reconcile journal.ndjson canonically equal across engines (t stripped)" "$jq_journal_canon" "$py_journal_canon"

  # rehydrate double-fold, both engines
  ( cd "$WORK_JQ" && bash "$FOLD" dual >/dev/null )
  JQ_CURSOR1="$(cat "$WORK_JQ/.qa/runs/dual/cursor.json")"
  ( cd "$WORK_JQ" && bash "$FOLD" dual >/dev/null )
  JQ_CURSOR2="$(cat "$WORK_JQ/.qa/runs/dual/cursor.json")"
  check "dual-equiv: jq-side double-fold cursor.json byte-identical" "$JQ_CURSOR1" "$JQ_CURSOR2"

  ( cd "$WORK_PY" && PATH="$FAKEBIN" "$BASH_BIN" "$FOLD" dual >/dev/null )
  PY_CURSOR1="$(cat "$WORK_PY/.qa/runs/dual/cursor.json")"
  ( cd "$WORK_PY" && PATH="$FAKEBIN" "$BASH_BIN" "$FOLD" dual >/dev/null )
  PY_CURSOR2="$(cat "$WORK_PY/.qa/runs/dual/cursor.json")"
  check "dual-equiv: py-side double-fold cursor.json byte-identical" "$PY_CURSOR1" "$PY_CURSOR2"

  canon_cursor_jq="$(bash "$JOURNAL" canonical <<< "$JQ_CURSOR2")"
  canon_cursor_py="$(bash "$JOURNAL" canonical <<< "$PY_CURSOR2")"
  check "dual-equiv: double-folded cursor.json canonically equal across engines" "$canon_cursor_jq" "$canon_cursor_py"

  echo "note - dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - dual-engine sub-case: jq or python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
