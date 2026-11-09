#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/generate-ship-criteria.sh — census + surface access + authz
# matrix + journeys -> load-clean / deny / ownership-isolation / input-validation / ux-revisit rows, with
# token-safe ids (checked against the engine checkpoint.sh / record-evidence.sh) and readable titles.
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
SHARED="$(mktemp -d)"; TMPDIRS+=("$SHARED")
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <file> <python expression over `rows`> — `r(t)` is the row whose human title (or id) is t (or None),
# `ids(prefix)` the sorted titles starting with prefix (row ids are token-safe hashes; titles are readable).
q(){ python3 -c '
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf-8"))
def r(i): return next((x for x in rows if x.get("title")==i or x["id"]==i), None)
def ids(p): return sorted(x.get("title", x["id"]) for x in rows if x.get("title", x["id"]).startswith(p))
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
    "[\"load-clean\",\"$CREATE\",\"/admin/hackathons/create\",\"admin\",[\"independent\",\"read-only\",\"sweep\"]]"
  check "$E load-clean unreached surface gets none" "$(q "$T/o.json" "ids('load-clean:GET /admin/reports')")" '[]'

  # deny_get_only_without_writes
  check "$E deny_get_only_without_writes GET/page ids" "$(q "$T/o.json" "[i for i in ids('deny:') if not i.startswith('deny:POST')]")" \
    "[\"deny:$CREATE:judge\",\"deny:$CREATE:participant\",\"deny:$HACK:judge\",\"deny:$HACK:participant\",\"deny:GET /ideas/{idea}:admin\",\"deny:$SHOW:judge\",\"deny:$SHOW:participant\"]"
  check "$E deny GET row tags + kind" "$(q "$T/o.json" "[r('deny:$CREATE:judge')['kind'],r('deny:$CREATE:judge')['tags']]")" '["deny",["independent","probe-needed","read-only","sweep"]]'
  check "$E deny default statuses" "$(q "$T/o.json" "r('deny:$CREATE:judge')['denyStatuses']")" '[401,403,404,302]'
  check "$E deny non-GET deferred without writes" "$(q "$T/o.json" "[r('deny:POST /admin/hackathons:participant')['tags'],r('deny:POST /admin/hackathons:judge')['tags']]")" '[["deny-write-deferred","probe-needed","sweep"],["deny-write-deferred","needs-confirmation","probe-needed","sweep"]]'
  check "$E deny-write-deferred is an explicit mutating attempt" "$(q "$T/o.json" "[r('deny:POST /admin/hackathons:participant')['mutates'], r('deny:POST /admin/hackathons:participant')['action']]")" '[true,"As participant, attempt POST /admin/hackathons without permission and expect refusal"]'
  # generator_emits_deny_for_unconfirmed_overreach
  check "$E generator_emits_deny_for_unconfirmed_overreach" "$(q "$T/o.json" "r('deny:$HACK:participant')['tags']")" '["independent","needs-confirmation","probe-needed","read-only","sweep"]'
  check "$E unconfirmed but not reached-without-evidence: no tag" "$(q "$T/o.json" "r('deny:$HACK:judge')['tags']")" '["independent","probe-needed","read-only","sweep"]'
  check "$E confirmed surface: no tag" "$(q "$T/o.json" "sorted(x['title'] for x in rows if 'needs-confirmation' in x['tags'])")" "[\"deny:$HACK:participant\",\"deny:POST /admin/hackathons:judge\"]"
  check "$E unconfirmed entries counted on stderr" "$(grep -c 'deny rows use 2 unconfirmed surface-access entries (2 rows tagged needs-confirmation)' "$T/o.err")" "1"
  check "$E deny none where every persona allowed" "$(q "$T/o.json" "ids('deny:GET /h/')")" '[]'
  check "$E deny none without an access entry" "$(q "$T/o.json" "ids('deny:GET /admin/reports')")" '[]'

  # iso_rows_from_matrix
  check "$E iso_rows_from_matrix ids" "$(q "$T/o.json" "ids('iso:')")" '["iso:idea:participant","iso:team:participant"]'
  check "$E iso row shape" "$(q "$T/o.json" "[r('iso:idea:participant')[k] for k in ('kind','persona','surfaceId','owningChain')]+[('ownership-isolation' in r('iso:idea:participant')['tags']) and ('read-only' in r('iso:idea:participant')['tags'])]")" \
    '["cross-tenant","participant","GET /ideas/{idea}",["user_id"],true]'
  # iso_tagged_cross_tenant (I5: the probe evidence gate keys on the tag, not the kind)
  check "$E iso rows tagged cross-tenant" "$(q "$T/o.json" "[r(i)['tags'] for i in ids('iso:')]")" '[["cross-tenant","independent","ownership-isolation","read-only"],["cross-tenant","independent","ownership-isolation","read-only"]]'
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
  check "$E ux_revisits_skip_primary count" "$(q "$T/o.json" "len(ids('ux:'))")" "21"
  check "$E ux primary combo skipped" "$(q "$T/o.json" "r('ux:$CREATE:admin@desktop-ar-light')")" "None"
  check "$E ux secondary combos present" "$(q "$T/o.json" "[i.split('@')[1] for i in ids('ux:$CREATE:admin@')]")" \
    '["desktop-ar-dark","desktop-en-dark","desktop-en-light","mobile-ar-dark","mobile-ar-light","mobile-en-dark","mobile-en-light"]'
  check "$E ux row shape" "$(q "$T/o.json" "[r('ux:$SHOW:admin@mobile-en-dark')[k] for k in ('surfaceId','persona','variant','priority')]+[sorted(r('ux:$SHOW:admin@mobile-en-dark')['tags'])]")" \
    "[\"$SHOW\",\"admin\",{\"colorScheme\":\"dark\",\"locale\":\"en\",\"viewport\":\"mobile\"},\"P1\",[\"independent\",\"read-only\",\"sweep\",\"ux-revisit\"]]"
  # ux_revisits_every_journey (Settled matrix: every journey's surfaces, not only P1; priority = the journey's)
  check "$E ux revisits a P2 journey too" "$(q "$T/o.json" "[len(ids('ux:GET /h/{slug}:participant@')), r('ux:GET /h/{slug}:participant@mobile-en-dark')['priority']]")" '[7,"P2"]'

  # no_duplicate_ids
  check "$E no_duplicate_ids existing id not re-emitted" "$(q "$T/o.json" "r('load-clean:$HACK:admin')")" "None"
  check "$E no_duplicate_ids unique" "$(q "$T/o.json" "len(rows)==len(set(x['id'] for x in rows))")" "True"
  check "$E every row carries surfaceId except unmatched iso" "$(q "$T/o.json" "[x['title'] for x in rows if 'surfaceId' not in x]")" '["iso:team:participant"]'

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
  check "$E budget_overflow all rows emitted" "$(q "$T/o.json" "len(rows)")" "53"
  check "$E budget_overflow reported on stderr" "$(grep -c 'exceeds criteriaBudget 5' "$T/o.err")" "1"
  check "$E stderr reports the row count" "$(grep -c '53 rows (load-clean 4, deny 9, iso 2, input 17, ux 21); 1 skipped' "$T/o.err")" "1"

  # deny_write_tagged_api_write_when_allowed
  gen "$E" "$FX/config-writes.json" > "$T/w.json" 2> "$T/w.err"; rc=$?
  check "$E writes config exit 0" "$rc" "0"
  check "$E deny_write_tagged_api_write_when_allowed" "$(q "$T/w.json" "[r('deny:POST /admin/hackathons:participant')['tags'],r('deny:POST /admin/hackathons:judge')['tags']]")" '[["api-write","probe-needed","sweep"],["api-write","needs-confirmation","probe-needed","sweep"]]'
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
  check "$E allowApiWrites without marker stays deferred" "$(q "$T/nm.json" "r('deny:POST /admin/hackathons:participant')['tags']")" '["deny-write-deferred","probe-needed","sweep"]'

  # deny rows only from positive evidence (fix round 2)
  cat > "$T/c2.json" <<'J'
{"version":1,"adapter":"laravel","adapterOk":true,"surfaces":[
 {"surfaceId":"GET /account","kind":"endpoint","pattern":"/account","sources":["adapter","crawl"],"reachedBy":["participant"],"allowed":null,"forms":[]},
 {"surfaceId":"GET /news","kind":"page","pattern":"/news","sources":["crawl"],"reachedBy":["participant"],"allowed":null,"forms":[]},
 {"surfaceId":"GET /board","kind":"page","pattern":"/board","sources":["crawl"],"reachedBy":["participant"],"allowed":null,"forms":[]},
 {"surfaceId":"GET /admin/x","kind":"endpoint","pattern":"/admin/x","sources":["adapter","crawl"],"reachedBy":["admin","participant"],"allowed":null,"forms":[]},
 {"surfaceId":"GET /unknown","kind":"endpoint","pattern":"/unknown","sources":["adapter"],"reachedBy":[],"allowed":null,"forms":[]}],
 "jobs":[],"mails":[],"notifications":[],"diffs":{"unreachable":[],"overreach":[],"crawlOnly":[]},"warnings":[]}
J
  cat > "$T/a2.json" <<'J'
{"version":1,"surfaces":{
 "GET /account":{"allowed":[],"source":"adapter","confirmed":false,"hints":["auth","verified"],"hintMatched":[],"reachedWithoutEvidence":["participant"]},
 "GET /news":{"allowed":["participant"],"source":"crawl","confirmed":false,"hints":[],"hintMatched":[],"reachedWithoutEvidence":["participant"]},
 "GET /board":{"allowed":["participant"],"source":"human","confirmed":true,"hints":[],"hintMatched":[],"reachedWithoutEvidence":[]},
 "GET /admin/x":{"allowed":["admin"],"source":"adapter","confirmed":false,"hints":["can:x.view"],"hintMatched":["admin"],"reachedWithoutEvidence":["participant"]}}}
J
  printf '%s' '[]' > "$T/m2.json"; printf '%s' '{}' > "$T/cfg2.json"
  QA_ENGINE=$E bash "$SH" --census "$T/c2.json" --access "$T/a2.json" --matrix "$T/m2.json" --personas "$FX/personas.json" --config "$T/cfg2.json" > "$T/e.json" 2> "$T/e.err"; rc=$?
  check "$E evidence fixture exit 0" "$rc" "0"
  check "$E auth_only_surface_no_deny_rows" "$(q "$T/e.json" "ids('deny:GET /account')")" '[]'
  check "$E no_hint_surface_no_deny_rows" "$(q "$T/e.json" "ids('deny:GET /news')+ids('deny:GET /unknown')")" '[]'
  check "$E confirmed_no_hint_surface_gets_deny_rows" "$(q "$T/e.json" "ids('deny:GET /board')")" '["deny:GET /board:admin","deny:GET /board:judge"]'
  check "$E hinted_surface_still_denies_unmatched" "$(q "$T/e.json" "[[i,r(i)['tags']] for i in ids('deny:GET /admin/x')]")" \
    '[["deny:GET /admin/x:judge",["independent","probe-needed","read-only","sweep"]],["deny:GET /admin/x:participant",["independent","needs-confirmation","probe-needed","read-only","sweep"]]]'
  check "$E skipped surfaces reported on stderr" "$(grep -c 'deny: 3 surfaces skipped — no permission evidence; confirm in surface-access to include' "$T/e.err")" "1"
  check "$E main fixture skips the two surfaces without access evidence" "$(grep -c 'deny: 2 surfaces skipped' "$T/o.err")" "1"
  bash "$VALIDATOR" "$T/e.json" >/dev/null 2>&1; check "$E evidence output validates" "$?" "0"

  # token_safe_ids (C1): id = <prefix>-<slug>-<h8>, h8 = sha1(title)[:8]; title keeps the human id
  check "$E token_safe_ids formula" "$(python3 -c '
import hashlib,json,re,sys
rows=json.load(open(sys.argv[1],encoding="utf-8")); bad=[]
for x in rows:
    t=x["title"]; p,rest=t.split(":",1)
    s="".join(c if ("a"<=c<="z" or "0"<=c<="9" or c in "._-") else chr(ord(c)+32) if "A"<=c<="Z" else "-" for c in rest)
    s=re.sub(r"-+","-",s); s=re.sub(r"\.+",".",s); s=re.sub(r"^[-.]+","",s); s=re.sub(r"[-.]+$","",s[:60])
    want=p+"-"+(s+"-" if s else "")+hashlib.sha1(t.encode("utf-8")).hexdigest()[:8]
    ok=x["id"]==want and re.fullmatch(r"(load-clean|deny|iso|input|ux)-[a-z0-9._-]*[0-9a-f]{8}",x["id"]) and ".." not in x["id"] and p in ("load-clean","deny","iso","input","ux")
    if not ok: bad.append(x["id"])
print(json.dumps(bad))' "$T/o.json")" '[]'
  check "$E ids unique" "$(q "$T/o.json" "len(set(x['id'] for x in rows))==len(rows)")" "True"
  check "$E every row has a title" "$(q "$T/o.json" "all(isinstance(x.get('title'),str) and ':' in x['title'] for x in rows)")" "True"
  check "$E slug example" "$(q "$T/o.json" "r('deny:GET /admin/hackathons/{hackathon}:participant')['id'][:-9]")" "deny-get-admin-hackathons-hackathon-participant"

  # personas_accepts_spec_roles (I1): {roles:[...]} (spec-roles.json) gives the same rows as the persona array
  printf '%s' '{"constitutionVersion":"v1","roles":[{"id":"admin","role":"admin","plane":"global"},{"id":"judge","role":"judge","plane":"contextual"},{"id":"participant","role":"participant","plane":"contextual"}],"overrides":[]}' > "$T/roles.json"
  QA_ENGINE=$E bash "$SH" --census "$FX/census.json" --access "$FX/access.json" --matrix "$FX/authz-matrix.json" --personas "$T/roles.json" \
    --config "$FX/config.json" --journeys "$FX/journeys.json" --checklist "$FX/checklist.json" > "$T/sr.json" 2>/dev/null; rc=$?
  check "$E personas_accepts_spec_roles exit 0" "$rc" "0"
  check "$E personas_accepts_spec_roles same rows" "$(cmp -s "$T/o.json" "$T/sr.json" && echo same || echo diff)" "same"
  printf '%s' '{"nope":[]}' > "$T/badp.json"
  QA_ENGINE=$E bash "$SH" --census "$FX/census.json" --access "$FX/access.json" --matrix "$FX/authz-matrix.json" --personas "$T/badp.json" \
    --config "$FX/config.json" >/dev/null 2>&1; check "$E personas of unknown shape dies" "$?" "1"

  # sample_urls_tabs_get_forms_oracles (I6, I9 consumer, I7), roles from `role`, empty locales, dedup by id
  cat > "$T/c3.json" <<'J'
{"version":1,"adapter":"laravel","adapterOk":true,"surfaces":[
 {"surfaceId":"page:Admin/Hackathons/Show","kind":"page","pattern":"Admin/Hackathons/Show","sources":["adapter","crawl"],"reachedBy":["admin"],"allowed":null,"sampleUrls":{"admin":"/admin/hackathons/42"},"forms":[
  {"formId":"filters","action":"/admin/hackathons/42","method":"get","fields":[{"name":"q","type":"search","required":false,"maxLength":null,"min":null,"max":null,"pattern":null}]},
  {"formId":"rename","action":"/admin/hackathons/42","method":"POST","fields":[{"name":"title","type":"text","required":true,"maxLength":null,"min":null,"max":null,"pattern":null},{"name":"opens_on","type":"date","required":false,"maxLength":null,"min":null,"max":null,"pattern":null}]}]},
 {"surfaceId":"page:Admin/Hackathons/Show#tab:الفرق","kind":"tab","pattern":"Admin/Hackathons/Show","sources":["crawl"],"reachedBy":["admin"],"allowed":null,"sampleUrls":{"admin":"/admin/hackathons/42"},"forms":[]},
 {"surfaceId":"GET /ideas/{idea}","kind":"endpoint","pattern":"/ideas/{idea}","sources":["adapter","crawl"],"reachedBy":["participant"],"allowed":null,"sampleUrls":{"participant":"/ideas/7?tab=summary"},"forms":[]},
 {"surfaceId":"GET /ideas/{idea}#dialog:delete","kind":"dialog","pattern":"/ideas/{idea}","sources":["crawl"],"reachedBy":["participant"],"allowed":null,"sampleUrls":{"participant":"/ideas/7?tab=summary"},"forms":[]},
 {"surfaceId":"GET /reports/{report}","kind":"endpoint","pattern":"/reports/{report}","sources":["adapter"],"reachedBy":[],"allowed":null,"forms":[]},
 {"surfaceId":"GET /docs/{team*?}","kind":"endpoint","pattern":"/docs/{team*?}","sources":["adapter"],"reachedBy":[],"allowed":null,"forms":[]}],
 "jobs":[],"mails":[],"notifications":[],"diffs":{"unreachable":[],"overreach":[],"crawlOnly":[]},"warnings":[]}
J
  cat > "$T/a3.json" <<'J'
{"version":1,"surfaces":{
 "page:Admin/Hackathons/Show":{"allowed":["admin"],"source":"adapter","confirmed":false,"hints":["role:admin"],"hintMatched":["admin"],"reachedWithoutEvidence":[]},
 "page:Admin/Hackathons/Show#tab:الفرق":{"allowed":["admin"],"source":"adapter","confirmed":false,"hints":["role:admin"],"hintMatched":["admin"],"reachedWithoutEvidence":[]},
 "GET /reports/{report}":{"allowed":["admin"],"source":"adapter","confirmed":false,"hints":["role:admin"],"hintMatched":["admin"],"reachedWithoutEvidence":[]},
 "GET /ideas/{idea}":{"allowed":["participant"],"source":"crawl","confirmed":false,"assumption":true,"hints":[],"hintMatched":[],"reachedWithoutEvidence":["participant"]}}}
J
  printf '%s' '[{"entity":"idea","owningChain":["user_id"],"roleScope":{"participant":"owns"}},{"entity":"team","owningChain":["hackathon_id"],"roleScope":{"participant":"owns"}}]' > "$T/m3.json"
  printf '%s' '[{"id":"S1","surfaceId":"GET /ideas/{idea}","role":"participant","kind":"happy-path","tags":["read-only"],"action":"Open the idea"},{"id":"S2","surfaceId":"page:Admin/Hackathons/Show","persona":"admin","kind":"happy-path","tags":["read-only"],"action":"Open the hackathon"}]' > "$T/k3.json"
  printf '%s' '[{"id":"J1","title":"تقديم فكرة","priority":"P1","roles":["admin","participant"],"steps":["S1"]},{"id":"J2","title":"متابعة","roles":["admin"],"steps":["S2"]}]' > "$T/j3.json"
  printf '%s' '{"profile":"ship","responsiveMatrix":[{"id":"desktop","width":1440,"height":900},{"id":"mobile","width":390,"height":844}],"locales":[],"colorSchemes":["light","dark"]}' > "$T/cfg3.json"
  QA_ENGINE=$E bash "$SH" --census "$T/c3.json" --access "$T/a3.json" --matrix "$T/m3.json" --personas "$FX/personas.json" --config "$T/cfg3.json" \
    --journeys "$T/j3.json" --checklist "$T/k3.json" > "$T/s.json" 2> "$T/s.err"; rc=$?
  check "$E sample fixture exit 0" "$rc" "0"
  check "$E load_clean_uses_sample_url" "$(q "$T/s.json" "[r('load-clean:page:Admin/Hackathons/Show:admin')['url'], r('load-clean:page:Admin/Hackathons/Show:admin')['action']]")" \
    '["/admin/hackathons/42","As admin, open /admin/hackathons/42 and let it settle"]'
  check "$E deny_uses_another_persona_sample" "$(q "$T/s.json" "[r('deny:page:Admin/Hackathons/Show:judge')['url'], r('deny:page:Admin/Hackathons/Show:judge')['action']]")" \
    '["/admin/hackathons/42","As judge, navigate directly to /admin/hackathons/42 (read-only)"]'
  check "$E no_sample_falls_back_to_pattern_with_note" "$(q "$T/s.json" "['url' in r('deny:GET /reports/{report}:judge'), r('deny:GET /reports/{report}:judge')['action']]")" \
    '[false,"As judge, navigate directly to /reports/{report} (no sampled URL in the census: fill the route parameters with a real record) (read-only)"]'
  check "$E tab_surface_action_opens_the_tab" "$(q "$T/s.json" "r('load-clean:page:Admin/Hackathons/Show#tab:الفرق:admin')['action']")" \
    'As admin, open /admin/hackathons/42, then open the tab "الفرق" and let it settle'
  check "$E dialog_surface_action_opens_the_dialog" "$(q "$T/s.json" "r('load-clean:GET /ideas/{idea}#dialog:delete:participant')['action']")" \
    'As participant, open /ideas/7?tab=summary, then open the dialog "delete" and let it settle'
  check "$E tab surface id token-safe" "$(q "$T/s.json" "r('load-clean:page:Admin/Hackathons/Show#tab:الفرق:admin')['id'][:-9]")" "load-clean-page-admin-hackathons-show-tab-admin"
  check "$E iso ignores tab/dialog subsurfaces" "$(q "$T/s.json" "r('iso:idea:participant')['surfaceId']")" "GET /ideas/{idea}"
  check "$E iso matches a catch-all {x*?} parameter" "$(q "$T/s.json" "r('iso:team:participant')['surfaceId']")" "GET /docs/{team*?}"
  check "$E assumed_entry_gives_no_deny" "$(q "$T/s.json" "ids('deny:GET /ideas/')")" '[]'
  check "$E assumed entries reported" "$(grep -c '1 surface-access entries are assumptions (autonomousSetup), not human confirmations' "$T/s.err")" "1"
  # input_skips_get_forms + accept_or_reject_oracle (I7)
  check "$E input_skips_get_forms" "$(q "$T/s.json" "ids('input:filters')")" '[]'
  check "$E get form skip reported" "$(grep -c 'input: 1 forms with method GET skipped (search / filter forms): filters (only an explicit method get is skipped' "$T/s.err")" "1"
  check "$E input rows of the POST form" "$(q "$T/s.json" "ids('input:rename:')")" '["input:rename:opens_on:invalid","input:rename:opens_on:past","input:rename:title:empty","input:rename:title:long-5000","input:rename:title:special"]'
  check "$E accept_or_reject_oracle special/long-5000/past" "$(q "$T/s.json" "sorted(set(r(i)['expected'] for i in ('input:rename:title:special','input:rename:title:long-5000','input:rename:opens_on:past')))")" \
    '["Either a validation message is visible, or the value is accepted and rendered escaped and intact; never a 5xx, never raw HTML injection"]'
  check "$E must_reject_oracle empty/invalid" "$(q "$T/s.json" "sorted(set(r(i)['expected'] for i in ('input:rename:title:empty','input:rename:opens_on:invalid')))")" \
    '["A validation message is visible, no 5xx, and no persisted change (bake multiplicity unchanged)"]'
  # input_rows_locatable: an input row carries the host's sampled url for its role, and on a
  # tab/dialog surface its action opens the parent url, then the tab/dialog, then submits.
  cat > "$T/c4.json" <<'J'
{"version":1,"adapterOk":true,"surfaces":[
 {"surfaceId":"GET /admin/hackathons/{hackathon}#tab:الفرق","kind":"tab","pattern":"/admin/hackathons/{hackathon}","sources":["crawl"],"reachedBy":["admin"],"allowed":null,"sampleUrls":{"admin":"/admin/hackathons/42"},
  "forms":[{"formId":"team-invite","method":"POST","fields":[{"name":"email","type":"email","required":true}]}]},
 {"surfaceId":"GET /profile","kind":"endpoint","pattern":"/profile","sources":["adapter","crawl"],"reachedBy":["participant"],"allowed":null,"sampleUrls":{"participant":"/profile?section=bio"},
  "forms":[{"formId":"profile-bio","method":"POST","fields":[{"name":"bio","type":"textarea","maxLength":3}]}]},
 {"surfaceId":"GET /legacy/{x}","kind":"endpoint","pattern":"/legacy/{x}","sources":["adapter"],"reachedBy":[],"allowed":null,
  "forms":[{"formId":"legacy-edit","method":"POST","fields":[{"name":"note","type":"text","required":true}]}]}],
 "jobs":[],"mails":[],"notifications":[],"diffs":{"unreachable":[],"overreach":[],"crawlOnly":[]},"warnings":[]}
J
  printf '%s' '{"version":1,"surfaces":{"GET /legacy/{x}":{"allowed":["judge"],"source":"adapter","confirmed":true,"hints":[],"hintMatched":[],"reachedWithoutEvidence":[]}}}' > "$T/a4.json"
  printf '%s' '[]' > "$T/m4.json"
  QA_ENGINE=$E bash "$SH" --census "$T/c4.json" --access "$T/a4.json" --matrix "$T/m4.json" --personas "$FX/personas.json" --config "$FX/config.json" > "$T/i4.json" 2> "$T/i4.err"; rc=$?
  check "$E input_rows_locatable exit 0" "$rc" "0"
  check "$E input_rows_locatable tab url+action" "$(q "$T/i4.json" "[r('input:team-invite:email:empty')['url'], r('input:team-invite:email:empty')['action']]")" \
    '["/admin/hackathons/42","As admin, open /admin/hackathons/42, then open the tab \"الفرق\", then submit form team-invite with field email set to the empty case"]'
  check "$E input_rows_locatable page url+action" "$(q "$T/i4.json" "[r('input:profile-bio:bio:maxlen+1')['url'], r('input:profile-bio:bio:maxlen+1')['action']]")" \
    '["/profile?section=bio","As participant, open /profile?section=bio, then submit form profile-bio with field bio set to the maxlen+1 case"]'
  check "$E input_rows_locatable no sample keeps the pattern note" "$(q "$T/i4.json" "['url' in r('input:legacy-edit:note:empty'), r('input:legacy-edit:note:empty')['action']]")" \
    '[false,"As judge, open /legacy/{x} (no sampled URL in the census: fill the route parameters with a real record), then submit form legacy-edit with field note set to the empty case"]'
  cp "$T/i4.json" "$SHARED/i4.$E"
  # ux_persona_from_role + ux_every_journey + empty locales (single pass, no locale suffix)
  check "$E ux_persona_from_role (not every journey role)" "$(q "$T/s.json" "sorted(set(r(i)['persona'] for i in ids('ux:GET /ideas/')))")" '["participant"]'
  check "$E ux_empty_locales_titles" "$(q "$T/s.json" "[i.split('@')[1] for i in ids('ux:GET /ideas/{idea}:participant@')]")" '["desktop-dark","mobile-dark","mobile-light"]'
  check "$E ux_empty_locales_variant_has_no_locale" "$(q "$T/s.json" "r('ux:GET /ideas/{idea}:participant@mobile-dark')['variant']")" '{"colorScheme":"dark","viewport":"mobile"}'
  check "$E ux action names the sampled url and no locale" "$(q "$T/s.json" "r('ux:GET /ideas/{idea}:participant@mobile-dark')['action']")" \
    'As participant, revisit /ideas/7?tab=summary at viewport mobile, dark scheme (read-only): screenshot and run the UX detectors'
  check "$E ux journey without priority has no priority" "$(q "$T/s.json" "['priority' in r('ux:page:Admin/Hackathons/Show:admin@mobile-dark'), r('ux:GET /ideas/{idea}:participant@mobile-dark')['priority']]")" '[false,"P1"]'
  python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));c["locales"]=["<default>"];json.dump(c,open(sys.argv[2],"w"))' "$T/cfg3.json" "$T/cfg3d.json"
  QA_ENGINE=$E bash "$SH" --census "$T/c3.json" --access "$T/a3.json" --matrix "$T/m3.json" --personas "$FX/personas.json" --config "$T/cfg3d.json" \
    --journeys "$T/j3.json" --checklist "$T/k3.json" > "$T/sd.json" 2>/dev/null
  check "$E literal <default> locale treated as empty" "$(cmp -s "$T/s.json" "$T/sd.json" && echo same || echo diff)" "same"
  # dedup by an existing new-format id and by an existing title
  python3 -c '
import json,sys
rows=json.load(open(sys.argv[1],encoding="utf-8")); k=json.load(open(sys.argv[2],encoding="utf-8"))
a=next(x for x in rows if x["title"]=="load-clean:GET /ideas/{idea}:participant"); b=next(x for x in rows if x["title"]=="deny:GET /reports/{report}:judge")
k.append({"id":a["id"],"surfaceId":"GET /ideas/{idea}","kind":"load-clean","tags":["read-only"]}); k.append({"id":"OLD-1","title":b["title"],"kind":"deny","tags":["read-only"]})
json.dump(k,open(sys.argv[3],"w",encoding="utf-8"),ensure_ascii=False)' "$T/s.json" "$T/k3.json" "$T/k4.json"
  QA_ENGINE=$E bash "$SH" --census "$T/c3.json" --access "$T/a3.json" --matrix "$T/m3.json" --personas "$FX/personas.json" --config "$T/cfg3.json" \
    --journeys "$T/j3.json" --checklist "$T/k4.json" > "$T/sk.json" 2>/dev/null
  check "$E dedup_by_existing_id_and_title" "$(q "$T/sk.json" "[r('load-clean:GET /ideas/{idea}:participant'), r('deny:GET /reports/{report}:judge')]")" '[null,null]'
  bash "$VALIDATOR" "$T/s.json" >/dev/null 2>&1; check "$E sample fixture output validates" "$?" "0"
  cp "$T/s.json" "$SHARED/s-$E.json"; cp "$T/s.err" "$SHARED/s-$E.err"

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
  check "cross-engine sample fixture rows byte-identical" "$(cmp -s "$SHARED/s-jq.json" "$SHARED/s-python3.json" && echo same || echo diff)" "same"
  check "cross-engine sample fixture stderr identical" "$(cmp -s "$SHARED/s-jq.err" "$SHARED/s-python3.err" && echo same || echo diff)" "same"
  check "cross-engine input_rows_locatable byte-identical" "$(cmp -s "$SHARED/i4.jq" "$SHARED/i4.python3" && echo same || echo diff)" "same"
fi

# ids_accepted_by_checkpoint (C1): every generated id is accepted as a criterion id by the engine's
# checkpoint.sh and record-evidence.sh token validation (test-only reference to the engine scripts),
# and the old human ids are what they reject.
CKP="$DIR/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
REC="$DIR/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
Y="$(mktemp -d)"; TMPDIRS+=("$Y")
gen python3 "$FX/config.json" --journeys "$FX/journeys.json" --checklist "$FX/checklist.json" > "$Y/all.json" 2>/dev/null
python3 -c 'import json,sys;[print(x["id"]+"\t"+x["persona"]) for f in sys.argv[1:] for x in json.load(open(f,encoding="utf-8"))]' "$Y/all.json" "$SHARED/s-python3.json" > "$Y/ids.tsv"
check "token test includes tab/dialog surfaces" "$(python3 -c 'import json,sys;print(sum(1 for x in json.load(open(sys.argv[1],encoding="utf-8")) if "#" in x.get("surfaceId","")))' "$SHARED/s-python3.json" | awk '{print ($1>0)?"yes":"no"}')" "yes"
bad_ck=0; bad_rec=0; n=0
while IFS="$(printf '\t')" read -r cid per; do
  n=$((n+1))
  (cd "$Y" && bash "$CKP" runtok "$cid" deferred --persona "$per" >/dev/null 2>&1) || { bad_ck=$((bad_ck+1)); echo "checkpoint rejected: $cid" >&2; }
  (cd "$Y" && bash "$REC" runtok "$cid" computed --persona "$per" --oracle 1 --observed 1 --match true >/dev/null 2>&1) || { bad_rec=$((bad_rec+1)); echo "record-evidence rejected: $cid" >&2; }
done < "$Y/ids.tsv"
check "ids_accepted_by_checkpoint: rows tried" "$([ "$n" -ge 50 ] && echo many || echo "$n")" "many"
check "ids_accepted_by_checkpoint: checkpoint.sh rejects none" "$bad_ck" "0"
check "ids_accepted_by_checkpoint: record-evidence.sh rejects none" "$bad_rec" "0"
(cd "$Y" && bash "$CKP" runtok "deny:GET /admin/x:participant" deferred >/dev/null 2>&1); check "control: an old human id is rejected" "$?" "1"

# required_kinds_probe_for_deny_and_iso (I5): the engine deriver requires probe evidence for both
RK="$DIR/../../skills/checkpointing-qa-memory/scripts/required-kinds.sh"
for t in 'deny:GET /admin/hackathons/create:judge' 'deny:POST /admin/hackathons:participant' 'iso:idea:participant'; do
  row="$(python3 -c 'import json,sys;print(json.dumps(next(x for x in json.load(open(sys.argv[1],encoding="utf-8")) if x["title"]==sys.argv[2])))' "$Y/all.json" "$t")"
  check "required_kinds derive probe: $t" "$(bash "$RK" derive "$row" | tr ',' '\n' | grep -cx probe)" "1"
done
row="$(python3 -c 'import json,sys;print(json.dumps(next(x for x in json.load(open(sys.argv[1],encoding="utf-8")) if x["title"]==sys.argv[2])))' "$Y/all.json" 'deny:POST /admin/hackathons:participant')"
check "required_kinds deny-write-deferred derives human-action,probe" "$(bash "$RK" derive "$row")" "human-action,probe"

# sha1 fallbacks (jq path without python hashing) give the same ids
if command -v jq >/dev/null 2>&1; then
  for tool in sha1sum shasum openssl; do
    command -v "$tool" >/dev/null 2>&1 || continue
    QA_SHA1=$tool gen jq "$FX/config.json" --journeys "$FX/journeys.json" > "$Y/h-$tool.json" 2>/dev/null
    gen jq "$FX/config.json" --journeys "$FX/journeys.json" > "$Y/h-py.json" 2>/dev/null
    check "sha1 fallback $tool matches" "$(cmp -s "$Y/h-$tool.json" "$Y/h-py.json" && echo same || echo diff)" "same"
  done
  QA_SHA1=bogus gen jq "$FX/config.json" >/dev/null 2>&1; check "unknown QA_SHA1 tool dies" "$?" "1"
fi
echo "ship-criteria: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
