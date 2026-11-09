#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/coverage.sh — per role x surface coverage of a checklist
# against the census, and the ship-profile coverage gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/coverage.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: coverage-gate: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <file> <python expression over `c`> — prints the expression's value (json for lists/dicts).
# r(surfaceId, personaId) returns that coverage row.
q(){ python3 -c '
import json,sys
c=json.load(open(sys.argv[1], encoding="utf-8"))
def r(s,p): return next((x for x in c["rows"] if x["surfaceId"]==s and x["personaId"]==p), None)
v=eval(sys.argv[2])
print(v if isinstance(v,(str,int,bool,float)) or v is None else json.dumps(v, ensure_ascii=False, separators=(",",":")))
' "$1" "$2"; }
C="$FX/census.json"
CF="$FX/census-adapter-failed.json"
ALL="$FX/checklist-all.json"
PART="$FX/checklist-partial.json"
COUNTS='[c["total"],c["covered"],c["excluded"],c["uncovered"]]'

run_engine() {
  local E="$1" T rc; T="$(mktemp -d)"; TMPDIRS+=("$T")
  cov(){ QA_ENGINE=$E bash "$SH" "$@"; }

  # all_covered_exit0
  cov "$C" "$ALL" --mode block > "$T/all.json"; rc=$?
  check "$E all_covered_exit0 exit" "$rc" "0"
  check "$E all_covered counts" "$(q "$T/all.json" "$COUNTS")" '[7,7,0,0]'
  check "$E all_covered percent" "$(q "$T/all.json" 'c["percent"]')" "100"
  check "$E all_covered pair order" "$(q "$T/all.json" '[[x["surfaceId"],x["personaId"]] for x in c["rows"]]')" '[["GET /admin/hackathons","admin"],["GET /h/{slug}","admin"],["GET /h/{slug}","participant"],["GET /الأخبار","participant"],["job:hackathons:close-registration","*"],["mail:App\\Mail\\TeamInvite","*"],["page:Admin/Hackathons/Show","admin"]]'
  check "$E all_covered persona-less row covers every persona" "$(q "$T/all.json" '[r("GET /h/{slug}","admin")["criteria"],r("GET /h/{slug}","participant")["criteria"]]')" '[["C-HACK-PAGE"],["C-HACK-PAGE"]]'
  check "$E all_covered role field matches persona" "$(q "$T/all.json" 'r("GET /الأخبار","participant")["state"]')" "covered"
  check "$E all_covered channel pair covered by any persona" "$(q "$T/all.json" 'r("mail:App\\Mail\\TeamInvite","*")["criteria"]')" '["C-MAIL"]'
  check "$E all_covered no reason on covered rows" "$(q "$T/all.json" 'any("reason" in x for x in c["rows"])')" "False"
  check "$E reachless surface makes no pair" "$(q "$T/all.json" 'any(x["surfaceId"]=="GET /admin/reports" for x in c["rows"])')" "False"

  # uncovered_blocks
  cov "$C" "$PART" --mode block > "$T/pb.json" 2>"$T/pb.err"; rc=$?
  check "$E uncovered_blocks exit" "$rc" "1"
  check "$E uncovered_blocks still prints coverage" "$(q "$T/pb.json" "$COUNTS")" '[7,2,0,5]'
  check "$E uncovered_blocks persona must match" "$(q "$T/pb.json" '[r("GET /admin/hackathons","admin")["criteria"],r("GET /h/{slug}","admin")["state"],r("GET /h/{slug}","participant")["criteria"]]')" '[["C-ADMIN-LIST"],"uncovered",["C-HACK-PARTICIPANT"]]'
  check "$E uncovered_blocks uncovered criteria empty" "$(q "$T/pb.json" 'r("page:Admin/Hackathons/Show","admin")["criteria"]')" '[]'
  check "$E uncovered_blocks says why on stderr" "$(grep -c 'uncovered' "$T/pb.err")" "1"

  # uncovered_advise_exit0
  cov "$C" "$PART" --mode advise > "$T/pa.json"; rc=$?
  check "$E uncovered_advise_exit0 exit" "$rc" "0"
  check "$E uncovered_advise same coverage as block" "$(cmp -s "$T/pa.json" "$T/pb.json" && echo same || echo diff)" "same"

  # --defer-channels
  cov "$C" "$PART" --mode advise --defer-channels > "$T/pd.json"
  check "$E defer_channels counts" "$(q "$T/pd.json" "$COUNTS")" '[7,2,2,3]'
  check "$E defer_channels reason" "$(q "$T/pd.json" '[r("job:hackathons:close-registration","*")["reason"],r("mail:App\\Mail\\TeamInvite","*")["state"]]')" '["channel checks arrive in increment 4","excluded"]'
  cov "$C" "$ALL" --mode advise --defer-channels > "$T/ad.json"
  check "$E defer_channels never overrides a covered channel" "$(q "$T/ad.json" "$COUNTS")" '[7,7,0,0]'

  # exclusion_without_reason_rejected
  for f in empty missing blank; do
    cov "$C" "$PART" --exclusions "$FX/exclusions-$f-reason.json" --mode advise > "$T/x.json" 2>"$T/x.err"; rc=$?
    check "$E exclusion_without_reason_rejected ($f) exit" "$rc" "2"
    check "$E exclusion_without_reason_rejected ($f) message" "$(grep -c 'reason' "$T/x.err")" "1"
  done

  # wildcard_persona_exclusion
  cov "$C" "$PART" --exclusions "$FX/exclusions-wildcard.json" --mode block > "$T/w.json" 2>/dev/null; rc=$?
  check "$E wildcard_persona_exclusion still blocks on others" "$rc" "1"
  check "$E wildcard_persona_exclusion counts" "$(q "$T/w.json" "$COUNTS")" '[7,2,1,4]'
  check "$E wildcard_persona_exclusion excludes uncovered persona" "$(q "$T/w.json" '[r("GET /h/{slug}","admin")["state"],r("GET /h/{slug}","admin")["reason"]]')" '["excluded","public page, checked by the smoke profile"]'
  check "$E wildcard_persona_exclusion covered wins" "$(q "$T/w.json" '[r("GET /h/{slug}","participant")["state"],"reason" in r("GET /h/{slug}","participant")]')" '["covered",false]'

  # percent_rounding_one_decimal
  check "$E percent_rounding 2/7 -> 28.6" "$(q "$T/pb.json" 'c["percent"]')" "28.6"
  cov "$C" "$PART" --exclusions "$FX/exclusions-ok.json" --defer-channels --mode block > "$T/r.json" 2>/dev/null; rc=$?
  check "$E percent_rounding exit" "$rc" "1"
  check "$E percent_rounding counts" "$(q "$T/r.json" "$COUNTS")" '[7,2,4,1]'
  check "$E percent_rounding 2/3 -> 66.7 (excluded leave the denominator)" "$(q "$T/r.json" 'c["percent"]')" "66.7"
  check "$E percent_rounding arabic reason copied" "$(q "$T/r.json" 'r("GET /الأخبار","participant")["reason"]')" "صفحة الأخبار خارج نطاق هذا الإصدار"
  cov "$C" "$PART" --exclusions "$FX/exclusions-ok.json" --mode advise > "$T/r2.json"
  check "$E percent_rounding 2/5 -> 40" "$(q "$T/r2.json" 'c["percent"]')" "40"

  # adapter_warning_surfaces_in_coverage
  check "$E census warnings copied" "$(q "$T/all.json" 'c["warnings"]')" '["skipped vendor route: horizon"]'
  cov "$CF" "$ALL" --mode block > "$T/f.json" 2>"$T/f.err"; rc=$?
  check "$E adapter_warning blocks a fully covered run" "$rc" "1"
  check "$E adapter_warning surfaces in coverage" "$(q "$T/f.json" 'c["warnings"]')" '["adapter-failed: laravel: php: command not found"]'
  check "$E adapter_warning adapterOk false" "$(q "$T/f.json" 'c["adapterOk"]')" "False"
  check "$E adapter_warning names the flag on stderr" "$(grep -c -- '--accept-crawl-only' "$T/f.err")" "1"
  cov "$CF" "$ALL" --mode block --accept-crawl-only > /dev/null; rc=$?
  check "$E adapter_warning --accept-crawl-only exit 0" "$rc" "0"
  cov "$CF" "$ALL" --mode advise > /dev/null; rc=$?
  check "$E adapter_warning advise exit 0" "$rc" "0"
  cov "$CF" "$PART" --mode block --accept-crawl-only > /dev/null 2>&1; rc=$?
  check "$E adapter_warning --accept-crawl-only still blocks uncovered" "$rc" "1"

  # arabic: raw (not \u-escaped) UTF-8 in output
  check "$E arabic raw utf-8 in output" "$(grep -c 'الأخبار' "$T/r.json")" "1"

  # argument / input errors exit 2 (exit 1 is reserved for the gate)
  cov "$C" > /dev/null 2>&1; check "$E missing checklist arg exit 2" "$?" "2"
  cov "$C" "$FX/nope.json" > /dev/null 2>&1; check "$E missing checklist file exit 2" "$?" "2"
  cov "$C" "$ALL" --mode strict > /dev/null 2>&1; check "$E unknown mode exit 2" "$?" "2"
  cov "$C" "$ALL" --bogus > /dev/null 2>&1; check "$E unknown flag exit 2" "$?" "2"
  printf 'not json' > "$T/bad.json"
  cov "$T/bad.json" "$ALL" > /dev/null 2>&1; check "$E malformed census exit 2" "$?" "2"
  echo '{"criteria":[]}' > "$T/obj.json"
  cov "$C" "$T/obj.json" > /dev/null 2>&1; check "$E non-array checklist exit 2" "$?" "2"
  echo '[{"surfaceId":"GET /h/{slug}","personaId":"admin","reason":"x"},{"surfaceId":"GET /h/{slug}","reason":"x"}]' > "$T/nop.json"
  cov "$C" "$ALL" --exclusions "$T/nop.json" > /dev/null 2>&1; check "$E exclusion without personaId exit 2" "$?" "2"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  n=0
  while IFS='|' read -r cen chk args; do
    n=$((n+1))
    # shellcheck disable=SC2086
    QA_ENGINE=jq bash "$SH" "$FX/$cen" "$FX/$chk" $args > "$X/j$n.json" 2>/dev/null
    # shellcheck disable=SC2086
    QA_ENGINE=python3 bash "$SH" "$FX/$cen" "$FX/$chk" $args > "$X/p$n.json" 2>/dev/null
    check "parity #$n ($chk $args) byte-identical" "$(cmp -s "$X/j$n.json" "$X/p$n.json" && echo same || echo diff)" "same"
  done <<EOF
census.json|checklist-all.json|--mode block
census.json|checklist-partial.json|--mode advise
census.json|checklist-partial.json|--mode advise --defer-channels --exclusions $FX/exclusions-ok.json
census.json|checklist-partial.json|--mode block --exclusions $FX/exclusions-wildcard.json
census-adapter-failed.json|checklist-all.json|--mode block --accept-crawl-only
EOF
fi
echo "coverage-gate: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
