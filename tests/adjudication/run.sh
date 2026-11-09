#!/usr/bin/env bash
# Dual-engine tests for skills/re-adjudicating-verdicts/scripts/adjudication.sh
# (select / bundle / apply / capability). Records are written through the real
# checkpoint.sh so apply is exercised against the same journal + fold path a run uses.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SH="$ROOT/skills/re-adjudicating-verdicts/scripts/adjudication.sh"
CP="$ROOT/skills/checkpointing-qa-memory/scripts/checkpoint.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: adjudication: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
TAB="$(printf '\t')"

# rec <project> <crit> <persona> <field> — one field of a checkpoint record.
rec() {
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
m=[r for r in d["criteria"] if r["criterion_id"]==sys.argv[2] and r["persona"]==sys.argv[3]]
print(m[0][sys.argv[4]] if m else "<none>")' "$1/.qa/runs/r1/checkpoint.json" "$2" "$3" "$4"
}

# make_fx -> prints a fresh project dir holding run r1.
make_fx() {
  local P; P="$(mktemp -d)"; TMPDIRS+=("$P")
  local R="$P/.qa/runs/r1"
  mkdir -p "$R/evidence/admin/C-LOW" "$R/evidence/C-UX"
  ( cd "$P" || exit 1
    bash "$CP" r1 C-LOW pass --confidence low --persona admin --last-action "saw the green toast so it worked" >/dev/null 2>&1
    bash "$CP" r1 C-HIGH pass --confidence high --last-action "list rendered" >/dev/null 2>&1
    bash "$CP" r1 C-UX fail --confidence high --last-action "button overflows its card" >/dev/null 2>&1
    bash "$CP" r1 C-UXBAKE fail --confidence high --kinds bake --last-action "row missing" >/dev/null 2>&1
    bash "$CP" r1 C-PLAINFAIL fail --confidence high --last-action "banner absent" >/dev/null 2>&1
    bash "$CP" r1 C-BLK blocked --confidence low --last-action "page did not load" >/dev/null 2>&1
  )
  # The plan is written after the records so the un-gated fixture passes skip the
  # required-kinds gate (happy-path derives bake); adjudication reads it afterwards.
  cat > "$R/checklist.json" <<'JSON'
[
  {"id":"C-LOW","surface":"/projects","kind":"happy-path","tags":[],"action":"view the project list","role":"admin"},
  {"id":"C-HIGH","surface":"/projects","kind":"happy-path","tags":[],"action":"view the project detail","role":"admin"},
  {"id":"C-UX","surface":"/projects","kind":"happy-path","tags":["visual-ux"],"action":"view the project list layout","role":"admin"},
  {"id":"C-UXBAKE","surface":"/projects","kind":"happy-path","tags":["ux-revisit"],"action":"view the project list","role":"admin"},
  {"id":"C-PLAINFAIL","surface":"/projects","kind":"error-state","tags":[],"action":"view the error banner","role":"admin"},
  {"id":"C-BLK","surface":"/projects","kind":"happy-path","tags":[],"action":"view the archive","role":"admin"}
]
JSON
  printf '{"entity":"Project","rows":[{"id":7,"name":"عداد المياه الذكي"}]}' > "$R/evidence/admin/C-LOW/bake-read-back.json"
  printf 'PNGDATA' > "$R/evidence/admin/C-LOW/screenshot-after.png"
  printf '{"sha256":"x","phase":"after"}' > "$R/evidence/admin/C-LOW/screenshot-after.json"
  printf 'agent notes: saw the green toast so it worked\n' > "$R/evidence/admin/C-LOW/notes.md"
  printf '{"event":"x"}\n' > "$R/evidence/admin/C-LOW/journal.ndjson"
  printf '{"tool":"browser_click"}\n' > "$R/evidence/admin/C-LOW/toolstream.jsonl"
  printf '{"persona":"admin","capturedSubject":"faisal.alharbi@innovation-lab.co","method":"whoami"}' > "$R/evidence/admin/identity.json"
  echo "$P"
}

run_engine() {
  local E="$1" P R out rc err
  adj(){ QA_ENGINE=$E bash "$SH" "$@"; }

  # --- select_low_conf_passes ------------------------------------------------
  P="$(make_fx)"; R="$P/.qa/runs/r1"
  check "$E fixture C-LOW recorded" "$(rec "$P" C-LOW admin verdict)" "pass"
  out="$(adj select "$R")"; rc=$?
  check "$E select_low_conf_passes rc" "$rc" "0"
  check "$E select_low_conf_passes ids" "$out" "C-LOW${TAB}admin${TAB}low-confidence-pass
C-UX${TAB}${TAB}ux-promoted-fail"
  printf '%s' "$out" > "$P/select.$E"

  # --- bundle_excludes_journal_and_prose -------------------------------------
  out="$(adj bundle "$R" C-LOW "$P/b" --persona admin)"; rc=$?
  check "$E bundle rc" "$rc" "0"
  check "$E bundle row" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$P/b/criterion.json")" "C-LOW"
  check "$E bundle claim" "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d,sort_keys=True))' "$P/b/claim.json")" \
    '{"claims": [{"confidence": "low", "kinds": [], "persona": "admin", "verdict": "pass"}], "criterionId": "C-LOW"}'
  check "$E bundle bake copied" "$([ -s "$P/b/evidence/admin/C-LOW/bake-read-back.json" ] && echo y)" "y"
  check "$E bundle screenshot copied" "$([ -s "$P/b/evidence/admin/C-LOW/screenshot-after.png" ] && echo y)" "y"
  check "$E bundle identity copied" "$([ -s "$P/b/evidence/admin/identity.json" ] && echo y)" "y"
  check "$E bundle_excludes_journal_and_prose journal/toolstream/md" \
    "$(find "$P/b" \( -name journal.ndjson -o -name toolstream.jsonl -o -name '*.md' \) | wc -l | tr -d ' ')" "0"
  check "$E bundle_excludes_journal_and_prose no lastAction prose" \
    "$(grep -rlE 'green toast|last_action|lastAction' "$P/b" | wc -l | tr -d ' ')" "0"
  check "$E bundle arabic kept" "$(grep -c 'عداد المياه الذكي' "$P/b/evidence/admin/C-LOW/bake-read-back.json")" "1"
  cp "$P/b/claim.json" "$P/claim.$E"; cp "$P/b/criterion.json" "$P/criterion.$E"
  adj bundle "$R" C-NOPE "$P/b2" >/dev/null 2>"$P/err"; rc=$?
  check "$E bundle unknown rc" "$rc" "1"
  check "$E bundle unknown msg" "$(grep -c '^ADJUDICATION: unknown criterion' "$P/err")" "1"
  adj bundle "$R" C-LOW "$P/b" --persona admin >/dev/null 2>&1; rc=$?
  check "$E bundle non-empty out refused" "$rc" "2"
  adj bundle "$R" ../x "$P/b3" >/dev/null 2>&1; rc=$?
  check "$E bundle unsafe id refused" "$rc" "2"

  # --- apply_disagree_downgrades_to_blocked ----------------------------------
  printf '[{"criterionId":"C-LOW","persona":"admin","agree":false,"reason":"bake shows no new project row"}]' > "$P/d1.json"
  out="$(adj apply "$R" "$P/d1.json" 2>"$P/err")"; rc=$?
  check "$E apply_disagree_downgrades_to_blocked rc" "$rc" "0"
  check "$E apply_disagree verdict" "$(rec "$P" C-LOW admin verdict)" "blocked"
  check "$E apply_disagree confidence" "$(rec "$P" C-LOW admin confidence)" "low"
  check "$E apply_disagree last_action" "$(rec "$P" C-LOW admin last_action)" "verifier-disagrees: bake shows no new project row"
  check "$E apply_disagree phase" "$(rec "$P" C-LOW admin phase)" "adjudicate"
  check "$E apply_disagree summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=1 noop=0 rejected=0 failed=0"
  # re-applying the same decisions is a no-op (already not a pass)
  out="$(adj apply "$R" "$P/d1.json" 2>/dev/null)"; rc=$?
  check "$E apply idempotent rc" "$rc" "0"
  check "$E apply idempotent summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=0 noop=1 rejected=0 failed=0"
  check "$E select after downgrade" "$(adj select "$R")" "C-UX${TAB}${TAB}ux-promoted-fail"

  # disputed UX fail: stays fail, confidence drops to low
  printf '[{"criterionId":"C-UX","persona":"","agree":false,"reason":"screenshot shows the button inside its card"}]' > "$P/d2.json"
  # a record-time gate refusal inside checkpoint.sh is reported, never swallowed:
  # a browser-driven run (toolstream with browser_* calls) refuses a fail with no screenshot.
  printf '{"tool":"browser_click"}\n' > "$R/toolstream.jsonl"
  out="$(adj apply "$R" "$P/d2.json" 2>"$P/err")"; rc=$?
  check "$E apply gate refusal rc" "$rc" "1"
  check "$E apply gate refusal reported" "$(grep -c '^ADJUDICATION: checkpoint.sh refused C-UX: .*SCREENSHOT GATE' "$P/err")" "1"
  check "$E apply gate refusal summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=0 noop=0 rejected=0 failed=1"
  rm -f "$R/toolstream.jsonl"
  adj apply "$R" "$P/d2.json" >/dev/null 2>"$P/err"; rc=$?
  check "$E apply disagree on fail rc" "$rc" "0"
  check "$E apply disagree on fail verdict" "$(rec "$P" C-UX "" verdict)" "fail"
  check "$E apply disagree on fail confidence" "$(rec "$P" C-UX "" confidence)" "low"

  # --- apply_upgrade_refused --------------------------------------------------
  P="$(make_fx)"; R="$P/.qa/runs/r1"
  cp "$R/checkpoint.json" "$P/cp.before"
  printf '[{"criterionId":"C-HIGH","persona":"","agree":false,"reason":"no read-back"},{"criterionId":"C-BLK","persona":"","agree":true,"reason":"","verdict":"pass"}]' > "$P/d3.json"
  adj apply "$R" "$P/d3.json" >/dev/null 2>"$P/err"; rc=$?
  check "$E apply_upgrade_refused rc" "$rc" "1"
  check "$E apply_upgrade_refused msg" "$(grep -c '^ADJUDICATION: upgrades are not allowed' "$P/err")" "1"
  check "$E apply_upgrade_refused nothing written" "$(cmp -s "$R/checkpoint.json" "$P/cp.before" && echo same)" "same"
  printf '[{"criterionId":"C-LOW","persona":"admin","agree":true,"reason":"ok","confidence":"high"}]' > "$P/d4.json"
  adj apply "$R" "$P/d4.json" >/dev/null 2>"$P/err"; rc=$?
  check "$E apply confidence upgrade refused rc" "$rc" "1"
  check "$E apply confidence upgrade refused msg" "$(grep -c '^ADJUDICATION: upgrades are not allowed' "$P/err")" "1"
  printf '[{"criterionId":"C-UX","persona":"","agree":false,"reason":"looks fine","verdict":"blocked"}]' > "$P/d5.json"
  adj apply "$R" "$P/d5.json" >/dev/null 2>"$P/err"; rc=$?
  check "$E apply lifting a fail refused rc" "$rc" "1"
  check "$E apply lifting a fail refused unchanged" "$(rec "$P" C-UX "" verdict)/$(rec "$P" C-UX "" confidence)" "fail/high"

  # --- apply_agree_noop -------------------------------------------------------
  printf '[{"criterionId":"C-HIGH","persona":"","agree":true,"reason":"bake row present"},{"criterionId":"C-LOW","persona":"admin","agree":true,"reason":"matches"}]' > "$P/d6.json"
  out="$(adj apply "$R" "$P/d6.json" 2>"$P/err")"; rc=$?
  check "$E apply_agree_noop rc" "$rc" "0"
  check "$E apply_agree_noop unchanged" "$(cmp -s "$R/checkpoint.json" "$P/cp.before" && echo same)" "same"
  check "$E apply_agree_noop summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=0 noop=2 rejected=0 failed=0"

  # --- apply_unknown_criterion_rejected --------------------------------------
  printf '[{"criterionId":"C-NOPE","persona":"","agree":false,"reason":"r"},{"criterionId":"C-LOW","persona":"admin","agree":false,"reason":"no read-back of the new row"},{"criterionId":"C-HIGH","agree":false,"reason":"r"},{"criterionId":"C-LOW","persona":"viewer","agree":false,"reason":"r"},"junk"]' > "$P/d7.json"
  out="$(adj apply "$R" "$P/d7.json" 2>"$P/err")"; rc=$?
  check "$E apply_unknown_criterion_rejected rc" "$rc" "1"
  check "$E apply_unknown_criterion_rejected unknown reported" "$(grep -c '^ADJUDICATION: rejected entry 0 (C-NOPE): unknown criterion' "$P/err")" "1"
  check "$E apply_unknown_criterion_rejected missing persona reported" "$(grep -c '^ADJUDICATION: rejected entry 2 (C-HIGH): persona missing' "$P/err")" "1"
  check "$E apply_unknown_criterion_rejected wrong persona reported" "$(grep -c '^ADJUDICATION: rejected entry 3 (C-LOW@viewer): unknown criterion' "$P/err")" "1"
  check "$E apply_unknown_criterion_rejected junk reported" "$(grep -c '^ADJUDICATION: rejected entry 4: entry is not an object' "$P/err")" "1"
  check "$E apply_unknown_criterion_rejected others applied" "$(rec "$P" C-LOW admin verdict)" "blocked"
  check "$E apply_unknown_criterion_rejected C-HIGH untouched" "$(rec "$P" C-HIGH "" verdict)/$(rec "$P" C-HIGH "" confidence)" "pass/high"
  check "$E apply_unknown_criterion_rejected no stray persona row" "$(rec "$P" C-LOW viewer verdict)" "<none>"
  check "$E apply_unknown_criterion_rejected summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=1 noop=0 rejected=4 failed=0"
  printf '{"criterionId":"C-LOW"}' > "$P/d8.json"
  adj apply "$R" "$P/d8.json" >/dev/null 2>&1; rc=$?
  check "$E apply non-array refused" "$rc" "2"

  # --- capability -------------------------------------------------------------
  P="$(make_fx)"; R="$P/.qa/runs/r1"
  check "$E capability claude" "$(adj capability claude "$R")" "available"
  out="$(adj capability codex "$R")"; rc=$?
  check "$E capability codex rc" "$rc" "0"
  check "$E capability codex banner" "$out" "re-adjudication unavailable on codex; 1 low-confidence passes unreviewed"
  check "$E capability unknown harness" "$(adj capability nosuch)" "re-adjudication unavailable on nosuch; 0 low-confidence passes unreviewed"
  check "$E capability no profiles claude" "$(QA_HARNESS_PROFILES="$P/none.json" adj capability claude)" "available"
  check "$E capability no profiles pi" "$(QA_HARNESS_PROFILES="$P/none.json" adj capability pi)" "re-adjudication unavailable on pi; 0 low-confidence passes unreviewed"

  echo "$P" > "$PARITY_DIR/$E"
  # keep the select/bundle outputs of the first fixture for the parity check
}

PARITY_DIR="$(mktemp -d)"; TMPDIRS+=("$PARITY_DIR")
engines=()
command -v jq >/dev/null 2>&1 && engines+=(jq)
command -v python3 >/dev/null 2>&1 && engines+=(python3)
for E in "${engines[@]}"; do run_engine "$E"; done

# --- engine parity: select + bundle output byte-identical across engines -----
if [ "${#engines[@]}" -eq 2 ]; then
  P="$(make_fx)"; R="$P/.qa/runs/r1"
  QA_ENGINE=jq bash "$SH" select "$R" > "$P/s.jq"; QA_ENGINE=python3 bash "$SH" select "$R" > "$P/s.py"
  check "parity select" "$(cmp -s "$P/s.jq" "$P/s.py" && echo same)" "same"
  QA_ENGINE=jq bash "$SH" bundle "$R" C-LOW "$P/bj" >/dev/null; QA_ENGINE=python3 bash "$SH" bundle "$R" C-LOW "$P/bp" >/dev/null
  check "parity bundle tree" "$(diff -r "$P/bj" "$P/bp" >/dev/null && echo same)" "same"
fi

echo "adjudication: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
