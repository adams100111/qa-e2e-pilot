#!/usr/bin/env bash
# auto-seed.sh — qa-kit's opt-in auto-seed write GATE (pure, dual-engine, no exec).
#
# `decide <config.json>` answers ONE question: may qa-kit apply the declared `seeded` rows
# (increment 6b) on this environment? It mirrors the qa-e2e-pilot engine's scripted write gate
# BYTE-FOR-BYTE (skills/driving-browser-qa/scripts/preflight.sh:205-215 and
# skills/detecting-stack-profile/scripts/detect-stack.sh:298-307):
#   seed = allowApiWrites == true
#          AND seedableEnvMarker is a NON-EMPTY string   (a config STRING tested for
#              non-emptiness — NOT an env-var name to look up; the real .qa/config.json
#              sets it to ".qa/DISPOSABLE")
#          AND environment != "production"                (default "auto" is NOT production)
#
# This script NEVER executes a seed command and NEVER writes — it only decides. The deliberate
# per-run signal (a human saying "yes, seed this disposable env") lives in /qa-spec, on top of
# this gate. Any gate unmet → the run falls back to 6a declare-and-verify (writes nothing).
#
# USAGE:
#   auto-seed.sh decide <config.json>   → prints {"reason":<string>,"seed":<bool>}; exit 0.
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

cmd_decide() {
  local file="$1"
  [ -f "$file" ] || die "auto-seed decide: config not found: $file"
  if has_jq; then
    jq -Sc '
      (.allowApiWrites == true) as $w
      | (((.seedableEnvMarker | type) == "string") and ((.seedableEnvMarker | length) > 0)) as $m
      | (((.environment // "auto")) != "production") as $e
      | ( if ($w and $m and $e) then {seed:true,  reason:"ok"}
          elif ($w | not)       then {seed:false, reason:"allowApiWrites:false"}
          elif ($m | not)       then {seed:false, reason:"seedableEnvMarker empty (env not marked disposable)"}
          else                       {seed:false, reason:"environment:production"} end )
    ' "$file" 2>/dev/null || die "auto-seed decide: invalid JSON in $file"
  elif has_py; then
    python3 -c '
import json, sys
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    sys.stderr.write("ERROR: auto-seed decide: invalid JSON in %s\n" % sys.argv[1]); sys.exit(1)
w = c.get("allowApiWrites") is True
mk = c.get("seedableEnvMarker")
m = isinstance(mk, str) and len(mk) > 0
e = (c.get("environment") or "auto") != "production"
if w and m and e:
    out = {"seed": True, "reason": "ok"}
elif not w:
    out = {"seed": False, "reason": "allowApiWrites:false"}
elif not m:
    out = {"seed": False, "reason": "seedableEnvMarker empty (env not marked disposable)"}
else:
    out = {"seed": False, "reason": "environment:production"}
print(json.dumps(out, sort_keys=True, separators=(",", ":")))
' "$file"
  else
    die "auto-seed.sh needs either 'jq' or 'python3'."
  fi
}

case "${1:-}" in
  decide) shift; [ "$#" -eq 1 ] || die "usage: auto-seed.sh decide <config.json>"; cmd_decide "$1" ;;
  *) die "usage: auto-seed.sh decide <config.json>" ;;
esac
