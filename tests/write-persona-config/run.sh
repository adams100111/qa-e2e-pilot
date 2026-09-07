#!/usr/bin/env bash
# Tests for write-persona-config.sh — pins the validation added after the
# post-merge audit (task #33), plus the audit-2 W3-4 fixes:
#   (A) roleScope VALUES must be a closed enum {owns, read-scoped, none};
#       an off-enum value silently reads as non-isolating in
#       generating-qa-checklist and disables the cross-role isolation probe
#       (fail-open leak). Must be REJECTED.
#   (B) persona ids must be UNIQUE (ADR-0012 checkpoint key (criterion,persona)).
#   (C) an empty authz matrix is rejected (exit 4) UNLESS --allow-empty is
#       passed (weak-signal/single-user degrade path, SKILL.md Eval 2);
#       WITHOUT the flag it stays rejected even with the flag omitted on a
#       personas-file that is itself empty (--allow-empty never relaxes the
#       personas-file's own non-empty requirement).
#   (D) wholesale personas regeneration preserves operator-only
#       `expectedSubject` per persona id (merge, not clobber) while
#       discovered fields (auth/role/plane) still regenerate, and a persona
#       id dropped from --personas-file still disappears from the config
#       (ADR-0011 wholesale semantics intact).
# Runs every case twice: once on the jq path (default) and once forcing the
# python3 path (PATH holding only python3) — parity is required (lesson of
# the earlier jq/python divergence, Fix #27). (D) additionally diffs the two
# engines' written config bytes directly for the same inputs.
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
PERSONAS_EMPTY='[]'
MATRIX_OK='[{"entity":"submission","owningChain":["team_id"],"roleScope":{"admin":"owns","user":"none"}}]'
MATRIX_BADSCOPE='[{"entity":"submission","owningChain":["team_id"],"roleScope":{"admin":"owns","user":"read"}}]'
MATRIX_UNKNOWN='[{"entity":"submission","owningChain":["team_id"],"roleScope":{"ghost":"none"}}]'
MATRIX_EMPTY='[]'

# Seed config for the expectedSubject-preservation case: admin + reviewer
# already have an operator-set expectedSubject; reviewer is about to be
# dropped upstream (not in PRESERVE_PERSONAS below).
PRESERVE_SEED='{
  "baseUrl": "http://localhost:3000",
  "personas": [
    { "id": "admin", "role": "admin", "plane": "global", "auth": "old-auth", "expectedSubject": "admin@corp.example" },
    { "id": "reviewer", "role": "reviewer", "plane": "global", "auth": "old-auth-2", "expectedSubject": "rev@corp.example" }
  ]
}'
# admin's auth is DISCOVERED and must regenerate; user is a brand-new
# persona that never had an expectedSubject; reviewer is gone.
PRESERVE_PERSONAS='[{"id":"admin","role":"admin","plane":"global","auth":"new-auth"},
                    {"id":"user","role":"user","plane":"contextual","auth":"new-auth-user"}]'

# run_case <label> <force-python:0|1> <personas-json> <matrix-json> [extra-arg...]
# -> sets RC, ERR, and writes CFG/MTX. Extra args (e.g. --allow-empty) are
# appended verbatim to the script invocation.
run_case() {
  local label="$1" force_py="$2" personas="$3" matrix="$4"; shift 4
  local extra_args=("$@")
  local d="$WORK/$label"; mkdir -p "$d"
  local pf="$d/personas.json" mf="$d/matrix.json" cfg="$d/config.json" mtx="$d/authz-matrix.json"
  printf '%s\n' "$personas" > "$pf"
  printf '%s\n' "$matrix"   > "$mf"
  seed_config "$cfg"
  if [[ "$force_py" == "1" ]]; then
    # env + absolute bash so ONLY the script's internal command lookups see the
    # jq-less PATH (a bare `PATH=.. bash` would search for `bash` itself in it).
    ERR="$(env PATH="$FAKEBIN" "$BASH_ABS" "$SCRIPT" --personas-file "$pf" --matrix-file "$mf" --config "$cfg" --matrix-out "$mtx" "${extra_args[@]}" 2>&1)"; RC=$?
  else
    ERR="$(bash "$SCRIPT" --personas-file "$pf" --matrix-file "$mf" --config "$cfg" --matrix-out "$mtx" "${extra_args[@]}" 2>&1)"; RC=$?
  fi
  LAST_CFG="$cfg"; LAST_MTX="$mtx"
}

# run_case_seeded <label> <force-python:0|1> -> like run_case but seeds CFG
# from PRESERVE_SEED (an existing config with operator-set expectedSubject)
# instead of the empty default, and drives PRESERVE_PERSONAS/MATRIX_OK.
run_case_seeded() {
  local label="$1" force_py="$2"
  local d="$WORK/$label"; mkdir -p "$d"
  local pf="$d/personas.json" mf="$d/matrix.json" cfg="$d/config.json" mtx="$d/authz-matrix.json"
  printf '%s\n' "$PRESERVE_PERSONAS" > "$pf"
  printf '%s\n' "$MATRIX_OK"         > "$mf"
  printf '%s\n' "$PRESERVE_SEED"     > "$cfg"
  if [[ "$force_py" == "1" ]]; then
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

  # --- (C) negative control: empty matrix WITHOUT --allow-empty still rejected ---
  # jq leg exits its documented 4 for every validation failure; the python3
  # leg's sys.exit(<message>) always yields 1 (pre-existing convention, same
  # as every other validation failure in this script) -- only jq's exit code
  # is pinned exactly, both legs are pinned nonzero.
  run_case "emptymatrix-$path_mode" "$fp" "$PERSONAS_OK" "$MATRIX_EMPTY"
  check "[$path_mode] empty matrix w/o flag rejected"       "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  if [[ "$path_mode" == "jq" ]]; then
    check "[jq] empty matrix w/o flag exit code 4" "$RC" "4"
  fi
  check "[$path_mode] empty matrix msg mentions --allow-empty" "$(echo "$ERR" | grep -qi 'allow-empty' && echo yes)" "yes"

  # --- (C) --allow-empty permits an empty matrix: exit 0, writes [] --------
  run_case "emptymatrix-flag-$path_mode" "$fp" "$PERSONAS_OK" "$MATRIX_EMPTY" --allow-empty
  check "[$path_mode] empty matrix + --allow-empty exits 0" "$RC" "0"
  check "[$path_mode] empty matrix + --allow-empty writes []" "$(cat "$LAST_MTX")" "[]"
  check "[$path_mode] empty matrix + --allow-empty still wrote personas" \
    "$(python3 -c "import json,sys;print(len(json.load(open('$LAST_CFG'))['personas']))" 2>/dev/null)" "2"

  # --- (C) --allow-empty never relaxes the PERSONAS-file's own requirement ---
  run_case "emptypersonas-flag-$path_mode" "$fp" "$PERSONAS_EMPTY" "$MATRIX_OK" --allow-empty
  check "[$path_mode] empty personas-file still rejected even with --allow-empty" \
    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"

  # --- (D) wholesale regen preserves expectedSubject per persona id, regenerates
  #         discovered fields, and drops a persona removed upstream -----------
  run_case_seeded "preserve-$path_mode" "$fp"
  check "[$path_mode] preserve-expectedSubject case exits 0" "$RC" "0"
  check "[$path_mode] admin keeps expectedSubject" \
    "$(python3 -c "import json;d=json.load(open('$LAST_CFG'))['personas'];print(next(p.get('expectedSubject') for p in d if p['id']=='admin'))" 2>/dev/null)" \
    "admin@corp.example"
  check "[$path_mode] admin's discovered auth regenerated" \
    "$(python3 -c "import json;d=json.load(open('$LAST_CFG'))['personas'];print(next(p['auth'] for p in d if p['id']=='admin'))" 2>/dev/null)" \
    "new-auth"
  check "[$path_mode] reviewer (dropped upstream) is gone" \
    "$(python3 -c "import json;d=json.load(open('$LAST_CFG'))['personas'];print('reviewer' in [p['id'] for p in d])" 2>/dev/null)" \
    "False"
  check "[$path_mode] new persona 'user' has no expectedSubject" \
    "$(python3 -c "import json;d=json.load(open('$LAST_CFG'))['personas'];print('expectedSubject' in next(p for p in d if p['id']=='user'))" 2>/dev/null)" \
    "False"

  if [[ "$path_mode" == "jq" ]]; then
    PRESERVE_CFG_JQ="$(cat "$LAST_CFG")"
  else
    PRESERVE_CFG_PY="$(cat "$LAST_CFG")"
  fi
done

# --- (D) dual-engine byte parity: same inputs -> byte-identical config.json ---
check "preserve case: jq and python3 legs write byte-identical config.json" \
  "$([[ "$PRESERVE_CFG_JQ" == "$PRESERVE_CFG_PY" ]] && echo yes)" "yes"

echo
echo "write-persona-config tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
