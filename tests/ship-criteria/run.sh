#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/generate-ship-criteria.sh — census + surface access + authz
# matrix + journeys -> load-clean / deny / ownership-isolation / input-validation / ux-revisit rows.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/generate-ship-criteria.sh"
# Test-only: the engine's checklist validator, called from the repo path (qa-kit never calls it at runtime).
VALIDATOR="$DIR/../../skills/generating-qa-checklist/scripts/validate-checklist-json.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: ship-criteria: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <file> <python expression over `rows`> — `r(id)` is the row with that id (or None),
# `ids(prefix)` the sorted ids starting with prefix.
q(){ python3 -c '
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf-8"))
def r(i): return next((x for x in rows if x["id"]==i), None)
def ids(p): return sorted(x["id"] for x in rows if x["id"].startswith(p))
v=eval(sys.argv[2])
print(v if isinstance(v,(str,int,bool)) or v is None else json.dumps(v, ensure_ascii=False, separators=(",",":")))
' "$1" "$2"; }
gen(){ # gen <engine> <config> [extra args...]
  local E="$1" C="$2"; shift 2
  QA_ENGINE=$E bash "$SH" --census "$FX/census.json" --access "$FX/access.json" --matrix "$FX/authz-matrix.json" \
    --personas "$FX/personas.json" --config "$C" "$@"
}
CREATE='GET /admin/hackathons/create'
HACK='GET /admin/hackathons/{hackathon}'
SHOW='page:Admin/Hackathons/Show'
B='ب'

run_engine() {
  local E="$1" T rc; T="$(mktemp -d)"; TMPDIRS+=("$T")

  gen "$E" "$FX/config.json" --journeys "$FX/journeys.json" --checklist "$FX/checklist.json" > "$T/o.json" 2> "$T/o.err"; rc=$?
  check "$E generate exit 0" "$rc" "0"

  # load_clean_per_reached_pair
  check "$E load_clean_per_reached_pair ids" "$(q "$T/o.json" "ids('load-clean:')")" \
    "[\"load-clean:$CREATE:admin\",\"load-clean:GET /h/{slug}:participant\",\"load-clean:GET /ideas/{idea}:participant\",\"load-clean:$SHOW:admin\"]"
  check "$E load-clean shape" "$(q "$T/o.json" "[r('load-clean:$CREATE:admin')[k] for k in ('kind','surfaceId','surface','persona','tags')]")" \
    "[\"load-clean\",\"$CREATE\",\"/admin/hackathons/create\",\"admin\",[\"independent\",\"read-only\"]]"
  check "$E load-clean unreached surface gets none" "$(q "$T/o.json" "ids('load-clean:GET /admin/reports')")" '[]'

  # deny_get_only_without_writes
  check "$E deny_get_only_without_writes GET/page ids" "$(q "$T/o.json" "[i for i in ids('deny:') if not i.startswith('deny:POST')]")" \
    "[\"deny:$CREATE:judge\",\"deny:$CREATE:participant\",\"deny:$HACK:judge\",\"deny:$HACK:participant\",\"deny:GET /ideas/{idea}:admin\",\"deny:$SHOW:judge\",\"deny:$SHOW:participant\"]"
  check "$E deny GET row tags + kind" "$(q "$T/o.json" "[r('deny:$CREATE:judge')['kind'],r('deny:$CREATE:judge')['tags']]")" '["deny",["independent","read-only"]]'
  check "$E deny default statuses" "$(q "$T/o.json" "r('deny:$CREATE:judge')['denyStatuses']")" '[401,403,404,302]'
  check "$E deny non-GET deferred without writes" "$(q "$T/o.json" "[r('deny:POST /admin/hackathons:participant')['tags'],r('deny:POST /admin/hackathons:judge')['tags']]")" '[["deny-write-deferred"],["deny-write-deferred","needs-confirmation"]]'
  # generator_emits_deny_for_unconfirmed_overreach
  check "$E generator_emits_deny_for_unconfirmed_overreach" "$(q "$T/o.json" "r('deny:$HACK:participant')['tags']")" '["independent","needs-confirmation","read-only"]'
  check "$E unconfirmed but not reached-without-evidence: no tag" "$(q "$T/o.json" "r('deny:$HACK:judge')['tags']")" '["independent","read-only"]'
  check "$E confirmed surface: no tag" "$(q "$T/o.json" "[x['id'] for x in rows if 'needs-confirmation' in x['tags']]")" "[\"deny:$HACK:participant\",\"deny:POST /admin/hackathons:judge\"]"
  check "$E unconfirmed entries counted on stderr" "$(grep -c 'deny rows use 2 unconfirmed surface-access entries (2 rows tagged needs-confirmation)' "$T/o.err")" "1"
  check "$E deny none where every persona allowed" "$(q "$T/o.json" "ids('deny:GET /h/')")" '[]'
  check "$E deny none without an access entry" "$(q "$T/o.json" "ids('deny:GET /admin/reports')")" '[]'

  # iso_rows_from_matrix
  check "$E iso_rows_from_matrix ids" "$(q "$T/o.json" "ids('iso:')")" '["iso:idea:participant","iso:team:participant"]'
  check "$E iso row shape" "$(q "$T/o.json" "[r('iso:idea:participant')[k] for k in ('kind','persona','surfaceId','owningChain')]+[('ownership-isolation' in r('iso:idea:participant')['tags']) and ('read-only' in r('iso:idea:participant')['tags'])]")" \
    '["cross-tenant","participant","GET /ideas/{idea}",["user_id"],true]'
  check "$E iso without a matching surface has no surfaceId" "$(q "$T/o.json" "'surfaceId' in r('iso:team:participant')")" "False"
  check "$E iso unmatched entity warned on stderr" "$(grep -c 'iso:team:participant' "$T/o.err")" "1"

  # input_cases_by_type
  check "$E input_cases_by_type ids" "$(q "$T/o.json" "ids('input:hackathon-create:')")" \
    '["input:hackathon-create:budget:huge","input:hackathon-create:budget:negative","input:hackathon-create:contact:long-5000","input:hackathon-create:contact:malformed","input:hackathon-create:contact:special","input:hackathon-create:description:long-5000","input:hackathon-create:description:special","input:hackathon-create:logo:empty","input:hackathon-create:seats:huge","input:hackathon-create:starts_on:empty","input:hackathon-create:starts_on:invalid","input:hackathon-create:starts_on:past","input:hackathon-create:title_ar:empty","input:hackathon-create:title_ar:maxlen+1","input:hackathon-create:title_ar:special"]'
  check "$E input maxlen+1 is maxLength+1 Arabic letters" "$(q "$T/o.json" "r('input:hackathon-create:title_ar:maxlen+1')['input']['value']==('$B'*121)")" "True"
  check "$E input long-5000 length" "$(q "$T/o.json" "len(r('input:hackathon-create:description:long-5000')['input']['value'])")" "5000"
  check "$E input special value" "$(q "$T/o.json" "r('input:hackathon-create:title_ar:special')['input']['value']")" "<b>\"'&;--</b>"
  check "$E input empty value" "$(q "$T/o.json" "r('input:hackathon-create:title_ar:empty')['input']['value']")" ""
  check "$E input number huge/negative" "$(q "$T/o.json" "[r('input:hackathon-create:budget:huge')['input']['value'],r('input:hackathon-create:budget:negative')['input']['value']]")" '["99999999999","-1"]'
  check "$E input no negative when min unset" "$(q "$T/o.json" "r('input:hackathon-create:seats:negative')")" "None"
  check "$E input date past/invalid" "$(q "$T/o.json" "[r('input:hackathon-create:starts_on:past')['input']['value'],r('input:hackathon-create:starts_on:invalid')['input']['value']]")" '["2000-01-01","2026-02-30"]'
  check "$E input email malformed" "$(q "$T/o.json" "r('input:hackathon-create:contact:malformed')['input']['value']")" "name@"
  check "$E input row shape" "$(q "$T/o.json" "[r('input:hackathon-create:logo:empty')[k] for k in ('kind','surfaceId','persona','tags')]")" \
    "[\"input-validation\",\"$CREATE\",\"admin\",[\"human-action\"]]"
  check "$E input expected names the three checks" "$(q "$T/o.json" "all(w in r('input:hackathon-create:logo:empty')['expected'] for w in ('validation message','5xx','multiplicity'))")" "True"
  check "$E input generic page form qualified by surface" "$(q "$T/o.json" "ids('input:GET /h/{slug}#page:')")" '["input:GET /h/{slug}#page:بحث:long-5000","input:GET /h/{slug}#page:بحث:special"]'

  # ux_revisits_skip_primary
  check "$E ux_revisits_skip_primary count" "$(q "$T/o.json" "len(ids('ux:'))")" "14"
  check "$E ux primary combo skipped" "$(q "$T/o.json" "r('ux:$CREATE:admin@desktop-ar-light')")" "None"
  check "$E ux secondary combos present" "$(q "$T/o.json" "[i.split('@')[1] for i in ids('ux:$CREATE:admin@')]")" \
    '["desktop-ar-dark","desktop-en-dark","desktop-en-light","mobile-ar-dark","mobile-ar-light","mobile-en-dark","mobile-en-light"]'
  check "$E ux row shape" "$(q "$T/o.json" "[r('ux:$SHOW:admin@mobile-en-dark')[k] for k in ('surfaceId','persona','variant','priority')]+[sorted(r('ux:$SHOW:admin@mobile-en-dark')['tags'])]")" \
    "[\"$SHOW\",\"admin\",{\"colorScheme\":\"dark\",\"locale\":\"en\",\"viewport\":\"mobile\"},\"P1\",[\"independent\",\"read-only\",\"ux-revisit\"]]"
  check "$E ux none for P2 journey" "$(q "$T/o.json" "ids('ux:GET /h/')")" '[]'

  # no_duplicate_ids
  check "$E no_duplicate_ids existing id not re-emitted" "$(q "$T/o.json" "r('load-clean:$HACK:admin')")" "None"
  check "$E no_duplicate_ids unique" "$(q "$T/o.json" "len(rows)==len(set(x['id'] for x in rows))")" "True"
  check "$E every row carries surfaceId except unmatched iso" "$(q "$T/o.json" "[x['id'] for x in rows if 'surfaceId' not in x]")" '["iso:team:participant"]'

  # every_row_has_role (controller ruling: role = persona id, on every row)
  check "$E every_row_has_role" "$(q "$T/o.json" "[x['id'] for x in rows if not isinstance(x.get('role'),str) or not x['role'] or x['role']!=x.get('persona')]")" '[]'
  check "$E role values are persona ids" "$(q "$T/o.json" "sorted(set(x['role'] for x in rows))")" '["admin","judge","participant"]'
  check "$E input row role is the reacher" "$(q "$T/o.json" "r('input:hackathon-create:logo:empty')['role']")" "admin"
  check "$E form with no role gets no rows" "$(q "$T/o.json" "ids('input:legacy-form:')")" '[]'
  check "$E form with no role warned on stderr" "$(grep -c 'form legacy-form has no role' "$T/o.err")" "1"

  # output_validates
  bash "$VALIDATOR" "$T/o.json" >/dev/null 2>"$T/v.err"; rc=$?
  check "$E output_validates" "$rc" "0"
  [ "$rc" -eq 0 ] || cat "$T/v.err" >&2

  # budget_overflow_reported_not_dropped (criteriaBudget 5, all 46 rows emitted)
  check "$E budget_overflow all rows emitted" "$(q "$T/o.json" "len(rows)")" "46"
  check "$E budget_overflow reported on stderr" "$(grep -c 'exceeds criteriaBudget 5' "$T/o.err")" "1"
  check "$E stderr reports the row count" "$(grep -c '46 rows (load-clean 4, deny 9, iso 2, input 17, ux 14); 1 skipped' "$T/o.err")" "1"

  # deny_write_tagged_api_write_when_allowed
  gen "$E" "$FX/config-writes.json" > "$T/w.json" 2> "$T/w.err"; rc=$?
  check "$E writes config exit 0" "$rc" "0"
  check "$E deny_write_tagged_api_write_when_allowed" "$(q "$T/w.json" "[r('deny:POST /admin/hackathons:participant')['tags'],r('deny:POST /admin/hackathons:judge')['tags']]")" '[["api-write"],["api-write","needs-confirmation"]]'
  check "$E api-write deny rows declare mutates true" "$(q "$T/w.json" "[r('deny:POST /admin/hackathons:participant')['mutates'],r('deny:POST /admin/hackathons:judge')['mutates']]")" '[true,true]'
  check "$E writes config deny statuses from ship.denyStatuses" "$(q "$T/w.json" "r('deny:$CREATE:judge')['denyStatuses']")" '[403,404]'
  check "$E single variant -> no ux revisits" "$(q "$T/w.json" "len(ids('ux:'))")" "0"
  check "$E without --checklist nothing is skipped" "$(q "$T/w.json" "r('load-clean:$HACK:admin')['kind']")" "load-clean"
  check "$E within budget: no overflow line" "$(grep -c 'criteriaBudget' "$T/w.err")" "0"
  bash "$VALIDATOR" "$T/w.json" >/dev/null 2>&1; check "$E writes output validates" "$?" "0"
  check "$E every_row_has_role (writes config)" "$(q "$T/w.json" "[x['id'] for x in rows if x.get('role')!=x.get('persona') or not x.get('role')]")" '[]'
  # writes allowed but no disposable marker -> still deferred
  python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));c["seedableEnvMarker"]="";json.dump(c,open(sys.argv[2],"w"))' "$FX/config-writes.json" "$T/nomarker.json"
  gen "$E" "$T/nomarker.json" > "$T/nm.json" 2>/dev/null
  check "$E allowApiWrites without marker stays deferred" "$(q "$T/nm.json" "r('deny:POST /admin/hackathons:participant')['tags']")" '["deny-write-deferred"]'

  # argument errors
  QA_ENGINE=$E bash "$SH" --census "$FX/census.json" >/dev/null 2>&1; check "$E missing required args dies" "$?" "1"
  printf 'not json' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" --census "$T/bad.json" --access "$FX/access.json" --matrix "$FX/authz-matrix.json" \
    --personas "$FX/personas.json" --config "$FX/config.json" >/dev/null 2>&1; check "$E malformed census dies" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  gen jq "$FX/config.json" --journeys "$FX/journeys.json" --checklist "$FX/checklist.json" > "$X/j.json" 2> "$X/j.err"
  gen python3 "$FX/config.json" --journeys "$FX/journeys.json" --checklist "$FX/checklist.json" > "$X/p.json" 2> "$X/p.err"
  check "cross-engine rows byte-identical" "$(cmp -s "$X/j.json" "$X/p.json" && echo same || echo diff)" "same"
  check "cross-engine stderr identical" "$(cmp -s "$X/j.err" "$X/p.err" && echo same || echo diff)" "same"
fi
echo "ship-criteria: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
