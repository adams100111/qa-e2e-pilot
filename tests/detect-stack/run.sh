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

# --- audit-2 W1-5: the verbatim bootstrap sentinel never marks disposable ---
# remote baseUrl + environment auto + marker == the old default sentinel -> production
OUT12="$(mktemp)"
CFG12="$(mktemp)"
printf '%s' '{"baseUrl":"https://app.example.com","environment":"auto","seedableEnvMarker":"QA_DISPOSABLE_ENV"}' > "$CFG12"
QA_CONFIG="$CFG12" bash "$ENGINE" --no-code --no-runtime --out "$OUT12" >/dev/null 2>&1
check "bootstrap sentinel marker forces production" "$(get "$OUT12" '.environment')" "production"

# sibling: remote baseUrl + environment auto + a real custom marker -> disposable (custom markers still work)
OUT13="$(mktemp)"
CFG13="$(mktemp)"
printf '%s' '{"baseUrl":"https://app.example.com","environment":"auto","seedableEnvMarker":"MY_DISPOSABLE"}' > "$CFG13"
QA_CONFIG="$CFG13" bash "$ENGINE" --no-code --no-runtime --out "$OUT13" >/dev/null 2>&1
check "custom marker still opts into disposable" "$(get "$OUT13" '.environment')" "disposable"

# --- audit-2 W3-5c: runtime HTML-marker + bounded openapi/fingerprintPaths ---
# probes. Hermetic: a python3 http.server against a fixture dir, started/stopped
# by this suite. Skipped entirely (not silently vacuous-pass) when python3 or
# curl is unavailable on this host.
have() { command -v "$1" >/dev/null 2>&1; }
SERVER_PIDS=()
rt_cleanup() { local pid; for pid in "${SERVER_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done; }
trap rt_cleanup EXIT

start_server() { # <dir> -> echoes "port|logfile|pid"
  local dir="$1" port log pid
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  log="$(mktemp)"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >"$log" 2>&1 &
  pid=$!
  SERVER_PIDS+=("$pid")
  local i=0
  until curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; do
    sleep 0.2; i=$((i+1)); [[ "$i" -gt 25 ]] && break
  done
  printf '%s|%s|%s' "$port" "$log" "$pid"
}

# count GET requests logged against a NON-root path (excludes the base "GET / " fetch)
count_subpath_gets() { # <logfile>
  grep -oE '"GET [^"]+"' "$1" 2>/dev/null | awk '{print $2}' | grep -vc '^/$'
}

if have curl && have python3; then
  FASTCFG="$(mktemp)"
  printf '%s' '{"maxRequestsPerSecond": 1000}' > "$FASTCFG"

  # Case R1: marker hit recorded — nextjs __NEXT_DATA__ marker in the served body
  IFS='|' read -r R1_PORT R1_LOG R1_PID <<< "$(start_server "$FIX/runtime/marker")"
  OUTR1="$(mktemp)"
  QA_CONFIG="$FASTCFG" bash "$ENGINE" --no-code --base-url "http://127.0.0.1:$R1_PORT" --out "$OUTR1" >/dev/null 2>&1
  check "marker hit: framework nextjs"  "$(get "$OUTR1" '.components[0].framework')" "nextjs"
  check "marker hit: signal strong"     "$(get "$OUTR1" '.components[0].signal')"    "strong"
  check "marker hit: evidence recorded" "$(get "$OUTR1" '.components[0].evidence | join(" ") | contains("html marker __NEXT_DATA__")')" "true"
  kill "$R1_PID" 2>/dev/null

  # Case R2: openapi probe hit recorded — /openapi.json served, no cookie/header signal at all
  IFS='|' read -r R2_PORT R2_LOG R2_PID <<< "$(start_server "$FIX/runtime/openapi")"
  OUTR2="$(mktemp)"
  QA_CONFIG="$FASTCFG" bash "$ENGINE" --no-code --base-url "http://127.0.0.1:$R2_PORT" --out "$OUTR2" >/dev/null 2>&1
  check "openapi hit: framework fastapi" "$(get "$OUTR2" '.components[0].framework')" "fastapi"
  check "openapi hit: signal strong"     "$(get "$OUTR2" '.components[0].signal')"    "strong"
  check "openapi hit: evidence recorded" "$(get "$OUTR2" '.components[0].evidence | join(" ") | contains("openapi probe hit /openapi.json")')" "true"
  check "openapi hit: request logged"    "$(grep -qc '"GET /openapi.json' "$R2_LOG" && echo yes)" "yes"
  kill "$R2_PID" 2>/dev/null

  # Case R3: noProbePaths excludes a path — /openapi.json exists on the server but
  # is listed in noProbePaths, so it must never be requested and never match.
  NOPROBECFG="$(mktemp)"
  printf '%s' '{"maxRequestsPerSecond": 1000, "noProbePaths": ["/openapi.json"]}' > "$NOPROBECFG"
  IFS='|' read -r R3_PORT R3_LOG R3_PID <<< "$(start_server "$FIX/runtime/noprobe")"
  OUTR3="$(mktemp)"
  QA_CONFIG="$NOPROBECFG" bash "$ENGINE" --no-code --base-url "http://127.0.0.1:$R3_PORT" --out "$OUTR3" >/dev/null 2>&1
  check "noProbePaths: excluded path never requested" "$(grep -qc '"GET /openapi.json' "$R3_LOG" && echo yes || echo no)" "no"
  check "noProbePaths: no false match from excluded path" "$(get "$OUTR3" '.components[0].framework')" "generic"
  kill "$R3_PID" 2>/dev/null

  # Case R4: cap-at-4 enforced — 5 surviving candidates (6 unique signature
  # openapiPaths minus 1 excluded via noProbePaths) -> exactly 4 GET requests.
  CAPCFG="$(mktemp)"
  printf '%s' '{"maxRequestsPerSecond": 1000, "noProbePaths": ["/api-json"]}' > "$CAPCFG"
  IFS='|' read -r R4_PORT R4_LOG R4_PID <<< "$(start_server "$FIX/runtime/cap")"
  OUTR4="$(mktemp)"
  QA_CONFIG="$CAPCFG" bash "$ENGINE" --no-code --base-url "http://127.0.0.1:$R4_PORT" --out "$OUTR4" >/dev/null 2>&1
  check "cap-at-4: exactly 4 probe requests" "$(count_subpath_gets "$R4_LOG")" "4"
  kill "$R4_PID" 2>/dev/null

  # Case R5: no-network / no-curl degrades cleanly — curl masked from PATH,
  # jq (and the rest of the engine's toolchain) still present. Must still emit
  # valid JSON with a weak/generic fallback, never a hard failure.
  BASH_BIN="$(command -v bash)"
  RTFAKEBIN="$(mktemp -d)"
  for tool in jq python3 grep sed awk date find head paste seq cat dirname basename mkdir sort; do
    tp="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tp" ]] && ln -sf "$tp" "$RTFAKEBIN/$tool"
  done
  OUTR5="$(mktemp)"
  RC5=0
  PATH="$RTFAKEBIN" QA_CONFIG="$FASTCFG" "$BASH_BIN" "$ENGINE" --no-code --base-url "http://127.0.0.1:1" --out "$OUTR5" >/dev/null 2>&1 || RC5=$?
  check "no-curl degrade: exit 0"      "$RC5" "0"
  check "no-curl degrade: valid json"  "$(jq -e . "$OUTR5" >/dev/null 2>&1 && echo ok)" "ok"
  check "no-curl degrade: framework generic" "$(get "$OUTR5" '.components[0].framework')" "generic"
  check "no-curl degrade: signal weak"       "$(get "$OUTR5" '.components[0].signal')"    "weak"
else
  echo "SKIP - audit-2 W3-5c runtime probe suite: curl/python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
