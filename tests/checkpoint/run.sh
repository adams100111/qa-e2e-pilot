#!/usr/bin/env bash
# Characterization tests for checkpoint.sh — pin TODAY's behavior (before the
# Phase 1 evidence-gate migration) so the migration can't silently regress
# upsert/resume/list semantics. Must PASS against the unmodified script.
#
# Also covers record-evidence.sh (Task 1.2) — the structured evidence writer
# the Phase 1 gate will content-check against.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
RECORD_SCRIPT="$HERE/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
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

  # --- record-evidence.sh python3-fallback sub-case (reuses the same fakebin,
  # which already excludes jq and provides date/mkdir/python3) --------------
  RE_RUN_ID="test-run-re-py-fallback"
  RE_EVID_DIR="$WORK/.qa/runs/${RE_RUN_ID}/evidence/C1"

  RE_PY_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$RECORD_SCRIPT" "$RE_RUN_ID" C1 bake --read-back '{"founders":3}' --multiplicity N 2>&1)"
  check "py-fallback record-evidence: bake file created" \
    "$([[ -f "$RE_EVID_DIR/bake-read-back.json" ]] && echo yes)" "yes"
  check "py-fallback record-evidence: valid json" \
    "$(python3 -c "import json; json.load(open('$RE_EVID_DIR/bake-read-back.json')); print('ok')" 2>/dev/null)" "ok"
  check "py-fallback record-evidence: readBack parsed as object" \
    "$(python3 -c "import json;d=json.load(open('$RE_EVID_DIR/bake-read-back.json'));print(d['readBack']['founders'])" 2>/dev/null)" "3"
  check "py-fallback record-evidence: multiplicity N" \
    "$(python3 -c "import json;d=json.load(open('$RE_EVID_DIR/bake-read-back.json'));print(d['multiplicity'])" 2>/dev/null)" "N"
  check "py-fallback record-evidence: stdout is the evidence-relative path" \
    "$RE_PY_OUT" "evidence/C1/bake-read-back.json"

  RE_PY_RECOMPUTE_FILE="$RE_EVID_DIR/recompute.json"
  RE_PY_COMPUTED_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$RECORD_SCRIPT" "$RE_RUN_ID" C1 computed --oracle 33.33 --observed 33.4 --match false 2>&1)"
  check "py-fallback record-evidence: computed file created" \
    "$([[ -f "$RE_PY_RECOMPUTE_FILE" ]] && echo yes)" "yes"
  check "py-fallback record-evidence: computed valid json" \
    "$(python3 -c "import json; json.load(open('$RE_PY_RECOMPUTE_FILE')); print('ok')" 2>/dev/null)" "ok"
  check "py-fallback record-evidence: computed oracle" \
    "$(python3 -c "import json;d=json.load(open('$RE_PY_RECOMPUTE_FILE'));print(d['oracle'])" 2>/dev/null)" "33.33"
  check "py-fallback record-evidence: computed observed" \
    "$(python3 -c "import json;d=json.load(open('$RE_PY_RECOMPUTE_FILE'));print(d['observed'])" 2>/dev/null)" "33.4"
  check "py-fallback record-evidence: computed match" \
    "$(python3 -c "import json;d=json.load(open('$RE_PY_RECOMPUTE_FILE'));print(d['match'])" 2>/dev/null)" "False"
  check "py-fallback record-evidence: computed stdout is the evidence-relative path" \
    "$RE_PY_COMPUTED_OUT" "evidence/C1/recompute.json"

  RE_PY_NETWORK_FILE="$RE_EVID_DIR/network-response.json"
  RE_PY_PROBE_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$RECORD_SCRIPT" "$RE_RUN_ID" C1 probe --status 200 --shape '{"ok":true}' 2>&1)"
  check "py-fallback record-evidence: probe file created" \
    "$([[ -f "$RE_PY_NETWORK_FILE" ]] && echo yes)" "yes"
  check "py-fallback record-evidence: probe valid json" \
    "$(python3 -c "import json; json.load(open('$RE_PY_NETWORK_FILE')); print('ok')" 2>/dev/null)" "ok"
  check "py-fallback record-evidence: probe status" \
    "$(python3 -c "import json;d=json.load(open('$RE_PY_NETWORK_FILE'));print(d['status'])" 2>/dev/null)" "200"
  check "py-fallback record-evidence: probe shape.ok" \
    "$(python3 -c "import json;d=json.load(open('$RE_PY_NETWORK_FILE'));print(d['shape']['ok'])" 2>/dev/null)" "True"
  check "py-fallback record-evidence: probe stdout is the evidence-relative path" \
    "$RE_PY_PROBE_OUT" "evidence/C1/network-response.json"

  echo "note - record-evidence.sh jq-fallback sub-case: RAN (same restricted fakebin, bake+computed+probe)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# --- Case 8: record-evidence.sh bake -> bake-read-back.json ------------------
RE_RUN_ID="test-run-evidence"
RE_C1_DIR="$WORK/.qa/runs/${RE_RUN_ID}/evidence/C1"
BAKE_FILE="$RE_C1_DIR/bake-read-back.json"

BAKE_STDOUT="$(cd "$WORK" && bash "$RECORD_SCRIPT" "$RE_RUN_ID" C1 bake --read-back '{"founders":3}' --multiplicity N)"
check "record-evidence bake: exits zero"        "$?" "0"
check "record-evidence bake: file exists"       "$([[ -f "$BAKE_FILE" ]] && echo yes)" "yes"
check "record-evidence bake: non-empty"         "$([[ -s "$BAKE_FILE" ]] && echo yes)" "yes"
check "record-evidence bake: valid json"        "$(jq -e . "$BAKE_FILE" >/dev/null 2>&1 && echo ok)" "ok"
check "record-evidence bake: readBack.founders" "$(get "$BAKE_FILE" '.readBack.founders')" "3"
check "record-evidence bake: multiplicity == N" "$(get "$BAKE_FILE" '.multiplicity')" "N"
check "record-evidence bake: stdout is evidence-relative path" "$BAKE_STDOUT" "evidence/C1/bake-read-back.json"

# --- Case 9: record-evidence.sh computed -> recompute.json -------------------
RECOMPUTE_FILE="$RE_C1_DIR/recompute.json"
COMPUTED_STDOUT="$(cd "$WORK" && bash "$RECORD_SCRIPT" "$RE_RUN_ID" C1 computed --oracle 33.33 --observed 33.4 --match false)"
check "record-evidence computed: file exists"   "$([[ -f "$RECOMPUTE_FILE" ]] && echo yes)" "yes"
check "record-evidence computed: valid json"    "$(jq -e . "$RECOMPUTE_FILE" >/dev/null 2>&1 && echo ok)" "ok"
check "record-evidence computed: oracle"        "$(get "$RECOMPUTE_FILE" '.oracle')" "33.33"
check "record-evidence computed: observed"      "$(get "$RECOMPUTE_FILE" '.observed')" "33.4"
check "record-evidence computed: match"         "$(get "$RECOMPUTE_FILE" '.match')" "false"
check "record-evidence computed: stdout is evidence-relative path" "$COMPUTED_STDOUT" "evidence/C1/recompute.json"

# --- Case 10: record-evidence.sh probe -> network-response.json --------------
NETWORK_FILE="$RE_C1_DIR/network-response.json"
PROBE_STDOUT="$(cd "$WORK" && bash "$RECORD_SCRIPT" "$RE_RUN_ID" C1 probe --status 200 --shape '{"ok":true}')"
check "record-evidence probe: file exists"      "$([[ -f "$NETWORK_FILE" ]] && echo yes)" "yes"
check "record-evidence probe: valid json"       "$(jq -e . "$NETWORK_FILE" >/dev/null 2>&1 && echo ok)" "ok"
check "record-evidence probe: status"           "$(get "$NETWORK_FILE" '.status')" "200"
check "record-evidence probe: shape.ok"         "$(get "$NETWORK_FILE" '.shape.ok')" "true"
check "record-evidence probe: stdout is evidence-relative path" "$PROBE_STDOUT" "evidence/C1/network-response.json"

# --- Case 11: unknown kind exits non-zero and writes nothing -----------------
RE_UNKNOWN_DIR="$WORK/.qa/runs/${RE_RUN_ID}/evidence/C-unknown"
(cd "$WORK" && bash "$RECORD_SCRIPT" "$RE_RUN_ID" C-unknown bogus >/dev/null 2>&1)
RC_UNKNOWN_KIND=$?
check "record-evidence unknown kind exits nonzero" "$([[ "$RC_UNKNOWN_KIND" -ne 0 ]] && echo yes)" "yes"
check "record-evidence unknown kind writes nothing" "$([[ ! -d "$RE_UNKNOWN_DIR" ]] && echo yes)" "yes"

# --- Case 12: missing required flag for a known kind exits non-zero ----------
(cd "$WORK" && bash "$RECORD_SCRIPT" "$RE_RUN_ID" C-missing bake --multiplicity N >/dev/null 2>&1)
RC_MISSING_FLAG=$?
check "record-evidence missing --read-back exits nonzero" "$([[ "$RC_MISSING_FLAG" -ne 0 ]] && echo yes)" "yes"

# --- Case 13: secret values are never echoed to stdout or stderr -------------
SECRET_VALUE="sk_live_super_secret_token_zzz"
RE_SECRET_OUT="$(cd "$WORK" && bash "$RECORD_SCRIPT" "$RE_RUN_ID" C-secret computed --oracle "$SECRET_VALUE" --observed "$SECRET_VALUE" --match true 2>&1)"
check "record-evidence never echoes secret values" "$(echo "$RE_SECRET_OUT" | grep -qF "$SECRET_VALUE" && echo LEAKED || echo safe)" "safe"
check "record-evidence secret value still written to disk" \
  "$(get "$RE_C1_DIR/../C-secret/recompute.json" '.oracle')" "$SECRET_VALUE"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
