#!/usr/bin/env bash
# Round-trip test for qa-kit/scripts/verify-plan.sh — the qa-kit-owned enforcement
# seam that flags an act on a criterion NOT in the frozen plan (checklist.json).
# This proves "phases populate the gate's existing checklist.json" catches out-of-plan
# acts WITHOUT modifying qa-verify (seam B(ii); increment 4 Task 1 finding).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/verify-plan.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-kit-enforcement: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

# checklist.json is a top-level array of entries with .id (the frozen plan {C1,C2})
PLAN='[{"id":"C1","surface":"s","kind":"happy-path","tags":[]},{"id":"C2","surface":"s","kind":"business-rule","tags":[]}]'

run_engine() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf '%s' "$PLAN" > "$T/checklist.json"

  # control: all acts on planned criteria -> ok, exit 0
  printf '%s' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C2","verdict":"fail"}]}' > "$T/cp_ok.json"
  local out rc
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp_ok.json" "$T/checklist.json")"; rc=$?
  check "$E control exit 0" "$rc" "0"
  check "$E control ok true" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "True"

  # out-of-plan: an act on C3 (not in the plan) -> flagged, exit 1
  printf '%s' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C3","verdict":"pass"}]}' > "$T/cp_bad.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp_bad.json" "$T/checklist.json")"; rc=$?
  check "$E out-of-plan exit 1" "$rc" "1"
  check "$E out-of-plan lists C3" "$(printf '%s' "$out" | python3 -c 'import json,sys;print("C3" in json.load(sys.stdin)["outOfPlan"])')" "True"
  check "$E out-of-plan ok false" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "False"

  # multiple out-of-plan -> all listed
  printf '%s' '{"criteria":[{"criterion_id":"C3"},{"criterion_id":"C4"}]}' > "$T/cp_multi.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp_multi.json" "$T/checklist.json")"; rc=$?
  check "$E multi lists both" "$(printf '%s' "$out" | python3 -c 'import json,sys;o=sorted(json.load(sys.stdin)["outOfPlan"]);print(",".join(o))')" "C3,C4"

  # empty checkpoint criteria -> nothing acted -> ok, exit 0
  printf '%s' '{"criteria":[]}' > "$T/cp_empty.json"
  QA_ENGINE=$E bash "$SH" "$T/cp_empty.json" "$T/checklist.json" >/dev/null; rc=$?
  check "$E empty acted -> ok exit 0" "$rc" "0"

  # malformed: checkpoint without .criteria array -> die
  printf '%s' '{}' > "$T/cp_malformed.json"
  QA_ENGINE=$E bash "$SH" "$T/cp_malformed.json" "$T/checklist.json" >/dev/null 2>&1
  check "$E malformed checkpoint dies" "$?" "1"
  # malformed: checklist not an array -> die
  printf '%s' '{"nope":1}' > "$T/pl_malformed.json"
  QA_ENGINE=$E bash "$SH" "$T/cp_ok.json" "$T/pl_malformed.json" >/dev/null 2>&1
  check "$E malformed checklist dies" "$?" "1"
}

command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3

# laundering scenario (audit-2 W2-4): a run-local checklist.json is agent-amendable, so passing
# it as the 2nd arg lets an out-of-plan act slip through undetected if the act was ALSO added to
# the run copy. Proves that passing the frozen SPEC plan instead (never the run copy) still
# catches it: checkpoint acted C1,C3; SPEC checklist (frozen) has only C1; a run-local checklist
# beside it contains C1,C3 (i.e. was amended to legitimize C3) but is NOT passed to verify-plan.sh.
run_engine_laundering() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf '%s' '[{"id":"C1","surface":"s","kind":"happy-path","tags":[]}]' > "$T/spec_checklist.json"
  printf '%s' '[{"id":"C1","surface":"s","kind":"happy-path","tags":[]},{"id":"C3","surface":"s","kind":"happy-path","tags":[]}]' > "$T/run_checklist.json"
  printf '%s' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C3","verdict":"pass"}]}' > "$T/cp.json"
  local out rc
  out="$(QA_ENGINE=$E bash "$SH" "$T/cp.json" "$T/spec_checklist.json")"; rc=$?
  check "$E laundering (spec plan) exit 1" "$rc" "1"
  check "$E laundering (spec plan) outOfPlan==[C3]" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys;print(",".join(sorted(json.load(sys.stdin)["outOfPlan"])))')" "C3"
}
command -v jq >/dev/null 2>&1 && run_engine_laundering jq
command -v python3 >/dev/null 2>&1 && run_engine_laundering python3

# cross-engine byte-identity of the report
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  printf '%s' "$PLAN" > "$X/checklist.json"
  printf '%s' '{"criteria":[{"criterion_id":"C2"},{"criterion_id":"Cx"},{"criterion_id":"Cy"}]}' > "$X/cp.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/cp.json" "$X/checklist.json"; true)"
  vp="$(QA_ENGINE=python3 bash "$SH" "$X/cp.json" "$X/checklist.json"; true)"
  check "cross-engine report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
fi

# ===========================================================================
# Task 11 — qa-kit/scripts/migrate-inverted-criterion.sh
#
# The migration path OUT of the originating incident: a criterion that pins
# `page.rendersWithoutServerError` to false (i.e. grades an HTTP 500 as the
# correct answer) is removed from the frozen plan and re-filed as a known
# defect — with NO ticket and NO expiry, so the command exits 2. That exit is
# the whole point: a known defect with no owner and no deadline is "deferred
# by design" under a new name, and the operator must not be able to mistake
# "filed" for "handled".
#
# What is asserted here, and why each one exists:
#   * the criterion leaves the checklist and the checklist STILL PASSES
#     validate-checklist-json.sh (round-trip against the real consumer);
#   * the registry FAILS known-defects.sh validate for EXACTLY two reasons —
#     `ticket` and `expiry` are empty. Any third error line is a reason the
#     operator cannot act on from the printed instructions, so it is a bug
#     (this is what catches a derived `title` carrying a control character,
#     or a blank `action` deriving an empty title);
#   * `.qa/runs/` is byte-identical before and after (history is read-only,
#     including the original incident's `match: true`), and a target path
#     under `.qa/runs/` is refused outright;
#   * the malformed-input space: missing id, non-array, multi-document,
#     unreadable, unwritable, KD-9/KD-10 id arithmetic, control characters
#     and an embedded newline in `action`;
#   * cross-engine parity of stdout AND of both written files.
# ===========================================================================
MIG="$DIR/../../qa-kit/scripts/migrate-inverted-criterion.sh"
KDSH="$DIR/../../scripts/known-defects.sh"
VCJ="$DIR/../../skills/generating-qa-checklist/scripts/validate-checklist-json.sh"

# The incident shape: EC10 pins the reserved health path to "false".
INV_PLAN='[{"id":"C1","surface":"/a","kind":"happy-path","tags":[],"action":"open the dashboard"},
{"id":"EC10","surface":"/admin/challenges/{challenge}?tab=gates","kind":"error-state","tags":["error"],"action":"open the gates tab as admin","fixture":{"expect":{"path":"page.rendersWithoutServerError","value":"false"}}},
{"id":"C2","surface":"/b","kind":"happy-path","tags":[],"action":"open b"}]'

mig_ids() { python3 -c 'import json,sys;print(",".join(e["id"] for e in json.load(open(sys.argv[1]))))' "$1"; }
mig_reg() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d[int(sys.argv[2])][sys.argv[3]]) if len(d)>int(sys.argv[2]) else "MISSING")' "$1" "$2" "$3"; }
mig_reglen() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$1"; }
snap_runs() { ( cd "$1" && find .qa/runs -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done ); }

# A .qa/runs/ tree whose evidence must survive untouched.
mig_seed_runs() {
  mkdir -p "$1/.qa/runs/2026-09-23-r1"
  printf '%s' '{"criteria":[{"criterion_id":"EC10","verdict":"pass","match":true}]}' > "$1/.qa/runs/2026-09-23-r1/checkpoint.json"
  printf '%s\n' 'seq=1 event=finding_observed' > "$1/.qa/runs/2026-09-23-r1/journal.ndjson"
}

run_migrate_engine() {
  local E="$1" T out rc
  T="$(mktemp -d)"; TMPDIRS+=("$T")
  mkdir -p "$T/.qa"
  printf '%s' "$INV_PLAN" > "$T/checklist.json"
  mig_seed_runs "$T"
  local before after
  before="$(snap_runs "$T")"

  # Precondition: the plan as authored is REJECTED by the validator.
  ( cd "$T" && QA_ENGINE=$E bash "$VCJ" checklist.json ) >/dev/null 2>&1
  check "$E migrate precondition: inverted plan is rejected" "$?" "1"

  out="$(cd "$T" && QA_ENGINE=$E bash "$MIG" checklist.json EC10 2>"$T/err.txt")"; rc=$?

  # test_exits_nonzero_pending_human_input — exit code 2 EXACTLY.
  check "$E migrate exit code is 2" "$rc" "2"
  # test_removes_criterion_from_checklist
  check "$E migrate removes the criterion" "$(mig_ids "$T/checklist.json")" "C1,C2"
  # test_appends_registry_entry_with_empty_ticket_and_expiry
  check "$E migrate registry has 1 entry" "$(mig_reglen "$T/.qa/known-defects.json")" "1"
  check "$E migrate ticket is empty"  "$(mig_reg "$T/.qa/known-defects.json" 0 ticket)"  '""'
  check "$E migrate expiry is empty"  "$(mig_reg "$T/.qa/known-defects.json" 0 expiry)"  '""'
  check "$E migrate id is KD-1"       "$(mig_reg "$T/.qa/known-defects.json" 0 id)"      '"KD-1"'
  check "$E migrate records migratedFrom" "$(mig_reg "$T/.qa/known-defects.json" 0 migratedFrom)" '"EC10"'
  # title from the criterion's action, surface from its surface
  check "$E migrate title from action" "$(mig_reg "$T/.qa/known-defects.json" 0 title)" '"open the gates tab as admin"'
  check "$E migrate surface from surface" "$(mig_reg "$T/.qa/known-defects.json" 0 surface)" '"/admin/challenges/{challenge}?tab=gates"'
  # test_derives_observed_class_from_reserved_path
  check "$E migrate observedClass non-rendering" "$(mig_reg "$T/.qa/known-defects.json" 0 observedClass)" '"non-rendering"'
  check "$E migrate severity floored to high"    "$(mig_reg "$T/.qa/known-defects.json" 0 severity)"      '"high"'
  # test_prints_required_fields — one machine-readable line, exactly two fields.
  check "$E migrate prints required fields" \
    "$(printf '%s\n' "$out" | grep '^REQUIRED-FIELDS:' | head -1)" "REQUIRED-FIELDS: ticket expiry"
  # test_resulting_checklist_passes_validator — round-trip against the real consumer.
  ( cd "$T" && QA_ENGINE=$E bash "$VCJ" checklist.json ) >/dev/null 2>&1
  check "$E migrate result passes checklist validator" "$?" "0"
  # The registry must fail validate for EXACTLY ticket+expiry and nothing else.
  ( cd "$T" && QA_ENGINE=$E bash "$KDSH" validate .qa/known-defects.json 2>"$T/kd.err" >/dev/null )
  check "$E migrate registry fails validate" "$?" "1"
  check "$E migrate registry fails ONLY on ticket+expiry" \
    "$(LC_ALL=C sort "$T/kd.err" | sed 's/^ERROR: //' | tr '\n' ';')" \
    "entry[0].expiry: missing or empty;entry[0].ticket: missing or empty;"
  # test_does_not_touch_runs_directory
  after="$(snap_runs "$T")"
  check "$E migrate leaves .qa/runs untouched" "$([ "$before" = "$after" ] && echo same || echo changed)" "same"

  # test_rerun_is_idempotent — no-op, still exit 2, files byte-identical.
  local c1 r1
  c1="$(cksum < "$T/checklist.json")"; r1="$(cksum < "$T/.qa/known-defects.json")"
  out="$(cd "$T" && QA_ENGINE=$E bash "$MIG" checklist.json EC10 2>>"$T/err.txt")"; rc=$?
  check "$E migrate rerun exit code is 2" "$rc" "2"
  check "$E migrate rerun leaves checklist byte-identical" "$(cksum < "$T/checklist.json")" "$c1"
  check "$E migrate rerun leaves registry byte-identical"  "$(cksum < "$T/.qa/known-defects.json")" "$r1"
  check "$E migrate rerun still prints required fields" \
    "$(printf '%s\n' "$out" | grep '^REQUIRED-FIELDS:' | head -1)" "REQUIRED-FIELDS: ticket expiry"
  check "$E migrate rerun says already migrated" \
    "$(printf '%s\n' "$out" | grep -c 'already migrated')" "1"
}

run_migrate_derivation() {
  local E="$1" T rc
  T="$(mktemp -d)"; TMPDIRS+=("$T")

  # A NON-health criterion: observedClass falls back to wrong-value, not non-rendering.
  printf '%s' '[{"id":"W1","surface":"/s","kind":"computed-logic","tags":[],"action":"check the total","fixture":{"expect":{"path":"counts.evaluators","value":2}}}]' > "$T/wv.json"
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" wv.json W1 --known-defects "$T/wv-reg.json" ) >/dev/null 2>&1
  check "$E derive wrong-value class" "$(mig_reg "$T/wv-reg.json" 0 observedClass)" '"wrong-value"'
  check "$E derive wrong-value severity is in enum" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[0]["severity"] in ("low","medium","high","critical"))' "$T/wv-reg.json")" "True"

  # http.status >= 500 is the reserved namespace too, and carries observedStatus.
  printf '%s' '[{"id":"H1","surface":"/s","kind":"error-state","tags":[],"action":"load the page","expect":{"path":"http.status","value":500}}]' > "$T/hs.json"
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" hs.json H1 --known-defects "$T/hs-reg.json" ) >/dev/null 2>&1
  check "$E derive http.status class" "$(mig_reg "$T/hs-reg.json" 0 observedClass)" '"non-rendering"'
  check "$E derive observedStatus"    "$(mig_reg "$T/hs-reg.json" 0 observedStatus)" "500"
  ( QA_ENGINE=$E bash "$KDSH" validate "$T/hs-reg.json" 2>"$T/hs.err" >/dev/null )
  check "$E derive http.status registry fails ONLY on ticket+expiry" \
    "$(LC_ALL=C sort "$T/hs.err" | sed 's/^ERROR: //' | tr '\n' ';')" \
    "entry[0].expiry: missing or empty;entry[0].ticket: missing or empty;"

  # test_generated_id_increments — KD-9 + KD-10 present -> KD-11, NOT KD-10.
  printf '%s' '[{"id":"KD-9","title":"t","ticket":"P-1","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/x","observedBehaviour":"b"},
{"id":"KD-10","title":"t","ticket":"P-2","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/y","observedBehaviour":"b"}]' > "$T/inc-reg.json"
  printf '%s' "$INV_PLAN" > "$T/inc.json"
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" inc.json EC10 --known-defects "$T/inc-reg.json" ) >/dev/null 2>&1
  check "$E id increments past the highest (9,10 -> 11)" "$(mig_reg "$T/inc-reg.json" 2 id)" '"KD-11"'
  check "$E id increment keeps existing entries" "$(mig_reglen "$T/inc-reg.json")" "3"

  # Non-conforming ids are ignored by the arithmetic (no crash, no collision).
  printf '%s' '[{"id":"OTHER-5","title":"t","ticket":"P-1","expiry":"2026-10-01","severity":"low","observedClass":"degraded","surface":"/x","observedBehaviour":"b"},
{"id":"KD-abc","title":"t","ticket":"P-1","expiry":"2026-10-01","severity":"low","observedClass":"degraded","surface":"/x","observedBehaviour":"b"},
{"id":"KD-99999999999999999999","title":"t","ticket":"P-1","expiry":"2026-10-01","severity":"low","observedClass":"degraded","surface":"/x","observedBehaviour":"b"},
{"id":"KD-4","title":"t","ticket":"P-1","expiry":"2026-10-01","severity":"low","observedClass":"degraded","surface":"/x","observedBehaviour":"b"}]' > "$T/odd-reg.json"
  printf '%s' "$INV_PLAN" > "$T/odd.json"
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" odd.json EC10 --known-defects "$T/odd-reg.json" ) >/dev/null 2>&1
  check "$E id arithmetic ignores non-conforming ids" "$(mig_reg "$T/odd-reg.json" 4 id)" '"KD-5"'

  # A criterion whose `action` carries control characters and an embedded newline:
  # the registry rejects control characters, so the DERIVED title must not smuggle
  # one in — otherwise validate fails for a reason the printed instructions do not
  # mention and the operator cannot act on.
  python3 - "$T/ctl.json" <<'PYEOF'
import json, sys
json.dump([{ "id": "X1", "surface": "/s\u0007urf", "kind": "error-state", "tags": [],
             "action": "open\nthe \u0001gates\ttab",
             "fixture": {"expect": {"path": "page.crashed", "value": True}}}],
          open(sys.argv[1], "w"))
PYEOF
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" ctl.json X1 --known-defects "$T/ctl-reg.json" ) >/dev/null 2>&1
  check "$E control chars stripped from derived title" \
    "$(python3 -c 'import json,sys;t=json.load(open(sys.argv[1]))[0];print(any(ord(c)<32 or ord(c)==127 for c in "".join(v for v in t.values() if isinstance(v,str))))' "$T/ctl-reg.json")" "False"
  ( QA_ENGINE=$E bash "$KDSH" validate "$T/ctl-reg.json" 2>"$T/ctl.err" >/dev/null )
  check "$E control-char entry fails ONLY on ticket+expiry" \
    "$(LC_ALL=C sort "$T/ctl.err" | sed 's/^ERROR: //' | tr '\n' ';')" \
    "entry[0].expiry: missing or empty;entry[0].ticket: missing or empty;"

  # A BLANK action must not derive an empty title (`missing or empty` is not a
  # field the operator was told to supply).
  printf '%s' '[{"id":"B1","surface":"   ","kind":"error-state","tags":[],"action":"   "}]' > "$T/blank.json"
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" blank.json B1 --known-defects "$T/blank-reg.json" ) >/dev/null 2>&1
  ( QA_ENGINE=$E bash "$KDSH" validate "$T/blank-reg.json" 2>"$T/blank.err" >/dev/null )
  check "$E blank action/surface entry fails ONLY on ticket+expiry" \
    "$(LC_ALL=C sort "$T/blank.err" | sed 's/^ERROR: //' | tr '\n' ';')" \
    "entry[0].expiry: missing or empty;entry[0].ticket: missing or empty;"

  # Duplicate criterion ids: every matching row leaves the plan (a duplicate id is
  # already invalid per the validator; leaving one behind would leave the crash
  # assertion in the plan).
  printf '%s' '[{"id":"D1","surface":"/s","kind":"error-state","tags":[],"action":"a","expect":{"path":"page.crashed","value":true}},
{"id":"D1","surface":"/s","kind":"error-state","tags":[],"action":"a","expect":{"path":"page.crashed","value":true}},
{"id":"K1","surface":"/s","kind":"happy-path","tags":[],"action":"a"}]' > "$T/dup.json"
  ( cd "$T" && QA_ENGINE=$E bash "$MIG" dup.json D1 --known-defects "$T/dup-reg.json" ) >/dev/null 2>&1
  check "$E duplicate rows all removed" "$(mig_ids "$T/dup.json")" "K1"
  check "$E duplicate rows produce ONE registry entry" "$(mig_reglen "$T/dup-reg.json")" "1"
}

run_migrate_malformed() {
  local E="$1" T rc c0
  T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf '%s' "$INV_PLAN" > "$T/checklist.json"
  c0="$(cksum < "$T/checklist.json")"

  # no args / one arg -> usage, exit 1
  QA_ENGINE=$E bash "$MIG" >/dev/null 2>&1;                      check "$E malformed: no args" "$?" "1"
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" >/dev/null 2>&1;   check "$E malformed: missing criterion id" "$?" "1"
  # unknown flag / flag without a value
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" EC10 --nope >/dev/null 2>&1
  check "$E malformed: unknown flag" "$?" "1"
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" EC10 --known-defects >/dev/null 2>&1
  check "$E malformed: --known-defects without a value" "$?" "1"
  # a criterion id that is in neither the plan nor the registry
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" NOPE --known-defects "$T/r.json" >/dev/null 2>&1
  check "$E malformed: criterion not found" "$?" "1"
  check "$E malformed: not-found wrote nothing" "$(cksum < "$T/checklist.json")" "$c0"
  check "$E malformed: not-found created no registry" "$([ -e "$T/r.json" ] && echo yes || echo no)" "no"
  # missing checklist file
  QA_ENGINE=$E bash "$MIG" "$T/nosuch.json" EC10 >/dev/null 2>&1
  check "$E malformed: checklist missing" "$?" "1"
  # checklist is not an array
  printf '%s' '{"id":"EC10"}' > "$T/obj.json"
  QA_ENGINE=$E bash "$MIG" "$T/obj.json" EC10 --known-defects "$T/r2.json" >/dev/null 2>&1
  check "$E malformed: checklist not an array" "$?" "1"
  # checklist is not JSON at all
  printf '%s' 'not json' > "$T/bad.json"
  QA_ENGINE=$E bash "$MIG" "$T/bad.json" EC10 --known-defects "$T/r3.json" >/dev/null 2>&1
  check "$E malformed: checklist unparseable" "$?" "1"
  # MULTI-DOCUMENT checklist — must be gated to exactly one document
  printf '%s %s' "$INV_PLAN" "$INV_PLAN" > "$T/multi.json"
  QA_ENGINE=$E bash "$MIG" "$T/multi.json" EC10 --known-defects "$T/r4.json" >/dev/null 2>&1
  check "$E malformed: multi-document checklist" "$?" "1"
  check "$E malformed: multi-doc wrote no registry" "$([ -e "$T/r4.json" ] && echo yes || echo no)" "no"
  # empty checklist file = zero documents
  : > "$T/empty.json"
  QA_ENGINE=$E bash "$MIG" "$T/empty.json" EC10 --known-defects "$T/r5.json" >/dev/null 2>&1
  check "$E malformed: empty checklist file" "$?" "1"
  # MULTI-DOCUMENT registry
  printf '%s' '[] []' > "$T/multireg.json"
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" EC10 --known-defects "$T/multireg.json" >/dev/null 2>&1
  check "$E malformed: multi-document registry" "$?" "1"
  check "$E malformed: multi-doc registry wrote no checklist change" "$(cksum < "$T/checklist.json")" "$c0"
  # registry is not an array
  printf '%s' '{"entries":[]}' > "$T/objreg.json"
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" EC10 --known-defects "$T/objreg.json" >/dev/null 2>&1
  check "$E malformed: registry not an array" "$?" "1"

  # HISTORY IS READ-ONLY: a target path under .qa/runs/ is refused outright.
  mkdir -p "$T/.qa/runs/r1"
  printf '%s' "$INV_PLAN" > "$T/.qa/runs/r1/checklist.json"
  local h0; h0="$(cksum < "$T/.qa/runs/r1/checklist.json")"
  QA_ENGINE=$E bash "$MIG" "$T/.qa/runs/r1/checklist.json" EC10 --known-defects "$T/r6.json" >/dev/null 2>&1
  check "$E refuses a checklist under .qa/runs" "$?" "1"
  check "$E refused run checklist unchanged" "$(cksum < "$T/.qa/runs/r1/checklist.json")" "$h0"
  QA_ENGINE=$E bash "$MIG" "$T/checklist.json" EC10 --known-defects "$T/.qa/runs/r1/known-defects.json" >/dev/null 2>&1
  check "$E refuses a registry under .qa/runs" "$?" "1"

  # UNREADABLE checklist (skipped when running as root, where 000 is still readable)
  if [ "$(id -u)" != "0" ]; then
    printf '%s' "$INV_PLAN" > "$T/noread.json"; chmod 000 "$T/noread.json"
    QA_ENGINE=$E bash "$MIG" "$T/noread.json" EC10 --known-defects "$T/r7.json" >/dev/null 2>&1
    check "$E malformed: unreadable checklist" "$?" "1"
    chmod 644 "$T/noread.json"
    # UNWRITABLE target directory -> nothing is written, including the registry
    mkdir -p "$T/ro"; printf '%s' "$INV_PLAN" > "$T/ro/checklist.json"
    local w0; w0="$(cksum < "$T/ro/checklist.json")"
    chmod 500 "$T/ro"
    QA_ENGINE=$E bash "$MIG" "$T/ro/checklist.json" EC10 --known-defects "$T/rw-reg.json" >/dev/null 2>&1
    check "$E malformed: unwritable checklist dir" "$?" "1"
    check "$E unwritable: registry not written" "$([ -e "$T/rw-reg.json" ] && echo yes || echo no)" "no"
    chmod 700 "$T/ro"
    check "$E unwritable: checklist unchanged" "$(cksum < "$T/ro/checklist.json")" "$w0"
    # UNWRITABLE registry directory -> the checklist keeps its criterion
    mkdir -p "$T/roreg"; chmod 500 "$T/roreg"
    printf '%s' "$INV_PLAN" > "$T/ok.json"; local k0; k0="$(cksum < "$T/ok.json")"
    QA_ENGINE=$E bash "$MIG" "$T/ok.json" EC10 --known-defects "$T/roreg/kd.json" >/dev/null 2>&1
    check "$E malformed: unwritable registry dir" "$?" "1"
    check "$E unwritable registry: checklist unchanged" "$(cksum < "$T/ok.json")" "$k0"
    chmod 700 "$T/roreg"
  fi
}

# ---------------------------------------------------------------------------
# FIX ROUND 1 — the migration key must identify the MIGRATION, not just the
# criterion id.
#
# THE CRITICAL THIS REPLACES. Keying idempotency on `migratedFrom == <id>` alone
# meant a SECOND checklist reusing a criterion id matched the FIRST checklist's
# registry entry: the criterion was deleted from the plan, NO entry was filed for
# it, and the command exited 2 — its success code. An inverted criterion removed
# with nothing gating it is the originating incident's failure mode (a known
# defect with no owner, no deadline and no record) reintroduced by the fix built
# to prevent it.
#
# THE INVARIANT NOW ENFORCED: the criterion is removed only if an entry for THAT
# migration — (`migratedFrom`, `migratedFromChecklist`) — exists on disk
# afterwards. The registry is written first, the entry is then VERIFIED BY
# RE-READING THE FILE (not inferred from the write having returned 0), and only
# then is the criterion removed; the post-state is verified again after.
#
# The deliverable is the reviewer's reproduction INVERTED: two checklists reusing
# id X1, second run -> a second entry is filed for it, never
# removed-with-nothing-filed.
# ---------------------------------------------------------------------------
MIG_INV='[{"id":"X1","surface":"/s","kind":"error-state","tags":[],"action":"open the page","fixture":{"expect":{"path":"page.crashed","value":true}}}]'
# Same id, DIFFERENT content — a genuinely different defect that happens to share an id.
MIG_INV2='[{"id":"X1","surface":"/other","kind":"error-state","tags":[],"action":"open the other page","fixture":{"expect":{"path":"console.hasError","value":true}}}]'

# The invariant, asserted directly: every checklist whose criterion is gone must have
# an entry keyed to THAT checklist. Prints "held" or the first violation.
mig_invariant() { # <registry> <checklist> <criterion-id>
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, os, sys
reg_p, cl_p, cid = sys.argv[1], sys.argv[2], sys.argv[3]
clid = os.path.join(os.path.realpath(os.path.dirname(cl_p)), os.path.basename(cl_p))
reg = json.load(open(reg_p)) if os.path.exists(reg_p) else []
cl = json.load(open(cl_p))
present = any(isinstance(e, dict) and e.get("id") == cid for e in cl)
gated = any(isinstance(e, dict) and e.get("migratedFrom") == cid
            and e.get("migratedFromChecklist") == clid for e in reg)
if present:
    print("held")            # still in the plan: nothing to gate
elif gated:
    print("held")            # removed AND an entry for this migration exists
else:
    print("VIOLATED: criterion removed with no entry for this migration")
PYEOF
}

mig_clid() { python3 -c 'import os,sys;print(os.path.join(os.path.realpath(os.path.dirname(sys.argv[1])),os.path.basename(sys.argv[1])))' "$1"; }

run_migrate_key() {
  local E="$1" T rc out
  T="$(mktemp -d)"; TMPDIRS+=("$T")
  mkdir -p "$T/t1" "$T/t2"
  printf '%s' "$MIG_INV" > "$T/t1/checklist.json"
  printf '%s' "$MIG_INV" > "$T/t2/checklist.json"

  # (1) THE REVIEWER'S REPRODUCTION, INVERTED. Two checklists reusing id X1 and one
  # shared registry: the second run must file its OWN entry, never delete the
  # criterion with nothing gating it.
  ( cd "$T/t1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/kd.json" ) >/dev/null 2>&1
  check "$E key: first checklist exits 2" "$?" "2"
  out="$(cd "$T/t2" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/kd.json" 2>&1)"; rc=$?
  check "$E key: second checklist exits 2" "$rc" "2"
  check "$E key: second checklist files its OWN entry" "$(mig_reglen "$T/kd.json")" "2"
  check "$E key: second entry is KD-2" "$(mig_reg "$T/kd.json" 1 id)" '"KD-2"'
  check "$E key: second entry names its own checklist" \
    "$(mig_reg "$T/kd.json" 1 migratedFromChecklist)" "\"$(mig_clid "$T/t2/checklist.json")\""
  check "$E key: first entry names the first checklist" \
    "$(mig_reg "$T/kd.json" 0 migratedFromChecklist)" "\"$(mig_clid "$T/t1/checklist.json")\""
  check "$E key: second run says it appended" "$(printf '%s\n' "$out" | grep -c 'appended known defect KD-2')" "1"
  # THE INVARIANT, on both checklists.
  check "$E key: invariant holds for checklist 1" "$(mig_invariant "$T/kd.json" "$T/t1/checklist.json" X1)" "held"
  check "$E key: invariant holds for checklist 2" "$(mig_invariant "$T/kd.json" "$T/t2/checklist.json" X1)" "held"
  # And the registry still fails ONLY on the empty ticket/expiry of BOTH entries.
  ( QA_ENGINE=$E bash "$KDSH" validate "$T/kd.json" 2>"$T/kd2.err" >/dev/null )
  check "$E key: two-entry registry fails ONLY on ticket+expiry" \
    "$(LC_ALL=C sort "$T/kd2.err" | sed 's/^ERROR: //' | tr '\n' ';')" \
    "entry[0].expiry: missing or empty;entry[0].ticket: missing or empty;entry[1].expiry: missing or empty;entry[1].ticket: missing or empty;"

  # (2) Same id, DIFFERENT content -> also two entries (two distinct migrations).
  mkdir -p "$T/d1" "$T/d2"
  printf '%s' "$MIG_INV"  > "$T/d1/checklist.json"
  printf '%s' "$MIG_INV2" > "$T/d2/checklist.json"
  ( cd "$T/d1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/dkd.json" ) >/dev/null 2>&1
  ( cd "$T/d2" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/dkd.json" ) >/dev/null 2>&1
  check "$E key: same id different content -> two entries" "$(mig_reglen "$T/dkd.json")" "2"
  check "$E key: different-content entry keeps its own surface" "$(mig_reg "$T/dkd.json" 1 surface)" '"/other"'
  check "$E key: invariant holds for d2" "$(mig_invariant "$T/dkd.json" "$T/d2/checklist.json" X1)" "held"

  # (3) The SAME checklist migrated twice -> still exactly one entry, no-op, exit 2.
  mkdir -p "$T/s1"; printf '%s' "$MIG_INV" > "$T/s1/checklist.json"
  ( cd "$T/s1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/skd.json" ) >/dev/null 2>&1
  local sc sr
  sc="$(cksum < "$T/s1/checklist.json")"; sr="$(cksum < "$T/skd.json")"
  out="$(cd "$T/s1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/skd.json" 2>&1)"; rc=$?
  check "$E key: same checklist twice exits 2" "$rc" "2"
  check "$E key: same checklist twice keeps ONE entry" "$(mig_reglen "$T/skd.json")" "1"
  check "$E key: same checklist twice is a no-op (registry)"  "$(cksum < "$T/skd.json")" "$sr"
  check "$E key: same checklist twice is a no-op (checklist)" "$(cksum < "$T/s1/checklist.json")" "$sc"
  check "$E key: same checklist twice says already migrated" "$(printf '%s\n' "$out" | grep -c 'already migrated')" "1"

  # (4) RELATIVE vs ABSOLUTE path for the same file -> the SAME migration.
  mkdir -p "$T/r1"; printf '%s' "$MIG_INV" > "$T/r1/checklist.json"
  ( cd "$T/r1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/rkd.json" ) >/dev/null 2>&1
  out="$(QA_ENGINE=$E bash "$MIG" "$T/r1/checklist.json" X1 --known-defects "$T/rkd.json" 2>&1)"; rc=$?
  check "$E key: relative-then-absolute exits 2" "$rc" "2"
  check "$E key: relative-then-absolute is ONE migration" "$(mig_reglen "$T/rkd.json")" "1"
  check "$E key: relative-then-absolute says already migrated" "$(printf '%s\n' "$out" | grep -c 'already migrated')" "1"
  # ... and via a SYMLINKED parent directory, which `pwd -P` must resolve to the same path.
  ln -s "$T/r1" "$T/r1-link"
  out="$(QA_ENGINE=$E bash "$MIG" "$T/r1-link/checklist.json" X1 --known-defects "$T/rkd.json" 2>&1)"; rc=$?
  check "$E key: symlinked parent is the SAME migration" "$(mig_reglen "$T/rkd.json")" "1"
  check "$E key: symlinked parent exits 2" "$rc" "2"

  # (5) A registry that ALREADY holds an entry for a DIFFERENT checklist's X1 —
  # hand-written, as an operator's registry would be — must not gate ours.
  mkdir -p "$T/o1"; printf '%s' "$MIG_INV" > "$T/o1/checklist.json"
  printf '%s' '[{"id":"KD-7","title":"someone else","ticket":"P-1","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/elsewhere","observedBehaviour":"b","migratedFrom":"X1","migratedFromChecklist":"/some/other/project/checklist.json"}]' > "$T/okd.json"
  ( cd "$T/o1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/okd.json" ) >/dev/null 2>&1
  check "$E key: another checklist's X1 does not gate ours" "$(mig_reglen "$T/okd.json")" "2"
  check "$E key: our entry increments past KD-7" "$(mig_reg "$T/okd.json" 1 id)" '"KD-8"'
  check "$E key: invariant holds against a foreign entry" "$(mig_invariant "$T/okd.json" "$T/o1/checklist.json" X1)" "held"

  # (6) A LEGACY entry (migratedFrom, no migratedFromChecklist) identifies no
  # migration, so it cannot gate a removal: a properly keyed entry is filed.
  mkdir -p "$T/l1"; printf '%s' "$MIG_INV" > "$T/l1/checklist.json"
  printf '%s' '[{"id":"KD-1","title":"legacy","ticket":"","expiry":"","severity":"high","observedClass":"non-rendering","surface":"/s","observedBehaviour":"b","migratedFrom":"X1"}]' > "$T/lkd.json"
  ( cd "$T/l1" && QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/lkd.json" ) >/dev/null 2>&1
  check "$E key: a legacy unkeyed entry does not gate a removal" "$(mig_reglen "$T/lkd.json")" "2"
  check "$E key: invariant holds against a legacy entry" "$(mig_invariant "$T/lkd.json" "$T/l1/checklist.json" X1)" "held"

  # (7) POST-STATE IS VERIFIED, NOT INFERRED. Fault injection: a `mv` shim on PATH
  # silently drops the registry rename, so the write "succeeds" and the entry is not
  # there. The criterion must NOT be removed, and the command must exit 1.
  mkdir -p "$T/p1" "$T/shim"
  printf '%s' "$MIG_INV" > "$T/p1/checklist.json"
  local pc; pc="$(cksum < "$T/p1/checklist.json")"
  cat > "$T/shim/mv" <<'SHIMEOF'
#!/usr/bin/env bash
# fault injection: silently drop the rename that would publish the registry
for a in "$@"; do case "$a" in *kd-drop.json|*checklist-drop.json) exit 0 ;; esac; done
exec /bin/mv "$@"
SHIMEOF
  chmod +x "$T/shim/mv"
  ( cd "$T/p1" && PATH="$T/shim:$PATH" QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/kd-drop.json" ) >/dev/null 2>&1
  check "$E post-state: dropped registry write exits 1" "$?" "1"
  check "$E post-state: dropped registry write leaves the criterion in the plan" \
    "$(cksum < "$T/p1/checklist.json")" "$pc"
  check "$E post-state: invariant holds after a dropped write" \
    "$(mig_invariant "$T/kd-drop.json" "$T/p1/checklist.json" X1)" "held"

  # (8) ...and the SECOND verification: the same shim drops the CHECKLIST rename, so
  # the entry is filed but the criterion is still in the plan. That is the SAFE
  # direction (a filed defect whose criterion survives, which a re-run finishes), but
  # it is not a consistent end state, so it must be reported as exit 1 rather than
  # declared a success.
  mkdir -p "$T/p2"
  printf '%s' "$MIG_INV" > "$T/p2/checklist-drop.json"
  local pc2; pc2="$(cksum < "$T/p2/checklist-drop.json")"
  ( cd "$T/p2" && PATH="$T/shim:$PATH" QA_ENGINE=$E bash "$MIG" checklist-drop.json X1 --known-defects "$T/kd2ok.json" ) >/dev/null 2>&1
  check "$E post-state: dropped checklist write exits 1" "$?" "1"
  check "$E post-state: dropped checklist write still filed the entry" "$(mig_reglen "$T/kd2ok.json")" "1"
  check "$E post-state: dropped checklist write left the plan intact" \
    "$(cksum < "$T/p2/checklist-drop.json")" "$pc2"
  check "$E post-state: invariant holds after a dropped checklist write" \
    "$(mig_invariant "$T/kd2ok.json" "$T/p2/checklist-drop.json" X1)" "held"

  # (9) THE VERIFICATION MUST USE THE WHOLE KEY. A mutation battery found that the
  # post-check could be loosened to `migratedFrom` alone with no test failing — the
  # engine always writes the full key, so the checklist half never mattered. It matters
  # HERE: the registry already holds a FOREIGN entry for another checklist's X1, and the
  # shim drops the append of ours. A post-check keyed on the criterion id alone accepts
  # the foreign entry as proof, removes our criterion and exits 2 — the Critical again,
  # one layer down. Keyed on both fields it exits 1 with the plan intact.
  mkdir -p "$T/p3"
  printf '%s' "$MIG_INV" > "$T/p3/checklist.json"
  printf '%s' '[{"id":"KD-7","title":"another project","ticket":"P-1","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/elsewhere","observedBehaviour":"b","migratedFrom":"X1","migratedFromChecklist":"/some/other/project/checklist.json"}]' > "$T/p3-kd-drop.json"
  local pc3; pc3="$(cksum < "$T/p3/checklist.json")"
  ( cd "$T/p3" && PATH="$T/shim:$PATH" QA_ENGINE=$E bash "$MIG" checklist.json X1 --known-defects "$T/p3-kd-drop.json" ) >/dev/null 2>&1
  check "$E post-state: a foreign entry is not proof of OUR migration" "$?" "1"
  check "$E post-state: foreign entry leaves our criterion in the plan" \
    "$(cksum < "$T/p3/checklist.json")" "$pc3"
  check "$E post-state: foreign-entry registry is unchanged" "$(mig_reglen "$T/p3-kd-drop.json")" "1"
  check "$E post-state: invariant holds against a foreign entry + dropped write" \
    "$(mig_invariant "$T/p3-kd-drop.json" "$T/p3/checklist.json" X1)" "held"
}

command -v jq >/dev/null 2>&1      && run_migrate_key jq
command -v python3 >/dev/null 2>&1 && run_migrate_key python3

command -v jq >/dev/null 2>&1      && { run_migrate_engine jq;      run_migrate_derivation jq;      run_migrate_malformed jq; }
command -v python3 >/dev/null 2>&1 && { run_migrate_engine python3; run_migrate_derivation python3; run_migrate_malformed python3; }

# Cross-engine parity: identical stdout AND identical written files. Two Wave-1
# lanes shipped engine divergence in exactly this shape, so it is asserted, not
# assumed.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  P="$(mktemp -d)"; TMPDIRS+=("$P")
  # Both engines run in the SAME directory on the SAME paths, inputs reset between
  # runs: `migratedFromChecklist` is a resolved absolute path, so a per-engine
  # directory would make the two outputs differ for a reason that is not divergence.
  mkdir -p "$P/wk"
  for eng in jq python3; do
    printf '%s' "$INV_PLAN" > "$P/wk/checklist.json"
    printf '%s' '[{"id":"KD-9","title":"t","ticket":"P-1","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/x","observedBehaviour":"b"}]' > "$P/wk/kd.json"
    ( cd "$P/wk" && QA_ENGINE=$eng bash "$MIG" checklist.json EC10 --known-defects kd.json ) > "$P/$eng.out" 2>&1
    cp "$P/wk/checklist.json" "$P/$eng.checklist"
    cp "$P/wk/kd.json" "$P/$eng.registry"
  done
  check "migrate: cross-engine stdout identical" \
    "$(cmp -s "$P/jq.out" "$P/python3.out" && echo same || echo diff)" "same"
  check "migrate: cross-engine checklist identical" \
    "$(cmp -s "$P/jq.checklist" "$P/python3.checklist" && echo same || echo diff)" "same"
  check "migrate: cross-engine registry identical" \
    "$(cmp -s "$P/jq.registry" "$P/python3.registry" && echo same || echo diff)" "same"
fi

echo "qa-kit-enforcement (incl. migrate-inverted-criterion): PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
