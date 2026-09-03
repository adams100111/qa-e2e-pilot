#!/usr/bin/env bash
# Tests for the persona-identity binding fast-follow (Plan H3 Task 1,
# honesty gap #6, docs/superpowers/plans/2026-09-03-honesty-fast-follows.md
# + .superpowers/sdd/task-1-brief.md).
#
# Two surfaces under test:
#   1. `record-evidence.sh identity` — writes evidence/<persona>/identity.json
#      = {persona, capturedSubject, method, recorded_at}. Requires --persona
#      (identity is per-persona, not per-criterion); validates --method is
#      one of whoami|storageState|none.
#   2. `qa-verify.sh` — for a `pass` on a PERSONA-SCOPED HIGH-STAKES
#      criterion (kinds contains human-action, OR the checklist.json row is
#      tagged cross-tenant/cross-role-fk-chain), reads that identity.json:
#        - captured subject CONFIDENTLY mismatches the persona -> OVERRIDE
#          to fail, exit non-zero, reason names both identities.
#        - matching subject -> verified, no change.
#        - absent, or method:none, or an ambiguous (email/UUID-shaped)
#          subject with no configured expectedSubject -> confidence:low
#          (DEGRADE, never an override), exit 0.
#        - __shared__/empty-persona/non-high-stakes (read-only) passes ->
#          identity NOT checked at all, even if a mismatching identity.json
#          happens to exist.
#      `.qa/config.json`'s `personas[].expectedSubject` (v1 mapping) is
#      authoritative over the bare persona-id comparison when configured.
#
# Every assertion runs under BOTH jq (default) and QA_ENGINE=python3 —
# record-evidence.sh auto-detects (has_jq/has_py), so its python3 path is
# exercised by hiding jq from PATH instead; qa-verify.sh honors QA_ENGINE
# directly (same contract as tests/qa-verify/run.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REC="$HERE/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
CKPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
QAVERIFY="$HERE/../../scripts/qa-verify.sh"
TOOLSTREAM="$HERE/../../scripts/toolstream.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' does not contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A fake PATH holding ONLY the exact external tools record-evidence.sh needs
# (date, mkdir, cat, python3) so `command -v jq` fails and has_py() succeeds
# — same idiom as tests/checkpoint/run.sh's Case 7. Deliberately excludes jq.
BASH_ABS="$(command -v bash)"
FAKEBIN="$WORK/pybin"
mkdir -p "$FAKEBIN"
for tool in date mkdir cat python3; do
  ln -sf "$(command -v "$tool")" "$FAKEBIN/$tool"
done

write_checklist() { # <run> <json>
  mkdir -p "$WORK/.qa/runs/$1"
  printf '%s' "$2" > "$WORK/.qa/runs/$1/checklist.json"
}
vf() { echo "$WORK/.qa/runs/$1/verification.json"; }

run_qv() { # <engine: "" | python3> <run>
  local engine="$1" run="$2"
  if [[ -n "$engine" ]]; then
    ( cd "$WORK" && QA_ENGINE="$engine" bash "$QAVERIFY" "$run" )
  else
    ( cd "$WORK" && bash "$QAVERIFY" "$run" )
  fi
}

# ---------------------------------------------------------------------------
# Part 1 — record-evidence.sh identity: writes the artifact (both engines),
# validates --persona/--subject/--method, rejects a bogus --method.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$REC" runREC C1 identity --persona alice --subject "alice" --method whoami >/dev/null )
check "record identity (jq): artifact written" \
  "$([[ -f "$WORK/.qa/runs/runREC/evidence/alice/identity.json" ]] && echo yes)" "yes"
check "record identity (jq): shape has persona/capturedSubject/method/recorded_at" \
  "$(jq -r '[.persona,.capturedSubject,.method,(has("recorded_at")|tostring)] | join(",")' "$WORK/.qa/runs/runREC/evidence/alice/identity.json")" \
  "alice,alice,whoami,true"
check "record identity (jq): prints the persona-scoped relative path" \
  "$( cd "$WORK" && bash "$REC" runREC C1 identity --persona alice --subject alice --method whoami )" \
  "evidence/alice/identity.json"

( cd "$WORK" && PATH="$FAKEBIN" "$BASH_ABS" "$REC" runREC C2 identity --persona bob --subject "bob@example.com" --method storageState >/dev/null )
check "record identity (python3 fallback): artifact written" \
  "$([[ -f "$WORK/.qa/runs/runREC/evidence/bob/identity.json" ]] && echo yes)" "yes"
check "record identity (python3 fallback): shape correct" \
  "$(jq -r '[.persona,.capturedSubject,.method] | join(",")' "$WORK/.qa/runs/runREC/evidence/bob/identity.json")" \
  "bob,bob@example.com,storageState"

RC_NOPERSONA=0
( cd "$WORK" && bash "$REC" runREC C3 identity --subject x --method whoami >/dev/null 2>&1 ) || RC_NOPERSONA=$?
check "record identity: --persona is required (dies non-zero)" "$([[ "$RC_NOPERSONA" -ne 0 ]] && echo yes)" "yes"

RC_BADMETHOD=0
( cd "$WORK" && bash "$REC" runREC C4 identity --persona alice --subject x --method bogus >/dev/null 2>&1 ) || RC_BADMETHOD=$?
check "record identity: an unknown --method dies non-zero" "$([[ "$RC_BADMETHOD" -ne 0 ]] && echo yes)" "yes"

RC_METHODNONE=1
( cd "$WORK" && bash "$REC" runREC C5 identity --persona carol --subject none --method none >/dev/null 2>&1 ) && RC_METHODNONE=$?
check "record identity: --method none is accepted (the degrade path)" "$RC_METHODNONE" "0"

# ---------------------------------------------------------------------------
# fixture builder: one persona-scoped, cross-tenant-tagged criterion (kind
# error-state, tags:[cross-tenant] -> required-kinds.sh derives 'probe'
# alone), bound to a real toolstream capture so provenance resolves 'bound'
# (never 'no-toolstream') -- isolates the identity-check assertions from the
# no-toolstream degrade path entirely.
# ---------------------------------------------------------------------------
build_crosstenant_run() { # <run> <persona> <marker>
  local run="$1" persona="$2" marker="$3"
  ( cd "$WORK" && bash "$TOOLSTREAM" append "$run" \
    "$(printf '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"%s"},"responseBody":"{\\"marker\\":\\"%s\\"}"}' "$marker" "$marker")" >/dev/null )
  local ref
  ref="$( cd "$WORK" && bash "$REC" "$run" CT1 probe --persona "$persona" \
    --status 403 --shape "{\"marker\":\"${marker}\"}" --ok true )"
  ( cd "$WORK" && bash "$CKPT" "$run" CT1 pass --persona "$persona" --kinds probe --evidence-refs "$ref" >/dev/null )
  write_checklist "$run" '[{"id":"CT1","surface":"/x","kind":"error-state","tags":["cross-tenant"],"action":"View another tenant'"'"'s record (expect isolation)"}]'
}

# a human-action-kinds variant (exercises the OTHER half of is_high_stakes:
# kinds contains human-action, no cross-tenant tag needed).
build_humanaction_run() { # <run> <persona>
  local run="$1" persona="$2"
  local ref
  ref="$( cd "$WORK" && bash "$REC" "$run" HA1 action-trace --persona "$persona" \
    --steps '[{"tool":"browser_click","phase":"act"}]' \
    --session-calls '[{"class":"human-path","mutating":true,"code":"await page.locator(\"#x\").click();"}]' \
    --fingerprint-before '{"count":1}' --fingerprint-after '{"count":2}' )"
  ( cd "$WORK" && bash "$CKPT" "$run" HA1 pass --persona "$persona" --kinds human-action --evidence-refs "$ref" >/dev/null )
  # kind error-state (NOT in the bake-kind set) + tags:[human-action] so
  # required-kinds.sh derives human-action ALONE (rule 1, the mutating verb
  # "Submit") -- no bake requirement to also satisfy, keeping this fixture
  # isolated to the identity-check assertion (a dropped-kind override would
  # otherwise also fire and muddy which reason caused the fail).
  write_checklist "$run" '[{"id":"HA1","surface":"/x","kind":"error-state","tags":["human-action"],"action":"Submit invalid data to trigger a validation error"}]'
}

for ENGINE in "" python3; do
  LABEL="${ENGINE:-jq(default)}"

  # --- mismatch: persona alice, captured subject bob (both simple tokens) --
  RUN="mismatch_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "MISMATCH-${ENGINE:-jq}-42"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject bob --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] mismatch: qa-verify exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] mismatch: CT1 overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "fail"
  check "[$LABEL] mismatch: confidence forced high on override" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "high"
  check_contains "[$LABEL] mismatch: reason names both identities" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .reasons | join("; ")' "$(vf "$RUN")")" \
    "acting identity 'bob' != persona 'alice'"
  check "[$LABEL] mismatch: inRunVerdict is still the original pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .inRunVerdict' "$(vf "$RUN")")" "pass"

  # --- match: persona alice, captured subject alice ------------------------
  RUN="match_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "MATCH-${ENGINE:-jq}-42"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject alice --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] match: qa-verify exits 0" "$RC" "0"
  check "[$LABEL] match: CT1 stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] match: confidence stays high (identity verified, provenance bound)" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "high"

  # --- match, case/casing-insensitive substring (Admin vs admin) -----------
  RUN="matchcase_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" admin "MATCHCASE-${ENGINE:-jq}-42"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona admin --subject "Admin User" --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  check "[$LABEL] case-insensitive substring match: CT1 stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] case-insensitive substring match: confidence stays high" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "high"

  # --- absent identity.json: degrade, NOT override --------------------------
  RUN="absent_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "ABSENT-${ENGINE:-jq}-42"
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] absent identity: qa-verify still exits 0" "$RC" "0"
  check "[$LABEL] absent identity: CT1 stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] absent identity: confidence degrades to low" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "low"
  check_contains "[$LABEL] absent identity: reason explains the degrade" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .reasons | join("; ")' "$(vf "$RUN")")" \
    "persona identity unverified"

  # --- method:none: degrade, NOT override -----------------------------------
  RUN="methodnone_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "METHODNONE-${ENGINE:-jq}-42"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject "n/a" --method none >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] method:none: qa-verify still exits 0" "$RC" "0"
  check "[$LABEL] method:none: CT1 stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] method:none: confidence degrades to low" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "low"
  check_contains "[$LABEL] method:none: reason mentions method:none" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .reasons | join("; ")' "$(vf "$RUN")")" "method:none"

  # --- ambiguous format (UUID-shaped subject, no expectedSubject) -> degrade
  RUN="ambiguous_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "AMBIG-${ENGINE:-jq}-42"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice \
    --subject "550e8400-e29b-41d4-a716-446655440000" --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] ambiguous (UUID) subject: qa-verify exits 0 (NOT overridden)" "$RC" "0"
  check "[$LABEL] ambiguous (UUID) subject: CT1 stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] ambiguous (UUID) subject: confidence degrades to low" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "low"

  # --- expectedSubject configured: authoritative over the bare persona id --
  RUN="expected_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "EXPECTED-${ENGINE:-jq}-42"
  mkdir -p "$WORK/.qa"
  printf '%s' '{"personas":[{"id":"alice","role":"user","plane":"global","auth":"seeded","expectedSubject":"alice@corp.test"}]}' \
    > "$WORK/.qa/config.json"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject "alice@corp.test" --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  check "[$LABEL] expectedSubject configured + matching complex subject: CT1 stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] expectedSubject configured + matching complex subject: confidence stays high" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .confidence' "$(vf "$RUN")")" "high"
  rm -f "$WORK/.qa/config.json"

  RUN="expectedmismatch_${ENGINE:-jq}"
  build_crosstenant_run "$RUN" alice "EXPECTEDMISMATCH-${ENGINE:-jq}-42"
  mkdir -p "$WORK/.qa"
  printf '%s' '{"personas":[{"id":"alice","role":"user","plane":"global","auth":"seeded","expectedSubject":"alice@corp.test"}]}' \
    > "$WORK/.qa/config.json"
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject "someone-else@corp.test" --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] expectedSubject configured + mismatching complex subject: qa-verify exits non-zero" \
    "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] expectedSubject configured + mismatching complex subject: overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="CT1") | .verifierVerdict' "$(vf "$RUN")")" "fail"
  rm -f "$WORK/.qa/config.json"

  # --- __shared__ / empty-persona: identity NOT checked at all -------------
  RUN="shared_${ENGINE:-jq}"
  ( cd "$WORK" && bash "$TOOLSTREAM" append "$RUN" \
    "$(printf '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"s1"},"responseBody":"{\\"marker\\":\\"SHARED-%s-42\\"}"}' "${ENGINE:-jq}")" >/dev/null )
  SREF="$( cd "$WORK" && bash "$REC" "$RUN" CTS probe --status 403 --shape "{\"marker\":\"SHARED-${ENGINE:-jq}-42\"}" --ok true )"
  ( cd "$WORK" && bash "$CKPT" "$RUN" CTS pass --kinds probe --evidence-refs "$SREF" >/dev/null )
  write_checklist "$RUN" '[{"id":"CTS","surface":"/x","kind":"error-state","tags":["cross-tenant"],"action":"View another tenant'"'"'s record (expect isolation), shared/no persona"}]'
  # a mismatching identity.json under a totally unrelated persona dir must
  # never be consulted for an empty-persona record.
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona ghost --subject nobody --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] shared/no-persona: qa-verify exits 0 (identity never consulted)" "$RC" "0"
  check "[$LABEL] shared/no-persona: CTS stays pass" \
    "$(jq -r '.[] | select(.criterionId=="CTS") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] shared/no-persona: confidence stays high (not degraded)" \
    "$(jq -r '.[] | select(.criterionId=="CTS") | .confidence' "$(vf "$RUN")")" "high"

  # --- read-only, non-high-stakes: identity NOT checked even though a ------
  # mismatching identity.json exists for the same persona/run. A real
  # toolstream capture backs the bake read-back so provenance resolves
  # 'bound' (never 'no-toolstream') -- isolates this fixture to the
  # identity-skip assertion, distinct from the pre-existing (unrelated)
  # no-toolstream confidence degrade tests/qa-verify/run.sh already covers.
  RUN="readonly_${ENGINE:-jq}"
  ( cd "$WORK" && bash "$TOOLSTREAM" append "$RUN" \
    "$(printf '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"ro1"},"responseBody":"{\\"count\\":\\"RO-COUNT-%s-1\\"}"}' "${ENGINE:-jq}")" >/dev/null )
  RREF="$( cd "$WORK" && bash "$REC" "$RUN" RO1 bake --persona alice --read-back "{\"count\":\"RO-COUNT-${ENGINE:-jq}-1\"}" --multiplicity 1 )"
  ( cd "$WORK" && bash "$CKPT" "$RUN" RO1 pass --persona alice --kinds bake --evidence-refs "$RREF" >/dev/null )
  write_checklist "$RUN" '[{"id":"RO1","surface":"/x","kind":"happy-path","tags":["read-only"],"action":"View the list"}]'
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject bob --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  check "[$LABEL] read-only/non-high-stakes: RO1 stays pass despite a mismatching identity.json" \
    "$(jq -r '.[] | select(.criterionId=="RO1") | .verifierVerdict' "$(vf "$RUN")")" "pass"
  check "[$LABEL] read-only/non-high-stakes: confidence untouched (high)" \
    "$(jq -r '.[] | select(.criterionId=="RO1") | .confidence' "$(vf "$RUN")")" "high"

  # --- human-action-kind high-stakes path (no cross-tenant tag needed) -----
  RUN="hamismatch_${ENGINE:-jq}"
  build_humanaction_run "$RUN" alice
  ( cd "$WORK" && bash "$REC" "$RUN" IDENT identity --persona alice --subject bob --method whoami >/dev/null )
  run_qv "$ENGINE" "$RUN" >/dev/null 2>&1
  RC=$?
  check "[$LABEL] human-action kind, mismatch: qa-verify exits non-zero" "$([[ "$RC" -ne 0 ]] && echo yes)" "yes"
  check "[$LABEL] human-action kind, mismatch: HA1 overridden to fail" \
    "$(jq -r '.[] | select(.criterionId=="HA1") | .verifierVerdict' "$(vf "$RUN")")" "fail"
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
