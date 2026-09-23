#!/usr/bin/env bash
# Dual-engine tests for scripts/known-defects.sh — the project-level known-defect
# registry gate (plan task 4, spec §5.3, decisions R2/R3/R4/R16).
#
# What this suite pins, and why each pin exists:
#   (A) SCHEMA. Every entry must carry id/title/ticket/expiry/severity/
#       observedClass/surface/observedBehaviour. A missing or EMPTY `ticket`,
#       or a missing/malformed `expiry`, is rejected: a known defect with no
#       owner and no deadline is "deferred by design" under a new name.
#   (B) EXPIRY CAP = 90 days (R2). Without the cap, `2099-01-01` turns the
#       whole gate into a paper rule. The boundary (exactly 90) is accepted;
#       91+ is rejected. Date arithmetic is computed inside the jq/python3
#       layer — never `date -d`, which is GNU-only and absent on macOS/BSD.
#   (C) SEVERITY FLOOR gates on the STRUCTURED `observedClass` enum, not prose
#       (R3): `observedClass: non-rendering` forces `severity` >= high. The
#       `non-rendering` + `low` case is the ORIGINATING INCIDENT's own entry —
#       it must be rejected.
#   (D) CLEARING REQUIRES POSITIVE EVIDENCE (R4). An entry is `cleared` only
#       when evidence shows its `surface` was driven with a 2xx AND carried no
#       fatal finding. ABSENCE OF A FINDING NEVER CLEARS: a run that never
#       reached the surface produces exactly the same silence as a fixed
#       defect. `test_status_not_cleared_when_navigation_absent_but_no_finding`
#       is the pin for that — it is the whole point of the script.
#   (E) EXIT CODE HONESTY. `validate` must never exit 0 while printing errors.
#       That exact bug shipped in qa-kit/scripts/data-baseline.sh and hid a
#       malformed baseline in production use.
#   (F) DUAL-ENGINE PARITY. Every case runs on jq and on python3; the two
#       engines must agree byte-for-byte on both streams and on the exit code
#       (lesson of the earlier jq/python divergence, Fix #27).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../scripts/known-defects.sh"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: known-defects: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

TODAY="2026-09-23"

# --- fixtures -----------------------------------------------------------------
# The originating incident's real entry, with the severity it was actually
# filed at corrected to the floor (see KD_NONRENDERING_LOW for the raw one).
KD_OK='{"id":"KD-1",
        "title":"stage_gate_reviews.status=completed rejected by StageGateReviewStatus",
        "ticket":"z8tvbhteuc",
        "expiry":"2026-10-07",
        "severity":"high",
        "observedClass":"non-rendering",
        "observedStatus":500,
        "surface":"/admin/evaluations/challenges/{challenge}?tab=gates",
        "observedBehaviour":"HTTP 500, unhandled ValueError from the status enum cast"}'

# helper: emit KD_OK with one field replaced / removed, via python3 (test-side
# only; the script under test must not need python3 when jq is present).
mutate() { # mutate <json> <python-expr-on-`e`>
  python3 -c '
import json,sys
e = json.loads(sys.argv[1])
exec(sys.argv[2])
print(json.dumps(e))' "$1" "$2"
}

KD_NO_TICKET="$(mutate "$KD_OK" 'e.pop("ticket")')"
KD_EMPTY_TICKET="$(mutate "$KD_OK" 'e["ticket"]=""')"
KD_BLANK_TICKET="$(mutate "$KD_OK" 'e["ticket"]="   "')"
KD_NO_EXPIRY="$(mutate "$KD_OK" 'e.pop("expiry")')"
KD_BAD_EXPIRY="$(mutate "$KD_OK" 'e["expiry"]="07-10-2026"')"
KD_IMPOSSIBLE_EXPIRY="$(mutate "$KD_OK" 'e["expiry"]="2026-02-30"')"
# 2026-09-23 -> 2026-12-31 is 99 days: over the cap.
KD_EXPIRY_99="$(mutate "$KD_OK" 'e["expiry"]="2026-12-31"')"
# 2026-09-23 + 90 days = 2026-12-22 exactly: the accepted boundary.
KD_EXPIRY_90="$(mutate "$KD_OK" 'e["expiry"]="2026-12-22"')"
KD_EXPIRY_91="$(mutate "$KD_OK" 'e["expiry"]="2026-12-23"')"
# THE ORIGINATING INCIDENT's severity: non-rendering filed as "low".
KD_NONRENDERING_LOW="$(mutate "$KD_OK" 'e["severity"]="low"')"
KD_NONRENDERING_MEDIUM="$(mutate "$KD_OK" 'e["severity"]="medium"')"
KD_NONRENDERING_CRITICAL="$(mutate "$KD_OK" 'e["severity"]="critical"')"
# A `degraded` defect at `low` is fine — the floor is observedClass-scoped.
KD_DEGRADED_LOW="$(mutate "$KD_OK" 'e["observedClass"]="degraded"; e["severity"]="low"')"
KD_BAD_CLASS="$(mutate "$KD_OK" 'e["observedClass"]="cosmetic"')"
KD_BAD_SEVERITY="$(mutate "$KD_OK" 'e["severity"]="blocker"')"
KD_DUP_B="$(mutate "$KD_OK" 'e["title"]="a second entry reusing KD-1"')"
KD_PAST_EXPIRY="$(mutate "$KD_OK" 'e["expiry"]="2026-09-22"')"
KD_FUTURE_EXPIRY="$(mutate "$KD_OK" 'e["expiry"]="2026-11-01"')"
KD_OTHER_SURFACE="$(mutate "$KD_OK" 'e["id"]="KD-2"; e["surface"]="/admin/reports"; e["expiry"]="2026-11-01"')"

write_registry() { # write_registry <file> <entry-json>...
  local f="$1"; shift
  local out="[" first=1 e
  for e in "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else out="$out,"; fi
    out="$out$e"
  done
  printf '%s]\n' "$out" > "$f"
}

# --- evidence fixtures --------------------------------------------------------
# The shape qa-verify.sh renders out of the findings journal (spec §5.1/§5.3):
# recorded navigations (url + HTTP status) and recorded findings.
EV_2XX_NO_FINDING='{"navigations":[{"url":"https://app.test/admin/evaluations/challenges/1?tab=gates","status":200}],
                    "findings":[]}'
EV_2XX_WITH_FATAL='{"navigations":[{"url":"https://app.test/admin/evaluations/challenges/1?tab=gates","status":200}],
                    "findings":[{"url":"https://app.test/admin/evaluations/challenges/1?tab=gates","statusClass":"fatal","status":500}]}'
# THE DANGEROUS CASE: the run produced no finding at all, but also never drove
# the surface. Silence is not proof of a fix.
EV_NO_NAV_NO_FINDING='{"navigations":[{"url":"https://app.test/dashboard","status":200}],"findings":[]}'
EV_EMPTY='{"navigations":[],"findings":[]}'
EV_NAV_5XX='{"navigations":[{"url":"https://app.test/admin/evaluations/challenges/1?tab=gates","status":500}],"findings":[]}'

# --- engine plumbing ----------------------------------------------------------
ENGINES=""
command -v jq      >/dev/null 2>&1 && ENGINES="$ENGINES jq"
command -v python3 >/dev/null 2>&1 && ENGINES="$ENGINES python3"

# run <engine> <args...> -> sets RC and OUT (stdout+stderr merged)
run() { local eng="$1"; shift; OUT="$(QA_ENGINE="$eng" bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
# run_split <engine> <args...> -> sets RC, SOUT (stdout only), SERR (stderr only)
run_split() {
  local eng="$1"; shift
  local ef="$WORK/.err.$$"
  SOUT="$(QA_ENGINE="$eng" bash "$SCRIPT" "$@" 2>"$ef")"; RC=$?
  SERR="$(cat "$ef")"; rm -f "$ef"
}

state_of() { # state_of <status-json> <id>
  python3 -c '
import json,sys
rows = json.loads(sys.argv[1])
print(next((r["state"] for r in rows if r["id"] == sys.argv[2]), "<absent>"))' "$1" "$2"
}

for ENG in $ENGINES; do
  R="$WORK/$ENG"; mkdir -p "$R"

  # ===== validate: happy path ================================================
  write_registry "$R/ok.json" "$KD_OK"
  run "$ENG" validate "$R/ok.json" "$TODAY"
  check "[$ENG] test_valid_entry_passes: exit 0"        "$RC" "0"
  check "[$ENG] test_valid_entry_passes: silent"        "$OUT" ""

  # ===== validate: empty array is vacuously valid ============================
  printf '[]\n' > "$R/empty.json"
  run "$ENG" validate "$R/empty.json" "$TODAY"
  check "[$ENG] test_empty_array_valid: exit 0"         "$RC" "0"
  check "[$ENG] test_empty_array_valid: silent"         "$OUT" ""

  # ===== validate: ticket ====================================================
  write_registry "$R/noticket.json" "$KD_NO_TICKET"
  run "$ENG" validate "$R/noticket.json" "$TODAY"
  check "[$ENG] test_missing_ticket_rejected: nonzero"  "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_missing_ticket_rejected: names entry[0].ticket" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.ticket: ' && echo yes)" "yes"

  write_registry "$R/emptyticket.json" "$KD_EMPTY_TICKET"
  run "$ENG" validate "$R/emptyticket.json" "$TODAY"
  check "[$ENG] test_empty_ticket_rejected: nonzero"    "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_empty_ticket_rejected: names entry[0].ticket" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.ticket: ' && echo yes)" "yes"

  write_registry "$R/blankticket.json" "$KD_BLANK_TICKET"
  run "$ENG" validate "$R/blankticket.json" "$TODAY"
  check "[$ENG] whitespace-only ticket rejected too"    "$([[ $RC -ne 0 ]] && echo yes)" "yes"

  # ===== validate: expiry ====================================================
  write_registry "$R/noexpiry.json" "$KD_NO_EXPIRY"
  run "$ENG" validate "$R/noexpiry.json" "$TODAY"
  check "[$ENG] test_missing_expiry_rejected: nonzero"  "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_missing_expiry_rejected: names entry[0].expiry" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.expiry: ' && echo yes)" "yes"

  write_registry "$R/badexpiry.json" "$KD_BAD_EXPIRY"
  run "$ENG" validate "$R/badexpiry.json" "$TODAY"
  check "[$ENG] test_malformed_expiry_rejected: nonzero" "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_malformed_expiry_rejected: names entry[0].expiry" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.expiry: ' && echo yes)" "yes"

  write_registry "$R/impossible.json" "$KD_IMPOSSIBLE_EXPIRY"
  run "$ENG" validate "$R/impossible.json" "$TODAY"
  check "[$ENG] calendar-impossible expiry (2026-02-30) rejected" "$([[ $RC -ne 0 ]] && echo yes)" "yes"

  # ===== validate: 90-day cap (R2) ===========================================
  write_registry "$R/e99.json" "$KD_EXPIRY_99"
  run "$ENG" validate "$R/e99.json" "$TODAY"
  check "[$ENG] test_expiry_beyond_90_days_rejected: nonzero" "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_expiry_beyond_90_days_rejected: names entry[0].expiry" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.expiry: ' && echo yes)" "yes"
  check "[$ENG] test_expiry_beyond_90_days_rejected: message cites 90" \
    "$(printf '%s\n' "$OUT" | grep -q '90' && echo yes)" "yes"

  write_registry "$R/e90.json" "$KD_EXPIRY_90"
  run "$ENG" validate "$R/e90.json" "$TODAY"
  check "[$ENG] test_expiry_at_exactly_90_days_accepted: exit 0" "$RC" "0"
  check "[$ENG] test_expiry_at_exactly_90_days_accepted: silent" "$OUT" ""

  write_registry "$R/e91.json" "$KD_EXPIRY_91"
  run "$ENG" validate "$R/e91.json" "$TODAY"
  check "[$ENG] 91 days (one past the boundary) rejected" "$([[ $RC -ne 0 ]] && echo yes)" "yes"

  # a PAST expiry is schema-valid (it is `status`'s job to call it expired)
  write_registry "$R/past.json" "$KD_PAST_EXPIRY"
  run "$ENG" validate "$R/past.json" "$TODAY"
  check "[$ENG] past expiry is schema-valid (status, not validate, flags it)" "$RC" "0"

  # ===== validate: severity floor via observedClass (R3) =====================
  write_registry "$R/nrlow.json" "$KD_NONRENDERING_LOW"
  run "$ENG" validate "$R/nrlow.json" "$TODAY"
  check "[$ENG] test_non_rendering_below_high_rejected: nonzero" "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_non_rendering_below_high_rejected: names entry[0].severity" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.severity: ' && echo yes)" "yes"

  write_registry "$R/nrmed.json" "$KD_NONRENDERING_MEDIUM"
  run "$ENG" validate "$R/nrmed.json" "$TODAY"
  check "[$ENG] non-rendering + medium also below the floor"  "$([[ $RC -ne 0 ]] && echo yes)" "yes"

  write_registry "$R/nrhigh.json" "$KD_OK"
  run "$ENG" validate "$R/nrhigh.json" "$TODAY"
  check "[$ENG] test_non_rendering_high_accepted: exit 0"     "$RC" "0"

  write_registry "$R/nrcrit.json" "$KD_NONRENDERING_CRITICAL"
  run "$ENG" validate "$R/nrcrit.json" "$TODAY"
  check "[$ENG] non-rendering + critical accepted"            "$RC" "0"

  write_registry "$R/deglow.json" "$KD_DEGRADED_LOW"
  run "$ENG" validate "$R/deglow.json" "$TODAY"
  check "[$ENG] floor is observedClass-scoped: degraded+low ok" "$RC" "0"

  # ===== validate: enums =====================================================
  write_registry "$R/badclass.json" "$KD_BAD_CLASS"
  run "$ENG" validate "$R/badclass.json" "$TODAY"
  check "[$ENG] test_observed_class_outside_enum_rejected: nonzero" "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_observed_class_outside_enum_rejected: names entry[0].observedClass" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[0\]\.observedClass: ' && echo yes)" "yes"

  write_registry "$R/badsev.json" "$KD_BAD_SEVERITY"
  run "$ENG" validate "$R/badsev.json" "$TODAY"
  check "[$ENG] severity outside enum rejected"                "$([[ $RC -ne 0 ]] && echo yes)" "yes"

  # ===== validate: duplicate id ==============================================
  write_registry "$R/dup.json" "$KD_OK" "$KD_DUP_B"
  run "$ENG" validate "$R/dup.json" "$TODAY"
  check "[$ENG] test_duplicate_id_rejected: nonzero"           "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_duplicate_id_rejected: names entry[1].id" \
    "$(printf '%s\n' "$OUT" | grep -qE '^ERROR: entry\[1\]\.id: ' && echo yes)" "yes"

  # ===== (E) exit-code honesty: the data-baseline.sh bug class ===============
  write_registry "$R/multi.json" "$KD_NONRENDERING_LOW" "$KD_NO_TICKET"
  run_split "$ENG" validate "$R/multi.json" "$TODAY"
  check "[$ENG] test_validate_exit_code_nonzero_on_error: RC != 0 while printing errors" \
    "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  check "[$ENG] test_validate_exit_code_nonzero_on_error: errors actually printed" \
    "$(printf '%s\n' "$SERR" | grep -c '^ERROR: ' | tr -d ' ')" "3"
  check "[$ENG] test_validate_exit_code_nonzero_on_error: stdout stays clean" "$SOUT" ""
  check "[$ENG] test_validate_exit_code_nonzero_on_error: reports EVERY violation, not just the first" \
    "$(printf '%s\n' "$SERR" | grep -qE '^ERROR: entry\[1\]\.' && echo yes)" "yes"

  # ===== status: expired =====================================================
  write_registry "$R/st-past.json" "$KD_PAST_EXPIRY"
  run_split "$ENG" status "$R/st-past.json" "$TODAY"
  check "[$ENG] test_status_expired_when_past_expiry: exit 0"  "$RC" "0"
  check "[$ENG] test_status_expired_when_past_expiry: state"   "$(state_of "$SOUT" KD-1)" "expired"

  # expiry == today is NOT yet expired
  write_registry "$R/st-today.json" "$(mutate "$KD_OK" 'e["expiry"]="2026-09-23"')"
  run_split "$ENG" status "$R/st-today.json" "$TODAY"
  check "[$ENG] expiry == today is still outstanding, not expired" "$(state_of "$SOUT" KD-1)" "outstanding"

  # ===== status: no evidence at all -> outstanding ===========================
  write_registry "$R/st-fut.json" "$KD_FUTURE_EXPIRY"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY"
  check "[$ENG] test_status_outstanding_when_surface_not_driven: exit 0" "$RC" "0"
  check "[$ENG] test_status_outstanding_when_surface_not_driven: outstanding, NOT cleared" \
    "$(state_of "$SOUT" KD-1)" "outstanding"

  printf '%s\n' "$EV_EMPTY" > "$R/ev-empty.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-empty.json"
  check "[$ENG] empty evidence does not clear" "$(state_of "$SOUT" KD-1)" "outstanding"

  # ===== status: cleared REQUIRES a 2xx navigation (R4) ======================
  printf '%s\n' "$EV_2XX_NO_FINDING" > "$R/ev-ok.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-ok.json"
  check "[$ENG] test_status_cleared_requires_2xx_navigation: exit 0" "$RC" "0"
  check "[$ENG] test_status_cleared_requires_2xx_navigation: cleared" \
    "$(state_of "$SOUT" KD-1)" "cleared"

  # ===== THE DANGEROUS CASE: silence != fixed ================================
  printf '%s\n' "$EV_NO_NAV_NO_FINDING" > "$R/ev-nonav.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-nonav.json"
  check "[$ENG] test_status_not_cleared_when_navigation_absent_but_no_finding: exit 0" "$RC" "0"
  check "[$ENG] test_status_not_cleared_when_navigation_absent_but_no_finding: NOT cleared" \
    "$([[ "$(state_of "$SOUT" KD-1)" != "cleared" ]] && echo yes)" "yes"
  check "[$ENG] test_status_not_cleared_when_navigation_absent_but_no_finding: stays outstanding" \
    "$(state_of "$SOUT" KD-1)" "outstanding"

  # a NON-2xx navigation to the surface is not positive evidence either
  printf '%s\n' "$EV_NAV_5XX" > "$R/ev-5xx.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-5xx.json"
  check "[$ENG] a 5xx navigation to the surface never clears" "$(state_of "$SOUT" KD-1)" "outstanding"

  # a 2xx navigation WITH a fatal finding on the surface does not clear
  printf '%s\n' "$EV_2XX_WITH_FATAL" > "$R/ev-fatal.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-fatal.json"
  check "[$ENG] 2xx + fatal finding on the surface does not clear" "$(state_of "$SOUT" KD-1)" "outstanding"

  # evidence for a DIFFERENT surface never clears this entry
  write_registry "$R/st-two.json" "$KD_FUTURE_EXPIRY" "$KD_OTHER_SURFACE"
  run_split "$ENG" status "$R/st-two.json" "$TODAY" --evidence "$R/ev-ok.json"
  check "[$ENG] evidence is surface-scoped: KD-1 cleared"    "$(state_of "$SOUT" KD-1)" "cleared"
  check "[$ENG] evidence is surface-scoped: KD-2 untouched"  "$(state_of "$SOUT" KD-2)" "outstanding"

  # ===== status: shape =======================================================
  printf '[]\n' > "$R/st-empty.json"
  run_split "$ENG" status "$R/st-empty.json" "$TODAY"
  check "[$ENG] status on an empty registry prints []"       "$SOUT" "[]"
  check "[$ENG] status on an empty registry exits 0"         "$RC" "0"

  # ===== errors that are real errors still exit nonzero ======================
  run "$ENG" validate "$R/does-not-exist.json" "$TODAY"
  check "[$ENG] missing registry file exits nonzero"         "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  printf 'not json\n' > "$R/bad.json"
  run "$ENG" validate "$R/bad.json" "$TODAY"
  check "[$ENG] unparseable registry exits nonzero"          "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  run "$ENG" status "$R/bad.json" "$TODAY"
  check "[$ENG] status on an unparseable registry exits nonzero" "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  printf '{"id":"KD-1"}\n' > "$R/obj.json"
  run "$ENG" validate "$R/obj.json" "$TODAY"
  check "[$ENG] non-array registry exits nonzero"            "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  run "$ENG" validate "$R/ok.json" "23-09-2026"
  check "[$ENG] malformed <today> exits nonzero"             "$([[ $RC -ne 0 ]] && echo yes)" "yes"
  run "$ENG" bogus "$R/ok.json" "$TODAY"
  check "[$ENG] unknown subcommand exits nonzero"            "$([[ $RC -ne 0 ]] && echo yes)" "yes"
done

# ===== (F) test_python_engine_matches_jq_engine ==============================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$WORK/parity"; mkdir -p "$X"
  printf '%s\n' "$EV_2XX_NO_FINDING" > "$X/ev.json"

  cmp_case() { # cmp_case <label> <args...>
    local label="$1"; shift
    local jo jr po pr
    jo="$(QA_ENGINE=jq      bash "$SCRIPT" "$@" 2>&1)"; jr=$?
    po="$(QA_ENGINE=python3 bash "$SCRIPT" "$@" 2>&1)"; pr=$?
    check "test_python_engine_matches_jq_engine: $label output byte-identical" \
      "$([[ "$jo" == "$po" ]] && echo same || echo "diff<<$jo>>vs<<$po>>")" "same"
    check "test_python_engine_matches_jq_engine: $label exit code identical" "$jr" "$pr"
  }

  # a registry exercising every validation branch at once
  write_registry "$X/all.json" \
    "$KD_NONRENDERING_LOW" "$KD_NO_TICKET" "$KD_EXPIRY_99" "$KD_BAD_CLASS" \
    "$KD_BAD_EXPIRY" "$KD_NO_EXPIRY" "$KD_BAD_SEVERITY" "$KD_DEGRADED_LOW"
  cmp_case "validate (every branch)" validate "$X/all.json" "$TODAY"

  write_registry "$X/good.json" "$KD_OK" "$KD_OTHER_SURFACE"
  cmp_case "validate (clean)"            validate "$X/good.json" "$TODAY"
  cmp_case "status (no evidence)"        status   "$X/good.json" "$TODAY"
  cmp_case "status (with evidence)"      status   "$X/good.json" "$TODAY" --evidence "$X/ev.json"
  write_registry "$X/mixed.json" "$KD_PAST_EXPIRY" "$KD_OTHER_SURFACE"
  cmp_case "status (expired + outstanding)" status "$X/mixed.json" "$TODAY" --evidence "$X/ev.json"
  printf '[]\n' > "$X/empty.json"
  cmp_case "status (empty registry)"     status   "$X/empty.json" "$TODAY"
  cmp_case "validate (empty registry)"   validate "$X/empty.json" "$TODAY"
fi

echo
echo "known-defects tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
