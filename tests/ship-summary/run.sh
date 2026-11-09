#!/usr/bin/env bash
# Tests for the "Ship readiness" section of the deterministic report renderer
# (scripts/render-report.js, D6): verdict from coverage.json + journeys.json +
# checkpoint.json + verification.json, rendered first in report.md / report.html.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RR="$ROOT/scripts/render-report.js"
JSH="$ROOT/scripts/journeys.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
has(){ case "$2" in *"$3"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: $1 (expected to contain [$3])"; ;; esac; }
lacks(){ case "$2" in *"$3"*) fail=$((fail+1)); echo "FAIL: $1 (expected NOT to contain [$3])" ;; *) pass=$((pass+1)) ;; esac; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; echo "ship-summary: PASS=0 FAIL=0"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: ship-summary needs python3 to write fixtures" >&2; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# mk <name> <uncovered|none> <c9-verdict> <c9-layer> : a run dir with one P1 journey (J1-S1..S2, both pass)
# plus a P1-priority criterion C9 outside any journey.
mk() {
  local d="$W/$1"; mkdir -p "$d"
  python3 - "$d" "$2" "$3" "$4" <<'PY'
import json, sys
d, unc, c9, layer = sys.argv[1:5]
w = lambda n, v: open(d + "/" + n, "w", encoding="utf-8").write(json.dumps(v, ensure_ascii=False))
row = lambda i, extra=None: dict({"id": i, "surface": "/x", "kind": "happy-path", "tags": [], "action": "a", "priority": "P1"}, **(extra or {}))
w("checklist.json", [row("J1-S1", {"journey": {"id": "J-SUBMIT", "step": 1}}), row("J1-S2", {"journey": {"id": "J-SUBMIT", "step": 2}}), row("C9")])
cp = lambda i, v: {"criterion_id": i, "persona": "", "verdict": v, "confidence": "high", "checkpointed_at": "2026-11-09T10:00:00Z", "last_action": "ok", "bug_ref": "BUG-9" if v == "fail" else None, "evidence_refs": []}
w("checkpoint.json", {"run_id": "r", "criteria": [cp("J1-S1", "pass"), cp("J1-S2", "pass"), cp("C9", c9)]})
w("journeys.json", [{"id": "J-SUBMIT", "title": "t", "priority": "P1", "roles": ["participant"], "steps": ["J1-S1", "J1-S2"]}])
if unc != "none":
    u = int(unc)
    w("coverage.json", {"total": 10, "covered": 10 - u, "excluded": 0, "uncovered": u, "unscopedCovered": 0, "percent": 100 if u == 0 else 80, "rows": [], "warnings": [], "adapterOk": True})
w("verification.json", [])
w("bug-log.json", [{"bug_id": "BUG-9", "criterion_id": "C9", "title": "t", "suspected_layer": layer}] if layer else [])
w("effective-config.json", {"profile": "ship", "profileSources": {"gates.coverage": "profile-default", "maxParallel": "user"}})
PY
  node "$RR" "$d" --quiet >/dev/null 2>&1; check "render $1 exits 0" "$?" "0"
}
md(){ cat "$W/$1/report.md"; }
html(){ cat "$W/$1/report.html"; }

mk green 0 pass ""
M="$(md green)"; H="$(html green)"
has "ship_ready_all_green md verdict" "$M" "**SHIP-READY**"
lacks "ship_ready_all_green not-ready absent" "$M" "NOT SHIP-READY"
has "ship_ready_all_green html heading" "$H" "Ship readiness"
has "ship_ready_all_green census row" "$M" "| Census coverage | 10 of 10 covered (100%) · 0 uncovered |"
has "ship_ready_all_green p1 row" "$M" "| P1 journeys | 1 of 1 pass |"
has "ship_ready_all_green regression row" "$M" "| Regression suite | not yet available |"
has "ship_ready_all_green profile line" "$M" "turned on by the profile: gates.coverage"
lacks "profile-user key not listed as turned on" "$M" "maxParallel"
check "ship section is first (md)" "$(printf '%s' "$M" | grep -n '^## ' | head -1 | cut -d: -f2)" "## Ship readiness"
case "$H" in *'id="ship-readiness"'*'class="summary"'*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: ship before summary (html)" ;; esac

mk uncov 2 pass ""
M="$(md uncov)"
has "uncovered_not_ready verdict" "$M" "**NOT SHIP-READY**"
has "uncovered_not_ready reason" "$M" "2 census surface(s) uncovered"

mk svc 0 fail service
M="$(md svc)"
has "p1_service_fail_not_ready verdict" "$M" "**NOT SHIP-READY**"
has "p1_service_fail_not_ready reason" "$M" "coding-layer fail on P1 C9 (service)"

mk fe 0 fail FE
M="$(md fe)"
has "fe_fail_still_ready verdict" "$M" "**SHIP-READY**"
has "fe_fail_still_ready listed" "$M" "listed, not blocking: C9 (fe)"

mk nocov none pass ""
M="$(md nocov)"
has "missing_coverage_unknown row" "$M" "| Census coverage | unknown |"
has "missing_coverage_unknown verdict" "$M" "**NOT SHIP-READY**"

mk noj 0 pass ""; rm "$W/noj/journeys.json"; node "$RR" "$W/noj" --quiet >/dev/null 2>&1
M="$(md noj)"
has "missing journeys row" "$M" "| P1 journeys | none declared |"
has "missing journeys verdict" "$M" "**NOT SHIP-READY**"

# verifier override on a P1 criterion blocks
mk ovr 0 pass ""
python3 - "$W/ovr" <<'PY'
import json, sys
d = sys.argv[1]
json.dump([{"criterionId": "C9", "persona": "", "inRunVerdict": "pass", "verifierVerdict": "fail", "confidence": "high", "reasons": ["x"]}], open(d + "/verification.json", "w"))
PY
node "$RR" "$W/ovr" --quiet >/dev/null 2>&1
has "verifier_override_on_p1 blocks" "$(md ovr)" "verifier override on P1 C9"

# fix round 1: fail-closed cases
mk adp 0 pass ""
python3 - "$W/adp" <<'PY'
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/coverage.json")); c["adapterOk"] = False; json.dump(c, open(d + "/coverage.json", "w"))
PY
node "$RR" "$W/adp" --quiet >/dev/null 2>&1
has "adapter_failed blocks" "$(md adp)" "**NOT SHIP-READY**"
has "adapter_failed reason" "$(md adp)" "- census adapter failed"

mk nov 0 pass ""; rm "$W/nov/verification.json"; node "$RR" "$W/nov" --quiet >/dev/null 2>&1
M="$(md nov)"
has "missing_verification blocks" "$M" "**NOT SHIP-READY**"
has "missing_verification reason" "$M" "- not independently verified"
has "missing_verification row" "$M" "| Verifier overrides on P1 | unknown |"

mk stl 0 pass ""
python3 - "$W/stl" <<'PY'
import json, sys
d = sys.argv[1]
json.dump([{"criterionId": "C9", "persona": "", "inRunVerdict": "fail", "verifierVerdict": "fail", "confidence": "high", "reasons": []}], open(d + "/verification.json", "w"))
PY
node "$RR" "$W/stl" --quiet >/dev/null 2>&1
M="$(md stl)"
has "stale_verification blocks" "$M" "**NOT SHIP-READY**"
has "stale_verification reason" "$M" "verification out of date on P1 C9"

mk err 0 error service
has "error_counts_as_fail" "$(md err)" "coding-layer fail on P1 C9 (service)"
mk unk 0 fail ""
M="$(md unk)"
has "unknown_layer blocks" "$M" "**NOT SHIP-READY**"
has "unknown_layer shown" "$M" "C9 (layer unknown)"

mk emp 0 pass ""
python3 - "$W/emp" <<'PY'
import json, sys
d = sys.argv[1]
json.dump({"total": 3, "covered": 0, "excluded": 3, "uncovered": 0, "rows": [], "warnings": [], "adapterOk": True}, open(d + "/coverage.json", "w"))
PY
node "$RR" "$W/emp" --quiet >/dev/null 2>&1
M="$(md emp)"
has "empty_census row" "$M" "| Census coverage | unknown (empty census) |"
has "empty_census blocks" "$M" "**NOT SHIP-READY**"

mk pct 3 pass ""
python3 - "$W/pct" <<'PY'
import json, sys
d = sys.argv[1]
json.dump({"total": 8, "covered": 5, "excluded": 0, "uncovered": 3, "rows": [], "warnings": [], "adapterOk": True}, open(d + "/coverage.json", "w"))
PY
node "$RR" "$W/pct" --quiet >/dev/null 2>&1
M="$(md pct)"
has "percent_computed" "$M" "5 of 8 covered (62.5%)"
lacks "no undefined" "$M" "undefined"

mk nop1 0 pass ""
python3 - "$W/nop1" <<'PY'
import json, sys
d = sys.argv[1]
json.dump([{"id": "J-SUBMIT", "title": "t", "priority": "P2", "roles": [], "steps": ["J1-S1"]}], open(d + "/journeys.json", "w"))
PY
node "$RR" "$W/nop1" --quiet >/dev/null 2>&1
M="$(md nop1)"
has "zero_p1_journeys row" "$M" "| P1 journeys | none declared |"
has "zero_p1_journeys blocks" "$M" "**NOT SHIP-READY**"

has "flaky not tracked" "$(md green)" "| Flaky | not tracked |"
mk flk 0 pass ""
python3 - "$W/flk" <<'PY'
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/checkpoint.json")); c["criteria"][2]["flaky"] = True; json.dump(c, open(d + "/checkpoint.json", "w"))
PY
node "$RR" "$W/flk" --quiet >/dev/null 2>&1
has "flaky counted" "$(md flk)" "| Flaky | 1 |"
check "md ship body has no trailing separator" "$(printf '%s' "$(md green)" | sed -n '/^## Ship readiness/,/^## Summary/p' | grep -c '^---$')" "1"

# --- re-adjudication (ADR-0033) in the ship summary: I1, I2, M7 ---------------
# setrec <dir> <crit> <json-patch> : merge fields into that checkpoint record.
setrec() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d, cid, patch = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
c = json.load(open(d + "/checkpoint.json", encoding="utf-8"))
for r in c["criteria"]:
    if r["criterion_id"] == cid: r.update(patch)
json.dump(c, open(d + "/checkpoint.json", "w", encoding="utf-8"), ensure_ascii=False)
PY
}
rr(){ node "$RR" "$W/$1" --quiet >/dev/null 2>&1; }
DISPUTE='{"verdict": "blocked", "confidence": "low", "phase": "adjudicate", "last_action": "verifier-disagrees: bake shows no new row"}'

has "green re-adjudication row" "$(md green)" "| Re-adjudication | did not run — 0 low-confidence passes unreviewed |"

# I1: a P1 criterion outside any journey, disputed by the re-adjudicator, blocks.
mk dsp 0 pass ""; setrec "$W/dsp" C9 "$DISPUTE"; rr dsp
M="$(md dsp)"
has "disputed_p1_outside_journey blocks" "$M" "**NOT SHIP-READY**"
has "disputed_p1_outside_journey reason" "$M" "- verifier disputed P1 C9"
has "disputed_p1_outside_journey overrides line" "$M" "| Verifier overrides on P1 | C9 (disputed) |"
has "disputed_p1_outside_journey journeys still pass" "$M" "| P1 journeys | 1 of 1 pass |"
# a disputed fail (stays fail, confidence low) on P1 blocks the same way
mk dspf 0 fail FE; setrec "$W/dspf" C9 '{"confidence": "low", "phase": "adjudicate", "last_action": "verifier-disagrees: screenshot shows the card moved"}'; rr dspf
has "disputed_p1_fail blocks" "$(md dspf)" "- verifier disputed P1 C9"
# an unverified run still names the dispute
mk dspn 0 pass ""; setrec "$W/dspn" C9 "$DISPUTE"; rm "$W/dspn/verification.json"; rr dspn
has "disputed_unverified overrides line" "$(md dspn)" "| Verifier overrides on P1 | unknown · C9 (disputed) |"
has "disputed_unverified reason" "$(md dspn)" "- verifier disputed P1 C9"

# M7: the journey line says disputed, and uses the verifier-adjusted verdicts.
mk jdsp 0 pass ""; setrec "$W/jdsp" J1-S2 "$DISPUTE"; rr jdsp
M="$(md jdsp)"
has "journey_step_disputed line" "$M" "| P1 journeys | 0 of 1 pass · J-SUBMIT incomplete (disputed: J1-S2) |"
has "journey_step_disputed condition" "$M" "- P1 journey J-SUBMIT is incomplete (disputed: J1-S2)"
mk jov 0 pass ""
python3 - "$W/jov" <<'PY'
import json, sys
json.dump([{"criterionId": "J1-S2", "persona": "", "inRunVerdict": "pass", "verifierVerdict": "fail", "confidence": "high", "reasons": ["no-state-evidence"]}], open(sys.argv[1] + "/verification.json", "w"))
PY
rr jov
has "journey_uses_verifier_verdict" "$(md jov)" "| P1 journeys | 0 of 1 pass · J-SUBMIT fail |"

# I2: the Re-adjudication line and its conditions.
mk adjn 0 pass ""; setrec "$W/adjn" C9 '{"confidence": "low"}'; rr adjn
M="$(md adjn)"
has "readj_not_run line" "$M" "| Re-adjudication | did not run — 1 low-confidence passes unreviewed |"
has "readj_not_run p1 blocks" "$M" "- re-adjudication did not run — 1 P1 low-confidence pass(es) unreviewed: C9"
has "readj_not_run verdict" "$M" "**NOT SHIP-READY**"
# a low-confidence pass on a non-P1 row is listed, not blocking
mk adjp2 0 pass ""
python3 - "$W/adjp2" <<'PY'
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/checklist.json")); c[2]["priority"] = "P2"; json.dump(c, open(d + "/checklist.json", "w"))
PY
setrec "$W/adjp2" C9 '{"confidence": "low"}'; rr adjp2
M="$(md adjp2)"
has "readj_not_run_non_p1 line" "$M" "| Re-adjudication | did not run — 1 low-confidence passes unreviewed |"
has "readj_not_run_non_p1 ready" "$M" "**SHIP-READY**"
lacks "readj_not_run_non_p1 not blocked" "$M" "NOT SHIP-READY"
# ran, the verifier agreed
mk adja 0 pass ""; setrec "$W/adja" C9 '{"confidence": "low"}'; mkdir -p "$W/adja/adjudication"
printf '[{"criterionId":"C9","persona":"","agree":true,"reason":"bake row present"}]' > "$W/adja/adjudication/decisions.json"; rr adja
M="$(md adja)"
has "readj_ran_agree line" "$M" "| Re-adjudication | re-judged 1 · disputed 0 |"
lacks "readj_ran_agree ready" "$M" "NOT SHIP-READY"
# ran, the verifier disputed (the record is now blocked)
mk adjd 0 pass ""; setrec "$W/adjd" C9 "$DISPUTE"; mkdir -p "$W/adjd/adjudication"
printf '[{"criterionId":"C9","persona":"","agree":false,"reason":"bake shows no new row"}]' > "$W/adjd/adjudication/decisions.json"; rr adjd
M="$(md adjd)"
has "readj_ran_disputed line" "$M" "| Re-adjudication | re-judged 1 · disputed 1 (C9) |"
has "readj_ran_disputed blocks" "$M" "- verifier disputed P1 C9"
# ran, but a low-confidence P1 pass was never judged
mk adjl 0 pass ""; setrec "$W/adjl" C9 '{"confidence": "low"}'; mkdir -p "$W/adjl/adjudication"
printf '[]' > "$W/adjl/adjudication/decisions.json"; rr adjl
M="$(md adjl)"
has "readj_ran_unjudged line" "$M" "| Re-adjudication | re-judged 0 · disputed 0 · 1 low-confidence passes not re-judged |"
has "readj_ran_unjudged blocks" "$M" "- 1 P1 low-confidence pass(es) not re-judged: C9"
# a decision checkpoint.sh refused leaves no trace in checkpoint.json: read from apply.txt
mk adjr 0 fail FE; mkdir -p "$W/adjr/adjudication"
printf '[{"criterionId":"C9","persona":"","agree":false,"reason":"screenshot shows the card moved"}]' > "$W/adjr/adjudication/decisions.json"
printf 'ADJUDICATION: checkpoint.sh refused C9: SCREENSHOT GATE: no screenshot\nadjudication: applied=0 noop=0 rejected=0 failed=1\n' > "$W/adjr/adjudication/apply.txt"; rr adjr
M="$(md adjr)"
has "readj_refused line" "$M" "| Re-adjudication | re-judged 1 · disputed 1 (C9) · 1 decision(s) not applied (see adjudication/apply.txt) |"
has "readj_refused blocks" "$M" "- re-adjudication decision on P1 C9 was not applied"
# unavailable harness: the banner is shown, P1 low-confidence passes block
mk adju 0 pass ""; setrec "$W/adju" C9 '{"confidence": "low"}'; mkdir -p "$W/adju/adjudication"
printf 're-adjudication unavailable on codex; 1 low-confidence passes unreviewed\n' > "$W/adju/adjudication/unavailable.txt"; rr adju
M="$(md adju)"
has "readj_unavailable line" "$M" "| Re-adjudication | re-adjudication unavailable on codex; 1 low-confidence passes unreviewed |"
has "readj_unavailable blocks" "$M" "- re-adjudication unavailable — 1 P1 low-confidence pass(es) unreviewed: C9"
# M2 alignment: a confidence verification.json lowered counts as a low-confidence pass
mk adjv 0 pass ""
python3 - "$W/adjv" <<'PY'
import json, sys
json.dump([{"criterionId": "C9", "persona": "", "inRunVerdict": "pass", "verifierVerdict": "pass", "confidence": "low", "reasons": ["identity unverifiable"]}], open(sys.argv[1] + "/verification.json", "w"))
PY
rr adjv
has "readj_counts_verifier_confidence" "$(md adjv)" "| Re-adjudication | did not run — 1 low-confidence passes unreviewed |"

# non-ship run (no coverage/journeys/profile): byte-identical to the pre-ship renderer (commit 8a207a2)
git -C "$ROOT" show 8a207a2:scripts/render-report.js > "$W/old-render.js" 2>/dev/null
if [ -s "$W/old-render.js" ]; then
  mkdir -p "$W/g-new" "$W/g-old"
  cp -R "$ROOT/tests/render-report/fixture-run/." "$W/g-new/"; cp -R "$ROOT/tests/render-report/fixture-run/." "$W/g-old/"
  T="$ROOT/skills/writing-qa-reports/templates"
  node "$RR" "$W/g-new" --templates "$T" --quiet >/dev/null 2>&1
  node "$W/old-render.js" "$W/g-old" --templates "$T" --quiet >/dev/null 2>&1
  check "non_ship_run_golden_unchanged html" "$(cmp -s "$W/g-new/report.html" "$W/g-old/report.html" && echo same)" "same"
  check "non_ship_run_golden_unchanged md" "$(cmp -s "$W/g-new/report.md" "$W/g-old/report.md" && echo same)" "same"
  lacks "non_ship_run has no ship section" "$(cat "$W/g-new/report.md")" "Ship readiness"
else
  fail=$((fail+1)); echo "FAIL: could not read 8a207a2 render-report.js for golden compare"
fi

# journey verdict equals journeys.sh status on the same fixtures; superseded verdict used
FX="$ROOT/tests/journeys/fixtures"
for r in run-all-pass run-one-fail run-incomplete run-superseded run-multi-persona run-deferred; do
  d="$W/j-$r"; mkdir -p "$d"; cp -R "$FX/$r/." "$d/"
  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
json.dump({"total": 1, "covered": 1, "excluded": 0, "uncovered": 0, "unscopedCovered": 0, "percent": 100, "rows": [], "warnings": [], "adapterOk": True}, open(d + "/coverage.json", "w"))
PY
  node "$RR" "$d" --quiet >/dev/null 2>&1
  want="$(bash "$JSH" status "$d" | python3 -c 'import json,sys;j=json.load(sys.stdin)[0];print("1 of 1 pass" if j["verdict"]=="pass" else "0 of 1 pass · %s %s" % (j["id"], j["verdict"]))')"
  has "journey_status_matches_shell $r" "$(md "j-$r")" "| P1 journeys | $want |"
done
has "superseded_verdict_used" "$(md j-run-superseded)" "| P1 journeys | 1 of 1 pass |"

echo "ship-summary: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
