#!/usr/bin/env bash
# Dual-engine tests for skills/re-adjudicating-verdicts/scripts/adjudication.sh
# (select / bundle / apply / capability). Records are written through the real
# checkpoint.sh so apply is exercised against the same journal + fold path a run uses.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SH="$ROOT/skills/re-adjudicating-verdicts/scripts/adjudication.sh"
CP="$ROOT/skills/checkpointing-qa-memory/scripts/checkpoint.sh"
RE="$ROOT/skills/checkpointing-qa-memory/scripts/record-evidence.sh"
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
v=m[0].get(sys.argv[4]) if m else "<none>"
print(json.dumps(v, ensure_ascii=False) if isinstance(v,(list,dict)) else v)' "$1/.qa/runs/r1/checkpoint.json" "$2" "$3" "$4"
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
  # not record-evidence outputs: never bundled (allow-list)
  printf 'scratch\n' > "$R/evidence/admin/C-LOW/random.txt"
  printf '{"summary":"saw the green toast"}' > "$R/evidence/admin/C-LOW/agent-summary.json"
  printf 'x' > "$R/evidence/admin/C-LOW/screenshot-after.png.bak"
  mkdir -p "$R/evidence/admin/C-LOW/scratch" "$R/evidence/admin/C-LOW/findings"
  printf '{"k":1}' > "$R/evidence/admin/C-LOW/scratch/bake-read-back.json"
  printf '{"status":500,"url":"/api/projects"}' > "$R/evidence/admin/C-LOW/findings/net-1.json"
  ln -s ../../../checkpoint.json "$R/evidence/admin/C-LOW/screenshot-link.json"
  echo "$P"
}

# add_secret_trace <run-dir> — an action trace on C-LOW that typed a password
# (step target #password), an api token (fill_form field api_token, camelCase
# apiKeyToken) and ordinary data that must stay visible to the verifier.
add_secret_trace() {
  cat > "$1/evidence/admin/C-LOW/action-trace.json" <<'JSON'
{"criterion_id":"C-LOW","steps":[
 {"tool":"browser_type","target":"#email","text":"faisal.alharbi@innovation-lab.co"},
 {"tool":"browser_type","target":"#password","text":"Riyadh#Pass2026"},
 {"tool":"browser_fill_form","fields":[
   {"name":"city","value":"الرياض"},
   {"field":"api_token","value":"tok-abc123secret"},
   {"name":"apiKeyToken","value":"tok-camel-777"}]},
 {"tool":"browser_type","element":"Login code","inputType":"password","value":"tok-otp-31337"},
 {"tool":"browser_select_option","name":"pin_code","values":["4321-pin-secret"]},
 "not-a-step"]}
JSON
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
  # --- unknown_file_not_bundled ----------------------------------------------
  check "$E unknown_file_not_bundled tree" "$(cd "$P/b" && find . \( -type f -o -type l \) | LC_ALL=C sort | tr '\n' ' ')" \
    "./claim.json ./criterion.json ./evidence/admin/C-LOW/bake-read-back.json ./evidence/admin/C-LOW/findings/net-1.json ./evidence/admin/C-LOW/screenshot-after.json ./evidence/admin/C-LOW/screenshot-after.png ./evidence/admin/identity.json "
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
  printf '[{"criterionId":"C-LOW","persona":"admin","agree":true,"reason":"matches"}]' > "$P/d6.json"
  out="$(adj apply "$R" "$P/d6.json" 2>"$P/err")"; rc=$?
  check "$E apply_agree_noop rc" "$rc" "0"
  check "$E apply_agree_noop unchanged" "$(cmp -s "$R/checkpoint.json" "$P/cp.before" && echo same)" "same"
  check "$E apply_agree_noop summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=0 noop=1 rejected=0 failed=0"

  # --- apply_rejects_unselected (M3): a record select does not list is refused,
  # even a high-confidence pass or a plain (non-UX) fail; the rest still apply.
  printf '[{"criterionId":"C-HIGH","persona":"","agree":false,"reason":"no read-back"},{"criterionId":"C-PLAINFAIL","persona":"","agree":false,"reason":"banner visible"},{"criterionId":"C-HIGH","persona":"","agree":true,"reason":"fine"}]' > "$P/d6b.json"
  out="$(adj apply "$R" "$P/d6b.json" 2>"$P/err")"; rc=$?
  check "$E apply_rejects_unselected rc" "$rc" "1"
  check "$E apply_rejects_unselected msg" "$(grep -c '^ADJUDICATION: rejected entry [0-9] (C-[A-Z]*): not selected for re-adjudication' "$P/err")" "3"
  check "$E apply_rejects_unselected unchanged" "$(cmp -s "$R/checkpoint.json" "$P/cp.before" && echo same)" "same"
  check "$E apply_rejects_unselected summary" "$(printf '%s\n' "$out" | tail -1)" "adjudication: applied=0 noop=0 rejected=3 failed=0"

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

  # --- evidence_refs_survive_disputed_pass + nonUiActionReason kept + comma ids ---
  P="$(mktemp -d)"; TMPDIRS+=("$P"); R="$P/.qa/runs/r1"
  ( cd "$P" || exit 1
    bash "$RE" r1 C-REFS computed --oracle 1250 --observed 1250 --match true >/dev/null 2>&1
    bash "$CP" r1 C-REFS pass --confidence low --kinds computed --evidence-refs evidence/C-REFS/recompute.json --last-action "total matched" >/dev/null 2>&1
    bash "$CP" r1 C-NU fail --confidence high --nonui-reason "the drag handle is canvas-drawn; the driver cannot reach it" --last-action "card did not move" >/dev/null 2>&1
    bash "$CP" r1 'C,UX2' fail --confidence high --last-action "label clipped" >/dev/null 2>&1
  )
  printf '%s' '[{"id":"C-REFS","surface":"/budget","kind":"computed-logic","tags":[],"action":"see the remaining budget","role":"admin"},{"id":"C-NU","surface":"/board","kind":"happy-path","tags":["interaction-ux"],"action":"drag the card to done","role":"admin"},{"id":"C,UX2","surface":"/budget","kind":"happy-path","tags":["visual-ux"],"action":"view the budget card","role":"admin"}]' > "$R/checklist.json"
  check "$E fixture C-REFS recorded" "$(rec "$P" C-REFS "" verdict)/$(rec "$P" C-REFS "" confidence)" "pass/low"
  check "$E fixture C-NU nonui" "$(rec "$P" C-NU "" confidence)" "low"
  check "$E rows_keep_commas_in_ids select" "$(adj select "$R")" "C-REFS${TAB}${TAB}low-confidence-pass
C-NU${TAB}${TAB}ux-promoted-fail
C,UX2${TAB}${TAB}ux-promoted-fail"
  printf '[{"criterionId":"C-REFS","persona":"","agree":false,"reason":"recompute oracle is the backend formula"},{"criterionId":"C-NU","persona":"","agree":false,"reason":"screenshot shows the card moved"}]' > "$P/d9.json"
  out="$(adj apply "$R" "$P/d9.json" 2>"$P/err")"; rc=$?
  check "$E evidence_refs_survive_disputed_pass rc" "$rc" "0"
  check "$E evidence_refs_survive_disputed_pass verdict" "$(rec "$P" C-REFS "" verdict)/$(rec "$P" C-REFS "" confidence)" "blocked/low"
  check "$E evidence_refs_survive_disputed_pass refs" "$(rec "$P" C-REFS "" evidence_refs)" '["evidence/C-REFS/recompute.json"]'
  check "$E evidence_refs_survive_disputed_pass kinds" "$(rec "$P" C-REFS "" kinds)" '["computed"]'
  check "$E nonui_reason_kept_on_disputed_fail" "$(rec "$P" C-NU "" nonUiActionReason)" "the drag handle is canvas-drawn; the driver cannot reach it"
  check "$E nonui disputed fail last_action" "$(rec "$P" C-NU "" last_action)" "verifier-disagrees: screenshot shows the card moved"

  # --- select_uses_verification_confidence (M2): the record as the report shows it
  P="$(make_fx)"; R="$P/.qa/runs/r1"
  printf '%s' '[{"criterionId":"C-HIGH","persona":"","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"low","reasons":["identity unverifiable"]},{"criterionId":"C-LOW","persona":"admin","inRunVerdict":"pass","verifierVerdict":"fail","confidence":"high","reasons":["no-state-evidence"]},{"criterionId":"C-UX","persona":"","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"low","reasons":[]},{"criterionId":"__run__","persona":"","inRunVerdict":"pass","verifierVerdict":"pass","confidence":"low"}]' > "$R/verification.json"
  check "$E select_uses_verification_confidence" "$(adj select "$R")" "C-HIGH${TAB}${TAB}low-confidence-pass
C-UX${TAB}${TAB}ux-promoted-fail"
  check "$E capability counts verification confidence" "$(adj capability codex "$R")" "re-adjudication unavailable on codex; 1 low-confidence passes unreviewed"
  printf '[{"criterionId":"C-HIGH","persona":"","agree":false,"reason":"identity of the acting user not shown"}]' > "$P/dv.json"
  adj apply "$R" "$P/dv.json" >/dev/null 2>"$P/err"; rc=$?
  check "$E apply verifier-lowered pass rc" "$rc" "0"
  check "$E apply verifier-lowered pass verdict" "$(rec "$P" C-HIGH "" verdict)/$(rec "$P" C-HIGH "" confidence)" "blocked/low"
  printf '[{"criterionId":"C-LOW","persona":"admin","agree":false,"reason":"r"}]' > "$P/dv2.json"
  adj apply "$R" "$P/dv2.json" >/dev/null 2>"$P/err"; rc=$?
  check "$E apply verifier-overridden pass not selected rc" "$rc" "1"
  check "$E apply verifier-overridden pass untouched" "$(rec "$P" C-LOW admin verdict)" "pass"
  printf '[]' > "$R/verification.json"
  check "$E select empty verification" "$(adj select "$R")" "C-LOW${TAB}admin${TAB}low-confidence-pass
C-UX${TAB}${TAB}ux-promoted-fail"
  printf 'not json' > "$R/verification.json"
  check "$E select unreadable verification falls back" "$(adj select "$R")" "C-LOW${TAB}admin${TAB}low-confidence-pass
C-UX${TAB}${TAB}ux-promoted-fail"

  # --- capability -------------------------------------------------------------
  P="$(make_fx)"; R="$P/.qa/runs/r1"
  check "$E capability claude" "$(adj capability claude "$R")" "available"
  out="$(adj capability codex "$R")"; rc=$?
  check "$E capability codex rc" "$rc" "0"
  check "$E capability codex banner" "$out" "re-adjudication unavailable on codex; 1 low-confidence passes unreviewed"
  check "$E capability unknown harness" "$(adj capability nosuch)" "re-adjudication unavailable on nosuch; 0 low-confidence passes unreviewed"
  check "$E capability no profiles claude" "$(QA_HARNESS_PROFILES="$P/none.json" adj capability claude)" "available"
  printf '%s' '{"harnesses":{"x1":{"dispatch":"via the Agent/Task tool, prose only"},"x2":{"subagentDispatch":true},"x3":{"subagentDispatch":"true"}}}' > "$P/prof.json"
  check "$E capability_reads_boolean prose without flag" "$(QA_HARNESS_PROFILES="$P/prof.json" adj capability x1)" "re-adjudication unavailable on x1; 0 low-confidence passes unreviewed"
  check "$E capability_reads_boolean flag true" "$(QA_HARNESS_PROFILES="$P/prof.json" adj capability x2)" "available"
  check "$E capability_reads_boolean string is not true" "$(QA_HARNESS_PROFILES="$P/prof.json" adj capability x3)" "re-adjudication unavailable on x3; 0 low-confidence passes unreviewed"
  check "$E capability opencode" "$(adj capability opencode)" "re-adjudication unavailable on opencode; 0 low-confidence passes unreviewed"
  check "$E capability no profiles pi" "$(QA_HARNESS_PROFILES="$P/none.json" adj capability pi)" "re-adjudication unavailable on pi; 0 low-confidence passes unreviewed"

  # --- bundle_redacts_secret_typed_values -----------------------------------
  P="$(make_fx)"; R="$P/.qa/runs/r1"; add_secret_trace "$R"
  adj bundle "$R" C-LOW "$P/bs" --persona admin >/dev/null 2>&1; rc=$?
  check "$E bundle_redacts_secret_typed_values rc" "$rc" "0"
  check "$E bundle_redacts_secret_typed_values trace present" "$([ -s "$P/bs/evidence/admin/C-LOW/action-trace.json" ] && echo y)" "y"
  check "$E bundle_redacts_secret_typed_values no secret anywhere" \
    "$(grep -rlE 'Riyadh#Pass2026|tok-abc123secret|tok-camel-777|tok-otp-31337|4321-pin-secret' "$P/bs" | wc -l | tr -d ' ')" "0"
  check "$E bundle_redacts_secret_typed_values redacted marks" "$(grep -o '\[redacted\]' "$P/bs/evidence/admin/C-LOW/action-trace.json" | wc -l | tr -d ' ')" "5"
  check "$E bundle_redacts_secret_typed_values ordinary data kept" \
    "$(grep -c -e 'faisal.alharbi@innovation-lab.co' -e 'الرياض' "$P/bs/evidence/admin/C-LOW/action-trace.json")" "2"
  check "$E bundle_redacts_secret_typed_values original untouched" "$(grep -c 'Riyadh#Pass2026' "$R/evidence/admin/C-LOW/action-trace.json")" "1"
  printf 'not json {' > "$R/evidence/admin/C-LOW/action-trace.json"
  adj bundle "$R" C-LOW "$P/bs2" --persona admin >/dev/null 2>&1; rc=$?
  check "$E bundle unparseable trace rc" "$rc" "0"
  check "$E bundle unparseable trace left out" "$([ -e "$P/bs2/evidence/admin/C-LOW/action-trace.json" ] && echo y || echo n)" "n"

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
  add_secret_trace "$R"
  QA_ENGINE=jq bash "$SH" bundle "$R" C-LOW "$P/tj" >/dev/null; QA_ENGINE=python3 bash "$SH" bundle "$R" C-LOW "$P/tp" >/dev/null
  check "parity redacted trace" "$(diff -r "$P/tj" "$P/tp" >/dev/null && echo same)" "same"
fi

echo "adjudication: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
