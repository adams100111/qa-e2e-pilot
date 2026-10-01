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

# --- redact: absent config (no `enforcement` key at all, e.g. "{}" or no
# config-json arg) -> Finding 1 fail-safe: the built-in DEFAULT pattern set
# applies (NOT a no-op) -- redaction must never silently no-op just because
# a project's config has no `enforcement` block. ---
OUT4="$( cd "$WORK" && bash "$T" redact "$ARGS1" )"
not_contains "redact: absent config -> default patterns still catch the secret" "$OUT4" "Sup3rSecret!"
contains     "redact: absent config -> redacted marker present" "$OUT4" "<redacted>"
OUT4B="$( cd "$WORK" && bash "$T" redact "$ARGS1" '{}' )"
not_contains "redact: explicit {} config -> default patterns still catch the secret" "$OUT4B" "Sup3rSecret!"

# --- redact: EXPLICIT "secretPatterns": [] -> operator opt-out honored as
# truly empty (no default fallback) -- distinct from the absent case above. ---
OPTOUT_CFG='{"enforcement":{"secretPatterns":[]}}'
OUT4C="$( cd "$WORK" && bash "$T" redact "$ARGS1" "$OPTOUT_CFG" )"
check "redact: explicit secretPatterns:[] opts out (args unchanged)" "$(echo "$OUT4C" | jq -c -S .)" "$(echo "$ARGS1" | jq -c -S .)"

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

  PYOUT4="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" redact "$ARGS1" )"
  not_contains "py-fallback: absent config -> default patterns still catch the secret" "$PYOUT4" "Sup3rSecret!"

  PYOUT4C="$( cd "$WORK" && PATH="$FAKEBIN" "$BASH_BIN" "$T" redact "$ARGS1" "$OPTOUT_CFG" )"
  check "py-fallback: explicit secretPatterns:[] opts out" "$(echo "$PYOUT4C" | jq -c -S .)" "$(echo "$ARGS1" | jq -c -S .)"

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

# --- redact-browser (0.8.1, Defect 2): secrets TYPED into the browser -------
# browser_type / browser_fill_form typed values of SECRET fields -> "<redacted>",
# descriptors kept; non-secret values get the normal redact pass; malformed
# args pass through; both engines agree byte-for-byte.
RB_TYPE='{"element":"Password textbox","ref":"e12","text":"Hunt3r2!pw","submit":true}'
RB_FORM='{"fields":[{"name":"Email","type":"textbox","ref":"e1","value":"qa@example.test"},{"name":"Password","type":"textbox","ref":"e2","value":"Hunt3r2!pw"}]}'
RB_PLAIN='{"element":"Search","ref":"e3","text":"blue widgets"}'
for ENG in jq python3; do
  command -v "$ENG" >/dev/null 2>&1 || { echo "SKIP - redact-browser [$ENG]: not present"; continue; }
  O="$( cd "$WORK" && QA_ENGINE=$ENG bash "$T" redact-browser mcp__plugin_playwright_playwright__browser_type "$RB_TYPE" "$CFG" )"
  check "redact-browser [$ENG]: password field text -> marker" "$(echo "$O" | jq -r '.args.text')" "<redacted>"
  check "redact-browser [$ENG]: descriptors kept" "$(echo "$O" | jq -c '.args | del(.text)')" '{"element":"Password textbox","ref":"e12","submit":true}'
  check "redact-browser [$ENG]: secrets lists the typed value (for response masking)" "$(echo "$O" | jq -r '.secrets | index("Hunt3r2!pw") != null')" "true"
  O="$( cd "$WORK" && QA_ENGINE=$ENG bash "$T" redact-browser mcp__plugin_playwright_playwright__browser_fill_form "$RB_FORM" "$CFG" )"
  check "redact-browser [$ENG]: fill_form password value -> marker, email verbatim" "$(echo "$O" | jq -c '[.args.fields[].value]')" '["qa@example.test","<redacted>"]'
  O="$( cd "$WORK" && QA_ENGINE=$ENG bash "$T" redact-browser mcp__plugin_playwright_playwright__browser_type "$RB_PLAIN" "$CFG" )"
  check "redact-browser [$ENG]: non-secret field unchanged, no secrets" "$(echo "$O" | jq -c .)" "{\"args\":$RB_PLAIN,\"secrets\":[]}"
  O="$( cd "$WORK" && QA_ENGINE=$ENG bash "$T" redact-browser mcp__plugin_playwright_playwright__browser_navigate '{"url":"https://x.test/?token=abc"}' "$CFG" )"
  check "redact-browser [$ENG]: other tools pass through untouched" "$(echo "$O" | jq -r '.args.url')" "https://x.test/?token=abc"
  O="$( cd "$WORK" && QA_ENGINE=$ENG bash "$T" redact-browser mcp__plugin_playwright_playwright__browser_fill_form '{"fields":"nope"}' "$CFG" )"
  check "redact-browser [$ENG]: malformed fields pass through" "$(echo "$O" | jq -c .args)" '{"fields":"nope"}'
done
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  for A in "$RB_TYPE" "$RB_FORM" "$RB_PLAIN"; do
    JQO="$( cd "$WORK" && QA_ENGINE=jq bash "$T" redact-browser x__browser_fill_form "$A" "$CFG" ; cd "$WORK" && QA_ENGINE=jq bash "$T" redact-browser x__browser_type "$A" "$CFG" )"
    PYO="$( cd "$WORK" && QA_ENGINE=python3 bash "$T" redact-browser x__browser_fill_form "$A" "$CFG" ; cd "$WORK" && QA_ENGINE=python3 bash "$T" redact-browser x__browser_type "$A" "$CFG" )"
    check "redact-browser: jq and python3 engines agree ($(printf '%s' "$A" | head -c 30)...)" "$JQO" "$PYO"
  done
fi

# ---------------------------------------------------------------------------
# 0.9.0 (ADR-0027) — extract-observed / observed-rows against the REAL
# Playwright MCP response shapes (content array + "### Result" markdown; a
# markdown request list), sanitized from a 2026-10-01 run whose findings
# channel read "none" although observe.js was injected verbatim. Every case
# runs under jq AND python3 and the two must agree byte-for-byte.
# ---------------------------------------------------------------------------
FX="$HERE/fixtures"
MCPP="mcp__plugin_playwright_playwright__"
for ENG in jq python3; do
  ex() { QA_ENGINE="$ENG" bash "$T" extract-observed "$1" < "$FX/$2"; }
  O="$(ex "${MCPP}browser_evaluate" mcp-observe-round.response.json)"
  check "[$ENG] observe round (14KB, over the 4KB body cap) -> source observe" "$(jq -r '.source' <<< "$O")" "observe"
  check "[$ENG] observe round -> the console error survives" "$(jq -r '.console[0].text' <<< "$O")" "TypeError: Cannot read properties of undefined (reading 'map')"
  check "[$ENG] observe round -> the network row survives" "$(jq -c '.network[0]' <<< "$O")" '{"method":"POST","url":"https://app.test/hackathons/88/registrations/438","status":422}'
  check "[$ENG] observe round -> the bulky domDigest is NOT stored" "$(jq -r 'has("domDigest")' <<< "$O")" "false"
  N="$(ex "${MCPP}browser_network_requests" mcp-network-requests.response.json)"
  check "[$ENG] network list -> source network-requests" "$(jq -r '.source' <<< "$N")" "network-requests"
  check "[$ENG] network list -> 5 rows parsed" "$(jq '.network | length' <<< "$N")" "5"
  check "[$ENG] network list -> the 500 is first (non-2xx first)" "$(jq -c '.network[0] | [.method, .status]' <<< "$N")" '["GET",500]'
  check "[$ENG] network list -> the Note line is not a row" "$(jq '[.network[] | select(.url | test("static"))] | length' <<< "$N")" "0"
  check "[$ENG] a projection (.domDigest.liveText) yields nothing" "$(ex "${MCPP}browser_evaluate" mcp-observe-projection.response.json)" ""
  check "[$ENG] a navigate response yields nothing" "$(ex "${MCPP}browser_navigate" mcp-navigate.response.json)" ""
  check "[$ENG] garbage on stdin yields nothing, exit 0" "$(printf 'not json' | QA_ENGINE="$ENG" bash "$T" extract-observed "${MCPP}browser_evaluate"; echo "rc=$?")" "rc=0"
done
for f in mcp-observe-round.response.json mcp-network-requests.response.json; do
  tool="${MCPP}browser_evaluate"; [[ "$f" == mcp-network* ]] && tool="${MCPP}browser_network_requests"
  check "extract-observed: engines agree on $f" \
    "$(QA_ENGINE=jq bash "$T" extract-observed "$tool" < "$FX/$f")" "$(QA_ENGINE=python3 bash "$T" extract-observed "$tool" < "$FX/$f")"
done
# observed-rows on a PRE-0.9.0 toolstream (no `observed`; responseBody is the
# content array truncated at 4000 bytes, exactly as recorded): the request
# list is intact and recovered; the observe round was cut mid-wrapper and
# honestly contributes nothing.
LEG="$HERE/../qa-verify/fixtures/real-mcp-legacy.toolstream.jsonl"
R_JQ="$(QA_ENGINE=jq bash "$T" observed-rows "$LEG")"
R_PY="$(QA_ENGINE=python3 bash "$T" observed-rows "$LEG")"
check "observed-rows (legacy): engines agree byte-for-byte" "$R_JQ" "$R_PY"
check "observed-rows (legacy): 5 network rows recovered from the request list" "$(printf '%s\n' "$R_JQ" | grep -c '^net$')" "5"
contains "observed-rows (legacy): the in-scope 500 is visible" "$(printf '%s\n' "$R_JQ" | paste - - - - - - )" "superset/data/hackathon-dashboard-data?hackathon_id=91&path_id=-1&stage_id=-1	500"
check "observed-rows (legacy): the truncated observe round adds no console row" "$(printf '%s\n' "$R_JQ" | grep -c '^console$')" "0"
# ...and on a 0.9.0 event carrying `observed`, that field is what is read.
printf '%s\n' "{\"tool\":\"${MCPP}browser_evaluate\",\"args\":{},\"responseBody\":\"[{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"### Result\\\\n{\\\\n  \\\\\\\"round\\\\\\\": 1, TRUNCATED\",\"observed\":$(QA_ENGINE=jq bash "$T" extract-observed "${MCPP}browser_evaluate" < "$FX/mcp-observe-round.response.json"),\"seq\":1,\"ts\":\"2026-10-01T00:00:00Z\"}" > "$WORK/obs.jsonl"
for ENG in jq python3; do
  ROWS="$(QA_ENGINE="$ENG" bash "$T" observed-rows "$WORK/obs.jsonl" | paste - - - - - -)"
  contains "[$ENG] observed-rows (0.9.0 event): console error row from the observed field" "$ROWS" "console				TypeError: Cannot read properties"
  contains "[$ENG] observed-rows (0.9.0 event): network row from the observed field" "$ROWS" "net	POST	https://app.test/hackathons/88/registrations/438	422"
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
