#!/usr/bin/env bash
# detect-seed.sh — qa-kit's stack seed-command PROPOSER (pure, dual-engine, read-only).
#
# Reads the qa-e2e-pilot engine's emitted stack-profile.json (per-run at
# .qa/runs/<run-id>/stack-profile.json, ADR-0002; or the cache .qa/stack-profile.cache.json)
# and PROPOSES the stack's database-seed command for qa-kit's opt-in auto-seed (increment 6b).
# It only READS the profile — the engine's detecting-stack-profile skill is never modified.
#
# The profile has no `commands.seed` field, so the command is DERIVED (never read) from the
# backend component's framework / orm.name — and only where a genuine standard command exists
# (honest, no guessing). Everything else proposes {mechanism:null, command:null}; the operator
# then sets a seedCommand by hand or stays with declare-and-verify (6a).
#
# USAGE:
#   detect-seed.sh propose <stack-profile.json> [<config.json>]
#       Backend component = the component at index .primary.backend when in range; else the
#       first component whose .role is "backend" or "fullstack"; else the first component; else
#       none. Its .framework / .orm.name map to a mechanism+command:
#         framework "laravel"     -> {mechanism:"laravel", command:"php artisan db:seed"}
#         framework "rails"       -> {mechanism:"rails",   command:"bin/rails db:seed"}
#         orm.name  "prisma"      -> {mechanism:"prisma",  command:"npx prisma db seed"}
#         else (django, unknown…) -> {mechanism:null,      command:null}
#       cwd = optional config.json repos[] path of the "backend" entry, else "fullstack", else ".".
#       Prints compact SORTED JSON (cross-engine byte-identical). NEVER executes anything.
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

cmd_propose() {
  local profile="$1" cfg_file="${2:-}"
  [ -f "$profile" ] || die "detect-seed propose: profile not found: $profile"
  local cfg_json='null'
  if [ -n "$cfg_file" ]; then
    [ -f "$cfg_file" ] || die "detect-seed propose: config not found: $cfg_file"
    cfg_json="$(cat "$cfg_file")"
  fi
  if has_jq; then
    jq -Sc --argjson cfg "$cfg_json" '
      (.components // []) as $comps
      | ( if (.primary.backend | type) == "number"
             and (.primary.backend >= 0)
             and (.primary.backend < ($comps | length))
            then $comps[.primary.backend]
            else ([ $comps[] | select(.role == "backend" or .role == "fullstack") ][0]
                   // $comps[0] // null)
          end ) as $bc
      | ($bc | .framework?) as $fw
      | ($bc | .orm? | .name?) as $orm
      | ( if $fw == "laravel" then {mechanism:"laravel", command:"php artisan db:seed"}
          elif $fw == "rails" then {mechanism:"rails",   command:"bin/rails db:seed"}
          elif $orm == "prisma" then {mechanism:"prisma", command:"npx prisma db seed"}
          else {mechanism:null, command:null} end ) as $m
      | (($cfg // {}) | (.repos // [])) as $repos
      | ( ([ $repos[] | select(.role == "backend")  ][0] | .path?)
          // ([ $repos[] | select(.role == "fullstack") ][0] | .path?)
          // "." ) as $cwd
      | {mechanism: $m.mechanism, command: $m.command, cwd: $cwd}
    ' "$profile" 2>/dev/null || die "detect-seed propose: invalid JSON in $profile"
  elif has_py; then
    python3 -c '
import json, sys
try:
    profile = json.load(open(sys.argv[1]))
except Exception:
    sys.stderr.write("ERROR: detect-seed propose: invalid JSON in %s\n" % sys.argv[1]); sys.exit(1)
cfg = json.loads(sys.argv[2])
comps = profile.get("components") or []
bc = None
pb = (profile.get("primary") or {}).get("backend")
if isinstance(pb, int) and not isinstance(pb, bool) and 0 <= pb < len(comps):
    bc = comps[pb]
else:
    for c in comps:
        if isinstance(c, dict) and c.get("role") in ("backend", "fullstack"):
            bc = c; break
    if bc is None and comps:
        bc = comps[0]
bc = bc if isinstance(bc, dict) else {}
fw = bc.get("framework")
orm = (bc.get("orm") or {}).get("name") if isinstance(bc.get("orm"), dict) else None
if fw == "laravel":
    mech, cmd = "laravel", "php artisan db:seed"
elif fw == "rails":
    mech, cmd = "rails", "bin/rails db:seed"
elif orm == "prisma":
    mech, cmd = "prisma", "npx prisma db seed"
else:
    mech, cmd = None, None
repos = ((cfg or {}).get("repos")) or []
be = [r.get("path") for r in repos if isinstance(r, dict) and r.get("role") == "backend"]
fs = [r.get("path") for r in repos if isinstance(r, dict) and r.get("role") == "fullstack"]
cwd = be[0] if be else (fs[0] if fs else ".")
print(json.dumps({"mechanism": mech, "command": cmd, "cwd": cwd}, sort_keys=True, separators=(",", ":")))
' "$profile" "$cfg_json"
  else
    die "detect-seed.sh needs either 'jq' or 'python3'."
  fi
}

case "${1:-}" in
  propose) shift; { [ "$#" -eq 1 ] || [ "$#" -eq 2 ]; } || die "usage: detect-seed.sh propose <stack-profile.json> [<config.json>]"; cmd_propose "$@" ;;
  *) die "usage: detect-seed.sh propose <stack-profile.json> [<config.json>]" ;;
esac
