#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/detecting-interaction-ux/scripts/overlay-stack.js"
NODE="${NODE:-node}"
PASS=0; FAIL=0
check(){ if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
# fieldc <fn> <jsonArgsArray> <key> -> result[key], "null" if result null
fieldc(){ "$NODE" -e 'const m=require(process.argv[1]);const r=m[process.argv[2]].apply(null,JSON.parse(process.argv[3]));process.stdout.write(r==null?"null":String(r[process.argv[4]]))' "$MOD" "$1" "$2" "$3" 2>/dev/null; }
callc(){ "$NODE" -e 'const m=require(process.argv[1]);const r=m[process.argv[2]].apply(null,JSON.parse(process.argv[3]));process.stdout.write(r==null?"null":JSON.stringify(r))' "$MOD" "$1" "$2" 2>/dev/null; }

# module loads under Node without a DOM
check "module loads" "$("$NODE" -e 'require(process.argv[1]);process.stdout.write("ok")' "$MOD" 2>/dev/null)" "ok"

# --- invariant 1: the sheet-stack bug (fixture #1) ---
# before: the deliverables LIST sheet is open. afterOpenChild: the NEW-DELIVERABLE form replaced it (list gone).
BEFORE='[{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true}]'
AFTER='[{"id":"dialog:New Deliverable","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true}]'
check "sheet-stack: parent destroyed -> interaction-overlay-destroyed" \
  "$(fieldc checkStackIntegrity "[$BEFORE,$AFTER,\"dialog:New Deliverable\"]" detector)" "interaction-overlay-destroyed"
# negative control: child STACKS on top of parent (both present) -> null
AFTER_OK='[{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true},{"id":"dialog:New Deliverable","role":"dialog","ariaModal":true,"zIndex":110,"position":"fixed","focusTrapped":true,"parentId":"dialog:Deliverables","present":true}]'
check "stacked correctly -> null" "$(callc checkStackIntegrity "[$BEFORE,$AFTER_OK,\"dialog:New Deliverable\"]")" "null"

# --- invariant 2: return-to-context ---
# after submitting the child, we should land back on the parent list. Empty stack = no return.
check "no return-to-context -> interaction-no-return" \
  "$(fieldc checkReturnToContext '[[],"dialog:Deliverables"]' detector)" "interaction-no-return"
check "returned to parent -> null" \
  "$(callc checkReturnToContext "[$BEFORE,\"dialog:Deliverables\"]")" "null"

# --- invariant 3: no dead-end ---
check "dead-end (empty after close) -> interaction-dead-end" \
  "$(fieldc checkNoDeadEnd '[[]]' detector)" "interaction-dead-end"
check "base context present after close -> null" \
  "$(callc checkNoDeadEnd "[$BEFORE]")" "null"

# --- invariant 4: focus-trap ---
UNTRAPPED='[{"id":"dialog:New Deliverable","role":"dialog","ariaModal":true,"zIndex":110,"position":"fixed","focusTrapped":false,"parentId":null,"present":true}]'
check "modal not focus-trapped -> interaction-focus-untrapped" \
  "$(fieldc checkFocusTrap "[$UNTRAPPED]" detector)" "interaction-focus-untrapped"
check "trapped modal -> null" "$(callc checkFocusTrap "[$AFTER]")" "null"

# --- invariant 5: no destructive-on-open (a NON-parent sibling vanished) ---
BEFORE2='[{"id":"dialog:A","role":"dialog","ariaModal":false,"zIndex":90,"position":"fixed","focusTrapped":false,"parentId":null,"present":true},{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true}]'
AFTER2='[{"id":"dialog:Deliverables","role":"dialog","ariaModal":true,"zIndex":100,"position":"fixed","focusTrapped":true,"parentId":null,"present":true},{"id":"dialog:Child","role":"dialog","ariaModal":true,"zIndex":110,"position":"fixed","focusTrapped":true,"parentId":"dialog:Deliverables","present":true}]'
check "sibling A destroyed on open -> interaction-destructive-on-open" \
  "$(fieldc checkNoDestructiveOnOpen "[$BEFORE2,$AFTER2]" detector)" "interaction-destructive-on-open"

echo "interaction-ux: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
