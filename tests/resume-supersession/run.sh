#!/usr/bin/env bash
# Regression suite for engine 0.11.0 (ADR-0029), built from a SANITIZED
# excerpt of a real 0.10.0 run (register-choose-later, 61 criteria, one
# resume) whose checkpoint.json ended with 100 rows for 61 criteria:
#
#   fixtures/journal.ndjson      — the run's own event sequence for five
#                                  criteria (+ the batch-slip row): the
#                                  shared-criterion slip (started admin/admin,
#                                  verdict __shared__/""), three persona-less
#                                  `deferred` placeholders that the resume
#                                  re-ran as `participant`, and one verdict
#                                  whose criterionId is several ids joined by
#                                  a shell loop. lastAction text, write-sets
#                                  and the run id are sanitized.
#   fixtures/checkpoint.v0100.json — what the 0.10.0 fold projected from it
#                                  (duplicate rows) — the stale input the
#                                  renderer and qa-verify must still count
#                                  per criterion.
#   fixtures/toolstream.jsonl    — the phase-surface shape of the same run:
#                                  login clicks after plan_frozen but before
#                                  the first phase_entered, a click during
#                                  Verify outside any acting window, a click
#                                  inside one, and a mutating evaluate.
#
# Covers: fold supersession (both engines, identical output), render-report
# and qa-verify per-criterion counting (fresh and stale checkpoints), the
# qa-resume `retry` list, the record-time identity guard (plan-guard.sh via
# checkpoint.sh and journal-emit.sh started), implicit phase windows +
# `journal-emit.sh phase`, and the capture hook's unjournaled-finding nudge.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPTS="$ROOT/skills/checkpointing-qa-memory/scripts"
FOLD="$SCRIPTS/fold.sh"; CKPT="$SCRIPTS/checkpoint.sh"; EMIT="$SCRIPTS/journal-emit.sh"
GUARD="$SCRIPTS/plan-guard.sh"; RESUME="$SCRIPTS/qa-resume.sh"
QAVERIFY="$ROOT/scripts/qa-verify.sh"; RENDER="$ROOT/scripts/render-report.sh"; HOOK="$ROOT/scripts/capture-hook.sh"
FX="$HERE/fixtures"
RID="rcl-fixture"
D2="RCL-D2-choose-in-screening-side-effects"; A1="RCL-A1-create-toggle-default-on"; C3="RCL-C3-choose-challenge-with-discipline-ar"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' unexpectedly contains '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export QA_REQUIRE_SCREENSHOTS=false

# fresh <dir> <run> [journal-lines] — a project dir whose run holds the fixture
# journal (optionally only its first N lines).
fresh() {
  local d="$1" run="$2" n="${3:-}"
  rm -rf "$d"; mkdir -p "$d/.qa/runs/$run"
  if [[ -n "$n" ]]; then head -n "$n" "$FX/journal.ndjson" > "$d/.qa/runs/$run/journal.ndjson"
  else cp "$FX/journal.ndjson" "$d/.qa/runs/$run/journal.ndjson"; fi
}

# ---------------------------------------------------------------------------
# 1. fold supersession — both engines, identical projection.
# ---------------------------------------------------------------------------
for ENGINE in jq python3; do
  P="$WORK/fold-$ENGINE"; fresh "$P" "$RID"
  ( cd "$P" && QA_ENGINE=$ENGINE bash "$FOLD" "$RID" >/dev/null )
  CK="$P/.qa/runs/$RID/checkpoint.json"; AN="$P/.qa/runs/$RID/fold-anomalies.json"
  check "[$ENGINE] fold: 6 authoritative rows (5 criteria + the batch-slip row), not 9" "$(jq '.criteria | length' "$CK")" "6"
  check "[$ENGINE] fold: 3 persona-less placeholders superseded" "$(jq '.superseded | length' "$CK")" "3"
  check "[$ENGINE] fold: D2's authoritative verdict is the resumed pass" \
    "$(jq -r --arg c "$D2" '[.criteria[] | select(.criterion_id == $c)] | map(.verdict + "/" + .persona) | join(",")' "$CK")" "pass/participant"
  check "[$ENGINE] fold: superseded D2 placeholder records what replaced it" \
    "$(jq -r --arg c "$D2" '.superseded[] | select(.criterion_id == $c) | .verdict + "->" + .superseded_by.verdict + "/" + .superseded_by.persona' "$CK")" "deferred->pass/participant"
  check "[$ENGINE] fold: a persona-less row with NO later persona verdict stays (A1 shared pass)" \
    "$(jq -r --arg c "$A1" '[.criteria[] | select(.criterion_id == $c)] | length' "$CK")" "1"
  check "[$ENGINE] fold: one superseded-row anomaly per superseded row" \
    "$(jq '[.anomalies[] | select(.rule == "superseded-row")] | length' "$AN")" "3"
  check "[$ENGINE] fold: tally over criteria[] is per criterion" \
    "$(jq -r '[.criteria[].verdict] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$CK")" "blocked=1 deferred=1 fail=1 pass=3"
done
check "fold: jq and python3 project byte-identical checkpoint.json" \
  "$(cmp -s "$WORK/fold-jq/.qa/runs/$RID/checkpoint.json" "$WORK/fold-python3/.qa/runs/$RID/checkpoint.json" && echo same)" "same"
check "fold: jq and python3 project byte-identical fold-anomalies.json" \
  "$(cmp -s "$WORK/fold-jq/.qa/runs/$RID/fold-anomalies.json" "$WORK/fold-python3/.qa/runs/$RID/fold-anomalies.json" && echo same)" "same"

# A persona-scoped row is NEVER superseded — not by a later persona-less row,
# not by another persona (two personas are two cases, ADR-0012).
for ENGINE in jq python3; do
  P="$WORK/asym-$ENGINE"; mkdir -p "$P/.qa/runs/asym"
  printf '%s\n' \
    '{"event":"run_started","runId":"asym","seq":1,"t":"2026-10-01T10:00:00Z"}' \
    '{"event":"criterion_verdict","scenarioId":"admin","criterionId":"C1","personaId":"admin","verdict":"fail","confidence":"high","seq":2,"t":"2026-10-01T10:00:01Z"}' \
    '{"event":"criterion_verdict","scenarioId":"user","criterionId":"C1","personaId":"user","verdict":"deferred","confidence":"high","seq":3,"t":"2026-10-01T10:00:02Z"}' \
    '{"event":"criterion_verdict","scenarioId":"__shared__","criterionId":"C1","personaId":"","verdict":"pass","confidence":"high","seq":4,"t":"2026-10-01T10:00:03Z"}' \
    > "$P/.qa/runs/asym/journal.ndjson"
  ( cd "$P" && QA_ENGINE=$ENGINE bash "$FOLD" asym >/dev/null )
  check "[$ENGINE] fold: a later shared pass does not erase the admin fail or the user deferred" \
    "$(jq -r '[.criteria[] | .verdict + "/" + .persona] | join(",")' "$P/.qa/runs/asym/checkpoint.json")" "fail/admin,deferred/user,pass/"
  check "[$ENGINE] fold: no superseded key when nothing is superseded" \
    "$(jq 'has("superseded")' "$P/.qa/runs/asym/checkpoint.json")" "false"
done

# ---------------------------------------------------------------------------
# 2. render-report — per-criterion tally, superseded + out-of-plan reported.
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  OUT="$(bash "$RENDER" "$WORK/fold-jq/.qa/runs/$RID" 2>&1)"
  contains "render (fresh fold): tally counts each criterion once; batch row excluded" "$OUT" \
    "tally: pass=3 fail=1 blocked=1 deferred=0 error=0 total=5"
  contains "render (fresh fold): reports superseded and out-of-plan rows" "$OUT" "criteria=5 superseded=3 out_of_plan=1"
  contains "render (fresh fold): report.md names the process anomalies" \
    "$(cat "$WORK/fold-jq/.qa/runs/$RID/report.md")" "3 superseded row(s) not counted"

  S="$WORK/stale/.qa/runs/$RID"; mkdir -p "$S"
  cp "$FX/journal.ndjson" "$S/"; cp "$FX/checkpoint.v0100.json" "$S/checkpoint.json"
  check "stale fixture really is the 0.10.0 duplicate projection (9 rows)" "$(jq '.criteria | length' "$S/checkpoint.json")" "9"
  OUT="$(bash "$RENDER" "$S" 2>&1)"
  contains "render (stale 0.10.0 checkpoint): same per-criterion tally without re-folding" "$OUT" \
    "tally: pass=3 fail=1 blocked=1 deferred=0 error=0 total=5"
  contains "render (stale 0.10.0 checkpoint): superseded rows found by timestamp" "$OUT" "superseded=3 out_of_plan=1"
  lacks "render (stale): the deferred placeholders are not in the Deferred section" \
    "$(sed -n '/## Deferred/,/## Bugs/p' "$S/report.md")" "$D2"
else
  echo "SKIP: node not available (render-report checks)"
fi

# ---------------------------------------------------------------------------
# 3. qa-verify — skips superseded passes, reports the count (stale input).
# ---------------------------------------------------------------------------
for ENGINE in jq python3; do
  P="$WORK/qv-$ENGINE"; rm -rf "$P"; mkdir -p "$P/.qa/runs/$RID"
  cp "$FX/checkpoint.v0100.json" "$P/.qa/runs/$RID/checkpoint.json"
  # a stale persona-less PASS that a later persona verdict superseded: it
  # must not be re-checked (and must not be overridden) as its own outcome.
  jq --arg c "$C3" '.criteria += [{"criterion_id":$c,"persona":"","verdict":"pass","confidence":"high","kinds":[],"evidence_refs":[],"checkpointed_at":"2026-10-01T14:00:00Z"}]' \
    "$P/.qa/runs/$RID/checkpoint.json" > "$P/ck.tmp" && mv "$P/ck.tmp" "$P/.qa/runs/$RID/checkpoint.json"
  ERR="$( cd "$P" && QA_ENGINE=$ENGINE bash "$QAVERIFY" "$RID" 2>&1 >/dev/null )"
  contains "[$ENGINE] qa-verify: summary counts criteria and superseded rows" "$ERR" "criteria=6 superseded=4"
  check "[$ENGINE] qa-verify: the superseded shared pass is not re-checked" \
    "$(jq -r --arg c "$C3" '[.[] | select(.criterionId == $c)] | length' "$P/.qa/runs/$RID/verification.json")" "0"
  check "[$ENGINE] qa-verify: the authoritative passes are re-checked (A1, B1, D2)" \
    "$(jq -r '[.[] | select(.criterionId | startswith("RCL-")) | .criterionId] | sort | join(",")' "$P/.qa/runs/$RID/verification.json")" \
    "RCL-A1-create-toggle-default-on,RCL-B1-decide-later-card-first,$D2"
done

# ---------------------------------------------------------------------------
# 4. qa-resume — deferred tuples are retried under their own identity.
# ---------------------------------------------------------------------------
for ENGINE in jq python3; do
  P="$WORK/res-$ENGINE"; fresh "$P" "$RID" 16   # the first pass only (ends with the placeholders)
  B="$( cd "$P" && QA_ENGINE=$ENGINE bash "$RESUME" "$RID" 2>/dev/null )"
  check "[$ENGINE] qa-resume: deferred placeholders are in retry (3 + the batch row)" "$(jq '.retry | length' <<< "$B")" "4"
  check "[$ENGINE] qa-resume: skip holds only finished work (A1, B1)" "$(jq -r '[.skip[].criterionId] | join(",")' <<< "$B")" \
    "RCL-A1-create-toggle-default-on,RCL-B1-decide-later-card-first"
  check "[$ENGINE] qa-resume: retry names the identity to re-run under" \
    "$(jq -r --arg c "$D2" '.retry[] | select(.criterionId == $c) | .scenarioId + "|" + .personaId' <<< "$B")" "__shared__|"
done

# ---------------------------------------------------------------------------
# 5. record-time identity guard — each slip of the real run is refused, and
#    nothing is appended when it is.
# ---------------------------------------------------------------------------
lines() { wc -l < "$1" | tr -d ' '; }
for ENGINE in jq python3; do
  P="$WORK/guard-$ENGINE"; fresh "$P" "$RID" 2   # run_started + plan_frozen
  J="$P/.qa/runs/$RID/journal.ndjson"
  if [[ "$ENGINE" == python3 ]]; then
    FB="$P/fakebin"; mkdir -p "$FB"; for t in date mkdir cat python3; do ln -sf "$(command -v "$t")" "$FB/$t"; done
    ck() { ( cd "$P" && PATH="$FB" "$(command -v bash)" "$CKPT" "$@" ); }
  else
    ck() { ( cd "$P" && bash "$CKPT" "$@" ); }
  fi
  em() { ( cd "$P" && QA_ENGINE=$ENGINE bash "$EMIT" "$@" ); }

  n0="$(lines "$J")"
  MSG="$(ck "$RID" "$C3 $D2" deferred 2>&1)"; RC=$?
  check "[$ENGINE] guard: batch-joined criterion id refused" "$RC" "1"
  contains "[$ENGINE] guard: batch refusal says one criterion per call" "$MSG" "record ONE criterion per call"
  MSG="$(ck "$RID" RCL-ZZ-not-planned deferred 2>&1)"; RC=$?
  check "[$ENGINE] guard: criterion outside the frozen plan refused" "$RC" "1"
  contains "[$ENGINE] guard: out-of-plan refusal names amend" "$MSG" "journal-emit.sh amend"
  MSG="$(ck "$RID" "$D2" deferred 2>&1)"; RC=$?
  check "[$ENGINE] guard: persona-less verdict for a participant-planned criterion refused" "$RC" "1"
  contains "[$ENGINE] guard: refusal names the planned persona" "$MSG" "planned for persona(s) [participant]"
  check "[$ENGINE] guard: nothing appended by any refusal" "$(lines "$J")" "$n0"

  MSG="$(em started "$RID" admin "$A1" "" 2>&1)"; RC=$?
  check "[$ENGINE] guard: started with a role scenario and empty persona refused" "$RC" "1"
  contains "[$ENGINE] guard: started refusal shows the shared form" "$MSG" "started $RID __shared__ $A1"
  MSG="$(em started "$RID" admin "$A1" participant 2>&1)"; RC=$?
  check "[$ENGINE] guard: started whose scenario != persona refused" "$RC" "1"
  MSG="$(em started "$RID" __shared__ "$A1" "" 2>&1)"; RC=$?
  check "[$ENGINE] guard: started as shared refused when the plan names admin" "$RC" "1"
  check "[$ENGINE] guard: still nothing appended" "$(lines "$J")" "$n0"

  em started "$RID" admin "$A1" admin >/dev/null 2>&1; RC=$?
  check "[$ENGINE] guard: started with the planned identity accepted" "$RC" "0"
  MSG="$(ck "$RID" "$A1" deferred 2>&1)"; RC=$?
  check "[$ENGINE] guard: the real slip — started admin/admin, verdict without --persona — refused" "$RC" "1"
  ck "$RID" "$A1" deferred --persona admin >/dev/null 2>&1; RC=$?
  check "[$ENGINE] guard: verdict under the started identity accepted" "$RC" "0"
  check "[$ENGINE] guard: one started + phase/verdict (+ capture probe) appended" "$(( $(lines "$J") - n0 ))" "4"

  # no plan: the started-identity rule still holds (legacy runs keep the rest)
  P2="$WORK/noplan-$ENGINE"; rm -rf "$P2"; mkdir -p "$P2/.qa/runs/np"
  ( cd "$P2" && QA_ENGINE=$ENGINE bash "$EMIT" started np admin C1 admin >/dev/null )
  if [[ "$ENGINE" == python3 ]]; then
    MSG="$( cd "$P2" && PATH="$FB" "$(command -v bash)" "$CKPT" np C1 deferred 2>&1)"; RC=$?
  else
    MSG="$( cd "$P2" && bash "$CKPT" np C1 deferred 2>&1)"; RC=$?
  fi
  check "[$ENGINE] guard (no plan): verdict under a different identity than the open start refused" "$RC" "1"
  contains "[$ENGINE] guard (no plan): message names the started identity" "$MSG" "admin / admin"
  ( cd "$P2" && bash "$CKPT" np C2 deferred >/dev/null 2>&1 ); RC=$?
  check "[$ENGINE] guard (no plan): an unplanned, unstarted criterion still records (legacy)" "$RC" "0"
done

# ---------------------------------------------------------------------------
# 6. phase windows end implicitly; `journal-emit.sh phase` closes for you.
# ---------------------------------------------------------------------------
for ENGINE in jq python3; do
  P="$WORK/ps-$ENGINE"; fresh "$P" "$RID"
  cp "$FX/toolstream.jsonl" "$P/.qa/runs/$RID/toolstream.jsonl"
  printf '{"criteria":[]}' > "$P/.qa/runs/$RID/checkpoint.json"
  ( cd "$P" && QA_ENGINE=$ENGINE bash "$QAVERIFY" "$RID" >/dev/null 2>&1 )
  PS="$(jq -c '[.[] | select(.criterionId == "__phase-surface__") | .reasons[]]' "$P/.qa/runs/$RID/verification.json")"
  check "[$ENGINE] phase-surface: only the mutating evaluate outside every acting window is flagged" "$(jq 'length' <<< "$PS")" "1"
  contains "[$ENGINE] phase-surface: the flagged call is the evaluate" "$PS" "browser_evaluate"
  lacks "[$ENGINE] phase-surface: login clicks after plan_frozen are no longer 'undeterminable'" "$PS" "undeterminable"

  # an explicit phase_exited closes Verify: a click after it IS flagged.
  printf '%s\n' '{"event":"phase_exited","phase":"verify","seq":30,"t":"2026-10-01T16:30:00Z"}' >> "$P/.qa/runs/$RID/journal.ndjson"
  printf '%s\n' '{"seq":6,"ts":"2026-10-01T16:31:00Z","tool":"mcp__plugin_playwright_playwright__browser_click","args":{"element":"x"},"resultDigest":{"len":0,"sha256":"a6"}}' >> "$P/.qa/runs/$RID/toolstream.jsonl"
  ( cd "$P" && QA_ENGINE=$ENGINE bash "$QAVERIFY" "$RID" >/dev/null 2>&1 )
  contains "[$ENGINE] phase-surface: a click after an explicit phase_exited is flagged" \
    "$(jq -c '[.[] | select(.criterionId == "__phase-surface__") | .reasons[]]' "$P/.qa/runs/$RID/verification.json")" \
    "no phase window was open"

  P3="$WORK/ph-$ENGINE"; rm -rf "$P3"; mkdir -p "$P3"
  ( cd "$P3" && QA_ENGINE=$ENGINE bash "$EMIT" phase r Verify >/dev/null && QA_ENGINE=$ENGINE bash "$EMIT" phase r verify >/dev/null \
      && QA_ENGINE=$ENGINE bash "$EMIT" phase r Report >/dev/null )
  check "[$ENGINE] journal-emit phase: closes the open window itself, re-entering is a no-op" \
    "$(jq -r -s '[.[] | select(.event != "run_started") | .event + ":" + .phase] | join(",")' "$P3/.qa/runs/r/journal.ndjson")" \
    "phase_entered:Verify,phase_exited:Verify,phase_entered:Report"
  ( cd "$P3" && QA_ENGINE=$ENGINE bash "$EMIT" phase r Discover >/dev/null 2>&1 ); RC=$?
  check "[$ENGINE] journal-emit phase: an unknown phase is refused" "$RC" "1"
done

# ---------------------------------------------------------------------------
# 7. capture hook — an observed in-scope 500 with no finding_observed is
#    called out N captured calls later (the real run journaled it only after
#    qa-verify's ledger check failed at the end).
# ---------------------------------------------------------------------------
for ENGINE in jq python3; do
  P="$WORK/hook-$ENGINE"; rm -rf "$P"; mkdir -p "$P/.qa/runs/$RID"
  echo "$RID" > "$P/.qa/runs/latest"
  printf '%s' '{"baseUrl":"https://app.test","humanInteraction":{"saveSession":false}}' > "$P/.qa/config.json"
  head -n 2 "$FX/journal.ndjson" > "$P/.qa/runs/$RID/journal.ndjson"
  printf '%s\n' '{"seq":1,"ts":"2026-10-01T15:43:36Z","tool":"mcp__plugin_playwright_playwright__browser_network_requests","args":{},"resultDigest":{"len":1,"sha256":"n1"},"responseBody":"","observed":{"source":"network-requests","network":[{"method":"GET","url":"https://app.test/api/v1/superset/data/hackathon-dashboard-data?hackathon_id=1","status":500},{"method":"GET","url":"https://widgets.other.test/config","status":503}]}}' \
    > "$P/.qa/runs/$RID/toolstream.jsonl"
  hook() { ( cd "$P" && printf '{"tool_name":"mcp__plugin_playwright_playwright__browser_snapshot","tool_input":{},"tool_response":"ok"}' \
            | QA_ENGINE=$ENGINE CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" 2>/dev/null ); }
  O1="$(hook)"; O2="$(hook)"; O3="$(hook)"
  check "[$ENGINE] nudge: silent before N (=3) calls have passed" "$O1$O2" ""
  contains "[$ENGINE] nudge: at N calls the unjournaled 500 is named" "$O3" "Unjournaled finding: GET https://app.test/api/v1/superset/data/hackathon-dashboard-data?hackathon_id=1 returned 500"
  lacks "[$ENGINE] nudge: a third-party 503 is not nudged" "$O3" "widgets.other.test"
  O4="$(hook)"
  check "[$ENGINE] nudge: not repeated on every call" "$O4" ""
  printf '%s\n' '{"event":"finding_observed","criterionId":"RCL-I1","source":"net","channel":"toolstream","method":"GET","url":"https://app.test/api/v1/superset/data/hackathon-dashboard-data?hackathon_id=1","status":500,"seq":3,"t":"2026-10-01T15:44:00Z"}' \
    >> "$P/.qa/runs/$RID/journal.ndjson"
  hook >/dev/null; O6="$(hook)"
  check "[$ENGINE] nudge: silent once the finding is journaled (2N)" "$O6" ""
done

# plan-guard usage errors
bash "$GUARD" check a b c >/dev/null 2>&1; check "plan-guard: wrong arity is a usage error (exit 2)" "$?" "2"

echo "resume-supersession: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
