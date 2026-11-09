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
#       hints:[...]}}}, one entry per census surface.
#         hints   = the census surface's own `permissionHints` when present, else the adapter's
#                   `permissionHints` for the same surfaceId (census.sh does not carry them), else [].
#         allowed = sorted union of (personas a hint matches) and the surface's crawl `reachedBy`.
#         source  = "adapter" when hints is non-empty, else "crawl".
#       Hint matching (exact, case-sensitive):
#         role:<a>|<b> / roles:<a>,<b> / a bare hint "<a>"  -> persona `id`, `role` or `roles[]` equals one
#         can:<p> / permission(s):<p> / ability:<p> / gate:<p> -> persona `permissions[]` holds <p> or "*"
#         any other prefix (auth, guest, verified, ...)    -> matches no persona (the human decides)
#       personas.json is an array of personas or {personas:[...]}; each needs a string `id`.
#   surface-access.sh confirm-table <surface-access.json>
#       Prints a Markdown table, one `## <hints joined by ", ">` section per hint group (sorted; the
#       "(no permission hint)" group last), rows sorted by surfaceId.
#   surface-access.sh apply <surface-access.json> <decisions.json>
#       decisions.json = {byHint?:{<group heading>:[personaId]}, bySurface?:{<surfaceId>:[personaId]}}.
#       bySurface wins over byHint. Each decided surface gets allowed = the sorted, deduplicated list,
#       source:"human", confirmed:true; undecided surfaces are unchanged. An unknown surfaceId or hint
#       group, or a non-array decision, exits 1 (a typo must not silently confirm nothing).
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
  | (if $i == null then {k: "role", v: $h} else {k: $h[0:$i], v: $h[$i+1:]} end) as $p
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
         | ([ $hints[] as $h | hintMatches($h; $ps)[] ] + ($s.reachedBy | strs) | unique) as $allowed
         | .[$s.surfaceId] = {allowed: $allowed, source: (if ($hints | length) > 0 then "adapter" else "crawl" end),
                              confirmed: false, hints: $hints}))}
  ' "$1"
}

jq_table() {
  jq -r --arg nohint "$NO_HINT" "$JQ_DEFS"'
    accessIn
    | [ .surfaces | to_entries[] | {sid: .key, e: (.value + {hints: (.value.hints | strs)})} | . + {g: (.e | groupKey)} ] as $rows
    | (([ $rows[].g | select(. != $nohint) ] | unique) + (if any($rows[]; .g == $nohint) then [$nohint] else [] end)) as $groups
    | def cell: gsub("\\|"; "\\|");
      ([ "# Surface access",
         "",
         "Confirm who should reach each surface. Rows are grouped by the permission hint the stack declared. Decide per group (`byHint`, keyed by the heading) or per surface (`bySurface`), then run `surface-access.sh apply <surface-access.json> <decisions.json>`." ]
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
    | ([ .surfaces | to_entries[] | (.value + {hints: (.value.hints | strs)}) | groupKey ] | unique) as $known
    | (([ $bs | keys[] ] - [ .surfaces | keys[] ]) as $u | if ($u | length) > 0 then error("surface-access: unknown surfaceId in decisions: " + ($u | join(", "))) else . end)
    | (([ $bh | keys[] ] - $known) as $u | if ($u | length) > 0 then error("surface-access: unknown hint group in decisions: " + ($u | join(", "))) else . end)
    | .surfaces |= with_entries(
        .key as $sid
        | (.value + {hints: (.value.hints | strs)}) as $e
        | ($bs[$sid] // $bh[$e | groupKey] // null) as $pick
        | if $pick == null then . else .value = ($e + {allowed: ($pick | unique), source: "human", confirmed: true}) end)
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
    k, v = ("role", h) if i < 0 else (h[:i], h[i+1:])
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
    allowed = sorted(set([pid for h in hints for pid in hint_matches(h, ps)] + strs(s.get("reachedBy"))))
    surfaces[s["surfaceId"]] = {"allowed": allowed, "source": "adapter" if hints else "crawl", "confirmed": False, "hints": hints}
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
         "Confirm who should reach each surface. Rows are grouped by the permission hint the stack declared. Decide per group (`byHint`, keyed by the heading) or per surface (`bySurface`), then run `surface-access.sh apply <surface-access.json> <decisions.json>`."]
for g in groups:
    lines += ["", "## " + g, "", "| Surface | Allowed | Source | Confirmed |", "|---|---|---|---|"]
    for r in sorted((r for r in rows if r["g"] == g), key=lambda r: r["sid"]):
        al = strs(r["e"].get("allowed"))
        lines.append("| `" + cell(r["sid"]) + "` | " + ("(none)" if not al else cell(", ".join(al)))
                     + " | " + cell(tostr(r["e"].get("source") if r["e"].get("source") is not None else ""))
                     + " | " + ("yes" if r["e"].get("confirmed") is True else "no") + " |")
print("\n".join(lines))
' "$1"
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
out = {}
for sid, v in a["surfaces"].items():
    e = norm(v)
    pick = bs.get(sid) if sid in bs else bh.get(group_key(e))
    if pick is None: out[sid] = v
    else:
        e.update({"allowed": sorted(set(pick)), "source": "human", "confirmed": True}); out[sid] = e
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
