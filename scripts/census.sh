#!/usr/bin/env bash
# census.sh — merge a stack adapter's surfaces with the per-role crawl output into census.json
# and compute the diffs between what the code declares and what each persona actually reached.
# Pure, dual-engine (jq | python3, byte-identical output).
#
# USAGE:
#   census.sh build --adapter <adapter.json> --crawl <crawl-dir> [--access <surface-access.json>] --out <census.json>
#
# INPUTS:
#   adapter.json   adapters/census/<stack>.sh stdout: {adapter, ok, surfaces:[{surfaceId, kind, pattern,
#                  method, permissionHints, source}], jobs, mails, notifications, locales, warnings}
#                  or, on failure, {adapter, ok:false, error}.
#   crawl-dir      one crawl-<personaId>.json per role: {personaId, visits:[{url, routeMatch?, kind,
#                  subKey?, status, findings, forms}], unexplored:[{url, reason}]}.
#   access.json    surface-access.json: {version, surfaces:{<surfaceId>:{allowed:[personaId], source, confirmed}}}.
#
# OUTPUT (compact, keys sorted, raw UTF-8):
#   {version:1, adapter, adapterOk, surfaces:[{surfaceId, kind, pattern, sources, reachedBy, sampleUrls,
#    allowed, forms}],
#    jobs, mails, notifications, warnings, diffs:{unreachable, overreach:[{surfaceId, personaId}], crawlOnly}}
#
# RULES:
#   - A visit URL (origin, query and fragment dropped) maps to the adapter GET surface whose pattern
#     matches segment by segment; `{param}` matches any one segment, a trailing `{param?}` may be absent,
#     a trailing catch-all `{param*}` matches one or more segments and `{param*?}` zero or more.
#     The most literal segments wins (`/x/create` beats `/x/{id}`), ties broken by surfaceId.
#     Segments compare as recorded (no percent-decoding), so raw and encoded Arabic both match a param.
#   - A visit's `routeMatch` that names an adapter surface (e.g. `page:<component>`) reaches it too.
#   - A visit with neither match is crawl-only: surfaceId = routeMatch, else `GET <path>`.
#   - A persona REACHED a surface when the visit status is absent, < 300, or >= 500 (5xx = got in,
#     then crashed). 3xx/4xx visits are recorded as sources but never count as reached, and their
#     forms are dropped (a surface's forms come only from visits that reached it).
#   - sampleUrls: {<personaId>: <path?query>} — the first reached visit's URL per persona, origin and
#     fragment dropped, query kept. Row actions open these, never a `{param}` pattern. {} when none.
#   - A `tab`/`dialog`/`sheet` visit with a non-empty `subKey` is its own surface
#     `<parent>#<kind>:<slug(subKey)>` (slug: ASCII-lowercase, whitespace runs -> '-', drop all but
#     [a-z0-9], Arabic U+0600-U+06FF and '-', collapse '-', trim '-'). parent = the visit's
#     routeMatch when it names an adapter surface, else its best GET match, else its crawl-only id.
#     kind = the visit kind, pattern = the parent's, sources ["crawl"], same reachedBy rule,
#     sampleUrls = the parent's (the sub-surface's own fill personas the parent lacks). It carries
#     its visit's forms; it never counts toward its page. Without a subKey the visit is its page.
#   - unreachable: adapter GET or page:* surfaces nobody reached. Non-GET endpoints and
#     tab/dialog/sheet surfaces never are.
#   - overreach: only with --access (read with --slurpfile, any size); persona in reachedBy but not in
#     that surface's `allowed`.
#   - crawlOnly: crawl-only surfaces, plus tab/dialog/sheet surfaces whose parent is crawl-only.
#   - Adapter ok != true: census is built from the crawl alone, adapterOk:false, and warnings carry
#     `adapter-failed: <stack>: <error>` (never a silent empty census).
#
# EXIT: 0 census written; 1 usage / missing or malformed input.
# DEPENDENCIES: bash (3.2-safe), coreutils, EITHER jq OR python3 (jq preferred). QA_ENGINE=jq|python3 forces one.
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

USAGE="usage: census.sh build --adapter <adapter.json> --crawl <crawl-dir> [--access <surface-access.json>] --out <census.json>"
[ "$#" -ge 1 ] || die "$USAGE"
[ "$1" = "build" ] || die "$USAGE"
shift
ADAPTER=""; CRAWL=""; ACCESS=""; OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --adapter) [ "$#" -ge 2 ] || die "$USAGE"; ADAPTER="$2"; shift 2 ;;
    --crawl)   [ "$#" -ge 2 ] || die "$USAGE"; CRAWL="$2"; shift 2 ;;
    --access)  [ "$#" -ge 2 ] || die "$USAGE"; ACCESS="$2"; shift 2 ;;
    --out)     [ "$#" -ge 2 ] || die "$USAGE"; OUT="$2"; shift 2 ;;
    *) die "census: unknown argument: $1" ;;
  esac
done
[ -n "$ADAPTER" ] && [ -n "$CRAWL" ] && [ -n "$OUT" ] || die "$USAGE"
[ -f "$ADAPTER" ] || die "census: adapter file not found: $ADAPTER"
[ -d "$CRAWL" ] || die "census: crawl dir not found: $CRAWL"
[ -z "$ACCESS" ] || [ -f "$ACCESS" ] || die "census: access file not found: $ACCESS"

FILES=()
for f in "$CRAWL"/crawl-*.json; do
  [ -f "$f" ] && FILES+=("$f")
done

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

if has_jq; then
  jq -e 'type == "object"' "$ADAPTER" >/dev/null 2>&1 || die "census: adapter is not a JSON object: $ADAPTER"
  ACCESS_FILE=/dev/null
  if [ -n "$ACCESS" ]; then
    jq -e '(.surfaces | type) == "object"' "$ACCESS" >/dev/null 2>&1 || die "census: access has no surfaces object: $ACCESS"
    ACCESS_FILE="$ACCESS"
  fi
  NOCRAWL="false"
  if [ "${#FILES[@]}" -eq 0 ]; then NOCRAWL="true"; FILES=(/dev/null); fi
  jq -n -S -c --slurpfile ad "$ADAPTER" --slurpfile acc "$ACCESS_FILE" --argjson nocrawl "$NOCRAWL" '
    def segs: sub("^[A-Za-z][A-Za-z0-9+.-]*://[^/]*"; "") | sub("[?#].*$"; "") | [split("/")[] | select(length > 0)];
    def sample: sub("^[A-Za-z][A-Za-z0-9+.-]*://[^/]*"; "") | sub("#.*$"; "") | if startswith("/") then . else "/" + . end;
    def psegs: [split("/")[] | select(length > 0)];
    def isparam: test("^\\{[^}]+\\}$");
    def isopt: test("^\\{[^}]+\\?\\}$");
    def isstar: test("^\\{[^}]+\\*\\??\\}$");
    def isoptstar: test("^\\{[^}]+\\*\\?\\}$");
    def slug: ascii_downcase | gsub("[ \t\n\r\f\u000b]+"; "-") | gsub("[^a-z0-9؀-ۿ-]"; "") | gsub("-+"; "-") | gsub("^-|-$"; "");
    def isget: ((.method // "") | if type == "string" then ascii_upcase | split("|") | index("GET") != null else false end);
    def prefixok($p; $u): [range(0; $p | length) as $i | if ($p[$i] | isparam) then true else $p[$i] == $u[$i] end] | all;
    def score($u): ((.pattern // "") | if type == "string" then psegs else [] end) as $p
      | if ($p | length) > 0 and ($p[-1] | isstar) then
          $p[0:(($p | length) - 1)] as $pre
          | if ($u | length) < (($pre | length) + (if ($p[-1] | isoptstar) then 0 else 1 end)) then null
            elif prefixok($pre; $u) then ([$pre[] | select(isparam | not)] | length)
            else null end
        elif ($u | length) > ($p | length) then null
        elif ([$p[($u | length):][] | isopt | not] | any) then null
        elif prefixok($p[0:($u | length)]; $u)
          then ([$p[0:($u | length)][] | select(isparam | not)] | length)
        else null end;
    def reached: .status as $s | ($s == null) or (($s | type) != "number") or $s < 300 or $s >= 500;

    $ad[0] as $a
    | ($acc[0] // null) as $access
    | ($a.ok == true) as $ok
    | (if $ok then [($a.surfaces // [])[] | select(type == "object" and (.surfaceId | type) == "string")] else [] end) as $asurf
    | [$asurf[] | select(isget)] as $gets
    | ([$asurf[] | .surfaceId]) as $aids
    | ([$asurf[] | {key: .surfaceId, value: (.pattern // null)}] | from_entries) as $apat
    | [ inputs
        | (.personaId // (input_filename | split("/") | last | sub("^crawl-"; "") | sub("\\.json$"; ""))) as $pid
        | (.visits // [])[]
        | . as $v
        | ((.url // "") | segs) as $u
        | ("/" + ($u | join("/"))) as $path
        | ((.url // "") | sample) as $url
        | ([$gets[] | {id: .surfaceId, sc: score($u)} | select(.sc != null)] | sort_by(-.sc, .id) | (first // null)) as $best
        | (($v.routeMatch | type) == "string" and ($aids | index($v.routeMatch)) != null) as $rmA
        | ((if $best != null then [$best.id] else [] end)
           + (if $rmA and $v.routeMatch != ($best.id // null) then [$v.routeMatch] else [] end)) as $hits
        | (if $rmA then $v.routeMatch elif $best != null then $best.id
           elif ($v.routeMatch | type) == "string" and ($v.routeMatch | length) > 0 then $v.routeMatch
           else "GET " + $path end) as $parent
        | (if (["tab", "dialog", "sheet"] | index([$v.kind])) != null and ($v.subKey | type) == "string"
           then ($v.subKey | slug) else "" end) as $sk
        | if $sk != "" then
            {id: ($parent + "#" + $v.kind + ":" + $sk), persona: $pid, reached: ($v | reached), forms: ($v.forms // []),
             url: $url, crawlOnly: false, sub: true, parent: $parent, parentCrawlOnly: (($hits | length) == 0),
             kind: $v.kind, pattern: (if ($hits | length) > 0 then $apat[$parent] else $path end)}
          elif ($hits | length) > 0 then
            ($hits[] | {id: ., persona: $pid, reached: ($v | reached), forms: ($v.forms // []), url: $url, crawlOnly: false, sub: false})
          else
            {id: $parent, persona: $pid, reached: ($v | reached), forms: ($v.forms // []), url: $url, crawlOnly: true, sub: false,
             kind: ($v.kind // null), pattern: $path}
          end
      ] as $recs
    | def samples($id): reduce ($recs[] | select(.id == $id and .reached)) as $x ({};
          if has($x.persona) then . else .[$x.persona] = $x.url end);
      def build($id; $base; $fromAdapter; $sampleUrls):
        [$recs[] | select(.id == $id)] as $r
        | {surfaceId: $id, kind: $base.kind, pattern: $base.pattern,
           sources: ((if $fromAdapter then ["adapter"] else [] end) + (if ($r | length) > 0 then ["crawl"] else [] end)),
           reachedBy: ([$r[] | select(.reached) | .persona] | unique),
           sampleUrls: $sampleUrls,
           allowed: (if $access == null then null else ($access.surfaces[$id].allowed // null) end),
           forms: ([$r[] | select(.reached) | .forms[]] | unique_by(.formId))};
      ([$asurf[] | . as $s | build($s.surfaceId; {kind: ($s.kind // null), pattern: ($s.pattern // null)}; true; samples($s.surfaceId))
        + {_reachable: (($s.surfaceId | startswith("page:")) or ($s | isget))}]) as $fromA
    | ([$recs[] | select(.crawlOnly and (.sub | not)) | .id] | unique) as $coids
    | ([$coids[] as $id | ([$recs[] | select(.crawlOnly and .id == $id)] | first) as $f
        | build($id; {kind: $f.kind, pattern: $f.pattern}; false; samples($id)) + {_reachable: false}]) as $fromC
    | ([$recs[] | select(.sub) | .id] | unique) as $subids
    | ([$subids[] as $id | ([$recs[] | select(.sub and .id == $id)] | first) as $f
        | build($id; {kind: $f.kind, pattern: $f.pattern}; false; (samples($id) + samples($f.parent)))
        + {_reachable: false, _crawlOnly: $f.parentCrawlOnly}]) as $fromS
    | (($fromA + $fromC + $fromS) | sort_by(.surfaceId)) as $all
    | {version: 1,
       adapter: ($a.adapter // null),
       adapterOk: $ok,
       surfaces: [$all[] | del(._reachable, ._crawlOnly)],
       jobs: (if $ok then ($a.jobs // []) else [] end),
       mails: (if $ok then ($a.mails // []) else [] end),
       notifications: (if $ok then ($a.notifications // []) else [] end),
       warnings: (($a.warnings // [])
         + (if $ok then [] else ["adapter-failed: " + (($a.adapter // "unknown") | tostring) + ": " + (($a.error // "no error message") | tostring)] end)
         + (if $nocrawl then ["crawl: no crawl-<personaId>.json files found"] else [] end)),
       diffs: {
         unreachable: [$all[] | select(._reachable and (.reachedBy | length) == 0) | .surfaceId],
         overreach: (if $access == null then [] else
           [$all[] | select((.allowed | type) == "array") | . as $s | .reachedBy[]
             | select(. as $p | ($s.allowed | index($p)) == null) | {surfaceId: $s.surfaceId, personaId: .}] end),
         crawlOnly: (($coids + [$fromS[] | select(._crawlOnly) | .surfaceId]) | sort)}}
  ' "${FILES[@]}" > "$TMP" 2>/dev/null || die "census: jq failed (malformed adapter, access or crawl JSON)."
elif has_py; then
  python3 - "$ADAPTER" "$ACCESS" "$TMP" ${FILES[@]+"${FILES[@]}"} <<'PY' || exit 1
import json, os, re, sys

def die(msg):
    sys.stderr.write("ERROR: " + msg + "\n"); sys.exit(1)

def load(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        die("census: malformed %s JSON: %s" % (what, path))

adapter_path, access_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
files = sys.argv[4:]
a = load(adapter_path, "adapter")
if not isinstance(a, dict): die("census: adapter is not a JSON object: " + adapter_path)
access = None
if access_path:
    access = load(access_path, "access")
    if not isinstance(access, dict) or not isinstance(access.get("surfaces"), dict):
        die("census: access has no surfaces object: " + access_path)

ORIGIN = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]*")
TAIL = re.compile(r"[?#].*$", re.S)
PARAM = re.compile(r"^\{[^}]+\}$")
OPT = re.compile(r"^\{[^}]+\?\}$")
STAR = re.compile(r"^\{[^}]+\*\??\}$")
OPTSTAR = re.compile(r"^\{[^}]+\*\?\}$")
FRAG = re.compile(r"#.*$", re.S)

def sample(s):
    s = FRAG.sub("", ORIGIN.sub("", s, count=1), count=1)
    return s if s.startswith("/") else "/" + s

def slug(s):
    s = re.sub(r"[A-Z]", lambda m: m.group(0).lower(), s)
    s = re.sub("[ \t\n\r\f\v]+", "-", s)
    s = re.sub("[^a-z0-9\u0600-\u06ff-]", "", s)
    s = re.sub("-+", "-", s)
    return re.sub("^-|-$", "", s)

def segs(s):
    s = TAIL.sub("", ORIGIN.sub("", s, count=1), count=1)
    return [x for x in s.split("/") if len(x) > 0]

def isget(s):
    m = s.get("method")
    return isinstance(m, str) and "GET" in m.upper().split("|")

def prefixok(p, u):
    for i in range(len(p)):
        if not PARAM.search(p[i]) and p[i] != u[i]: return False
    return True

def score(s, u):
    p = s.get("pattern")
    p = [x for x in p.split("/") if len(x) > 0] if isinstance(p, str) else []
    if p and STAR.search(p[-1]):
        pre = p[:-1]
        if len(u) < len(pre) + (0 if OPTSTAR.search(p[-1]) else 1): return None
        if not prefixok(pre, u): return None
        return sum(1 for x in pre if not PARAM.search(x))
    if len(u) > len(p): return None
    if any(not OPT.search(x) for x in p[len(u):]): return None
    for i in range(len(u)):
        if not PARAM.search(p[i]) and p[i] != u[i]: return None
    return sum(1 for x in p[:len(u)] if not PARAM.search(x))

def reached(v):
    st = v.get("status")
    if st is None or isinstance(st, bool) or not isinstance(st, (int, float)): return True
    return st < 300 or st >= 500

def nn(v, d):
    return d if v is None or v is False else v

ok = a.get("ok") is True
asurf = [s for s in (nn(a.get("surfaces"), []) if ok else []) if isinstance(s, dict) and isinstance(s.get("surfaceId"), str)]
gets = [s for s in asurf if isget(s)]
aids = [s["surfaceId"] for s in asurf]
apat = {}
for s in asurf: apat[s["surfaceId"]] = nn(s.get("pattern"), None)

recs = []
for f in files:
    c = load(f, "crawl")
    if not isinstance(c, dict): die("census: crawl file is not a JSON object: " + f)
    pid = nn(c.get("personaId"), None)
    if pid is None:
        pid = re.sub(r"\.json$", "", re.sub(r"^crawl-", "", os.path.basename(f), count=1), count=1)
    for v in nn(c.get("visits"), []):
        u = segs(nn(v.get("url"), ""))
        path = "/" + "/".join(u)
        url = sample(nn(v.get("url"), ""))
        cands = [(s["surfaceId"], score(s, u)) for s in gets]
        cands = sorted([(sid, sc) for sid, sc in cands if sc is not None], key=lambda t: (-t[1], t[0]))
        best = cands[0][0] if cands else None
        hits = [best] if best is not None else []
        rm = v.get("routeMatch")
        rm_a = isinstance(rm, str) and rm in aids
        if rm_a and rm != best:
            hits.append(rm)
        if rm_a: parent = rm
        elif best is not None: parent = best
        elif isinstance(rm, str) and len(rm) > 0: parent = rm
        else: parent = "GET " + path
        forms = nn(v.get("forms"), [])
        kind = v.get("kind")
        sk = slug(v["subKey"]) if kind in ("tab", "dialog", "sheet") and isinstance(v.get("subKey"), str) else ""
        if sk != "":
            recs.append({"id": parent + "#" + kind + ":" + sk, "persona": pid, "reached": reached(v), "forms": forms,
                         "url": url, "crawlOnly": False, "sub": True, "parent": parent, "parentCrawlOnly": not hits,
                         "kind": kind, "pattern": apat.get(parent) if hits else path})
        elif hits:
            for h in hits:
                recs.append({"id": h, "persona": pid, "reached": reached(v), "forms": forms, "url": url,
                             "crawlOnly": False, "sub": False})
        else:
            recs.append({"id": parent, "persona": pid, "reached": reached(v), "forms": forms, "url": url,
                         "crawlOnly": True, "sub": False, "kind": nn(kind, None), "pattern": path})

def jkey(x):
    # jq ordering for the keys we sort on: null < booleans < numbers < strings
    if x is None: return (0, 0)
    if isinstance(x, bool): return (1, x)
    if isinstance(x, (int, float)): return (2, x)
    return (3, x)

def unique_forms(forms):
    seen = {}
    order = []
    for fm in forms:
        k = fm.get("formId") if isinstance(fm, dict) else None
        kk = json.dumps(k, sort_keys=True, ensure_ascii=False)
        if kk not in seen:
            seen[kk] = fm; order.append((k, fm))
    return [fm for k, fm in sorted(order, key=lambda t: jkey(t[0]))]

def samples(sid):
    out = {}
    for x in recs:
        if x["id"] == sid and x["reached"] and x["persona"] not in out:
            out[x["persona"]] = x["url"]
    return out

def build(sid, kind, pattern, from_adapter, sample_urls):
    r = [x for x in recs if x["id"] == sid]
    allowed = None
    if access is not None:
        ent = access["surfaces"].get(sid)
        allowed = nn(ent.get("allowed"), None) if isinstance(ent, dict) else None
    forms = []
    for x in r:
        if x["reached"]: forms.extend(x["forms"])
    return {"surfaceId": sid, "kind": kind, "pattern": pattern,
            "sources": (["adapter"] if from_adapter else []) + (["crawl"] if r else []),
            "reachedBy": sorted(set(x["persona"] for x in r if x["reached"])),
            "sampleUrls": sample_urls,
            "allowed": allowed, "forms": unique_forms(forms)}

alls = []
for s in asurf:
    b = build(s["surfaceId"], nn(s.get("kind"), None), nn(s.get("pattern"), None), True, samples(s["surfaceId"]))
    alls.append((b, s["surfaceId"].startswith("page:") or isget(s)))
coids = sorted(set(x["id"] for x in recs if x["crawlOnly"] and not x["sub"]))
for cid in coids:
    first = next(x for x in recs if x["crawlOnly"] and x["id"] == cid)
    alls.append((build(cid, first["kind"], first["pattern"], False, samples(cid)), False))
sub_crawl_only = []
for sid in sorted(set(x["id"] for x in recs if x["sub"])):
    first = next(x for x in recs if x["sub"] and x["id"] == sid)
    su = samples(sid); su.update(samples(first["parent"]))
    alls.append((build(sid, first["kind"], first["pattern"], False, su), False))
    if first["parentCrawlOnly"]: sub_crawl_only.append(sid)
alls.sort(key=lambda t: t[0]["surfaceId"])

warnings = list(nn(a.get("warnings"), []))
if not ok:
    def ts(x): return x if isinstance(x, str) else json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    warnings.append("adapter-failed: " + ts(nn(a.get("adapter"), "unknown")) + ": " + ts(nn(a.get("error"), "no error message")))
if not files:
    warnings.append("crawl: no crawl-<personaId>.json files found")

overreach = []
if access is not None:
    for b, _ in alls:
        if isinstance(b["allowed"], list):
            for p in b["reachedBy"]:
                if p not in b["allowed"]:
                    overreach.append({"surfaceId": b["surfaceId"], "personaId": p})

out = {"version": 1,
       "adapter": nn(a.get("adapter"), None),
       "adapterOk": ok,
       "surfaces": [b for b, _ in alls],
       "jobs": nn(a.get("jobs"), []) if ok else [],
       "mails": nn(a.get("mails"), []) if ok else [],
       "notifications": nn(a.get("notifications"), []) if ok else [],
       "warnings": warnings,
       "diffs": {"unreachable": [b["surfaceId"] for b, r in alls if r and len(b["reachedBy"]) == 0],
                 "overreach": overreach,
                 "crawlOnly": sorted(coids + sub_crawl_only)}}
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(out, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
PY
else
  die "census: needs jq or python3"
fi
mv "$TMP" "$OUT" || die "census: cannot write $OUT"
trap - EXIT
