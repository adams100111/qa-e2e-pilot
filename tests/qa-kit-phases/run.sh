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
trap 'rm -rf "$T"' EXIT
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

# A3: /qa-verify command exists and wires verify-plan + verification.json
QV="$ROOT/qa-kit/commands/qa-verify.md"
check "qa-verify command exists" "$([ -f "$QV" ] && echo y)" "y"
grep -q 'verify-plan.sh'    "$QV"; check "qa-verify references verify-plan.sh" "$?" "0"
grep -q 'verification.json' "$QV"; check "qa-verify reads verification.json"   "$?" "0"
# audit-2 W2-4: the out-of-plan gate must be pointed at the frozen SPEC plan (never the
# agent-amendable run copy) whenever one is resolvable, and the run-local fallback must banner
# its weaker guarantee.
grep -q 'verify-plan.sh".*\.qa/specs/' "$QV"; check "qa-verify invokes verify-plan.sh with the frozen spec plan as 2nd arg" "$?" "0"
grep -q 'run-local plan only' "$QV"; check "qa-verify carries the weaker-mode banner text" "$?" "0"
QVT="$ROOT/qa-kit/templates/qa-verify-template.md"
check "qa-verify template has three states" \
  "$(grep -Eic 'VERIFIED|OVERRIDDEN|NOT VERIFIED' "$QVT")" "3"
# status ladder and agent flow name the new step
grep -q '/qa-verify' "$ROOT/qa-kit/commands/qa-status.md"; check "status names /qa-verify" "$?" "0"
grep -q 'qa-verify'  "$ROOT/qa-kit/agents/qa-kit.md";      check "agent flow names /qa-verify" "$?" "0"
# audit-2 W3-7b: qa-status.md must not claim a phantom `runs.json` artifact the engine never
# writes, and its drift-advisory text must point at the now-shipped spec-snapshot.sh drift helper.
grep -q 'runs\.json' "$ROOT/qa-kit/core/commands/qa-status.md"; check "status.md no longer claims runs.json" "$?" "1"
grep -q 'spec-snapshot\.sh drift' "$ROOT/qa-kit/core/commands/qa-status.md"; check "status.md points at the shipped drift helper" "$?" "0"
# spine docs (hand-authored: qa-kit README + harness READMEs) name /qa-verify as a real step
grep -qE '/qa-verify' "$ROOT/qa-kit/README.md"; check "qa-kit README spine names /qa-verify" "$?" "0"
grep -qE '/qa-verify' "$ROOT/qa-kit/harnesses/pi/README.md"; check "pi README spine names /qa-verify" "$?" "0"
# constitution template no longer implies five nonexistent /qa-* gate commands
for cmd in qa-sanitize qa-assure qa-perf qa-security qa-uiux; do
  grep -q "/$cmd" "$ROOT/qa-kit/templates/constitution-template.md"; check "constitution template drops fictional /$cmd" "$?" "1"
done

# --- ship-profile wiring (increment 1, task 11): command/template text assertions ---
QC="$ROOT/qa-kit/commands/qa-constitution.md"; QS="$ROOT/qa-kit/commands/qa-spec.md"
QSC="$ROOT/qa-kit/commands/qa-scenarios.md"; QA="$ROOT/qa-kit/commands/qa-analyze.md"
CT="$ROOT/qa-kit/templates/constitution-template.md"; JT="$ROOT/qa-kit/templates/journeys-template.json"
# constitution_has_profile_rows
grep -q '| profile |' "$CT"; check "constitution_has_profile_rows: template profile row" "$?" "0"
grep -q 'detection.ux' "$CT"; check "constitution_has_profile_rows: uiux -> detection.ux" "$?" "0"
grep -q 'deny' "$CT" && grep -q 'profile.sh' "$QC"; check "constitution_has_profile_rows: security row + profile.sh in command" "$?" "0"
grep -q 'surface-access.sh" derive' "$QC" && grep -q 'confirm-table' "$QC" && grep -q 'apply' "$QC" && grep -q 'taking-surface-census' "$QC"; check "constitution_has_profile_rows: surface-access confirmation round" "$?" "0"
grep -q 'assumption' "$QC" && grep -q 'autonomousSetup' "$QC"; check "constitution_has_profile_rows: autonomousSetup assumption" "$?" "0"
# spec_mentions_journeys_validate
grep -q 'journeys.json' "$QS" && grep -q 'journeys.sh validate' "$QS" && grep -q 'journeys-template.json' "$QS" && grep -q 'P1' "$QS"; check "spec_mentions_journeys_validate" "$?" "0"
python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert isinstance(d,list)' "$JT" 2>/dev/null; check "journeys template is valid JSON array" "$?" "0"
# scenarios_runs_generator
grep -q 'generate-ship-criteria.sh' "$QSC" && grep -q 'taking-surface-census' "$QSC" && grep -q 'coverage.sh' "$QSC"; check "scenarios_runs_generator" "$?" "0"
# analyze_blocks_on_uncovered_under_ship
grep -q 'coverage.sh' "$QA" && grep -q 'BLOCKED' "$QA" && grep -q -- '--mode' "$QA"; check "analyze_blocks_on_uncovered_under_ship: command" "$?" "0"
grep -q 'BLOCKED' "$ROOT/qa-kit/templates/qa-analyze-template.md" && grep -q '## Coverage' "$ROOT/qa-kit/templates/qa-analyze-template.md"; check "analyze_blocks_on_uncovered_under_ship: template" "$?" "0"

# --- increment 1 final-review fixes: command text assertions ---
QST="$ROOT/qa-kit/commands/qa-status.md"; AG="$ROOT/qa-kit/agents/qa-kit.md"
# C2: autonomous setup assumes, never denies
grep -q 'apply --assume' "$QC"; check "constitution_autonomous_uses_apply_assume" "$?" "0"
grep -q 'decide every remaining `reachedWithoutEvidence` pair as `deny`' "$QC"; check "constitution_autonomous_never_denies" "$?" "1"
# canonical adapter path + stack profile for locales (I8)
grep -q '.qa/census/adapter.json' "$QC" && grep -q '.qa/census/adapter.json' "$QSC"; check "canonical_adapter_path" "$?" "0"
grep -q -- '--stack-profile' "$QC" && grep -q -- '--stack-profile' "$QSC" && grep -q -- '--stack-profile' "$QA"; check "profile_resolve_gets_stack_profile" "$?" "0"
grep -q 'stack-profile.cache.json' "$QSC"; check "scenarios_names_stack_profile_cache" "$?" "0"
# I1: persona input file
grep -q 'surface-access.sh" personas' "$QS" && grep -q 'personas-for-generation.json' "$QS"; check "spec_writes_personas_for_generation" "$?" "0"
grep -q -- '--personas .qa/specs/<target>/personas-for-generation.json' "$QSC"; check "scenarios_passes_personas_for_generation" "$?" "0"
grep -q 'personas-tmp' "$QSC"; check "scenarios_has_no_undefined_personas_tmp" "$?" "1"
# I3/I4: scoped gate, fail closed, deferred channels, crawl-only only on human ok
grep -q -- '--roles .qa/specs/<target>/spec-roles.json' "$QA" && grep -q 'coverage-scope.txt' "$QA" && grep -q 'coverage-scope.txt' "$QS"; check "analyze_gate_scoped_to_spec" "$?" "0"
grep -q 'no census' "$QA" && grep -q 'engine script unavailable' "$QA"; check "analyze_missing_census_blocks_under_ship" "$?" "0"
grep -q -- '--defer-channels' "$QA" && grep -q 'channel checks arrive in increment 4' "$QA"; check "analyze_defers_channels_with_reason" "$?" "0"
grep -q -- '--accept-crawl-only' "$QA" && grep -q 'explicitly said' "$QA"; check "analyze_accept_crawl_only_needs_human" "$?" "0"
grep -q 'covered-sweep' "$QA" && grep -q 'covered-sweep' "$QSC"; check "sweep_rows_do_not_close_pairs" "$?" "0"
# I4: no hand-off to /qa-run while BLOCKED
grep -q 'never `/qa-run` while the analysis is' "$QST"; check "status_refuses_run_while_blocked" "$?" "0"
grep -q 'Never hand off to `/qa-run` while' "$AG"; check "agent_refuses_run_while_blocked" "$?" "0"
grep -q 'Engine-only runs have no gate' "$QA"; check "analyze_documents_engine_only_has_no_gate" "$?" "0"

# --- UX wiring (0.12.0): hand-authored plans carry visual-ux rows; analyze blocks a ship plan without them ---
grep -q 'every surface in scope gets a `visual-ux` criterion' "$QSC" && grep -q 'analyzing-feature-ui' "$QSC"; check "scenarios_hand_authored_visual_ux_per_surface" "$?" "0"
grep -q 'every locale and viewport in the profile gets a `ux-revisit` row' "$QSC"; check "scenarios_hand_authored_ux_revisit_per_variant" "$?" "0"
grep -q 'interaction-ux' "$QSC"; check "scenarios_names_interaction_ux" "$?" "0"
grep -q -- '--require-visual-ux' "$QSC"; check "scenarios_fill_gaps_requires_visual_ux" "$?" "0"
grep -q -- '--require-visual-ux' "$QA" && grep -q 'uxMissing' "$QA"; check "analyze_flags_surfaces_without_visual_ux" "$?" "0"
grep -q 'until uncovered = 0 and `uxMissing` is empty' "$QA"; check "analyze_visual_ux_blocking_under_ship" "$?" "0"
grep -q 'uxMissing' "$ROOT/qa-kit/templates/qa-analyze-template.md"; check "analyze_template_coverage_lists_ux_missing" "$?" "0"
grep -q -- '--require-visual-ux' "$ROOT/qa-kit/core/commands/qa-analyze.md" && grep -q 'step 5c' "$ROOT/qa-kit/core/commands/qa-scenarios.md"; check "ux_wiring_in_core_sources" "$?" "0"

# --- ClickUp spec tracking wiring (Task 10): every step command guards, then calls its verb ---
GUARD='Only when docs/agents/qa-tracker.json has specs.<target>.enabled: true. If the step below exits non-zero, stop and report its one-line error; do not continue the command.'
CC="$ROOT/qa-kit/core/commands"
for pair in qa-spec:spec-init qa-spec:push-docs qa-scenarios:push-scenarios qa-scenarios:lint qa-analyze:spec-note qa-verify:sync-run qa-verify:push-bug qa-verify:push-docs qa-status:spec-status; do
  f="${pair%%:*}"; v="${pair##*:}"
  grep -qF "$GUARD" "$CC/$f.md" && grep -Eq "tracker.sh\"? $v" "$CC/$f.md"; check "tracker_wiring_${f}_${v}" "$?" "0"
done
grep -qF -- '--global' "$CC/qa-tracker.md" && grep -qF -- '--spec <target>' "$CC/qa-tracker.md" && grep -q 'spec-init' "$CC/qa-tracker.md"; check "tracker_cmd_global_and_spec_levels" "$?" "0"
grep -q 'writing-rules.md' "$CC/qa-tracker.md"; check "tracker_cmd_references_writing_rules" "$?" "0"
[ -f "$ROOT/qa-kit/templates/trackers/writing-rules.md" ]; check "writing_rules_file_exists" "$?" "0"
grep -q 'writing-rules.md' "$CC/qa-scenarios.md" && grep -q 'tracker-cards.json' "$CC/qa-scenarios.md"; check "scenarios_reads_rules_writes_cards" "$?" "0"
grep -q 'Screenshots are sent as they are' "$ROOT/qa-kit/templates/trackers/writing-rules.md"; check "writing_rules_screenshot_line" "$?" "0"

# --- Fix round 1 (Tasks 10 and 17): exact flags per verb line, the cards schema, I1-I6, R-a..R-e ---
# verb_flags <file> <verb> <flag>...: some line that calls the verb carries every flag
verb_flags(){ local f="$1" v="$2" l; shift 2
  l="$(grep -E "tracker\.sh\"? $v( |\$)" "$f" 2>/dev/null)"; [ -n "$l" ] || return 1
  local fl; for fl in "$@"; do l="$(printf '%s\n' "$l" | grep -F -- "$fl")"; [ -n "$l" ] || return 1; done; }
verb_flags "$CC/qa-spec.md" spec-init '--spec <target>' '--apply'; check "flags_spec_spec_init" "$?" "0"
verb_flags "$CC/qa-spec.md" push-docs '--spec <target>' '--apply'; check "flags_spec_push_docs" "$?" "0"
verb_flags "$CC/qa-scenarios.md" lint '--spec <target>'; check "flags_scenarios_lint" "$?" "0"
check "scenarios_lint_is_never_applied" "$(grep -E 'tracker\.sh"? lint' "$CC/qa-scenarios.md" | grep -c -- '--apply' || true)" "0"
verb_flags "$CC/qa-scenarios.md" push-scenarios '--spec <target>' '--apply'; check "flags_scenarios_push_scenarios" "$?" "0"
verb_flags "$CC/qa-scenarios.md" push-docs '--spec <target>' '--apply'; check "flags_scenarios_push_docs" "$?" "0"
verb_flags "$CC/qa-analyze.md" spec-note '--spec <target>' '--file <note-file>' '--apply'; check "flags_analyze_spec_note" "$?" "0"
grep -q 'Add `--blocked` when the Verdict is `BLOCKED`' "$CC/qa-analyze.md"; check "flags_analyze_blocked" "$?" "0"
for v in push-bug sync-run push-docs; do
  verb_flags "$CC/qa-verify.md" "$v" '--spec <target>' '--run <run-id>' '--apply'; check "flags_verify_${v}" "$?" "0"   # I5: push-bug too
done
verb_flags "$CC/qa-status.md" spec-status '--spec <target>'; check "flags_status_spec_status" "$?" "0"
check "status_spec_status_is_never_applied" "$(grep -E 'tracker\.sh"? spec-status' "$CC/qa-status.md" | grep -c -- '--apply' || true)" "0"
for k in '"as"' 'subtasks' 'checklist' '"criterion"'; do
  grep -qF -- "$k" "$CC/qa-scenarios.md"; check "scenarios_names_schema_key_${k//\"/}" "$?" "0"
done
# I1: lint is the exception to the stop rule, stated right after the guard sentence
grep -A1 -F "ClickUp cards (per spec).** $GUARD" "$CC/qa-scenarios.md" | tail -1 | grep -q '`lint` is the exception'; check "i1_lint_exception_follows_guard" "$?" "0"
grep -q 'fix the cards and run it again' "$CC/qa-scenarios.md" && grep -q 'The stop rule applies to `push-scenarios` and `push-docs`' "$CC/qa-scenarios.md"; check "i1_stop_rule_names_the_two_pushes" "$?" "0"
# I2: the offer sits outside the guarded part, only on the ClickUp backend, never unattended
check "i2_offer_not_on_a_guarded_line" "$(grep -A2 -F "$GUARD" "$CC/qa-spec.md" | grep -c 'offer' || true)" "0"
grep -q 'Only when `docs/agents/qa-tracker.json` has `backend: "clickup"`' "$CC/qa-spec.md" && grep -q 'offer `/qa-tracker --spec <target>` once' "$CC/qa-spec.md"; check "i2_offer_only_on_clickup_backend" "$?" "0"
grep -q 'Make no offer under an unattended journey or `autonomousSetup`' "$CC/qa-spec.md"; check "i2_no_offer_unattended" "$?" "0"
grep -q 'say nothing about ClickUp' "$CC/qa-spec.md"; check "i2_other_backends_see_nothing" "$?" "0"
# I3: a failed ClickUp step never hides the command's own result
grep -q 'never hides this command.s result' "$CC/qa-verify.md" && grep -q 'the run is not complete' "$CC/qa-verify.md"; check "i3_verify_reports_first_then_not_complete" "$?" "0"
grep -q 'never hides this command.s result' "$CC/qa-analyze.md" && grep -q 'ClickUp was not updated' "$CC/qa-analyze.md"; check "i3_analyze_reports_first_then_not_updated" "$?" "0"
# I4: where the row id goes, and the role rule
grep -q '`criterion` is the one field that holds the checklist row id' "$CC/qa-scenarios.md" && grep -q '`title`, `do`, `expect`, `storyline` and `overview` must contain no ids' "$CC/qa-scenarios.md"; check "i4_criterion_is_the_only_id_field" "$?" "0"
grep -q 'A card has one `role`' "$CC/qa-scenarios.md" && grep -q 'needs one check per role, each inside a card of that role' "$CC/qa-scenarios.md" && grep -q 'a single `persona`' "$CC/qa-scenarios.md" && grep -q 'a row with no role goes in exactly one card' "$CC/qa-scenarios.md"; check "i4_role_rule_exact" "$?" "0"
grep -q '`personas` or `roles` list' "$CC/qa-scenarios.md" && grep -q 'wording.allow' "$CC/qa-scenarios.md"; check "i4_role_lists_and_wording_allow" "$?" "0"
# I6: the token stays inside the tracker script; a pasted id is proved by the dry spec-init
QT="$CC/qa-tracker.md"
check "i6_tracker_cmd_has_no_curl" "$(grep -ci 'curl' "$QT" || true)" "0"
check "i6_tracker_cmd_has_no_api_host" "$(grep -c 'api\.clickup\.com' "$QT" || true)" "0"
check "i6_no_get_through_the_api" "$(grep -c 'GET through the API' "$QT" || true)" "0"
grep -Eq 'tracker\.sh"? spec-init --spec <target>$' "$QT"; check "i6_dry_spec_init_line" "$?" "0"
# (the token rule itself was reworded in fix round 2: see f7_* below)
grep -q 'remove the saved id and ask again' "$QT" && grep -q '`folder` for a folder URL, `list` for a list URL' "$QT"; check "i6_wrong_id_is_removed_and_asked_again" "$?" "0"
grep -q 'tell the person to run `/qa-tracker` first' "$QT"; check "i6_other_backend_stops" "$?" "0"
# minors
grep -q 'only if they are not already there' "$QT"; check "minor_writing_rules_appended_once" "$?" "0"
grep -q 'once per tracked spec' "$CC/qa-status.md" && grep -q 'before the final \*\*next step\*\* line' "$CC/qa-status.md"; check "minor_status_clickup_line_placement" "$?" "0"
grep -q 'in the configured `language`' "$CC/qa-analyze.md" && grep -q "session's temp directory" "$CC/qa-analyze.md"; check "minor_analyze_note_language_and_temp" "$?" "0"
check "minor_clickup_rules_list_not_split" "$(awk '/^## Rules/{r=1;next} r&&/^## /{r=0} r&&seen&&/^$/{gap=1} r&&gap&&/^- /{bad++;gap=0} r&&/^- /{seen=1;gap=0} END{print bad+0}' "$ROOT/qa-kit/templates/trackers/clickup.md")" "0"
# R-a..R-e: the auto.sh interface /qa-auto and /qa-status follow
QAU="$CC/qa-auto.md"
grep -q 'plus `--known-defects-invalid` when step 2 exited non-zero' "$QAU"; check "ra_start_passes_known_defects_invalid" "$?" "0"
grep -q 'auto: no journey for <target>' "$QAU" && grep -q 'auto: no journey for <target>' "$CC/qa-status.md"; check "rb_status_exit_1_means_no_journey" "$?" "0"
check "rb_no_journey_json_lookup" "$(cat "$QAU" "$CC/qa-status.md" | grep -c 'Look for `.qa/specs/<target>/auto/journey.json`\|Only when `.qa/specs/<target>/auto/journey.json` exists' || true)" "0"
grep -q 'auto: no open journey for <target>' "$QAU"; check "rc_closed_journey_refusal_named" "$?" "0"
check "rc_no_stop_after_a_failed_final_note" "$(sed -n '/^11\. \*\*ClickUp note/,/^12\. /p' "$QAU" | grep -c 'auto.sh stop' || true)" "0"
grep -q 'do not try to stop the journey' "$QAU" && grep -q 'The ClickUp comment was not posted' "$QAU"; check "rc_says_the_comment_was_not_posted" "$?" "0"
check "rd_source_has_no_unavailable_call" "$(grep -c -- '--unavailable' "$QAU" || true)" "0"
grep -q 'counts every low-confidence decision that has no second-look verdict' "$QAU"; check "rd_handoff_counts_unlooked_decisions" "$?" "0"
grep -q 'auto.sh" note <target> --kind seed-not-run|check-left-out --text "<plain sentence>"' "$QAU"; check "re_note_verb_line" "$?" "0"
grep -q -- '--kind seed-not-run' "$QAU" && grep -q -- '--kind check-left-out' "$QAU"; check "re_both_note_kinds_used" "$?" "0"
check "re_left_out_check_is_not_a_scope_decision" "$(grep -c 'record that as a `scope` decision' "$QAU" || true)" "0"
# /qa-auto follows the step commands: lint is not a failed sync, and the step's own result is said first
grep -q '`lint` reporting problems is not a failed sync' "$QAU"; check "qa_auto_lint_is_not_a_failed_sync" "$?" "0"

# --- Unattended journey (Task 17): /qa-auto is a loop over auto.sh; steps honour an open journey ---
OJ='An open unattended journey for this target (`bash {{PLUGIN_ROOT}}/scripts/auto.sh status <target>` shows `state: open`) counts as `autonomousSetup` on for this step. Record each answer you give in place of a person with `auto.sh decide`.'
for f in qa-constitution qa-spec qa-scenarios qa-analyze; do
  grep -qF "$OJ" "$CC/$f.md"; check "open_journey_line_${f}" "$?" "0"
done
grep -q 'with the reason `unattended journey`' "$CC/qa-constitution.md"; check "constitution_passes_unattended_journey_reason" "$?" "0"
grep -q 'auto.sh" status <target>' "$CC/qa-status.md" && grep -q 'unattended journey' "$CC/qa-status.md" && grep -q 'needsPerson' "$CC/qa-status.md" && grep -q 'stop.reason' "$CC/qa-status.md"; check "status_shows_journey_step_reason_and_count" "$?" "0"
QAU="$CC/qa-auto.md"
[ -f "$QAU" ]; check "qa_auto_source_exists" "$?" "0"
grep -qxF 'description: Drive the whole qa-kit process for a target with nobody present, record every self-answered question, and end with a handoff list for a person.' "$QAU" 2>/dev/null; check "qa_auto_description_verbatim" "$?" "0"
grep -qxF 'argument-hint: "<target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]"' "$QAU" 2>/dev/null; check "qa_auto_argument_hint_verbatim" "$?" "0"
for v in start resume next step-start step-done signin decide stop audit handoff status; do
  grep -Eq "auto\.sh\"? $v( |\$)" "$QAU" 2>/dev/null; check "qa_auto_calls_$v" "$?" "0"
done
check "qa_auto_second_look_token_once" "$(grep -c '{{SECOND_LOOK}}' "$QAU" 2>/dev/null || true)" "1"
grep -q -- '--known-defects-invalid' "$QAU" 2>/dev/null && grep -q 'caffeinate -dimsu' "$QAU" 2>/dev/null; check "qa_auto_start_flags_and_keep_awake" "$?" "0"
for r in step-failed tracker; do
  grep -q -- "--reason $r" "$QAU" 2>/dev/null; check "qa_auto_stops_with_$r" "$?" "0"
done
grep -q 'time-limit' "$QAU" 2>/dev/null; check "qa_auto_names_time_limit" "$?" "0"
for c in roles surface-access scope role-overrides journeys inputs expected gaps seed exclusion crawl-only oracle-human safety known-defect; do
  grep -q "\`$c\`" "$QAU" 2>/dev/null; check "qa_auto_names_class_$c" "$?" "0"
done
grep -q 'When unsure whether a journey is P1, mark it P1' "$QAU" 2>/dev/null; check "qa_auto_unsure_p1_is_p1" "$?" "0"
grep -q 'Never `oracleSource: "human"`' "$QAU" 2>/dev/null; check "qa_auto_never_oracle_human" "$?" "0"
grep -q 'main session' "$QAU" 2>/dev/null && grep -q '{{ENGINE_RUN}}' "$QAU" 2>/dev/null && grep -q '/qa-resume' "$QAU" 2>/dev/null; check "qa_auto_run_in_main_session_engine_run_and_resume" "$?" "0"
grep -q 'data-policy.sh list' "$QAU" 2>/dev/null && grep -q -- '--records' "$QAU" 2>/dev/null && grep -q 'known-defects.sh validate' "$QAU" 2>/dev/null; check "qa_auto_engine_results_passed_in" "$?" "0"
grep -qF "<n> items need a person's review. See the results page." "$QAU" 2>/dev/null && grep -qF "Nothing needs a person's review." "$QAU" 2>/dev/null && grep -q 'tracker.sh" spec-note' "$QAU" 2>/dev/null; check "qa_auto_fixed_clickup_note" "$?" "0"
# the words: "unattended journey"; never bare "autonomous" or "auto mode"
check "qa_auto_no_bare_autonomous" "$(grep -oi 'autonomous[A-Za-z]*' "$QAU" 2>/dev/null | grep -vc '^autonomousSetup$' || true)" "0"
check "qa_auto_no_auto_mode" "$(grep -ci 'auto mode' "$QAU" 2>/dev/null || true)" "0"
grep -q 'unattended journey' "$QAU" 2>/dev/null; check "qa_auto_says_unattended_journey" "$?" "0"
# no second copy of a step's instructions: the step scripts are named only in the step sources
for s in spec-snapshot.sh constitution.sh generate-ship-criteria.sh coverage.sh check-fixtures.sh verify-plan.sh surface-access.sh; do
  check "qa_auto_does_not_copy_step_$s" "$(grep -c "scripts/$s" "$QAU" 2>/dev/null || true)" "0"
done
# the second look follows the engine's subagentDispatch, recorded in qa-kit's own profile
check "second_look_profile_matches_engine_dispatch" "$(python3 - "$ROOT" <<'PYEOF'
import json, sys
root = sys.argv[1]
eng = json.load(open(root + "/harness-profiles.json"))["harnesses"]
kit = json.load(open(root + "/qa-kit/harness-profiles.qakit.json"))["harnesses"]
banner = "SECOND LOOK UNAVAILABLE: this harness cannot start a fresh agent; every low-confidence decision is left for a person."
bad = []
for h in ("claude", "pi", "codex", "opencode"):
    k = kit[h]
    if k.get("subagentDispatch") is not eng[h]["subagentDispatch"]:
        bad.append(h + ":dispatch")
    sl = k.get("secondLook", "")
    if "auto.sh\" second <target> --unavailable" not in sl or banner not in sl:
        bad.append(h + ":banner")
    if ("Start one fresh agent" in sl) is not bool(k.get("subagentDispatch")):
        bad.append(h + ":instruction")
print(",".join(bad) or "ok")
PYEOF
)" "ok"

# --- Fix round 2 (Task 17): F1-F7, M1-M7, the safety sentences, the words ---
QAU="$CC/qa-auto.md"; PROFJ="$ROOT/qa-kit/harness-profiles.qakit.json"
has(){ grep -qF -- "$2" "$1" 2>/dev/null; }
# sl <harness>: that harness's secondLook string
sl(){ python3 -c "import json,sys;sys.stdout.write(json.load(open(sys.argv[1]))['harnesses'][sys.argv[2]]['secondLook'])" "$PROFJ" "$1"; }
slhas(){ sl "$1" | grep -qF -- "$2"; }
# F1: a scenarios step on an existing plan only appends
has "$QAU" 'only appends' && has "$QAU" 'Never rewrite, remove, reorder or re-derive an existing row, its tags or its expected value'; check "f1_scenarios_round_only_appends" "$?" "0"
has "$QAU" 'a plan that existed when the journey started' && has "$QAU" 'that close the gaps analyze listed'; check "f1_covers_reopened_round_and_starting_plan" "$?" "0"
has "$QAU" 'a row from the starting plan is gone' && has "$QAU" 'a person-confirmed expected value is no longer marked as confirmed'; check "f1_audit_fails_on_lost_row_or_confirmation" "$?" "0"
# F2: the run step is marked done only on a finished run
has "$QAU" "only after the engine's end-of-run order has completed" && has "$QAU" 'report.md'; check "f2_step_done_run_needs_finished_run" "$?" "0"
has "$QAU" 'auto: that run started before this journey'; check "f2_names_the_script_refusal" "$?" "0"
has "$QAU" 'resume it (step 6); never mark it done'; check "f2_unfinished_run_is_resumed_never_marked_done" "$?" "0"
# F3: only a run of this journey is resumed
has "$QAU" 'is not earlier than `startedAt` in `auto.sh status <target>`' && has "$QAU" 'started_at'; check "f3_resume_only_a_run_of_this_journey" "$?" "0"
has "$QAU" 'start a new run'; check "f3_older_run_means_a_new_run" "$?" "0"
# F4: the fresh agent is told it only reads; the banner is not a way out
for s in 'You only read.' 'Change no file.' 'Run no script or command that writes.' 'Do not run auto.sh.' 'Do not correct or rewrite an answer.' 'Your whole reply is one line per decision id'; do
  slhas claude "$s"; check "f4_claude_prompt_says_${s// /_}" "$?" "0"
done
slhas claude 'allowed only when the tool for starting a fresh agent is absent or its call fails' && slhas claude 'never because of time, cost or the number of decisions'; check "f4_banner_only_when_no_fresh_agent" "$?" "0"
# F5: three fixed sentences, and when no comment is posted
has "$QAU" 'This run was stopped before it finished. See the results page.'; check "f5_stopped_sentence" "$?" "0"
has "$QAU" '`result` is `stopped`' && has "$QAU" '`needsPerson` is more than 0'; check "f5_sentence_chosen_from_result_and_needs_person" "$?" "0"
has "$QAU" 'the stop reason is not `tracker`' && has "$QAU" 'No ClickUp comment was posted'; check "f5_no_comment_without_run_or_after_tracker_stop" "$?" "0"
# F6: --unavailable runs only where the second look would have run
for h in claude pi codex opencode; do
  check "f6_${h}_no_run_before_the_audit" "$(sl "$h" | grep -ci 'once more\|before the audit' || true)" "0"
done
for h in pi codex opencode; do
  check "f6_${h}_unavailable_called_once" "$(sl "$h" | grep -c -- 'second <target> --unavailable' || true)" "1"
  slhas "$h" 'Run it only here, after `spec` and after `scenarios`'; check "f6_${h}_only_after_spec_and_scenarios" "$?" "0"
done
# F7: one token rule in /qa-tracker, nothing against it
QT="$CC/qa-tracker.md"
has "$QT" 'only ever referenced as the environment variable' && has "$QT" 'Never read it into the conversation, print, echo, paste, log or store it'; check "f7_token_rule" "$?" "0"
has "$QT" 'only the tracker script talks to ClickUp' && has "$QT" 'checking a pasted folder or list URL'; check "f7_everything_else_goes_through_the_tracker" "$?" "0"
check "f7_token_rule_stated_once" "$(grep -c 'only the tracker script talks to ClickUp' "$QT" || true)" "1"
has "$QT" 'list workspaces, spaces and folders through'; check "f7_first_setup_still_lists_through_the_api" "$?" "0"
check "f7_no_contradicting_sentence" "$(grep -c 'pass the ClickUp token yourself\|with the token in `CLICKUP_API_TOKEN`' "$QT" || true)" "0"
# safety sentences that had no test
slhas claude 'It never receives this conversation'; check "safety_fresh_agent_never_gets_the_conversation" "$?" "0"
slhas claude 'do not review the decisions yourself'; check "safety_no_self_review" "$?" "0"
slhas claude 'recorded as `ask` with the reason `no answer from the second look`'; check "safety_odd_answer_is_ask" "$?" "0"
a="$(grep -n '^9\. \*\*Audit\.\*\*' "$QAU" | cut -d: -f1)"; b="$(grep -n '^10\. \*\*Handoff\.\*\*' "$QAU" | cut -d: -f1)"
check "safety_audit_before_handoff" "$([ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo y)" "y"
has "$QAU" 'Go on to step 10 either way'; check "safety_handoff_follows_a_failed_audit" "$?" "0"
# minors
has "$QAU" '(`step-start`, `next`, `signin`, `decide`)' && has "$QAU" '--detail "<the script'"'"'s line>"'; check "m1_unruled_exit_1_stops_the_loop" "$?" "0"
has "$QAU" 'The launch profile was not applied: the spec already had its own settings.' && has "$QAU" 'write nothing to the existing run-config'; check "m2_launch_profile_not_applied_to_existing_spec" "$?" "0"
M3='When a person runs this command while a journey is open for the target, tell them first that an unattended journey is open; `auto.sh status` exit 1 means no journey, and the command goes on as usual.'
for f in qa-constitution qa-spec qa-scenarios qa-analyze; do
  grep -A1 -F "$OJ" "$CC/$f.md" | tail -1 | grep -qF "$M3"; check "m3_person_told_first_${f}" "$?" "0"
done
has "$CC/qa-constitution.md" 'run it for each directory under `.qa/specs/`'; check "m3_constitution_finds_the_target" "$?" "0"
has "$QAU" "the engine's resume command (\`/qa-resume <run-id>\`; on a harness that prefixes plugin commands, the same prefix as the run command above)"; check "m4_resume_wording" "$?" "0"
has "$QAU" 'shows that step still `running`' && has "$QAU" 'A second failure of the same step is `step-failed`'; check "m5_redo_count_comes_from_status" "$?" "0"
has "$QAU" 'At the start of every `/qa-auto` invocation' && has "$QAU" '--reason step-failed --detail "the known-defect registry is not valid"'; check "m6_registry_checked_every_invocation" "$?" "0"
grep -q 'substituted AFTER the skill and engine-run tokens' "$ROOT/qa-kit/scripts/build-qakit-adapter.sh" && grep -q 'must not contain them' "$ROOT/qa-kit/scripts/build-qakit-adapter.sh"; check "m7_token_order_comment" "$?" "0"
check "m7_second_look_has_no_earlier_token" "$(grep -c '{{SKILL_REF\|{{ENGINE_RUN' "$PROFJ" || true)" "0"
# the words, in the profile strings and every command source this lane edited
for f in "$PROFJ" "$CC/qa-auto.md" "$CC/qa-constitution.md" "$CC/qa-spec.md" "$CC/qa-scenarios.md" "$CC/qa-analyze.md" "$CC/qa-status.md" "$CC/qa-tracker.md"; do
  check "no_bare_autonomous_$(basename "$f")" "$(grep -oi 'autonomous[A-Za-z]*' "$f" 2>/dev/null | grep -vc '^autonomousSetup$' || true)" "0"
  check "no_auto_mode_$(basename "$f")" "$(grep -ci 'auto mode' "$f" 2>/dev/null || true)" "0"
done

# --- Verdict line: one machine-readable line under ## Verdict ---
TPL="$ROOT/qa-kit/templates/qa-analyze-template.md"
check "vl_template_verdict_line_first" "$(awk '/^## Verdict$/{f=1;next} f&&NF{print;exit}' "$TPL")" "Verdict: {{VERDICT}}"
has "$CC/qa-analyze.md" '`Verdict: BLOCKED`' && has "$CC/qa-analyze.md" '`Verdict: PASS (advisory)`' && has "$CC/qa-analyze.md" 'nothing else on the line'; check "vl_analyze_names_both_values" "$?" "0"
has "$CC/qa-status.md" '`Verdict: BLOCKED`' && has "$CC/qa-status.md" '`Verdict: PASS (advisory)`' && has "$CC/qa-status.md" 'not finished'; check "vl_status_reads_the_line" "$?" "0"
has "$CC/qa-auto.md" 'reads that one line'; check "vl_auto_reads_the_line" "$?" "0"
# /qa-auto follows the final auto.sh rules (limits in step verbs, run refusals, run-config keys, audit before handoff)
has "$CC/qa-auto.md" 'A limit stop is not a failed step' && has "$CC/qa-auto.md" 'do not call `stop`'; check "qa_auto_step_verbs_limit_stop" "$?" "0"
has "$CC/qa-auto.md" 'auto: that run is still in progress' && has "$CC/qa-auto.md" 'auto: that run has no results for this spec' && has "$CC/qa-auto.md" 'auto: run has no result yet' && has "$CC/qa-auto.md" 'auto: verify has no result yet'; check "qa_auto_step_done_run_refusals" "$?" "0"
has "$CC/qa-auto.md" '`gates`, `humanInteraction`, `environment`, `allowApiWrites`, `seedableEnvMarker`, `allowBlackboxCrawl`, `profile` and `baseUrl`' && has "$CC/qa-auto.md" 'run-config-safety:<key>'; check "qa_auto_run_config_whole_keys" "$?" "0"
has "$CC/qa-auto.md" 'not older than the last step' && has "$CC/qa-auto.md" 'The audit has not run for this journey.'; check "qa_auto_audit_before_handoff" "$?" "0"
for f in qa-analyze qa-status; do
  has "$ROOT/qa-kit/commands/$f.md" 'Verdict: PASS (advisory)'; check "vl_rendered_$f" "$?" "0"
done

echo "qa-kit-phases: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
