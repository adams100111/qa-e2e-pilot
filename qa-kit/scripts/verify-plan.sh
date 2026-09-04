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
