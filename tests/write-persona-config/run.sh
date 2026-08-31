#!/usr/bin/env bash
# Tests for write-persona-config.sh — pins the validation added after the
# post-merge audit (task #33):
#   (A) roleScope VALUES must be a closed enum {owns, read-scoped, none};
#       an off-enum value silently reads as non-isolating in
#       generating-qa-checklist and disables the cross-role isolation probe
#       (fail-open leak). Must be REJECTED.
#   (B) persona ids must be UNIQUE (ADR-0012 checkpoint key (criterion,persona)).
# Runs every case twice: once on the jq path (default) and once forcing the
# python3 path (PATH holding only python3) — parity is required (lesson of
# the earlier jq/python divergence, Fix #27).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../skills/confirming-discovered-roles/scripts/write-persona-config.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A fake PATH holding ONLY python3 (+ its real dir deps) so `command -v jq`
# fails and the script takes its python3 branch. The python branch shells out
# to nothing but python3, so a lone symlink suffices.
FAKEBIN="$WORK/pybin"
mkdir -p "$FAKEBIN"
ln -s "$(command -v python3)" "$FAKEBIN/python3"
BASH_ABS="$(command -v bash)"

# Minimal valid config the script mutates in place.
seed_config() { printf '{\n  "baseUrl": "http://localhost:3000",\n  "personas": []\n}\n' > "$1"; }

PERSONAS_OK='[{"id":"admin","role":"admin","plane":"global","auth":"qa.admin (seeded)"},
              {"id":"user","role":"user","plane":"contextual","auth":"qa.user (seeded)"}]'
PERSONAS_DUP='[{"id":"admin","role":"admin","plane":"global","auth":"a"},
               {"id":"admin","role":"reviewer","plane":"global","auth":"b"}]'
MATRIX_OK='[{"entity":"submission","owningChain":["team_id"],"roleScope":{"admin":"owns","user":"none"}}]'
MATRIX_BADSCOPE='[{"entity":"submission","owningChain":["team_id"],"roleScope":{"admin":"owns","user":"read"}}]'
MATRIX_UNKNOWN='[{"entity":"submission","owningChain":["team_id"],"roleScope":{"ghost":"none"}}]'

# run_case <label> <force-python:0|1> <personas-json> <matrix-json> -> sets RC, ERR, and writes CFG/MTX
run_case() {
  local label="$1" force_py="$2" personas="$3" matrix="$4"
  local d="$WORK/$label"; mkdir -p "$d"
  local pf="$d/personas.json" mf="$d/matrix.json" cfg="$d/config.json" mtx="$d/authz-matrix.json"
  printf '%s\n' "$personas" > "$pf"
  printf '%s\n' "$matrix"   > "$mf"
  seed_config "$cfg"
  if [[ "$force_py" == "1" ]]; then
    # env + absolute bash so ONLY the script's internal command lookups see the
    # jq-less PATH (a bare `PATH=.. bash` would search for `bash` itself in it).
    ERR="$(env PATH="$FAKEBIN" "$BASH_ABS" "$SCRIPT" --personas-file "$pf" --matrix-file "$mf" --config "$cfg" --matrix-out "$mtx" 2>&1)"; RC=$?
  else
    ERR="$(bash "$SCRIPT" --personas-file "$pf" --matrix-file "$mf" --config "$cfg" --matrix-out "$mtx" 2>&1)"; RC=$?
  fi
  LAST_CFG="$cfg"; LAST_MTX="$mtx"
}

for path_mode in jq py; do
  fp=0; [[ "$path_mode" == "py" ]] && fp=1

  # --- happy path: valid enum + unique ids -> writes both files, RC 0 --------
  run_case "ok-$path_mode" "$fp" "$PERSONAS_OK" "$MATRIX_OK"
  check "[$path_mode] happy path exits 0"                 "$RC" "0"
  check "[$path_mode] happy path wrote personas to config" "$(python3 -c "import json,sys;print(len(json.load(open('$LAST_CFG'))['personas']))" 2>/dev/null)" "2"
  check "[$path_mode] happy path wrote matrix-out"          "$([[ -f "$LAST_MTX" ]] && echo yes)" "yes"

  # --- (A) invalid roleScope value 'read' -> REJECTED, nonzero ---------------
  run_case "badscope-$path_mode" "$fp" "$PERSONAS_OK" "$MATRIX_BADSCOPE"
  check "[$path_mode] invalid roleScope value rejected"    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$path_mode] badscope msg mentions allowed enum"  "$(echo "$ERR" | grep -qiE 'owns|read-scoped|none' && echo yes)" "yes"

  # --- (B) duplicate persona id -> REJECTED, nonzero -------------------------
  run_case "dup-$path_mode" "$fp" "$PERSONAS_DUP" "$MATRIX_OK"
  check "[$path_mode] duplicate persona id rejected"       "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$path_mode] dup msg mentions duplicate"          "$(echo "$ERR" | grep -qi 'duplicate' && echo yes)" "yes"

  # --- regression: unknown persona id in roleScope still rejected ------------
  run_case "unknown-$path_mode" "$fp" "$PERSONAS_OK" "$MATRIX_UNKNOWN"
  check "[$path_mode] unknown persona id still rejected"    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
done

echo
echo "write-persona-config tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
