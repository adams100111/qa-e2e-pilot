#!/usr/bin/env bash
# skill-gate-consistency — structural regression for the audit-2 W3-1/W3-3
# reconciliation: skill docs must not contradict the enforcement gates they
# describe. Four grep-level structural assertions + a body-length check:
#
#   1. Every fingerprint flag `check-action-trace.js` Check 3 (R1) MANDATES
#      (derived from `record-evidence.sh`'s `have_fp=1` pair, never
#      hardcoded) is named in driving-browser-qa's SKILL.md.
#   2. `human-action` appears inside generating-qa-checklist/SKILL.md's
#      "Derive `Kinds`" section (Step 7) — the FOUR-kind vocabulary, not
#      the stale three-kind one.
#   3. No `recompute.md` reference survives in the skill docs — the real
#      artifact `record-evidence.sh` writes for a `computed` kind is
#      `recompute.json` (see its `cmd_computed`/kind-to-filename map).
#   4. No skill instructs SETTING a value via `react-set-input.js` — the
#      script was demoted to read-only by ADR-0015; a "using the script"
#      re-fill instruction is the exact antipattern the audit caught in
#      walking-multistep-flows/SKILL.md Eval 3.
#   5. Every touched skill's SKILL.md body stays under 500 lines (move
#      overflow into references/, repo precedent: checkpointing-qa-memory).
#
# Assertions 1/3/4 are scoped to skills/ (the skill-docs layer this suite
# polices) — NOT the whole repo. A pre-existing, out-of-scope mention
# elsewhere (e.g. a tool script's comment, or a doc-drift item explicitly
# deferred to a later batch task) must not make this suite permanently red;
# see docs/superpowers/plans/2026-09-07-audit2-wave3-reconciliation.md Task 3
# vs. Task 8/9 (Appendix A verify-then-fix batches) for the scoping split.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL - $1"; FAIL=$((FAIL+1)); }

RECORD_EVIDENCE="$ROOT/skills/checkpointing-qa-memory/scripts/record-evidence.sh"
CHECK_ACTION_TRACE="$ROOT/skills/checkpointing-qa-memory/scripts/check-action-trace.js"
DRIVING_SKILL="$ROOT/skills/driving-browser-qa/SKILL.md"
CHECKLIST_SKILL="$ROOT/skills/generating-qa-checklist/SKILL.md"

# ---------------------------------------------------------------------------
# 1. Every fingerprint flag Check 3/R1 MANDATES appears in driving-browser-qa.
#
# Derived, not hardcoded: pull the flags from record-evidence.sh's own
# action-trace option parser whose branch sets `have_fp=1` (the mandatory
# pair Check 3's R1 die()s without — `--fingerprint-target` sets
# `have_target=1` instead and is optional/Check-3b-only, so it is correctly
# excluded here).
# ---------------------------------------------------------------------------
[[ -f "$RECORD_EVIDENCE" ]] || { bad "record-evidence.sh not found at $RECORD_EVIDENCE"; }
[[ -f "$CHECK_ACTION_TRACE" ]] || { bad "check-action-trace.js not found at $CHECK_ACTION_TRACE"; }

mapfile -t REQUIRED_FP_FLAGS < <(
  grep -E -- '--fingerprint-[a-z]+\).*have_fp=1' "$RECORD_EVIDENCE" \
    | grep -oE -- '--fingerprint-[a-z]+' \
    | sort -u
)

if [[ "${#REQUIRED_FP_FLAGS[@]}" -eq 0 ]]; then
  bad "derived zero mandatory --fingerprint-* flags from record-evidence.sh (parser regex stale?)"
else
  ok "derived ${#REQUIRED_FP_FLAGS[@]} mandatory fingerprint flag(s) from record-evidence.sh: ${REQUIRED_FP_FLAGS[*]}"
fi

# Sanity: check-action-trace.js Check 3/R1 must still hard-die on missing
# before/after fingerprints — if this ever stops being true the derivation
# above is testing a gate that no longer exists.
if grep -q "before' in fp" "$CHECK_ACTION_TRACE" && grep -q "after' in fp" "$CHECK_ACTION_TRACE"; then
  ok "check-action-trace.js Check 3/R1 still requires before+after fingerprints"
else
  bad "check-action-trace.js no longer hard-requires before/after fingerprints (Check 3/R1 moved?)"
fi

for flag in "${REQUIRED_FP_FLAGS[@]}"; do
  if grep -qF -- "$flag" "$DRIVING_SKILL"; then
    ok "driving-browser-qa/SKILL.md names $flag"
  else
    bad "driving-browser-qa/SKILL.md does NOT name $flag (check-action-trace.js Check 3 requires it)"
  fi
done

# ---------------------------------------------------------------------------
# 2. `human-action` present in generating-qa-checklist Step 7's Kinds
#    derivation section (the FOUR-kind vocab, matching required-kinds.sh).
# ---------------------------------------------------------------------------
[[ -f "$CHECKLIST_SKILL" ]] || bad "generating-qa-checklist/SKILL.md not found at $CHECKLIST_SKILL"

DERIVE_SECTION="$(awk '/Derive `Kinds`/{flag=1} flag{print} /^### Step 8/{exit}' "$CHECKLIST_SKILL")"
if [[ -z "$DERIVE_SECTION" ]]; then
  bad "could not locate the 'Derive \`Kinds\`' section in generating-qa-checklist/SKILL.md (heading moved/renamed?)"
elif grep -q "human-action" <<< "$DERIVE_SECTION"; then
  ok "generating-qa-checklist/SKILL.md Step 7 derivation names human-action"
else
  bad "generating-qa-checklist/SKILL.md Step 7 derivation is missing human-action (stale 3-kind vocab)"
fi

# ---------------------------------------------------------------------------
# 3. Zero `recompute.md` references left in the skill docs — the real
#    artifact is recompute.json (record-evidence.sh's kind-to-filename map).
# ---------------------------------------------------------------------------
mapfile -t RECOMPUTE_MD_HITS < <(grep -rl "recompute\.md" "$ROOT/skills" 2>/dev/null || true)
if [[ "${#RECOMPUTE_MD_HITS[@]}" -eq 0 ]]; then
  ok "no recompute.md references remain under skills/"
else
  bad "recompute.md still referenced in: ${RECOMPUTE_MD_HITS[*]}"
fi

REAL_ARTIFACT="$(grep -oE 'computed\) echo "recompute\.[a-z]+"' "$RECORD_EVIDENCE" | grep -oE 'recompute\.[a-z]+')"
if [[ "$REAL_ARTIFACT" == "recompute.json" ]]; then
  ok "record-evidence.sh's computed-kind artifact is recompute.json (sanity check)"
else
  bad "record-evidence.sh's computed-kind artifact is '${REAL_ARTIFACT:-<not found>}', not recompute.json — skill docs may be chasing the wrong filename"
fi

# ---------------------------------------------------------------------------
# 4. No skill instructs SETTING a value via react-set-input.js (ADR-0015:
#    the script is read-only). The audit's exact defect was an imperative
#    "using the script" re-fill instruction — grep for that pattern.
# ---------------------------------------------------------------------------
mapfile -t SET_VIA_SCRIPT_HITS < <(grep -rlin "using the script" "$ROOT/skills" 2>/dev/null || true)
if [[ "${#SET_VIA_SCRIPT_HITS[@]}" -eq 0 ]]; then
  ok "no skill instructs re-filling/setting a value 'using the script' (react-set-input.js)"
else
  bad "found a 'using the script' set-instruction in: ${SET_VIA_SCRIPT_HITS[*]} (react-set-input.js is read-only per ADR-0015)"
fi

# ---------------------------------------------------------------------------
# 5. Skill bodies stay under 500 lines (move overflow to references/).
# ---------------------------------------------------------------------------
BODIES=(
  "skills/driving-browser-qa/SKILL.md"
  "skills/generating-qa-checklist/SKILL.md"
  "skills/writing-qa-reports/SKILL.md"
  "skills/walking-multistep-flows/SKILL.md"
)
for rel in "${BODIES[@]}"; do
  f="$ROOT/$rel"
  if [[ ! -f "$f" ]]; then
    bad "$rel not found"
    continue
  fi
  n="$(wc -l < "$f" | tr -d ' ')"
  if [[ "$n" -lt 500 ]]; then
    ok "$rel is $n lines (< 500)"
  else
    bad "$rel is $n lines (>= 500) — move overflow to references/"
  fi
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
