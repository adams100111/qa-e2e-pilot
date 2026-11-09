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
# PERSONAS: an array of personas, {personas:[...]} (the constitution / .qa/config.json shape, or
#   `.qa/specs/<target>/personas-for-generation.json` from `surface-access.sh personas`), or
#   {roles:[...]} (a spec's spec-roles.json). Each entry needs a string `id`.
#
# IDS (token-safe, so checkpoint.sh / record-evidence.sh accept them): every row's `id` is
#   <prefix>-<slug>-<h8>, prefix in load-clean|deny|iso|input|ux. `title` holds the human id listed
#   below (e.g. "deny:GET /admin/x:participant"); slug = the title after "<prefix>:", ASCII-lowercased,
#   every character outside [a-z0-9._-] replaced by "-", runs of "-" and of "." collapsed, leading and
#   trailing "-"/"." trimmed, cut to 60 characters (and trimmed again); an empty slug drops its part.
#   h8 = the first 8 hex digits of the SHA-1 of the title's UTF-8 bytes. `surfaceId` keeps the raw value.
#
# ROWS (every row carries `role` = `persona` = the persona id used in census reachedBy / spec-roles, so the
# coverage gate can count it for a role-specific pair; `surfaceId` unless noted; kind from the D1 enum).
# Tags are sorted. A row whose target has a census `sampleUrls` entry carries `url` (the concrete path
# the crawl reached) and its action opens that URL; otherwise the action names the route pattern and
# says no sampled URL exists. Tab / dialog / sheet surfaces (`<parent>#<kind>:<subKey>`) say to open
# the URL and then that tab, dialog or sheet.
#   load-clean:<surfaceId>:<persona>   one per census surface x persona in its crawl `reachedBy`;
#                                      tags independent + read-only + sweep; expects no in-scope fatal
#                                      finding. URL = sampleUrls[persona], else any sampled URL.
#   deny:<surfaceId>:<persona>         one per persona (personas.json) x surface whose `allowed` excludes
#                                      it, ONLY where the access entry carries positive permission
#                                      evidence: confirmed:true by a human, or permission hints that
#                                      matched at least one persona (`hintMatched` non-empty; for an entry
#                                      without that field: non-empty hints, source "adapter", non-empty
#                                      allowed). A surface with no hints, only guard hints (auth, guest,
#                                      verified, web, api), or no access entry gets NO deny rows until a
#                                      human confirms it: "the crawl did not reach it" is never evidence
#                                      of denial. An entry marked `assumption:true` (autonomousSetup) is
#                                      not a confirmation. stderr counts the surfaces skipped this way.
#                                      Every deny row is tagged probe-needed + sweep.
#                                      GET/HEAD/page -> tags independent + read-only. Any other method ->
#                                      tag deny-write-deferred (mutates:true, action "attempt ... and expect
#                                      refusal"; the run records it deferred), or api-write when config allowApiWrites is
#                                      true AND seedableEnvMarker is non-empty (D6; such rows carry
#                                      mutates:true). `denyStatuses` from config ship.denyStatuses,
#                                      default [401,403,404,302]. A persona listed in the access entry's
#                                      reachedWithoutEvidence on a surface that HAS hints and is not
#                                      confirmed gets its deny row as usual plus tag needs-confirmation
#                                      (the run fails it if the role really gets in). stderr counts the
#                                      unconfirmed access entries the deny rows rest on.
#   iso:<entity>:<persona>             one per authz-matrix row x persona whose roleScope is "owns": open
#                                      another owner's record by direct URL (kind cross-tenant, tags
#                                      cross-tenant + independent + ownership-isolation + read-only).
#                                      surfaceId = the GET/page surfaces (not tab/dialog/sheet) with a
#                                      route parameter named {entity}, {entity_id} or {entityid} (ASCII
#                                      case-insensitive; an optional "?" or catch-all "*" suffix such as
#                                      {entity*} or {entity*?} is ignored); none found -> no surfaceId and stderr warns.
#   input:<formId>:<field>:<case>      one per census form field x edge case (kind input-validation,
#                                      tag human-action). A form whose method is GET (search / filter)
#                                      gets no rows; stderr counts them. A generic form id ("page",
#                                      "form[N]") is qualified as "<surfaceId>#<formId>"; a named form
#                                      found on several surfaces is one form (fields from the first
#                                      surface by id). role = first (sorted) persona that reached a host
#                                      surface, else first allowed on one; a form with neither gets no
#                                      rows (stderr warns).
#                                      Cases: required -> empty ""; text-like (text, textarea, search,
#                                      tel, url, email, password) -> maxlen+1 (maxLength+1 letters "ب")
#                                      or long-5000 (5000 "ب") when no maxLength, and special
#                                      `<b>"'&;--</b>`; email -> malformed "name@"; number/range ->
#                                      huge "99999999999", negative "-1" when min >= 0; date -> past
#                                      "2000-01-01", invalid "2026-02-30".
#                                      Expected for empty, maxlen+1, malformed, huge, negative, invalid: a
#                                      validation message, no 5xx, no persisted change (bake multiplicity
#                                      unchanged). For special, long-5000 and past (accepting is often
#                                      correct): either a validation message, or the value is accepted and
#                                      rendered escaped and intact; never a 5xx, never raw HTML injection.
#   ux:<surfaceId>:<persona>@<viewport>-<locale>-<scheme>
#                                      for every surface a journey step's checklist row names (any
#                                      priority; persona = the row's `persona`, else its `role`, else the
#                                      journey's roles), each variant combo except the primary (first
#                                      viewport, first locale, light). Viewports = responsiveMatrix ids
#                                      (e.g. "mobile"; else "<w>x<h>"), else config viewport, else
#                                      "default"; locales = config locales; schemes = config colorSchemes
#                                      (light|dark) else light. Empty locales (the app default, one pass):
#                                      no locale in the title (`@<viewport>-<scheme>`) nor in `variant`.
#                                      kind load-clean, priority = the best (lowest) priority of the
#                                      journeys that touched the pair (absent when none has one), tags
#                                      independent + read-only + sweep + ux-revisit, `variant` set.
#                                      Needs --checklist to resolve steps.
#   A row whose title or id is already an id or title in --checklist is never emitted. criteriaBudget
#   is NOT applied: it is a run-time cost lever, so every row is emitted and an overflow is reported on
#   stderr.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (QA_ENGINE=jq|python3 forces one). The jq path
# also needs a SHA-1 tool for the ids: python3 (hashlib), else sha1sum, shasum or openssl
# (QA_SHA1=python3|sha1sum|shasum|openssl forces one). Never calls an engine script.
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

NO_SAMPLE=" (no sampled URL in the census: fill the route parameters with a real record)"
ACCEPT_OR_REJECT="Either a validation message is visible, or the value is accepted and rendered escaped and intact; never a 5xx, never raw HTML injection"
MUST_REJECT="A validation message is visible, no 5xx, and no persisted change (bake multiplicity unchanged)"

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
def hasEvidence:
  if .confirmed == true then true
  elif has("hintMatched") then ((.hintMatched | strs | length) > 0)
  else ((.hints | strs | length) > 0) and (.source == "adapter") and ((.allowed | strs | length) > 0) end;
def genericForm: . == "page" or test("^form\\[[0-9]+\\]$");
def params: [ str0 | match("\\{([^}]*)\\}"; "g") | .captures[0].string | sub("[*?]+$"; "") | ascii_downcase ];
def slug: explode
  | map(if (. >= 97 and . <= 122) or (. >= 48 and . <= 57) or . == 46 or . == 95 or . == 45 then .
        elif (. >= 65 and . <= 90) then . + 32 else 45 end)
  | implode | gsub("-+"; "-") | gsub("\\.+"; ".") | sub("^[-.]+"; "") | .[0:60] | sub("[-.]+$"; "");
def mk($prefix; $rest): {title: ($prefix + ":" + $rest), _p: $prefix, _s: ($rest | slug)};
def subKind($s): (($s.kind // "") | if type == "string" then . else "" end) as $k
  | if (["tab","dialog","sheet"] | index([$k]) != null) and ($s.surfaceId | contains("#" + $k + ":"))
    then {kind: $k, key: ($s.surfaceId | split("#" + $k + ":") | .[1:] | join("#" + $k + ":"))} else null end;
def sample($s; $pp): (($s.sampleUrls // null) | if type == "object" then . else {} end) as $su
  | if (($su[$pp] // null) | type) == "string" and ($su[$pp] | length) > 0 then $su[$pp]
    else ([ $su | to_entries[] | select((.value | type) == "string" and (.value | length) > 0) ] | sort_by(.key) | .[0].value) end;
def target($s; $u): (if $u != null then $u else ($s.pattern | str0) + $nosample end)
  + (subKind($s) as $sk | if $sk != null then ", then open the " + $sk.kind + " \"" + $sk.key + "\"" else "" end);
def withUrl($u): if $u != null then {url: $u} else {} end;
def tagset: unique;
def caseExpect($c): if (["special","long-5000","past"] | index([$c]) != null) then $accrej else $mustrej end;
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
           elif type == "object" and ((.roles // null) | type) == "array" then .roles
           else error("personas must be an array, {personas:[...]} or {roles:[...]}") end
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
    | sample($s; $pp) as $u
    | mk("load-clean"; $s.surfaceId + ":" + $pp)
      + {kind: "load-clean", surface: ($s.pattern | str0), surfaceId: $s.surfaceId,
         persona: $pp, tags: (["independent", "read-only", "sweep"] | tagset), humanAction: false, mutates: false,
         action: ("As " + $pp + ", open " + target($s; $u) + " and let it settle"),
         expected: "The surface loads with no 5xx, no crash and no in-scope console error (no in-scope fatal finding)"}
      + withUrl($u) ] as $loadClean

| [ $S[] as $s
    | ($acc.surfaces[$s.surfaceId] // null) as $e
    | ($e | if type == "object" then . else {} end) as $eo
    | ((($eo.hints | strs | length) > 0) and ($eo.confirmed != true)) as $unconfHinted
    | ($eo.reachedWithoutEvidence | strs) as $rwe
    | select($eo | hasEvidence)
    | ($eo.allowed | strs) as $allowed
    | $pids[] as $pp | select($allowed | index([$pp]) == null)
    | (if $unconfHinted and ($rwe | index([$pp]) != null) then ["needs-confirmation"] else [] end) as $nc
    | sample($s; $pp) as $u
    | mk("deny"; $s.surfaceId + ":" + $pp)
      + {kind: "deny", surface: ($s.pattern | str0), surfaceId: $s.surfaceId,
         persona: $pp, denyStatuses: $ds, humanAction: false}
      + (if isRead($s.surfaceId) then
           {tags: (["independent", "probe-needed", "read-only", "sweep"] + $nc | tagset), mutates: false,
            action: ("As " + $pp + ", navigate directly to " + target($s; $u) + " (read-only)"),
            expected: ("Refused with one of HTTP " + $dsText + " (302 = redirect to login); none of the surface data is rendered")}
           + withUrl($u)
         elif $writes then
           {tags: (["api-write", "probe-needed", "sweep"] + $nc | tagset), mutates: true,
            action: ("As " + $pp + ", send " + methodOf($s.surfaceId) + " " + ($s.pattern | str0) + " through the recorded write probe"),
            expected: ("Refused with one of HTTP " + $dsText + "; nothing is persisted")}
         else
           {tags: (["deny-write-deferred", "probe-needed", "sweep"] + $nc | tagset), mutates: true,
            action: ("As " + $pp + ", attempt " + methodOf($s.surfaceId) + " " + ($s.pattern | str0) + " without permission and expect refusal"),
            expected: ("Refused with one of HTTP " + $dsText + "; nothing is persisted. Writes are not allowed on this environment, so the run records this row as deferred")}
         end) ] as $deny

| [ $matrix[] | select(type == "object" and (.entity | type) == "string") | . as $row
    | ($row.entity | ascii_downcase) as $en | [$en, $en + "_id", $en + "id"] as $cands
    | ([ $S[] | select(isRead(.surfaceId) and (subKind(.) == null))
         | select((.pattern | params) as $ps | any($cands[]; . as $x | $ps | index([$x]) != null))
         | .surfaceId ] | unique) as $hits
    | (($row.roleScope // {}) | if type == "object" then [to_entries[] | select(.value == "owns") | .key] else [] end)[] as $pp
    | mk("iso"; $row.entity + ":" + $pp)
      + {kind: "cross-tenant", entity: $row.entity, owningChain: ($row.owningChain | arr),
         surface: (if ($hits | length) > 0 then ($byId[$hits[0]].pattern | str0) else "" end),
         persona: $pp, tags: (["cross-tenant", "independent", "ownership-isolation", "read-only"] | tagset),
         denyStatuses: $ds, humanAction: false, mutates: false,
         action: ("As " + $pp + ", open a " + $row.entity + " owned by another " + $pp + " user by direct URL (read-only GET)"),
         expected: ("Refused with one of HTTP " + $dsText + ", or the record is absent; another owner " + $row.entity + " data is never shown")}
      + (if ($hits | length) > 0 then {surfaceId: ($hits | one)} else {} end) ] as $iso

| (reduce ($S | sort_by(.surfaceId))[] as $s ({order: [], forms: {}, getForms: []};
     reduce (($s.forms | arr)[] | select(type == "object" and (.formId | type) == "string" and (.formId | length) > 0)) as $f (.;
       (if ($f.formId | genericForm) then $s.surfaceId + "#" + $f.formId else $f.formId end) as $key
       | if ((($f.method // null) | if type == "string" then ascii_upcase else "" end) == "GET") then .getForms += [$key]
         elif .forms[$key] == null then .forms[$key] = {key: $key, fields: ($f.fields | arr), hosts: [$s.surfaceId]} | .order += [$key]
         else .forms[$key].hosts += [$s.surfaceId] end))) as $fs
| ($fs.getForms | unique | map(select(. as $g | $fs.order | index([$g]) == null))) as $getSkipped
| [ $fs.order[] as $key | $fs.forms[$key] as $form
    | ($form.hosts | unique) as $hosts
    | (([ $hosts[] | ($byId[.].reachedBy | strs | sort)[] ] + [ $hosts[] | ((($acc.surfaces[.] // {}) | if type == "object" then .allowed else null end) | strs | sort)[] ]) | .[0]) as $who
    | select($who != null)
    | $form.fields[] | select(type == "object" and (.name | type) == "string" and (.name | length) > 0) | . as $fd
    | ($fd | cases)[] as $cs
    | mk("input"; $key + ":" + $fd.name + ":" + $cs.c)
      + {kind: "input-validation",
         surface: ($byId[$hosts[0]].pattern | str0), surfaceId: ($hosts | one), formId: $key,
         tags: ["human-action"], humanAction: true,
         input: {field: $fd.name, case: $cs.c, value: $cs.v, type: (($fd.type // "text") | if type == "string" then . else "text" end)},
         action: ("Submit form " + $key + " with field " + $fd.name + " set to the " + $cs.c + " case"),
         expected: caseExpect($cs.c), persona: $who} ] as $input
| ([ $fs.order[] as $key | $fs.forms[$key] as $form | ($form.hosts | unique) as $hosts
     | select(([ $hosts[] | ($byId[.].reachedBy | strs)[], ((($acc.surfaces[.] // {}) | if type == "object" then .allowed else null end) | strs)[] ] | length) == 0)
     | $key ]) as $roleless

| ($existing | map({key: .id, value: .}) | from_entries) as $exById
| ([ $journeys[] | select(type == "object") | . as $jr | ($jr.steps | strs)[] as $step
     | ($exById[$step] // null) as $row | select($row != null)
     | (if ($row.surfaceId | type) == "string" then [$row.surfaceId] else ($row.surfaceId | strs) end)[] as $sid
     | (if ($row.persona | type) == "string" and ($row.persona | length) > 0 then [$row.persona]
        elif ($row.role | type) == "string" and ($row.role | length) > 0 then [$row.role]
        else ($jr.roles | strs) end)[] as $pp
     | {sid: $sid, p: $pp, pr: (if ($jr.priority | type) == "string" and ($jr.priority | length) > 0 then $jr.priority else null end)} ]
   | group_by([.sid, .p]) | map({sid: .[0].sid, p: .[0].p, pr: ([ .[].pr | select(. != null) ] | sort | .[0])})) as $pairs
| (($cfg.responsiveMatrix | arr)
   | map(if type == "object" and (.id | type) == "string" and (.id | length) > 0 then .id
         elif type == "object" and (.width | type) == "number" and (.height | type) == "number" then "\(.width)x\(.height)"
         else empty end)) as $vp0
| (if ($vp0 | length) > 0 then $vp0
   elif (($cfg.viewport // null) | type) == "object" and ($cfg.viewport.width | type) == "number" and ($cfg.viewport.height | type) == "number"
     then ["\($cfg.viewport.width)x\($cfg.viewport.height)"]
   else ["default"] end) as $vps
| (($cfg.locales | strs | map(select(length > 0 and . != "<default>"))) | if length > 0 then . else [null] end) as $locs
| (($cfg.colorSchemes | strs | map(select(. == "light" or . == "dark"))) | if length > 0 then . else ["light"] end) as $schs
| [ $pairs[] as $pr | $vps[] as $v | $locs[] as $l | $schs[] as $sc
    | select(($v == $vps[0] and $l == $locs[0] and $sc == "light") | not)
    | ($byId[$pr.sid] // {surfaceId: $pr.sid, pattern: $pr.sid}) as $s
    | sample($s; $pr.p) as $u
    | (($s.pattern // null) | if type == "string" then . else $pr.sid end) as $pat
    | mk("ux"; $pr.sid + ":" + $pr.p + "@" + $v + (if $l != null then "-" + $l else "" end) + "-" + $sc)
      + {kind: "load-clean", surface: $pat, surfaceId: $pr.sid,
         persona: $pr.p, tags: (["independent", "read-only", "sweep", "ux-revisit"] | tagset), humanAction: false, mutates: false,
         variant: ({viewport: $v, colorScheme: $sc} + (if $l != null then {locale: $l} else {} end)),
         action: ("As " + $pr.p + ", revisit " + target($s + {pattern: $pat}; $u) + " at viewport " + $v
                  + (if $l != null then ", locale " + $l else "" end) + ", " + $sc + " scheme (read-only): screenshot and run the UX detectors"),
         expected: "Renders with no 5xx, no crash and no objective UX finding at this variant"}
      + (if $pr.pr != null then {priority: $pr.pr} else {} end)
      + withUrl($u) ] as $ux

| ([ $S[] | (($acc.surfaces[.surfaceId] // null) | if type == "object" then . else {} end) as $eo
     | select(($eo | hasEvidence) | not)
     | (if (($eo.allowed // null) | type) == "array" then ($eo.allowed | strs) elif ((.allowed // null) | type) == "array" then (.allowed | strs) else [] end) as $al
     | select(any($pids[]; . as $x | $al | index([$x]) == null)) ] | length) as $skippedNoEvidence
| ([ $acc.surfaces[] | select(type == "object" and .assumption == true) ] | length) as $assumed
| ([$loadClean, $deny, $iso, $input, $ux] | map(unique_by(.title))) as $groups
| if $h[0] == null then {titles: ($groups | add | map(.title) | unique)} else
  ($h[0]) as $H
| ($existing | map(.id, (.title | select(type == "string")))) as $exKeys
| def finish: map(.id = (._p + "-" + (if ._s == "" then "" else ._s + "-" end) + $H[.title]) | del(._p, ._s));
  def keep: map(select(. as $r | ($exKeys | index([$r.title]) == null) and ($exKeys | index([$r.id]) == null)));
  ($groups | map(finish)) as $G
| ($G[0] | keep) as $LC | ($G[1] | keep) as $DN | ($G[2] | keep) as $IS | ($G[3] | keep) as $IN | ($G[4] | keep) as $UX
| ($G | map(length) | add) as $generated
| ($LC + $DN + $IS + $IN + $UX | map(. + {role: .persona})) as $rows
| ($rows | length) as $total
| {rows: $rows,
   notes: ((if $census.adapterOk == false then ["generate-ship-criteria: warning: the census adapter did not run (adapterOk false); rows cover crawl-observed surfaces only"] else [] end)
     + (if any($journeys[]; type == "object") and ($existing | length) == 0
        then ["generate-ship-criteria: warning: journeys given without --checklist; their steps cannot be resolved to surfaces, so no ux revisits"] else [] end)
     + [ $roleless[] | "generate-ship-criteria: warning: form " + . + " has no role that reaches or is allowed on its surface; no input rows generated for it" ]
     + [ $IS[] | select(has("surfaceId") | not)
         | "generate-ship-criteria: warning: " + .title + " has no readable census surface with a {" + .entity + "} route parameter; emitted without surfaceId" ]
     + (if ($getSkipped | length) > 0
        then ["generate-ship-criteria: input: \($getSkipped | length) forms with method GET skipped (search / filter forms): \($getSkipped | join(", ")) (only an explicit method get is skipped; add input criteria by hand if one of these writes)"] else [] end)
     + ["generate-ship-criteria: \($total) rows (load-clean \($LC | length), deny \($DN | length), iso \($IS | length), input \($IN | length), ux \($UX | length)); \($generated - $total) skipped as already in the checklist"]
     + (if $skippedNoEvidence > 0 then ["generate-ship-criteria: deny: \($skippedNoEvidence) surfaces skipped — no permission evidence; confirm in surface-access to include"] else [] end)
     + ([ $DN[].surfaceId ] | unique | map(select((($acc.surfaces[.] // null) | if type == "object" then .confirmed else null end) != true))
        | if length > 0 then ["generate-ship-criteria: deny rows use \(length) unconfirmed surface-access entries (\([ $DN[] | select(.tags | index(["needs-confirmation"]) != null) ] | length) rows tagged needs-confirmation)"] else [] end)
     + (if $assumed > 0 then ["generate-ship-criteria: \($assumed) surface-access entries are assumptions (autonomousSetup), not human confirmations"] else [] end)
     + (if ($cfg.criteriaBudget | type) == "number" and $total > $cfg.criteriaBudget
        then ["generate-ship-criteria: \($total) rows exceeds criteriaBudget \($cfg.criteriaBudget) by \($total - $cfg.criteriaBudget); every row is emitted (criteriaBudget is a run-time cost lever, not a coverage cut)"]
        else [] end))}
  end
'

# sha1_map <titles.json> — prints {title: first 8 hex of sha1(title)} for a JSON array of titles.
sha1_map() {
  local tool="${QA_SHA1:-}" t
  if [ -z "$tool" ]; then
    if has_py; then tool=python3
    elif command -v sha1sum >/dev/null 2>&1; then tool=sha1sum
    elif command -v shasum >/dev/null 2>&1; then tool=shasum
    elif command -v openssl >/dev/null 2>&1; then tool=openssl
    else die "generate-ship-criteria: the jq path needs a SHA-1 tool (python3, sha1sum, shasum or openssl)"; fi
  fi
  if [ "$tool" = python3 ]; then
    python3 -c '
import hashlib, json, sys
ts = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps({t: hashlib.sha1(t.encode("utf-8")).hexdigest()[:8] for t in ts}, sort_keys=True, ensure_ascii=False))
' "$1" || die "generate-ship-criteria: hashing failed"
    return
  fi
  case "$tool" in
    sha1sum|shasum|openssl) command -v "$tool" >/dev/null 2>&1 || die "generate-ship-criteria: QA_SHA1 tool not found: $tool" ;;
    *) die "generate-ship-criteria: unknown QA_SHA1 tool: $tool (python3|sha1sum|shasum|openssl)" ;;
  esac
  while IFS= read -r -d '' t; do
    case "$tool" in
      sha1sum) printf '%s' "$t" | sha1sum ;;
      shasum) printf '%s' "$t" | shasum -a 1 ;;
      openssl) printf '%s' "$t" | openssl dgst -sha1 -r ;;
    esac | cut -c1-8 >> "$HASHES"
  done < <(jq -j '.[] | . + "\u0000"' "$1")
  jq -nc --slurpfile t "$1" --rawfile h "$HASHES" \
    '[$t[0], ($h | split("\n") | map(select(length > 0)))] | transpose | map({key: .[0], value: .[1]}) | from_entries'
}

run_prog() { # run_prog <hash-map file: null (pass 1, titles only) or {title: h8}>
  jq -nSc --slurpfile c "$census" --slurpfile a "$access" --slurpfile m "$matrix" --slurpfile p "$personas" \
    --slurpfile cfg "$config" --slurpfile j "${journeys:-/dev/null}" --slurpfile k "${checklist:-/dev/null}" \
    --slurpfile h "$1" --arg nosample "$NO_SAMPLE" --arg accrej "$ACCEPT_OR_REJECT" --arg mustrej "$MUST_REJECT" "$JQ_PROG"
}

run_jq() {
  local out
  TITLES="$(mktemp)"; HMAP="$(mktemp)"; HASHES="$(mktemp)"
  trap 'rm -f "$TITLES" "$HMAP" "$HASHES"' EXIT
  printf 'null' > "$HMAP"
  out="$(run_prog "$HMAP")" || die "generate-ship-criteria: malformed input (see the jq error above)"
  printf '%s' "$out" | jq -c '.titles' > "$TITLES"
  sha1_map "$TITLES" > "$HMAP" || exit 1
  out="$(run_prog "$HMAP")" || die "generate-ship-criteria: malformed input (see the jq error above)"
  printf '%s' "$out" | jq -r '.notes[]' >&2
  printf '%s' "$out" | jq -Sc '.rows'
}

# ---------------------------------------------------------------- python3
PY_PROG='
import hashlib, json, math, re, sys
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
def params(p): return [alower(re.sub(r"[*?]+$", "", x)) for x in re.findall(r"\{([^}]*)\}", str0(p))]
def ftype(fd):
    t = fd.get("type") if fd.get("type") is not None else "text"
    return t if isinstance(t, str) else "text"
def slug(s):
    out = "".join(ch if ("a" <= ch <= "z" or "0" <= ch <= "9" or ch in "._-") else chr(ord(ch) + 32) if "A" <= ch <= "Z" else "-" for ch in s)
    out = re.sub(r"-+", "-", out); out = re.sub(r"\.+", ".", out); out = re.sub(r"^[-.]+", "", out)
    return re.sub(r"[-.]+$", "", out[:60])
def mk(prefix, rest):
    title = prefix + ":" + rest; s = slug(rest)
    return {"title": title, "id": prefix + "-" + (s + "-" if s else "") + hashlib.sha1(title.encode("utf-8")).hexdigest()[:8]}
NO_SAMPLE = sys.argv[8]; ACCREJ = sys.argv[9]; MUSTREJ = sys.argv[10]
def sub_kind(s):
    k = s.get("kind") if isinstance(s.get("kind"), str) else ""
    if k in ("tab", "dialog", "sheet") and ("#" + k + ":") in s["surfaceId"]:
        return k, ("#" + k + ":").join(s["surfaceId"].split("#" + k + ":")[1:])
    return None
def sample(s, pp):
    su = s.get("sampleUrls") if isinstance(s.get("sampleUrls"), dict) else {}
    v = su.get(pp)
    if isinstance(v, str) and len(v) > 0: return v
    rest = sorted((k, v) for k, v in su.items() if isinstance(v, str) and len(v) > 0)
    return rest[0][1] if rest else None
def target(s, u):
    t = u if u is not None else str0(s.get("pattern")) + NO_SAMPLE
    sk = sub_kind(s)
    return t + (", then open the " + sk[0] + " \"" + sk[1] + "\"" if sk else "")
def with_url(r, u):
    if u is not None: r["url"] = u
    return r
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
elif isinstance(p, dict) and isinstance(p.get("roles"), list): p = p["roles"]
if not isinstance(p, list): die("personas must be an array, {personas:[...]} or {roles:[...]}")
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
        pat = str0(s.get("pattern")); u = sample(s, pp)
        r = mk("load-clean", s["surfaceId"] + ":" + pp)
        r.update({"kind": "load-clean", "surface": pat,
            "surfaceId": s["surfaceId"], "persona": pp, "tags": ["independent", "read-only", "sweep"], "humanAction": False, "mutates": False,
            "action": "As " + pp + ", open " + target(s, u) + " and let it settle",
            "expected": "The surface loads with no 5xx, no crash and no in-scope console error (no in-scope fatal finding)"})
        load_clean.append(with_url(r, u))

def has_evidence(eo):
    if eo.get("confirmed") is True: return True
    if "hintMatched" in eo: return len(strs(eo.get("hintMatched"))) > 0
    return len(strs(eo.get("hints"))) > 0 and eo.get("source") == "adapter" and len(strs(eo.get("allowed"))) > 0
deny = []
skipped_no_evidence = 0
for s in S:
    e = acc["surfaces"].get(s["surfaceId"])
    eo = e if isinstance(e, dict) else {}
    if not has_evidence(eo):
        al = strs(eo["allowed"]) if isinstance(eo.get("allowed"), list) else strs(s.get("allowed")) if isinstance(s.get("allowed"), list) else []
        if any(x not in al for x in pids): skipped_no_evidence += 1
        continue
    allowed = strs(eo.get("allowed"))
    pat = str0(s.get("pattern"))
    unconf_hinted = len(strs(eo.get("hints"))) > 0 and eo.get("confirmed") is not True
    rwe = strs(eo.get("reachedWithoutEvidence"))
    for pp in pids:
        if pp in allowed: continue
        nc = ["needs-confirmation"] if unconf_hinted and pp in rwe else []
        u = sample(s, pp)
        row = mk("deny", s["surfaceId"] + ":" + pp)
        row.update({"kind": "deny", "surface": pat, "surfaceId": s["surfaceId"],
               "persona": pp, "denyStatuses": ds, "humanAction": False})
        if is_read(s["surfaceId"]):
            row.update({"tags": sorted(set(["independent", "probe-needed", "read-only", "sweep"] + nc)), "mutates": False,
                "action": "As " + pp + ", navigate directly to " + target(s, u) + " (read-only)",
                "expected": "Refused with one of HTTP " + ds_text + " (302 = redirect to login); none of the surface data is rendered"})
            with_url(row, u)
        elif writes:
            row.update({"tags": sorted(set(["api-write", "probe-needed", "sweep"] + nc)), "mutates": True,
                "action": "As " + pp + ", send " + method_of(s["surfaceId"]) + " " + pat + " through the recorded write probe",
                "expected": "Refused with one of HTTP " + ds_text + "; nothing is persisted"})
        else:
            row.update({"tags": sorted(set(["deny-write-deferred", "probe-needed", "sweep"] + nc)), "mutates": True,
                "action": "As " + pp + ", attempt " + method_of(s["surfaceId"]) + " " + pat + " without permission and expect refusal",
                "expected": "Refused with one of HTTP " + ds_text + "; nothing is persisted. Writes are not allowed on this environment, so the run records this row as deferred"})
        deny.append(row)

iso = []
for row in matrix:
    if not (isinstance(row, dict) and isinstance(row.get("entity"), str)): continue
    en = alower(row["entity"]); cands = [en, en + "_id", en + "id"]
    hits = sorted(set(s["surfaceId"] for s in S if is_read(s["surfaceId"]) and sub_kind(s) is None and any(c in params(s.get("pattern")) for c in cands)))
    rs = row.get("roleScope") if row.get("roleScope") is not None else {}
    owners = [k for k, v in rs.items() if v == "owns"] if isinstance(rs, dict) else []
    for pp in owners:
        r = mk("iso", row["entity"] + ":" + pp)
        r.update({"kind": "cross-tenant", "entity": row["entity"], "owningChain": arr(row.get("owningChain")),
             "surface": str0(by_id[hits[0]].get("pattern")) if hits else "",
             "persona": pp, "tags": ["cross-tenant", "independent", "ownership-isolation", "read-only"], "denyStatuses": ds, "humanAction": False, "mutates": False,
             "action": "As " + pp + ", open a " + row["entity"] + " owned by another " + pp + " user by direct URL (read-only GET)",
             "expected": "Refused with one of HTTP " + ds_text + ", or the record is absent; another owner " + row["entity"] + " data is never shown"})
        if hits: r["surfaceId"] = one(hits)
        iso.append(r)

order, forms, get_forms = [], {}, []
for s in sorted(S, key=lambda s: s["surfaceId"]):
    for f in arr(s.get("forms")):
        if not (isinstance(f, dict) and isinstance(f.get("formId"), str) and len(f["formId"]) > 0): continue
        key = s["surfaceId"] + "#" + f["formId"] if generic_form(f["formId"]) else f["formId"]
        method = f.get("method").upper() if isinstance(f.get("method"), str) else ""
        if method == "GET": get_forms.append(key)
        elif key not in forms:
            forms[key] = {"fields": arr(f.get("fields")), "hosts": [s["surfaceId"]]}; order.append(key)
        else: forms[key]["hosts"].append(s["surfaceId"])
get_skipped = sorted(set(k for k in get_forms if k not in forms))
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
            r = mk("input", key + ":" + fd["name"] + ":" + c)
            r.update({"kind": "input-validation",
                 "surface": str0(by_id[hosts[0]].get("pattern")), "surfaceId": one(hosts), "formId": key,
                 "tags": ["human-action"], "humanAction": True,
                 "input": {"field": fd["name"], "case": c, "value": v, "type": ftype(fd)},
                 "action": "Submit form " + key + " with field " + fd["name"] + " set to the " + c + " case",
                 "expected": ACCREJ if c in ("special", "long-5000", "past") else MUSTREJ, "persona": who})
            inputs.append(r)

ex_by_id = {}
for r in existing: ex_by_id[r["id"]] = r
pairs = {}
for jr in journeys:
    if not isinstance(jr, dict): continue
    pr = jr.get("priority") if isinstance(jr.get("priority"), str) and len(jr["priority"]) > 0 else None
    for step in strs(jr.get("steps")):
        row = ex_by_id.get(step)
        if row is None: continue
        sids = [row["surfaceId"]] if isinstance(row.get("surfaceId"), str) else strs(row.get("surfaceId"))
        if isinstance(row.get("persona"), str) and len(row["persona"]) > 0: who = [row["persona"]]
        elif isinstance(row.get("role"), str) and len(row["role"]) > 0: who = [row["role"]]
        else: who = strs(jr.get("roles"))
        for sid in sids:
            for pp in who:
                lst = pairs.setdefault((sid, pp), [])
                if pr is not None: lst.append(pr)
vp0 = []
for x in arr(cfg.get("responsiveMatrix")):
    if isinstance(x, dict) and isinstance(x.get("id"), str) and len(x["id"]) > 0: vp0.append(x["id"])
    elif isinstance(x, dict) and isnum(x.get("width")) and isnum(x.get("height")): vp0.append(numstr(x["width"]) + "x" + numstr(x["height"]))
vw = cfg.get("viewport")
if vp0: vps = vp0
elif isinstance(vw, dict) and isnum(vw.get("width")) and isnum(vw.get("height")): vps = [numstr(vw["width"]) + "x" + numstr(vw["height"])]
else: vps = ["default"]
locs = [x for x in strs(cfg.get("locales")) if len(x) > 0 and x != "<default>"] or [None]
schs = [x for x in strs(cfg.get("colorSchemes")) if x in ("light", "dark")] or ["light"]
ux = []
for (sid, pp) in sorted(pairs):
    prs = sorted(pairs[(sid, pp)])
    s = by_id.get(sid) or {"surfaceId": sid, "pattern": sid}
    pat = s.get("pattern") if isinstance(s.get("pattern"), str) else sid
    s2 = dict(s); s2["pattern"] = pat
    u = sample(s, pp)
    for v in vps:
        for l in locs:
            for sc in schs:
                if v == vps[0] and l == locs[0] and sc == "light": continue
                r = mk("ux", sid + ":" + pp + "@" + v + ("-" + l if l is not None else "") + "-" + sc)
                variant = {"viewport": v, "colorScheme": sc}
                if l is not None: variant["locale"] = l
                r.update({"kind": "load-clean", "surface": pat, "surfaceId": sid,
                    "persona": pp, "tags": ["independent", "read-only", "sweep", "ux-revisit"], "humanAction": False, "mutates": False,
                    "variant": variant,
                    "action": "As " + pp + ", revisit " + target(s2, u) + " at viewport " + v + (", locale " + l if l is not None else "")
                              + ", " + sc + " scheme (read-only): screenshot and run the UX detectors",
                    "expected": "Renders with no 5xx, no crash and no objective UX finding at this variant"})
                if prs: r["priority"] = prs[0]
                ux.append(with_url(r, u))

ex_keys = set(r["id"] for r in existing) | set(r["title"] for r in existing if isinstance(r.get("title"), str))
def uniq(rows):
    seen = {}
    for r in rows:
        if r["title"] not in seen: seen[r["title"]] = r
    return [seen[k] for k in sorted(seen)]
groups = [uniq(g) for g in (load_clean, deny, iso, inputs, ux)]
generated = sum(len(g) for g in groups)
LC, DN, IS, IN, UX = [[r for r in g if r["title"] not in ex_keys and r["id"] not in ex_keys] for g in groups]
rows = LC + DN + IS + IN + UX
for r in rows: r["role"] = r["persona"]
total = len(rows)
notes = []
if census.get("adapterOk") is False:
    notes.append("generate-ship-criteria: warning: the census adapter did not run (adapterOk false); rows cover crawl-observed surfaces only")
if any(isinstance(jr, dict) for jr in journeys) and len(existing) == 0:
    notes.append("generate-ship-criteria: warning: journeys given without --checklist; their steps cannot be resolved to surfaces, so no ux revisits")
for key in roleless:
    notes.append("generate-ship-criteria: warning: form " + key + " has no role that reaches or is allowed on its surface; no input rows generated for it")
for r in IS:
    if "surfaceId" not in r:
        notes.append("generate-ship-criteria: warning: " + r["title"] + " has no readable census surface with a {" + r["entity"] + "} route parameter; emitted without surfaceId")
if get_skipped:
    notes.append("generate-ship-criteria: input: %d forms with method GET skipped (search / filter forms): %s (only an explicit method get is skipped; add input criteria by hand if one of these writes)"
                 % (len(get_skipped), ", ".join(get_skipped)))
notes.append("generate-ship-criteria: %d rows (load-clean %d, deny %d, iso %d, input %d, ux %d); %d skipped as already in the checklist"
             % (total, len(LC), len(DN), len(IS), len(IN), len(UX), generated - total))
def confirmed_of(sid):
    v = acc["surfaces"].get(sid)
    return v.get("confirmed") if isinstance(v, dict) else None
if skipped_no_evidence > 0:
    notes.append("generate-ship-criteria: deny: %d surfaces skipped — no permission evidence; confirm in surface-access to include" % skipped_no_evidence)
unconf = [sid for sid in sorted(set(r["surfaceId"] for r in DN)) if confirmed_of(sid) is not True]
if unconf:
    notes.append("generate-ship-criteria: deny rows use %d unconfirmed surface-access entries (%d rows tagged needs-confirmation)"
                 % (len(unconf), sum(1 for r in DN if "needs-confirmation" in r["tags"])))
assumed = sum(1 for v in acc["surfaces"].values() if isinstance(v, dict) and v.get("assumption") is True)
if assumed > 0:
    notes.append("generate-ship-criteria: %d surface-access entries are assumptions (autonomousSetup), not human confirmations" % assumed)
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
  python3 -c "$PY_PROG" "$census" "$access" "$matrix" "$personas" "$config" "$journeys" "$checklist" \
    "$NO_SAMPLE" "$ACCEPT_OR_REJECT" "$MUST_REJECT"
fi
