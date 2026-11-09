#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/surface-access.sh — derives who should reach each census
# surface (permission hints matched against persona roles + crawl reachedBy), renders the one-pass
# confirmation table, and applies the human's decisions (confirmed:true, source:"human").
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

  # derive_from_hints_and_crawl
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$FX/personas.json" --adapter "$FX/adapter.json" > "$T/a.json"; rc=$?
  check "$E derive exit 0" "$rc" "0"
  check "$E derive version" "$(q "$T/a.json" "a['version']")" "1"
  check "$E derive_from_hints_and_crawl can: hint via permissions only (crawl reach is not permission)" "$(q "$T/a.json" "e('$PATHS')['allowed']")" '["admin"]'
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
r=next((x for x in json.load(open(sys.argv[1],encoding="utf-8")) if x["id"]=="deny:"+sys.argv[2]+":participant"),None)
print(None if r is None else json.dumps(r["tags"]))' "$T/rows.json" "$PATHS")" '["independent", "needs-confirmation", "read-only"]'
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
fi
echo "surface-access: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
