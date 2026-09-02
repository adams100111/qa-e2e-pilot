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

# --- Task 2: content / data-rendering ------------------------------------------
check "content: [object Object] kind"   "$(field contentOracleSignal '["Owner: [object Object]"]' kind)"       "object-object"
check 'content: $NaN kind'              "$(field contentOracleSignal '["Total: $NaN"]' kind)"                  "currency-nan"
# Whole-cell bare literals: fires ONLY when the entire trimmed direct text IS the literal.
check "content: NaN kind (whole-cell)"       "$(field contentOracleSignal '["NaN"]' kind)"                    "nan"
check "content: NaN rawSignal clean"         "$(field contentOracleSignal '["NaN"]' rawSignal)"               "NaN"
check "content: Invalid Date kind"      "$(field contentOracleSignal '["Due Invalid Date"]' kind)"             "invalid-date"
check "content: undefined kind (whole-cell)" "$(field contentOracleSignal '["undefined"]' kind)"               "undefined"
check "content: null kind (whole-cell)"      "$(field contentOracleSignal '["null"]' kind)"                   "null"
check "content: raw interp kind"        "$(field contentOracleSignal '["Hello {{ user.name }}"]' kind)"        "raw-interp"
check "content: raw ISO kind"           "$(field contentOracleSignal '["2026-09-02T14:33:00Z"]' kind)"         "raw-iso"
# negative controls: clean rendered values -> null (zero findings)
check "content: clean name -> null"     "$(call contentOracleSignal '["Alice Smith"]')"                        "null"
check "content: clean money -> null"    "$(call contentOracleSignal '["$1,240.00"]')"                          "null"
check "content: clean count -> null"    "$(call contentOracleSignal '["12 items"]')"                           "null"
check "content: bare date -> null"      "$(call contentOracleSignal '["2026-09-02"]')"                         "null"
check "content: humanized date -> null" "$(call contentOracleSignal '["Jan 3, 2026"]')"                        "null"
# Q2 adversarial: prose containing a bare literal NOT in value position -> null (a human
# reads "The null hypothesis" as prose, never a rendering bug). Value-position stays flagged.
check "content: prose null -> null"     "$(call contentOracleSignal '["The null hypothesis"]')"                "null"
check "content: prose undefined -> null" "$(call contentOracleSignal '["a truly undefined concept in math"]')" "null"
# Whole-cell precision fix regression guard: a longer string merely ENDING in the bare literal
# (realistic prose, not a data slot) must NOT fire -- a human QA doesn't flag help-text ending
# in "NaN". These previously false-positived under the old trailing-token regex.
check "content: prose ending in NaN -> null"        "$(call contentOracleSignal '["The result is NaN"]')"                "null"
check "content: prose ending in undefined -> null"  "$(call contentOracleSignal '["This field is undefined"]')"          "null"
check "content: prose ending in null -> null"       "$(call contentOracleSignal '["Value is null"]')"                    "null"
check "content: prose ending in NaN (2) -> null"    "$(call contentOracleSignal '["Division by zero returns NaN"]')"     "null"
# empty-required-label core
check "content: empty label -> true"    "$(call isEmptyRequiredLabel '["   "]')"                               "true"
check "content: real label -> false"    "$(call isEmptyRequiredLabel '["Email"]')"                             "false"

# --- Task 3: i18n-script -------------------------------------------------------
# raw translation key (whole-label dotted identifier)
check "i18n: raw key rawSignal"          "$(field rawTranslationKeySignal '["deliverables.title"]' rawSignal)"   "deliverables.title"
check "i18n: nested raw key"             "$(field rawTranslationKeySignal '["common.buttons.save"]' rawSignal)"  "common.buttons.save"
check "i18n: label with space -> null"   "$(call rawTranslationKeySignal '["Save changes"]')"                    "null"
check "i18n: domain -> null"             "$(call rawTranslationKeySignal '["www.example.com"]')"                  "null"
check "i18n: email -> null"              "$(call rawTranslationKeySignal '["user@site.com"]')"                    "null"
check "i18n: decimal -> null"            "$(call rawTranslationKeySignal '["3.14"]')"                             "null"
# Q4 adversarial: version strings, ccTLD domains, and file names are NOT translation keys
check "i18n: version v1.2.3 -> null"     "$(call rawTranslationKeySignal '["v1.2.3"]')"                           "null"
check "i18n: ccTLD domain -> null"       "$(call rawTranslationKeySignal '["example.co.uk"]')"                    "null"
check "i18n: source file -> null"        "$(call rawTranslationKeySignal '["Component.tsx"]')"                    "null"
# script mismatch vs expected locale
check "i18n: ar expected, latin text"    "$(field scriptMismatchSignal '["Save changes","ar"]' expectedScript)"  "Arabic"
check "i18n: ar expected, arabic text"   "$(call scriptMismatchSignal '["حفظ التغييرات","ar"]')"                 "null"
check "i18n: en expected (latin) -> null" "$(call scriptMismatchSignal '["Save changes","en"]')"                  "null"
check "i18n: too short -> null"          "$(call scriptMismatchSignal '["OK","ar"]')"                             "null"
check "i18n: ru expected, latin text"    "$(field scriptMismatchSignal '["Sohranit izmeneniya","ru"]' expectedScript)" "Cyrillic"
# Q3 adversarial: a human does NOT flag a brand/acronym on an Arabic page as untranslated
check "i18n: ar + brand GitHub -> null"  "$(call scriptMismatchSignal '["GitHub","ar"]')"                        "null"
check "i18n: ar + acronym PDF -> null"   "$(call scriptMismatchSignal '["PDF","ar"]')"                           "null"
check "i18n: ar + URL -> null"           "$(call scriptMismatchSignal '["https://example.com","ar"]')"           "null"

# --- Critical fix 1: script-mismatch must catch Title-Case prose (false-NEGATIVE) --------
# Title-Case / lowercase multi-word English phrases are prose and MUST fire on locale ar.
check "i18n: ar + Title-Case 'Save Changes' -> fires"   "$(field scriptMismatchSignal '["Save Changes","ar"]' expectedScript)"   "Arabic"
check "i18n: ar + Title-Case 'Sign In' -> fires"        "$(field scriptMismatchSignal '["Sign In","ar"]' expectedScript)"        "Arabic"
check "i18n: ar + Title-Case 'Contact Us' -> fires"     "$(field scriptMismatchSignal '["Contact Us","ar"]' expectedScript)"     "Arabic"
check "i18n: ar + Title-Case 'Delete Account' -> fires" "$(field scriptMismatchSignal '["Delete Account","ar"]' expectedScript)" "Arabic"
check "i18n: ar + Title-Case 'View Details' -> fires"   "$(field scriptMismatchSignal '["View Details","ar"]' expectedScript)"   "Arabic"
# existing lowercase phrase must still fire (regression guard)
check "i18n: ar + lowercase 'Save changes' -> fires"    "$(field scriptMismatchSignal '["Save changes","ar"]' expectedScript)"   "Arabic"
# still exempt: single-token brands, ALLCAPS acronyms, CamelCase/product names, URLs, emails, code
check "i18n: ar + brand GitHub -> still null"       "$(call scriptMismatchSignal '["GitHub","ar"]')"                    "null"
check "i18n: ar + acronym PDF -> still null"        "$(call scriptMismatchSignal '["PDF","ar"]')"                       "null"
check "i18n: ar + product 'iPhone 15' -> still null" "$(call scriptMismatchSignal '["iPhone 15","ar"]')"                "null"
check "i18n: ar + acronym OK -> still null"         "$(call scriptMismatchSignal '["OK","ar"]')"                        "null"
check "i18n: ar + URL x.com -> still null"          "$(call scriptMismatchSignal '["https://x.com","ar"]')"             "null"
check "i18n: ar + email a@b.com -> still null"      "$(call scriptMismatchSignal '["a@b.com","ar"]')"                   "null"
check "i18n: ar + Component.tsx -> still null"      "$(call scriptMismatchSignal '["Component.tsx","ar"]')"             "null"

# --- Critical fix 2: raw-key must NOT fire on PascalCase.PascalCase (false-POSITIVE) -----
check "i18n: React.Component -> no finding"  "$(call rawTranslationKeySignal '["React.Component"]')"          "null"
check "i18n: Foo.Bar -> no finding"          "$(call rawTranslationKeySignal '["Foo.Bar"]')"                  "null"
check "i18n: Error.NotFound -> no finding"   "$(call rawTranslationKeySignal '["Error.NotFound"]')"            "null"
# real keys still fire
check "i18n: deliverables.title still fires" "$(field rawTranslationKeySignal '["deliverables.title"]' rawSignal)" "deliverables.title"
check "i18n: foo.bar.baz still fires"        "$(field rawTranslationKeySignal '["foo.bar.baz"]' rawSignal)"        "foo.bar.baz"
check "i18n: user.profile.name still fires"  "$(field rawTranslationKeySignal '["user.profile.name"]' rawSignal)"  "user.profile.name"
# Q4 exemptions stay green
check "i18n: v1.2.3 -> still null"           "$(call rawTranslationKeySignal '["v1.2.3"]')"                    "null"
check "i18n: example.co.uk -> still null"    "$(call rawTranslationKeySignal '["example.co.uk"]')"             "null"
check "i18n: Component.tsx -> still null"    "$(call rawTranslationKeySignal '["Component.tsx"]')"             "null"
check "i18n: app.py -> still null"           "$(call rawTranslationKeySignal '["app.py"]')"                    "null"
check "i18n: a@b.com -> still null"          "$(call rawTranslationKeySignal '["a@b.com"]')"                   "null"
check "i18n: www.example.com -> still null"  "$(call rawTranslationKeySignal '["www.example.com"]')"           "null"
check "i18n: 3.14 -> still null"             "$(call rawTranslationKeySignal '["3.14"]')"                      "null"

# --- Fix: lone-lowercase untranslated word must still fire; lone Title-Case/brand stays exempt ---
# Prior fix's `wordTokens.length < 2` guard exempted lone Title-Case brands ("Dashboard","GitHub")
# but over-exempted lone LOWERCASE prose words too. A lone all-lowercase word still reads as
# translatable prose to a human ("loading", "search", "changes") and must fire on locale ar.
check "i18n: ar + lone lowercase 'loading' -> fires" "$(field scriptMismatchSignal '["loading","ar"]' expectedScript)" "Arabic"
check "i18n: ar + lone lowercase 'search' -> fires"  "$(field scriptMismatchSignal '["search","ar"]' expectedScript)"  "Arabic"
check "i18n: ar + lone lowercase 'changes' -> fires" "$(field scriptMismatchSignal '["changes","ar"]' expectedScript)" "Arabic"
# lone Title-Case / brand / acronym stays exempt (prior fix's intent preserved)
check "i18n: ar + lone Title-Case 'Dashboard' -> still null" "$(call scriptMismatchSignal '["Dashboard","ar"]')" "null"
check "i18n: ar + lone brand 'GitHub' -> still null"          "$(call scriptMismatchSignal '["GitHub","ar"]')"    "null"
check "i18n: ar + lone acronym 'PDF' -> still null"           "$(call scriptMismatchSignal '["PDF","ar"]')"       "null"
check "i18n: ar + lone acronym 'OK' -> still null"            "$(call scriptMismatchSignal '["OK","ar"]')"        "null"
# Title-Case multi-word phrases from the prior fix still fire (no regression)
check "i18n: ar + Title-Case 'Save Changes' -> still fires" "$(field scriptMismatchSignal '["Save Changes","ar"]' expectedScript)" "Arabic"
check "i18n: ar + Title-Case 'Sign In' -> still fires"       "$(field scriptMismatchSignal '["Sign In","ar"]' expectedScript)"       "Arabic"

# --- Task 4: assets + invisible-text -------------------------------------------
check "asset: failed image -> true"     "$(call isBrokenImage '[{"naturalWidth":0,"complete":true}]')"          "true"
check "asset: loaded image -> false"    "$(call isBrokenImage '[{"naturalWidth":120,"complete":true}]')"        "false"
check "asset: still-loading -> false"   "$(call isBrokenImage '[{"naturalWidth":0,"complete":false}]')"         "false"
check "invisible: white-on-white ratio" "$(field invisibleTextSignal '[{"r":255,"g":255,"b":255},{"r":255,"g":255,"b":255}]' ratio)" "1"
check "invisible: near-equal fires"     "$(field invisibleTextSignal '[{"r":118,"g":118,"b":118},{"r":119,"g":119,"b":119}]' ratio)" "1.01"
check "invisible: black-on-white -> null" "$(call invisibleTextSignal '[{"r":0,"g":0,"b":0},{"r":255,"g":255,"b":255}]')"           "null"
check "invisible: mid-contrast -> null" "$(call invisibleTextSignal '[{"r":17,"g":17,"b":17},{"r":255,"g":255,"b":255}]')"          "null"

# --- Task 5: overlap / z-index -------------------------------------------------
check "z: modal below backdrop -> true"  "$(call modalBehindBackdrop '[10,100]')"    "true"
check "z: modal above backdrop -> false" "$(call modalBehindBackdrop '[1000,999]')"  "false"
check "z: equal -> false"                "$(call modalBehindBackdrop '[50,50]')"     "false"
check "collide: overlapping -> true"     "$(call rectsCollide '[{"left":0,"top":0,"right":50,"bottom":50},{"left":25,"top":25,"right":75,"bottom":75}]')" "true"
check "collide: adjacent -> false"       "$(call rectsCollide '[{"left":0,"top":0,"right":50,"bottom":50},{"left":50,"top":0,"right":100,"bottom":50}]')" "false"
check "frac: contained -> 1"             "$(call rectOverlapFraction '[{"left":0,"top":0,"right":100,"bottom":100},{"left":10,"top":10,"right":30,"bottom":30}]')" "1"
check "frac: adjacent -> 0"              "$(call rectOverlapFraction '[{"left":0,"top":0,"right":50,"bottom":50},{"left":50,"top":0,"right":100,"bottom":50}]')" "0"

echo; echo "ux-detectors tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
