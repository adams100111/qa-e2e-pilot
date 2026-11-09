#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/coverage.sh — per role x surface coverage of a checklist
# against the census (functional vs sweep coverage, --scope / --roles filters, glob exclusions), and
# the ship-profile coverage gate.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/coverage.sh"
FX="$DIR/fixtures"
# python3 is required even for the jq leg: q() reads the results with it.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: coverage-gate: python3 not available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
SHARED="$(mktemp -d)"; TMPDIRS+=("$SHARED")
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
  check "$E all_covered counts" "$(q "$T/all.json" "$COUNTS")" '[8,8,0,0]'
  check "$E all_covered percent" "$(q "$T/all.json" 'c["percent"]')" "100"
  check "$E all_covered pair order" "$(q "$T/all.json" '[[x["surfaceId"],x["personaId"]] for x in c["rows"]]')" '[["GET /admin/hackathons","admin"],["GET /admin/reports","*"],["GET /h/{slug}","admin"],["GET /h/{slug}","participant"],["GET /الأخبار","participant"],["job:hackathons:close-registration","*"],["mail:App\\Mail\\TeamInvite","*"],["page:Admin/Hackathons/Show","admin"]]'
  check "$E all_covered each persona by its own row" "$(q "$T/all.json" '[r("GET /h/{slug}","admin")["criteria"],r("GET /h/{slug}","participant")["criteria"],c["unscopedCovered"]]')" '[["C-HACK-PAGE"],["C-HACK-VIEW"],0]'
  check "$E all_covered role field matches persona" "$(q "$T/all.json" 'r("GET /الأخبار","participant")["state"]')" "covered"
  check "$E all_covered channel pair covered by any persona" "$(q "$T/all.json" 'r("mail:App\\Mail\\TeamInvite","*")["criteria"]')" '["C-MAIL"]'
  check "$E all_covered no reason on covered rows" "$(q "$T/all.json" 'any("reason" in x for x in c["rows"])')" "False"
  # unreached_declared_surface_is_a_star_pair (I2): an adapter surface nobody reached must still be covered
  check "$E unreached adapter surface is a * pair" "$(q "$T/all.json" '[x["personaId"] for x in c["rows"] if x["surfaceId"]=="GET /admin/reports"]')" '["*"]'
  check "$E * pair covered by a scoped functional row" "$(q "$T/all.json" 'r("GET /admin/reports","*")["criteria"]')" '["C-REPORTS"]'

  # require_visual_ux: every in-scope UI surface needs a visual-ux row (ship plan); channels and
  # non-GET writes are not UI surfaces; without the flag the output has no uxMissing key.
  check "$E no uxMissing key without the flag" "$(q "$T/all.json" '"uxMissing" in c')" "False"
  cov "$C" "$ALL" --mode block --require-visual-ux > "$T/ux0.json" 2> "$T/ux0.err"; rc=$?
  check "$E require_visual_ux blocks when surfaces lack a visual-ux row" "$rc" "1"
  check "$E require_visual_ux lists the UI surfaces" "$(q "$T/ux0.json" 'c["uxMissing"]')" '["GET /admin/hackathons","GET /admin/reports","GET /h/{slug}","GET /الأخبار","page:Admin/Hackathons/Show"]'
  check "$E require_visual_ux message" "$(grep -c '5 surface(s) have no visual-ux criterion' "$T/ux0.err")" "1"
  check "$E require_visual_ux leaves coverage counts alone" "$(q "$T/ux0.json" "$COUNTS")" '[8,8,0,0]'
  python3 -c '
import json,sys
k=json.load(open(sys.argv[1],encoding="utf-8"))
k.append({"id":"UX-1","surfaceId":["GET /admin/hackathons","GET /admin/reports","GET /h/{slug}","GET /الأخبار"],"persona":"admin","tags":["visual-ux"]})
json.dump(k,open(sys.argv[2],"w",encoding="utf-8"),ensure_ascii=False)' "$ALL" "$T/k-ux.json"
  cov "$C" "$T/k-ux.json" --mode block --require-visual-ux > "$T/ux1.json" 2>/dev/null; rc=$?
  check "$E require_visual_ux one surface left" "[$rc,$(q "$T/ux1.json" 'c["uxMissing"]')]" '[1,["page:Admin/Hackathons/Show"]]'
  cov "$C" "$T/k-ux.json" --mode advise --require-visual-ux > "$T/ux2.json" 2>/dev/null; rc=$?
  check "$E require_visual_ux advise reports without blocking" "[$rc,$(q "$T/ux2.json" 'len(c["uxMissing"])')]" '[0,1]'
  printf '%s' '[{"surfaceId":"page:Admin/Hackathons/Show","personaId":"*","reason":"legacy page, retired next sprint"}]' > "$T/ux-ex.json"
  cov "$C" "$T/k-ux.json" --mode block --require-visual-ux --exclusions "$T/ux-ex.json" > "$T/ux3.json" 2>/dev/null; rc=$?
  check "$E require_visual_ux excluded surface not required" "[$rc,$(q "$T/ux3.json" 'c["uxMissing"]')]" '[0,[]]'

  # unscoped_row_does_not_cover_role_pair_in_block
  U="$FX/checklist-unscoped.json"
  cov "$C" "$U" --mode block > "$T/ub.json" 2>/dev/null; rc=$?
  check "$E unscoped_row_does_not_cover_role_pair_in_block exit" "$rc" "1"
  check "$E unscoped block counts" "$(q "$T/ub.json" '[c["total"],c["covered"],c["excluded"],c["uncovered"],c["unscopedCovered"],c["percent"]]')" '[8,6,0,2,2,75]'
  check "$E unscoped rows labelled" "$(q "$T/ub.json" '[r("GET /h/{slug}","admin")["state"],r("GET /h/{slug}","admin")["criteria"],r("page:Admin/Hackathons/Show","admin")["state"]]')" '["covered-unscoped",["C-HACK-PAGE","C-HACK-ANY"],"covered-unscoped"]'
  check "$E scoped row wins over unscoped" "$(q "$T/ub.json" '[r("GET /h/{slug}","participant")["state"],r("GET /h/{slug}","participant")["criteria"]]')" '["covered",["C-HACK-VIEW"]]'
  check "$E channel pair covered by a persona-less row" "$(q "$T/ub.json" 'r("job:hackathons:close-registration","*")["state"]')" "covered"
  cov "$C" "$U" --mode advise > "$T/ua.json"; rc=$?
  check "$E unscoped advise exit 0" "$rc" "0"
  check "$E unscoped advise counts toward covered" "$(q "$T/ua.json" '[c["total"],c["covered"],c["excluded"],c["uncovered"],c["unscopedCovered"],c["percent"]]')" '[8,8,0,0,2,100]'
  check "$E unscoped advise still labelled" "$(q "$T/ua.json" 'r("GET /h/{slug}","admin")["state"]')" "covered-unscoped"

  # empty_census_blocks
  E0="$FX/census-empty.json"
  cov "$E0" "$ALL" --mode block > "$T/e.json" 2>"$T/e.err"; rc=$?
  check "$E empty_census_blocks exit" "$rc" "1"
  check "$E empty_census_blocks message" "$(grep -c '^coverage: nothing to cover — census is empty or uncrawled$' "$T/e.err")" "1"
  check "$E empty_census_blocks counts" "$(q "$T/e.json" "$COUNTS")" '[0,0,0,0]'
  cov "$E0" "$ALL" --mode advise > /dev/null 2>&1; rc=$?
  check "$E empty_census advise exit 0" "$rc" "0"
  cov "$C" "$FX/checklist-empty.json" --mode block --defer-channels --exclusions "$FX/exclusions-all.json" > /dev/null 2>"$T/ex.err"; rc=$?
  check "$E everything excluded blocks" "$rc$(grep -c 'nothing to cover' "$T/ex.err")" "11"

  # uncovered_blocks
  cov "$C" "$PART" --mode block > "$T/pb.json" 2>"$T/pb.err"; rc=$?
  check "$E uncovered_blocks exit" "$rc" "1"
  check "$E uncovered_blocks still prints coverage" "$(q "$T/pb.json" "$COUNTS")" '[8,2,0,6]'
  check "$E uncovered_blocks persona must match" "$(q "$T/pb.json" '[r("GET /admin/hackathons","admin")["criteria"],r("GET /h/{slug}","admin")["state"],r("GET /h/{slug}","participant")["criteria"]]')" '[["C-ADMIN-LIST"],"uncovered",["C-HACK-PARTICIPANT"]]'
  check "$E uncovered_blocks uncovered criteria empty" "$(q "$T/pb.json" 'r("page:Admin/Hackathons/Show","admin")["criteria"]')" '[]'
  check "$E uncovered_blocks says why on stderr" "$(grep -c 'uncovered' "$T/pb.err")" "1"

  # uncovered_advise_exit0
  cov "$C" "$PART" --mode advise > "$T/pa.json"; rc=$?
  check "$E uncovered_advise_exit0 exit" "$rc" "0"
  check "$E uncovered_advise same coverage as block" "$(cmp -s "$T/pa.json" "$T/pb.json" && echo same || echo diff)" "same"

  # --defer-channels
  cov "$C" "$PART" --mode advise --defer-channels > "$T/pd.json"
  check "$E defer_channels counts" "$(q "$T/pd.json" "$COUNTS")" '[8,2,2,4]'
  check "$E defer_channels reason" "$(q "$T/pd.json" '[r("job:hackathons:close-registration","*")["reason"],r("mail:App\\Mail\\TeamInvite","*")["state"]]')" '["channel checks arrive in increment 4","excluded"]'
  cov "$C" "$ALL" --mode advise --defer-channels > "$T/ad.json"
  check "$E defer_channels never overrides a covered channel" "$(q "$T/ad.json" "$COUNTS")" '[8,8,0,0]'

  # exclusion_without_reason_rejected
  for f in empty missing blank; do
    cov "$C" "$PART" --exclusions "$FX/exclusions-$f-reason.json" --mode advise > "$T/x.json" 2>"$T/x.err"; rc=$?
    check "$E exclusion_without_reason_rejected ($f) exit" "$rc" "2"
    check "$E exclusion_without_reason_rejected ($f) message" "$(grep -c 'reason' "$T/x.err")" "1"
  done

  # wildcard_persona_exclusion
  cov "$C" "$PART" --exclusions "$FX/exclusions-wildcard.json" --mode block > "$T/w.json" 2>/dev/null; rc=$?
  check "$E wildcard_persona_exclusion still blocks on others" "$rc" "1"
  check "$E wildcard_persona_exclusion counts" "$(q "$T/w.json" "$COUNTS")" '[8,2,1,5]'
  check "$E wildcard_persona_exclusion excludes uncovered persona" "$(q "$T/w.json" '[r("GET /h/{slug}","admin")["state"],r("GET /h/{slug}","admin")["reason"]]')" '["excluded","public page, checked by the smoke profile"]'
  check "$E wildcard_persona_exclusion covered wins" "$(q "$T/w.json" '[r("GET /h/{slug}","participant")["state"],"reason" in r("GET /h/{slug}","participant")]')" '["covered",false]'

  # percent_rounding_one_decimal
  check "$E percent_rounding 2/8 -> 25" "$(q "$T/pb.json" 'c["percent"]')" "25"
  cov "$C" "$PART" --exclusions "$FX/exclusions-ok.json" --defer-channels --mode block > "$T/r.json" 2>/dev/null; rc=$?
  check "$E percent_rounding exit" "$rc" "1"
  check "$E percent_rounding counts" "$(q "$T/r.json" "$COUNTS")" '[8,2,4,2]'
  check "$E percent_rounding 2/4 -> 50 (excluded leave the denominator)" "$(q "$T/r.json" 'c["percent"]')" "50"
  check "$E percent_rounding arabic reason copied" "$(q "$T/r.json" 'r("GET /الأخبار","participant")["reason"]')" "صفحة الأخبار خارج نطاق هذا الإصدار"
  cov "$C" "$PART" --exclusions "$FX/exclusions-ok.json" --mode advise > "$T/r2.json"
  check "$E percent_rounding 2/6 -> 33.3" "$(q "$T/r2.json" 'c["percent"]')" "33.3"

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

  # sweep_rows_are_not_functional_coverage (I2) + non-GET / unreached declared surfaces + tab surfaces
  cat > "$T/c2.json" <<'J'
{"version":1,"adapter":"laravel","adapterOk":true,"jobs":[],"mails":[],"notifications":[],"warnings":[],
 "diffs":{"unreachable":[],"overreach":[],"crawlOnly":[]},
 "surfaces":[
  {"surfaceId":"GET /admin/hackathons","kind":"endpoint","pattern":"/admin/hackathons","sources":["adapter","crawl"],"reachedBy":["admin"],"allowed":["admin"],"forms":[]},
  {"surfaceId":"page:Admin/Hackathons/Show","kind":"page","pattern":"Admin/Hackathons/Show","sources":["adapter","crawl"],"reachedBy":["admin","participant"],"allowed":null,"forms":[]},
  {"surfaceId":"page:Admin/Hackathons/Show#tab:الفرق","kind":"tab","pattern":"Admin/Hackathons/Show","sources":["crawl"],"reachedBy":["admin"],"allowed":null,"forms":[]},
  {"surfaceId":"POST /admin/hackathons","kind":"endpoint","pattern":"/admin/hackathons","sources":["adapter"],"reachedBy":[],"allowed":null,"forms":[]},
  {"surfaceId":"DELETE /admin/hackathons/{hackathon}","kind":"endpoint","pattern":"/admin/hackathons/{hackathon}","sources":["adapter"],"reachedBy":[],"allowed":["admin"],"forms":[]},
  {"surfaceId":"GET /old","kind":"page","pattern":"/old","sources":["crawl"],"reachedBy":[],"allowed":null,"forms":[]},
  {"surfaceId":"GET /reports/{report}","kind":"endpoint","pattern":"/reports/{report}","sources":["adapter"],"reachedBy":[],"allowed":null,"forms":[]}]}
J
  cat > "$T/k2.json" <<'J'
[{"id":"load-clean-get-admin-hackathons-admin-11111111","title":"load-clean:GET /admin/hackathons:admin","kind":"load-clean","tags":["independent","read-only","sweep"],"surfaceId":"GET /admin/hackathons","persona":"admin","action":"open"},
 {"id":"C-LIST","kind":"happy-path","tags":["read-only"],"surfaceId":"page:Admin/Hackathons/Show","persona":"admin","action":"افتح هاكاثون الرياض للمياه"},
 {"id":"load-clean-page-show-participant-22222222","kind":"load-clean","tags":["independent","read-only","sweep"],"surfaceId":"page:Admin/Hackathons/Show","persona":"participant","action":"open"},
 {"id":"C-TEAMS","kind":"happy-path","tags":["read-only"],"surfaceId":"page:Admin/Hackathons/Show#tab:الفرق","persona":"admin","action":"افتح تبويب الفرق"},
 {"id":"deny-post-admin-hackathons-participant-33333333","kind":"deny","tags":["deny-write-deferred","probe-needed","sweep"],"surfaceId":"POST /admin/hackathons","persona":"participant","action":"send"}]
J
  cov "$T/c2.json" "$T/k2.json" --mode block > "$T/sw.json" 2> "$T/sw.err"; rc=$?
  check "$E sweep_only_pairs_block" "$rc" "1"
  check "$E sweep pair order (non-GET + unreached declared are * pairs, crawl-only unreached none, tab counted)" "$(q "$T/sw.json" '[[x["surfaceId"],x["personaId"],x["state"]] for x in c["rows"]]')" \
    '[["DELETE /admin/hackathons/{hackathon}","admin","uncovered"],["GET /admin/hackathons","admin","covered-sweep"],["GET /reports/{report}","*","uncovered"],["POST /admin/hackathons","*","covered-sweep"],["page:Admin/Hackathons/Show","admin","covered"],["page:Admin/Hackathons/Show","participant","covered-sweep"],["page:Admin/Hackathons/Show#tab:الفرق","admin","covered"]]'
  check "$E functional vs sweep counts (block)" "$(q "$T/sw.json" '[c["total"],c["covered"],c["functionalCovered"],c["sweepCovered"],c["uncovered"],c["percent"]]')" '[7,2,2,3,5,28.6]'
  check "$E sweep-only stated on stderr" "$(grep -c 'sweep-only pairs count as uncovered' "$T/sw.err")" "1"
  cov "$T/c2.json" "$T/k2.json" --mode advise > "$T/swa.json"; rc=$?
  check "$E sweep advise exit 0 and counted" "$rc$(q "$T/swa.json" '[c["covered"],c["functionalCovered"],c["sweepCovered"],c["uncovered"]]')" '0[5,2,3,2]'

  # scope_and_roles_filters (I3)
  cov "$T/c2.json" "$T/k2.json" --mode block --scope 'Show' > "$T/sc.json" 2>/dev/null
  check "$E --scope keeps matching surfaces only" "$(q "$T/sc.json" '[[x["surfaceId"],x["personaId"]] for x in c["rows"]]')" '[["page:Admin/Hackathons/Show","admin"],["page:Admin/Hackathons/Show","participant"],["page:Admin/Hackathons/Show#tab:الفرق","admin"]]'
  cov "$T/c2.json" "$T/k2.json" --mode block --scope '^page:Admin/Hackathons/Show$' --roles "$T/roles.json" > /dev/null 2>&1; check "$E --roles file missing exit 2" "$?" "2"
  printf '%s' '{"constitutionVersion":"v1","roles":[{"id":"admin","role":"admin","plane":"global"}],"overrides":[]}' > "$T/roles.json"
  cov "$T/c2.json" "$T/k2.json" --mode block --scope 'Show$|reports' --roles "$T/roles.json" > "$T/sr.json" 2>/dev/null; rc=$?
  check "$E --roles keeps spec roles and * pairs" "$(q "$T/sr.json" '[[x["surfaceId"],x["personaId"]] for x in c["rows"]]')" '[["GET /reports/{report}","*"],["page:Admin/Hackathons/Show","admin"]]'
  check "$E --scope + --roles gate on the filtered pairs" "$rc" "1"
  cov "$T/c2.json" "$T/k2.json" --mode block --scope '^page:' --roles "$T/roles.json" > /dev/null 2>&1; rc=$?
  check "$E scoped gate passes when the scope is covered" "$rc" "0"
  printf '%s' '[{"id":"participant"}]' > "$T/roles-arr.json"
  cov "$T/c2.json" "$T/k2.json" --mode advise --roles "$T/roles-arr.json" > "$T/ra.json"
  check "$E --roles accepts a persona array" "$(q "$T/ra.json" 'sorted(set(x["personaId"] for x in c["rows"]))')" '["*","participant"]'
  cov "$T/c2.json" "$T/k2.json" --mode advise --scope '([' > /dev/null 2>&1; check "$E invalid --scope regex exit 2" "$?" "2"
  printf '%s' '{"nope":1}' > "$T/roles-bad.json"
  cov "$T/c2.json" "$T/k2.json" --mode advise --roles "$T/roles-bad.json" > /dev/null 2>&1; check "$E roles file of unknown shape exit 2" "$?" "2"

  # glob_exclusions (I3): * and ? in the exclusion surfaceId
  printf '%s' '[{"surfaceId":"* /admin/hackathons*","personaId":"*","reason":"إدارة الهاكاثونات تغطيها رحلة لاحقة"},{"surfaceId":"GET /reports/{report?}","personaId":"*","reason":"not a glob hit: literal ? needs one char"},{"surfaceId":"GET /reports/{repor?}","personaId":"*","reason":"reports are out of scope"}]' > "$T/gx.json"
  cov "$T/c2.json" "$T/k2.json" --mode block --exclusions "$T/gx.json" > "$T/gx.out" 2>/dev/null
  check "$E glob_exclusions" "$(q "$T/gx.out" '[[x["surfaceId"],x["state"],x.get("reason")] for x in c["rows"] if x["state"]=="excluded"]')" \
    '[["DELETE /admin/hackathons/{hackathon}","excluded","إدارة الهاكاثونات تغطيها رحلة لاحقة"],["GET /admin/hackathons","excluded","إدارة الهاكاثونات تغطيها رحلة لاحقة"],["GET /reports/{report}","excluded","reports are out of scope"],["POST /admin/hackathons","excluded","إدارة الهاكاثونات تغطيها رحلة لاحقة"]]'
  check "$E glob exclusion never overrides functional coverage" "$(q "$T/gx.out" 'r("page:Admin/Hackathons/Show","admin")["state"]')" "covered"
  printf '%s' '[{"surfaceId":"page:Admin/Hackathons/Show#tab:الفرق","personaId":"admin","reason":"exact ids still match"},{"surfaceId":"page:Admin/(Hackathons)/Show","personaId":"*","reason":"regex characters are literal"}]' > "$T/gl.json"
  cov "$T/c2.json" "$T/k2.json" --mode advise --exclusions "$T/gl.json" > "$T/gl.out"
  check "$E exclusion regex characters are literal" "$(q "$T/gl.out" 'r("page:Admin/Hackathons/Show","participant")["state"]')" "covered-sweep"
  cp "$T/c2.json" "$SHARED/c2.json"; cp "$T/k2.json" "$SHARED/k2.json"; cp "$T/gx.json" "$SHARED/gx.json"; cp "$T/roles.json" "$SHARED/roles.json"

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
    case "$cen" in /*) ;; *) cen="$FX/$cen"; chk="$FX/$chk" ;; esac
    QA_ENGINE=jq bash "$SH" "$cen" "$chk" $args > "$X/j$n.json" 2>/dev/null
    # shellcheck disable=SC2086
    QA_ENGINE=python3 bash "$SH" "$cen" "$chk" $args > "$X/p$n.json" 2>/dev/null
    check "parity #$n produced output" "$([ -s "$X/j$n.json" ] && echo yes || echo no)" "yes"
    check "parity #$n (${chk##*/} $args) byte-identical" "$(cmp -s "$X/j$n.json" "$X/p$n.json" && echo same || echo diff)" "same"
  done <<EOF
census.json|checklist-all.json|--mode block
census.json|checklist-partial.json|--mode advise
census.json|checklist-partial.json|--mode advise --defer-channels --exclusions $FX/exclusions-ok.json
census.json|checklist-partial.json|--mode block --exclusions $FX/exclusions-wildcard.json
census-adapter-failed.json|checklist-all.json|--mode block --accept-crawl-only
census.json|checklist-unscoped.json|--mode block
census.json|checklist-unscoped.json|--mode advise
census-empty.json|checklist-all.json|--mode block
$SHARED/c2.json|$SHARED/k2.json|--mode block --exclusions $SHARED/gx.json
$SHARED/c2.json|$SHARED/k2.json|--mode advise --scope Show$ --roles $SHARED/roles.json
census.json|checklist-all.json|--mode block --require-visual-ux
census.json|checklist-partial.json|--mode advise --require-visual-ux
census.json|checklist-partial.json|--mode block --exclusions $FX/exclusions-wildcard.json --require-visual-ux
EOF
fi
echo "coverage-gate: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
