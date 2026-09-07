#!/usr/bin/env bash
# Tests for index-routes.sh — .qa/config.json repos[] role resolution.
#
# Audit-2 W3-5b: with jq absent from PATH, index-routes.sh falls back to a
# `node -e '<code>'` invocation. Both fallback calls put `QA_CFG="$CONFIG_FILE"`
# AFTER the node script argument, which node treats as a positional argv entry
# (process.argv[2]), NOT an environment variable — process.env.QA_CFG stays
# undefined, readFileSync(undefined) throws, and `2>/dev/null || true` swallows
# the failure silently: FRONTEND_PATH/BACKEND_PATH resolve empty and the
# backend scan is silently skipped. Fix: put the QA_CFG assignment BEFORE
# `node` (so it's a real env var for that command), and WARN to stderr on a
# genuine resolution failure instead of swallowing it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../skills/analyzing-feature-ui/scripts/index-routes.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2', want it to contain '$3')"; FAIL=$((FAIL+1)); fi; }

BASH_BIN="$(command -v bash)"

# Build a restricted PATH containing every external tool index-routes.sh needs
# EXCEPT jq — this forces `command -v jq` to fail and the node fallback branch
# to run. Modeled on tests/journal/run.sh's fakebin idiom.
build_fakebin() {
  local dir="$1"
  mkdir -p "$dir"
  local tool tpath
  for tool in grep find sed xargs sort head date node cat dirname wc mktemp rm ls tr basename mkdir env printf true false; do
    tpath="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tpath" ]] && ln -sf "$tpath" "$dir/$tool"
  done
}

# QA_PROFILE=/dev/null short-circuits index-routes.sh's own
# `ls .qa/runs/*/stack-profile.json` auto-discovery (a fixture project has no
# .qa/runs/ dir, and that glob-miss is orthogonal to what this suite covers)
# — this is the script's own documented override var, not a workaround.
run_indexer() {
  local work="$1" path_val="$2"
  ( cd "$work" && PATH="$path_val" QA_PROFILE=/dev/null "$BASH_BIN" "$SCRIPT" )
}

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP - index-routes: node not present on this host, cannot exercise the node fallback"
  echo "---"; echo "PASS=$PASS FAIL=$FAIL"
  exit 0
fi

# ── Case 1 (RED before the fix): jq masked + node present + repos[] roles ────
# → both frontend and backend paths resolve via the node fallback.
WORK1="$(mktemp -d)"
mkdir -p "$WORK1/fe" "$WORK1/be" "$WORK1/.qa"
printf '%s' '{"repos":[{"role":"frontend","path":"fe"},{"role":"backend","path":"be"}]}' \
  > "$WORK1/.qa/config.json"
FAKEBIN1="$WORK1/fakebin"
build_fakebin "$FAKEBIN1"

OUT1="$(run_indexer "$WORK1" "$FAKEBIN1" 2>"$WORK1/err.log")"
RC1=$?
check "case1: exits 0" "$RC1" "0"
FE1="$(printf '%s' "$OUT1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["frontend"]["path"])' 2>/dev/null || true)"
BE1="$(printf '%s' "$OUT1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["backend"]["path"])' 2>/dev/null || true)"
check "case1: frontend path resolved from config repos[]" "$FE1" "fe"
check "case1: backend path resolved from config repos[]"  "$BE1" "be"

# ── Case 2: corrupt config → resolution failure WARNs on stderr ─────────────
# (still jq-masked, so this exercises the same node fallback branch.)
WORK2="$(mktemp -d)"
mkdir -p "$WORK2/.qa"
printf '%s' '{not valid json' > "$WORK2/.qa/config.json"
FAKEBIN2="$WORK2/fakebin"
build_fakebin "$FAKEBIN2"

OUT2="$(run_indexer "$WORK2" "$FAKEBIN2" 2>"$WORK2/err.log")"
RC2=$?
check "case2: still exits 0 (degrades, doesn't crash)" "$RC2" "0"
check_contains "case2: WARN visible on stderr for corrupt config" \
  "$(cat "$WORK2/err.log")" "WARN"
check_contains "case2: WARN mentions config resolution" \
  "$(cat "$WORK2/err.log")" "config resolution"
FE2="$(printf '%s' "$OUT2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["frontend"]["path"])' 2>/dev/null || true)"
check "case2: frontend falls back to '.' (not silently mis-resolved)" "$FE2" "."

# ── Case 3 (control): jq present, unmodified path — behavior unchanged ──────
if command -v jq >/dev/null 2>&1; then
  WORK3="$(mktemp -d)"
  mkdir -p "$WORK3/fe" "$WORK3/be" "$WORK3/.qa"
  printf '%s' '{"repos":[{"role":"frontend","path":"fe"},{"role":"backend","path":"be"}]}' \
    > "$WORK3/.qa/config.json"

  OUT3="$( ( cd "$WORK3" && QA_PROFILE=/dev/null "$BASH_BIN" "$SCRIPT" ) 2>"$WORK3/err.log" )"
  RC3=$?
  check "case3 (jq control): exits 0" "$RC3" "0"
  FE3="$(printf '%s' "$OUT3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["frontend"]["path"])' 2>/dev/null || true)"
  BE3="$(printf '%s' "$OUT3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["backend"]["path"])' 2>/dev/null || true)"
  check "case3 (jq control): frontend path resolved" "$FE3" "fe"
  check "case3 (jq control): backend path resolved"  "$BE3" "be"
else
  echo "SKIP - index-routes: jq not present on this host, cannot exercise the jq control path"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
