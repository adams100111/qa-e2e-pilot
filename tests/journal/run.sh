#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
J="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0
get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# append two events → two lines, seq 1 then 2, both parse, event field preserved
( cd "$WORK" && bash "$J" append r1 '{"event":"run_started","runId":"r1"}' >/dev/null )
( cd "$WORK" && bash "$J" append r1 '{"event":"phase_entered","phase":"verify"}' >/dev/null )
JF="$WORK/.qa/runs/r1/journal.ndjson"
check "two lines"      "$(wc -l < "$JF" | tr -d ' ')"            "2"
check "seq1"           "$(sed -n 1p "$JF" | jq -r '.seq')"       "1"
check "seq2"           "$(sed -n 2p "$JF" | jq -r '.seq')"       "2"
check "event1"         "$(sed -n 1p "$JF" | jq -r '.event')"     "run_started"
check "has ts"         "$(sed -n 1p "$JF" | jq -r '.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")')" "true"
check "each line json" "$(while read -r l; do echo "$l" | jq -e . >/dev/null || { echo bad; break; }; done < "$JF"; echo ok)" "ok"

# malformed append (no event field) → non-zero, no line written
( cd "$WORK" && bash "$J" append r2 '{"foo":1}' >/dev/null 2>&1 ); rc=$?
check "reject no-event rc"  "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "reject no-event file" "$([[ -f "$WORK/.qa/runs/r2/journal.ndjson" ]] && echo exists || echo none)" "none"

# atomic_write produces canonical sorted-key output and leaves no tmp
echo '{"b":2,"a":1}' | ( cd "$WORK" && bash "$J" atomic_write "$WORK/out.json" )
check "atomic keys sorted" "$(cat "$WORK/out.json")" '{"a":1,"b":2}'
check "no tmp left"        "$(ls "$WORK"/out.json.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# canonical helper sorts nested keys
check "canonical nested" "$(echo '{"z":{"y":1,"x":2},"a":3}' | ( cd "$WORK" && bash "$J" canonical ))" '{"a":3,"z":{"x":2,"y":1}}'

# --- python3-fallback pass: mask jq from PATH so has_jq() fails and has_py()
# succeeds, then re-assert four representative cases under the fallback.
# Modeled on tests/checkpoint/run.sh:88-100. Only attempted when both jq and
# python3 exist on this host, so masking jq genuinely forces the fallback
# branch instead of faking it.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  # Only symlink the exact external tools journal.sh needs, deliberately
  # excluding jq — this forces has_jq() to fail and has_py() to succeed.
  for tool in date mkdir mv rm cat dirname sed wc python3; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" append pyr1 '{"event":"run_started","runId":"pyr1"}' >/dev/null )
  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" append pyr1 '{"event":"phase_entered","phase":"verify"}' >/dev/null )
  PYJF="$WORK/.qa/runs/pyr1/journal.ndjson"
  check "py-fallback: two lines" "$(wc -l < "$PYJF" | tr -d ' ')" "2"

  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" append pyr2 '{"foo":1}' >/dev/null 2>&1 ); pyrc=$?
  check "py-fallback: reject no-event rc" "$([[ $pyrc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  echo '{"b":2,"a":1}' | ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" atomic_write "$WORK/py-out.json" )
  check "py-fallback: atomic keys sorted" "$(cat "$WORK/py-out.json")" '{"a":1,"b":2}'

  check "py-fallback: canonical nested" \
    "$(echo '{"z":{"y":1,"x":2},"a":3}' | ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" canonical ))" \
    '{"a":3,"z":{"x":2,"y":1}}'

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
