#!/usr/bin/env bash
# Tests for validate-state-machine.sh — the structural validator for the
# state-machine.json statechart-as-data (Run FSM Enforcement, Task 1). Covers:
# the shipped state-machine.json validates; an edge referencing an undeclared
# subState; a guard on a non-existent edge; a phaseToolSurface phase not in
# phases; a duplicate phase order; an unknown tool class; malformed/empty
# JSON; missing file; no args. Dual-engine (jq preferred, python3 fallback
# via a jq-masked fakebin, matching tests/validate-checklist-json/run.sh's
# idiom).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/../../skills/checkpointing-qa-memory/scripts/validate-state-machine.sh"
SM="$HERE/../../skills/checkpointing-qa-memory/references/state-machine.json"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (output did not contain '$3': $2)"; FAIL=$((FAIL+1)); fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP - all: jq required to build fixtures (mutating the shipped file)"; echo "---"; echo "PASS=$PASS FAIL=$FAIL"; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

[[ -f "$SM" ]] || { echo "FAIL - shipped state-machine.json not found at $SM"; echo "---"; echo "PASS=1 FAIL=1"; exit 1; }

# ---------------------------------------------------------------------------
# Fixtures — mutants of the real shipped file, so every mutant is otherwise
# valid except the one thing under test.
# ---------------------------------------------------------------------------

jq '.legalSubStateEdges += [["bogus-substate", "verdict"]]' "$SM" > "$WORK/bad-substate-edge.json"
jq '.guards += [{"edge": ["pending", "verdict"], "requires": "bogus"}]' "$SM" > "$WORK/bad-guard-edge.json"
jq '.phaseToolSurface["Discover"] = {"allowedToolClasses": ["bash"]}' "$SM" > "$WORK/bad-surface-phase.json"
jq '.phases[1].order = .phases[0].order' "$SM" > "$WORK/dup-phase-order.json"
jq '.phaseToolSurface["Verify"].allowedToolClasses += ["browser-teleport"]' "$SM" > "$WORK/bad-tool-class.json"
jq '.legalPhaseEdges += [["Verify", "Discover"]]' "$SM" > "$WORK/bad-phase-edge.json"
jq '.phases += [{"id": "Analyze", "order": 6}]' "$SM" > "$WORK/dup-phase-id.json"

echo '{"not": "the right shape"}' > "$WORK/non-object-fields.json"
echo 'this is not json at all {{{' > "$WORK/malformed.json"
: > "$WORK/empty.json"

# ---------------------------------------------------------------------------
# jq-engine assertions (the default engine on this host)
# ---------------------------------------------------------------------------

bash "$V" "$SM" >/dev/null 2>&1; rc=$?
check "shipped state-machine.json -> exit 0" "$rc" "0"

out="$(bash "$V" "$WORK/bad-substate-edge.json" 2>&1)"; rc=$?
check "edge referencing undeclared subState -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "undeclared subState -> message names it" "$out" "bogus-substate"

out="$(bash "$V" "$WORK/bad-guard-edge.json" 2>&1)"; rc=$?
check "guard on non-existent edge -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "guard on non-existent edge -> message names guards[]" "$out" "guards["
check_contains "guard on non-existent edge -> message says not a declared legalSubStateEdge" "$out" "not a declared legalSubStateEdge"

out="$(bash "$V" "$WORK/bad-surface-phase.json" 2>&1)"; rc=$?
check "phaseToolSurface phase not in phases -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "phaseToolSurface bad phase -> message names Discover" "$out" "Discover"

out="$(bash "$V" "$WORK/dup-phase-order.json" 2>&1)"; rc=$?
check "duplicate phase order -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "duplicate phase order -> message says duplicate order" "$out" "duplicate order"

out="$(bash "$V" "$WORK/bad-tool-class.json" 2>&1)"; rc=$?
check "unknown tool class -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "unknown tool class -> message names it" "$out" "browser-teleport"

out="$(bash "$V" "$WORK/bad-phase-edge.json" 2>&1)"; rc=$?
check "legalPhaseEdges referencing undeclared phase -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "legalPhaseEdges bad phase -> message names Discover" "$out" "Discover"

out="$(bash "$V" "$WORK/dup-phase-id.json" 2>&1)"; rc=$?
check "duplicate phase id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "duplicate phase id -> message says duplicate phase id" "$out" "duplicate phase id"

out="$(bash "$V" "$WORK/non-object-fields.json" 2>&1)"; rc=$?
check "non-object-shaped fields -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

out="$(bash "$V" "$WORK/malformed.json" 2>&1)"; rc=$?
check "malformed JSON -> non-zero (dies clearly, does not crash)" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "malformed JSON -> message says invalid JSON" "$out" "invalid JSON"

out="$(bash "$V" "$WORK/empty.json" 2>&1)"; rc=$?
check "empty file -> non-zero (dies clearly)" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "empty file -> message says invalid JSON" "$out" "invalid JSON"

bash "$V" >/dev/null 2>&1; rc=$?
check "no args -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

bash "$V" "$WORK/does-not-exist.json" >/dev/null 2>&1; rc=$?
check "nonexistent file -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# python3-fallback pass: mask jq from PATH, re-run every case, same
# expectations. Dual-engine agreement is the point.
# ---------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(type -P bash)"
  FAKEBIN="$WORK/fakebin-no-jq"
  mkdir -p "$FAKEBIN"
  for tool in bash python3 cat dirname basename mkdir sort; do
    TOOL_PATH="$(type -P "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$SM" >/dev/null 2>&1; rc=$?
  check "py-fallback: shipped state-machine.json -> exit 0" "$rc" "0"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/bad-substate-edge.json" 2>&1)"; rc=$?
  check "py-fallback: undeclared subState -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names bogus-substate" "$out" "bogus-substate"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/bad-guard-edge.json" 2>&1)"; rc=$?
  check "py-fallback: guard on non-existent edge -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: says not a declared legalSubStateEdge" "$out" "not a declared legalSubStateEdge"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/bad-surface-phase.json" 2>&1)"; rc=$?
  check "py-fallback: phaseToolSurface phase not in phases -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names Discover" "$out" "Discover"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/dup-phase-order.json" 2>&1)"; rc=$?
  check "py-fallback: duplicate phase order -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: says duplicate order" "$out" "duplicate order"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/bad-tool-class.json" 2>&1)"; rc=$?
  check "py-fallback: unknown tool class -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names browser-teleport" "$out" "browser-teleport"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/dup-phase-id.json" 2>&1)"; rc=$?
  check "py-fallback: duplicate phase id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: says duplicate phase id" "$out" "duplicate phase id"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/malformed.json" 2>&1)"; rc=$?
  check "py-fallback: malformed JSON -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: says invalid JSON" "$out" "invalid JSON"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/empty.json" 2>&1)"; rc=$?
  check "py-fallback: empty file -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  echo "note - jq-fallback dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
