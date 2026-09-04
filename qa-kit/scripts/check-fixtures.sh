#!/usr/bin/env bash
# check-fixtures.sh — qa-kit's pinned-expect gate for computed criteria (pure, dual-engine).
#
# A criterion that COMPUTES (kind ∈ {computed-logic, business-rule} — the engine's own definition;
# `required-kinds.sh` derives `computed` from `kind` alone) MUST carry a well-formed ABSOLUTE pinned
# expect. Multiplicity criteria derive `bake`, not `computed`, so they are NOT gated here (their
# relative count form is resolved + asserted by the run). This gate keys on `kind` — a REQUIRED,
# reliably-present checklist.json field — NOT on `requiredKinds` (which the engine does not write into
# checklist.json). It never calls an engine script at runtime, so `qa-verify`/the engine stay untouched.
#
# USAGE:
#   check-fixtures.sh <checklist.json>
#       Prints {ok, missing:[{id,reason}], sources:{human:<n>,llmSuggested:<n>}}.
#       Exit 0 iff every computing row has a well-formed absolute expect; else exit 1.
#   A well-formed absolute expect = fixture.expect with: path (non-empty string), value (present,
#   string or number), tolerance (number), oracleSource ∈ {"human","llm-suggested"}.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred). No node/perl/grep -P.
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

[ "$#" -eq 1 ] || die "usage: check-fixtures.sh <checklist.json>"
CHECKLIST="$1"
[ -f "$CHECKLIST" ] || die "check-fixtures: checklist not found: $CHECKLIST"

if has_jq; then
  out="$(jq -Sc '
    if type != "array" then error("checklist must be a JSON array") else . end
    | def computes: (.kind // "" | ascii_downcase) as $k | ($k=="computed-logic" or $k=="business-rule");
      def wellFormed:
        (.fixture.expect) as $e
        | ($e != null)
          and (($e.path|type)=="string") and (($e.path|length)>0)
          and ($e|has("value")) and (($e.value|type)=="string" or ($e.value|type)=="number")
          and (($e.tolerance|type)=="number")
          and ([$e.oracleSource] - ["human","llm-suggested"] | length == 0);
      ([ .[] | select(computes) ]) as $comp
    | { ok: ([ $comp[] | select(wellFormed|not) ] | length == 0),
        missing: ([ $comp[] | select(wellFormed|not) | {id, reason: "computed criterion missing a well-formed pinned expect"} ] | sort_by(.id)),
        sources: { human: ([ $comp[] | select(.fixture.expect.oracleSource=="human") ] | length),
                   llmSuggested: ([ $comp[] | select(.fixture.expect.oracleSource=="llm-suggested") ] | length) } }
  ' "$CHECKLIST" 2>/dev/null)" || die "check-fixtures: jq failed (malformed checklist)."
  printf '%s\n' "$out"
  [ "$(printf '%s' "$out" | jq -r '.ok')" = "true" ] && exit 0 || exit 1
elif has_py; then
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit("check-fixtures: invalid JSON")
if not isinstance(data, list): sys.exit("check-fixtures: checklist must be a JSON array")
def computes(r): return str(r.get("kind","")).lower() in ("computed-logic","business-rule")
def well_formed(r):
    e = (r.get("fixture") or {}).get("expect")
    if not isinstance(e, dict): return False
    if not isinstance(e.get("path"), str) or len(e["path"]) == 0: return False
    if "value" not in e or not isinstance(e["value"], (str, int, float)) or isinstance(e["value"], bool): return False
    if not isinstance(e.get("tolerance"), (int, float)) or isinstance(e.get("tolerance"), bool): return False
    if e.get("oracleSource") not in ("human","llm-suggested"): return False
    return True
comp = [r for r in data if isinstance(r, dict) and computes(r)]
missing = sorted(({"id": r.get("id"), "reason": "computed criterion missing a well-formed pinned expect"}
                  for r in comp if not well_formed(r)), key=lambda m: (m["id"] is None, m["id"]))
def src(r): return ((r.get("fixture") or {}).get("expect") or {}).get("oracleSource")
obj = {"ok": len(missing) == 0, "missing": missing,
       "sources": {"human": sum(1 for r in comp if src(r)=="human"),
                   "llmSuggested": sum(1 for r in comp if src(r)=="llm-suggested")}}
print(json.dumps(obj, sort_keys=True, separators=(",", ":")))
sys.exit(0 if obj["ok"] else 1)
' "$CHECKLIST"
else
  die "check-fixtures.sh needs either 'jq' or 'python3'."
fi
