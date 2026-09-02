#!/usr/bin/env bash
# Tests for required-kinds.sh — the deterministic, agent-untrusted
# required-evidence-kinds deriver (Plan H1 Task 1, honesty WS-1 #2). Covers
# the four union rules (human-action via mutation-flag.sh reuse, computed,
# bake, probe), the read-only suppression of bake, the empty-set case, and
# the adversary proof that a mutating criterion still derives human-action
# regardless of what the agent itself claimed in its own `kinds` field.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$HERE/../../skills/checkpointing-qa-memory/scripts/required-kinds.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Vocabulary guard: every "ok" result across this file must be a subset of
# the four-kind vocabulary. Spot-checked inline per case below; this helper
# additionally re-checks any non-empty result contains only known kinds.
# ---------------------------------------------------------------------------
assert_subset() {
  local label="$1" csv="$2"
  [[ -z "$csv" ]] && return 0
  local bad=0 tok
  IFS=',' read -ra toks <<< "$csv"
  for tok in "${toks[@]}"; do
    case "$tok" in
      bake|computed|human-action|probe) : ;;
      *) bad=1 ;;
    esac
  done
  if [[ "$bad" -eq 0 ]]; then echo "ok   - $label (vocab subset)"; PASS=$((PASS+1));
  else echo "FAIL - $label (vocab subset) got '$csv'"; FAIL=$((FAIL+1)); fi
}

# ---------------------------------------------------------------------------
# derive — core rule cases (from the task spec, expectations verified exact)
# ---------------------------------------------------------------------------

CASE1='{"action":"Create a founder","kind":"happy-path"}'
OUT1="$(bash "$R" derive "$CASE1")"
check "derive: mutating happy-path -> bake,human-action" "$OUT1" "bake,human-action"
assert_subset "case1" "$OUT1"

CASE2='{"kind":"computed-logic","action":"Verify the total"}'
OUT2="$(bash "$R" derive "$CASE2")"
check "derive: computed-logic -> computed (no bake, no human-action)" "$OUT2" "computed"
assert_subset "case2" "$OUT2"

CASE3='{"kind":"cross-tenant","tags":["cross-tenant","probe-needed"],"action":"Confirm no leak"}'
OUT3="$(bash "$R" derive "$CASE3")"
check "derive: cross-tenant + probe-needed tags, non-mutating, non-bake-kind -> probe" "$OUT3" "probe"
assert_subset "case3" "$OUT3"

CASE4='{"kind":"loading-state","tags":["read-only"],"action":"See the spinner"}'
OUT4="$(bash "$R" derive "$CASE4")"
check "derive: read-only loading-state, no mutation, no persisted-state kind -> empty" "$OUT4" ""
assert_subset "case4" "$OUT4"

# ---------------------------------------------------------------------------
# derive — adversary: a mutating criterion STILL derives human-action no
# matter what the agent put in its own `kinds` field. This proves the
# derivation goes through mutation-flag.sh's independent action-shape
# classifier (the action verb "Delete"), not any agent self-report.
# ---------------------------------------------------------------------------

ADV='{"action":"Delete the row","kind":"happy-path","kinds":["bake"]}'
OUTADV="$(bash "$R" derive "$ADV")"
check "derive ADVERSARY: agent claims kinds=[bake] only, action is mutating -> human-action still derived" \
  "$OUTADV" "bake,human-action"
assert_subset "adversary" "$OUTADV"
case ",${OUTADV}," in
  *,human-action,*) echo "ok   - adversary: human-action present despite agent's kinds=[bake] claim"; PASS=$((PASS+1)) ;;
  *) echo "FAIL - adversary: human-action MISSING — agent's kinds field was wrongly trusted"; FAIL=$((FAIL+1)) ;;
esac

# ---------------------------------------------------------------------------
# derive — additional rule coverage: business-rule kind, read-only
# suppression of an otherwise-bake kind, and a multi-rule union (bake+probe).
# ---------------------------------------------------------------------------

check "derive: business-rule kind -> computed only" \
  "$(bash "$R" derive '{"kind":"business-rule","action":"Compute the discount"}')" "computed"

check "derive: read-only tag suppresses bake even for a bake-kind (multiplicity-1)" \
  "$(bash "$R" derive '{"kind":"multiplicity-1","tags":["read-only"],"action":"View row count"}')" ""

check "derive: empty-state + cross-role-fk-chain tag -> bake,probe (union)" \
  "$(bash "$R" derive '{"kind":"empty-state","tags":["cross-role-fk-chain"],"action":"Confirm empty list"}')" "bake,probe"

check "derive: multiplicity-N happy path with no tags -> bake only (non-mutating verb)" \
  "$(bash "$R" derive '{"kind":"multiplicity-N","action":"List all deliverables"}')" "bake"

check "derive: downstream-cascade + mutating verb -> bake,human-action" \
  "$(bash "$R" derive '{"kind":"downstream-cascade","action":"Update the parent record"}')" "bake,human-action"

# ---------------------------------------------------------------------------
# malformed input -> non-zero exit, no stray output
# ---------------------------------------------------------------------------

bash "$R" derive 'not json' >/dev/null 2>&1; rc=$?
check "derive: malformed JSON -> non-zero exit" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

bash "$R" derive '["not","an","object"]' >/dev/null 2>&1; rc2=$?
check "derive: non-object JSON -> non-zero exit" "$([[ $rc2 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

bash "$R" >/dev/null 2>&1; rc3=$?
check "no subcommand -> non-zero exit" "$([[ $rc3 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# python3-fallback pass: mask jq from PATH so has_jq() fails in BOTH
# required-kinds.sh and the mutation-flag.sh it shells out to, then
# re-assert representative cases (incl. the adversary) under the fallback.
# Dual-engine agreement is the point: identical CSVs, identical ordering.
# ---------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(type -P bash)"
  FAKEBIN="$WORK/fakebin-no-jq"
  mkdir -p "$FAKEBIN"
  # Deliberately exclude jq -- forces has_jq() to fail, has_py() to succeed,
  # in both required-kinds.sh and the mutation-flag.sh it invokes.
  for tool in bash python3 grep cat dirname basename mkdir sort; do
    TOOL_PATH="$(type -P "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  check "py-fallback: mutating happy-path -> bake,human-action (matches jq engine)" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$R" derive "$CASE1")" "bake,human-action"

  check "py-fallback: computed-logic -> computed (matches jq engine)" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$R" derive "$CASE2")" "computed"

  check "py-fallback: cross-tenant probe-needed -> probe (matches jq engine)" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$R" derive "$CASE3")" "probe"

  check "py-fallback: read-only loading-state -> empty (matches jq engine)" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$R" derive "$CASE4")" ""

  check "py-fallback ADVERSARY: agent's kinds=[bake] claim still overridden -> bake,human-action" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$R" derive "$ADV")" "bake,human-action"

  check "py-fallback: malformed JSON -> non-zero exit" \
    "$(PATH="$FAKEBIN" "$BASH_BIN" "$R" derive 'not json' >/dev/null 2>&1; echo $?)" "1"

  echo "note - jq-fallback dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
