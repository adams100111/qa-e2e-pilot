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

run_engine() {
  local E="$1" T rc; T="$(mktemp -d)"; TMPDIRS+=("$T")

  # derive_from_hints_and_crawl
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$FX/personas.json" --adapter "$FX/adapter.json" > "$T/a.json"; rc=$?
  check "$E derive exit 0" "$rc" "0"
  check "$E derive version" "$(q "$T/a.json" "a['version']")" "1"
  check "$E derive_from_hints_and_crawl can: hint via permissions + crawl reach" "$(q "$T/a.json" "e('$PATHS')['allowed']")" '["admin","participant"]'
  check "$E derive hinted surface source adapter" "$(q "$T/a.json" "e('$PATHS')['source']")" "adapter"
  check "$E derive unconfirmed" "$(q "$T/a.json" "all(not x['confirmed'] for x in a['surfaces'].values())")" "True"
  check "$E derive role: hint with alternatives" "$(q "$T/a.json" "e('GET /organizer/dashboard')['allowed']")" '["admin","organizer"]'
  check "$E derive census hints win over adapter" "$(q "$T/a.json" "[e('GET /admin/reports')['allowed'],e('GET /admin/reports')['hints']]")" '[["admin"],["role:admin"]]'
  check "$E derive non-GET surface from hint" "$(q "$T/a.json" "e('POST /admin/hackathons')['allowed']")" '["admin"]'
  check "$E derive no hint -> crawl only" "$(q "$T/a.json" "[e('GET /h/{slug}')['allowed'],e('GET /h/{slug}')['source']]")" '[["participant"],"crawl"]'
  check "$E derive arabic crawl-only surface" "$(q "$T/a.json" "e('GET /الأخبار')['allowed']")" '["participant"]'
  check "$E derive nothing known -> empty allowed" "$(q "$T/a.json" "e('page:Orphan')['allowed']")" '[]'
  check "$E derive covers every census surface" "$(q "$T/a.json" "len(a['surfaces'])")" "7"
  check "$E derive arabic raw utf-8" "$(grep -c 'الأخبار' "$T/a.json")" "1"
  QA_ENGINE=$E bash "$SH" derive "$FX/census.json" "$FX/personas.json" > "$T/n.json"; rc=$?
  check "$E derive without adapter exit 0" "$rc" "0"
  check "$E derive without adapter: crawl reach only" "$(q "$T/n.json" "[e('$PATHS')['allowed'],e('$PATHS')['source']]")" '[["admin","participant"],"crawl"]'
  check "$E derive without adapter: census hints still read" "$(q "$T/n.json" "e('GET /admin/reports')['allowed']")" '["admin"]'

  # confirm_apply_marks_human
  QA_ENGINE=$E bash "$SH" confirm-table "$T/a.json" > "$T/t.md"; rc=$?
  check "$E confirm-table exit 0" "$rc" "0"
  check "$E confirm-table groups by hint" "$(grep -c '^## can:hackathons.view$' "$T/t.md")" "1"
  check "$E confirm-table no-hint group last" "$(grep '^## ' "$T/t.md" | tail -1)" "## (no permission hint)"
  check "$E confirm-table row" "$(grep -cF "| \`$PATHS\` | admin, participant | adapter | no |" "$T/t.md")" "1"
  check "$E confirm-table empty allowed shown" "$(grep -cF '| `page:Orphan` | (none) | crawl | no |' "$T/t.md")" "1"
  QA_ENGINE=$E bash "$SH" apply "$T/a.json" "$FX/decisions.json" > "$T/h.json"; rc=$?
  check "$E apply exit 0" "$rc" "0"
  check "$E confirm_apply_marks_human by hint" "$(q "$T/h.json" "[e('$PATHS')['allowed'],e('$PATHS')['source'],e('$PATHS')['confirmed']]")" '[["admin"],"human",true]'
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
