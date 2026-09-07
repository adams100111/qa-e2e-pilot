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
# W3-5a: extractOverlayStack() appends a base-context descriptor (baseContext:true) to every
# captured stack. Clean-close fixture: all overlays correctly closed AND the base context is
# healthy -> NOT a dead-end (this used to false-fail: an empty overlay stack alone tripped the
# check, indistinguishable from a true dead-end).
BASE_HEALTHY='[{"id":"__base-context__","role":"base-context","baseContext":true,"present":true}]'
check "clean close: overlays empty, base context healthy -> null (no false dead-end)" \
  "$(callc checkNoDeadEnd "[$BASE_HEALTHY]")" "null"
# Negative control: overlays empty AND the base context is itself missing/inert -> still a
# true dead-end, suspicion stands.
BASE_INERT='[{"id":"__base-context__","role":"base-context","baseContext":true,"present":false}]'
check "true dead-end: overlays empty, base context missing/inert -> interaction-dead-end" \
  "$(fieldc checkNoDeadEnd "[$BASE_INERT]" detector)" "interaction-dead-end"

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

# --- regression coverage: the trailing base-context descriptor (real extractOverlayStack()
# shape) must be INVISIBLE to all four invariant checkers below (checkNoDeadEnd is the only
# one that looks at it). Reviewer-found CRITICAL: topmost()'s `>=` tie-break let the
# base-context descriptor (zIndex defaults to 0/undefined) beat a genuinely untrapped modal
# whose own computed z-index also resolved to 0, so checkFocusTrap returned null instead of
# flagging it. Every invariant checker now strips baseContext entries via overlaysOnly()
# before doing anything else — these fixtures feed the REAL trailing-descriptor shape through
# all five checkers to prove that stays true.
BASE='{"id":"__base-context__","role":"base-context","baseContext":true,"present":true}'

# invariant 4 (checkFocusTrap) — THE regression case: an untrapped modal at zIndex 0, plus the
# trailing base descriptor. Before the fix, the base descriptor (zIndex 0) won the topmost()
# tie-break over the modal (also zIndex 0) and this returned null; it must return the finding.
UNTRAPPED_Z0="[{\"id\":\"dialog:X\",\"role\":\"dialog\",\"ariaModal\":true,\"zIndex\":0,\"focusTrapped\":false,\"present\":true},$BASE]"
check "REGRESSION: untrapped modal at zIndex 0 + base descriptor -> interaction-focus-untrapped" \
  "$(fieldc checkFocusTrap "[$UNTRAPPED_Z0]" detector)" "interaction-focus-untrapped"
# and the base descriptor must not itself ever surface as the "trapped" topmost when it's the
# only entry (no real overlay open) -> null, not a spurious finding.
check "base descriptor alone (no real overlay) -> null, not a spurious focus-trap finding" \
  "$(callc checkFocusTrap "[$BASE]")" "null"

# invariant 1 (checkStackIntegrity) smoke with the real trailing descriptor in both snapshots.
# (append BASE to each bare-array fixture by swapping its closing ']' for ',$BASE]')
BEFORE_WB="${BEFORE%]},$BASE]"
AFTER_WB="${AFTER%]},$BASE]"
AFTER_OK_WB="${AFTER_OK%]},$BASE]"
check "smoke: checkStackIntegrity with trailing base descriptor, stacked correctly -> null" \
  "$(callc checkStackIntegrity "[$BEFORE_WB,$AFTER_OK_WB,\"dialog:New Deliverable\"]")" "null"
check "smoke: checkStackIntegrity with trailing base descriptor, parent destroyed -> interaction-overlay-destroyed" \
  "$(fieldc checkStackIntegrity "[$BEFORE_WB,$AFTER_WB,\"dialog:New Deliverable\"]" detector)" "interaction-overlay-destroyed"

# invariant 2 (checkReturnToContext) smoke with the real trailing descriptor — the base
# descriptor being present must NOT be mistaken for "returned to the expected parent".
check "smoke: checkReturnToContext with trailing base descriptor, no return -> interaction-no-return" \
  "$(fieldc checkReturnToContext "[[$BASE],\"dialog:Deliverables\"]" detector)" "interaction-no-return"
check "smoke: checkReturnToContext with trailing base descriptor, parent present -> null" \
  "$(callc checkReturnToContext "[$BEFORE_WB,\"dialog:Deliverables\"]")" "null"

# invariant 5 (checkNoDestructiveOnOpen) smoke with the real trailing descriptor in both
# snapshots — must not suppress (or spuriously trigger from) the base descriptor's presence.
BEFORE2_WB="${BEFORE2%]},$BASE]"
AFTER2_WB="${AFTER2%]},$BASE]"
check "smoke: checkNoDestructiveOnOpen with trailing base descriptor, sibling destroyed -> interaction-destructive-on-open" \
  "$(fieldc checkNoDestructiveOnOpen "[$BEFORE2_WB,$AFTER2_WB]" detector)" "interaction-destructive-on-open"

echo "interaction-ux: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
