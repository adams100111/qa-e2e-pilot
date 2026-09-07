#!/usr/bin/env bash
# Tests for the harness/manual installers (audit-2 W2-1/W2-2):
#  - every installer ships EVERY rendered/repo command, not just qa-run/qa-roles
#    (today FAILS: qa-resume.md is missing everywhere)
#  - harnesses/pi/install-pi.sh merges an existing .pi/mcp.json instead of clobbering it
#    (today FAILS: it blind-cp's the snippet over any pre-existing file)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$HERE/../.."
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

sorted_basenames() { # <dir>
  if [ -d "$1" ]; then ls "$1" 2>/dev/null | sort | tr '\n' ' '; else echo ""; fi
}

# jbool/jcanon: jq-guarded JSON assertions with a python3 fallback -- mirrors
# the "command -v jq guard / python3-fallback" idiom sibling suites use (e.g.
# tests/critic-coverage/run.sh's `command -v jq >/dev/null 2>&1 && jq ... ||
# python3 -c ...`), so this suite doesn't hard-require jq on the test-runner.
jbool() { # <file> <jq-boolean-filter> <python3-bool-expr-on-d>
  local file="$1" jqf="$2" pyexpr="$3"
  if command -v jq >/dev/null 2>&1; then
    jq -e "$jqf" "$file" >/dev/null 2>&1 && echo true || echo false
  else
    python3 -c "
import json
d = json.load(open('$file'))
print('true' if ($pyexpr) else 'false')
" 2>/dev/null
  fi
}
jcanon() { # <file> <jq-path-filter> <python3-expr-on-d>
  local file="$1" jqf="$2" pyexpr="$3"
  if command -v jq >/dev/null 2>&1; then
    jq -S "$jqf" "$file" 2>/dev/null
  else
    python3 -c "
import json
d = json.load(open('$file'))
print(json.dumps($pyexpr, sort_keys=True))
" 2>/dev/null
  fi
}

# --- build all three non-Claude dist adapters once, so dist/<h>/commands/*.md reflects
# whatever core/commands/*.md currently contains (today: qa-run, qa-roles, qa-resume). ---
bash "$REPO/scripts/build-adapter.sh" codex    >/dev/null
bash "$REPO/scripts/build-adapter.sh" pi       >/dev/null
bash "$REPO/scripts/build-adapter.sh" opencode >/dev/null

# === command-set cases: installed set must equal the rendered/source set (glob compare) ===

T1="$(mktemp -d)"
bash "$REPO/harnesses/codex/install-codex.sh" "$T1" >/dev/null 2>&1
check "codex ships full command set" \
  "$(sorted_basenames "$T1/.codex/prompts")" \
  "$(sorted_basenames "$REPO/dist/codex/commands")"
rm -rf "$T1"

T2="$(mktemp -d)"
bash "$REPO/harnesses/pi/install-pi.sh" "$T2" >/dev/null 2>&1
check "pi ships full command set" \
  "$(sorted_basenames "$T2/.pi/prompts")" \
  "$(sorted_basenames "$REPO/dist/pi/commands")"
rm -rf "$T2"

T3="$(mktemp -d)"
bash "$REPO/harnesses/opencode/install-opencode.sh" "$T3" >/dev/null 2>&1
check "opencode ships full command set" \
  "$(sorted_basenames "$T3/.opencode/command")" \
  "$(sorted_basenames "$REPO/dist/opencode/commands")"
rm -rf "$T3"

# manual install.sh: HOME/CLAUDE_CONFIG_DIR override kept hermetic (install.sh already reads
# CLAUDE_CONFIG_DIR, falling back to $HOME/.claude — see scripts/install.sh:13)
T4="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$T4" bash "$REPO/scripts/install.sh" --copy >/dev/null 2>&1
check "install.sh ships every repo commands/*.md" \
  "$(sorted_basenames "$T4/commands")" \
  "$(sorted_basenames "$REPO/commands")"
rm -rf "$T4"

# === pi mcp.json merge cases ===

# case 1: pre-existing .pi/mcp.json with a foreign server "foo" -> BOTH "foo" and
# "playwright-qa" present afterwards; a .bak backup of the pre-existing file exists.
T5="$(mktemp -d)"
mkdir -p "$T5/.pi"
cat > "$T5/.pi/mcp.json" <<'JSON'
{
  "mcpServers": {
    "foo": { "command": "foo-cmd", "args": [] }
  }
}
JSON
bash "$REPO/harnesses/pi/install-pi.sh" "$T5" >/dev/null 2>&1
check "pi-merge case1: foreign key 'foo' preserved" \
  "$(jbool "$T5/.pi/mcp.json" '.mcpServers|has("foo")' '"foo" in d["mcpServers"]')" "true"
check "pi-merge case1: 'playwright-qa' added" \
  "$(jbool "$T5/.pi/mcp.json" '.mcpServers|has("playwright-qa")' '"playwright-qa" in d["mcpServers"]')" "true"
check "pi-merge case1: backup written" \
  "$([ -f "$T5/.pi/mcp.json.bak-qa-e2e-pilot" ] && echo yes || echo no)" "yes"
check "pi-merge case1: backup has the original foreign-only content" \
  "$(jbool "$T5/.pi/mcp.json.bak-qa-e2e-pilot" '.mcpServers|has("foo") and (has("playwright-qa")|not)' '"foo" in d["mcpServers"] and "playwright-qa" not in d["mcpServers"]')" "true"
rm -rf "$T5"

# case 2: no pre-existing mcp.json -> file equals the snippet content
T6="$(mktemp -d)"
bash "$REPO/harnesses/pi/install-pi.sh" "$T6" >/dev/null 2>&1
check "pi-merge case2: matches snippet (no pre-existing file)" \
  "$(cat "$T6/.pi/mcp.json" 2>/dev/null)" \
  "$(cat "$REPO/harnesses/pi/mcp.snippet")"
rm -rf "$T6"

# case 3 (no-engine fallback): PATH masked of jq AND python3 -> installer does NOT overwrite
# the existing file; prints the snippet + a merge-it-yourself message (mirrors the codex/
# opencode print-and-ask wording). Build a scratch PATH containing every real executable
# EXCEPT jq/python(3) so the rest of the installer (bash, cp, mkdir, git, ...) still works.
shopt -s nullglob
MASKDIR="$(mktemp -d)"
IFS=':' read -ra PDIRS <<< "$PATH"
for d in "${PDIRS[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -x "$f" ] && [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in jq|python|python2*|python3*) continue ;; esac
    [ -e "$MASKDIR/$b" ] || ln -s "$f" "$MASKDIR/$b" 2>/dev/null
  done
done
shopt -u nullglob

T7="$(mktemp -d)"
mkdir -p "$T7/.pi"
printf '{\n  "mcpServers": {\n    "foo": { "command": "foo-cmd" }\n  }\n}\n' > "$T7/.pi/mcp.json"
ORIG="$(cat "$T7/.pi/mcp.json")"
OUT="$(PATH="$MASKDIR" bash "$REPO/harnesses/pi/install-pi.sh" "$T7" 2>&1 || true)"
check "pi-merge case3: existing file left untouched" "$(cat "$T7/.pi/mcp.json")" "$ORIG"
check "pi-merge case3: prints a merge-it-yourself message" \
  "$(printf '%s\n' "$OUT" | grep -qi 'merge this into' && echo yes || echo no)" "yes"
check "pi-merge case3: prints the snippet content" \
  "$(printf '%s\n' "$OUT" | grep -q 'playwright-qa' && echo yes || echo no)" "yes"
rm -rf "$T7" "$MASKDIR"

# === pi-merge dual-engine parity: a STALE pre-existing playwright-qa entry (extra sub-key,
# e.g. "cwd") must be fully REPLACED by the snippet's entry, not deep-merged with it — under
# BOTH engines. jq's `.[0] * .[1]` is a recursive merge, so it was preserving the stale
# sub-key while the python3 leg (dict.update) was already replacing the whole entry —
# reviewer-reported divergence. ===
pi_merge_parity_case() { # <label> <PATH-override-or-empty>
  local label="$1" pathoverride="$2" T
  T="$(mktemp -d)"; mkdir -p "$T/.pi"
  cat > "$T/.pi/mcp.json" <<'JSON'
{
  "mcpServers": {
    "foo": { "command": "foo-cmd", "args": [] },
    "playwright-qa": { "command": "npx", "args": ["-y", "@playwright/mcp@0.0.1"], "cwd": "/stale" }
  }
}
JSON
  if [ -n "$pathoverride" ]; then
    PATH="$pathoverride" bash "$REPO/harnesses/pi/install-pi.sh" "$T" >/dev/null 2>&1
  else
    bash "$REPO/harnesses/pi/install-pi.sh" "$T" >/dev/null 2>&1
  fi
  check "$label: foreign key 'foo' intact" \
    "$(jbool "$T/.pi/mcp.json" '.mcpServers|has("foo")' '"foo" in d["mcpServers"]')" "true"
  check "$label: playwright-qa equals snippet entry exactly (stale sub-key gone)" \
    "$(jcanon "$T/.pi/mcp.json" '.mcpServers."playwright-qa"' 'd["mcpServers"]["playwright-qa"]')" \
    "$(jcanon "$REPO/harnesses/pi/mcp.snippet" '.mcpServers."playwright-qa"' 'd["mcpServers"]["playwright-qa"]')"
  rm -rf "$T"
}

# jq leg (PATH untouched — this box has jq)
pi_merge_parity_case "pi-merge parity (jq)" ""

# python3 leg: mask ONLY jq off PATH (keep python3), same scratch-PATH technique as case 3.
shopt -s nullglob
MASKDIR_NOJQ="$(mktemp -d)"
IFS=':' read -ra PDIRS2 <<< "$PATH"
for d in "${PDIRS2[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -x "$f" ] && [ -f "$f" ] || continue
    b="$(basename "$f")"
    [ "$b" = "jq" ] && continue
    [ -e "$MASKDIR_NOJQ/$b" ] || ln -s "$f" "$MASKDIR_NOJQ/$b" 2>/dev/null
  done
done
shopt -u nullglob
pi_merge_parity_case "pi-merge parity (python3, jq masked)" "$MASKDIR_NOJQ"
rm -rf "$MASKDIR_NOJQ"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
