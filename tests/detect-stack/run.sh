#!/usr/bin/env bash
# Smoke tests for detect-stack.sh. Each case: run the engine against a fixture
# (and/or a fake baseUrl) and assert fields in the emitted stack-profile.json.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../../skills/detecting-stack-profile/scripts/detect-stack.sh"
FIX="$HERE/fixtures"
# Hermetic: point QA_CONFIG at a guaranteed-nonexistent file so the engine's cfg()
# falls back to its built-in defaults instead of inheriting whatever .qa/config.json
# happens to sit in the cwd (the repo ships one with seedableEnvMarker + environment
# set, which otherwise leaks in and forces Case 4's production inference to disposable).
# A case that means to test config behavior sets its own QA_CONFIG.
export QA_CONFIG="$HERE/.no-such-config.json"
PASS=0; FAIL=0
get() { jq -r "$2" "$1" 2>/dev/null; }
check() { # desc, actual, expected
  if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1));
  else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi
}

# Case 1: Laravel fixture, code-based only (no baseUrl)
OUT="$(mktemp)"
QA_REPOS="$FIX/laravel" bash "$ENGINE" --no-runtime --out "$OUT" >/dev/null 2>&1
check "laravel framework"   "$(get "$OUT" '.components[0].framework')"          "laravel"
check "laravel playbook"    "$(get "$OUT" '.components[0].playbook')"           "laravel"
check "laravel orm"         "$(get "$OUT" '.components[0].orm.name')"           "eloquent"
check "laravel frontend"    "$(get "$OUT" '.components[0].frontend.routing')"   "server-bridge"

# Case 2: runtime-only fingerprint from a captured headers file → laravel
OUT2="$(mktemp)"
bash "$ENGINE" --no-code --headers-file "$FIX/server/laravel-headers.txt" --out "$OUT2" >/dev/null 2>&1
check "runtime laravel" "$(get "$OUT2" '.components[0].framework')" "laravel"
check "runtime signal"  "$(get "$OUT2" '.components[0].signal')"     "weak"

# Case 3: unknown repo → generic / weak, still valid JSON
OUT3="$(mktemp)"
QA_REPOS="$FIX/unknown" bash "$ENGINE" --no-runtime --out "$OUT3" >/dev/null 2>&1
check "unknown playbook" "$(get "$OUT3" '.components[0].playbook // "generic"')" "generic"
check "unknown valid"    "$(jq -e . "$OUT3" >/dev/null 2>&1 && echo ok)"          "ok"

# Case 4: prod baseUrl + no repo → environment=production, mode=black-box
OUT4="$(mktemp)"
bash "$ENGINE" --no-code --base-url "https://app.example.com" --headers-file "$FIX/server/laravel-headers.txt" --out "$OUT4" >/dev/null 2>&1
check "prod env"  "$(get "$OUT4" '.environment')" "production"
check "prod mode" "$(get "$OUT4" '.mode')"        "black-box"
check "prod writes off" "$(get "$OUT4" '.notes | index("allowApiWrites forced off (production)") != null')" "true"
check "prod guardrails" "$(get "$OUT4" '.guardrails.requireWriteConfirm')" "true"
check "prod crawl off"  "$(get "$OUT4" '.guardrails.blackboxCrawl')"       "false"

# Case 5: disposable local target → no production guardrails
OUT5="$(mktemp)"
QA_REPOS="$FIX/laravel" bash "$ENGINE" --no-runtime --base-url "http://localhost:8000" --out "$OUT5" >/dev/null 2>&1
check "local env"        "$(get "$OUT5" '.environment')"        "disposable"
check "local guardrails" "$(get "$OUT5" '.guardrails')"         "null"

# Case 6: Laravel i18n mechanism map — php per-locale dirs + flat lang/<locale>.json; non-locale json ignored
OUT6="$(mktemp)"
QA_REPOS="$FIX/laravel" bash "$ENGINE" --no-runtime --out "$OUT6" >/dev/null 2>&1
check "i18n present"      "$(get "$OUT6" '.components[0].i18n.present')"                                        "true"
check "i18n mechanism"    "$(get "$OUT6" '.components[0].i18n.mechanisms | index("laravel-lang") != null')"    "true"
check "i18n signal"       "$(get "$OUT6" '.components[0].i18n.signal')"                                         "strong"
check "i18n locale ar"    "$(get "$OUT6" '.components[0].i18n.locales | index("ar") != null')"                 "true"
check "i18n locale en"    "$(get "$OUT6" '.components[0].i18n.locales | index("en") != null')"                 "true"
check "i18n has php"      "$(get "$OUT6" '[.components[0].i18n.catalogs[].format] | index("php") != null')"    "true"
check "i18n has json"     "$(get "$OUT6" '[.components[0].i18n.catalogs[].format] | index("json") != null')"   "true"
check "i18n file path"    "$(get "$OUT6" '[.components[0].i18n.catalogs[] | select(.format=="php") | .path] | index("lang/ar/messages.php") != null')" "true"
check "i18n namespace"    "$(get "$OUT6" '[.components[0].i18n.catalogs[] | select(.format=="php") | .namespace] | index("messages") != null')" "true"
check "i18n gate config"  "$(get "$OUT6" '.components[0].i18n.locales | index("config") == null')"             "true"

# Case 7: unknown repo → fallback component's i18n degrades to present:false / signal:weak (never fails)
OUT7="$(mktemp)"
QA_REPOS="$FIX/unknown" bash "$ENGINE" --no-runtime --out "$OUT7" >/dev/null 2>&1
check "i18n absent present" "$(get "$OUT7" '.components[0].i18n.present')" "false"
check "i18n absent signal"  "$(get "$OUT7" '.components[0].i18n.signal')"  "weak"

# Case 8: runtime-only component (no repo to scan) still carries a weak i18n map
OUT8="$(mktemp)"
bash "$ENGINE" --no-code --headers-file "$FIX/server/laravel-headers.txt" --out "$OUT8" >/dev/null 2>&1
check "i18n runtime present" "$(get "$OUT8" '.components[0].i18n.present')" "false"
check "i18n runtime signal"  "$(get "$OUT8" '.components[0].i18n.signal')"  "weak"

# Case 9: JS i18n catalog — per-locale JSON subdirs + library read from package.json
OUT9="$(mktemp)"
QA_REPOS="$FIX/react-intl" bash "$ENGINE" --no-runtime --out "$OUT9" >/dev/null 2>&1
check "js i18n present"   "$(get "$OUT9" '.components[0].i18n.present')"                                     "true"
check "js i18n mechanism" "$(get "$OUT9" '.components[0].i18n.mechanisms | index("js-catalog") != null')"   "true"
check "js i18n library"   "$(get "$OUT9" '.components[0].i18n.libraries | index("react-intl") != null')"    "true"
check "js i18n signal"    "$(get "$OUT9" '.components[0].i18n.signal')"                                      "strong"
check "js i18n locale ar" "$(get "$OUT9" '.components[0].i18n.locales | index("ar") != null')"              "true"
check "js i18n json fmt"  "$(get "$OUT9" '[.components[0].i18n.catalogs[].format] | index("json") != null')" "true"
check "js i18n ns"        "$(get "$OUT9" '[.components[0].i18n.catalogs[].namespace] | index("messages") != null')" "true"

# Case 10: fullstack repo (Laravel php + JS json) → BOTH mechanisms, JS library present
OUT10="$(mktemp)"
QA_REPOS="$FIX/fullstack" bash "$ENGINE" --no-runtime --out "$OUT10" >/dev/null 2>&1
check "both mech laravel"  "$(get "$OUT10" '.components[0].i18n.mechanisms | index("laravel-lang") != null')" "true"
check "both mech js"       "$(get "$OUT10" '.components[0].i18n.mechanisms | index("js-catalog") != null')"   "true"
check "both lib react-intl" "$(get "$OUT10" '.components[0].i18n.libraries | index("react-intl") != null')"   "true"

# Case 11: negative control — non-locale json under a scanned root → present:false, "directory present" reason
OUT11="$(mktemp)"
QA_REPOS="$FIX/nolocale" bash "$ENGINE" --no-runtime --out "$OUT11" >/dev/null 2>&1
check "negctrl present"  "$(get "$OUT11" '.components[0].i18n.present')"                                        "false"
check "negctrl reason"   "$(get "$OUT11" '.components[0].i18n.evidence | join(" ") | contains("directory present")')" "true"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
