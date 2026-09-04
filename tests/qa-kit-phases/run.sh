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
DB="$ROOT/qa-kit/scripts/data-baseline.sh"
CF="$ROOT/qa-kit/scripts/check-fixtures.sh"
DS="$ROOT/qa-kit/scripts/detect-seed.sh"
AS="$ROOT/qa-kit/scripts/auto-seed.sh"
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

# 7. TDQA data layer (increment 6a): baseline validate, check-fixtures gate, measured/scoped counts.
printf '%s' '[{"entity":"Category","origin":"seeded","identity":{"name":"Books"},"scope":null},{"entity":"Order","origin":"created","identity":null}]' > "$T/spec/data-baseline.json"
bash "$DB" validate "$T/spec/data-baseline.json" >/dev/null; check "data-baseline validates" "$?" "0"
# measured baseline 2 -> empty-state expects 2, after +1 -> 3 (scope A); scope B measured 5 -> 5 then 6
check "empty-state = measured baseline (2)" "$(bash "$DB" expected-count 2 0)" "2"
check "after 1 create -> 3" "$(bash "$DB" expected-count 2 1)" "3"
check "scope B empty-state = 5" "$(bash "$DB" expected-count 5 0)" "5"
check "scope B after 1 create -> 6" "$(bash "$DB" expected-count 5 1)" "6"
# check-fixtures: a computed row without a pinned expect is flagged; a business-rule too; pinned+human passes
printf '%s' '[{"id":"K1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"total","value":"0.003","tolerance":0,"oracleSource":"human"}}}]' > "$T/cl_ok.json"
bash "$CF" "$T/cl_ok.json" >/dev/null; check "pinned human computed -> gate ok" "$?" "0"
printf '%s' '[{"id":"K2","surface":"/x","kind":"computed-logic","tags":[],"action":"a"}]' > "$T/cl_missing.json"
bash "$CF" "$T/cl_missing.json" >/dev/null 2>&1; check "unpinned computed -> gate flags" "$?" "1"
printf '%s' '[{"id":"K3","surface":"/x","kind":"business-rule","tags":[],"action":"a"}]' > "$T/cl_br.json"
bash "$CF" "$T/cl_br.json" >/dev/null 2>&1; check "unpinned business-rule -> gate flags (kind trigger)" "$?" "1"
# an llm-suggested pin is present-but-low (sources.llmSuggested counted)
printf '%s' '[{"id":"K4","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"llm-suggested"}}}]' > "$T/cl_llm.json"
check "llm-suggested pin counted low" "$(bash "$CF" "$T/cl_llm.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sources"]["llmSuggested"])')" "1"

# 8. Opt-in auto-seed (increment 6b): detect-seed proposes from a REAL profile shape; auto-seed gates the write.
#    The actual seed exec is NOT run here (honest boundary) — only the pure proposal + gate decision.
printf '%s' '{"components":[{"role":"backend","framework":"laravel","orm":{"name":"eloquent"}}],"primary":{"backend":0}}' > "$T/sp_laravel.json"
check "detect-seed laravel -> artisan" "$(bash "$DS" propose "$T/sp_laravel.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"])')" "php artisan db:seed"
printf '%s' '{"components":[{"role":"backend","framework":"django","orm":{"name":"django-orm"}}],"primary":{"backend":0}}' > "$T/sp_django.json"
check "detect-seed django -> null command" "$(bash "$DS" propose "$T/sp_django.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"] is None)')" "True"
printf '%s' '{"components":[{"role":"backend","framework":"flask","orm":{"name":"sqlalchemy"}}],"primary":{"backend":0}}' > "$T/sp_flask.json"
check "detect-seed flask -> null mechanism" "$(bash "$DS" propose "$T/sp_flask.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mechanism"] is None)')" "True"
# auto-seed decide: the write gate mirrors the engine (allowApiWrites + non-empty marker + environment != production)
printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":".qa/DISPOSABLE","environment":"disposable"}' > "$T/as_ok.json"
check "auto-seed disposable -> seed true" "$(bash "$AS" decide "$T/as_ok.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')" "True"
printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"","environment":"disposable"}' > "$T/as_nomark.json"
check "auto-seed empty marker -> seed false" "$(bash "$AS" decide "$T/as_nomark.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')" "False"
printf '%s' '{"allowApiWrites":false,"seedableEnvMarker":".qa/DISPOSABLE","environment":"disposable"}' > "$T/as_nowrite.json"
check "auto-seed writes off -> seed false" "$(bash "$AS" decide "$T/as_nowrite.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')" "False"
printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":".qa/DISPOSABLE","environment":"production"}' > "$T/as_prod.json"
check "auto-seed production -> seed false" "$(bash "$AS" decide "$T/as_prod.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')" "False"

rm -rf "$T"
echo "qa-kit-phases: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
