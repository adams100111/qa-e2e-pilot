#!/usr/bin/env bash
# data-baseline.sh — qa-kit's data-baseline validator + count helper (pure, dual-engine).
#
# The qa-kit spec declares the entities a scenario touches, each flagged origin=seeded|created
# and optionally tenant/persona-scoped, in .qa/specs/<target>/data-baseline.json. This script
# validates that file's shape and does the deterministic baseline+delta arithmetic the run uses
# to resolve multiplicity counts (measured baseline + N).
#
# USAGE:
#   data-baseline.sh validate <data-baseline.json>
#       Valid = a top-level ARRAY; each row an object with: entity (non-empty string);
#       origin in {"seeded","created"}; identity (object|null); scope (object|null, when present).
#       Exit 0 if valid; else nonzero + {"errors":[...]} on stdout (errors in input order).
#       Extra keys are allowed (forward-compat). A seeded row without identity is NOT an error
#       (some seeded rows are not surface-readable) — the run flags those low-confidence.
#
#   data-baseline.sh expected-count <measured-int> <delta-int>
#       Print measured+delta. Dies on a non-integer argument.
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

cmd_validate() {
  local file="$1"
  [ -f "$file" ] || die "data-baseline validate: file not found: $file"
  if has_jq; then
    local report rc
    report="$(jq -Sc '
      def rowErrors($i; $r):
        (if ($r|type) != "object" then ["row[\($i)]: must be an object"]
         else
           (if (($r|has("entity"))|not) or (($r.entity|type) != "string") or (($r.entity|length)==0)
              then ["row[\($i)].entity: must be a non-empty string"] else [] end)
           + (if (($r|has("origin"))|not) or ([$r.origin] - ["seeded","created"] | length != 0)
              then ["row[\($i)].origin: must be \"seeded\" or \"created\""] else [] end)
           + (if ($r|has("identity")) and ($r.identity != null) and (($r.identity|type) != "object")
              then ["row[\($i)].identity: must be an object or null"] else [] end)
           + (if ($r|has("scope")) and ($r.scope != null) and (($r.scope|type) != "object")
              then ["row[\($i)].scope: must be an object or null"] else [] end)
         end);
      if type != "array" then {errors: ["top level: must be an array"]}
      else { errors: ([ to_entries[] | rowErrors(.key; .value) ] | add // []) }
      end' "$file" 2>/dev/null)" || { echo '{"errors":["invalid JSON"]}'; return 1; }
    printf '%s\n' "$report"
    [ "$(printf '%s' "$report" | jq '.errors | length')" -eq 0 ]
  elif has_py; then
    python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print(json.dumps({"errors": ["invalid JSON"]}, sort_keys=True, separators=(",", ":"))); sys.exit(1)
errors = []
if not isinstance(data, list):
    errors = ["top level: must be an array"]
else:
    for i, r in enumerate(data):
        if not isinstance(r, dict):
            errors.append("row[%d]: must be an object" % i); continue
        e = r.get("entity")
        if not isinstance(e, str) or len(e) == 0:
            errors.append("row[%d].entity: must be a non-empty string" % i)
        if r.get("origin") not in ("seeded", "created"):
            errors.append("row[%d].origin: must be \"seeded\" or \"created\"" % i)
        if "identity" in r and r["identity"] is not None and not isinstance(r["identity"], dict):
            errors.append("row[%d].identity: must be an object or null" % i)
        if "scope" in r and r["scope"] is not None and not isinstance(r["scope"], dict):
            errors.append("row[%d].scope: must be an object or null" % i)
print(json.dumps({"errors": errors}, sort_keys=True, separators=(",", ":")))
sys.exit(0 if not errors else 1)
' "$file"
  else
    die "data-baseline.sh needs either 'jq' or 'python3'."
  fi
}

is_int() { case "$1" in ''|*[!0-9-]*) return 1 ;; -) return 1 ;; *) return 0 ;; esac; }

cmd_expected_count() {
  local measured="$1" delta="$2"
  is_int "$measured" || die "expected-count: measured must be an integer: $measured"
  is_int "$delta" || die "expected-count: delta must be an integer: $delta"
  printf '%s\n' "$(( measured + delta ))"
}

case "${1:-}" in
  validate)       shift; [ "$#" -eq 1 ] || die "usage: data-baseline.sh validate <data-baseline.json>"; cmd_validate "$1" ;;
  expected-count) shift; [ "$#" -eq 2 ] || die "usage: data-baseline.sh expected-count <measured> <delta>"; cmd_expected_count "$1" "$2" ;;
  *) die "usage: data-baseline.sh <validate|expected-count> …" ;;
esac
