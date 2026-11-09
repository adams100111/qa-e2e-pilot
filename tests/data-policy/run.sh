#!/usr/bin/env bash
# Dual-engine tests for scripts/data-policy.sh (check / record / list).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../scripts/data-policy.sh"
FX="$DIR/fixtures"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: data-policy: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
q(){ printf '%s' "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(eval(sys.argv[1]),sort_keys=True,separators=(",",":"),ensure_ascii=False))' "$2"; }

run_engine() {
  local E="$1" T out rc P="$FX/config-policy.json"; T="$(mktemp -d)"; TMPDIRS+=("$T")
  chk(){ QA_ENGINE=$E bash "$SH" check "$@"; }

  # contest_not_flagged: whole-word matching; "test" must not hit contest/attestation.
  out="$(chk "$P" "contest attestation latest")"; rc=$?
  check "$E contest_not_flagged rc" "$rc" "0"
  check "$E contest_not_flagged ok" "$(q "$out" 'd["ok"]')" "true"
  # qa_word_flagged: hyphen is a boundary (match); underscore is a word char (no match).
  out="$(chk "$P" "QA-ready team")"; rc=$?
  check "$E qa_word_flagged rc" "$rc" "1"
  check "$E qa_word_flagged violation" "$(q "$out" '[[v["rule"],v["match"]] for v in d["violations"]]')" '[["forbidden-marker","qa"]]'
  out="$(chk "$P" "the qa_lead joined")"; rc=$?
  check "$E underscore_not_boundary rc" "$rc" "0"
  out="$(chk "$P" "Lorem Ipsum dolor")"; rc=$?
  check "$E case_insensitive multiword rc" "$rc" "1"
  # arabic_marker_flagged: substring match.
  out="$(chk "$P" "هذا مشروع اختباري")"; rc=$?
  check "$E arabic_marker_flagged rc" "$rc" "1"
  check "$E arabic_marker_flagged match" "$(q "$out" 'd["violations"][0]["match"]')" '"اختبار"'
  # email_domain_enforced
  out="$(chk "$P" "نورة: noura@innovation-lab.co")"; rc=$?
  check "$E email ok rc" "$rc" "0"
  out="$(chk "$P" "reach faisal@gmail.com now")"; rc=$?
  check "$E email_domain_enforced rc" "$rc" "1"
  check "$E email_domain_enforced violation" "$(q "$out" '[[v["rule"],v["match"]] for v in d["violations"]]')" '[["email-domain","faisal@gmail.com"]]'
  # date_window_enforced
  out="$(chk "$P" "starts 2026-03-15 ends 2025-12-31")"; rc=$?
  check "$E date_window_enforced rc" "$rc" "1"
  check "$E date_window_enforced violation" "$(q "$out" '[[v["rule"],v["match"]] for v in d["violations"]]')" '[["date-window","2025-12-31"]]'
  # no_policy_noop
  out="$(chk "$FX/config-nopolicy.json" "test bot fake 1999-01-01 a@b.c")"; rc=$?
  check "$E no_policy_noop rc" "$rc" "0"
  check "$E no_policy_noop policy" "$(q "$out" '[d["ok"],d["policy"]]')" '[true,"none"]'
  # default markers when forbiddenMarkers unset
  out="$(chk "$FX/config-defaults.json" "an automated Playwright run")"; rc=$?
  check "$E default markers rc" "$rc" "1"
  check "$E default markers" "$(q "$out" '[v["match"] for v in d["violations"]]')" '["automated","playwright"]'
  # JSON input walked recursively
  out="$(chk "$P" @"$FX/input-nested.json")"; rc=$?
  check "$E nested rc" "$rc" "1"
  check "$E nested violations" "$(q "$out" '[v["match"] for v in d["violations"]]')" '["dummy"]'
  # long values truncated to 80
  out="$(chk "$P" "$(printf 'x%.0s' $(seq 1 120)) bot")"; rc=$?
  check "$E truncated value" "$(q "$out" 'len(d["violations"][0]["value"])')" "80"
  # --kind input-validation: date-window and email-domain skipped, markers still enforced (I10)
  out="$(chk "$P" "starts 2025-12-31 reach faisal@gmail.com" --kind input-validation)"; rc=$?
  check "$E kind_input_validation skips date+email rc" "$rc" "0"
  out="$(chk "$P" --kind input-validation "dummy 2025-12-31")"; rc=$?
  check "$E kind_input_validation keeps markers rc" "$rc" "1"
  check "$E kind_input_validation keeps markers rule" "$(q "$out" '[v["rule"] for v in d["violations"]]')" '["forbidden-marker"]'
  out="$(chk "$P" "starts 2025-12-31" --kind business-rule)"; rc=$?
  check "$E other kind still enforces date window" "$rc" "1"
  chk "$P" "x" --kind >/dev/null 2>&1; check "$E --kind without value rc" "$?" "2"
  # masking: sensitive keys / name fields are checked but never echoed (I10)
  out="$(chk "$P" @"$FX/input-sensitive.json")"; rc=$?
  check "$E masked rc" "$rc" "1"
  check "$E masked: secret values never echoed" "$(printf '%s' "$out" | grep -c 'gmail\|2019-01-01\|qa bot')" "0"
  check "$E masked: violations" "$(q "$out" '[[v["rule"],v["value"],v["match"]] for v in d["violations"]]')" \
    '[["forbidden-marker","[masked]","qa"],["forbidden-marker","[masked]","bot"],["email-domain","[masked]","[masked]"],["date-window","[masked]","[masked]"],["forbidden-marker","[masked]","dummy"],["forbidden-marker","Please ignore this dummy entry","dummy"],["email-domain","[masked]","[masked]"]]'
  # usage errors
  chk "$P" >/dev/null 2>&1; check "$E usage rc" "$?" "2"
  QA_ENGINE=$E bash "$SH" bogus >/dev/null 2>&1; check "$E bad subcommand rc" "$?" "2"
  chk "$T/missing.json" "x" >/dev/null 2>&1; check "$E missing config rc" "$?" "2"

  # record_and_list
  QA_ENGINE=$E bash "$SH" record "$T" challenge 41 >/dev/null; rc=$?
  check "$E record rc" "$rc" "0"
  QA_ENGINE=$E bash "$SH" record "$T" idea "7" >/dev/null
  out="$(QA_ENGINE=$E bash "$SH" list "$T")"
  check "$E list entries" "$(q "$out" '[[r["entity"],r["id"]] for r in d]')" '[["challenge","41"],["idea","7"]]'
  check "$E list has at" "$(q "$out" 'all(r["at"] for r in d)')" "true"
  check "$E list empty" "$(QA_ENGINE=$E bash "$SH" list "$T/none" 2>/dev/null | tr -d ' \n')" "[]"
  QA_ENGINE=$E bash "$SH" record "$T/nodir" a 1 >/dev/null 2>&1; check "$E record missing dir rc" "$?" "2"
}

engines=()
command -v jq >/dev/null 2>&1 && engines+=(jq)
command -v python3 >/dev/null 2>&1 && engines+=(python3)
for e in "${engines[@]}"; do run_engine "$e"; done

# parity: byte-identical output across engines.
if [ "${#engines[@]}" -eq 2 ]; then
  P="$FX/config-policy.json"
  for args in "check $P @$FX/input-nested.json" "check $P @$FX/input-sensitive.json" "check $P @$FX/input-sensitive.json --kind input-validation" "check $P مرحبا_qa_فيصل@x.com_2027-01-01_اختبار" "check $FX/config-nopolicy.json x"; do
    a="$(QA_ENGINE=jq bash "$SH" $args 2>&1)"; b="$(QA_ENGINE=python3 bash "$SH" $args 2>&1)"
    check "parity: $args" "$a" "$b"
  done
  PT="$(mktemp -d)"; TMPDIRS+=("$PT")
  printf '[{"entity":"idea","id":"é","at":"2026-01-01T00:00:00Z"}]' > "$PT/created-records.json"
  check "parity list" "$(QA_ENGINE=jq bash "$SH" list "$PT")" "$(QA_ENGINE=python3 bash "$SH" list "$PT")"
fi

echo "data-policy: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
