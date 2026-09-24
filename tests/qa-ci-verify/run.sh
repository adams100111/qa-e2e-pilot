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
#   PART 8 — Fix round 2: the `driver-log` arm of the capture check (which
#     had no test), and `runChecks.findingsChannel == "none"` as a SECOND
#     witness that holds even when the canary claims a channel that is not
#     there; plus a corrupt (not absent) fold-anomalies.json as UNVERIFIED.
#   PART 7 — Fix round 1: the Lane K `__run-checks__` record reaches the
#     REPORT (it already reached the exit code), naming WHICH run-scoped
#     check failed, counted once, never masking (or masked by) UNVERIFIED.
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
# Two RUN-LEVEL failures, and neither belongs to C2. The second arrived with
# Lane K's three-state `loadWindowCovered`: this run has no toolstream, so
# there was no ordered tool sequence to evaluate the load window against, and
# the check records `not-evaluated` rather than `true`. A check that silently
# does not run must not read as a check that passed — so it is named, not
# assumed. C2's own rendering is untouched either way.
check "junit: exactly TWO <failure>s, both run-level (UNVERIFIED + the un-evaluated load-window check)" \
  "$(grep -c '<failure' "$LC_XML" | tr -d ' ')" "2"
check_contains "junit: one is the run-level __run-verified__ case" "$LC_CONTENT" '<testcase name="__run-verified__"'
check_contains "junit: the other names the un-evaluated check, never a passed one" \
  "$LC_CONTENT" '<failure message="run checks failed: loadWindowCovered"'
check "junit: and C2 itself still carries no <failure> of its own" \
  "$(awk '/<testcase name="C2/,/<\/testcase>/' "$LC_XML" | grep -c '<failure' | tr -d ' ')" "0"

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

# rc_runchecks_field <run-dir> <field> -> that runChecks field as text, or
# "absent". python3 rather than grep: verification.json is written through
# `jq -s '.'` on one engine and json.dumps on the other, so its whitespace
# is not stable enough to match on.
rc_runchecks_field() {
  python3 - "$1/verification.json" "$2" <<'RCFEOF'
import json, os, sys
path, field = sys.argv[1], sys.argv[2]
out = "absent"
if os.path.isfile(path):
    try:
        recs = json.load(open(path))
    except Exception:
        recs = []
    for r in recs if isinstance(recs, list) else []:
        if isinstance(r, dict) and r.get("criterionId") == "__run-checks__":
            checks = r.get("runChecks")
            if isinstance(checks, dict) and field in checks:
                out = str(checks[field])
            break
print(out)
RCFEOF
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

# --- 5j: a CORRUPT fold-anomalies.json is UNVERIFIED; an ABSENT one is
# benign. The two differ because fold-anomalies.json is DERIVED and
# atomically written beside checkpoint.json: its absence is a normal older
# run that predates the fold writing it, while a present-but-unreadable file
# means we CANNOT KNOW whether the run's record is damaged — which is the
# definition of unverified. Treating it as `{}` (the earlier behaviour this
# case pinned) made it the only gate input in this feature that reads as
# benign when unreadable, the opposite of the adjudicated init-config.sh
# ruling (refuse rather than overwrite what you could not read) and of the
# `is not True` posture on runChecks two sections below.
V5J="$WORK/p5j"; mkdir -p "$V5J"
( cd "$V5J" && bash "$TOOLSTREAM" append junkanom '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"j1"}}' >/dev/null )
( cd "$V5J" && bash "$CKPT" junkanom J1 pass --last-action "viewed the list" >/dev/null )
printf 'not json at all {{{' > "$V5J/.qa/runs/junkanom/fold-anomalies.json"
junit_run "$V5J" junkanom "$V5J/rep"; RC5J=$?
check "test_corrupt_fold_anomalies_marks_unverified_while_absent_stays_benign: a present-but-unreadable file exits NON-ZERO" \
  "$([[ "$RC5J" -ne 0 ]] && echo yes)" "yes"
check_contains "test_corrupt_fold_anomalies_marks_unverified_while_absent_stays_benign: reason names the unreadable file, not an invented rule" \
  "$(cat "$V5J/rep.xml")" 'UNVERIFIED — run record damaged (unreadable anomalies)'
check_not_contains "test_corrupt_fold_anomalies_marks_unverified_while_absent_stays_benign: no rule name is fabricated" \
  "$(cat "$V5J/rep.xml")" 'unparseable-line'
check_not_contains "test_corrupt_fold_anomalies_marks_unverified_while_absent_stays_benign: no anomaly-COUNT property is fabricated either" \
  "$(cat "$V5J/rep.xml")" 'qa.foldAnomalies'
check "test_corrupt_fold_anomalies_marks_unverified_while_absent_stays_benign: the export still succeeds (a corrupt sibling never crashes it)" \
  "$([[ -s "$V5J/rep.xml" ]] && echo yes)" "yes"

# Valid JSON of the WRONG SHAPE is the same class: present, and unusable.
for BADSHAPE in '{"anomalies":"boom"}' '5' '{"openActs":[]}' '"[]"'; do
  BSD="$WORK/p5j-shape"; rm -rf "$BSD"; mkdir -p "$BSD"
  ( cd "$BSD" && bash "$TOOLSTREAM" append shapeanom '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"s1"}}' >/dev/null )
  ( cd "$BSD" && bash "$CKPT" shapeanom S1 pass --last-action "viewed the list" >/dev/null )
  printf '%s' "$BADSHAPE" > "$BSD/.qa/runs/shapeanom/fold-anomalies.json"
  junit_run "$BSD" shapeanom "$BSD/rep"; RC_BS=$?
  check "test_wrong_shape_fold_anomalies_marks_unverified[$BADSHAPE]: exits NON-ZERO" \
    "$([[ "$RC_BS" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_wrong_shape_fold_anomalies_marks_unverified[$BADSHAPE]: reason names the unreadable file" \
    "$(cat "$BSD/rep.xml")" 'run record damaged (unreadable anomalies)'
done

# A well-formed, EMPTY anomaly set is a clean run — the common case, and the
# proof this guard reads the file rather than merely noticing it exists.
V5J2="$WORK/p5j-empty"; mkdir -p "$V5J2"
( cd "$V5J2" && bash "$TOOLSTREAM" append emptyanom '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"e1"}}' >/dev/null )
( cd "$V5J2" && bash "$CKPT" emptyanom E1 pass --last-action "viewed the list" >/dev/null )
printf '%s' '{"anomalies":[],"openActs":[]}' > "$V5J2/.qa/runs/emptyanom/fold-anomalies.json"
junit_run "$V5J2" emptyanom "$V5J2/rep"; RC5J2=$?
check "test_empty_fold_anomalies_is_clean: an empty anomaly set exits 0" "$RC5J2" "0"
check_not_contains "test_empty_fold_anomalies_is_clean: nothing is synthesized" \
  "$(cat "$V5J2/rep.xml")" "__run-verified__"

# ABSENT stays benign: an older run whose fold never wrote the file must not
# be retro-failed. checkpoint.sh folds on every upsert, so the absence has
# to be built deliberately — a captured run whose journal carries the canary
# and whose run dir has no fold-anomalies.json at all.
V5J3="$WORK/p5j-absent"; mkdir -p "$V5J3/.qa/runs/noanom"
printf '{"run_id":"noanom","criteria":[{"criterion_id":"A1","verdict":"pass","confidence":"high"}]}' \
  > "$V5J3/.qa/runs/noanom/checkpoint.json"
( cd "$V5J3" && bash "$JOURNAL" append noanom '{"event":"capture_probed","channel":"toolstream"}' >/dev/null )
check "test_absent_fold_anomalies_stays_benign: fixture sanity — the run dir has no fold-anomalies.json" \
  "$([[ -e "$V5J3/.qa/runs/noanom/fold-anomalies.json" ]] && echo present || echo absent)" "absent"
junit_run "$V5J3" noanom "$V5J3/rep"; RC5J3=$?
check "test_absent_fold_anomalies_stays_benign: an absent file exits 0 — absence is an older run, corruption is not" "$RC5J3" "0"
check_not_contains "test_absent_fold_anomalies_stays_benign: nothing is synthesized" \
  "$(cat "$V5J3/rep.xml")" "__run-verified__"

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
check "test_multiple_reasons_all_named: still exactly ONE synthetic testcase element" \
  "$(grep -c '<testcase name="__run-verified__"' "$V5L/rep.xml" | tr -d ' ')" "1"

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

# ===========================================================================
# PART 7 — Fix round 1 (Lane K hand-off): the synthetic `__run-checks__`
# record reaches the REPORT, not just the exit code.
#
# Lane K's Task 8 writes one run-level `__run-checks__` record into
# verification.json carrying
#   runChecks: {ledgerComplete, classificationsAgree, loadWindowCovered,
#               knownDefectsOk}
# and — unlike `__phase-surface__` — it DOES flip qa-verify's exit code, so
# qa-ci.sh's VERIFY_RC path already fails the build. Enforcement was never
# the gap. The gap was diagnostic: report-to-junit.sh renders testcases for
# checkpoint criteria only (plus the `__phase-surface__` property), so a CI
# user got a red build with nothing in the report naming WHICH run-check
# failed — and a build that fails without saying why is the kind of thing
# people route around, which is the very failure this feature exists to stop.
#
# WHAT IS PINNED HERE:
#   (A) A non-pass `__run-checks__` record synthesizes a
#       `<testcase name="__run-checks__">` carrying a `<failure>` whose
#       message NAMES the failed checks: `run checks failed: ledgerComplete,
#       loadWindowCovered`. Counted in tests/failures, so it reaches
#       `sys.exit` — asserted as an EXIT CODE, never as XML text alone.
#   (B) It fails ONCE. `verify_overrides` is computed over checkpoint
#       criteria only, and `__run-checks__` is not one, so there is no
#       double count: a run whose ONLY problem is a failed run-check reports
#       exactly `failures="1"` and exactly one `__run-checks__` testcase.
#   (C) It never masks, and is never masked by, an UNVERIFIED
#       `__run-verified__` failure. Both are legitimately present together
#       (a run with no capture channel whose journal also misclassifies a
#       finding), and then BOTH appear and `failures` counts both.
#   (D) An all-pass record synthesizes NO testcase and leaves the exit code
#       alone; the positive result is surfaced as a `qa.runChecks` property,
#       so "the gate ran and passed" is still visible.
#   (E) Fail CLOSED on a malformed record: qa-verify's own
#       `build_error_record("__run-checks__", …)` path writes a record with
#       `verifierVerdict: "error"` and NO `runChecks` key at all (the four
#       checks did not complete). A lost gate must never render as a clean
#       run, so that shape still produces the failure case.
#   (F) Every fixture is produced by the REAL qa-verify.sh under BOTH of its
#       engines (QA_ENGINE=jq and QA_ENGINE=python3, each in its own tree),
#       and the report's xml/stdout/stderr are compared SEPARATELY between
#       them. report-to-junit.sh itself is python3-only; the dual-engine
#       axis is the PRODUCER of the artefact it reads.
# ===========================================================================
MCP="mcp__plugin_playwright_playwright"
RC_NAV="${MCP}__browser_navigate"
RC_NETREQ="${MCP}__browser_network_requests"
RC_SNAP="${MCP}__browser_snapshot"
RC_FINDING_500='{"event":"finding_observed","criterionId":"EC10","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/dashboard","status":500,"originClass":"in-scope","statusClass":"fatal","message":"500 on the dashboard document request"}'
RC_NETLOG='[{"method":"GET","url":"https://app.test/dashboard","status":500,"type":"document"}]'

rc_ts() { # <tree> <run> <tool>
  ( cd "$1" && bash "$TOOLSTREAM" append "$2" \
      "{\"tool\":\"$3\",\"args\":{},\"resultDigest\":{\"len\":0,\"sha256\":\"x\"},\"responseBody\":\"\"}" >/dev/null )
}
rc_jr() { ( cd "$1" && bash "$JOURNAL" append "$2" "$3" >/dev/null ); }
rc_netlog() { mkdir -p "$1/.qa/runs/$2"; printf '%s' "$3" > "$1/.qa/runs/$2/network-log.json"; }
rc_ckpt() { ( cd "$1" && bash "$CKPT" "$2" "$3" blocked --last-action "environment stopped us" >/dev/null ); }
# rc_checks <run-dir> -> "<field>=<value> …" for the four run-checks, from the
# __run-checks__ record. python3 so it needs no jq and is engine-agnostic.
rc_checks() {
  python3 - "$1/verification.json" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
fields = ("ledgerComplete", "classificationsAgree", "loadWindowCovered", "knownDefectsOk")
out = "no-record"
if os.path.isfile(path):
    try:
        recs = json.load(open(path))
    except Exception:
        recs = []
    for r in recs if isinstance(recs, list) else []:
        if isinstance(r, dict) and r.get("criterionId") == "__run-checks__":
            checks = r.get("runChecks")
            if isinstance(checks, dict):
                out = r.get("verifierVerdict", "?") + " " + " ".join(
                    "%s=%s" % (f, str(checks.get(f)).lower()) for f in fields)
            else:
                out = r.get("verifierVerdict", "?") + " no-runChecks"
            break
print(out)
PYEOF
}

for QV_ENGINE in jq python3; do
  if ! command -v "$QV_ENGINE" >/dev/null 2>&1; then
    echo "SKIP - __run-checks__ cases [$QV_ENGINE]: $QV_ENGINE not on this host"; continue
  fi
  T="$WORK/p7-$QV_ENGINE"; mkdir -p "$T/.qa"
  # .qa/config.json is PROJECT-level (decision R16): its baseUrl is what
  # makes an app.test 500 in-scope rather than third-party.
  printf '%s' '{"baseUrl":"https://app.test"}' > "$T/.qa/config.json"
  qv() { ( cd "$T" && QA_ENGINE="$QV_ENGINE" bash "$QAVERIFY" "$1" >/dev/null 2>&1 ); }

  # --- 7a: ONE failed check (ledgerComplete). The driver log holds a
  # navigation 500 the findings journal never recorded — incident regression
  # shape. A toolstream exists, so the run is CAPTURED and the only problem
  # is the run-check: that isolation is what makes the count assertion mean
  # something. The criterion is `blocked` (a skip, not a failure), so any
  # `failures` above 1 is this task double-counting.
  rc_ts "$T" rcone "$RC_NAV"; rc_ts "$T" rcone "$RC_NETREQ"
  rc_netlog "$T" rcone "$RC_NETLOG"
  rc_jr "$T" rcone '{"event":"run_started"}'
  rc_ckpt "$T" rcone EC10
  qv rcone; RCV_ONE=$?
  check "test_run_checks_failure[$QV_ENGINE]: fixture sanity — qa-verify itself exits non-zero" \
    "$([[ "$RCV_ONE" -ne 0 ]] && echo yes)" "yes"
  check "test_run_checks_failure[$QV_ENGINE]: fixture sanity — exactly ledgerComplete is false" \
    "$(rc_checks "$T/.qa/runs/rcone")" \
    "fail ledgerComplete=false classificationsAgree=true loadWindowCovered=true knownDefectsOk=true"
  check "test_run_checks_failure[$QV_ENGINE]: fixture sanity — the run IS captured (so UNVERIFIED is not in play)" \
    "$(canary_channel "$T/.qa/runs/rcone")" "toolstream"
  junit_run "$T" rcone "$T/rcone"; RC7A=$?
  check "test_run_checks_failure_produces_nonzero_exit[$QV_ENGINE]: exit is NON-ZERO" \
    "$([[ "$RC7A" -ne 0 ]] && echo yes)" "yes"
  X7A="$(cat "$T/rcone.xml")"
  check_contains "test_run_checks_failure_synthesizes_junit_failure_case[$QV_ENGINE]: the testcase is named __run-checks__" \
    "$X7A" '<testcase name="__run-checks__"'
  check_contains "test_run_checks_message_names_which_checks_failed[$QV_ENGINE]: the message names the one failed check" \
    "$X7A" '<failure message="run checks failed: ledgerComplete"'
  check_contains "test_run_checks_failure_carries_the_verifier_reason[$QV_ENGINE]: the body carries qa-verify's own reason" \
    "$X7A" "absent from the findings journal"
  check "test_run_checks_failure_counted_once[$QV_ENGINE]: failures is exactly 1 (no double count with VERIFY_RC)" \
    "$(attr1 "$T/rcone.xml" failures)" 'failures="1"'
  check "test_run_checks_failure_counted_once[$QV_ENGINE]: exactly ONE __run-checks__ testcase" \
    "$(grep -c '<testcase name="__run-checks__"' "$T/rcone.xml" | tr -d ' ')" "1"
  check "test_run_checks_failure_counted_once[$QV_ENGINE]: tests is 1 criterion + 1 synthetic" \
    "$(attr1 "$T/rcone.xml" tests)" 'tests="2"'
  check_not_contains "test_run_checks_does_not_imply_unverified[$QV_ENGINE]: a captured run gets no __run-verified__ case" \
    "$X7A" "__run-verified__"
  check_contains "test_run_checks_is_also_surfaced_as_a_property[$QV_ENGINE]" \
    "$X7A" 'name="qa.runChecks"'
  # The assurance tier must not stamp "every recorded pass independently
  # verified" next to a failed structural gate — the same too-quiet-stamp
  # failure this plan exists to remove, one level up.
  check_contains "test_assurance_tier_names_the_failed_run_check[$QV_ENGINE]" \
    "$X7A" "the run-scoped checks did NOT all pass"

  # --- 7b: TWO failed checks — a navigation with no browser_network_requests
  # before the next one (loadWindowCovered) on top of the missing ledger
  # entry. The message must name BOTH, in the canonical field order.
  rc_ts "$T" rctwo "$RC_NAV"; rc_ts "$T" rctwo "$RC_SNAP"
  rc_ts "$T" rctwo "$RC_NAV"; rc_ts "$T" rctwo "$RC_NETREQ"
  rc_netlog "$T" rctwo "$RC_NETLOG"
  rc_jr "$T" rctwo '{"event":"run_started"}'
  rc_ckpt "$T" rctwo EC10
  qv rctwo
  check "test_run_checks_two_failures[$QV_ENGINE]: fixture sanity — ledgerComplete AND loadWindowCovered are false" \
    "$(rc_checks "$T/.qa/runs/rctwo")" \
    "fail ledgerComplete=false classificationsAgree=true loadWindowCovered=false knownDefectsOk=true"
  junit_run "$T" rctwo "$T/rctwo"; RC7B=$?
  check "test_run_checks_two_failures[$QV_ENGINE]: exit is NON-ZERO" \
    "$([[ "$RC7B" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_run_checks_message_names_which_checks_failed[$QV_ENGINE]: both names, canonical order" \
    "$(cat "$T/rctwo.xml")" '<failure message="run checks failed: ledgerComplete, loadWindowCovered"'
  check "test_run_checks_two_failures[$QV_ENGINE]: still ONE testcase for the whole run-checks record" \
    "$(grep -c '<testcase name="__run-checks__"' "$T/rctwo.xml" | tr -d ' ')" "1"
  check "test_run_checks_two_failures[$QV_ENGINE]: still failures=1 — one record, one failure" \
    "$(attr1 "$T/rctwo.xml" failures)" 'failures="1"'

  # --- 7c: all four pass -> no testcase, exit code untouched, and the
  # positive result still visible as a property.
  rc_ts "$T" rcok "$RC_NAV"; rc_ts "$T" rcok "$RC_NETREQ"
  rc_netlog "$T" rcok "$RC_NETLOG"
  rc_jr "$T" rcok '{"event":"run_started"}'
  rc_jr "$T" rcok "$RC_FINDING_500"
  rc_ckpt "$T" rcok EC10
  qv rcok; RCV_OK=$?
  check "test_run_checks_all_pass[$QV_ENGINE]: fixture sanity — qa-verify exits 0" "$RCV_OK" "0"
  check "test_run_checks_all_pass[$QV_ENGINE]: fixture sanity — all four true" \
    "$(rc_checks "$T/.qa/runs/rcok")" \
    "pass ledgerComplete=true classificationsAgree=true loadWindowCovered=true knownDefectsOk=true"
  junit_run "$T" rcok "$T/rcok"; RC7C=$?
  check "test_run_checks_all_pass_exit_code_unchanged[$QV_ENGINE]: exits 0" "$RC7C" "0"
  check_not_contains "test_run_checks_all_pass_emits_no_failure_case[$QV_ENGINE]: no testcase is synthesized" \
    "$(cat "$T/rcok.xml")" '<testcase name="__run-checks__"'
  check "test_run_checks_all_pass[$QV_ENGINE]: failures stays 0" \
    "$(attr1 "$T/rcok.xml" failures)" 'failures="0"'
  check_contains "test_run_checks_all_pass_is_still_visible[$QV_ENGINE]: the property records that the gate ran and passed" \
    "$(cat "$T/rcok.xml")" 'ledgerComplete=true classificationsAgree=true loadWindowCovered=true knownDefectsOk=true'

  # --- 7d: a run-check failure AND an UNVERIFIED run in the SAME report.
  # No toolstream at all (canary channel=none -> UNVERIFIED) and a journal
  # that calls a baseUrl-origin 500 `third-party` (classificationsAgree
  # false). Neither signal may mask the other.
  rc_jr "$T" rcboth '{"event":"finding_observed","criterionId":"EC10","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/broken","status":500,"originClass":"third-party","statusClass":"fatal","message":"claimed third-party"}'
  rc_ckpt "$T" rcboth EC10
  qv rcboth
  # `loadWindowCovered=not-evaluated`, NOT `true`: this fixture has no
  # toolstream by design, so there was no ordered tool sequence to evaluate
  # the load window against. Lane K made the field three-state precisely so
  # that a check which never ran cannot present as a check that passed (the
  # earlier expectation `true` here encoded exactly that bug), and
  # report-to-junit.sh's `is not True` test treats an unperformed structural
  # check as not proven.
  check "test_run_checks_and_unverified_coexist[$QV_ENGINE]: fixture sanity — classificationsAgree false, load window not-evaluated (a skipped check is not a passed one)" \
    "$(rc_checks "$T/.qa/runs/rcboth")" \
    "fail ledgerComplete=true classificationsAgree=false loadWindowCovered=not-evaluated knownDefectsOk=true"
  check "test_run_checks_and_unverified_coexist[$QV_ENGINE]: fixture sanity — and there is no capture channel" \
    "$(canary_channel "$T/.qa/runs/rcboth")" "none"
  junit_run "$T" rcboth "$T/rcboth"; RC7D=$?
  X7D="$(cat "$T/rcboth.xml")"
  check "test_run_checks_and_unverified_coexist[$QV_ENGINE]: exit is NON-ZERO" \
    "$([[ "$RC7D" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_run_checks_and_unverified_coexist[$QV_ENGINE]: the UNVERIFIED case is NOT masked" \
    "$X7D" '<testcase name="__run-verified__"'
  check_contains "test_run_checks_and_unverified_coexist[$QV_ENGINE]: the run-checks case is NOT masked" \
    "$X7D" '<testcase name="__run-checks__"'
  check_contains "test_run_checks_and_unverified_coexist[$QV_ENGINE]: the UNVERIFIED reason survives" \
    "$X7D" "UNVERIFIED — no independent capture"
  check_contains "test_run_checks_and_unverified_coexist[$QV_ENGINE]: the run-check name survives" \
    "$X7D" 'run checks failed: classificationsAgree'
  check "test_run_checks_and_unverified_coexist[$QV_ENGINE]: BOTH are counted (1 criterion + 2 synthetic)" \
    "$(attr1 "$T/rcboth.xml" tests)" 'tests="3"'
  check "test_run_checks_and_unverified_coexist[$QV_ENGINE]: failures counts both, exactly once each" \
    "$(attr1 "$T/rcboth.xml" failures)" 'failures="2"'

  # --- 7e: FAIL CLOSED on qa-verify's own error record for this pass. Its
  # build_error_record shape carries verifierVerdict "error" and NO
  # runChecks key (the four checks never completed). Hand-authored here
  # because forcing an internal crash inside run_run_checks_pass is not
  # reachable from the outside — the SHAPE is pinned by qa-verify.sh's
  # build_error_record, quoted verbatim.
  rc_ts "$T" rcerr "$RC_NAV"
  rc_ckpt "$T" rcerr EC10
  printf '%s' '[{"criterionId":"__run-checks__","persona":"","inRunVerdict":"pass","verifierVerdict":"error","confidence":"high","reasons":["qa-verify internal error while re-checking this criterion: run_run_checks_pass exited 1 (see qa-verify'"'"'s own stderr above for the underlying failure) — the four run-scoped checks did not complete — recorded as error rather than silently dropped"]}]' \
    > "$T/.qa/runs/rcerr/verification.json"
  check "test_run_checks_error_record[$QV_ENGINE]: fixture sanity — the record carries no runChecks object" \
    "$(rc_checks "$T/.qa/runs/rcerr")" "error no-runChecks"
  junit_run "$T" rcerr "$T/rcerr"; RC7E=$?
  check "test_run_checks_error_record_still_fails[$QV_ENGINE]: a gate that did not complete exits NON-ZERO" \
    "$([[ "$RC7E" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_run_checks_error_record_still_fails[$QV_ENGINE]: the failure names the incompleteness, not four false checks" \
    "$(cat "$T/rcerr.xml")" '<failure message="run checks failed: the four run-scoped checks did not complete (verifierVerdict=error)"'
  check_not_contains "test_run_checks_error_record_still_fails[$QV_ENGINE]: it does not claim a specific check failed" \
    "$(cat "$T/rcerr.xml")" "run checks failed: ledgerComplete"

  # --- 7f: a verification.json with NO __run-checks__ record at all is an
  # unchanged no-op (the shape every pre-Task-8 run has).
  rc_ts "$T" rcnone "$RC_NAV"
  rc_ckpt "$T" rcnone EC10
  printf '%s' '[]' > "$T/.qa/runs/rcnone/verification.json"
  junit_run "$T" rcnone "$T/rcnone"; RC7F=$?
  check "test_run_checks_absent_is_a_noop[$QV_ENGINE]: exits 0" "$RC7F" "0"
  check_not_contains "test_run_checks_absent_is_a_noop[$QV_ENGINE]: no testcase" \
    "$(cat "$T/rcnone.xml")" '__run-checks__'
  check_not_contains "test_run_checks_absent_is_a_noop[$QV_ENGINE]: no property either" \
    "$(cat "$T/rcnone.xml")" 'qa.runChecks'
done

# --- 7j: an UNRECORDED check fails CLOSED. A `runChecks` object that simply
# OMITS a field (or carries a non-boolean) has not PROVEN that check — and an
# unproven structural check is not a pass. Hand-authored because qa-verify
# always writes all four today; this pins the reader's posture so a future
# producer that adds a fifth field, or omits one on a degrade, cannot turn a
# silent omission into a green build.
RC_PARTIAL="$WORK/p7-partial"; mkdir -p "$RC_PARTIAL"
( cd "$RC_PARTIAL" && bash "$TOOLSTREAM" append partial "{\"tool\":\"$RC_NAV\",\"args\":{},\"resultDigest\":{\"len\":0,\"sha256\":\"x\"},\"responseBody\":\"\"}" >/dev/null )
( cd "$RC_PARTIAL" && bash "$CKPT" partial EC10 blocked --last-action "environment stopped us" >/dev/null )
printf '%s' '[{"criterionId":"__run-checks__","persona":"","inRunVerdict":"n/a","verifierVerdict":"pass","confidence":"high","reasons":["a producer that recorded only three of the four checks"],"runChecks":{"ledgerComplete":true,"classificationsAgree":true,"knownDefectsOk":null}}]' \
  > "$RC_PARTIAL/.qa/runs/partial/verification.json"
junit_run "$RC_PARTIAL" partial "$RC_PARTIAL/rep"; RC7J=$?
check "test_run_checks_unrecorded_check_fails_closed: exit is NON-ZERO even though verifierVerdict says pass" \
  "$([[ "$RC7J" -ne 0 ]] && echo yes)" "yes"
check_contains "test_run_checks_unrecorded_check_fails_closed: the message names the two it could not prove" \
  "$(cat "$RC_PARTIAL/rep.xml")" '<failure message="run checks failed: loadWindowCovered, knownDefectsOk"'
check_contains "test_run_checks_unrecorded_check_fails_closed: the property distinguishes unrecorded from false" \
  "$(cat "$RC_PARTIAL/rep.xml")" 'loadWindowCovered=unrecorded knownDefectsOk=unrecorded'

# --- 7i: END TO END through qa-ci.sh with the REAL qa-verify.sh (no stub).
# The build must fail ONCE, and the report it leaves behind must name the
# failed check — the whole point of this fix round: qa-verify's exit code
# already failed the build, silently.
DIR_H="$WORK/ci-h"; mkdir -p "$DIR_H/.qa"
printf '%s' '{"baseUrl":"https://app.test"}' > "$DIR_H/.qa/config.json"
cat > "$DIR_H/agent-stub.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# The incident shape: the driver log holds a navigation 500 that the findings
# journal never recorded, and every criterion is recorded non-pass so the
# per-criterion pass loop visits nothing.
bash "$TOOLSTREAM" append rcci '{"tool":"${MCP}__browser_navigate","args":{},"resultDigest":{"len":0,"sha256":"x"},"responseBody":""}' >/dev/null
bash "$TOOLSTREAM" append rcci '{"tool":"${MCP}__browser_network_requests","args":{},"resultDigest":{"len":0,"sha256":"x"},"responseBody":""}' >/dev/null
mkdir -p .qa/runs/rcci
printf '%s' '$RC_NETLOG' > .qa/runs/rcci/network-log.json
bash "$JOURNAL" append rcci '{"event":"run_started"}' >/dev/null
bash "$CKPT" rcci EC10 blocked --last-action "environment stopped us" >/dev/null
EOF
chmod +x "$DIR_H/agent-stub.sh"
( cd "$DIR_H" && QA_SKIP_PREFLIGHT=1 QA_SKIP_SESSION_PREFLIGHT=1 \
    QA_AGENT_CMD="bash ./agent-stub.sh" QA_JUNIT_OUT="$DIR_H/out.xml" \
    bash "$QACI" "some target" >"$DIR_H/stdout.log" 2>&1 )
RC_H=$?
check "qa-ci Case H: a failed run-scoped check fails the build (real qa-verify, no stub)" \
  "$([[ "$RC_H" -ne 0 ]] && echo yes)" "yes"
check_contains "qa-ci Case H: the exported report NAMES the failed check" \
  "$(cat "$DIR_H/out.xml")" '<failure message="run checks failed: ledgerComplete"'
check "qa-ci Case H: exactly one __run-checks__ row in the report" \
  "$(grep -c '<testcase name="__run-checks__"' "$DIR_H/out.xml" | tr -d ' ')" "1"
check "qa-ci Case H: the report counts it once" \
  "$(attr1 "$DIR_H/out.xml" failures)" 'failures="1"'
check_contains "qa-ci Case H: qa.verified is true — qa-verify DID run; the run-check is what failed" \
  "$(cat "$DIR_H/out.xml")" 'name="qa.verified" value="true"'

# --- 7g: engine PARITY over every __run-checks__ fixture, streams compared
# SEPARATELY (the producer is dual-engine; the reader is python3-only).
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for RCFX in rcone rctwo rcok rcboth rcerr rcnone; do
    for STREAM in xml stdout stderr; do
      check "test_engines_agree[$RCFX/$STREAM]: identical across qa-verify engines" \
        "$(diff <(norm "$WORK/p7-jq/$RCFX.$STREAM" "$WORK/p7-jq") \
                <(norm "$WORK/p7-python3/$RCFX.$STREAM" "$WORK/p7-python3") >/dev/null && echo same)" "same"
    done
  done
else
  echo "SKIP - test_engines_agree[__run-checks__]: both jq and python3 are needed"
fi

# --- 7h: the pre-existing qa-verify OVERRIDE report is untouched: an
# override is a CRITERION failure and must not gain a run-checks row.
check_not_contains "test_override_report_gains_no_run_checks_row: PART 1a's override XML has no __run-checks__" \
  "$(cat "$WORK/overridden.xml")" '__run-checks__'

# ===========================================================================
# PART 8 — Fix round 2: the `driver-log` arm, and the SECOND witness
# (`runChecks.findingsChannel`) that does not depend on the canary being
# honest.
#
# WHY THIS PART EXISTS. Three lanes meant three different things by
# "driver-log": checkpoint.sh's canary reports it on the mere PRESENCE of a
# `.playwright-mcp/*.md`, report-to-junit.sh accepts it as independent
# capture, and qa-verify.sh resolves a driver log only from `*.har` /
# `network-log.json`. A stub `session.md` with no toolstream and no HAR
# therefore produced exit 0 at confidence `high` with the report stamping
# "every recorded pass independently verified" — I1b failing OPEN. Lane I is
# tightening the canary; this side adds a trigger that holds even when the
# canary lies:
#
#   runChecks.findingsChannel == "none"  ->  UNVERIFIED
#
# RATIFIED INTERFACE (Lane K), used verbatim: `runChecks.findingsChannel` is
# exactly one of `toolstream` | `driver-log` | `none`. The verifier reporting
# that NO channel yielded findings is independent evidence of the same fact
# the canary is supposed to report, so it reuses the ratified reason string
# `no independent capture` (the reason set stays the three the plan pins) and
# the WITNESSES are named in the failure body. The two witnesses are
# deliberately not merged into one reason line: a CI grep for
# `UNVERIFIED — no independent capture` must keep working.
#
# ALSO PINNED HERE: the `driver-log` arm of CAPTURE_CHANNELS itself, which
# had no test at all before this round — and an untested arm is where this
# project keeps finding Criticals. It is exercised through the REAL
# checkpoint.sh canary (a `.playwright-mcp/*.md` in the tree), under BOTH of
# that script's engines, with the report's streams compared separately.
#
# The findingsChannel fixtures write verification.json directly: at the time
# of writing Lane K has not yet emitted the field (`grep findingsChannel`
# over the tree finds nothing), so these are literals of the ratified
# contract, and each carries the four booleans alongside so the reader is
# proven to treat findingsChannel as a CHANNEL and never as a fifth boolean
# check.
# ===========================================================================

# write_runchecks_vj <run-dir> <findingsChannel|""> [verifierVerdict]
# "" omits the field entirely — today's record shape, which must stay benign.
write_runchecks_vj() {
  python3 - "$1/verification.json" "$2" "${3:-pass}" <<'PYEOF'
import json, sys
path, fc, verdict = sys.argv[1], sys.argv[2], sys.argv[3]
checks = {"ledgerComplete": True, "classificationsAgree": True,
          "loadWindowCovered": True, "knownDefectsOk": True}
if fc != "":
    checks["findingsChannel"] = fc
open(path, "w").write(json.dumps([{
    "criterionId": "__run-checks__", "persona": "", "inRunVerdict": "n/a",
    "verifierVerdict": verdict, "confidence": "high",
    "reasons": ["run-scoped checks recorded for this fixture"],
    "channel": fc or "none", "knownDefects": [], "runChecks": checks,
}]))
PYEOF
}

for CK_ENGINE in jq python3; do
  if ! command -v "$CK_ENGINE" >/dev/null 2>&1; then
    echo "SKIP - driver-log arm [$CK_ENGINE]: $CK_ENGINE not on this host"; continue
  fi
  D="$WORK/p8-$CK_ENGINE"; mkdir -p "$D/.playwright-mcp"
  # A stub session.md is deliberately present and deliberately INERT: Lane I's
  # canary fix made file presence stop counting as capture, so this converts
  # to zero events and yields `none`. The driver-log fixtures below get a
  # per-run network-log.json instead — a log qa-verify.sh would actually
  # resolve, which is what `driver-log` is now allowed to mean. Keeping the
  # stub here is the regression: if presence ever counts again, the
  # `bothnone` fixture at the end of this loop stops reporting `none`.
  printf 'stub session log\n' > "$D/.playwright-mcp/session.md"
  mkck() { ( cd "$D" && QA_ENGINE="$CK_ENGINE" bash "$CKPT" "$1" "$2" pass --last-action "viewed the list" >/dev/null ); }
  # mk_netlog <run> — the run's own network-log.json, second in the
  # resolution order qa-verify.sh's network_log_file() uses.
  mk_netlog() { mkdir -p "$D/.qa/runs/$1"; printf '%s' '[]' > "$D/.qa/runs/$1/network-log.json"; }

  # --- 8a: the driver-log ARM itself — the arm that had NO test at all
  # before this round, which is how three lanes came to mean three different
  # things by the label. With a driver network log the verifier would
  # resolve and no verifier record to consult, the canary is the only
  # witness and accepting it is correct (post-Lane-I, `driver-log` can no
  # longer be claimed on file presence alone).
  mk_netlog dlonly
  mkck dlonly DL1
  check "test_driver_log_channel_is_accepted_as_capture[$CK_ENGINE]: fixture sanity — the canary reports driver-log" \
    "$(canary_channel "$D/.qa/runs/dlonly")" "driver-log"
  junit_run "$D" dlonly "$D/dlonly"; RC8A=$?
  check "test_driver_log_channel_is_accepted_as_capture[$CK_ENGINE]: exits 0 on the canary's word alone (no second witness present)" \
    "$RC8A" "0"
  check_not_contains "test_driver_log_channel_is_accepted_as_capture[$CK_ENGINE]: nothing is synthesized" \
    "$(cat "$D/dlonly.xml")" "__run-verified__"

  # --- 8b: THE HEADLINE CASE. The canary says driver-log; the verifier says
  # no channel yielded findings. The second witness wins: a stub session.md
  # must not buy a green build.
  mk_netlog dlnone
  mkck dlnone DL2
  write_runchecks_vj "$D/.qa/runs/dlnone" none
  check "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: fixture sanity — the canary claims driver-log" \
    "$(canary_channel "$D/.qa/runs/dlnone")" "driver-log"
  junit_run "$D" dlnone "$D/dlnone"; RC8B=$?
  check "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: exits NON-ZERO" \
    "$([[ "$RC8B" -ne 0 ]] && echo yes)" "yes"
  X8B="$(cat "$D/dlnone.xml")"
  check_contains "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: the ratified reason string is reused verbatim" \
    "$X8B" '<failure message="UNVERIFIED — no independent capture"'
  check_contains "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: the body names the verifier witness" \
    "$X8B" "runChecks.findingsChannel=none"
  check_contains "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: and names what the canary claimed, so the disagreement is visible" \
    "$X8B" "channel=driver-log"
  check "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: counted once (1 criterion + 1 synthetic)" \
    "$(attr1 "$D/dlnone.xml" tests)" 'tests="2"'
  check "test_findings_channel_none_overrides_a_driver_log_canary[$CK_ENGINE]: failures is exactly 1" \
    "$(attr1 "$D/dlnone.xml" failures)" 'failures="1"'
  check_not_contains "test_findings_channel_is_never_read_as_a_fifth_boolean_check[$CK_ENGINE]: no run-checks failure is invented" \
    "$X8B" 'run checks failed'
  check_contains "test_findings_channel_is_never_read_as_a_fifth_boolean_check[$CK_ENGINE]: the property still reports exactly the four booleans" \
    "$X8B" 'value="ledgerComplete=true classificationsAgree=true loadWindowCovered=true knownDefectsOk=true"'
  check_not_contains "test_assurance_tier_never_stamps_all_clear_on_an_unverified_run[$CK_ENGINE]: the all-clear stamp is gone" \
    "$X8B" "every recorded pass independently verified"
  check_contains "test_assurance_tier_never_stamps_all_clear_on_an_unverified_run[$CK_ENGINE]: the tier itself names the UNVERIFIED status" \
    "$X8B" 'recorded passes were independently verified, but the run is UNVERIFIED — no independent capture'

  # --- 8c: both witnesses agree there IS a channel -> clean. ---
  mk_netlog dlok
  mkck dlok DL3
  write_runchecks_vj "$D/.qa/runs/dlok" driver-log
  junit_run "$D" dlok "$D/dlok"; RC8C=$?
  check "test_findings_channel_driver_log_agrees[$CK_ENGINE]: exits 0" "$RC8C" "0"
  check_not_contains "test_findings_channel_driver_log_agrees[$CK_ENGINE]: nothing is synthesized" \
    "$(cat "$D/dlok.xml")" "__run-verified__"

  # --- 8d: the field OMITTED is today's record shape and stays benign —
  # this witness may never retro-fail a run recorded before Lane K emitted
  # it. (Fail-closed applies to a field that IS recorded but unusable, not
  # to one that was never written.) ---
  mk_netlog dlomit
  mkck dlomit DL4
  write_runchecks_vj "$D/.qa/runs/dlomit" ""
  check "test_findings_channel_absent_stays_benign[$CK_ENGINE]: fixture sanity — the field is genuinely absent" \
    "$(grep -c findingsChannel "$D/.qa/runs/dlomit/verification.json" | tr -d ' ')" "0"
  junit_run "$D" dlomit "$D/dlomit"; RC8D=$?
  check "test_findings_channel_absent_stays_benign[$CK_ENGINE]: exits 0" "$RC8D" "0"

  # --- 8e: a RECORDED but unrecognized value fails closed, exactly like an
  # unrecognized canary channel. A value this reader cannot interpret is not
  # evidence that a channel produced findings. ---
  for BADFC in carrier-pigeon "" TOOLSTREAM; do
    mk_netlog dlbad
    mkck "dlbad" DL5
    write_runchecks_vj "$D/.qa/runs/dlbad" "$BADFC"
    if [[ "$BADFC" == "" ]]; then
      # "" omits the field in the writer, so write the empty-string value
      # explicitly — an empty string IS a recorded, uninterpretable value.
      python3 - "$D/.qa/runs/dlbad/verification.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
recs = json.load(open(path))
recs[0]["runChecks"]["findingsChannel"] = ""
open(path, "w").write(json.dumps(recs))
PYEOF
    fi
    junit_run "$D" dlbad "$D/dlbad"; RC8E=$?
    check "test_findings_channel_unrecognized_value_fails_closed[$CK_ENGINE/'$BADFC']: exits NON-ZERO" \
      "$([[ "$RC8E" -ne 0 ]] && echo yes)" "yes"
    check_contains "test_findings_channel_unrecognized_value_fails_closed[$CK_ENGINE/'$BADFC']: reason is the ratified capture string" \
      "$(cat "$D/dlbad.xml")" "UNVERIFIED — no independent capture"
  done

  # --- 8f: a toolstream canary with findingsChannel=none is the same
  # disagreement in the other direction — a toolstream that exists but
  # yielded no findings channel to the verifier. ---
  ( cd "$D" && bash "$TOOLSTREAM" append tsnone '{"tool":"browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"t1"}}' >/dev/null )
  mkck tsnone DL6
  write_runchecks_vj "$D/.qa/runs/tsnone" none
  check "test_findings_channel_none_overrides_a_toolstream_canary[$CK_ENGINE]: fixture sanity — the canary reports toolstream" \
    "$(canary_channel "$D/.qa/runs/tsnone")" "toolstream"
  junit_run "$D" tsnone "$D/tsnone"; RC8F=$?
  check "test_findings_channel_none_overrides_a_toolstream_canary[$CK_ENGINE]: exits NON-ZERO" \
    "$([[ "$RC8F" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_findings_channel_none_overrides_a_toolstream_canary[$CK_ENGINE]: the body names both witnesses" \
    "$(cat "$D/tsnone.xml")" "channel=toolstream"

  # --- 8g: BOTH witnesses negative -> the reason appears exactly ONCE.
  # No per-run network log, no toolstream, and the tree's session.md stub
  # converts to zero events, so the canary honestly reports `none` — which
  # is also the regression guard for Lane I's fix: were file presence to
  # count as capture again, this fixture would report `driver-log` and the
  # sanity check below would fail.
  mkck bothnone DL7
  write_runchecks_vj "$D/.qa/runs/bothnone" none
  check "test_both_witnesses_negative_reason_is_not_duplicated[$CK_ENGINE]: fixture sanity — the canary is none too" \
    "$(canary_channel "$D/.qa/runs/bothnone")" "none"
  junit_run "$D" bothnone "$D/bothnone"; RC8G=$?
  check "test_both_witnesses_negative_reason_is_not_duplicated[$CK_ENGINE]: exits NON-ZERO" \
    "$([[ "$RC8G" -ne 0 ]] && echo yes)" "yes"
  check "test_both_witnesses_negative_reason_is_not_duplicated[$CK_ENGINE]: the headline names the reason ONCE" \
    "$(head -1 "$D/bothnone.stderr")" "UNVERIFIED — no independent capture"
  check "test_both_witnesses_negative_reason_is_not_duplicated[$CK_ENGINE]: exactly one synthetic testcase element" \
    "$(grep -c '<testcase name="__run-verified__"' "$D/bothnone.xml" | tr -d ' ')" "1"
  check_contains "test_both_witnesses_negative_reason_is_not_duplicated[$CK_ENGINE]: the body names both witnesses" \
    "$(cat "$D/bothnone.xml")" "runChecks.findingsChannel=none"
  check_not_contains "test_both_witnesses_negative_reason_is_not_duplicated[$CK_ENGINE]: with no phantom canary claim, since the canary agreed" \
    "$(cat "$D/bothnone.xml")" "although the canary claimed"

  # --- 8i: `loadWindowCovered: "not-evaluated"` while the capture witnesses
  # are BOTH positive — the checks could not be evaluated for a reason other
  # than missing capture, and nothing pinned that combination before.
  #
  # It is genuinely reachable, not synthetic: a run with a driver
  # network-log.json (so the canary AND runChecks.findingsChannel both say
  # `driver-log`) but no toolstream has no ordered tool sequence, so the
  # load-window check has nothing to evaluate. Built with the REAL
  # qa-verify.sh, whose own exit code is 0 here — the un-evaluated check does
  # not fail the run at the verifier — so this export is the ONLY thing
  # standing between a check that never ran and a green build.
  #
  # WHERE THE SIGNAL LANDS, stated explicitly so a future change to it is
  # visible rather than silent: the build fails through the `__run-checks__`
  # row, which NAMES the un-evaluated check; there is no `__run-verified__`
  # row, because neither capture witness is negative. The run therefore never
  # reads as verified — the assurance tier carries the caveat too.
  mkdir -p "$D/.qa/runs/nevalch"
  printf '%s' "$RC_NETLOG" > "$D/.qa/runs/nevalch/network-log.json"
  rc_jr "$D" nevalch '{"event":"run_started"}'
  rc_jr "$D" nevalch "$RC_FINDING_500"
  ( cd "$D" && QA_ENGINE="$CK_ENGINE" bash "$CKPT" nevalch EC10 blocked --last-action "environment stopped us" >/dev/null )
  ( cd "$D" && QA_ENGINE="$CK_ENGINE" bash "$QAVERIFY" nevalch >/dev/null 2>&1 ); RCV_NE=$?
  check "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: fixture sanity — qa-verify itself exits 0" "$RCV_NE" "0"
  check "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: fixture sanity — only the load window is un-evaluated" \
    "$(rc_checks "$D/.qa/runs/nevalch")" \
    "pass ledgerComplete=true classificationsAgree=true loadWindowCovered=not-evaluated knownDefectsOk=true"
  check "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: fixture sanity — the canary reports a real channel" \
    "$(canary_channel "$D/.qa/runs/nevalch")" "driver-log"
  check "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: fixture sanity — and so does the verifier's findingsChannel" \
    "$(rc_runchecks_field "$D/.qa/runs/nevalch" findingsChannel)" "driver-log"
  junit_run "$D" nevalch "$D/nevalch"; RC8I=$?
  X8I="$(cat "$D/nevalch.xml")"
  check "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: the build FAILS even though qa-verify exited 0" \
    "$([[ "$RC8I" -ne 0 ]] && echo yes)" "yes"
  check_contains "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: the report NAMES the un-evaluated check" \
    "$X8I" '<failure message="run checks failed: loadWindowCovered"'
  check_not_contains "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: no capture reason is invented — both witnesses were positive" \
    "$X8I" "no independent capture"
  check_not_contains "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: so there is no __run-verified__ row" \
    "$X8I" '<testcase name="__run-verified__"'
  check_not_contains "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: and the tier never stamps the all-clear" \
    "$X8I" "every recorded pass independently verified"
  check_contains "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: the property reports the recorded value verbatim, not as unrecorded" \
    "$X8I" 'loadWindowCovered=not-evaluated'
  check "test_not_evaluated_check_with_real_capture[$CK_ENGINE]: counted once (1 criterion + 1 synthetic)" \
    "$(attr1 "$D/nevalch.xml" failures)" 'failures="1"'

done

# --- 8h: engine PARITY across the canary's two engines, streams SEPARATE.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for FX in dlonly dlnone dlok dlomit dlbad tsnone bothnone nevalch; do
    for STREAM in xml stdout stderr; do
      check "test_engines_agree[$FX/$STREAM]: identical across checkpoint.sh engines" \
        "$(diff <(norm "$WORK/p8-jq/$FX.$STREAM" "$WORK/p8-jq") \
                <(norm "$WORK/p8-python3/$FX.$STREAM" "$WORK/p8-python3") >/dev/null && echo same)" "same"
    done
  done
else
  echo "SKIP - test_engines_agree[driver-log arm]: both jq and python3 are needed"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
