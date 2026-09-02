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

  echo "note - jq-fallback dual-engine sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
