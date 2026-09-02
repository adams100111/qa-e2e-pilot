#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
J="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0
get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# a >=300 KB single string value -- regression fixture for the E2BIG bug
# below (generated once, reused by both the normal pass and the
# python3-fallback pass).
BIG="$(head -c 300000 /dev/zero | tr '\0' 'x')"
BIGJSON="{\"b\":\"$BIG\",\"a\":1}"
BIG_EXPECT="{\"a\":1,\"b\":\"$BIG\"}"

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

# malformed append: multi-value / trailing-content input (e.g. two
# concatenated JSON objects) → non-zero, no line written. Regression for a
# bug where `jq -e`'s exit status reflected only the LAST value in a
# multi-value stream, so the leading value(s) slipped through unvalidated
# and corrupted the monotonic seq (two lines written with the same seq).
( cd "$WORK" && bash "$J" append r4 '{"foo":1} {"event":"a"}' >/dev/null 2>&1 ); rc4=$?
check "reject multi-value rc"   "$([[ $rc4 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "reject multi-value file" "$([[ -f "$WORK/.qa/runs/r4/journal.ndjson" ]] && echo exists || echo none)" "none"

# atomic_write produces canonical sorted-key output and leaves no tmp
echo '{"b":2,"a":1}' | ( cd "$WORK" && bash "$J" atomic_write "$WORK/out.json" )
check "atomic keys sorted" "$(cat "$WORK/out.json")" '{"a":1,"b":2}'
check "no tmp left"        "$(ls "$WORK"/out.json.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# canonical helper sorts nested keys
check "canonical nested" "$(echo '{"z":{"y":1,"x":2},"a":3}' | ( cd "$WORK" && bash "$J" canonical ))" '{"a":3,"z":{"x":2,"y":1}}'

# large payload (>=300 KB single string value) through canonical/atomic_write
# -- regression for the python3-fallback branches passing the JSON payload
# as a `python3 -c` command-line ARGUMENT, which exceeds the kernel's
# per-argument length limit (E2BIG) on a payload this size. The python3
# branches now read the JSON via stdin instead.
BIGOUT="$(echo "$BIGJSON" | ( cd "$WORK" && bash "$J" canonical ))"; bigrc=$?
check "large payload canonical rc"  "$bigrc" "0"
check "large payload canonical out" "$BIGOUT" "$BIG_EXPECT"

echo "$BIGJSON" | ( cd "$WORK" && bash "$J" atomic_write "$WORK/big-out.json" ); bigrc2=$?
check "large payload atomic_write rc"  "$bigrc2" "0"
check "large payload atomic_write out" "$(cat "$WORK/big-out.json")" "$BIG_EXPECT"

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

  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" append pyr4 '{"foo":1} {"event":"a"}' >/dev/null 2>&1 ); pyrc4=$?
  check "py-fallback: reject multi-value rc"   "$([[ $pyrc4 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
  check "py-fallback: reject multi-value file" "$([[ -f "$WORK/.qa/runs/pyr4/journal.ndjson" ]] && echo exists || echo none)" "none"

  echo '{"b":2,"a":1}' | ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" atomic_write "$WORK/py-out.json" )
  check "py-fallback: atomic keys sorted" "$(cat "$WORK/py-out.json")" '{"a":1,"b":2}'

  check "py-fallback: canonical nested" \
    "$(echo '{"z":{"y":1,"x":2},"a":3}' | ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" canonical ))" \
    '{"a":3,"z":{"x":2,"y":1}}'

  # large payload (>=300 KB single string value) through the python3-only
  # canonical/atomic_write branches -- proves the E2BIG fix on the actual
  # fallback path, not just the (already stdin-based) jq path.
  PYBIGOUT="$(echo "$BIGJSON" | ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" canonical ))"; pybigrc=$?
  check "py-fallback: large payload canonical rc"  "$pybigrc" "0"
  check "py-fallback: large payload canonical out" "$PYBIGOUT" "$BIG_EXPECT"

  echo "$BIGJSON" | ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$J" atomic_write "$WORK/py-big-out.json" ); pybigrc2=$?
  check "py-fallback: large payload atomic_write rc"  "$pybigrc2" "0"
  check "py-fallback: large payload atomic_write out" "$(cat "$WORK/py-big-out.json")" "$BIG_EXPECT"

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# --- poisoned-jq sub-case: QA_ENGINE=python3 must actually force python3,
# not just "python3 happens to be picked because jq was absent". Put a `jq`
# on PATH that always FAILS (exit 1, no stdout) -- if has_jq() ever consulted
# it (auto-detect, or a broken override), every jq-branch call would error
# out and the operation would fail. Asserting SUCCESS + correct output here
# is proof the python3 branch ran, not the poisoned jq. Regression guard for
# checkpoint.sh's ext_path leak (${BASH%/*} re-exposing a real /usr/bin/jq
# that would have masked this): output being byte-identical either engine is
# exactly why that leak shipped silently, so this test asserts the MECHANISM
# (QA_ENGINE override), never just output.
if command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  POISONBIN="$WORK/poisonbin"
  mkdir -p "$POISONBIN"
  for tool in date mkdir mv rm cat dirname sed wc python3; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$POISONBIN/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' > "$POISONBIN/jq"
  chmod +x "$POISONBIN/jq"

  ( cd "$WORK" && QA_ENGINE=python3 PATH="$POISONBIN" "$BASH_BIN" "$J" append qer1 '{"event":"run_started","runId":"qer1"}' >/dev/null 2>&1 ); qerc=$?
  QEJF="$WORK/.qa/runs/qer1/journal.ndjson"
  check "QA_ENGINE=python3 + poisoned jq: append rc 0" "$qerc" "0"
  check "QA_ENGINE=python3 + poisoned jq: line written" "$(wc -l < "$QEJF" 2>/dev/null | tr -d ' ')" "1"
  check "QA_ENGINE=python3 + poisoned jq: event field correct" \
    "$(sed -n 1p "$QEJF" 2>/dev/null | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["event"])' 2>/dev/null)" \
    "run_started"

  echo "$BIGJSON" | ( cd "$WORK" && QA_ENGINE=python3 PATH="$POISONBIN" "$BASH_BIN" "$J" canonical ) > "$WORK/qe-canon.out" 2>/dev/null
  check "QA_ENGINE=python3 + poisoned jq: canonical rc 0 + correct" "$(cat "$WORK/qe-canon.out")" "$BIG_EXPECT"

  # Optional sanity: WITHOUT the override, auto-detect finds the poisoned jq
  # first (has_jq() only checks presence, not that it works) and the
  # operation fails -- proving the poisoned jq is actually reachable/picked
  # by default, i.e. this is a real regression guard and not a no-op.
  ( cd "$WORK" && PATH="$POISONBIN" "$BASH_BIN" "$J" append qer2 '{"event":"run_started","runId":"qer2"}' >/dev/null 2>&1 ); qerc2=$?
  check "unset QA_ENGINE + poisoned jq: append fails (auto-detect picked the poisoned jq)" \
    "$([[ $qerc2 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  echo "note - poisoned-jq sub-case: RAN (QA_ENGINE=python3 override proven against a jq that always fails)"
else
  echo "SKIP - poisoned-jq sub-case: python3 not present on this host"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
