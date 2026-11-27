#!/usr/bin/env bash
# Dual-engine tests for `auto.sh handoff`: at the end of an unattended journey the script writes
# `.qa/specs/<target>/auto/handoff.md`, the list a person reads, and prints one line,
# {"result":…,"needsPerson":n}. (The state machine is tested in tests/qa-auto/, the decision verbs
# in tests/qa-auto-decisions/, the audit in tests/qa-auto-audit/, the start checks in
# tests/qa-auto-gate/; this suite is separate so each stays well inside the CI time cap.)
#
# The result must never read better than what the engine recorded. Every result value has a case
# built from a fixture, and so has every way the result could overstate. Every case runs under
# QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines' output and
# handoff.md byte for byte. No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
HX="$DIR/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-handoff: python3 is needed to read results - suite cannot run" >&2; exit 1; }
# The real interpreter, not a version-manager shim (see tests/qa-auto/run.sh).
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null </dev/null)"; [ -x "$PY" ] || PY=python3
case "$PY" in */python3) PATH="${PY%/python3}:$PATH"; export PATH ;; esac
pass=0; fail=0
ROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# has <label> <file> <fixed text> / lacks … — the file holds (does not hold) that exact text.
has(){ if grep -qF -- "$3" "$2" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 missing=[$3]"; fi; }
lacks(){ if [ -f "$2" ] && ! grep -qF -- "$3" "$2" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 present=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
T_OLD=202611270700; T_MID=202611270710
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" QA_AUTO_VERIFY_PLAN_CMD="${VP-true}" bash "$SH" "$@" </dev/null; }
jv() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null </dev/null || echo "<unreadable>"; }
snapshot() { (cd "$1" && find . \( -type f -o -type l \) ! -name handoff.md -exec cksum {} + 2>&1 | LC_ALL=C sort -k3); }
# ed <json file> <python statements over d> — change a JSON file in place.
ed() { "$PY" -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p,encoding="utf-8")); exec(sys.argv[2])
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False)' "$1" "$2" </dev/null; }
# sec <handoff.md> <section title> — the lines of that section, blank lines dropped.
sec() { awk -v t="## $2" '$0==t{on=1;next} /^## /{on=0} on && $0!=""' "$1" 2>/dev/null; }
# items <handoff.md> <section title> — how many list items the section has.
items() { sec "$1" "$2" | grep -c '^- '; }
NL='
'
# The audit asks the tracker; this stub answers that the spec is not tracked.
printf '#!/usr/bin/env bash\nprintf "SKIP\\tnot-set-up\\t%%s\\n" checkout\n' > "$ROOT/trk-skip.sh"

artifact() {
  local P="$1" S="$1/.qa/specs/checkout" R="$1/.qa/runs/r1"
  mkdir -p "$S"
  case "$2" in
    constitution) printf '{"version":"c1"}\n' > "$P/.qa/constitution.state.json" ;;
    spec)         printf '# QA spec\n' > "$S/qa-spec.md"; printf '{"roles":[]}\n' > "$S/spec-roles.json" ;;
    scenarios)    printf '# Scenarios\n' > "$S/scenarios.md"; cp "$HX/checklist.json" "$S/checklist.json"; touch -t "$T_OLD" "$S/checklist.json" ;;
    analyze)      cp "$FX/analysis-pass.md" "$S/analysis.md"; touch -t "$T_MID" "$S/analysis.md" ;;
    run)          mkdir -p "$R"
                  printf '{"run_id":"r1","target_feature":"checkout","started_at":"2026-11-27T08:30:00Z","status":"complete"}\n' > "$R/run-manifest.json"
                  cp "$HX/checkpoint.json" "$R/checkpoint.json"; cp "$HX/report-ready.md" "$R/report.md" ;;
    verify)       mkdir -p "$R"; cp "$HX/verification-clean.json" "$R/verification.json" ;;
  esac
}
done_step() {
  artifact "$1" "$2"
  if [ "$2" = run ]; then auto step-done checkout run --run r1 --project "$1" >/dev/null 2>&1
  else auto step-done checkout "$2" --project "$1" >/dev/null 2>&1; fi
}
# fin [shape] — a project for the target `checkout`. Built once per engine and shape through the
# verbs, then copied. Shapes:
#   done   the journey has ended (state done). The run's report says SHIP-READY, the second check
#          confirmed every pass, the sign-in file is there and one decision (the scope, with
#          evidence, high confidence) was recorded: nothing is left for a person.
#   open   as done, but `next` was never asked: the journey is still open.
fin() {
  local shape="${1:-done}" tpl="$ROOT/tpl-$E-${1:-done}" P S
  if [ ! -d "$tpl" ]; then
    P="$(mktemp -d "$ROOT/p.XXXXXX")"; S="$P/.qa/specs/checkout"; mkdir -p "$S" "$P/.qa/auth"
    # the project's tracker settings: without this file the audit does not ask the tracker at all
    mkdir -p "$P/docs/agents"; printf '{"specs":{}}\n' > "$P/docs/agents/qa-tracker.json"
    cp "$FX/config-local.json" "$P/.qa/config.json"; printf '{"cookies":[]}\n' > "$P/.qa/auth/storageState.json"
    artifact "$P" constitution; artifact "$P" spec; artifact "$P" scenarios
    auto start checkout --project "$P" >/dev/null 2>&1
    auto decide checkout --project "$P" --step spec --class scope --question "أي الشاشات تدخل في النطاق؟" --answer "شاشات السلة والدفع والفاتورة" --evidence "routes/web.php:12" --confidence high >/dev/null 2>&1
    done_step "$P" analyze; done_step "$P" run; done_step "$P" verify
    [ "$shape" = open ] || auto next checkout --project "$P" >/dev/null 2>&1
    # the audit has run and passed (T1: without its record the result is never better than not verified)
    QA_AUTO_TRACKER_CMD="bash $ROOT/trk-skip.sh" auto audit checkout --project "$P" >/dev/null 2>&1
    mv "$P" "$tpl"
  fi
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; rmdir "$P"; cp -Rp "$tpl" "$P"
  printf '%s' "$P"
}
# ho <project> [handoff arguments] — the handoff; prints "<exit code>|<output>".
ho() { local P="$1" out rc; shift; out="$(auto handoff checkout --project "$P" "$@" 2>&1)"; rc=$?; printf '%s|%s' "$rc" "$out"; }
# stopj <project> <reason> — close the journey as stopped, as `auto.sh stop` records it.
stopj() { ed "$1/.qa/specs/checkout/auto/journey.json" "d['state']='stopped'; d['stop']={'reason':'$2','detail':'recorded detail'}; d['endedAt']='2026-11-27T09:00:00Z'"; }
# dec <project> <python dict fields> — append one decision; fields not given take plain defaults.
dec() { ed "$1/.qa/specs/checkout/auto/decisions.json" "r={'id':'D%d'%(len(d)+1),'step':'scenarios','class':'expected','question':'ما القيمة المتوقعة لرسوم التوصيل؟','answer':'15 ريالاً','evidence':'resources/views/cart.blade.php:40','confidence':'high','criteria':[],'assumption':True,'needsPerson':False,'second':None,'secondReason':None}; r.update($2); d.append(r)"; }

# Free text a shell, an engine or a renderer could mangle (the same shape as in tests/qa-auto-decisions).
MARK="$ROOT/must-not-exist"
NASTY="$(printf '%s\n%s\t%s' "--قيمة \"مزدوجة\" و'مفردة' \\ \\\\n \\u0041 \$HOME \${PATH} \`touch $MARK\` \$(touch $MARK)" "سطر ثانٍ: 15% ضريبة %s %d | jq '.[]' ; touch $MARK #" "$(printf 'end\177.')")"
# The same text as one line: every control character is a blank, runs of blanks are one.
NASTY_FLAT="--قيمة \"مزدوجة\" و'مفردة' \\ \\\\n \\u0041 \$HOME \${PATH} \`touch $MARK\` \$(touch $MARK) سطر ثانٍ: 15% ضريبة %s %d | jq '.[]' ; touch $MARK # end ."

TITLES="## Result${NL}## Scope chosen for this spec${NL}## Decided without a person${NL}## Needs a person${NL}## Records created${NL}## How to confirm"
T1='إجمالي الفاتورة يشمل ضريبة القيمة المضافة'; T2='خصم العميل الدائم يطبق مرة واحدة'; T3='صفحة الطلبات تعرض طلبات العميل'

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
run_engine() {
  E="$1"
  local P S R H J D out before r want n i

  # ---- ready_when_ship_ready_and_nothing_pending ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  check "$E the fixture is a finished journey" "$(jv "$J" '[d["state"],d["runId"]]')" '["done", "r1"]'
  before="$(snapshot "$P")"
  check "$E ready_when_ship_ready_and_nothing_pending" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  check "$E ready: the Result section" "$(sec "$H" Result)" "Ready."
  check "$E ready: nothing needs a person" "$(sec "$H" "Needs a person")" "Nothing needs a person."
  check "$E ready: the file opens with the result" "$(head -1 "$H")" "## Result"
  check "$E handoff changes no other file" "$(snapshot "$P")" "$before"
  check "$E handoff leaves no temporary file" "$(ls "$S/auto" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json decisions.json handoff.md journey.json "
  check "$E the file ends with one line break" "$(tail -c 1 "$H" | od -An -c | tr -d ' ')" '\n'

  # ---- sections_in_order ----
  check "$E sections_in_order" "$(grep '^#' "$H")" "$TITLES"
  check "$E the scope the journey chose is shown" "$(sec "$H" "Scope chosen for this spec")" "- شاشات السلة والدفع والفاتورة"
  check "$E a decision is listed under its step with its evidence in one line" "$(sec "$H" "Decided without a person")" "Spec step:${NL}- Asked: أي الشاشات تدخل في النطاق؟; decided: شاشات السلة والدفع والفاتورة; based on: routes/web.php:12"
  check "$E how to confirm names the tools" "$(sec "$H" "How to confirm")" "- Expected results: run \`oracle-confirm.sh render\` and confirm each value on the page it writes.${NL}- Who may reach each screen: run \`surface-access.sh confirm-table\` and confirm the table.${NL}- Then run \`/qa-auto checkout\` again. It starts a new journey on the confirmed plan."

  # ---- no_records_sentence / records_listed ----
  check "$E no_records_sentence (no --records)" "$(sec "$H" "Records created")" "None recorded."
  check "$E records_listed: output" "$(ho "$P" --records "$HX/records.json")" '0|{"result":"ready","needsPerson":0}'
  check "$E records_listed" "$(sec "$H" "Records created")" "- order: 4821${NL}- عميل: cust-7f3a"
  check "$E the last write wins" "$(ho "$P")|$(sec "$H" "Records created")" '0|{"result":"ready","needsPerson":0}|None recorded.'
  printf '[]\n' > "$ROOT/r-empty-list.json"; : > "$ROOT/r-empty.json"; printf '[{"entity":"order",' > "$ROOT/r-broken.json"
  printf '{"entity":"order","id":"1"}\n' > "$ROOT/r-object.json"; printf '[7,"x",{"note":"none"},{"entity":"invoice","id":310},{"entity":"فاتورة\\nضريبية","id":"inv-9"}]\n' > "$ROOT/r-mixed.json"
  for r in "$ROOT/r-empty-list.json" "$ROOT/r-empty.json" "$ROOT/r-broken.json" "$ROOT/r-object.json" "$ROOT/no-such-file.json"; do
    check "$E no_records_sentence (${r##*/})" "$(ho "$P" --records "$r")|$(sec "$H" "Records created")" '0|{"result":"ready","needsPerson":0}|None recorded.'
  done
  check "$E records: only real records are listed, on one line each" "$(ho "$P" --records "$ROOT/r-mixed.json")|$(sec "$H" "Records created")" "0|{\"result\":\"ready\",\"needsPerson\":0}|- invoice: 310${NL}- فاتورة ضريبية: inv-9"

  # ---- not_confirmed_when_p1_rests_on_proposal ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  ed "$S/checklist.json" 'd[1]["fixture"]["expect"]={"value":"90.00","oracleSource":"llm-suggested"}'
  check "$E not_confirmed_when_p1_rests_on_proposal" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  check "$E not confirmed: the Result section" "$(sec "$H" Result)" "Not confirmed: 1 items need a person."
  check "$E not confirmed: the proposal is listed by its title" "$(sec "$H" "Needs a person")" "- Expected result to confirm: $T2"
  lacks "$E no criterion id in the file" "$H" "C-002"
  cp "$HX/tracker-cards.json" "$S/tracker-cards.json"
  check "$E the title comes from the cards file when there is one" "$(ho "$P")|$(sec "$H" "Needs a person")" '0|{"result":"not confirmed","needsPerson":1}|- Expected result to confirm: خصم العميل الدائم'
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  ed "$S/checklist.json" 'del d[1]["fixture"]'
  check "$E a P1 calculated check with no source at all is a proposal" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  ed "$S/checklist.json" 'del d[1]["priority"]; d[1]["fixture"]["expect"]["oracleSource"]="llm-suggested"; del d[1]["title"]'
  check "$E a proposal on a check with no priority counts as top priority" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  check "$E the id is shown only when there is no title" "$(sec "$H" "Needs a person")" "- Expected result to confirm: C-002"
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  ed "$S/checklist.json" 'd[4]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  printf '[{"id":"J-PAY","title":"الدفع","priority":"P1","roles":["cashier"],"steps":["C-001","C-005"]}]\n' > "$R/journeys.json"
  check "$E a P2 proposal that is a step of a main journey counts as top priority" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'

  # ---- not_confirmed_when_spec_wide_decision_needs_person ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  dec "$P" "{'needsPerson':True,'evidence':'app/Http/Controllers/CartController.php:88'}"
  check "$E not_confirmed_when_spec_wide_decision_needs_person" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  check "$E the decision is listed under Needs a person" "$(sec "$H" "Needs a person")" "- Decision to confirm. Asked: ما القيمة المتوقعة لرسوم التوصيل؟; decided: 15 ريالاً"
  check "$E the decision is also listed under its step" "$(sec "$H" "Decided without a person" | tail -2)" "Scenarios step:${NL}- Asked: ما القيمة المتوقعة لرسوم التوصيل؟; decided: 15 ريالاً; based on: app/Http/Controllers/CartController.php:88"
  # ruling R-d: low confidence without a second look needs a person, whatever needsPerson says
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; D="$S/auto/decisions.json"
  dec "$P" "{'confidence':'low'}"
  check "$E not confirmed: a spec-wide low-confidence decision that never got a second look" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  check "$E status counts it by the same rule" "$(jv <(auto status checkout --project "$P" 2>/dev/null) 'd["needsPerson"]')" "1"
  ed "$D" 'd[1]["second"]="stands"; d[1]["secondReason"]="The value matches the screen."'
  check "$E a low-confidence decision whose second look stands needs nobody" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  check "$E status agrees" "$(jv <(auto status checkout --project "$P" 2>/dev/null) 'd["needsPerson"]')" "0"
  ed "$D" 'd[1]["second"]="ask"; d[1]["needsPerson"]=True'
  check "$E a decision the second look sent to a person" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  ed "$D" 'd[1]["second"]=None; d[1]["needsPerson"]=False; d[1]["confidence"]="high"'
  check "$E a high-confidence decision with evidence needs nobody" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  ed "$D" 'd[1]["needsPerson"]=True; d[1]["criteria"]=["C-003","C-001"]'
  check "$E not confirmed: a decision on a top priority check" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  ed "$D" 'd[1]["criteria"]=["C-404"]'
  check "$E not confirmed: a decision on a check the plan does not have" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'
  ed "$D" 'd[1]["criteria"]="C-003"'
  check "$E not confirmed: a decision whose checks cannot be read counts for the whole spec" "$(ho "$P")" '0|{"result":"not confirmed","needsPerson":1}'

  # ---- ready_when_only_p2_needs_person ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  dec "$P" "{'needsPerson':True,'criteria':['C-003','C-004']}"
  ed "$S/checklist.json" 'd[4]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  ed "$R/checkpoint.json" 'd["criteria"][2]["confidence"]="low"'
  check "$E ready_when_only_p2_needs_person" "$(ho "$P")" '0|{"result":"ready","needsPerson":3}'
  check "$E ready with items: the Result section says they do not hold the result back" "$(sec "$H" Result)" "Ready. 3 items need a person.${NL}Some items still need a person. They are listed below, and none rests on a top priority check."
  check "$E the three items" "$(sec "$H" "Needs a person")" "- Decision to confirm. Asked: ما القيمة المتوقعة لرسوم التوصيل؟; decided: 15 ريالاً${NL}- Expected result to confirm: حد الطلب الأدنى${NL}- Passed with low confidence: $T3"
  check "$E needsPerson is the number of listed items" "$(items "$H" "Needs a person")" "3"

  # ---- low-confidence passes, from the run's files ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  ed "$R/verification.json" 'd[0]["confidence"]="low"; d[0]["reasons"]=["no screenshot evidence"]'
  check "$E a pass the second check lowered to low confidence is listed" "$(ho "$P")|$(sec "$H" "Needs a person")" "0|{\"result\":\"ready\",\"needsPerson\":1}|- Passed with low confidence: $T1 (as cashier)"
  ed "$R/checkpoint.json" 'd["criteria"].append(dict(d["criteria"][3], confidence="low")); d["criteria"].append(dict(d["criteria"][3], confidence="high", persona="admin")); del d["criteria"][4]["confidence"]'
  check "$E the latest record of a check counts; a pass with no confidence is listed" "$(ho "$P")|$(sec "$H" "Needs a person")" "0|{\"result\":\"ready\",\"needsPerson\":3}|- Passed with low confidence: $T1 (as cashier)${NL}- Passed with low confidence: رسوم التوصيل داخل الرياض (as cashier)${NL}- Passed with low confidence: حد الطلب الأدنى (as cashier)"
  ed "$S/checklist.json" 'd[3]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  check "$E a check listed as a proposal is not listed again as a low-confidence pass" "$(ho "$P")|$(sec "$H" "Needs a person" | sed -n 1,2p)" "0|{\"result\":\"ready\",\"needsPerson\":3}|- Expected result to confirm: رسوم التوصيل داخل الرياض${NL}- Passed with low confidence: $T1 (as cashier)"

  # ---- notes and sign-in ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  printf '[{"at":"2026-11-27T08:10:00Z","id":"N1","kind":"seed-not-run","text":"php artisan db:seed --class=CartSeeder"},{"at":"2026-11-27T08:20:00Z","id":"N2","kind":"check-left-out","text":"صفحة الفاتورة تعرض خطأ 500\\nعند طلب بلا عناصر"},"x",{"id":"N3","kind":"seed-not-run","text":"  "}]\n' > "$S/auto/notes.json"
  check "$E notes are listed in plain words, with their own text" "$(ho "$P")|$(sec "$H" "Needs a person")" "0|{\"result\":\"ready\",\"needsPerson\":2}|- A data setup command was proposed and not run: php artisan db:seed --class=CartSeeder${NL}- A check was left out because it expects the application to fail: صفحة الفاتورة تعرض خطأ 500 عند طلب بلا عناصر"
  cp "$FX/config-personas.json" "$P/.qa/config.json"
  check "$E personas missing sign-in are listed" "$(ho "$P")|$(sec "$H" "Needs a person" | sed -n 1,3p)" "0|{\"result\":\"ready\",\"needsPerson\":5}|- Sign-in is not set up for this role: cashier${NL}- Sign-in is not set up for this role: branch-manager${NL}- Sign-in is not set up for this role: accountant"
  printf '{"notes":[]}\n' > "$S/auto/notes.json"; cp "$FX/config-local.json" "$P/.qa/config.json"
  check "$E notes that cannot be read are one item for a person" "$(ho "$P")|$(sec "$H" "Needs a person")" '0|{"result":"ready","needsPerson":1}|- The notes of this journey could not be read.'

  # ---- not_ready_lists_conditions / never_better_than_engine ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  cp "$HX/report-not-ready.md" "$R/report.md"
  check "$E never_better_than_engine" "$(ho "$P")" '0|{"result":"not ready","needsPerson":0}'
  check "$E not_ready_lists_conditions" "$(sec "$H" Result)" "Not ready: some screens have not been checked yet; a main user journey did not pass; a top priority check failed; the results have not had their second check yet."
  lacks "$E the engine's own wording is not shown" "$H" "census surface"
  lacks "$E no criterion id from a condition" "$H" "C-002"
  dec "$P" "{'needsPerson':True}"
  check "$E not ready stays not ready when something also waits for a person" "$(ho "$P")" '0|{"result":"not ready","needsPerson":1}'
  # every condition the engine can write
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  printf '## Ship readiness\n\n**NOT SHIP-READY**\n\n- 1 census surface(s) uncovered\n- census is empty\n- census coverage unknown\n- census adapter failed\n- no P1 journeys declared\n- P1 journey J-PAY is blocked (disputed: C-001)\n- coding-layer fail on P1 C-002 (service)\n- fail on P1 with unknown layer C-001 (layer unknown)\n- not independently verified\n- verifier override on P1 C-001\n- verification out of date on P1 C-001\n- verifier disputed P1 C-001\n- 2 P1 low-confidence pass(es) not re-judged: C-001, C-002\n- re-adjudication unavailable — 1 P1 low-confidence pass(es) unreviewed: C-001\n- re-adjudication did not run — 1 P1 low-confidence pass(es) unreviewed: C-001\n- re-adjudication decision on P1 C-001 was not applied\n- adjudication/decisions.json is not a JSON array\n- a condition added in a later release\n\n| Check | Result |\n|---|---|\n' > "$R/report.md"
  check "$E every engine condition has plain words" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"not ready","needsPerson":0}|Not ready: some screens have not been checked yet; the list of screens to check is not complete; no main user journey is listed for this run; a main user journey did not pass; a top priority check failed; the results have not had their second check yet; the second check did not confirm a top priority result; the second check is out of date for a top priority result; a reviewer did not confirm a top priority result; a top priority result still needs a person to confirm it; a review of a top priority result was not recorded; the review of the results could not be read; another condition is not met (see the report of the run).'
  lacks "$E no criterion id from any condition" "$H" "C-00"
  # a report that says both
  printf '## Ship readiness\n\n**SHIP-READY**\n\n- not independently verified\n\n| Check | Result |\n|---|---|\n' > "$R/report.md"
  check "$E a ready line that lists a condition is not ready" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"not ready","needsPerson":0}|Not ready: the results have not had their second check yet.'
  printf '## Ship readiness\n\n**SHIP-READY**\n\n| Check | Result |\n|---|---|\n| Census coverage | 12 of 12 |\n\nAn earlier run was NOT SHIP-READY.\n' > "$R/report.md"
  check "$E a section that says NOT SHIP-READY anywhere is not ready" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"not ready","needsPerson":0}|Not ready: the report does not say why.'
  printf '## Ship readiness\n\n**SHIP-READY**\n\n| Check | Result |\n|---|---|\n\n## Summary\n\n## Ship readiness\n\n**NOT SHIP-READY**\n\n- no P1 journeys declared\n' > "$R/report.md"
  check "$E two sections, one not ready: not ready" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"not ready","needsPerson":0}|Not ready: no main user journey is listed for this run.'

  # ---- a malformed ship section is never ready ----
  n=0
  for r in '## Ship readiness\n\n  **SHIP-READY**\n\n| Check | Result |\n' \
           '## Ship readiness\n\nSHIP-READY\n\n| Check | Result |\n' \
           '## Ship readiness\n\n**SHIP-READY** as far as we can tell\n' \
           '## Ship readiness\n\n| Check | Result |\n|---|---|\n\n**SHIP-READY**\n' \
           '## Ship readiness\n\n' \
           '## Ship readiness\n\n**SHIP-READY**\n\n## Summary\n\n## Ship readiness\n\n**SHIP-READY**\n' \
           '## Ship readiness\n\n**ship-ready**\n'; do
    n=$((n + 1))
    # shellcheck disable=SC2059
    printf "$r" > "$R/report.md"
    check "$E a malformed ship section is never ready [$n]" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}The readiness result in the report of the run could not be read."
  done
  printf '##   Ship readiness\n\n**SHIP-READY**\n' > "$R/report.md"
  check "$E a heading that is not the engine's is no ship section" "$(ho "$P")" '0|{"result":"verified","needsPerson":0}'
  printf '## Ship readiness  \r\n\r\n**SHIP-READY**\r\n\r\n| Check | Result |\r\n' > "$R/report.md"
  check "$E blanks and carriage returns at line ends are not part of the verdict" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  rm "$R/report.md"
  check "$E a run without its report" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}The readiness result in the report of the run could not be read."
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"; J="$S/auto/journey.json"
  cp "$HX/report-plain.md" "$R/report.md"; ed "$J" 'd["profile"]="ship"'
  check "$E a ship journey whose report has no ship section" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}The report of the run has no readiness result."

  # ---- ready needs the files it is decided from ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  printf '{"decisions":[]}\n' > "$S/auto/decisions.json"
  check "$E ship-ready with decisions that cannot be read" "$(ho "$P")|$(sec "$H" Result)|$(sec "$H" "Needs a person")" "0|{\"result\":\"not verified\",\"needsPerson\":1}|Not verified. 1 items need a person.${NL}The decisions or the plan of checks could not be read.|- The record of decisions could not be read."
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  printf '{"rows":' > "$S/checklist.json"
  check "$E ship-ready with a plan that cannot be read" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":1}|Not verified. 1 items need a person.${NL}The decisions or the plan of checks could not be read."
  rm "$S/checklist.json"
  check "$E ship-ready with no plan" "$(ho "$P")" '0|{"result":"not verified","needsPerson":1}'
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  rm "$R/verification.json"
  check "$E ship-ready with no second check on disk" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}The results have not had their second check."
  cp "$HX/verification-override.json" "$R/verification.json"
  # an empty second check (the engine writes [] for a run with no passes) beside recorded passes
  # covers none of them: never `ready`
  printf '[]\n' > "$R/verification.json"
  check "$E empty_second_check_beside_passes_is_not_verified" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}The second check does not cover the passed results."
  printf '{"rows":[]}\n' > "$R/verification.json"
  check "$E empty_second_check_beside_passes_is_not_verified (rows under a key)" "$(ho "$P")" '0|{"result":"not verified","needsPerson":0}'
  ed "$R/checkpoint.json" 'rows=d["criteria"] if isinstance(d,dict) else d
for r in rows: r["verdict"]="fail"'
  printf '[]\n' > "$R/verification.json"
  check "$E empty_second_check_with_no_passes_follows_the_report" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  cp "$HX/checkpoint.json" "$R/checkpoint.json"
  cp "$HX/verification-override.json" "$R/verification.json"
  # item 23: an override on the run is never `ready`, also when the engine's ship verdict did not count it
  check "$E override_under_ship_ready_is_not_verified" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}The second check did not confirm every passed result."
  ed "$R/verification.json" 'd[1]["verifierVerdict"]="blocked"'
  check "$E override_under_ship_ready_is_not_verified (a pass turned into blocked)" "$(ho "$P")" '0|{"result":"not verified","needsPerson":0}'
  cp "$HX/verification-clean.json" "$R/verification.json"
  ed "$R/verification.json" 'd.append({"criterionId":"C-002","persona":"cashier","inRunVerdict":"fail","verifierVerdict":"fail"})'
  check "$E ship-ready: a recorded fail the second check left a fail is no override" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  cp "$HX/verification-clean.json" "$R/verification.json"
  printf '{"criteria":' > "$R/checkpoint.json"
  check "$E ship-ready with results that cannot be read" "$(ho "$P")|$(sec "$H" Result)|$(sec "$H" "Needs a person")" "0|{\"result\":\"not verified\",\"needsPerson\":1}|Not verified. 1 items need a person.${NL}The results of the run could not be read.|- The results of the run could not be read."

  # ---- verified_under_full_profile / not_verified_without_verification ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  cp "$HX/report-plain.md" "$R/report.md"
  check "$E verified_under_full_profile" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"verified","needsPerson":0}|Verified.'
  dec "$P" "{'needsPerson':True}"; ed "$S/checklist.json" 'd[1]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  check "$E verified is about the run; what waits for a person is counted beside it" "$(ho "$P")" '0|{"result":"verified","needsPerson":2}'
  cp "$HX/verification-override.json" "$R/verification.json"
  check "$E not verified: the second check turned a pass into a fail" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":2}|Not verified. 2 items need a person.${NL}The second check did not confirm every passed result."
  ed "$R/verification.json" 'd[1]["verifierVerdict"]="blocked"'
  check "$E not verified: the second check turned a pass into blocked" "$(ho "$P")" '0|{"result":"not verified","needsPerson":2}'
  ed "$R/verification.json" 'd[1]["verifierVerdict"]="pass"; d[2]["verifierVerdict"]="fail"'
  check "$E not verified: the run-level second check failed" "$(ho "$P")" '0|{"result":"not verified","needsPerson":2}'
  ed "$R/verification.json" 'd[2]["verifierVerdict"]="pass"; d.append({"criterionId":"C-002","persona":"cashier","inRunVerdict":"fail","verifierVerdict":"fail"})'
  check "$E verified: a recorded fail the second check left a fail is no override" "$(ho "$P")" '0|{"result":"verified","needsPerson":2}'
  ed "$R/verification.json" 'del d[0]["verifierVerdict"]'
  check "$E not verified: a second-check row without a verdict" "$(ho "$P")" '0|{"result":"not verified","needsPerson":2}'
  printf '[]\n' > "$R/verification.json"
  check "$E not verified under full: an empty second check beside recorded passes" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":2}|Not verified. 2 items need a person.${NL}The second check does not cover the passed results."
  printf '{"rows":[{"criterionId":"C-001","inRunVerdict":"pass","verifierVerdict":"pass"}]}\n' > "$R/verification.json"
  check "$E verified: the rows may sit under a key" "$(ho "$P")" '0|{"result":"verified","needsPerson":2}'
  n=0
  for r in '{"overrides":[]}' '[{"criterionId":"C-001"' '' '"pass"' '[["C-001","pass"]]'; do
    n=$((n + 1))
    printf '%s\n' "$r" > "$R/verification.json"
    check "$E not verified: a second check that cannot be read [$n]" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":2}|Not verified. 2 items need a person.${NL}The second check could not be read."
  done
  rm "$R/verification.json"
  check "$E not_verified_without_verification" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":2}|Not verified. 2 items need a person.${NL}The results have not had their second check."
  cp "$HX/verification-clean.json" "$R/verification.json"; rm "$R/checkpoint.json"
  check "$E not verified: the run has no results on disk" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":3}|Not verified. 3 items need a person.${NL}The results of the run could not be read."
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ed "$J" 'd["runId"]=None'
  check "$E not verified: a finished journey with no run" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}This journey has no run."
  ed "$J" 'd["runId"]="../../specs/checkout"'
  check "$E a run id that is not a plain name is no run" "$(ho "$P")" '0|{"result":"not verified","needsPerson":0}'

  # ---- an open journey is neither stopped nor ready ----
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  before="$(snapshot "$P")"
  check "$E an open journey is not verified" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}This journey has not finished."
  check "$E handoff never changes the journey's state" "$(jv "$J" 'd["state"]')|$([ "$(snapshot "$P")" = "$before" ] && echo same)" "open|same"

  # ---- stopped_time_limit_sentence, and the other reasons ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  stopj "$P" time-limit
  check "$E stopped_time_limit_sentence" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"stopped","needsPerson":0}|Stopped: the time limit was reached.'
  for r in "step-failed|a step could not be completed" "until|it was asked to stop before the run" "blocked|coverage could not be reached" \
           "no-sign-in|no role has sign-in set up" "tracker|ClickUp could not be updated" "audit|a limit was broken" "tired|the reason was not recorded"; do
    stopj "$P" "${r%%|*}"
    check "$E stopped: ${r%%|*}" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"stopped\",\"needsPerson\":0}|Stopped: ${r#*|}."
  done
  lacks "$E the stop detail is not copied into the file" "$H" "recorded detail"
  ed "$J" 'd["stop"]=None'
  check "$E stopped with no reason recorded" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"stopped","needsPerson":0}|Stopped: the reason was not recorded.'

  # ---- an audit-stopped journey lists what was broken, in plain words ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  cp "$HX/tracker-cards.json" "$S/tracker-cards.json"
  ed "$S/auto/decisions.json" 'd.append({"id":"D2","step":"spec","class":"seed","question":"هل نشغل أمر تجهيز البيانات؟","answer":"نعم","evidence":"x","confidence":"high","criteria":[],"needsPerson":False,"second":None})'
  ed "$J" 'd["state"]="stopped"; d["stopBeforeAudit"]={"reason":"time-limit","detail":"the deadline has passed"}; d["stop"]={"reason":"audit","detail":"x"}; d["auditViolations"]=["base-url-changed","baseline-changed","baseline-missing","decisions-unreadable","exclusion-added","forbidden-decision:#4","forbidden-decision:D2","human-oracle-added:C-003","human-oracle-changed:C-001","human-oracle-removed:C-004","known-defects-changed","not-verified","plan-row-removed:C-900","plan-unreadable","run-config-safety:gates","safety-setting-changed:humanInteraction.maxOptOutRate","seed-added","step-without-result:analyze","step-without-result:run","tracker-behind","something-new:C-001",7]'
  want="Stopped: a limit was broken.
- The address of the application under test was changed during the journey.
- The record of the starting settings was changed during the journey.
- The record of the starting settings is missing.
- The record of decisions could not be read.
- A screen was left out of coverage during the journey.
- A decision was recorded that this journey may not make.
- A decision was recorded that this journey may not make: هل نشغل أمر تجهيز البيانات؟
- An expected result was marked as confirmed by a person during the journey: $T3
- An expected result that a person had confirmed was changed: الإجمالي يشمل الضريبة
- An expected result that a person had confirmed is no longer marked as confirmed: رسوم التوصيل داخل الرياض
- The list of known defects was changed during the journey.
- The run was not verified.
- A check from the starting plan was removed: C-900
- The plan of checks could not be read.
- A safety setting was changed in the run settings of this spec: gates
- A safety setting was changed during the journey: humanInteraction.maxOptOutRate
- A data setup command was added during the journey.
- A step was marked as done without its result: the analysis step
- A step was marked as done without its result: the run step
- ClickUp is behind the results.
- A limit was broken; see the journey record.
Before the limits were checked, this journey had stopped because the time limit was reached."
  check "$E an audit-stopped journey lists every violation in plain words" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"stopped\",\"needsPerson\":0}|$want"
  lacks "$E no raw violation code in the file" "$H" "human-oracle"
  lacks "$E no criterion id where a title exists" "$H" "C-001"
  ed "$J" 'del d["stopBeforeAudit"]; d["auditViolations"]=[]'
  check "$E an audit stop without codes" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"stopped","needsPerson":0}|Stopped: a limit was broken.'
  # the real audit, then the handoff
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  printf '{"command":"php artisan db:seed"}\n' > "$S/seed.json"
  QA_AUTO_TRACKER_CMD="bash $ROOT/trk-skip.sh" auto audit checkout --project "$P" >/dev/null 2>&1
  check "$E after a failed audit the journey is stopped, whatever the report says" "$(jv "$J" 'd["auditViolations"]')|$(ho "$P")|$(sec "$H" Result)" "[\"seed-added\"]|0|{\"result\":\"stopped\",\"needsPerson\":0}|Stopped: a limit was broken.${NL}- A data setup command was added during the journey."

  # ---- restarted ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ed "$J" 'd["restartedFrom"]=2'
  check "$E a restarted journey says so in the Result section" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"ready\",\"needsPerson\":0}|Ready.${NL}This journey was restarted; the earlier one is kept in its history."

  # ---- item 12: the next action named in "How to confirm" is a command that works ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ho "$P" >/dev/null
  check "$E next_action_after_a_finished_journey" "$(sec "$H" "How to confirm" | tail -1)" "- Then run \`/qa-auto checkout\` again. It starts a new journey on the confirmed plan."
  out="$(auto start checkout --project "$P" 2>&1)"
  check "$E next_action_after_a_finished_journey works" "$?" "0"
  for r in blocked audit no-sign-in tracker; do
    P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
    auto stop checkout --project "$P" --reason "$r" --detail "x" >/dev/null 2>&1
    ho "$P" >/dev/null
    check "$E next_action_after_a_${r}_stop" "$(sec "$H" "How to confirm" | tail -1)" "- Then run \`/qa-auto checkout --restart\`. It starts a new journey on the confirmed plan."
    auto start checkout --project "$P" >/dev/null 2>&1; rc=$?
    auto start checkout --project "$P" --restart >/dev/null 2>&1
    check "$E next_action_after_a_${r}_stop: the plain start is refused, the named command works" "$rc|$?" "1|0"
  done
  for r in time-limit step-failed until; do
    P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
    auto stop checkout --project "$P" --reason "$r" --detail "x" >/dev/null 2>&1
    ho "$P" >/dev/null
    check "$E next_action_after_a_${r}_stop" "$(sec "$H" "How to confirm" | tail -2)" "- Then run \`/qa-auto checkout --restart\`. It starts a new journey on the confirmed plan.${NL}- To continue this journey with nothing confirmed, run \`/qa-auto checkout\`."
    auto resume checkout --project "$P" >/dev/null 2>&1
    check "$E next_action_after_a_${r}_stop: the journey can be continued" "$?" "0"
  done
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  ho "$P" >/dev/null
  check "$E next_action_on_an_open_journey" "$(sec "$H" "How to confirm" | tail -1)" "- Then run \`/qa-auto checkout --restart\`. It starts a new journey on the confirmed plan."
  # a journey that replaced one stopped by its audit says so, in one sentence
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ed "$J" 'd["replacedFrom"]=1; d["replacedAfterAudit"]=True'
  check "$E replaced_after_audit_sentence" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"ready\",\"needsPerson\":0}|Ready.${NL}An earlier journey for this target was replaced; it is kept in the history.${NL}The earlier journey had stopped because a limit was broken; this one started from the settings as they were after that."
  ed "$J" 'd["replacedAfterAudit"]="yes"'
  check "$E replacedAfterAudit must be true to be said" "$(sec "$(ho "$P" >/dev/null; echo "$H")" Result | wc -l | tr -d ' ')" "2"
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  auto stop checkout --project "$P" --reason audit --detail "seed-added" >/dev/null 2>&1
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  ho "$P" >/dev/null
  check "$E replaced_after_audit_sentence through the verbs" "$(jv "$J" 'd.get("replacedAfterAudit")')|$(sec "$H" Result | tail -1)" "true|The earlier journey had stopped because a limit was broken; this one started from the settings as they were after that."

  # ---- H5: a journey that was continued, or that took the place of an earlier one, says so ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ed "$J" 'd["replacedFrom"]=3'
  check "$E a journey that replaced an earlier one says so" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"ready\",\"needsPerson\":0}|Ready.${NL}An earlier journey for this target was replaced; it is kept in the history."
  ed "$J" 'd["resumes"]=[{"at":"2026-11-27T09:00:00Z","maxHours":6,"from":"time-limit"},{"at":"2026-11-27T10:00:00Z","maxHours":2,"from":"step-failed"}]'
  check "$E a journey that was continued says how many times" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"ready\",\"needsPerson\":0}|Ready.${NL}An earlier journey for this target was replaced; it is kept in the history.${NL}This journey was continued 2 times after stopping."
  ed "$J" 'd["restartedFrom"]=3; del d["resumes"][1]'
  check "$E restarted, replaced and continued once: one sentence each" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"ready\",\"needsPerson\":0}|Ready.${NL}This journey was restarted; the earlier one is kept in its history.${NL}An earlier journey for this target was replaced; it is kept in the history.${NL}This journey was continued 1 times after stopping."
  ed "$J" 'd["resumes"]="twice"; d["replacedFrom"]=None; del d["restartedFrom"]'
  check "$E a resumes value that is not a list, and no earlier journey, say nothing" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"ready","needsPerson":0}|Ready.'
  # through the verbs: a real stop, resume and restart leave the sentences
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  auto stop checkout --project "$P" --reason time-limit --detail "the deadline has passed" >/dev/null 2>&1
  auto resume checkout --project "$P" >/dev/null 2>&1
  check "$E after a real resume the handoff says the journey was continued" "$(ho "$P" | cut -c1-2)$(sec "$H" Result | tail -1)" "0|This journey was continued 1 times after stopping."
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E after a real restart the handoff says both" "$(ho "$P" | cut -c1-2)$(sec "$H" Result | tail -2 | tr '\n' '|')" "0|This journey was restarted; the earlier one is kept in its history.|An earlier journey for this target was replaced; it is kept in the history.|"

  # ---- T1: without a passing audit that is not older than the steps, never better than not verified ----
  NOAUDIT="The audit has not run for this journey."
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  check "$E the fixture carries a passing audit record" "$(jv "$J" '[d["audit"]["ok"],d["audit"]["at"]>=d["stepsChangedAt"]]')" "[true, true]"
  ed "$J" 'del d["audit"]'
  check "$E a finished journey that was never audited is not verified" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}$NOAUDIT"
  ed "$J" 'd["audit"]={"ok":True,"at":"2026-11-27T07:59:59Z"}'
  check "$E an audit older than the last change to the steps does not count" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}$NOAUDIT"
  ed "$J" 'd["audit"]={"ok":True,"at":d["stepsChangedAt"]}'
  check "$E an audit as new as the last change to the steps counts" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  for v in '{"ok":False,"at":"2026-11-27T12:00:00Z"}' '{"ok":"true","at":"2026-11-27T12:00:00Z"}' '{"ok":True}' '{"ok":True,"at":20261127}' 'True' '"ok"' '[]'; do
    ed "$J" "d['audit']=$v"
    check "$E an audit record of $v does not count" "$(ho "$P")" '0|{"result":"not verified","needsPerson":0}'
  done
  # a step that changed after the audit
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ed "$J" 'd["steps"][5]["state"]="pending"'
  NOW="2026-11-27T09:00:00Z" auto step-start checkout verify --project "$P" >/dev/null 2>&1
  NOW="2026-11-27T09:05:00Z" auto step-done checkout verify --project "$P" >/dev/null 2>&1
  NOW="2026-11-27T09:06:00Z" auto next checkout --project "$P" >/dev/null 2>&1
  check "$E a step finished after the audit makes the audit stale" "$(jv "$J" '[d["state"],d["audit"]["at"],d["stepsChangedAt"]]')|$(ho "$P")|$(sec "$H" Result)" "[\"done\", \"2026-11-27T08:00:00Z\", \"2026-11-27T09:05:00Z\"]|0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}$NOAUDIT"
  NOW="2026-11-27T09:10:00Z" QA_AUTO_TRACKER_CMD="bash $ROOT/trk-skip.sh" auto audit checkout --project "$P" >/dev/null 2>&1
  check "$E and a new audit makes the result count again" "$(ho "$P")" '0|{"result":"ready","needsPerson":0}'
  # every result that would be better, or as good, becomes not verified; a stop stays a stop
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"; R="$P/.qa/runs/r1"
  ed "$J" 'del d["audit"]'; cp "$HX/report-not-ready.md" "$R/report.md"
  check "$E a not ready report without an audit is not verified" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}$NOAUDIT"
  cp "$HX/report-plain.md" "$R/report.md"
  check "$E a verified run without an audit is not verified" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}$NOAUDIT"
  stopj "$P" time-limit
  check "$E a stopped journey without an audit stays stopped, and says so" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"stopped\",\"needsPerson\":0}|Stopped: the time limit was reached.${NL}$NOAUDIT"
  stopj "$P" audit
  check "$E a journey stopped by its audit is not told the audit has not run" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"stopped","needsPerson":0}|Stopped: a limit was broken.'
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  ed "$J" 'del d["audit"]'
  check "$E an open journey that was never audited says both" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":0}|Not verified.${NL}This journey has not finished.${NL}$NOAUDIT"

  # ---- T2: the count goes with every result ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"; R="$P/.qa/runs/r1"
  ed "$S/checklist.json" 'd[4]["fixture"]["expect"]["oracleSource"]="llm-suggested"'; ed "$R/checkpoint.json" 'd["criteria"][2]["confidence"]="low"'
  check "$E ready with a count" "$(ho "$P")|$(sec "$H" Result | sed -n 1p)" '0|{"result":"ready","needsPerson":2}|Ready. 2 items need a person.'
  cp "$HX/report-plain.md" "$R/report.md"
  check "$E verified with a count" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"verified","needsPerson":2}|Verified. 2 items need a person.'
  cp "$HX/report-not-ready.md" "$R/report.md"
  check "$E not ready with a count" "$(ho "$P" | cut -c1-43)|$(sec "$H" Result | sed -n 1p | sed 's/^Not ready: .*\. \([0-9]* items need a person\.\)$/Not ready: <why>. \1/')" '0|{"result":"not ready","needsPerson":2}|Not ready: <why>. 2 items need a person.'
  ed "$J" 'del d["audit"]'
  check "$E not verified with a count" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"not verified\",\"needsPerson\":2}|Not verified. 2 items need a person.${NL}$NOAUDIT"
  stopj "$P" step-failed
  check "$E stopped with a count" "$(ho "$P")|$(sec "$H" Result)" "0|{\"result\":\"stopped\",\"needsPerson\":2}|Stopped: a step could not be completed. 2 items need a person.${NL}$NOAUDIT"
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  ed "$S/checklist.json" 'd[1]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  check "$E not confirmed says the count once" "$(ho "$P")|$(sec "$H" Result)" '0|{"result":"not confirmed","needsPerson":1}|Not confirmed: 1 items need a person.'
  check "$E the printed keys are result and needsPerson, in that order" "$(ho "$P" | cut -c3- | sed 's/:[^,}]*//g')" '{"result","needsPerson"}'

  # ---- no_requirements_opening_line ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  dec "$P" "{'evidence':None,'needsPerson':True,'criteria':['C-003']}"
  check "$E no_requirements_opening_line" "$(ho "$P")|$(sed -n 1,3p "$H")" "0|{\"result\":\"ready\",\"needsPerson\":1}|No written requirements were found for this target. Expected results were taken from the application and need a person.${NL}${NL}## Result"
  check "$E a decision without evidence says so" "$(sec "$H" "Decided without a person" | tail -1)" "- Asked: ما القيمة المتوقعة لرسوم التوصيل؟; decided: 15 ريالاً; based on: nothing written"
  check "$E the sections still come in order" "$(grep '^#' "$H")" "$TITLES"

  # ---- decisions grouped by step, in step order; no scope recorded ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  printf '[]\n' > "$S/auto/decisions.json"
  dec "$P" "{'step':'run','class':'inputs','question':'q-run','answer':'a-run','evidence':'e-run'}"
  dec "$P" "{'step':'constitution','class':'roles','question':'q-roles','answer':'a-roles','evidence':'e-roles'}"
  dec "$P" "{'step':'verify','class':'gaps','question':'q-verify','answer':'a-verify','evidence':'e-verify'}"
  dec "$P" "{'step':'analyze','class':'gaps','question':'q-analyze','answer':'a-analyze','evidence':'e-analyze'}"
  dec "$P" "{'step':'somewhere','class':'gaps','question':'q-else','answer':'a-else','evidence':'e-else'}"
  dec "$P" "{'step':'constitution','class':'roles','question':'q-roles-2','answer':'a-roles-2','evidence':'e-roles-2'}"
  ho "$P" >/dev/null
  check "$E decisions are grouped by step, in step order" "$(sec "$H" "Decided without a person" | grep -v '^- ' | tr '\n' '|')" "Project rules step:|Analysis step:|Run step:|Verification step:|Other:|"
  check "$E a step lists its decisions in the order they were made" "$(sec "$H" "Decided without a person" | sed -n 2,3p)" "- Asked: q-roles; decided: a-roles; based on: e-roles${NL}- Asked: q-roles-2; decided: a-roles-2; based on: e-roles-2"
  check "$E no scope recorded" "$(sec "$H" "Scope chosen for this spec")" "No scope was recorded."
  rm "$S/auto/decisions.json"
  check "$E no decisions at all" "$(ho "$P")|$(sec "$H" "Decided without a person")" '0|{"result":"ready","needsPerson":0}|Nothing was decided without a person.'

  # ---- free text is written as it is, on one line ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  "$PY" -c 'import json,sys
t=sys.argv[3]
json.dump([{"id":"D1","step":"spec","class":"scope","question":t,"answer":t,"evidence":t,"confidence":"low","criteria":["C-003"],"assumption":True,"needsPerson":False,"second":None,"secondReason":None}],open(sys.argv[1],"w",encoding="utf-8"))
json.dump([{"id":"N1","kind":"check-left-out","text":t,"at":"2026-11-27T08:10:00Z"}],open(sys.argv[2],"w",encoding="utf-8"),ensure_ascii=False)' "$S/auto/decisions.json" "$S/auto/notes.json" "$NASTY" </dev/null
  check "$E free text: output" "$(ho "$P")" '0|{"result":"ready","needsPerson":2}'
  check "$E free text: the scope line" "$(sec "$H" "Scope chosen for this spec")" "- $NASTY_FLAT"
  check "$E free text: the decision line" "$(sec "$H" "Decided without a person" | tail -1)" "- Asked: $NASTY_FLAT; decided: $NASTY_FLAT; based on: $NASTY_FLAT"
  check "$E free text: the items for a person" "$(sec "$H" "Needs a person")" "- Decision to confirm. Asked: $NASTY_FLAT; decided: $NASTY_FLAT${NL}- A check was left out because it expects the application to fail: $NASTY_FLAT"
  check "$E free text: nothing in it was run" "$([ -e "$MARK" ] && echo ran || echo no)" "no"
  check "$E free text: every list item is one line" "$(grep -cE '^(سطر|end)' "$H")|$(grep -c 'سطر ثانٍ' "$H")" "0|4"

  # ---- the words of the file ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; R="$P/.qa/runs/r1"
  dec "$P" "{'needsPerson':True,'evidence':None}"; ed "$S/checklist.json" 'd[1]["fixture"]["expect"]["oracleSource"]="llm-suggested"'
  ed "$R/checkpoint.json" 'd["criteria"][2]["confidence"]="low"'
  ho "$P" --records "$HX/records.json" >/dev/null
  for r in " AI " "agent" "Agent" "automat" "Automat" "bot" "robot" "Claude" "unattended" "C-00" ".json" ".qa/" "D1" "D2"; do
    lacks "$E the file does not say: $r" "$H" "$r"
  done
  check "$E headings are sentence case and nothing is an emoji" "$(LC_ALL=C grep -c "$(printf '\360\237')" "$H")|$(grep -c '^## [A-Z][a-z]' "$H")" "0|6"

  # ---- refusals and usage ----
  P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"; J="$S/auto/journey.json"
  before="$(snapshot "$P")"
  check "$E handoff for a target with no journey" "$(auto handoff orders --project "$P" 2>&1; echo "rc=$?")" "auto: no journey for orders${NL}rc=1"
  check "$E handoff takes no extra word" "$(auto handoff checkout extra --project "$P" 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")" "auto: handoff does not take: extra${NL}rc=2"
  check "$E --records needs a file" "$(auto handoff checkout --project "$P" --records 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")" "auto: --records needs a file${NL}rc=2"
  check "$E handoff takes no other option" "$(auto handoff checkout --project "$P" --reason x 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")" "auto: handoff does not take: --reason${NL}rc=2"
  check "$E handoff without a target" "$(auto handoff --project "$P" 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")" "auto: a target is needed${NL}rc=2"
  check "$E refusals write nothing" "$(snapshot "$P")|$([ -e "$H" ] && echo made || echo none)" "$before|none"
  printf '{"state":"paused"}\n' > "$J"
  check "$E a journey that cannot be read" "$(auto handoff checkout --project "$P" 2>&1; echo "rc=$?")" "auto: journey.json for checkout is not readable${NL}rc=1"
  printf '{"state":' > "$J"
  check "$E a journey that is not JSON" "$(auto handoff checkout --project "$P" 2>&1; echo "rc=$?")|$([ -e "$H" ] && echo made || echo none)" "auto: journey.json for checkout is not readable${NL}rc=1|none"
  if [ "$(id -u)" != 0 ]; then
    P="$(fin)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
    chmod 555 "$S/auto"
    check "$E a handoff that cannot be written prints no result" "$(auto handoff checkout --project "$P" 2>&1; echo "rc=$?")" "auto: could not write .qa/specs/checkout/auto/handoff.md${NL}rc=1"
    chmod 755 "$S/auto"
  fi

  # ---- status counts by the same rule as the handoff (ruling R-d) ----
  P="$(fin open)"; S="$P/.qa/specs/checkout"; H="$S/auto/handoff.md"
  auto decide checkout --project "$P" --step scenarios --class expected --question "ما رسوم التوصيل خارج الرياض؟" --answer "25 ريالاً" --evidence "resources/views/cart.blade.php:52" --confidence low --criteria C-003 >/dev/null 2>&1
  auto decide checkout --project "$P" --step scenarios --class inputs --question "ما قيم الحدود للخصم؟" --answer "0 و 100 و 100.01" --evidence none --confidence high --criteria C-003 >/dev/null 2>&1
  auto decide checkout --project "$P" --step scenarios --class inputs --question "ما أقل كمية؟" --answer "1" --evidence "app/Models/Order.php:20" --confidence high >/dev/null 2>&1
  check "$E status and handoff count the same decisions" "$(jv <(auto status checkout --project "$P" 2>/dev/null) 'd["needsPerson"]')|$(ho "$P")" '2|0|{"result":"not verified","needsPerson":2}'
  auto second checkout D2 stands --reason "الملف يذكر القيمة نفسها" --project "$P" >/dev/null 2>&1
  check "$E after the second look stands on the low-confidence decision" "$(jv <(auto status checkout --project "$P" 2>/dev/null) 'd["needsPerson"]')|$(ho "$P")" '1|0|{"result":"not verified","needsPerson":1}'
}

for e in jq python3; do
  if [ "$e" = jq ] && ! command -v jq >/dev/null 2>&1; then echo "SKIP: jq not installed"; continue; fi
  run_engine "$e"
done

# ---- cross-engine: the same journey gives the same bytes ----
if command -v jq >/dev/null 2>&1; then
  # mut <project> — everything a handoff reads, at once, with text a shell or an engine could mangle
  mut() {
    local P="$1" S="$1/.qa/specs/checkout" R="$1/.qa/runs/r1"
    "$PY" -c 'import json,sys
S,R,t=sys.argv[1:4]
ids=["C-001","معيار-٧ \"مقتبس\" \\ $HOME\n`x`","C-\u007f-del","C-\u0000-nul 🧾",""]
plan=json.load(open(S+"/checklist.json",encoding="utf-8"))
plan[1]["fixture"]["expect"]["oracleSource"]="llm-suggested"
plan+=[{"id":ids[1],"title":t,"kind":"business-rule","priority":"P2","fixture":{"expect":{"value":1.50}}},
       {"id":ids[2],"label":"  عنوان  من   label\t","kind":"bake","fixture":{"expect":{"oracleSource":"llm-suggested"}}},
       {"id":ids[3],"kind":"computed-logic","priority":7},{"id":ids[4],"kind":"computed-logic","priority":"P3","title":""},
       {"id":"C-001","title":"a second row with the same id","kind":"business-rule","priority":"P2"},"x",{"title":"no id"}]
json.dump(plan,open(S+"/checklist.json","w",encoding="utf-8"),ensure_ascii=False)
dec=json.load(open(S+"/auto/decisions.json",encoding="utf-8"))
base={"assumption":True,"second":None,"secondReason":None}
dec+=[dict(base,id="D2",step="scenarios",**{"class":"expected"},question=t,answer=t,evidence=None,confidence="low",criteria=[ids[1],7,ids[2]],needsPerson=False),
      dict(base,id="D3",step="spec",**{"class":"scope"},question="س ؤال",answer="جواب\r\nثانٍ",evidence="",confidence="low",criteria=[],needsPerson=False,second="stands"),
      dict(base,id="D4",step=7,**{"class":None},question=None,answer=["x"],evidence={"a":1},confidence="high",criteria="C-001",needsPerson=True),
      "x",{"id":"D5"},dict(base,id="D6",step="run",**{"class":"gaps"},question="q",answer="a",evidence="e",confidence="low",criteria=[ids[0]],needsPerson=False,second="ask")]
json.dump(dec,open(S+"/auto/decisions.json","w",encoding="utf-8"))
json.dump([{"id":"N1","kind":"seed-not-run","text":t,"at":"x"},{"id":"N2","kind":"other","text":"ملاحظة \u0085 أخرى"},{"kind":"check-left-out"},7],open(S+"/auto/notes.json","w",encoding="utf-8"),ensure_ascii=False)
cp=json.load(open(R+"/checkpoint.json",encoding="utf-8"))
cp["criteria"]+=[{"criterion_id":ids[1],"persona":"أمين \"الصندوق\"","verdict":"PASS","confidence":"low"},{"criterionId":ids[2],"verdict":"pass"},
                 {"criterion_id":ids[3],"persona":7,"verdict":"pass","confidence":"medium"},{"id":"C-003","persona":"","verdict":"fail","confidence":"low"},
                 {"criterion_id":"C-005","persona":"cashier","verdict":"Pass","confidence":"high"},"x",{"verdict":"pass"}]
json.dump(cp,open(R+"/checkpoint.json","w",encoding="utf-8"),ensure_ascii=False)
v=json.load(open(R+"/verification.json",encoding="utf-8"))
v+=[{"criterionId":"C-005","persona":"cashier","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"low"},
    {"criterionId":"C-004","persona":"cashier","inRunVerdict":"pass","verifierVerdict":"blocked","confidence":"high"}]
json.dump(v,open(R+"/verification.json","w",encoding="utf-8"))
json.dump({"cards":[{"checks":[{"criterion":ids[2],"title":""},{"criterion":"C-004","title":t},{"criterion":"C-004","title":"second title"},7]},"x",{"checks":"none"}]},open(S+"/tracker-cards.json","w",encoding="utf-8"),ensure_ascii=False)
json.dump([{"id":"J1","priority":"P1","steps":[ids[4],{"criterionId":ids[1]},7]},{"id":"J2","priority":"P2","steps":["C-003"]},"x"],open(R+"/journeys.json","w",encoding="utf-8"),ensure_ascii=False)
json.dump([{"entity":t,"id":t},{"entity":"order","id":1.0},{"entity":"order","id":2.50},{"entity":True,"id":None},{"id":"only-id"}],open(sys.argv[4],"w",encoding="utf-8"),ensure_ascii=False)' "$S" "$R" "$NASTY" "$P/records.json" </dev/null
    cp "$FX/config-personas.json" "$P/.qa/config.json"
  }
  xcheck() { # <label> <jq project> <python project> [handoff arguments]
    local label="$1" a="$2" b="$3" oj op; shift 3
    oj="$(E=jq; ho "$a" "$@")"; op="$(E=python3; ho "$b" "$@")"
    check "cross-engine output identical: $label" "$oj" "$op"
    check "cross-engine handoff.md identical: $label" "$(cksum < "$a/.qa/specs/checkout/auto/handoff.md")" "$(cksum < "$b/.qa/specs/checkout/auto/handoff.md")"
  }
  for shape in done open; do
    XJ="$(E=jq; fin "$shape")"; XP="$(E=python3; fin "$shape")"
    xcheck "clean ($shape)" "$XJ" "$XP"
    xcheck "clean with records ($shape)" "$XJ" "$XP" --records "$HX/records.json"
    mut "$XJ"; mut "$XP"
    xcheck "everything at once ($shape)" "$XJ" "$XP" --records "$XJ/records.json"
    cp "$HX/report-plain.md" "$XJ/.qa/runs/r1/report.md"; cp "$HX/report-plain.md" "$XP/.qa/runs/r1/report.md"
    xcheck "everything at once, no ship section ($shape)" "$XJ" "$XP" --records "$XP/records.json"
    cp "$HX/report-not-ready.md" "$XJ/.qa/runs/r1/report.md"; cp "$HX/report-not-ready.md" "$XP/.qa/runs/r1/report.md"
    xcheck "everything at once, not ready ($shape)" "$XJ" "$XP"
    ed "$XJ/.qa/specs/checkout/auto/journey.json" 'd["state"]="stopped"; d["stop"]={"reason":"audit","detail":"x"}; d["auditViolations"]=["forbidden-decision:D4","forbidden-decision:D2","human-oracle-changed:معيار-٧ \"مقتبس\" \\ $HOME\n`x`","plan-row-removed:C-\u007f-del","safety-setting-changed:a:b","run-config-safety:","nonsense \u0000 code",""]; d["restartedFrom"]=1'
    cp "$XJ/.qa/specs/checkout/auto/journey.json" "$XP/.qa/specs/checkout/auto/journey.json"
    xcheck "everything at once, stopped by the audit ($shape)" "$XJ" "$XP"
    # each engine reads the other's project and still agrees
    oj="$(E=jq; ho "$XP")"; cj="$(cksum < "$XP/.qa/specs/checkout/auto/handoff.md")"
    op="$(E=python3; ho "$XP")"
    check "cross-engine: one project, both engines ($shape)" "$oj|$cj" "$op|$(cksum < "$XP/.qa/specs/checkout/auto/handoff.md")"
  done
  H="$XJ/.qa/specs/checkout/auto/handoff.md"
  check "cross-engine: the big journey really lists things" "$([ "$(items "$H" "Needs a person")" -ge 8 ] && echo many)|$(sed -n 1p "$H")" "many|No written requirements were found for this target. Expected results were taken from the application and need a person."
  check "cross-engine: nothing in the free text was run" "$([ -e "$MARK" ] && echo ran || echo no)" "no"
  XJ="$(E=jq; fin)"; XP="$(E=python3; fin)"
  for v in "handoff nothing-here" "handoff checkout extra" "handoff checkout --reason x" "handoff"; do
    # shellcheck disable=SC2086
    oj="$(E=jq; auto $v --project "$XJ" 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")"
    # shellcheck disable=SC2086
    op="$(E=python3; auto $v --project "$XP" 2>&1 | head -1; echo "rc=${PIPESTATUS[0]}")"
    check "cross-engine refusal identical: $v" "$oj" "$op"
  done
fi

echo "qa-auto-handoff: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
