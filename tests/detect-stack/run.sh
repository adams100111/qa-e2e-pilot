#!/usr/bin/env bash
# Smoke tests for detect-stack.sh. Each case: run the engine against a fixture
# (and/or a fake baseUrl) and assert fields in the emitted stack-profile.json.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../../skills/detecting-stack-profile/scripts/detect-stack.sh"
FIX="$HERE/fixtures"
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

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
