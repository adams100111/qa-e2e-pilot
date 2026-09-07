#!/usr/bin/env bash
# tests/memory-sync/run.sh — first test coverage for scripts/memory-sync.sh
# (previously untested — Appendix A: memory-sync missing Fix-28 run-id
# validation).
#
# Covers:
#   - Fix-28 run-id validation: a path-traversal/absolute/dotted/flag-like
#     run-id is REJECTED before it is ever interpolated into RUN_DIR, exactly
#     like checkpoint.sh/toolstream.sh/qa-verify.sh/provenance.sh's own
#     validate_token/validate_run_id (negative control).
#   - a well-formed run-id with no .qa/config.json is a clean no-op (default
#     "file" backend posture) — positive control proving the guard doesn't
#     reject legitimate ids.
#   - a well-formed run-id with an explicit memory.backend="file" config is
#     also a no-op, never touching the network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/../../scripts/memory-sync.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.qa/runs/goodrun"

# ===========================================================================
# Fix-28 run-id validation (negative controls) — each MUST be rejected
# (exit non-zero) before RUN_DIR="${QA_BASE}/${RUN_ID}" is ever built.
# ===========================================================================
for BAD in "../../etc/passwd" "..\\..\\evil" "foo/bar" ".." "..." "-rf"; do
  OUT="$( ( cd "$WORK" && bash "$SYNC" "$BAD" ) 2>&1 )"
  RC=$?
  check "Fix-28: run-id '$BAD' is rejected (exit non-zero)" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check_contains "Fix-28: run-id '$BAD' rejection names the run-id" "$OUT" "run-id"
done

# ===========================================================================
# Positive control: a well-formed run-id is NEVER rejected by the guard.
# ===========================================================================
NO_CFG_OUT="$( ( cd "$WORK" && bash "$SYNC" goodrun ) 2>&1 )"
NO_CFG_RC=$?
check "well-formed run-id: no .qa/config.json -> clean no-op exit 0" "$NO_CFG_RC" "0"
check_contains "well-formed run-id: nothing-to-sync message (no config)" "$NO_CFG_OUT" "nothing to sync"

cat > "$WORK/.qa/config.json" <<'EOF'
{"memory": {"backend": "file"}}
EOF
FILE_BACKEND_OUT="$( ( cd "$WORK" && bash "$SYNC" goodrun ) 2>&1 )"
FILE_BACKEND_RC=$?
check "well-formed run-id: explicit backend=file -> no-op exit 0" "$FILE_BACKEND_RC" "0"
check_contains "well-formed run-id: file-backend message names the run dir" "$FILE_BACKEND_OUT" ".qa/runs/goodrun"

# --- missing run dir with a well-formed id -> a clean error, not a crash. ---
MISSING_OUT="$( ( cd "$WORK" && bash "$SYNC" no-such-run ) 2>&1 )"
MISSING_RC=$?
check "well-formed but missing run dir -> exit non-zero" "$([[ "$MISSING_RC" -ne 0 ]] && echo yes)" "yes"
check_contains "missing run dir: error names the path" "$MISSING_OUT" "run dir not found"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
