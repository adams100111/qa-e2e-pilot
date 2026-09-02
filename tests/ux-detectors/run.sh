#!/usr/bin/env bash
# Tests for ux-detectors.js PURE family cores (DOM-free, plain Node — no jsdom).
# The browser DOM walk (DETECT) is validated by node --check + the accuracy-harness
# fixture browser run; these tests exercise the pure predicate cores behind each family.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/detecting-visual-ux/scripts/ux-detectors.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# call <exportName> <jsonArgsArray>  -> prints JSON.stringify(result); "null" when null.
call() { node -e 'const m=require(process.argv[1]);const f=m[process.argv[2]];const a=JSON.parse(process.argv[3]);const r=f.apply(null,a);process.stdout.write(r===null?"null":JSON.stringify(r));' "$MOD" "$1" "$2" 2>/dev/null; }
# field <exportName> <jsonArgsArray> <key> -> prints result[key]; "null" when result is null.
field() { node -e 'const m=require(process.argv[1]);const f=m[process.argv[2]];const a=JSON.parse(process.argv[3]);const r=f.apply(null,a);process.stdout.write(r==null?"null":String(r[process.argv[4]]));' "$MOD" "$1" "$2" "$3" 2>/dev/null; }

# --- Task 1: dual-mode module loads under Node and shared color cores work -------
check "module requires under node (no document)" \
  "$(node -e 'require(process.argv[1]);process.stdout.write("ok")' "$MOD" 2>/dev/null)" "ok"
check "contrastRatio black-on-white ~21" \
  "$(node -e 'const{contrastRatio}=require(process.argv[1]);process.stdout.write(contrastRatio({r:0,g:0,b:0},{r:255,g:255,b:255}).toFixed(1))' "$MOD" 2>/dev/null)" "21.0"
check "parseRGB parses rgb()" \
  "$(field parseRGB '["rgb(255, 0, 0)"]' r)" "255"
# Q6: DETECT() end-to-end — stub the handful of globals it touches on an EMPTY document
# and assert it runs without throwing and returns an array (the browser completion-value
# contract, exercised in Node — not just node --check syntax).
check "DETECT() returns an array on an empty document" \
  "$(node -e 'const m=require(process.argv[1]);
    global.document={querySelectorAll:function(){return [];},querySelector:function(){return null;},getElementById:function(){return null;},documentElement:{getAttribute:function(){return null;}}};
    global.getComputedStyle=function(){return {};};
    const r=m.DETECT();process.stdout.write(Array.isArray(r)?"array":"NOT-ARRAY");' "$MOD" 2>/dev/null)" "array"

echo; echo "ux-detectors tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
