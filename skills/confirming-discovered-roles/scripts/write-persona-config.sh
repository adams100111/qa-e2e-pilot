#!/usr/bin/env bash
# write-persona-config.sh — deterministic REGENERATE-not-reconcile writer for
# the confirmed persona set + authz matrix produced by confirming-discovered-roles'
# 3-round HITL (roles -> credentials -> scope). Never hand-author the config or
# the matrix file directly; always call this script (mirrors
# bootstrapping-qa-config/scripts/init-config.sh's own rule).
#
# USAGE:
#   write-persona-config.sh --personas-file <path> --matrix-file <path>
#       [--config .qa/config.json] [--matrix-out .qa/authz-matrix.json]
#
# --personas-file  JSON array of confirmed personas (Round 1 + Round 2 output),
#                  one object per role that survived confirmation:
#                    [{ "id": "admin", "role": "admin", "plane": "global",
#                       "auth": "qa.admin@<host> (seeded credential)" }, ...]
#                  REPLACES any existing `personas` key in --config wholesale
#                  (regenerate, not reconcile — Decision 5). `auth` is a
#                  credential descriptor/citation only — never a password.
#
# --matrix-file    JSON array of confirmed authz-matrix rows (Round 3 output):
#                    [{ "entity": "submission",
#                       "owningChain": ["team_id", "hackathon_id"],
#                       "roleScope": { "admin": "owns", "evaluator": "read-scoped" } }]
#                  Written whole to --matrix-out, REPLACING any prior file —
#                  regenerate, not reconcile.
#
# Validates before writing anything:
#   - every persona has {id, role, plane in global|contextual, auth}
#   - every matrix row has {entity (string), owningChain (non-empty array),
#     roleScope (object)}, and every roleScope key names a persona id that
#     actually survived --personas-file (fails loud rather than writing a
#     matrix that references a persona nobody confirmed / an orphan)
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3.
set -euo pipefail

CONFIG=".qa/config.json"
MATRIX_OUT=".qa/authz-matrix.json"
PERSONAS_FILE=""
MATRIX_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --personas-file) PERSONAS_FILE="$2"; shift 2 ;;
    --matrix-file)   MATRIX_FILE="$2"; shift 2 ;;
    --config)        CONFIG="$2"; shift 2 ;;
    --matrix-out)    MATRIX_OUT="$2"; shift 2 ;;
    *) echo "write-persona-config: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$PERSONAS_FILE" && -f "$PERSONAS_FILE" ]] || { echo "write-persona-config: --personas-file <path> is required and must exist" >&2; exit 2; }
[[ -n "$MATRIX_FILE" && -f "$MATRIX_FILE" ]] || { echo "write-persona-config: --matrix-file <path> is required and must exist" >&2; exit 2; }
[[ -f "$CONFIG" ]] || { echo "write-persona-config: $CONFIG does not exist -- run bootstrapping-qa-config first" >&2; exit 3; }

have() { command -v "$1" >/dev/null 2>&1; }

if have jq; then
  jq -e 'type=="array" and length>0 and all(.[]; has("id") and has("role") and has("plane") and has("auth") and (.plane=="global" or .plane=="contextual"))' \
     "$PERSONAS_FILE" >/dev/null || { echo "write-persona-config: personas-file failed shape validation (need id/role/plane[global|contextual]/auth on every entry)" >&2; exit 4; }

  persona_ids="$(jq -c '[.[].id]' "$PERSONAS_FILE")"
  jq -e --argjson ids "$persona_ids" '
    type=="array" and length>0 and
    all(.[]; has("entity") and has("owningChain") and has("roleScope")
        and (.owningChain|type=="array") and (.owningChain|length>0)
        and (.roleScope|type=="object")
        and ((.roleScope|keys) - $ids | length == 0))
  ' "$MATRIX_FILE" >/dev/null || { echo "write-persona-config: matrix-file failed shape/reference validation (every roleScope key must be a confirmed persona id; owningChain must be a non-empty array)" >&2; exit 4; }

  tmp_cfg="$(mktemp)"
  jq --slurpfile personas "$PERSONAS_FILE" '.personas = $personas[0]' "$CONFIG" > "$tmp_cfg"
  mv "$tmp_cfg" "$CONFIG"
  jq '.' "$MATRIX_FILE" > "$MATRIX_OUT"

  n_personas="$(jq 'length' "$PERSONAS_FILE")"
  n_rows="$(jq 'length' "$MATRIX_FILE")"
  echo "Wrote $n_personas persona(s) into $CONFIG; wrote $n_rows authz-matrix row(s) to $MATRIX_OUT"

elif have python3; then
  python3 - "$PERSONAS_FILE" "$MATRIX_FILE" "$CONFIG" "$MATRIX_OUT" <<'PYEOF'
import json, sys

personas_file, matrix_file, config_file, matrix_out = sys.argv[1:5]

with open(personas_file) as f:
    personas = json.load(f)
if not isinstance(personas, list) or not personas:
    sys.exit("write-persona-config: personas-file must be a non-empty JSON array")
for p in personas:
    if not all(k in p for k in ("id", "role", "plane", "auth")) or p.get("plane") not in ("global", "contextual"):
        sys.exit("write-persona-config: personas-file failed shape validation (need id/role/plane[global|contextual]/auth on every entry)")
persona_ids = {p["id"] for p in personas}

with open(matrix_file) as f:
    matrix = json.load(f)
if not isinstance(matrix, list) or not matrix:
    sys.exit("write-persona-config: matrix-file must be a non-empty JSON array")
for row in matrix:
    if not all(k in row for k in ("entity", "owningChain", "roleScope")):
        sys.exit("write-persona-config: matrix-file failed shape validation (need entity/owningChain/roleScope on every row)")
    if not isinstance(row["owningChain"], list) or not row["owningChain"]:
        sys.exit("write-persona-config: matrix-file row owningChain must be a non-empty array")
    if not isinstance(row["roleScope"], dict):
        sys.exit("write-persona-config: matrix-file row roleScope must be an object")
    unknown = sorted(set(row["roleScope"].keys()) - persona_ids)
    if unknown:
        sys.exit(f"write-persona-config: matrix-file references unconfirmed persona id(s): {unknown}")

with open(config_file) as f:
    config = json.load(f)
config["personas"] = personas
with open(config_file, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

with open(matrix_out, "w") as f:
    json.dump(matrix, f, indent=2)
    f.write("\n")

print(f"Wrote {len(personas)} persona(s) into {config_file}; wrote {len(matrix)} authz-matrix row(s) to {matrix_out}")
PYEOF
else
  echo "write-persona-config: needs either 'jq' or 'python3'." >&2
  exit 5
fi
