#!/usr/bin/env bash
# tests/rebake/run.sh — TDD suite for rebake.sh (durable-resume Plan B,
# Task 3): the D-5 write-set re-bake classifier + reconciler. classify is a
# pure function (all/none/partial/deferred + precedence); reconcile
# journals landed/partial via journal-emit.sh/checkpoint.sh and NEVER
# journals on none/deferred, and NEVER prints a silent "done".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REBAKE="$HERE/../../skills/checkpointing-qa-memory/scripts/rebake.sh"
EMIT="$HERE/../../skills/checkpointing-qa-memory/scripts/journal-emit.sh"
CKPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
FOLD="$HERE/../../skills/checkpointing-qa-memory/scripts/fold.sh"
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0

get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# classify: all-found -> landed
# ---------------------------------------------------------------------------
WS_ALL='[{"entity":"founder","key":"f1"},{"entity":"founder","key":"f2"}]'
RB_ALL='[{"entity":"founder","key":"f1","found":true},{"entity":"founder","key":"f2","found":true}]'
OUT_ALL="$(bash "$REBAKE" classify --write-set "$WS_ALL" --readbacks "$RB_ALL")"
check "classify all-found: outcome landed" "$(jq -r '.outcome' <<< "$OUT_ALL")" "landed"
check "classify all-found: missing empty" "$(jq -c '.missing' <<< "$OUT_ALL")" "[]"
check "classify all-found: writeSetSize == 2" "$(jq -r '.writeSetSize' <<< "$OUT_ALL")" "2"
check "classify all-found: foundCount == 2" "$(jq -r '.foundCount' <<< "$OUT_ALL")" "2"

# ---------------------------------------------------------------------------
# classify: none-found -> none
# ---------------------------------------------------------------------------
RB_NONE='[{"entity":"founder","key":"f1","found":false},{"entity":"founder","key":"f2","found":false}]'
OUT_NONE="$(bash "$REBAKE" classify --write-set "$WS_ALL" --readbacks "$RB_NONE")"
check "classify none-found: outcome none" "$(jq -r '.outcome' <<< "$OUT_NONE")" "none"
check "classify none-found: foundCount == 0" "$(jq -r '.foundCount' <<< "$OUT_NONE")" "0"

# ---------------------------------------------------------------------------
# classify: some-found -> partial with the EXACT missing keys (non-empty)
# ---------------------------------------------------------------------------
WS_THREE='[{"entity":"founder","key":"f1"},{"entity":"founder","key":"f2"},{"entity":"founder","key":"f3"}]'
RB_SOME='[{"entity":"founder","key":"f1","found":true},{"entity":"founder","key":"f2","found":false},{"entity":"founder","key":"f3","found":false}]'
OUT_SOME="$(bash "$REBAKE" classify --write-set "$WS_THREE" --readbacks "$RB_SOME")"
check "classify partial: outcome partial" "$(jq -r '.outcome' <<< "$OUT_SOME")" "partial"
check "classify partial: missing == [f2,f3]" "$(jq -c '.missing | sort' <<< "$OUT_SOME")" '["f2","f3"]'
check "classify partial: missing is non-empty (a bug if empty)" \
  "$([[ "$(jq '.missing | length' <<< "$OUT_SOME")" -gt 0 ]] && echo yes || echo no)" "yes"
check "classify partial: foundCount == 1" "$(jq -r '.foundCount' <<< "$OUT_SOME")" "1"

# ---------------------------------------------------------------------------
# classify: a member {writeOnly:true} that is NOT found -> deferred
# ---------------------------------------------------------------------------
WS_WO='[{"entity":"webhook","key":"w1","writeOnly":true}]'
RB_WO_NOTFOUND='[{"entity":"webhook","key":"w1","found":false}]'
OUT_WO="$(bash "$REBAKE" classify --write-set "$WS_WO" --readbacks "$RB_WO_NOTFOUND")"
check "classify writeOnly unfound: outcome deferred" "$(jq -r '.outcome' <<< "$OUT_WO")" "deferred"
check "classify writeOnly unfound: deferredKeys == [w1]" "$(jq -c '.deferredKeys' <<< "$OUT_WO")" '["w1"]'
check "classify writeOnly unfound: missing does NOT include w1" "$(jq -c '.missing' <<< "$OUT_WO")" '[]'

# ---------------------------------------------------------------------------
# PRECEDENCE: a writeOnly member that IS found still counts as landed for
# that member (not deferred) — mixed with other found members -> landed.
# ---------------------------------------------------------------------------
WS_MIX='[{"entity":"founder","key":"f1"},{"entity":"webhook","key":"w1","writeOnly":true}]'
RB_MIX_ALL_FOUND='[{"entity":"founder","key":"f1","found":true},{"entity":"webhook","key":"w1","found":true}]'
OUT_MIX_LANDED="$(bash "$REBAKE" classify --write-set "$WS_MIX" --readbacks "$RB_MIX_ALL_FOUND")"
check "precedence: writeOnly FOUND + others found -> landed (not deferred)" \
  "$(jq -r '.outcome' <<< "$OUT_MIX_LANDED")" "landed"

# PRECEDENCE: deferred wins over partial/none when the writeOnly member is
# unfound, even though a normal member IS found (i.e. not "none").
RB_MIX_WO_UNFOUND='[{"entity":"founder","key":"f1","found":true},{"entity":"webhook","key":"w1","found":false}]'
OUT_MIX_DEFERRED="$(bash "$REBAKE" classify --write-set "$WS_MIX" --readbacks "$RB_MIX_WO_UNFOUND")"
check "precedence: writeOnly UNFOUND -> deferred wins even with a found normal member" \
  "$(jq -r '.outcome' <<< "$OUT_MIX_DEFERRED")" "deferred"
check "precedence: deferredKeys == [w1] (only the writeOnly one)" \
  "$(jq -c '.deferredKeys' <<< "$OUT_MIX_DEFERRED")" '["w1"]'
check "precedence: missing == [] (f1 is found, w1 is deferred not missing)" \
  "$(jq -c '.missing' <<< "$OUT_MIX_DEFERRED")" '[]'

# ---------------------------------------------------------------------------
# classify: missing/unmatched readback for a member is treated as not-found
# ---------------------------------------------------------------------------
RB_MISSING_ENTRY='[{"entity":"founder","key":"f1","found":true}]'
OUT_UNMATCHED="$(bash "$REBAKE" classify --write-set "$WS_ALL" --readbacks "$RB_MISSING_ENTRY")"
check "classify: a write-set member with no matching readback is treated not-found (partial)" \
  "$(jq -r '.outcome' <<< "$OUT_UNMATCHED")" "partial"
check "classify: missing == [f2] for the unmatched member" "$(jq -c '.missing' <<< "$OUT_UNMATCHED")" '["f2"]'

# ---------------------------------------------------------------------------
# classify: rejects malformed --write-set / --readbacks (nothing printed)
# ---------------------------------------------------------------------------
( bash "$REBAKE" classify --write-set '{"not":"an array"}' --readbacks "$RB_ALL" >/dev/null 2>&1 ); rc_bad_ws=$?
check "classify: malformed --write-set rejected (nonzero)" "$([[ $rc_bad_ws -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
( bash "$REBAKE" classify --write-set "$WS_ALL" --readbacks '[{"entity":"x"}]' >/dev/null 2>&1 ); rc_bad_rb=$?
check "classify: malformed --readbacks (missing key/found) rejected (nonzero)" "$([[ $rc_bad_rb -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

echo "---"; echo "PASS=$PASS FAIL=$FAIL (classify, jq default engine)"

# ---------------------------------------------------------------------------
# reconcile: landed -> journals act_committed (closes the open act opened by
# a prior act-intent); fold openActs EMPTY after; prints the classify
# summary then the literal "done" as the final line.
# ---------------------------------------------------------------------------
MUT_CRIT='{"criterionId":"AC1","kinds":["human-action"],"action":"Create founders","title":"Create founders"}'
( cd "$WORK" && bash "$EMIT" act-intent rc1 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )

RECON_LANDED_OUT="$( cd "$WORK" && bash "$REBAKE" reconcile rc1 admin AC1 admin --write-set "$WS_ALL" --readbacks "$RB_ALL" )"
check "reconcile landed: last line is literal 'done'" "$(tail -n1 <<< "$RECON_LANDED_OUT")" "done"
check "reconcile landed: first line is the classify summary (outcome landed)" \
  "$(head -n1 <<< "$RECON_LANDED_OUT" | jq -r '.outcome')" "landed"

JF_RC1="$WORK/.qa/runs/rc1/journal.ndjson"
check "reconcile landed: act_committed line present" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$JF_RC1")" "1"
check "reconcile landed: act_committed outcome == landed" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")][0].outcome' "$JF_RC1")" "landed"
check "reconcile landed: act_committed key == run:scenario:criterion" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")][0].key' "$JF_RC1")" "rc1:admin:AC1"

( cd "$WORK" && bash "$FOLD" rc1 >/dev/null )
ANOM_RC1="$WORK/.qa/runs/rc1/fold-anomalies.json"
check "reconcile landed: fold openActs EMPTY after reconcile" "$(get "$ANOM_RC1" '.openActs | length')" "0"

# ---------------------------------------------------------------------------
# reconcile: partial -> journals a BLOCKED criterion_verdict naming the
# missing key(s) in last_action; prints "blocked" as the final line; the
# open act is NOT closed (no act_committed emitted for a partial landing —
# crash-safety: the caller can retry the act later).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent rc2 admin AC2 admin --criterion '{"criterionId":"AC2","kinds":["human-action"],"action":"Create three founders"}' --write-set "$WS_THREE" >/dev/null )

RECON_PARTIAL_OUT="$( cd "$WORK" && bash "$REBAKE" reconcile rc2 admin AC2 admin --write-set "$WS_THREE" --readbacks "$RB_SOME" )"
check "reconcile partial: last line is literal 'blocked'" "$(tail -n1 <<< "$RECON_PARTIAL_OUT")" "blocked"

CKPT_RC2="$WORK/.qa/runs/rc2/checkpoint.json"
check "reconcile partial: checkpoint verdict == blocked" \
  "$(get "$CKPT_RC2" '.criteria[] | select(.criterion_id=="AC2") | .verdict')" "blocked"
LAST_ACTION_RC2="$(get "$CKPT_RC2" '.criteria[] | select(.criterion_id=="AC2") | .last_action')"
check "reconcile partial: last_action names missing key f2" \
  "$([[ "$LAST_ACTION_RC2" == *f2* ]] && echo yes || echo no)" "yes"
check "reconcile partial: last_action names missing key f3" \
  "$([[ "$LAST_ACTION_RC2" == *f3* ]] && echo yes || echo no)" "yes"

( cd "$WORK" && bash "$FOLD" rc2 >/dev/null )
ANOM_RC2="$WORK/.qa/runs/rc2/fold-anomalies.json"
check "reconcile partial: open act NOT closed (no act_committed on partial)" \
  "$(get "$ANOM_RC2" '.openActs | length')" "1"
check "reconcile partial: no act_committed line was journaled" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$WORK/.qa/runs/rc2/journal.ndjson")" "0"

# ---------------------------------------------------------------------------
# reconcile: none -> journals NOTHING (no act_committed, no criterion_verdict,
# open act unchanged); prints "retry" as the final line.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent rc3 admin AC3 admin --criterion '{"criterionId":"AC3","kinds":["human-action"],"action":"Create founders"}' --write-set "$WS_ALL" >/dev/null )
JF_RC3="$WORK/.qa/runs/rc3/journal.ndjson"
LINES_BEFORE_RC3="$(wc -l < "$JF_RC3" | tr -d ' ')"

RECON_NONE_OUT="$( cd "$WORK" && bash "$REBAKE" reconcile rc3 admin AC3 admin --write-set "$WS_ALL" --readbacks "$RB_NONE" )"
check "reconcile none: last line is literal 'retry'" "$(tail -n1 <<< "$RECON_NONE_OUT")" "retry"
check "reconcile none: journals NOTHING (journal line count unchanged)" \
  "$(wc -l < "$JF_RC3" | tr -d ' ')" "$LINES_BEFORE_RC3"
check "reconcile none: no checkpoint.json was created for rc3" \
  "$([[ -e "$WORK/.qa/runs/rc3/checkpoint.json" ]] && echo exists || echo none)" "none"

( cd "$WORK" && bash "$FOLD" rc3 >/dev/null )
ANOM_RC3="$WORK/.qa/runs/rc3/fold-anomalies.json"
check "reconcile none: open act still OPEN (unchanged, retryable)" "$(get "$ANOM_RC3" '.openActs | length')" "1"

# ---------------------------------------------------------------------------
# reconcile: deferred -> journals NOTHING; prints "deferred: ..." with the
# reason naming the unconfirmable write-only key(s) — never a silent "done".
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" act-intent rc4 admin AC4 admin --criterion '{"criterionId":"AC4","kinds":["human-action"],"action":"Trigger webhook"}' --write-set "$WS_WO" >/dev/null )
JF_RC4="$WORK/.qa/runs/rc4/journal.ndjson"
LINES_BEFORE_RC4="$(wc -l < "$JF_RC4" | tr -d ' ')"

RECON_DEFERRED_OUT="$( cd "$WORK" && bash "$REBAKE" reconcile rc4 admin AC4 admin --write-set "$WS_WO" --readbacks "$RB_WO_NOTFOUND" )"
LAST_LINE_RC4="$(tail -n1 <<< "$RECON_DEFERRED_OUT")"
check "reconcile deferred: last line starts with 'deferred:'" \
  "$([[ "$LAST_LINE_RC4" == deferred:* ]] && echo yes || echo no)" "yes"
check "reconcile deferred: last line names the unconfirmable key w1" \
  "$([[ "$LAST_LINE_RC4" == *w1* ]] && echo yes || echo no)" "yes"
check "reconcile deferred: NEVER a silent 'done' (last line != done)" \
  "$([[ "$LAST_LINE_RC4" != "done" ]] && echo yes || echo no)" "yes"
check "reconcile deferred: journals NOTHING (journal line count unchanged)" \
  "$(wc -l < "$JF_RC4" | tr -d ' ')" "$LINES_BEFORE_RC4"
check "reconcile deferred: no checkpoint.json was created for rc4" \
  "$([[ -e "$WORK/.qa/runs/rc4/checkpoint.json" ]] && echo exists || echo none)" "none"

# ---------------------------------------------------------------------------
# reconcile: rejects a malformed invocation (missing --write-set/--readbacks
# or wrong positional count) — nothing journaled.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$REBAKE" reconcile rc5 admin AC5 admin --write-set "$WS_ALL" >/dev/null 2>&1 ); rc_no_rb=$?
check "reconcile: missing --readbacks rejected (nonzero)" "$([[ $rc_no_rb -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "reconcile: missing --readbacks writes nothing" \
  "$([[ -e "$WORK/.qa/runs/rc5/journal.ndjson" ]] && echo exists || echo none)" "none"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"

# ---------------------------------------------------------------------------
# dual-engine equivalence: classify + reconcile (landed AND partial paths)
# under jq (default) vs. python3 (jq masked from PATH), same run-ids in two
# separate work dirs, canonically compared (t / timestamps stripped).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin-rebake"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash node; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  # classify (pure, no filesystem) under jq vs python3-forced-via-masked-PATH
  OUT_JQ="$(bash "$REBAKE" classify --write-set "$WS_THREE" --readbacks "$RB_SOME")"
  OUT_PY="$(PATH="$FAKEBIN" "$BASH_BIN" "$REBAKE" classify --write-set "$WS_THREE" --readbacks "$RB_SOME")"
  canon_jq="$(bash "$JOURNAL" canonical <<< "$OUT_JQ")"
  canon_py="$(bash "$JOURNAL" canonical <<< "$OUT_PY")"
  check "dual-equiv: classify partial summary canonically equal across engines" "$canon_jq" "$canon_py"

  OUT_JQ_DEF="$(bash "$REBAKE" classify --write-set "$WS_MIX" --readbacks "$RB_MIX_WO_UNFOUND")"
  OUT_PY_DEF="$(PATH="$FAKEBIN" "$BASH_BIN" "$REBAKE" classify --write-set "$WS_MIX" --readbacks "$RB_MIX_WO_UNFOUND")"
  canon_jq_def="$(bash "$JOURNAL" canonical <<< "$OUT_JQ_DEF")"
  canon_py_def="$(bash "$JOURNAL" canonical <<< "$OUT_PY_DEF")"
  check "dual-equiv: classify deferred summary canonically equal across engines" "$canon_jq_def" "$canon_py_def"

  # reconcile (landed) under jq vs python3 (forced by masking jq from PATH
  # for journal-emit.sh/checkpoint.sh/fold.sh/rebake.sh all together, since
  # checkpoint.sh's own engine choice is PATH-driven, not QA_ENGINE-driven).
  WORK_JQ="$WORK/dual-jq"; WORK_PY="$WORK/dual-py"
  mkdir -p "$WORK_JQ" "$WORK_PY"

  run_landed_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-rc admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$REBAKE" reconcile dual-rc admin AC1 admin --write-set "$WS_ALL" --readbacks "$RB_ALL" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$FOLD" dual-rc >/dev/null )
  }
  run_landed_scenario "$WORK_JQ"
  run_landed_scenario "$WORK_PY" --py

  jq_journal="$(jq -c 'del(.t)' "$WORK_JQ/.qa/runs/dual-rc/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  py_journal="$(jq -c 'del(.t)' "$WORK_PY/.qa/runs/dual-rc/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  check "dual-equiv: reconcile-landed journal.ndjson canonically equal across engines (t stripped)" "$jq_journal" "$py_journal"

  canon_jq_anom="$(bash "$JOURNAL" canonical < "$WORK_JQ/.qa/runs/dual-rc/fold-anomalies.json")"
  canon_py_anom="$(bash "$JOURNAL" canonical < "$WORK_PY/.qa/runs/dual-rc/fold-anomalies.json")"
  check "dual-equiv: reconcile-landed fold-anomalies.json canonically equal across engines" "$canon_jq_anom" "$canon_py_anom"

  check "dual-equiv: jq-side openActs empty after reconcile-landed" \
    "$(jq '.openActs | length' "$WORK_JQ/.qa/runs/dual-rc/fold-anomalies.json")" "0"
  check "dual-equiv: py-side openActs empty after reconcile-landed" \
    "$(jq '.openActs | length' "$WORK_PY/.qa/runs/dual-rc/fold-anomalies.json")" "0"

  # reconcile (partial) under jq vs python3 -- checkpoint.json's last_action
  # canonical comparison (checkpointed_at/updated_at stripped, same idiom as
  # tests/journal-emit/run.sh's norm_ckpt).
  WORK_JQ_P="$WORK/dual-jq-partial"; WORK_PY_P="$WORK/dual-py-partial"
  mkdir -p "$WORK_JQ_P" "$WORK_PY_P"

  run_partial_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-rcp admin AC2 admin --criterion '{"criterionId":"AC2","kinds":["human-action"],"action":"Create three founders"}' --write-set "$WS_THREE" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$REBAKE" reconcile dual-rcp admin AC2 admin --write-set "$WS_THREE" --readbacks "$RB_SOME" >/dev/null )
  }
  run_partial_scenario "$WORK_JQ_P"
  run_partial_scenario "$WORK_PY_P" --py

  norm_ckpt() { jq -c '.updated_at = null | .criteria[]?.checkpointed_at = null' "$1" | bash "$JOURNAL" canonical; }
  canon_jq_ckpt="$(norm_ckpt "$WORK_JQ_P/.qa/runs/dual-rcp/checkpoint.json")"
  canon_py_ckpt="$(norm_ckpt "$WORK_PY_P/.qa/runs/dual-rcp/checkpoint.json")"
  check "dual-equiv: reconcile-partial checkpoint.json canonically equal across engines (timestamps stripped)" "$canon_jq_ckpt" "$canon_py_ckpt"

  py_last_action="$(jq -r '.criteria[] | select(.criterion_id=="AC2") | .last_action' "$WORK_PY_P/.qa/runs/dual-rcp/checkpoint.json")"
  check "dual-equiv: py-side last_action names missing key f2" "$([[ "$py_last_action" == *f2* ]] && echo yes || echo no)" "yes"
  check "dual-equiv: py-side last_action names missing key f3" "$([[ "$py_last_action" == *f3* ]] && echo yes || echo no)" "yes"

  echo "note - dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - dual-engine sub-case: jq or python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
