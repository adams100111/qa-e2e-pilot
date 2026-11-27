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
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
T_OLD=202611270700; T_MID=202611270710
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" bash "$SH" "$@"; }
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

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
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
  # T1: a passing audit leaves its record in the journey, and changes nothing else anywhere
  before="$(snapx "$P")"; v="$(jrest "$J")"
  check "$E a journey that was never audited has no audit record" "$(jv "$J" '"audit" in d')" "false"
  out="$(NOW="2026-11-27T10:00:00Z" au "$P" 2>&1)"; rc=$?
  check "$E clean_journey_passes" "$rc|$out" '0|{"ok":true,"violations":[]}'
  check "$E a passing audit changes no other file" "$(snapx "$P")" "$before"
  check "$E a passing audit records itself in the journey" "$(jv "$J" 'd["audit"]')" '{"at": "2026-11-27T10:00:00Z", "ok": true}'
  check "$E a passing audit changes nothing else in the journey" "$(jrest "$J")" "$v"
  NOW="2026-11-27T10:30:00Z" au "$P" >/dev/null 2>&1
  check "$E a second passing audit moves the record's time" "$(jv "$J" 'd["audit"]')|$(jrest "$J")" '{"at": "2026-11-27T10:30:00Z", "ok": true}|'"$v"
  check "$E status prints the audit record" "$(auto status checkout --project "$P" 2>/dev/null | grep -c '"audit":{"at":"2026-11-27T10:30:00Z","ok":true}')" "1"
  for k in ship rich bare; do expect "clean $k journey passes" "$(fin "$k")" 0 ""; done
  P="$(fin open)"; before="$(snapx "$P")"
  expect "an open journey can be audited" "$P" 0 ""
  check "$E a passing audit leaves an open journey open" "$(snapx "$P")|$(jv "$P/.qa/specs/checkout/auto/journey.json" '[d["state"],d["audit"]["ok"]]')" "$before"'|["open", true]'

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
  P="$(fin)"; printf '{"profile":"full","humanInteraction":{"maxOptOutRate":0.20,"autonomousSetup":false,"saveSession":true,"enforce":true},\n "allowBlackboxCrawl":false,"environment":"auto","seedableEnvMarker":"","allowApiWrites":false,"auth":{"storageState":"x.json"},"baseUrl":"http://localhost:3000"}\n' > "$P/.qa/config.json"
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
  expect "a config link that leads nowhere fails every key" "$P" 1 "\"base-url-changed\",$ALL8"
  P="$(fin)"; rm "$P/.qa/config.json"
  expect "a removed config fails every key" "$P" 1 "\"base-url-changed\",$ALL8"
  P="$(fin)"; printf '{"allowApiWrites":' > "$P/.qa/config.json"
  expect "a config that does not parse fails every key" "$P" 1 "\"base-url-changed\",$ALL8"

  # ---- base-url-changed ----
  P="$(fin)"; B="$P/.qa/specs/checkout/auto/baseline.json"
  check "$E start records the address the journey ran against" "$(jv "$B" 'd["baseUrl"]')" "http://localhost:3000"
  ed "$P/.qa/config.json" 'd["baseUrl"]="https://app.example.sa"'
  expect "base-url-changed" "$P" 1 '"base-url-changed"'
  P="$(fin)"; ed "$P/.qa/config.json" 'd["baseUrl"]="http://localhost:3000/"'
  expect "base-url-changed on one added character" "$P" 1 '"base-url-changed"'
  P="$(fin)"; ed "$P/.qa/config.json" 'del d["baseUrl"]'
  expect "base-url-changed when the address is removed" "$P" 1 '"base-url-changed"'
  P="$(fin)"; ed "$P/.qa/config.json" 'd["baseUrl"]=["http://localhost:3000"]'
  expect "base-url-changed when the address is no longer text" "$P" 1 '"base-url-changed"'
  # a baseline written before the address was recorded has nothing to compare
  P="$(fin)"; J="$P/.qa/specs/checkout/auto/journey.json"; B="$P/.qa/specs/checkout/auto/baseline.json"
  ed "$B" 'del d["baseUrl"]'; ed "$J" "d['baselineHash']='$(sha "$B")'"
  ed "$P/.qa/config.json" 'd["baseUrl"]="https://app.example.sa"'
  expect "an older baseline without the address skips the check" "$P" 0 ""

  # ---- run-config-safety:<top-level key>, and the merged settings it changes ----
  # The run-config replaces the config's whole key of the same name, so a change there is reported
  # twice: the key the run-config gained (`run-config-safety`) and each merged setting that moved.
  while IFS='|' read -r k v c; do
    P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" "$v"
    expect "run-config-safety:$k" "$P" 1 "\"run-config-safety:$k\"$c"
  done <<'EOT'
allowApiWrites|d["allowApiWrites"]=True|,"safety-setting-changed:allowApiWrites"
seedableEnvMarker|d["seedableEnvMarker"]="MATJAR_DISPOSABLE"|,"safety-setting-changed:seedableEnvMarker"
environment|d["environment"]="disposable"|,"safety-setting-changed:environment"
allowBlackboxCrawl|d["allowBlackboxCrawl"]=True|,"safety-setting-changed:allowBlackboxCrawl"
gates|d["gates"]={"dataPolicy":"off"}|,"safety-setting-changed:gates"
profile|d["profile"]="smoke"|,"safety-setting-changed:profile"
humanInteraction|d["humanInteraction"]={"enforce":False}|,"safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate"
humanInteraction|d["humanInteraction"]={"maxOptOutRate":0.9}|,"safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate"
EOT
  # H2, the reviewer's cases: a run-config that drops `enforce` and `maxOptOutRate` by replacing the key
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["humanInteraction"]={"saveSession":False}'
  expect "a run-config humanInteraction without the safety members drops them" "$P" 1 '"run-config-safety:humanInteraction","safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["humanInteraction"]=None'
  expect "a run-config humanInteraction of null drops them" "$P" 1 '"run-config-safety:humanInteraction","safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["baseUrl"]="https://app.example.sa"'
  expect "an address added to the run-config in the middle of the journey" "$P" 1 '"base-url-changed","run-config-safety:baseUrl"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["baseUrl"]="http://localhost:3000"'
  expect "the project's own address added to the run-config is still a gained key" "$P" 1 '"run-config-safety:baseUrl"'
  P="$(fin bare)"; printf '{"humanInteraction":{"enforce":true,"maxOptOutRate":0.20,"saveSession":false}}\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a gained key that leaves the merged settings as they were is reported once" "$P" 1 '"run-config-safety:humanInteraction"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["allowApiWrites"]=False'
  expect "a safety key added with the project's own value is still a violation" "$P" 1 '"run-config-safety:allowApiWrites"'
  P="$(fin)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["criteriaBudget"]=10; d["journeys"]=["checkout"]; d["humanInteractionNotes"]="x"'
  expect "other run-config keys are free" "$P" 0 ""
  # launch_profile_is_not_a_violation
  P="$(fin ship)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["profile"]="ship"'
  expect "launch_profile_is_not_a_violation" "$P" 0 ""
  P="$(fin ship)"; ed "$P/.qa/config.json" 'd["profile"]="ship"'
  expect "the launch profile written into the config is not a violation either" "$P" 0 ""
  P="$(fin ship)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["profile"]="full"'
  expect "a profile other than the launch profile" "$P" 1 '"run-config-safety:profile"'
  P="$(fin ship)"; ed "$P/.qa/specs/checkout/run-config.json" 'd["profile"]=["ship"]'
  expect "the launch profile in another type" "$P" 1 '"run-config-safety:profile","safety-setting-changed:profile"'
  P="$(fin bare)"; printf '{"allowBlackboxCrawl":true}\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that appears with a safety key" "$P" 1 '"run-config-safety:allowBlackboxCrawl","safety-setting-changed:allowBlackboxCrawl"'
  P="$(fin bare)"; printf '{"criteriaBudget":12}\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that appears without safety keys passes" "$P" 0 ""
  # a safety key the run-config already had at the start (rich: the config says true, the run-config false)
  P="$(fin rich)"; B="$P/.qa/specs/checkout/auto/baseline.json"
  check "$E the baseline holds the merged value and the run-config's own key" "$(jv "$B" '[d["safety"]["allowBlackboxCrawl"],d["runConfig"]]')" '[false, {"allowBlackboxCrawl": false}]'
  ed "$P/.qa/specs/checkout/run-config.json" 'd["allowBlackboxCrawl"]=True'
  expect "a starting run-config safety value that changed" "$P" 1 '"run-config-safety:allowBlackboxCrawl","safety-setting-changed:allowBlackboxCrawl"'
  P="$(fin rich)"; ed "$P/.qa/specs/checkout/run-config.json" 'del d["allowBlackboxCrawl"]'
  expect "a starting run-config safety key that was removed" "$P" 1 '"run-config-safety:allowBlackboxCrawl","safety-setting-changed:allowBlackboxCrawl"'
  P="$(fin rich)"; rm "$P/.qa/specs/checkout/run-config.json"
  expect "a removed run-config that held a safety key" "$P" 1 '"run-config-safety:allowBlackboxCrawl","safety-setting-changed:allowBlackboxCrawl"'
  P="$(fin rich)"; ed "$P/.qa/config.json" 'd["allowBlackboxCrawl"]=False'
  expect "a config value the run-config overrides may change: the merged setting did not" "$P" 0 ""
  RC8='"run-config-safety:allowApiWrites","run-config-safety:allowBlackboxCrawl","run-config-safety:baseUrl","run-config-safety:environment","run-config-safety:gates","run-config-safety:humanInteraction","run-config-safety:profile","run-config-safety:seedableEnvMarker"'
  P="$(fin)"; printf '{"criteriaBudget":' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that does not parse fails every key, and every merged setting" "$P" 1 "\"base-url-changed\",$RC8,$ALL8"
  P="$(fin)"; printf '["environment","production"]\n' > "$P/.qa/specs/checkout/run-config.json"
  expect "a run-config that is not an object fails the same way" "$P" 1 "\"base-url-changed\",$RC8,$ALL8"
  # a baseline written before this change (config-only values, `runConfigSafety`) keeps working
  P="$(fin rich)"; J="$P/.qa/specs/checkout/auto/journey.json"; B="$P/.qa/specs/checkout/auto/baseline.json"
  ed "$B" 'del d["runConfig"]; d["runConfigSafety"]={"allowBlackboxCrawl":False}; d["safety"]["allowBlackboxCrawl"]=True'; ed "$J" "d['baselineHash']='$(sha "$B")'"
  expect "an earlier baseline is compared the earlier way and passes" "$P" 0 ""
  ed "$P/.qa/specs/checkout/run-config.json" 'd["humanInteraction"]={"enforce":False}'
  expect "an earlier baseline still reports a run-config safety key" "$P" 1 '"run-config-safety:humanInteraction.enforce"'
  P="$(fin rich)"; J="$P/.qa/specs/checkout/auto/journey.json"; B="$P/.qa/specs/checkout/auto/baseline.json"
  ed "$B" 'del d["runConfig"]; d["runConfigSafety"]={"allowBlackboxCrawl":False}; d["safety"]["allowBlackboxCrawl"]=True'; ed "$J" "d['baselineHash']='$(sha "$B")'"
  ed "$P/.qa/config.json" 'd["allowApiWrites"]=True'
  expect "an earlier baseline still reports a changed config value" "$P" 1 '"safety-setting-changed:allowApiWrites"'
}

for e in jq python3; do
  if [ "$e" = jq ] && ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; continue; fi
  run_engine "$e"
done

echo "qa-auto-audit: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
