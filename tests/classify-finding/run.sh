#!/usr/bin/env bash
# Tests for scripts/classify-finding.sh — the deterministic origin/status
# classifier that replaces agent judgement about whether an observed browser
# error belongs to the application under test (plan
# 2026-09-23-error-honesty-invariants, Task 2).
#
# What is pinned here (these output strings are a CONTRACT consumed by the
# findings ledger and qa-verify.sh):
#   (A) stdout is exactly two lines, in order:
#         originClass=<in-scope|third-party|benign>
#         statusClass=<fatal|non-fatal>
#   (B) statusClass=fatal IFF status >= 500, or the literal
#       `unhandled-exception`, or the literal `page-crash`. 3xx/4xx are
#       recorded, never fatal (plan decision R1).
#   (C) origin equal to baseUrl's origin (scheme+host+port, default ports
#       normalized) => in-scope; a different origin => third-party.
#   (D) a `findings.benign[]` POSIX-ERE matched against the URL PATH
#       downgrades to benign — checked AFTER origin, so it can downgrade an
#       in-scope path.
#   (E) FAIL-CLOSED applies to an UNKNOWABLE origin, never to a KNOWN
#       FOREIGN one: an unparseable URL, a relative URL, an absent/unusable
#       `baseUrl`, or an unparseable config => `in-scope`, never
#       `third-party`, never `benign`. An absent `findings` block is NOT one
#       of those cases — it removes only the benign downgrade, so the origin
#       comparison still decides and a cross-origin URL stays `third-party`.
#       That is also the Lane-E independence case: this script must not
#       require the config key Lane E adds, and its absence must neither
#       excuse an in-scope error nor make third-party noise fatal.
#   (F) exit 0 on any successful classification; non-zero ONLY on unusable
#       arguments (missing config file, wrong arg count).
#   (G) the jq and python3 engines agree byte-for-byte over the whole matrix.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../scripts/classify-finding.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: classify-finding: neither jq nor python3 available - suite cannot run" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- config fixtures (keyed by name; bash 3.2 has no associative arrays) ----
cfg_json() {
  case "$1" in
    basic)       printf '%s' '{"baseUrl":"https://app.test","findings":{"benign":[]}}' ;;
    benign)      printf '%s' '{"baseUrl":"https://app.test","findings":{"benign":["^/favicon\\.ico$"]}}' ;;
    httpbase)    printf '%s' '{"baseUrl":"http://localhost:3000","findings":{"benign":[]}}' ;;
    nobase)      printf '%s' '{"findings":{"benign":[]}}' ;;
    nofindings)  printf '%s' '{"baseUrl":"https://app.test"}' ;;
    malformed)   printf '%s' '{not json' ;;
    *)           printf '%s' '{}' ;;
  esac
}

# cfg_file <key> -> path to a materialized config
cfg_file() {
  local key="$1" f="$WORK/config-$1.json"
  [[ -f "$f" ]] || cfg_json "$key" > "$f"
  printf '%s' "$f"
}

# run_cls <engine> <cfg-key> <url> <status> -> sets OUT (stdout) and RC.
# Deliberately NOT a command-substitution helper: `$(run_cls ...)` would run
# the whole function in a subshell and the exit code would never come back.
OUT=""; RC=0
run_cls() {
  OUT="$(QA_ENGINE="$1" bash "$SCRIPT" "$(cfg_file "$2")" "$3" "$4" 2>/dev/null)"; RC=$?
}
origin_of() { printf '%s\n' "$1" | sed -n 's/^originClass=//p'; }
status_of() { printf '%s\n' "$1" | sed -n 's/^statusClass=//p'; }

# ---------------------------------------------------------------------------
# the named tests (one shell function per test named in the task brief)
# ---------------------------------------------------------------------------
test_origin_match_is_in_scope() {
  local e="$1"; run_cls "$e" basic 'https://app.test/x' 500
  check "[$e] test_origin_match_is_in_scope (originClass)" "$(origin_of "$OUT")" "in-scope"
  check "[$e] test_origin_match_is_in_scope (statusClass)" "$(status_of "$OUT")" "fatal"
  check "[$e] test_origin_match_is_in_scope (exit 0)" "$RC" "0"
  check "[$e] test_origin_match_is_in_scope (exactly two lines, ordered)" \
    "$(printf '%s' "$OUT" | tr '\n' ';')" "originClass=in-scope;statusClass=fatal"
}

test_origin_mismatch_is_third_party() {
  local e="$1"; run_cls "$e" basic 'https://cdn.other.test/beacon' 403
  check "[$e] test_origin_mismatch_is_third_party (originClass)" "$(origin_of "$OUT")" "third-party"
  check "[$e] test_origin_mismatch_is_third_party (statusClass)" "$(status_of "$OUT")" "non-fatal"
}

test_benign_allowlist_downgrades() {
  local e="$1"; run_cls "$e" benign 'https://app.test/favicon.ico' 404
  check "[$e] test_benign_allowlist_downgrades" "$(origin_of "$OUT")" "benign"
  # a non-matching path under the same config is untouched (anchors honoured)
  run_cls "$e" benign 'https://app.test/favicon.icoX' 404
  check "[$e] test_benign_allowlist_downgrades (anchored, no partial match)" "$(origin_of "$OUT")" "in-scope"
  # benign is checked after origin, so it downgrades a third-party path too
  run_cls "$e" benign 'https://cdn.other.test/favicon.ico' 404
  check "[$e] test_benign_allowlist_downgrades (applies to third-party too)" "$(origin_of "$OUT")" "benign"
}

test_default_port_normalized() {
  local e="$1"; run_cls "$e" basic 'https://app.test:443/x' 200
  check "[$e] test_default_port_normalized (https :443)" "$(origin_of "$OUT")" "in-scope"
  run_cls "$e" httpbase 'http://localhost:3000/x' 200
  check "[$e] test_default_port_normalized (explicit non-default port matches)" "$(origin_of "$OUT")" "in-scope"
  run_cls "$e" httpbase 'http://localhost:4000/x' 200
  check "[$e] test_default_port_normalized (different port is third-party)" "$(origin_of "$OUT")" "third-party"
  run_cls "$e" basic 'HTTPS://APP.TEST/x' 200
  check "[$e] test_default_port_normalized (scheme/host case-insensitive)" "$(origin_of "$OUT")" "in-scope"
}

test_unparseable_url_fails_closed() {
  local e="$1"; run_cls "$e" benign 'not a url' 500
  check "[$e] test_unparseable_url_fails_closed" "$(origin_of "$OUT")" "in-scope"
  check "[$e] test_unparseable_url_fails_closed (still classifies, exit 0)" "$RC" "0"
  run_cls "$e" benign 'https://' 500
  check "[$e] test_unparseable_url_fails_closed (empty authority)" "$(origin_of "$OUT")" "in-scope"
  run_cls "$e" benign '' 500
  check "[$e] test_unparseable_url_fails_closed (empty url)" "$(origin_of "$OUT")" "in-scope"
}

test_missing_baseurl_fails_closed() {
  local e="$1"; run_cls "$e" nobase 'https://cdn.other.test/beacon' 500
  check "[$e] test_missing_baseurl_fails_closed (never third-party)" "$(origin_of "$OUT")" "in-scope"
  check "[$e] test_missing_baseurl_fails_closed (exit 0)" "$RC" "0"
}

test_relative_url_fails_closed() {
  local e="$1"; run_cls "$e" benign '/admin/x' 500
  check "[$e] test_relative_url_fails_closed" "$(origin_of "$OUT")" "in-scope"
  # a relative path that WOULD match a benign rule is still not downgraded
  run_cls "$e" benign '/favicon.ico' 404
  check "[$e] test_relative_url_fails_closed (never benign)" "$(origin_of "$OUT")" "in-scope"
}

# An absent `findings` block removes the BENIGN DOWNGRADE and nothing else.
# It says nothing about origin, which `baseUrl` alone decides — so a known
# foreign origin is still `third-party`. (Classifying third-party noise —
# analytics beacons, CDN errors, extension traffic — as in-scope+fatal is
# the false-positive class "report everything, fail only in-scope" exists to
# avoid.) The genuine fail-closed cases are pinned by
# test_unparseable_url_fails_closed / test_missing_baseurl_fails_closed /
# test_relative_url_fails_closed instead.
test_absent_findings_block_fails_closed() {
  local e="$1"; run_cls "$e" nofindings 'https://app.test/x' 404
  check "[$e] test_absent_findings_block_fails_closed (same origin -> in-scope)" "$(origin_of "$OUT")" "in-scope"
  check "[$e] test_absent_findings_block_fails_closed (exit 0)" "$RC" "0"
  # no allowlist => nothing can be downgraded, so a benign-LOOKING path on
  # the app's own origin stays in-scope
  run_cls "$e" nofindings 'https://app.test/favicon.ico' 404
  check "[$e] test_absent_findings_block_fails_closed (benign-looking path -> in-scope)" "$(origin_of "$OUT")" "in-scope"
  # a KNOWN FOREIGN origin is not an unknowable one: still third-party
  run_cls "$e" nofindings 'https://cdn.other.test/beacon' 403
  check "[$e] test_absent_findings_block_fails_closed (cross-origin -> third-party)" "$(origin_of "$OUT")" "third-party"
  check "[$e] test_absent_findings_block_fails_closed (cross-origin statusClass)" "$(status_of "$OUT")" "non-fatal"
  # ... including a 5xx: recorded as third-party, not a fatal in-scope finding
  run_cls "$e" nofindings 'https://cdn.other.test/beacon' 500
  check "[$e] test_absent_findings_block_fails_closed (cross-origin 5xx -> third-party)" "$(origin_of "$OUT")" "third-party"
  # an UNPARSEABLE config is a different case: baseUrl is then unknowable,
  # so it stays fail-closed in-scope, and still exit 0
  run_cls "$e" malformed 'https://cdn.other.test/beacon' 500
  check "[$e] test_absent_findings_block_fails_closed (unparseable config -> in-scope)" "$(origin_of "$OUT")" "in-scope"
  check "[$e] test_absent_findings_block_fails_closed (unparseable config, exit 0)" "$RC" "0"
}

test_status_500_is_fatal() {
  local e="$1"; run_cls "$e" basic 'https://app.test/x' 500
  check "[$e] test_status_500_is_fatal" "$(status_of "$OUT")" "fatal"
  run_cls "$e" basic 'https://app.test/x' 503
  check "[$e] test_status_500_is_fatal (503 too)" "$(status_of "$OUT")" "fatal"
}
test_status_302_is_not_fatal() {
  local e="$1"; run_cls "$e" basic 'https://app.test/x' 302
  check "[$e] test_status_302_is_not_fatal" "$(status_of "$OUT")" "non-fatal"
}
test_status_404_is_not_fatal() {
  local e="$1"; run_cls "$e" basic 'https://app.test/x' 404
  check "[$e] test_status_404_is_not_fatal" "$(status_of "$OUT")" "non-fatal"
  run_cls "$e" basic 'https://app.test/x' 499
  check "[$e] test_status_404_is_not_fatal (499 boundary)" "$(status_of "$OUT")" "non-fatal"
  run_cls "$e" basic 'https://app.test/x' 200
  check "[$e] test_status_404_is_not_fatal (200)" "$(status_of "$OUT")" "non-fatal"
}
test_unhandled_exception_literal_is_fatal() {
  local e="$1"; run_cls "$e" basic 'https://app.test/x' unhandled-exception
  check "[$e] test_unhandled_exception_literal_is_fatal" "$(status_of "$OUT")" "fatal"
  run_cls "$e" basic 'https://app.test/x' 'an unhandled-exception occurred'
  check "[$e] test_unhandled_exception_literal_is_fatal (literal only, not a substring)" \
    "$(status_of "$OUT")" "non-fatal"
}
test_page_crash_literal_is_fatal() {
  local e="$1"; run_cls "$e" basic 'https://app.test/x' page-crash
  check "[$e] test_page_crash_literal_is_fatal" "$(status_of "$OUT")" "fatal"
}
test_unusable_arguments_exit_nonzero() {
  local e="$1" rc
  QA_ENGINE="$e" bash "$SCRIPT" "$WORK/does-not-exist.json" 'https://app.test/x' 500 >/dev/null 2>&1; rc=$?
  check "[$e] test_unusable_arguments_exit_nonzero (missing config file)" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
  QA_ENGINE="$e" bash "$SCRIPT" "$(cfg_file basic)" 'https://app.test/x' >/dev/null 2>&1; rc=$?
  check "[$e] test_unusable_arguments_exit_nonzero (missing args)" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
  QA_ENGINE="$e" bash "$SCRIPT" >/dev/null 2>&1; rc=$?
  check "[$e] test_unusable_arguments_exit_nonzero (no args)" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
}

run_all_tests() {
  local e="$1"
  test_origin_match_is_in_scope "$e"
  test_origin_mismatch_is_third_party "$e"
  test_benign_allowlist_downgrades "$e"
  test_default_port_normalized "$e"
  test_unparseable_url_fails_closed "$e"
  test_missing_baseurl_fails_closed "$e"
  test_relative_url_fails_closed "$e"
  test_absent_findings_block_fails_closed "$e"
  test_status_500_is_fatal "$e"
  test_status_302_is_not_fatal "$e"
  test_status_404_is_not_fatal "$e"
  test_unhandled_exception_literal_is_fatal "$e"
  test_page_crash_literal_is_fatal "$e"
  test_unusable_arguments_exit_nonzero "$e"
}

# the whole classification matrix, as one deterministic blob per engine
matrix_output() {
  local e="$1" key url status
  while IFS='|' read -r key url status; do
    [[ -n "$key" ]] || continue
    printf '%s|%s|%s => ' "$key" "$url" "$status"
    run_cls "$e" "$key" "$url" "$status"
    printf '%s' "$OUT" | tr '\n' ';'
    printf ' rc=%s\n' "$RC"
  done <<'CASES'
basic|https://app.test/x|500
basic|https://cdn.other.test/beacon|403
benign|https://app.test/favicon.ico|404
benign|https://app.test/favicon.icoX|404
benign|https://cdn.other.test/favicon.ico|404
basic|https://app.test:443/x|200
httpbase|http://localhost:3000/x|200
httpbase|http://localhost:80/x|200
httpbase|http://localhost:4000/x|200
basic|HTTPS://APP.TEST/x|200
basic|https://user:pw@app.test/x|500
basic|https://app.test/x?a=b#frag|500
basic|https://app.test|500
benign|not a url|500
benign|/admin/x|500
benign|/favicon.ico|404
nobase|https://cdn.other.test/beacon|500
nofindings|https://app.test/x|404
nofindings|https://app.test/favicon.ico|404
nofindings|https://cdn.other.test/beacon|403
nofindings|https://cdn.other.test/beacon|500
malformed|https://cdn.other.test/beacon|500
basic|https://app.test/x|302
basic|https://app.test/x|404
basic|https://app.test/x|unhandled-exception
basic|https://app.test/x|page-crash
basic|https://app.test/x|not-a-status
CASES
}

HAVE_JQ=no; HAVE_PY=no
command -v jq      >/dev/null 2>&1 && HAVE_JQ=yes
command -v python3 >/dev/null 2>&1 && HAVE_PY=yes

[[ "$HAVE_JQ" == "yes" ]] && run_all_tests jq
[[ "$HAVE_PY" == "yes" ]] && run_all_tests python3

test_python_engine_matches_jq_engine() {
  if [[ "$HAVE_JQ" != "yes" || "$HAVE_PY" != "yes" ]]; then
    echo "skip - test_python_engine_matches_jq_engine (needs both jq and python3)"
    return 0
  fi
  local mj mp
  mj="$(matrix_output jq)"
  mp="$(matrix_output python3)"
  # non-vacuity guard: two empty blobs are also "identical" (that is exactly
  # what this comparison reported while the script did not yet exist).
  check "test_python_engine_matches_jq_engine (matrix is non-vacuous)" \
    "$(printf '%s\n' "$mj" | grep -c 'originClass=')" "27"
  check "test_python_engine_matches_jq_engine (whole matrix byte-identical)" \
    "$([[ "$mj" == "$mp" ]] && echo same || echo diff)" "same"
  if [[ "$mj" != "$mp" ]]; then
    printf '%s\n' "$mj" > "$WORK/matrix.jq"
    printf '%s\n' "$mp" > "$WORK/matrix.py"
    diff "$WORK/matrix.jq" "$WORK/matrix.py" || true
  fi
}
test_python_engine_matches_jq_engine

echo
echo "classify-finding tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
