#!/usr/bin/env bash
# oracle-confirm.sh — human confirmation page for proposed (unconfirmed) oracle values. Dual-engine.
#
# USAGE:
#   oracle-confirm.sh render <checklist.json> <out.html>
#       Writes a self-contained, offline HTML form (no network, no external assets) listing every row
#       whose fixture.expect.oracleSource is not human|spec, grouped by fixture.expect.rule (fallback
#       "<kind>:<fixture.expect.path>"). The page's "Save decisions" button downloads
#       oracle-decisions.json: [{criterionId, decision:"accept"|"edit"|"unknown", value?}].
#       Prints {groups:<n>, rows:<n>, out:<path>}.
#   oracle-confirm.sh apply <checklist.json> <oracle-decisions.json>
#       Rewrites the checklist in place (backup <checklist>.bak): accept -> oracleSource "human";
#       edit -> new value + "human"; unknown -> unchanged. Prints {accepted,edited,unknown,unmatched:[ids]}.
#
# DEPENDENCIES: bash, coreutils, awk, EITHER jq OR python3 (jq preferred). No node/perl/grep -P.
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
has_jq || has_py || die "oracle-confirm.sh needs either 'jq' or 'python3'."

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/../templates/oracle-confirm.html"
CMD="${1:-}"; [ "$#" -ge 1 ] && shift

# groups JSON: {"groups":[{"rule":..,"rows":[..]}]} in first-appearance order.
groups_json() {
  if has_jq; then
    jq -Sc '
      if type != "array" then error("checklist must be a JSON array") else . end
      | [ .[] | select(type=="object")
          | select((.fixture|type)=="object" and (.fixture.expect|type)=="object")
          | select(((.fixture.expect.oracleSource // "") | . != "human" and . != "spec")) ] as $rows
      | def rule: (.fixture.expect.rule // "" | if type=="string" and length>0 then . else null end)
                  // ((.kind // "") + ":" + (.fixture.expect.path // "" | tostring));
        def item: { id, surface, action, kind, inputs: .fixture.actionInput, path: .fixture.expect.path,
                    value: .fixture.expect.value, tolerance: .fixture.expect.tolerance,
                    oracleSource: .fixture.expect.oracleSource, citation: .fixture.expect.citation,
                    groundingNote: .fixture.expect.groundingNote } | with_entries(select(.value != null));
        ([ $rows[] | rule ] | reduce .[] as $r ([]; if index($r) == null then . + [$r] else . end)) as $order
      | { groups: [ $order[] as $g | { rule: $g, rows: [ $rows[] | select(rule == $g) | item ] } ] }
    ' "$1"
  else
    python3 -c '
import json, sys
try: data = json.load(open(sys.argv[1]))
except Exception: sys.exit("invalid JSON")
if not isinstance(data, list): sys.exit("checklist must be a JSON array")
order, by = [], {}
for r in data:
    if not isinstance(r, dict): continue
    f = r.get("fixture")
    e = f.get("expect") if isinstance(f, dict) else None
    if not isinstance(e, dict): continue
    if e.get("oracleSource", "") in ("human", "spec"): continue
    rule = e.get("rule")
    if not (isinstance(rule, str) and rule): rule = str(r.get("kind", "")) + ":" + str(e.get("path", ""))
    item = {"id": r.get("id"), "surface": r.get("surface"), "action": r.get("action"), "kind": r.get("kind"),
            "inputs": f.get("actionInput"), "path": e.get("path"), "value": e.get("value"),
            "tolerance": e.get("tolerance"), "oracleSource": e.get("oracleSource"),
            "citation": e.get("citation"), "groundingNote": e.get("groundingNote")}
    item = {k: v for k, v in item.items() if v is not None}
    if rule not in by: by[rule] = []; order.append(rule)
    by[rule].append(item)
print(json.dumps({"groups": [{"rule": g, "rows": by[g]} for g in order]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
' "$1"
  fi
}

do_render() {
  [ "$#" -eq 2 ] || die "usage: oracle-confirm.sh render <checklist.json> <out.html>"
  [ -f "$1" ] || die "oracle-confirm: checklist not found: $1"
  [ -f "$TEMPLATE" ] || die "oracle-confirm: template missing: $TEMPLATE"
  local g tmp
  g="$(groups_json "$1")" || die "oracle-confirm: malformed checklist."
  tmp="$(mktemp)"
  # '<' as < keeps the embedded JSON from closing its script tag; still valid JSON.
  printf '%s\n' "$g" | sed 's/</\\u003c/g' > "$tmp"
  awk -v df="$tmp" '$0=="__ORACLE_DATA__"{while((getline l < df)>0) print l; next} {print}' "$TEMPLATE" > "$2" \
    || { rm -f "$tmp"; die "oracle-confirm: cannot write $2"; }
  rm -f "$tmp"
  if has_jq; then
    printf '%s' "$g" | jq -Sc --arg out "$2" '{groups: (.groups|length), rows: ([.groups[].rows|length]|add // 0), out: $out}'
  else
    printf '%s' "$g" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"groups": len(d["groups"]), "rows": sum(len(x["rows"]) for x in d["groups"]), "out": sys.argv[1]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
' "$2"
  fi
}

do_apply() {
  [ "$#" -eq 2 ] || die "usage: oracle-confirm.sh apply <checklist.json> <oracle-decisions.json>"
  [ -f "$1" ] || die "oracle-confirm: checklist not found: $1"
  [ -f "$2" ] || die "oracle-confirm: decisions not found: $2"
  local new tmp
  tmp="$(mktemp)"
  if has_jq; then
    new="$(jq --indent 2 --slurpfile d "$2" '
      if type != "array" then error("checklist must be a JSON array") else . end
      | . as $cl
      | ($d[0] | if type=="array" then . else error("decisions must be a JSON array") end) as $dec
      | def valid: (type=="object") and (.criterionId != null)
          and ((.decision=="accept") or (.decision=="unknown")
               or (.decision=="edit" and has("value") and ((.value|type)=="string") and (.value|length > 0))
               or (.decision=="edit" and has("value") and (.value|type)=="number"));
        def rowok($x): (type=="object") and ((.fixture|type)=="object") and ((.fixture.expect|type)=="object")
          and ((.id|tostring) == ($x.criterionId|tostring))
          and ((.fixture.expect.oracleSource // "") | . != "human" and . != "spec")
          and ($x.decision == "unknown"
               or ((.fixture.expect.path|type)=="string" and (.fixture.expect.path|length)>0
                   and ((.fixture.expect.tolerance|type)=="number")
                   and ($x.decision == "edit" or (.fixture.expect|has("value") and ((.value|type)=="string" or (.value|type)=="number")))));
        def matched($x): ($x|valid) and ([ $cl[] | select(rowok($x)) ] | length > 0);
        ([ $dec[] | select(type=="object" and .criterionId != null) ]
          | reduce .[] as $x ({}; .[$x.criterionId|tostring] = $x)) as $m
      | ($m | to_entries | map(select(matched(.value)))) as $ok
      | { c: ($cl | map(. as $r | if ($r|type)=="object" and ($r.id != null) and ($m[($r.id|tostring)] != null)
                              and ($m[($r.id|tostring)] as $x | ($x|valid) and ($r|rowok($x)))
                        then ($m[($r.id|tostring)]) as $x
                        | if $x.decision=="accept" then .fixture.expect.oracleSource = "human"
                          elif $x.decision=="edit" then (.fixture.expect.value = $x.value | .fixture.expect.oracleSource = "human")
                          else . end
                        else . end)),
          s: { accepted: ([ $ok[] | select(.value.decision=="accept") ] | length),
               edited: ([ $ok[] | select(.value.decision=="edit") ] | length),
               unknown: ([ $ok[] | select(.value.decision=="unknown") ] | length),
               unmatched: ([ $m | to_entries[] | select(matched(.value)|not) | .key ] | sort) } }
    ' "$1" 2>/dev/null)" || die "oracle-confirm: jq failed (malformed checklist or decisions)."
    printf '%s\n' "$new" | jq --indent 2 '.c' > "$tmp" || die "oracle-confirm: internal error"
    cp "$1" "$1.bak" && mv "$tmp" "$1" || die "oracle-confirm: cannot write $1"
    printf '%s\n' "$new" | jq -Sc '.s'
  else
    cp "$1" "$1.bak" || die "oracle-confirm: cannot write backup"
    python3 -c '
import json, sys
try:
    cl = json.load(open(sys.argv[1])); dec = json.load(open(sys.argv[2]))
except Exception: sys.exit("oracle-confirm: invalid JSON")
if not isinstance(cl, list): sys.exit("oracle-confirm: checklist must be a JSON array")
if not isinstance(dec, list): sys.exit("oracle-confirm: decisions must be a JSON array")
m = {}
for x in dec:
    if isinstance(x, dict) and x.get("criterionId") is not None:
        k = x["criterionId"]; m[k if isinstance(k, str) else json.dumps(k, ensure_ascii=False)] = x
def valid(x):
    d = x.get("decision")
    if d in ("accept", "unknown"): return True
    v = x.get("value")
    return d == "edit" and isinstance(v, (str, int, float)) and not isinstance(v, bool) and v != ""
def has_expect(r):
    return isinstance(r, dict) and isinstance(r.get("fixture"), dict) and isinstance(r["fixture"].get("expect"), dict)
def isnum(v): return isinstance(v, (int, float)) and not isinstance(v, bool)
def rowok(r, x):
    if not has_expect(r): return False
    e = r["fixture"]["expect"]
    if e.get("oracleSource", "") in ("human", "spec"): return False
    if x["decision"] == "unknown": return True
    if not (isinstance(e.get("path"), str) and e["path"]) or not isnum(e.get("tolerance")): return False
    if x["decision"] == "accept":
        return "value" in e and (isinstance(e["value"], str) or isnum(e["value"]))
    return True
def rid(r):
    i = r.get("id"); return i if isinstance(i, str) else json.dumps(i, ensure_ascii=False)
rows = {}
for r in cl:
    if isinstance(r, dict) and r.get("id") is not None: rows.setdefault(rid(r), []).append(r)
acc = edt = unk = 0; unmatched = []
for k, x in m.items():
    ok = [r for r in rows.get(k, []) if rowok(r, x)] if valid(x) else []
    if not ok: unmatched.append(k); continue
    for r in ok:
        e = r["fixture"]["expect"]
        if x["decision"] == "accept": e["oracleSource"] = "human"
        elif x["decision"] == "edit": e["value"] = x["value"]; e["oracleSource"] = "human"
    if x["decision"] == "accept": acc += 1
    elif x["decision"] == "edit": edt += 1
    else: unk += 1
with open(sys.argv[1], "w") as f:
    f.write(json.dumps(cl, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"accepted": acc, "edited": edt, "unknown": unk, "unmatched": sorted(unmatched)}, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
' "$1" "$2" || die "oracle-confirm: apply failed"
  fi
}

case "$CMD" in
  render) do_render "$@" ;;
  apply) do_apply "$@" ;;
  *) die "usage: oracle-confirm.sh render <checklist.json> <out.html> | apply <checklist.json> <oracle-decisions.json>" ;;
esac
