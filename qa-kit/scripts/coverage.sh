#!/usr/bin/env bash
# coverage.sh — qa-kit's per role x surface coverage of a checklist against the census, and the
# ship-profile coverage gate (pure, dual-engine).
#
# USAGE:
#   coverage.sh <census.json> <checklist.json> [--exclusions <exclusions.json>]
#               [--mode block|advise] [--defer-channels] [--accept-crawl-only]
#               [--scope <regex>] [--roles <spec-roles.json|personas.json>]
#
#   Prints coverage.json on stdout (compact, sorted keys, raw UTF-8):
#     {total, covered, functionalCovered, sweepCovered, excluded, uncovered, unscopedCovered, percent,
#      adapterOk, warnings:[...],
#      rows:[{surfaceId, personaId, state:"covered"|"covered-unscoped"|"covered-sweep"|"excluded"|"uncovered",
#             criteria:[ids], reason?}]}
#
# PAIRS: every census surface (pages, endpoints, and the tab / dialog / sheet surfaces
#   `<parent>#<kind>:<subKey>`) x each persona in (reachedBy ∪ allowed). A surface with no such
#   persona still makes ONE pair with persona "*" when it is declared by the stack adapter (`sources`
#   holds "adapter") or is a non-GET endpoint: an unreached declared surface or an unprobed write is
#   exactly what must be covered or excluded. Only a crawl-only surface nobody reached makes no pair.
#   Census jobs, mails and notifications are channel pairs with persona "*", surfaceIds
#   "job:<id>", "mail:<id>", "notification:<id>".
# FILTERS (scope the gate to the spec instead of the whole app; applied before counting):
#   --scope <regex>  keep only pairs whose surfaceId matches (unanchored search; use a regex both
#                    jq/Oniguruma and Python accept, e.g. "hackathon|/h/"). Invalid regex -> exit 2.
#   --roles <file>   keep only pairs whose persona is one of the file's ids, plus "*" pairs. The file
#                    is spec-roles.json {roles:[...]}, {personas:[...]} or an array of {id}.
# The row persona is the first set field of persona | personaId | role. A row with none, or with
#   "*", is UNSCOPED. A row tagged `sweep` (generated load-clean / deny / ux revisit rows) is a SWEEP
#   row: it proves the surface loads or refuses, not that its function works. A row matches a pair
#   when its surfaceId (string or string[]) includes the pair's surface. criteria = the matching row
#   ids in checklist order.
# State, first that applies (functional = not tagged sweep):
#   covered           a "*" pair matched by any functional row, or a role pair matched by a functional
#                     row whose persona equals the pair's persona (criteria = those rows);
#   excluded          the pair matches an exclusion {surfaceId, personaId|"*", reason} (first match,
#                     file order; reason copied; every exclusion needs a non-empty reason). The
#                     exclusion surfaceId may be a glob: "*" matches any run of characters, "?" any one
#                     (e.g. "GET /admin/reports*", "page:Admin/Settings/*");
#   covered-unscoped  a role pair matched only by unscoped functional rows (criteria = those rows);
#   covered-sweep     a pair matched only by sweep rows (scoped to its persona or unscoped; any row
#                     for a "*" pair) (criteria = those rows);
#   excluded          with --defer-channels, an unmatched channel pair, reason
#                     "channel checks arrive in increment 4";
#   uncovered         otherwise.
# COUNTS: functionalCovered = covered rows; sweepCovered = covered-sweep rows; unscopedCovered =
#   covered-unscoped rows. Under --mode block only functionalCovered counts as covered (unscoped and
#   sweep-only pairs add to uncovered and block); under --mode advise all three add to covered.
# PERCENT: covered / (total - excluded) x 100, rounded half-up to one decimal (integer math, so
#   both engines agree); 100 when nothing is left to cover. A whole value prints without ".0".
# WARNINGS: census warnings are copied. adapterOk is false only when the census says so.
#
# EXIT: 0 ok; 1 the gate blocks (only under --mode block): uncovered > 0 (including
#   covered-unscoped and covered-sweep pairs), total - excluded == 0 (empty or uncrawled census, or everything
#   excluded), or the census was built with a failed adapter and --accept-crawl-only was not
#   passed; 2 usage or input error.
#   --mode defaults to block (fail closed). Coverage JSON is printed even when the gate blocks.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq >= 1.7 OR python3 (jq preferred; QA_ENGINE=jq|python3
# forces one). jq >= 1.7 is needed for shortest float printing (28.6, not 28.600000000000001).
# Deterministic given inputs; jq and python3 outputs are byte-identical.
set -uo pipefail

DEFER_REASON="channel checks arrive in increment 4"

die() { echo "ERROR: coverage: $*" >&2; exit 2; }

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

CENSUS="" CHECKLIST="" EXCLUSIONS="" MODE="block" DEFER=false ACCEPT_CRAWL=false SCOPE="" SCOPE_SET=false ROLES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exclusions) [ $# -ge 2 ] || die "--exclusions needs a file"; EXCLUSIONS="$2"; shift 2 ;;
    --mode) [ $# -ge 2 ] || die "--mode needs block|advise"; MODE="$2"; shift 2 ;;
    --defer-channels) DEFER=true; shift ;;
    --accept-crawl-only) ACCEPT_CRAWL=true; shift ;;
    --scope) [ $# -ge 2 ] || die "--scope needs a regex"; SCOPE="$2"; SCOPE_SET=true; shift 2 ;;
    --roles) [ $# -ge 2 ] || die "--roles needs a file"; ROLES="$2"; shift 2 ;;
    --*) die "unknown flag: $1" ;;
    *)
      if [ -z "$CENSUS" ]; then CENSUS="$1"
      elif [ -z "$CHECKLIST" ]; then CHECKLIST="$1"
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done
[ -n "$CENSUS" ] && [ -n "$CHECKLIST" ] || die "usage: coverage.sh <census.json> <checklist.json> [--exclusions <file>] [--mode block|advise] [--defer-channels] [--accept-crawl-only] [--scope <regex>] [--roles <file>]"
case "$MODE" in block|advise) ;; *) die "unknown mode: $MODE (block|advise)" ;; esac
[ -f "$CENSUS" ] || die "census not found: $CENSUS"
[ -f "$CHECKLIST" ] || die "checklist not found: $CHECKLIST"
[ -z "$EXCLUSIONS" ] || [ -f "$EXCLUSIONS" ] || die "exclusions not found: $EXCLUSIONS"
[ -z "$ROLES" ] || [ -f "$ROLES" ] || die "roles file not found: $ROLES"

if has_jq; then
  EXC_JSON='[]'
  if [ -n "$EXCLUSIONS" ]; then EXC_JSON="$(jq -c '.' "$EXCLUSIONS")" || die "malformed exclusions: $EXCLUSIONS"; fi
  ROLES_JSON='null'
  if [ -n "$ROLES" ]; then ROLES_JSON="$(jq -c '.' "$ROLES")" || die "malformed roles file: $ROLES"; fi
  SCOPE_JSON='null'
  if [ "$SCOPE_SET" = true ]; then
    SCOPE_JSON="$(jq -n --arg s "$SCOPE" '$s')"
    jq -n --arg s "$SCOPE" '"" | test($s)' >/dev/null 2>&1 || die "invalid --scope regex: $SCOPE"
  fi
  OUT="$(jq -n -S -c --slurpfile cen "$CENSUS" --slurpfile chk "$CHECKLIST" --argjson exc "$EXC_JSON" \
      --argjson defer "$DEFER" --arg deferReason "$DEFER_REASON" --arg mode "$MODE" \
      --argjson scope "$SCOPE_JSON" --argjson rolesIn "$ROLES_JSON" '
    def dedupe: reduce .[] as $i ([]; if any(.[]; . == $i) then . else . + [$i] end);
    def strs: if type == "array" then map(select(type == "string")) else [] end;
    def globre: "^" + (explode | map([.] | implode | if . == "*" then ".*" elif . == "?" then "."
                         elif test("[\\\\^$.|+()\\[\\]{}]") then "\\" + . else . end) | join("")) + "$";
    def isWrite: (startswith("page:") | not) and ((split(" ")[0] | split("|")) as $m | ($m | index(["GET"]) == null) and ($m | index(["HEAD"]) == null));
    ($rolesIn | if . == null then null
                elif type == "array" then .
                elif type == "object" and ((.roles // null) | type) == "array" then .roles
                elif type == "object" and ((.personas // null) | type) == "array" then .personas
                else error("roles file must be spec-roles.json {roles:[...]}, {personas:[...]} or an array") end
              | if . == null then null else [ .[] | select(type == "object" and (.id | type) == "string") | .id ] end) as $roleIds |
    ($cen[0]) as $c
    | if ($c | type) != "object" or ($c.surfaces | type) != "array" then error("census: .surfaces must be an array") else . end
    | ($chk[0]) as $rows0
    | if ($rows0 | type) != "array" then error("checklist must be a JSON array of rows") else . end
    | if ($exc | type) != "array" then error("exclusions must be a JSON array") else . end
    | ($exc | map(select((type != "object") or ((.surfaceId | type) != "string") or (.surfaceId == "")
                         or ((.personaId | type) != "string") or (.personaId == "")))) as $badId
    | if ($badId | length) > 0 then error("every exclusion needs a string surfaceId and personaId (or \"*\")") else . end
    | ($exc | map(select(((.reason | type) != "string") or ((.reason | test("\\S")) | not)))) as $badReason
    | if ($badReason | length) > 0 then error("exclusion without a reason: " + ($badReason[0].surfaceId) + " / " + ($badReason[0].personaId) + " (reason is required, non-empty)") else . end
    | ([ $c.surfaces[] | .surfaceId as $s
         | (((.reachedBy | strs) + (.allowed | strs)) | unique) as $ps
         | if ($ps | length) > 0 then ($ps[] | {s: $s, p: ., ch: false})
           elif ((.sources | strs | index(["adapter"])) != null) or ($s | isWrite) then {s: $s, p: "*", ch: false}
           else empty end ]
       + [ ($c.jobs // [])[] | {s: ("job:" + .id), p: "*", ch: true} ]
       + [ ($c.mails // [])[] | {s: ("mail:" + .id), p: "*", ch: true} ]
       + [ ($c.notifications // [])[] | {s: ("notification:" + .id), p: "*", ch: true} ]
      ) | unique_by([.s, .p])
      | map(select(($scope == null) or (.s | test($scope))))
      | map(select(($roleIds == null) or .p == "*" or (. as $x | $roleIds | index([$x.p]) != null))) as $pairs
    | [ $exc[] | . + {re: (.surfaceId | globre)} ] as $excR
    | [ $rows0[] | select(type == "object")
        | { id: .id,
            sids: (if (.surfaceId | type) == "string" then [.surfaceId]
                   elif (.surfaceId | type) == "array" then [.surfaceId[] | select(type == "string")]
                   else [] end),
            p: (.persona // .personaId // .role // null),
            sw: ((.tags | strs | index(["sweep"])) != null) }
        | select((.sids | length) > 0) ] as $rows
    | [ $pairs[] as $pr
        | [ $rows[] | select(.sids | index([$pr.s])) ] as $hit
        | ($hit | map(select(.sw | not))) as $fn
        | (if $pr.p == "*" then ($fn | map(.id)) else ($fn | map(select(.p == $pr.p) | .id)) end | dedupe) as $crit
        | (if $pr.p == "*" then [] else ($fn | map(select(.p == null or .p == "*") | .id)) end | dedupe) as $uns
        | (if $pr.p == "*" then ($hit | map(select(.sw) | .id)) else ($hit | map(select(.sw and (.p == $pr.p or .p == null or .p == "*")) | .id)) end | dedupe) as $swp
        | (first($excR[] | . as $e | select(($e.personaId == "*" or $e.personaId == $pr.p) and ($pr.s | test($e.re)))) // null) as $ex
        | if ($crit | length) > 0 then {surfaceId: $pr.s, personaId: $pr.p, state: "covered", criteria: $crit}
          elif $ex != null then {surfaceId: $pr.s, personaId: $pr.p, state: "excluded", criteria: [], reason: $ex.reason}
          elif ($uns | length) > 0 then {surfaceId: $pr.s, personaId: $pr.p, state: "covered-unscoped", criteria: $uns}
          elif ($swp | length) > 0 then {surfaceId: $pr.s, personaId: $pr.p, state: "covered-sweep", criteria: $swp}
          elif ($defer and $pr.ch) then {surfaceId: $pr.s, personaId: $pr.p, state: "excluded", criteria: [], reason: $deferReason}
          else {surfaceId: $pr.s, personaId: $pr.p, state: "uncovered", criteria: []} end ] as $out
    | ($out | length) as $total
    | ($out | map(select(.state == "covered-unscoped")) | length) as $unsc
    | ($out | map(select(.state == "covered-sweep")) | length) as $swc
    | ($out | map(select(.state == "covered")) | length) as $fnc
    | ($fnc + (if $mode == "advise" then $unsc + $swc else 0 end)) as $cov
    | ($out | map(select(.state == "excluded")) | length) as $exd
    | ($total - $exd) as $den
    | (if $den == 0 then 1000 else (((2000 * $cov) + $den) / (2 * $den) | floor) end) as $tenths
    | { total: $total, covered: $cov, functionalCovered: $fnc, sweepCovered: $swc,
        excluded: $exd, uncovered: ($total - $cov - $exd), unscopedCovered: $unsc,
        percent: (if ($tenths % 10) == 0 then ($tenths / 10 | floor) else ($tenths / 10) end),
        adapterOk: (if $c.adapterOk == false then false else true end),
        warnings: ($c.warnings // []),
        rows: $out }
  ')" || die "could not compute coverage (see the message above)"
elif has_py; then
  OUT="$(EXCP="$EXCLUSIONS" DEFER="$DEFER" DEFER_REASON="$DEFER_REASON" MODE="$MODE" ROLESP="$ROLES" \
      SCOPE="$SCOPE" SCOPE_SET="$SCOPE_SET" python3 -c '
import json, os, re, sys
def fail(m):
    sys.stderr.write("ERROR: " + m + "\n"); sys.exit(2)
c = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(c, dict) or not isinstance(c.get("surfaces"), list): fail("census: .surfaces must be an array")
rows0 = json.load(open(sys.argv[2], encoding="utf-8"))
if not isinstance(rows0, list): fail("checklist must be a JSON array of rows")
excp = os.environ.get("EXCP", "")
exc = json.load(open(excp, encoding="utf-8")) if excp else []
if not isinstance(exc, list): fail("exclusions must be a JSON array")
for e in exc:
    if not isinstance(e, dict) or not isinstance(e.get("surfaceId"), str) or e.get("surfaceId") == "" \
       or not isinstance(e.get("personaId"), str) or e.get("personaId") == "":
        fail("every exclusion needs a string surfaceId and personaId (or \"*\")")
for e in exc:
    r = e.get("reason")
    if not isinstance(r, str) or not r.strip():
        fail("exclusion without a reason: %s / %s (reason is required, non-empty)" % (e["surfaceId"], e["personaId"]))
def strs(v): return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []
scope = os.environ.get("SCOPE") if os.environ.get("SCOPE_SET") == "true" else None
if scope is not None:
    try: re.compile(scope)
    except re.error: fail("invalid --scope regex: " + scope)
role_ids = None
if os.environ.get("ROLESP"):
    try: ro = json.load(open(os.environ["ROLESP"], encoding="utf-8"))
    except Exception: fail("malformed roles file: " + os.environ["ROLESP"])
    if isinstance(ro, dict) and isinstance(ro.get("roles"), list): ro = ro["roles"]
    elif isinstance(ro, dict) and isinstance(ro.get("personas"), list): ro = ro["personas"]
    elif not isinstance(ro, list): fail("roles file must be spec-roles.json {roles:[...]}, {personas:[...]} or an array")
    role_ids = [x["id"] for x in ro if isinstance(x, dict) and isinstance(x.get("id"), str)]
def globre(g):
    out = "^"
    for ch in g:
        if ch == "*": out += ".*"
        elif ch == "?": out += "."
        elif ch in "\\^$.|+()[]{}": out += "\\" + ch
        else: out += ch
    return out + "$"
def is_write(sid):
    if sid.startswith("page:"): return False
    m = sid.split(" ")[0].split("|")
    return "GET" not in m and "HEAD" not in m
defer = os.environ.get("DEFER") == "true"
defer_reason = os.environ.get("DEFER_REASON", "")
def present(v): return v is not None and v is not False
pairs = {}
for s in c["surfaces"]:
    ps = set(strs(s.get("reachedBy")) + strs(s.get("allowed")))
    if ps:
        for p in ps: pairs.setdefault((s["surfaceId"], p), False)
    elif "adapter" in strs(s.get("sources")) or is_write(s["surfaceId"]):
        pairs.setdefault((s["surfaceId"], "*"), False)
for key, prefix in (("jobs", "job:"), ("mails", "mail:"), ("notifications", "notification:")):
    for ch in (c.get(key) or []):
        pairs[(prefix + ch["id"], "*")] = True
pairs = {k: v for k, v in pairs.items()
         if (scope is None or re.search(scope, k[0])) and (role_ids is None or k[1] == "*" or k[1] in role_ids)}
exc_re = [(e, re.compile(globre(e["surfaceId"]))) for e in exc]
rows = []
for r in rows0:
    if not isinstance(r, dict): continue
    sid = r.get("surfaceId")
    sids = [sid] if isinstance(sid, str) else ([x for x in sid if isinstance(x, str)] if isinstance(sid, list) else [])
    if not sids: continue
    p = next((r[k] for k in ("persona", "personaId", "role") if present(r.get(k))), None)
    rows.append({"id": r.get("id"), "sids": sids, "p": p, "sw": "sweep" in strs(r.get("tags"))})
out = []
for (s, p) in sorted(pairs):
    crit, uns, swp = [], [], []
    for r in rows:
        if s not in r["sids"]: continue
        if r["sw"]:
            if (p == "*" or r["p"] == p or r["p"] is None or r["p"] == "*") and r["id"] not in swp: swp.append(r["id"])
        elif p == "*" or r["p"] == p:
            if r["id"] not in crit: crit.append(r["id"])
        elif r["p"] is None or r["p"] == "*":
            if r["id"] not in uns: uns.append(r["id"])
    ex = next((e for e, rx in exc_re if (e["personaId"] == "*" or e["personaId"] == p) and rx.search(s)), None)
    if crit: out.append({"surfaceId": s, "personaId": p, "state": "covered", "criteria": crit})
    elif ex is not None: out.append({"surfaceId": s, "personaId": p, "state": "excluded", "criteria": [], "reason": ex["reason"]})
    elif uns: out.append({"surfaceId": s, "personaId": p, "state": "covered-unscoped", "criteria": uns})
    elif swp: out.append({"surfaceId": s, "personaId": p, "state": "covered-sweep", "criteria": swp})
    elif defer and pairs[(s, p)]: out.append({"surfaceId": s, "personaId": p, "state": "excluded", "criteria": [], "reason": defer_reason})
    else: out.append({"surfaceId": s, "personaId": p, "state": "uncovered", "criteria": []})
total = len(out)
unsc = sum(1 for x in out if x["state"] == "covered-unscoped")
swc = sum(1 for x in out if x["state"] == "covered-sweep")
fnc = sum(1 for x in out if x["state"] == "covered")
cov = fnc + (unsc + swc if os.environ.get("MODE") == "advise" else 0)
exd = sum(1 for x in out if x["state"] == "excluded")
den = total - exd
tenths = 1000 if den == 0 else (2000 * cov + den) // (2 * den)
res = {"total": total, "covered": cov, "functionalCovered": fnc, "sweepCovered": swc, "excluded": exd, "uncovered": total - cov - exd, "unscopedCovered": unsc,
       "percent": tenths // 10 if tenths % 10 == 0 else tenths / 10,
       "adapterOk": c.get("adapterOk") is not False,
       "warnings": c.get("warnings") or [],
       "rows": out}
sys.stdout.buffer.write((json.dumps(res, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8"))
' "$CENSUS" "$CHECKLIST")" || die "could not compute coverage (see the message above)"
else
  die "neither jq nor python3 available"
fi

printf '%s\n' "$OUT"

[ "$MODE" = "block" ] || exit 0
# Read the gate inputs back from the result with the engine (never by grepping serialized JSON):
# "<uncovered> <adapterOk:0|1> <total-excluded>".
if has_jq; then
  GATE="$(printf '%s\n' "$OUT" | jq -r '"\(.uncovered) \(if .adapterOk then 1 else 0 end) \(.total - .excluded)"')" || die "could not read the coverage result"
else
  GATE="$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c["uncovered"], 1 if c["adapterOk"] else 0, c["total"] - c["excluded"])')" || die "could not read the coverage result"
fi
read -r uncovered adapter_ok coverable <<EOF_GATE
$GATE
EOF_GATE
blocked=0
if [ "$coverable" -eq 0 ]; then
  echo "coverage: nothing to cover — census is empty or uncrawled" >&2
  blocked=1
fi
if [ "$uncovered" -gt 0 ]; then
  echo "coverage: gate blocked: $uncovered role x surface pair(s) uncovered (covered-unscoped and sweep-only pairs count as uncovered)" >&2
  blocked=1
fi
if [ "$adapter_ok" -eq 0 ] && [ "$ACCEPT_CRAWL" != true ]; then
  echo "coverage: gate blocked: the census adapter failed, so the census is crawl-only; pass --accept-crawl-only to run on it anyway" >&2
  blocked=1
fi
exit "$blocked"
