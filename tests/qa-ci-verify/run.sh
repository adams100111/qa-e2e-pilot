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
check "junit: exits 0 when qa-verify only degraded confidence (no override)" "$LC_JRC" "0"
LC_CONTENT="$(cat "$LC_XML")"
check_contains "junit: confidence:low pass carries a <system-out>" "$LC_CONTENT" '<system-out>confidence: low'
check_contains "junit: confidence:low system-out mentions the toolstream reason" "$LC_CONTENT" "toolstream"
check_contains "junit: confidence:low pass still names the criterion with the suffix" "$LC_CONTENT" 'C2 (confidence: low)'
check_not_contains "junit: a degrade-only pass never gets a <failure>" "$LC_CONTENT" "<failure"

# ===========================================================================
# PART 2 — back-compat: no verification.json at all -> unchanged rendering,
# and the assurance tier is honest that qa-verify was never run.
# ===========================================================================
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
check "qa-ci Case C: QA_SKIP_VERIFY=1 -> final exit reflects junit alone (0, all-pass checkpoint)" "$RC_C" "0"
check "qa-ci Case C: the failing verify stub was never invoked" "$([[ -f "$MARKER_C" ]] && echo yes || echo no)" "no"
check_contains "qa-ci Case C: the skip is LOGGED, not silent" "$(cat "$DIR_C/stdout.log")" "qa-verify SKIPPED"
check_contains "qa-ci Case C: the log names the reason (QA_SKIP_VERIFY=1)" "$(cat "$DIR_C/stdout.log")" "QA_SKIP_VERIFY=1"
check_contains "qa-ci Case C: the log states the run is UNVERIFIED" "$(cat "$DIR_C/stdout.log")" "UNVERIFIED"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
