#!/usr/bin/env bash
# Dual-engine tests for `auto.sh audit`: after an unattended journey, the script compares the
# files as they are now with the baseline taken at `start` and fails the journey when a limit was
# crossed. (The state machine is tested in tests/qa-auto/, the decision verbs in
# tests/qa-auto-decisions/; this suite is separate so each stays well inside the CI time cap.)
#
# Every violation code has a case that starts from a clean finished journey, makes exactly one
# change and expects exactly that code. Every case runs under QA_ENGINE=jq and QA_ENGINE=python3;
# a final block compares the two engines' output and journey.json byte for byte. The tracker
# command is always a stub (QA_AUTO_TRACKER_CMD). No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-audit: python3 is needed to read results - suite cannot run" >&2; exit 1; }
# The real interpreter, not a version-manager shim (see tests/qa-auto/run.sh).
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; [ -x "$PY" ] || PY=python3
case "$PY" in */python3) PATH="${PY%/python3}:$PATH"; export PATH ;; esac
pass=0; fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
T_OLD=202611270700; T_MID=202611270710
auto() { QA_ENGINE="$E" QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" bash "$SH" "$@"; }
jv() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
snapshot() { (cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done); }
sha() { "$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# ed <json file> <python statements over d> — change a JSON file in place.
ed() { "$PY" -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding="utf-8")); exec(sys.argv[2])
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False)' "$1" "$2"; }
# edk <project> <python statements over d> — change the plan without touching its file time (a
# newer plan than its analysis is a separate finding, `step-without-result:analyze`).
edk() { ed "$1/.qa/specs/checkout/checklist.json" "$2"; touch -t "$T_OLD" "$1/.qa/specs/checkout/checklist.json"; }

# Tracker stubs. The audit runs `$QA_AUTO_TRACKER_CMD spec-status --spec <target> --project <dir>`.
printf '#!/usr/bin/env bash\nprintf "SKIP\\tnot-set-up\\t%%s\\n" checkout\necho "SUMMARY {\\"skip\\": 1} dry-run"\n' > "$ROOT/trk-skip.sh"
printf '#!/usr/bin/env bash\necho "LINK\\tfolder\\thttps://app.clickup.example/901"\necho "{\\"behind\\": true, \\"cards\\": 2}"\n' > "$ROOT/trk-behind.sh"
printf '#!/usr/bin/env bash\necho "LINK\\tfolder\\thttps://app.clickup.example/901"\necho "{\\"behind\\": false, \\"cards\\": 0}"\n' > "$ROOT/trk-level.sh"
printf '#!/usr/bin/env bash\necho "error: 401 the token pk_81_SECRETVALUE was refused" >&2\necho "half a line"\nexit 3\n' > "$ROOT/trk-fail.sh"
printf '#!/usr/bin/env bash\necho "everything looks fine"\n' > "$ROOT/trk-noise.sh"
printf '#!/usr/bin/env bash\necho "{\\"behind\\": \\"no\\"}"\n' > "$ROOT/trk-odd.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/trk-args.txt"\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\n' "$ROOT" > "$ROOT/trk-args.sh"
printf '#!/usr/bin/env bash\nsleep 6\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\n' > "$ROOT/trk-slow.sh"
TRK=""
# au <project> — the audit, with the stub tracker ($TRK names the stub; default: not set up).
au() { QA_AUTO_TRACKER_CMD="bash $ROOT/trk-${TRK:-skip}.sh" auto audit checkout --project "$1"; }
# expect <label> <project> <exit code> <violations, as the inside of the JSON array>
expect() {
  local out rc ok=true
  out="$(au "$2" 2>&1)"; rc=$?
  [ "$3" = 0 ] || ok=false
  check "$E $1" "$rc|$out" "$3|{\"ok\":$ok,\"violations\":[$4]}"
}

artifact() {
  local P="$1" S="$1/.qa/specs/checkout" R="$1/.qa/runs/r1"
  mkdir -p "$S"
  case "$2" in
    constitution) printf '{"version":"c1"}\n' > "$P/.qa/constitution.state.json" ;;
    spec)         printf '# QA spec\n' > "$S/qa-spec.md"; printf '{"roles":[]}\n' > "$S/spec-roles.json" ;;
    scenarios)    printf '# Scenarios\n' > "$S/scenarios.md"; cp "$FX/checklist.json" "$S/checklist.json"; touch -t "$T_OLD" "$S/checklist.json" ;;
    analyze)      cp "$FX/analysis-pass.md" "$S/analysis.md"; touch -t "$T_MID" "$S/analysis.md" ;;
    run)          mkdir -p "$R"
                  printf '{"run_id":"r1","target_feature":"checkout","started_at":"2026-11-27T08:30:00Z","status":"complete"}\n' > "$R/run-manifest.json"
                  printf '{"criteria":[]}\n' > "$R/checkpoint.json"; printf '# Report\n' > "$R/report.md" ;;
    verify)       mkdir -p "$R"; printf '{"overrides":[]}\n' > "$R/verification.json" ;;
  esac
}
done_step() {
  artifact "$1" "$2"
  if [ "$2" = run ]; then auto step-done checkout run --run r1 --project "$1" >/dev/null 2>&1
  else auto step-done checkout "$2" --project "$1" >/dev/null 2>&1; fi
}
RICH_CONFIG='{"baseUrl":"http://localhost:3000","allowApiWrites":false,"seedableEnvMarker":"","environment":"auto","allowBlackboxCrawl":true,"gates":{"dataPolicy":"enforce","oracle":"advise"},"humanInteraction":{"enforce":true,"maxOptOutRate":0.2},"profile":"full"}'
# fin [shape] — a project for the target `checkout` whose journey has ended cleanly. Built once per
# engine and shape, then copied with file times (`start` is the slow verb). Shapes:
#   plain  finished (state done); known defects, exclusions, a run-config without safety keys, one decision
#   ship   as plain, launched with --profile ship
#   rich   finished; config with `gates`; run-config with one safety key; seed.json there from the start
#   bare   finished; no known-defect registry, no exclusions, no run-config, no decision
#   open   every step done, `next` not asked yet (state open)
#   atrun  stopped (time-limit) with analyze done and no run
#   atverify  stopped (step-failed) with the run done and nothing verified
fin() {
  local shape="${1:-plain}" tpl="$ROOT/tpl-$E-${1:-plain}" P S flags=""
  if [ ! -d "$tpl" ]; then
    P="$(mktemp -d "$ROOT/p.XXXXXX")"; S="$P/.qa/specs/checkout"; mkdir -p "$S"
    if [ "$shape" = rich ]; then printf '%s\n' "$RICH_CONFIG" > "$P/.qa/config.json"; else cp "$FX/config-local.json" "$P/.qa/config.json"; fi
    artifact "$P" constitution; artifact "$P" spec; artifact "$P" scenarios
    case "$shape" in
      bare) ;;
      rich) cp "$FX/known-defects.json" "$P/.qa/known-defects.json"; cp "$FX/coverage-exclusions.json" "$S/coverage-exclusions.json"
            printf '{"allowBlackboxCrawl":false,"criteriaBudget":40}\n' > "$S/run-config.json"
            printf '{"command":"php artisan db:seed","cwd":"."}\n' > "$S/seed.json" ;;
      *)    cp "$FX/known-defects.json" "$P/.qa/known-defects.json"; cp "$FX/coverage-exclusions.json" "$S/coverage-exclusions.json"
            printf '{"criteriaBudget":40}\n' > "$S/run-config.json" ;;
    esac
    [ "$shape" = ship ] && flags="--profile ship"
    # shellcheck disable=SC2086
    auto start checkout --project "$P" $flags >/dev/null 2>&1
    [ "$shape" = bare ] || auto decide checkout --project "$P" --step spec --class scope --question "أي الشاشات تدخل في النطاق؟" --answer "شاشات السلة والدفع" --evidence "routes/web.php:12" --confidence high >/dev/null 2>&1
    done_step "$P" analyze
    case "$shape" in
      atrun) auto stop checkout --project "$P" --reason time-limit --detail "the deadline has passed" >/dev/null 2>&1 ;;
      atverify) done_step "$P" run; auto stop checkout --project "$P" --reason step-failed --detail "the verification did not finish" >/dev/null 2>&1 ;;
      open) done_step "$P" run; done_step "$P" verify ;;
      *) done_step "$P" run; done_step "$P" verify; auto next checkout --project "$P" >/dev/null 2>&1 ;;
    esac
    mv "$P" "$tpl"
  fi
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; rmdir "$P"; cp -Rp "$tpl" "$P"
  printf '%s' "$P"
}

run_engine() {
  E="$1"
  local P S J B out rc before k v c i

  # ---- the fixture itself, and what `start` now records ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; J="$S/auto/journey.json"; B="$S/auto/baseline.json"
  check "$E the fixture is a finished journey" "$(jv "$J" '[d["state"],d["runId"],[s["state"] for s in d["steps"]]]')" '["done", "r1", ["done", "done", "done", "done", "done", "done"]]'
  check "$E start records every row id of the plan" "$(jv "$B" 'd["planRowIds"]')" '["C-001", "C-002", "C-003", "C-004", "C-005"]'
  check "$E start still records the person-confirmed rows" "$(jv "$B" 'd["humanOracleIds"]')" '["C-001", "C-004"]'
  check "$E start records the baseline's hash in the journey" "$(jv "$J" 'd["baselineHash"]')" "$(sha "$B")"
  out="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$out/.qa"; cp "$FX/config-local.json" "$out/.qa/config.json"
  auto start checkout --project "$out" >/dev/null 2>&1
  check "$E a journey that starts without a plan records no row ids" "$(jv "$out/.qa/specs/checkout/auto/baseline.json" '[d["planRowIds"],d["humanOracleIds"]]')" '[null, []]'

  # ---- clean_journey_passes ----
  before="$(snapshot "$P")"
  out="$(au "$P" 2>&1)"; rc=$?
  check "$E clean_journey_passes" "$rc|$out" '0|{"ok":true,"violations":[]}'
  check "$E a passing audit changes nothing" "$(snapshot "$P")" "$before"
  for k in ship rich bare; do expect "clean $k journey passes" "$(fin "$k")" 0 ""; done
  P="$(fin open)"; before="$(snapshot "$P")"
  expect "an open journey can be audited" "$P" 0 ""
  check "$E a passing audit leaves an open journey open" "$(snapshot "$P")" "$before"

  # ---- usage and refusals ----
  P="$(fin)"; before="$(snapshot "$P")"
  auto audit checkout extra --project "$P" >/dev/null 2>&1; check "$E audit with an extra word is usage" "$?" "2"
  auto audit --project "$P" >/dev/null 2>&1; check "$E audit without a target is usage" "$?" "2"
  check "$E a usage error writes nothing" "$(snapshot "$P")" "$before"
  out="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$out/.qa"; cp "$FX/config-local.json" "$out/.qa/config.json"
  v="$(au "$out" 2>&1)"; rc=$?
  check "$E audit without a journey is refused" "$rc|$v" "1|auto: no journey for checkout"
  printf '{"state":' > "$P/.qa/specs/checkout/auto/journey.json"
  v="$(au "$P" 2>&1)"; rc=$?
  check "$E audit on a journey file that does not parse is refused" "$rc|$v" "1|auto: journey.json for checkout is not readable"

  # ---- safety-setting-changed:<key>, one key at a time ----
  while IFS='|' read -r k v; do
    P="$(fin)"; ed "$P/.qa/config.json" "$v"
    expect "safety-setting-changed:$k" "$P" 1 "\"safety-setting-changed:$k\""
  done <<'EOT'
allowApiWrites|d["allowApiWrites"]=True
seedableEnvMarker|d["seedableEnvMarker"]="MATJAR_DISPOSABLE"
environment|d["environment"]="disposable"
allowBlackboxCrawl|d["allowBlackboxCrawl"]=True
gates|d["gates"]={"dataPolicy":"off"}
profile|d["profile"]="smoke"
humanInteraction.enforce|d["humanInteraction"]["enforce"]=False
humanInteraction.maxOptOutRate|d["humanInteraction"]["maxOptOutRate"]=0.9
EOT
  P="$(fin)"; ed "$P/.qa/config.json" 'd["allowApiWrites"]="false"'
  expect "a changed type is a change (false to the text false)" "$P" 1 '"safety-setting-changed:allowApiWrites"'
  P="$(fin)"; ed "$P/.qa/config.json" 'del d["allowBlackboxCrawl"]'
  expect "a removed safety key is a change" "$P" 1 '"safety-setting-changed:allowBlackboxCrawl"'
  P="$(fin)"; printf '{"profile":"full","humanInteraction":{"maxOptOutRate":0.20,"autonomousSetup":false,"saveSession":true,"enforce":true},\n "allowBlackboxCrawl":false,"environment":"auto","seedableEnvMarker":"","allowApiWrites":false,"auth":{"storageState":"x.json"},"baseUrl":"http://127.0.0.1:8000"}\n' > "$P/.qa/config.json"
  expect "key order, number spelling and other keys are not a change" "$P" 0 ""
  # the nested gates object
  P="$(fin rich)"; ed "$P/.qa/config.json" 'd["gates"]["oracle"]="off"'
  expect "a changed member of gates" "$P" 1 '"safety-setting-changed:gates"'
  P="$(fin rich)"; ed "$P/.qa/config.json" 'd["gates"]["coverage"]="advise"'
  expect "an added member of gates" "$P" 1 '"safety-setting-changed:gates"'
  P="$(fin rich)"; ed "$P/.qa/config.json" 'del d["gates"]["dataPolicy"]'
  expect "a removed member of gates" "$P" 1 '"safety-setting-changed:gates"'
  P="$(fin rich)"; ed "$P/.qa/config.json" 'd["gates"]={"oracle":"advise","dataPolicy":"enforce"}'
  expect "gates in another key order is not a change" "$P" 0 ""
  # the config file itself
  P="$(fin)"; cp "$P/.qa/config.json" "$P/elsewhere.json"; rm "$P/.qa/config.json"; ln -s "$P/elsewhere.json" "$P/.qa/config.json"
  expect "a symlinked config with the same values passes" "$P" 0 ""
  ed "$P/elsewhere.json" 'd["allowApiWrites"]=True'
  expect "a symlinked config is read through the link" "$P" 1 '"safety-setting-changed:allowApiWrites"'
  ALL8='"safety-setting-changed:allowApiWrites","safety-setting-changed:allowBlackboxCrawl","safety-setting-changed:environment","safety-setting-changed:gates","safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate","safety-setting-changed:profile","safety-setting-changed:seedableEnvMarker"'
  P="$(fin)"; rm "$P/.qa/config.json"; ln -s "$P/nowhere.json" "$P/.qa/config.json"
  expect "a config link that leads nowhere fails every key" "$P" 1 "$ALL8"
  P="$(fin)"; rm "$P/.qa/config.json"
  expect "a removed config fails every key" "$P" 1 "$ALL8"
  P="$(fin)"; printf '{"allowApiWrites":' > "$P/.qa/config.json"
  expect "a config that does not parse fails every key" "$P" 1 "$ALL8"

  # ---- run-config-safety:<key> ----
  while IFS='|' read -r k v; do
    P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" "$v"
    expect "run-config-safety:$k" "$P" 1 "\"run-config-safety:$k\""
  done <<'EOT'
allowApiWrites|d["allowApiWrites"]=True
seedableEnvMarker|d["seedableEnvMarker"]="MATJAR_DISPOSABLE"
environment|d["environment"]="disposable"
allowBlackboxCrawl|d["allowBlackboxCrawl"]=True
gates|d["gates"]={"dataPolicy":"off"}
profile|d["profile"]="smoke"
humanInteraction.enforce|d["humanInteraction"]={"enforce":False}
humanInteraction.maxOptOutRate|d["humanInteraction"]={"maxOptOutRate":0.9}
EOT
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["allowApiWrites"]=False'
  expect "a safety key added with the project's own value is still a violation" "$P" 1 '"run-config-safety:allowApiWrites"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["criteriaBudget"]=10; d["journeys"]=["checkout"]'
  expect "other run-config keys are free" "$P" 0 ""
  # launch_profile_is_not_a_violation
  P="$(fin ship)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["profile"]="ship"'
  expect "launch_profile_is_not_a_violation" "$P" 0 ""
  P="$(fin ship)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["profile"]="full"'
  expect "a profile other than the launch profile" "$P" 1 '"run-config-safety:profile"'
  P="$(fin ship)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["profile"]=["ship"]'
  expect "the launch profile in another type" "$P" 1 '"run-config-safety:profile"'
  P="$(fin bare)"; printf '{"allowBlackboxCrawl":true}\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that appears with a safety key" "$P" 1 '"run-config-safety:allowBlackboxCrawl"'
  P="$(fin bare)"; printf '{"criteriaBudget":12}\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that appears without safety keys passes" "$P" 0 ""
  # a safety key the run-config already had at the start
  P="$(fin rich)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["allowBlackboxCrawl"]=True'
  expect "a starting run-config safety value that changed" "$P" 1 '"run-config-safety:allowBlackboxCrawl"'
  P="$(fin rich)"; ed "$P/.qa/specs/checkout/run-config.json" 'del d["allowBlackboxCrawl"]'
  expect "a starting run-config safety key that was removed" "$P" 1 '"run-config-safety:allowBlackboxCrawl"'
  P="$(fin rich)"; rm "$P/.qa/specs/checkout/run-config.json"
  expect "a removed run-config that held a safety key" "$P" 1 '"run-config-safety:allowBlackboxCrawl"'
  P="$(fin)"; printf '{"criteriaBudget":' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that does not parse fails every key" "$P" 1 '"run-config-safety:allowApiWrites","run-config-safety:allowBlackboxCrawl","run-config-safety:environment","run-config-safety:gates","run-config-safety:humanInteraction.enforce","run-config-safety:humanInteraction.maxOptOutRate","run-config-safety:profile","run-config-safety:seedableEnvMarker"'

  # ---- the plan: human-oracle-added, plan-row-removed, human-oracle-removed, plan-unreadable ----
  P="$(fin)"; edk "$P" 'd[1]["fixture"]["expect"]["oracleSource"]="human"'
  expect "human-oracle-added:<criterion id>" "$P" 1 '"human-oracle-added:C-002"'
  P="$(fin)"; edk "$P" 'd[2]["fixture"]={"expect":{"value":"3","oracleSource":"human"}}'
  expect "human-oracle-added on a row that had no expected value" "$P" 1 '"human-oracle-added:C-003"'
  P="$(fin)"; edk "$P" 'd.append({"id":"C-900","title":"رسوم الدفع عند الاستلام","kind":"computed-logic","fixture":{"expect":{"value":"10.00","oracleSource":"human"}}})'
  expect "human-oracle-added on a new row" "$P" 1 '"human-oracle-added:C-900"'
  P="$(fin)"; edk "$P" 'd.append({"id":"C-901","title":"سلة فارغة تعرض رسالة","kind":"bake"}); d.append({"id":"C-902","kind":"business-rule","fixture":{"expect":{"value":"1","oracleSource":"llm-suggested"}}})'
  expect "adding rows is allowed" "$P" 0 ""
  P="$(fin)"; edk "$P" 'd.reverse(); d[0]["title"]="حد الطلب الأدنى للتوصيل"'
  expect "reordered rows and a changed title pass" "$P" 0 ""
  P="$(fin)"; edk "$P" 'del d[2]'
  expect "plan-row-removed:<criterion id>" "$P" 1 '"plan-row-removed:C-003"'
  P="$(fin)"; edk "$P" 'del d[0]'
  expect "a removed person-confirmed row is reported once, as removed" "$P" 1 '"plan-row-removed:C-001"'
  P="$(fin)"; edk "$P" 'd[2]["id"]="C-003b"'
  expect "a renamed row is a removed row" "$P" 1 '"plan-row-removed:C-003"'
  P="$(fin)"; edk "$P" 'd[0]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  expect "human-oracle-removed:<criterion id>" "$P" 1 '"human-oracle-removed:C-001"'
  P="$(fin)"; edk "$P" 'del d[3]["fixture"]'
  expect "human-oracle-removed when the expected value is dropped" "$P" 1 '"human-oracle-removed:C-004"'
  P="$(fin)"; edk "$P" 'd[0]["fixture"]["expect"]["value"]="120.00"'
  expect "known limit: a changed expected value on a row that stays person-confirmed is not seen" "$P" 0 ""
  P="$(fin)"; printf '[{"id":' > "$P/.qa/specs/checkout/checklist.json"; touch -t "$T_OLD" "$P/.qa/specs/checkout/checklist.json"
  expect "plan-unreadable (does not parse)" "$P" 1 '"plan-unreadable"'
  P="$(fin)"; : > "$P/.qa/specs/checkout/checklist.json"; touch -t "$T_OLD" "$P/.qa/specs/checkout/checklist.json"
  expect "plan-unreadable (empty file)" "$P" 1 '"plan-unreadable"'
  P="$(fin)"; printf '{"criteria":%s}\n' "$(cat "$FX/checklist.json")" > "$P/.qa/specs/checkout/checklist.json"; touch -t "$T_OLD" "$P/.qa/specs/checkout/checklist.json"
  expect "plan-unreadable (not a list of rows)" "$P" 1 '"plan-unreadable"'
  P="$(fin)"; rm "$P/.qa/specs/checkout/checklist.json"
  expect "a deleted plan loses every row and the scenarios result" "$P" 1 '"plan-row-removed:C-001","plan-row-removed:C-002","plan-row-removed:C-003","plan-row-removed:C-004","plan-row-removed:C-005","step-without-result:scenarios"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/checklist.json" 'd.append({"id":"C-901","kind":"bake"})'
  expect "a plan changed after its analysis" "$P" 1 '"step-without-result:analyze"'
  # a baseline written before row ids were recorded: the plan counts as not there at the start
  P="$(fin)"; J="$P/.qa/specs/checkout/auto/journey.json"; B="$P/.qa/specs/checkout/auto/baseline.json"
  ed "$B" 'del d["planRowIds"]'; ed "$J" "d['baselineHash']='$(sha "$B")'"
  edk "$P" 'del d[2]'
  expect "an older baseline has no starting rows to lose" "$P" 0 ""
  edk "$P" 'del d[0]'
  expect "an older baseline still knows its person-confirmed rows" "$P" 1 '"human-oracle-removed:C-001"'

  # ---- seed-added ----
  P="$(fin)"; printf '{"command":"php artisan db:seed","cwd":"."}\n' > "$P/.qa/specs/checkout/seed.json"
  expect "seed-added" "$P" 1 '"seed-added"'
  P="$(fin)"; ln -s "$P/nowhere.json" "$P/.qa/specs/checkout/seed.json"
  expect "seed-added for a link too" "$P" 1 '"seed-added"'
  P="$(fin rich)"; printf '{"command":"php artisan migrate:fresh --seed","cwd":"."}\n' > "$P/.qa/specs/checkout/seed.json"
  expect "a seed.json that was there at the start is not seed-added" "$P" 0 ""

  # ---- exclusion-added ----
  P="$(fin)"; ed "$P/.qa/specs/checkout/coverage-exclusions.json" 'd.append({"surfaceId":"page:Orders/Refund","personaId":"cashier","reason":"الاسترجاع خارج النطاق"})'
  expect "exclusion-added" "$P" 1 '"exclusion-added"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/coverage-exclusions.json" 'd[0]["personaId"]="*"'
  expect "a widened exclusion is an added one" "$P" 1 '"exclusion-added"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/coverage-exclusions.json" 'd.reverse(); d[0]=dict(reversed(list(d[0].items())))'
  expect "exclusions in another order pass" "$P" 0 ""
  P="$(fin)"; ed "$P/.qa/specs/checkout/coverage-exclusions.json" 'del d[0]'
  expect "a removed exclusion passes" "$P" 0 ""
  P="$(fin)"; rm "$P/.qa/specs/checkout/coverage-exclusions.json"
  expect "a removed exclusions file passes" "$P" 0 ""
  P="$(fin)"; printf '[{"surfaceId":' > "$P/.qa/specs/checkout/coverage-exclusions.json"
  expect "exclusions that do not parse" "$P" 1 '"exclusion-added"'
  P="$(fin)"; printf '{"exclusions":%s}\n' "$(cat "$FX/coverage-exclusions.json")" > "$P/.qa/specs/checkout/coverage-exclusions.json"
  expect "exclusions in another shape" "$P" 1 '"exclusion-added"'
  P="$(fin bare)"; printf '[{"surfaceId":"page:Orders/Refund","personaId":"*","reason":"خارج النطاق"}]\n' > "$P/.qa/specs/checkout/coverage-exclusions.json"
  expect "an exclusions file that appears" "$P" 1 '"exclusion-added"'
  P="$(fin bare)"; printf '[]\n' > "$P/.qa/specs/checkout/coverage-exclusions.json"
  expect "an empty exclusions file that appears passes" "$P" 0 ""

  # ---- known-defects-changed ----
  P="$(fin)"; ed "$P/.qa/known-defects.json" 'd["defects"].append({"id":"KD-2","title":"الإجمالي لا يشمل الضريبة","ticket":"SHOP-300","expiry":"2026-12-31"})'
  expect "known-defects-changed" "$P" 1 '"known-defects-changed"'
  P="$(fin)"; printf '\n' >> "$P/.qa/known-defects.json"
  expect "known-defects-changed on one added byte" "$P" 1 '"known-defects-changed"'
  P="$(fin)"; rm "$P/.qa/known-defects.json"
  expect "known-defects-changed when the registry is removed" "$P" 1 '"known-defects-changed"'
  P="$(fin bare)"; cp "$FX/known-defects.json" "$P/.qa/known-defects.json"
  expect "known-defects-changed when a registry appears" "$P" 1 '"known-defects-changed"'

  # ---- forbidden-decision:<id>, decisions-unreadable ----
  i=1
  for c in seed exclusion crawl-only oracle-human safety known-defect budget; do
    i=$((i + 1))
    P="$(fin)"; ed "$P/.qa/specs/checkout/auto/decisions.json" "d.append({'id':'D$i','step':'spec','class':'$c','question':'q','answer':'a','evidence':'e','confidence':'high','criteria':[],'assumption':True,'needsPerson':False,'second':None,'secondReason':None})"
    expect "forbidden-decision:<id> for class $c" "$P" 1 "\"forbidden-decision:D$i\""
  done
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/decisions.json" 'd.append({"id":"D2","step":"spec","question":"q","answer":"a"}); d.append({"class":"seed"}); d.append("note")'
  expect "a decision without a class, and one without an id" "$P" 1 '"forbidden-decision:#3","forbidden-decision:D2"'
  P="$(fin)"; printf '[{"id":"D1",' > "$P/.qa/specs/checkout/auto/decisions.json"
  expect "decisions-unreadable (does not parse)" "$P" 1 '"decisions-unreadable"'
  P="$(fin)"; printf '{"decisions":[]}\n' > "$P/.qa/specs/checkout/auto/decisions.json"
  expect "decisions-unreadable (not a list)" "$P" 1 '"decisions-unreadable"'
  P="$(fin)"; rm "$P/.qa/specs/checkout/auto/decisions.json"
  expect "no decisions file passes" "$P" 0 ""

  # ---- step-without-result:<step>, not-verified ----
  while IFS='|' read -r k v; do
    P="$(fin)"; rm "$P/$v"
    expect "step-without-result:$k" "$P" 1 "\"step-without-result:$k\""
  done <<'EOT'
constitution|.qa/constitution.state.json
spec|.qa/specs/checkout/spec-roles.json
scenarios|.qa/specs/checkout/scenarios.md
analyze|.qa/specs/checkout/analysis.md
run|.qa/runs/r1/report.md
EOT
  P="$(fin)"; rm "$P/.qa/runs/r1/verification.json"
  expect "not-verified" "$P" 1 '"not-verified"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/journey.json" 'd["runId"]=None'
  expect "a finished journey without a run id" "$P" 1 '"not-verified","step-without-result:run"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/journey.json" 'd["steps"][5]["state"]="pending"'
  expect "a journey marked done whose verify step is not done, with a verification on disk" "$P" 0 ""
  rm "$P/.qa/runs/r1/verification.json"
  expect "a journey marked done without a verification" "$P" 1 '"not-verified"'

  # ---- early_stop_audited_without_verify_checks ----
  P="$(fin atrun)"; before="$(snapshot "$P")"
  expect "early_stop_audited_without_verify_checks (stopped before the run)" "$P" 0 ""
  check "$E a passing audit leaves the stop as it was" "$(snapshot "$P")" "$before"
  P="$(fin atverify)"
  expect "early_stop_audited_without_verify_checks (stopped before verify)" "$P" 0 ""
  P="$(fin atrun)"; rm "$P/.qa/specs/checkout/qa-spec.md"; printf '{"x":1}\n' > "$P/.qa/specs/checkout/seed.json"
  expect "an early stop is still audited for what it reached" "$P" 1 '"seed-added","step-without-result:spec"'
  check "$E a stopped journey that fails its audit is stopped for the audit" "$(jv "$P/.qa/specs/checkout/auto/journey.json" '[d["state"],d["stop"],d["stopBeforeAudit"]]')" '["stopped", {"detail": "seed-added, step-without-result:spec", "reason": "audit"}, {"detail": "the deadline has passed", "reason": "time-limit"}]'
  out="$(auto resume checkout --project "$P" 2>&1)"; rc=$?
  check "$E a journey stopped by its audit cannot be resumed" "$rc|$out" "1|auto: nothing to resume"

  # ---- the tracker ----
  P="$(fin)"; TRK=behind expect "tracker-behind" "$P" 1 '"tracker-behind"'
  P="$(fin)"; TRK=level expect "a tracker that is level passes" "$P" 0 ""
  P="$(fin)"; TRK=skip expect "untracked_spec_skips_tracker_check" "$P" 0 ""
  P="$(fin)"; out="$(TRK=fail au "$P" 2>&1)"; rc=$?
  check "$E tracker_failure_is_violation" "$rc|$out" '1|{"ok":false,"violations":["tracker-behind"]}'
  check "$E the tracker's error text is stored nowhere" "$(grep -rl "SECRETVALUE" "$P" | wc -l | tr -d ' ')" "0"
  P="$(fin)"; TRK=noise expect "tracker output without an answer is a violation" "$P" 1 '"tracker-behind"'
  P="$(fin)"; TRK=odd expect "a behind value that is not false is a violation" "$P" 1 '"tracker-behind"'
  P="$(fin)"; out="$(QA_AUTO_TRACKER_CMD="$ROOT/no-such-command" auto audit checkout --project "$P" 2>&1)"; rc=$?
  check "$E a tracker command that cannot run is a violation" "$rc|$out" '1|{"ok":false,"violations":["tracker-behind"]}'
  P="$(fin)"; out="$(QA_AUTO_TRACKER_CMD="   " auto audit checkout --project "$P" 2>&1)"; rc=$?
  check "$E a blank tracker command is a violation" "$rc|$out" '1|{"ok":false,"violations":["tracker-behind"]}'
  P="$(fin)"; TRK=args au "$P" >/dev/null 2>&1
  check "$E the tracker is asked for this spec in this project" "$(cat "$ROOT/trk-args.txt")" "spec-status --spec checkout --project $P"
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    P="$(fin)"; out="$(QA_AUTO_TRACKER_TIMEOUT=1 TRK=slow au "$P" 2>&1)"; rc=$?
    check "$E a tracker that does not answer in time is a violation" "$rc|$out" '1|{"ok":false,"violations":["tracker-behind"]}'
  fi

  # ---- two_violations_both_reported, and what a failed audit does to the journey ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; J="$S/auto/journey.json"
  printf '{"command":"php artisan db:seed","cwd":"."}\n' > "$S/seed.json"; ed "$P/.qa/config.json" 'd["allowApiWrites"]=True'
  before="$(snapshot "$P" | grep -v '/auto/journey.json$')"
  out="$(NOW="2026-11-27T11:00:00Z" au "$P" 2>/dev/null)"; rc=$?
  check "$E two_violations_both_reported" "$rc|$out" '1|{"ok":false,"violations":["safety-setting-changed:allowApiWrites","seed-added"]}'
  check "$E a done journey that fails its audit is stopped" "$(jv "$J" '[d["state"],d["stop"],d["endedAt"],d["auditViolations"],d["stopBeforeAudit"]]')" '["stopped", {"detail": "safety-setting-changed:allowApiWrites, seed-added", "reason": "audit"}, "2026-11-27T11:00:00Z", ["safety-setting-changed:allowApiWrites", "seed-added"], null]'
  check "$E a failed audit writes journey.json only" "$(snapshot "$P" | grep -v '/auto/journey.json$')" "$before"
  check "$E no temp file is left behind" "$(ls "$S/auto" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json decisions.json journey.json "
  check "$E next shows the audit stop" "$(auto next checkout --project "$P" 2>&1)" '{"detail":"safety-setting-changed:allowApiWrites, seed-added","next":"stopped","reason":"audit"}'
  # the same answer twice, byte for byte
  before="$(snapshot "$P")"
  out="$(NOW="2026-11-27T12:00:00Z" au "$P" 2>/dev/null)"; rc=$?
  check "$E a second audit gives the same answer" "$rc|$out" '1|{"ok":false,"violations":["safety-setting-changed:allowApiWrites","seed-added"]}'
  check "$E a second audit changes nothing" "$(snapshot "$P")" "$before"
  # undoing the change does not clear the failure
  rm "$S/seed.json"; ed "$P/.qa/config.json" 'd["allowApiWrites"]=False'
  before="$(snapshot "$P")"
  out="$(au "$P" 2>/dev/null)"; rc=$?
  check "$E undoing the changes does not clear a failed audit" "$rc|$out" '1|{"ok":false,"violations":["safety-setting-changed:allowApiWrites","seed-added"]}'
  check "$E the journey stays stopped for the audit" "$(snapshot "$P")" "$before"
  # a later violation is added to the earlier ones
  rm "$P/.qa/runs/r1/verification.json"
  out="$(NOW="2026-11-27T13:00:00Z" au "$P" 2>/dev/null)"; rc=$?
  check "$E a later audit adds what it finds" "$rc|$out" '1|{"ok":false,"violations":["not-verified","safety-setting-changed:allowApiWrites","seed-added"]}'
  check "$E the journey lists them all and keeps its end time" "$(jv "$J" '[d["stop"]["detail"],d["endedAt"],d["auditViolations"]]')" '["not-verified, safety-setting-changed:allowApiWrites, seed-added", "2026-11-27T11:00:00Z", ["not-verified", "safety-setting-changed:allowApiWrites", "seed-added"]]'
  # an open journey that fails is stopped too
  P="$(fin open)"; printf '{"x":1}\n' > "$P/.qa/specs/checkout/seed.json"
  expect "an open journey that fails its audit" "$P" 1 '"seed-added"'
  check "$E the open journey is stopped for the audit" "$(jv "$P/.qa/specs/checkout/auto/journey.json" '[d["state"],d["stop"]["reason"],d["stop"]["detail"]]')" '["stopped", "audit", "seed-added"]'

  # ---- the baseline itself: baseline-missing, baseline-changed ----
  P="$(fin)"; rm "$P/.qa/specs/checkout/auto/baseline.json"
  expect "baseline-missing" "$P" 1 '"baseline-missing"'
  P="$(fin)"; rm "$P/.qa/specs/checkout/auto/baseline.json" "$P/.qa/runs/r1/verification.json"
  ed "$P/.qa/specs/checkout/auto/decisions.json" 'd[0]["class"]="safety"'
  expect "without a baseline the other checks still run" "$P" 1 '"baseline-missing","forbidden-decision:D1","not-verified"'
  # the agent loosens a setting and rewrites the baseline to match
  P="$(fin)"; ed "$P/.qa/config.json" 'd["allowApiWrites"]=True'; ed "$P/.qa/specs/checkout/auto/baseline.json" 'd["safety"]["allowApiWrites"]=True'
  expect "baseline-changed" "$P" 1 '"baseline-changed"'
  P="$(fin)"; printf '\n' >> "$P/.qa/specs/checkout/auto/baseline.json"
  expect "baseline-changed on one added byte" "$P" 1 '"baseline-changed"'
  P="$(fin)"; printf '{"safety":' > "$P/.qa/specs/checkout/auto/baseline.json"
  expect "baseline-changed when it no longer parses" "$P" 1 '"baseline-changed"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/journey.json" 'del d["baselineHash"]'
  expect "baseline-changed when the journey holds no hash" "$P" 1 '"baseline-changed"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/baseline.json" 'd["humanOracleIds"]=["C-001","C-002","C-004"]'; edk "$P" 'd[1]["fixture"]["expect"]["oracleSource"]="human"'
  expect "a baseline rewritten to hide a confirmed value" "$P" 1 '"baseline-changed"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/baseline.json" 'd["safety"]="x"; d["exclusions"]=None'
  expect "a baseline rewritten into another shape" "$P" 1 "\"baseline-changed\",\"exclusion-added\",$ALL8"

  # ---- nothing outside auto/ is ever written ----
  P="$(fin)"; printf '{"x":1}\n' > "$P/.qa/specs/checkout/seed.json"
  before="$(snapshot "$P" | grep -v '/auto/')"
  au "$P" >/dev/null 2>&1
  check "$E a failed audit writes nothing outside auto/" "$(snapshot "$P" | grep -v '/auto/')" "$before"
}

for e in jq python3; do
  if [ "$e" = jq ] && ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; continue; fi
  run_engine "$e"
done

# ---- cross-engine: the same changes give the same bytes ----
if command -v jq >/dev/null 2>&1; then
  # mut <project> — everything at once, with ids a shell or an engine could mangle
  mut() {
    local P="$1" S="$1/.qa/specs/checkout"
    ed "$P/.qa/config.json" 'd["gates"]={"dataPolicy":"off","weight":1.0}; d["humanInteraction"]["maxOptOutRate"]=1E+0'
    ed "$S/run-config.json" 'd["environment"]="disposable"'
    edk "$P" 'd.append({"id":"معيار-٧ \"مقتبس\" \\ $HOME\n`x`","fixture":{"expect":{"oracleSource":"human"}}}); d.append({"id":"C-\u007f-del","fixture":{"expect":{"oracleSource":"human"}}}); del d[2]; d[0]["fixture"]["expect"]["oracleSource"]="spec"'
    ed "$S/coverage-exclusions.json" 'd.append({"surfaceId":"x","personaId":"*","weight":2.0})'
    ed "$S/auto/decisions.json" 'd.append({"id":"قرار, ٢","class":"seed"}); d.append({"id":7,"class":"safety"})'
    printf '\n' >> "$P/.qa/known-defects.json"; printf '{}\n' > "$S/seed.json"; rm "$P/.qa/runs/r1/report.md"
  }
  for shape in plain rich atverify; do
    XJ="$(E=jq; fin "$shape")"; XP="$(E=python3; fin "$shape")"
    check "cross-engine fixture journey.json identical ($shape)" "$(cat "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cat "$XP/.qa/specs/checkout/auto/journey.json")"
    check "cross-engine fixture baseline.json identical ($shape)" "$(cat "$XJ/.qa/specs/checkout/auto/baseline.json")" "$(cat "$XP/.qa/specs/checkout/auto/baseline.json")"
    oj="$(E=jq; au "$XJ" 2>&1; echo "rc=$?")"; op="$(E=python3; au "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine clean audit identical ($shape)" "$oj" "$op"
    mut "$XJ"; mut "$XP"
    for t in skip behind fail; do
      oj="$(E=jq; NOW="2026-11-27T11:00:00Z" TRK=$t au "$XJ" 2>&1; echo "rc=$?")"; op="$(E=python3; NOW="2026-11-27T11:00:00Z" TRK=$t au "$XP" 2>&1; echo "rc=$?")"
      check "cross-engine failed audit output identical ($shape, tracker $t)" "$oj" "$op"
      check "cross-engine journey.json identical after the audit ($shape, tracker $t)" "$(cat "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cat "$XP/.qa/specs/checkout/auto/journey.json")"
    done
    check "the failed audit found something ($shape)" "$(printf '%s' "$oj" | grep -c '"ok":false.*"exclusion-added".*"forbidden-decision:#3".*"known-defects-changed".*"tracker-behind"')" "1"
    # each engine reads the other's files and still agrees
    oj="$(E=jq; au "$XP" 2>&1; echo "rc=$?")"; op="$(E=python3; au "$XJ" 2>&1; echo "rc=$?")"
    check "cross-engine audit of each other's journey identical ($shape)" "$oj" "$op"
  done
  XJ="$(E=jq; fin)"; XP="$(E=python3; fin)"
  for v in "audit" "audit nothing-here" "audit checkout extra"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")"
    check "cross-engine refusal identical: $v" "$oj" "$op"
  done
fi

echo "qa-auto-audit: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
