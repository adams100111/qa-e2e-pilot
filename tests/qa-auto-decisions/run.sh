#!/usr/bin/env bash
# Dual-engine tests for the verbs of qa-kit/scripts/auto.sh that record what an unattended journey
# answered in place of a person: `decide`, `second` and `note`. (The journey's own state machine is
# tested in tests/qa-auto/; this suite is separate so each stays well inside the CI time cap.)
# Every case runs under QA_ENGINE=jq and QA_ENGINE=python3; a final block compares the two engines'
# files and output byte for byte. No live tracker, model or browser. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto.sh"
FX="$DIR/../qa-auto/fixtures"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-auto-decisions: python3 is needed to read results - suite cannot run" >&2; exit 1; }
# The real interpreter, not a version-manager shim (see tests/qa-auto/run.sh).
PY="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"; [ -x "$PY" ] || PY=python3
case "$PY" in */python3) PATH="${PY%/python3}:$PATH"; export PATH ;; esac
pass=0; fail=0
ROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }

E=jq
NOW_DEFAULT="2026-11-27T08:00:00Z"
auto() { QA_ENGINE="$E" QA_AUTO_TEST=1 QA_AUTO_NOW="${NOW:-$NOW_DEFAULT}" QA_AUTO_VERIFY_PLAN_CMD="${VP-true}" bash "$SH" "$@"; }
# jv <file> <python expr over d> — read one value out of a JSON file.
jv() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
# js <json text> <python expr over d>
js() { printf '%s' "$1" | "$PY" -c 'import json,sys
d=json.load(sys.stdin)
v=eval(sys.argv[1])
print(json.dumps(v,sort_keys=True,ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null || echo "<unreadable>"; }
# same <file> <python expr over d> <text>… — `yes` when the expression's value (a string, or a list
# of strings) is exactly the text(s) given, byte for byte, trailing line breaks included.
same() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
v=eval(sys.argv[2])
w=sys.argv[3] if len(sys.argv)==4 else sys.argv[3:]
print("yes" if v==w else "no: "+repr(v))' "$@" 2>/dev/null || echo "<unreadable>"; }
snapshot() { (cd "$1" && find . -type f -exec cksum {} + | LC_ALL=C sort -k3); }
# newj [open|stopped|done|none] — a project for the target `checkout` whose journey is in that
# state. Built once per engine, then copied: `start` is the slow verb.
newj() {
  local want="${1:-open}" tpl="$ROOT/tpl-$E-${1:-open}" P
  if [ ! -d "$tpl" ]; then
    P="$(mktemp -d "$ROOT/p.XXXXXX")"; mkdir -p "$P/.qa"; cp "$FX/config-local.json" "$P/.qa/config.json"
    case "$want" in
      none) ;;
      *) auto start checkout --project "$P" >/dev/null 2>&1 ;;
    esac
    case "$want" in
      stopped) auto stop checkout --project "$P" --reason step-failed --detail "the application did not answer" >/dev/null 2>&1 ;;
      done) "$PY" -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["state"]="done"; d["endedAt"]="2026-11-27T09:00:00Z"
for s in d["steps"]: s["state"]="done"
json.dump(d,open(p,"w"))' "$P/.qa/specs/checkout/auto/journey.json" ;;
    esac
    mv "$P" "$tpl"
  fi
  P="$(mktemp -d "$ROOT/p.XXXXXX")"; rmdir "$P"; cp -Rp "$tpl" "$P"
  printf '%s' "$P"
}
# dec <project> <class> <confidence> <evidence> [more flags…] — one plain decision.
dec() {
  local P="$1" c="$2" conf="$3" ev="$4"; shift 4
  auto decide checkout --project "$P" --step spec --class "$c" --question "أي الشاشات تدخل في النطاق؟" --answer "شاشات السلة والدفع" --evidence "$ev" --confidence "$conf" "$@"
}

# Free text that a shell, jq or python would mangle if it were ever pasted into a program:
# quotes, backslashes, a line break, a tab, $, backticks, a command substitution, an escape that
# must stay six characters, a percent directive, U+007F, Arabic and an emoji.
MARK="$ROOT/must-not-exist"
NASTY="$(printf '%s\n%s\t%s' "--قيمة \"مزدوجة\" و'مفردة' \\ \\\\n \\u0041 \$HOME \${PATH} \`touch $MARK\` \$(touch $MARK)" "سطر ثانٍ: 15% ضريبة %s %d 🧾 | jq '.[]' ; touch $MARK #" "$(printf 'end\177.')")"
NASTY_NL="$NASTY
"

# One python process answers jv, js and ed from here on (see tests/qa-auto/lib.sh).
# shellcheck source=/dev/null
. "$DIR/../qa-auto/lib.sh"
run_engine() {
  E="$1"
  local P D N J out rc before c f i

  # ---- decide_appends_with_id ----
  P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"; J="$P/.qa/specs/checkout/auto/journey.json"
  before="$(cksum "$J")"
  out="$(auto decide checkout --project "$P" --step spec --class scope --question "Which screens are in scope?" --answer "Cart and payment" --evidence "routes/web.php:12" --confidence high 2>&1)"; rc=$?
  check "$E decide_appends_with_id: rc and id" "$rc|$out" "0|D1"
  check "$E decisions.json is a bare array of one J4 record" "$(jv "$D" 'd')" '[{"answer": "Cart and payment", "assumption": true, "class": "scope", "confidence": "high", "criteria": [], "evidence": "routes/web.php:12", "id": "D1", "needsPerson": false, "question": "Which screens are in scope?", "second": null, "secondReason": null, "step": "spec"}]'
  out="$(auto decide checkout --project "$P" --step scenarios --class expected --question "ما الإجمالي المتوقع؟" --answer "115.00 ريال" --evidence "app/Services/CartTotals.php:40" --confidence low --criteria " C-001, ,C-002 ,," 2>&1)"; rc=$?
  check "$E the second decision is D2" "$rc|$out" "0|D2"
  check "$E the first decision is kept, the second appended" "$(jv "$D" '[len(d),d[0]["id"],d[1]["id"],d[1]["step"],d[1]["class"],d[1]["answer"]]')" '[2, "D1", "D2", "scenarios", "expected", "115.00 ريال"]'
  check "$E --criteria is stored as given, trimmed, without empties" "$(jv "$D" 'd[1]["criteria"]')" '["C-001", "C-002"]'
  check "$E low confidence alone does not need a person" "$(jv "$D" '[d[1]["confidence"],d[1]["needsPerson"],d[1]["assumption"],d[1]["second"]]')" '["low", false, true, null]'
  check "$E J4 keys exactly" "$(jv "$D" '",".join(sorted(d[1].keys()))')" "answer,assumption,class,confidence,criteria,evidence,id,needsPerson,question,second,secondReason,step"
  check "$E decide writes only decisions.json" "$(ls "$P/.qa/specs/checkout/auto" | LC_ALL=C sort | tr '\n' ' ')|$(cksum "$J")|$(cd "$P" && find . -type f -not -path './.qa/specs/checkout/auto/*' | tr '\n' ' ')" "baseline.json decisions.json journey.json |$before|./.qa/config.json "
  check "$E the file is pretty-printed with sorted keys" "$(sed -n '1,3p' "$D" | tr '\n' '|')" '[|  {|    "answer": "Cart and payment",|'
  # a low-confidence decision that has had no second look counts for a person (the rule `handoff` uses)
  check "$E status counts the low-confidence decision that had no second look" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "1"
  # the next id follows the highest one, not the count
  printf '[{"id":"D7","needsPerson":false},{"id":"note"},{"id":"D2"}]\n' > "$D"
  out="$(dec "$P" roles high "config/permission.php:3" 2>&1)"
  check "$E the next id follows the highest id in the file" "$out|$(jv "$D" '[x["id"] for x in d]')" 'D8|["D7", "note", "D2", "D8"]'
  # every decidable class is accepted
  P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"; i=0
  for c in roles surface-access scope role-overrides journeys inputs expected gaps; do
    i=$((i + 1))
    out="$(dec "$P" "$c" high "docs/requirements.md:$i" 2>&1)"; rc=$?
    check "$E decidable class $c is recorded" "$rc|$out" "0|D$i"
  done
  check "$E eight classes recorded in order" "$(jv "$D" '",".join(x["class"] for x in d)')" "roles,surface-access,scope,role-overrides,journeys,inputs,expected,gaps"
  for c in constitution spec scenarios analyze run verify; do
    auto decide checkout --project "$P" --step "$c" --class gaps --question q --answer a --evidence e --confidence low >/dev/null 2>&1
    check "$E step $c is accepted" "$?" "0"
  done

  # ---- decide_refuses_each_forbidden_class ----
  P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"
  dec "$P" scope high "routes/web.php:12" >/dev/null 2>&1
  before="$(snapshot "$P")"
  for c in seed exclusion crawl-only oracle-human safety known-defect; do
    out="$(dec "$P" "$c" high "routes/web.php:12" 2>&1)"; rc=$?
    check "$E decide_refuses_each_forbidden_class: $c" "$rc|$out" "1|auto: $c is never decided by an unattended journey"
  done
  check "$E a refused class writes nothing" "$(snapshot "$P")" "$before"

  # ---- evidence_none_needs_person ----
  out="$(dec "$P" expected high none 2>&1)"; rc=$?
  check "$E evidence_none_needs_person: rc and id" "$rc|$out" "0|D2"
  check "$E evidence none is stored as null and needs a person" "$(jv "$D" '[d[1]["evidence"],d[1]["needsPerson"],d[1]["confidence"],d[1]["assumption"]]')" '[null, true, "high", true]'
  # m4: the word none in any letter case, blanks around it ignored, means no evidence
  dec "$P" expected high None >/dev/null 2>&1; dec "$P" expected high "none " >/dev/null 2>&1; dec "$P" expected high "  NONE	" >/dev/null 2>&1
  check "$E none in any letter case, with blanks around it, means no evidence" "$(jv "$D" '[[x["evidence"],x["needsPerson"]] for x in d[2:]]')" '[[null, true], [null, true], [null, true]]'
  dec "$P" expected high "none of the routes mention it" >/dev/null 2>&1; dec "$P" expected high "nonesuch.php:3" >/dev/null 2>&1
  check "$E a text that only starts with none is evidence" "$(jv "$D" '[[x["evidence"],x["needsPerson"]] for x in d[5:]]')" '[["none of the routes mention it", false], ["nonesuch.php:3", false]]'
  check "$E status counts the decisions that need a person" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "4"
  for c in "" " " "	" "$(printf ' \n\t ')"; do
    out="$(dec "$P" expected high "$c" 2>&1)"; rc=$?
    check "$E an evidence value that is empty after trimming is a usage error [$(printf '%s' "$c" | od -An -c | tr -d ' \n')]" "$rc|$(printf '%s\n' "$out" | sed -n 1p)" "2|auto: --evidence cannot be empty; pass the word none when there is no evidence"
  done
  check "$E an empty evidence value adds no decision" "$(jv "$D" 'len(d)')" "7"

  # ---- usage ----
  before="$(snapshot "$P")"
  for f in --step --class --question --answer --evidence --confidence; do
    set -- --step spec --class scope --question q --answer a --evidence e --confidence high
    local args=()
    while [ "$#" -gt 0 ]; do [ "$1" = "$f" ] || args+=("$1" "$2"); shift 2; done
    auto decide checkout --project "$P" "${args[@]}" >/dev/null 2>&1
    check "$E decide without $f is usage" "$?" "2"
  done
  auto decide checkout --project "$P" --step spec --class budget --question q --answer a --evidence e --confidence high >/dev/null 2>&1
  check "$E an unknown class is usage" "$?" "2"
  auto decide checkout --project "$P" --step spec --class "scope role-overrides" --question q --answer a --evidence e --confidence high >/dev/null 2>&1
  check "$E two class names in one value is usage" "$?" "2"
  auto decide checkout --project "$P" --step deploy --class scope --question q --answer a --evidence e --confidence high >/dev/null 2>&1
  check "$E an unknown step is usage" "$?" "2"
  auto decide checkout --project "$P" --step spec --class scope --question q --answer a --evidence e --confidence medium >/dev/null 2>&1
  check "$E a confidence other than high or low is usage" "$?" "2"
  auto decide checkout --project "$P" --step spec --class scope --question "" --answer a --evidence e --confidence high >/dev/null 2>&1
  check "$E an empty question is usage" "$?" "2"
  auto decide checkout --project "$P" --step spec --class scope --question q --answer "  " --evidence e --confidence high >/dev/null 2>&1
  check "$E a blank answer is usage" "$?" "2"
  auto decide checkout --project "$P" --step spec --class scope --question q --answer a --evidence "" --confidence high >/dev/null 2>&1
  check "$E an empty evidence is usage (the word none is required)" "$?" "2"
  auto decide checkout --project "$P" --step spec --class scope --question q --answer a --evidence e --confidence high --force >/dev/null 2>&1
  check "$E an unknown flag is usage" "$?" "2"
  auto decide checkout extra --project "$P" --step spec --class scope --question q --answer a --evidence e --confidence high >/dev/null 2>&1
  check "$E an extra word is usage" "$?" "2"
  auto decide checkout --project "$P" --step spec --class seed --question q --answer a --evidence e --confidence sure >/dev/null 2>&1
  check "$E a usage error comes before the class refusal" "$?" "2"
  auto second checkout --project "$P" >/dev/null 2>&1;                               check "$E second without an id is usage" "$?" "2"
  auto second checkout D1 --project "$P" --reason r >/dev/null 2>&1;                 check "$E second without a verdict is usage" "$?" "2"
  auto second checkout D1 maybe --project "$P" --reason r >/dev/null 2>&1;           check "$E a verdict other than stands or ask is usage" "$?" "2"
  auto second checkout D1 stands --project "$P" >/dev/null 2>&1;                     check "$E second without --reason is usage" "$?" "2"
  auto second checkout D1 ask --project "$P" --reason "" >/dev/null 2>&1;            check "$E an empty reason is usage" "$?" "2"
  auto second checkout D1 ask again --project "$P" --reason r >/dev/null 2>&1;       check "$E second with a third word is usage" "$?" "2"
  auto second checkout D1 --unavailable --project "$P" >/dev/null 2>&1;              check "$E --unavailable with an id is usage" "$?" "2"
  auto second checkout --unavailable --reason r --project "$P" >/dev/null 2>&1;      check "$E --unavailable with a reason is usage" "$?" "2"
  auto note checkout --project "$P" --text "x" >/dev/null 2>&1;                      check "$E note without --kind is usage" "$?" "2"
  auto note checkout --project "$P" --kind seed-not-run >/dev/null 2>&1;             check "$E note without --text is usage" "$?" "2"
  auto note checkout --project "$P" --kind reminder --text "x" >/dev/null 2>&1;      check "$E an unknown note kind is usage" "$?" "2"
  auto note checkout --project "$P" --kind seed-not-run --text "" >/dev/null 2>&1;   check "$E an empty note text is usage" "$?" "2"
  auto note checkout --project "$P" --kind seed-not-run --text x --at now >/dev/null 2>&1; check "$E note with an unknown flag is usage" "$?" "2"
  check "$E usage errors write nothing" "$(snapshot "$P")" "$before"

  # ---- decide_refused_on_closed_journey ----
  for c in stopped done; do
    P="$(newj "$c")"
    before="$(snapshot "$P")"
    out="$(dec "$P" scope high "routes/web.php:12" 2>&1)"; rc=$?
    check "$E decide_refused_on_closed_journey ($c)" "$rc|$out" "1|auto: no open journey for checkout"
    out="$(auto second checkout D1 ask --reason "no source" --project "$P" 2>&1)"; rc=$?
    check "$E second refused on a $c journey" "$rc|$out" "1|auto: no open journey for checkout"
    out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
    check "$E second --unavailable refused on a $c journey" "$rc|$out" "1|auto: no open journey for checkout"
    out="$(auto note checkout --kind seed-not-run --text "The seed command was not run." --project "$P" 2>&1)"; rc=$?
    check "$E note refused on a $c journey" "$rc|$out" "1|auto: no open journey for checkout"
    check "$E verbs on a $c journey write nothing" "$(snapshot "$P")" "$before"
  done
  P="$(newj none)"
  out="$(dec "$P" scope high "routes/web.php:12" 2>&1)"; rc=$?
  check "$E decide without a journey" "$rc|$out" "1|auto: no journey for checkout"
  out="$(auto second checkout D1 stands --reason "cited" --project "$P" 2>&1)"; rc=$?
  check "$E second without a journey" "$rc|$out" "1|auto: no journey for checkout"
  out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
  check "$E second --unavailable without a journey" "$rc|$out" "1|auto: no journey for checkout"
  out="$(auto note checkout --kind check-left-out --text "One check was left out." --project "$P" 2>&1)"; rc=$?
  check "$E note without a journey" "$rc|$out" "1|auto: no journey for checkout"
  check "$E verbs without a journey write nothing" "$([ -e "$P/.qa/specs" ] && echo yes || echo no)" "no"
  # a forbidden class on a journey that is not open: the journey is named first
  P="$(newj stopped)"
  out="$(dec "$P" seed high "x" 2>&1)"; rc=$?
  check "$E a closed journey is reported before the class" "$rc|$out" "1|auto: no open journey for checkout"

  # ---- second_ask_sets_needs_person ----
  P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"; J="$P/.qa/specs/checkout/auto/journey.json"
  dec "$P" scope high "routes/web.php:12" >/dev/null 2>&1      # D1
  dec "$P" expected high none >/dev/null 2>&1                  # D2 (needs a person from the start)
  dec "$P" journeys low "resources/js/cart.js:8" >/dev/null 2>&1   # D3
  dec "$P" inputs low "app/Rules/Vat.php:5" >/dev/null 2>&1    # D4
  before="$(cksum "$J")"
  out="$(auto second checkout D1 ask --reason "The route file does not show the refund screen." --project "$P" 2>&1)"; rc=$?
  check "$E second_ask_sets_needs_person: output" "$rc|$out" '0|{"id":"D1","needsPerson":true,"second":"ask"}'
  check "$E ask is recorded with its reason" "$(jv "$D" '[d[0]["second"],d[0]["needsPerson"],d[0]["secondReason"]]')" '["ask", true, "The route file does not show the refund screen."]'
  check "$E ask changes nothing else in the decision" "$(jv "$D" '[d[0]["answer"],d[0]["evidence"],d[0]["confidence"],d[0]["assumption"],d[0]["criteria"],len(d)]')" '["شاشات السلة والدفع", "routes/web.php:12", "high", true, [], 4]'
  check "$E second leaves journey.json alone" "$(cksum "$J")" "$before"

  # ---- second_stands_never_clears ----
  out="$(auto second checkout D2 stands --reason "The value matches the screen." --project "$P" 2>&1)"; rc=$?
  check "$E second_stands_never_clears: output" "$rc|$out" '0|{"id":"D2","needsPerson":true,"second":"stands"}'
  check "$E stands is recorded and the decision still needs a person" "$(jv "$D" '[d[1]["second"],d[1]["needsPerson"],d[1]["secondReason"]]')" '["stands", true, "The value matches the screen."]'
  out="$(auto second checkout D3 stands --reason "Cited line agrees." --project "$P" 2>&1)"; rc=$?
  check "$E stands on a decision that needed nobody" "$rc|$out" '0|{"id":"D3","needsPerson":false,"second":"stands"}'
  # a second verdict: only stands -> ask replaces the first
  out="$(auto second checkout D1 stands --reason "Looks fine after all." --project "$P" 2>&1)"; rc=$?
  check "$E ask is never replaced by stands" "$rc|$out|$(jv "$D" '[d[0]["second"],d[0]["needsPerson"],d[0]["secondReason"]]')" '0|{"id":"D1","needsPerson":true,"second":"ask"}|["ask", true, "The route file does not show the refund screen."]'
  auto second checkout D1 ask --reason "Another reason." --project "$P" >/dev/null 2>&1
  check "$E a repeated ask keeps the first reason" "$?|$(jv "$D" 'd[0]["secondReason"]')" "0|The route file does not show the refund screen."
  auto second checkout D3 stands --reason "Checked twice." --project "$P" >/dev/null 2>&1
  check "$E a repeated stands keeps the first reason" "$?|$(jv "$D" '[d[2]["second"],d[2]["secondReason"]]')" '0|["stands", "Cited line agrees."]'
  out="$(auto second checkout D3 ask --reason "The cited line is about another screen." --project "$P" 2>&1)"; rc=$?
  check "$E stands is replaced by ask" "$rc|$out|$(jv "$D" '[d[2]["second"],d[2]["needsPerson"],d[2]["secondReason"]]')" '0|{"id":"D3","needsPerson":true,"second":"ask"}|["ask", true, "The cited line is about another screen."]'
  # D1 and D3 were sent to a person, D2 has no evidence, D4 is low confidence with no second look
  check "$E status counts every decision for a person" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "4"
  # an id that is not there
  before="$(snapshot "$P")"
  out="$(auto second checkout D9 ask --reason "x" --project "$P" 2>&1)"; rc=$?
  check "$E an unknown decision id is refused" "$rc|$out" "1|auto: no decision D9"
  out="$(auto second checkout d1 stands --reason "x" --project "$P" 2>&1)"; rc=$?
  check "$E decision ids are matched exactly" "$rc|$out" "1|auto: no decision d1"
  check "$E an unknown id writes nothing" "$(snapshot "$P")" "$before"
  P="$(newj)"
  out="$(auto second checkout D1 stands --reason "x" --project "$P" 2>&1)"; rc=$?
  check "$E second with no decisions at all" "$rc|$out|$([ -e "$P/.qa/specs/checkout/auto/decisions.json" ] && echo made || echo none)" "1|auto: no decision D1|none"

  # ---- second_unavailable_marks_low_confidence ----
  P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"; J="$P/.qa/specs/checkout/auto/journey.json"
  dec "$P" scope high "routes/web.php:12" >/dev/null 2>&1          # D1 high
  dec "$P" journeys low "resources/js/cart.js:8" >/dev/null 2>&1   # D2 low
  dec "$P" inputs low "app/Rules/Vat.php:5" >/dev/null 2>&1        # D3 low, second look stands
  dec "$P" expected low "app/Services/CartTotals.php:40" >/dev/null 2>&1   # D4 low
  dec "$P" expected low none >/dev/null 2>&1                       # D5 low, already for a person
  auto second checkout D3 stands --reason "Boundaries are the documented ones." --project "$P" >/dev/null 2>&1
  out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
  check "$E second_unavailable_marks_low_confidence: output" "$rc|$out" '0|{"marked":["D2","D4"]}'
  check "$E low confidence without a second look now needs a person" "$(jv "$D" '[x["needsPerson"] for x in d]')" "[false, true, false, true, true]"
  check "$E --unavailable records no verdict on the decisions" "$(jv "$D" '[[x["second"],x["secondReason"]] for x in d if x["id"]!="D3"]')" "[[null, null], [null, null], [null, null], [null, null]]"
  check "$E journey.json records the second look as unavailable" "$(jv "$J" '[d["secondLook"],d["state"],len(d["steps"])]')" '["unavailable", "open", 6]'
  check "$E status prints secondLook and the count" "$(js "$(auto status checkout --project "$P" 2>/dev/null)" '[d["secondLook"],d["needsPerson"]]')" '["unavailable", 3]'
  before="$(snapshot "$P")"
  out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
  check "$E --unavailable again marks nothing new" "$rc|$out" '0|{"marked":[]}'
  check "$E --unavailable again changes no file" "$(snapshot "$P")" "$before"
  dec "$P" gaps low "analysis.md:14" >/dev/null 2>&1               # D6 low, after the next step
  out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
  check "$E --unavailable after a later step marks the new decision" "$rc|$out|$(jv "$D" 'd[5]["needsPerson"]')" '0|{"marked":["D6"]}|true'
  # item 28: once the second look was recorded as unavailable, no decision can be let stand
  before="$(snapshot "$P")"
  out="$(auto second checkout D2 stands --reason "Seen later by a reviewer agent." --project "$P" 2>&1)"; rc=$?
  check "$E second_stands_refused_after_unavailable" "$rc|$out" "1|auto: the second look was recorded as unavailable; a decision cannot be let stand"
  check "$E second_stands_refused_after_unavailable changes no file" "$(snapshot "$P")" "$before"
  check "$E the refused decision still needs a person" "$(jv "$D" '[d[1]["second"],d[1]["needsPerson"]]')" '[null, true]'
  out="$(auto second checkout D1 stands --reason "x" --project "$P" 2>&1)"; rc=$?
  check "$E stands is refused for a high-confidence decision too" "$rc|$out" "1|auto: the second look was recorded as unavailable; a decision cannot be let stand"
  out="$(auto second checkout D99 stands --reason "x" --project "$P" 2>&1)"; rc=$?
  check "$E stands for an unknown decision is refused the same way" "$rc|$out" "1|auto: the second look was recorded as unavailable; a decision cannot be let stand"
  out="$(auto second checkout D2 ask --reason "A person should look." --project "$P" 2>&1)"; rc=$?
  check "$E ask is still taken after --unavailable" "$rc|$out" '0|{"id":"D2","needsPerson":true,"second":"ask"}'
  P="$(newj)"; J="$P/.qa/specs/checkout/auto/journey.json"
  out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
  check "$E --unavailable with no decisions" "$rc|$out|$(jv "$J" 'd["secondLook"]')|$([ -e "$P/.qa/specs/checkout/auto/decisions.json" ] && echo made || echo none)" '0|{"marked":[]}|unavailable|none'
  check "$E a journey without --unavailable has no secondLook key" "$(jv "$(newj)/.qa/specs/checkout/auto/journey.json" '"secondLook" in d')" "false"

  # ---- note ----
  P="$(newj)"; N="$P/.qa/specs/checkout/auto/notes.json"; D="$P/.qa/specs/checkout/auto/decisions.json"
  out="$(NOW="2026-11-27T08:10:00Z" auto note checkout --kind seed-not-run --text "The command php artisan db:seed was proposed and not run." --project "$P" 2>&1)"; rc=$?
  check "$E note: rc and id" "$rc|$out" "0|N1"
  check "$E notes.json is a bare array of {at,id,kind,text}" "$(jv "$N" 'd')" '[{"at": "2026-11-27T08:10:00Z", "id": "N1", "kind": "seed-not-run", "text": "The command php artisan db:seed was proposed and not run."}]'
  out="$(NOW="2026-11-27T08:25:00Z" auto note checkout --kind check-left-out --text "لم يُدرج فحص رسالة الخطأ عند الدفع لأنه يؤكد عطلاً في التطبيق." --project "$P" 2>&1)"; rc=$?
  check "$E the second note is N2" "$rc|$out|$(jv "$N" '[len(d),d[1]["id"],d[1]["kind"],d[1]["at"]]')" '0|N2|[2, "N2", "check-left-out", "2026-11-27T08:25:00Z"]'
  check "$E a note makes no decision and needs nobody by itself" "$([ -e "$D" ] && echo made || echo none)|$(js "$(auto status checkout --project "$P" 2>/dev/null)" 'd["needsPerson"]')" "none|0"
  dec "$P" scope high "routes/web.php:12" >/dev/null 2>&1
  check "$E decisions and notes are separate files" "$(jv "$D" 'len(d)')|$(jv "$N" 'len(d)')|$(ls "$P/.qa/specs/checkout/auto" | LC_ALL=C sort | tr '\n' ' ')" "1|2|baseline.json decisions.json journey.json notes.json "
  # a new journey takes the old one's decisions and notes to history
  auto start checkout --project "$P" --restart >/dev/null 2>&1
  check "$E a restart moves decisions and notes to history" "$(ls "$P/.qa/specs/checkout/auto/history/1" | LC_ALL=C sort | tr '\n' ' ')|$(ls "$P/.qa/specs/checkout/auto" | LC_ALL=C sort | tr '\n' ' ')" "baseline.json decisions.json journey.json notes.json |baseline.json history journey.json "

  # ---- free text is stored exactly as given ----
  P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"; N="$P/.qa/specs/checkout/auto/notes.json"
  out="$(auto decide checkout --project "$P" --step spec --class scope --question "$NASTY" --answer "$NASTY_NL" --evidence "$NASTY" --confidence low --criteria "C-\"1\",\$(touch $MARK), C-\\2 ,\`id\`" 2>&1)"; rc=$?
  check "$E free text: decide rc and id" "$rc|$out" "0|D1"
  check "$E free text: the question round-trips" "$(same "$D" 'd[0]["question"]' "$NASTY")" "yes"
  check "$E free text: the answer round-trips, final line break kept" "$(same "$D" 'd[0]["answer"]' "$NASTY_NL")" "yes"
  check "$E free text: the evidence round-trips" "$(same "$D" 'd[0]["evidence"]' "$NASTY")" "yes"
  check "$E free text: criteria ids round-trip" "$(same "$D" 'd[0]["criteria"]' 'C-"1"' "\$(touch $MARK)" 'C-\2' '`id`')" "yes"
  out="$(auto second checkout D1 ask --reason "$NASTY_NL" --project "$P" 2>&1)"; rc=$?
  check "$E free text: the reason round-trips" "$rc|$out|$(same "$D" 'd[0]["secondReason"]' "$NASTY_NL")" '0|{"id":"D1","needsPerson":true,"second":"ask"}|yes'
  check "$E free text: the decision's own text is untouched by second" "$(same "$D" 'd[0]["question"]' "$NASTY")/$(same "$D" 'd[0]["answer"]' "$NASTY_NL")" "yes/yes"
  auto second checkout --unavailable --project "$P" >/dev/null 2>&1
  check "$E free text: untouched by --unavailable" "$(same "$D" 'd[0]["evidence"]' "$NASTY")" "yes"
  out="$(auto note checkout --kind check-left-out --text "$NASTY_NL" --project "$P" 2>&1)"; rc=$?
  check "$E free text: the note text round-trips" "$rc|$out|$(same "$N" 'd[0]["text"]' "$NASTY_NL")" "0|N1|yes"
  out="$(auto decide checkout --project "$P" --step spec --class scope --question "--question" --answer "--project" --evidence "--evidence none" --confidence high 2>&1)"; rc=$?
  check "$E values that look like flags are kept as text" "$rc|$out|$(jv "$D" '[d[1]["question"],d[1]["answer"],d[1]["evidence"],d[1]["needsPerson"]]')" '0|D2|["--question", "--project", "--evidence none", false]'
  out="$(auto second checkout 'D1" or true' ask --reason x --project "$P" 2>&1)"; rc=$?
  check "$E a decision id is data, never part of a program" "$rc|$out" '1|auto: no decision D1" or true'
  check "$E no text was run as a command" "$([ -e "$MARK" ] && echo ran || echo clean)" "clean"

  # ---- a decisions file that is not an array is refused, never overwritten ----
  for c in '{"decisions":[]}' '[{"id":"D1"' '[] []'; do
    P="$(newj)"; D="$P/.qa/specs/checkout/auto/decisions.json"; printf '%s\n' "$c" > "$D"; before="$(snapshot "$P")"
    out="$(dec "$P" scope high "routes/web.php:12" 2>&1)"; rc=$?
    check "$E decide on a broken decisions.json [$c]" "$rc|$out" "1|auto: decisions.json for checkout is not readable"
    out="$(auto second checkout D1 ask --reason x --project "$P" 2>&1)"; rc=$?
    check "$E second on a broken decisions.json [$c]" "$rc|$out" "1|auto: decisions.json for checkout is not readable"
    out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
    check "$E second --unavailable on a broken decisions.json [$c]" "$rc|$out" "1|auto: decisions.json for checkout is not readable"
    check "$E a broken decisions.json is left as it is [$c]" "$(snapshot "$P")" "$before"
  done
  # ---- a write that fails stops the verb, with one line and no id ----
  if [ "$(id -u)" != 0 ]; then
    P="$(newj)"; dec "$P" journeys low "resources/js/cart.js:8" >/dev/null 2>&1
    chmod 555 "$P/.qa/specs/checkout/auto"; before="$(snapshot "$P")"
    out="$(dec "$P" scope high "routes/web.php:12" 2>&1)"; rc=$?
    check "$E decide on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/decisions.json"
    out="$(auto note checkout --kind seed-not-run --text "The seed command was not run." --project "$P" 2>&1)"; rc=$?
    check "$E note on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/notes.json"
    out="$(auto second checkout D1 ask --reason "no source" --project "$P" 2>&1)"; rc=$?
    check "$E second on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/decisions.json"
    out="$(auto second checkout --unavailable --project "$P" 2>&1)"; rc=$?
    check "$E second --unavailable on a journey directory it cannot write" "$rc|$out" "1|auto: could not write .qa/specs/checkout/auto/decisions.json"
    check "$E the failed writes changed nothing" "$(snapshot "$P")" "$before"
    chmod 755 "$P/.qa/specs/checkout/auto"
  fi
  P="$(newj)"; N="$P/.qa/specs/checkout/auto/notes.json"; printf '{"notes":[]}\n' > "$N"; before="$(snapshot "$P")"
  out="$(auto note checkout --kind seed-not-run --text "x" --project "$P" 2>&1)"; rc=$?
  check "$E note on a broken notes.json" "$rc|$out|$([ "$(snapshot "$P")" = "$before" ] && echo same || echo changed)" "1|auto: notes.json for checkout is not readable|same"
}

command -v jq >/dev/null 2>&1 && run_engine jq
run_engine python3

# ---- both engines: byte-identical files and output ----
if command -v jq >/dev/null 2>&1; then
  XJ="$(E=jq; newj)"; XP="$(E=python3; newj)"
  # the two journeys were started by different engines; make them one and the same file set
  rm -rf "$XP"; cp -Rp "$XJ" "$XP"
  # crossd <label> <verb args…> — run the verb under both engines and compare everything it touches.
  crossd() {
    local label="$1" oj op f; shift
    oj="$(E=jq; auto "$@" --project "$XJ" 2>&1; echo "rc=$?")"
    op="$(E=python3; auto "$@" --project "$XP" 2>&1; echo "rc=$?")"
    check "cross-engine output identical: $label" "$oj" "$op"
    for f in decisions.json notes.json journey.json; do
      check "cross-engine $f identical after: $label" "$(cat "$XJ/.qa/specs/checkout/auto/$f" 2>/dev/null | cksum)" "$(cat "$XP/.qa/specs/checkout/auto/$f" 2>/dev/null | cksum)"
    done
  }
  crossd "decide plain" decide checkout --step spec --class scope --question "Which screens?" --answer "Cart" --evidence "routes/web.php:12" --confidence high
  crossd "decide nasty" decide checkout --step scenarios --class expected --question "$NASTY" --answer "$NASTY_NL" --evidence "$NASTY" --confidence low --criteria " C-001 ,,C-\"2\", ج-٣ "
  crossd "decide no evidence" decide checkout --step scenarios --class inputs --question "ما القيم الحدّية؟" --answer "0، 0.005، 999999.99" --evidence none --confidence low
  crossd "decide control characters" decide checkout --step analyze --class gaps --question "$(printf 'a\001b\033c\177d\342\200\250e')" --answer "</script> & < >" --evidence "x" --confidence low --criteria ""
  crossd "decide forbidden" decide checkout --step spec --class safety --question q --answer a --evidence e --confidence high
  crossd "decide usage" decide checkout --step spec --class nothing --question q --answer a --evidence e --confidence high
  crossd "second ask" second checkout D1 ask --reason "$NASTY_NL"
  crossd "second stands after ask" second checkout D1 stands --reason "fine"
  crossd "second stands" second checkout D3 stands --reason "السبب: \"موثّق\" \\ \$x"
  crossd "second unknown" second checkout D99 ask --reason x
  crossd "second unavailable" second checkout --unavailable
  crossd "second unavailable again" second checkout --unavailable
  crossd "second ask after stands" second checkout D3 ask --reason "$NASTY"
  crossd "second stands after unavailable" second checkout D2 stands --reason "late"
  crossd "note seed" note checkout --kind seed-not-run --text "$NASTY_NL"
  crossd "note left out" note checkout --kind check-left-out --text "$(printf 'tab\there 🧾\177')"
  crossd "note usage" note checkout --kind other --text x
  crossd "status" status checkout
  crossd "stop" stop checkout --reason step-failed --detail "paused"
  crossd "decide closed" decide checkout --step spec --class scope --question q --answer a --evidence e --confidence high
  crossd "note closed" note checkout --kind seed-not-run --text x
  crossd "second closed" second checkout --unavailable
  check "cross-engine: the journeys really hold decisions" "$(jv "$XP/.qa/specs/checkout/auto/decisions.json" '[len(d),sum(1 for x in d if x["needsPerson"])]')/$(jv "$XP/.qa/specs/checkout/auto/notes.json" 'len(d)')" "[4, 4]/2"
  check "cross-engine: no text was run as a command" "$([ -e "$MARK" ] && echo ran || echo clean)" "clean"
  # a file written by one engine is read and extended by the other
  E=python3 auto resume checkout --project "$XJ" >/dev/null 2>&1; E=jq auto resume checkout --project "$XP" >/dev/null 2>&1
  oj="$(E=python3; auto decide checkout --project "$XJ" --step run --class gaps --question "$NASTY" --answer a --evidence e --confidence low 2>&1)"
  op="$(E=jq; auto decide checkout --project "$XP" --step run --class gaps --question "$NASTY" --answer a --evidence e --confidence low 2>&1)"
  check "cross-engine: engines swapped, same id" "$oj|$op" "D5|D5"
  check "cross-engine: engines swapped, same decisions.json" "$(cksum < "$XJ/.qa/specs/checkout/auto/decisions.json")" "$(cksum < "$XP/.qa/specs/checkout/auto/decisions.json")"
fi

echo "qa-auto-decisions: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
