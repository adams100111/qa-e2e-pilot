#!/usr/bin/env bash
# Dual-engine tests for scripts/census.sh — merges a stack adapter's surfaces with the per-role
# crawl output into census.json and computes diffs (unreachable, overreach, crawlOnly).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../scripts/census.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: census-merge: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <file> <python expression over `c`> — prints the expression's value (json for lists/dicts).
q(){ python3 -c '
import json,sys
c=json.load(open(sys.argv[1], encoding="utf-8"))
def s(i): return next((x for x in c["surfaces"] if x["surfaceId"]==i), None)
v=eval(sys.argv[2])
print(v if isinstance(v,(str,int,bool)) or v is None else json.dumps(v, ensure_ascii=False, separators=(",",":")))
' "$1" "$2"; }
PATHS='GET /admin/hackathons/{hackathon}/paths/{path}'

run_engine() {
  local E="$1" T rc; T="$(mktemp -d)"; TMPDIRS+=("$T")

  # merge_maps_params
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/adapter.json" --crawl "$FX/crawl" --out "$T/c.json"; rc=$?
  check "$E build exit 0" "$rc" "0"
  check "$E merge_maps_params two-param route reachedBy" "$(q "$T/c.json" "s('$PATHS')['reachedBy']")" '["admin","participant"]'
  check "$E merge_maps_params sources adapter+crawl" "$(q "$T/c.json" "s('$PATHS')['sources']")" '["adapter","crawl"]'
  check "$E merge_maps_params literal beats param (create)" "$(q "$T/c.json" "s('GET /admin/hackathons/create')['reachedBy']")" '["admin"]'
  check "$E merge_maps_params forms deduped by formId" "$(q "$T/c.json" "[f['formId'] for f in s('GET /admin/hackathons/create')['forms']]")" '["hackathon-create"]'
  check "$E merge_maps_params create not mapped to {hackathon}" "$(q "$T/c.json" "len(s('GET /admin/hackathons/{hackathon}')['forms'])")" "0"
  check "$E merge_maps_params denied (403) visit is not reached" "$(q "$T/c.json" "s('GET /admin/hackathons/{hackathon}')['reachedBy']")" '["admin"]'
  check "$E merge_maps_params routeMatch reaches page surface" "$(q "$T/c.json" "s('page:Admin/Hackathons/Show')['reachedBy']")" '["admin"]'
  check "$E merge_maps_params encoded + raw Arabic slug both map" "$(q "$T/c.json" "s('GET /h/{slug}')['reachedBy']")" '["participant"]'
  check "$E merge_maps_params allowed null without --access" "$(q "$T/c.json" "s('$PATHS')['allowed']")" "None"
  check "$E merge_maps_params channels copied" "$(q "$T/c.json" "[len(c['jobs']),len(c['mails']),len(c['notifications']),c['version'],c['adapter'],c['adapterOk']]")" '[1,1,1,1,"laravel",true]'
  check "$E merge_maps_params adapter warnings copied" "$(q "$T/c.json" "c['warnings']")" '["skipped vendor route: horizon"]'

  # merge_maps_params: optional trailing param may be absent; root path; extra segments never match
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/optional/adapter.json" --crawl "$FX/optional/crawl" --out "$T/o.json"
  check "$E merge_maps_params optional param absent matches" "$(q "$T/o.json" "s('GET /reports/{year?}')['reachedBy']")" '["viewer"]'
  check "$E merge_maps_params root path matches" "$(q "$T/o.json" "s('GET /')['reachedBy']")" '["viewer"]'
  check "$E merge_maps_params extra segments are crawl-only" "$(q "$T/o.json" "c['diffs']['crawlOnly']")" '["GET /reports/2026/q1"]'

  # unreachable_detected
  check "$E unreachable_detected (GET + page only, never POST)" "$(q "$T/c.json" "c['diffs']['unreachable']")" '["GET /admin/reports","page:Orphan"]'

  # overreach_detected
  check "$E overreach empty without --access" "$(q "$T/c.json" "c['diffs']['overreach']")" '[]'
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/adapter.json" --crawl "$FX/crawl" --access "$FX/access.json" --out "$T/a.json"; rc=$?
  check "$E build with --access exit 0" "$rc" "0"
  check "$E overreach_detected" "$(q "$T/a.json" "c['diffs']['overreach']")" "[{\"personaId\":\"participant\",\"surfaceId\":\"$PATHS\"}]"
  check "$E overreach allowed copied from access" "$(q "$T/a.json" "s('$PATHS')['allowed']")" '["admin"]'

  # crawl_only_listed
  check "$E crawl_only_listed" "$(q "$T/c.json" "c['diffs']['crawlOnly']")" '["GET /legacy/old","GET /الأخبار"]'
  check "$E crawl_only surface sources" "$(q "$T/c.json" "s('GET /legacy/old')['sources']")" '["crawl"]'

  # adapter_failure_degrades_with_warning
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/adapter-failed.json" --crawl "$FX/crawl" --out "$T/f.json"; rc=$?
  check "$E adapter_failure exit 0" "$rc" "0"
  check "$E adapter_failure warning carries error" "$(q "$T/f.json" "any('php: command not found' in w for w in c['warnings'])")" "True"
  check "$E adapter_failure adapterOk false" "$(q "$T/f.json" "c['adapterOk']")" "False"
  check "$E adapter_failure census still built from crawl" "$(q "$T/f.json" "len(c['surfaces'])>0 and len(c['diffs']['crawlOnly'])==len(c['surfaces'])")" "True"

  # arabic: raw (not \u-escaped) UTF-8 in output
  check "$E arabic raw utf-8 in output" "$(grep -c 'تسجيل-الفريق' "$T/c.json")" "1"

  # sampleUrls (contract §1, I6): first reached path+query per persona; fragment dropped, query kept
  check "$E sample_urls two personas" "$(q "$T/c.json" "s('$PATHS')['sampleUrls']")" '{"admin":"/admin/hackathons/12/paths/7?tab=teams","participant":"/admin/hackathons/13/paths/2"}'
  check "$E sample_urls skip unreached (403) visits" "$(q "$T/c.json" "s('GET /admin/hackathons/{hackathon}')['sampleUrls']")" '{"admin":"/admin/hackathons/12"}'
  check "$E sample_urls empty when nobody reached" "$(q "$T/c.json" "s('GET /admin/reports')['sampleUrls']")" '{}'
  check "$E sample_urls crawl-only arabic path kept raw" "$(q "$T/c.json" "s('GET /الأخبار')['sampleUrls']")" '{"participant":"/الأخبار"}'

  # tab/dialog/sheet surfaces (contract §1, I9)
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/surfaces/adapter.json" --crawl "$FX/surfaces/crawl" --out "$T/s.json"; rc=$?
  check "$E subsurfaces build exit 0" "$rc" "0"
  check "$E subsurfaces ids" "$(q "$T/s.json" "[x['surfaceId'] for x in c['surfaces']]")" \
    '["GET /admin/hackathons/{hackathon}","GET /legacy/board","GET /legacy/board#sheet:filters","page:Admin/Hackathons/Show","page:Admin/Hackathons/Show#dialog:تعديل-الهاكاثون","page:Admin/Hackathons/Show#tab:team-members"]'
  check "$E subsurface tab kind+pattern+sources" "$(q "$T/s.json" "[s('page:Admin/Hackathons/Show#tab:team-members')[k] for k in ('kind','pattern','sources')]")" '["tab","Admin/Hackathons/Show",["crawl"]]'
  check "$E subsurface tab reachedBy (403 not reached)" "$(q "$T/s.json" "s('page:Admin/Hackathons/Show#tab:team-members')['reachedBy']")" '["admin"]'
  check "$E subsurface sampleUrls = parent's" "$(q "$T/s.json" "s('page:Admin/Hackathons/Show#tab:team-members')['sampleUrls']==s('page:Admin/Hackathons/Show')['sampleUrls']")" "True"
  check "$E parent sampleUrls" "$(q "$T/s.json" "s('page:Admin/Hackathons/Show')['sampleUrls']")" '{"admin":"/admin/hackathons/12?lang=ar","judge":"/admin/hackathons/14"}'
  check "$E dialog forms belong to the dialog surface" "$(q "$T/s.json" "[[f['formId'] for f in s('page:Admin/Hackathons/Show#dialog:تعديل-الهاكاثون')['forms']], len(s('page:Admin/Hackathons/Show')['forms'])]")" '[["hackathon-edit"],0]'
  check "$E tab visit without subKey counts as its page" "$(q "$T/s.json" "len([x for x in c['surfaces'] if x['surfaceId'].endswith('#tab:')])")" "0"
  check "$E sub of a crawl-only parent is crawl-only" "$(q "$T/s.json" "c['diffs']['crawlOnly']")" '["GET /legacy/board","GET /legacy/board#sheet:filters"]'
  check "$E subsurfaces never unreachable" "$(q "$T/s.json" "c['diffs']['unreachable']")" '[]'

  # forms only from visits that reached the surface (I12)
  check "$E forms of a 403 visit are dropped" "$(q "$T/s.json" "[f['formId'] for x in c['surfaces'] for f in x['forms']]")" '["hackathon-edit"]'

  # catch-all params (Next.js [...x] -> {x*}, [[...x]] -> {x*?})
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/catchall/adapter.json" --crawl "$FX/catchall/crawl" --out "$T/ca.json"; rc=$?
  check "$E catchall exit 0" "$rc" "0"
  check "$E catchall {x*} matches many segments" "$(q "$T/ca.json" "s('GET /docs/{slug*}')['sampleUrls']")" '{"viewer":"/docs/guides/setup/linux"}'
  check "$E catchall literal beats {x*}" "$(q "$T/ca.json" "s('GET /docs/intro')['reachedBy']")" '["viewer"]'
  check "$E catchall {x*} needs one segment" "$(q "$T/ca.json" "c['diffs']['crawlOnly']")" '["GET /docs"]'
  check "$E catchall {x*?} matches zero or many" "$(q "$T/ca.json" "s('GET /shop/{cat*?}')['sampleUrls']")" '{"viewer":"/shop"}'

  # --access is read with --slurpfile: a >1 MB access file still works (I12)
  python3 -c '
import json,sys
s={"GET /h/{slug}":{"allowed":["admin","participant"],"source":"human","confirmed":True}}
for i in range(12000): s["GET /filler/%05d" % i]={"allowed":["admin"],"source":"adapter","confirmed":False,"hints":["can:filler.view"]}
json.dump({"version":1,"surfaces":s},open(sys.argv[1],"w"))' "$T/big-access.json"
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/adapter.json" --crawl "$FX/crawl" --access "$T/big-access.json" --out "$T/big.json"; rc=$?
  check "$E big access file exit 0" "$rc" "0"
  check "$E big access allowed copied" "$(q "$T/big.json" "s('GET /h/{slug}')['allowed']")" '["admin","participant"]'

  # argument errors
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/adapter.json" --out "$T/x.json" >/dev/null 2>&1; check "$E missing --crawl dies" "$?" "1"
  QA_ENGINE=$E bash "$SH" build --adapter "$FX/nope.json" --crawl "$FX/crawl" --out "$T/x.json" >/dev/null 2>&1; check "$E missing adapter file dies" "$?" "1"
  printf 'not json' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" build --adapter "$T/bad.json" --crawl "$FX/crawl" --out "$T/x.json" >/dev/null 2>&1; check "$E malformed adapter dies" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  # arabic_urls_parity — Arabic paths, slugs, form ids and field names: byte-identical across engines
  QA_ENGINE=jq bash "$SH" build --adapter "$FX/adapter.json" --crawl "$FX/crawl" --access "$FX/access.json" --out "$X/j.json"
  QA_ENGINE=python3 bash "$SH" build --adapter "$FX/adapter.json" --crawl "$FX/crawl" --access "$FX/access.json" --out "$X/p.json"
  check "arabic_urls_parity census byte-identical" "$(cmp -s "$X/j.json" "$X/p.json" && echo same || echo diff)" "same"
  QA_ENGINE=jq bash "$SH" build --adapter "$FX/adapter-failed.json" --crawl "$FX/crawl" --out "$X/jf.json"
  QA_ENGINE=python3 bash "$SH" build --adapter "$FX/adapter-failed.json" --crawl "$FX/crawl" --out "$X/pf.json"
  for F in surfaces catchall; do
    QA_ENGINE=jq bash "$SH" build --adapter "$FX/$F/adapter.json" --crawl "$FX/$F/crawl" --out "$X/j-$F.json"
    QA_ENGINE=python3 bash "$SH" build --adapter "$FX/$F/adapter.json" --crawl "$FX/$F/crawl" --out "$X/p-$F.json"
    check "cross-engine $F census byte-identical" "$(cmp -s "$X/j-$F.json" "$X/p-$F.json" && echo same || echo diff)" "same"
  done
  check "cross-engine adapter-failure census byte-identical" "$(cmp -s "$X/jf.json" "$X/pf.json" && echo same || echo diff)" "same"
fi
echo "census-merge: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
