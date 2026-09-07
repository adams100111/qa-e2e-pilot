#!/usr/bin/env bash
# tests/cost-summary/run.sh — dual-engine suite for
# skills/checkpointing-qa-memory/scripts/cost-summary.sh (audit-2 W4-3).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../../skills/checkpointing-qa-memory/scripts/cost-summary.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to contain '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'cd /; rm -rf "$WORK"' EXIT
cd "$WORK"

jget() { jq -r "$2" <<< "$1"; }

# ---------------------------------------------------------------------------
# 1) No run dir at all -> graceful empty summary, exit 0, honest degrade.
# ---------------------------------------------------------------------------
OUT0="$(bash "$S" nope)"; rc0=$?
check "empty run: exit 0"            "$rc0" "0"
check "empty run: toolCalls"         "$(jget "$OUT0" .toolCalls)" "0"
check "empty run: criteria"          "$(jget "$OUT0" .criteria)" "0"
check "empty run: attribution"       "$(jget "$OUT0" .attribution)" "unavailable"
check "empty run: startedAt null"    "$(jget "$OUT0" .startedAt)" "null"
check "empty run: criteriaDone null" "$(jget "$OUT0" .criteriaDone)" "null"
check "empty run: budgetWarn null"   "$(jget "$OUT0" .budgetWarn)" "null"
check "empty run: tokens null"       "$(jget "$OUT0" .tokens)" "null"
check "empty run: default budget 60" "$(jget "$OUT0" .criteriaBudget)" "60"

# ---------------------------------------------------------------------------
# 2) Full fixture: manifest + config + journal (2 criteria) + toolstream (7
#    calls: 2 before C1, 3 in C1's window, 2 in C2's window).
# ---------------------------------------------------------------------------
setup_full_fixture() {
  local run="$1"
  mkdir -p ".qa/runs/${run}"
  cat > ".qa/runs/${run}/run-manifest.json" <<EOF
{"run_id":"${run}","started_at":"2026-09-07T10:00:00Z","ended_at":null,"criteria_done":2,"criteria_total":5}
EOF
  cat > .qa/config.json <<'EOF'
{"criteriaBudget": 5}
EOF
  cat > ".qa/runs/${run}/journal.ndjson" <<EOF
{"event":"run_started","runId":"${run}","seq":1,"t":"2026-09-07T10:00:00Z"}
{"event":"criterion_started","scenarioId":"__shared__","criterionId":"C1","personaId":"","seq":2,"t":"2026-09-07T10:00:05Z"}
{"event":"criterion_started","scenarioId":"__shared__","criterionId":"C2","personaId":"","seq":3,"t":"2026-09-07T10:00:20Z"}
EOF
  : > ".qa/runs/${run}/toolstream.jsonl"
  local i=0
  for t in "2026-09-07T10:00:01Z" "2026-09-07T10:00:02Z" "2026-09-07T10:00:06Z" "2026-09-07T10:00:10Z" "2026-09-07T10:00:15Z" "2026-09-07T10:00:21Z" "2026-09-07T10:00:25Z"; do
    i=$((i+1))
    echo "{\"tool\":\"Bash\",\"args\":{},\"resultDigest\":{\"len\":0,\"sha256\":\"x\"},\"responseBody\":\"\",\"seq\":${i},\"ts\":\"${t}\"}" >> ".qa/runs/${run}/toolstream.jsonl"
  done
}
setup_full_fixture r1

OUT1="$(bash "$S" r1)"
check "r1: toolCalls total"         "$(jget "$OUT1" .toolCalls)" "7"
check "r1: criteria distinct"       "$(jget "$OUT1" .criteria)" "2"
check "r1: C1 count"                "$(jget "$OUT1" '.toolCallsByCriterion.C1')" "3"
check "r1: C2 count"                "$(jget "$OUT1" '.toolCallsByCriterion.C2')" "2"
check "r1: unattributed before C1"  "$(jget "$OUT1" .unattributedToolCalls)" "2"
check "r1: attribution mode"        "$(jget "$OUT1" .attribution)" "time-windowed"
check "r1: startedAt passthrough"   "$(jget "$OUT1" .startedAt)" "2026-09-07T10:00:00Z"
check "r1: finishedAt null (ended_at null)" "$(jget "$OUT1" .finishedAt)" "null"
check "r1: criteriaDone passthrough" "$(jget "$OUT1" .criteriaDone)" "2"
check "r1: criteriaBudget from config" "$(jget "$OUT1" .criteriaBudget)" "5"
check "r1: budgetWarn false (2/5=40%)" "$(jget "$OUT1" .budgetWarn)" "false"
check "r1: tokens null (no --tokens)" "$(jget "$OUT1" .tokens)" "null"

OUT1T="$(bash "$S" r1 --tokens 999)"
check "r1: --tokens populates field" "$(jget "$OUT1T" .tokens)" "999"

# ---------------------------------------------------------------------------
# 3) Budget-warn fires at exactly 80% consumption (spec W4-3 acceptance:
#    "budget-warn fires in a fixture run at 80%").
# ---------------------------------------------------------------------------
mkdir -p .qa/runs/r2
cat > .qa/runs/r2/run-manifest.json <<'EOF'
{"run_id":"r2","started_at":"2026-09-07T10:00:00Z","ended_at":"2026-09-07T10:05:00Z","criteria_done":4,"criteria_total":5}
EOF
cat > .qa/config.json <<'EOF'
{"criteriaBudget": 5}
EOF
OUT2="$(bash "$S" r2)"
check "r2: 4/5=80% -> budgetWarn true" "$(jget "$OUT2" .budgetWarn)" "true"
check "r2: finishedAt passthrough (ended_at set)" "$(jget "$OUT2" .finishedAt)" "2026-09-07T10:05:00Z"
check "r2: no journal -> attribution unavailable" "$(jget "$OUT2" .attribution)" "unavailable"
check "r2: no journal -> toolCallsByCriterion empty" "$(jget "$OUT2" .toolCallsByCriterion)" "{}"

mkdir -p .qa/runs/r3
cat > .qa/runs/r3/run-manifest.json <<'EOF'
{"run_id":"r3","started_at":"2026-09-07T10:00:00Z","ended_at":null,"criteria_done":3,"criteria_total":5}
EOF
OUT3="$(bash "$S" r3)"
check "r3: 3/5=60% -> budgetWarn false" "$(jget "$OUT3" .budgetWarn)" "false"

# ---------------------------------------------------------------------------
# 4) No .qa/config.json at all -> default criteriaBudget (60), never null.
# ---------------------------------------------------------------------------
mkdir -p .qa/runs/r4
rm -f .qa/config.json
cat > .qa/runs/r4/run-manifest.json <<'EOF'
{"run_id":"r4","started_at":"2026-09-07T10:00:00Z","ended_at":null,"criteria_done":1,"criteria_total":5}
EOF
OUT4="$(bash "$S" r4)"
check "r4: no config -> default criteriaBudget 60" "$(jget "$OUT4" .criteriaBudget)" "60"
check "r4: 1/60 -> budgetWarn false" "$(jget "$OUT4" .budgetWarn)" "false"

# ---------------------------------------------------------------------------
# 5) Torn last line in both journal.ndjson and toolstream.jsonl is skipped,
#    not fatal (mirrors fold.sh's own torn-line tolerance).
# ---------------------------------------------------------------------------
mkdir -p .qa/runs/r5
cat > .qa/runs/r5/journal.ndjson <<'EOF'
{"event":"criterion_started","scenarioId":"__shared__","criterionId":"C1","personaId":"","seq":1,"t":"2026-09-07T10:00:00Z"}
{"event":"criterion_started","scenarioId":"__shared__","criterionId"
EOF
cat > .qa/runs/r5/toolstream.jsonl <<'EOF'
{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"x"},"responseBody":"","seq":1,"ts":"2026-09-07T10:00:01Z"}
{"tool":"Bash","args":{},"resultDig
EOF
OUT5="$(bash "$S" r5)"; rc5=$?
check "r5: torn lines -> exit 0"       "$rc5" "0"
check "r5: torn journal -> 1 boundary" "$(jget "$OUT5" .criteria)" "1"
check "r5: torn toolstream -> 1 call"  "$(jget "$OUT5" .toolCalls)" "1"
check "r5: torn line's call attributed" "$(jget "$OUT5" '.toolCallsByCriterion.C1')" "1"

# ---------------------------------------------------------------------------
# 6) Invalid run-id rejected before touching the filesystem.
# ---------------------------------------------------------------------------
bash "$S" "../evil" >/dev/null 2>&1; rc6=$?
check "invalid run-id (path separator) rejected" "$([[ $rc6 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

bash "$S" >/dev/null 2>&1; rc7=$?
check "missing run-id arg rejected" "$([[ $rc7 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# 7) QA_ENGINE=python3 forces the fallback even with jq present, and the
#    python3-fallback pass (jq masked from PATH, mirroring
#    tests/toolstream's own technique) reproduces the SAME numbers as jq.
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  QOUT="$(QA_ENGINE=python3 bash "$S" r1)"
  check "QA_ENGINE=python3: toolCalls matches jq path" "$(jget "$QOUT" .toolCalls)" "7"
  check "QA_ENGINE=python3: C1 count matches jq path"  "$(jget "$QOUT" '.toolCallsByCriterion.C1')" "3"
  check "QA_ENGINE=python3: budgetWarn matches jq path" "$(jget "$QOUT" .budgetWarn)" "false"

  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir cat dirname sed wc python3 tr head awk; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done
  PYOUT="$(PATH="$FAKEBIN" "$BASH_BIN" "$S" r1)"
  check "py-fallback: toolCalls" "$(jget "$PYOUT" .toolCalls)" "7"
  check "py-fallback: C1 count"  "$(jget "$PYOUT" '.toolCallsByCriterion.C1')" "3"
  check "py-fallback: C2 count"  "$(jget "$PYOUT" '.toolCallsByCriterion.C2')" "2"
  check "py-fallback: criteria"  "$(jget "$PYOUT" .criteria)" "2"
  check "py-fallback: still valid JSON" "$(jq -e . >/dev/null 2>&1 <<< "$PYOUT" && echo valid || echo invalid)" "valid"
  echo "note - python3-fallback sub-case: RAN"
else
  echo "SKIP - python3-fallback sub-case: jq or python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
