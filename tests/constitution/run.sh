#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../scripts/qa-kit/constitution.sh"   # adjust to chosen location
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' '[{"id":"admin","role":"admin","plane":"global","auth":"a@x (seeded)"},{"id":"viewer","role":"viewer","plane":"contextual","auth":"v@x (seeded)"}]' > "$T/p.json"
  printf '%s' '[{"entity":"submission","owningChain":["team_id"],"roleScope":{"admin":"owns","viewer":"read-scoped"}}]' > "$T/m.json"
  # version is deterministic + engine-stable + auth-independent
  local v1 v2; v1="$(QA_ENGINE=$E bash "$SH" version "$T/p.json" "$T/m.json")"
  printf '%s' '[{"id":"admin","role":"admin","plane":"global","auth":"DIFFERENT (seeded)"},{"id":"viewer","role":"viewer","plane":"contextual","auth":"v@x (seeded)"}]' > "$T/p2.json"
  v2="$(QA_ENGINE=$E bash "$SH" version "$T/p2.json" "$T/m.json")"
  check "$E version non-empty" "$([ -n "$v1" ] && echo y)" "y"
  check "$E version auth-independent" "$v1" "$v2"
  # order-independent: reordered personas -> same version
  printf '%s' '[{"id":"viewer","role":"viewer","plane":"contextual","auth":"v@x (seeded)"},{"id":"admin","role":"admin","plane":"global","auth":"a@x (seeded)"}]' > "$T/p3.json"
  check "$E version order-independent" "$(QA_ENGINE=$E bash "$SH" version "$T/p3.json" "$T/m.json")" "$v1"
  # a role change -> different version
  printf '%s' '[{"id":"admin","role":"superadmin","plane":"global","auth":"a@x (seeded)"},{"id":"viewer","role":"viewer","plane":"contextual","auth":"v@x (seeded)"}]' > "$T/p4.json"
  check "$E role-change changes version" "$([ "$(QA_ENGINE=$E bash "$SH" version "$T/p4.json" "$T/m.json")" != "$v1" ] && echo y)" "y"
  # a roleScope VALUE change -> different version (R2-Q6: values, not just keys)
  printf '%s' '[{"entity":"submission","owningChain":["team_id"],"roleScope":{"admin":"read-scoped","viewer":"read-scoped"}}]' > "$T/m2.json"
  check "$E scope-value change bumps version" "$([ "$(QA_ENGINE=$E bash "$SH" version "$T/p.json" "$T/m2.json")" != "$v1" ] && echo y)" "y"
  # diff: added / removed / changed
  printf '%s' '{"roles":[{"id":"admin","role":"admin","plane":"global"},{"id":"guest","role":"guest","plane":"contextual"}],"version":"old"}' > "$T/prev.json"
  printf '%s' '{"roles":[{"id":"admin","role":"superadmin","plane":"global"},{"id":"auditor","role":"auditor","plane":"global"}],"version":"new"}' > "$T/curr.json"
  local d; d="$(QA_ENGINE=$E bash "$SH" diff "$T/prev.json" "$T/curr.json")"
  check "$E diff added auditor" "$(printf '%s' "$d" | python3 -c 'import json,sys;print("auditor" in json.load(sys.stdin)["added"])')" "True"
  check "$E diff removed guest"  "$(printf '%s' "$d" | python3 -c 'import json,sys;print("guest" in json.load(sys.stdin)["removed"])')" "True"
  check "$E diff changed admin"  "$(printf '%s' "$d" | python3 -c 'import json,sys;print(any(c["id"]=="admin" for c in json.load(sys.stdin)["changed"]))')" "True"
  check "$E empty-prev all added" "$(printf '{}' > "$T/e.json"; QA_ENGINE=$E bash "$SH" diff "$T/e.json" "$T/curr.json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["added"]))')" "2"
  # render: substitutes placeholders (human-only — no state block, R3-Q4)
  printf '%s\n' '# QA Constitution' 'VERSION: {{VERSION}} @ {{TIMESTAMP}}' '{{ROLES_TABLE}}' > "$T/tmpl.md"
  local out; out="$(QA_ENGINE=$E bash "$SH" render "$T/p.json" "abc123" "$T/tmpl.md" "2026-09-04T00:00:00Z")"
  check "$E render has version" "$(printf '%s' "$out" | grep -c 'abc123')" "1"
  check "$E render has admin row" "$(printf '%s' "$out" | grep -c '| admin | admin | global |')" "1"
  # state subcommand emits the authoritative machine state (R3-Q4: sibling file, not in the md)
  local st; st="$(QA_ENGINE=$E bash "$SH" state "$T/p.json" "abc123")"
  check "$E state has version" "$(printf '%s' "$st" | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')" "abc123"
  check "$E state has admin role" "$(printf '%s' "$st" | python3 -c 'import json,sys;print(any(r["id"]=="admin" for r in json.load(sys.stdin)["roles"]))')" "True"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3

# Cross-engine regression: jq and python3 must build the EXACT same canonical
# string (and therefore hash) for the same logical role state, even when
# persona ids / entity names are prefixes of one another (e.g. "admin" vs
# "admin_ro"). Sorting the ALREADY-COMPOSED "id|role|plane" delimited string
# (where "|" == 0x7C sorts after letters/digits/_/-) diverges from sorting by
# the structured field first — this check catches that divergence directly.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  T="$(mktemp -d)"
  printf '%s' '[{"id":"admin_ro","role":"viewer","plane":"global","auth":"a@x (seeded)"},{"id":"admin","role":"admin","plane":"global","auth":"a@x (seeded)"}]' > "$T/p.json"
  printf '%s' '[{"entity":"team_member","owningChain":["team_id"],"roleScope":{"viewer":"read-scoped"}},{"entity":"team","owningChain":[],"roleScope":{"admin":"owns"}}]' > "$T/m.json"
  V_JQ="$(QA_ENGINE=jq bash "$SH" version "$T/p.json" "$T/m.json")"
  V_PY="$(QA_ENGINE=python3 bash "$SH" version "$T/p.json" "$T/m.json")"
  check "cross-engine version identical (prefix-colliding ids)" "$V_JQ" "$V_PY"
  rm -rf "$T"
fi

# Cross-engine regression: malformed personas/authz must be rejected
# IDENTICALLY (same nonzero exit) by both engines, not silently accepted by
# one and crashed-on by the other. See constitution.sh canonical_string()'s
# schema validation.
malformed_check() {
  local E="$1" name="$2" pfile="$3" mfile="$4"
  local rc
  QA_ENGINE=$E bash "$SH" version "$pfile" "$mfile" >/dev/null 2>&1; rc=$?
  check "$E $name rejected (nonzero exit)" "$([ "$rc" -ne 0 ] && echo y)" "y"
}
T="$(mktemp -d)"
# persona missing `plane`
printf '%s' '[{"id":"a","role":"r"}]' > "$T/p_missing_plane.json"
printf '%s' '[{"entity":"e","owningChain":[],"roleScope":{}}]' > "$T/m_valid.json"
# authz roleScope value `true` (non-string)
printf '%s' '[{"id":"a","role":"r","plane":"p"}]' > "$T/p_valid.json"
printf '%s' '[{"entity":"e","owningChain":[],"roleScope":{"admin":true}}]' > "$T/m_bad_scope.json"
if command -v jq >/dev/null 2>&1; then
  malformed_check jq "persona missing plane" "$T/p_missing_plane.json" "$T/m_valid.json"
  malformed_check jq "roleScope value true" "$T/p_valid.json" "$T/m_bad_scope.json"
  # control: existing valid fixture still succeeds
  check "jq valid fixture still succeeds" "$([ -n "$(QA_ENGINE=jq bash "$SH" version "$T/p_valid.json" "$T/m_valid.json" 2>/dev/null)" ] && echo y)" "y"
fi
if command -v python3 >/dev/null 2>&1; then
  malformed_check python3 "persona missing plane" "$T/p_missing_plane.json" "$T/m_valid.json"
  malformed_check python3 "roleScope value true" "$T/p_valid.json" "$T/m_bad_scope.json"
  # control: existing valid fixture still succeeds
  check "python3 valid fixture still succeeds" "$([ -n "$(QA_ENGINE=python3 bash "$SH" version "$T/p_valid.json" "$T/m_valid.json" 2>/dev/null)" ] && echo y)" "y"
fi
rm -rf "$T"

echo "constitution: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
