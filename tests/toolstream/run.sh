#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$HERE/../../scripts/toolstream.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to contain '$3')"; FAIL=$((FAIL+1)); fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to NOT contain '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

CFG='{"enforcement":{"secretPatterns":["(?i)(password|token|secret|api[_-]?key)\\s*[=:]\\s*\\S+"],"redactedKeys":["s3cr3t-cred-value"]}}'

# --- append: two events -> two lines, seq 1 then 2, ts stamped, tool/args preserved ---
( cd "$WORK" && bash "$T" append r1 '{"tool":"Bash","args":{"command":"ls -la"},"resultDigest":{"len":0,"sha256":"x"},"responseBody":""}' >/dev/null )
( cd "$WORK" && bash "$T" append r1 '{"tool":"Bash","args":{"command":"pwd"},"resultDigest":{"len":0,"sha256":"y"},"responseBody":""}' >/dev/null )
TF="$WORK/.qa/runs/r1/toolstream.jsonl"
check "two lines"   "$(wc -l < "$TF" | tr -d ' ')"      "2"
check "seq1"        "$(sed -n 1p "$TF" | jq -r '.seq')" "1"
check "seq2"        "$(sed -n 2p "$TF" | jq -r '.seq')" "2"
check "tool1"        "$(sed -n 1p "$TF" | jq -r '.tool')" "Bash"
check "has ts"       "$(sed -n 1p "$TF" | jq -r '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")')" "true"
check "each line json" "$(while read -r l; do echo "$l" | jq -e . >/dev/null || { echo bad; break; }; done < "$TF"; echo ok)" "ok"

# --- append: malformed (not an object) -> non-zero, no line written ---
( cd "$WORK" && bash "$T" append r2 '"just a string"' >/dev/null 2>&1 ); rc=$?
check "reject non-object rc"   "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "reject non-object file" "$([[ -f "$WORK/.qa/runs/r2/toolstream.jsonl" ]] && echo exists || echo none)" "none"

# --- append: multi-value / trailing-content input -> non-zero, no line written ---
( cd "$WORK" && bash "$T" append r3 '{"tool":"a"} {"tool":"b"}' >/dev/null 2>&1 ); rc3=$?
check "reject multi-value rc"   "$([[ $rc3 -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "reject multi-value file" "$([[ -f "$WORK/.qa/runs/r3/toolstream.jsonl" ]] && echo exists || echo none)" "none"

# --- read: returns the appended events verbatim ---
READ_OUT="$( cd "$WORK" && bash "$T" read r1 )"
check "read line count" "$(echo "$READ_OUT" | wc -l | tr -d ' ')" "2"
check "read first tool" "$(echo "$READ_OUT" | sed -n 1p | jq -r '.tool')" "Bash"

# --- read: nonexistent run -> empty output, exit 0 ---
( cd "$WORK" && bash "$T" read nope >/dev/null 2>&1 ); rrc=$?
check "read nonexistent rc"     "$rrc" "0"
check "read nonexistent output" "$( cd "$WORK" && bash "$T" read nope )" ""

# --- redact: config secretPattern masks a matched substring, leaves the rest ---
ARGS1='{"command":"curl --data '"'"'password=Sup3rSecret!'"'"' https://api.example.com/x"}'
OUT1="$( cd "$WORK" && bash "$T" redact "$ARGS1" "$CFG" )"
not_contains "redact: secret value gone"   "$OUT1" "Sup3rSecret!"
contains     "redact: redacted marker present" "$OUT1" "<redacted>"
contains     "redact: unrelated text kept"  "$OUT1" "curl --data"
contains     "redact: URL kept"             "$OUT1" "https://api.example.com/x"
check        "redact: still valid JSON"     "$(echo "$OUT1" | jq -e . >/dev/null 2>&1 && echo valid || echo invalid)" "valid"

# --- redact: declared credential value (redactedKeys) masked wherever it appears ---
ARGS2='{"command":"echo s3cr3t-cred-value | some-tool --login"}'
OUT2="$( cd "$WORK" && bash "$T" redact "$ARGS2" "$CFG" )"
not_contains "redact: declared credential gone" "$OUT2" "s3cr3t-cred-value"
contains     "redact: declared credential -> marker" "$OUT2" "<redacted>"
contains     "redact: rest of command kept" "$OUT2" "some-tool --login"

# --- redact: non-secret value passes through completely unchanged ---
ARGS3='{"command":"ls -la /tmp","note":"nothing sensitive here"}'
OUT3="$( cd "$WORK" && bash "$T" redact "$ARGS3" "$CFG" )"
check "redact: non-secret unchanged" "$(echo "$OUT3" | jq -c -S .)" "$(echo "$ARGS3" | jq -c -S .)"

# --- redact: absent/empty config -> no-op (args unchanged) ---
OUT4="$( cd "$WORK" && bash "$T" redact "$ARGS1" )"
check "redact: no config leaves args untouched" "$(echo "$OUT4" | jq -c -S .)" "$(echo "$ARGS1" | jq -c -S .)"

# --- python3-fallback pass: mask jq from PATH so has_jq() fails and has_py()
# succeeds, then re-assert the representative cases under the fallback.
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  for tool in date mkdir mv rm cat dirname sed wc python3 tr head awk; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" append pyr1 '{"tool":"Bash","args":{"command":"ls"},"resultDigest":{"len":0,"sha256":"x"},"responseBody":""}' >/dev/null )
  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" append pyr1 '{"tool":"Bash","args":{"command":"pwd"},"resultDigest":{"len":0,"sha256":"y"},"responseBody":""}' >/dev/null )
  PYTF="$WORK/.qa/runs/pyr1/toolstream.jsonl"
  check "py-fallback: two lines" "$(wc -l < "$PYTF" | tr -d ' ')" "2"
  check "py-fallback: seq2" "$(sed -n 2p "$PYTF" | jq -r '.seq')" "2"

  ( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" append pyr2 '"nope"' >/dev/null 2>&1 ); pyrc=$?
  check "py-fallback: reject non-object rc" "$([[ $pyrc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"

  PYOUT1="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" redact "$ARGS1" "$CFG" )"
  not_contains "py-fallback: redact secret gone" "$PYOUT1" "Sup3rSecret!"
  contains     "py-fallback: redact marker present" "$PYOUT1" "<redacted>"

  PYOUT2="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" redact "$ARGS2" "$CFG" )"
  not_contains "py-fallback: declared credential gone" "$PYOUT2" "s3cr3t-cred-value"

  PYOUT3="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" redact "$ARGS3" "$CFG" )"
  check "py-fallback: non-secret unchanged" "$(echo "$PYOUT3" | jq -c -S .)" "$(echo "$ARGS3" | jq -c -S .)"

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# --- QA_ENGINE=python3 override forces the fallback even with jq present ---
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  QEOUT="$( cd "$WORK" && QA_ENGINE=python3 bash "$T" redact "$ARGS1" "$CFG" )"
  not_contains "QA_ENGINE=python3: redact secret gone" "$QEOUT" "Sup3rSecret!"
  ( cd "$WORK" && QA_ENGINE=python3 bash "$T" append qer1 '{"tool":"Bash","args":{},"resultDigest":{"len":0,"sha256":"x"},"responseBody":""}' >/dev/null )
  QETF="$WORK/.qa/runs/qer1/toolstream.jsonl"
  check "QA_ENGINE=python3: line written" "$(wc -l < "$QETF" | tr -d ' ')" "1"
fi

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
