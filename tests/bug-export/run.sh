#!/usr/bin/env bash
# Tests for scripts/bug-export.sh: the three bug-log shapes, verifier overrides (contradiction ->
# bug, evidence gap -> needs-recheck.json), evidence/journey fallback, stale-file pruning,
# known-defect dedup (outstanding vs expired), empty input, Arabic text. Every case runs on BOTH engines
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
  check "exports_bug_log_shapes[$shape]: summary" "$SUM" '{"exported":2,"duplicates":0,"skipped":0,"needsRecheck":0}'
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

# --- verifier overrides: a contradiction is a bug, an evidence gap goes to needs-recheck.json
R="$(mkrun ver)"
echo "[$BUG_A]" > "$R/bug-log.json"
cat > "$R/checklist.json" <<'EOF'
[{"id":"C-9","surface":"/orders","kind":"computed-logic","tags":[],"action":"Open the order and read the total with VAT"},
 {"id":"C-10","surface":"/orders","kind":"happy-path","tags":["human-action"],"title":"Saving an order keeps the delivery date","action":"Change the delivery date and save"},
 {"id":"C-11","surface":"/orders","kind":"happy-path","tags":[],"action":"Open the orders list","journey":{"id":"J-ROW","step":1}}]
EOF
echo '[{"id":"J-ORD","priority":"P1","steps":["C-10"]}]' > "$R/journeys.json"
mkdir -p "$R/evidence/admin/C-11"; echo '{}' > "$R/evidence/admin/C-11/bake.json"
cat > "$R/checkpoint.json" <<'EOF'
{"criteria":[{"criterion_id":"C-9","persona":"admin","verdict":"pass","evidence_refs":["evidence/admin/C-9/old.json"]},
 {"criterion_id":"C-9","persona":"admin","verdict":"pass","evidence_refs":["evidence/admin/C-9/computed.json"]},
 {"criterion_id":"C-9","persona":"viewer","verdict":"pass","evidence_refs":["evidence/viewer/C-9/computed.json"]}]}
EOF
cat > "$R/verification.json" <<'EOF'
[{"criterionId":"C-1","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["covered by a bug"]},
 {"criterionId":"C-9","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["evidence artifact 'evidence/admin/C-9/computed.json' shows match:false — the independent recompute diverged from the observed value"]},
 {"criterionId":"C-10","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["acting identity 'nora@innovation-lab.co' != expected identity 'faisal@innovation-lab.co' for persona 'admin' (evidence/admin/identity.json) — this pass was performed as the wrong user","evidence artifact 'evidence/admin/C-10/bake.json' shows readBack:null with non-zero multiplicity — nothing was actually persisted"]},
 {"criterionId":"C-11","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["oracle-ungrounded: oracleSource=agent cannot ground a high-confidence pass (allowed: human, spec)"]},
 {"criterionId":"C-12","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["no-state-evidence: C-12 is mutating; a pass needs bake or probe evidence (got: human-action)","provenance UNBOUND: 'evidence/admin/C-12/x.json' corresponds to no captured toolstream call — forgery signal (AC-1)","invalid-confidence: maybe","data-policy-violation: checker unavailable (scripts/data-policy.sh not found)","persona identity unverified: no evidence/admin/identity.json recorded for this run"]},
 {"criterionId":"__run-checks__","persona":"","inRunVerdict":"n/a","verifierVerdict":"fail","confidence":"high","reasons":["effectiveConfigMissing: project config asks for profile ship"]},
 {"criterionId":"C-8","persona":"admin","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"high","reasons":[]},
 {"criterionId":"C-7","persona":"admin","inRunVerdict":"fail","verifierVerdict":"fail","confidence":"high","reasons":[]}]
EOF
run ver "$R"
check "override_contradiction_is_bug: summary" "$SUM" '{"exported":3,"duplicates":0,"skipped":1,"needsRecheck":2}'
check "override_contradiction_is_bug: only contradictions exported" "$(python3 -c 'import json,sys;print([b["criterionId"] for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['C-1', 'C-9', 'C-10']"
check "override_title_from_row: action, then title" "$(python3 -c 'import json,sys;print([b["title"] for b in json.load(open(sys.argv[1]))[1:]])' "$OUTD/bugs.json")" "['Open the order and read the total with VAT', 'Saving an order keeps the delivery date']"
check "override_evidence_from_checkpoint: latest matching record" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[1]["evidence"])' "$OUTD/bugs.json")" "['evidence/admin/C-9/computed.json']"
check "override_journey_from_journeys_json" "$(python3 -c 'import json,sys;b=json.load(open(sys.argv[1]));print(b[2].get("journeyId"),b[1].get("journeyId"))' "$OUTD/bugs.json")" "J-ORD None"
check "evidence_gap_to_recheck: ids and order" "$(python3 -c 'import json,sys;print([(n["criterionId"],n["persona"]) for n in json.load(open(sys.argv[1]))])' "$OUTD/needs-recheck.json")" "[('C-11', 'admin'), ('C-12', 'admin')]"
check "evidence_gap_to_recheck: row journey, dir evidence fallback, reasons kept" "$(python3 -c 'import json,sys;n=json.load(open(sys.argv[1]))[0];print(n["journeyId"],n["evidence"],n["title"],n["reasons"][0][:17])' "$OUTD/needs-recheck.json")" "J-ROW ['evidence/admin/C-11/'] Open the orders list oracle-ungrounded"
[ ! -e "$OUTD/VERIFY-C-11-admin.md" ] && [ ! -e "$OUTD/VERIFY-C-12-admin.md" ] && ok "evidence_gap_to_recheck: no bug file for a gap" || no "gap became a bug file"
VMD="$OUTD/VERIFY-C-10-admin.md"
grep -q "different user" "$VMD" && grep -q "did not stick" "$VMD" && ok "override_contradiction_is_bug: plain What happened" || no "override md body"
grep -qF "This should work: Change the delivery date and save" "$VMD" && ok "override_contradiction_is_bug: expected from the action" || no "override expected"
for f in "$OUTD"/VERIFY-*.md; do
  if grep -qiE 'criterion|verdict|oracle|bake|persona|readBack|match:false|ok:false|GATE|identity|re-check|verifier' "$f"; then
    no "override md leaks gate jargon: $(basename "$f")"
  else ok "override_no_gate_jargon: $(basename "$f")"; fi
done

# --- bug-log evidence + journey fallback (M1)
R="$(mkrun evfb)"
cat > "$R/bug-log.json" <<'EOF'
[{"id":"E-1","criterion_id":"C-20","persona":"admin","actual":"The total is wrong"},
 {"id":"E-2","criterion_id":"C-21","persona":"admin","actual":"The list is empty"},
 {"id":"E-3","criterion_id":"C-22","actual":"Nothing saved"},
 {"id":"E-4","criterion_id":"C-23","persona":"admin","actual":"x","evidence_refs":["own.png"],"journey_id":"J-OWN"}]
EOF
echo '{"criteria":[{"criterion_id":"C-20","persona":"admin","verdict":"fail","evidence_refs":["evidence/admin/C-20/computed.json"]},{"criterion_id":"C-23","persona":"admin","verdict":"fail","evidence_refs":["other.png"]}]}' > "$R/checkpoint.json"
mkdir -p "$R/evidence/admin/C-21" "$R/evidence/C-22"
echo '[{"id":"J-A","priority":"P1","steps":["C-21","C-23"]}]' > "$R/journeys.json"
run evfb "$R"
check "evidence_fallback: checkpoint refs, persona dir, shared dir, own wins" "$(python3 -c 'import json,sys;print([b["evidence"] for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "[['evidence/admin/C-20/computed.json'], ['evidence/admin/C-21/'], ['evidence/C-22/'], ['own.png']]"
check "journey_fallback: journeys.json, own wins" "$(python3 -c 'import json,sys;print([b.get("journeyId") for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "[None, 'J-A', None, 'J-OWN']"

# --- stale files (I4): only .md files the previous bugs.json listed are pruned
R="$(mkrun prune)"
for e in $ENGINES; do
  echo '[{"id":"P-1","actual":"a"},{"id":"P-2","actual":"b"}]' > "$R/bug-log.json"
  O="$W/out-prune-$e"; mkdir -p "$O"; echo keep > "$O/NOTES.md"; echo keep > "$O/P-9.md"
  QA_ENGINE="$e" bash "$SCRIPT" "$R" --out "$O" --today "$TODAY" > /dev/null 2>&1
  echo '[{"id":"P-2","actual":"b"}]' > "$R/bug-log.json"
  QA_ENGINE="$e" bash "$SCRIPT" "$R" --out "$O" --today "$TODAY" > /dev/null 2>&1
  check "stale_md_pruned[$e]: P-1 gone, P-2 kept, unlisted files kept" "$(cd "$O" && LC_ALL=C ls | tr '\n' ' ')" "NOTES.md P-2.md P-9.md bugs.json needs-recheck.json "
done
# a hostile previous bugs.json never deletes outside its own listed ids
for e in $ENGINES; do
  O="$W/out-hostile-$e"; mkdir -p "$O/sub"; echo keep > "$O/sub/x.md"; echo keep > "$W/outside-$e.md"
  echo "[{\"id\":\"../outside-$e\"},{\"id\":\"sub/x\"},{\"id\":\".hidden\"},{\"id\":42}]" > "$O/bugs.json"
  echo '[]' > "$R/bug-log.json"
  QA_ENGINE="$e" bash "$SCRIPT" "$R" --out "$O" --today "$TODAY" > /dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ -e "$W/outside-$e.md" ] && [ -e "$O/sub/x.md" ]; then ok "stale_md_pruned[$e]: path-like ids never delete"; else no "hostile prune ($e rc=$rc)"; fi
  echo 'not json' > "$O/bugs.json"
  if QA_ENGINE="$e" bash "$SCRIPT" "$R" --out "$O" --today "$TODAY" > /dev/null 2>&1; then ok "stale_md_pruned[$e]: unparseable previous export tolerated"; else no "unparseable prev bugs.json ($e)"; fi
done

# --- known defects
REG="$W/known.json"
cat > "$REG" <<'EOF'
[{"id":"KD-1","title":"Profile save loses data","ticket":"T-1","expiry":"2026-12-01","severity":"high","observedClass":"wrong-value","surface":"/profile","criterionId":"C-1","observedBehaviour":"old value returns"},
 {"id":"KD-2","title":"Old list bug","ticket":"T-2","expiry":"2026-10-01","severity":"high","observedClass":"non-rendering","surface":"/list","observedBehaviour":"blank"}]
EOF
R="$(mkrun kd)"; echo "[$BUG_A,{\"id\":\"BUG-3\",\"criterion_id\":\"C-3\",\"actual\":\"blank\",\"surface\":\"https://app.test/list?x=1\"},{\"id\":\"BUG-4\",\"actual\":\"other\",\"surface\":\"/other\"}]" > "$R/bug-log.json"
run kd "$R" --known-defects "$REG"
check "known_defect_dedup: summary" "$SUM" '{"exported":2,"duplicates":1,"skipped":0,"needsRecheck":0}'
check "known_defect_dedup: duplicateOf set" "$(python3 -c 'import json,sys;print([b.get("duplicateOf") for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['KD-1', None, None]"
[ ! -e "$OUTD/BUG-1.md" ] && ok "known_defect_dedup: no .md for the duplicate" || no "duplicate wrote an .md"
[ -e "$OUTD/BUG-3.md" ] && ok "expired_known_defect_not_dedup: expired defect does not dedup" || no "expired defect swallowed a bug"
# criterion on the defect must match
R="$(mkrun kdc)"; echo "[$BUG_A]" > "$R/bug-log.json"
sed 's/"criterionId":"C-1"/"criterionId":"C-OTHER"/' "$REG" > "$W/known-c.json"
run kdc "$R" --known-defects "$W/known-c.json"
check "different_criterion_same_surface_not_dedup" "$SUM" '{"exported":1,"duplicates":0,"skipped":0,"needsRecheck":0}'

# no criterion on the defect: dedup only on matching class; "/" never dedups
cat > "$W/known-cls.json" <<'EOF'
[{"id":"KD-5","title":"Orders list blank","ticket":"T-5","expiry":"2026-12-01","severity":"high","observedClass":"non-rendering","surface":"/orders","observedBehaviour":"blank"},
 {"id":"KD-6","title":"Home degraded","ticket":"T-6","expiry":"2026-12-01","severity":"high","observedClass":"non-rendering","surface":"/","observedBehaviour":"blank"}]
EOF
R="$(mkrun cls)"
cat > "$R/bug-log.json" <<'EOF'
[{"id":"C1","layer":"FE","criterion_id":"C-5","actual":"The orders page stays blank","surface":"/orders"},
 {"id":"C2","layer":"FE","criterion_id":"C-6","actual":"The total shows the wrong amount","surface":"/orders"},
 {"id":"C3","layer":"service","criterion_id":"C-7","actual":"The page is slow","surface":"/orders"},
 {"id":"C4","criterion_id":"C-8","actual":"The orders page stays blank","surface":"/orders"},
 {"id":"C5","layer":"FE","observedClass":"non-rendering","criterion_id":"C-9","actual":"x","surface":"/orders"},
 {"id":"C6","layer":"FE","criterion_id":"C-10","actual":"The home page stays blank","surface":"/"}]
EOF
run cls "$R" --known-defects "$W/known-cls.json"
check "class_match_dedups: only a same-class bug on the surface is a duplicate" "$(python3 -c 'import json,sys;print([b.get("duplicateOf") for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['KD-5', None, None, None, 'KD-5', None]"
check "root_surface_not_dedup: '/' never dedups" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[5].get("duplicateOf"))' "$OUTD/bugs.json")" None

# ids: case-insensitive collisions are bumped until free
R="$(mkrun ids)"; echo '[{"id":"a","actual":"1"},{"id":"A","actual":"2"},{"id":"a-2","actual":"3"},{"id":"a","actual":"4"}]' > "$R/bug-log.json"
run ids "$R"
check "ids: collision-proof, case-insensitive" "$(python3 -c 'import json,sys;print([b["id"] for b in json.load(open(sys.argv[1]))])' "$OUTD/bugs.json")" "['a', 'A-2', 'a-2-2', 'a-3']"
check "ids: one file per bug" "$(ls "$OUTD" | grep -c '\.md$')" 4

# --- empty_bug_log_exports_zero
R="$(mkrun empty)"; echo '[]' > "$R/bug-log.json"
run empty "$R"
check "empty_bug_log_exports_zero: summary" "$SUM" '{"exported":0,"duplicates":0,"skipped":0,"needsRecheck":0}'
check "empty_bug_log_exports_zero: bugs.json empty array" "$(tr -d ' \n' < "$OUTD/bugs.json")" '[]'
R="$(mkrun nolog)"; run nolog "$R"
check "empty_bug_log_exports_zero: absent bug-log" "$SUM" '{"exported":0,"duplicates":0,"skipped":0,"needsRecheck":0}'

# --- arabic_title_parity
R="$(mkrun ar)"
cat > "$R/bug-log.json" <<'EOF'
[{"bug_id":"BUG-ع","title":"حفظ رقم الجوال لا يعمل في صفحة الملف الشخصي","layer":"service","criterion_id":"C-1","steps":["افتح الملف الشخصي","اضغط حفظ"],"expected":"يُحفظ الرقم الجديد","actual":"يعود الرقم القديم","evidence":[]}]
EOF
run ar "$R"
grep -q 'حفظ رقم الجوال' "$OUTD/bugs.json" && ok "arabic_title_parity: UTF-8 kept in bugs.json (no \\u escapes)" || no "arabic escaped"
WANT="BUG-$(printf '%s' 'BUG-ع' | python3 -c 'import sys,hashlib;print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])')"
[ -e "$OUTD/$WANT.md" ] && ok "arabic_title_parity: non-ASCII id -> BUG-<sha1 first 8>" || no "unexpected md name: $(ls "$OUTD")"
grep -q 'يعود الرقم القديم' "$OUTD/$WANT.md" && ok "arabic_title_parity: md carries Arabic body" || no "arabic md body"

# --- secrets never exported
R="$(mkrun sec)"; mkdir -p "$W/sec/.qa"
echo '{"enforcement":{"redactedKeys":["hunter2"],"secretPatterns":["token\\s*[=:]\\s*\\S+"]}}' > "$W/sec/.qa/config.json"
JWT='eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl'
cat > "$R/bug-log.json" <<EOF
[{"id":"S-1","password":"p@ss","actual":"login with hunter2 sent token=abc123 to server; header Authorization: Bearer $JWT and Authorization: Basic dXNlcjpwYXNz; also Bearer $JWT alone","expected":"ok","steps":["type hunter2","saw eyJzdWIiOiIxMjM0In0.x.y"],"api_key":"k"}]
EOF
run sec "$R"
if grep -rqE 'hunter2|abc123|p@ss|eyJ|dXNlcjpwYXNz' "$OUTD"; then no "secret leaked"; else ok "secrets: keys dropped, bearer/basic/JWT values redacted"; fi
grep -q '<redacted>' "$OUTD/S-1.md" && ok "secrets: placeholder shown" || no "no placeholder"

echo "bug-export: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
