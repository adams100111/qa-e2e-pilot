#!/usr/bin/env bash
# Tests for validate-checklist-json.sh — the structural validator for the
# checklist.json schema emitted by generating-qa-checklist (Plan H1 Task 2).
# Covers: well-formed (incl. a mutating criterion with assertedState + a
# read-only one), missing id, bad kind enum value, assertedState missing
# entity, requiredKinds with a bogus kind, duplicate id, empty array
# (vacuously valid), non-array top-level, and malformed JSON. Dual-engine
# (jq preferred, python3 fallback via a jq-masked fakebin, matching
# tests/required-kinds/run.sh's idiom).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/../../skills/generating-qa-checklist/scripts/validate-checklist-json.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
check_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (output did not contain '$3': $2)"; FAIL=$((FAIL+1)); fi; }
# Parity compares two engines; NEITHER side is the "wanted" one, so it must
# not borrow check()'s got/want wording.
check_parity() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (ENGINES DIVERGED -- jq printed: '$2' | python3 printed: '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Well-formed: one mutating criterion carrying assertedState, one read-only
# criterion with assertedState explicitly null.
cat > "$WORK/wellformed.json" <<'EOF'
[
  {
    "id": "C-FOUNDERS-01",
    "surface": "/founders",
    "kind": "happy-path",
    "tags": ["human-action"],
    "action": "create a founder",
    "requiredKinds": ["bake", "human-action"],
    "assertedState": {"entity": "Founder", "readBackPath": "count", "expectChange": true},
    "humanAction": true
  },
  {
    "id": "C-FOUNDERS-02",
    "surface": "/founders",
    "kind": "loading-state",
    "tags": ["read-only"],
    "action": "view the founders list while loading",
    "requiredKinds": [],
    "assertedState": null,
    "humanAction": false
  }
]
EOF

# Minimal well-formed: only the required fields, no optional fields at all.
cat > "$WORK/minimal.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "race", "tags": [], "action": "do a race"}
]
EOF

echo '[]' > "$WORK/empty.json"

cat > "$WORK/missing-id.json" <<'EOF'
[{"surface": "/x", "kind": "happy-path", "tags": [], "action": "do x"}]
EOF

cat > "$WORK/bad-kind.json" <<'EOF'
[{"id": "C-1", "surface": "/x", "kind": "not-a-real-kind", "tags": [], "action": "do x"}]
EOF

cat > "$WORK/missing-entity.json" <<'EOF'
[{"id": "C-1", "surface": "/x", "kind": "happy-path", "tags": [], "action": "do x",
  "assertedState": {"readBackPath": "count", "expectChange": true}}]
EOF

cat > "$WORK/bogus-required-kind.json" <<'EOF'
[{"id": "C-1", "surface": "/x", "kind": "happy-path", "tags": [], "action": "do x",
  "requiredKinds": ["bake", "not-a-real-kind"]}]
EOF

cat > "$WORK/duplicate-id.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "happy-path", "tags": [], "action": "do x"},
  {"id": "C-1", "surface": "/y", "kind": "race", "tags": [], "action": "do y"}
]
EOF

echo '{"not": "an array"}' > "$WORK/non-array.json"

echo 'this is not json at all {{{' > "$WORK/malformed.json"

# ---------------------------------------------------------------------------
# jq-engine assertions (the default engine on this host)
# ---------------------------------------------------------------------------

bash "$V" "$WORK/wellformed.json" >/dev/null 2>&1; rc=$?
check "well-formed (mutating + read-only criteria) -> exit 0" "$rc" "0"

bash "$V" "$WORK/minimal.json" >/dev/null 2>&1; rc=$?
check "minimal well-formed (no optional fields) -> exit 0" "$rc" "0"

bash "$V" "$WORK/empty.json" >/dev/null 2>&1; rc=$?
check "empty array -> exit 0 (vacuously valid)" "$rc" "0"

out="$(bash "$V" "$WORK/missing-id.json" 2>&1)"; rc=$?
check "missing id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "missing id -> message names entry[0] and id" "$out" "entry[0].id"

out="$(bash "$V" "$WORK/bad-kind.json" 2>&1)"; rc=$?
check "bad kind enum value -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "bad kind -> message names entry[0] and kind" "$out" "entry[0].kind"

out="$(bash "$V" "$WORK/missing-entity.json" 2>&1)"; rc=$?
check "assertedState missing entity -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "assertedState missing entity -> message names assertedState.entity" "$out" "assertedState.entity"

out="$(bash "$V" "$WORK/bogus-required-kind.json" 2>&1)"; rc=$?
check "requiredKinds bogus kind -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "requiredKinds bogus kind -> message names requiredKinds and the bad value" "$out" "requiredKinds"
check_contains "requiredKinds bogus kind -> message names the offending value" "$out" "not-a-real-kind"

out="$(bash "$V" "$WORK/duplicate-id.json" 2>&1)"; rc=$?
check "duplicate id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "duplicate id -> message names the duplicate id" "$out" "C-1"
check_contains "duplicate id -> message says duplicate" "$out" "duplicate"

out="$(bash "$V" "$WORK/non-array.json" 2>&1)"; rc=$?
check "non-array top-level -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "non-array top-level -> message says must be a JSON array" "$out" "must be a JSON array"

out="$(bash "$V" "$WORK/malformed.json" 2>&1)"; rc=$?
check "malformed JSON -> non-zero (dies clearly, does not crash)" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "malformed JSON -> message says invalid JSON" "$out" "invalid JSON"

bash "$V" >/dev/null 2>&1; rc=$?
check "no args -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

bash "$V" "$WORK/does-not-exist.json" >/dev/null 2>&1; rc=$?
check "nonexistent file -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# Error-honesty invariants (plan 2026-09-23, Task 3): a criterion may not
# assert that the application FAILED. Two layers — a reserved health
# namespace on `expect.path`, and two reserved prose phrases in the
# oracle/expect fields ONLY (never `action`). 3xx/4xx stay legal (spec §4
# carve-out: an authorization refusal is the application WORKING).
# ---------------------------------------------------------------------------

# The EC10 shape VERBATIM from the originating incident (spec §1): the
# pinned value is the STRING "false", not a boolean, and oracleSource is
# "human". This is incident regression case 1.
cat > "$WORK/ec10-string-false.json" <<'EOF'
[
  {
    "id": "EC10",
    "surface": "/challenges/1/gates",
    "kind": "business-rule",
    "tags": [],
    "action": "open the gates surface as an authorized admin",
    "fixture": {
      "expect": {
        "path": "page.rendersWithoutServerError",
        "value": "false",
        "tolerance": 0,
        "oracleSource": "human"
      }
    }
  }
]
EOF

cat > "$WORK/ec10-boolean-false.json" <<'EOF'
[
  {
    "id": "EC10",
    "surface": "/challenges/1/gates",
    "kind": "business-rule",
    "tags": [],
    "action": "open the gates surface as an authorized admin",
    "fixture": {
      "expect": {
        "path": "page.rendersWithoutServerError",
        "value": false,
        "tolerance": 0,
        "oracleSource": "human"
      }
    }
  }
]
EOF

cat > "$WORK/page-crashed-true.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "business-rule", "tags": [], "action": "open x",
   "fixture": {"expect": {"path": "page.crashed", "value": true, "tolerance": 0, "oracleSource": "human"}}}
]
EOF

cat > "$WORK/console-haserror-true.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "business-rule", "tags": [], "action": "open x",
   "fixture": {"expect": {"path": "console.hasError", "value": true, "tolerance": 0, "oracleSource": "human"}}}
]
EOF

cat > "$WORK/http-status-500.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "business-rule", "tags": [], "action": "open x",
   "fixture": {"expect": {"path": "http.status", "value": 500, "tolerance": 0, "oracleSource": "human"}}}
]
EOF

# The §4 carve-out: an authorization refusal (302 redirect to login, or a
# 403) is the application WORKING and must keep validating.
cat > "$WORK/http-status-302.json" <<'EOF'
[
  {"id": "EC9", "surface": "/challenges/1/gates", "kind": "business-rule", "tags": ["role-sensitive"],
   "action": "open the gates surface as an unauthorized evaluator",
   "fixture": {"expect": {"path": "http.status", "value": 302, "tolerance": 0, "oracleSource": "human"}}}
]
EOF

cat > "$WORK/http-status-403.json" <<'EOF'
[
  {"id": "EC11", "surface": "/challenges/1/gates", "kind": "business-rule", "tags": ["role-sensitive"],
   "action": "POST a gate decision as an unauthorized evaluator",
   "fixture": {"expect": {"path": "http.status", "value": 403, "tolerance": 0, "oracleSource": "human"}}}
]
EOF

# Fix round 1, item 3: `expected to fail` is BEHAVIOUR language, not process
# language. "the save is expected to fail with a validation error" is a
# legitimate error-state oracle — a 4xx validation rejection is the
# application WORKING (spec §4). It must validate even in `oracle`, the
# natural field for an expectation. (It is demoted to a /qa-analyze
# plan-defect flag, Lane M / Task 13.)
cat > "$WORK/prose-expected-to-fail.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "error-state", "tags": [],
   "action": "Submit the form with a blank title",
   "oracle": "The save is Expected To Fail with a 422 validation error and the row is not written."}
]
EOF

cat > "$WORK/prose-deferred-by-design.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "happy-path", "tags": [], "action": "open the gates surface",
   "oracle": "Deferred by design - not actionable within this QA pass's scope."}
]
EOF

# `action` is where an author legitimately describes a non-rendering state.
# It is NEVER scanned — not even when it literally contains a reserved
# phrase.
cat > "$WORK/prose-in-action-only.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "happy-path", "tags": [],
   "action": "View the evaluators list; this list does not render until the challenge reaches Judging"},
  {"id": "C-2", "surface": "/y", "kind": "error-state", "tags": [],
   "action": "Submit the form with a blank title; the save is expected to fail with a validation error"},
  {"id": "C-3", "surface": "/z", "kind": "happy-path", "tags": [],
   "action": "Open the archive tab, which is deferred by design in this release"}
]
EOF

# Violation on entry index 1, so the index in the message is load-bearing.
cat > "$WORK/second-entry-violates.json" <<'EOF'
[
  {"id": "C-1", "surface": "/x", "kind": "happy-path", "tags": [], "action": "open x"},
  {"id": "C-2", "surface": "/y", "kind": "business-rule", "tags": [], "action": "open y",
   "fixture": {"expect": {"path": "page.rendersWithoutServerError", "value": "false", "tolerance": 0, "oracleSource": "human"}}}
]
EOF

out="$(bash "$V" "$WORK/ec10-boolean-false.json" 2>&1)"; rc=$?
check "test_rejects_renders_without_server_error_false_boolean -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_rejects_renders_without_server_error_false_boolean -> names the reserved path" "$out" "page.rendersWithoutServerError"

out="$(bash "$V" "$WORK/ec10-string-false.json" 2>&1)"; rc=$?
check "test_rejects_renders_without_server_error_false_string -> non-zero (EC10 verbatim)" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_rejects_renders_without_server_error_false_string -> names the reserved path" "$out" "page.rendersWithoutServerError"
check_contains "test_rejects_renders_without_server_error_false_string -> ends with the remediation pointer" "$out" "— move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)"

out="$(bash "$V" "$WORK/page-crashed-true.json" 2>&1)"; rc=$?
check "test_rejects_page_crashed_true -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_rejects_page_crashed_true -> names the reserved path" "$out" "page.crashed"

out="$(bash "$V" "$WORK/console-haserror-true.json" 2>&1)"; rc=$?
check "test_rejects_console_has_error_true -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_rejects_console_has_error_true -> names the reserved path" "$out" "console.hasError"

out="$(bash "$V" "$WORK/http-status-500.json" 2>&1)"; rc=$?
check "test_rejects_http_status_500 -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_rejects_http_status_500 -> names the reserved path" "$out" "http.status"

bash "$V" "$WORK/http-status-302.json" >/dev/null 2>&1; rc=$?
check "test_accepts_http_status_302 -> exit 0 (authz refusal is the app WORKING)" "$rc" "0"

bash "$V" "$WORK/http-status-403.json" >/dev/null 2>&1; rc=$?
check "test_accepts_http_status_403 -> exit 0 (authz refusal is the app WORKING)" "$rc" "0"

bash "$V" "$WORK/prose-expected-to-fail.json" >/dev/null 2>&1; rc=$?
check "test_accepts_prose_expected_to_fail_in_oracle -> exit 0 (behaviour language, a legitimate error-state oracle)" "$rc" "0"

out="$(bash "$V" "$WORK/prose-deferred-by-design.json" 2>&1)"; rc=$?
check "test_rejects_prose_deferred_by_design_in_oracle -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_rejects_prose_deferred_by_design_in_oracle -> names entry[0].oracle" "$out" "entry[0].oracle"
check_contains "test_rejects_prose_deferred_by_design_in_oracle -> quotes the phrase" "$out" "deferred by design"

bash "$V" "$WORK/prose-in-action-only.json" >/dev/null 2>&1; rc=$?
check "test_accepts_prose_in_action_field -> exit 0 (action is NEVER scanned)" "$rc" "0"

out="$(bash "$V" "$WORK/second-entry-violates.json" 2>&1)"; rc=$?
check "test_error_line_names_entry_index_and_field -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check_contains "test_error_line_names_entry_index_and_field -> one-line-per-violation ERROR form naming entry[1] and the field" "$out" "ERROR: entry[1].fixture.expect"

# ---------------------------------------------------------------------------
# Fix round 1, items 1 + 2: value normalisation, and DUAL-ENGINE PARITY.
#
# The two engines must reach the same verdict AND print the same bytes for
# every shape in the matrix below. jq is the preferred engine, so a
# divergence where jq is permissive is a silent route-around of the whole
# check: legality would depend on QA_ENGINE and what is on PATH. Every case
# here is asserted on jq, on python3, and for byte-identical output.
# ---------------------------------------------------------------------------

DUAL=0
# The default-engine label must name the engine ACTUALLY exercised. Labelling
# a python-only host's run "norm[jq]" is exactly the green-signal-that-does-
# not-cover-what-it-claims failure this plan exists to remove.
if command -v jq >/dev/null 2>&1; then DEFAULT_ENGINE="jq"
elif command -v python3 >/dev/null 2>&1; then DEFAULT_ENGINE="py"
else DEFAULT_ENGINE="none"; fi

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(type -P bash)"
  FAKEBIN="$WORK/fakebin-no-jq"
  mkdir -p "$FAKEBIN"
  for tool in bash python3 cat dirname basename mkdir sort; do
    TOOL_PATH="$(type -P "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done
  DUAL=1
fi

# health_case <label> <path-json> <value-json> <reject|accept>
health_case() {
  local label="$1" pathv="$2" valv="$3" want="$4"
  local f="$WORK/health-case.json" out_j out_p rc_j rc_p got_j got_p
  printf '[{"id":"P-1","surface":"/x","kind":"business-rule","tags":[],"action":"open the surface","fixture":{"expect":{"path":%s,"value":%s,"tolerance":0,"oracleSource":"human"}}}]\n' \
    "$pathv" "$valv" > "$f"
  out_j="$(bash "$V" "$f" 2>&1)"; rc_j=$?
  got_j="$([[ $rc_j -ne 0 ]] && echo reject || echo accept)"
  check "norm[$DEFAULT_ENGINE]: $label -> $want" "$got_j" "$want"
  if [[ "$DUAL" -eq 1 ]]; then
    out_p="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$f" 2>&1)"; rc_p=$?
    got_p="$([[ $rc_p -ne 0 ]] && echo reject || echo accept)"
    check "norm[py]: $label -> $want" "$got_p" "$want"
    check_parity "parity: $label -> both engines print identical bytes" "$out_j" "$out_p"
  fi
}

if [[ "$DUAL" -eq 1 ]]; then
  echo "note - dual-engine parity matrix: RAN (every case asserted on jq, on python3, and for identical bytes)"
else
  echo "SKIP - dual-engine parity matrix: jq or python3 not present on this host, the engines were NOT compared"
  echo "SKIP - the norm[$DEFAULT_ENGINE] cases below exercise ONE engine only; a divergence CANNOT be detected by this run"
fi

# --- the reported divergence: jq's tonumber vs python's float() ------------
health_case "http.status 500 (number)"            '"http.status"' '500'        reject
health_case "http.status \"500\" (string)"        '"http.status"' '"500"'      reject
health_case "http.status \" 500 \" (padded both)" '"http.status"' '" 500 "'    reject
health_case "http.status \"500 \" (trailing ws)"  '"http.status"' '"500 "'     reject
health_case "http.status \" 500\" (leading ws)"   '"http.status"' '" 500"'     reject
health_case "http.status \"\\t500\\n\" (tab/nl)"  '"http.status"' '"\t500\n"'  reject
health_case "http.status \"1_000\" (underscored)" '"http.status"' '"1_000"'    accept

# --- TRIM-SET GUARD -------------------------------------------------------
# These pin the deliberate choice of a 4-character trim set (SP/TAB/LF/CR)
# over each language's own idea of whitespace. VT, FF, NEL and NBSP are
# stripped by python's bare `str.strip()` but NOT by jq's set, so swapping
# `_trim_ws` back to `str.strip()` makes python reject these while jq accepts
# them — reintroducing exactly the jq-permissive/python-strict split that fix
# round 1 closed. Without these cases that mutation is invisible: the suite
# reported PASS=217 FAIL=0 with it applied. A deliberate design decision with
# no test is a comment, not a guarantee.
health_case "http.status VT+500 (\\u000b, python-only ws)"   '"http.status"' '"\u000b500"' accept
health_case "http.status FF+500 (\\u000c, python-only ws)"   '"http.status"' '"\u000c500"' accept
health_case "http.status NBSP+500 (\\u00a0, python-only ws)" '"http.status"' '" 500"' accept
health_case "http.status NEL+500 (\\u0085, python-only ws)"  '"http.status"' '"\u0085500"' accept
health_case "http.status 500+VT (\\u000b trailing)"          '"http.status"' '"500\u000b"' accept
# ...and the four characters that ARE in the trim set must still be trimmed,
# so the guard cannot be satisfied by trimming nothing at all.
health_case "http.status SP+500 (in the trim set)"           '"http.status"' '" 500"'      reject
health_case "http.status TAB+500 (in the trim set)"          '"http.status"' '"\t500"'     reject
health_case "http.status LF+500 (in the trim set)"           '"http.status"' '"\n500"'     reject
health_case "http.status CR+500 (in the trim set)"           '"http.status"' '"\r500"'     reject

# --- UNICODE DIGITS: a DELIBERATE accept ----------------------------------
# Both engines compare against ASCII 48..57 only, so an Arabic-Indic or
# fullwidth digit spelling is not a number and is accepted. Parity holds.
# Pinned so the accept stays deliberate rather than becoming a surprise.
health_case "http.status Arabic-Indic 500 (deliberate accept)" '"http.status"' '"٥٠٠"' accept
health_case "http.status fullwidth 500 (deliberate accept)"    '"http.status"' '"５００"' accept
health_case "http.status \"+500\" (signed)"       '"http.status"' '"+500"'     reject
health_case "http.status 500.0 (json float)"      '"http.status"' '500.0'      reject
health_case "http.status \"500.0\" (float string)" '"http.status"' '"500.0"'   reject
health_case "http.status 503.5 (non-integral)"    '"http.status"' '503.5'      reject
health_case "http.status \"5e2\" (exponent)"      '"http.status"' '"5e2"'      accept
health_case "http.status \"abc\""                 '"http.status"' '"abc"'      accept
health_case "http.status null"                    '"http.status"' 'null'       accept
health_case "http.status true (boolean)"          '"http.status"' 'true'       accept

# --- the carve-out, restated across spellings ------------------------------
health_case "http.status 302"                     '"http.status"' '302'        accept
health_case "http.status \" 302 \""               '"http.status"' '" 302 "'    accept
health_case "http.status 403"                     '"http.status"' '403'        accept
health_case "http.status 499 (boundary below)"    '"http.status"' '499'        accept
health_case "http.status \"499\""                 '"http.status"' '"499"'      accept
health_case "http.status 200"                     '"http.status"' '200'        accept

# --- item 2: the falsy/truthy route-around ---------------------------------
health_case "rendersWithoutServerError false"        '"page.rendersWithoutServerError"' 'false'     reject
health_case "rendersWithoutServerError \"false\""    '"page.rendersWithoutServerError"' '"false"'   reject
health_case "rendersWithoutServerError \"FALSE\""    '"page.rendersWithoutServerError"' '"FALSE"'   reject
health_case "rendersWithoutServerError \" false \""  '"page.rendersWithoutServerError"' '" false "' reject
health_case "rendersWithoutServerError 0 (number)"   '"page.rendersWithoutServerError"' '0'         reject
health_case "rendersWithoutServerError \"0\""        '"page.rendersWithoutServerError"' '"0"'       reject
health_case "rendersWithoutServerError true (legal)" '"page.rendersWithoutServerError"' 'true'      accept
health_case "rendersWithoutServerError 1 (legal)"    '"page.rendersWithoutServerError"' '1'         accept
health_case "page.crashed true"                      '"page.crashed"' 'true'        reject
health_case "page.crashed \"true\""                  '"page.crashed"' '"true"'      reject
health_case "page.crashed \"TRUE\""                  '"page.crashed"' '"TRUE"'      reject
health_case "page.crashed 1 (number)"                '"page.crashed"' '1'           reject
health_case "page.crashed \"1\""                     '"page.crashed"' '"1"'         reject
health_case "page.crashed false (legal)"             '"page.crashed"' 'false'       accept
health_case "page.crashed 0 (legal)"                 '"page.crashed"' '0'           accept
health_case "console.hasError true"                  '"console.hasError"' 'true'    reject
health_case "console.hasError 1 (number)"            '"console.hasError"' '1'       reject
health_case "console.hasError \"yes\" (not truthy)"  '"console.hasError"' '"yes"'   accept
health_case "console.hasError false (legal)"         '"console.hasError"' 'false'   accept

# --- item 2: a padded PATH must still be caught ----------------------------
health_case "path \"http.status \" (trailing ws)"  '"http.status "' '500'   reject
health_case "path \" page.crashed\" (leading ws)"  '" page.crashed"' 'true' reject
# ...but the path is NOT case-folded: a fuzzy path match would risk
# rejecting a legitimate domain path, so a differently-cased path is a
# different (unreserved) path.
health_case "path \"HTTP.STATUS\" (not case-folded)" '"HTTP.STATUS"' '500'  accept

# --- paths outside the namespace stay untouched ----------------------------
health_case "counts.evaluators 2 (domain path)"     '"counts.evaluators"' '2'      accept
health_case "counts.evaluators 500 (domain path)"   '"counts.evaluators"' '500'    accept
health_case "totals.errors true (domain path)"      '"totals.errors"' 'true'       accept

# test_existing_validations_unchanged — the suite's pre-existing fixtures
# keep their exact exit-code behaviour after the new layers land.
bash "$V" "$WORK/wellformed.json" >/dev/null 2>&1; rc=$?
check "test_existing_validations_unchanged: wellformed -> exit 0" "$rc" "0"
bash "$V" "$WORK/minimal.json" >/dev/null 2>&1; rc=$?
check "test_existing_validations_unchanged: minimal -> exit 0" "$rc" "0"
bash "$V" "$WORK/empty.json" >/dev/null 2>&1; rc=$?
check "test_existing_validations_unchanged: empty array -> exit 0" "$rc" "0"
bash "$V" "$WORK/missing-id.json" >/dev/null 2>&1; rc=$?
check "test_existing_validations_unchanged: missing id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
bash "$V" "$WORK/duplicate-id.json" >/dev/null 2>&1; rc=$?
check "test_existing_validations_unchanged: duplicate id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
bash "$V" "$WORK/bogus-required-kind.json" >/dev/null 2>&1; rc=$?
check "test_existing_validations_unchanged: bogus requiredKinds -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

# ---------------------------------------------------------------------------
# python3-fallback pass: mask jq from PATH, re-run every case, same
# expectations. Dual-engine agreement is the point.
# ---------------------------------------------------------------------------

if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(type -P bash)"
  FAKEBIN="$WORK/fakebin-no-jq"
  mkdir -p "$FAKEBIN"
  for tool in bash python3 cat dirname basename mkdir sort; do
    TOOL_PATH="$(type -P "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/wellformed.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: well-formed -> exit 0" "$rc" "0"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/minimal.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: minimal well-formed -> exit 0" "$rc" "0"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/empty.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: empty array -> exit 0" "$rc" "0"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/missing-id.json" 2>&1)"; rc=$?
  check "py-fallback: missing id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: missing id -> names entry[0].id" "$out" "entry[0].id"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/bad-kind.json" 2>&1)"; rc=$?
  check "py-fallback: bad kind -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: bad kind -> names entry[0].kind" "$out" "entry[0].kind"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/missing-entity.json" 2>&1)"; rc=$?
  check "py-fallback: assertedState missing entity -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names assertedState.entity" "$out" "assertedState.entity"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/bogus-required-kind.json" 2>&1)"; rc=$?
  check "py-fallback: requiredKinds bogus kind -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names bogus requiredKinds value" "$out" "not-a-real-kind"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/duplicate-id.json" 2>&1)"; rc=$?
  check "py-fallback: duplicate id -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names the duplicate id" "$out" "C-1"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/non-array.json" 2>&1)"; rc=$?
  check "py-fallback: non-array top-level -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: says must be a JSON array" "$out" "must be a JSON array"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/malformed.json" 2>&1)"; rc=$?
  check "py-fallback: malformed JSON -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: says invalid JSON" "$out" "invalid JSON"

  # Error-honesty invariants must hold identically on the python3 engine.
  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/ec10-string-false.json" 2>&1)"; rc=$?
  check "py-fallback: test_rejects_renders_without_server_error_false_string -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names the reserved path" "$out" "page.rendersWithoutServerError"
  check_contains "py-fallback: ends with the remediation pointer" "$out" "— move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/ec10-boolean-false.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_rejects_renders_without_server_error_false_boolean -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/page-crashed-true.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_rejects_page_crashed_true -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/console-haserror-true.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_rejects_console_has_error_true -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/http-status-500.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_rejects_http_status_500 -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/http-status-302.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_accepts_http_status_302 -> exit 0" "$rc" "0"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/http-status-403.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_accepts_http_status_403 -> exit 0" "$rc" "0"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/prose-expected-to-fail.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_accepts_prose_expected_to_fail_in_oracle -> exit 0" "$rc" "0"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/prose-deferred-by-design.json" 2>&1)"; rc=$?
  check "py-fallback: test_rejects_prose_deferred_by_design_in_oracle -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names entry[0].oracle" "$out" "entry[0].oracle"

  PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/prose-in-action-only.json" >/dev/null 2>&1; rc=$?
  check "py-fallback: test_accepts_prose_in_action_field -> exit 0 (action is NEVER scanned)" "$rc" "0"

  out="$(PATH="$FAKEBIN" "$BASH_BIN" "$V" "$WORK/second-entry-violates.json" 2>&1)"; rc=$?
  check "py-fallback: test_error_line_names_entry_index_and_field -> non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check_contains "py-fallback: names entry[1] and the field" "$out" "ERROR: entry[1].fixture.expect"

  echo "note - jq-fallback dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
