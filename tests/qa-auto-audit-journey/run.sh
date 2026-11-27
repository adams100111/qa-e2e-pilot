#!/usr/bin/env bash
# Dual-engine tests for `auto.sh audit`, second half: what the audit finds in the journey itself
# (steps without a result, a run nobody verified), the tracker, what a failed and a passing audit
# leave in journey.json, the baseline file, and the cross-engine comparison. (The file checks
# against the baseline are in tests/qa-auto-audit/; the two are separate so each stays well inside
# the CI time cap.)
#
# Every violation code has a case that starts from a clean finished journey, makes exactly one
# change and expects exactly that code. Every case runs under QA_ENGINE=jq and QA_ENGINE=python3;
# a final block compares the two engines' output and journey.json byte for byte. The tracker
# command is always a stub (QA_AUTO_TRACKER_CMD). No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-audit-journey: python3 is needed to read results - suite cannot run" >&2; exit 1; }
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
# item 4: the one-line answers of the tracker's spec-status
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": false, \\"target\\": \\"checkout\\"}"\n' > "$ROOT/trk-notsetup.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": true, \\"target\\": \\"checkout\\", \\"behind\\": false, \\"cards\\": 3}"\n' > "$ROOT/trk-setuplevel.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": true, \\"target\\": \\"checkout\\", \\"behind\\": true}"\n' > "$ROOT/trk-setupbehind.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": true, \\"target\\": \\"checkout\\"}"\n' > "$ROOT/trk-setuponly.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": false, \\"target\\": \\"checkout\\"}"\necho "PUSH\\tcard\\t1"\n' > "$ROOT/trk-notsetupextra.sh"
printf '#!/usr/bin/env bash\necho "{\\"setUp\\": false, \\"target\\": \\"checkout\\"}"\necho "SUMMARY {\\"skip\\": 1} dry-run"\n' > "$ROOT/trk-notsetupsummary.sh"
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

ALL8='"safety-setting-changed:allowApiWrites","safety-setting-changed:allowBlackboxCrawl","safety-setting-changed:environment","safety-setting-changed:gates","safety-setting-changed:humanInteraction.enforce","safety-setting-changed:humanInteraction.maxOptOutRate","safety-setting-changed:profile","safety-setting-changed:seedableEnvMarker"'

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
run_engine() {
  E="$1"
  local P S J B out rc before k v c i

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
  # H3: a verification that is empty or does not parse is no verification
  P="$(fin)"; : > "$P/.qa/runs/r1/verification.json"
  expect "an empty verification.json is not-verified" "$P" 1 '"not-verified"'
  P="$(fin)"; printf '{"overrides":' > "$P/.qa/runs/r1/verification.json"
  expect "a verification.json that does not parse is not-verified" "$P" 1 '"not-verified"'
  # item 14: a verification that parses and holds no rows is no verification either
  for k in 'null' '[]' '{}' '{"overrides":[]}' '{"rows":[]}' '[1]' '"ok"'; do
    P="$(fin)"; printf '%s\n' "$k" > "$P/.qa/runs/r1/verification.json"
    expect "not_verified_without_rows [$k]" "$P" 1 '"not-verified"'
  done
  P="$(fin)"; printf '{"rows":[{"criterionId":"C-001","inRunVerdict":"pass","verifierVerdict":"pass"}]}\n' > "$P/.qa/runs/r1/verification.json"
  expect "a verification with its rows under a key is a verification" "$P" 0 ""
  P="$(fin)"; ed "$P/.qa/specs/checkout/auto/journey.json" 'd["runId"]="../r1"'
  expect "a run id that is not a plain name has no verification" "$P" 1 '"not-verified","step-without-result:run"'

  # ---- early_stop_audited_without_verify_checks ----
  P="$(fin atrun)"; before="$(snapx "$P")"; v="$(jrest "$P/.qa/specs/checkout/auto/journey.json")"
  expect "early_stop_audited_without_verify_checks (stopped before the run)" "$P" 0 ""
  check "$E a passing audit leaves the stop as it was" "$(snapx "$P")|$(jrest "$P/.qa/specs/checkout/auto/journey.json")" "$before|$v"
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
  # m5: only the tracker's own not-set-up answer is accepted, and only a boolean `behind`
  for k in loose skipextra skipmid skipblank setuptwo setuptext setupyes setuplist zero null; do
    P="$(fin)"; TRK=$k expect "tracker answer '$k' is a violation" "$P" 1 '"tracker-behind"'
  done
  for k in skipone setup; do
    P="$(fin)"; TRK=$k expect "tracker answer '$k' is the not-set-up answer" "$P" 0 ""
  done
  # item 4: the tracker's answer for a spec that is not set up is one JSON line, alone; a set-up
  # spec's line says so and still needs `behind: false`
  for k in notsetup setuplevel; do
    P="$(fin)"; TRK=$k expect "tracker_not_set_up_json_line: '$k' passes" "$P" 0 ""
  done
  for k in setupbehind setuponly notsetupextra notsetupsummary; do
    P="$(fin)"; TRK=$k expect "tracker_not_set_up_json_line: '$k' is a violation" "$P" 1 '"tracker-behind"'
  done
  # item 26: without docs/agents/qa-tracker.json no spec is tracked, so the tracker is not asked
  P="$(fin)"; rm "$P/docs/agents/qa-tracker.json"; rm -f "$ROOT/trk-args.txt"
  TRK=args expect "audit_skips_tracker_without_settings_file" "$P" 0 ""
  check "$E audit_skips_tracker_without_settings_file: the tracker was not called" "$([ -e "$ROOT/trk-args.txt" ] && echo called || echo not-called)" "not-called"
  P="$(fin)"; rm "$P/docs/agents/qa-tracker.json"
  TRK=behind expect "without the settings file a tracker that says behind is not heard" "$P" 0 ""
  P="$(fin)"; rm -rf "$P/docs"
  TRK=fail expect "without the docs folder a failing tracker is not heard" "$P" 0 ""
  # the machine file cannot turn tracking on, so it does not make the audit ask either
  P="$(fin)"; rm "$P/docs/agents/qa-tracker.json"; mkdir -p "$P/.qa"; printf '{"specs":{"checkout":{"enabled":true}}}\n' > "$P/.qa/tracker.local.json"
  TRK=behind expect "a machine file alone does not make the audit ask the tracker" "$P" 0 ""
  # the file being there is enough to ask, whatever it holds; so is a link that leads nowhere
  P="$(fin)"; : > "$P/docs/agents/qa-tracker.json"
  TRK=behind expect "an empty settings file still asks the tracker" "$P" 1 '"tracker-behind"'
  P="$(fin)"; rm "$P/docs/agents/qa-tracker.json"; ln -s "$P/nowhere.json" "$P/docs/agents/qa-tracker.json"
  TRK=behind expect "a settings file that is a link leading nowhere still asks the tracker" "$P" 1 '"tracker-behind"'
  # QA_AUTO_TRACKER_CMD is for the suites: without QA_AUTO_TEST=1 the real tracker script is asked
  # (this project has no tracker file, so the real answer is not-set-up)
  P="$(fin)"; out="$(QA_ENGINE="$E" QA_AUTO_NOW="$NOW_DEFAULT" QA_AUTO_TRACKER_CMD="bash $ROOT/trk-behind.sh" bash "$SH" audit checkout --project "$P" 2>&1)"; rc=$?
  check "$E without QA_AUTO_TEST the tracker command from the environment is ignored" "$rc|$out" '0|{"ok":true,"violations":[]}'
  P="$(fin)"; out="$(QA_ENGINE="$E" QA_AUTO_TEST=0 QA_AUTO_NOW="$NOW_DEFAULT" QA_AUTO_TRACKER_CMD="$ROOT/no-such-command" bash "$SH" audit checkout --project "$P" 2>&1)"; rc=$?
  check "$E QA_AUTO_TEST must be exactly 1" "$rc|$out" '0|{"ok":true,"violations":[]}'
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
  check "$E a failed audit records itself too" "$(jv "$J" 'd["audit"]')" '{"at": "2026-11-27T11:00:00Z", "ok": false}'
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
  check "$E the journey lists them all and keeps its end time" "$(jv "$J" '[d["stop"]["detail"],d["endedAt"],d["auditViolations"],d["audit"]]')" '["not-verified, safety-setting-changed:allowApiWrites, seed-added", "2026-11-27T11:00:00Z", ["not-verified", "safety-setting-changed:allowApiWrites", "seed-added"], {"at": "2026-11-27T13:00:00Z", "ok": false}]'
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

  # ---- a failed audit that cannot be recorded ----
  if [ "$(id -u)" != 0 ]; then
    P="$(fin)"; printf '{"x":1}\n' > "$P/.qa/specs/checkout/seed.json"; chmod 555 "$P/.qa/specs/checkout/auto"; before="$(snapshot "$P")"
    out="$(au "$P" 2>&1)"; rc=$?
    check "$E a failed audit that cannot write the journey" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    check "$E the journey it could not write is unchanged" "$(snapshot "$P")" "$before"
    rm "$P/.qa/specs/checkout/seed.json"
    out="$(au "$P" 2>&1)"; rc=$?
    check "$E a passing audit that cannot leave its record fails, with one line" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/journey.json"
    chmod 755 "$P/.qa/specs/checkout/auto"
  fi

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
    ed "$P/.qa/config.json" 'd["baseUrl"]="https://متجر.example.sa/\"x\""'
    edk "$P" 'd[3]["fixture"]["expect"]={"value":1.50,"oracleSource":"human","note":"قيمة \"جديدة\" \u007f","z":[1.0,{"b":2,"a":None}]}; d.append({"id":"معيار-٧ \"مقتبس\" \\ $HOME\n`x`","fixture":{"expect":{"oracleSource":"human"}}}); d.append({"id":"C-\u007f-del","fixture":{"expect":{"oracleSource":"human"}}}); del d[2]; d[0]["fixture"]["expect"]["oracleSource"]="spec"'
    ed "$S/coverage-exclusions.json" 'd.append({"surfaceId":"x","personaId":"*","weight":2.0})'
    ed "$S/auto/decisions.json" 'd.append({"id":"قرار, ٢","class":"seed"}); d.append({"id":7,"class":"safety"})'
    printf '\n' >> "$P/.qa/known-defects.json"; printf '{}\n' > "$S/seed.json"; rm "$P/.qa/runs/r1/report.md"
  }
  for shape in plain rich atverify; do
    XJ="$(E=jq; fin "$shape")"; XP="$(E=python3; fin "$shape")"
    check "cross-engine fixture journey.json identical ($shape)" "$(cksum < "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/journey.json")"
    check "cross-engine fixture baseline.json identical ($shape)" "$(cksum < "$XJ/.qa/specs/checkout/auto/baseline.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/baseline.json")"
    oj="$(E=jq; au "$XJ" 2>&1; echo "rc=$?")"; op="$(E=python3; au "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine clean audit identical ($shape)" "$oj" "$op"
    mut "$XJ"; mut "$XP"
    for t in skip behind fail; do
      oj="$(E=jq; NOW="2026-11-27T11:00:00Z" TRK=$t au "$XJ" 2>&1; echo "rc=$?")"; op="$(E=python3; NOW="2026-11-27T11:00:00Z" TRK=$t au "$XP" 2>&1; echo "rc=$?")"
      check "cross-engine failed audit output identical ($shape, tracker $t)" "$oj" "$op"
      check "cross-engine journey.json identical after the audit ($shape, tracker $t)" "$(cksum < "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/journey.json")"
    done
    check "the failed audit found something ($shape)" "$(printf '%s' "$oj" | grep -c '"ok":false.*"base-url-changed".*"exclusion-added".*"forbidden-decision:#3".*"human-oracle-changed:C-004".*"known-defects-changed".*"tracker-behind"')" "1"
    # each engine reads the other's files and still agrees
    oj="$(E=jq; au "$XP" 2>&1; echo "rc=$?")"; op="$(E=python3; au "$XJ" 2>&1; echo "rc=$?")"
    check "cross-engine audit of each other's journey identical ($shape)" "$oj" "$op"
  done
  # m6: one verdict per number spelling, whichever engine reads it
  for v in 0.2000000000000000001 2E-1 1e16 12345678901234567890 9007199254740993 1e-7 1e400 -0.0; do
    XJ="$(E=jq; fin)"; XP="$(E=python3; fin)"
    sed "s/\"maxOptOutRate\": 0.2 /\"maxOptOutRate\": $v /" "$FX/config-local.json" > "$XJ/.qa/config.json"; cp "$XJ/.qa/config.json" "$XP/.qa/config.json"
    oj="$(E=jq; au "$XJ" 2>&1; echo "rc=$?")"; op="$(E=python3; au "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine verdict identical for the number $v" "$oj" "$op"
    check "cross-engine journey.json identical for the number $v" "$(cksum < "$XJ/.qa/specs/checkout/auto/journey.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/journey.json")"
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

echo "qa-auto-audit-journey: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
