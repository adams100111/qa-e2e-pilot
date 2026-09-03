#!/usr/bin/env bash
# Tests for scripts/provenance.sh (Plan H2 Task 3, spec §5.4) + the
# --source-ref addition to skills/checkpointing-qa-memory/scripts/record-evidence.sh.
#
# Covers: a bake whose readBack is CONTAINED in a captured toolstream
# responseBody -> bound; a bake whose value is in NO captured response ->
# unbound (the forgery signal); no toolstream file at all -> no-toolstream
# (a degrade, distinct from unbound); an action-trace whose sessionCalls
# correspond to a captured browser_* call -> bound, an EXPLICITLY EMPTY
# sessionCalls -> unbound (the AC-1 forged-trace pattern); an explicit
# provenance.sourceRef resolving to a real toolstream entry -> bound
# (bypassing containment even when the value itself is nowhere in the
# toolstream), a dangling sourceRef -> unbound. Every provenance.sh
# assertion runs under BOTH jq and the QA_ENGINE=python3 fallback (provenance.sh
# honors QA_ENGINE the same way toolstream.sh does); one additional sub-case
# exercises record-evidence.sh's --source-ref writer itself under the
# python3-fallback (jq masked from PATH), since record-evidence.sh does NOT
# honor QA_ENGINE (same idiom as tests/checkpoint/run.sh's fakebin cases).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROV="$HERE/../../scripts/provenance.sh"
TOOLSTREAM="$HERE/../../scripts/toolstream.sh"
REC="$HERE/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixture setup (run r1): a toolstream with two captured events — a Bash
# call whose responseBody carries a real backend read-back value, and a
# captured browser_click — plus a bake artifact whose value is genuinely
# contained, one whose value is nowhere in the toolstream (forged), and two
# action-trace artifacts (matching session call / explicitly empty).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append r1 '{"tool":"Bash","args":{"command":"curl .../api/founders/1"},"resultDigest":{"len":0,"sha256":"x"},"responseBody":"{\"id\":1,\"name\":\"Alice Founder\",\"equity\":42}"}' >/dev/null )
SEQ1="$(jq -r '.seq' < "$WORK/.qa/runs/r1/toolstream.jsonl" | sed -n 1p)"
( cd "$WORK" && bash "$TOOLSTREAM" append r1 '{"tool":"mcp__plugin_playwright_playwright__browser_click","args":{"element":"Add founder","ref":"e12"},"resultDigest":{"len":0,"sha256":"y"},"responseBody":""}' >/dev/null )

BAKE_BOUND="$( cd "$WORK" && bash "$REC" r1 C1 bake --read-back '{"name":"Alice Founder","equity":42}' --multiplicity 1 )"
BAKE_UNBOUND="$( cd "$WORK" && bash "$REC" r1 C2 bake --read-back '{"name":"Ghost Value Not Captured 999"}' --multiplicity 1 )"
ACTION_BOUND="$( cd "$WORK" && bash "$REC" r1 C4 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click();"}]' )"
ACTION_UNBOUND="$( cd "$WORK" && bash "$REC" r1 C5 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[]' )"
BAKE_SOURCEREF_BOUND="$( cd "$WORK" && bash "$REC" r1 C6 bake --read-back '{"anything":"NOT-IN-TOOLSTREAM-XYZ"}' --multiplicity 1 --source-ref "seq:${SEQ1}" )"
BAKE_SOURCEREF_DANGLING="$( cd "$WORK" && bash "$REC" r1 C7 bake --read-back '{"anything":"NOT-IN-TOOLSTREAM-XYZ"}' --multiplicity 1 --source-ref "seq:9999" )"

# run r3: evidence recorded, but NO toolstream.jsonl ever written for it.
BAKE_NOTOOLSTREAM="$( cd "$WORK" && bash "$REC" r3 C1 bake --read-back '{"x":1}' --multiplicity 1 )"

run_check() { # <engine: "" | python3> <run-id> <artifact-rel-path (relative to the run dir)>
  local engine="$1" run="$2" artifact="$3"
  if [[ -n "$engine" ]]; then
    ( cd "$WORK" && QA_ENGINE="$engine" bash "$PROV" check "$run" ".qa/runs/$run/$artifact" )
  else
    ( cd "$WORK" && bash "$PROV" check "$run" ".qa/runs/$run/$artifact" )
  fi
}

for ENGINE in "" python3; do
  LABEL="${ENGINE:-jq(default)}"

  check "[$LABEL] bake containment -> bound" \
    "$(run_check "$ENGINE" "r1" "$BAKE_BOUND")" "bound"

  check "[$LABEL] bake no matching capture -> unbound (forgery signal)" \
    "$(run_check "$ENGINE" "r1" "$BAKE_UNBOUND")" "unbound"

  check "[$LABEL] no toolstream file at all -> no-toolstream (degrade, not unbound)" \
    "$(run_check "$ENGINE" "r3" "$BAKE_NOTOOLSTREAM")" "no-toolstream"

  check "[$LABEL] action-trace sessionCalls matching a captured browser_* call -> bound" \
    "$(run_check "$ENGINE" "r1" "$ACTION_BOUND")" "bound"

  check "[$LABEL] action-trace with explicitly empty sessionCalls -> unbound (AC-1 pattern)" \
    "$(run_check "$ENGINE" "r1" "$ACTION_UNBOUND")" "unbound"

  check "[$LABEL] explicit sourceRef resolving to a real toolstream entry -> bound (bypasses containment)" \
    "$(run_check "$ENGINE" "r1" "$BAKE_SOURCEREF_BOUND")" "bound"

  check "[$LABEL] dangling sourceRef (no such captured seq) -> unbound" \
    "$(run_check "$ENGINE" "r1" "$BAKE_SOURCEREF_DANGLING")" "unbound"
done

# ---------------------------------------------------------------------------
# Watch (a): containment handles readBack as a SCALAR, an OBJECT (key or
# leaf), and an ARRAY (element) — three separate artifacts, one per shape,
# each genuinely contained in a captured responseBody.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append shapes '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"z"},"responseBody":"{\"founders\":[{\"id\":7,\"equityPct\":33.5}],\"scalarField\":\"exact-scalar-marker\"}"}' >/dev/null )

BAKE_SCALAR="$( cd "$WORK" && bash "$REC" shapes S1 bake --read-back '"exact-scalar-marker"' --multiplicity 1 )"
check "[scalar] readBack scalar contained -> bound" \
  "$(run_check "" "shapes" "$BAKE_SCALAR")" "bound"

BAKE_OBJ_KEY="$( cd "$WORK" && bash "$REC" shapes S2 bake --read-back '{"equityPct":33.5,"unrelatedKey":"nowhere"}' --multiplicity 1 )"
check "[object] readBack leaf value contained -> bound" \
  "$(run_check "" "shapes" "$BAKE_OBJ_KEY")" "bound"

BAKE_ARRAY="$( cd "$WORK" && bash "$REC" shapes S3 bake --read-back '[{"id":7}]' --multiplicity N )"
check "[array] readBack element leaf contained -> bound" \
  "$(run_check "" "shapes" "$BAKE_ARRAY")" "bound"

# ---------------------------------------------------------------------------
# Back-compat: record-evidence.sh WITHOUT --source-ref never writes a
# `provenance` key at all (today's exact shape) — bake, probe, action-trace.
# ---------------------------------------------------------------------------
check "back-compat: bake without --source-ref has no provenance key" \
  "$(jq -e 'has("provenance")' "$WORK/.qa/runs/r1/$BAKE_BOUND" 2>&1)" "false"
PROBE_NOREF="$( cd "$WORK" && bash "$REC" r1 CP1 probe --status 200 --shape '{"ok":true}' --ok true )"
check "back-compat: probe without --source-ref has no provenance key" \
  "$(jq -e 'has("provenance")' "$WORK/.qa/runs/r1/$PROBE_NOREF" 2>&1)" "false"
check "back-compat: action-trace without --source-ref has no provenance key" \
  "$(jq -e 'has("provenance")' "$WORK/.qa/runs/r1/$ACTION_BOUND" 2>&1)" "false"

# provenance shape when --source-ref IS given: {sourceRef, boundAt}
check "provenance shape: sourceRef recorded verbatim" \
  "$(jq -r '.provenance.sourceRef' "$WORK/.qa/runs/r1/$BAKE_SOURCEREF_BOUND")" "seq:${SEQ1}"
check "provenance shape: boundAt is an ISO-8601 UTC timestamp" \
  "$(jq -r '.provenance.boundAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$WORK/.qa/runs/r1/$BAKE_SOURCEREF_BOUND")" "true"

# ---------------------------------------------------------------------------
# probe kind: shape/status containment -> bound; unrelated -> unbound.
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append r1 '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"p"},"responseBody":"{\"error\":\"Forbidden\",\"code\":403}"}' >/dev/null )
PROBE_BOUND="$( cd "$WORK" && bash "$REC" r1 CP2 probe --status 403 --shape '{"error":"Forbidden"}' --ok true )"
check "probe: status/shape contained in a captured response -> bound" \
  "$(run_check "" "r1" "$PROBE_BOUND")" "bound"
PROBE_UNBOUND="$( cd "$WORK" && bash "$REC" r1 CP3 probe --status 999 --shape '{"nonexistent":"nope-never-captured-anywhere"}' --ok false )"
check "probe: value in no captured response -> unbound" \
  "$(run_check "" "r1" "$PROBE_UNBOUND")" "unbound"

# ---------------------------------------------------------------------------
# record-evidence.sh python3-fallback: --source-ref writer produces the SAME
# provenance shape when jq is masked from PATH (mirrors tests/checkpoint's
# fakebin idiom — record-evidence.sh does not honor QA_ENGINE, only PATH).
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc python3 tr head awk node; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  PY_BAKE_REF="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$REC" r1 CPY1 bake --read-back '{"a":1}' --multiplicity 1 --source-ref "seq:${SEQ1}" )"
  check "py-fallback: --source-ref writer produces a provenance key" \
    "$(jq -e 'has("provenance")' "$WORK/.qa/runs/r1/$PY_BAKE_REF")" "true"
  check "py-fallback: --source-ref value recorded verbatim" \
    "$(jq -r '.provenance.sourceRef' "$WORK/.qa/runs/r1/$PY_BAKE_REF")" "seq:${SEQ1}"
  check "py-fallback: sourceRef resolves bound (provenance.sh QA_ENGINE=python3)" \
    "$(run_check "python3" "r1" "$PY_BAKE_REF")" "bound"

  PY_BAKE_NOREF="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$REC" r1 CPY2 bake --read-back '{"a":1}' --multiplicity 1 )"
  check "py-fallback: bake WITHOUT --source-ref still has no provenance key" \
    "$(jq -e 'has("provenance")' "$WORK/.qa/runs/r1/$PY_BAKE_NOREF" 2>&1)" "false"

  echo "note - py-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - py-fallback sub-case: jq or python3 not present on this host"
fi

# ---------------------------------------------------------------------------
# Fix: action-trace forgery paths.
#   Fix 1 (Critical) — jq's call_matches human-path branch used to rebind
#     `.` before contains(), making "$t contains $t" -- vacuously always
#     true on ANY captured browser_* call, even a bare navigate.
#   Fix 2 (Important) — the `class` catch-all used to bind on ANY captured
#     browser_* call regardless of class, letting a forged
#     `class:"other"` sessionCall (the real value parse-session-log.js
#     emits for navigate/wait) bind on a navigate-only run.
# run r2: toolstream has ONLY navigation/observation captures -- browser_navigate
# and browser_snapshot -- deliberately NO interaction tool (click/type/...).
# ---------------------------------------------------------------------------
( cd "$WORK" && bash "$TOOLSTREAM" append r2 '{"tool":"mcp__plugin_playwright_playwright__browser_navigate","args":{"url":"https://example.test/"},"resultDigest":{"len":0,"sha256":"n"},"responseBody":""}' >/dev/null )
( cd "$WORK" && bash "$TOOLSTREAM" append r2 '{"tool":"mcp__plugin_playwright_playwright__browser_snapshot","args":{},"resultDigest":{"len":0,"sha256":"s"},"responseBody":""}' >/dev/null )

ACTION_FORGED_HUMANPATH="$( cd "$WORK" && bash "$REC" r2 F1 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"fabricated -- never actually run"}]' )"
ACTION_FORGED_OTHER="$( cd "$WORK" && bash "$REC" r2 F2 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[{"class":"other","mutating":false,"code":"fabricated -- never actually run"}]' )"

# run r4: a genuine captured interaction (browser_click) and a genuine
# captured browser_evaluate, to prove the tightened check does NOT produce
# false-unbound on real activity.
( cd "$WORK" && bash "$TOOLSTREAM" append r4 '{"tool":"mcp__plugin_playwright_playwright__browser_click","args":{"element":"Submit","ref":"e1"},"resultDigest":{"len":0,"sha256":"c"},"responseBody":""}' >/dev/null )
( cd "$WORK" && bash "$TOOLSTREAM" append r4 '{"tool":"mcp__plugin_playwright_playwright__browser_evaluate","args":{"function":"() => document.title"},"resultDigest":{"len":0,"sha256":"e"},"responseBody":""}' >/dev/null )

ACTION_LEGIT_HUMANPATH="$( cd "$WORK" && bash "$REC" r4 F3 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"await page.locator(\"#submit\").click();"}]' )"
ACTION_LEGIT_EVALUATE="$( cd "$WORK" && bash "$REC" r4 F4 action-trace --steps '[{"tool":"browser_evaluate","phase":"act"}]' --session-calls '[{"class":"evaluate","mutating":false,"code":"await page.evaluate(() => document.title);"}]' )"

for ENGINE in "" python3; do
  LABEL="${ENGINE:-jq(default)}"

  check "[$LABEL] Fix 1: forged class:human-path sessionCall + navigate-only toolstream (no interaction) -> unbound" \
    "$(run_check "$ENGINE" "r2" "$ACTION_FORGED_HUMANPATH")" "unbound"

  check "[$LABEL] Fix 2: forged class:other sessionCall + navigate-only toolstream -> unbound (no catch-all)" \
    "$(run_check "$ENGINE" "r2" "$ACTION_FORGED_OTHER")" "unbound"

  check "[$LABEL] legit class:human-path sessionCall + captured browser_click -> bound (no false-unbound)" \
    "$(run_check "$ENGINE" "r4" "$ACTION_LEGIT_HUMANPATH")" "bound"

  check "[$LABEL] legit class:evaluate sessionCall + captured browser_evaluate -> bound" \
    "$(run_check "$ENGINE" "r4" "$ACTION_LEGIT_EVALUATE")" "bound"
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
