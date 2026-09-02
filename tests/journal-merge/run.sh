#!/usr/bin/env bash
# tests/journal-merge/run.sh — TDD suite for journal-merge.sh (Task 6,
# durable-substrate plan): fan-out sub-journals (journal.<name>.ndjson) +
# lock + idempotent merge into journal.ndjson with a re-stamped monotonic
# global seq, plus fold's new seq-gap / cross-child-duplicate anomaly rules.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
J="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
M="$HERE/../../skills/checkpointing-qa-memory/scripts/journal-merge.sh"
FOLD="$HERE/../../skills/checkpointing-qa-memory/scripts/fold.sh"
PASS=0; FAIL=0

get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { local d="$WORK"; cd /tmp 2>/dev/null || true; rm -rf "$d"; }
trap cleanup EXIT

append_child() { # run child event-json
  ( cd "$WORK" && bash "$J" append --child "$2" "$1" "$3" >/dev/null )
}

# ---------------------------------------------------------------------------
# Case: basic two-child merge — a and b each append two events; each event
# carries childId/childSeq; no main journal yet.
# ---------------------------------------------------------------------------
RUN=basic-run
append_child "$RUN" a '{"event":"scenario_started","scenarioId":"S1","personaId":"P1"}'
append_child "$RUN" a '{"event":"criterion_verdict","scenarioId":"S1","criterionId":"C1","personaId":"P1","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'
append_child "$RUN" b '{"event":"scenario_started","scenarioId":"S2","personaId":"P2"}'
append_child "$RUN" b '{"event":"criterion_verdict","scenarioId":"S2","criterionId":"C2","personaId":"P2","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'

RUNDIR="$WORK/.qa/runs/$RUN"
MAINJ="$RUNDIR/journal.ndjson"
AJ="$RUNDIR/journal.a.ndjson"
BJ="$RUNDIR/journal.b.ndjson"

check "pre-merge: journal.a.ndjson exists"    "$([[ -f "$AJ" ]] && echo yes || echo no)" "yes"
check "pre-merge: journal.b.ndjson exists"    "$([[ -f "$BJ" ]] && echo yes || echo no)" "yes"
check "pre-merge: main journal absent"        "$([[ -f "$MAINJ" ]] && echo yes || echo no)" "no"
check "pre-merge: a events carry childId"     "$(sed -n 1p "$AJ" | jq -r '.childId')" "a"
check "pre-merge: a events carry childSeq"    "$(sed -n 2p "$AJ" | jq -r '.childSeq')" "2"
check "pre-merge: a events carry no seq"      "$(sed -n 1p "$AJ" | jq -r 'has("seq")')" "false"

( cd "$WORK" && bash "$M" "$RUN" >/dev/null 2>&1 ); rc_merge=$?
check "merge: exit 0" "$rc_merge" "0"
check "merge: main journal has 4 lines" "$(wc -l < "$MAINJ" | tr -d ' ')" "4"
check "merge: seqs contiguous 1..4" "$(jq -c '.seq' "$MAINJ" | tr '\n' ',' )" "1,2,3,4,"
check "merge: child a file removed" "$([[ -f "$AJ" ]] && echo exists || echo gone)" "gone"
check "merge: child b file removed" "$([[ -f "$BJ" ]] && echo exists || echo gone)" "gone"
check "merge: merged events keep childId/childSeq" \
  "$(jq -c '[.childId,.childSeq]' "$MAINJ" | tr '\n' ' ')" \
  '["a",1] ["a",2] ["b",1] ["b",2] '

( cd "$WORK" && bash "$FOLD" "$RUN" >/dev/null ); rc_fold=$?
CKPT="$RUNDIR/checkpoint.json"
ANOM="$RUNDIR/fold-anomalies.json"
check "fold: exit 0" "$rc_fold" "0"
check "fold: both children's verdicts present" \
  "$(get "$CKPT" '[.criteria[].criterion_id] | sort | join(",")')" "C1,C2"
check "fold: no seq-gap anomaly" "$(get "$ANOM" '[.anomalies[] | select(.rule=="seq-gap")] | length')" "0"
check "fold: no cross-child-duplicate anomaly" "$(get "$ANOM" '[.anomalies[] | select(.rule=="cross-child-duplicate")] | length')" "0"

# ---------------------------------------------------------------------------
# Idempotency (grill Q6): simulate a crash that left the (already-merged)
# children re-present — re-create journal.a.ndjson/journal.b.ndjson with the
# SAME content (same childId/childSeq pairs), re-run the merge. Must be a
# no-op on the main journal: no duplicate lines, seq still 1..4.
# ---------------------------------------------------------------------------
append_child "$RUN" a '{"event":"scenario_started","scenarioId":"S1","personaId":"P1"}'
append_child "$RUN" a '{"event":"criterion_verdict","scenarioId":"S1","criterionId":"C1","personaId":"P1","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'
append_child "$RUN" b '{"event":"scenario_started","scenarioId":"S2","personaId":"P2"}'
append_child "$RUN" b '{"event":"criterion_verdict","scenarioId":"S2","criterionId":"C2","personaId":"P2","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'

( cd "$WORK" && bash "$M" "$RUN" >/dev/null 2>&1 ); rc_remerge=$?
check "idempotent re-merge: exit 0" "$rc_remerge" "0"
check "idempotent re-merge: still 4 lines (no duplicates)" "$(wc -l < "$MAINJ" | tr -d ' ')" "4"
check "idempotent re-merge: seqs still contiguous 1..4" "$(jq -c '.seq' "$MAINJ" | tr '\n' ',')" "1,2,3,4,"
check "idempotent re-merge: child files cleaned up again" \
  "$([[ -f "$AJ" || -f "$BJ" ]] && echo exists || echo gone)" "gone"

# A second dedup pass with only ONE child re-created (asserts dedup is per
# (childId,childSeq), not "all-or-nothing" across a whole merge run).
append_child "$RUN" a '{"event":"scenario_started","scenarioId":"S1","personaId":"P1"}'
( cd "$WORK" && bash "$M" "$RUN" >/dev/null 2>&1 ); rc_remerge2=$?
check "idempotent re-merge (single child): exit 0" "$rc_remerge2" "0"
check "idempotent re-merge (single child): still 4 lines" "$(wc -l < "$MAINJ" | tr -d ' ')" "4"

# ---------------------------------------------------------------------------
# Cross-child case (grill Q8): two DIFFERENT children verdict the SAME
# (scenario,criterion,persona) tuple -> cross-child-duplicate anomaly. A
# single child's own repeated verdict for a tuple (normal last-wins) must
# NOT fire this rule -- asserted via the basic-run case above (a and b never
# share a tuple there, so cross-child-duplicate was correctly 0).
# ---------------------------------------------------------------------------
XRUN=cross-run
append_child "$XRUN" a '{"event":"criterion_verdict","scenarioId":"SX","criterionId":"CX","personaId":"PX","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'
append_child "$XRUN" a '{"event":"criterion_verdict","scenarioId":"SX","criterionId":"CX","personaId":"PX","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'
append_child "$XRUN" b '{"event":"criterion_verdict","scenarioId":"SX","criterionId":"CX","personaId":"PX","verdict":"fail","confidence":"high","evidenceRefs":[],"kinds":["state"]}'

( cd "$WORK" && bash "$M" "$XRUN" >/dev/null 2>&1 )
( cd "$WORK" && bash "$FOLD" "$XRUN" >/dev/null 2>&1 ); rc_xfold=$?
XANOM="$WORK/.qa/runs/$XRUN/fold-anomalies.json"
check "cross-child: fold exit 0" "$rc_xfold" "0"
check "cross-child: cross-child-duplicate anomaly present" \
  "$(get "$XANOM" '[.anomalies[] | select(.rule=="cross-child-duplicate" and .tuple=="SX/CX/PX")] | length')" "1"
check "cross-child: single-child's OWN repeat verdict does not itself add a second anomaly" \
  "$(get "$XANOM" '[.anomalies[] | select(.rule=="cross-child-duplicate")] | length')" "1"

# ---------------------------------------------------------------------------
# seq-gap: a hand-crafted main journal with seqs 1,2,4 (3 missing) folds
# with a seq-gap anomaly {"after":2}. No merge involved -- exercises fold
# directly against a journal that could result from a lost/partial merge.
# ---------------------------------------------------------------------------
GRUN=gap-run
GRUNDIR="$WORK/.qa/runs/$GRUN"
mkdir -p "$GRUNDIR"
cat > "$GRUNDIR/journal.ndjson" <<'EOF'
{"event":"run_started","runId":"gap-run","seq":1,"t":"2026-09-01T10:00:00Z"}
{"event":"phase_entered","phase":"verify","seq":2,"t":"2026-09-01T10:00:01Z"}
{"event":"phase_entered","phase":"verify","seq":4,"t":"2026-09-01T10:00:03Z"}
EOF
( cd "$WORK" && bash "$FOLD" "$GRUN" >/dev/null 2>&1 ); rc_gfold=$?
GANOM="$GRUNDIR/fold-anomalies.json"
check "seq-gap: fold exit 0 (does not abort)" "$rc_gfold" "0"
check "seq-gap: anomaly present" "$(get "$GANOM" '[.anomalies[] | select(.rule=="seq-gap" and .after==2)] | length')" "1"

# ---------------------------------------------------------------------------
# mkdir-lock degrade: mask `flock` off PATH (fakebin with everything else
# journal-merge.sh needs) and confirm the merge still runs correctly and
# prints the NOTE about the fallback.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  DRUN=degrade-run
  append_child "$DRUN" a '{"event":"scenario_started","scenarioId":"SD","personaId":"PD"}'
  append_child "$DRUN" a '{"event":"criterion_verdict","scenarioId":"SD","criterionId":"CD","personaId":"PD","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'

  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin-noflock"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc find sort basename grep mktemp jq python3; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tp" ]] && ln -sf "$tp" "$FAKEBIN/$tool"
  done
  # deliberately NOT symlinking flock -- forces the mkdir-lock fallback.

  DRUNDIR="$WORK/.qa/runs/$DRUN"
  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$M" "$DRUN" >"$WORK/degrade.out" 2>"$WORK/degrade.err" ); rc_degrade=$?
  check "mkdir-lock degrade: exit 0" "$rc_degrade" "0"
  check "mkdir-lock degrade: NOTE printed" \
    "$(grep -c "mkdir-based lock" "$WORK/degrade.err" | tr -d ' ')" "1"
  check "mkdir-lock degrade: merge actually happened" \
    "$(wc -l < "$DRUNDIR/journal.ndjson" | tr -d ' ')" "2"
  check "mkdir-lock degrade: child file removed" \
    "$([[ -f "$DRUNDIR/journal.a.ndjson" ]] && echo exists || echo gone)" "gone"
  check "mkdir-lock degrade: no leftover lock dir" \
    "$([[ -d "$DRUNDIR/.journal.lock.d" ]] && echo exists || echo gone)" "gone"
else
  echo "SKIP - mkdir-lock degrade: jq not present on this host"
fi

# ---------------------------------------------------------------------------
# poisoned-jq — QA_ENGINE=python3 must actually FORCE python3 for
# journal-merge.sh too (not just fold.jq/fold.py), against a `jq` on PATH
# that always fails. Combines with the flock-absent fakebin above (no flock
# in POISONBIN either) so this also doubles as a second, independent
# mkdir-lock-degrade proof under the python3 engine.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  PRUN=poisoned-run
  append_child "$PRUN" a '{"event":"scenario_started","scenarioId":"SP","personaId":"PP"}'
  append_child "$PRUN" a '{"event":"criterion_verdict","scenarioId":"SP","criterionId":"CP","personaId":"PP","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":["state"]}'

  POISONBIN="$WORK/poisonbin"
  mkdir -p "$POISONBIN"
  for tool in date mkdir mv rm cat dirname sed wc find sort basename grep mktemp python3 bash; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ "$tp" == /* ]] && ln -sf "$tp" "$POISONBIN/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' > "$POISONBIN/jq"
  chmod +x "$POISONBIN/jq"
  # deliberately no flock in POISONBIN -- exercises the mkdir-lock fallback
  # simultaneously with the engine override.

  PRUNDIR="$WORK/.qa/runs/$PRUN"
  ( cd "$WORK" && QA_ENGINE=python3 PATH="$POISONBIN" bash "$M" "$PRUN" >/dev/null 2>&1 ); rc_poison=$?
  check "poisoned-jq: QA_ENGINE=python3 merge exit 0" "$rc_poison" "0"
  check "poisoned-jq: merged (2 lines, seq 1..2)" "$(jq -c '.seq' "$PRUNDIR/journal.ndjson" | tr '\n' ',')" "1,2,"
  check "poisoned-jq: child file removed" \
    "$([[ -f "$PRUNDIR/journal.a.ndjson" ]] && echo exists || echo gone)" "gone"

  # Optional sanity: WITHOUT the override, auto-detect finds the poisoned jq
  # first and the merge fails -- proving the poisoned jq is really reachable.
  PRUN2=poisoned-run-nooverride
  append_child "$PRUN2" a '{"event":"scenario_started","scenarioId":"SP2","personaId":"PP2"}'
  ( cd "$WORK" && PATH="$POISONBIN" bash "$M" "$PRUN2" >/dev/null 2>&1 ); rc_poison_no=$?
  check "unset QA_ENGINE + poisoned jq: merge fails (auto-detect picked the poisoned jq)" \
    "$([[ $rc_poison_no -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  echo "note - poisoned-jq sub-case: RAN (QA_ENGINE=python3 override proven against a jq that always fails)"
else
  echo "SKIP - poisoned-jq sub-case: python3 not present on this host"
fi

# ---------------------------------------------------------------------------
# Default (no --child) journal_append stays byte-identical: no childId/
# childSeq stamped, main journal.ndjson used directly -- regression guard
# alongside tests/journal/run.sh's own 32 assertions.
# ---------------------------------------------------------------------------
DEFRUN=default-run
( cd "$WORK" && bash "$J" append "$DEFRUN" '{"event":"run_started","runId":"default-run"}' >/dev/null )
DEFJ="$WORK/.qa/runs/$DEFRUN/journal.ndjson"
check "default append: no childId field" "$(jq -r 'has("childId")' "$DEFJ")" "false"
check "default append: no childSeq field" "$(jq -r 'has("childSeq")' "$DEFJ")" "false"
check "default append: has seq" "$(jq -r '.seq' "$DEFJ")" "1"

# ---------------------------------------------------------------------------
# dual-equiv (extends the fold dual-equiv pattern to the two NEW anomaly
# rules): fold the cross-child and seq-gap journals under jq, then again
# with jq masked from PATH (forcing python3 for both line-parse and reduce),
# canonicalize both fold-anomalies.json outputs, assert string-equal.
# ---------------------------------------------------------------------------
dual_equiv_anomalies() {
  local label="$1" src_run="$2"
  local run_jq="dualam-${label}-jq" run_py="dualam-${label}-py"
  mkdir -p "$WORK/.qa/runs/${run_jq}" "$WORK/.qa/runs/${run_py}"
  cp "$WORK/.qa/runs/${src_run}/journal.ndjson" "$WORK/.qa/runs/${run_jq}/journal.ndjson"
  cp "$WORK/.qa/runs/${src_run}/journal.ndjson" "$WORK/.qa/runs/${run_py}/journal.ndjson"

  ( cd "$WORK" && bash "$FOLD" "$run_jq" >/dev/null 2>&1 ); local rc_jq=$?

  local FAKEBIN="$WORK/fakebin-dual-${label}"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash; do
    local tp; tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tp" ]] && ln -sf "$tp" "$FAKEBIN/$tool"
  done
  ( cd "$WORK" && PATH="$FAKEBIN" bash "$FOLD" "$run_py" >/dev/null 2>&1 ); local rc_py=$?

  check "dual-equiv-anomalies ${label}: jq run exit 0" "$rc_jq" "0"
  check "dual-equiv-anomalies ${label}: python3 run exit 0" "$rc_py" "0"

  local canon_jq canon_py
  canon_jq="$(bash "$J" canonical < "$WORK/.qa/runs/${run_jq}/fold-anomalies.json")"
  canon_py="$(bash "$J" canonical < "$WORK/.qa/runs/${run_py}/fold-anomalies.json")"
  check "dual-equiv-anomalies ${label}: fold-anomalies.json canonically equal across engines" "$canon_jq" "$canon_py"
}

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  dual_equiv_anomalies crosschild "$XRUN"
  dual_equiv_anomalies seqgap "$GRUN"
else
  echo "SKIP - dual-equiv-anomalies: jq or python3 not present on this host, cannot exercise both engines"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
