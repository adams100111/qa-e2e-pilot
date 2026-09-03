#!/usr/bin/env bash
# Tests for adjudicate.js pure classifier (DOM-free, plain Node — no jsdom).
# Mirrors the helper style of tests/ux-detectors/run.sh: call()/field() apply the
# named export to a JSON-parsed args array; scalar-returning functions (oracleGradeFor,
# deliberateKey) are exercised via a direct node -e one-liner, same as ux-detectors does
# for contrastRatio/parseRGB.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/detecting-visual-ux/scripts/adjudicate.js"
NODE="${NODE:-node}"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# call <exportName> <jsonArgsArray>  -> prints JSON.stringify(result); "null" when null.
call() { node -e 'const m=require(process.argv[1]);const f=m[process.argv[2]];const a=JSON.parse(process.argv[3]);const r=f.apply(null,a);process.stdout.write(r===null?"null":JSON.stringify(r));' "$MOD" "$1" "$2" 2>/dev/null; }
# field <exportName> <jsonArgsArray> <key> -> prints result[key]; "null" when result is null.
field() { node -e 'const m=require(process.argv[1]);const f=m[process.argv[2]];const a=JSON.parse(process.argv[3]);const r=f.apply(null,a);process.stdout.write(r==null?"null":String(r[process.argv[4]]));' "$MOD" "$1" "$2" "$3" 2>/dev/null; }
# grade <detector> -> prints oracleGradeFor(detector) directly (scalar string return).
grade() { node -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor(process.argv[2]))' "$MOD" "$1" 2>/dev/null; }

# --- oracleGradeFor: the table (longest-prefix-wins) -----------------------------
check "grade content-nan"          "$(grade content-nan)"          "definite-dom"
check "grade i18n-raw-key"         "$(grade i18n-raw-key)"         "definite-dom"
check "grade broken-image"         "$(grade broken-image)"         "definite-dom"
check "grade invisible-text"       "$(grade invisible-text)"       "definite-dom"
check "grade modal-behind-backdrop" "$(grade modal-behind-backdrop)" "definite-dom"
check "grade content-raw-iso"      "$(grade content-raw-iso)"      "definite-dom"
check "grade i18n-script-mismatch" "$(grade i18n-script-mismatch)" "definite-catalog"
check "grade overlap"              "$(grade overlap)"              "heuristic"
check "grade unknown->heuristic"   "$(grade something-new)"        "heuristic"

# --- adjudicate: definite-dom -> fail@FE high, needs no source ------------------
check "nan verdict"    "$(field adjudicate '[{"detector":"content-nan","rawSignal":"NaN"},{}]' 'verdict')"       "fail"
check "nan layer"      "$(field adjudicate '[{"detector":"content-nan","rawSignal":"NaN"},{}]' 'suspectedLayer')" "FE"
check "nan conf high"  "$(field adjudicate '[{"detector":"content-nan","rawSignal":"NaN"},{}]' 'confidence')"    "high"
check "raw-key high even black-box" "$(field adjudicate '[{"detector":"i18n-raw-key","rawSignal":"deliverables.title"},{"hasSource":false}]' 'confidence')" "high"
check "invisible-text high" "$(field adjudicate '[{"detector":"invisible-text","rawSignal":"1.02"},{}]' 'confidence')" "high"

# --- adjudicate: heuristic (overlap) -> advisory unless corroborated ------------
check "overlap advisory"              "$(field adjudicate '[{"detector":"overlap","rawSignal":"0.30"},{}]' 'advisory')"                     "true"
check "overlap corroborated->verdict" "$(field adjudicate '[{"detector":"overlap","rawSignal":"0.30"},{"corroborated":true}]' 'verdict')"    "fail"
check "overlap corroborated conf"     "$(field adjudicate '[{"detector":"overlap","rawSignal":"0.30"},{"corroborated":true}]' 'confidence')" "high"

# --- adjudicate: definite-catalog -> depends on catalogResult -------------------
check "i18n gap -> fail high"  "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"missing"}]' 'confidence')" "high"
check "i18n legit-latin -> null (deliberate, dropped)" "$(call adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"GitHub"},{"catalogResult":"present-latin-legit"}]')" "null"
check "i18n suspected-untranslated sparse -> advisory" "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"present-latin-eq-en","catalogCompleteness":0.2}]' 'advisory')" "true"
check "i18n suspected-untranslated in complete catalog -> fail high" "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"present-latin-eq-en","catalogCompleteness":0.95}]' 'confidence')" "high"
check "i18n no-catalog (black-box) -> advisory" "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"no-catalog"}]' 'advisory')" "true"

# --- known-deliberate short-circuit: any grade -> dropped (null) ----------------
KD='[{"detector":"content-raw-iso","rawSignal":"2026-09-02T00:00:00Z"}]'
check "known-deliberate -> null" "$(call adjudicate "[{\"detector\":\"content-raw-iso\",\"rawSignal\":\"2026-09-02T00:00:00Z\"},{\"knownDeliberate\":$KD}]")" "null"
check "deliberateKey shape" "$(node -e 'process.stdout.write(require(process.argv[1]).deliberateKey({detector:"content-nan",rawSignal:"NaN"}))' "$MOD" 2>/dev/null)" $'content-nan␟NaN'

# --- deriveCatalogResult: the catalog record -> canonical result string ---
dcr() { "$NODE" -e 'process.stdout.write(String(require(process.argv[1]).deriveCatalogResult(JSON.parse(process.argv[2]))))' "$MOD" "$1"; }
check "no catalog record -> no-catalog" "$(dcr 'null')" "no-catalog"
check "absent key -> missing"        "$(dcr '{"presentInTarget":false}')" "missing"
check "present empty -> empty"       "$(dcr '{"presentInTarget":true,"targetValue":""}')" "empty"
check "present technical Latin -> legit" "$(dcr '{"presentInTarget":true,"targetValue":"GitHub","enValue":"GitHub","isTechnical":true}')" "present-latin-legit"
check "present Latin == en prose -> eq-en" "$(dcr '{"presentInTarget":true,"targetValue":"Save","enValue":"Save","isTechnical":false}')" "present-latin-eq-en"
check "present Arabic (differs from en, non-latin) -> translated" "$(dcr '{"presentInTarget":true,"targetValue":"حفظ","enValue":"Save","isTechnical":false}')" "present-translated"
check "present Latin != en (localized to another latin lang) -> translated" "$(dcr '{"presentInTarget":true,"targetValue":"Enregistrer","enValue":"Save","isTechnical":false}')" "present-translated"

echo; echo "ux-adjudicate: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
