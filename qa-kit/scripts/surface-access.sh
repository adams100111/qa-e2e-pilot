#!/usr/bin/env bash
# surface-access.sh — who SHOULD reach each census surface (decision D3), derived then human-confirmed.
#
# `.qa/surface-access.json` is the surface-keyed companion of the entity-keyed authz-matrix.json
# (which stays unchanged). It is derived from the stack adapter's permission hints plus what the
# crawl observed, then confirmed by a human in one pass grouped by permission hint. The generated
# deny criteria and census.sh's overreach diff read it.
#
# USAGE:
#   surface-access.sh derive <census.json> <personas.json> [--adapter <adapter.json>]
#       Prints D3 JSON: {version:1, surfaces:{<surfaceId>:{allowed:[personaId], source, confirmed:false,
#       hints:[...], hintMatched:[personaId], reachedWithoutEvidence:[personaId]}}}, one entry per census
#       surface. `hintMatched` records the positive evidence: the personas a hint matched (the generator
#       emits deny rows only for surfaces with such evidence or a human confirmation).
#         hints   = the census surface's own `permissionHints` when present, else the adapter's
#                   `permissionHints` for the same surfaceId (census.sh does not carry them), else [].
#         With hints:    allowed = the personas a hint matches ONLY; source "adapter";
#                        reachedWithoutEvidence = crawl `reachedBy` personas no hint matches. Reaching a
#                        page is never evidence of permission: such a persona stays out of `allowed`, so
#                        its deny row is generated and census.sh reports the overreach.
#         Without hints: allowed = crawl `reachedBy`; source "crawl"; reachedWithoutEvidence = the same
#                        personas, so a human sees that nothing declared protects the surface.
#       Hint matching (exact, case-sensitive):
#         role:<a>|<b> / roles:<a>,<b>        -> persona `id`, `role` or `roles[]` equals one
#         a bare hint "<a>" (no colon)        -> a role name, matched the same way, EXCEPT the
#                                                framework guard names auth, guest, verified, web, api,
#                                                which match no persona
#         can:<p> / permission(s):<p> / ability:<p> / gate:<p> -> persona `permissions[]` holds <p> or "*"
#         any other prefix (auth:sanctum, throttle:..., ...) -> matches no persona (the human decides)
#       personas.json is an array of personas or {personas:[...]}; each needs a string `id`.
#   surface-access.sh confirm-table <surface-access.json>
#       Prints Markdown. First section: "Reached without permission evidence — confirm or deny", one row
#       per (surface, persona) in reachedWithoutEvidence with the reason (no matching hint / no hints on
#       surface). Then one `## <hints joined by ", ">` section per hint group (sorted; the
#       "(no permission hint)" group last), rows sorted by surfaceId.
#   surface-access.sh apply <surface-access.json> <decisions.json>
#       decisions.json = {byHint?:{<group heading>:[personaId]}, bySurface?:{<surfaceId>:[personaId]},
#                         pairs?:[{surfaceId, persona, decision:"allow"|"deny"}]}.
#       bySurface wins over byHint. A whole-surface decision sets allowed = the sorted, deduplicated list,
#       reachedWithoutEvidence = [], source:"human", confirmed:true. A pair (which must be listed in that
#       surface's reachedWithoutEvidence) is decided alone: allow adds the persona to allowed, deny removes
#       it from allowed (so a deny row results); either way it leaves reachedWithoutEvidence, source
#       becomes "human", and confirmed becomes true once no undecided pair remains. Undecided surfaces are
#       unchanged. An unknown surfaceId, hint group or pair, a pair on a surface also decided whole, or a
#       malformed decision exits 1 (a typo must not silently confirm nothing).
#
# Output JSON has sorted keys, compact separators, raw UTF-8 (byte-identical between engines).
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (QA_ENGINE=jq|python3 forces one).
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
usage="usage: surface-access.sh derive <census.json> <personas.json> [--adapter <adapter.json>] | confirm-table <surface-access.json> | apply <surface-access.json> <decisions.json>"
NO_HINT="(no permission hint)"
RWE_TITLE="Reached without permission evidence — confirm or deny"

[ "$#" -ge 1 ] || die "$usage"
cmd="$1"; shift

# ---------------------------------------------------------------- jq
JQ_DEFS='
def personas: if type == "array" then . elif type == "object" and ((.personas // null) | type) == "array" then .personas
              else error("surface-access: personas must be an array or {personas:[...]}") end
            | if all(.[]; type == "object" and (.id | type) == "string") then .
              else error("surface-access: every persona needs a string id") end;
def strs: if type == "array" then map(select(type == "string")) else [] end;
def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def hintMatches($h; $ps):
  ($h | index(":")) as $i
  | (if $i == null then (if (["auth","guest","verified","web","api"] | index([$h])) != null then {k: "none", v: $h} else {k: "role", v: $h} end)
     else {k: $h[0:$i], v: $h[$i+1:]} end) as $p
  | ($p.v | split("[|,]"; null) | map(trim) | map(select(length > 0))) as $vals
  | if ($p.k == "role" or $p.k == "roles") then
      [ $ps[] | . as $x | select(([$x.id, $x.role] + ($x.roles | strs)) as $names
                                 | any($vals[]; . as $v | $names | index([$v]) != null)) | .id ]
    elif ($p.k == "can" or $p.k == "permission" or $p.k == "permissions" or $p.k == "ability" or $p.k == "gate") then
      [ $ps[] | . as $x | ($x.permissions | strs) as $perms
              | select(($perms | index(["*"]) != null) or any($vals[]; . as $v | $perms | index([$v]) != null)) | .id ]
    else [] end;
def groupKey: if (.hints | length) == 0 then $nohint else (.hints | join(", ")) end;
def accessIn: if type == "object" and ((.surfaces // null) | type) == "object" then .
              else error("surface-access: surface-access.json needs a surfaces object") end;
'

jq_derive() { # census personas adapter-or-empty
  local adapter_arg=()
  if [ -n "$3" ]; then adapter_arg=(--slurpfile ad "$3"); else adapter_arg=(--argjson ad '[null]'); fi
  jq -Sc --slurpfile p "$2" "${adapter_arg[@]}" --arg nohint "$NO_HINT" "$JQ_DEFS"'
    if type == "object" and ((.surfaces // null) | type) == "array" then . else error("surface-access: census needs a surfaces array") end
    | ($p[0] | personas) as $ps
    | (($ad[0] // {}) | if type == "object" then (.surfaces // []) else [] end
       | map(select(type == "object" and (.surfaceId | type) == "string"))
       | map({key: .surfaceId, value: (.permissionHints | strs)}) | from_entries) as $adHints
    | {version: 1,
       surfaces: (reduce (.surfaces[] | select(type == "object" and (.surfaceId | type) == "string")) as $s ({};
         (if ($s | has("permissionHints")) and (($s.permissionHints | type) == "array")
          then ($s.permissionHints | strs) else ($adHints[$s.surfaceId] // []) end) as $hints
         | ([ $hints[] as $h | hintMatches($h; $ps)[] ] | unique) as $matched
         | ($s.reachedBy | strs | unique) as $reached
         | .[$s.surfaceId] = (if ($hints | length) > 0
             then {allowed: $matched, source: "adapter", reachedWithoutEvidence: ($reached - $matched)}
             else {allowed: $reached, source: "crawl", reachedWithoutEvidence: $reached} end)
             + {confirmed: false, hints: $hints, hintMatched: $matched}))}
  ' "$1"
}

jq_table() {
  jq -r --arg nohint "$NO_HINT" --arg rwetitle "$RWE_TITLE" "$JQ_DEFS"'
    accessIn
    | [ .surfaces | to_entries[] | {sid: .key, e: (.value + {hints: (.value.hints | strs)})} | . + {g: (.e | groupKey)} ] as $rows
    | (([ $rows[].g | select(. != $nohint) ] | unique) + (if any($rows[]; .g == $nohint) then [$nohint] else [] end)) as $groups
    | def cell: gsub("\\|"; "\\|");
      ([ "# Surface access",
         "",
         "Confirm who should reach each surface. Rows are grouped by the permission hint the stack declared. Decide per group (`byHint`, keyed by the heading) or per surface (`bySurface`), then run `surface-access.sh apply <surface-access.json> <decisions.json>`.",
         "", "## " + $rwetitle, "",
         "The crawl reached these surfaces as these roles, but no permission hint grants it. Decide each pair in `pairs` (`{surfaceId, persona, decision: \"allow\"|\"deny\"}`); a denied pair becomes a deny criterion." ]
       + ([ $rows | sort_by(.sid)[] | . as $r | (.e.reachedWithoutEvidence | strs)[]
            | "| `" + ($r.sid | cell) + "` | " + (. | cell) + " | "
              + (if ($r.e.hints | length) == 0 then "no hints on surface" else "no matching hint" end) + " |" ]
          | if length == 0 then ["", "None."] else ["", "| Surface | Persona | Why |", "|---|---|---|"] + . end)
       + [ $groups[] as $g
           | "", "## " + $g, "", "| Surface | Allowed | Source | Confirmed |", "|---|---|---|---|",
             ( [ $rows[] | select(.g == $g) ] | sort_by(.sid)[]
               | "| `" + (.sid | cell) + "` | "
                 + (if ((.e.allowed | strs) | length) == 0 then "(none)" else ((.e.allowed | strs) | join(", ") | cell) end)
                 + " | " + ((.e.source // "") | tostring | cell)
                 + " | " + (if .e.confirmed == true then "yes" else "no" end) + " |" ) ])
      | join("\n")
  ' "$1"
}

jq_apply() {
  jq -Sc --slurpfile d "$2" --arg nohint "$NO_HINT" "$JQ_DEFS"'
    accessIn
    | ($d[0]) as $dec
    | (if ($dec | type) == "object" then . else error("surface-access: decisions must be an object") end)
    | ($dec.byHint // {}) as $bh | ($dec.bySurface // {}) as $bs
    | (if ($bh | type) == "object" and ($bs | type) == "object" then . else error("surface-access: byHint/bySurface must be objects") end)
    | (if all(($bh, $bs) | to_entries[]; (.value | type) == "array" and all(.value[]; type == "string" and length > 0)) then .
       else error("surface-access: every decision must be an array of persona ids") end)
    | ($dec.pairs // []) as $pairs
    | (if ($pairs | type) == "array" and all($pairs[]; type == "object" and (.surfaceId | type) == "string" and (.persona | type) == "string"
                                              and (.decision == "allow" or .decision == "deny")) then .
       else error("surface-access: pairs must be [{surfaceId, persona, decision: allow|deny}]") end)
    | ([ .surfaces | to_entries[] | (.value + {hints: (.value.hints | strs)}) | groupKey ] | unique) as $known
    | (([ $bs | keys[] ] - [ .surfaces | keys[] ]) as $u | if ($u | length) > 0 then error("surface-access: unknown surfaceId in decisions: " + ($u | join(", "))) else . end)
    | (([ $bh | keys[] ] - $known) as $u | if ($u | length) > 0 then error("surface-access: unknown hint group in decisions: " + ($u | join(", "))) else . end)
    | .surfaces as $sv
    | ([ $pairs[] | . as $x
         | if ($sv[$x.surfaceId] | type) != "object" then "unknown surfaceId " + $x.surfaceId
           elif ($sv[$x.surfaceId].reachedWithoutEvidence | strs | index([$x.persona])) == null
             then "not a reached-without-evidence pair: " + $x.surfaceId + " / " + $x.persona
           elif ($bs[$x.surfaceId] != null) or ($bh[($sv[$x.surfaceId] + {hints: ($sv[$x.surfaceId].hints | strs)}) | groupKey] != null)
             then "pair conflicts with a whole-surface decision: " + $x.surfaceId
           else empty end ] | .[0]) as $bad
    | (if $bad == null then . else error("surface-access: " + $bad) end)
    | .surfaces |= with_entries(
        .key as $sid
        | (.value + {hints: (.value.hints | strs)}) as $e
        | ($bs[$sid] // $bh[$e | groupKey] // null) as $pick
        | [ $pairs[] | select(.surfaceId == $sid) ] as $mine
        | if $pick != null then .value = ($e + {allowed: ($pick | unique), source: "human", confirmed: true, reachedWithoutEvidence: []})
          elif ($mine | length) > 0 then
            ([ $mine[] | select(.decision == "allow") | .persona ]) as $A
            | ([ $mine[] | select(.decision == "deny") | .persona ]) as $D
            | (($e.reachedWithoutEvidence | strs) - $A - $D) as $left
            | .value = ($e + {allowed: ((($e.allowed | strs) + $A) - $D | unique), reachedWithoutEvidence: $left,
                              source: "human", confirmed: (($left | length) == 0)})
          else . end)
  ' "$1"
}

# ---------------------------------------------------------------- python3
PY_DEFS='
import json, re, sys
NOHINT = "(no permission hint)"
def die(m): sys.stderr.write("ERROR: " + m + "\n"); sys.exit(1)
def load(p, what):
    try:
        with open(p, encoding="utf-8") as f: return json.load(f)
    except Exception: die("surface-access: invalid JSON in " + what + ": " + p)
def dump(o): print(json.dumps(o, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
def strs(v): return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []
def personas(p):
    if isinstance(p, dict) and isinstance(p.get("personas"), list): p = p["personas"]
    if not isinstance(p, list): die("surface-access: personas must be an array or {personas:[...]}")
    if not all(isinstance(x, dict) and isinstance(x.get("id"), str) for x in p): die("surface-access: every persona needs a string id")
    return p
def trim(s): return re.sub(r"\s+$", "", re.sub(r"^\s+", "", s))
def hint_matches(h, ps):
    i = h.find(":")
    if i < 0: k, v = ("none" if h in ("auth", "guest", "verified", "web", "api") else "role", h)
    else: k, v = h[:i], h[i+1:]
    vals = [x for x in (trim(x) for x in re.split(r"[|,]", v)) if len(x) > 0]
    out = []
    for x in ps:
        if k in ("role", "roles"):
            names = [x.get("id"), x.get("role")] + strs(x.get("roles"))
            if any(val in names for val in vals): out.append(x["id"])
        elif k in ("can", "permission", "permissions", "ability", "gate"):
            perms = strs(x.get("permissions"))
            if "*" in perms or any(val in perms for val in vals): out.append(x["id"])
    return out
def group_key(e): return NOHINT if len(e["hints"]) == 0 else ", ".join(e["hints"])
def access_in(a):
    if not (isinstance(a, dict) and isinstance(a.get("surfaces"), dict)): die("surface-access: surface-access.json needs a surfaces object")
    return a
'

py_derive() {
  python3 -c "$PY_DEFS"'
c = load(sys.argv[1], "census")
if not (isinstance(c, dict) and isinstance(c.get("surfaces"), list)): die("surface-access: census needs a surfaces array")
ps = personas(load(sys.argv[2], "personas"))
ad_hints = {}
if sys.argv[3]:
    ad = load(sys.argv[3], "adapter")
    for s in (ad.get("surfaces") or []) if isinstance(ad, dict) else []:
        if isinstance(s, dict) and isinstance(s.get("surfaceId"), str): ad_hints[s["surfaceId"]] = strs(s.get("permissionHints"))
surfaces = {}
for s in c["surfaces"]:
    if not (isinstance(s, dict) and isinstance(s.get("surfaceId"), str)): continue
    hints = strs(s["permissionHints"]) if isinstance(s.get("permissionHints"), list) else ad_hints.get(s["surfaceId"], [])
    matched = sorted(set(pid for h in hints for pid in hint_matches(h, ps)))
    reached = sorted(set(strs(s.get("reachedBy"))))
    if hints: e = {"allowed": matched, "source": "adapter", "reachedWithoutEvidence": [x for x in reached if x not in matched]}
    else: e = {"allowed": reached, "source": "crawl", "reachedWithoutEvidence": reached}
    e.update({"confirmed": False, "hints": hints, "hintMatched": matched})
    surfaces[s["surfaceId"]] = e
dump({"version": 1, "surfaces": surfaces})
' "$1" "$2" "$3"
}

py_table() {
  python3 -c "$PY_DEFS"'
a = access_in(load(sys.argv[1], "surface-access"))
rows = []
for sid, v in a["surfaces"].items():
    e = dict(v) if isinstance(v, dict) else {}
    e["hints"] = strs(e.get("hints"))
    rows.append({"sid": sid, "e": e, "g": group_key(e)})
groups = sorted(set(r["g"] for r in rows if r["g"] != NOHINT)) + ([NOHINT] if any(r["g"] == NOHINT for r in rows) else [])
def cell(s): return s.replace("|", "\\|")
def tostr(v): return v if isinstance(v, str) else json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
lines = ["# Surface access", "",
         "Confirm who should reach each surface. Rows are grouped by the permission hint the stack declared. Decide per group (`byHint`, keyed by the heading) or per surface (`bySurface`), then run `surface-access.sh apply <surface-access.json> <decisions.json>`.",
         "", "## " + sys.argv[2], "",
         "The crawl reached these surfaces as these roles, but no permission hint grants it. Decide each pair in `pairs` (`{surfaceId, persona, decision: \"allow\"|\"deny\"}`); a denied pair becomes a deny criterion."]
rwe = []
for r in sorted(rows, key=lambda r: r["sid"]):
    for pp in strs(r["e"].get("reachedWithoutEvidence")):
        rwe.append("| `" + cell(r["sid"]) + "` | " + cell(pp) + " | " + ("no hints on surface" if len(r["e"]["hints"]) == 0 else "no matching hint") + " |")
lines += ["", "None."] if not rwe else ["", "| Surface | Persona | Why |", "|---|---|---|"] + rwe
for g in groups:
    lines += ["", "## " + g, "", "| Surface | Allowed | Source | Confirmed |", "|---|---|---|---|"]
    for r in sorted((r for r in rows if r["g"] == g), key=lambda r: r["sid"]):
        al = strs(r["e"].get("allowed"))
        lines.append("| `" + cell(r["sid"]) + "` | " + ("(none)" if not al else cell(", ".join(al)))
                     + " | " + cell(tostr(r["e"].get("source") if r["e"].get("source") is not None else ""))
                     + " | " + ("yes" if r["e"].get("confirmed") is True else "no") + " |")
print("\n".join(lines))
' "$1" "$RWE_TITLE"
}

py_apply() {
  python3 -c "$PY_DEFS"'
a = access_in(load(sys.argv[1], "surface-access"))
dec = load(sys.argv[2], "decisions")
if not isinstance(dec, dict): die("surface-access: decisions must be an object")
bh = dec.get("byHint") if dec.get("byHint") is not None else {}
bs = dec.get("bySurface") if dec.get("bySurface") is not None else {}
if not (isinstance(bh, dict) and isinstance(bs, dict)): die("surface-access: byHint/bySurface must be objects")
for d in (bh, bs):
    for v in d.values():
        if not (isinstance(v, list) and all(isinstance(x, str) and len(x) > 0 for x in v)): die("surface-access: every decision must be an array of persona ids")
def norm(v):
    e = dict(v) if isinstance(v, dict) else {}
    e["hints"] = strs(e.get("hints")); return e
known = set(group_key(norm(v)) for v in a["surfaces"].values())
u = sorted(k for k in bs if k not in a["surfaces"])
if u: die("surface-access: unknown surfaceId in decisions: " + ", ".join(u))
u = sorted(k for k in bh if k not in known)
if u: die("surface-access: unknown hint group in decisions: " + ", ".join(u))
pairs = dec.get("pairs") if dec.get("pairs") is not None else []
if not (isinstance(pairs, list) and all(isinstance(x, dict) and isinstance(x.get("surfaceId"), str) and isinstance(x.get("persona"), str)
                                        and x.get("decision") in ("allow", "deny") for x in pairs)):
    die("surface-access: pairs must be [{surfaceId, persona, decision: allow|deny}]")
sv = a["surfaces"]
for x in pairs:
    v = sv.get(x["surfaceId"])
    if not isinstance(v, dict): die("surface-access: unknown surfaceId " + x["surfaceId"])
    if x["persona"] not in strs(v.get("reachedWithoutEvidence")):
        die("surface-access: not a reached-without-evidence pair: " + x["surfaceId"] + " / " + x["persona"])
    if x["surfaceId"] in bs or bh.get(group_key(norm(v))) is not None:
        die("surface-access: pair conflicts with a whole-surface decision: " + x["surfaceId"])
out = {}
for sid, v in a["surfaces"].items():
    e = norm(v)
    pick = bs.get(sid) if sid in bs else bh.get(group_key(e))
    mine = [x for x in pairs if x["surfaceId"] == sid]
    if pick is not None:
        e.update({"allowed": sorted(set(pick)), "source": "human", "confirmed": True, "reachedWithoutEvidence": []}); out[sid] = e
    elif mine:
        A = [x["persona"] for x in mine if x["decision"] == "allow"]
        D = [x["persona"] for x in mine if x["decision"] == "deny"]
        left = [x for x in strs(e.get("reachedWithoutEvidence")) if x not in A and x not in D]
        e.update({"allowed": sorted(set(x for x in strs(e.get("allowed")) + A if x not in D)), "reachedWithoutEvidence": left,
                  "source": "human", "confirmed": len(left) == 0}); out[sid] = e
    else: out[sid] = v
a = dict(a); a["surfaces"] = out
dump(a)
' "$1" "$2"
}

# ---------------------------------------------------------------- dispatch
has_jq || has_py || die "surface-access: needs jq or python3"
case "$cmd" in
  derive)
    [ "$#" -ge 2 ] || die "$usage"
    census="$1"; personas="$2"; shift 2; adapter=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --adapter) [ "$#" -ge 2 ] || die "$usage"; adapter="$2"; shift 2 ;;
        *) die "$usage" ;;
      esac
    done
    for f in "$census" "$personas" ${adapter:+"$adapter"}; do [ -f "$f" ] || die "surface-access: file not found: $f"; done
    if has_jq; then out="$(jq_derive "$census" "$personas" "$adapter")" || die "surface-access: derive failed (malformed input)"
    else out="$(py_derive "$census" "$personas" "$adapter")" || exit 1; fi ;;
  confirm-table)
    [ "$#" -eq 1 ] || die "$usage"; [ -f "$1" ] || die "surface-access: file not found: $1"
    if has_jq; then out="$(jq_table "$1")" || die "surface-access: confirm-table failed (malformed surface-access.json)"
    else out="$(py_table "$1")" || exit 1; fi ;;
  apply)
    [ "$#" -eq 2 ] || die "$usage"
    for f in "$1" "$2"; do [ -f "$f" ] || die "surface-access: file not found: $f"; done
    if has_jq; then out="$(jq_apply "$1" "$2")" || die "surface-access: apply failed (see the error above)"
    else out="$(py_apply "$1" "$2")" || exit 1; fi ;;
  *) die "$usage" ;;
esac
printf '%s\n' "$out"
