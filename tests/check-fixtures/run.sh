#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/check-fixtures.sh — computed criteria
# (kind ∈ {computed-logic, business-rule}) must carry a well-formed absolute pinned expect.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/check-fixtures.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: check-fixtures: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
OKROW='{"id":"C1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"actionInput":{"q":3},"expect":{"path":"total","value":"0.003","tolerance":0,"oracleSource":"human"}}}'
DISPLAY='{"id":"C2","surface":"/x","kind":"empty-state","tags":["read-only"],"action":"a"}'
MISSING='{"id":"C3","surface":"/x","kind":"computed-logic","tags":[],"action":"a"}'
BIZRULE='{"id":"C4","surface":"/x","kind":"business-rule","tags":[],"action":"a"}'
ILLFORMED='{"id":"C5","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"total","value":"1","tolerance":0,"oracleSource":"bogus"}}}'
NOID_A='{"surface":"/x","kind":"computed-logic","tags":[],"action":"a"}'
NOID_B='{"id":"zzz","surface":"/x","kind":"computed-logic","tags":[],"action":"a"}'
run_engine() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf '[%s,%s]' "$OKROW" "$DISPLAY" > "$T/ok.json"
  QA_ENGINE=$E bash "$SH" "$T/ok.json" >/dev/null; check "$E computed pinned + display exempt -> ok" "$?" "0"
  printf '[%s]' "$MISSING" > "$T/m.json"
  local out; out="$(QA_ENGINE=$E bash "$SH" "$T/m.json")"; local rc=$?
  check "$E computed-logic missing expect -> exit 1" "$rc" "1"
  check "$E missing lists C3" "$(printf '%s' "$out" | python3 -c 'import json,sys;print(any(m["id"]=="C3" for m in json.load(sys.stdin)["missing"]))')" "True"
  printf '[%s]' "$BIZRULE" > "$T/br.json"
  QA_ENGINE=$E bash "$SH" "$T/br.json" >/dev/null 2>&1; check "$E business-rule missing expect -> exit 1 (kind trigger)" "$?" "1"
  printf '[%s]' "$ILLFORMED" > "$T/if.json"
  QA_ENGINE=$E bash "$SH" "$T/if.json" >/dev/null 2>&1; check "$E bad oracleSource -> exit 1" "$?" "1"
  # sources counts human pins
  printf '[%s]' "$OKROW" > "$T/src.json"
  check "$E sources.human counted" "$(QA_ENGINE=$E bash "$SH" "$T/src.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sources"]["human"])')" "1"
  printf '%s' '{"nope":1}' > "$T/na.json"
  QA_ENGINE=$E bash "$SH" "$T/na.json" >/dev/null 2>&1; check "$E non-array dies" "$?" "1"
  # audit-2 W3-7b: missing[] ordering when one row has no id at all — jq sort_by(.id)
  # puts null FIRST (jq type ordering); the old python key put it LAST.
  printf '[%s,%s]' "$NOID_B" "$NOID_A" > "$T/noid.json"
  check "$E missing[] puts null id first" \
    "$(QA_ENGINE=$E bash "$SH" "$T/noid.json" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["missing"][0]["id"])')" "None"
}
spec_engine() {
  local E="$1" T; T="$(mktemp -d)"; TMPDIRS+=("$T")
  printf 'l1\nl2\nl3\n' > "$T/spec.md"
  mk() { printf '[{"id":"S1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"spec"%s}}}]' "$1" > "$T/c.json"; }
  mk ',"citation":"spec.md:3"'
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null; check "$E spec_with_valid_citation_ok" "$?" "0"
  check "$E sources_counts_spec" "$(QA_ENGINE=$E bash "$SH" "$T/c.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sources"]["spec"])')" "1"
  mk ''
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null 2>&1; check "$E spec_missing_citation_missing" "$?" "1"
  mk ',"citation":"spec.md:4"'
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null 2>&1; check "$E spec_citation_bad_line_missing" "$?" "1"
  mk ',"citation":"nofile.md:1"'
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null 2>&1; check "$E spec_citation_missing_file" "$?" "1"
  mk ',"citation":"spec.md"'
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null 2>&1; check "$E spec_citation_no_line" "$?" "1"
  mk ',"citation":""'
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null 2>&1; check "$E spec_empty_citation_rejected" "$?" "1"
  mk ',"citation":":3"'
  QA_ENGINE=$E bash "$SH" "$T/c.json" >/dev/null 2>&1; check "$E spec_colon_only_citation_rejected" "$?" "1"
  # containment: traversal, absolute path, symlink out
  mkdir -p "$T/dir"; cp "$T/c.json" "$T/dir/c.json"; printf 'x\ny\n' > "$T/outside.txt"
  ln -s "$T/outside.txt" "$T/dir/link.md"; ln -s /etc/passwd "$T/dir/pw.md"
  printf 'a\nb\n' > "$T/dir/in.md"
  mkd() { printf '[{"id":"S1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"spec","citation":"%s"}}}]' "$1" > "$T/dir/c.json"; }
  mkd "in.md:2"; QA_ENGINE=$E bash "$SH" "$T/dir/c.json" >/dev/null 2>&1; check "$E spec_contained_ok" "$?" "0"
  mkd "../outside.txt:1"; QA_ENGINE=$E bash "$SH" "$T/dir/c.json" >/dev/null 2>&1; check "$E spec_traversal_rejected" "$?" "1"
  mkd "../../../../../../etc/passwd:1"; QA_ENGINE=$E bash "$SH" "$T/dir/c.json" >/dev/null 2>&1; check "$E spec_deep_traversal_rejected" "$?" "1"
  mkd "/etc/passwd:1"; QA_ENGINE=$E bash "$SH" "$T/dir/c.json" >/dev/null 2>&1; check "$E spec_absolute_rejected" "$?" "1"
  mkd "link.md:1"; QA_ENGINE=$E bash "$SH" "$T/dir/c.json" >/dev/null 2>&1; check "$E spec_symlink_out_rejected" "$?" "1"
  mkd "pw.md:1"; QA_ENGINE=$E bash "$SH" "$T/dir/c.json" >/dev/null 2>&1; check "$E spec_symlink_etc_rejected" "$?" "1"
  # sources.spec counts only valid citations
  mkd "../outside.txt:1"; check "$E sources_spec_counts_valid_only" "$(QA_ENGINE=$E bash "$SH" "$T/dir/c.json" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["sources"]["spec"])')" "0"
}
command -v jq >/dev/null 2>&1 && spec_engine jq
command -v python3 >/dev/null 2>&1 && spec_engine python3
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  printf '[%s,%s]' "$MISSING" "$OKROW" > "$X/c.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/c.json"; true)"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/c.json"; true)"
  check "cross-engine report identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  # cross-engine ordering byte-parity when a row has no id (the null-first case)
  printf '[%s,%s]' "$NOID_B" "$NOID_A" > "$X/noid.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/noid.json" 2>/dev/null; true)"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/noid.json" 2>/dev/null; true)"
  check "cross-engine null-id ordering byte-identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
  printf '[{"id":"S1","surface":"/x","kind":"computed-logic","tags":[],"action":"a","fixture":{"expect":{"path":"t","value":"1","tolerance":0,"oracleSource":"spec","citation":""}}}]' > "$X/e.json"
  vj="$(QA_ENGINE=jq bash "$SH" "$X/e.json" 2>/dev/null; true)"; vp="$(QA_ENGINE=python3 bash "$SH" "$X/e.json" 2>/dev/null; true)"
  check "cross-engine empty citation parity" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"
fi
echo "check-fixtures: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
