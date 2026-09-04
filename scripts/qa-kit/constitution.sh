#!/usr/bin/env bash
# constitution.sh — deterministic role-state version/hash + informational
# diff + constitution.md render (qa-kit increment 1, Task 1). Mirrors the
# header idioms (die/has_jq/has_py/QA_ENGINE) used by
# skills/checkpointing-qa-memory/scripts/journal.sh and
# skills/detecting-visual-ux/scripts/ux-conventions.sh.
#
# USAGE:
#   constitution.sh version <personas.json> <authz-matrix.json>
#       Prints a deterministic hex digest over the canonical role state:
#       personas sorted by `id`, each reduced to "<id>|<role>|<plane>" (the
#       `auth` field is EXCLUDED — credentials aren't identity and rotate),
#       newline-joined; then authz-matrix rows sorted by `entity`, each
#       reduced to "<entity>|<owningChain joined by ,>|<sorted 'role:scope'
#       pairs joined by ,>" (roleScope VALUES are included, not just keys —
#       an `admin: owns -> read-scoped` narrowing bumps the version),
#       newline-joined. The two blocks are concatenated with a `--` separator
#       line and hashed. Byte-identical across engines (jq and python3 both
#       build the exact same canonical string; only the final digest step
#       requires python3 — see the DIGEST note below).
#
#   constitution.sh diff <prev-state.json> <curr-state.json>
#       Prints JSON {added:[roleIds], removed:[roleIds], changed:[{id, was,
#       now}]} comparing two canonical-state objects (`{roles:[{id,role,
#       plane}], version}`). `changed` = same `id`, differing `role` or
#       `plane`. An empty/missing-fields prev (e.g. `{}`) is treated as
#       having zero roles, so every current role is `added`.
#
#   constitution.sh state <personas.json> <version>
#       Prints the machine state JSON {roles:[{id,role,plane}] sorted by id,
#       version} (the `auth` field is dropped — same exclusion as `version`).
#       This is the authoritative state; a caller persists it to the sibling
#       file `.qa/constitution.state.json` (this script only prints it).
#
#   constitution.sh render <personas.json> <version> <template> <timestamp>
#       Prints the filled constitution.md: <template> with `{{ROLES_TABLE}}`
#       (a Markdown `| id | role | plane |` table, one row per persona,
#       sorted by id), `{{VERSION}}`, and `{{TIMESTAMP}}` substituted.
#       HUMAN-ONLY — emits no fenced/machine state block; the machine state
#       lives in the sibling `.qa/constitution.state.json` written via the
#       `state` subcommand (R3-Q4). Deterministic given its arguments.
#
# DIGEST NOTE: the canonical-string construction (the part that must be
# order-independent, auth-independent, and identical across engines) is
# built by whichever engine is selected (jq or python3, per QA_ENGINE/
# auto-detect below). The final string -> hex-digest step always shells out
# to `python3 hashlib.sha256(...).hexdigest()[:16]` regardless of which
# engine built the string — python3 is already a hard dependency of this
# repo's other scripts (see journal.sh), so this adds no new dependency,
# and guarantees the digest itself (not just the canonical string) is
# byte-identical across QA_ENGINE=jq and QA_ENGINE=python3 runs.
#
# DEPENDENCIES: bash, coreutils (mkdir, mv, cat, dirname), and EITHER jq OR
#               python3 for canonical-string construction (jq preferred;
#               python3 fallback) PLUS python3 specifically for the version
#               digest (see DIGEST NOTE). No node, no perl, no grep -P.
#               Honors QA_ENGINE the same way journal.sh/ux-conventions.sh
#               do.

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE (unset by default): python3 forces the python3 branch even if
# jq is on PATH; jq forces the jq branch; unset/anything else = auto-detect
# (jq if present, else python3) — same contract as journal.sh's has_jq.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

has_py() { command -v python3 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# canonical_string <personas.json> <authz-matrix.json>
#
# Builds the canonical role-state string described in the header, on stdout.
# Identical bytes regardless of which engine (jq/python3) builds it.
# ---------------------------------------------------------------------------
canonical_string() {
  local personas="$1" matrix="$2"

  if has_jq; then
    jq -n --slurpfile p "$personas" --slurpfile m "$matrix" -r '
      ($p[0]) as $personas
      | ($m[0]) as $matrix
      | ($personas
          | map({id: .id, role: .role, plane: .plane})
          | sort_by(.id)
          | map(.id + "|" + .role + "|" + .plane)
          | join("\n")) as $pBlock
      | ($matrix
          | map(
              . as $row
              | ($row.roleScope // {}) as $rs
              | ($rs | keys | sort | map(. + ":" + ($rs[.] | tostring)) | join(",")) as $rsStr
              | (($row.owningChain // []) | join(",")) as $ocStr
              | ($row.entity + "|" + $ocStr + "|" + $rsStr)
            )
          | sort
          | join("\n")) as $mBlock
      | $pBlock + "\n--\n" + $mBlock
    ' || die "canonical_string: jq failed (are '${personas}'/'${matrix}' valid JSON?)."
  elif has_py; then
    python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    personas = json.load(f)
with open(sys.argv[2]) as f:
    matrix = json.load(f)

p_lines = sorted(
    "{}|{}|{}".format(p["id"], p["role"], p["plane"]) for p in personas
)
p_block = "\n".join(p_lines)

m_lines = []
for row in matrix:
    rs = row.get("roleScope") or {}
    rs_str = ",".join("{}:{}".format(k, rs[k]) for k in sorted(rs.keys()))
    oc_str = ",".join(row.get("owningChain") or [])
    m_lines.append("{}|{}|{}".format(row["entity"], oc_str, rs_str))
m_block = "\n".join(sorted(m_lines))

sys.stdout.write(p_block + "\n--\n" + m_block)
' "$personas" "$matrix" || die "canonical_string: python3 failed (are '${personas}'/'${matrix}' valid JSON?)."
  else
    die "constitution.sh needs either 'jq' or 'python3' to build the canonical role-state string."
  fi
}

# ---------------------------------------------------------------------------
# cmd_version <personas.json> <authz-matrix.json>
# ---------------------------------------------------------------------------
cmd_version() {
  [[ $# -ge 2 ]] || die "version requires: <personas.json> <authz-matrix.json>"
  local personas="$1" matrix="$2"
  [[ -f "$personas" ]] || die "version: no such file '${personas}'."
  [[ -f "$matrix" ]] || die "version: no such file '${matrix}'."

  has_py || die "constitution.sh version requires python3 for the digest step (see DIGEST NOTE)."

  # Capture via command substitution (NOT a direct pipe): $(...) strips all
  # trailing newlines uniformly regardless of which engine produced the
  # string, so `jq -r` (which always emits a trailing newline) and the
  # python3 branch (which does not) feed byte-identical content into the
  # digest. A direct pipe here would let a jq-vs-python3 trailing-newline
  # difference silently produce two different hashes for the same logical
  # state.
  local canon
  canon="$(canonical_string "$personas" "$matrix")" || die "version: failed to build the canonical string."
  printf '%s' "$canon" | python3 -c '
import hashlib, sys
data = sys.stdin.read()
print(hashlib.sha256(data.encode()).hexdigest()[:16])
' || die "version: failed to compute the digest."
}

# ---------------------------------------------------------------------------
# cmd_state <personas.json> <version>
# ---------------------------------------------------------------------------
cmd_state() {
  [[ $# -ge 2 ]] || die "state requires: <personas.json> <version>"
  local personas="$1" version="$2"
  [[ -f "$personas" ]] || die "state: no such file '${personas}'."

  if has_jq; then
    jq -n --slurpfile p "$personas" --arg version "$version" '
      {
        roles: ($p[0]
          | map({id: .id, role: .role, plane: .plane})
          | sort_by(.id)),
        version: $version
      }
    ' || die "state: jq failed (is '${personas}' valid JSON?)."
  elif has_py; then
    python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    personas = json.load(f)
version = sys.argv[2]

roles = sorted(
    ({"id": p["id"], "role": p["role"], "plane": p["plane"]} for p in personas),
    key=lambda r: r["id"],
)
print(json.dumps({"roles": roles, "version": version}))
' "$personas" "$version" || die "state: python3 failed (is '${personas}' valid JSON?)."
  else
    die "constitution.sh needs either 'jq' or 'python3' to build the state JSON."
  fi
}

# ---------------------------------------------------------------------------
# cmd_diff <prev-state.json> <curr-state.json>
# ---------------------------------------------------------------------------
cmd_diff() {
  [[ $# -ge 2 ]] || die "diff requires: <prev-state.json> <curr-state.json>"
  local prev="$1" curr="$2"
  [[ -f "$prev" ]] || die "diff: no such file '${prev}'."
  [[ -f "$curr" ]] || die "diff: no such file '${curr}'."

  if has_jq; then
    jq -n --slurpfile prev "$prev" --slurpfile curr "$curr" '
      (($prev[0].roles) // []) as $prevRoles
      | (($curr[0].roles) // []) as $currRoles
      | ($prevRoles | map({(.id): .}) | add // {}) as $prevById
      | ($currRoles | map({(.id): .}) | add // {}) as $currById
      | ($currRoles | map(.id) | map(select(($prevById[.]) == null))) as $added
      | ($prevRoles | map(.id) | map(select(($currById[.]) == null))) as $removed
      | ($currRoles
          | map(select(($prevById[.id]) != null))
          | map(select(($prevById[.id].role != .role) or ($prevById[.id].plane != .plane)))
          | map({id: .id, was: $prevById[.id], now: .})
        ) as $changed
      | {added: $added, removed: $removed, changed: $changed}
    ' || die "diff: jq failed (are '${prev}'/'${curr}' valid JSON?)."
  elif has_py; then
    python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    prev = json.load(f)
with open(sys.argv[2]) as f:
    curr = json.load(f)

prev_roles = prev.get("roles") or []
curr_roles = curr.get("roles") or []

prev_by_id = {r["id"]: r for r in prev_roles}
curr_by_id = {r["id"]: r for r in curr_roles}

added = [r["id"] for r in curr_roles if r["id"] not in prev_by_id]
removed = [r["id"] for r in prev_roles if r["id"] not in curr_by_id]
changed = []
for r in curr_roles:
    was = prev_by_id.get(r["id"])
    if was is None:
        continue
    if was.get("role") != r.get("role") or was.get("plane") != r.get("plane"):
        changed.append({"id": r["id"], "was": was, "now": r})

print(json.dumps({"added": added, "removed": removed, "changed": changed}))
' "$prev" "$curr" || die "diff: python3 failed (are '${prev}'/'${curr}' valid JSON?)."
  else
    die "constitution.sh needs either 'jq' or 'python3' to compute the diff."
  fi
}

# ---------------------------------------------------------------------------
# cmd_render <personas.json> <version> <template> <timestamp>
# ---------------------------------------------------------------------------
cmd_render() {
  [[ $# -ge 4 ]] || die "render requires: <personas.json> <version> <template> <timestamp>"
  local personas="$1" version="$2" template="$3" timestamp="$4"
  [[ -f "$personas" ]] || die "render: no such file '${personas}'."
  [[ -f "$template" ]] || die "render: no such file '${template}'."

  local roles_table
  if has_jq; then
    roles_table="$(jq -r --slurpfile p "$personas" -n '
      ($p[0]
        | map({id: .id, role: .role, plane: .plane})
        | sort_by(.id)
        | map("| " + .id + " | " + .role + " | " + .plane + " |")
        | join("\n"))
    ')" || die "render: jq failed to build the roles table (is '${personas}' valid JSON?)."
  elif has_py; then
    roles_table="$(python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    personas = json.load(f)

rows = sorted(
    ({"id": p["id"], "role": p["role"], "plane": p["plane"]} for p in personas),
    key=lambda r: r["id"],
)
print("\n".join("| {} | {} | {} |".format(r["id"], r["role"], r["plane"]) for r in rows))
' "$personas")" || die "render: python3 failed to build the roles table (is '${personas}' valid JSON?)."
  else
    die "constitution.sh needs either 'jq' or 'python3' to build the roles table."
  fi

  # Pure-bash placeholder substitution (no grep -P/perl/node): read the
  # template as a single string and do literal find/replace via bash
  # parameter expansion. Order matters only in that each placeholder is
  # distinct, so sequential replacement is safe.
  local template_content
  template_content="$(cat "$template")"
  template_content="${template_content//\{\{ROLES_TABLE\}\}/$roles_table}"
  template_content="${template_content//\{\{VERSION\}\}/$version}"
  template_content="${template_content//\{\{TIMESTAMP\}\}/$timestamp}"
  printf '%s\n' "$template_content"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: constitution.sh version <personas.json> <authz-matrix.json>
       constitution.sh diff <prev-state.json> <curr-state.json>
       constitution.sh state <personas.json> <version>
       constitution.sh render <personas.json> <version> <template> <timestamp>"
  local cmd="$1"; shift
  case "$cmd" in
    version) cmd_version "$@" ;;
    diff)    cmd_diff "$@" ;;
    state)   cmd_state "$@" ;;
    render)  cmd_render "$@" ;;
    *) die "Unknown subcommand '${cmd}' (expected: version|diff|state|render)." ;;
  esac
}

main "$@"
