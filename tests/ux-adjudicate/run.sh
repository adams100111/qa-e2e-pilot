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
check "grade i18n-locale-date"     "$(grade i18n-locale-date)"     "definite-catalog"
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

# --- behavioral-observed grade (interaction family, sub-plan B) ---
check "grade interaction-overlay-destroyed" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("interaction-overlay-destroyed"))' "$MOD")" "behavioral-observed"
check "behavioral observed-only -> fail low"  "$(field adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x->destroyed"},{}]' 'confidence')" "low"
check "behavioral observed-only -> fail verdict" "$(field adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x"},{}]' 'verdict')" "fail"
check "behavioral corroborated -> fail high" "$(field adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x"},{"corroborated":true}]' 'confidence')" "high"
check "behavioral known-deliberate -> null" "$(call adjudicate '[{"detector":"interaction-overlay-destroyed","rawSignal":"x"},{"knownDeliberate":[{"detector":"interaction-overlay-destroyed","rawSignal":"x"}]}]')" "null"


# --- explicit critic-* grade (layer-3 generative critic, advisory-only guarantee) ---
check "grade critic-layout-off" "$(grade critic-layout-off)" "heuristic"
check "critic suspicion advisory" "$(field adjudicate '[{"detector":"critic-layout-off","rawSignal":"x"},{}]' 'advisory')" "true"
check "critic suspicion corroborated -> fail high" "$(field adjudicate '[{"detector":"critic-layout-off","rawSignal":"x"},{"corroborated":true}]' 'confidence')" "high"

# --- W3-2 completeness: every id ux-detectors.js's DETECT() can emit must adjudicate to its
# intended grade, not the default. Two known mismatches (audit-2): `asset-broken-image` fell
# through 'broken-image's definite-dom prefix (position-0 prefix match, no match -> default
# 'heuristic'), and `overlap-modal-behind-backdrop` matched the 'overlap' heuristic prefix
# BEFORE 'modal-behind-backdrop' could ever be considered. This case enumerates the STATIC
# (non-dynamic) suspicion-id literals straight out of ux-detectors.js's source -- so a newly
# added detector id that nobody wired into ORACLE_GRADES fails here instead of silently
# degrading to 'heuristic' -- plus the dynamic content-<kind> family's known kinds, each
# checked against a COMMITTED expectation table.
DET="$HERE/../../skills/detecting-visual-ux/scripts/ux-detectors.js"

# Static suspicion('id', ...) literals emitted by DETECT(), scraped from source. The dynamic
# 'content-' + sig.kind family is excluded here (its prefix literal is never itself an emitted
# id) and enumerated by hand below instead.
ACTUAL_LITERAL_IDS="$(grep -oE "suspicion\('[a-zA-Z0-9_-]+'" "$DET" | sed -E "s/suspicion\('//; s/'$//" | grep -v '^content-$' | sort -u)"
EXPECT_LITERAL_IDS="$(printf '%s\n' \
  broken-image \
  content-empty-required-label \
  i18n-locale-date \
  i18n-raw-key \
  i18n-script-mismatch \
  invisible-text \
  modal-behind-backdrop \
  overlap-controls | sort -u)"
check "completeness: static suspicion ids match the committed set (no undeclared drift)" \
  "$ACTUAL_LITERAL_IDS" "$EXPECT_LITERAL_IDS"

# Committed expectation table: detector id -> intended oracle grade (W3-2 authority: detector
# ids ARE the graded prefixes; adjudicate.js's ORACLE_GRADES is unchanged).
declare -A EXPECT_GRADE=(
  [broken-image]=definite-dom
  [content-empty-required-label]=definite-dom
  [i18n-locale-date]=definite-catalog
  [i18n-raw-key]=definite-dom
  [i18n-script-mismatch]=definite-catalog
  [invisible-text]=definite-dom
  [modal-behind-backdrop]=definite-dom
  [overlap-controls]=heuristic
  # dynamic content-<kind> family (contentOracleSignal's committed kinds; Task 2 above pins them)
  [content-null]=definite-dom
  [content-undefined]=definite-dom
  [content-nan]=definite-dom
  [content-object-object]=definite-dom
  [content-currency-nan]=definite-dom
  [content-invalid-date]=definite-dom
  [content-raw-interp]=definite-dom
  [content-raw-iso]=definite-dom
)
for id in "${!EXPECT_GRADE[@]}"; do
  check "completeness grade: $id -> ${EXPECT_GRADE[$id]}" "$(grade "$id")" "${EXPECT_GRADE[$id]}"
done

echo; echo "ux-adjudicate: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
