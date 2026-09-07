#!/usr/bin/env bash
# tests/find-spec-kit/run.sh — first test coverage for
# skills/ingesting-spec-kit/scripts/find-spec-kit.sh (previously untested).
#
# Covers the Appendix A "duplicate inventory" bug: SEARCH_ROOTS starts with
# "$(pwd)" (absolute) and appends `.qa/config.json`'s raw `repos[].path`/
# `.root` string verbatim — the very common single-repo default is `"."`
# (exactly what bootstrapping-qa-config's init-config.sh writes). An
# exact-string dedup on the RAW values never noticed "." and "$(pwd)" name
# the SAME directory, so search_dir ran on it twice and every spec-kit
# artifact found there was emitted TWICE in the inventory. Also covers the
# doc-drift-adjacent claim that a `role: "specs"` repo entry is specially
# recognized — it isn't; every configured repo path is searched
# unconditionally, regardless of its `role`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FSK="$HERE/../../skills/ingesting-spec-kit/scripts/find-spec-kit.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# Case 1: no config at all -> a constitution.md in cwd is found exactly once.
# ===========================================================================
CASE1="$WORK/case1"; mkdir -p "$CASE1"
printf '# My Constitution\n\nRule 1.\n' > "$CASE1/constitution.md"
OUT1="$( cd "$CASE1" && bash "$FSK" 2>/dev/null )"
check "case1: exactly one line of output (no config, no duplication)" \
  "$(echo "$OUT1" | grep -c 'constitution.md')" "1"
check_contains "case1: artifact type is constitution" "$OUT1" "| constitution |"

# ===========================================================================
# Case 2 (the confirmed bug): .qa/config.json declares repos:[{"path":"."}]
# -- the single-repo default -- while cwd IS that same directory. Before the
# fix this duplicated every found artifact (once via "$(pwd)", once via the
# raw "." from config).
# ===========================================================================
CASE2="$WORK/case2"; mkdir -p "$CASE2/.qa"
printf '# My Spec\n\nAC1: something.\n' > "$CASE2/spec.md"
printf '{"repos":[{"path":"."}]}' > "$CASE2/.qa/config.json"
OUT2="$( cd "$CASE2" && bash "$FSK" 2>/dev/null )"
check "case2: spec.md found EXACTLY ONCE despite repos:[{path:'.'}] == cwd" \
  "$(echo "$OUT2" | grep -c 'spec.md')" "1"

# ===========================================================================
# Case 3: a genuinely SEPARATE repo path (not == cwd) is still searched
# in addition to cwd -- the fix must not accidentally collapse distinct
# roots, only ones that resolve to the same real directory.
# ===========================================================================
CASE3="$WORK/case3"; mkdir -p "$CASE3/.qa" "$WORK/case3-specs-repo"
printf 'plain repo file, no config here\n' > "$CASE3/README.md"
printf '# Tasks\n\nT001: do the thing.\n' > "$WORK/case3-specs-repo/tasks.md"
printf '{"repos":[{"path":"%s","role":"specs"}]}' "$WORK/case3-specs-repo" > "$CASE3/.qa/config.json"
OUT3="$( cd "$CASE3" && bash "$FSK" 2>/dev/null )"
check "case3: tasks.md from the SEPARATE specs-role repo is found" \
  "$(echo "$OUT3" | grep -c 'tasks.md')" "1"

# ===========================================================================
# Case 4: role is NOT special-cased -- a repo tagged role:"backend" (not
# "specs") is searched exactly the same way; proves the script doesn't
# filter by role at all (matches the corrected SKILL.md wording).
# ===========================================================================
CASE4="$WORK/case4"; mkdir -p "$CASE4/.qa" "$WORK/case4-backend-repo"
printf '# Constitution Two\n\nRule A.\n' > "$WORK/case4-backend-repo/constitution.md"
printf '{"repos":[{"path":"%s","role":"backend"}]}' "$WORK/case4-backend-repo" > "$CASE4/.qa/config.json"
OUT4="$( cd "$CASE4" && bash "$FSK" 2>/dev/null )"
check "case4: a role:backend repo's artifact is found too (role is not filtered)" \
  "$(echo "$OUT4" | grep -c 'constitution.md')" "1"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
