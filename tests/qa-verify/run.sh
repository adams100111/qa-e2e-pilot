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
# The leak assertion runs against a PRIVATE TMPDIR, created for this
# invocation only. It used to snapshot the whole shared `$TMPDIR` for
# `tmp.*`, which made it go red whenever any other process on the machine
# touched /tmp during the run — a flaky assertion inside a 47-suite gate is
# the thing teams learn to route around, so the fix is isolation, not a
# retry.
PRIVATE_TMP="$WORK/private-tmp"
mkdir -p "$PRIVATE_TMP"
STDERR_OUT="$( ( cd "$WORK" && TMPDIR="$PRIVATE_TMP" bash "$QAVERIFY" genuine ) 2>&1 1>/dev/null )"
LEAK_AFTER="$(find "$PRIVATE_TMP" -mindepth 1 2>/dev/null | sort)"
check "no leaked results_tmp: qa-verify exits 0 on a plain invocation" \
  "$( ( cd "$WORK" && TMPDIR="$PRIVATE_TMP" bash "$QAVERIFY" genuine >/dev/null 2>&1 ); echo $? )" "0"
check "no unbound-variable stderr on a plain qa-verify invocation" \
  "$(grep -ci 'unbound variable' <<< "$STDERR_OUT")" "0"
check "no temp file left in qa-verify's own TMPDIR after it exits" \
  "$([[ -z "$LEAK_AFTER" ]] && echo empty || echo "$LEAK_AFTER")" "empty"

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


# ===========================================================================
# TASK 8 (plan 2026-09-23-error-honesty-invariants, Lane K): the FOUR
# RUN-SCOPED CHECKS and the synthetic `__run-checks__` record.
#
# These fixtures live in their OWN work tree (WORK2/WORK3), deliberately
# separate from the $WORK tree above, for two reasons:
#   1. `.qa/known-defects.json` and `.qa/config.json` are PROJECT-level
#      (decision R16) — dropping either into $WORK would change the inputs
#      of every pre-existing fixture in this file at once.
#   2. The pre-existing fixtures are this suite's regression proof that the
#      run-scoped pass adds NO record when a run carries no findings
#      evidence at all (asserted explicitly at the end of this section).
#
# Every assertion below runs under BOTH engines, and a dedicated parity
# block compares stdout and stderr SEPARATELY (a merged 2>&1 comparison
# would pass a channel swap).
# ===========================================================================
JOURNAL="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
KD="$HERE/../../scripts/known-defects.sh"
MCP="mcp__plugin_playwright_playwright"

WORK2="$(mktemp -d)"
WORK3="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3"' EXIT

mkdir -p "$WORK2/.qa" "$WORK3/.qa"
printf '%s' '{"baseUrl":"https://app.test"}' > "$WORK2/.qa/config.json"
printf '%s' '{"baseUrl":"https://app.test"}' > "$WORK3/.qa/config.json"

vf2() { echo "$WORK2/.qa/runs/$1/verification.json"; }
vf3() { echo "$WORK3/.qa/runs/$1/verification.json"; }

ts_append() { # <root> <run> <tool> <responseBody-json-string>
  ( cd "$1" && bash "$TOOLSTREAM" append "$2" \
    "{\"tool\":\"$3\",\"args\":{},\"resultDigest\":{\"len\":0,\"sha256\":\"x\"},\"responseBody\":$4}" >/dev/null )
}
ts_append_args() { # <root> <run> <tool> <args-json> <responseBody-json-string>
  ( cd "$1" && bash "$TOOLSTREAM" append "$2" \
    "{\"tool\":\"$3\",\"args\":$4,\"resultDigest\":{\"len\":0,\"sha256\":\"x\"},\"responseBody\":$5}" >/dev/null )
}
jr_append() { # <root> <run> <event-json>
  ( cd "$1" && bash "$JOURNAL" append "$2" "$3" >/dev/null )
}
netlog() { # <root> <run> <raw-file-content>
  mkdir -p "$1/.qa/runs/$2"
  printf '%s' "$3" > "$1/.qa/runs/$2/network-log.json"
}
mk_ckpt() { # <root> <run> <crit>
  ( cd "$1" && bash "$CKPT" "$2" "$3" fail --last-action "recorded fail" >/dev/null )
}
# rc_field <verification.json> <jq-path-after-the-record>
rc_field() { jq -r ".[] | select(.criterionId==\"__run-checks__\") | $2" "$1"; }
rc_count() { jq '[.[] | select(.criterionId=="__run-checks__")] | length' "$1"; }

NAV="${MCP}__browser_navigate"
NETREQ="${MCP}__browser_network_requests"
SNAP="${MCP}__browser_snapshot"

FINDING_500='{"event":"finding_observed","criterionId":"EC10","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/dashboard","status":500,"originClass":"in-scope","statusClass":"fatal","message":"500 on the dashboard document request"}'

ts_reset() { rm -f "$1/.qa/runs/$2/toolstream.jsonl"; }

# --- nothing: a run with NO toolstream, NO journal findings, NO driver log
#     and NO registry. Every check that COULD run passes; the load-window
#     check could NOT run, and that must be stated rather than implied
#     (fix round 1, item 5). ------------------------------------------------
mk_ckpt "$WORK2" nothing EC0

# --- ledgerok: the driver log holds a 500 and the journal records it -------
ts_append "$WORK2" ledgerok "$NAV" '""'
ts_append "$WORK2" ledgerok "$NETREQ" '""'
netlog "$WORK2" ledgerok '[{"method":"GET","url":"https://app.test/dashboard","status":500,"type":"document"}]'
jr_append "$WORK2" ledgerok '{"event":"run_started"}'
jr_append "$WORK2" ledgerok "$FINDING_500"
mk_ckpt "$WORK2" ledgerok EC10

# --- ledgermiss (INCIDENT REGRESSION CASE 2): the driver log holds a
#     navigation 500, the journal omits it entirely. Every criterion in this
#     run is recorded `fail`, so the pre-existing pass-record loop visits
#     NOTHING — the exact shape in which EC10 shipped a verified 500. ------
ts_append "$WORK2" ledgermiss "$NAV" '""'
ts_append "$WORK2" ledgermiss "$NETREQ" '""'
netlog "$WORK2" ledgermiss '[{"method":"GET","url":"https://app.test/dashboard","status":500,"type":"document"}]'
jr_append "$WORK2" ledgermiss '{"event":"run_started"}'
mk_ckpt "$WORK2" ledgermiss EC10

# --- misclass: the journal calls a baseUrl-origin 500 `third-party` -------
jr_append "$WORK2" misclass '{"event":"finding_observed","criterionId":"EC10","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/broken","status":500,"originClass":"third-party","statusClass":"fatal","message":"claimed third-party"}'
mk_ckpt "$WORK2" misclass EC10

# --- misclassstatus: the journal calls a 500 `non-fatal` ------------------
jr_append "$WORK2" misclassstatus '{"event":"finding_observed","criterionId":"EC10","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/broken","status":500,"originClass":"in-scope","statusClass":"non-fatal","message":"claimed non-fatal"}'
mk_ckpt "$WORK2" misclassstatus EC10

# --- navnofollow (INCIDENT REGRESSION CASE 3): a browser_navigate with no
#     browser_network_requests before the NEXT navigation. -----------------
ts_append "$WORK2" navnofollow "$NAV" '""'
ts_append "$WORK2" navnofollow "$SNAP" '""'
ts_append "$WORK2" navnofollow "$NAV" '""'
ts_append "$WORK2" navnofollow "$NETREQ" '""'
mk_ckpt "$WORK2" navnofollow EC1

# --- navfollow: every navigation followed up ------------------------------
ts_append "$WORK2" navfollow "$NAV" '""'
ts_append "$WORK2" navfollow "$NETREQ" '""'
ts_append "$WORK2" navfollow "$NAV" '""'
ts_append "$WORK2" navfollow "$NETREQ" '""'
netlog "$WORK2" navfollow '[]'
mk_ckpt "$WORK2" navfollow EC1

# --- navtwo: the FIRST navigation is covered, the SECOND (and last) is not
ts_append "$WORK2" navtwo "$NAV" '""'
ts_append "$WORK2" navtwo "$NETREQ" '""'
ts_append "$WORK2" navtwo "$NAV" '""'
ts_append "$WORK2" navtwo "$SNAP" '""'
mk_ckpt "$WORK2" navtwo EC1

# --- nochannel: the journal claims a finding; NO independent channel
#     exists to confirm or contradict it. Absence must never fail a run. ---
jr_append "$WORK2" nochannel "$FINDING_500"
mk_ckpt "$WORK2" nochannel EC10

# --- consolemiss: channel 1 (in-page interception). An observe payload in
#     the toolstream carries a console error the journal never recorded. ---
ts_append "$WORK2" consolemiss "${MCP}__browser_evaluate" '"{\"round\":1,\"console\":[{\"level\":\"error\",\"text\":\"TypeError: p.map is not a function\"}],\"network\":[]}"'
jr_append "$WORK2" consolemiss '{"event":"run_started"}'
mk_ckpt "$WORK2" consolemiss EC2

# --- consoleok: the same payload, journaled ------------------------------
ts_append "$WORK2" consoleok "${MCP}__browser_evaluate" '"{\"round\":1,\"console\":[{\"level\":\"error\",\"text\":\"TypeError: p.map is not a function\"}],\"network\":[]}"'
jr_append "$WORK2" consoleok '{"event":"finding_observed","criterionId":"EC2","source":"console","channel":"toolstream","method":"","url":"","status":"unhandled-exception","originClass":"in-scope","statusClass":"fatal","message":"TypeError: p.map is not a function"}'
mk_ckpt "$WORK2" consoleok EC2

# --- observenet: an observe payload network row with an in-scope 500 the
#     journal omits (channel 1 carrying a fetch/XHR error). ---------------
ts_append "$WORK2" observenet "${MCP}__browser_evaluate" '"{\"round\":1,\"console\":[],\"network\":[{\"method\":\"POST\",\"url\":\"https://app.test/api/save\",\"status\":503,\"ok\":false}]}"'
jr_append "$WORK2" observenet '{"event":"run_started"}'
mk_ckpt "$WORK2" observenet EC3

# --- thirdparty: an out-of-origin 500 is NOT a required finding ----------
netlog "$WORK2" thirdparty '[{"method":"GET","url":"https://cdn.example.com/a.js","status":500}]'
jr_append "$WORK2" thirdparty '{"event":"run_started"}'
mk_ckpt "$WORK2" thirdparty EC4

# --- nonfatal: an in-scope 404 is recorded, never required (R1) ----------
netlog "$WORK2" nonfatal '[{"method":"GET","url":"https://app.test/missing","status":404}]'
jr_append "$WORK2" nonfatal '{"event":"run_started"}'
mk_ckpt "$WORK2" nonfatal EC5

# --- truncurl: the capping-invariant key. The driver log carries the FULL
#     url; the journal carries the 1024-char cap plus the full `urlLen`. --
LONG_URL="https://app.test/q?v=$(jq -rn '[range(0;1990)] | map("a") | join("")')"
LONG_LEN="${#LONG_URL}"
LONG_CAP="${LONG_URL:0:1024}"
netlog "$WORK2" truncurl "$(jq -cn --arg u "$LONG_URL" '[{method:"GET",url:$u,status:500}]')"
jr_append "$WORK2" truncurl "$(jq -cn --arg u "$LONG_CAP" --argjson n "$LONG_LEN" \
  '{event:"finding_observed",criterionId:"EC6",source:"network",channel:"driver-log",method:"GET",url:$u,urlLen:$n,status:500,originClass:"in-scope",statusClass:"fatal",message:"long url 500",detailRef:"evidence/EC6/findings/1.json"}')"
mk_ckpt "$WORK2" truncurl EC6

# --- prefixdup: ONE request seen by BOTH channels. observe.js:109 slices
#     every url it records to 300 characters and supplies no `urlLen`, so
#     the in-page record of a 400-character url is genuinely shorter than
#     the driver log's. The journal records it once, in the driver form.
#     Without net_prefix's 300-character fallback the observe row looks
#     like a dropped finding and the run is FALSELY overridden. -----------
DUP_URL="https://app.test/p?v=$(jq -rn '[range(0;379)] | map("b") | join("")')"
DUP_LEN="${#DUP_URL}"
DUP_SLICE="${DUP_URL:0:300}"
netlog "$WORK2" prefixdup "$(jq -cn --arg u "$DUP_URL" '[{method:"GET",url:$u,status:500}]')"
ts_append "$WORK2" prefixdup "${MCP}__browser_evaluate" \
  "$(jq -cn --arg u "$DUP_SLICE" '{round:1,console:[],network:[{method:"GET",url:$u,status:500,ok:false}]}' | jq -Rc .)"
jr_append "$WORK2" prefixdup "$(jq -cn --arg u "$DUP_URL" --argjson n "$DUP_LEN" \
  '{event:"finding_observed",criterionId:"EC11",source:"network",channel:"driver-log",method:"GET",url:$u,urlLen:$n,status:500,originClass:"in-scope",statusClass:"fatal",message:"one request, two channels"}')"
mk_ckpt "$WORK2" prefixdup EC11

# --- identsplit: two DRIVER-LOG urls that share their first 1024 characters
#     and differ only in total length. The journal records exactly one. The
#     other must be reported as dropped — which is only possible because
#     net_ident carries the full `urlLen` past the 1024-character cap, and
#     because the coarse 300-character fallback does NOT apply to a driver
#     row (the two urls share their first 300 characters too). -------------
SPLIT_HEAD="https://app.test/z?a=$(jq -rn '[range(0;1100)] | map("c") | join("")')"
SPLIT_A="${SPLIT_HEAD}TAILA"
SPLIT_B="${SPLIT_HEAD}TAILBB"
SPLIT_A_LEN="${#SPLIT_A}"
SPLIT_B_LEN="${#SPLIT_B}"
netlog "$WORK2" identsplit "$(jq -cn --arg a "$SPLIT_A" --arg b "$SPLIT_B" \
  '[{method:"GET",url:$a,status:500},{method:"GET",url:$b,status:500}]')"
jr_append "$WORK2" identsplit "$(jq -cn --arg u "${SPLIT_A:0:1024}" --argjson n "$SPLIT_A_LEN" \
  '{event:"finding_observed",criterionId:"EC12",source:"network",channel:"driver-log",method:"GET",url:$u,urlLen:$n,status:500,originClass:"in-scope",statusClass:"fatal",message:"only one of the two",detailRef:"evidence/EC12/findings/1.json"}')"
mk_ckpt "$WORK2" identsplit EC12

# --- malformed: one run dir whose network-log.json is rewritten per case --
jr_append "$WORK2" malformed '{"event":"run_started"}'
mk_ckpt "$WORK2" malformed EC7

# --- manyreasons: 120 distinct console errors, none journaled. The reason
#     list must be CAPPED: json_array_from_args passes every reason as a
#     positional argument, so an unbounded list eventually exceeds ARG_MAX,
#     the record builder fails and the whole run-scoped record is lost. The
#     booleans stay authoritative; only the prose is bounded. Console
#     findings are used on purpose — they need no classify-finding.sh
#     subprocess, so 120 of them cost nothing. ----------------------------
ts_append "$WORK2" manyreasons "${MCP}__browser_evaluate" \
  "$(jq -cn '{round:1,network:[],console:[range(0;120) | {level:"error",text:("TypeError: distinct failure number " + (.|tostring))}]}' | jq -Rc .)"
jr_append "$WORK2" manyreasons '{"event":"run_started"}'
mk_ckpt "$WORK2" manyreasons EC13

# --- badjournal: a torn line plus a usable finding_observed -------------
jr_append "$WORK2" badjournal '{"event":"run_started"}'
printf '%s\n' '{"event":"finding_observed","criterionId":"EC8","source":"netw' >> "$WORK2/.qa/runs/badjournal/journal.ndjson"
jr_append "$WORK2" badjournal '{"event":"finding_observed","criterionId":"EC8","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/broken","status":500,"originClass":"third-party","statusClass":"fatal","message":"survives the torn line"}'
mk_ckpt "$WORK2" badjournal EC8

# --- fieldless: finding_observed events with missing/empty/non-string
#     fields. None may crash the pass or manufacture an override. ---------
jr_append "$WORK2" fieldless '{"event":"finding_observed","criterionId":"EC9","source":"network"}'
jr_append "$WORK2" fieldless '{"event":"finding_observed","criterionId":"EC9","source":"network","url":"","status":"","originClass":"","statusClass":""}'
jr_append "$WORK2" fieldless '{"event":"finding_observed","criterionId":"EC9","source":"network","url":{"a":1},"status":[500],"originClass":false,"statusClass":null}'
jr_append "$WORK2" fieldless '{"event":"finding_observed","criterionId":"EC9","source":"network","url":"https://app.test/ok","status":204,"originClass":"in-scope","statusClass":"non-fatal"}'
mk_ckpt "$WORK2" fieldless EC9

run_qv2() { # <root> <engine> <run>
  ( cd "$1" && QA_ENGINE="$2" bash "$QAVERIFY" "$3" )
}

for ENGINE in jq python3; do
  LABEL="$ENGINE"

  # ---- FIX ROUND 1, ITEM 5: a check that did not run says so -------------
  run_qv2 "$WORK2" "$ENGINE" nothing >/dev/null 2>&1; RC=$?
  check "[$LABEL] item5: a run with no capture at all still exits 0" "$RC" "0"
  check "[$LABEL] item5: ... but it DOES get a __run-checks__ record (silence reads as 'nothing wrong')" \
    "$(rc_count "$(vf2 nothing)")" "1"
  check "[$LABEL] item5: loadWindowCovered is not-evaluated, NEVER true" \
    "$(rc_field "$(vf2 nothing)" '.runChecks.loadWindowCovered')" "not-evaluated"
  check "[$LABEL] item5: findingsChannel carries WHY" \
    "$(rc_field "$(vf2 nothing)" '.runChecks.findingsChannel')" "none"
  check "[$LABEL] item5: confidence degrades rather than claiming a verified run" \
    "$(rc_field "$(vf2 nothing)" '.confidence')" "low"
  check_contains "[$LABEL] item5: a reason names the unperformed check" \
    "$(rc_field "$(vf2 nothing)" '.reasons | join("; ")')" "load-window coverage: NOT EVALUATED"

  # ---- ledger completeness ------------------------------------------------
  run_qv2 "$WORK2" "$ENGINE" ledgerok >/dev/null 2>&1; RC=$?
  check "[$LABEL] ledgerok: exits 0" "$RC" "0"
  check "[$LABEL] ledgerok: a __run-checks__ record is written" "$(rc_count "$(vf2 ledgerok)")" "1"
  check "[$LABEL] ledgerok: ledgerComplete true" "$(rc_field "$(vf2 ledgerok)" '.runChecks.ledgerComplete')" "true"
  check "[$LABEL] ledgerok: classificationsAgree true" "$(rc_field "$(vf2 ledgerok)" '.runChecks.classificationsAgree')" "true"
  check "[$LABEL] ledgerok: loadWindowCovered true" "$(rc_field "$(vf2 ledgerok)" '.runChecks.loadWindowCovered')" "true"
  check "[$LABEL] ledgerok: knownDefectsOk true" "$(rc_field "$(vf2 ledgerok)" '.runChecks.knownDefectsOk')" "true"
  check "[$LABEL] ledgerok: verifierVerdict pass" "$(rc_field "$(vf2 ledgerok)" '.verifierVerdict')" "pass"
  check "[$LABEL] ledgerok: channel names the driver log" "$(rc_field "$(vf2 ledgerok)" '.channel')" "driver-log"

  run_qv2 "$WORK2" "$ENGINE" ledgermiss >/dev/null 2>&1; RC=$?
  check "[$LABEL] ledgermiss: exits non-zero (the run is overridden)" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] ledgermiss: ledgerComplete false" "$(rc_field "$(vf2 ledgermiss)" '.runChecks.ledgerComplete')" "false"
  check "[$LABEL] ledgermiss: verifierVerdict fail" "$(rc_field "$(vf2 ledgermiss)" '.verifierVerdict')" "fail"
  check_contains "[$LABEL] ledgermiss: the reason names the dropped url" \
    "$(rc_field "$(vf2 ledgermiss)" '.reasons | join("; ")')" "https://app.test/dashboard"
  check_contains "[$LABEL] ledgermiss: the reason names the status" \
    "$(rc_field "$(vf2 ledgermiss)" '.reasons | join("; ")')" "500"
  check "[$LABEL] ledgermiss: run-scoped — NO pass record was re-checked" \
    "$(jq '[.[] | select(.criterionId != "__run-checks__" and .criterionId != "__phase-surface__")] | length' "$(vf2 ledgermiss)")" "0"
  check "[$LABEL] ledgermiss: the other three checks stay true" \
    "$(rc_field "$(vf2 ledgermiss)" '[.runChecks.classificationsAgree,.runChecks.loadWindowCovered,.runChecks.knownDefectsOk] | join(",")')" "true,true,true"

  # ---- classification re-check --------------------------------------------
  run_qv2 "$WORK2" "$ENGINE" misclass >/dev/null 2>&1; RC=$?
  check "[$LABEL] misclass: exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] misclass: classificationsAgree false" "$(rc_field "$(vf2 misclass)" '.runChecks.classificationsAgree')" "false"
  check_contains "[$LABEL] misclass: the reason names the claimed class" \
    "$(rc_field "$(vf2 misclass)" '.reasons | join("; ")')" "third-party"
  check_contains "[$LABEL] misclass: the reason names the recomputed class" \
    "$(rc_field "$(vf2 misclass)" '.reasons | join("; ")')" "in-scope"
  check "[$LABEL] misclass: ledgerComplete unaffected (no channel to contradict)" \
    "$(rc_field "$(vf2 misclass)" '.runChecks.ledgerComplete')" "true"

  run_qv2 "$WORK2" "$ENGINE" misclassstatus >/dev/null 2>&1; RC=$?
  check "[$LABEL] misclassstatus: a 500 called non-fatal exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] misclassstatus: classificationsAgree false" \
    "$(rc_field "$(vf2 misclassstatus)" '.runChecks.classificationsAgree')" "false"
  check_contains "[$LABEL] misclassstatus: the reason names statusClass" \
    "$(rc_field "$(vf2 misclassstatus)" '.reasons | join("; ")')" "statusClass"

  # ---- load-window coverage ----------------------------------------------
  run_qv2 "$WORK2" "$ENGINE" navnofollow >/dev/null 2>&1; RC=$?
  check "[$LABEL] navnofollow: exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] navnofollow: loadWindowCovered false" "$(rc_field "$(vf2 navnofollow)" '.runChecks.loadWindowCovered')" "false"
  check_contains "[$LABEL] navnofollow: the reason names browser_navigate" \
    "$(rc_field "$(vf2 navnofollow)" '.reasons | join("; ")')" "browser_navigate"
  check_contains "[$LABEL] navnofollow: the reason names browser_network_requests" \
    "$(rc_field "$(vf2 navnofollow)" '.reasons | join("; ")')" "browser_network_requests"

  run_qv2 "$WORK2" "$ENGINE" navfollow >/dev/null 2>&1; RC=$?
  check "[$LABEL] navfollow: exits 0" "$RC" "0"
  check "[$LABEL] navfollow: loadWindowCovered true" "$(rc_field "$(vf2 navfollow)" '.runChecks.loadWindowCovered')" "true"

  run_qv2 "$WORK2" "$ENGINE" navtwo >/dev/null 2>&1; RC=$?
  check "[$LABEL] navtwo: the trailing uncovered navigation exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] navtwo: loadWindowCovered false" "$(rc_field "$(vf2 navtwo)" '.runChecks.loadWindowCovered')" "false"

  # ---- no evidence is not contradicted evidence --------------------------
  run_qv2 "$WORK2" "$ENGINE" nochannel >/dev/null 2>&1; RC=$?
  check "[$LABEL] nochannel: exits 0 (a missing capture never fails a run)" "$RC" "0"
  check "[$LABEL] nochannel: channel recorded as none" "$(rc_field "$(vf2 nochannel)" '.channel')" "none"
  check "[$LABEL] nochannel: ledgerComplete true" "$(rc_field "$(vf2 nochannel)" '.runChecks.ledgerComplete')" "true"
  check "[$LABEL] nochannel: confidence degrades rather than overriding" \
    "$(rc_field "$(vf2 nochannel)" '.confidence')" "low"
  check_contains "[$LABEL] nochannel: a reason records the absence" \
    "$(rc_field "$(vf2 nochannel)" '.reasons | join("; ")')" "no independent"

  # ---- console channel ----------------------------------------------------
  run_qv2 "$WORK2" "$ENGINE" consolemiss >/dev/null 2>&1; RC=$?
  check "[$LABEL] consolemiss: exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] consolemiss: ledgerComplete false" "$(rc_field "$(vf2 consolemiss)" '.runChecks.ledgerComplete')" "false"
  check_contains "[$LABEL] consolemiss: the reason names the console message" \
    "$(rc_field "$(vf2 consolemiss)" '.reasons | join("; ")')" "p.map is not a function"
  check "[$LABEL] consolemiss: channel names the toolstream" "$(rc_field "$(vf2 consolemiss)" '.channel')" "toolstream"

  run_qv2 "$WORK2" "$ENGINE" consoleok >/dev/null 2>&1; RC=$?
  check "[$LABEL] consoleok: exits 0" "$RC" "0"
  check "[$LABEL] consoleok: ledgerComplete true" "$(rc_field "$(vf2 consoleok)" '.runChecks.ledgerComplete')" "true"
  check "[$LABEL] consoleok: classificationsAgree true" "$(rc_field "$(vf2 consoleok)" '.runChecks.classificationsAgree')" "true"

  run_qv2 "$WORK2" "$ENGINE" observenet >/dev/null 2>&1; RC=$?
  check "[$LABEL] observenet: an omitted in-page 503 exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] observenet: ledgerComplete false" "$(rc_field "$(vf2 observenet)" '.runChecks.ledgerComplete')" "false"
  check_contains "[$LABEL] observenet: the reason names the method" \
    "$(rc_field "$(vf2 observenet)" '.reasons | join("; ")')" "POST"

  # ---- the classifier decides scope, not this pass -----------------------
  run_qv2 "$WORK2" "$ENGINE" thirdparty >/dev/null 2>&1; RC=$?
  check "[$LABEL] thirdparty: a foreign-origin 500 never requires a journal entry" "$RC" "0"
  check "[$LABEL] thirdparty: ledgerComplete true" "$(rc_field "$(vf2 thirdparty)" '.runChecks.ledgerComplete')" "true"

  run_qv2 "$WORK2" "$ENGINE" nonfatal >/dev/null 2>&1; RC=$?
  check "[$LABEL] nonfatal: an in-scope 404 never requires a journal entry (R1)" "$RC" "0"
  check "[$LABEL] nonfatal: ledgerComplete true" "$(rc_field "$(vf2 nonfatal)" '.runChecks.ledgerComplete')" "true"

  # ---- capping-invariant key --------------------------------------------
  run_qv2 "$WORK2" "$ENGINE" truncurl >/dev/null 2>&1; RC=$?
  check "[$LABEL] truncurl: a capped journal url still matches the full driver url" "$RC" "0"
  check "[$LABEL] truncurl: ledgerComplete true" "$(rc_field "$(vf2 truncurl)" '.runChecks.ledgerComplete')" "true"
  check "[$LABEL] truncurl: classificationsAgree true (statusClass still re-checked)" \
    "$(rc_field "$(vf2 truncurl)" '.runChecks.classificationsAgree')" "true"
  check_contains "[$LABEL] truncurl: a reason records the un-re-classifiable origin" \
    "$(rc_field "$(vf2 truncurl)" '.reasons | join("; ")')" "truncated"

  # ---- one request, two channels, one journal entry ---------------------
  run_qv2 "$WORK2" "$ENGINE" prefixdup >/dev/null 2>&1; RC=$?
  check "[$LABEL] prefixdup: a 300-char in-page slice of a journaled url is NOT a dropped finding" "$RC" "0"
  check "[$LABEL] prefixdup: ledgerComplete true" "$(rc_field "$(vf2 prefixdup)" '.runChecks.ledgerComplete')" "true"
  check "[$LABEL] prefixdup: both channels were seen" "$(rc_field "$(vf2 prefixdup)" '.channel')" "both"

  # ---- the cap marker must still separate two near-identical long urls ---
  run_qv2 "$WORK2" "$ENGINE" identsplit >/dev/null 2>&1; RC=$?
  check "[$LABEL] identsplit: the un-journaled twin of a capped url is still reported" \
    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] identsplit: ledgerComplete false" "$(rc_field "$(vf2 identsplit)" '.runChecks.ledgerComplete')" "false"
  check_contains "[$LABEL] identsplit: the reason carries the distinguishing full length" \
    "$(rc_field "$(vf2 identsplit)" '.reasons | join("; ")')" "$SPLIT_B_LEN"
  check "[$LABEL] identsplit: exactly ONE finding is reported missing, not both" \
    "$(rc_field "$(vf2 identsplit)" '[.reasons[] | select(startswith("ledger completeness: an observed finding is absent"))] | length')" "1"

  # ---- item 5, the three load-window states, once their runs have executed
  check "[$LABEL] item5: a toolstream with tools but no navigation is EVALUATED and covered" \
    "$(rc_field "$(vf2 consolemiss)" '.runChecks.loadWindowCovered')" "true"
  check "[$LABEL] item5: a run with no toolstream reports not-evaluated, not covered" \
    "$(rc_field "$(vf2 nochannel)" '.runChecks.loadWindowCovered')" "not-evaluated"
  check "[$LABEL] item5: a violated load window is still plainly false" \
    "$(rc_field "$(vf2 navnofollow)" '.runChecks.loadWindowCovered')" "false"

  # ---- malformed network logs: no evidence, never an override -----------
  for BAD in '{"not":"an array"}' 'null' 'false' '[1,2,3]' '' '{"a":1}
{"b":2}' '[{"method":"GET"}]' '[{"url":"https://app.test/x","status":"500"}]' 'not json at all' \
    '[{"method":"GET","url":"","status":500}]' '[{"method":"GET","url":"https://app.test/x","status":500.5}]' \
    '[{"method":"GET","url":"https://app.test/x","status":true}]' '[null,false,"x",3]'; do
    netlog "$WORK2" malformed "$BAD"
    run_qv2 "$WORK2" "$ENGINE" malformed >/dev/null 2>&1; RC=$?
    check "[$LABEL] malformed network log never fails the run: $(printf '%s' "$BAD" | tr '\n' ' ' | cut -c1-28)" "$RC" "0"
    check "[$LABEL] malformed network log keeps ledgerComplete true: $(printf '%s' "$BAD" | tr '\n' ' ' | cut -c1-28)" \
      "$(rc_field "$(vf2 malformed)" '.runChecks.ledgerComplete')" "true"
  done
  netlog "$WORK2" malformed '[{"method":"GET","url":"https://app.test/dashboard","status":500}]'
  run_qv2 "$WORK2" "$ENGINE" malformed >/dev/null 2>&1; RC=$?
  check "[$LABEL] malformed control: a WELL-FORMED log with the same 500 DOES fail the run" \
    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"

  # ---- the reason list is bounded ---------------------------------------
  run_qv2 "$WORK2" "$ENGINE" manyreasons >/dev/null 2>&1; RC=$?
  check "[$LABEL] manyreasons: 120 dropped console errors still exit non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] manyreasons: ledgerComplete false" "$(rc_field "$(vf2 manyreasons)" '.runChecks.ledgerComplete')" "false"
  check "[$LABEL] manyreasons: the reason list is capped at 100 plus one truncation notice" \
    "$(rc_field "$(vf2 manyreasons)" '.reasons | length')" "101"
  check_contains "[$LABEL] manyreasons: the last reason says the list was truncated" \
    "$(rc_field "$(vf2 manyreasons)" '.reasons[-1]')" "truncated at 100 entries"

  # ---- malformed journal -------------------------------------------------
  run_qv2 "$WORK2" "$ENGINE" badjournal >/dev/null 2>&1; RC=$?
  check "[$LABEL] badjournal: a torn line does not hide the misclassified finding after it" \
    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] badjournal: classificationsAgree false" \
    "$(rc_field "$(vf2 badjournal)" '.runChecks.classificationsAgree')" "false"

  run_qv2 "$WORK2" "$ENGINE" fieldless >/dev/null 2>&1; RC=$?
  check "[$LABEL] fieldless: missing/empty/non-string finding fields never fail the run" "$RC" "0"
  check "[$LABEL] fieldless: classificationsAgree true" \
    "$(rc_field "$(vf2 fieldless)" '.runChecks.classificationsAgree')" "true"
  check "[$LABEL] fieldless: verification.json still parses" \
    "$(jq -e 'type' "$(vf2 fieldless)" >/dev/null 2>&1 && echo valid || echo invalid)" "valid"
done

# ---------------------------------------------------------------------------
# DUAL-ENGINE PARITY — every fixture through BOTH engines, stdout and stderr
# compared SEPARATELY. A merged `2>&1` comparison would pass a channel swap.
# ---------------------------------------------------------------------------
for R in ledgerok ledgermiss misclass misclassstatus navnofollow navfollow navtwo \
         nochannel consolemiss consoleok observenet thirdparty nonfatal truncurl \
         prefixdup identsplit manyreasons badjournal fieldless; do
  ( cd "$WORK2" && QA_ENGINE=jq      bash "$QAVERIFY" "$R" >"$WORK2/p.jq.out" 2>"$WORK2/p.jq.err" ); PRC_JQ=$?
  cp "$(vf2 "$R")" "$WORK2/p.jq.json"
  ( cd "$WORK2" && QA_ENGINE=python3 bash "$QAVERIFY" "$R" >"$WORK2/p.py.out" 2>"$WORK2/p.py.err" ); PRC_PY=$?
  cp "$(vf2 "$R")" "$WORK2/p.py.json"
  check "parity[$R]: exit codes agree" "$PRC_JQ" "$PRC_PY"
  check "parity[$R]: STDOUT agrees" \
    "$(cmp -s "$WORK2/p.jq.out" "$WORK2/p.py.out" && echo same || echo diff)" "same"
  check "parity[$R]: STDERR agrees" \
    "$(cmp -s "$WORK2/p.jq.err" "$WORK2/p.py.err" && echo same || echo diff)" "same"
  check "parity[$R]: the __run-checks__ record agrees" \
    "$(jq -S -c '[.[] | select(.criterionId=="__run-checks__")]' "$WORK2/p.jq.json")" \
    "$(jq -S -c '[.[] | select(.criterionId=="__run-checks__")]' "$WORK2/p.py.json")"
done

# ---------------------------------------------------------------------------
# KNOWN-DEFECT GATE — its own project tree, because the registry is
# PROJECT-level (R16) and rewriting it changes every run at once.
# ---------------------------------------------------------------------------
kd_write() { printf '%s' "$1" > "$WORK3/.qa/known-defects.json"; }
OUTSTANDING_EXPIRY="$(jq -rn '(now + 30*86400) | strftime("%Y-%m-%d")')"

jr_append "$WORK3" kdrun '{"event":"run_started"}'
mk_ckpt "$WORK3" kdrun EC1

kd_entry() { # <expiry>
  jq -cn --arg e "$1" '[{id:"KD-1",title:"Dashboard 500",ticket:"JIRA-1",expiry:$e,
    severity:"high",observedClass:"non-rendering",surface:"/dashboard",
    observedBehaviour:"the dashboard document request returns 500"}]'
}

for ENGINE in jq python3; do
  LABEL="$ENGINE"

  kd_write "$(kd_entry 2020-01-01)"
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd expired: exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] kd expired: knownDefectsOk false" "$(rc_field "$(vf3 kdrun)" '.runChecks.knownDefectsOk')" "false"
  check "[$LABEL] kd expired: the state is reported" "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "expired"
  check_contains "[$LABEL] kd expired: the reason names the entry id" \
    "$(rc_field "$(vf3 kdrun)" '.reasons | join("; ")')" "KD-1"

  kd_write "$(kd_entry "$OUTSTANDING_EXPIRY")"
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd outstanding: exits 0" "$RC" "0"
  check "[$LABEL] kd outstanding: knownDefectsOk true" "$(rc_field "$(vf3 kdrun)" '.runChecks.knownDefectsOk')" "true"
  check "[$LABEL] kd outstanding: the state is reported" "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"

  # validate failure: a missing `ticket`
  kd_write '[{"id":"KD-2","title":"t","expiry":"2026-11-01","severity":"high","observedClass":"non-rendering","surface":"/d","observedBehaviour":"b"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd invalid: exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] kd invalid: knownDefectsOk false" "$(rc_field "$(vf3 kdrun)" '.runChecks.knownDefectsOk')" "false"
  check_contains "[$LABEL] kd invalid: the reason carries the validator line" \
    "$(rc_field "$(vf3 kdrun)" '.reasons | join("; ")')" "entry[0]"

  # a non-array container is exit 2 from known-defects.sh, not a silent pass
  kd_write '{}'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd non-array container: exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] kd non-array container: knownDefectsOk false" \
    "$(rc_field "$(vf3 kdrun)" '.runChecks.knownDefectsOk')" "false"

  # ---- EVIDENCE CONTRACT: urls must be ABSOLUTE to clear anything -------
  kd_write "$(kd_entry "$OUTSTANDING_EXPIRY")"
  netlog "$WORK3" kdrun '[{"method":"GET","url":"dashboard","status":200,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd evidence: a RELATIVE navigation url never clears an entry" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
  check "[$LABEL] kd evidence: a relative url still exits 0" "$RC" "0"

  netlog "$WORK3" kdrun '[{"method":"GET","url":"https://app.test/dashboard","status":200}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd evidence: a 2xx row with NO resource type is not a navigation and never clears" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"

  netlog "$WORK3" kdrun '[{"method":"GET","url":"https://app.test/dashboard","status":200,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd evidence: an ABSOLUTE 2xx navigation to the surface clears it" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "cleared"
  check "[$LABEL] kd evidence: a cleared entry exits 0" "$RC" "0"

  # a fatal finding on the same surface blocks clearing
  jr_append "$WORK3" kdrun '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"driver-log","method":"GET","url":"https://app.test/dashboard","status":500,"originClass":"in-scope","statusClass":"fatal","message":"still broken"}'
  netlog "$WORK3" kdrun '[{"method":"GET","url":"https://app.test/dashboard","status":200,"type":"document"},{"method":"GET","url":"https://app.test/dashboard","status":500,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] kd evidence: a fatal finding on the surface blocks clearing" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
  # ======================= FIX ROUND 1, CRITICAL 1 =======================
  # A fatal finding with NO USABLE URL must BLOCK clearing. known-defects.sh
  # has that guard (`:293-297`, py `:495-498`) and this script is its ONLY
  # producer, so dropping url-less findings made the guard unreachable: a
  # `page-crash` on the defect's own surface used to declare it FIXED.
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"driver-log","method":"GET","url":"","status":"page-crash","originClass":"in-scope","statusClass":"fatal","message":"renderer crashed on the dashboard"}'
  netlog "$WORK3" kdrun '[{"method":"GET","url":"https://app.test/dashboard","status":200,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] C1: a url-less FATAL finding blocks clearing (page-crash on the surface)" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"

  # ... and it must do so from the COMPUTED statusClass, so omitting the
  # field entirely is not a way to unblock clearing either.
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"driver-log","method":"GET","url":"","status":"page-crash","message":"crash with no statusClass claimed"}'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] C1: omitting statusClass does NOT unblock clearing (computed value wins)" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"

  # A url-less NON-fatal finding is not a blocker — the guard must not
  # over-reach into "any url-less finding blocks everything".
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"finding_observed","criterionId":"EC1","source":"console","channel":"toolstream","method":"","url":"","status":"","originClass":"in-scope","statusClass":"non-fatal","message":"a mere warning"}'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] C1 control: a url-less NON-fatal finding still allows clearing" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "cleared"

  # ======================= FIX ROUND 1, CRITICAL 2 =======================
  # Clearing evidence must be ORIGIN-SCOPED. rawpath() strips scheme and
  # host, so without a baseUrl filter a 2xx from any origin cleared an
  # in-scope defect.
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"run_started"}'
  netlog "$WORK3" kdrun '[{"method":"GET","url":"https://other.test/dashboard","status":200,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] C2: a THIRD-PARTY 2xx does not clear an in-scope defect" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
  check "[$LABEL] C2: a third-party nav still exits 0" "$RC" "0"

  # The malformed/edge origin space. NONE of these may clear.
  for BADNAV in 'dashboard' '/dashboard' 'about:blank' 'data:text/html,%3Cp%3Ex' \
                'https://app.test:8443/dashboard' 'http://app.test/dashboard' \
                '//app.test/dashboard' 'https://app.test.evil.com/dashboard' \
                'https://APP.TEST.evil/dashboard' ''; do
    netlog "$WORK3" kdrun "$(jq -cn --arg u "$BADNAV" '[{method:"GET",url:$u,status:200,type:"document"}]')"
    run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
    check "[$LABEL] C2 origin space: '$BADNAV' never clears" \
      "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
    check "[$LABEL] C2 origin space: '$BADNAV' still exits 0" "$RC" "0"
  done

  # Default-port normalization is the classifier's job and must still clear:
  # baseUrl https://app.test and https://app.test:443 are ONE origin.
  netlog "$WORK3" kdrun '[{"method":"GET","url":"https://app.test:443/dashboard","status":200,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] C2: an explicit DEFAULT port is the same origin and still clears" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "cleared"

  # Case-insensitive host: HTTPS://APP.TEST is the same origin.
  netlog "$WORK3" kdrun '[{"method":"GET","url":"HTTPS://APP.TEST/dashboard","status":200,"type":"document"}]'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] C2: a differently-cased same origin still clears" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "cleared"

  # ======================== FIX ROUND 1, ITEM 6 ==========================
  # Clearing must be REACHABLE. Only driver_rows can report a resource type
  # and nothing writes a HAR, so `navigations` used to be always empty and
  # no entry could ever clear — the registry was a one-way ratchet whose
  # only exit was renewal. A browser_network_requests result paired with the
  # url the run actually navigated to is a document request, inferred from
  # the capture hook`s own record rather than faked.
  #
  # The matrix the coordinator asked for: same-origin AND 2xx AND matching
  # the surface clears; getting any one of the three wrong must not.
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"run_started"}'
  rm -f "$WORK3/.qa/runs/kdrun/network-log.json"

  # (a) all three right -> CLEARS, from the toolstream channel alone.
  ts_reset "$WORK3" kdrun
  ts_append_args "$WORK3" kdrun "$NAV" '{"url":"https://app.test/dashboard"}' '""'
  ts_append "$WORK3" kdrun "$NETREQ" '"[{\"method\":\"GET\",\"url\":\"https://app.test/dashboard\",\"status\":200}]"'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1; RC=$?
  check "[$LABEL] item6: a toolstream-sourced same-origin 2xx to the surface CLEARS" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "cleared"
  check "[$LABEL] item6: navigationsChannel names the toolstream" \
    "$(rc_field "$(vf3 kdrun)" '.runChecks.navigationsChannel')" "toolstream"
  check "[$LABEL] item6: clearing exits 0" "$RC" "0"

  # (b) wrong ORIGIN -> does not clear, and no navigation is admitted.
  ts_reset "$WORK3" kdrun
  ts_append_args "$WORK3" kdrun "$NAV" '{"url":"https://other.test/dashboard"}' '""'
  ts_append "$WORK3" kdrun "$NETREQ" '"[{\"method\":\"GET\",\"url\":\"https://other.test/dashboard\",\"status\":200}]"'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1
  check "[$LABEL] item6: wrong origin does not clear" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
  check "[$LABEL] item6: wrong origin admits no navigation at all" \
    "$(rc_field "$(vf3 kdrun)" '.runChecks.navigationsChannel')" "none"

  # (c) wrong STATUS -> admitted as a navigation, but 2xx is known-defects.sh's
  #     requirement and a 500 is not positive evidence of anything.
  ts_reset "$WORK3" kdrun
  ts_append_args "$WORK3" kdrun "$NAV" '{"url":"https://app.test/dashboard"}' '""'
  ts_append "$WORK3" kdrun "$NETREQ" '"[{\"method\":\"GET\",\"url\":\"https://app.test/dashboard\",\"status\":500}]"'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1
  check "[$LABEL] item6: a 500 document navigation does not clear" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"

  # (d) wrong SURFACE -> a real same-origin 2xx navigation, to somewhere else.
  ts_reset "$WORK3" kdrun
  ts_append_args "$WORK3" kdrun "$NAV" '{"url":"https://app.test/settings"}' '""'
  ts_append "$WORK3" kdrun "$NETREQ" '"[{\"method\":\"GET\",\"url\":\"https://app.test/settings\",\"status\":200}]"'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1
  check "[$LABEL] item6: a 2xx to a DIFFERENT surface does not clear" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
  check "[$LABEL] item6: ... but the navigation itself was still admitted" \
    "$(rc_field "$(vf3 kdrun)" '.runChecks.navigationsChannel')" "toolstream"

  # (e) a request that matches NO navigate argument and carries no resource
  #     type is still not a navigation — the inference must not widen into
  #     "every 2xx is a document".
  ts_reset "$WORK3" kdrun
  ts_append "$WORK3" kdrun "$NETREQ" '"[{\"method\":\"GET\",\"url\":\"https://app.test/dashboard\",\"status\":200}]"'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1
  check "[$LABEL] item6: an unnavigated same-origin 2xx is NOT a document navigation" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "outstanding"
  check "[$LABEL] item6: ... and navigationsChannel says none, visibly" \
    "$(rc_field "$(vf3 kdrun)" '.runChecks.navigationsChannel')" "none"
  check_contains "[$LABEL] item6: a reason explains why nothing could clear" \
    "$(rc_field "$(vf3 kdrun)" '.reasons | join("; ")')" "no admissible document navigation"

  # (f) BOTH directions in one run: the surface clears while a fatal finding
  #     elsewhere does not block it.
  ts_reset "$WORK3" kdrun
  ts_append_args "$WORK3" kdrun "$NAV" '{"url":"https://app.test/dashboard"}' '""'
  ts_append "$WORK3" kdrun "$NETREQ" '"[{\"method\":\"GET\",\"url\":\"https://app.test/dashboard\",\"status\":200}]"'
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"finding_observed","criterionId":"EC1","source":"network","channel":"toolstream","method":"GET","url":"https://app.test/settings","status":500,"originClass":"in-scope","statusClass":"fatal","message":"broken elsewhere"}'
  run_qv2 "$WORK3" "$ENGINE" kdrun >/dev/null 2>&1
  check "[$LABEL] item6: a fatal finding on ANOTHER surface does not block clearing" \
    "$(rc_field "$(vf3 kdrun)" '.knownDefects[0].state')" "cleared"

  # reset for the next engine iteration
  ts_reset "$WORK3" kdrun
  rm -f "$WORK3/.qa/runs/kdrun/journal.ndjson"
  jr_append "$WORK3" kdrun '{"event":"run_started"}'
  rm -f "$WORK3/.qa/runs/kdrun/network-log.json"
done
rm -f "$WORK3/.qa/known-defects.json"

# ---------------------------------------------------------------------------
# FIX ROUND 1, CRITICAL 2 — the other half: when ORIGIN COMPARISON IS NOT
# RUNNING at all (no usable `.baseUrl`), classify-finding.sh is fail-closed
# for findings and answers `in-scope` for EVERY url, including a foreign one.
# Accepting that verbatim would let any 2xx clear a defect. Its own project
# tree, because `.qa/config.json` is project-level.
# ---------------------------------------------------------------------------
WORK4="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4"' EXIT
mkdir -p "$WORK4/.qa"
printf '%s' '{}' > "$WORK4/.qa/config.json"
printf '%s' "$(kd_entry "$OUTSTANDING_EXPIRY")" > "$WORK4/.qa/known-defects.json"
jr_append "$WORK4" nobase '{"event":"run_started"}'
mk_ckpt "$WORK4" nobase EC1
netlog "$WORK4" nobase '[{"method":"GET","url":"https://anything.test/dashboard","status":200,"type":"document"}]'
vf4() { echo "$WORK4/.qa/runs/$1/verification.json"; }
for ENGINE in jq python3; do
  run_qv2 "$WORK4" "$ENGINE" nobase >/dev/null 2>&1; RC=$?
  check "[$ENGINE] C2: with no usable baseUrl, NO navigation is admitted as clearing evidence" \
    "$(rc_field "$(vf4 nobase)" '.knownDefects[0].state')" "outstanding"
  check "[$ENGINE] C2: the reason says origin comparison was unavailable" \
    "$(rc_field "$(vf4 nobase)" '[.reasons[] | select(contains("origin comparison is not available"))] | length')" "1"
  check "[$ENGINE] C2: an unavailable origin comparison still exits 0" "$RC" "0"
done

# ---------------------------------------------------------------------------
# FIX ROUND 1, ITEM 3 — `runChecks.findingsChannel` is a ratified interface:
# exactly one of toolstream | driver-log | none, and never `both`.
# ---------------------------------------------------------------------------
for ENGINE in jq python3; do
  run_qv2 "$WORK2" "$ENGINE" ledgerok >/dev/null 2>&1
  check "[$ENGINE] findingsChannel: a driver log alone reports driver-log" \
    "$(rc_field "$(vf2 ledgerok)" '.runChecks.findingsChannel')" "driver-log"
  run_qv2 "$WORK2" "$ENGINE" consolemiss >/dev/null 2>&1
  check "[$ENGINE] findingsChannel: an __qaObserve payload alone reports toolstream" \
    "$(rc_field "$(vf2 consolemiss)" '.runChecks.findingsChannel')" "toolstream"
  run_qv2 "$WORK2" "$ENGINE" nochannel >/dev/null 2>&1
  check "[$ENGINE] findingsChannel: no channel reports none" \
    "$(rc_field "$(vf2 nochannel)" '.runChecks.findingsChannel')" "none"
  run_qv2 "$WORK2" "$ENGINE" prefixdup >/dev/null 2>&1
  check "[$ENGINE] findingsChannel: BOTH channels collapse to driver-log, never 'both'" \
    "$(rc_field "$(vf2 prefixdup)" '.runChecks.findingsChannel')" "driver-log"
  check "[$ENGINE] findingsChannel: the richer channel field may still say both" \
    "$(rc_field "$(vf2 prefixdup)" '.channel')" "both"
  check "[$ENGINE] findingsChannel: the value is always one of the three ratified strings" \
    "$(for R in ledgerok consolemiss nochannel prefixdup; do rc_field "$(vf2 $R)" '.runChecks.findingsChannel'; done | sort -u | grep -cvE '^(toolstream|driver-log|none)$')" "0"
done

# ---------------------------------------------------------------------------
# FAIL-CLOSED CLASSIFIER. classify-finding.sh is resolved by a path relative
# to qa-verify.sh's own location, so it is poisoned the same way this suite
# already poisons required-kinds.sh: in a COPY of the scripts/+skills/ tree.
# `thirdparty` is the fixture whose only observation is a FOREIGN-origin 500
# — unpoisoned it exits 0 (the classifier said third-party, so nothing was
# required), and with the classifier unable to answer it must fail CLOSED
# (in-scope + fatal, i.e. required, i.e. absent from the journal, i.e. an
# override), not fall open to a clean run. The direction is the whole point:
# a gate that cannot classify must not therefore pass.
# ---------------------------------------------------------------------------
POISON2="$WORK2/poison-classify"
mkdir -p "$POISON2"
cp -R "$ROOT/scripts" "$POISON2/scripts"
cp -R "$ROOT/skills" "$POISON2/skills"
cat > "$POISON2/scripts/classify-finding.sh" <<'POISONEOF'
#!/usr/bin/env bash
echo "POISONED classify-finding.sh: simulated crash" >&2
exit 2
POISONEOF
chmod +x "$POISON2/scripts/classify-finding.sh"

for ENGINE in jq python3; do
  ( cd "$WORK2" && QA_ENGINE="$ENGINE" bash "$QAVERIFY" thirdparty >/dev/null 2>&1 )
  check "[$ENGINE] fail-closed control: a third-party 500 exits 0 with a WORKING classifier" "$?" "0"
  ( cd "$WORK2" && QA_ENGINE="$ENGINE" bash "$POISON2/scripts/qa-verify.sh" thirdparty >/dev/null 2>&1 )
  RC=$?
  check "[$ENGINE] fail-closed: an unusable classifier exits NON-zero, never open" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$ENGINE] fail-closed: ledgerComplete false" \
    "$(rc_field "$(vf2 thirdparty)" '.runChecks.ledgerComplete')" "false"
  check_contains "[$ENGINE] fail-closed: the reason says so explicitly" \
    "$(rc_field "$(vf2 thirdparty)" '.reasons | join("; ")')" "failing closed"
done
# leave `thirdparty` in its unpoisoned state for anything after this point
( cd "$WORK2" && bash "$QAVERIFY" thirdparty >/dev/null 2>&1 )

# ---------------------------------------------------------------------------
# REGRESSION: a run with NO findings evidence at all gains NO record. This is
# what keeps every pre-existing fixture in this file byte-identical.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$QAVERIFY" genuine >/dev/null 2>&1 )
check "existing cases unchanged: genuine still has exactly 3 records" "$(jq 'length' "$(vf genuine)")" "3"
check "existing cases unchanged: genuine has no __run-checks__ record" "$(rc_count "$(vf genuine)")" "0"
( cd "$WORK" && bash "$QAVERIFY" forged >/dev/null 2>&1 )
check "existing cases unchanged: forged still has exactly 4 records" "$(jq 'length' "$(vf forged)")" "4"
check "existing cases unchanged: forged has no __run-checks__ record" "$(rc_count "$(vf forged)")" "0"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
