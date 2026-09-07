#!/usr/bin/env bash
# Tests for scripts/qa-verify.sh (Plan H2 Task 4, spec §5.3) — the
# out-of-agent, deterministic authority that re-checks every `pass` in a
# completed run against the toolstream and OVERRIDES a forged pass.
#
# Builds real run directories with the actual bundled scripts (checkpoint.sh,
# record-evidence.sh, toolstream.sh) — same idiom as tests/provenance/run.sh —
# rather than hand-authoring checkpoint.json/toolstream.jsonl, so the fixtures
# exercise the real write paths qa-verify.sh has to interoperate with.
#
# checklist.json is deliberately written to each run dir AFTER all
# checkpoint.sh calls (not before): checkpoint.sh's OWN live gate
# (gate_required_kinds) already re-derives required kinds from checklist.json
# at checkpoint time and would refuse to checkpoint a `pass` with a dropped
# required kind if the row were present then — that's the LIVE gate's job,
# already covered by tests/checkpoint's own suite. This suite is about
# qa-verify's OWN, independent, OUT-OF-AGENT authority (spec §5.3's
# "redundant with the live gate, but qa-verify is the authority" — see the
# AC-3-style dropped-kind case), so checklist.json is added late on purpose
# to isolate that qa-verify catches it on its own, not merely re-confirming
# what the live gate already blocked.
#
# Covers:
#   AC-1  — a forged human-action pass (action-trace.json with the default
#           empty sessionCalls, fabricated steps, real fingerprints — passes
#           check-action-trace.js's OWN structural gate, so checkpoint.sh's
#           live gate happily accepts it) with NO matching toolstream
#           capture -> qa-verify OVERRIDES to fail, exit non-zero.
#   genuine run — real evidence (bake/human-action/computed) + matching
#           toolstream captures -> every pass verified, exit 0.
#   dropped kind — a mutating bake criterion checkpointed with only `bake`
#           (human-action dropped) -> qa-verify's own required-kinds
#           re-derivation (independent of the live gate) flags it.
#   unbound bake — a `pass` whose bake readBack is in no captured toolstream
#           response, even though a toolstream exists for the run -> override
#           (distinct from the no-toolstream degrade below).
#   no-toolstream — a genuine run with NO toolstream.jsonl at all -> passes
#           stay `pass` but confidence degrades to `low` (NOT an override),
#           exit 0.
#   selective overriding — a mixed run overrides only the bad criteria,
#           leaves a genuinely bound one alone, and never surfaces a
#           non-`pass` in-run verdict in verification.json at all.
#   QA_VERIFY_REDRIVE_CMD — the documented, un-unit-tested-by-design stub:
#           invoked (once) for a high-stakes criterion when set, never when
#           unset, and never changes the verifier's verdict either way.
#
# Every assertion runs under BOTH jq (default) and QA_ENGINE=python3 (qa-verify.sh
# honors QA_ENGINE the same way toolstream.sh/provenance.sh do).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QAVERIFY="$HERE/../../scripts/qa-verify.sh"
CKPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
REC="$HERE/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
TOOLSTREAM="$HERE/../../scripts/toolstream.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

write_checklist() { # <run> <json>
  mkdir -p "$WORK/.qa/runs/$1"
  printf '%s' "$2" > "$WORK/.qa/runs/$1/checklist.json"
}

vf() { echo "$WORK/.qa/runs/$1/verification.json"; }

# ---------------------------------------------------------------------------
# RUN "genuine": three passes (human-action, bake, computed), real matching
# toolstream captures for the two provenance-checked kinds.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append genuine '{"tool":"Bash","args":{"command":"curl backend/founders/2"},"resultDigest":{"len":0,"sha256":"g1"},"responseBody":"{\"id\":2,\"name\":\"Genuine Founder\",\"equity\":55}"}' >/dev/null )
( cd "$WORK" && bash "$TOOLSTREAM" append genuine '{"tool":"mcp__plugin_playwright_playwright__browser_click","args":{"element":"Add duplicate","ref":"e9"},"resultDigest":{"len":0,"sha256":"g2"},"responseBody":""}' >/dev/null )

G_C1_REF="$( cd "$WORK" && bash "$REC" genuine C1 action-trace \
  --steps '[{"tool":"browser_click","phase":"act"}]' \
  --session-calls '[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click();"}]' \
  --fingerprint-before '{"count":1}' --fingerprint-after '{"count":1}' )"
( cd "$WORK" && bash "$CKPT" genuine C1 pass --kinds human-action --evidence-refs "$G_C1_REF" >/dev/null )

G_C2_REF="$( cd "$WORK" && bash "$REC" genuine C2 bake --read-back '{"name":"Genuine Founder","equity":55}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" genuine C2 pass --kinds bake --evidence-refs "$G_C2_REF" >/dev/null )

G_C3_REF="$( cd "$WORK" && bash "$REC" genuine C3 computed --oracle 10 --observed 10 --match true )"
( cd "$WORK" && bash "$CKPT" genuine C3 pass --kinds computed --evidence-refs "$G_C3_REF" >/dev/null )

write_checklist genuine '[
  {"id":"C1","surface":"/x","kind":"error-state","tags":[],"action":"Add a duplicate founder to trigger a validation error"},
  {"id":"C2","surface":"/x","kind":"happy-path","tags":[],"action":"View the founder list"},
  {"id":"C3","surface":"/x","kind":"computed-logic","tags":[],"action":"Recompute total equity percentage"}
]'

# ---------------------------------------------------------------------------
# RUN "forged": AC-1 (forged human-action, no capture), dropped-kind, unbound
# bake, a genuinely bound control, and an already-`fail` criterion (must
# never appear in verification.json). Only TWO toolstream captures, neither
# of which is a browser_click — so the forged human-action trace has
# genuinely nothing to bind to.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append forged '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"f1"},"responseBody":"{\"marker\":\"GOOD-MARKER-42\"}"}' >/dev/null )
( cd "$WORK" && bash "$TOOLSTREAM" append forged '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"f2"},"responseBody":"{\"marker\":\"DROP-MARKER-77\"}"}' >/dev/null )

# AC-1: forged action-trace — default sessionCalls ([]), fabricated steps,
# real fingerprints (equal, so Check 3's "changed" branch never even fires) —
# this passes check-action-trace.js's OWN structural gate (and therefore
# checkpoint.sh's live gate) fine. No --session-calls given at all.
F_AC1_REF="$( cd "$WORK" && bash "$REC" forged F_AC1 action-trace \
  --steps '[{"tool":"browser_click","phase":"act"}]' \
  --fingerprint-before '{"count":1}' --fingerprint-after '{"count":1}' )"
( cd "$WORK" && bash "$CKPT" forged F_AC1 pass --kinds human-action --evidence-refs "$F_AC1_REF" >/dev/null )

# Dropped kind: mutating bake criterion, only `bake` recorded (human-action
# dropped). Bound evidence, so the ONLY failure reason is the dropped kind.
F_DROP_REF="$( cd "$WORK" && bash "$REC" forged F_DROP bake --read-back '{"marker":"DROP-MARKER-77"}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" forged F_DROP pass --kinds bake --evidence-refs "$F_DROP_REF" >/dev/null )

# Unbound bake: value in no captured response.
F_UNBOUND_REF="$( cd "$WORK" && bash "$REC" forged F_UNBOUND bake --read-back '{"ghost":"GHOST-VALUE-NEVER-CAPTURED-999"}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" forged F_UNBOUND pass --kinds bake --evidence-refs "$F_UNBOUND_REF" >/dev/null )

# Control: genuinely bound bake in the SAME run — proves selective overriding.
F_GOOD_REF="$( cd "$WORK" && bash "$REC" forged F_GOOD bake --read-back '{"marker":"GOOD-MARKER-42"}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" forged F_GOOD pass --kinds bake --evidence-refs "$F_GOOD_REF" >/dev/null )

# An already-fail criterion — must never appear in verification.json.
( cd "$WORK" && bash "$CKPT" forged F_ALREADYFAIL fail --last-action "known bug" >/dev/null )

write_checklist forged '[
  {"id":"F_AC1","surface":"/x","kind":"error-state","tags":[],"action":"Add a duplicate founder to trigger a validation error"},
  {"id":"F_DROP","surface":"/x","kind":"happy-path","tags":[],"action":"Add a founder"},
  {"id":"F_UNBOUND","surface":"/x","kind":"happy-path","tags":[],"action":"View recent activity log"},
  {"id":"F_GOOD","surface":"/x","kind":"happy-path","tags":[],"action":"View equity table"}
]'

# ---------------------------------------------------------------------------
# RUN "notoolstream": a genuine pass, NO toolstream.jsonl ever written for it.
# Also carries a HUMAN-ACTION pass (C_NT_HA) with no toolstream, alongside
# the non-high-stakes bake pass (C_NT) — the QA_VERIFY_STRICT fixture: both
# have identical no-toolstream provenance, but only C_NT_HA is high-stakes.
# ---------------------------------------------------------------------------
NT_REF="$( cd "$WORK" && bash "$REC" notoolstream C_NT bake --read-back '{"anything":"1"}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" notoolstream C_NT pass --kinds bake --evidence-refs "$NT_REF" >/dev/null )

# C_NT_HA: a human-action pass — default sessionCalls ([]), real fingerprints
# (equal, so check-action-trace.js's structural gate passes fine, same idiom
# as the "forged" run's F_AC1) — but for THIS run there is no toolstream.jsonl
# at all, so provenance.sh returns "no-toolstream" (a degrade), never
# "unbound" (a forgery override). Exercises the QA_VERIFY_STRICT high-stakes
# path, not the AC-1 forgery path.
NT_HA_REF="$( cd "$WORK" && bash "$REC" notoolstream C_NT_HA action-trace \
  --steps '[{"tool":"browser_click","phase":"act"}]' \
  --fingerprint-before '{"count":1}' --fingerprint-after '{"count":1}' )"
( cd "$WORK" && bash "$CKPT" notoolstream C_NT_HA pass --kinds human-action --evidence-refs "$NT_HA_REF" >/dev/null )

write_checklist notoolstream '[
  {"id":"C_NT","surface":"/x","kind":"happy-path","tags":[],"action":"View reports"},
  {"id":"C_NT_HA","surface":"/x","kind":"error-state","tags":[],"action":"Add a duplicate founder to trigger a validation error"}
]'

# ---------------------------------------------------------------------------
# RUN "personarun": a persona-scoped pass (Watch item d) — evidence lives
# under evidence/<persona>/<crit>/, not evidence/<crit>/, and must resolve
# and bind correctly.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append personarun '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"p1"},"responseBody":"{\"role\":\"admin-only-value-555\"}"}' >/dev/null )
P_REF="$( cd "$WORK" && bash "$REC" personarun CP1 bake --persona admin --read-back '{"marker":"admin-only-value-555"}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" personarun CP1 pass --persona admin --kinds bake --evidence-refs "$P_REF" >/dev/null )
write_checklist personarun '[{"id":"CP1","surface":"/x","kind":"happy-path","tags":[],"action":"View admin-only dashboard"}]'
check "persona fixture: evidence written under the persona-scoped path" \
  "$([[ -f "$WORK/.qa/runs/personarun/evidence/admin/CP1/bake-read-back.json" ]] && echo yes)" "yes"

# ---------------------------------------------------------------------------
# run assertions under both engines
# ---------------------------------------------------------------------------
run_qv() { # <engine: "" | python3> <run>
  local engine="$1" run="$2"
  if [[ -n "$engine" ]]; then
    ( cd "$WORK" && QA_ENGINE="$engine" bash "$QAVERIFY" "$run" )
  else
    ( cd "$WORK" && bash "$QAVERIFY" "$run" )
  fi
}

for ENGINE in "" python3; do
  LABEL="${ENGINE:-jq(default)}"

  # --- genuine: exit 0, all three verified pass, confidence untouched -------
  run_qv "$ENGINE" genuine >/dev/null 2>&1
  RC_GENUINE=$?
  check "[$LABEL] genuine run: qa-verify exits 0" "$RC_GENUINE" "0"
  check "[$LABEL] genuine C1 verifierVerdict pass" \
    "$(jq -r '.[] | select(.criterionId=="C1") | .verifierVerdict' "$(vf genuine)")" "pass"
  check "[$LABEL] genuine C1 confidence stays high (bound provenance)" \
    "$(jq -r '.[] | select(.criterionId=="C1") | .confidence' "$(vf genuine)")" "high"
  check "[$LABEL] genuine C2 verifierVerdict pass" \
    "$(jq -r '.[] | select(.criterionId=="C2") | .verifierVerdict' "$(vf genuine)")" "pass"
  check "[$LABEL] genuine C3 (computed, no provenance check needed) verifierVerdict pass" \
    "$(jq -r '.[] | select(.criterionId=="C3") | .verifierVerdict' "$(vf genuine)")" "pass"
  check "[$LABEL] genuine: verification.json has exactly 3 records" \
    "$(jq 'length' "$(vf genuine)")" "3"

  # --- forged: exit non-zero, selective overriding ---------------------------
  run_qv "$ENGINE" forged >/dev/null 2>&1
  RC_FORGED=$?
  check "[$LABEL] forged run: qa-verify exits non-zero" "$([[ "$RC_FORGED" -ne 0 ]] && echo yes)" "yes"

  check "[$LABEL] AC-1: forged human-action pass overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="F_AC1") | .verifierVerdict' "$(vf forged)")" "fail"
  check_contains "[$LABEL] AC-1: reason mentions the provenance forgery signal" \
    "$(jq -r '.[] | select(.criterionId=="F_AC1") | .reasons | join("; ")' "$(vf forged)")" "UNBOUND"
  check "[$LABEL] AC-1: inRunVerdict is still recorded as the original pass" \
    "$(jq -r '.[] | select(.criterionId=="F_AC1") | .inRunVerdict' "$(vf forged)")" "pass"

  check "[$LABEL] dropped-kind: overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="F_DROP") | .verifierVerdict' "$(vf forged)")" "fail"
  check_contains "[$LABEL] dropped-kind: reason names the missing required kind" \
    "$(jq -r '.[] | select(.criterionId=="F_DROP") | .reasons | join("; ")' "$(vf forged)")" "human-action"

  check "[$LABEL] unbound bake: overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="F_UNBOUND") | .verifierVerdict' "$(vf forged)")" "fail"
  check_contains "[$LABEL] unbound bake: reason mentions provenance" \
    "$(jq -r '.[] | select(.criterionId=="F_UNBOUND") | .reasons | join("; ")' "$(vf forged)")" "UNBOUND"

  check "[$LABEL] control F_GOOD stays pass (selective overriding)" \
    "$(jq -r '.[] | select(.criterionId=="F_GOOD") | .verifierVerdict' "$(vf forged)")" "pass"

  check "[$LABEL] an already-fail in-run criterion never appears in verification.json" \
    "$(jq -r '[.[] | select(.criterionId=="F_ALREADYFAIL")] | length' "$(vf forged)")" "0"

  check "[$LABEL] forged: verification.json has exactly 4 records (only the passes)" \
    "$(jq 'length' "$(vf forged)")" "4"

  # --- no-toolstream: degrade, NOT override -----------------------------------
  run_qv "$ENGINE" notoolstream >/dev/null 2>&1
  RC_NT=$?
  check "[$LABEL] no-toolstream run: qa-verify still exits 0" "$RC_NT" "0"
  check "[$LABEL] no-toolstream: verifierVerdict stays pass" \
    "$(jq -r '.[] | select(.criterionId=="C_NT") | .verifierVerdict' "$(vf notoolstream)")" "pass"
  check "[$LABEL] no-toolstream: confidence degrades to low" \
    "$(jq -r '.[] | select(.criterionId=="C_NT") | .confidence' "$(vf notoolstream)")" "low"
  check_contains "[$LABEL] no-toolstream: reason explains the degrade" \
    "$(jq -r '.[] | select(.criterionId=="C_NT") | .reasons | join("; ")' "$(vf notoolstream)")" "toolstream"

  # --- QA_VERIFY_STRICT regression (1): default (unset) — human-action pass
  #     with no toolstream degrades exactly like a non-high-stakes pass would,
  #     confidence:low, exit 0. Unchanged behavior. ----------------------------
  check "[$LABEL] default (no QA_VERIFY_STRICT): human-action no-toolstream pass stays verifierVerdict pass" \
    "$(jq -r '.[] | select(.criterionId=="C_NT_HA") | .verifierVerdict' "$(vf notoolstream)")" "pass"
  check "[$LABEL] default (no QA_VERIFY_STRICT): human-action no-toolstream pass confidence degrades to low" \
    "$(jq -r '.[] | select(.criterionId=="C_NT_HA") | .confidence' "$(vf notoolstream)")" "low"
  check "[$LABEL] default (no QA_VERIFY_STRICT): notoolstream run still exits 0" "$RC_NT" "0"

  # --- QA_VERIFY_STRICT regression (2)+(3): strict mode overrides ONLY the
  #     high-stakes (human-action) no-toolstream pass to fail; the read-only/
  #     bake pass (C_NT, non-high-stakes) still just degrades. ----------------
  if [[ -n "$ENGINE" ]]; then
    ( cd "$WORK" && QA_ENGINE="$ENGINE" QA_VERIFY_STRICT=1 bash "$QAVERIFY" notoolstream >/dev/null 2>&1 )
  else
    ( cd "$WORK" && QA_VERIFY_STRICT=1 bash "$QAVERIFY" notoolstream >/dev/null 2>&1 )
  fi
  RC_STRICT=$?
  check "[$LABEL] QA_VERIFY_STRICT=1: qa-verify exits non-zero (high-stakes override present)" \
    "$([[ "$RC_STRICT" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] QA_VERIFY_STRICT=1: human-action no-toolstream pass overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="C_NT_HA") | .verifierVerdict' "$(vf notoolstream)")" "fail"
  check "[$LABEL] QA_VERIFY_STRICT=1: overridden confidence is high" \
    "$(jq -r '.[] | select(.criterionId=="C_NT_HA") | .confidence' "$(vf notoolstream)")" "high"
  check_contains "[$LABEL] QA_VERIFY_STRICT=1: reason names strict mode + suppression risk" \
    "$(jq -r '.[] | select(.criterionId=="C_NT_HA") | .reasons | join("; ")' "$(vf notoolstream)")" "strict mode"
  check "[$LABEL] QA_VERIFY_STRICT=1: non-high-stakes bake pass (C_NT) verifierVerdict still pass (not over-punished)" \
    "$(jq -r '.[] | select(.criterionId=="C_NT") | .verifierVerdict' "$(vf notoolstream)")" "pass"
  check "[$LABEL] QA_VERIFY_STRICT=1: non-high-stakes bake pass (C_NT) confidence still just degrades to low" \
    "$(jq -r '.[] | select(.criterionId=="C_NT") | .confidence' "$(vf notoolstream)")" "low"

  # --- persona-scoped evidence (Watch item d) --------------------------------
  run_qv "$ENGINE" personarun >/dev/null 2>&1
  RC_PERSONA=$?
  check "[$LABEL] persona run: qa-verify exits 0" "$RC_PERSONA" "0"
  check "[$LABEL] persona-scoped evidence resolves and binds -> pass" \
    "$(jq -r '.[] | select(.criterionId=="CP1") | .verifierVerdict' "$(vf personarun)")" "pass"
  check "[$LABEL] persona-scoped record carries the persona" \
    "$(jq -r '.[] | select(.criterionId=="CP1") | .persona' "$(vf personarun)")" "admin"
done

# ---------------------------------------------------------------------------
# QA_VERIFY_REDRIVE_CMD — documented stub: invoked only when set, only for a
# high-stakes (human-action/probe) criterion, and never changes the verdict.
# ---------------------------------------------------------------------------
MARKER="$WORK/redrive-invoked"
rm -f "$MARKER"
STUB="$WORK/redrive-stub.sh"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2 \$3" >> "$MARKER"
exit 0
EOF
chmod +x "$STUB"

( cd "$WORK" && bash "$QAVERIFY" genuine >/dev/null 2>&1 )
check "redrive: NOT invoked when QA_VERIFY_REDRIVE_CMD is unset (default deterministic-only)" \
  "$([[ -f "$MARKER" ]] && echo present || echo absent)" "absent"

( cd "$WORK" && QA_VERIFY_REDRIVE_CMD="$STUB" bash "$QAVERIFY" genuine >/dev/null 2>&1 )
check "redrive: invoked when QA_VERIFY_REDRIVE_CMD is set" \
  "$([[ -f "$MARKER" ]] && echo present || echo absent)" "present"
check_contains "redrive: invoked with the human-action criterion C1" \
  "$(cat "$MARKER" 2>/dev/null)" "genuine C1"
check "redrive: verdict for C1 is unaffected (still pass)" \
  "$(jq -r '.[] | select(.criterionId=="C1") | .verifierVerdict' "$(vf genuine)")" "pass"
check "redrive: NOT invoked for a non-high-stakes (computed) criterion" \
  "$(grep -c ' C3 ' "$MARKER" 2>/dev/null)" "0"

# ---------------------------------------------------------------------------
# error handling: missing run dies non-zero, no verification.json written.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$QAVERIFY" no-such-run >/dev/null 2>&1 )
RC_MISSING=$?
check "missing run: qa-verify exits non-zero" "$([[ "$RC_MISSING" -ne 0 ]] && echo yes)" "yes"
check "missing run: no verification.json written" "$([[ -f "$(vf no-such-run)" ]] && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
# Fix 1 regression: `results_tmp` was `local` to main() while the `trap 'rm
# -f "$results_tmp"' EXIT` fires AFTER main returns (global scope) — under
# `set -uo pipefail` this used to print "results_tmp: unbound variable" to
# stderr on EVERY invocation, and skipped the `rm -f`, leaking the mktemp
# file every run. Assert both symptoms are gone on a plain invocation.
# ---------------------------------------------------------------------------
TMP_BASE="${TMPDIR:-/tmp}"
LEAK_BEFORE="$(find "$TMP_BASE" -maxdepth 1 -name 'tmp.*' 2>/dev/null | sort)"
STDERR_OUT="$( ( cd "$WORK" && bash "$QAVERIFY" genuine ) 2>&1 1>/dev/null )"
LEAK_AFTER="$(find "$TMP_BASE" -maxdepth 1 -name 'tmp.*' 2>/dev/null | sort)"
check "no leaked results_tmp: qa-verify exits 0 on a plain invocation" \
  "$( ( cd "$WORK" && bash "$QAVERIFY" genuine >/dev/null 2>&1 ); echo $? )" "0"
check "no unbound-variable stderr on a plain qa-verify invocation" \
  "$(grep -ci 'unbound variable' <<< "$STDERR_OUT")" "0"
check "no leaked mktemp results_tmp file after qa-verify exits" \
  "$([[ "$LEAK_BEFORE" == "$LEAK_AFTER" ]] && echo same || echo diff)" "same"

# ---------------------------------------------------------------------------
# Appendix A: verification.json is written atomically (temp-in-same-dir +
# rename), not streamed directly to the destination path. Assert (a) no
# `.tmp.$$` sibling is left behind next to verification.json after a run,
# and (b) the final file is well-formed JSON (a partial/torn write would
# fail to parse) — the closest black-box proxy for atomicity without
# instrumenting a mid-write kill.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$QAVERIFY" genuine >/dev/null 2>&1 )
RUN_DIR_TMP="$(dirname "$(vf genuine)")"
LEAKED_VF_TMP="$(find "$RUN_DIR_TMP" -maxdepth 1 -name 'verification.json.tmp.*' 2>/dev/null)"
check "no leaked verification.json.tmp.\$\$ sibling after a run" \
  "$([[ -z "$LEAKED_VF_TMP" ]] && echo none || echo "$LEAKED_VF_TMP")" "none"
check "verification.json parses as valid JSON after the atomic write" \
  "$(jq -e 'type' "$(vf genuine)" >/dev/null 2>&1 && echo valid || echo invalid)" "valid"

# ===========================================================================
# Appendix A: die()-in-subshell criterion loss. process_criterion is invoked
# inside `rec_json="$(process_criterion ...)"` — a die() anywhere in its call
# chain (e.g. required-kinds.sh derive crashing) only exits that SUBSHELL
# (qa-verify.sh runs under `set -uo pipefail`, no `-e`), so before the fix
# the criterion silently VANISHED from verification.json (empty rec_json,
# no error surfaced, exit code potentially still 0). Proven by poisoning a
# COPY of the whole scripts/+skills/ tree's required-kinds.sh (it's resolved
# via a hardcoded path relative to qa-verify.sh's own location, not PATH, so
# a PATH-based poison can't reach it) so the ONE criterion whose checklist
# row forces a required-kinds.sh derive call crashes deep inside
# process_criterion.
# ===========================================================================
ROOT="$(cd "$HERE/../.." && pwd)"
POISON_TREE="$WORK/poison-tree"
mkdir -p "$POISON_TREE"
cp -r "$ROOT/scripts" "$POISON_TREE/scripts"
cp -r "$ROOT/skills" "$POISON_TREE/skills"
cat > "$POISON_TREE/skills/checkpointing-qa-memory/scripts/required-kinds.sh" <<'EOF'
#!/usr/bin/env bash
echo "POISONED required-kinds.sh: simulated crash" >&2
exit 1
EOF
chmod +x "$POISON_TREE/skills/checkpointing-qa-memory/scripts/required-kinds.sh"
POISON_QAVERIFY="$POISON_TREE/scripts/qa-verify.sh"

( cd "$WORK" && bash "$TOOLSTREAM" append lostcrit '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"lc1"},"responseBody":"{\"anything\":1}"}' >/dev/null )
LC_REF2="$( cd "$WORK" && bash "$REC" lostcrit LC1 bake --read-back '{"anything":1}' --multiplicity 1 )"
( cd "$WORK" && bash "$CKPT" lostcrit LC1 pass --kinds bake --evidence-refs "$LC_REF2" >/dev/null )
write_checklist lostcrit '[{"id":"LC1","surface":"/x","kind":"happy-path","tags":[],"action":"View the list"}]'

( cd "$WORK" && bash "$POISON_QAVERIFY" lostcrit >"$WORK/lostcrit.stdout" 2>"$WORK/lostcrit.stderr" ); RC_LOST=$?
check "die()-in-subshell: qa-verify exits non-zero (never a silent clean exit)" "$([[ "$RC_LOST" -ne 0 ]] && echo yes)" "yes"
check "die()-in-subshell: verification.json still written" "$([[ -f "$(vf lostcrit)" ]] && echo yes)" "yes"
check "die()-in-subshell: exactly ONE record (the criterion, not vanished)" "$(jq 'length' "$(vf lostcrit)")" "1"
check "die()-in-subshell: the record is for LC1, not dropped" "$(jq -r '.[0].criterionId' "$(vf lostcrit)")" "LC1"
check "die()-in-subshell: verifierVerdict is error (not pass, not silently absent)" \
  "$(jq -r '.[0].verifierVerdict' "$(vf lostcrit)")" "error"
check "die()-in-subshell: confidence is high (this is a definite internal failure, not a judgment call)" \
  "$(jq -r '.[0].confidence' "$(vf lostcrit)")" "high"
check_contains "die()-in-subshell: reason names the internal failure, not silence" \
  "$(jq -r '.[0].reasons | join("; ")' "$(vf lostcrit)")" "internal error"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
