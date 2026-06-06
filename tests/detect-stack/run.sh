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

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
