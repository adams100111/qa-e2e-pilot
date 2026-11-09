#!/usr/bin/env bash
# Dual-engine tests for skills/detecting-visual-ux/scripts/ux-sweep.sh — the ux-sweep.json run artifact
# (objective UX defects on surfaces with no visual-ux row): dedup on surface + detector + selector,
# atomic rewrite, validation, list, and jq/python3 byte parity.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/../../skills/detecting-visual-ux/scripts/ux-sweep.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: ux-sweep: needs jq or python3" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

F1='{"surfaceId":"GET /notifications#sheet:panel","detector":"i18n-script-mismatch","selector":"#notif-list > li:nth-child(1)","message":"Latin text on an ar page","axis":"ux-suspicion","variant":{"viewport":"mobile","locale":"ar","colorScheme":"dark","extra":"x"},"observedIn":"ux-get-notifications-1a2b3c4d","verdict":"fail"}'
F1B='{"surfaceId":"GET /notifications#sheet:panel","detector":"i18n-script-mismatch","selector":"#notif-list > li:nth-child(1)","message":"seen again"}'
F2='{"surfaceId":"GET /notifications#sheet:panel","detector":"contrast","selector":"#notif-list .time","message":"Contrast 2.1:1 below WCAG AA 4.5:1 (SC 1.4.3)","axis":"ux-objective"}'

run_engine() {
  local E="$1" R="$WORK/$1" out rc
  mkdir -p "$R"
  check "$E list on a run with no file" "$(QA_ENGINE=$E bash "$SH" list "$R")" "[]"
  check "$E add first finding" "$(QA_ENGINE=$E bash "$SH" add "$R" "$F1")" "added"
  check "$E same surface+detector+selector is deduplicated" "$(QA_ENGINE=$E bash "$SH" add "$R" "$F1B")" "exists"
  printf '%s' "$F2" > "$R/f2.json"
  check "$E add from @file" "$(QA_ENGINE=$E bash "$SH" add "$R" "@$R/f2.json")" "added"
  check "$E two entries kept in order" "$(QA_ENGINE=$E bash "$SH" list "$R" | jq -r '[.[].detector] | join(",")')" "i18n-script-mismatch,contrast"
  check "$E first-seen message kept" "$(jq -r '.outsidePlan[0].message' "$R/ux-sweep.json")" "Latin text on an ar page"
  check "$E unknown keys dropped, variant filtered" "$(jq -c '.outsidePlan[0] | [has("verdict"), .variant]' "$R/ux-sweep.json")" '[false,{"colorScheme":"dark","locale":"ar","viewport":"mobile"}]'
  check "$E file shape" "$(jq -c '[.version, (.outsidePlan | length)]' "$R/ux-sweep.json")" "[1,2]"
  check "$E no temp or lock left behind" "$(ls -A "$R" | grep -c '^\.ux-sweep')" "0"
  QA_ENGINE=$E bash "$SH" add "$R" '{"surfaceId":"page:Home","detector":"contrast"}' >/dev/null 2>&1; rc=$?
  check "$E missing selector refused (exit 1)" "$rc" "1"
  QA_ENGINE=$E bash "$SH" add "$R" '[1,2]' >/dev/null 2>&1; rc=$?
  check "$E non-object refused" "$rc" "1"
  check "$E refused add leaves the file unchanged" "$(jq -c '.outsidePlan | length' "$R/ux-sweep.json")" "2"
  long="$(printf 'x%.0s' $(seq 1 300))"
  QA_ENGINE=$E bash "$SH" add "$R" "{\"surfaceId\":\"page:Home\",\"detector\":\"target-size\",\"selector\":\"#menu\",\"message\":\"$long\"}" >/dev/null
  check "$E message capped at 200" "$(jq -r '.outsidePlan[2].message | length' "$R/ux-sweep.json")" "200"
  mkdir -p "$R/bad"; printf '%s' '{"outsidePlan":"nope"}' > "$R/bad/ux-sweep.json"
  QA_ENGINE=$E bash "$SH" add "$R/bad" "$F2" >/dev/null 2>&1; rc=$?
  check "$E malformed existing file refused" "$rc" "1"
  check "$E malformed file not overwritten" "$(cat "$R/bad/ux-sweep.json")" '{"outsidePlan":"nope"}'
  mkdir -p "$R/arr"; printf '%s' '[{"surfaceId":"page:Home","detector":"contrast","selector":"#a"}]' > "$R/arr/ux-sweep.json"
  check "$E bare-array file is read and deduplicated" "$(QA_ENGINE=$E bash "$SH" add "$R/arr" '{"surfaceId":"page:Home","detector":"contrast","selector":"#a"}')" "exists"
  bash "$SH" add >/dev/null 2>&1; rc=$?; check "$E usage error exit 2" "$rc" "2"
  QA_ENGINE=$E bash "$SH" add "$WORK/nope" "$F1" >/dev/null 2>&1; rc=$?; check "$E missing run dir exit 1" "$rc" "1"
  # parallel lanes: 8 concurrent adds of distinct selectors all land
  mkdir -p "$R/par"
  for i in 1 2 3 4 5 6 7 8; do
    QA_ENGINE=$E bash "$SH" add "$R/par" "{\"surfaceId\":\"page:Home\",\"detector\":\"contrast\",\"selector\":\"#c$i\"}" >/dev/null &
  done
  wait
  check "$E concurrent adds lose nothing" "$(jq '.outsidePlan | length' "$R/par/ux-sweep.json")" "8"
}

command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  check "jq and python3 write byte-identical files" "$(cmp -s "$WORK/jq/ux-sweep.json" "$WORK/python3/ux-sweep.json" && echo same || echo diff)" "same"
fi
echo "---"; echo "ux-sweep: PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
