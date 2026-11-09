#!/usr/bin/env bash
# coverage.sh — qa-kit's per role x surface coverage of a checklist against the census, and the
# ship-profile coverage gate (pure, dual-engine).
#
# USAGE:
#   coverage.sh <census.json> <checklist.json> [--exclusions <exclusions.json>]
#               [--mode block|advise] [--defer-channels] [--accept-crawl-only]
#
#   Prints coverage.json on stdout (compact, sorted keys, raw UTF-8):
#     {total, covered, excluded, uncovered, unscopedCovered, percent, adapterOk, warnings:[...],
#      rows:[{surfaceId, personaId, state:"covered"|"covered-unscoped"|"excluded"|"uncovered",
#             criteria:[ids], reason?}]}
#
# PAIRS: every census surface x each persona in (reachedBy ∪ allowed). A surface no persona
#   reached and none is allowed on makes no pair (it is already in census diffs.unreachable).
#   Census jobs, mails and notifications are pairs with persona "*", surfaceIds
#   "job:<id>", "mail:<id>", "notification:<id>".
# The row persona is the first set field of persona | personaId | role. A row with none, or with
#   "*", is UNSCOPED. A row matches a pair when its surfaceId (string or string[]) includes the
#   pair's surface. criteria = the matching row ids in checklist order.
# State, first that applies:
#   covered           a channel pair ("*") matched by any row, or a role pair matched by a row
#                     whose persona equals the pair's persona (criteria = those scoped rows);
#   excluded          the pair matches an exclusion {surfaceId, personaId|"*", reason} (first
#                     match, file order; reason copied; every exclusion needs a non-empty reason);
#   covered-unscoped  a role pair matched only by unscoped rows (criteria = those rows);
#   excluded          with --defer-channels, an unmatched channel pair, reason
#                     "channel checks arrive in increment 4";
#   uncovered         otherwise.
# COUNTS: unscopedCovered = covered-unscoped rows. Under --mode block they do NOT count as
#   covered (they add to uncovered and block); under --mode advise they add to covered.
# PERCENT: covered / (total - excluded) x 100, rounded half-up to one decimal (integer math, so
#   both engines agree); 100 when nothing is left to cover. A whole value prints without ".0".
# WARNINGS: census warnings are copied. adapterOk is false only when the census says so.
#
# EXIT: 0 ok; 1 the gate blocks (only under --mode block): uncovered > 0 (including
#   covered-unscoped pairs), total - excluded == 0 (empty or uncrawled census, or everything
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

CENSUS="" CHECKLIST="" EXCLUSIONS="" MODE="block" DEFER=false ACCEPT_CRAWL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --exclusions) [ $# -ge 2 ] || die "--exclusions needs a file"; EXCLUSIONS="$2"; shift 2 ;;
    --mode) [ $# -ge 2 ] || die "--mode needs block|advise"; MODE="$2"; shift 2 ;;
    --defer-channels) DEFER=true; shift ;;
    --accept-crawl-only) ACCEPT_CRAWL=true; shift ;;
    --*) die "unknown flag: $1" ;;
    *)
      if [ -z "$CENSUS" ]; then CENSUS="$1"
      elif [ -z "$CHECKLIST" ]; then CHECKLIST="$1"
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done
[ -n "$CENSUS" ] && [ -n "$CHECKLIST" ] || die "usage: coverage.sh <census.json> <checklist.json> [--exclusions <file>] [--mode block|advise] [--defer-channels] [--accept-crawl-only]"
case "$MODE" in block|advise) ;; *) die "unknown mode: $MODE (block|advise)" ;; esac
[ -f "$CENSUS" ] || die "census not found: $CENSUS"
[ -f "$CHECKLIST" ] || die "checklist not found: $CHECKLIST"
[ -z "$EXCLUSIONS" ] || [ -f "$EXCLUSIONS" ] || die "exclusions not found: $EXCLUSIONS"

if has_jq; then
  EXC_JSON='[]'
  if [ -n "$EXCLUSIONS" ]; then EXC_JSON="$(jq -c '.' "$EXCLUSIONS")" || die "malformed exclusions: $EXCLUSIONS"; fi
  OUT="$(jq -n -S -c --slurpfile cen "$CENSUS" --slurpfile chk "$CHECKLIST" --argjson exc "$EXC_JSON" \
      --argjson defer "$DEFER" --arg deferReason "$DEFER_REASON" --arg mode "$MODE" '
    def dedupe: reduce .[] as $i ([]; if any(.[]; . == $i) then . else . + [$i] end);
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
         | (((.reachedBy // []) + (.allowed // [])) | unique[]) | {s: $s, p: ., ch: false} ]
       + [ ($c.jobs // [])[] | {s: ("job:" + .id), p: "*", ch: true} ]
       + [ ($c.mails // [])[] | {s: ("mail:" + .id), p: "*", ch: true} ]
       + [ ($c.notifications // [])[] | {s: ("notification:" + .id), p: "*", ch: true} ]
      ) | unique_by([.s, .p]) as $pairs
    | [ $rows0[] | select(type == "object")
        | { id: .id,
            sids: (if (.surfaceId | type) == "string" then [.surfaceId]
                   elif (.surfaceId | type) == "array" then [.surfaceId[] | select(type == "string")]
                   else [] end),
            p: (.persona // .personaId // .role // null) }
        | select((.sids | length) > 0) ] as $rows
    | [ $pairs[] as $pr
        | [ $rows[] | select(.sids | index([$pr.s])) ] as $hit
        | (if $pr.p == "*" then ($hit | map(.id)) else ($hit | map(select(.p == $pr.p) | .id)) end | dedupe) as $crit
        | (if $pr.p == "*" then [] else ($hit | map(select(.p == null or .p == "*") | .id)) end | dedupe) as $uns
        | (first($exc[] | select(.surfaceId == $pr.s and (.personaId == "*" or .personaId == $pr.p))) // null) as $ex
        | if ($crit | length) > 0 then {surfaceId: $pr.s, personaId: $pr.p, state: "covered", criteria: $crit}
          elif $ex != null then {surfaceId: $pr.s, personaId: $pr.p, state: "excluded", criteria: [], reason: $ex.reason}
          elif ($uns | length) > 0 then {surfaceId: $pr.s, personaId: $pr.p, state: "covered-unscoped", criteria: $uns}
          elif ($defer and $pr.ch) then {surfaceId: $pr.s, personaId: $pr.p, state: "excluded", criteria: [], reason: $deferReason}
          else {surfaceId: $pr.s, personaId: $pr.p, state: "uncovered", criteria: []} end ] as $out
    | ($out | length) as $total
    | ($out | map(select(.state == "covered-unscoped")) | length) as $unsc
    | (($out | map(select(.state == "covered")) | length) + (if $mode == "advise" then $unsc else 0 end)) as $cov
    | ($out | map(select(.state == "excluded")) | length) as $exd
    | ($total - $exd) as $den
    | (if $den == 0 then 1000 else (((2000 * $cov) + $den) / (2 * $den) | floor) end) as $tenths
    | { total: $total, covered: $cov, excluded: $exd, uncovered: ($total - $cov - $exd), unscopedCovered: $unsc,
        percent: (if ($tenths % 10) == 0 then ($tenths / 10 | floor) else ($tenths / 10) end),
        adapterOk: (if $c.adapterOk == false then false else true end),
        warnings: ($c.warnings // []),
        rows: $out }
  ')" || die "could not compute coverage (see the message above)"
elif has_py; then
  OUT="$(EXCP="$EXCLUSIONS" DEFER="$DEFER" DEFER_REASON="$DEFER_REASON" MODE="$MODE" python3 -c '
import json, os, sys
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
defer = os.environ.get("DEFER") == "true"
defer_reason = os.environ.get("DEFER_REASON", "")
def present(v): return v is not None and v is not False
pairs = {}
for s in c["surfaces"]:
    for p in set((s.get("reachedBy") or []) + (s.get("allowed") or [])):
        pairs.setdefault((s["surfaceId"], p), False)
for key, prefix in (("jobs", "job:"), ("mails", "mail:"), ("notifications", "notification:")):
    for ch in (c.get(key) or []):
        pairs[(prefix + ch["id"], "*")] = True
rows = []
for r in rows0:
    if not isinstance(r, dict): continue
    sid = r.get("surfaceId")
    sids = [sid] if isinstance(sid, str) else ([x for x in sid if isinstance(x, str)] if isinstance(sid, list) else [])
    if not sids: continue
    p = next((r[k] for k in ("persona", "personaId", "role") if present(r.get(k))), None)
    rows.append({"id": r.get("id"), "sids": sids, "p": p})
out = []
for (s, p) in sorted(pairs):
    crit, uns = [], []
    for r in rows:
        if s not in r["sids"]: continue
        if p == "*" or r["p"] == p:
            if r["id"] not in crit: crit.append(r["id"])
        elif r["p"] is None or r["p"] == "*":
            if r["id"] not in uns: uns.append(r["id"])
    ex = next((e for e in exc if e["surfaceId"] == s and (e["personaId"] == "*" or e["personaId"] == p)), None)
    if crit: out.append({"surfaceId": s, "personaId": p, "state": "covered", "criteria": crit})
    elif ex is not None: out.append({"surfaceId": s, "personaId": p, "state": "excluded", "criteria": [], "reason": ex["reason"]})
    elif uns: out.append({"surfaceId": s, "personaId": p, "state": "covered-unscoped", "criteria": uns})
    elif defer and pairs[(s, p)]: out.append({"surfaceId": s, "personaId": p, "state": "excluded", "criteria": [], "reason": defer_reason})
    else: out.append({"surfaceId": s, "personaId": p, "state": "uncovered", "criteria": []})
total = len(out)
unsc = sum(1 for x in out if x["state"] == "covered-unscoped")
cov = sum(1 for x in out if x["state"] == "covered") + (unsc if os.environ.get("MODE") == "advise" else 0)
exd = sum(1 for x in out if x["state"] == "excluded")
den = total - exd
tenths = 1000 if den == 0 else (2000 * cov + den) // (2 * den)
res = {"total": total, "covered": cov, "excluded": exd, "uncovered": total - cov - exd, "unscopedCovered": unsc,
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
  echo "coverage: gate blocked: $uncovered role x surface pair(s) uncovered (covered-unscoped pairs count as uncovered)" >&2
  blocked=1
fi
if [ "$adapter_ok" -eq 0 ] && [ "$ACCEPT_CRAWL" != true ]; then
  echo "coverage: gate blocked: the census adapter failed, so the census is crawl-only; pass --accept-crawl-only to run on it anyway" >&2
  blocked=1
fi
exit "$blocked"
