#!/usr/bin/env bash
# tests/qa-resume/run.sh — TDD suite for qa-resume.sh (durable-resume Plan B,
# Task 5): resolve run-id (arg > `.qa/runs/latest`) -> fold -> resume
# briefing {run_id, phase, cursor, openActs, skip}.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RESUME="$HERE/../../skills/checkpointing-qa-memory/scripts/qa-resume.sh"
EMIT="$HERE/../../skills/checkpointing-qa-memory/scripts/journal-emit.sh"
CHECKPOINT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0

check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

MUT_CRIT='{"criterionId":"AC1","kinds":["human-action"],"action":"Create founders","title":"Create founders"}'
WS_ALL='[{"entity":"founder","key":"f1"},{"entity":"founder","key":"f2"}]'

# ---------------------------------------------------------------------------
# no-arg + no `.qa/runs/latest` -> dies clearly.
# ---------------------------------------------------------------------------
NOARG_ERR="$( cd "$WORK/empty-dir-1" 2>/dev/null || mkdir -p "$WORK/empty-dir-1"; cd "$WORK/empty-dir-1" && bash "$RESUME" 2>&1 >/dev/null )"; rc_noarg=$?
check "no arg, no latest -> nonzero" "$([[ $rc_noarg -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "no arg, no latest -> mentions latest" "$([[ "$NOARG_ERR" == *"latest"* ]] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
# explicit run-id that does not exist -> dies clearly (distinct message from
# the no-latest case above).
# ---------------------------------------------------------------------------
NOEXIST_ERR="$( cd "$WORK" && bash "$RESUME" nope-no-such-run 2>&1 >/dev/null )"; rc_noexist=$?
check "explicit nonexistent run-id -> nonzero" "$([[ $rc_noexist -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "explicit nonexistent run-id -> mentions run-id" "$([[ "$NOEXIST_ERR" == *"nope-no-such-run"* ]] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
# a run with one completed (verdicted) criterion and one started-but-not-
# verdicted criterion -> cursor points at the unverdicted tuple; skip lists
# the completed one; openActs empty (no acts at all in this run).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started rone admin AC1 admin >/dev/null )
( cd "$WORK" && bash "$CHECKPOINT" rone AC1 pass --persona admin --last-action "did it" >/dev/null )
( cd "$WORK" && bash "$EMIT" started rone user AC2 user >/dev/null )

BRIEF1="$( cd "$WORK" && bash "$RESUME" rone )"
check "briefing: run_id" "$(jq -r '.run_id' <<< "$BRIEF1")" "rone"
check "briefing: cursor scenarioId == user (first unverdicted)" "$(jq -r '.cursor.scenarioId' <<< "$BRIEF1")" "user"
check "briefing: cursor criterionId == AC2" "$(jq -r '.cursor.criterionId' <<< "$BRIEF1")" "AC2"
check "briefing: skip has exactly one entry" "$(jq '.skip | length' <<< "$BRIEF1")" "1"
check "briefing: skip[0] scenarioId == admin" "$(jq -r '.skip[0].scenarioId' <<< "$BRIEF1")" "admin"
check "briefing: skip[0] criterionId == AC1" "$(jq -r '.skip[0].criterionId' <<< "$BRIEF1")" "AC1"
check "briefing: openActs empty (no act_intent at all)" "$(jq '.openActs | length' <<< "$BRIEF1")" "0"

# ---------------------------------------------------------------------------
# explicit run-id OVERRIDES `.qa/runs/latest` — build a second run so `latest`
# points elsewhere, then request `rone` explicitly.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started rtwo admin ACX admin >/dev/null )
LATEST_CONTENT="$(cat "$WORK/.qa/runs/latest")"
check "latest pointer now points at rtwo (2nd run started later)" "$LATEST_CONTENT" "rtwo"

BRIEF_OVERRIDE="$( cd "$WORK" && bash "$RESUME" rone )"
check "explicit run-id overrides latest: run_id == rone" "$(jq -r '.run_id' <<< "$BRIEF_OVERRIDE")" "rone"

BRIEF_LATEST="$( cd "$WORK" && bash "$RESUME" )"
check "no-arg resolves via latest: run_id == rtwo" "$(jq -r '.run_id' <<< "$BRIEF_LATEST")" "rtwo"
check "no-arg via latest: cursor scenarioId == admin" "$(jq -r '.cursor.scenarioId' <<< "$BRIEF_LATEST")" "admin"
check "no-arg via latest: cursor criterionId == ACX" "$(jq -r '.cursor.criterionId' <<< "$BRIEF_LATEST")" "ACX"

# ---------------------------------------------------------------------------
# a run with an open act (act_intent, no act_committed) -> briefing's
# openActs is non-empty and carries the joined key/writeSet.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$EMIT" started ropen admin AC1 admin >/dev/null )
( cd "$WORK" && bash "$EMIT" act-intent ropen admin AC1 admin --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )

BRIEF_OPEN="$( cd "$WORK" && bash "$RESUME" ropen )"
check "open-act run: openActs has exactly one entry" "$(jq '.openActs | length' <<< "$BRIEF_OPEN")" "1"
check "open-act run: openActs[0] key == ropen:admin:AC1" "$(jq -r '.openActs[0].key' <<< "$BRIEF_OPEN")" "ropen:admin:AC1"
check "open-act run: openActs[0] writeSet == WS_ALL" "$(jq -c '.openActs[0].writeSet' <<< "$BRIEF_OPEN")" "$WS_ALL"
# AC1 is started (act-intent), no verdict yet -> it is ALSO the cursor, not skip.
check "open-act run: cursor points at the open-act tuple" "$(jq -r '.cursor.criterionId' <<< "$BRIEF_OPEN")" "AC1"
check "open-act run: skip is empty (nothing verdicted yet)" "$(jq '.skip | length' <<< "$BRIEF_OPEN")" "0"

# ---------------------------------------------------------------------------
# a run with NOTHING journaled at all for a given run-id: journal file simply
# absent -> dies clearly (distinct from a run whose journal exists but is
# empty of criteria).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/.qa/runs/rblank"
BLANK_ERR="$( cd "$WORK" && bash "$RESUME" rblank 2>&1 >/dev/null )"; rc_blank=$?
check "run dir exists but no journal.ndjson -> nonzero" "$([[ $rc_blank -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# `.qa/runs/latest` exists but is empty -> dies clearly (distinct message).
# ---------------------------------------------------------------------------
EMPTYLATEST_DIR="$WORK/empty-latest"
mkdir -p "$EMPTYLATEST_DIR/.qa/runs"
: > "$EMPTYLATEST_DIR/.qa/runs/latest"
EMPTYLATEST_ERR="$( cd "$EMPTYLATEST_DIR" && bash "$RESUME" 2>&1 >/dev/null )"; rc_emptylatest=$?
check "empty latest file -> nonzero" "$([[ $rc_emptylatest -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "empty latest file -> mentions empty" "$([[ "$EMPTYLATEST_ERR" == *"empty"* ]] && echo yes || echo no)" "yes"

echo "---"; echo "PASS=$PASS FAIL=$FAIL (jq default engine)"

# ---------------------------------------------------------------------------
# dual-engine equivalence: same scenario (one completed + one open-act
# criterion) under jq (default) vs. python3 (jq masked from PATH), canonically
# compared.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin-resume"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc grep mktemp python3 bash head tail tr; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  WORK_JQ="$WORK/dual-jq"; WORK_PY="$WORK/dual-py"
  mkdir -p "$WORK_JQ" "$WORK_PY"

  run_scenario() {
    local dir="$1"; shift
    local run_bash=(bash); local run_path=""
    if [[ "${1:-}" == "--py" ]]; then run_bash=("$BASH_BIN"); run_path="$FAKEBIN"; shift; fi
    ( cd "$dir" \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" started dual admin AC1 admin >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$CHECKPOINT" dual AC1 pass --persona admin --last-action "did it" >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" started dual user AC2 user >/dev/null \
        && PATH="${run_path:-$PATH}" "${run_bash[@]}" "$EMIT" act-intent dual user AC2 user --criterion "$MUT_CRIT" --write-set "$WS_ALL" >/dev/null )
  }
  run_scenario "$WORK_JQ"
  run_scenario "$WORK_PY" --py

  DUAL_JQ="$( cd "$WORK_JQ" && bash "$RESUME" dual )"
  DUAL_PY="$( cd "$WORK_PY" && PATH="$FAKEBIN" "$BASH_BIN" "$RESUME" dual )"
  canon_jq="$(bash "$JOURNAL" canonical <<< "$DUAL_JQ")"
  canon_py="$(bash "$JOURNAL" canonical <<< "$DUAL_PY")"
  check "dual-equiv: resume briefing canonically equal across engines" "$canon_jq" "$canon_py"
  check "dual-equiv: py-side cursor criterionId == AC2" "$(jq -r '.cursor.criterionId' <<< "$DUAL_PY")" "AC2"
  check "dual-equiv: py-side skip[0] criterionId == AC1" "$(jq -r '.skip[0].criterionId' <<< "$DUAL_PY")" "AC1"
  check "dual-equiv: py-side openActs[0] key == dual:user:AC2" "$(jq -r '.openActs[0].key' <<< "$DUAL_PY")" "dual:user:AC2"

  echo "note - dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - dual-engine sub-case: jq or python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
