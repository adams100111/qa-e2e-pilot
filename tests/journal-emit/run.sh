#!/usr/bin/env bash
# tests/journal-emit/run.sh — TDD suite for journal-emit.sh (durable-resume
# Plan B, Task 1): started/freeze/amend feed the fold's cursor; .qa/runs/latest
# is written on the first event of a run regardless of which entrypoint gets
# there first (journal-emit.sh or checkpoint.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EMIT="$HERE/../../skills/checkpointing-qa-memory/scripts/journal-emit.sh"
FOLD="$HERE/../../skills/checkpointing-qa-memory/scripts/fold.sh"
CKPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0

get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PLAN_R1='{"criteria":[{"criterionId":"C1","scenarioId":"admin","personaId":"admin","mutates":false}],"order":["C1"]}'

# ---------------------------------------------------------------------------
# Case: started — appends a criterion_started line with the right ids, and
# (since this is the first event of the run) writes run_started + .qa/runs/latest.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started r1 admin C1 admin >/dev/null )
JF1="$WORK/.qa/runs/r1/journal.ndjson"

check "started: two lines (run_started + criterion_started)" "$(wc -l < "$JF1" | tr -d ' ')" "2"
check "started: line1 event run_started"     "$(sed -n 1p "$JF1" | jq -r '.event')"       "run_started"
check "started: line1 runId"                 "$(sed -n 1p "$JF1" | jq -r '.runId')"       "r1"
check "started: line2 event criterion_started" "$(sed -n 2p "$JF1" | jq -r '.event')"     "criterion_started"
check "started: line2 scenarioId"             "$(sed -n 2p "$JF1" | jq -r '.scenarioId')" "admin"
check "started: line2 criterionId"            "$(sed -n 2p "$JF1" | jq -r '.criterionId')" "C1"
check "started: line2 personaId"              "$(sed -n 2p "$JF1" | jq -r '.personaId')"  "admin"
check "started: .qa/runs/latest == r1"        "$(cat "$WORK/.qa/runs/latest" 2>/dev/null)" "r1"

# ---------------------------------------------------------------------------
# Case: started (shared criterion, personaId "") + a checkpoint.sh verdict
# for the SAME tuple -> fold's cursor reflects it, and fold-anomalies.json
# has NO verdict-without-started for that tuple (proves emission feeds the
# fold). scenarioId "__shared__" / personaId "" matches checkpoint.sh's own
# ADR-0012 identity convention (scenarioId == persona, or "__shared__" when
# no --persona) so the two events land on the SAME tuple key.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started r1 __shared__ C0 "" >/dev/null )
( cd "$WORK" && bash "$CKPT" r1 C0 pass --last-action "checked" >/dev/null )
( cd "$WORK" && bash "$FOLD" r1 >/dev/null )
ANOM1="$WORK/.qa/runs/r1/fold-anomalies.json"
CUR1="$WORK/.qa/runs/r1/cursor.json"

check "started+verdict: no verdict-without-started for C0" \
  "$(get "$ANOM1" '[.anomalies[] | select(.rule=="verdict-without-started" and .criterionId=="C0")] | length')" "0"
check "started+verdict: cursor.json criteria_total >= 1" \
  "$(get "$CUR1" '(.criteria_total >= 1)')" "true"
check "started+verdict: cursor.json run_id == r1 (run_started emitted by journal-emit)" \
  "$(get "$CUR1" '.run_id')" "r1"

# Also verdict the r1/admin/C1 tuple from the very first "started" case
# above, so it stops being a pending started-without-verdict tuple before
# the next case introduces a NEW pending one.
( cd "$WORK" && bash "$CKPT" r1 C1 pass --persona admin --last-action "checked" >/dev/null )

# A second tuple started-without-verdict -> cursor points at it.
( cd "$WORK" && bash "$EMIT" started r1 user C2 user >/dev/null )
( cd "$WORK" && bash "$FOLD" r1 >/dev/null )
CUR1B="$WORK/.qa/runs/r1/cursor.json"
check "started-without-verdict: cursor points at the pending tuple (scenarioId)" \
  "$(get "$CUR1B" '.cursor.scenarioId')" "user"
check "started-without-verdict: cursor points at the pending tuple (criterionId)" \
  "$(get "$CUR1B" '.cursor.criterionId')" "C2"

# ---------------------------------------------------------------------------
# Case: freeze — appends plan_frozen; run_started precedes it (freeze is the
# first event); .qa/runs/latest is (re)written to the new run.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" freeze r2 "$PLAN_R1" >/dev/null )
JF2="$WORK/.qa/runs/r2/journal.ndjson"

check "freeze: two lines (run_started + plan_frozen)" "$(wc -l < "$JF2" | tr -d ' ')" "2"
check "freeze: line1 event run_started" "$(sed -n 1p "$JF2" | jq -r '.event')" "run_started"
check "freeze: line2 event plan_frozen" "$(sed -n 2p "$JF2" | jq -r '.event')" "plan_frozen"
check "freeze: plan_frozen criteria[0].criterionId" \
  "$(sed -n 2p "$JF2" | jq -r '.criteria[0].criterionId')" "C1"
check "freeze: plan_frozen order == [C1]" \
  "$(sed -n 2p "$JF2" | jq -c '.order')" '["C1"]'
check "freeze: .qa/runs/latest == r2" "$(cat "$WORK/.qa/runs/latest" 2>/dev/null)" "r2"

# ---------------------------------------------------------------------------
# Case: a SECOND freeze on the same run -> plan_amended for the new
# criterion only, NOT a duplicate plan_frozen. fold-anomalies.json must show
# ZERO duplicate-plan-frozen anomalies. A criterion tuple already covered by
# the first freeze is NOT re-amended.
# ---------------------------------------------------------------------------
PLAN_R1_PLUS='{"criteria":[{"criterionId":"C1","scenarioId":"admin","personaId":"admin","mutates":false},{"criterionId":"C3","scenarioId":"__shared__","personaId":"","mutates":true}],"order":["C1","C3"]}'
( cd "$WORK" && bash "$EMIT" freeze r2 "$PLAN_R1_PLUS" >/dev/null )

check "second freeze: still only ONE plan_frozen line in the journal" \
  "$(jq -s '[.[] | select(.event=="plan_frozen")] | length' "$JF2")" "1"
check "second freeze: exactly one plan_amended line, for C3 only" \
  "$(jq -s -r '[.[] | select(.event=="plan_amended")] | length' "$JF2")" "1"
check "second freeze: plan_amended criterionId == C3" \
  "$(jq -s -r '[.[] | select(.event=="plan_amended")][0].criterionId' "$JF2")" "C3"
check "second freeze: plan_amended mutates is JSON boolean true" \
  "$(jq -s -r '[.[] | select(.event=="plan_amended")][0].mutates' "$JF2")" "true"

( cd "$WORK" && bash "$FOLD" r2 >/dev/null )
ANOM2="$WORK/.qa/runs/r2/fold-anomalies.json"
check "second freeze: NO duplicate-plan-frozen anomaly" \
  "$(get "$ANOM2" '[.anomalies[] | select(.rule=="duplicate-plan-frozen")] | length')" "0"

# A THIRD freeze re-supplying the SAME criteria (C1 + C3, nothing new) ->
# zero new plan_amended events (both tuples already known).
( cd "$WORK" && bash "$EMIT" freeze r2 "$PLAN_R1_PLUS" >/dev/null 2>&1 )
check "third freeze (nothing new): still exactly one plan_amended line total" \
  "$(jq -s -r '[.[] | select(.event=="plan_amended")] | length' "$JF2")" "1"

# ---------------------------------------------------------------------------
# Case: --force freeze deliberately appends a SECOND plan_frozen (the
# escape hatch) -- this DOES reproduce the duplicate-plan-frozen anomaly,
# proving --force actually bypasses the idempotent guard rather than being
# a silent no-op.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" freeze r2 "$PLAN_R1" --force >/dev/null )
check "force freeze: TWO plan_frozen lines now" \
  "$(jq -s '[.[] | select(.event=="plan_frozen")] | length' "$JF2")" "2"
( cd "$WORK" && bash "$FOLD" r2 >/dev/null )
ANOM2B="$WORK/.qa/runs/r2/fold-anomalies.json"
check "force freeze: duplicate-plan-frozen anomaly now present" \
  "$(get "$ANOM2B" '[.anomalies[] | select(.rule=="duplicate-plan-frozen")] | length')" "1"

# ---------------------------------------------------------------------------
# Case: amend — direct subcommand, independent of freeze.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started r3 __shared__ CX "" >/dev/null )
( cd "$WORK" && bash "$EMIT" amend r3 C9 __shared__ "" true >/dev/null )
JF3="$WORK/.qa/runs/r3/journal.ndjson"
check "amend: a plan_amended line exists for C9" \
  "$(jq -s -r '[.[] | select(.event=="plan_amended" and .criterionId=="C9")] | length' "$JF3")" "1"
check "amend: mutates is JSON boolean true (not the string \"true\")" \
  "$(jq -s -r '[.[] | select(.event=="plan_amended" and .criterionId=="C9")][0].mutates | type' "$JF3")" "boolean"

# amend rejects a non-boolean mutates value, nothing written.
LINES_BEFORE="$(wc -l < "$JF3" | tr -d ' ')"
( cd "$WORK" && bash "$EMIT" amend r3 C8 __shared__ "" maybe >/dev/null 2>&1 ); rc_bad_mutates=$?
check "amend: invalid mutates value rejected (nonzero)" "$([[ $rc_bad_mutates -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "amend: invalid mutates value writes nothing" "$(wc -l < "$JF3" | tr -d ' ')" "$LINES_BEFORE"

# ---------------------------------------------------------------------------
# Case: freeze rejects a malformed plan-json shape (missing 'order') --
# nothing written.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" freeze r4 '{"criteria":[]}' >/dev/null 2>&1 ); rc_bad_plan=$?
check "freeze: malformed plan-json (missing order) rejected" "$([[ $rc_bad_plan -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "freeze: malformed plan-json writes nothing" "$([[ -f "$WORK/.qa/runs/r4/journal.ndjson" ]] && echo exists || echo none)" "none"

# ---------------------------------------------------------------------------
# Case: checkpoint.sh upsert (verdict-first, no journal-emit call at all)
# ALSO writes .qa/runs/latest — proves the pointer is set regardless of
# which entrypoint starts a run.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$CKPT" r5 CY pass --last-action "checked" >/dev/null )
check "checkpoint.sh verdict-first: .qa/runs/latest == r5" "$(cat "$WORK/.qa/runs/latest" 2>/dev/null)" "r5"

# .qa/runs/latest reflects the MOST RECENTLY started run (last-write-wins,
# each new run's first event overwrites the pointer).
( cd "$WORK" && bash "$EMIT" started r6 __shared__ C1 "" >/dev/null )
check "latest pointer: most recently started run wins (r6)" "$(cat "$WORK/.qa/runs/latest" 2>/dev/null)" "r6"

echo "---"; echo "PASS=$PASS FAIL=$FAIL (jq default engine)"

# ---------------------------------------------------------------------------
# dual-engine equivalence: repeat the started+freeze+second-freeze+verdict
# scenario once under jq (default) and once with jq masked from PATH
# (forcing python3 for journal-emit.sh, journal.sh, checkpoint.sh AND
# fold.sh), using the SAME run-id in two SEPARATE work dirs (so run_id
# itself doesn't need masking), then canonically compare journal.ndjson
# (with its live-stamped `t` fields zeroed -- wall-clock time is the only
# genuinely non-deterministic field two real, separately-timed invocations
# can differ on) and checkpoint.json/fold-anomalies.json/cursor.json (the
# latter two carry no timestamps at all) across engines.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  WORK_JQ="$WORK/dual-jq"; WORK_PY="$WORK/dual-py"
  mkdir -p "$WORK_JQ" "$WORK_PY"

  run_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" started dual-run admin C1 admin >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" freeze dual-run "$PLAN_R1" >/dev/null 2>&1 \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" freeze dual-run "$PLAN_R1_PLUS" >/dev/null 2>&1 \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$CKPT" dual-run C1 pass --persona admin --last-action ok >/dev/null 2>&1 \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$FOLD" dual-run >/dev/null )
  }

  run_scenario "$WORK_JQ"
  run_scenario "$WORK_PY" --py

  # normalize away live-stamped `t` (journal.ndjson lines) / checkpointed_at
  # / updated_at (checkpoint.json) before comparing -- everything else must
  # be byte-identical.
  norm_journal() { jq -c 'del(.t)' "$1" | bash "$JOURNAL" canonical; }
  norm_ckpt()    { jq -c '.updated_at = null | .criteria[]?.checkpointed_at = null' "$1" | bash "$JOURNAL" canonical; }

  jq_journal_lines="$(jq -c 'del(.t)' "$WORK_JQ/.qa/runs/dual-run/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  py_journal_lines="$(jq -c 'del(.t)' "$WORK_PY/.qa/runs/dual-run/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  check "dual-equiv: journal.ndjson canonically equal across engines (t stripped)" "$jq_journal_lines" "$py_journal_lines"

  canon_jq_ckpt="$(norm_ckpt "$WORK_JQ/.qa/runs/dual-run/checkpoint.json")"
  canon_py_ckpt="$(norm_ckpt "$WORK_PY/.qa/runs/dual-run/checkpoint.json")"
  check "dual-equiv: checkpoint.json canonically equal across engines (timestamps stripped)" "$canon_jq_ckpt" "$canon_py_ckpt"

  canon_jq_anom="$(bash "$JOURNAL" canonical < "$WORK_JQ/.qa/runs/dual-run/fold-anomalies.json")"
  canon_py_anom="$(bash "$JOURNAL" canonical < "$WORK_PY/.qa/runs/dual-run/fold-anomalies.json")"
  check "dual-equiv: fold-anomalies.json canonically equal across engines" "$canon_jq_anom" "$canon_py_anom"

  canon_jq_cur="$(bash "$JOURNAL" canonical < "$WORK_JQ/.qa/runs/dual-run/cursor.json")"
  canon_py_cur="$(bash "$JOURNAL" canonical < "$WORK_PY/.qa/runs/dual-run/cursor.json")"
  check "dual-equiv: cursor.json canonically equal across engines" "$canon_jq_cur" "$canon_py_cur"

  check "dual-equiv: py-side journal has exactly one plan_frozen (idempotent guard held under python3 too)" \
    "$(jq -s '[.[] | select(.event=="plan_frozen")] | length' "$WORK_PY/.qa/runs/dual-run/journal.ndjson")" "1"
  check "dual-equiv: py-side journal has exactly one plan_amended (for C3)" \
    "$(jq -s '[.[] | select(.event=="plan_amended")] | length' "$WORK_PY/.qa/runs/dual-run/journal.ndjson")" "1"
  check "dual-equiv: py-side .qa/runs/latest == dual-run" \
    "$(cat "$WORK_PY/.qa/runs/latest" 2>/dev/null)" "dual-run"

  echo "note - dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - dual-engine sub-case: jq or python3 not present on this host"
fi

# ---------------------------------------------------------------------------
# poisoned-jq sub-case: QA_ENGINE=python3 must actually force python3, not
# just happen to be picked because jq is absent. Mirrors tests/journal/run.sh
# and tests/fold/run.sh's identical regression guard.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  POISONBIN="$WORK/poisonbin"
  mkdir -p "$POISONBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$POISONBIN/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' > "$POISONBIN/jq"
  chmod +x "$POISONBIN/jq"

  ( cd "$WORK" && QA_ENGINE=python3 PATH="$POISONBIN" "$BASH_BIN" "$EMIT" started qer1 admin C1 admin >/dev/null 2>&1 ); qerc=$?
  QEJF="$WORK/.qa/runs/qer1/journal.ndjson"
  check "QA_ENGINE=python3 + poisoned jq: started rc 0" "$qerc" "0"
  check "QA_ENGINE=python3 + poisoned jq: criterion_started line present" \
    "$(python3 -c 'import json,sys
found=False
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    if json.loads(line).get("event")=="criterion_started": found=True
print("yes" if found else "no")' "$QEJF" 2>/dev/null)" "yes"

  # Sanity: without the override, auto-detect finds the poisoned jq and fails.
  ( cd "$WORK" && PATH="$POISONBIN" "$BASH_BIN" "$EMIT" started qer2 admin C1 admin >/dev/null 2>&1 ); qerc2=$?
  check "unset QA_ENGINE + poisoned jq: started fails (auto-detect picked the poisoned jq)" \
    "$([[ $qerc2 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  echo "note - poisoned-jq sub-case: RAN"
else
  echo "SKIP - poisoned-jq sub-case: python3 not present on this host"
fi

# ---------------------------------------------------------------------------
# Case: act-intent / act-commit — the mutation-bracketed act emission (Task
# 2). A mutating criterion (kinds:["human-action"]) gets both an act_intent
# and (once the caller emits it) an act_committed for the SAME composite key
# `run:scenario:criterion`; fold's openActs is empty once both exist, and
# NON-empty when only the intent was emitted (simulated crash mid-act). A
# non-mutating criterion's act-intent is a derive-gated no-op: nothing is
# journaled at all.
# ---------------------------------------------------------------------------
MUT_CRIT='{"criterionId":"AC1","kinds":["human-action"],"action":"Create a founder","title":"Create founder"}'
READ_CRIT='{"criterionId":"AC2","kinds":["bake"],"action":"View founder list","title":"View founders"}'
WRITE_SET='[{"entity":"founder","key":"founder-123"}]'

# -- non-mutating: no-op, prints SKIP, nothing journaled (run r7 never touched) --
NONMUT_OUT="$( cd "$WORK" && bash "$EMIT" act-intent r7 admin AC2 admin --criterion "$READ_CRIT" --write-set "$WRITE_SET" )"
NONMUT_RC=$?
check "act-intent non-mutating: exit 0" "$NONMUT_RC" "0"
check "act-intent non-mutating: prints SKIP" "$([[ "$NONMUT_OUT" == SKIP* ]] && echo yes || echo no)" "yes"
check "act-intent non-mutating: no journal file created at all" \
  "$([[ -e "$WORK/.qa/runs/r7/journal.ndjson" ]] && echo exists || echo none)" "none"

# -- mutating: act-intent then act-commit -> openActs empty after both --
( cd "$WORK" && bash "$EMIT" act-intent r8 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WRITE_SET" >/dev/null )
JF8="$WORK/.qa/runs/r8/journal.ndjson"
check "act-intent mutating: act_intent line present" \
  "$(jq -s -r '[.[] | select(.event=="act_intent")] | length' "$JF8")" "1"
check "act-intent mutating: key == run:scenario:criterion" \
  "$(jq -s -r '[.[] | select(.event=="act_intent")][0].key' "$JF8")" "r8:admin:AC1"
check "act-intent mutating: writeSet passed through" \
  "$(jq -s -c '[.[] | select(.event=="act_intent")][0].writeSet' "$JF8")" '[{"entity":"founder","key":"founder-123"}]'

( cd "$WORK" && bash "$EMIT" act-commit r8 admin AC1 admin --outcome landed >/dev/null )
check "act-commit: act_committed line present" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")] | length' "$JF8")" "1"
check "act-commit: key matches the intent's key" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")][0].key' "$JF8")" "r8:admin:AC1"
check "act-commit: outcome == landed" \
  "$(jq -s -r '[.[] | select(.event=="act_committed")][0].outcome' "$JF8")" "landed"

( cd "$WORK" && bash "$FOLD" r8 >/dev/null )
ANOM8="$WORK/.qa/runs/r8/fold-anomalies.json"
check "act-intent+act-commit: openActs EMPTY after both" \
  "$(get "$ANOM8" '.openActs | length')" "0"

# -- crash mid-act: ONLY act-intent emitted (no act-commit) -> openActs non-empty --
( cd "$WORK" && bash "$EMIT" act-intent r9 admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WRITE_SET" >/dev/null )
( cd "$WORK" && bash "$FOLD" r9 >/dev/null )
ANOM9="$WORK/.qa/runs/r9/fold-anomalies.json"
check "act-intent only (simulated crash): openActs has exactly the one key" \
  "$(get "$ANOM9" '.openActs | length')" "1"
check "act-intent only (simulated crash): openActs[0] == run:scenario:criterion key" \
  "$(get "$ANOM9" '.openActs[0]')" "r9:admin:AC1"

# -- act-intent is the FIRST event of a run too: run_started + .qa/runs/latest --
JF10_RUN="r10"
( cd "$WORK" && bash "$EMIT" act-intent "$JF10_RUN" admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WRITE_SET" >/dev/null )
JF10="$WORK/.qa/runs/r10/journal.ndjson"
check "act-intent as first event: run_started precedes act_intent" \
  "$(sed -n 1p "$JF10" | jq -r '.event')" "run_started"
check "act-intent as first event: .qa/runs/latest == r10" \
  "$(cat "$WORK/.qa/runs/latest" 2>/dev/null)" "r10"

# -- act-commit rejects an invalid --outcome; nothing written --
( cd "$WORK" && bash "$EMIT" act-commit r8 admin AC1 admin --outcome bogus >/dev/null 2>&1 ); rc_bad_outcome=$?
check "act-commit: invalid --outcome rejected (nonzero)" "$([[ $rc_bad_outcome -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "act-commit: invalid --outcome writes nothing (line count unchanged)" \
  "$(jq -s 'length' "$JF8")" "3"

# -- act-intent requires --write-set; rejects when missing --
( cd "$WORK" && bash "$EMIT" act-intent r11 admin AC1 admin --criterion "$MUT_CRIT" >/dev/null 2>&1 ); rc_no_ws=$?
check "act-intent: missing --write-set rejected (nonzero)" "$([[ $rc_no_ws -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "act-intent: missing --write-set writes nothing" \
  "$([[ -e "$WORK/.qa/runs/r11/journal.ndjson" ]] && echo exists || echo none)" "none"

# ---------------------------------------------------------------------------
# dual-engine equivalence: act-intent + act-commit under jq vs. python3
# (jq masked from PATH), same run-id in two separate work dirs, canonically
# compared (t stripped).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN_AC="$WORK/fakebin-actbracket"
  mkdir -p "$FAKEBIN_AC"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN_AC/$tool"
  done

  WORK_AC_JQ="$WORK/dual-ac-jq"; WORK_AC_PY="$WORK/dual-ac-py"
  mkdir -p "$WORK_AC_JQ" "$WORK_AC_PY"

  run_act_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN_AC"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual-act admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WRITE_SET" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-commit dual-act admin AC1 admin --outcome landed >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$FOLD" dual-act >/dev/null )
  }

  run_act_scenario "$WORK_AC_JQ"
  run_act_scenario "$WORK_AC_PY" --py

  jq_ac_journal="$(jq -c 'del(.t)' "$WORK_AC_JQ/.qa/runs/dual-act/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  py_ac_journal="$(jq -c 'del(.t)' "$WORK_AC_PY/.qa/runs/dual-act/journal.ndjson" | while read -r l; do echo "$l" | bash "$JOURNAL" canonical; done)"
  check "dual-equiv (act bracket): journal.ndjson canonically equal across engines (t stripped)" "$jq_ac_journal" "$py_ac_journal"

  canon_jq_ac_anom="$(bash "$JOURNAL" canonical < "$WORK_AC_JQ/.qa/runs/dual-act/fold-anomalies.json")"
  canon_py_ac_anom="$(bash "$JOURNAL" canonical < "$WORK_AC_PY/.qa/runs/dual-act/fold-anomalies.json")"
  check "dual-equiv (act bracket): fold-anomalies.json canonically equal across engines" "$canon_jq_ac_anom" "$canon_py_ac_anom"

  check "dual-equiv (act bracket): jq-side openActs empty" \
    "$(jq '.openActs | length' "$WORK_AC_JQ/.qa/runs/dual-act/fold-anomalies.json")" "0"
  check "dual-equiv (act bracket): py-side openActs empty" \
    "$(jq '.openActs | length' "$WORK_AC_PY/.qa/runs/dual-act/fold-anomalies.json")" "0"

  echo "note - dual-engine act-bracket sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - dual-engine act-bracket sub-case: jq or python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
