#!/usr/bin/env bash
# Dual-engine tests for the ship-QA checklist schema additions (decision D1 of
# docs/superpowers/plans/2026-11-09-ship-qa-increment-1-census-ship-profile.md)
# in skills/generating-qa-checklist/scripts/validate-checklist-json.sh:
# optional `surfaceId` / `priority` / `journey` / `variant` row fields and the
# kinds `load-clean`, `deny`, `input-validation`. Legacy (v2-style) checklists
# must validate byte-identically to the pre-change validator (golden below).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../skills/generating-qa-checklist/scripts/validate-checklist-json.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: checklist-ship-schema: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
contains(){ case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# --- fixtures ---------------------------------------------------------------
# v2-style legacy checklist: valid, no new fields.
LEGACY_OK='[{"id":"C-FOUNDERS-01","surface":"/founders","kind":"happy-path","tags":["human-action"],"action":"create a founder","requiredKinds":["bake","human-action"],"assertedState":{"entity":"Founder","readBackPath":"count","expectChange":true},"humanAction":true},{"id":"C-FOUNDERS-02","surface":"/founders","kind":"loading-state","tags":["read-only"],"action":"view the list","requiredKinds":[],"assertedState":null,"humanAction":false}]'
# v2-style legacy checklist with many violations; its stderr below is the
# golden captured from the validator BEFORE the D1 change (both engines agreed).
LEGACY_BAD='[{"id":"L-1","surface":"/a","kind":"bogus","tags":["x",1],"action":"a","requiredKinds":["bake","zzz"],"assertedState":{"entity":"E"},"humanAction":"yes","mutates":false},
 {"id":"L-1","surface":5,"kind":"happy-path","tags":[],"action":"b","fixture":{"expect":{"path":"http.status","value":" 500 ","oracle":"Deferred by design"}}},
 {"surface":"/c","kind":"race","tags":[],"action":"c","mutates":false,"humanAction":true}]'
LEGACY_BAD_GOLDEN='ERROR: entry[0].kind: bogus: must be one of the kind enum
ERROR: entry[0].tags: must be an array of strings
ERROR: entry[0].requiredKinds: invalid kind(s) zzz
ERROR: entry[0].assertedState.readBackPath: must be a string
ERROR: entry[0].assertedState.expectChange: must be a boolean
ERROR: entry[0].humanAction: must be a boolean
ERROR: entry[1].surface: must be a string
ERROR: entry[1].fixture.expect: http.status may not be pinned to 500 (a 5xx asserts the application FAILED; 3xx/4xx stay legal) — move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)
ERROR: entry[1].fixture.expect.oracle: reserved phrase "deferred by design" may not appear in an oracle/expect field — a criterion may not assert that the application failed
ERROR: entry[2].id: must be a non-empty string
ERROR: entry[2].mutates: false contradicts humanAction/requiredKinds human-action — a row cannot declare itself non-mutating and require a human-action trace
ERROR: duplicate id "L-1": appears 2 times'
NEWKINDS='[{"id":"S-LOAD-1","surface":"/dashboard","surfaceId":"page:dashboard","priority":"P1","kind":"load-clean","tags":["read-only","independent"],"action":"open the dashboard"},
 {"id":"S-DENY-1","surface":"/admin/users","surfaceId":["page:admin.users","endpoint:GET /admin/users"],"priority":"P2","kind":"deny","tags":["read-only","deny-write-deferred"],"action":"open the admin users page as a participant"},
 {"id":"S-INPUT-1","surface":"/ideas/create","surfaceId":"page:ideas.create","priority":"P3","kind":"input-validation","tags":["human-action"],"action":"submit the idea form with an empty title"},
 {"id":"S-ISO-1","surface":"/ideas/42","kind":"cross-tenant","tags":["ownership-isolation","read-only"],"action":"open another participant idea","journey":{"id":"J-SUBMIT","step":1},"variant":{"viewport":"390x844","locale":"ar","colorScheme":"dark"}},
 {"id":"S-UX-1","surface":"/ideas","kind":"happy-path","tags":["ux-revisit","read-only","independent"],"action":"revisit the ideas list","variant":{"colorScheme":"light"}}]'
row(){ printf '[{"id":"R-1","surface":"/x","kind":"happy-path","tags":[],"action":"a",%s}]' "$1"; }

run_engine() {
  local E="$1" T out rc; T="$(mktemp -d)"; TMPDIRS+=("$T")
  # legacy_rows_unchanged
  printf '%s' "$LEGACY_OK" > "$T/lok.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/lok.json" 2>&1)"; rc=$?
  check "$E legacy_rows_unchanged: valid legacy -> exit 0" "$rc" "0"
  check "$E legacy_rows_unchanged: valid legacy -> no output" "$out" ""
  printf '%s' "$LEGACY_BAD" > "$T/lbad.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/lbad.json" 2>&1)"; rc=$?
  check "$E legacy_rows_unchanged: invalid legacy -> exit 1" "$rc" "1"
  check "$E legacy_rows_unchanged: invalid legacy output == pre-change golden" "$out" "$LEGACY_BAD_GOLDEN"
  # new_kinds_accepted (+ all new fields in valid shapes)
  printf '%s' "$NEWKINDS" > "$T/nk.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/nk.json" 2>&1)"; rc=$?
  check "$E new_kinds_accepted -> exit 0" "$rc" "0"
  check "$E new_kinds_accepted -> no output" "$out" ""
  # bad_priority_rejected
  row '"priority":"P0"' > "$T/p0.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/p0.json" 2>&1)"; rc=$?
  check "$E bad_priority_rejected -> exit 1" "$rc" "1"
  check "$E bad_priority_rejected names field" "$(contains "$out" "entry[0].priority")" "yes"
  check "$E bad_priority_rejected names row id" "$(contains "$out" '"R-1"')" "yes"
  row '"priority":null' > "$T/pn.json"
  QA_ENGINE=$E bash "$SH" "$T/pn.json" >/dev/null 2>&1; check "$E priority null tolerated" "$?" "0"
  # journey_step_zero_rejected
  row '"journey":{"id":"J-1","step":0}' > "$T/j0.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/j0.json" 2>&1)"; rc=$?
  check "$E journey_step_zero_rejected -> exit 1" "$rc" "1"
  check "$E journey_step_zero_rejected names field+row" "$(contains "$out" 'entry[0].journey.step')$(contains "$out" '"R-1"')" "yesyes"
  row '"journey":{"id":"J-1","step":1.5}' > "$T/jf.json"
  QA_ENGINE=$E bash "$SH" "$T/jf.json" >/dev/null 2>&1; check "$E journey non-integer step -> exit 1" "$?" "1"
  row '"journey":{"step":2}' > "$T/jn.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/jn.json" 2>&1)"; rc=$?
  check "$E journey missing id -> exit 1 naming journey.id" "$rc$(contains "$out" 'entry[0].journey.id')" "1yes"
  row '"journey":"J-1"' > "$T/js.json"
  QA_ENGINE=$E bash "$SH" "$T/js.json" >/dev/null 2>&1; check "$E journey not an object -> exit 1" "$?" "1"
  # variant_dark_ok_sepia_rejected
  row '"variant":{"colorScheme":"dark"}' > "$T/vd.json"
  QA_ENGINE=$E bash "$SH" "$T/vd.json" >/dev/null 2>&1; check "$E variant_dark_ok" "$?" "0"
  row '"variant":{}' > "$T/ve.json"
  QA_ENGINE=$E bash "$SH" "$T/ve.json" >/dev/null 2>&1; check "$E variant keys individually optional" "$?" "0"
  row '"variant":{"colorScheme":"sepia"}' > "$T/vs.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/vs.json" 2>&1)"; rc=$?
  check "$E variant_sepia_rejected -> exit 1" "$rc" "1"
  check "$E variant_sepia_rejected names field+row" "$(contains "$out" 'entry[0].variant.colorScheme')$(contains "$out" '"R-1"')" "yesyes"
  row '"variant":{"viewport":1280}' > "$T/vv.json"
  QA_ENGINE=$E bash "$SH" "$T/vv.json" >/dev/null 2>&1; check "$E variant non-string viewport -> exit 1" "$?" "1"
  # surfaceId shapes
  row '"surfaceId":""' > "$T/s1.json"
  QA_ENGINE=$E bash "$SH" "$T/s1.json" >/dev/null 2>&1; check "$E surfaceId empty string -> exit 1" "$?" "1"
  row '"surfaceId":[]' > "$T/s2.json"
  QA_ENGINE=$E bash "$SH" "$T/s2.json" >/dev/null 2>&1; check "$E surfaceId empty array -> exit 1" "$?" "1"
  row '"surfaceId":["page:a",""]' > "$T/s3.json"
  out="$(QA_ENGINE=$E bash "$SH" "$T/s3.json" 2>&1)"; rc=$?
  check "$E surfaceId array with empty member -> exit 1 naming surfaceId" "$rc$(contains "$out" 'entry[0].surfaceId')" "1yes"
  row '"surfaceId":7' > "$T/s4.json"
  QA_ENGINE=$E bash "$SH" "$T/s4.json" >/dev/null 2>&1; check "$E surfaceId number -> exit 1" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  # QA_ENGINE really switches engines: the invalid-JSON message is engine-specific.
  printf '%s' '[{' > "$X/broken.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/broken.json" 2>&1)"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/broken.json" 2>&1)"
  check "QA_ENGINE selects distinct engines" "$([ "$vj" != "$vp" ] && echo distinct || echo same)" "distinct"
  # arabic_text_parity: Arabic action + Arabic row id inside error messages.
  printf '%s' '[{"id":"م-١","surface":"/الأفكار","surfaceId":"صفحة:الأفكار","kind":"deny","tags":[],"action":"افتح صفحة إدارة المستخدمين بصفتك مشاركاً","priority":"P9","journey":{"id":"رحلة-التقديم","step":0},"variant":{"locale":"ar","colorScheme":"sepia"}},{"id":"م-٢","surface":"/x","kind":"load-clean","tags":[],"action":"عرض لوحة المعلومات"}]' > "$X/ar.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/ar.json" 2>&1; echo "rc=$?")"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/ar.json" 2>&1; echo "rc=$?")"
  check "arabic_text_parity: jq and python3 byte-identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  check "arabic_text_parity: Arabic row id printed raw" "$(contains "$vj" '"م-١"')" "yes"
  [ "$vj" = "$vp" ] || { echo "--- jq:"; echo "$vj"; echo "--- python3:"; echo "$vp"; }
  # cross-engine parity on every new-field violation shape at once.
  printf '%s' '[{"id":"P-1","surface":"/x","kind":"input-validation","tags":[],"action":"a","surfaceId":["ok",3],"priority":1,"journey":{"id":"","step":"1"},"variant":{"viewport":"","locale":5,"colorScheme":"Dark"}},{"id":"P-2","surface":"/x","kind":"deny","tags":[],"action":"a","journey":null,"variant":"dark","surfaceId":null}]' > "$X/all.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/all.json" 2>&1; echo "rc=$?")"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/all.json" 2>&1; echo "rc=$?")"
  check "cross-engine new-field violations byte-identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  [ "$vj" = "$vp" ] || { echo "--- jq:"; echo "$vj"; echo "--- python3:"; echo "$vp"; }
fi
echo "checklist-ship-schema: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
