#!/usr/bin/env bash
# Tests for scripts/bug-export.sh: the three bug-log shapes, verifier overrides, known-defect
# dedup (outstanding vs expired), empty input, Arabic text. Every case runs on BOTH engines
# (jq and python3) and the outputs must be byte-identical.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bug-export.sh"
pass=0; fail=0
ok() { echo "ok   - $1"; pass=$((pass+1)); }
no() { echo "FAIL - $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }
W="$(mktemp -d "${TMPDIR:-/tmp}/bug-export-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
TODAY=2026-11-09

# run <name> <run-dir> [extra args]: both engines, assert identical, leave jq output in $W/out-<name>.
ENGINES="jq python3"; command -v jq >/dev/null 2>&1 || ENGINES="python3"
run() {
  local name="$1" rd="$2"; shift 2
  local e
  for e in $ENGINES; do
    QA_ENGINE="$e" bash "$SCRIPT" "$rd" --out "$W/out-$name-$e" --today "$TODAY" "$@" > "$W/sum-$name-$e" 2> "$W/err-$name-$e"
    echo $? > "$W/rc-$name-$e"
  done
  SUM="$(cat "$W/sum-$name-${ENGINES%% *}")"; OUTD="$W/out-$name-${ENGINES%% *}"
  if [ "$ENGINES" = "jq python3" ]; then
    if diff -r "$W/out-$name-jq" "$W/out-$name-python3" >/dev/null && cmp -s "$W/sum-$name-jq" "$W/sum-$name-python3"; then
      ok "$name: jq and python3 byte-identical"
    else no "$name: engines differ"; diff -r "$W/out-$name-jq" "$W/out-$name-python3" | head -10; fi
  fi
}
mkrun() { mkdir -p "$W/$1/.qa/runs/r1"; echo "$W/$1/.qa/runs/r1"; }

BUG_A='{"bug_id":"BUG-1","title":"Saving the profile loses the phone number","severity":"critical","suspected_layer":"service","criterion_id":"C-1","persona":"admin","steps":["Open the profile","Change the phone","Press Save"],"expected":"The new phone is kept","actual":"The old phone comes back","evidence_refs":["evidence/admin/C-1/after.png"],"surface":"/profile"}'
BUG_B='{"id":"BUG-2","layer":"FE","criterion":"C-2","repro":["Open the list"],"expected":"Ten rows","actual":"Three rows. The rest never load","evidence":["evidence/C-2/s.png"],"journey_id":"J-1"}'

# --- exports_bug_log_shapes
for shape in array entries bugs; do
  R="$(mkrun shape-$shape)"
  case "$shape" in
    array) echo "[$BUG_A,$BUG_B]" > "$R/bug-log.json" ;;
    entries) echo "{\"entries\":[$BUG_A,$BUG_B]}" > "$R/bug-log.json" ;;
    bugs) echo "{\"bugs\":[$BUG_A,$BUG_B]}" > "$R/bug-log.json" ;;
  esac
  run "shape-$shape" "$R"
  check "exports_bug_log_shapes[$shape]: summary" "$SUM" '{"exported":2,"duplicates":0,"skipped":0}'
done
BJ="$W/out-shape-array-${ENGINES%% *}/bugs.json"
check "exports_bug_log_shapes: explicit severity wins" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[0]["severity"])' "$BJ")" critical
check "exports_bug_log_shapes: FE defaults to medium" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[1]["severity"])' "$BJ")" medium
check "exports_bug_log_shapes: aliases map (criterionId, journeyId)" "$(python3 -c 'import json,sys;b=json.load(open(sys.argv[1]))[1];print(b["criterionId"],b["journeyId"],b["steps"],b["evidence"])' "$BJ")" "C-2 J-1 ['Open the list'] ['evidence/C-2/s.png']"
MD="$W/out-shape-array-${ENGINES%% *}/BUG-1.md"
for sec in "## What happened" "## What should happen" "## Steps" "## Evidence"; do
  grep -qF "$sec" "$MD" && ok "exports_bug_log_shapes: md has '$sec'" || no "md missing '$sec'"
done
grep -qiE 'criterion|verdict|oracle|bake|persona' "$MD" && no "md leaks internal jargon" || ok "exports_bug_log_shapes: md free of jargon"
# default high for a backend layer
R="$(mkrun layer)"; echo '[{"id":"X","layer":"migration","actual":"a"},{"id":"Y","layer":"DB","actual":"a"},{"id":"Z","actual":"a"}]' > "$R/bug-log.json"
run layer "$R"
check "severity defaults by layer" "$(python3 -c 'import json,sys;print([b["severity"] for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['high', 'high', 'medium']"

# --- verifier_override_becomes_bug
R="$(mkrun ver)"
echo "[$BUG_A]" > "$R/bug-log.json"
cat > "$R/verification.json" <<'EOF'
[{"criterionId":"C-1","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["covered by a bug"]},
 {"criterionId":"C-9","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["no recorded request","screenshot missing"]},
 {"criterionId":"C-8","persona":"admin","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"high","reasons":[]},
 {"criterionId":"C-7","persona":"admin","inRunVerdict":"fail","verifierVerdict":"fail","confidence":"high","reasons":[]}]
EOF
run ver "$R"
check "verifier_override_becomes_bug: one extra bug, covered one skipped" "$SUM" '{"exported":2,"duplicates":0,"skipped":1}'
check "verifier_override_becomes_bug: criterionId carried" "$(python3 -c 'import json,sys;print([b["criterionId"] for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['C-1', 'C-9']"
VMD="$(ls "$OUTD"/VERIFY-*.md 2>/dev/null | head -1)"
[ -n "$VMD" ] && grep -q "no recorded request" "$VMD" && ok "verifier_override_becomes_bug: reasons in What happened" || no "override md missing"
head -1 "$VMD" | grep -qiE 'criterion|verdict|oracle|bake|persona|C-9' && no "override title leaks jargon" || ok "verifier_override_becomes_bug: plain title"

# --- known defects
REG="$W/known.json"
cat > "$REG" <<'EOF'
[{"id":"KD-1","title":"Profile page blank","ticket":"T-1","expiry":"2026-12-01","severity":"high","observedClass":"non-rendering","surface":"/profile","observedBehaviour":"blank"},
 {"id":"KD-2","title":"Old list bug","ticket":"T-2","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/list","observedBehaviour":"blank"}]
EOF
R="$(mkrun kd)"; echo "[$BUG_A,{\"id\":\"BUG-3\",\"criterion_id\":\"C-3\",\"actual\":\"blank\",\"surface\":\"https://app.test/list?x=1\"},{\"id\":\"BUG-4\",\"actual\":\"other\",\"surface\":\"/other\"}]" > "$R/bug-log.json"
run kd "$R" --known-defects "$REG"
check "known_defect_dedup: summary" "$SUM" '{"exported":2,"duplicates":1,"skipped":0}'
check "known_defect_dedup: duplicateOf set" "$(python3 -c 'import json,sys;print([b.get("duplicateOf") for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['KD-1', None, None]"
[ ! -e "$OUTD/BUG-1.md" ] && ok "known_defect_dedup: no .md for the duplicate" || no "duplicate wrote an .md"
[ -e "$OUTD/BUG-3.md" ] && ok "expired_known_defect_not_dedup: expired defect does not dedup" || no "expired defect swallowed a bug"
# criterion on the defect must match
R="$(mkrun kdc)"; echo "[$BUG_A]" > "$R/bug-log.json"
sed 's/"surface":"\/profile"/"surface":"\/profile","criterionId":"C-OTHER"/' "$REG" > "$W/known-c.json"
run kdc "$R" --known-defects "$W/known-c.json"
check "known_defect_dedup: differing criterion is not a duplicate" "$SUM" '{"exported":1,"duplicates":0,"skipped":0}'

# --- empty_bug_log_exports_zero
R="$(mkrun empty)"; echo '[]' > "$R/bug-log.json"
run empty "$R"
check "empty_bug_log_exports_zero: summary" "$SUM" '{"exported":0,"duplicates":0,"skipped":0}'
check "empty_bug_log_exports_zero: bugs.json empty array" "$(tr -d ' \n' < "$OUTD/bugs.json")" '[]'
R="$(mkrun nolog)"; run nolog "$R"
check "empty_bug_log_exports_zero: absent bug-log" "$SUM" '{"exported":0,"duplicates":0,"skipped":0}'

# --- arabic_title_parity
R="$(mkrun ar)"
cat > "$R/bug-log.json" <<'EOF'
[{"bug_id":"BUG-ع","title":"حفظ رقم الجوال لا يعمل في صفحة الملف الشخصي","layer":"service","criterion_id":"C-1","steps":["افتح الملف الشخصي","اضغط حفظ"],"expected":"يُحفظ الرقم الجديد","actual":"يعود الرقم القديم","evidence":[]}]
EOF
run ar "$R"
grep -q 'حفظ رقم الجوال' "$OUTD/bugs.json" && ok "arabic_title_parity: UTF-8 kept in bugs.json (no \\u escapes)" || no "arabic escaped"
ls "$OUTD" | grep -q '^BUG.md$' && ok "arabic_title_parity: id sanitised to a safe filename" || no "unexpected md name: $(ls "$OUTD")"
grep -q 'يعود الرقم القديم' "$OUTD"/BUG.md && ok "arabic_title_parity: md carries Arabic body" || no "arabic md body"

# --- secrets never exported
R="$(mkrun sec)"; mkdir -p "$W/sec/.qa"
echo '{"enforcement":{"redactedKeys":["hunter2"],"secretPatterns":["token\\s*[=:]\\s*\\S+"]}}' > "$W/sec/.qa/config.json"
echo '[{"id":"S-1","password":"p@ss","actual":"login with hunter2 sent token=abc123 to server","expected":"ok","steps":["type hunter2"],"api_key":"k"}]' > "$R/bug-log.json"
run sec "$R"
if grep -rqE 'hunter2|abc123|p@ss' "$OUTD"; then no "secret leaked"; else ok "secrets: keys dropped and values redacted"; fi
grep -q '<redacted>' "$OUTD/S-1.md" && ok "secrets: placeholder shown" || no "no placeholder"

echo "bug-export: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
