#!/usr/bin/env bash
# verify-plan.sh — qa-kit's out-of-plan-act enforcement seam (pure, dual-engine).
#
# WHY THIS EXISTS (increment 4 Task 1 finding): the engine's `qa-verify` iterates
# only the recorded passes in checkpoint.json and, when a recorded criterion has no
# matching checklist.json row, SKIPS the required-kinds re-derivation — it never
# flags "this criterion was acted but is not in the plan" (qa-verify.sh line ~1030 /
# checklist_row_for line ~481). So qa-verify does not enforce "only-planned-criteria-
# may-act". This qa-kit-owned checker closes that gap WITHOUT modifying qa-verify: it
# sits beside it (like session-preflight beside the live gate) and compares the run's
# ACTED criteria against the frozen plan.
#
# USAGE:
#   verify-plan.sh <checkpoint.json> <checklist.json>
#       <checkpoint.json>  — the run's .qa/runs/<id>/checkpoint.json ({criteria:[{criterion_id,…}]}).
#       <checklist.json>   — the run's frozen plan (a top-level array of entries with .id),
#                            compiled by /qa-scenarios.
#   Prints {ok, outOfPlan:[ids], planned:<n>, acted:<n>}; exit 0 iff every acted
#   criterion_id appears in the plan, else exit 1 (and outOfPlan lists the offenders).
#
#   verify-plan.sh --drift <run-checklist.json> <frozen-checklist.json> [<run-journeys.json> <frozen-journeys.json>]
#       Trust-bearing drift check. The engine's gates (checkpoint.sh, qa-verify.sh) read the
#       RUN copy .qa/runs/<id>/checklist.json, which the acting agent can edit; this compares
#       it against the frozen .qa/specs/<target>/checklist.json row by row (matched by id) on
#       kind, tags (as a set), mutates, humanAction, priority, journey,
#       fixture.expect.oracleSource, fixture.expect.citation and fixture.expect.value
#       (absent == null). It also compares the run's journeys.json with the spec's (by
#       default the journeys.json beside each checklist; a file that does not exist is "no
#       journeys"), journey by journey (matched by id) on priority and steps (ordered).
#       Prints {ok, drift:[{id, field, frozen, run}], addedInRun:[ids], missingInRun:[ids],
#       journeyDrift:[{id, field, frozen, run}], journeysAddedInRun:[ids],
#       journeysMissingInRun:[ids], variantsInRun:[ids], variantJourneysInRun:[ids]}; exit 0
#       iff nothing drifted and every id set is equal, else exit 1. The one sanctioned
#       addition is a journeys.sh expand-variant copy (listed in variantsInRun /
#       variantJourneysInRun, not as drift): a run row "<spec id>@<suffix>" (suffix
#       [A-Za-z0-9][A-Za-z0-9_-]*) whose every field but id, variant and journey.id equals the
#       spec row's (tags as a set), with an object `variant` and journey.id = the spec row's
#       journey.id + the same suffix; and a run journey "<spec journey id>@<suffix>" equal to
#       the spec journey except id and steps, whose steps are the spec steps + the suffix, 1:1. A flipped oracleSource, a dropped human-action tag, a P1 row or journey
#       downgraded to P2, or a journey step removed is exactly what this catches: each one
#       relaxes a gate or the ship verdict.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred). No node/perl/grep -P.
# Deterministic; outOfPlan is sorted + de-duplicated.
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

# --drift <run-checklist.json> <frozen-checklist.json>: the trust-bearing fields of every row.
if [ "${1:-}" = "--drift" ]; then
  { [ "$#" -eq 3 ] || [ "$#" -eq 5 ]; } || die "usage: verify-plan.sh --drift <run-checklist.json> <frozen-checklist.json> [<run-journeys.json> <frozen-journeys.json>]"
  RUNPLAN="$2"; FROZEN="$3"
  [ -f "$RUNPLAN" ] || die "verify-plan: run checklist not found: $RUNPLAN"
  [ -f "$FROZEN" ]  || die "verify-plan: frozen checklist not found: $FROZEN"
  if [ "$#" -eq 5 ]; then RUNJ="$4"; FROZENJ="$5"
  else RUNJ="$(dirname "$RUNPLAN")/journeys.json"; FROZENJ="$(dirname "$FROZEN")/journeys.json"; fi
  # A journeys file that does not exist is read as "no journeys" (null).
  RUNJ_IN="$RUNJ"; [ -f "$RUNJ" ] || RUNJ_IN=/dev/null
  FROZENJ_IN="$FROZENJ"; [ -f "$FROZENJ" ] || FROZENJ_IN=/dev/null
  if has_jq; then
    out="$(jq -n --slurpfile r "$RUNPLAN" --slurpfile f "$FROZEN" --slurpfile rj "$RUNJ_IN" --slurpfile fj "$FROZENJ_IN" '
      ($r[0]) as $run | ($f[0]) as $fro | ($rj[0]) as $rjs | ($fj[0]) as $fjs
      | if ($run | type) != "array" then error("malformed run checklist: top level must be an array") else . end
      | if ($fro | type) != "array" then error("malformed frozen checklist: top level must be an array") else . end
      | if ($rjs != null and ($rjs | type) != "array") then error("malformed run journeys: top level must be an array") else . end
      | if ($fjs != null and ($fjs | type) != "array") then error("malformed frozen journeys: top level must be an array") else . end
      | def byid($a): reduce ($a[] | select(type == "object" and (.id | type) == "string")) as $e ({}; if has($e.id) then . else .[$e.id] = $e end);
        def at($p): reduce $p[] as $k (.; if type == "object" then .[$k] else null end);
        def norm($n): if $n == "tags" and type == "array" then map(tojson) | unique else . end;
        def cmp($R; $F; $fields): [ ($F | keys | sort | .[]) as $id | select($R | has($id)) | $fields[] as $n | ($n | split(".")) as $p
          | ($F[$id] | at($p)) as $fv | ($R[$id] | at($p)) as $rv
          | select(($fv | norm($n)) != ($rv | norm($n)))
          | {id: $id, field: $n, frozen: $fv, run: $rv} ];
        ["kind", "tags", "mutates", "humanAction", "priority", "journey", "fixture.expect.oracleSource", "fixture.expect.citation", "fixture.expect.value"] as $fields
      | byid($run) as $R | byid($fro) as $F
      | byid($rjs // []) as $RJ | byid($fjs // []) as $FJ
      | def tagset: if type == "object" and (.tags | type) == "array" then .tags |= (map(tojson) | unique) else . end;
        def base_of($M; $id): ([$M | keys[] | select(. as $b | $id | startswith($b + "@"))] | max_by(length)) as $b
          | if $b != null and ($id[($b | length):] | test("\\A@[A-Za-z0-9][A-Za-z0-9_-]*\\z")) then $b else null end;
        def variant_row_ok($r; $F): base_of($F; $r.id) as $b
          | if $b == null then false else ($r.id[($b | length):]) as $s | $F[$b] as $B
            | (($r.variant | type) == "object")
              and (($r.journey | type) == "object") and (($r.journey.id | type) == "string") and ($r.journey.id | endswith($s))
              and (if ($B.journey | type) == "object" and ($B.journey.id | type) == "string" then $r.journey.id == $B.journey.id + $s else true end)
              and (($r.journey | del(.id)) == (if ($B.journey | type) == "object" then $B.journey | del(.id) else {} end))
              and (($r | del(.id, .variant, .journey) | tagset) == ($B | del(.id, .variant, .journey) | tagset))
            end;
        def variant_journey_ok($j; $FJ): base_of($FJ; $j.id) as $b
          | if $b == null then false else ($j.id[($b | length):]) as $s | $FJ[$b] as $B
            | (($B.steps | type) == "array") and all($B.steps[]; type == "string")
              and (($j.steps | type) == "array") and ($j.steps == ($B.steps | map(. + $s)))
              and (($j | del(.id, .steps)) == ($B | del(.id, .steps)))
            end;
        ([$R | keys[] | . as $k | select($F | has($k) | not)] | sort) as $added0
      | [ $added0[] | select(variant_row_ok($R[.]; $F)) ] as $variants
      | [ $added0[] | select(variant_row_ok($R[.]; $F) | not) ] as $added
      | ([$F | keys[] | . as $k | select($R | has($k) | not)] | sort) as $missing
      | ([$RJ | keys[] | . as $k | select($FJ | has($k) | not)] | sort) as $jadded0
      | [ $jadded0[] | select(variant_journey_ok($RJ[.]; $FJ)) ] as $jvariants
      | [ $jadded0[] | select(variant_journey_ok($RJ[.]; $FJ) | not) ] as $jadded
      | ([$FJ | keys[] | . as $k | select($RJ | has($k) | not)] | sort) as $jmissing
      | cmp($R; $F; $fields) as $drift
      | cmp($RJ; $FJ; ["priority", "steps"]) as $jdrift
      | {ok: (($drift | length) == 0 and ($added | length) == 0 and ($missing | length) == 0
             and ($jdrift | length) == 0 and ($jadded | length) == 0 and ($jmissing | length) == 0),
         drift: $drift, addedInRun: $added, missingInRun: $missing,
         journeyDrift: $jdrift, journeysAddedInRun: $jadded, journeysMissingInRun: $jmissing,
         variantsInRun: $variants, variantJourneysInRun: $jvariants}
    ')" || die "verify-plan: jq failed (malformed input)."
    printf '%s\n' "$out"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] && exit 0 || exit 1
  elif has_py; then
    python3 -I -c '
import json, re, sys
run = json.load(open(sys.argv[1], encoding="utf-8")); fro = json.load(open(sys.argv[2], encoding="utf-8"))
def load_opt(p):
    if p == "/dev/null": return None
    return json.load(open(p, encoding="utf-8"))
rjs = load_opt(sys.argv[3]); fjs = load_opt(sys.argv[4])
if not isinstance(run, list): sys.exit("malformed run checklist: top level must be an array")
if not isinstance(fro, list): sys.exit("malformed frozen checklist: top level must be an array")
if rjs is not None and not isinstance(rjs, list): sys.exit("malformed run journeys: top level must be an array")
if fjs is not None and not isinstance(fjs, list): sys.exit("malformed frozen journeys: top level must be an array")
def byid(a):
    m = {}
    for e in a or []:
        if isinstance(e, dict) and isinstance(e.get("id"), str) and e["id"] not in m: m[e["id"]] = e
    return m
def at(v, p):
    for k in p:
        v = v.get(k) if isinstance(v, dict) else None
    return v
def canon(v):
    if isinstance(v, bool) or v is None: return v
    if isinstance(v, float) and v == int(v): return int(v)
    if isinstance(v, dict): return {k: canon(x) for k, x in v.items()}
    if isinstance(v, list): return [canon(x) for x in v]
    return v
def norm(n, v):
    v = canon(v)
    if n == "tags" and isinstance(v, list): return sorted(set(json.dumps(x, sort_keys=True, ensure_ascii=False) for x in v))
    return json.dumps(v, sort_keys=True, ensure_ascii=False)
def cmp(R, F, fields):
    out = []
    for i in sorted(F):
        if i not in R: continue
        for n in fields:
            p = n.split("."); fv, rv = at(F[i], p), at(R[i], p)
            if norm(n, fv) != norm(n, rv): out.append({"id": i, "field": n, "frozen": fv, "run": rv})
    return out
FIELDS = ["kind", "tags", "mutates", "humanAction", "priority", "journey", "fixture.expect.oracleSource", "fixture.expect.citation", "fixture.expect.value"]
R, F = byid(run), byid(fro)
RJ, FJ = byid(rjs), byid(fjs)
added = sorted(k for k in R if k not in F); missing = sorted(k for k in F if k not in R)
jadded = sorted(k for k in RJ if k not in FJ); jmissing = sorted(k for k in FJ if k not in RJ)
VSUF = re.compile(r"@[A-Za-z0-9][A-Za-z0-9_-]*\Z")
def same(a, b): return json.dumps(canon(a), sort_keys=True, ensure_ascii=False) == json.dumps(canon(b), sort_keys=True, ensure_ascii=False)
def tagset(o):
    o = dict(o)
    if isinstance(o.get("tags"), list): o["tags"] = sorted(set(json.dumps(canon(x), sort_keys=True, ensure_ascii=False) for x in o["tags"]))
    return o
def without(o, *ks): return {k: v for k, v in o.items() if k not in ks}
def base_of(M, i):
    bs = [b for b in M if i.startswith(b + "@")]
    if not bs: return None
    b = max(bs, key=len)
    return b if VSUF.match(i[len(b):]) else None
def variant_row_ok(r, F):
    b = base_of(F, r["id"])
    if b is None: return False
    sfx = r["id"][len(b):]; B = F[b]
    j = r.get("journey"); bj = B.get("journey")
    if not isinstance(r.get("variant"), dict) or not isinstance(j, dict) or not isinstance(j.get("id"), str) or not j["id"].endswith(sfx): return False
    if isinstance(bj, dict) and isinstance(bj.get("id"), str) and j["id"] != bj["id"] + sfx: return False
    if not same(without(j, "id"), without(bj, "id") if isinstance(bj, dict) else {}): return False
    return same(tagset(without(r, "id", "variant", "journey")), tagset(without(B, "id", "variant", "journey")))
def variant_journey_ok(jn, FJ):
    b = base_of(FJ, jn["id"])
    if b is None: return False
    sfx = jn["id"][len(b):]; B = FJ[b]
    bs = B.get("steps")
    if not isinstance(bs, list) or not all(isinstance(x, str) for x in bs): return False
    if not isinstance(jn.get("steps"), list) or not same(jn["steps"], [x + sfx for x in bs]): return False
    return same(without(jn, "id", "steps"), without(B, "id", "steps"))
variants = [k for k in added if variant_row_ok(R[k], F)]; added = [k for k in added if k not in variants]
jvariants = [k for k in jadded if variant_journey_ok(RJ[k], FJ)]; jadded = [k for k in jadded if k not in jvariants]
drift = cmp(R, F, FIELDS); jdrift = cmp(RJ, FJ, ["priority", "steps"])
obj = {"ok": not drift and not added and not missing and not jdrift and not jadded and not jmissing,
       "drift": drift, "addedInRun": added, "missingInRun": missing,
       "journeyDrift": jdrift, "journeysAddedInRun": jadded, "journeysMissingInRun": jmissing,
       "variantsInRun": variants, "variantJourneysInRun": jvariants}
print(json.dumps(obj, indent=2, ensure_ascii=False))
sys.exit(0 if obj["ok"] else 1)
' "$RUNPLAN" "$FROZEN" "$RUNJ_IN" "$FROZENJ_IN"
    exit $?
  else
    die "verify-plan.sh needs either 'jq' or 'python3'."
  fi
fi

[ "$#" -eq 2 ] || die "usage: verify-plan.sh <checkpoint.json> <checklist.json>"
CHECKPOINT="$1"; CHECKLIST="$2"
[ -f "$CHECKPOINT" ] || die "verify-plan: checkpoint file not found: $CHECKPOINT"
[ -f "$CHECKLIST" ]  || die "verify-plan: checklist file not found: $CHECKLIST"

if has_jq; then
  out="$(jq -n --slurpfile cp "$CHECKPOINT" --slurpfile pl "$CHECKLIST" '
    ($cp[0]) as $c | ($pl[0]) as $p
    | if ($c.criteria | type) != "array" then error("malformed checkpoint: .criteria must be an array") else . end
    | if ($p | type) != "array" then error("malformed checklist: top level must be an array") else . end
    | ([ $p[] | .id ] | map(select(. != null))) as $planned
    | ([ $c.criteria[] | .criterion_id ] | map(select(. != null)) | unique) as $acted
    | ($acted | map(select(. as $a | ($planned | index($a)) == null)) | unique | sort) as $oop
    | { ok: (($oop | length) == 0), outOfPlan: $oop, planned: ($planned | length), acted: ($acted | length) }
  ')" || die "verify-plan: jq failed (malformed input)."
  printf '%s\n' "$out"
  [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] && exit 0 || exit 1
elif has_py; then
  python3 -c '
import json, sys
cp = json.load(open(sys.argv[1])); pl = json.load(open(sys.argv[2]))
if not isinstance(cp.get("criteria"), list): sys.exit("malformed checkpoint: .criteria must be an array")
if not isinstance(pl, list): sys.exit("malformed checklist: top level must be an array")
planned = [e.get("id") for e in pl if isinstance(e, dict) and e.get("id") is not None]
acted = []
for c in cp["criteria"]:
    cid = c.get("criterion_id")
    if cid is not None and cid not in acted: acted.append(cid)
planned_set = set(planned)
oop = sorted({a for a in acted if a not in planned_set})
obj = {"ok": len(oop) == 0, "outOfPlan": oop, "planned": len(planned), "acted": len(acted)}
print(json.dumps(obj, indent=2))
sys.exit(0 if obj["ok"] else 1)
' "$CHECKPOINT" "$CHECKLIST"
else
  die "verify-plan.sh needs either 'jq' or 'python3'."
fi
