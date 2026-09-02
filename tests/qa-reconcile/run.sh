#!/usr/bin/env bash
# tests/qa-reconcile/run.sh — TDD suite for qa-reconcile.sh (durable-resume
# Plan B, Task 4): fold -> openActs -> write-set join -> rebake.sh reconcile,
# plus the crash-safe retry-escalation attempt counter (retry -> retry ->
# blocked, never a third consecutive "retry" for the same key).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RECON="$HERE/../../skills/checkpointing-qa-memory/scripts/qa-reconcile.sh"
EMIT="$HERE/../../skills/checkpointing-qa-memory/scripts/journal-emit.sh"
FOLD="$HERE/../../skills/checkpointing-qa-memory/scripts/fold.sh"
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0

get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

MUT_CRIT='{"criterionId":"AC1","kinds":["human-action"],"action":"Create founders","title":"Create founders"}'
WS_ALL='[{"entity":"founder","key":"f1"},{"entity":"founder","key":"f2"}]'
RB_ALL='[{"entity":"founder","key":"f1","found":true},{"entity":"founder","key":"f2","found":true}]'
RB_NONE='[{"entity":"founder","key":"f1","found":false},{"entity":"founder","key":"f2","found":false}]'
WS_THREE='[{"entity":"founder","key":"f1"},{"entity":"founder","key":"f2"},{"entity":"founder","key":"f3"}]'
RB_SOME='[{"entity":"founder","key":"f1","found":true},{"entity":"founder","key":"f2","found":false},{"entity":"founder","key":"f3","found":false}]'

# ---------------------------------------------------------------------------
# plan: an open act (act_intent, no commit) lists the key + its writeSet;
# no persona context anywhere -> personaId "" (shared/no-context default).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qp1 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
PLAN1="$( cd "$WORK" && bash "$RECON" plan qp1 )"
check "plan: one open act listed" "$(jq 'length' <<< "$PLAN1")" "1"
check "plan: key == qp1:admin:AC1" "$(jq -r '.[0].key' <<< "$PLAN1")" "qp1:admin:AC1"
check "plan: scenarioId == admin" "$(jq -r '.[0].scenarioId' <<< "$PLAN1")" "admin"
check "plan: criterionId == AC1" "$(jq -r '.[0].criterionId' <<< "$PLAN1")" "AC1"
check "plan: personaId defaults to '' (no started/verdict context)" "$(jq -r '.[0].personaId' <<< "$PLAN1")" ""
check "plan: writeSet joined from the act_intent event" "$(jq -c '.[0].writeSet' <<< "$PLAN1")" "$WS_ALL"

# ---------------------------------------------------------------------------
# plan: a journal where the act WAS committed -> plan is empty (nothing to
# reconcile).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qp2 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
( cd "$WORK" && bash "$EMIT" act-commit qp2 admin AC1 admin --outcome landed >/dev/null )
PLAN2="$( cd "$WORK" && bash "$RECON" plan qp2 )"
check "plan: committed act -> empty array" "$PLAN2" "[]"

# ---------------------------------------------------------------------------
# plan: MULTIPLE open acts -> each entry gets its OWN correctly-joined
# writeSet (proves the join doesn't cross-wire keys).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qp3 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
( cd "$WORK" && bash "$EMIT" act-intent qp3 user AC2 user --criterion "$MUT_CRIT" --write-set "$WS_THREE" >/dev/null )
PLAN3="$( cd "$WORK" && bash "$RECON" plan qp3 )"
check "plan: two open acts listed" "$(jq 'length' <<< "$PLAN3")" "2"
check "plan: entry[0] key == qp3:admin:AC1" "$(jq -r '.[0].key' <<< "$PLAN3")" "qp3:admin:AC1"
check "plan: entry[0] writeSet == WS_ALL" "$(jq -c '.[0].writeSet' <<< "$PLAN3")" "$WS_ALL"
check "plan: entry[1] key == qp3:user:AC2" "$(jq -r '.[1].key' <<< "$PLAN3")" "qp3:user:AC2"
check "plan: entry[1] writeSet == WS_THREE" "$(jq -c '.[1].writeSet' <<< "$PLAN3")" "$WS_THREE"

# ---------------------------------------------------------------------------
# plan: persona-join, KEYED-persona case — a criterion_started for the same
# (scenarioId,criterionId) tuple BEFORE the act-intent supplies personaId.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started qp4 admin AC1 admin >/dev/null )
( cd "$WORK" && bash "$EMIT" act-intent qp4 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
PLAN4="$( cd "$WORK" && bash "$RECON" plan qp4 )"
check "plan: keyed-persona case -> personaId == admin" "$(jq -r '.[0].personaId' <<< "$PLAN4")" "admin"

# ---------------------------------------------------------------------------
# plan: persona-join, SHARED-persona case — scenarioId __shared__, personaId
# "" throughout (ADR-0012 shared-criterion convention).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started qp5 __shared__ AC9 "" >/dev/null )
( cd "$WORK" && bash "$EMIT" act-intent qp5 __shared__ AC9 "" --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
PLAN5="$( cd "$WORK" && bash "$RECON" plan qp5 )"
check "plan: shared-persona case -> scenarioId == __shared__" "$(jq -r '.[0].scenarioId' <<< "$PLAN5")" "__shared__"
check "plan: shared-persona case -> personaId == ''" "$(jq -r '.[0].personaId' <<< "$PLAN5")" ""

# ---------------------------------------------------------------------------
# apply: all-found readbacks -> "done"; act_committed journaled; re-fold ->
# openActs empty for that run.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa1 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
APPLY_DONE="$( cd "$WORK" && bash "$RECON" apply qa1 "qa1:admin:AC1" --readbacks "$RB_ALL" )"
check "apply done: first line outcome == landed" "$(head -n1 <<< "$APPLY_DONE" | jq -r '.outcome')" "landed"
check "apply done: last line == done" "$(tail -n1 <<< "$APPLY_DONE")" "done"
check "apply done: act_committed journaled" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK/.qa/runs/qa1/journal.ndjson")" "1"
( cd "$WORK" && bash "$FOLD" qa1 >/dev/null )
check "apply done: openActs EMPTY after re-fold" "$(get "$WORK/.qa/runs/qa1/fold-anomalies.json" '.openActs | length')" "0"

# ---------------------------------------------------------------------------
# apply: partial readbacks -> "blocked"; checkpoint verdict blocked, naming
# the missing key(s); the open act itself is NOT closed (matches rebake's
# own partial convention — crash-safe retry-later).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa2 admin AC2 admin --criterion "$MUT_CRIT" --write-set "$WS_THREE" >/dev/null )
APPLY_PARTIAL="$( cd "$WORK" && bash "$RECON" apply qa2 "qa2:admin:AC2" --readbacks "$RB_SOME" )"
check "apply partial: last line == blocked" "$(tail -n1 <<< "$APPLY_PARTIAL")" "blocked"
CKPT_QA2="$WORK/.qa/runs/qa2/checkpoint.json"
check "apply partial: checkpoint verdict == blocked" \
  "$(get "$CKPT_QA2" '.criteria[] | select(.criterion_id=="AC2") | .verdict')" "blocked"
LA_QA2="$(get "$CKPT_QA2" '.criteria[] | select(.criterion_id=="AC2") | .last_action')"
check "apply partial: last_action names missing key f2" "$([[ "$LA_QA2" == *f2* ]] && echo yes || echo no)" "yes"
check "apply partial: last_action names missing key f3" "$([[ "$LA_QA2" == *f3* ]] && echo yes || echo no)" "yes"
( cd "$WORK" && bash "$FOLD" qa2 >/dev/null )
check "apply partial: open act still counted (not closed by a partial landing)" \
  "$(get "$WORK/.qa/runs/qa2/fold-anomalies.json" '.openActs | length')" "1"

# ---------------------------------------------------------------------------
# apply: none-found readbacks -> "retry" (first consecutive retry for this
# key). Nothing journaled (no act_committed, no criterion_verdict); the
# attempt marker for this key is now 1.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa3 admin AC3 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
JF_QA3="$WORK/.qa/runs/qa3/journal.ndjson"
LINES_BEFORE_QA3="$(wc -l < "$JF_QA3" | tr -d ' ')"

APPLY_RETRY1="$( cd "$WORK" && bash "$RECON" apply qa3 "qa3:admin:AC3" --readbacks "$RB_NONE" )"
check "apply none (1st): last line == retry" "$(tail -n1 <<< "$APPLY_RETRY1")" "retry"
check "apply none (1st): journals nothing (line count unchanged)" \
  "$(wc -l < "$JF_QA3" | tr -d ' ')" "$LINES_BEFORE_QA3"
# NOTE: apply() folds first (fold.sh unconditionally writes checkpoint.json,
# even with zero criteria) — so checkpoint.json existing is not itself
# informative here; what matters is that AC3 has no verdict recorded yet.
check "apply none (1st): AC3 has no verdict recorded yet" \
  "$(get "$WORK/.qa/runs/qa3/checkpoint.json" '[.criteria[] | select(.criterion_id=="AC3")] | length')" "0"
check "apply none (1st): attempt marker == 1 for this key" \
  "$(get "$WORK/.qa/runs/qa3/.reconcile-attempts" '.["qa3:admin:AC3"]')" "1"

# ---------------------------------------------------------------------------
# apply: a SECOND consecutive none/retry for the SAME key -> escalates to
# "blocked" (attempt-counter escalation — no infinite retry loop). A
# blocked criterion_verdict is journaled naming the key; the attempt
# marker for this key is cleared afterward.
# ---------------------------------------------------------------------------
APPLY_RETRY2="$( cd "$WORK" && bash "$RECON" apply qa3 "qa3:admin:AC3" --readbacks "$RB_NONE" )"
check "apply none (2nd/escalation): last line == blocked (NOT retry again)" "$(tail -n1 <<< "$APPLY_RETRY2")" "blocked"
CKPT_QA3="$WORK/.qa/runs/qa3/checkpoint.json"
check "apply none (2nd/escalation): checkpoint verdict == blocked" \
  "$(get "$CKPT_QA3" '.criteria[] | select(.criterion_id=="AC3") | .verdict')" "blocked"
LA_QA3="$(get "$CKPT_QA3" '.criteria[] | select(.criterion_id=="AC3") | .last_action')"
check "apply none (2nd/escalation): last_action names the key" \
  "$([[ "$LA_QA3" == *"qa3:admin:AC3"* ]] && echo yes || echo no)" "yes"
check "apply none (2nd/escalation): attempt marker cleared" \
  "$(get "$WORK/.qa/runs/qa3/.reconcile-attempts" '.["qa3:admin:AC3"] // "absent"')" "absent"
check "apply none (2nd/escalation): still exactly ONE act_committed line (zero — never closed)" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$JF_QA3")" "0"

# ---------------------------------------------------------------------------
# apply: rejects a run with NO journal at all (fold_run dies first) —
# nonzero, nothing journaled. (Distinct from the genuinely-unknown-key case
# below, where the run/journal DOES exist but this particular key was never
# intended.)
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$RECON" apply qa4 "qa4:admin:AC1" --readbacks "$RB_ALL" >/dev/null 2>&1 ); rc_not_open=$?
check "apply: no journal for run -> rejected (nonzero)" "$([[ $rc_not_open -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# apply: GENUINELY UNKNOWN KEY — the run/journal exists (has an act_intent
# for a DIFFERENT key) but the requested key has no act_intent anywhere in
# it. This rejection stays: apply must still die clearly for a key that was
# never intended at all.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa6 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
APPLY_UNKNOWN_ERR="$( cd "$WORK" && bash "$RECON" apply qa6 "qa6:admin:AC-NEVER-INTENDED" --readbacks "$RB_ALL" 2>&1 >/dev/null )"; rc_unknown=$?
check "apply: genuinely-unknown key -> rejected (nonzero)" "$([[ $rc_unknown -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "apply: genuinely-unknown key -> dies clearly (mentions the key)" \
  "$([[ "$APPLY_UNKNOWN_ERR" == *"qa6:admin:AC-NEVER-INTENDED"* ]] && echo yes || echo no)" "yes"
check "apply: genuinely-unknown key journals no act_committed" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK/.qa/runs/qa6/journal.ndjson")" "0"

# ---------------------------------------------------------------------------
# apply: CORROBORATION — the journal already shows the key as committed
# (act_intent + a SELF-REPORTED act_commit --outcome landed, the live Verify
# loop's own report), but `apply` re-verifies it against re-bake anyway,
# because re-bake (not the journal) is the landed/not authority. Readbacks
# say NOT found -> this is a correction path: "retry" (not a die), then a
# SECOND not-found apply on the same key escalates to "blocked" naming the
# key — exactly the retry-escalation ladder committed keys were previously
# excluded from.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa7 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
( cd "$WORK" && bash "$EMIT" act-commit qa7 admin AC1 admin --outcome landed >/dev/null )
JF_QA7="$WORK/.qa/runs/qa7/journal.ndjson"
check "corroboration setup: journal already shows this key committed" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$JF_QA7")" "1"

CORR_APPLY1="$( cd "$WORK" && bash "$RECON" apply qa7 "qa7:admin:AC1" --readbacks "$RB_NONE" )"; rc_corr1=$?
check "corroboration: apply on a committed key does NOT die (zero exit)" "$rc_corr1" "0"
check "corroboration (1st not-found): last line == retry (not a die)" "$(tail -n1 <<< "$CORR_APPLY1")" "retry"
check "corroboration (1st not-found): journals nothing new (still exactly 1 act_committed)" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$JF_QA7")" "1"

CORR_APPLY2="$( cd "$WORK" && bash "$RECON" apply qa7 "qa7:admin:AC1" --readbacks "$RB_NONE" )"; rc_corr2=$?
check "corroboration: SECOND apply on the committed key does NOT die (zero exit)" "$rc_corr2" "0"
check "corroboration (2nd not-found/escalation): last line == blocked" "$(tail -n1 <<< "$CORR_APPLY2")" "blocked"
CKPT_QA7="$WORK/.qa/runs/qa7/checkpoint.json"
check "corroboration (2nd not-found/escalation): checkpoint verdict == blocked" \
  "$(get "$CKPT_QA7" '.criteria[] | select(.criterion_id=="AC1") | .verdict')" "blocked"
LA_QA7="$(get "$CKPT_QA7" '.criteria[] | select(.criterion_id=="AC1") | .last_action')"
check "corroboration (2nd not-found/escalation): last_action names the key" \
  "$([[ "$LA_QA7" == *"qa7:admin:AC1"* ]] && echo yes || echo no)" "yes"
check "corroboration: re-bake OVERRIDES the wrong self-report — still exactly 1 act_committed (never a 2nd)" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$JF_QA7")" "1"
( cd "$WORK" && bash "$FOLD" qa7 >/dev/null )
check "corroboration: plan STILL empty for this committed act post-escalation (plan lists only genuinely open acts)" \
  "$(get "$WORK/.qa/runs/qa7/fold-anomalies.json" '.openActs | length')" "0"

# ---------------------------------------------------------------------------
# apply: CONFIRMING case — committed key + all-found readbacks -> "done"
# (confirms the self-report; no error, no spurious re-open).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa8 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
( cd "$WORK" && bash "$EMIT" act-commit qa8 admin AC1 admin --outcome landed >/dev/null )
CORR_CONFIRM="$( cd "$WORK" && bash "$RECON" apply qa8 "qa8:admin:AC1" --readbacks "$RB_ALL" )"; rc_confirm=$?
check "confirming case: apply on a committed key with all-found readbacks does NOT die" "$rc_confirm" "0"
check "confirming case: last line == done" "$(tail -n1 <<< "$CORR_CONFIRM")" "done"
check "confirming case: still exactly ONE act_committed line total (idempotent-ish confirm)" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK/.qa/runs/qa8/journal.ndjson")" "2"

# ---------------------------------------------------------------------------
# apply: rejects a malformed invocation (missing --readbacks) — nothing
# journaled.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent qa5 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
( cd "$WORK" && bash "$RECON" apply qa5 "qa5:admin:AC1" >/dev/null 2>&1 ); rc_no_rb=$?
check "apply: missing --readbacks rejected (nonzero)" "$([[ $rc_no_rb -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "apply: missing --readbacks journals no act_committed" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK/.qa/runs/qa5/journal.ndjson")" "0"

# ---------------------------------------------------------------------------
# plan: rejects a run with no journal at all — clear nonzero error.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$RECON" plan qp-nonexistent >/dev/null 2>&1 ); rc_no_journal=$?
check "plan: no journal for run -> rejected (nonzero)" "$([[ $rc_no_journal -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

echo "---"; echo "PASS=$PASS FAIL=$FAIL (jq default engine)"

# ---------------------------------------------------------------------------
# dual-engine equivalence: plan (multi-open-act join) + apply (done path) +
# apply (retry -> retry -> blocked escalation) under jq (default) vs.
# python3 (jq masked from PATH), same run-ids in two SEPARATE work dirs,
# canonically compared (t / timestamps stripped).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin-reconcile"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash head tail; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  WORK_JQ="$WORK/dual-jq"; WORK_PY="$WORK/dual-py"
  mkdir -p "$WORK_JQ" "$WORK_PY"

  run_plan_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" started dual-plan admin AC1 admin >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-plan admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-plan user AC2 user --criterion "$MUT_CRIT" --write-set "$WS_THREE" >/dev/null )
  }
  run_plan_scenario "$WORK_JQ"
  run_plan_scenario "$WORK_PY" --py

  DUAL_PLAN_JQ="$( cd "$WORK_JQ" && bash "$RECON" plan dual-plan )"
  DUAL_PLAN_PY="$( cd "$WORK_PY" && PATH="$FAKEBIN" "$BASH_BIN" "$RECON" plan dual-plan )"
  canon_plan_jq="$(bash "$JOURNAL" canonical <<< "$DUAL_PLAN_JQ")"
  canon_plan_py="$(bash "$JOURNAL" canonical <<< "$DUAL_PLAN_PY")"
  check "dual-equiv: plan (multi-open-act join) canonically equal across engines" "$canon_plan_jq" "$canon_plan_py"
  check "dual-equiv: py-side plan personaId == admin (keyed-persona join)" \
    "$(jq -r '.[0].personaId' <<< "$DUAL_PLAN_PY")" "admin"

  run_apply_done_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-done admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$RECON" apply dual-done "dual-done:admin:AC1" --readbacks "$RB_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$FOLD" dual-done >/dev/null )
  }
  run_apply_done_scenario "$WORK_JQ"
  run_apply_done_scenario "$WORK_PY" --py

  jq_done_journal="$(jq -c 'del(.t)' "$WORK_JQ/.qa/runs/dual-done/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  py_done_journal="$(jq -c 'del(.t)' "$WORK_PY/.qa/runs/dual-done/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  check "dual-equiv: apply-done journal.ndjson canonically equal across engines (t stripped)" "$jq_done_journal" "$py_done_journal"
  check "dual-equiv: jq-side apply-done openActs empty" \
    "$(jq '.openActs | length' "$WORK_JQ/.qa/runs/dual-done/fold-anomalies.json")" "0"
  check "dual-equiv: py-side apply-done openActs empty" \
    "$(jq '.openActs | length' "$WORK_PY/.qa/runs/dual-done/fold-anomalies.json")" "0"

  run_apply_escalate_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-esc admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$RECON" apply dual-esc "dual-esc:admin:AC1" --readbacks "$RB_NONE" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$RECON" apply dual-esc "dual-esc:admin:AC1" --readbacks "$RB_NONE" >/dev/null )
  }
  run_apply_escalate_scenario "$WORK_JQ"
  run_apply_escalate_scenario "$WORK_PY" --py

  norm_ckpt() { jq -c '.updated_at = null | .criteria[]?.checkpointed_at = null' "$1" | bash "$JOURNAL" canonical; }
  canon_esc_jq="$(norm_ckpt "$WORK_JQ/.qa/runs/dual-esc/checkpoint.json")"
  canon_esc_py="$(norm_ckpt "$WORK_PY/.qa/runs/dual-esc/checkpoint.json")"
  check "dual-equiv: retry-escalation checkpoint.json canonically equal across engines (timestamps stripped)" "$canon_esc_jq" "$canon_esc_py"
  check "dual-equiv: py-side retry-escalation verdict == blocked" \
    "$(jq -r '.criteria[] | select(.criterion_id=="AC1") | .verdict' "$WORK_PY/.qa/runs/dual-esc/checkpoint.json")" "blocked"
  check "dual-equiv: py-side retry-escalation attempt marker cleared" \
    "$(jq -r '.["dual-esc:admin:AC1"] // "absent"' "$WORK_PY/.qa/runs/dual-esc/.reconcile-attempts" 2>/dev/null)" "absent"

  # -------------------------------------------------------------------------
  # dual-equiv: CORROBORATION — a self-reported committed key (act_intent +
  # act-commit --outcome landed), then two not-found `apply` calls on that
  # SAME already-committed key (retry -> blocked escalation, re-bake
  # overriding the wrong self-report), under jq vs. python3.
  # -------------------------------------------------------------------------
  run_apply_corroborate_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-corr admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-commit dual-corr admin AC1 admin --outcome landed >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$RECON" apply dual-corr "dual-corr:admin:AC1" --readbacks "$RB_NONE" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$RECON" apply dual-corr "dual-corr:admin:AC1" --readbacks "$RB_NONE" >/dev/null )
  }
  run_apply_corroborate_scenario "$WORK_JQ"; rc_dual_corr_jq=$?
  run_apply_corroborate_scenario "$WORK_PY" --py; rc_dual_corr_py=$?
  check "dual-equiv: corroboration — jq side never dies (both applies zero exit)" "$rc_dual_corr_jq" "0"
  check "dual-equiv: corroboration — py side never dies (both applies zero exit)" "$rc_dual_corr_py" "0"

  canon_corr_jq="$(norm_ckpt "$WORK_JQ/.qa/runs/dual-corr/checkpoint.json")"
  canon_corr_py="$(norm_ckpt "$WORK_PY/.qa/runs/dual-corr/checkpoint.json")"
  check "dual-equiv: corroboration checkpoint.json canonically equal across engines (timestamps stripped)" "$canon_corr_jq" "$canon_corr_py"
  check "dual-equiv: jq-side corroboration verdict == blocked" \
    "$(jq -r '.criteria[] | select(.criterion_id=="AC1") | .verdict' "$WORK_JQ/.qa/runs/dual-corr/checkpoint.json")" "blocked"
  check "dual-equiv: py-side corroboration verdict == blocked" \
    "$(jq -r '.criteria[] | select(.criterion_id=="AC1") | .verdict' "$WORK_PY/.qa/runs/dual-corr/checkpoint.json")" "blocked"
  check "dual-equiv: jq-side corroboration still exactly 1 act_committed (re-bake never confirms a not-found)" \
    "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK_JQ/.qa/runs/dual-corr/journal.ndjson")" "1"
  check "dual-equiv: py-side corroboration still exactly 1 act_committed (re-bake never confirms a not-found)" \
    "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK_PY/.qa/runs/dual-corr/journal.ndjson")" "1"

  echo "note - dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - dual-engine sub-case: jq or python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
