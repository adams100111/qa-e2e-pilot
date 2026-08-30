#!/usr/bin/env bash
# Characterization tests for checkpoint.sh — pin TODAY's behavior (before the
# Phase 1 evidence-gate migration) so the migration can't silently regress
# upsert/resume/list semantics. Must PASS against the unmodified script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
PASS=0; FAIL=0
get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

RUN_ID="test-run-1"
CKPT_FILE="$WORK/.qa/runs/${RUN_ID}/checkpoint.json"

# --- Case 1: upsert insert — creates valid JSON w/ criterion_id=C1 -----------
(cd "$WORK" && bash "$SCRIPT" "$RUN_ID" C1 pass >/dev/null)
check "checkpoint file created"        "$([[ -f "$CKPT_FILE" ]] && echo yes)"        "yes"
check "valid json after insert"        "$(jq -e . "$CKPT_FILE" >/dev/null 2>&1 && echo ok)" "ok"
check "criteria count == 1 after insert" "$(get "$CKPT_FILE" '.criteria | length')" "1"
check "C1 criterion_id present"        "$(get "$CKPT_FILE" '.criteria[0].criterion_id')" "C1"
check "C1 verdict pass"                "$(get "$CKPT_FILE" '.criteria[0].verdict')" "pass"
check "C1 confidence default high"     "$(get "$CKPT_FILE" '.criteria[0].confidence')" "high"
check "C1 phase default verify"        "$(get "$CKPT_FILE" '.criteria[0].phase')" "verify"
check "C1 evidence_refs default []"    "$(get "$CKPT_FILE" '.criteria[0].evidence_refs')" "[]"
check "C1 bug_ref default null"        "$(get "$CKPT_FILE" '.criteria[0].bug_ref')" "null"
check "root run_id"                    "$(get "$CKPT_FILE" '.run_id')" "$RUN_ID"

# --- Case 2: second upsert of C1 REPLACES (not append) -----------------------
(cd "$WORK" && bash "$SCRIPT" "$RUN_ID" C1 fail >/dev/null)
check "criteria count still 1 after replace" "$(get "$CKPT_FILE" '.criteria | length')" "1"
check "C1 verdict now fail"            "$(get "$CKPT_FILE" '.criteria[0].verdict')" "fail"

# add a second criterion so resume/list exercise real "last" + multi-row TSV
(cd "$WORK" && bash "$SCRIPT" "$RUN_ID" C2 blocked --confidence low >/dev/null)
check "criteria count 2 after adding C2" "$(get "$CKPT_FILE" '.criteria | length')" "2"

# --- Case 3: --resume prints last criterion (C2) with the fields the code emits
RESUME_OUT="$(cd "$WORK" && bash "$SCRIPT" --resume "$RUN_ID")"
check "resume: criterion_id C2"   "$(echo "$RESUME_OUT" | grep -qE 'criterion_id:[[:space:]]+C2' && echo yes)" "yes"
check "resume: verdict blocked"   "$(echo "$RESUME_OUT" | grep -qE 'verdict:[[:space:]]+blocked' && echo yes)" "yes"
check "resume: confidence low"    "$(echo "$RESUME_OUT" | grep -qE 'confidence:[[:space:]]+low' && echo yes)" "yes"
check "resume: phase verify"      "$(echo "$RESUME_OUT" | grep -qE 'phase:[[:space:]]+verify' && echo yes)" "yes"
check "resume: checkpointed_at present" "$(echo "$RESUME_OUT" | grep -qE 'checkpointed:[[:space:]]+[0-9]{4}-' && echo yes)" "yes"
check "resume: skip-to line"      "$(echo "$RESUME_OUT" | grep -qF 'Skip all criteria up to and including: C2' && echo yes)" "yes"

# --resume with no checkpoint file at all exits non-zero
(cd "$WORK" && bash "$SCRIPT" --resume "no-such-run" >/dev/null 2>&1)
RC_RESUME_MISSING=$?
check "resume: missing run exits nonzero" "$([[ "$RC_RESUME_MISSING" -ne 0 ]] && echo yes)" "yes"

# --- Case 4: --list TSV includes both criteria, with the header the code emits
LIST_OUT="$(cd "$WORK" && bash "$SCRIPT" --list "$RUN_ID")"
check "list: header row" "$(echo "$LIST_OUT" | head -1)" "$(printf 'criterion_id\tverdict\tconfidence\tcheckpointed_at')"
check "list: row count == 2" "$(echo "$LIST_OUT" | tail -n +2 | grep -c .)" "2"
check "list: C1 row fields" "$(echo "$LIST_OUT" | awk -F'\t' '$1=="C1"{print $1","$2","$3}')" "C1,fail,high"
check "list: C2 row fields" "$(echo "$LIST_OUT" | awk -F'\t' '$1=="C2"{print $1","$2","$3}')" "C2,blocked,low"

# --- Case 5: invalid verdict exits non-zero and does not mutate the file -----
(cd "$WORK" && bash "$SCRIPT" "$RUN_ID" C3 foo >/dev/null 2>&1)
RC_INVALID=$?
check "invalid verdict exits nonzero"  "$([[ "$RC_INVALID" -ne 0 ]] && echo yes)" "yes"
check "invalid verdict: no C3 added"   "$(get "$CKPT_FILE" '.criteria | length')" "2"

# --- Case 6: checkpoint file is valid JSON via python3 too (not just jq) -----
check "python3 parses checkpoint file" \
  "$(python3 -c "import json; json.load(open('$CKPT_FILE')); print('ok')" 2>/dev/null)" "ok"

# --- Case 7: python3 fallback path (jq masked from PATH) --------------------
# Only attempted when both jq and python3 exist on this host, so masking jq
# genuinely forces the fallback branch instead of faking it.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  # Only symlink the exact external tools checkpoint.sh needs, deliberately
  # excluding jq — this forces has_jq() to fail and has_py() to succeed.
  for tool in date mkdir cat python3; do
    TOOL_PATH="$(command -v "$tool")"
    ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  PY_RUN_ID="test-run-py-fallback"
  PY_CKPT_FILE="$WORK/.qa/runs/${PY_RUN_ID}/checkpoint.json"

  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PY_RUN_ID" C1 pass >/dev/null 2>&1)
  check "py-fallback: file created" "$([[ -f "$PY_CKPT_FILE" ]] && echo yes)" "yes"
  check "py-fallback: valid json"   "$(python3 -c "import json; json.load(open('$PY_CKPT_FILE')); print('ok')" 2>/dev/null)" "ok"
  check "py-fallback: criterion_id C1" \
    "$(python3 -c "import json;d=json.load(open('$PY_CKPT_FILE'));print(d['criteria'][0]['criterion_id'])" 2>/dev/null)" "C1"

  # upsert-replace under the fallback too
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PY_RUN_ID" C1 fail >/dev/null 2>&1)
  check "py-fallback: replace keeps count 1" \
    "$(python3 -c "import json;d=json.load(open('$PY_CKPT_FILE'));print(len(d['criteria']))" 2>/dev/null)" "1"
  check "py-fallback: replace updates verdict" \
    "$(python3 -c "import json;d=json.load(open('$PY_CKPT_FILE'));print(d['criteria'][0]['verdict'])" 2>/dev/null)" "fail"

  PY_RESUME_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --resume "$PY_RUN_ID" 2>&1)"
  check "py-fallback: resume shows C1" \
    "$(echo "$PY_RESUME_OUT" | grep -qE 'criterion_id:[[:space:]]*C1' && echo yes)" "yes"

  PY_LIST_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --list "$PY_RUN_ID" 2>&1)"
  check "py-fallback: list shows C1" \
    "$(echo "$PY_LIST_OUT" | awk -F'\t' '$1=="C1"{print "yes"}')" "yes"

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
