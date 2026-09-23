#!/usr/bin/env bash
# tests/qa-ci-verify/run.sh — Plan H2 Task 5: qa-verify wired into the CI
# turnkey chain (qa-ci.sh) + report-to-junit.sh honoring verification.json.
#
# Covers:
#   PART 1 — report-to-junit.sh, against real fixtures built with the actual
#     checkpoint.sh/record-evidence.sh/toolstream.sh/qa-verify.sh (same idiom
#     as tests/qa-verify/run.sh, not hand-authored JSON):
#       - a pass qa-verify OVERRIDES (unbound human-action provenance) ->
#         the JUnit testcase renders as a <failure> carrying the verifier's
#         reason, and the suite's exit code + failures count reflect it.
#       - a pass qa-verify only DEGRADES (no-toolstream confidence:low, no
#         override) -> surfaced via a <system-out>, not just the name
#         suffix; the testcase stays a plain pass (no <failure>).
#   PART 2 — back-compat: NO verification.json at all -> today's rendering
#     is unchanged (plain testcase/failure shapes), the assurance-tier
#     property is honest that qa-verify was NOT run for that report.
#   PART 3 — qa-ci.sh: the qa-verify step's exit code genuinely gates the
#     FINAL exit (independent of report-to-junit's own exit code), and
#     QA_SKIP_VERIFY is explicit and LOGGED, never silent.
#   PART 5/6 — Task 10 (plan 2026-09-23-error-honesty-invariants, spec §5.7):
#     run-level `UNVERIFIED` reaches the EXIT CODE. The word already existed
#     in `<properties>`, which `:395`'s `sys.exit(1 if (failures or errors)`
#     can never see; Task 10 SYNTHESIZES a `<testcase name="__run-verified__">`
#     carrying a `<failure>` so it lands in the failures count, and
#     `QA_SKIP_VERIFY=1` stops buying a green build.
#
# TWO EXISTING EXPECTATIONS DELIBERATELY FLIP HERE, and only these two — both
# are the behaviour Task 10 exists to remove, so leaving them green would be
# leaving the bug in:
#   - PART 1b (`lowconf`, a run with NO capture channel at all) exited 0.
#   - PART 3 Case C (`QA_SKIP_VERIFY=1`) exited 0.
# Every other pre-existing assertion is preserved verbatim; where a fixture
# only ever exited 0 incidentally (it had no independent capture because it
# never needed one), the FIXTURE gains a real capture channel rather than the
# assertion being weakened.
#
# Every fixture writer/reader in PART 1/2 is invoked via `cd "$WORK" && ...`
# (never shelling out with an absolute run-id path), matching this repo's
# established test idiom.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
QACI="$ROOT/scripts/qa-ci.sh"
JUNIT="$ROOT/scripts/report-to-junit.sh"
CKPT="$ROOT/skills/checkpointing-qa-memory/scripts/checkpoint.sh"
REC="$ROOT/skills/checkpointing-qa-memory/scripts/record-evidence.sh"
TOOLSTREAM="$ROOT/scripts/toolstream.sh"
QAVERIFY="$ROOT/scripts/qa-verify.sh"
JOURNAL="$ROOT/skills/checkpointing-qa-memory/scripts/journal.sh"
FOLD="$ROOT/skills/checkpointing-qa-memory/scripts/fold.sh"

PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }
check_not_contains() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' unexpectedly contains '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# PART 1a — a forged human-action pass with NO matching toolstream capture:
# qa-verify overrides it -> junit must render a <failure> even though
# checkpoint.json still says "pass".
# ===========================================================================
( cd "$WORK" && bash "$TOOLSTREAM" append overridden '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"o1"},"responseBody":"{\"unrelated\":true}"}' >/dev/null )
O_REF="$( cd "$WORK" && bash "$REC" overridden C1 action-trace \
  --steps '[{"tool":"browser_click","phase":"act"}]' \
  --fingerprint-before '{"count":1}' --fingerprint-after '{"count":1}' )"
( cd "$WORK" && bash "$CKPT" overridden C1 pass --kinds human-action --evidence-refs "$O_REF" >/dev/null )
mkdir -p "$WORK/.qa/runs/overridden"
printf '[{"id":"C1","surface":"/x","kind":"error-state","tags":[],"action":"Add a duplicate to trigger a validation error"}]' \
  > "$WORK/.qa/runs/overridden/checklist.json"

( cd "$WORK" && bash "$QAVERIFY" overridden >/dev/null 2>&1 )
VRC=$?
check "fixture sanity: qa-verify overrides the forged pass (exit non-zero)" "$([[ "$VRC" -ne 0 ]] && echo yes)" "yes"
check "fixture sanity: verification.json was written" "$([[ -f "$WORK/.qa/runs/overridden/verification.json" ]] && echo yes)" "yes"

OUT_XML="$WORK/overridden.xml"
( cd "$WORK" && bash "$JUNIT" overridden "$OUT_XML" >/dev/null 2>&1 )
JRC=$?
check "junit: exits non-zero when qa-verify overrode a pass" "$([[ "$JRC" -ne 0 ]] && echo yes)" "yes"
XML="$(cat "$OUT_XML")"
check_contains "junit: overridden criterion renders as a <failure>" "$XML" '<failure'
check_contains "junit: failure message names the qa-verify override" "$XML" "qa-verify OVERRIDE"
check_contains "junit: failure body carries the verifier's reason (provenance UNBOUND)" "$XML" "UNBOUND"
check_contains "junit: testcase name flags the override" "$XML" "(qa-verify OVERRIDE)"
check_contains "junit: testsuite failures count reflects the override" "$XML" 'failures="1"'
check_contains "junit: assurance-tier property is present" "$XML" 'qa.assuranceTier'
check_contains "junit: qa.verified=true when verification.json exists" "$XML" 'name="qa.verified" value="true"'

# ===========================================================================
# PART 1b — a genuine pass with NO toolstream at all: qa-verify degrades
# confidence to low WITHOUT overriding -> junit must surface it via a
# <system-out>, not just bury it in the testcase name.
# ===========================================================================
LC_REF="$( cd "$WORK" && bash "$REC" lowconf C2 bake --read-back '{"anything":"1"}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" lowconf C2 pass --kinds bake --evidence-refs "$LC_REF" >/dev/null )
( cd "$WORK" && bash "$QAVERIFY" lowconf >/dev/null 2>&1 )
LC_VRC=$?
check "fixture sanity: qa-verify exits 0 for a genuine no-toolstream run (degrade, not override)" "$LC_VRC" "0"

LC_XML="$WORK/lowconf.xml"
( cd "$WORK" && bash "$JUNIT" lowconf "$LC_XML" >/dev/null 2>&1 )
LC_JRC=$?
# TASK 10 FLIP (spec §5.7). This run has no independent capture channel at
# all — no toolstream, no driver log — so the RUN is UNVERIFIED and the
# process must no longer exit 0. A green exit on a run that could not be
# verified is precisely the signal Task 10 removes; the per-criterion
# rendering asserted below is UNCHANGED (C2 is still a plain confidence:low
# pass with a <system-out> and no <failure> of its own).
check "junit: a degrade-only pass no longer buys exit 0 when the run has NO independent capture" \
  "$([[ "$LC_JRC" -ne 0 ]] && echo yes)" "yes"
LC_CONTENT="$(cat "$LC_XML")"
check_contains "junit: confidence:low pass carries a <system-out>" "$LC_CONTENT" '<system-out>confidence: low'
check_contains "junit: confidence:low system-out mentions the toolstream reason" "$LC_CONTENT" "toolstream"
check_contains "junit: confidence:low pass still names the criterion with the suffix" "$LC_CONTENT" 'C2 (confidence: low)'
check_not_contains "junit: the C2 testcase ITSELF still never gets a <failure> (per-criterion semantics unchanged)" \
  "$(awk '/<testcase name="C2/,/<\/testcase>/' "$LC_XML")" "<failure"
check "junit: exactly ONE <failure> in the document — the run-level one, not C2's" \
  "$(grep -c '<failure' "$LC_XML" | tr -d ' ')" "1"
check_contains "junit: that one failure is the run-level __run-verified__ case" "$LC_CONTENT" '__run-verified__'

# ===========================================================================
# PART 2 — back-compat: no verification.json at all -> unchanged rendering,
# and the assurance tier is honest that qa-verify was never run.
# ===========================================================================
# This part is about verification.json's ABSENCE, not about capture, so the
# fixture gets a real capture channel (a toolstream line, written by the
# actual toolstream.sh before the first checkpoint) — that keeps every
# back-compat assertion below literally unchanged under Task 10 instead of
# conflating "qa-verify never ran" with "the run had no independent capture".
( cd "$WORK" && bash "$TOOLSTREAM" append plainrun '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"p0"}}' >/dev/null )
( cd "$WORK" && bash "$CKPT" plainrun P1 pass --last-action "viewed the list" >/dev/null )
( cd "$WORK" && bash "$CKPT" plainrun P2 fail --last-action "saw a 500" >/dev/null )
PLAIN_XML="$WORK/plain.xml"
( cd "$WORK" && bash "$JUNIT" plainrun "$PLAIN_XML" >/dev/null 2>&1 )
PLAIN_RC=$?
check "back-compat: exit reflects only the original fail/error (P2), no verification.json involved" \
  "$([[ "$PLAIN_RC" -ne 0 ]] && echo yes)" "yes"
PLAIN_CONTENT="$(cat "$PLAIN_XML")"
check_contains "back-compat: a plain pass still renders as a self-closing testcase" "$PLAIN_CONTENT" '<testcase name="P1"'
check_not_contains "back-compat: no verification.json -> no OVERRIDE marker anywhere" "$PLAIN_CONTENT" "OVERRIDE"
check_contains "back-compat: assurance tier honestly states qa-verify was NOT run" "$PLAIN_CONTENT" "NOT RUN for this report"
check_contains "back-compat: qa.verified=false property present" "$PLAIN_CONTENT" 'name="qa.verified" value="false"'
check "back-compat: testsuite failures count is exactly 1 (P2 only — no override inflation)" \
  "$(grep -o 'failures="[0-9]*"' "$PLAIN_XML" | head -1)" 'failures="1"'

# ===========================================================================
# PART 3 — qa-ci.sh: the qa-verify step's exit code genuinely gates the
# FINAL exit, and QA_SKIP_VERIFY is explicit + LOGGED, never silent.
# Uses a stub agent (writes a real checkpoint via the actual checkpoint.sh,
# not hand-authored JSON) and a stub QA_VERIFY_CMD (pluggable by design,
# exactly like QA_AGENT_CMD/QA_PREFLIGHT_CMD) so no real browser/LLM is
# needed to exercise the orchestration.
# ===========================================================================
setup_ci_run() { # <scenario-dir>
  local dir="$1"
  cat > "$dir/agent-stub.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# A capture line FIRST, so checkpoint.sh's capture_probed canary records
# channel=toolstream: these cases are about the qa-verify/exit wiring, not
# about capture, and an uncaptured run is UNVERIFIED under Task 10.
bash "$TOOLSTREAM" append ciok '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"c0"}}' >/dev/null
bash "$CKPT" ciok K1 pass --last-action "viewed the list" >/dev/null
EOF
  chmod +x "$dir/agent-stub.sh"
}

# --- Case A: verify passes (rc 0) -> qa-ci exits 0. -------------------------
DIR_A="$WORK/ci-a"; mkdir -p "$DIR_A"; setup_ci_run "$DIR_A"
cat > "$DIR_A/verify-ok.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DIR_A/verify-ok.sh"
( cd "$DIR_A" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_VERIFY_CMD="$DIR_A/verify-ok.sh" QA_JUNIT_OUT="$DIR_A/out.xml" \
    bash "$QACI" "some target" >"$DIR_A/stdout.log" 2>&1 )
RC_A=$?
check "qa-ci Case A: clean verify -> qa-ci exits 0" "$RC_A" "0"

# --- Case B: verify OVERRIDES (rc 1) -> qa-ci MUST exit non-zero, even
# though the checkpoint itself is all-pass (report-to-junit alone would be
# 0) — proves the final gate is genuinely wired to qa-verify's own exit
# code, not merely inherited via junit re-reading verification.json. -------
DIR_B="$WORK/ci-b"; mkdir -p "$DIR_B"; setup_ci_run "$DIR_B"
cat > "$DIR_B/verify-fail.sh" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PWD/.qa/runs/$1"
echo '[]' > "$PWD/.qa/runs/$1/verification.json"
exit 1
EOF
chmod +x "$DIR_B/verify-fail.sh"
( cd "$DIR_B" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_VERIFY_CMD="$DIR_B/verify-fail.sh" QA_JUNIT_OUT="$DIR_B/out.xml" \
    bash "$QACI" "some target" >"$DIR_B/stdout.log" 2>&1 )
RC_B=$?
check "qa-ci Case B: qa-verify override -> qa-ci exits non-zero (even though junit alone would be clean)" \
  "$([[ "$RC_B" -ne 0 ]] && echo yes)" "yes"
check_contains "qa-ci Case B: the log names the override" "$(cat "$DIR_B/stdout.log")" "qa-verify overrode"

# --- Case C: QA_SKIP_VERIFY=1 -> the (failing) verify stub is NEVER
# invoked, the skip is LOGGED (not silent), and the final exit reflects
# junit alone (0, since the checkpoint is all-pass). ------------------------
DIR_C="$WORK/ci-c"; mkdir -p "$DIR_C"; setup_ci_run "$DIR_C"
MARKER_C="$DIR_C/verify-invoked-marker"
cat > "$DIR_C/verify-should-not-run.sh" <<EOF
#!/usr/bin/env bash
touch "$MARKER_C"
exit 1
EOF
chmod +x "$DIR_C/verify-should-not-run.sh"
( cd "$DIR_C" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_SKIP_VERIFY=1 QA_VERIFY_CMD="$DIR_C/verify-should-not-run.sh" QA_JUNIT_OUT="$DIR_C/out.xml" \
    bash "$QACI" "some target" >"$DIR_C/stdout.log" 2>&1 )
RC_C=$?
# TASK 10 FLIP (spec §5.7). QA_SKIP_VERIFY=1 used to be logged and then exit
# 0 on an all-pass checkpoint — an env var that silently switched the whole
# guarantee off. Skipping verification is still allowed; the run must now
# report itself UNVERIFIED and fail the build.
check "qa-ci Case C: QA_SKIP_VERIFY=1 no longer buys a green build (exit non-zero)" \
  "$([[ "$RC_C" -ne 0 ]] && echo yes)" "yes"
check "qa-ci Case C: the failing verify stub was STILL never invoked (skip means skip)" "$([[ -f "$MARKER_C" ]] && echo yes || echo no)" "no"
check_contains "qa-ci Case C: the skip is LOGGED, not silent" "$(cat "$DIR_C/stdout.log")" "qa-verify SKIPPED"
check_contains "qa-ci Case C: the log names the reason (QA_SKIP_VERIFY=1)" "$(cat "$DIR_C/stdout.log")" "QA_SKIP_VERIFY=1"
check_contains "qa-ci Case C: the log states the run is UNVERIFIED" "$(cat "$DIR_C/stdout.log")" "UNVERIFIED"
check_contains "qa-ci Case C: the exported JUnit carries the synthetic run-level failure case" \
  "$(cat "$DIR_C/out.xml")" '<testcase name="__run-verified__"'
check_contains "qa-ci Case C: the synthetic failure names the skip as the reason" \
  "$(cat "$DIR_C/out.xml")" 'verification skipped (QA_SKIP_VERIFY)'

# ===========================================================================
# PART 4 — qa-ci.sh locates the run via .qa/runs/latest (Appendix A: qa-ci.sh
# `ls -t` vs `.qa/runs/latest`), not an mtime scan, and still degrades
# gracefully via the mtime fallback when the pointer is stale/absent.
# ===========================================================================
DIR_D="$WORK/ci-d"; mkdir -p "$DIR_D/.qa/runs/older-run" "$DIR_D/.qa/runs/pointer-target"
cat > "$DIR_D/.qa/runs/older-run/checkpoint.json" <<'EOF'
{"runId":"older-run","criteria":[]}
EOF
cat > "$DIR_D/.qa/runs/pointer-target/checkpoint.json" <<'EOF'
{"runId":"pointer-target","criteria":[]}
EOF
# Both runs get the capture_probed canary (through journal.sh, the real
# journal writer) so this case stays about RUN RESOLUTION: without a capture
# channel the run is UNVERIFIED under Task 10 and qa-ci would exit non-zero
# for a reason that has nothing to do with the latest pointer.
( cd "$DIR_D" && bash "$JOURNAL" append older-run '{"event":"capture_probed","channel":"toolstream"}' >/dev/null )
( cd "$DIR_D" && bash "$JOURNAL" append pointer-target '{"event":"capture_probed","channel":"toolstream"}' >/dev/null )
printf 'pointer-target\n' > "$DIR_D/.qa/runs/latest"
# older-run is touched LAST so it is the mtime-newest directory — proves an
# mtime scan alone would pick the wrong run; the `latest` pointer must win.
sleep 1.1
touch "$DIR_D/.qa/runs/older-run/checkpoint.json"
cat > "$DIR_D/agent-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DIR_D/agent-stub.sh"
cat > "$DIR_D/verify-ok.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DIR_D/verify-ok.sh"
( cd "$DIR_D" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_VERIFY_CMD="$DIR_D/verify-ok.sh" QA_JUNIT_OUT="$DIR_D/out.xml" \
    bash "$QACI" "some target" >"$DIR_D/stdout.log" 2>&1 )
RC_D=$?
check "qa-ci Case D: latest-pointer run resolved even when mtime order disagrees" "$RC_D" "0"
check_contains "qa-ci Case D: the resolved run is the latest-pointer target, not the mtime-newest dir" \
  "$(cat "$DIR_D/stdout.log")" "run: pointer-target"

# --- Case E: .qa/runs/latest missing entirely -> fall back to mtime scan. ---
DIR_E="$WORK/ci-e"; mkdir -p "$DIR_E/.qa/runs/onlyrun"
cat > "$DIR_E/.qa/runs/onlyrun/checkpoint.json" <<'EOF'
{"runId":"onlyrun","criteria":[]}
EOF
( cd "$DIR_E" && bash "$JOURNAL" append onlyrun '{"event":"capture_probed","channel":"toolstream"}' >/dev/null )
cat > "$DIR_E/agent-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DIR_E/agent-stub.sh"
( cd "$DIR_E" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_VERIFY_CMD="$DIR_D/verify-ok.sh" QA_JUNIT_OUT="$DIR_E/out.xml" \
    bash "$QACI" "some target" >"$DIR_E/stdout.log" 2>&1 )
check_contains "qa-ci Case E: no latest pointer -> falls back to mtime scan and still finds the run" \
  "$(cat "$DIR_E/stdout.log")" "run: onlyrun"
check_contains "qa-ci Case E: fallback path is logged, not silent" \
  "$(cat "$DIR_E/stdout.log")" "falling back to mtime scan"

# ===========================================================================
# PART 5 — Task 10 / spec §5.7: run-level `UNVERIFIED` reaches the EXIT CODE.
#
# WHAT IS PINNED HERE (a contract, not a smoke test):
#   (A) A run that CANNOT be verified exits NON-ZERO. The literal word
#       `UNVERIFIED` has lived in `<properties>` since Plan H2 Task 5, and
#       `<properties>` is unreachable from `sys.exit(1 if (failures or
#       errors) else 0)` — so the assertion that matters is the PROCESS EXIT
#       CODE, never "the XML contains the word". Every case below asserts the
#       exit code first; an XML-only assertion would re-ship the exact bug.
#   (B) The signal is a SYNTHESIZED `<testcase name="__run-verified__">`
#       carrying a `<failure>`, counted in the testsuite's tests/failures.
#       The `__phase-surface__` property (qa-verify.sh) is the precedent for
#       a run-level row that deliberately never fails; this one must fail.
#   (C) The four UNVERIFIED triggers, and ONLY those four: channel `none`,
#       the canary absent entirely, `QA_SKIP_VERIFY=1`, and the two
#       record-damaging fold anomalies `unparseable-line` / `seq-gap`.
#       The other fold anomalies are surfaced as a COUNT ONLY — a
#       data-quality problem in one finding is not damage to the record.
#   (D) Reason strings verbatim: `no independent capture`,
#       `verification skipped (QA_SKIP_VERIFY)`,
#       `run record damaged (<anomaly>)`, all behind the prefix
#       `UNVERIFIED — `; the headline is `UNVERIFIED — <reason>` with the
#       tally printed beneath it.
#   (E) The malformed space never reads as clean: no journal, no
#       verification.json, no run-manifest.json, an empty checkpoint.json,
#       an unrecognized `channel` value, a malformed fold-anomalies.json,
#       and `QA_SKIP_VERIFY` set to something other than `1`.
#   (F) report-to-junit.sh is a python3 program with no jq path, but the
#       ARTEFACTS it reads are produced by the dual-engine fold — so the two
#       record-damage fixtures are driven through BOTH fold engines and the
#       report's stdout and stderr are compared SEPARATELY between them (a
#       merged 2>&1 comparison would pass a channel swap).
#
# RULE FOR WHOEVER EXTENDS THIS PART: adding a case to one engine's section
# is not coverage, and parity alone cannot see a divergence the fixtures
# never reach. Every rule gets a fixture that actually reaches it plus a
# NAMED assertion; prove the assertion is live by deleting the rule from a
# /tmp copy of the script and watching this suite go red.
# ===========================================================================

# canary_channel <run-dir> -> the `channel` of the first capture_probed
# journal event, or "" when the event (or the journal) is absent. python3
# rather than a grep/jq so it is independent of which engine serialized the
# line (jq emits `{"a":1}`, python3 `{"a": 1}`).
canary_channel() {
  python3 - "$1/journal.ndjson" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
if os.path.isfile(path):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if isinstance(obj, dict) and obj.get("event") == "capture_probed":
                print(obj.get("channel", ""))
                break
PYEOF
}

# anom_count <run-dir> <rule> -> how many fold anomalies carry that rule.
anom_count() {
  python3 - "$1/fold-anomalies.json" "$2" <<'PYEOF'
import json, os, sys
path, rule = sys.argv[1], sys.argv[2]
total = 0
if os.path.isfile(path):
    try:
        raw = json.load(open(path))
    except Exception:
        raw = None
    items = raw.get("anomalies") if isinstance(raw, dict) else raw
    if isinstance(items, list):
        total = sum(1 for i in items if isinstance(i, dict) and i.get("rule") == rule)
print(total)
PYEOF
}

# junit_run <cwd> <run-id> <artifact-prefix> — stdout and stderr captured
# SEPARATELY (<prefix>.stdout / <prefix>.stderr), XML to <prefix>.xml.
junit_run() {
  ( cd "$1" && bash "$JUNIT" "$2" "$3.xml" >"$3.stdout" 2>"$3.stderr" )
}
attr1() { grep -o "$2=\"[^\"]*\"" "$1" | head -1; }

# --- 5a: test_verified_run_exit_code_unchanged -----------------------------
# A real toolstream line before the first checkpoint -> the canary records
# channel=toolstream -> the run is verifiable and nothing is synthesized.
V5A="$WORK/p5a"; mkdir -p "$V5A"
( cd "$V5A" && bash "$TOOLSTREAM" append vok '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"v1"}}' >/dev/null )
( cd "$V5A" && bash "$CKPT" vok V1 pass --last-action "viewed the list" >/dev/null )
check "test_verified_run_exit_code_unchanged: fixture sanity — canary channel is toolstream" \
  "$(canary_channel "$V5A/.qa/runs/vok")" "toolstream"
junit_run "$V5A" vok "$V5A/rep"; RC5A=$?
check "test_verified_run_exit_code_unchanged: a captured, all-pass run still exits 0" "$RC5A" "0"
check_not_contains "test_verified_run_exit_code_unchanged: nothing is synthesized" \
  "$(cat "$V5A/rep.xml")" "__run-verified__"
check "test_verified_run_exit_code_unchanged: failures count untouched" \
  "$(attr1 "$V5A/rep.xml" failures)" 'failures="0"'
check "test_verified_run_exit_code_unchanged: tests count untouched (1 criterion)" \
  "$(attr1 "$V5A/rep.xml" tests)" 'tests="1"'
check_not_contains "test_verified_run_exit_code_unchanged: no UNVERIFIED headline on stderr" \
  "$(cat "$V5A/rep.stderr")" "UNVERIFIED — "

# --- 5b: test_channel_none_marks_unverified + test_unverified_produces_nonzero_exit
#         + test_unverified_synthesizes_junit_failure_case
#         + test_failure_message_names_the_reason
# No toolstream and no driver log -> checkpoint.sh's own canary records
# channel=none. `none` is not an error at the canary; it is the honest input
# to this status.
V5B="$WORK/p5b"; mkdir -p "$V5B"
( cd "$V5B" && bash "$CKPT" nocap N1 pass --last-action "viewed the list" >/dev/null )
check "test_channel_none_marks_unverified: fixture sanity — canary channel is none" \
  "$(canary_channel "$V5B/.qa/runs/nocap")" "none"
junit_run "$V5B" nocap "$V5B/rep"; RC5B=$?
check "test_unverified_produces_nonzero_exit: channel=none exits NON-ZERO" \
  "$([[ "$RC5B" -ne 0 ]] && echo yes)" "yes"
X5B="$(cat "$V5B/rep.xml")"
check_contains "test_unverified_synthesizes_junit_failure_case: the synthetic testcase is named __run-verified__" \
  "$X5B" '<testcase name="__run-verified__"'
check_contains "test_unverified_synthesizes_junit_failure_case: it carries a <failure> (not a property, not a <skipped>)" \
  "$X5B" '<failure message="UNVERIFIED — no independent capture"'
check_contains "test_failure_message_names_the_reason: the message names the capture reason" \
  "$X5B" "UNVERIFIED — no independent capture"
check "test_unverified_synthesizes_junit_failure_case: the synthetic case is COUNTED in failures" \
  "$(attr1 "$V5B/rep.xml" failures)" 'failures="1"'
check "test_unverified_synthesizes_junit_failure_case: and in tests (1 criterion + 1 synthetic)" \
  "$(attr1 "$V5B/rep.xml" tests)" 'tests="2"'
check "test_unverified_synthesizes_junit_failure_case: the synthetic case is classed to the run" \
  "$(grep -c 'name="__run-verified__" classname="nocap"' "$V5B/rep.xml" | tr -d ' ')" "1"
check "test_unverified_headline_is_first_with_the_tally_beneath: headline line" \
  "$(head -1 "$V5B/rep.stderr")" "UNVERIFIED — no independent capture"
check_contains "test_unverified_headline_is_first_with_the_tally_beneath: tally beneath it" \
  "$(sed -n '2p' "$V5B/rep.stderr")" "2 tests, 1 failures"
check "test_unverified_headline_goes_to_stderr_not_stdout: stdout stays empty when an out path was given" \
  "$(cat "$V5B/rep.stdout")" ""
check_contains "test_properties_unchanged: qa.verified is still rendered as before" \
  "$X5B" 'name="qa.verified" value="false"'
check_contains "test_properties_unchanged: qa.assuranceTier is still rendered as before" \
  "$X5B" 'name="qa.assuranceTier"'
check_contains "test_unverified_reason_is_also_surfaced_as_a_property" \
  "$X5B" 'name="qa.unverifiedReason" value="UNVERIFIED — no independent capture"'
check "test_missing_run_manifest_is_a_noop: no qa.cost property is fabricated" \
  "$(grep -c 'qa.cost' "$V5B/rep.xml" | tr -d ' ')" "0"

# --- 5b2: the headline + tally also appear when the XML goes to STDOUT ------
( cd "$V5B" && bash "$JUNIT" nocap >"$V5B/so.stdout" 2>"$V5B/so.stderr" ); RC5B2=$?
check "test_unverified_stdout_mode_exit: XML-to-stdout mode also exits non-zero" \
  "$([[ "$RC5B2" -ne 0 ]] && echo yes)" "yes"
check_contains "test_unverified_stdout_mode: the XML itself still goes to stdout" \
  "$(cat "$V5B/so.stdout")" '<testcase name="__run-verified__"'
check "test_unverified_stdout_mode: the headline goes to STDERR, never into the XML stream" \
  "$(head -1 "$V5B/so.stderr")" "UNVERIFIED — no independent capture"
check_contains "test_unverified_stdout_mode: the tally is printed beneath the headline on stderr too" \
  "$(cat "$V5B/so.stderr")" "2 tests, 1 failures"

# --- 5c: the canary ABSENT ENTIRELY is treated identically to `none` --------
# An aborted run (journal, no verdicts, no canary) must not read as clean.
# Built through journal.sh + fold.sh — the real writers.
V5C="$WORK/p5c"; mkdir -p "$V5C"
( cd "$V5C" && bash "$JOURNAL" append aborted '{"event":"run_started","runId":"aborted"}' >/dev/null )
( cd "$V5C" && bash "$JOURNAL" append aborted '{"event":"phase_entered","phase":"Verify"}' >/dev/null )
( cd "$V5C" && bash "$FOLD" aborted >/dev/null 2>&1 )
check "test_capture_probed_absent_marks_unverified: fixture sanity — no canary in the journal" \
  "$(canary_channel "$V5C/.qa/runs/aborted")" ""
junit_run "$V5C" aborted "$V5C/rep"; RC5C=$?
check "test_capture_probed_absent_marks_unverified: an aborted run exits NON-ZERO" \
  "$([[ "$RC5C" -ne 0 ]] && echo yes)" "yes"
check_contains "test_capture_probed_absent_marks_unverified: same reason as channel=none" \
  "$(cat "$V5C/rep.xml")" "UNVERIFIED — no independent capture"
check "test_capture_probed_absent_marks_unverified: a zero-criterion run still reports 1 failure" \
  "$(attr1 "$V5C/rep.xml" failures)" 'failures="1"'

# --- 5d: no journal at all (the degenerate fixture) ------------------------
V5D="$WORK/p5d"; mkdir -p "$V5D/.qa/runs/nojournal"
printf '{"run_id":"nojournal","criteria":[]}' > "$V5D/.qa/runs/nojournal/checkpoint.json"
junit_run "$V5D" nojournal "$V5D/rep"; RC5D=$?
check "test_missing_journal_marks_unverified: no journal.ndjson at all exits NON-ZERO" \
  "$([[ "$RC5D" -ne 0 ]] && echo yes)" "yes"
check_contains "test_missing_journal_marks_unverified: reason is no independent capture" \
  "$(cat "$V5D/rep.xml")" "UNVERIFIED — no independent capture"

# --- 5e: an UNRECOGNIZED channel value fails CLOSED -----------------------
# The canary is appended FIRST so checkpoint.sh's once-guard leaves it alone
# (a real writer path, not a hand-edited journal).
V5E="$WORK/p5e"; mkdir -p "$V5E"
( cd "$V5E" && bash "$JOURNAL" append oddchan '{"event":"run_started","runId":"oddchan"}' >/dev/null )
( cd "$V5E" && bash "$JOURNAL" append oddchan '{"event":"capture_probed","channel":"carrier-pigeon"}' >/dev/null )
( cd "$V5E" && bash "$CKPT" oddchan E1 pass --last-action "viewed the list" >/dev/null )
check "test_unexpected_channel_value_marks_unverified: fixture sanity — the odd channel survived the once-guard" \
  "$(canary_channel "$V5E/.qa/runs/oddchan")" "carrier-pigeon"
junit_run "$V5E" oddchan "$V5E/rep"; RC5E=$?
check "test_unexpected_channel_value_marks_unverified: an unrecognized channel exits NON-ZERO (fails closed)" \
  "$([[ "$RC5E" -ne 0 ]] && echo yes)" "yes"
check_contains "test_unexpected_channel_value_marks_unverified: reason is no independent capture" \
  "$(cat "$V5E/rep.xml")" "UNVERIFIED — no independent capture"

# --- 5f/5g: the two RECORD-DAMAGING fold anomalies, through BOTH engines ---
# write_damaged_journal <dir> <run-id> <unparseable|seqgap>
# Written directly because journal.sh restamps `seq` contiguously by design
# and so cannot produce a gap, and validates envelopes so it cannot append a
# torn line — both damaged shapes only ever arrive from a crashed writer.
write_damaged_journal() {
  local dir="$1" run_id="$2" kind="$3"
  mkdir -p "$dir/.qa/runs/$run_id"
  {
    printf '%s\n' '{"seq":1,"t":"2026-09-23T00:00:01Z","event":"run_started","runId":"'"$run_id"'"}'
    printf '%s\n' '{"seq":2,"t":"2026-09-23T00:00:02Z","event":"capture_probed","channel":"toolstream"}'
    if [[ "$kind" == "seqgap" ]]; then
      # seq 3 is MISSING — the shape a dropped torn line leaves behind.
      printf '%s\n' '{"seq":4,"t":"2026-09-23T00:00:04Z","event":"criterion_started","scenarioId":"__shared__","criterionId":"D1","personaId":""}'
      printf '%s\n' '{"seq":5,"t":"2026-09-23T00:00:05Z","event":"criterion_verdict","scenarioId":"__shared__","criterionId":"D1","personaId":"","verdict":"pass","confidence":"high","layer":null,"evidenceRefs":[],"kinds":[],"bugRef":null,"lastAction":"viewed the list","nonUiActionReason":null}'
    else
      printf '%s\n' '{"seq":3,"t":"2026-09-23T00:00:03Z","event":"criterion_started","scenarioId":"__shared__","criterionId":"D1","personaId":""}'
      printf '%s\n' '{"seq":4,"t":"2026-09-23T00:00:04Z","event":"criterion_verdict","scenarioId":"__shared__","criterionId":"D1","personaId":"","verdict":"pass","confidence":"high","layer":null,"evidenceRefs":[],"kinds":[],"bugRef":null,"lastAction":"viewed the list","nonUiActionReason":null}'
      # A torn final line: valid JSON prefix, no closing brace.
      printf '%s\n' '{"seq":5,"t":"2026-09-23T00:00:05Z","event":"criterion_ver'
    fi
  } > "$dir/.qa/runs/$run_id/journal.ndjson"
}

for FOLD_ENGINE in jq python3; do
  if [[ "$FOLD_ENGINE" == "python3" ]] && ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP - record-damage cases [python3]: python3 not on this host"; continue
  fi
  if [[ "$FOLD_ENGINE" == "jq" ]] && ! command -v jq >/dev/null 2>&1; then
    echo "SKIP - record-damage cases [jq]: jq not on this host"; continue
  fi

  # --- unparseable-line -> UNVERIFIED ---
  DU="$WORK/p5f-$FOLD_ENGINE"; mkdir -p "$DU"
  write_damaged_journal "$DU" torn unparseable
  ( cd "$DU" && QA_ENGINE="$FOLD_ENGINE" bash "$FOLD" torn >/dev/null 2>&1 )
  check "test_unparseable_line_marks_unverified[$FOLD_ENGINE]: fixture sanity — the fold recorded unparseable-line" \
    "$(anom_count "$DU/.qa/runs/torn" unparseable-line)" "1"
  check "test_unparseable_line_marks_unverified[$FOLD_ENGINE]: fixture sanity — and NO seq-gap (the reason must be unambiguous)" \
    "$(anom_count "$DU/.qa/runs/torn" seq-gap)" "0"
  check "test_unparseable_line_marks_unverified[$FOLD_ENGINE]: fixture sanity — capture channel is intact" \
    "$(canary_channel "$DU/.qa/runs/torn")" "toolstream"
  junit_run "$DU" torn "$DU/rep"; RC_DU=$?
  check "test_unparseable_line_marks_unverified[$FOLD_ENGINE]: exits NON-ZERO" \
    "$([[ "$RC_DU" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_unparseable_line_marks_unverified[$FOLD_ENGINE]: reason names the anomaly" \
    "$(cat "$DU/rep.xml")" "UNVERIFIED — run record damaged (unparseable-line)"
  check_contains "test_unparseable_line_marks_unverified[$FOLD_ENGINE]: headline on stderr" \
    "$(head -1 "$DU/rep.stderr")" "UNVERIFIED — run record damaged (unparseable-line)"

  # --- seq-gap -> UNVERIFIED ---
  DG="$WORK/p5g-$FOLD_ENGINE"; mkdir -p "$DG"
  write_damaged_journal "$DG" gapped seqgap
  ( cd "$DG" && QA_ENGINE="$FOLD_ENGINE" bash "$FOLD" gapped >/dev/null 2>&1 )
  check "test_seq_gap_marks_unverified[$FOLD_ENGINE]: fixture sanity — the fold recorded seq-gap" \
    "$(anom_count "$DG/.qa/runs/gapped" seq-gap)" "1"
  check "test_seq_gap_marks_unverified[$FOLD_ENGINE]: fixture sanity — and NO unparseable-line" \
    "$(anom_count "$DG/.qa/runs/gapped" unparseable-line)" "0"
  junit_run "$DG" gapped "$DG/rep"; RC_DG=$?
  check "test_seq_gap_marks_unverified[$FOLD_ENGINE]: exits NON-ZERO" \
    "$([[ "$RC_DG" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_seq_gap_marks_unverified[$FOLD_ENGINE]: reason names the anomaly" \
    "$(cat "$DG/rep.xml")" "UNVERIFIED — run record damaged (seq-gap)"

  # --- illegal-edge (and its friends) -> COUNT ONLY, never UNVERIFIED ---
  # A mutates:true criterion that jumps straight from criterion_started to a
  # verdict, skipping the act sub-states: fold.jq/fold.py's state-machine
  # guard fires. The record itself is INTACT, so the run stays verifiable.
  DI="$WORK/p5h-$FOLD_ENGINE"; mkdir -p "$DI"
  ( cd "$DI" && bash "$JOURNAL" append edged '{"event":"run_started","runId":"edged"}' >/dev/null )
  ( cd "$DI" && bash "$JOURNAL" append edged '{"event":"capture_probed","channel":"toolstream"}' >/dev/null )
  ( cd "$DI" && bash "$JOURNAL" append edged '{"event":"phase_entered","phase":"Verify"}' >/dev/null )
  ( cd "$DI" && bash "$JOURNAL" append edged '{"event":"plan_frozen","criteria":[{"criterionId":"C-MUT-SKIP","scenarioId":"s1","personaId":"p1","mutates":true}],"order":["C-MUT-SKIP"]}' >/dev/null )
  ( cd "$DI" && bash "$JOURNAL" append edged '{"event":"criterion_started","scenarioId":"s1","criterionId":"C-MUT-SKIP","personaId":"p1"}' >/dev/null )
  ( cd "$DI" && bash "$JOURNAL" append edged '{"event":"criterion_verdict","scenarioId":"s1","criterionId":"C-MUT-SKIP","personaId":"p1","verdict":"pass","confidence":"high","layer":null,"evidenceRefs":[],"kinds":[],"bugRef":null,"lastAction":"claimed done","nonUiActionReason":null}' >/dev/null )
  ( cd "$DI" && QA_ENGINE="$FOLD_ENGINE" bash "$FOLD" edged >/dev/null 2>&1 )
  check "test_illegal_edge_does_not_mark_unverified[$FOLD_ENGINE]: fixture sanity — the fold recorded illegal-edge" \
    "$(anom_count "$DI/.qa/runs/edged" illegal-edge)" "1"
  junit_run "$DI" edged "$DI/rep"; RC_DI=$?
  check "test_illegal_edge_does_not_mark_unverified[$FOLD_ENGINE]: exits 0 — counted, never unverified" "$RC_DI" "0"
  check_not_contains "test_illegal_edge_does_not_mark_unverified[$FOLD_ENGINE]: nothing is synthesized" \
    "$(cat "$DI/rep.xml")" "__run-verified__"
  check_contains "test_illegal_edge_is_surfaced_as_a_count[$FOLD_ENGINE]: the anomaly count property names it" \
    "$(cat "$DI/rep.xml")" 'name="qa.foldAnomalies"'
  check_contains "test_illegal_edge_is_surfaced_as_a_count[$FOLD_ENGINE]: with its rule and count" \
    "$(cat "$DI/rep.xml")" 'illegal-edge=1'
done

# --- 5i: engine PARITY over the damaged fixtures, stdout vs stderr separately
# norm <file> <engine-dir> — strips the two things that legitimately differ
# between the two fixture copies (the per-engine artifact path that appears
# in the `wrote <path>:` tally line, and the wall-clock timestamp a run
# built through journal.sh stamps) so what remains is ENGINE output.
norm() { sed -e "s#$2#<DIR>#g" -e 's#timestamp="[^"]*"#timestamp="<T>"#g' "$1"; }
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for PAIR in p5f p5g p5h; do
    for STREAM in xml stderr stdout; do
      check "test_engines_agree[$PAIR/$STREAM]: identical across fold engines (streams compared SEPARATELY)" \
        "$(diff <(norm "$WORK/$PAIR-jq/rep.$STREAM" "$WORK/$PAIR-jq") \
                <(norm "$WORK/$PAIR-python3/rep.$STREAM" "$WORK/$PAIR-python3") >/dev/null && echo same)" "same"
    done
  done
else
  echo "SKIP - test_engines_agree: both jq and python3 are needed for the parity comparison"
fi

# --- 5j: a MALFORMED fold-anomalies.json never invents damage, and never
# crashes the export (same posture as the other optional siblings). --------
V5J="$WORK/p5j"; mkdir -p "$V5J"
( cd "$V5J" && bash "$TOOLSTREAM" append junkanom '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"j1"}}' >/dev/null )
( cd "$V5J" && bash "$CKPT" junkanom J1 pass --last-action "viewed the list" >/dev/null )
printf 'not json at all {{{' > "$V5J/.qa/runs/junkanom/fold-anomalies.json"
junit_run "$V5J" junkanom "$V5J/rep"; RC5J=$?
check "test_malformed_fold_anomalies_is_not_fatal: the export still succeeds and exits 0" "$RC5J" "0"
check_not_contains "test_malformed_fold_anomalies_is_not_fatal: no damage is invented from unreadable JSON" \
  "$(cat "$V5J/rep.xml")" "__run-verified__"
check_not_contains "test_malformed_fold_anomalies_is_not_fatal: no anomaly-count property is fabricated" \
  "$(cat "$V5J/rep.xml")" 'qa.foldAnomalies'

# --- 5k: QA_SKIP_VERIFY at the report level -------------------------------
# report-to-junit.sh reads the SAME env var qa-ci.sh branches on, so the
# status survives even a hand-rolled CI that calls the exporter directly.
V5K="$WORK/p5k"; mkdir -p "$V5K"
( cd "$V5K" && bash "$TOOLSTREAM" append skipped '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"s1"}}' >/dev/null )
( cd "$V5K" && bash "$CKPT" skipped S1 pass --last-action "viewed the list" >/dev/null )
( cd "$V5K" && QA_SKIP_VERIFY=1 bash "$JUNIT" skipped "$V5K/rep.xml" >"$V5K/rep.stdout" 2>"$V5K/rep.stderr" ); RC5K=$?
check "test_qa_skip_verify_marks_unverified: a fully captured all-pass run still exits NON-ZERO under QA_SKIP_VERIFY=1" \
  "$([[ "$RC5K" -ne 0 ]] && echo yes)" "yes"
check_contains "test_qa_skip_verify_marks_unverified: reason is the skip, verbatim" \
  "$(cat "$V5K/rep.xml")" 'UNVERIFIED — verification skipped (QA_SKIP_VERIFY)'
check_contains "test_qa_skip_verify_marks_unverified: it is a <failure>, not a property" \
  "$(cat "$V5K/rep.xml")" '<failure message="UNVERIFIED — verification skipped (QA_SKIP_VERIFY)"'

for ODD in 0 true yes "" "1 "; do
  ( cd "$V5K" && QA_SKIP_VERIFY="$ODD" bash "$JUNIT" skipped "$V5K/odd.xml" >/dev/null 2>&1 ); RC_ODD=$?
  check "test_qa_skip_verify_only_the_literal_1_counts[QA_SKIP_VERIFY='$ODD']: exits 0, same as qa-ci.sh's own branch" \
    "$RC_ODD" "0"
done

# --- 5l: several reasons at once are ALL named ----------------------------
V5L="$WORK/p5l"; mkdir -p "$V5L"
( cd "$V5L" && bash "$CKPT" manyreasons M1 pass --last-action "viewed the list" >/dev/null )
( cd "$V5L" && QA_SKIP_VERIFY=1 bash "$JUNIT" manyreasons "$V5L/rep.xml" >/dev/null 2>"$V5L/rep.stderr" ); RC5L=$?
check "test_multiple_reasons_all_named: exits NON-ZERO" "$([[ "$RC5L" -ne 0 ]] && echo yes)" "yes"
check_contains "test_multiple_reasons_all_named: the capture reason is named" \
  "$(cat "$V5L/rep.xml")" "no independent capture"
check_contains "test_multiple_reasons_all_named: the skip reason is named too" \
  "$(cat "$V5L/rep.xml")" "verification skipped (QA_SKIP_VERIFY)"
check "test_multiple_reasons_all_named: still exactly ONE synthetic case" \
  "$(grep -c '__run-verified__' "$V5L/rep.xml" | tr -d ' ')" "1"

# --- 5m: an EMPTY checkpoint.json never reads as clean -------------------
V5M="$WORK/p5m"; mkdir -p "$V5M/.qa/runs/emptyckpt"
: > "$V5M/.qa/runs/emptyckpt/checkpoint.json"
( cd "$V5M" && bash "$JUNIT" emptyckpt "$V5M/rep.xml" >/dev/null 2>&1 ); RC5M=$?
check "test_empty_checkpoint_never_exits_zero: an unreadable checkpoint fails the export" \
  "$([[ "$RC5M" -ne 0 ]] && echo yes)" "yes"

# --- 5n: a null `run_id` (a real fold output when the journal never carried
# run_started — i.e. exactly an aborted run, which is an UNVERIFIED run) must
# still produce the synthetic failure case instead of a python traceback: a
# crash writes no XML at all, so the reason would never reach the report.
V5N="$WORK/p5n"; mkdir -p "$V5N"
( cd "$V5N" && bash "$JOURNAL" append nullrun '{"event":"phase_entered","phase":"Verify"}' >/dev/null )
( cd "$V5N" && bash "$FOLD" nullrun >/dev/null 2>&1 )
check "test_null_run_id_still_renders: fixture sanity — the fold left run_id null" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run_id"))' "$V5N/.qa/runs/nullrun/checkpoint.json")" "None"
junit_run "$V5N" nullrun "$V5N/rep"; RC5N=$?
check "test_null_run_id_still_renders: exits NON-ZERO" "$([[ "$RC5N" -ne 0 ]] && echo yes)" "yes"
check_contains "test_null_run_id_still_renders: the XML was written and carries the synthetic case" \
  "$(cat "$V5N/rep.xml")" '<testcase name="__run-verified__"'
check_not_contains "test_null_run_id_still_renders: no python traceback on stderr" \
  "$(cat "$V5N/rep.stderr")" "Traceback"

# ===========================================================================
# PART 6 — qa-ci.sh: QA_SKIP_VERIFY=1 is an UNVERIFIED run end to end, and
# only the literal `1` takes that branch.
# ===========================================================================
DIR_F="$WORK/ci-f"; mkdir -p "$DIR_F"; setup_ci_run "$DIR_F"
cat > "$DIR_F/verify-ok.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$DIR_F/verify-ok.sh"
( cd "$DIR_F" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_SKIP_VERIFY=1 QA_VERIFY_CMD="$DIR_F/verify-ok.sh" QA_JUNIT_OUT="$DIR_F/out.xml" \
    bash "$QACI" "some target" >"$DIR_F/stdout.log" 2>&1 )
RC_F=$?
check "qa-ci Case F: QA_SKIP_VERIFY=1 on a fully CAPTURED all-pass run still exits non-zero" \
  "$([[ "$RC_F" -ne 0 ]] && echo yes)" "yes"
# The phrase below is printed ONLY by qa-ci.sh's own final gate, never by
# report-to-junit.sh's headline (which says `UNVERIFIED — verification
# skipped (QA_SKIP_VERIFY)`). The status is deliberately guarded twice — the
# exporter reads the env var for a hand-rolled CI, this gate covers a
# replaced/unreached JUnit export — and a redundant guard still needs its own
# assertion, or one of the two can be deleted with the suite staying green.
check_contains "qa-ci Case F: qa-ci.sh's OWN final gate fires and names the skip" \
  "$(cat "$DIR_F/stdout.log")" "is UNVERIFIED -- verification skipped (QA_SKIP_VERIFY); a skipped verification never yields a green build"
check_contains "qa-ci Case F: the exporter's headline names it too" \
  "$(cat "$DIR_F/stdout.log")" "UNVERIFIED — verification skipped (QA_SKIP_VERIFY)"
check_contains "qa-ci Case F: the exported JUnit carries the synthetic failure case" \
  "$(cat "$DIR_F/out.xml")" '<testcase name="__run-verified__"'
check "qa-ci Case F: the capture channel was genuinely present (so the ONLY reason is the skip)" \
  "$(canary_channel "$DIR_F/.qa/runs/ciok")" "toolstream"
check_not_contains "qa-ci Case F: the capture reason is NOT claimed" \
  "$(cat "$DIR_F/out.xml")" "no independent capture"

# --- Case G: QA_SKIP_VERIFY set to something other than `1` behaves exactly
# as before — the verify step RUNS and a clean run exits 0. ----------------
DIR_G="$WORK/ci-g"; mkdir -p "$DIR_G"; setup_ci_run "$DIR_G"
MARKER_G="$DIR_G/verify-invoked-marker"
cat > "$DIR_G/verify-ok.sh" <<EOF
#!/usr/bin/env bash
touch "$MARKER_G"
exit 0
EOF
chmod +x "$DIR_G/verify-ok.sh"
( cd "$DIR_G" && QA_SKIP_PREFLIGHT=1 QA_AGENT_CMD="bash ./agent-stub.sh" \
    QA_SKIP_VERIFY=true QA_VERIFY_CMD="$DIR_G/verify-ok.sh" QA_JUNIT_OUT="$DIR_G/out.xml" \
    bash "$QACI" "some target" >"$DIR_G/stdout.log" 2>&1 )
RC_G=$?
check "qa-ci Case G: QA_SKIP_VERIFY=true (not 1) -> verification is NOT skipped, exit 0" "$RC_G" "0"
check "qa-ci Case G: the verify command genuinely ran" "$([[ -f "$MARKER_G" ]] && echo yes || echo no)" "yes"
check_not_contains "qa-ci Case G: nothing is reported as skipped" \
  "$(cat "$DIR_G/stdout.log")" "qa-verify SKIPPED"
check_not_contains "qa-ci Case G: no synthetic failure case in the export" \
  "$(cat "$DIR_G/out.xml")" "__run-verified__"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
