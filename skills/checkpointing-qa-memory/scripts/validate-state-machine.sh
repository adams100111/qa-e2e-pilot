#!/usr/bin/env bash
# validate-state-machine.sh — structural validator for state-machine.json (see
# ../references/state-machine-schema.md for the schema this checks).
#
# state-machine.json is the statechart-as-data (ADR-0017 Run FSM Enforcement,
# Task 1): the 6 emitted pipeline phases, the per-criterion sub-states, their
# legal edges, the transition guards, and the per-phase tool surface. It is
# the CONTRACT later tasks read: fold's sub-state inference + illegal-edge
# anomaly, and qa-verify's phase-surface enforcement. This script checks only
# that the file is STRUCTURALLY well-shaped and internally cross-referenced
# (every edge/guard/surface-key points at something actually declared) — it
# does not interpret what a guard's `requires` token means or how a
# phaseToolSurface class maps to a real tool name; that is fold's/qa-verify's
# job (Tasks 2/3), reading this file as data.
#
# USAGE:
#   validate-state-machine.sh <state-machine.json-path>
#     Exits 0 iff the file is valid JSON and every cross-reference below
#     holds. Exits non-zero and prints one "ERROR: ..." line per violation to
#     stderr, each naming the offending field/edge/index.
#
# CHECKS:
#   - phases: array of {id: non-empty string, order: number}; no duplicate
#     id, no duplicate order.
#   - subStates: array of strings; no duplicate.
#   - legalPhaseEdges: array of [from,to] string pairs; from/to must each be
#     a declared phase id.
#   - legalSubStateEdges: array of [from,to] string pairs; from/to must each
#     be a declared subState.
#   - guards: array of {edge:[from,to], requires:<non-empty string>}; edge
#     must be either a literal declared legalSubStateEdge, or a wildcard
#     ["*", <declared subState>] (matches a transition into that subState
#     from any source).
#   - toolClasses (optional): array of strings, the closed tool-class
#     vocabulary phaseToolSurface entries are drawn from.
#   - phaseToolSurface: object whose keys are each a declared phase id, and
#     whose values are {allowedToolClasses?:[string], forbiddenToolClasses?:
#     [string]} — when toolClasses is present, every listed class must be a
#     member of it.
#
# DEPENDENCIES: bash, EITHER jq OR python3 (jq preferred, python3 fallback).
# No node. Never grep -P/perl (tests/portability/run.sh forbids it in
# bundled scripts) — this script does no grep-based parsing at all, jq/
# python3 do all JSON handling.

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
has_jq() { command -v jq >/dev/null 2>&1; }
has_py() { command -v python3 >/dev/null 2>&1; }

usage() { die "Usage: validate-state-machine.sh <state-machine.json-path>"; }

# ---------------------------------------------------------------------------
# jq engine
# ---------------------------------------------------------------------------
validate_jq() {
  local path="$1"
  local jq_out jq_rc
  jq_out="$(jq -e -r 'type' "$path" 2>&1)"; jq_rc=$?
  if [[ $jq_rc -ne 0 ]]; then
    die "state-machine.json: invalid JSON (${path}): ${jq_out}"
  fi

  local filter
  filter='
def blank: [];

( .phases ) as $phasesField
| (if ($phasesField|type) != "array" then ["phases: must be an array"] else [] end) as $vPhasesType
| (if ($phasesField|type) == "array" then $phasesField else [] end) as $phases

| ( [ range(0; ($phases|length)) as $i
      | ($phases[$i]) as $p
      | select(($p|type) != "object" or (($p|has("id"))|not) or (($p.id|type) != "string") or (($p.id|length) == 0))
      | "phases[\($i)]: must be an object with a non-empty string id"
  ] ) as $vPhasesId

| ( [ range(0; ($phases|length)) as $i
      | ($phases[$i]) as $p
      | select(($p|type) == "object" and (($p|has("id"))) and (($p.id|type) == "string") and (($p.id|length) > 0))
      | select((($p|has("order"))|not) or (($p.order|type) != "number"))
      | "phases[\($i)].order: must be a number"
  ] ) as $vPhasesOrder

| ( [ range(0; ($phases|length)) as $i
      | ($phases[$i]) as $p
      | select(($p|type) == "object" and (($p|has("id"))) and (($p.id|type) == "string") and (($p.id|length) > 0) and (($p|has("order"))) and (($p.order|type) == "number"))
      | {id: $p.id, order: $p.order}
  ] ) as $validPhases
| ($validPhases | map(.id)) as $phaseIds
| ($validPhases | map(.order)) as $phaseOrders

| ( ($phaseIds | group_by(.) | map(select(length>1) | {key: .[0], n: length}))
    | map("phases: duplicate phase id \"\(.key)\": appears \(.n) times") ) as $vDupPhaseIds

| ( ($phaseOrders | group_by(.) | map(select(length>1) | {key: .[0], n: length}))
    | map("phases: duplicate order \(.key): appears \(.n) times") ) as $vDupPhaseOrders

| (.subStates) as $subStatesField
| (if ($subStatesField|type) != "array" or ( [$subStatesField[]?] | map((type)!="string") | any )
   then ["subStates: must be an array of strings"] else [] end) as $vSubStatesType
| (if ($subStatesField|type) == "array" then ($subStatesField | map(select(type=="string"))) else [] end) as $subStates
| ($subStates | group_by(.) | map(select(length>1) | {key: .[0], n: length}) | map("subStates: duplicate sub-state \"\(.key)\": appears \(.n) times")) as $vDupSubStates

| (.legalPhaseEdges) as $lpeField
| (if ($lpeField|type) != "array" then ["legalPhaseEdges: must be an array"] else [] end) as $vLpeType
| (if ($lpeField|type) == "array" then $lpeField else [] end) as $lpe

| ( [ range(0; ($lpe|length)) as $i
      | ($lpe[$i]) as $e
      | select(($e|type) != "array" or (($e|length) != 2) or ( [$e[]?] | map((type)!="string") | any ))
      | "legalPhaseEdges[\($i)]: must be a [from,to] pair of strings"
  ] ) as $vLpeShape

| ( [ range(0; ($lpe|length)) as $i
      | ($lpe[$i]) as $e
      | select(($e|type) == "array" and (($e|length) == 2) and (( [$e[]?] | map((type)!="string") | any ) | not))
      | ($e[0]) as $frm | ($e[1]) as $to
      | ( if ($phaseIds | index($frm)) == null then "legalPhaseEdges[\($i)]: \"\($frm)\" is not a declared phase id" else empty end ),
        ( if ($phaseIds | index($to)) == null then "legalPhaseEdges[\($i)]: \"\($to)\" is not a declared phase id" else empty end )
  ] ) as $vLpeEndpoints

| (.legalSubStateEdges) as $lseField
| (if ($lseField|type) != "array" then ["legalSubStateEdges: must be an array"] else [] end) as $vLseType
| (if ($lseField|type) == "array" then $lseField else [] end) as $lse

| ( [ range(0; ($lse|length)) as $i
      | ($lse[$i]) as $e
      | select(($e|type) != "array" or (($e|length) != 2) or ( [$e[]?] | map((type)!="string") | any ))
      | "legalSubStateEdges[\($i)]: must be a [from,to] pair of strings"
  ] ) as $vLseShape

| ( [ range(0; ($lse|length)) as $i
      | ($lse[$i]) as $e
      | select(($e|type) == "array" and (($e|length) == 2) and (( [$e[]?] | map((type)!="string") | any ) | not))
      | ($e[0]) as $frm | ($e[1]) as $to
      | ( if ($subStates | index($frm)) == null then "legalSubStateEdges[\($i)]: \"\($frm)\" is not a declared subState" else empty end ),
        ( if ($subStates | index($to)) == null then "legalSubStateEdges[\($i)]: \"\($to)\" is not a declared subState" else empty end )
  ] ) as $vLseEndpoints

| ( [ range(0; ($lse|length)) as $i
      | ($lse[$i]) as $e
      | select(($e|type) == "array" and (($e|length) == 2) and (( [$e[]?] | map((type)!="string") | any ) | not))
      | "\($e[0])\($e[1])"
  ] ) as $subEdgeKeys

| (.guards) as $guardsField
| (if ($guardsField|type) != "array" then ["guards: must be an array"] else [] end) as $vGuardsType
| (if ($guardsField|type) == "array" then $guardsField else [] end) as $guards

| ( [ range(0; ($guards|length)) as $i
      | ($guards[$i]) as $g
      | select(($g|type) != "object" or (($g|has("edge"))|not) or (($g|has("requires"))|not))
      | "guards[\($i)]: must be an object with edge and requires"
  ] ) as $vGuardsShape

| ( [ range(0; ($guards|length)) as $i
      | ($guards[$i]) as $g
      | select(($g|type) == "object" and ($g|has("edge")) and ($g|has("requires")))
      | select((($g.requires|type) != "string") or (($g.requires|length) == 0))
      | "guards[\($i)].requires: must be a non-empty string"
  ] ) as $vGuardsRequires

| ( [ range(0; ($guards|length)) as $i
      | ($guards[$i]) as $g
      | select(($g|type) == "object" and ($g|has("edge")) and ($g|has("requires")))
      | ($g.edge) as $edge
      | select(($edge|type) != "array" or (($edge|length) != 2) or ( [$edge[]?] | map((type)!="string") | any ))
      | "guards[\($i)].edge: must be a [from,to] pair of strings"
  ] ) as $vGuardsEdgeShape

| ( [ range(0; ($guards|length)) as $i
      | ($guards[$i]) as $g
      | select(($g|type) == "object" and ($g|has("edge")) and ($g|has("requires")))
      | ($g.edge) as $edge
      | select(($edge|type) == "array" and (($edge|length) == 2) and (( [$edge[]?] | map((type)!="string") | any ) | not))
      | ($edge[0]) as $frm | ($edge[1]) as $to
      | if $frm == "*" then
          (if ($subStates | index($to)) == null then "guards[\($i)].edge: wildcard target \"\($to)\" is not a declared subState" else empty end)
        else
          (if ($subEdgeKeys | index("\($frm)\($to)")) == null then "guards[\($i)].edge: [\($frm),\($to)] is not a declared legalSubStateEdge" else empty end)
        end
  ] ) as $vGuardsEdgeRef

| (.toolClasses) as $toolClassesField
| ($toolClassesField != null) as $hasToolClasses
| (if $hasToolClasses and (($toolClassesField|type) != "array" or ( [$toolClassesField[]?] | map((type)!="string") | any ))
   then ["toolClasses: must be an array of strings"] else [] end) as $vToolClassesType
| (if $hasToolClasses and ($toolClassesField|type) == "array" then $toolClassesField else null end) as $toolClasses

| (.phaseToolSurface) as $surfaceField
| (if ($surfaceField|type) != "object" then ["phaseToolSurface: must be an object"] else [] end) as $vSurfaceType
| (if ($surfaceField|type) == "object" then $surfaceField else {} end) as $surface

| ( [ ($surface | keys[]) as $k
      | select(($phaseIds | index($k)) == null)
      | "phaseToolSurface[\"\($k)\"]: \"\($k)\" is not a declared phase id"
  ] ) as $vSurfaceKeys

| ( [ ($surface | keys[]) as $k
      | ($surface[$k]) as $v
      | select(($v|type) != "object")
      | "phaseToolSurface[\"\($k)\"]: must be an object"
  ] ) as $vSurfaceValShape

| ( [ ($surface | keys[]) as $k
      | ($surface[$k]) as $v
      | select(($v|type) == "object")
      | ("allowedToolClasses", "forbiddenToolClasses") as $field
      | select(($v|has($field)) and ($v[$field] != null))
      | ($v[$field]) as $lst
      | if ($lst|type) != "array" or ( [$lst[]?] | map((type)!="string") | any )
        then "phaseToolSurface[\"\($k)\"].\($field): must be an array of strings"
        elif $toolClasses != null then
          ( [ $lst[] | . as $item | select(($toolClasses | index($item)) == null) ] ) as $bad
          | if ($bad|length) > 0 then "phaseToolSurface[\"\($k)\"].\($field): unknown tool class(es) \($bad | join(","))" else empty end
        else empty
        end
  ] ) as $vSurfaceClasses

| ($vPhasesType + $vPhasesId + $vPhasesOrder + $vDupPhaseIds + $vDupPhaseOrders
   + $vSubStatesType + $vDupSubStates
   + $vLpeType + $vLpeShape + $vLpeEndpoints
   + $vLseType + $vLseShape + $vLseEndpoints
   + $vGuardsType + $vGuardsShape + $vGuardsRequires + $vGuardsEdgeShape + $vGuardsEdgeRef
   + $vToolClassesType
   + $vSurfaceType + $vSurfaceKeys + $vSurfaceValShape + $vSurfaceClasses
  ) as $violations
| $violations[]
'

  local violations
  violations="$(jq -r -f <(printf '%s' "$filter") "$path" 2>&1)" || die "state-machine.json: jq validation failed unexpectedly (${path}): ${violations}"

  if [[ -z "$violations" ]]; then
    return 0
  fi
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "ERROR: ${line}" >&2
  done <<< "$violations"
  return 1
}

# ---------------------------------------------------------------------------
# python3 engine (fallback)
# ---------------------------------------------------------------------------
validate_py() {
  local path="$1"
  python3 - "$path" <<'PYEOF'
import json, sys


def main():
    path = sys.argv[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as exc:
        print(f"ERROR: state-machine.json: invalid JSON ({path}): {exc}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(data, dict):
        print(f"ERROR: top-level: must be a JSON object (got {type(data).__name__})", file=sys.stderr)
        sys.exit(1)

    violations = []

    # --- phases ---------------------------------------------------------
    phases = data.get("phases")
    if not isinstance(phases, list):
        violations.append("phases: must be an array")
        phases = []
    phase_ids = []
    phase_orders = []
    for i, p in enumerate(phases):
        if not isinstance(p, dict) or not isinstance(p.get("id"), str) or len(p.get("id")) == 0:
            violations.append(f"phases[{i}]: must be an object with a non-empty string id")
            continue
        if "order" not in p or not isinstance(p.get("order"), (int, float)) or isinstance(p.get("order"), bool):
            violations.append(f"phases[{i}].order: must be a number")
            continue
        phase_ids.append(p["id"])
        phase_orders.append(p["order"])

    counts = {}
    for pid in phase_ids:
        counts[pid] = counts.get(pid, 0) + 1
    for pid, n in counts.items():
        if n > 1:
            violations.append(f'phases: duplicate phase id "{pid}": appears {n} times')

    ocounts = {}
    for o in phase_orders:
        ocounts[o] = ocounts.get(o, 0) + 1
    for o, n in ocounts.items():
        if n > 1:
            violations.append(f"phases: duplicate order {o}: appears {n} times")

    phase_id_set = set(phase_ids)

    # --- subStates --------------------------------------------------------
    sub_states = data.get("subStates")
    if not isinstance(sub_states, list) or any(not isinstance(s, str) for s in sub_states):
        violations.append("subStates: must be an array of strings")
        sub_states = [s for s in (sub_states or []) if isinstance(s, str)]
    scounts = {}
    for s in sub_states:
        scounts[s] = scounts.get(s, 0) + 1
    for s, n in scounts.items():
        if n > 1:
            violations.append(f'subStates: duplicate sub-state "{s}": appears {n} times')
    sub_state_set = set(sub_states)

    # --- legalPhaseEdges ----------------------------------------------------
    lpe = data.get("legalPhaseEdges")
    if not isinstance(lpe, list):
        violations.append("legalPhaseEdges: must be an array")
        lpe = []
    for i, e in enumerate(lpe):
        if not isinstance(e, list) or len(e) != 2 or not all(isinstance(x, str) for x in e):
            violations.append(f"legalPhaseEdges[{i}]: must be a [from,to] pair of strings")
            continue
        frm, to = e
        if frm not in phase_id_set:
            violations.append(f'legalPhaseEdges[{i}]: "{frm}" is not a declared phase id')
        if to not in phase_id_set:
            violations.append(f'legalPhaseEdges[{i}]: "{to}" is not a declared phase id')

    # --- legalSubStateEdges -------------------------------------------------
    lse = data.get("legalSubStateEdges")
    if not isinstance(lse, list):
        violations.append("legalSubStateEdges: must be an array")
        lse = []
    sub_edge_set = set()
    for i, e in enumerate(lse):
        if not isinstance(e, list) or len(e) != 2 or not all(isinstance(x, str) for x in e):
            violations.append(f"legalSubStateEdges[{i}]: must be a [from,to] pair of strings")
            continue
        frm, to = e
        if frm not in sub_state_set:
            violations.append(f'legalSubStateEdges[{i}]: "{frm}" is not a declared subState')
        if to not in sub_state_set:
            violations.append(f'legalSubStateEdges[{i}]: "{to}" is not a declared subState')
        sub_edge_set.add((frm, to))

    # --- guards -------------------------------------------------------------
    guards = data.get("guards")
    if not isinstance(guards, list):
        violations.append("guards: must be an array")
        guards = []
    for i, g in enumerate(guards):
        if not isinstance(g, dict) or "edge" not in g or "requires" not in g:
            violations.append(f"guards[{i}]: must be an object with edge and requires")
            continue
        requires = g["requires"]
        if not isinstance(requires, str) or len(requires) == 0:
            violations.append(f"guards[{i}].requires: must be a non-empty string")
        edge = g["edge"]
        if not isinstance(edge, list) or len(edge) != 2 or not all(isinstance(x, str) for x in edge):
            violations.append(f"guards[{i}].edge: must be a [from,to] pair of strings")
            continue
        frm, to = edge
        if frm == "*":
            if to not in sub_state_set:
                violations.append(f'guards[{i}].edge: wildcard target "{to}" is not a declared subState')
        else:
            if (frm, to) not in sub_edge_set:
                violations.append(f"guards[{i}].edge: [{frm},{to}] is not a declared legalSubStateEdge")

    # --- toolClasses (optional) ---------------------------------------------
    tool_classes = data.get("toolClasses")
    tool_class_set = None
    if tool_classes is not None:
        if not isinstance(tool_classes, list) or any(not isinstance(t, str) for t in tool_classes):
            violations.append("toolClasses: must be an array of strings")
        else:
            tool_class_set = set(tool_classes)

    # --- phaseToolSurface -----------------------------------------------------
    surface = data.get("phaseToolSurface")
    if not isinstance(surface, dict):
        violations.append("phaseToolSurface: must be an object")
        surface = {}
    for key, val in surface.items():
        if key not in phase_id_set:
            violations.append(f'phaseToolSurface["{key}"]: "{key}" is not a declared phase id')
        if not isinstance(val, dict):
            violations.append(f'phaseToolSurface["{key}"]: must be an object')
            continue
        for field in ("allowedToolClasses", "forbiddenToolClasses"):
            if field in val and val[field] is not None:
                lst = val[field]
                if not isinstance(lst, list) or any(not isinstance(t, str) for t in lst):
                    violations.append(f'phaseToolSurface["{key}"].{field}: must be an array of strings')
                elif tool_class_set is not None:
                    bad = [t for t in lst if t not in tool_class_set]
                    if bad:
                        violations.append(f'phaseToolSurface["{key}"].{field}: unknown tool class(es) {",".join(bad)}')

    if violations:
        for v in violations:
            print(f"ERROR: {v}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)


main()
PYEOF
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && usage
  local path="$1"
  [[ -f "$path" ]] || die "state-machine.json not found: ${path}"

  if has_jq; then
    validate_jq "$path"
  elif has_py; then
    validate_py "$path"
  else
    die "validate-state-machine.sh needs either 'jq' or 'python3' on PATH."
  fi
}

main "$@"
