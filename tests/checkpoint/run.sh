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
# NOTE: header intentionally updated for Task 1.4 (append-only: kinds + evidence
# trailing columns added). This is a deliberate change to a prior assertion —
# see task-1.4-report.md.
LIST_OUT="$(cd "$WORK" && bash "$SCRIPT" --list "$RUN_ID")"
check "list: header row" "$(echo "$LIST_OUT" | head -1)" "$(printf 'criterion_id\tverdict\tconfidence\tcheckpointed_at\tkinds\tevidence')"
check "list: row count == 2" "$(echo "$LIST_OUT" | tail -n +2 | grep -c .)" "2"
check "list: C1 row fields" "$(echo "$LIST_OUT" | awk -F'\t' '$1=="C1"{print $1","$2","$3}')" "C1,fail,high"
check "list: C2 row fields" "$(echo "$LIST_OUT" | awk -F'\t' '$1=="C2"{print $1","$2","$3}')" "C2,blocked,low"
check "list: C1 (fail, no kinds) kinds+evidence" "$(echo "$LIST_OUT" | awk -F'\t' '$1=="C1"{print $5","$6}')" "-,n/a"
check "list: C2 (blocked, no kinds) kinds+evidence" "$(echo "$LIST_OUT" | awk -F'\t' '$1=="C2"{print $5","$6}')" "-,n/a"

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

# --- Case 14: evidence gate — pass --kinds bake with NO bake artifact --------
GATE_RUN_ID="test-run-gate"
GATE_CKPT_FILE="$WORK/.qa/runs/${GATE_RUN_ID}/checkpoint.json"

GATE_NOEV_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE_RUN_ID" G1 pass --kinds bake 2>&1 >/dev/null)"
RC_GATE_NOEV=$?
check "gate: no-evidence pass exits nonzero" "$([[ "$RC_GATE_NOEV" -ne 0 ]] && echo yes)" "yes"
check "gate: no-evidence stderr names bake-read-back.json" \
  "$(echo "$GATE_NOEV_ERR" | grep -qF 'bake-read-back.json' && echo yes)" "yes"
check "gate: no-evidence stderr has blocked reminder" \
  "$(echo "$GATE_NOEV_ERR" | grep -qF 'record `blocked`' && echo yes)" "yes"
check "gate: no-evidence record not written" \
  "$([[ ! -f "$GATE_CKPT_FILE" ]] && echo yes || echo "$(get "$GATE_CKPT_FILE" '.criteria | length')")" "yes"

# --- Case 15: evidence gate — pass --kinds bake with an EMPTY bake file ------
GATE_EVID_DIR="$WORK/.qa/runs/${GATE_RUN_ID}/evidence/G1"
mkdir -p "$GATE_EVID_DIR"
touch "$GATE_EVID_DIR/bake-read-back.json"

GATE_EMPTY_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE_RUN_ID" G1 pass --kinds bake 2>&1 >/dev/null)"
RC_GATE_EMPTY=$?
check "gate: empty bake file exits nonzero" "$([[ "$RC_GATE_EMPTY" -ne 0 ]] && echo yes)" "yes"
check "gate: empty bake file stderr names bake-read-back.json" \
  "$(echo "$GATE_EMPTY_ERR" | grep -qF 'bake-read-back.json' && echo yes)" "yes"
check "gate: empty bake file record not written" \
  "$([[ ! -f "$GATE_CKPT_FILE" ]] && echo yes)" "yes"

# --- Case 16: evidence gate — bake file missing required key (multiplicity) -
echo '{"readBack": {"x": 1}}' > "$GATE_EVID_DIR/bake-read-back.json"

GATE_MISSKEY_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE_RUN_ID" G1 pass --kinds bake 2>&1 >/dev/null)"
RC_GATE_MISSKEY=$?
check "gate: missing-key bake file exits nonzero" "$([[ "$RC_GATE_MISSKEY" -ne 0 ]] && echo yes)" "yes"
check "gate: missing-key stderr names bake-read-back.json" \
  "$(echo "$GATE_MISSKEY_ERR" | grep -qF 'bake-read-back.json' && echo yes)" "yes"
check "gate: missing-key record not written" \
  "$([[ ! -f "$GATE_CKPT_FILE" ]] && echo yes)" "yes"

# --- Case 17: valid bake evidence via record-evidence.sh -> pass ACCEPTED ---
(cd "$WORK" && bash "$RECORD_SCRIPT" "$GATE_RUN_ID" G1 bake --read-back '{"x":1}' --multiplicity N >/dev/null)

GATE_OK_OUT="$(cd "$WORK" && bash "$SCRIPT" "$GATE_RUN_ID" G1 pass --kinds bake 2>&1)"
RC_GATE_OK=$?
check "gate: valid bake evidence accepted (exit 0)" "$RC_GATE_OK" "0"
check "gate: valid bake evidence record written" \
  "$([[ -f "$GATE_CKPT_FILE" ]] && echo yes)" "yes"
check "gate: valid bake evidence criteria count 1" "$(get "$GATE_CKPT_FILE" '.criteria | length')" "1"
check "gate: valid bake evidence verdict pass" "$(get "$GATE_CKPT_FILE" '.criteria[0].verdict')" "pass"
check "gate: valid bake evidence stored kinds contains bake" \
  "$(get "$GATE_CKPT_FILE" '.criteria[0].kinds | index("bake") != null')" "true"

# --- Case 18: blocked --kinds bake with NO evidence -> ACCEPTED (non-pass exempt)
GATE2_RUN_ID="test-run-gate-2"
GATE2_CKPT_FILE="$WORK/.qa/runs/${GATE2_RUN_ID}/checkpoint.json"
GATE2_OUT="$(cd "$WORK" && bash "$SCRIPT" "$GATE2_RUN_ID" G2 blocked --kinds bake 2>&1)"
RC_GATE2=$?
check "gate: blocked with --kinds and no evidence accepted" "$RC_GATE2" "0"
check "gate: blocked record written" "$([[ -f "$GATE2_CKPT_FILE" ]] && echo yes)" "yes"
check "gate: blocked verdict stored" "$(get "$GATE2_CKPT_FILE" '.criteria[0].verdict')" "blocked"
check "gate: blocked stored kinds contains bake" \
  "$(get "$GATE2_CKPT_FILE" '.criteria[0].kinds | index("bake") != null')" "true"

# --- Case 19: pass with NO --kinds -> accepted + stderr un-gated note -------
GATE3_RUN_ID="test-run-gate-3"
GATE3_CKPT_FILE="$WORK/.qa/runs/${GATE3_RUN_ID}/checkpoint.json"
GATE3_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE3_RUN_ID" G3 pass 2>&1 >/dev/null)"
RC_GATE3=$?
check "gate: pass with no --kinds accepted" "$RC_GATE3" "0"
check "gate: pass with no --kinds record written" "$([[ -f "$GATE3_CKPT_FILE" ]] && echo yes)" "yes"
check "gate: pass with no --kinds un-gated stderr note" \
  "$(echo "$GATE3_ERR" | grep -qi 'un-gated\|ungated\|no evidence required\|no --kinds' && echo yes)" "yes"
check "gate: pass with no --kinds stored kinds is empty" \
  "$(get "$GATE3_CKPT_FILE" '.criteria[0].kinds')" "[]"

# --- Case 20: multi-kind pass requires BOTH artifacts -----------------------
GATE4_RUN_ID="test-run-gate-4"
GATE4_CKPT_FILE="$WORK/.qa/runs/${GATE4_RUN_ID}/checkpoint.json"

# only bake evidence present -> still rejected (missing computed)
(cd "$WORK" && bash "$RECORD_SCRIPT" "$GATE4_RUN_ID" G4 bake --read-back '{"x":1}' --multiplicity N >/dev/null)
GATE4_PARTIAL_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE4_RUN_ID" G4 pass --kinds bake,computed 2>&1 >/dev/null)"
RC_GATE4_PARTIAL=$?
check "gate: multi-kind partial evidence rejected" "$([[ "$RC_GATE4_PARTIAL" -ne 0 ]] && echo yes)" "yes"
check "gate: multi-kind partial stderr names recompute.json" \
  "$(echo "$GATE4_PARTIAL_ERR" | grep -qF 'recompute.json' && echo yes)" "yes"
check "gate: multi-kind partial record not written" \
  "$([[ ! -f "$GATE4_CKPT_FILE" ]] && echo yes)" "yes"

# add computed evidence too -> accepted
(cd "$WORK" && bash "$RECORD_SCRIPT" "$GATE4_RUN_ID" G4 computed --oracle 1 --observed 1 --match true >/dev/null)
GATE4_OK_OUT="$(cd "$WORK" && bash "$SCRIPT" "$GATE4_RUN_ID" G4 pass --kinds bake,computed 2>&1)"
RC_GATE4_OK=$?
check "gate: multi-kind full evidence accepted" "$RC_GATE4_OK" "0"
check "gate: multi-kind full evidence stored kinds has both" \
  "$(get "$GATE4_CKPT_FILE" '.criteria[0].kinds | (index("bake") != null) and (index("computed") != null)')" "true"

# --- Case 21: evidence gate exercised under the jq-masked python3 fallback --
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="${BASH_BIN:-$(command -v bash)}"
  FAKEBIN="${FAKEBIN:-$WORK/fakebin}"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir cat python3; do
    TOOL_PATH="$(command -v "$tool")"
    ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  PYGATE_RUN_ID="test-run-py-gate"
  PYGATE_CKPT_FILE="$WORK/.qa/runs/${PYGATE_RUN_ID}/checkpoint.json"

  # reject case: no evidence
  PYGATE_REJ_ERR="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYGATE_RUN_ID" PG1 pass --kinds bake 2>&1 >/dev/null)"
  RC_PYGATE_REJ=$?
  check "py-fallback gate: no-evidence pass exits nonzero" "$([[ "$RC_PYGATE_REJ" -ne 0 ]] && echo yes)" "yes"
  check "py-fallback gate: no-evidence stderr names bake-read-back.json" \
    "$(echo "$PYGATE_REJ_ERR" | grep -qF 'bake-read-back.json' && echo yes)" "yes"
  check "py-fallback gate: no-evidence record not written" \
    "$([[ ! -f "$PYGATE_CKPT_FILE" ]] && echo yes)" "yes"

  # accept case: write evidence via python3 fallback record-evidence.sh, then pass
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$RECORD_SCRIPT" "$PYGATE_RUN_ID" PG1 bake --read-back '{"x":1}' --multiplicity N >/dev/null)
  PYGATE_OK_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYGATE_RUN_ID" PG1 pass --kinds bake 2>&1)"
  RC_PYGATE_OK=$?
  check "py-fallback gate: valid bake evidence accepted" "$RC_PYGATE_OK" "0"
  check "py-fallback gate: stored kinds contains bake" \
    "$(python3 -c "import json;d=json.load(open('$PYGATE_CKPT_FILE'));print('bake' in d['criteria'][0]['kinds'])" 2>/dev/null)" "True"

  # probe reject: no evidence
  PYGATE_PROBE_RUN_ID="test-run-py-gate-probe"
  PYGATE_PROBE_CKPT_FILE="$WORK/.qa/runs/${PYGATE_PROBE_RUN_ID}/checkpoint.json"
  PYGATE_PROBE_REJ_ERR="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYGATE_PROBE_RUN_ID" PG2 pass --kinds probe 2>&1 >/dev/null)"
  RC_PYGATE_PROBE_REJ=$?
  check "py-fallback gate: probe no-evidence pass exits nonzero" "$([[ "$RC_PYGATE_PROBE_REJ" -ne 0 ]] && echo yes)" "yes"
  check "py-fallback gate: probe no-evidence stderr names network-response.json" \
    "$(echo "$PYGATE_PROBE_REJ_ERR" | grep -qF 'network-response.json' && echo yes)" "yes"
  check "py-fallback gate: probe no-evidence record not written" \
    "$([[ ! -f "$PYGATE_PROBE_CKPT_FILE" ]] && echo yes)" "yes"

  # probe accept: write evidence via python3 fallback record-evidence.sh, then pass
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$RECORD_SCRIPT" "$PYGATE_PROBE_RUN_ID" PG2 probe --status 200 --shape '{"ok":true}' >/dev/null)
  PYGATE_PROBE_OK_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYGATE_PROBE_RUN_ID" PG2 pass --kinds probe 2>&1)"
  RC_PYGATE_PROBE_OK=$?
  check "py-fallback gate: valid probe evidence accepted" "$RC_PYGATE_PROBE_OK" "0"
  check "py-fallback gate: probe stored kinds is probe" \
    "$(python3 -c "import json;d=json.load(open('$PYGATE_PROBE_CKPT_FILE'));print(d['criteria'][0]['kinds'])" 2>/dev/null)" "['probe']"

  echo "note - evidence-gate jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - evidence-gate jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# --- Case 22: evidence gate — pass --kinds probe with NO probe artifact -----
GATE5_RUN_ID="test-run-gate-5"
GATE5_CKPT_FILE="$WORK/.qa/runs/${GATE5_RUN_ID}/checkpoint.json"

GATE5_NOEV_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE5_RUN_ID" G5 pass --kinds probe 2>&1 >/dev/null)"
RC_GATE5_NOEV=$?
check "gate: probe no-evidence pass exits nonzero" "$([[ "$RC_GATE5_NOEV" -ne 0 ]] && echo yes)" "yes"
check "gate: probe no-evidence stderr names network-response.json" \
  "$(echo "$GATE5_NOEV_ERR" | grep -qF 'network-response.json' && echo yes)" "yes"
check "gate: probe no-evidence record not written" \
  "$([[ ! -f "$GATE5_CKPT_FILE" ]] && echo yes)" "yes"

# --- Case 23: evidence gate — valid probe evidence -> pass ACCEPTED, stored
# kinds is ["probe"], and this specifically confirms the gate accepts
# `status` as a JSON NUMBER (200, not the string "200") -----------------------
(cd "$WORK" && bash "$RECORD_SCRIPT" "$GATE5_RUN_ID" G5 probe --status 200 --shape '{"ok":true}' >/dev/null)

GATE5_OK_OUT="$(cd "$WORK" && bash "$SCRIPT" "$GATE5_RUN_ID" G5 pass --kinds probe 2>&1)"
RC_GATE5_OK=$?
check "gate: valid probe evidence accepted (exit 0)" "$RC_GATE5_OK" "0"
check "gate: valid probe evidence record written" \
  "$([[ -f "$GATE5_CKPT_FILE" ]] && echo yes)" "yes"
check "gate: valid probe evidence stored kinds is [\"probe\"]" \
  "$(jq -c '.criteria[0].kinds' "$GATE5_CKPT_FILE" 2>/dev/null)" '["probe"]'
check "gate: valid probe evidence status stored as JSON number (not string)" \
  "$(python3 -c "import json;d=json.load(open('$WORK/.qa/runs/${GATE5_RUN_ID}/evidence/G5/network-response.json'));print(type(d['status']).__name__)" 2>/dev/null)" "int"

# --- Case 24: evidence gate — pass --kinds bogus (unknown kind) exits
# nonzero with a single correct message (Finding 1's fix) — no fabricated
# "missing artifact ''" second message, and nothing is written -------------
GATE6_RUN_ID="test-run-gate-6"
GATE6_CKPT_FILE="$WORK/.qa/runs/${GATE6_RUN_ID}/checkpoint.json"
GATE6_ERR="$(cd "$WORK" && bash "$SCRIPT" "$GATE6_RUN_ID" G6 pass --kinds bogus 2>&1 >/dev/null)"
RC_GATE6=$?
check "gate: invalid kind exits nonzero" "$([[ "$RC_GATE6" -ne 0 ]] && echo yes)" "yes"
check "gate: invalid kind stderr says unknown kind" \
  "$(echo "$GATE6_ERR" | grep -qF "unknown kind 'bogus'" && echo yes)" "yes"
check "gate: invalid kind record not written" \
  "$([[ ! -f "$GATE6_CKPT_FILE" ]] && echo yes)" "yes"
check "gate: invalid kind emits exactly one gate/diagnostic line" \
  "$(echo "$GATE6_ERR" | grep -cE 'EVIDENCE GATE|Invalid kind')" "1"

# --- Case 25: --resume surfaces kinds + evidence:complete for a gated pass ---
# GATE_RUN_ID/G1 (Case 17) is a `pass` with --kinds bake backed by valid evidence.
RESUME_GATED_OUT="$(cd "$WORK" && bash "$SCRIPT" --resume "$GATE_RUN_ID")"
check "resume: gated pass shows kinds bake" \
  "$(echo "$RESUME_GATED_OUT" | grep -qE 'kinds:[[:space:]]+bake' && echo yes)" "yes"
check "resume: gated pass shows evidence complete" \
  "$(echo "$RESUME_GATED_OUT" | grep -qE 'evidence:[[:space:]]+complete' && echo yes)" "yes"

# --- Case 26: --list surfaces kinds + evidence columns for a gated pass -----
LIST_GATED_OUT="$(cd "$WORK" && bash "$SCRIPT" --list "$GATE_RUN_ID")"
check "list: gated pass row kinds+evidence" \
  "$(echo "$LIST_GATED_OUT" | awk -F'\t' '$1=="G1"{print $5","$6}')" "bake,complete"

# --- Case 27: blocked criterion (with kinds) shows evidence n/a, resume+list -
# GATE2_RUN_ID/G2 (Case 18) is `blocked` with --kinds bake but no evidence on
# disk — non-pass verdicts are exempt from the gate, so the record exists, but
# evidence status must read n/a (the gate never ran/enforced it).
RESUME_BLOCKED_OUT="$(cd "$WORK" && bash "$SCRIPT" --resume "$GATE2_RUN_ID")"
check "resume: blocked shows evidence n/a" \
  "$(echo "$RESUME_BLOCKED_OUT" | grep -qE 'evidence:[[:space:]]+n/a' && echo yes)" "yes"
check "resume: blocked still shows its kinds" \
  "$(echo "$RESUME_BLOCKED_OUT" | grep -qE 'kinds:[[:space:]]+bake' && echo yes)" "yes"

LIST_BLOCKED_OUT="$(cd "$WORK" && bash "$SCRIPT" --list "$GATE2_RUN_ID")"
check "list: blocked row shows evidence n/a" \
  "$(echo "$LIST_BLOCKED_OUT" | awk -F'\t' '$1=="G2"{print $6}')" "n/a"

# --- Case 28: pass with no --kinds shows evidence:ungated, kinds: - --------
# GATE3_RUN_ID/G3 (Case 19) is a `pass` recorded with no --kinds at all.
RESUME_UNGATED_OUT="$(cd "$WORK" && bash "$SCRIPT" --resume "$GATE3_RUN_ID")"
check "resume: ungated pass shows kinds -" \
  "$(echo "$RESUME_UNGATED_OUT" | grep -qE 'kinds:[[:space:]]+-' && echo yes)" "yes"
check "resume: ungated pass shows evidence ungated" \
  "$(echo "$RESUME_UNGATED_OUT" | grep -qE 'evidence:[[:space:]]+ungated' && echo yes)" "yes"

LIST_UNGATED_OUT="$(cd "$WORK" && bash "$SCRIPT" --list "$GATE3_RUN_ID")"
check "list: ungated pass row kinds+evidence" \
  "$(echo "$LIST_UNGATED_OUT" | awk -F'\t' '$1=="G3"{print $5","$6}')" "-,ungated"

# --- Case 29: kinds/evidence parity under the jq-masked python3 fallback ---
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="${BASH_BIN:-$(command -v bash)}"
  FAKEBIN="${FAKEBIN:-$WORK/fakebin}"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir cat python3; do
    TOOL_PATH="$(command -v "$tool")"
    ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  # complete: PYGATE_RUN_ID/PG1 (Case 21) is a gated pass w/ valid bake evidence
  PY_RESUME_COMPLETE="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --resume "$PYGATE_RUN_ID" 2>&1)"
  check "py-fallback resume: gated pass shows kinds bake" \
    "$(echo "$PY_RESUME_COMPLETE" | grep -qE 'kinds:[[:space:]]*bake' && echo yes)" "yes"
  check "py-fallback resume: gated pass shows evidence complete" \
    "$(echo "$PY_RESUME_COMPLETE" | grep -qE 'evidence:[[:space:]]*complete' && echo yes)" "yes"

  PY_LIST_COMPLETE="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --list "$PYGATE_RUN_ID" 2>&1)"
  check "py-fallback list: gated pass row kinds+evidence" \
    "$(echo "$PY_LIST_COMPLETE" | awk -F'\t' '$1=="PG1"{print $5","$6}')" "bake,complete"

  # ungated: a fresh `pass` with no --kinds, written entirely under the
  # fallback (PY_RUN_ID/C1 from Case 7 is unsuitable — it gets replaced to
  # `fail` later in that same case, so its final verdict is not `pass`).
  PYUNGATED_RUN_ID="test-run-py-ungated"
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYUNGATED_RUN_ID" PU1 pass >/dev/null 2>&1)
  PY_RESUME_UNGATED="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --resume "$PYUNGATED_RUN_ID" 2>&1)"
  check "py-fallback resume: ungated pass shows kinds -" \
    "$(echo "$PY_RESUME_UNGATED" | grep -qE 'kinds:[[:space:]]*-' && echo yes)" "yes"
  check "py-fallback resume: ungated pass shows evidence ungated" \
    "$(echo "$PY_RESUME_UNGATED" | grep -qE 'evidence:[[:space:]]*ungated' && echo yes)" "yes"

  # n/a: a fresh blocked-with-kinds record written entirely under the fallback
  PYBLOCK_RUN_ID="test-run-py-blocked"
  PYBLOCK_CKPT_FILE="$WORK/.qa/runs/${PYBLOCK_RUN_ID}/checkpoint.json"
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYBLOCK_RUN_ID" PB1 blocked --kinds bake >/dev/null 2>&1)
  PY_RESUME_NA="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --resume "$PYBLOCK_RUN_ID" 2>&1)"
  check "py-fallback resume: blocked shows evidence n/a" \
    "$(echo "$PY_RESUME_NA" | grep -qE 'evidence:[[:space:]]*n/a' && echo yes)" "yes"
  PY_LIST_NA="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" --list "$PYBLOCK_RUN_ID" 2>&1)"
  check "py-fallback list: blocked row shows evidence n/a" \
    "$(echo "$PY_LIST_NA" | awk -F'\t' '$1=="PB1"{print $6}')" "n/a"

  echo "note - kinds/evidence jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - kinds/evidence jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# --- Case 30: persona-keying — pass C1 --persona admin, then pass C1
# --persona user -> TWO SEPARATE records (criteria length grows by 2, not
# replace); each carries its own persona. This is Task 15's core fix: a
# criterion recorded `pass` under one persona must never read as done for a
# different persona on resume. ------------------------------------------
PERSONA_RUN_ID="test-run-persona"
PERSONA_CKPT_FILE="$WORK/.qa/runs/${PERSONA_RUN_ID}/checkpoint.json"

(cd "$WORK" && bash "$SCRIPT" "$PERSONA_RUN_ID" C1 pass --persona admin >/dev/null)
check "persona: criteria count 1 after first persona upsert" \
  "$(get "$PERSONA_CKPT_FILE" '.criteria | length')" "1"
check "persona: admin record persona field" \
  "$(get "$PERSONA_CKPT_FILE" '.criteria[0].persona')" "admin"

(cd "$WORK" && bash "$SCRIPT" "$PERSONA_RUN_ID" C1 pass --persona user >/dev/null)
check "persona: criteria count grows to 2 (not replaced)" \
  "$(get "$PERSONA_CKPT_FILE" '.criteria | length')" "2"
check "persona: admin record still present after adding user" \
  "$(jq -r '[.criteria[] | select(.criterion_id=="C1" and .persona=="admin")] | length' "$PERSONA_CKPT_FILE")" "1"
check "persona: user record present" \
  "$(jq -r '[.criteria[] | select(.criterion_id=="C1" and .persona=="user")] | length' "$PERSONA_CKPT_FILE")" "1"
check "persona: both records have criterion_id C1" \
  "$(jq -r '[.criteria[].criterion_id] | unique | join(",")' "$PERSONA_CKPT_FILE")" "C1"

# --- Case 31: --resume/--list show both C1/admin and C1/user distinctly ----
PERSONA_LIST_OUT="$(cd "$WORK" && bash "$SCRIPT" --list "$PERSONA_RUN_ID")"
check "persona list: C1@admin row present" \
  "$(echo "$PERSONA_LIST_OUT" | awk -F'\t' '$1=="C1@admin"{print "yes"}')" "yes"
check "persona list: C1@user row present" \
  "$(echo "$PERSONA_LIST_OUT" | awk -F'\t' '$1=="C1@user"{print "yes"}')" "yes"
check "persona list: header row unchanged (back-compat)" \
  "$(echo "$PERSONA_LIST_OUT" | head -1)" \
  "$(printf 'criterion_id\tverdict\tconfidence\tcheckpointed_at\tkinds\tevidence')"

PERSONA_RESUME_OUT="$(cd "$WORK" && bash "$SCRIPT" --resume "$PERSONA_RUN_ID")"
check "persona resume: last record shows criterion_id C1" \
  "$(echo "$PERSONA_RESUME_OUT" | grep -qE 'criterion_id:[[:space:]]+C1' && echo yes)" "yes"
check "persona resume: last record shows persona user" \
  "$(echo "$PERSONA_RESUME_OUT" | grep -qE 'persona:[[:space:]]+user' && echo yes)" "yes"

# --- Case 32: no-persona upsert of C1 still replaces the no-persona C1
# (back-compat) and does NOT touch the persona-scoped records -------------
(cd "$WORK" && bash "$SCRIPT" "$PERSONA_RUN_ID" C1 fail >/dev/null)
check "persona: no-persona upsert grows count to 3 (new (none) record)" \
  "$(get "$PERSONA_CKPT_FILE" '.criteria | length')" "3"
check "persona: no-persona C1 record has persona empty" \
  "$(jq -r '[.criteria[] | select(.criterion_id=="C1" and (.persona // "")=="")] | length' "$PERSONA_CKPT_FILE")" "1"

(cd "$WORK" && bash "$SCRIPT" "$PERSONA_RUN_ID" C1 blocked >/dev/null)
check "persona: second no-persona upsert REPLACES (count stays 3)" \
  "$(get "$PERSONA_CKPT_FILE" '.criteria | length')" "3"
check "persona: no-persona C1 record now blocked" \
  "$(jq -r '.criteria[] | select(.criterion_id=="C1" and (.persona // "")=="") | .verdict' "$PERSONA_CKPT_FILE")" "blocked"
check "persona: admin record untouched by no-persona upserts" \
  "$(jq -r '.criteria[] | select(.criterion_id=="C1" and .persona=="admin") | .verdict' "$PERSONA_CKPT_FILE")" "pass"
check "persona: user record untouched by no-persona upserts" \
  "$(jq -r '.criteria[] | select(.criterion_id=="C1" and .persona=="user") | .verdict' "$PERSONA_CKPT_FILE")" "pass"

# --- Case 33: persona-scoped evidence gate -------------------------------
# record-evidence.sh writes under evidence/<persona>/<crit>/ when --persona
# is set; checkpoint.sh's gate, given --persona on a pass, must look there.
PGATE_RUN_ID="test-run-persona-gate"
PGATE_CKPT_FILE="$WORK/.qa/runs/${PGATE_RUN_ID}/checkpoint.json"
PGATE_EVID_PATH="$WORK/.qa/runs/${PGATE_RUN_ID}/evidence/admin/PC1/bake-read-back.json"

PGATE_EVID_OUT="$(cd "$WORK" && bash "$RECORD_SCRIPT" "$PGATE_RUN_ID" PC1 bake --persona admin --read-back '{"x":1}' --multiplicity N)"
check "persona evidence: written under evidence/admin/PC1/" \
  "$([[ -f "$PGATE_EVID_PATH" ]] && echo yes)" "yes"
check "persona evidence: stdout path is persona-scoped" \
  "$PGATE_EVID_OUT" "evidence/admin/PC1/bake-read-back.json"
check "persona evidence: NOT written under the non-persona path" \
  "$([[ ! -f "$WORK/.qa/runs/${PGATE_RUN_ID}/evidence/PC1/bake-read-back.json" ]] && echo yes)" "yes"

PGATE_OK_OUT="$(cd "$WORK" && bash "$SCRIPT" "$PGATE_RUN_ID" PC1 pass --persona admin --kinds bake 2>&1)"
RC_PGATE_OK=$?
check "persona gate: pass with persona-scoped evidence ACCEPTED" "$RC_PGATE_OK" "0"
check "persona gate: record written with persona admin" \
  "$(get "$PGATE_CKPT_FILE" '.criteria[0].persona')" "admin"

# same pass WITHOUT the persona-scoped evidence (a different persona, no
# evidence written for it yet) is REJECTED
PGATE_NOEV_ERR="$(cd "$WORK" && bash "$SCRIPT" "$PGATE_RUN_ID" PC1 pass --persona participant --kinds bake 2>&1 >/dev/null)"
RC_PGATE_NOEV=$?
check "persona gate: pass without persona-scoped evidence REJECTED" \
  "$([[ "$RC_PGATE_NOEV" -ne 0 ]] && echo yes)" "yes"
check "persona gate: rejection names the persona-scoped path" \
  "$(echo "$PGATE_NOEV_ERR" | grep -qF 'evidence/participant/PC1/bake-read-back.json' && echo yes)" "yes"
check "persona gate: rejected pass did not add a second record" \
  "$(get "$PGATE_CKPT_FILE" '.criteria | length')" "1"

# a plain (no --persona) pass for the same criterion also can't be satisfied
# by the admin persona's evidence — it looks at the non-persona-scoped path,
# which was never written, so it is also rejected.
PGATE_PLAIN_ERR="$(cd "$WORK" && bash "$SCRIPT" "$PGATE_RUN_ID" PC1 pass --kinds bake 2>&1 >/dev/null)"
RC_PGATE_PLAIN=$?
check "persona gate: no-persona pass can't reuse admin's evidence, REJECTED" \
  "$([[ "$RC_PGATE_PLAIN" -ne 0 ]] && echo yes)" "yes"
check "persona gate: no-persona rejection names the non-scoped path" \
  "$(echo "$PGATE_PLAIN_ERR" | grep -qF 'evidence/PC1/bake-read-back.json' && echo yes)" "yes"

# --- Case 34: persona record identity + persona-scoped gate under the
# jq-masked python3 fallback ----------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="${BASH_BIN:-$(command -v bash)}"
  FAKEBIN="${FAKEBIN:-$WORK/fakebin}"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir cat python3; do
    TOOL_PATH="$(command -v "$tool")"
    ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  PYP_RUN_ID="test-run-py-persona"
  PYP_CKPT_FILE="$WORK/.qa/runs/${PYP_RUN_ID}/checkpoint.json"

  # two-persona record identity under the python3 fallback
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYP_RUN_ID" C1 pass --persona admin >/dev/null 2>&1)
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYP_RUN_ID" C1 pass --persona user >/dev/null 2>&1)
  check "py-fallback persona: two records for C1 (admin, user)" \
    "$(python3 -c "import json;d=json.load(open('$PYP_CKPT_FILE'));print(len(d['criteria']))" 2>/dev/null)" "2"
  check "py-fallback persona: personas are admin and user" \
    "$(python3 -c "import json;d=json.load(open('$PYP_CKPT_FILE'));print(sorted(c['persona'] for c in d['criteria']))" 2>/dev/null)" "['admin', 'user']"

  # no-persona upsert of C1 still replaces only the no-persona C1
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYP_RUN_ID" C1 fail >/dev/null 2>&1)
  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYP_RUN_ID" C1 blocked >/dev/null 2>&1)
  check "py-fallback persona: no-persona replace keeps count at 3" \
    "$(python3 -c "import json;d=json.load(open('$PYP_CKPT_FILE'));print(len(d['criteria']))" 2>/dev/null)" "3"
  check "py-fallback persona: admin/user records untouched (still pass)" \
    "$(python3 -c "import json;d=json.load(open('$PYP_CKPT_FILE'));print(sorted(c['verdict'] for c in d['criteria'] if c['persona']))" 2>/dev/null)" "['pass', 'pass']"

  # persona-scoped evidence gate under the python3 fallback
  PYPGATE_RUN_ID="test-run-py-persona-gate"
  PYPGATE_CKPT_FILE="$WORK/.qa/runs/${PYPGATE_RUN_ID}/checkpoint.json"
  PYPGATE_EVID_PATH="$WORK/.qa/runs/${PYPGATE_RUN_ID}/evidence/admin/PC1/bake-read-back.json"

  (cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$RECORD_SCRIPT" "$PYPGATE_RUN_ID" PC1 bake --persona admin --read-back '{"x":1}' --multiplicity N >/dev/null 2>&1)
  check "py-fallback persona evidence: written under evidence/admin/PC1/" \
    "$([[ -f "$PYPGATE_EVID_PATH" ]] && echo yes)" "yes"

  PYPGATE_OK_OUT="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYPGATE_RUN_ID" PC1 pass --persona admin --kinds bake 2>&1)"
  RC_PYPGATE_OK=$?
  check "py-fallback persona gate: pass with persona-scoped evidence ACCEPTED" "$RC_PYPGATE_OK" "0"

  PYPGATE_NOEV_ERR="$(cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$SCRIPT" "$PYPGATE_RUN_ID" PC1 pass --persona participant --kinds bake 2>&1 >/dev/null)"
  RC_PYPGATE_NOEV=$?
  check "py-fallback persona gate: pass without persona-scoped evidence REJECTED" \
    "$([[ "$RC_PYPGATE_NOEV" -ne 0 ]] && echo yes)" "yes"
  check "py-fallback persona gate: rejected pass did not add a second record" \
    "$(python3 -c "import json;d=json.load(open('$PYPGATE_CKPT_FILE'));print(len(d['criteria']))" 2>/dev/null)" "1"

  echo "note - persona-keying jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - persona-keying jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
