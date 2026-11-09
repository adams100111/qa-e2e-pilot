#!/usr/bin/env bash
# generate-ship-criteria.sh — turns the surface census into ship-profile checklist rows (pure, dual-engine).
#
# USAGE:
#   generate-ship-criteria.sh --census <census.json> --access <surface-access.json> --matrix <authz-matrix.json>
#                             --personas <personas.json> --config <effective-config.json>
#                             [--journeys <journeys.json>] [--checklist <existing checklist.json>]
#   Prints a JSON array of checklist rows (append-ready; sorted keys, raw UTF-8) on stdout and a
#   summary plus warnings on stderr. Exit 0 on success, 1 on bad arguments or malformed input.
#
# ROWS (every row carries `role` = `persona` = the persona id used in census reachedBy / spec-roles, so the
# coverage gate can count it for a role-specific pair; `surfaceId` unless noted; kind from the D1 enum):
#   load-clean:<surfaceId>:<persona>   one per census surface x persona in its crawl `reachedBy`;
#                                      tags independent + read-only; expects no in-scope fatal finding.
#   deny:<surfaceId>:<persona>         one per persona (personas.json) x surface whose `allowed` (access
#                                      entry, else census `allowed`; no entry = no rows) excludes it.
#                                      GET/HEAD/page -> tags independent + read-only. Any other method ->
#                                      tag deny-write-deferred, or api-write when config allowApiWrites is
#                                      true AND seedableEnvMarker is non-empty (D6). `denyStatuses` from
#                                      config ship.denyStatuses, default [401,403,404,302].
#   iso:<entity>:<persona>             one per authz-matrix row x persona whose roleScope is "owns": open
#                                      another owner's record by direct URL (kind cross-tenant, tags
#                                      independent + ownership-isolation + read-only). surfaceId = the
#                                      GET/page surfaces with a route parameter named {entity},
#                                      {entity_id} or {entityid} (ASCII case-insensitive); none found ->
#                                      the row has no surfaceId and stderr warns.
#   input:<formId>:<field>:<case>      one per census form field x edge case (kind input-validation,
#                                      tag human-action). A generic form id ("page", "form[N]") is
#                                      qualified as "<surfaceId>#<formId>"; a named form found on several
#                                      surfaces is one form (fields from the first surface by id).
#                                      role = first (sorted) persona that reached a host surface, else
#                                      first allowed on one; a form with neither gets no rows (stderr warns).
#                                      Cases: required -> empty ""; text-like (text, textarea, search,
#                                      tel, url, email, password) -> maxlen+1 (maxLength+1 letters "ب")
#                                      or long-5000 (5000 "ب") when no maxLength, and special
#                                      `<b>"'&;--</b>`; email -> malformed "name@"; number/range ->
#                                      huge "99999999999", negative "-1" when min >= 0; date -> past
#                                      "2000-01-01", invalid "2026-02-30". Expected: validation message
#                                      visible, no 5xx, no persisted change (bake multiplicity unchanged).
#   ux:<surfaceId>:<persona>@<viewport>-<locale>-<scheme>
#                                      for every surface a P1 journey step's checklist row names (persona
#                                      = the row's `persona`, else the journey's roles), each variant
#                                      combo except the primary (first viewport, first locale, light).
#                                      Viewports = responsiveMatrix ids (else "<w>x<h>"), else config
#                                      viewport, else "default"; locales = config locales else
#                                      "default"; schemes = config colorSchemes (light|dark) else light.
#                                      kind load-clean, priority P1, tags independent + read-only +
#                                      ux-revisit, `variant` set. Needs --checklist to resolve steps.
#   An id already in --checklist is never emitted. criteriaBudget is NOT applied: it is a run-time
#   cost lever, so every row is emitted and an overflow is reported on stderr.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (QA_ENGINE=jq|python3 forces one). Never calls
# an engine script.
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }
usage="usage: generate-ship-criteria.sh --census <c> --access <a> --matrix <authz-matrix.json> --personas <p> --config <effective-config.json> [--journeys <j>] [--checklist <existing>]"

census=""; access=""; matrix=""; personas=""; config=""; journeys=""; checklist=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "$usage"
  case "$1" in
    --census) census="$2" ;;
    --access) access="$2" ;;
    --matrix) matrix="$2" ;;
    --personas) personas="$2" ;;
    --config) config="$2" ;;
    --journeys) journeys="$2" ;;
    --checklist) checklist="$2" ;;
    *) die "$usage" ;;
  esac
  shift 2
done
[ -n "$census" ] && [ -n "$access" ] && [ -n "$matrix" ] && [ -n "$personas" ] && [ -n "$config" ] || die "$usage"
for f in "$census" "$access" "$matrix" "$personas" "$config" ${journeys:+"$journeys"} ${checklist:+"$checklist"}; do
  [ -f "$f" ] || die "generate-ship-criteria: file not found: $f"
done
has_jq || has_py || die "generate-ship-criteria: needs jq or python3"

# ---------------------------------------------------------------- jq
JQ_PROG='
def strs: if type == "array" then map(select(type == "string")) else [] end;
def arr: if type == "array" then . else [] end;
def str0: if type == "string" then . else "" end;
def isRead($sid): ($sid | startswith("page:"))
  or (($sid | split(" ")[0] | split("|")) as $m | ($m | index(["GET"]) != null) or ($m | index(["HEAD"]) != null));
def methodOf($sid): if ($sid | startswith("page:")) then "GET" else ($sid | split(" ")[0]) end;
def one: if length == 1 then .[0] else . end;
def textLike: . as $t | ["text","textarea","search","tel","url","email","password"] | index([$t]) != null;
def minNum: if type == "number" then . elif type == "string" then (try tonumber catch null) else null end;
def genericForm: . == "page" or test("^form\\[[0-9]+\\]$");
def params: [ str0 | match("\\{([^}]*)\\}"; "g") | .captures[0].string | rtrimstr("?") | ascii_downcase ];
def cases:
  ((.type // "text") | if type == "string" then . else "text" end) as $t
  | (if .required == true then [{c: "empty", v: ""}] else [] end)
  + (if ($t | textLike) then
       (if (.maxLength | type) == "number" and .maxLength >= 0 then [{c: "maxlen+1", v: ("ب" * ((.maxLength | floor) + 1))}]
        else [{c: "long-5000", v: ("ب" * 5000)}] end)
     else [] end)
  + (if $t == "email" then [{c: "malformed", v: "name@"}] else [] end)
  + (if $t == "number" or $t == "range" then
       [{c: "huge", v: "99999999999"}] + (if ((.min | minNum) // -1) >= 0 then [{c: "negative", v: "-1"}] else [] end)
     else [] end)
  + (if $t == "date" then [{c: "past", v: "2000-01-01"}, {c: "invalid", v: "2026-02-30"}] else [] end)
  + (if ($t | textLike) then [{c: "special", v: "<b>\"'"'"'&;--</b>"}] else [] end);

($c[0]) as $census
| if ($census | type) == "object" and (($census.surfaces // null) | type) == "array" then . else error("census needs a surfaces array") end
| ($a[0]) as $acc
| if ($acc | type) == "object" and (($acc.surfaces // null) | type) == "object" then . else error("surface-access needs a surfaces object") end
| ($p[0] | if type == "array" then . elif type == "object" and ((.personas // null) | type) == "array" then .personas
           else error("personas must be an array or {personas:[...]}") end
         | map(select(type == "object" and (.id | type) == "string") | .id) | unique) as $pids
| ($m[0] | if type == "array" then . elif type == "object" and ((.rows // null) | type) == "array" then .rows
           else error("authz-matrix must be an array of rows") end) as $matrix
| ($cfg[0] | if type == "object" then . else error("config must be an object") end) as $cfg
| ($j[0] | if . == null then [] elif type == "array" then . elif type == "object" and ((.journeys // null) | type) == "array" then .journeys
           else error("journeys must be an array") end) as $journeys
| ($k[0] | if . == null then [] elif type == "array" then . else error("checklist must be an array") end
         | map(select(type == "object" and (.id | type) == "string"))) as $existing
| [ $census.surfaces[] | select(type == "object" and (.surfaceId | type) == "string") ] as $S
| ($S | map({key: .surfaceId, value: .}) | from_entries) as $byId
| (($cfg.ship // null) | if type == "object" then (.denyStatuses // null) else null end
   | if type == "array" and length > 0 then . else [401, 403, 404, 302] end) as $ds
| ($ds | map(tostring) | join(", ")) as $dsText
| (($cfg.allowApiWrites == true) and (($cfg.seedableEnvMarker | type) == "string") and (($cfg.seedableEnvMarker | length) > 0)) as $writes

| [ $S[] as $s | ($s.reachedBy | strs | unique)[] as $pp
    | {id: ("load-clean:" + $s.surfaceId + ":" + $pp), kind: "load-clean", surface: ($s.pattern | str0), surfaceId: $s.surfaceId,
       persona: $pp, tags: ["independent", "read-only"], humanAction: false, mutates: false,
       action: ("As " + $pp + ", open " + ($s.pattern | str0) + " and let it settle"),
       expected: "The surface loads with no 5xx, no crash and no in-scope console error (no in-scope fatal finding)"} ] as $loadClean

| [ $S[] as $s
    | ($acc.surfaces[$s.surfaceId] // null) as $e
    | (if ($e | type) == "object" and (($e.allowed // null) | type) == "array" then ($e.allowed | strs)
       elif (($s.allowed // null) | type) == "array" then ($s.allowed | strs) else null end) as $allowed
    | select($allowed != null)
    | $pids[] as $pp | select($allowed | index([$pp]) == null)
    | {id: ("deny:" + $s.surfaceId + ":" + $pp), kind: "deny", surface: ($s.pattern | str0), surfaceId: $s.surfaceId,
       persona: $pp, denyStatuses: $ds, humanAction: false}
      + (if isRead($s.surfaceId) then
           {tags: ["independent", "read-only"], mutates: false,
            action: ("As " + $pp + ", navigate directly to " + ($s.pattern | str0) + " (read-only)"),
            expected: ("Refused with one of HTTP " + $dsText + " (302 = redirect to login); none of the surface data is rendered")}
         elif $writes then
           {tags: ["api-write"],
            action: ("As " + $pp + ", send " + methodOf($s.surfaceId) + " " + ($s.pattern | str0) + " through the recorded write probe"),
            expected: ("Refused with one of HTTP " + $dsText + "; nothing is persisted")}
         else
           {tags: ["deny-write-deferred"],
            action: ("As " + $pp + ", send " + methodOf($s.surfaceId) + " " + ($s.pattern | str0) + " without permission"),
            expected: ("Refused with one of HTTP " + $dsText + "; nothing is persisted. Writes are not allowed on this environment, so the run records this row as deferred")}
         end) ] as $deny

| [ $matrix[] | select(type == "object" and (.entity | type) == "string") | . as $row
    | ($row.entity | ascii_downcase) as $en | [$en, $en + "_id", $en + "id"] as $cands
    | ([ $S[] | select(isRead(.surfaceId)) | select((.pattern | params) as $ps | any($cands[]; . as $x | $ps | index([$x]) != null))
         | .surfaceId ] | unique) as $hits
    | (($row.roleScope // {}) | if type == "object" then [to_entries[] | select(.value == "owns") | .key] else [] end)[] as $pp
    | {id: ("iso:" + $row.entity + ":" + $pp), kind: "cross-tenant", entity: $row.entity, owningChain: ($row.owningChain | arr),
       surface: (if ($hits | length) > 0 then ($byId[$hits[0]].pattern | str0) else "" end),
       persona: $pp, tags: ["independent", "ownership-isolation", "read-only"], denyStatuses: $ds, humanAction: false, mutates: false,
       action: ("As " + $pp + ", open a " + $row.entity + " owned by another " + $pp + " user by direct URL (read-only GET)"),
       expected: ("Refused with one of HTTP " + $dsText + ", or the record is absent; another owner " + $row.entity + " data is never shown")}
      + (if ($hits | length) > 0 then {surfaceId: ($hits | one)} else {} end) ] as $iso

| (reduce ($S | sort_by(.surfaceId))[] as $s ({order: [], forms: {}};
     reduce (($s.forms | arr)[] | select(type == "object" and (.formId | type) == "string" and (.formId | length) > 0)) as $f (.;
       (if ($f.formId | genericForm) then $s.surfaceId + "#" + $f.formId else $f.formId end) as $key
       | if .forms[$key] == null then .forms[$key] = {key: $key, fields: ($f.fields | arr), hosts: [$s.surfaceId]} | .order += [$key]
         else .forms[$key].hosts += [$s.surfaceId] end))) as $fs
| [ $fs.order[] as $key | $fs.forms[$key] as $form
    | ($form.hosts | unique) as $hosts
    | (([ $hosts[] | ($byId[.].reachedBy | strs | sort)[] ] + [ $hosts[] | ((($acc.surfaces[.] // {}) | if type == "object" then .allowed else null end) | strs | sort)[] ]) | .[0]) as $who
    | select($who != null)
    | $form.fields[] | select(type == "object" and (.name | type) == "string" and (.name | length) > 0) | . as $fd
    | ($fd | cases)[] as $cs
    | {id: ("input:" + $key + ":" + $fd.name + ":" + $cs.c), kind: "input-validation",
       surface: ($byId[$hosts[0]].pattern | str0), surfaceId: ($hosts | one), formId: $key,
       tags: ["human-action"], humanAction: true,
       input: {field: $fd.name, case: $cs.c, value: $cs.v, type: (($fd.type // "text") | if type == "string" then . else "text" end)},
       action: ("Submit form " + $key + " with field " + $fd.name + " set to the " + $cs.c + " case"),
       expected: "A validation message is visible, no 5xx, and no persisted change (bake multiplicity unchanged)", persona: $who} ] as $input
| ([ $fs.order[] as $key | $fs.forms[$key] as $form | ($form.hosts | unique) as $hosts
     | select(([ $hosts[] | ($byId[.].reachedBy | strs)[], ((($acc.surfaces[.] // {}) | if type == "object" then .allowed else null end) | strs)[] ] | length) == 0)
     | $key ]) as $roleless

| ($existing | map({key: .id, value: .}) | from_entries) as $exById
| ([ $journeys[] | select(type == "object" and .priority == "P1") | . as $jr | ($jr.steps | strs)[] as $step
     | ($exById[$step] // null) as $row | select($row != null)
     | (if ($row.surfaceId | type) == "string" then [$row.surfaceId] else ($row.surfaceId | strs) end)[] as $sid
     | (if ($row.persona | type) == "string" and ($row.persona | length) > 0 then [$row.persona] else ($jr.roles | strs) end)[] as $pp
     | {sid: $sid, p: $pp} ] | unique) as $pairs
| (($cfg.responsiveMatrix | arr)
   | map(if type == "object" and (.id | type) == "string" and (.id | length) > 0 then .id
         elif type == "object" and (.width | type) == "number" and (.height | type) == "number" then "\(.width)x\(.height)"
         else empty end)) as $vp0
| (if ($vp0 | length) > 0 then $vp0
   elif (($cfg.viewport // null) | type) == "object" and ($cfg.viewport.width | type) == "number" and ($cfg.viewport.height | type) == "number"
     then ["\($cfg.viewport.width)x\($cfg.viewport.height)"]
   else ["default"] end) as $vps
| (($cfg.locales | strs | map(select(length > 0))) | if length > 0 then . else ["default"] end) as $locs
| (($cfg.colorSchemes | strs | map(select(. == "light" or . == "dark"))) | if length > 0 then . else ["light"] end) as $schs
| [ $pairs[] as $pr | $vps[] as $v | $locs[] as $l | $schs[] as $sc
    | select(($v == $vps[0] and $l == $locs[0] and $sc == "light") | not)
    | (($byId[$pr.sid].pattern // null) | if type == "string" then . else $pr.sid end) as $pat
    | {id: ("ux:" + $pr.sid + ":" + $pr.p + "@" + $v + "-" + $l + "-" + $sc), kind: "load-clean", surface: $pat, surfaceId: $pr.sid,
       persona: $pr.p, priority: "P1", tags: ["independent", "read-only", "ux-revisit"], humanAction: false, mutates: false,
       variant: {viewport: $v, locale: $l, colorScheme: $sc},
       action: ("As " + $pr.p + ", revisit " + $pat + " at viewport " + $v + ", locale " + $l + ", " + $sc + " scheme (read-only): screenshot and run the UX detectors"),
       expected: "Renders with no 5xx, no crash and no objective UX finding at this variant"} ] as $ux

| ($existing | map(.id)) as $exIds
| def keep: unique_by(.id) | map(select(.id as $i | $exIds | index([$i]) == null));
  ($loadClean | keep) as $LC | ($deny | keep) as $DN | ($iso | keep) as $IS | ($input | keep) as $IN | ($ux | keep) as $UX
| ([$loadClean, $deny, $iso, $input, $ux] | map(unique_by(.id) | length) | add) as $generated
| ($LC + $DN + $IS + $IN + $UX | map(. + {role: .persona})) as $rows
| ($rows | length) as $total
| {rows: $rows,
   notes: ((if $census.adapterOk == false then ["generate-ship-criteria: warning: the census adapter did not run (adapterOk false); rows cover crawl-observed surfaces only"] else [] end)
     + (if any($journeys[]; type == "object" and .priority == "P1") and ($existing | length) == 0
        then ["generate-ship-criteria: warning: P1 journeys given without --checklist; their steps cannot be resolved to surfaces, so no ux revisits"] else [] end)
     + [ $roleless[] | "generate-ship-criteria: warning: form " + . + " has no role that reaches or is allowed on its surface; no input rows generated for it" ]
     + [ $IS[] | select(has("surfaceId") | not)
         | "generate-ship-criteria: warning: " + .id + " has no readable census surface with a {" + .entity + "} route parameter; emitted without surfaceId" ]
     + ["generate-ship-criteria: \($total) rows (load-clean \($LC | length), deny \($DN | length), iso \($IS | length), input \($IN | length), ux \($UX | length)); \($generated - $total) skipped as already in the checklist"]
     + (if ($cfg.criteriaBudget | type) == "number" and $total > $cfg.criteriaBudget
        then ["generate-ship-criteria: \($total) rows exceeds criteriaBudget \($cfg.criteriaBudget) by \($total - $cfg.criteriaBudget); every row is emitted (criteriaBudget is a run-time cost lever, not a coverage cut)"]
        else [] end))}
'

run_jq() {
  local out
  out="$(jq -nSc --slurpfile c "$census" --slurpfile a "$access" --slurpfile m "$matrix" --slurpfile p "$personas" \
    --slurpfile cfg "$config" --slurpfile j "${journeys:-/dev/null}" --slurpfile k "${checklist:-/dev/null}" "$JQ_PROG")" \
    || die "generate-ship-criteria: malformed input (see the jq error above)"
  printf '%s' "$out" | jq -r '.notes[]' >&2
  printf '%s' "$out" | jq -Sc '.rows'
}

# ---------------------------------------------------------------- python3
PY_PROG='
import json, math, re, sys
def die(m): sys.stderr.write("ERROR: generate-ship-criteria: " + m + "\n"); sys.exit(1)
def load(p, what):
    if not p: return None
    try:
        with open(p, encoding="utf-8") as f: return json.load(f)
    except Exception: die("invalid JSON in " + what + ": " + p)
def strs(v): return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []
def arr(v): return v if isinstance(v, list) else []
def str0(v): return v if isinstance(v, str) else ""
def isnum(v): return isinstance(v, (int, float)) and not isinstance(v, bool)
def numstr(v): return str(int(v)) if isinstance(v, float) and v.is_integer() else str(v)
def alower(s): return "".join(ch.lower() if "A" <= ch <= "Z" else ch for ch in s)
def is_read(sid):
    if sid.startswith("page:"): return True
    m = sid.split(" ")[0].split("|")
    return "GET" in m or "HEAD" in m
def method_of(sid): return "GET" if sid.startswith("page:") else sid.split(" ")[0]
def one(xs): return xs[0] if len(xs) == 1 else xs
TEXT = ["text", "textarea", "search", "tel", "url", "email", "password"]
def min_num(v):
    if isnum(v): return v
    if isinstance(v, str):
        try: return float(v)
        except Exception: return None
    return None
def generic_form(f): return f == "page" or re.match(r"^form\[[0-9]+\]$", f) is not None
def params(p): return [alower(x[:-1] if x.endswith("?") else x) for x in re.findall(r"\{([^}]*)\}", str0(p))]
def ftype(fd):
    t = fd.get("type") if fd.get("type") is not None else "text"
    return t if isinstance(t, str) else "text"
def cases(fd):
    t = ftype(fd); out = []
    if fd.get("required") is True: out.append(("empty", ""))
    if t in TEXT:
        ml = fd.get("maxLength")
        if isnum(ml) and ml >= 0: out.append(("maxlen+1", "ب" * (int(math.floor(ml)) + 1)))
        else: out.append(("long-5000", "ب" * 5000))
    if t == "email": out.append(("malformed", "name@"))
    if t in ("number", "range"):
        out.append(("huge", "99999999999"))
        mn = min_num(fd.get("min"))
        if mn is not None and mn >= 0: out.append(("negative", "-1"))
    if t == "date": out += [("past", "2000-01-01"), ("invalid", "2026-02-30")]
    if t in TEXT: out.append(("special", "<b>\"'"'"'&;--</b>"))
    return out

a = sys.argv[1:]
census = load(a[0], "census")
if not (isinstance(census, dict) and isinstance(census.get("surfaces"), list)): die("census needs a surfaces array")
acc = load(a[1], "surface-access")
if not (isinstance(acc, dict) and isinstance(acc.get("surfaces"), dict)): die("surface-access needs a surfaces object")
p = load(a[3], "personas")
if isinstance(p, dict) and isinstance(p.get("personas"), list): p = p["personas"]
if not isinstance(p, list): die("personas must be an array or {personas:[...]}")
pids = sorted(set(x["id"] for x in p if isinstance(x, dict) and isinstance(x.get("id"), str)))
matrix = load(a[2], "authz-matrix")
if isinstance(matrix, dict) and isinstance(matrix.get("rows"), list): matrix = matrix["rows"]
if not isinstance(matrix, list): die("authz-matrix must be an array of rows")
cfg = load(a[4], "config")
if not isinstance(cfg, dict): die("config must be an object")
journeys = load(a[5], "journeys")
if journeys is None: journeys = []
elif isinstance(journeys, dict) and isinstance(journeys.get("journeys"), list): journeys = journeys["journeys"]
elif not isinstance(journeys, list): die("journeys must be an array")
existing = load(a[6], "checklist")
if existing is None: existing = []
elif not isinstance(existing, list): die("checklist must be an array")
existing = [r for r in existing if isinstance(r, dict) and isinstance(r.get("id"), str)]

S = [s for s in census["surfaces"] if isinstance(s, dict) and isinstance(s.get("surfaceId"), str)]
by_id = {}
for s in S: by_id[s["surfaceId"]] = s
ship = cfg.get("ship")
ds = ship.get("denyStatuses") if isinstance(ship, dict) else None
if not (isinstance(ds, list) and len(ds) > 0): ds = [401, 403, 404, 302]
ds_text = ", ".join(numstr(x) if isnum(x) else json.dumps(x, ensure_ascii=False) if not isinstance(x, str) else x for x in ds)
marker = cfg.get("seedableEnvMarker")
writes = cfg.get("allowApiWrites") is True and isinstance(marker, str) and len(marker) > 0

load_clean = []
for s in S:
    for pp in sorted(set(strs(s.get("reachedBy")))):
        pat = str0(s.get("pattern"))
        load_clean.append({"id": "load-clean:" + s["surfaceId"] + ":" + pp, "kind": "load-clean", "surface": pat,
            "surfaceId": s["surfaceId"], "persona": pp, "tags": ["independent", "read-only"], "humanAction": False, "mutates": False,
            "action": "As " + pp + ", open " + pat + " and let it settle",
            "expected": "The surface loads with no 5xx, no crash and no in-scope console error (no in-scope fatal finding)"})

deny = []
for s in S:
    e = acc["surfaces"].get(s["surfaceId"])
    if isinstance(e, dict) and isinstance(e.get("allowed"), list): allowed = strs(e["allowed"])
    elif isinstance(s.get("allowed"), list): allowed = strs(s["allowed"])
    else: continue
    pat = str0(s.get("pattern"))
    for pp in pids:
        if pp in allowed: continue
        row = {"id": "deny:" + s["surfaceId"] + ":" + pp, "kind": "deny", "surface": pat, "surfaceId": s["surfaceId"],
               "persona": pp, "denyStatuses": ds, "humanAction": False}
        if is_read(s["surfaceId"]):
            row.update({"tags": ["independent", "read-only"], "mutates": False,
                "action": "As " + pp + ", navigate directly to " + pat + " (read-only)",
                "expected": "Refused with one of HTTP " + ds_text + " (302 = redirect to login); none of the surface data is rendered"})
        elif writes:
            row.update({"tags": ["api-write"],
                "action": "As " + pp + ", send " + method_of(s["surfaceId"]) + " " + pat + " through the recorded write probe",
                "expected": "Refused with one of HTTP " + ds_text + "; nothing is persisted"})
        else:
            row.update({"tags": ["deny-write-deferred"],
                "action": "As " + pp + ", send " + method_of(s["surfaceId"]) + " " + pat + " without permission",
                "expected": "Refused with one of HTTP " + ds_text + "; nothing is persisted. Writes are not allowed on this environment, so the run records this row as deferred"})
        deny.append(row)

iso = []
for row in matrix:
    if not (isinstance(row, dict) and isinstance(row.get("entity"), str)): continue
    en = alower(row["entity"]); cands = [en, en + "_id", en + "id"]
    hits = sorted(set(s["surfaceId"] for s in S if is_read(s["surfaceId"]) and any(c in params(s.get("pattern")) for c in cands)))
    rs = row.get("roleScope") if row.get("roleScope") is not None else {}
    owners = [k for k, v in rs.items() if v == "owns"] if isinstance(rs, dict) else []
    for pp in owners:
        r = {"id": "iso:" + row["entity"] + ":" + pp, "kind": "cross-tenant", "entity": row["entity"], "owningChain": arr(row.get("owningChain")),
             "surface": str0(by_id[hits[0]].get("pattern")) if hits else "",
             "persona": pp, "tags": ["independent", "ownership-isolation", "read-only"], "denyStatuses": ds, "humanAction": False, "mutates": False,
             "action": "As " + pp + ", open a " + row["entity"] + " owned by another " + pp + " user by direct URL (read-only GET)",
             "expected": "Refused with one of HTTP " + ds_text + ", or the record is absent; another owner " + row["entity"] + " data is never shown"}
        if hits: r["surfaceId"] = one(hits)
        iso.append(r)

order, forms = [], {}
for s in sorted(S, key=lambda s: s["surfaceId"]):
    for f in arr(s.get("forms")):
        if not (isinstance(f, dict) and isinstance(f.get("formId"), str) and len(f["formId"]) > 0): continue
        key = s["surfaceId"] + "#" + f["formId"] if generic_form(f["formId"]) else f["formId"]
        if key not in forms:
            forms[key] = {"fields": arr(f.get("fields")), "hosts": [s["surfaceId"]]}; order.append(key)
        else: forms[key]["hosts"].append(s["surfaceId"])
inputs = []
roleless = []
for key in order:
    form = forms[key]; hosts = sorted(set(form["hosts"]))
    def allowed_of(h):
        e = acc["surfaces"].get(h)
        return sorted(strs(e.get("allowed"))) if isinstance(e, dict) else []
    who = next((pp for h in hosts for pp in sorted(strs(by_id[h].get("reachedBy")))), None)
    if who is None: who = next((pp for h in hosts for pp in allowed_of(h)), None)
    if who is None:
        roleless.append(key); continue
    for fd in form["fields"]:
        if not (isinstance(fd, dict) and isinstance(fd.get("name"), str) and len(fd["name"]) > 0): continue
        for c, v in cases(fd):
            r = {"id": "input:" + key + ":" + fd["name"] + ":" + c, "kind": "input-validation",
                 "surface": str0(by_id[hosts[0]].get("pattern")), "surfaceId": one(hosts), "formId": key,
                 "tags": ["human-action"], "humanAction": True,
                 "input": {"field": fd["name"], "case": c, "value": v, "type": ftype(fd)},
                 "action": "Submit form " + key + " with field " + fd["name"] + " set to the " + c + " case",
                 "expected": "A validation message is visible, no 5xx, and no persisted change (bake multiplicity unchanged)", "persona": who}
            inputs.append(r)

ex_by_id = {}
for r in existing: ex_by_id[r["id"]] = r
pairs = set()
for jr in journeys:
    if not (isinstance(jr, dict) and jr.get("priority") == "P1"): continue
    for step in strs(jr.get("steps")):
        row = ex_by_id.get(step)
        if row is None: continue
        sids = [row["surfaceId"]] if isinstance(row.get("surfaceId"), str) else strs(row.get("surfaceId"))
        who = [row["persona"]] if isinstance(row.get("persona"), str) and len(row["persona"]) > 0 else strs(jr.get("roles"))
        for sid in sids:
            for pp in who: pairs.add((sid, pp))
vp0 = []
for x in arr(cfg.get("responsiveMatrix")):
    if isinstance(x, dict) and isinstance(x.get("id"), str) and len(x["id"]) > 0: vp0.append(x["id"])
    elif isinstance(x, dict) and isnum(x.get("width")) and isnum(x.get("height")): vp0.append(numstr(x["width"]) + "x" + numstr(x["height"]))
vw = cfg.get("viewport")
if vp0: vps = vp0
elif isinstance(vw, dict) and isnum(vw.get("width")) and isnum(vw.get("height")): vps = [numstr(vw["width"]) + "x" + numstr(vw["height"])]
else: vps = ["default"]
locs = [x for x in strs(cfg.get("locales")) if len(x) > 0] or ["default"]
schs = [x for x in strs(cfg.get("colorSchemes")) if x in ("light", "dark")] or ["light"]
ux = []
for sid, pp in sorted(pairs):
    pat = by_id[sid].get("pattern") if sid in by_id else None
    pat = pat if isinstance(pat, str) else sid
    for v in vps:
        for l in locs:
            for sc in schs:
                if v == vps[0] and l == locs[0] and sc == "light": continue
                ux.append({"id": "ux:" + sid + ":" + pp + "@" + v + "-" + l + "-" + sc, "kind": "load-clean", "surface": pat, "surfaceId": sid,
                    "persona": pp, "priority": "P1", "tags": ["independent", "read-only", "ux-revisit"], "humanAction": False, "mutates": False,
                    "variant": {"viewport": v, "locale": l, "colorScheme": sc},
                    "action": "As " + pp + ", revisit " + pat + " at viewport " + v + ", locale " + l + ", " + sc + " scheme (read-only): screenshot and run the UX detectors",
                    "expected": "Renders with no 5xx, no crash and no objective UX finding at this variant"})

ex_ids = set(r["id"] for r in existing)
def uniq(rows):
    seen = {}
    for r in rows:
        if r["id"] not in seen: seen[r["id"]] = r
    return [seen[k] for k in sorted(seen)]
groups = [uniq(g) for g in (load_clean, deny, iso, inputs, ux)]
generated = sum(len(g) for g in groups)
LC, DN, IS, IN, UX = [[r for r in g if r["id"] not in ex_ids] for g in groups]
rows = LC + DN + IS + IN + UX
for r in rows: r["role"] = r["persona"]
total = len(rows)
notes = []
if census.get("adapterOk") is False:
    notes.append("generate-ship-criteria: warning: the census adapter did not run (adapterOk false); rows cover crawl-observed surfaces only")
if any(isinstance(jr, dict) and jr.get("priority") == "P1" for jr in journeys) and len(existing) == 0:
    notes.append("generate-ship-criteria: warning: P1 journeys given without --checklist; their steps cannot be resolved to surfaces, so no ux revisits")
for key in roleless:
    notes.append("generate-ship-criteria: warning: form " + key + " has no role that reaches or is allowed on its surface; no input rows generated for it")
for r in IS:
    if "surfaceId" not in r:
        notes.append("generate-ship-criteria: warning: " + r["id"] + " has no readable census surface with a {" + r["entity"] + "} route parameter; emitted without surfaceId")
notes.append("generate-ship-criteria: %d rows (load-clean %d, deny %d, iso %d, input %d, ux %d); %d skipped as already in the checklist"
             % (total, len(LC), len(DN), len(IS), len(IN), len(UX), generated - total))
budget = cfg.get("criteriaBudget")
if isnum(budget) and total > budget:
    notes.append("generate-ship-criteria: " + str(total) + " rows exceeds criteriaBudget " + numstr(budget) + " by " + numstr(total - budget)
                 + "; every row is emitted (criteriaBudget is a run-time cost lever, not a coverage cut)")
for n in notes: sys.stderr.write(n + "\n")
print(json.dumps(rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
'

if has_jq; then
  run_jq
else
  python3 -c "$PY_PROG" "$census" "$access" "$matrix" "$personas" "$config" "$journeys" "$checklist"
fi
