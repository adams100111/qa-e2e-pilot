#!/usr/bin/env bash
# Dual-engine tests for `auto.sh audit`, the plan half: null against absent, how numbers are
# judged, the plan and its person-confirmed rows, the seed, the exclusions, the known-defect
# registry and the decisions. (The settings checks are in tests/qa-auto-audit/, the journey's own
# checks in tests/qa-auto-audit-journey/; they are separate so each stays well inside the CI time
# cap.)
#
# Every violation code has a case that starts from a clean finished journey, makes exactly one
# change and expects exactly that code. Every case runs under QA_ENGINE=jq and QA_ENGINE=python3;
# a final block compares the two engines' output and journey.json byte for byte. The tracker
# command is always a stub (QA_AUTO_TRACKER_CMD). No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-audit-plan: python3 is needed to read results - suite cannot run" >&2; exit 1; }
# The real interpreter, not a version-manager shim (see tests/qa-auto/run.sh).
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; [ -x "$PY" ] || PY=python3
case "$PY" in */python3) PATH="${PY%/python3}:$PATH"; export PATH ;; esac
pass=0; fail=0
ROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
T_OLD=202611270700; T_MID=202611270710
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" QA_AUTO_VERIFY_PLAN_CMD="${VP-true}" bash "$SH" "$@"; }
jv() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
snapshot() { (cd "$1" && find . \( -type f -o -type l \) -exec cksum {} + 2>&1 | LC_ALL=C sort -k3); }
# snapx <project> — the snapshot without journey.json (a passing audit leaves its record there).
snapx() { snapshot "$1" | grep -v '/auto/journey.json$'; }
# jrest <journey.json> — the journey without its audit record, on one line.
jrest() { jv "$1" 'dict((k,v) for k,v in d.items() if k!="audit")'; }
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
printf '#!/usr/bin/env bash\necho "the spec is not-set-up for the tracker"\n' > "$ROOT/trk-loose.sh"
printf '#!/usr/bin/env bash\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\necho "SUMMARY {\\"skip\\": 1} dry-run"\necho "PUSH\\tcard\\t1"\n' > "$ROOT/trk-skipextra.sh"
printf '#!/usr/bin/env bash\necho "LINK\\tfolder\\thttps://app.clickup.example/901"\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\n' > "$ROOT/trk-skipmid.sh"
printf '#!/usr/bin/env bash\nprintf "SKIP not-set-up checkout\\n"\n' > "$ROOT/trk-skipblank.sh"
printf '#!/usr/bin/env bash\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\n' > "$ROOT/trk-skipone.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": false}"\n' > "$ROOT/trk-setup.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": false}"\necho "{\\"cards\\": 2}"\n' > "$ROOT/trk-setuptwo.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": \\"false\\"}"\n' > "$ROOT/trk-setuptext.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": true}"\n' > "$ROOT/trk-setupyes.sh"
printf '#!/usr/bin/env bash\necho "[{\\"setUp\\": false}]"\n' > "$ROOT/trk-setuplist.sh"
printf '#!/usr/bin/env bash\necho "{\\"behind\\": 0}"\n' > "$ROOT/trk-zero.sh"
printf '#!/usr/bin/env bash\necho "{\\"behind\\": null}"\nprintf "SKIP\\tnot-set-up\\tcheckout\\n"\n' > "$ROOT/trk-null.sh"
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
                  printf '{"criteria":[{"criterion_id":"C-001","persona":"admin","verdict":"pass","confidence":"high"}]}\n' > "$R/checkpoint.json"; printf '# Report\n' > "$R/report.md" ;;
    verify)       mkdir -p "$R"; printf '%s\n' '[{"criterionId":"C-001","persona":"admin","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"high","reasons":[]}]' > "$R/verification.json" ;;
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
    # the project's tracker settings: without this file the audit does not ask the tracker at all
    mkdir -p "$P/docs/agents"; printf '{"specs":{}}\n' > "$P/docs/agents/qa-tracker.json"
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

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
ALL8='"safety-setting-changed:allowApiWrites","safety-setting-changed:allowBlackboxCrawl","safety-setting-changed:environment","safety-setting-changed:gates","safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate","safety-setting-changed:profile","safety-setting-changed:seedableEnvMarker"'

run_engine() {
  E="$1"
  local P S J B out rc before k v c i

  # ---- m7: a key that goes from absent to an explicit null is a change ----
  P="$(fin)"; ed "$P/.qa/config.json" 'd["gates"]=None'
  expect "gates from absent to null in the config" "$P" 1 '"safety-setting-changed:gates"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["gates"]=None'
  expect "gates from absent to null in the run-config" "$P" 1 '"run-config-safety:gates","safety-setting-changed:gates"'
  P="$(fin)"; ed "$P/.qa/config.json" 'd["allowBlackboxCrawl"]=None'
  expect "a safety key from a value to null" "$P" 1 '"safety-setting-changed:allowBlackboxCrawl"'
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa"
  printf '{"baseUrl":"http://localhost:3000","allowApiWrites":null}\n' > "$P/.qa/config.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  check "$E the baseline tells null from absent" "$(jv "$P/.qa/specs/checkout/auto/baseline.json" 'd["safety"]')" '{"allowApiWrites": null}'
  expect "a journey whose key is null from the start passes" "$P" 0 ""
  printf '{"baseUrl":"http://localhost:3000"}\n' > "$P/.qa/config.json"
  expect "a safety key from null to absent" "$P" 1 '"safety-setting-changed:allowApiWrites"'
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa"
  printf '{"baseUrl":"http://localhost:3000"}\n' > "$P/.qa/config.json"
  auto start checkout --project "$P" >/dev/null 2>&1
  printf '{"baseUrl":"http://localhost:3000","seedableEnvMarker":null,"humanInteraction":{"enforce":null}}\n' > "$P/.qa/config.json"
  expect "safety keys from absent to null" "$P" 1 '"safety-setting-changed:humanInteraction.enforce","safety-setting-changed:seedableEnvMarker"'

  # ---- m6: numbers are judged one way by both engines ----
  # num <project> <number text> — write the config's maxOptOutRate with exactly that spelling
  num() { sed "s/\"maxOptOutRate\": 0.2 /\"maxOptOutRate\": $2 /" "$FX/config-local.json" > "$1/.qa/config.json"; }
  for v in 0.2000000000000000001 0.20 2E-1 0.2e0 0.19999999999999999999; do
    P="$(fin)"; num "$P" "$v"
    expect "the number $v is the starting 0.2" "$P" 0 ""
  done
  for v in 1e16 12345678901234567890 9007199254740993 1e-7 0.3 2 -0.2 1e400 0.2000001; do
    P="$(fin)"; num "$P" "$v"
    expect "the number $v is a change" "$P" 1 '"safety-setting-changed:humanInteraction.maxOptOutRate"'
  done
  P="$(fin)"; printf '{"criteriaBudget":40,"gates":{"weight":1e16}}\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a number too large to compare in the run-config" "$P" 1 '"run-config-safety:gates","safety-setting-changed:gates"'

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
  expect "human-oracle-changed:<criterion id>" "$P" 1 '"human-oracle-changed:C-001"'
  P="$(fin)"; B="$P/.qa/specs/checkout/auto/baseline.json"
  check "$E start records a hash of each person-confirmed expected value" "$(jv "$B" 'd["humanOracleHashes"]')" "{\"C-001\": \"$(printf '%s' '{"oracleSource":"human","value":"115.00"}' | "$PY" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')\", \"C-004\": \"$(printf '%s' '{"oracleSource":"human","value":"15.00"}' | "$PY" -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')\"}"
  edk "$P" 'd[3]["fixture"]["expect"]["citation"]="docs/pricing.md:30"'
  expect "human-oracle-changed when a field is added to the expected value" "$P" 1 '"human-oracle-changed:C-004"'
  P="$(fin)"; edk "$P" 'd[0]["fixture"]["expect"]["value"]=115.00; d[3]["fixture"]["expect"]["value"]="15.0"'
  expect "human-oracle-changed for each changed row, a changed type included" "$P" 1 '"human-oracle-changed:C-001","human-oracle-changed:C-004"'
  P="$(fin)"; edk "$P" 'd[0]["fixture"]["expect"]={"value":"115.00","oracleSource":"human"}; d[0]["fixture"]["note"]="x"; d[0]["title"]="t"; d[1]["fixture"]["expect"]["value"]="91.00"'
  expect "the same expected value in another key order, and other fields of the row, pass" "$P" 0 ""
  P="$(fin)"; edk "$P" 'd[0]["fixture"]["expect"]={"value":"120.00","oracleSource":"spec"}'
  expect "a row that is no longer person-confirmed is reported as that, once" "$P" 1 '"human-oracle-removed:C-001"'
  # a baseline written before the hashes were recorded has nothing to compare
  P="$(fin)"; J="$P/.qa/specs/checkout/auto/journey.json"; B="$P/.qa/specs/checkout/auto/baseline.json"
  ed "$B" 'del d["humanOracleHashes"]'; ed "$J" "d['baselineHash']='$(sha "$B")'"
  edk "$P" 'd[0]["fixture"]["expect"]["value"]="120.00"'
  expect "an older baseline without the hashes skips the check" "$P" 0 ""
  P="$(fin)"; printf '[{"id":' > "$P/.qa/specs/checkout/checklist.json"; touch -t "$T_OLD" "$P/.qa/specs/checkout/checklist.json"
  expect "plan-unreadable (does not parse)" "$P" 1 '"plan-unreadable"'
  P="$(fin)"; : > "$P/.qa/specs/checkout/checklist.json"; touch -t "$T_OLD" "$P/.qa/specs/checkout/checklist.json"
  expect "plan-unreadable (empty file)" "$P" 1 '"plan-unreadable"'
  P="$(fin)"; printf '{"criteria":%s}\n' "$(cat "$FX/checklist.json")" > "$P/.qa/specs/checkout/checklist.json"; touch -t "$T_OLD" "$P/.qa/specs/checkout/checklist.json"
  expect "plan-unreadable (not a list of rows)" "$P" 1 '"plan-unreadable"'
  # item 25: half of a surrogate pair written as an escape. Both engines read it one way: a first
  # half with no second half after it makes the plan unreadable; a second half alone is U+FFFD.
  # surr <project> <title as JSON text> — add one row with that title to the plan, as raw text
  surr() {
    local f="$1/.qa/specs/checkout/checklist.json" t
    t="$(cat "$f")"; t="${t%]*}"
    printf '%s,\n  {"id": "C-900", "title": %s, "kind": "bake", "priority": "P2"}\n]\n' "$t" "$2" > "$f"; touch -t "$T_OLD" "$f"
  }
  for k in '"\ud800"' '"x\uD83Dy"' '"\ud800\u0041"' '"\udc00\ud800"' '"\ud800\ud800"'; do
    P="$(fin)"; surr "$P" "$k"
    expect "plan_unreadable_lone_surrogate [$k]" "$P" 1 '"plan-unreadable"'
  done
  for k in '"\ud83d\ude00"' '"\udc00"' '"a\uDFFFb"' '"\\ud800 as plain text"'; do
    P="$(fin)"; surr "$P" "$k"
    expect "a plan with the title [$k] is readable (a row was added)" "$P" 0 ""
  done
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa/specs/checkout"; cp "$FX/config-local.json" "$P/.qa/config.json"
  cp "$FX/checklist.json" "$P/.qa/specs/checkout/checklist.json"; surr "$P" '"\ud800"'
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start refuses a plan with a lone surrogate" "$rc|$out" "1|auto: .qa/specs/checkout/checklist.json is not valid JSON"
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa"; printf '{"baseUrl":"http://localhost:3000","note":"\\ud800"}\n' > "$P/.qa/config.json"
  out="$(auto start checkout --project "$P" 2>&1)"; rc=$?
  check "$E start refuses a config with a lone surrogate" "$rc|$out" "1|auto: .qa/config.json is not valid JSON"
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

}

for e in jq python3; do
  if [ "$e" = jq ] && ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; continue; fi
  run_engine "$e"
done

echo "qa-auto-audit-plan: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
