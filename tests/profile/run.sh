#!/usr/bin/env bash
# Dual-engine tests for scripts/profile.sh — resolves the ship|smoke|full profile
# into a run's effective config (profile defaults fill only keys the user did not set).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../scripts/profile.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: profile: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <json> <python-expression over d> — read a value from output JSON (engine-independent reader).
q(){ printf '%s' "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(eval(sys.argv[1]),sort_keys=True,separators=(",",":"),ensure_ascii=False))' "$2"; }

run_engine() {
  local E="$1" T out rc; T="$(mktemp -d)"; TMPDIRS+=("$T")

  # default_is_full: no profile anywhere -> full, no defaults added, user keys preserved.
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json")"; rc=$?
  check "$E default_is_full exit 0" "$rc" "0"
  check "$E default_is_full profile" "$(q "$out" 'd["profile"]')" '"full"'
  check "$E default_is_full no responsiveMatrix added" "$(q "$out" '"responsiveMatrix" in d')" "false"
  check "$E default_is_full no gates added" "$(q "$out" '"gates" in d')" "false"
  check "$E default_is_full no maxParallel added" "$(q "$out" '"maxParallel" in d')" "false"
  check "$E default_is_full profileSources empty" "$(q "$out" 'd["profileSources"]')" "{}"
  check "$E default_is_full keeps user keys (utf-8)" "$(q "$out" 'd["tenantName"]')" '"مختبر الابتكار"'

  # ship_fills_defaults: --profile ship over a minimal config fills every exact default.
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --stack-profile "$FX/stack-profile.json" --profile ship)"; rc=$?
  check "$E ship_fills_defaults exit 0" "$rc" "0"
  check "$E ship profile" "$(q "$out" 'd["profile"]')" '"ship"'
  check "$E ship responsiveMatrix" "$(q "$out" 'd["responsiveMatrix"]')" '[{"height":900,"id":"desktop","width":1440},{"height":844,"id":"mobile","width":390}]'
  check "$E ship colorSchemes" "$(q "$out" 'd["colorSchemes"]')" '["light","dark"]'
  check "$E ship detection.ux" "$(q "$out" 'd["detection"]["ux"]')" '{"advisoryAesthetics":true,"axe":true,"critic":true,"objective":true}'
  check "$E ship gates" "$(q "$out" 'd["gates"]')" '{"coverage":"block","dataPolicy":"enforce","oracle":"enforce"}'
  check "$E ship maxParallel" "$(q "$out" 'd["maxParallel"]')" "3"
  check "$E ship sources all profile-default" "$(q "$out" 'sorted(set(d["profileSources"].values()))')" '["profile-default"]'
  check "$E ship sources cover every default" "$(q "$out" 'sorted(d["profileSources"].keys())')" '["colorSchemes","detection.ux.advisoryAesthetics","detection.ux.axe","detection.ux.critic","detection.ux.objective","gates.coverage","gates.dataPolicy","gates.oracle","locales","maxParallel","responsiveMatrix"]'

  # user_value_wins: config.profile=ship; user-set keys (incl. nested leaves) are kept and sourced "user".
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-user.json" --stack-profile "$FX/stack-profile.json")"
  check "$E user_value_wins profile from config" "$(q "$out" 'd["profile"]')" '"ship"'
  check "$E user_value_wins colorSchemes" "$(q "$out" 'd["colorSchemes"]')" '["dark"]'
  check "$E user_value_wins maxParallel" "$(q "$out" 'd["maxParallel"]')" "1"
  check "$E user_value_wins nested leaf kept" "$(q "$out" 'd["detection"]["ux"]["objective"]')" "false"
  check "$E user_value_wins nested leaf filled" "$(q "$out" 'd["detection"]["ux"]["critic"]')" "true"
  check "$E user_value_wins gates merge" "$(q "$out" 'd["gates"]')" '{"coverage":"advise","dataPolicy":"enforce","oracle":"enforce"}'
  check "$E user_value_wins sources" "$(q "$out" '[d["profileSources"][k] for k in ["colorSchemes","maxParallel","detection.ux.objective","detection.ux.critic","gates.coverage","gates.oracle","responsiveMatrix"]]')" '["user","user","user","profile-default","user","profile-default","profile-default"]'

  # run-config profile beats config profile; --profile beats both.
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-user.json" --run-config "$FX/run-config-smoke.json" --stack-profile "$FX/stack-profile.json")"
  check "$E run-config profile beats config" "$(q "$out" 'd["profile"]')" '"smoke"'
  check "$E run-config deltas merged" "$(q "$out" 'd["criteriaBudget"]')" "20"
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-user.json" --run-config "$FX/run-config-smoke.json" --profile full)"
  check "$E --profile beats run-config" "$(q "$out" 'd["profile"]')" '"full"'
  check "$E full sources only user keys" "$(q "$out" 'd["profileSources"]')" '{"colorSchemes":"user","detection.ux.advisoryAesthetics":"user","detection.ux.objective":"user","gates.coverage":"user","maxParallel":"user"}'

  # smoke: desktop only, light only, first locale only, coverage advise.
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --stack-profile "$FX/stack-profile.json" --profile smoke)"
  check "$E smoke responsiveMatrix desktop only" "$(q "$out" 'd["responsiveMatrix"]')" '[{"height":900,"id":"desktop","width":1440}]'
  check "$E smoke colorSchemes" "$(q "$out" 'd["colorSchemes"]')" '["light"]'
  check "$E smoke locales first only" "$(q "$out" 'd["locales"]')" '["ar"]'
  check "$E smoke gates.coverage advise" "$(q "$out" 'd["gates"]["coverage"]')" '"advise"'
  check "$E smoke maxParallel" "$(q "$out" 'd["maxParallel"]')" "3"

  # explicit_empty_matrix_kept: explicit [] is a user value, not "unset".
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-empty-matrix.json" --stack-profile "$FX/stack-profile.json" --profile ship)"
  check "$E explicit_empty_matrix_kept" "$(q "$out" 'd["responsiveMatrix"]')" "[]"
  check "$E explicit_empty_locales_kept" "$(q "$out" 'd["locales"]')" "[]"
  check "$E explicit_empty sources user" "$(q "$out" '[d["profileSources"]["responsiveMatrix"],d["profileSources"]["locales"]]')" '["user","user"]'

  # locales_from_stack_profile: frontend first, then backend, then <default>.
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --stack-profile "$FX/stack-profile.json" --profile ship)"
  check "$E locales_from_stack_profile frontend" "$(q "$out" 'd["locales"]')" '["ar","en"]'
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --stack-profile "$FX/stack-profile-backend-only.json" --profile ship)"
  check "$E locales_from_stack_profile backend fallback" "$(q "$out" 'd["locales"]')" '["ar","en","fr"]'
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --stack-profile "$FX/stack-profile-none.json" --profile ship)"
  check "$E locales_from_stack_profile default fallback" "$(q "$out" 'd["locales"]')" '["<default>"]'
  out="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --profile ship)"
  check "$E locales no stack-profile -> default" "$(q "$out" 'd["locales"]')" '["<default>"]'

  # unknown_profile_rejected: exit 1 with the exact message, from any source.
  local err
  err="$(QA_ENGINE=$E bash "$SH" resolve "$FX/config-min.json" --profile turbo 2>&1 >/dev/null)"; rc=$?
  check "$E unknown_profile_rejected exit 1" "$rc" "1"
  check "$E unknown_profile_rejected message" "$(printf '%s' "$err" | grep -c 'unknown profile: turbo')" "1"
  printf '%s' '{"profile":"nightly"}' > "$T/bad.json"
  err="$(QA_ENGINE=$E bash "$SH" resolve "$T/bad.json" 2>&1 >/dev/null)"; rc=$?
  check "$E unknown config profile rejected" "$rc" "1"
  check "$E unknown config profile message" "$(printf '%s' "$err" | grep -c 'unknown profile: nightly')" "1"

  # usage / input errors.
  QA_ENGINE=$E bash "$SH" >/dev/null 2>&1; check "$E no args -> exit 1" "$?" "1"
  QA_ENGINE=$E bash "$SH" resolve "$T/missing.json" >/dev/null 2>&1; check "$E missing config -> exit 1" "$?" "1"
  printf '%s' '[1]' > "$T/arr.json"
  QA_ENGINE=$E bash "$SH" resolve "$T/arr.json" >/dev/null 2>&1; check "$E non-object config -> exit 1" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3

# parity: byte-identical output across engines for every profile path.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for args in \
    "$FX/config-min.json" \
    "$FX/config-min.json --stack-profile $FX/stack-profile.json --profile ship" \
    "$FX/config-min.json --stack-profile $FX/stack-profile-backend-only.json --profile smoke" \
    "$FX/config-user.json --stack-profile $FX/stack-profile.json" \
    "$FX/config-user.json --run-config $FX/run-config-smoke.json --stack-profile $FX/stack-profile.json" \
    "$FX/config-empty-matrix.json --profile ship"; do
    # shellcheck disable=SC2086
    vj="$(QA_ENGINE=jq bash "$SH" resolve $args; true)"; vp="$(QA_ENGINE=python3 bash "$SH" resolve $args; true)"
    check "parity byte-identical: ${args##*/}" "$([ -n "$vj" ] && [ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  done
fi
echo "profile: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
