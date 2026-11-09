#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/oracle-confirm.sh (render + apply).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/oracle-confirm.sh"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: oracle-confirm: python3 needed for assertions" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
pyj(){ python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

CHECKLIST='[
 {"id":"A1","surface":"/rates","kind":"computed-logic","tags":[],"action":"compute","fixture":{"actionInput":{"q":3},"expect":{"path":"total","value":"0.003","tolerance":0,"oracleSource":"llm-suggested","rule":"fee = rate x qty"}}},
 {"id":"A2","surface":"/rates","kind":"computed-logic","tags":[],"action":"compute","fixture":{"actionInput":{"q":5},"expect":{"path":"total","value":"0.005","tolerance":0,"oracleSource":"llm-suggested","rule":"fee = rate x qty"}}},
 {"id":"B1","surface":"/vat","kind":"business-rule","tags":[],"action":"compute","fixture":{"actionInput":{"amount":100},"expect":{"path":"vat","value":15,"tolerance":0.01,"oracleSource":"llm-suggested"}}},
 {"id":"H1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"human","rule":"done"}}},
 {"id":"S1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"spec","citation":"s.md:1","rule":"done2"}}},
 {"id":"D1","surface":"/x","kind":"empty-state","tags":[],"action":"a"},
 {"id":"AR1","surface":"/ar","kind":"business-rule","tags":[],"action":"احسب","fixture":{"actionInput":{"اسم":"فيصل الحربي"},"expect":{"path":"المبلغ","value":"١٢٣ ريال","tolerance":0,"oracleSource":"llm-suggested","rule":"رسوم الخدمة"}}}
]'

run_engine() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf '%s' "$CHECKLIST" > "$T/c.json"
  QA_ENGINE=$E bash "$SH" render "$T/c.json" "$T/o.html" > "$T/r.out"; check "$E render rc" "$?" "0"
  check "$E render_groups_by_rule: group count" "$(pyj 'd["groups"]' < "$T/r.out")" "3"
  check "$E render_groups_by_rule: rows count" "$(pyj 'd["rows"]' < "$T/r.out")" "4"
  grep -q 'fee = rate x qty' "$T/o.html"; check "$E render_groups_by_rule: rule in html" "$?" "0"
  grep -q 'business-rule:vat' "$T/o.html"; check "$E render_groups_by_rule: fallback kind:path" "$?" "0"
  grep -q '"id":"H1"' "$T/o.html"; check "$E render excludes human rows" "$?" "1"
  grep -q '"id":"S1"' "$T/o.html"; check "$E render excludes spec rows" "$?" "1"
  grep -q '"id":"D1"' "$T/o.html"; check "$E render excludes rows without expect" "$?" "1"
  grep -q '__ORACLE_DATA__' "$T/o.html"; check "$E render replaced placeholder" "$?" "1"
  check "$E groups A1+A2 together" "$(python3 - "$T/o.html" <<'PY'
import json, re, sys
h = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<script type="application/json" id="oracle-data">\n(.*?)\n</script>', h, re.S)
d = json.loads(m.group(1))
g = [x for x in d["groups"] if x["rule"] == "fee = rate x qty"][0]
print(",".join(r["id"] for r in g["rows"]))
PY
)" "A1,A2"
  check "$E render_no_external_urls" "$(sed 's/<!--.*-->//' "$T/o.html" | grep -ci 'http' )" "0"
  grep -q 'oracle-decisions.json' "$T/o.html" && grep -q 'new Blob' "$T/o.html"; check "$E page downloads oracle-decisions.json via Blob" "$?" "0"
  grep -q "dir: 'auto'\|dir=\"auto\"" "$T/o.html"; check "$E page sets dir auto" "$?" "0"

  printf '%s' '[{"criterionId":"A1","decision":"accept"},{"criterionId":"A2","decision":"edit","value":"0.006"},{"criterionId":"B1","decision":"unknown"}]' > "$T/d.json"
  QA_ENGINE=$E bash "$SH" apply "$T/c.json" "$T/d.json" > "$T/a.out"; check "$E apply rc" "$?" "0"
  check "$E apply_accept_edit_unknown summary" "$(cat "$T/a.out")" '{"accepted":1,"edited":1,"unknown":1,"unmatched":[]}'
  check "$E apply accept -> human" "$(pyj '[r for r in d if r["id"]=="A1"][0]["fixture"]["expect"]["oracleSource"]' < "$T/c.json")" "human"
  check "$E apply edit -> value+human" "$(pyj '[(r["fixture"]["expect"]["value"], r["fixture"]["expect"]["oracleSource"]) for r in d if r["id"]=="A2"][0]' < "$T/c.json")" "('0.006', 'human')"
  check "$E apply unknown unchanged" "$(pyj '[(r["fixture"]["expect"]["value"], r["fixture"]["expect"]["oracleSource"]) for r in d if r["id"]=="B1"][0]' < "$T/c.json")" "(15, 'llm-suggested')"
  check "$E apply backup is original" "$(printf '%s' "$CHECKLIST" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True))')" "$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),sort_keys=True))' "$T/c.json.bak")"
  printf '%s' '[{"criterionId":"ZZ","decision":"accept"},{"criterionId":"D1","decision":"accept"},{"criterionId":"B1","decision":"edit"},{"criterionId":"B1b","decision":"accept"}]' > "$T/d2.json"
  QA_ENGINE=$E bash "$SH" apply "$T/c.json" "$T/d2.json" > "$T/a2.out"
  check "$E apply_reports_unmatched" "$(cat "$T/a2.out")" '{"accepted":0,"edited":0,"unknown":0,"unmatched":["B1","B1b","D1","ZZ"]}'
  # fix round 1: human/spec rows, malformed expects, empty edit value -> unmatched, file unchanged
  printf '%s' '[{"id":"N1","kind":"computed-logic","fixture":{"expect":{"path":"t","tolerance":0,"oracleSource":"llm-suggested"}}},{"id":"N2","kind":"computed-logic","fixture":{"expect":{"path":"t","value":"1","oracleSource":"llm-suggested"}}},{"id":"N3","kind":"computed-logic","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"llm-suggested"}}}]' > "$T/m2.json"
  printf "%s" "$CHECKLIST" > "$T/c5.json"
  printf '%s' '[{"criterionId":"H1","decision":"edit","value":"9"},{"criterionId":"S1","decision":"accept"},{"criterionId":"N1","decision":"accept"},{"criterionId":"N2","decision":"edit","value":"2"},{"criterionId":"N3","decision":"edit","value":""}]' > "$T/d5.json"
  QA_ENGINE=$E bash "$SH" apply "$T/c5.json" "$T/d5.json" > "$T/a5.out"
  check "$E apply_refuses_human_spec_and_malformed" "$(cat "$T/a5.out")" '{"accepted":0,"edited":0,"unknown":0,"unmatched":["H1","N1","N2","N3","S1"]}'
  check "$E apply_refusal_leaves_checklist_values" "$(pyj '[r for r in d if r["id"]=="H1"][0]["fixture"]["expect"]["value"]' < "$T/c5.json")" "1"
  printf '%s' '[{"criterionId":"N1","decision":"accept"},{"criterionId":"N2","decision":"accept"},{"criterionId":"N3","decision":"edit","value":""},{"criterionId":"N3","decision":"edit","value":"5"}]' > "$T/d6.json"
  QA_ENGINE=$E bash "$SH" apply "$T/m2.json" "$T/d6.json" > "$T/a6.out"
  check "$E apply_malformed_expect_unmatched" "$(cat "$T/a6.out")" '{"accepted":0,"edited":1,"unknown":0,"unmatched":["N1","N2"]}'
  printf '%s' '[{"criterionId":"AR1","decision":"edit","value":"٤٥٦ ريال"}]' > "$T/d3.json"
  QA_ENGINE=$E bash "$SH" apply "$T/c.json" "$T/d3.json" >/dev/null
  check "$E arabic_values_roundtrip value" "$(pyj '[r for r in d if r["id"]=="AR1"][0]["fixture"]["expect"]["value"]' < "$T/c.json")" "٤٥٦ ريال"
  grep -q 'فيصل الحربي' "$T/c.json"; check "$E arabic kept unescaped in checklist" "$?" "0"
  printf '%s' "$CHECKLIST" > "$T/c4.json"
  QA_ENGINE=$E bash "$SH" render "$T/c4.json" "$T/o2.html" >/dev/null
  grep -q 'رسوم الخدمة' "$T/o2.html"; check "$E arabic rule in rendered page" "$?" "0"
  printf '%s' '{"x":1}' > "$T/bad.json"
  QA_ENGINE=$E bash "$SH" render "$T/bad.json" "$T/o3.html" >/dev/null 2>&1; check "$E non-array render dies" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
run_engine python3
if command -v jq >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  printf '%s' "$CHECKLIST" > "$X/c.json"
  QA_ENGINE=jq bash "$SH" render "$X/c.json" "$X/j.html" >/dev/null; QA_ENGINE=python3 bash "$SH" render "$X/c.json" "$X/p.html" >/dev/null
  check "cross-engine html identical" "$(cmp -s "$X/j.html" "$X/p.html" && echo same || echo diff)" "same"
  printf '%s' '[{"criterionId":"A1","decision":"accept"},{"criterionId":"AR1","decision":"edit","value":"٤٥٦ ريال"},{"criterionId":"ZZ","decision":"accept"}]' > "$X/d.json"
  cp "$X/c.json" "$X/c2.json"
  QA_ENGINE=jq bash "$SH" apply "$X/c.json" "$X/d.json" > "$X/ja.out"; QA_ENGINE=python3 bash "$SH" apply "$X/c2.json" "$X/d.json" > "$X/pa.out"
  check "cross-engine apply summary identical" "$(cmp -s "$X/ja.out" "$X/pa.out" && echo same || echo diff)" "same"
  check "cross-engine applied checklist identical" "$(cmp -s "$X/c.json" "$X/c2.json" && echo same || echo diff)" "same"
fi
echo "oracle-confirm: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
