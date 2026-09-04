#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/spec-snapshot.sh (create / drift).
# Mirrors tests/constitution/run.sh. Applies increment-1 lessons proactively:
# a cross-engine byte-identity check and malformed-input symmetry are first-class.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/spec-snapshot.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

# constitution state: two roles + a version (the shape constitution.sh `state` emits)
STATE='{"roles":[{"id":"admin","role":"admin","plane":"global"},{"id":"viewer","role":"viewer","plane":"contextual"}],"version":"cver1"}'

run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' "$STATE" > "$T/state.json"

  # create, no overrides -> spec-roles.json copies the state's roles + stamps its version
  mkdir -p "$T/s1"
  QA_ENGINE=$E bash "$SH" create "$T/state.json" "$T/s1" >/dev/null
  check "$E create writes spec-roles.json" "$([ -f "$T/s1/spec-roles.json" ] && echo y)" "y"
  check "$E create stamps constitutionVersion" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["constitutionVersion"])' "$T/s1/spec-roles.json")" "cver1"
  check "$E create copies both roles" \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["roles"]))' "$T/s1/spec-roles.json")" "2"
  check "$E create overrides null when none" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["overrides"] is None)' "$T/s1/spec-roles.json")" "True"

  # subset -> only the listed ids
  mkdir -p "$T/s2"; printf '%s' '{"subset":["admin"]}' > "$T/ov_subset.json"
  QA_ENGINE=$E bash "$SH" create "$T/state.json" "$T/s2" "$T/ov_subset.json" >/dev/null
  check "$E subset keeps only admin" \
    "$(python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["roles"];print(",".join(x["id"] for x in r))' "$T/s2/spec-roles.json")" "admin"

  # add -> appended; adding an existing id dies
  mkdir -p "$T/s3"; printf '%s' '{"add":[{"id":"bot","role":"bot","plane":"global"}]}' > "$T/ov_add.json"
  QA_ENGINE=$E bash "$SH" create "$T/state.json" "$T/s3" "$T/ov_add.json" >/dev/null
  check "$E add appends bot" \
    "$(python3 -c 'import json,sys;print(any(x["id"]=="bot" for x in json.load(open(sys.argv[1]))["roles"]))' "$T/s3/spec-roles.json")" "True"
  mkdir -p "$T/s3b"; printf '%s' '{"add":[{"id":"admin","role":"x","plane":"global"}]}' > "$T/ov_addc.json"
  QA_ENGINE=$E bash "$SH" create "$T/state.json" "$T/s3b" "$T/ov_addc.json" >/dev/null 2>&1
  check "$E add colliding id dies" "$?" "1"

  # modify -> patches plane, leaves role
  mkdir -p "$T/s4"; printf '%s' '{"modify":[{"id":"admin","plane":"contextual"}]}' > "$T/ov_mod.json"
  QA_ENGINE=$E bash "$SH" create "$T/state.json" "$T/s4" "$T/ov_mod.json" >/dev/null
  check "$E modify patches admin plane" \
    "$(python3 -c 'import json,sys;a=[x for x in json.load(open(sys.argv[1]))["roles"] if x["id"]=="admin"][0];print(a["plane"],a["role"])' "$T/s4/spec-roles.json")" "contextual admin"

  # drift
  local d; d="$(QA_ENGINE=$E bash "$SH" drift "$T/s1/spec-roles.json" "cver1")"
  check "$E drift equal -> not stale" "$(printf '%s' "$d" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stale"])')" "False"
  d="$(QA_ENGINE=$E bash "$SH" drift "$T/s1/spec-roles.json" "cver2")"
  check "$E drift differ -> stale" "$(printf '%s' "$d" | python3 -c 'import json,sys;o=json.load(sys.stdin);print(o["stale"],o["stamped"],o["current"])')" "True cver1 cver2"

  # malformed state (no roles key) -> die
  printf '%s' '{"version":"v"}' > "$T/bad.json"; mkdir -p "$T/sb"
  QA_ENGINE=$E bash "$SH" create "$T/bad.json" "$T/sb" >/dev/null 2>&1
  check "$E malformed state dies" "$?" "1"
  # add missing a required field (plane) -> die identically on both engines
  mkdir -p "$T/sc"; printf '%s' '{"add":[{"id":"x","role":"r"}]}' > "$T/ov_bad.json"
  QA_ENGINE=$E bash "$SH" create "$T/state.json" "$T/sc" "$T/ov_bad.json" >/dev/null 2>&1
  check "$E add missing plane dies" "$?" "1"
  rm -rf "$T"
}

command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3

# cross-engine byte-identity: same inputs -> identical spec-roles.json under jq and python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' "$STATE" > "$X/state.json"
  printf '%s' '{"add":[{"id":"zeta","role":"z","plane":"global"}],"modify":[{"id":"viewer","role":"reader"}]}' > "$X/ov.json"
  mkdir -p "$X/j" "$X/p"
  QA_ENGINE=jq      bash "$SH" create "$X/state.json" "$X/j" "$X/ov.json" >/dev/null
  QA_ENGINE=python3 bash "$SH" create "$X/state.json" "$X/p" "$X/ov.json" >/dev/null
  check "cross-engine spec-roles.json identical" "$(diff "$X/j/spec-roles.json" "$X/p/spec-roles.json" >/dev/null && echo same || echo diff)" "same"
  rm -rf "$X"
fi

echo "spec-snapshot: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
