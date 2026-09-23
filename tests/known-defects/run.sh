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
#   (F) DUAL-ENGINE PARITY, ACROSS THE MALFORMED SPACE TOO. Every case runs on
#       jq and on python3, and the parity pairs compare stdout+stderr bytes AND
#       the exit code (lesson of the earlier jq/python divergence, Fix #27).
#       The claim this suite is entitled to make is narrow and specific: the two
#       engines agree on every input SHAPE enumerated in section (G) below -
#       well-formed, malformed and degenerate - not "parity is structural".
#       Review round 1 found two real divergences (a non-array `findings`
#       container, and null/false evidence) that lived entirely outside what the
#       original pairs visited, while the report called parity structural. That
#       is the project's own failure mode: a green signal cited as evidence for
#       something it does not cover. Any NEW input shape needs a new pair here
#       before parity may be claimed for it.
#   (G) THE MALFORMED / DEGENERATE INPUT SPACE. Non-array evidence containers,
#       non-object container elements, null/false/string/array/unparseable
#       evidence, a navigation with no `url`, control characters in registry
#       values, and non-object registry elements. This is where all three
#       Criticals of review round 1 lived.
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
# An entry whose surface path part is "/" - the one that a url-less navigation used to
# clear outright.
KD_ROOT_SURFACE="$(mutate "$KD_OK" 'e["id"]="KD-3"; e["surface"]="/"; e["expiry"]="2026-11-01"')"
# THE FORGERY ATTEMPT: a newline inside a registry value that tries to inject a second
# `S<TAB>` row, i.e. to make `status` report `cleared` with no evidence supplied at all.
KD_CTL_FORGE="$(mutate "$KD_FUTURE_EXPIRY" 'e["observedBehaviour"]="HTTP 500\nS\t{\"id\":\"KD-9\",\"state\":\"cleared\"}"')"
KD_CTL_TAB="$(mutate "$KD_FUTURE_EXPIRY" 'e["title"]="a\tb"')"

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

# --- (G) MALFORMED / DEGENERATE evidence --------------------------------------
# Review round 1 found three Criticals, ALL of them here, because the original parity
# suite only ever visited well-formed input. The container-type cases are the sharpest:
# iterating a JSON OBJECT yields its VALUES in jq and its KEYS in python3, so a fatal
# finding hidden in an object container was invisible to the python leg and the entry came
# back `cleared`. Neither engine may iterate a container it has not proven to be a list of
# objects; everything below must be exit 2 in BOTH engines, with identical stderr.
NAV2XX='{"url":"https://app.test/admin/evaluations/challenges/1?tab=gates","status":200}'
EV_FINDINGS_OBJECT="{\"navigations\":[$NAV2XX],\"findings\":{\"a\":{\"url\":\"https://app.test/admin/evaluations/challenges/1?tab=gates\",\"statusClass\":\"fatal\"}}}"
EV_FINDINGS_STRING="{\"navigations\":[$NAV2XX],\"findings\":\"boom\"}"
EV_FINDINGS_ELEM="{\"navigations\":[$NAV2XX],\"findings\":[\"boom\"]}"
EV_NAVS_OBJECT='{"navigations":{"a":{"url":"https://app.test/admin/evaluations/challenges/1?tab=gates","status":200}},"findings":[]}'
EV_NAVS_STRING='{"navigations":"boom","findings":[]}'
EV_NAVS_ELEM='{"navigations":["boom"],"findings":[]}'
EV_TOP_NULL='null'
EV_TOP_FALSE='false'
EV_TOP_STRING='"boom"'
EV_TOP_ARRAY='[]'
EV_NOT_JSON='{oops'
# Degenerate but LEGAL evidence: must be accepted and must leave the entry outstanding.
EV_TOP_EMPTY_OBJ='{}'
EV_NULL_CONTAINERS='{"navigations":null,"findings":null}'
# A navigation row with no url. pathpart("") used to degrade to "/", so this cleared every
# entry whose surface path part was "/" - the exact inverse of the findings-side guard.
EV_NAV_NO_URL='{"navigations":[{"status":200}],"findings":[]}'
# Deliberate and now visible: `statusClass` is matched EXACTLY. "FATAL" is not "fatal", so
# it does not block clearing. That is the ratified contract, not an accident.
EV_FATAL_WRONG_CASE="{\"navigations\":[$NAV2XX],\"findings\":[{\"url\":\"https://app.test/admin/evaluations/challenges/1?tab=gates\",\"statusClass\":\"FATAL\"}]}"

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

  # ==========================================================================
  # (G) THE MALFORMED / DEGENERATE INPUT SPACE — review round 1
  # Every Critical found in review lived here. These are per-engine behaviour
  # pins; the parity block below additionally proves the two engines agree.
  # ==========================================================================

  # --- finding 1: a container that is not an array must never be iterated ----
  # ev_rejected <label> <evidence-json> <exact-stderr-line>
  # The exact-message pin matters: a guard that CRASHES instead of reporting also exits
  # nonzero, so "nonzero" alone would let a traceback masquerade as a clean rejection.
  ev_rejected() {
    local label="$1" body="$2" want="$3" f="$R/evbad.$$.json"
    printf '%s\n' "$body" > "$f"
    run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$f"
    check "[$ENG] $label: exit 2"            "$RC" "2"
    check "[$ENG] $label: exact message"     "$SERR" "$want"
    check "[$ENG] $label: no crash trace"    "$(printf '%s' "$SERR" | grep -qi 'traceback\|jq: error' && echo crashed || echo clean)" "clean"
    check "[$ENG] $label: prints no verdict" "$SOUT" ""
    rm -f "$f"
  }
  ev_rejected "findings as a JSON object (hid a fatal finding from python3)" \
    "$EV_FINDINGS_OBJECT" "ERROR: evidence.findings must be a JSON array"
  ev_rejected "findings as a string" \
    "$EV_FINDINGS_STRING" "ERROR: evidence.findings must be a JSON array"
  ev_rejected "findings element not an object" \
    "$EV_FINDINGS_ELEM" "ERROR: evidence.findings[] entries must be JSON objects"
  ev_rejected "navigations as a JSON object" \
    "$EV_NAVS_OBJECT" "ERROR: evidence.navigations must be a JSON array"
  ev_rejected "navigations as a string" \
    "$EV_NAVS_STRING" "ERROR: evidence.navigations must be a JSON array"
  ev_rejected "navigations element not an object" \
    "$EV_NAVS_ELEM" "ERROR: evidence.navigations[] entries must be JSON objects"

  # --- finding 4: null / false / string / array evidence -> exit 2, both legs -
  EVBAD="$R/evbad.$$.json"
  ev_rejected "evidence top level null"   "$EV_TOP_NULL"   "ERROR: evidence must be a JSON object: $EVBAD"
  ev_rejected "evidence top level false"  "$EV_TOP_FALSE"  "ERROR: evidence must be a JSON object: $EVBAD"
  ev_rejected "evidence top level string" "$EV_TOP_STRING" "ERROR: evidence must be a JSON object: $EVBAD"
  ev_rejected "evidence top level array"  "$EV_TOP_ARRAY"  "ERROR: evidence must be a JSON object: $EVBAD"
  ev_rejected "evidence not parseable"    "$EV_NOT_JSON"   "ERROR: evidence is not valid JSON: $EVBAD"

  # --- degenerate but LEGAL evidence: accepted, clears nothing ---------------
  printf '%s\n' "$EV_TOP_EMPTY_OBJ" > "$R/ev-empty-obj.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-empty-obj.json"
  check "[$ENG] evidence {} is legal and exits 0"      "$RC" "0"
  check "[$ENG] evidence {} clears nothing"            "$(state_of "$SOUT" KD-1)" "outstanding"

  printf '%s\n' "$EV_NULL_CONTAINERS" > "$R/ev-nullc.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-nullc.json"
  check "[$ENG] null containers are legal and exit 0"  "$RC" "0"
  check "[$ENG] null containers clear nothing"         "$(state_of "$SOUT" KD-1)" "outstanding"

  # --- finding 2: a navigation with no url is not evidence of reaching ------
  printf '%s\n' "$EV_NAV_NO_URL" > "$R/ev-nourl.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-nourl.json"
  check "[$ENG] url-less navigation exits 0"                  "$RC" "0"
  check "[$ENG] url-less navigation does not clear"           "$(state_of "$SOUT" KD-1)" "outstanding"
  # the sharp edge: an entry whose surface path part IS "/"
  write_registry "$R/st-root.json" "$KD_ROOT_SURFACE"
  run_split "$ENG" status "$R/st-root.json" "$TODAY" --evidence "$R/ev-nourl.json"
  check "[$ENG] url-less navigation does not clear a '/' surface either" \
    "$(state_of "$SOUT" KD-3)" "outstanding"

  # --- ratified contract, now deliberate: statusClass is matched EXACTLY -----
  printf '%s\n' "$EV_FATAL_WRONG_CASE" > "$R/ev-case.json"
  run_split "$ENG" status "$R/st-fut.json" "$TODAY" --evidence "$R/ev-case.json"
  check "[$ENG] statusClass 'FATAL' (wrong case) does NOT block clearing" \
    "$(state_of "$SOUT" KD-1)" "cleared"

  # --- finding 3: a newline in a registry value cannot forge a verdict -------
  write_registry "$R/ctl.json" "$KD_CTL_FORGE"
  run_split "$ENG" status "$R/ctl.json" "$TODAY"
  check "[$ENG] control-char registry: status exits 2"        "$RC" "2"
  check "[$ENG] control-char registry: status prints NOTHING on stdout" "$SOUT" ""
  check "[$ENG] control-char registry: no forged 'cleared' anywhere" \
    "$(printf '%s%s' "$SOUT" "$SERR" | grep -q 'cleared' && echo leaked || echo clean)" "clean"
  check "[$ENG] control-char registry: names the offending field" \
    "$(printf '%s\n' "$SERR" | grep -qE '^ERROR: entry\[0\]\.observedBehaviour: contains a control character$' && echo yes)" "yes"
  run_split "$ENG" validate "$R/ctl.json" "$TODAY"
  check "[$ENG] control-char registry: validate exits 1"      "$RC" "1"
  check "[$ENG] control-char registry: validate names it"     \
    "$(printf '%s\n' "$SERR" | grep -qE 'contains a control character' && echo yes)" "yes"
  write_registry "$R/ctltab.json" "$KD_CTL_TAB"
  run_split "$ENG" validate "$R/ctltab.json" "$TODAY"
  check "[$ENG] a tab in a registry value is rejected too"    "$RC" "1"

  # --- degenerate registry elements -----------------------------------------
  printf '[null]\n' > "$R/null-elem.json"
  run_split "$ENG" validate "$R/null-elem.json" "$TODAY"
  check "[$ENG] null registry element rejected"               "$RC" "1"
  check "[$ENG] null registry element named"                  \
    "$(printf '%s\n' "$SERR" | grep -qE '^ERROR: entry\[0\]: not a JSON object$' && echo yes)" "yes"
  run_split "$ENG" status "$R/null-elem.json" "$TODAY"
  check "[$ENG] null registry element is expired, not cleared" "$(state_of "$SOUT" '<none>')" "<absent>"
  check "[$ENG] null registry element status exits 0"          "$RC" "0"
  check "[$ENG] null registry element status row is expired"   \
    "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])[0]["state"])' "$SOUT")" "expired"
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

  # ==========================================================================
  # PARITY ACROSS THE MALFORMED AND DEGENERATE SPACE — review round 1, finding 5
  #
  # The original parity block used well-formed registries and well-formed evidence for all
  # seven of its pairs, then the report claimed byte parity was "structural". It was not:
  # two real divergences (a non-array `findings` container, and null/false evidence) lived
  # entirely outside what the suite visited. That is the same mistake this whole project
  # exists to remove - a green signal cited as evidence for something it never covered.
  # These pairs visit the space where the divergences actually were.
  # ==========================================================================
  parity_ev() { # parity_ev <label> <evidence-json>
    local label="$1" body="$2" f="$X/p.$$.json"
    printf '%s\n' "$body" > "$f"
    cmp_case "$label" status "$X/good.json" "$TODAY" --evidence "$f"
    rm -f "$f"
  }
  parity_ev "evidence: findings as an object"      "$EV_FINDINGS_OBJECT"
  parity_ev "evidence: findings as a string"       "$EV_FINDINGS_STRING"
  parity_ev "evidence: findings element not object" "$EV_FINDINGS_ELEM"
  parity_ev "evidence: navigations as an object"   "$EV_NAVS_OBJECT"
  parity_ev "evidence: navigations as a string"    "$EV_NAVS_STRING"
  parity_ev "evidence: navigations element not object" "$EV_NAVS_ELEM"
  parity_ev "evidence: top level null"             "$EV_TOP_NULL"
  parity_ev "evidence: top level false"            "$EV_TOP_FALSE"
  parity_ev "evidence: top level string"           "$EV_TOP_STRING"
  parity_ev "evidence: top level array"            "$EV_TOP_ARRAY"
  parity_ev "evidence: unparseable"                "$EV_NOT_JSON"
  parity_ev "evidence: empty object"               "$EV_TOP_EMPTY_OBJ"
  parity_ev "evidence: null containers"            "$EV_NULL_CONTAINERS"
  parity_ev "evidence: navigation with no url"     "$EV_NAV_NO_URL"
  parity_ev "evidence: empty arrays"               "$EV_EMPTY"
  parity_ev "evidence: statusClass wrong case"     "$EV_FATAL_WRONG_CASE"
  parity_ev "evidence: 2xx nav + fatal finding"    "$EV_2XX_WITH_FATAL"
  parity_ev "evidence: 5xx nav only"               "$EV_NAV_5XX"

  # degenerate REGISTRIES, both subcommands
  write_registry "$X/ctl.json" "$KD_CTL_FORGE"
  cmp_case "registry: control characters (status)"   status   "$X/ctl.json" "$TODAY"
  cmp_case "registry: control characters (validate)" validate "$X/ctl.json" "$TODAY"
  printf '[null,"boom",3]\n' > "$X/degen.json"
  cmp_case "registry: non-object elements (validate)" validate "$X/degen.json" "$TODAY"
  cmp_case "registry: non-object elements (status)"   status   "$X/degen.json" "$TODAY"
  printf '{"id":"KD-1"}\n' > "$X/obj.json"
  cmp_case "registry: not an array (validate)"       validate "$X/obj.json" "$TODAY"
  cmp_case "registry: not an array (status)"         status   "$X/obj.json" "$TODAY"
  printf 'not json\n' > "$X/bad.json"
  cmp_case "registry: unparseable (validate)"        validate "$X/bad.json" "$TODAY"
  cmp_case "registry: unparseable (status)"          status   "$X/bad.json" "$TODAY"
  write_registry "$X/root.json" "$KD_ROOT_SURFACE"
  printf '%s\n' "$EV_NAV_NO_URL" > "$X/nourl.json"
  cmp_case "registry: '/' surface vs url-less nav"   status   "$X/root.json" "$TODAY" --evidence "$X/nourl.json"
  # argument-level degenerate cases
  cmp_case "args: malformed today"                   validate "$X/good.json" "23-09-2026"
  cmp_case "args: missing registry file"             status   "$X/absent.json" "$TODAY"
fi

echo
echo "known-defects tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
