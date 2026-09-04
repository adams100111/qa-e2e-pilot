#!/usr/bin/env bash
# qa-kit phase INTEGRATION test — chains the qa-kit helpers the way the step
# commands do, on synthetic artifacts, and asserts the gates fire end-to-end:
#   constitution state -> spec-roles snapshot -> (frozen) checklist -> verify-plan
#   -> runconfig-merge -> drift.
#
# HONESTY NOTE: the full "phased run's verdicts ≡ a one-shot /qa-run's verdicts"
# equivalence needs a live browser agent and is NOT scriptable headlessly here — it
# is the MANUAL ACCURACY RUN's job (docs/harness-adapters.md). This test proves the
# helper chain composes and every deterministic gate fires; it does not run the agent.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$DIR/../.."
CONST="$ROOT/qa-kit/scripts/constitution.sh"
SNAP="$ROOT/qa-kit/scripts/spec-snapshot.sh"
VP="$ROOT/qa-kit/scripts/verify-plan.sh"
RC="$ROOT/qa-kit/scripts/runconfig-merge.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

T="$(mktemp -d)"
# 1. constitution: personas+authz -> version + state
printf '%s' '[{"id":"admin","role":"admin","plane":"global","auth":"a"},{"id":"viewer","role":"viewer","plane":"contextual","auth":"v"}]' > "$T/personas.json"
printf '%s' '[{"entity":"doc","owningChain":["team_id"],"roleScope":{"admin":"owns","viewer":"read-scoped"}}]' > "$T/authz.json"
VER="$(bash "$CONST" version "$T/personas.json" "$T/authz.json")"
check "constitution version non-empty" "$([ -n "$VER" ] && echo y)" "y"
bash "$CONST" state "$T/personas.json" "$VER" > "$T/constitution.state.json"

# 2. spec snapshot: copy roles, stamp version, subset to admin
mkdir -p "$T/spec"
printf '%s' '{"subset":["admin"]}' > "$T/ov.json"
bash "$SNAP" create "$T/constitution.state.json" "$T/spec" "$T/ov.json"
check "spec-roles stamped with constitution version" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["constitutionVersion"])' "$T/spec/spec-roles.json")" "$VER"
check "spec-roles narrowed to admin" \
  "$(python3 -c 'import json,sys;print(",".join(r["id"] for r in json.load(open(sys.argv[1]))["roles"]))' "$T/spec/spec-roles.json")" "admin"

# 3. the frozen plan (what /qa-scenarios would compile) — two planned criteria
printf '%s' '[{"id":"C1","surface":"/x","kind":"happy-path","tags":[],"role":"admin"},{"id":"C2","surface":"/x","kind":"business-rule","tags":[],"role":"admin"}]' > "$T/spec/checklist.json"

# 4. verify-plan gate: an in-plan run passes; an out-of-plan act is flagged
printf '%s' '{"criteria":[{"criterion_id":"C1","verdict":"pass"},{"criterion_id":"C2","verdict":"pass"}]}' > "$T/cp_ok.json"
bash "$VP" "$T/cp_ok.json" "$T/spec/checklist.json" >/dev/null; check "in-plan run passes gate" "$?" "0"
printf '%s' '{"criteria":[{"criterion_id":"C1"},{"criterion_id":"C9"}]}' > "$T/cp_bad.json"
bash "$VP" "$T/cp_bad.json" "$T/spec/checklist.json" >/dev/null 2>&1; check "out-of-plan act flagged by gate" "$?" "1"

# 5. runconfig-merge: spec deltas over config
printf '%s' '{"baseUrl":"http://x","maxParallel":1,"viewport":"desktop"}' > "$T/config.json"
printf '%s' '{"maxParallel":6}' > "$T/spec/run-config.json"
EFF="$(bash "$RC" "$T/config.json" "$T/spec/run-config.json")"
check "effective config applies spec delta" "$(printf '%s' "$EFF" | python3 -c 'import json,sys;print(json.load(sys.stdin)["maxParallel"])')" "6"
check "effective config keeps default" "$(printf '%s' "$EFF" | python3 -c 'import json,sys;print(json.load(sys.stdin)["viewport"])')" "desktop"

# 6. drift: same version in-sync; a bumped constitution shows stale (spec snapshot unchanged)
d="$(bash "$SNAP" drift "$T/spec/spec-roles.json" "$VER")"
check "drift in-sync while version unchanged" "$(printf '%s' "$d" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stale"])')" "False"
d="$(bash "$SNAP" drift "$T/spec/spec-roles.json" "someNewVersion")"
check "drift stale after constitution bump" "$(printf '%s' "$d" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stale"])')" "True"

rm -rf "$T"
echo "qa-kit-phases: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
