#!/usr/bin/env bash
# tests/qa-verify-phase/run.sh — TDD suite for qa-verify.sh's PHASE-SURFACE
# pass (Run FSM Enforcement Task 3, plan
# docs/superpowers/plans/2026-09-03-run-fsm-enforcement.md).
#
# qa-verify.sh is the phase-surface AUTHORITY: it temporally correlates
# every toolstream.jsonl (H2) call to the phase/acting-window active at that
# moment (from journal.ndjson's phase_entered/act_intent/act_committed
# timeline) and flags a tool used outside its sanctioned surface
# (state-machine.json's phaseToolSurface). Toolstream events carry NO phase
# tag, so correlation is by wall-clock ts (ISO-8601 UTC seconds — lexical
# string comparison is chronological comparison for this format).
#
# Fixtures are HAND-AUTHORED (journal.ndjson + toolstream.jsonl), not built
# via journal.sh/toolstream.sh append — this suite needs EXACT, deterministic
# ts values to exercise "before"/"inside"/"after" temporal placement
# precisely, and journal.sh/toolstream.sh's ts() has only 1-second
# resolution (a real-clock append-based fixture would be flaky). This
# mirrors tests/fold/run.sh's own hand-authored-fixture idiom.
#
# Covers (Step 1 of the plan's Task 3):
#   (a) a mutating browser_evaluate call whose ts falls AFTER phase_entered
#       Report (and after C1's acting window closed) -> a phase-surface
#       finding, confidence:low, reason names the phase ("mixed" run).
#   (b) a mutating browser_click call INSIDE C1's acting window (between
#       act_intent and act_committed) -> NO finding ("mixed" run, same
#       fixture as (a) — proves SELECTIVE flagging: only the outside-window
#       call is flagged).
#   (c) a non-mutating browser_navigate call during Report (forbidden
#       toolClass per phaseToolSurface, independent of the acting-window
#       rule) -> a finding ("duringreport" run).
#   (d) NO toolstream.jsonl at all -> the pass is skipped entirely, no
#       finding ("notoolstream" run).
#   (e) a mutating call whose ts precedes every phase_entered in the journal
#       (can't be placed) -> confidence:low finding, NEVER an override
#       ("undeterminable" run).
#   (clean) a mutating call fully inside its criterion's acting window, no
#       other toolstream traffic -> a genuinely clean run, verification.json
#       == [] (no phase-surface record at all).
#
# Plus a NO-REGRESSION check: this pass must never affect a run that has NO
# journal.ndjson at all (every EXISTING qa-verify fixture) — covered by
# re-running tests/qa-verify/run.sh itself, not duplicated here.
#
# Every assertion runs under BOTH jq (default) and QA_ENGINE=python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QAVERIFY="$HERE/../../scripts/qa-verify.sh"
FIXTURES="$HERE/fixtures"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

vf() { echo "$WORK/.qa/runs/$1/verification.json"; }

# seed_run <run-id> [journal-fixture] [toolstream-fixture] — always writes a
# minimal `{"criteria":[]}` checkpoint.json (qa-verify.sh requires one to
# exist; this suite tests the phase-surface pass in isolation, no pass
# records needed). journal/toolstream fixtures are optional (an absent
# toolstream fixture exercises the "no toolstream -> skip" degrade).
seed_run() {
  local run_id="$1" journal_fx="${2:-}" toolstream_fx="${3:-}"
  local dir="$WORK/.qa/runs/${run_id}"
  mkdir -p "$dir"
  printf '{"criteria":[]}' > "$dir/checkpoint.json"
  [[ -n "$journal_fx" ]] && cp "$FIXTURES/$journal_fx" "$dir/journal.ndjson"
  [[ -n "$toolstream_fx" ]] && cp "$FIXTURES/$toolstream_fx" "$dir/toolstream.jsonl"
}

seed_run mixed mixed.journal.ndjson mixed.toolstream.jsonl
seed_run clean clean.journal.ndjson clean.toolstream.jsonl
seed_run duringreport duringreport.journal.ndjson duringreport.toolstream.jsonl
seed_run notoolstream notoolstream.journal.ndjson ""
seed_run undeterminable undeterminable.journal.ndjson undeterminable.toolstream.jsonl

run_qv() { # <engine: "" | python3> <run>
  local engine="$1" run="$2"
  if [[ -n "$engine" ]]; then
    ( cd "$WORK" && QA_ENGINE="$engine" bash "$QAVERIFY" "$run" )
  else
    ( cd "$WORK" && bash "$QAVERIFY" "$run" )
  fi
}

for ENGINE in "" python3; do
  LABEL="${ENGINE:-jq(default)}"

  # --- (a)+(b) mixed: one call inside the acting window (no finding), one
  # call after Report / outside every window (a finding) — proves selective
  # flagging within the SAME run. -------------------------------------------
  run_qv "$ENGINE" mixed >/dev/null 2>&1
  RC_MIXED=$?
  check "[$LABEL] mixed: qa-verify exits 0 (record-only, never a live block)" "$RC_MIXED" "0"
  check "[$LABEL] mixed: verification.json has exactly 1 record (only the outside-window call)" \
    "$(jq 'length' "$(vf mixed)")" "1"
  check "[$LABEL] mixed: the record is the synthetic phase-surface finding" \
    "$(jq -r '.[0].criterionId' "$(vf mixed)")" "__phase-surface__"
  check "[$LABEL] mixed: verifierVerdict stays pass (record-only, never an override)" \
    "$(jq -r '.[0].verifierVerdict' "$(vf mixed)")" "pass"
  check "[$LABEL] mixed: confidence is low" \
    "$(jq -r '.[0].confidence' "$(vf mixed)")" "low"
  check_contains "[$LABEL] mixed: reason names the active phase (Report)" \
    "$(jq -r '.[0].reasons | join("; ")' "$(vf mixed)")" "Report"
  check_contains "[$LABEL] mixed: reason names the mutating tool (browser_evaluate)" \
    "$(jq -r '.[0].reasons | join("; ")' "$(vf mixed)")" "browser_evaluate"
  check "[$LABEL] mixed: exactly one reason (the in-window click is never flagged)" \
    "$(jq -r '.[0].reasons | length' "$(vf mixed)")" "1"

  # --- clean: a mutating call fully inside its acting window, nothing else
  # -> a genuinely clean run, no phase-surface record at all. -----------------
  run_qv "$ENGINE" clean >/dev/null 2>&1
  RC_CLEAN=$?
  check "[$LABEL] clean: qa-verify exits 0" "$RC_CLEAN" "0"
  check "[$LABEL] clean: verification.json is empty (no phase-surface finding)" \
    "$(jq 'length' "$(vf clean)")" "0"

  # --- (c) duringreport: a non-mutating browser_navigate during Report ->
  # forbidden toolClass per phaseToolSurface (independent of the
  # acting-window rule, which never applies to a non-mutating tool). ---------
  run_qv "$ENGINE" duringreport >/dev/null 2>&1
  RC_DURING=$?
  check "[$LABEL] duringreport: qa-verify exits 0 (record-only)" "$RC_DURING" "0"
  check "[$LABEL] duringreport: verification.json has exactly 1 record" \
    "$(jq 'length' "$(vf duringreport)")" "1"
  check "[$LABEL] duringreport: verifierVerdict stays pass" \
    "$(jq -r '.[0].verifierVerdict' "$(vf duringreport)")" "pass"
  check "[$LABEL] duringreport: confidence is low" \
    "$(jq -r '.[0].confidence' "$(vf duringreport)")" "low"
  check_contains "[$LABEL] duringreport: reason names the phase (Report)" \
    "$(jq -r '.[0].reasons | join("; ")' "$(vf duringreport)")" "Report"
  check_contains "[$LABEL] duringreport: reason names the forbidden toolClass (browser-navigate)" \
    "$(jq -r '.[0].reasons | join("; ")' "$(vf duringreport)")" "browser-navigate"

  # --- (d) notoolstream: journal.ndjson exists (a real timeline) but NO
  # toolstream.jsonl at all -> the phase-surface pass is skipped entirely,
  # never a finding (degrade, matches the H2/H3 no-toolstream posture). ------
  run_qv "$ENGINE" notoolstream >/dev/null 2>&1
  RC_NT=$?
  check "[$LABEL] notoolstream: qa-verify exits 0" "$RC_NT" "0"
  check "[$LABEL] notoolstream: verification.json is empty (pass skipped, not just no violations)" \
    "$(jq 'length' "$(vf notoolstream)")" "0"

  # --- (e) undeterminable: a mutating call whose ts precedes every
  # phase_entered in the journal -> confidence:low, NEVER an override. -------
  run_qv "$ENGINE" undeterminable >/dev/null 2>&1
  RC_UNDET=$?
  check "[$LABEL] undeterminable: qa-verify exits 0 (never a false override)" "$RC_UNDET" "0"
  check "[$LABEL] undeterminable: verification.json has exactly 1 record" \
    "$(jq 'length' "$(vf undeterminable)")" "1"
  check "[$LABEL] undeterminable: verifierVerdict stays pass (NOT overridden)" \
    "$(jq -r '.[0].verifierVerdict' "$(vf undeterminable)")" "pass"
  check "[$LABEL] undeterminable: confidence is low" \
    "$(jq -r '.[0].confidence' "$(vf undeterminable)")" "low"
  check_contains "[$LABEL] undeterminable: reason says the phase could not be determined" \
    "$(jq -r '.[0].reasons | join("; ")' "$(vf undeterminable)")" "undeterminable"
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
