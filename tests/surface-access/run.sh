#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/surface-access.sh — derives who should reach each census
# surface (permission hints matched against persona roles / permissions + crawl reachedBy), renders the
# one-pass confirmation table, applies the human's decisions (confirmed:true, source:"human") or the
# autonomous assumption (apply --assume), and builds the persona input for generation (personas).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/surface-access.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: surface-access: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <file> <python expression over `a`> — `e(sid)` is the access entry for a surface id.
q(){ python3 -c '
import json,sys
a=json.load(open(sys.argv[1], encoding="utf-8"))
def e(i): return a["surfaces"].get(i)
v=eval(sys.argv[2])
print(v if isinstance(v,(str,int,bool)) or v is None else json.dumps(v, ensure_ascii=False, separators=(",",":")))
' "$1" "$2"; }
PATHS='GET /admin/hackathons/{hackathon}/paths/{path}'
# Test-only cross-script wiring: the engine census merger and its fixtures, plus the qa-kit generator.
CENSUS="$DIR/../../scripts/census.sh"
CM="$DIR/../census-merge/fixtures"
GEN="$DIR/../../qa-kit/scripts/generate-ship-criteria.sh"

run_engine() {
  local E="$1" T rc; T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf '%s' '[]' > "$T/m0.json"; printf '%s' '{}' > "$T/cfg0.json"

  # derive_from_hints_and_crawl
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$FX/personas.json" --adapter "$FX/adapter.json" > "$T/a.json"; rc=$?
  check "$E derive exit 0" "$rc" "0"
  check "$E derive version" "$(q "$T/a.json" "a['version']")" "1"
  check "$E derive_from_hints_and_crawl can: hint via permissions only (crawl reach is not permission)" "$(q "$T/a.json" "e('$PATHS')['allowed']")" '["admin"]'
  check "$E derive records hint evidence" "$(q "$T/a.json" "[e('$PATHS')['hintMatched'],e('GET /account')['hintMatched'],e('GET /h/{slug}')['hintMatched']]")" '[["admin"],[],[]]'
  # crawl_reached_without_hint_not_allowed
  check "$E crawl_reached_without_hint_not_allowed" "$(q "$T/a.json" "[e('$PATHS')['allowed'],e('$PATHS')['reachedWithoutEvidence']]")" '[["admin"],["participant"]]'
  check "$E reached persona of a matching hint is not listed" "$(q "$T/a.json" "e('GET /organizer/dashboard')['reachedWithoutEvidence']")" '[]'
  check "$E bare guard hints (auth/verified/api) match no persona" "$(q "$T/a.json" "[e('GET /account')['allowed'],e('GET /account')['reachedWithoutEvidence'],e('GET /account')['source']]")" '[[],["participant"],"adapter"]'
  check "$E bare hint is a role name" "$(q "$T/a.json" "e('GET /admin/settings')['allowed']")" '["admin"]'
  check "$E derive hinted surface source adapter" "$(q "$T/a.json" "e('$PATHS')['source']")" "adapter"
  check "$E derive unconfirmed" "$(q "$T/a.json" "all(not x['confirmed'] for x in a['surfaces'].values())")" "True"
  check "$E derive role: hint with alternatives" "$(q "$T/a.json" "e('GET /organizer/dashboard')['allowed']")" '["admin","organizer"]'
  check "$E derive census hints win over adapter" "$(q "$T/a.json" "[e('GET /admin/reports')['allowed'],e('GET /admin/reports')['hints']]")" '[["admin"],["role:admin"]]'
  check "$E derive non-GET surface from hint" "$(q "$T/a.json" "e('POST /admin/hackathons')['allowed']")" '["admin"]'
  check "$E derive no hint -> crawl only" "$(q "$T/a.json" "[e('GET /h/{slug}')['allowed'],e('GET /h/{slug}')['source']]")" '[["participant"],"crawl"]'
  # no_hint_surface_marked_crawl
  check "$E no_hint_surface_marked_crawl (reach listed as without evidence)" "$(q "$T/a.json" "[e('GET /h/{slug}')['source'],e('GET /h/{slug}')['reachedWithoutEvidence']]")" '["crawl",["participant"]]'
  check "$E no hint surface never labelled adapter" "$(q "$T/a.json" "sorted(k for k,x in a['surfaces'].items() if not x['hints'] and x['source']!='crawl')")" '[]'
  check "$E derive arabic crawl-only surface" "$(q "$T/a.json" "e('GET /الأخبار')['allowed']")" '["participant"]'
  check "$E derive nothing known -> empty allowed" "$(q "$T/a.json" "e('page:Orphan')['allowed']")" '[]'
  check "$E derive covers every census surface" "$(q "$T/a.json" "len(a['surfaces'])")" "9"
  check "$E derive arabic raw utf-8" "$(grep -c 'الأخبار' "$T/a.json")" "1"
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$FX/personas.json" > "$T/n.json"; rc=$?
  check "$E derive without adapter exit 0" "$rc" "0"
  check "$E derive without adapter: crawl reach only" "$(q "$T/n.json" "[e('$PATHS')['allowed'],e('$PATHS')['source'],e('$PATHS')['reachedWithoutEvidence']]")" '[["admin","participant"],"crawl",["admin","participant"]]'
  check "$E derive without adapter: census hints still read" "$(q "$T/n.json" "e('GET /admin/reports')['allowed']")" '["admin"]'

  # confirm_apply_marks_human
  QA_ENGINE=$E bash "$SH" confirm-table "$T/a.json" > "$T/t.md"; rc=$?
  check "$E confirm-table exit 0" "$rc" "0"
  check "$E confirm-table groups by hint" "$(grep -c '^## can:hackathons.view$' "$T/t.md")" "1"
  check "$E confirm-table no-hint group last" "$(grep '^## ' "$T/t.md" | tail -1)" "## (no permission hint)"
  check "$E confirm-table row" "$(grep -cF "| \`$PATHS\` | admin | adapter | no |" "$T/t.md")" "1"
  # confirm_table_lists_reached_without_evidence
  check "$E confirm_table_lists_reached_without_evidence first section" "$(grep '^## ' "$T/t.md" | head -1)" "## Reached without permission evidence — confirm or deny"
  check "$E rwe row: no matching hint" "$(grep -cF "| \`$PATHS\` | participant | no matching hint |" "$T/t.md")" "1"
  check "$E rwe row: no hints on surface" "$(grep -cF '| `GET /h/{slug}` | participant | no hints on surface |' "$T/t.md")" "1"
  check "$E rwe row count" "$(grep -cE ' \| (no matching hint|no hints on surface) \|$' "$T/t.md")" "4"
  check "$E confirm-table empty allowed shown" "$(grep -cF '| `page:Orphan` | (none) | crawl | no |' "$T/t.md")" "1"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$FX/decisions.json" > "$T/h.json"; rc=$?
  check "$E apply exit 0" "$rc" "0"
  check "$E confirm_apply_marks_human by hint" "$(q "$T/h.json" "[e('$PATHS')['allowed'],e('$PATHS')['source'],e('$PATHS')['confirmed'],e('$PATHS')['reachedWithoutEvidence']]")" '[["admin"],"human",true,[]]'
  # apply_deny_removes_pair (+ allow moves a pair into allowed)
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$FX/decisions-pairs.json" > "$T/pr.json"; rc=$?
  check "$E apply pairs exit 0" "$rc" "0"
  check "$E apply_deny_removes_pair (hinted)" "$(q "$T/pr.json" "[e('$PATHS')['allowed'],e('$PATHS')['reachedWithoutEvidence'],e('$PATHS')['source'],e('$PATHS')['confirmed']]")" '[["admin"],[],"human",true]'
  check "$E apply_deny_removes_pair (no-hint surface drops from allowed)" "$(q "$T/pr.json" "[e('GET /h/{slug}')['allowed'],e('GET /h/{slug}')['reachedWithoutEvidence'],e('GET /h/{slug}')['source']]")" '[[],[],"human"]'
  check "$E apply allow pair moves into allowed" "$(q "$T/pr.json" "[e('GET /account')['allowed'],e('GET /account')['reachedWithoutEvidence'],e('GET /account')['source'],e('GET /account')['confirmed']]")" '[["participant"],[],"human",true]'
  check "$E apply pairs leave other rwe pairs pending" "$(q "$T/pr.json" "[e('GET /الأخبار')['reachedWithoutEvidence'],e('GET /الأخبار')['confirmed']]")" '[["participant"],false]'
  printf '%s' '{"pairs":[{"surfaceId":"GET /admin/reports","persona":"participant","decision":"allow"}]}' > "$T/bad4.json"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$T/bad4.json" >/dev/null 2>&1; check "$E apply pair not reached-without-evidence dies" "$?" "1"
  printf '%s' '{"bySurface":{"GET /h/{slug}":["admin"]},"pairs":[{"surfaceId":"GET /h/{slug}","persona":"participant","decision":"deny"}]}' > "$T/bad5.json"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$T/bad5.json" >/dev/null 2>&1; check "$E apply pair conflicting with surface decision dies" "$?" "1"
  printf '%s' '{"pairs":[{"surfaceId":"GET /h/{slug}","persona":"participant","decision":"maybe"}]}' > "$T/bad6.json"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$T/bad6.json" >/dev/null 2>&1; check "$E apply bad pair decision dies" "$?" "1"

  # overreach integration: derive -> census.sh build --access -> diffs.overreach non-empty
  QA_ENGINE=$E bash "$CENSUS" build --adapter "$CM/adapter.json" --crawl "$CM/crawl" --out "$T/c0.json"
  QA_ENGINE=$E bash "$SH" derive "$T/c0.json" "$FX/personas.json" --adapter "$CM/adapter.json" > "$T/ca.json"
  QA_ENGINE=$E bash "$CENSUS" build --adapter "$CM/adapter.json" --crawl "$CM/crawl" --access "$T/ca.json" --out "$T/c1.json"; rc=$?
  check "$E overreach integration build exit 0" "$rc" "0"
  check "$E overreach integration: participant overreach reported" "$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1],encoding="utf-8"))["diffs"]["overreach"],separators=(",",":")))' "$T/c1.json")" "[{\"personaId\":\"participant\",\"surfaceId\":\"$PATHS\"}]"

  # generator_emits_deny_for_unconfirmed_overreach (derived access fed straight to the generator)
  printf '%s' '[]' > "$T/m.json"; printf '%s' '{}' > "$T/cfg.json"
  QA_ENGINE=$E bash "$GEN" --census "$T/c1.json" --access "$T/ca.json" --matrix "$T/m.json" --personas "$FX/personas.json" --config "$T/cfg.json" > "$T/rows.json" 2> "$T/rows.err"; rc=$?
  check "$E generator exit 0" "$rc" "0"
  check "$E generator_emits_deny_for_unconfirmed_overreach" "$(python3 -c '
import json,sys
r=next((x for x in json.load(open(sys.argv[1],encoding="utf-8")) if x["title"]=="deny:"+sys.argv[2]+":participant"),None)
print(None if r is None else json.dumps(r["tags"]))' "$T/rows.json" "$PATHS")" '["independent", "needs-confirmation", "probe-needed", "read-only", "sweep"]'
  check "$E generator reports unconfirmed entries on stderr" "$(grep -c 'unconfirmed surface-access entries' "$T/rows.err")" "1"
  check "$E apply by surface (sorted, deduped)" "$(q "$T/h.json" "[e('GET /h/{slug}')['allowed'],e('GET /h/{slug}')['source'],e('GET /h/{slug}')['confirmed']]")" '[["admin","participant"],"human",true]'
  check "$E apply arabic surface" "$(q "$T/h.json" "e('GET /الأخبار')['allowed']")" '["organizer","participant"]'
  check "$E apply leaves undecided surfaces" "$(q "$T/h.json" "[e('page:Orphan')['source'],e('page:Orphan')['confirmed']]")" '["crawl",false]'
  printf '%s' '{"bySurface":{"GET /nope":["admin"]}}' > "$T/bad1.json"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$T/bad1.json" >/dev/null 2>&1; check "$E apply unknown surface dies" "$?" "1"
  printf '%s' '{"byHint":{"can:nope":["admin"]}}' > "$T/bad2.json"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$T/bad2.json" >/dev/null 2>&1; check "$E apply unknown hint group dies" "$?" "1"
  printf '%s' '{"bySurface":{"GET /h/{slug}":"admin"}}' > "$T/bad3.json"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$T/bad3.json" >/dev/null 2>&1; check "$E apply non-array decision dies" "$?" "1"

  # permission_matching (contract §2): exact, "*" and "prefix.*"; personas without permissions never match
  printf '%s' '{"roles":[{"id":"admin","role":"admin","plane":"global","permissions":["*"]},{"id":"organizer","role":"organizer","plane":"global","permissions":["hackathons.*"]},{"id":"viewer","role":"viewer","plane":"global","permissions":["reports.view","hackathons"]},{"id":"participant","role":"participant","plane":"contextual"}]}' > "$T/pp.json"
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$T/pp.json" --adapter "$FX/adapter.json" > "$T/pw.json"; rc=$?
  check "$E derive accepts {roles:[...]}" "$rc" "0"
  check "$E permission wildcard prefix.* and *" "$(q "$T/pw.json" "[e('$PATHS')['allowed'],e('POST /admin/hackathons')['allowed']]")" '[["admin","organizer"],["admin","organizer"]]'
  check "$E permission exact; a bare prefix is not a wildcard" "$(q "$T/pw.json" "e('GET /admin/reports')['allowed']")" '["admin"]'
  check "$E persona without permissions: reach goes to reachedWithoutEvidence" "$(q "$T/pw.json" "[e('$PATHS')['reachedWithoutEvidence'],e('$PATHS')['hintMatched']]")" '[["participant"],["admin","organizer"]]'

  # apply_assume (C2): autonomous setup accepts derived allowed, decides nothing, denies nothing
  QA_ENGINE=$E bash "$SH" apply --assume "$T/a.json" > "$T/as.json"; rc=$?
  check "$E apply --assume exit 0" "$rc" "0"
  check "$E apply --assume marks every derived entry" "$(q "$T/as.json" "sorted(set(x.get('assumption') for x in a['surfaces'].values()))")" '[true]'
  check "$E apply --assume keeps allowed, pairs and confirmed" "$(q "$T/as.json" "[e('GET /h/{slug}')['allowed'],e('GET /h/{slug}')['reachedWithoutEvidence'],e('GET /h/{slug}')['confirmed'],e('GET /h/{slug}')['source']]")" '[["participant"],["participant"],false,"crawl"]'
  check "$E apply --assume never confirms" "$(q "$T/as.json" "any(x['confirmed'] for x in a['surfaces'].values())")" "False"
  QA_ENGINE=$E bash "$SH" apply --assume "$T/h.json" > "$T/ash.json"
  check "$E apply --assume leaves human decisions alone" "$(q "$T/ash.json" "['assumption' in e('$PATHS'), e('$PATHS')['confirmed'], e('page:Orphan')['assumption']]")" '[false,true,true]'
  QA_ENGINE=$E bash "$SH" confirm-table "$T/as.json" > "$T/ast.md"
  check "$E confirm-table shows assumed" "$(grep -cF '| `GET /h/{slug}` | participant | crawl | assumed |' "$T/ast.md")" "1"
  # no false deny rows from an autonomous setup (C2 regression): only hinted surfaces with a matched hint deny
  QA_ENGINE=$E bash "$GEN" --census "$FX/census.json" --access "$T/as.json" --matrix "$T/m0.json" --personas "$FX/personas.json" --config "$T/cfg0.json" > "$T/asr.json" 2> "$T/asr.err"; rc=$?
  check "$E generator on assumed access exit 0" "$rc" "0"
  check "$E autonomous_setup_no_false_deny_rows" "$(python3 -c '
import json,sys
rows=json.load(open(sys.argv[1],encoding="utf-8"))
print(json.dumps(sorted(set(x["surfaceId"] for x in rows if x["kind"]=="deny")),ensure_ascii=False,separators=(",",":")))' "$T/asr.json")" \
    "[\"$PATHS\",\"GET /admin/reports\",\"GET /admin/settings\",\"GET /organizer/dashboard\",\"POST /admin/hackathons\"]"
  check "$E generator reports assumed entries" "$(grep -c 'surface-access entries are assumptions (autonomousSetup)' "$T/asr.err")" "1"
  printf '%s' '{"pairs":[{"surfaceId":"GET /h/{slug}","persona":"participant","decision":"allow"}],"bySurface":{"GET /admin/reports":["admin","organizer"]}}' > "$T/ad.json"
  QA_ENGINE=$E bash "$SH" apply --assume "$T/a.json" "$T/ad.json" > "$T/asd.json"; rc=$?
  check "$E apply --assume with decisions exit 0" "$rc" "0"
  check "$E apply --assume allow pair" "$(q "$T/asd.json" "[e('GET /h/{slug}')['allowed'],e('GET /h/{slug}')['reachedWithoutEvidence'],e('GET /h/{slug}')['assumption'],e('GET /h/{slug}')['confirmed'],e('GET /h/{slug}')['source']]")" '[["participant"],[],true,false,"crawl"]'
  check "$E apply --assume whole decision only adds" "$(q "$T/asd.json" "[e('GET /admin/reports')['allowed'],e('GET /admin/reports')['assumption'],e('GET /admin/reports')['confirmed']]")" '[["admin","organizer"],true,false]'
  check "$E apply --assume leaves undecided entries unmarked" "$(q "$T/asd.json" "'assumption' in e('page:Orphan')")" "False"
  printf '%s' '{"pairs":[{"surfaceId":"GET /h/{slug}","persona":"participant","decision":"deny"}]}' > "$T/adn.json"
  QA_ENGINE=$E bash "$SH" apply --assume "$T/a.json" "$T/adn.json" >/dev/null 2>&1; check "$E apply --assume deny pair dies" "$?" "1"
  printf '%s' '{"bySurface":{"GET /organizer/dashboard":["organizer"]}}' > "$T/adw.json"
  QA_ENGINE=$E bash "$SH" apply --assume "$T/a.json" "$T/adw.json" >/dev/null 2>&1; check "$E apply --assume whole decision dropping a persona dies" "$?" "1"
  QA_ENGINE=$E bash "$SH" apply "$T/asd.json" "$FX/decisions.json" > "$T/hh.json"
  check "$E human apply clears the assumption" "$(q "$T/hh.json" "['assumption' in e('GET /h/{slug}'), e('GET /h/{slug}')['confirmed']]")" '[false,true]'
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" >/dev/null 2>&1; check "$E apply without --assume needs decisions" "$?" "1"

  # personas_for_generation (I1): spec-roles + constitution personas -> permissions carried, credentials dropped
  printf '%s' '{"constitutionVersion":"v1","roles":[{"id":"participant","role":"participant","plane":"contextual"},{"id":"admin","role":"admin","plane":"global"},{"id":"auditor","role":"auditor","plane":"global"}],"overrides":[]}' > "$T/sr.json"
  printf '%s' '{"baseUrl":"https://x.test","personas":[{"id":"admin","role":"admin","plane":"global","auth":{"password":"s3cret"},"permissions":["hackathons.*"],"roles":["admin","super"]},{"id":"participant","role":"participant","plane":"contextual","auth":"seeded"}]}' > "$T/cfgp.json"
  QA_ENGINE=$E bash "$SH" personas "$T/sr.json" "$T/cfgp.json" > "$T/pg.json" 2> "$T/pg.err"; rc=$?
  check "$E personas exit 0" "$rc" "0"
  check "$E personas_for_generation output" "$(cat "$T/pg.json")" '{"personas":[{"id":"admin","permissions":["hackathons.*"],"plane":"global","role":"admin","roles":["admin","super"]},{"id":"auditor","plane":"global","role":"auditor"},{"id":"participant","plane":"contextual","role":"participant"}]}'
  check "$E personas never copies credentials" "$(grep -c 's3cret\|seeded\|auth' "$T/pg.json")" "0"
  check "$E personas warns about a role missing from the constitution" "$(grep -c 'no constitution persona (no roles/permissions copied): auditor' "$T/pg.err")" "1"
  check "$E personas counts roles without permissions" "$(grep -c '2 personas carry no permissions' "$T/pg.err")" "1"
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$T/pg.json" --adapter "$FX/adapter.json" > "$T/pgd.json"
  check "$E derive on generated personas uses their permissions" "$(q "$T/pgd.json" "e('$PATHS')['allowed']")" '["admin"]'
  printf '%s' '{"roles":"x"}' > "$T/srbad.json"
  QA_ENGINE=$E bash "$SH" personas "$T/srbad.json" "$T/cfgp.json" >/dev/null 2>&1; check "$E personas bad spec-roles dies" "$?" "1"

  # argument errors
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" >/dev/null 2>&1; check "$E derive missing personas dies" "$?" "1"
  QA_ENGINE=$E bash "$SH" bogus >/dev/null 2>&1; check "$E unknown subcommand dies" "$?" "1"
  printf 'not json' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" derive "$T/bad.json" "$FX/personas.json" >/dev/null 2>&1; check "$E malformed census dies" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  QA_ENGINE=jq bash "$SH" derive "$FX/census.json" "$FX/personas.json" --adapter "$FX/adapter.json" > "$X/j.json"
  QA_ENGINE=python3 bash "$SH" derive "$FX/census.json" "$FX/personas.json" --adapter "$FX/adapter.json" > "$X/p.json"
  check "cross-engine derive byte-identical" "$(cmp -s "$X/j.json" "$X/p.json" && echo same || echo diff)" "same"
  QA_ENGINE=jq bash "$SH" confirm-table "$X/j.json" > "$X/j.md"
  QA_ENGINE=python3 bash "$SH" confirm-table "$X/j.json" > "$X/p.md"
  check "cross-engine confirm-table byte-identical" "$(cmp -s "$X/j.md" "$X/p.md" && echo same || echo diff)" "same"
  QA_ENGINE=jq bash "$SH" apply "$X/j.json" "$FX/decisions.json" > "$X/ja.json"
  QA_ENGINE=python3 bash "$SH" apply "$X/j.json" "$FX/decisions.json" > "$X/pa.json"
  check "cross-engine apply byte-identical" "$(cmp -s "$X/ja.json" "$X/pa.json" && echo same || echo diff)" "same"
  QA_ENGINE=jq bash "$SH" apply --assume "$X/j.json" > "$X/jas.json"
  QA_ENGINE=python3 bash "$SH" apply --assume "$X/j.json" > "$X/pas.json"
  check "cross-engine apply --assume byte-identical" "$(cmp -s "$X/jas.json" "$X/pas.json" && echo same || echo diff)" "same"
  printf '%s' '{"pairs":[{"surfaceId":"GET /h/{slug}","persona":"participant","decision":"allow"}],"bySurface":{"GET /admin/reports":["admin","organizer"]}}' > "$X/ad.json"
  QA_ENGINE=jq bash "$SH" apply --assume "$X/j.json" "$X/ad.json" > "$X/jad.json"
  QA_ENGINE=python3 bash "$SH" apply --assume "$X/j.json" "$X/ad.json" > "$X/pad.json"
  check "cross-engine apply --assume decisions byte-identical" "$(cmp -s "$X/jad.json" "$X/pad.json" && echo same || echo diff)" "same"
  QA_ENGINE=jq bash "$SH" confirm-table "$X/jas.json" > "$X/jas.md"
  QA_ENGINE=python3 bash "$SH" confirm-table "$X/jas.json" > "$X/pas.md"
  check "cross-engine confirm-table (assumed) byte-identical" "$(cmp -s "$X/jas.md" "$X/pas.md" && echo same || echo diff)" "same"
  printf '%s' '{"roles":[{"id":"b","role":"b","plane":"global"},{"id":"a","role":"a","plane":"global"}]}' > "$X/sr.json"
  printf '%s' '[{"id":"a","role":"a","permissions":["x.*"],"auth":"seeded"}]' > "$X/cp.json"
  QA_ENGINE=jq bash "$SH" personas "$X/sr.json" "$X/cp.json" > "$X/jp.json" 2> "$X/jp.err"
  QA_ENGINE=python3 bash "$SH" personas "$X/sr.json" "$X/cp.json" > "$X/pp.json" 2> "$X/pp.err"
  check "cross-engine personas byte-identical" "$(cmp -s "$X/jp.json" "$X/pp.json" && cmp -s "$X/jp.err" "$X/pp.err" && echo same || echo diff)" "same"
fi
echo "surface-access: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
