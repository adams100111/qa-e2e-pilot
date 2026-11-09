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
#   verify-plan.sh --drift <run-checklist.json> <frozen-checklist.json>
#       Trust-bearing drift check. The engine's gates (checkpoint.sh, qa-verify.sh) read the
#       RUN copy .qa/runs/<id>/checklist.json, which the acting agent can edit; this compares
#       it against the frozen .qa/specs/<target>/checklist.json row by row (matched by id) on
#       kind, tags (as a set), mutates, humanAction, fixture.expect.oracleSource,
#       fixture.expect.citation and fixture.expect.value (absent == null). Prints
#       {ok, drift:[{id, field, frozen, run}], addedInRun:[ids], missingInRun:[ids]}; exit 0
#       iff nothing drifted and both id sets are equal, else exit 1. A flipped oracleSource or
#       a dropped human-action tag is exactly what this catches: either one relaxes a gate.
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
  [ "$#" -eq 3 ] || die "usage: verify-plan.sh --drift <run-checklist.json> <frozen-checklist.json>"
  RUNPLAN="$2"; FROZEN="$3"
  [ -f "$RUNPLAN" ] || die "verify-plan: run checklist not found: $RUNPLAN"
  [ -f "$FROZEN" ]  || die "verify-plan: frozen checklist not found: $FROZEN"
  if has_jq; then
    out="$(jq -n --slurpfile r "$RUNPLAN" --slurpfile f "$FROZEN" '
      ($r[0]) as $run | ($f[0]) as $fro
      | if ($run | type) != "array" then error("malformed run checklist: top level must be an array") else . end
      | if ($fro | type) != "array" then error("malformed frozen checklist: top level must be an array") else . end
      | def byid($a): reduce ($a[] | select(type == "object" and (.id | type) == "string")) as $e ({}; if has($e.id) then . else .[$e.id] = $e end);
        def at($p): reduce $p[] as $k (.; if type == "object" then .[$k] else null end);
        def norm($n): if $n == "tags" and type == "array" then map(tojson) | unique else . end;
        ["kind", "tags", "mutates", "humanAction", "fixture.expect.oracleSource", "fixture.expect.citation", "fixture.expect.value"] as $fields
      | byid($run) as $R | byid($fro) as $F
      | ([$R | keys[] | . as $k | select($F | has($k) | not)] | sort) as $added
      | ([$F | keys[] | . as $k | select($R | has($k) | not)] | sort) as $missing
      | [ ($F | keys | sort | .[]) as $id | select($R | has($id)) | $fields[] as $n | ($n | split(".")) as $p
          | ($F[$id] | at($p)) as $fv | ($R[$id] | at($p)) as $rv
          | select(($fv | norm($n)) != ($rv | norm($n)))
          | {id: $id, field: $n, frozen: $fv, run: $rv} ] as $drift
      | {ok: (($drift | length) == 0 and ($added | length) == 0 and ($missing | length) == 0),
         drift: $drift, addedInRun: $added, missingInRun: $missing}
    ')" || die "verify-plan: jq failed (malformed input)."
    printf '%s\n' "$out"
    [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] && exit 0 || exit 1
  elif has_py; then
    python3 -I -c '
import json, sys
run = json.load(open(sys.argv[1], encoding="utf-8")); fro = json.load(open(sys.argv[2], encoding="utf-8"))
if not isinstance(run, list): sys.exit("malformed run checklist: top level must be an array")
if not isinstance(fro, list): sys.exit("malformed frozen checklist: top level must be an array")
def byid(a):
    m = {}
    for e in a:
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
FIELDS = ["kind", "tags", "mutates", "humanAction", "fixture.expect.oracleSource", "fixture.expect.citation", "fixture.expect.value"]
R, F = byid(run), byid(fro)
added = sorted(k for k in R if k not in F); missing = sorted(k for k in F if k not in R)
drift = []
for i in sorted(F):
    if i not in R: continue
    for n in FIELDS:
        p = n.split("."); fv, rv = at(F[i], p), at(R[i], p)
        if norm(n, fv) != norm(n, rv): drift.append({"id": i, "field": n, "frozen": fv, "run": rv})
obj = {"ok": not drift and not added and not missing, "drift": drift, "addedInRun": added, "missingInRun": missing}
print(json.dumps(obj, indent=2, ensure_ascii=False))
sys.exit(0 if obj["ok"] else 1)
' "$RUNPLAN" "$FROZEN"
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
