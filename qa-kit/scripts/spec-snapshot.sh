#!/usr/bin/env bash
# spec-snapshot.sh — qa-kit's per-spec role snapshot helper (pure, dual-engine).
#
# A qa-kit spec pins an IMMUTABLE copy of the constitution's roles, stamped with
# the constitution version it was built from, so a run replays a frozen role set
# and never re-reads a mutating constitution mid-run (design decision 6; ADR-0020
# freeze-and-replay). This script is that copy+stamp+override step, and the
# stamped-version drift check.
#
# USAGE:
#   spec-snapshot.sh create <constitution.state.json> <spec-dir> [<overrides.json>]
#       Read {roles:[{id,role,plane}], version} from <constitution.state.json>
#       (the authoritative machine state written by constitution.sh `state`),
#       apply the optional <overrides.json>, and write
#       <spec-dir>/spec-roles.json = {constitutionVersion, roles, overrides}.
#       roles are sorted by id (deterministic, byte-identical across engines).
#       overrides.json (optional):
#         { "subset": ["id",…],                      keep only these ids
#           "modify": [{"id":"…","role"?:"…","plane"?:"…"}],  patch a matching id
#           "add":    [{"id":"…","role":"…","plane":"…"}] }   append (die on id clash)
#       Application order: subset -> modify -> add.
#
#   spec-snapshot.sh drift <spec-roles.json> <current-constitution-version>
#       Print {stale:<bool>, stamped:<v>, current:<v>}; stale = the two differ.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3 (jq preferred). No
# node/perl/grep -P. Deterministic given inputs (no clock/random in output).
#
# NOTE: config.json is intentionally NOT an input — R3-Q4 made the constitution
# state file carry both roles and version, so it is the single source here.
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

cmd_create() {
  local state="$1" spec_dir="$2" overrides="${3:-}"
  [ -f "$state" ] || die "spec-snapshot create: constitution state file not found: $state"
  [ -d "$spec_dir" ] || die "spec-snapshot create: spec dir not found: $spec_dir"
  local out="$spec_dir/spec-roles.json"

  if has_jq; then
    local ov_arg='null'
    [ -n "$overrides" ] && ov_arg="$(cat "$overrides")"
    jq -e -n --slurpfile s "$state" --argjson ov "$ov_arg" '
      ($s[0]) as $st
      | ($st.roles) as $roles0
      | if ($roles0 | type) != "array" then error("malformed state: .roles must be an array") else . end
      | ($st.version) as $ver
      | if ($ver | type) != "string" then error("malformed state: .version must be a string") else . end
      # normalize every role to {id,role,plane} strings
      | ($roles0 | map({id, role, plane})) as $roles1
      | ($ov) as $o
      # subset
      | (if ($o != null and ($o.subset? != null))
           then ($roles1 | map(select(.id as $i | ($o.subset | index($i)) != null)))
           else $roles1 end) as $roles2
      # modify (patch role/plane on matching id)
      | (if ($o != null and ($o.modify? != null))
           then reduce $o.modify[] as $m ($roles2;
                 map(if .id == $m.id then . + ($m | del(.id)) else . end))
           else $roles2 end) as $roles3
      # add (die on id clash)
      | (if ($o != null and ($o.add? != null))
           then reduce $o.add[] as $a ($roles3;
                 if (map(.id) | index($a.id)) != null
                   then error("add: id already exists: " + $a.id)
                   else . + [{id:$a.id, role:$a.role, plane:$a.plane}] end)
           else $roles3 end) as $roles4
      # symmetric validation: every final role needs string id/role/plane
      | ($roles4 | map(select((.id|type)!="string" or (.role|type)!="string" or (.plane|type)!="string"))) as $bad
      | if ($bad | length) > 0 then error("role missing string id/role/plane") else . end
      | { constitutionVersion: $ver,
          roles: ($roles4 | sort_by(.id)),
          overrides: $o }
    ' > "$out" || die "spec-snapshot create: jq failed (bad state/overrides, or an add-id collision)."
  elif has_py; then
    OVP="$overrides" python3 -c '
import json, os, sys
state = json.load(open(sys.argv[1]))
out_path = sys.argv[2]
roles0 = state.get("roles")
if not isinstance(roles0, list): sys.exit("malformed state: .roles must be an array")
ver = state.get("version")
if not isinstance(ver, str): sys.exit("malformed state: .version must be a string")
roles = [{"id": r["id"], "role": r["role"], "plane": r["plane"]} for r in roles0]
ovp = os.environ.get("OVP", "")
o = json.load(open(ovp)) if ovp else None
if o is not None:
    if o.get("subset") is not None:
        keep = set(o["subset"]); roles = [r for r in roles if r["id"] in keep]
    for m in (o.get("modify") or []):
        for r in roles:
            if r["id"] == m["id"]:
                for k in ("role","plane"):
                    if k in m: r[k] = m[k]
    for a in (o.get("add") or []):
        if any(r["id"] == a.get("id") for r in roles): sys.exit("add: id already exists: " + str(a.get("id")))
        roles.append({"id": a.get("id"), "role": a.get("role"), "plane": a.get("plane")})
# symmetric validation: every final role needs string id/role/plane
if any(not isinstance(r.get(k), str) for r in roles for k in ("id","role","plane")):
    sys.exit("role missing string id/role/plane")
roles.sort(key=lambda r: r["id"])
obj = {"constitutionVersion": ver, "roles": roles, "overrides": o}
with open(out_path, "w") as f:
    json.dump(obj, f, indent=2); f.write("\n")
' "$state" "$out" || die "spec-snapshot create: python3 failed (bad state/overrides, or an add-id collision)."
  else
    die "spec-snapshot.sh needs either 'jq' or 'python3'."
  fi
}

cmd_drift() {
  local spec_roles="$1" current="$2"
  [ -f "$spec_roles" ] || die "spec-snapshot drift: spec-roles file not found: $spec_roles"
  if has_jq; then
    jq -e -n --slurpfile r "$spec_roles" --arg cur "$current" '
      ($r[0].constitutionVersion) as $st
      | { stale: ($st != $cur), stamped: $st, current: $cur }
    ' || die "spec-snapshot drift: jq failed."
  elif has_py; then
    python3 -c '
import json, sys
st = json.load(open(sys.argv[1])).get("constitutionVersion")
cur = sys.argv[2]
print(json.dumps({"stale": st != cur, "stamped": st, "current": cur}, indent=2))
' "$spec_roles" "$current" || die "spec-snapshot drift: python3 failed."
  else
    die "spec-snapshot.sh needs either 'jq' or 'python3'."
  fi
}

case "${1:-}" in
  create) shift; [ "$#" -ge 2 ] || die "usage: spec-snapshot.sh create <constitution.state.json> <spec-dir> [<overrides.json>]"; cmd_create "$@" ;;
  drift)  shift; [ "$#" -eq 2 ] || die "usage: spec-snapshot.sh drift <spec-roles.json> <current-constitution-version>"; cmd_drift "$@" ;;
  *) die "usage: spec-snapshot.sh <create|drift> …" ;;
esac
