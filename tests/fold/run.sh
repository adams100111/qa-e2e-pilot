#!/usr/bin/env bash
# tests/fold/run.sh — TDD suite for fold(journal) (Plan A Task 2). Exercises
# fold.sh (dispatcher) end-to-end against three fixtures, then a dual-engine
# (jq vs jq-masked/python3) canonical-equivalence check and an AC-1
# regenerate-is-idempotent check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FOLD="$HERE/../../skills/checkpointing-qa-memory/scripts/fold.sh"
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
FIXTURES="$HERE/fixtures"
PASS=0; FAIL=0

get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

seed_run() {
  local run_id="$1" fixture="$2"
  mkdir -p "$WORK/.qa/runs/${run_id}"
  cp "$FIXTURES/${fixture}" "$WORK/.qa/runs/${run_id}/journal.ndjson"
}

# ---------------------------------------------------------------------------
# Case: basic — three tuples, one shared, one persona, one superseding verdict
# ---------------------------------------------------------------------------
seed_run basic-run basic.ndjson
( cd "$WORK" && bash "$FOLD" basic-run >/dev/null ); rc_basic=$?
CKPT="$WORK/.qa/runs/basic-run/checkpoint.json"

check "basic: exit 0"              "$rc_basic"                                          "0"
check "basic: run_id"              "$(get "$CKPT" '.run_id')"                           "authz-run"
check "basic: criteria order"      "$(get "$CKPT" '[.criteria[].criterion_id] | join(",")')" "C3,C1"
check "basic: C1 verdict (last-wins, seq7 pass not seq6 fail)" \
  "$(get "$CKPT" '.criteria[] | select(.criterion_id=="C1") | .verdict')" "pass"
check "basic: C1 bug_ref cleared by superseding pass" \
  "$(get "$CKPT" '.criteria[] | select(.criterion_id=="C1") | .bug_ref')" "null"
check "basic: C3 persona is empty string (__shared__ -> \"\")" \
  "$(get "$CKPT" '.criteria[] | select(.criterion_id=="C3") | .persona')" ""
check "basic: C1 persona alice" \
  "$(get "$CKPT" '.criteria[] | select(.criterion_id=="C1") | .persona')" "alice"
check "basic: updated_at == max event t" "$(get "$CKPT" '.updated_at')" "2026-09-01T10:00:06Z"
check "basic: fold-anomalies.json empty" \
  "$(get "$WORK/.qa/runs/basic-run/fold-anomalies.json" '.anomalies | length')" "0"

# ---------------------------------------------------------------------------
# Case: torn — truncated last line is dropped, not a crash; the already-
# durable PRECEDING verdict for the same tuple (seq 6, a real complete line)
# survives untouched, only the superseding seq-7 pass is lost.
# ---------------------------------------------------------------------------
seed_run torn-run torn.ndjson
( cd "$WORK" && bash "$FOLD" torn-run >/dev/null ); rc_torn=$?
TCKPT="$WORK/.qa/runs/torn-run/checkpoint.json"
TANOM="$WORK/.qa/runs/torn-run/fold-anomalies.json"

check "torn: exit 0 (does not error on a torn line)" "$rc_torn" "0"
check "torn: criteria present (C3 + C1, C1 keeps its last VALID verdict)" \
  "$(get "$TCKPT" '[.criteria[].criterion_id] | sort | join(",")')" "C1,C3"
check "torn: C1 verdict is the last VALID one (seq6 fail; seq7 pass was torn)" \
  "$(get "$TCKPT" '.criteria[] | select(.criterion_id=="C1") | .verdict')" "fail"
check "torn: fold-anomalies.json records the torn line" \
  "$(get "$TANOM" '[.anomalies[] | select(.rule=="unparseable-line" and .line==7)] | length')" "1"

# ---------------------------------------------------------------------------
# Case: malformed-classes — one of each named anomaly class
# ---------------------------------------------------------------------------
seed_run mal-run malformed-classes.ndjson
( cd "$WORK" && bash "$FOLD" mal-run >/dev/null ); rc_mal=$?
MCKPT="$WORK/.qa/runs/mal-run/checkpoint.json"
MANOM="$WORK/.qa/runs/mal-run/fold-anomalies.json"

check "malformed: exit 0" "$rc_mal" "0"
check "malformed: CX verdict record IS present (record-the-verdict rule)" \
  "$(get "$MCKPT" '.criteria[] | select(.criterion_id=="CX") | .verdict')" "pass"
check "malformed: verdict-without-started anomaly for CX" \
  "$(get "$MANOM" '[.anomalies[] | select(.rule=="verdict-without-started" and .criterionId=="CX")] | length')" "1"
check "malformed: duplicate-plan-frozen anomaly" \
  "$(get "$MANOM" '[.anomalies[] | select(.rule=="duplicate-plan-frozen")] | length')" "1"
check "malformed: act-committed-no-intent anomaly for m:__shared__:CY" \
  "$(get "$MANOM" '[.anomalies[] | select(.rule=="act-committed-no-intent" and .key=="m:__shared__:CY")] | length')" "1"
check "malformed: unknown-event anomaly for totally_unknown" \
  "$(get "$MANOM" '[.anomalies[] | select(.rule=="unknown-event" and .event=="totally_unknown")] | length')" "1"

# ---------------------------------------------------------------------------
# Case: acts — act_intent/act_committed openActs computation (Finding-1
# regression: fold.jq's openActs pipe used to rebind `.` to the committed-set
# object before calling has(.), causing a jq type error / crash on ANY
# act_intent event). K1 is intent+committed (excluded from openActs); K2 is
# intent-only (open); K2b is committed with no matching intent (anomaly).
# Also doubles as the persona-verbatim regression (Finding 3): C2's
# personaId is the LITERAL string "__shared__" (as opposed to basic.ndjson's
# C3, whose scenarioId is "__shared__" and personaId is already "") — the
# emitted `persona` field must be personaId AS-IS, with no collapse.
# ---------------------------------------------------------------------------
seed_run acts-run acts.ndjson
( cd "$WORK" && bash "$FOLD" acts-run >/dev/null ); rc_acts=$?
ACKPT="$WORK/.qa/runs/acts-run/checkpoint.json"
AANOM="$WORK/.qa/runs/acts-run/fold-anomalies.json"

check "acts: exit 0 (no jq crash on act_intent)" "$rc_acts" "0"
check "acts: openActs == [K2] (K1 committed, excluded)" \
  "$(get "$AANOM" '.openActs | join(",")')" "K2"
check "acts: act-committed-no-intent anomaly for K2b" \
  "$(get "$AANOM" '[.anomalies[] | select(.rule=="act-committed-no-intent" and .key=="K2b")] | length')" "1"
check "acts: C1 persona verbatim (personaId \"alice\")" \
  "$(get "$ACKPT" '.criteria[] | select(.criterion_id=="C1") | .persona')" "alice"
check "acts: C2 persona verbatim (literal personaId \"__shared__\", NOT collapsed)" \
  "$(get "$ACKPT" '.criteria[] | select(.criterion_id=="C2") | .persona')" "__shared__"

# ---------------------------------------------------------------------------
# Case: dual-equiv — fold the SAME journal under jq, then again with jq
# masked from PATH (forcing python3 for BOTH the line-parse and reduce
# passes), canonicalize both checkpoint.json outputs via journal.sh
# canonical, and assert they are STRING-EQUAL. Run for basic AND (as a
# second, independent malformed-class case) malformed-classes, since a
# divergence is far more likely to hide in the anomaly-rule branches than
# in the happy path.
# ---------------------------------------------------------------------------
dual_equiv_case() {
  local label="$1" fixture="$2"
  local run_jq="dual-${label}-jq" run_py="dual-${label}-py"
  seed_run "$run_jq" "$fixture"
  seed_run "$run_py" "$fixture"

  ( cd "$WORK" && bash "$FOLD" "$run_jq" >/dev/null 2>&1 )
  local rc_jq=$?

  local FAKEBIN="$WORK/fakebin-${label}"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash; do
    local tp; tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tp" ]] && ln -sf "$tp" "$FAKEBIN/$tool"
  done
  ( cd "$WORK" && PATH="$FAKEBIN" bash "$FOLD" "$run_py" >/dev/null 2>&1 )
  local rc_py=$?

  check "dual-equiv ${label}: jq run exit 0" "$rc_jq" "0"
  check "dual-equiv ${label}: python3 run exit 0" "$rc_py" "0"

  local canon_jq canon_py
  canon_jq="$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/${run_jq}/checkpoint.json")"
  canon_py="$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/${run_py}/checkpoint.json")"
  check "dual-equiv ${label}: checkpoint.json canonically equal across engines" "$canon_jq" "$canon_py"

  local canon_anom_jq canon_anom_py
  canon_anom_jq="$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/${run_jq}/fold-anomalies.json")"
  canon_anom_py="$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/${run_py}/fold-anomalies.json")"
  check "dual-equiv ${label}: fold-anomalies.json canonically equal across engines" "$canon_anom_jq" "$canon_anom_py"
}

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  dual_equiv_case basic basic.ndjson
  dual_equiv_case malformed malformed-classes.ndjson
  # acts.ndjson under both engines -- closes the coverage gap that let the
  # Finding-1 openActs jq crash ship: dual-equiv previously never exercised
  # an act_intent event under the jq engine at all.
  dual_equiv_case acts acts.ndjson
else
  echo "SKIP - dual-equiv: jq or python3 not present on this host, cannot exercise both engines"
fi

# ---------------------------------------------------------------------------
# Case: poisoned-jq — QA_ENGINE=python3 must actually FORCE python3, not
# just happen to be picked because jq was absent. Put a `jq` on PATH that
# always fails (exit 1, no stdout); if has_jq() ever consulted it (auto-
# detect, or a broken override), fold.jq would never run and every jq-branch
# call would error. Asserting success + a correct checkpoint here is proof
# the python3 engine actually ran. Regression guard for checkpoint.sh's
# ext_path leak (${BASH%/*} re-exposing a real jq that would have masked
# this) -- output being byte-identical either engine is exactly why that
# leak shipped silently, so this asserts the MECHANISM, not just output.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  seed_run poisoned-run basic.ndjson
  POISONBIN="$WORK/poisonbin"
  mkdir -p "$POISONBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tp" ]] && ln -sf "$tp" "$POISONBIN/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' > "$POISONBIN/jq"
  chmod +x "$POISONBIN/jq"

  ( cd "$WORK" && QA_ENGINE=python3 PATH="$POISONBIN" bash "$FOLD" poisoned-run >/dev/null 2>&1 ); rc_poison=$?
  PCKPT="$WORK/.qa/runs/poisoned-run/checkpoint.json"
  check "poisoned-jq: QA_ENGINE=python3 fold exit 0" "$rc_poison" "0"
  check "poisoned-jq: checkpoint criteria order (same as basic case)" \
    "$(get "$PCKPT" '[.criteria[].criterion_id] | join(",")')" "C3,C1"
  check "poisoned-jq: C1 verdict correct (proves real reduce ran, not the poisoned jq)" \
    "$(get "$PCKPT" '.criteria[] | select(.criterion_id=="C1") | .verdict')" "pass"

  # Optional sanity: without the override, auto-detect finds the poisoned jq
  # first and the fold fails -- proving the poisoned jq is really reachable
  # and this isn't a no-op regression guard.
  seed_run poisoned-run-nooverride basic.ndjson
  ( cd "$WORK" && PATH="$POISONBIN" bash "$FOLD" poisoned-run-nooverride >/dev/null 2>&1 ); rc_poison_no=$?
  check "unset QA_ENGINE + poisoned jq: fold fails (auto-detect picked the poisoned jq)" \
    "$([[ $rc_poison_no -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  echo "note - poisoned-jq sub-case: RAN (QA_ENGINE=python3 override proven against a jq that always fails)"
else
  echo "SKIP - poisoned-jq sub-case: python3 not present on this host"
fi

# ---------------------------------------------------------------------------
# Case: regenerate — AC-1. fold.sh on basic, delete checkpoint.json, fold.sh
# again -> canonically-equal to the first (a full re-fold from the journal
# alone reproduces the same checkpoint, since fold is a pure function of the
# journal).
# ---------------------------------------------------------------------------
seed_run regen-run basic.ndjson
( cd "$WORK" && bash "$FOLD" regen-run >/dev/null )
canon_first="$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/regen-run/checkpoint.json")"
rm -f "$WORK/.qa/runs/regen-run/checkpoint.json"
( cd "$WORK" && bash "$FOLD" regen-run >/dev/null ); rc_regen=$?
canon_second="$(bash "$JOURNAL" canonical < "$WORK/.qa/runs/regen-run/checkpoint.json")"

check "regenerate (AC-1): second fold exit 0" "$rc_regen" "0"
check "regenerate (AC-1): re-fold canonically equal to first" "$canon_second" "$canon_first"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
