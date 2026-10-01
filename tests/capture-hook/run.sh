#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/scripts/capture-hook.sh"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to contain '$3')"; FAIL=$((FAIL+1)); fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (expected '$2' to NOT contain '$3')"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

setup_run() {
  # a fresh, minimal .qa/ inside $WORK with an active run "r1" and an
  # explicit enforcement config (deterministic, independent of whatever
  # the repo's real .qa/config.json.example happens to contain). $WORK is
  # reused across cases, so wipe any toolstream.jsonl a prior case left
  # behind -- each case that calls setup_run expects to start clean.
  rm -rf "$WORK/.qa/runs"
  mkdir -p "$WORK/.qa/runs/r1"
  printf 'r1\n' > "$WORK/.qa/runs/latest"
  cat > "$WORK/.qa/config.json" <<'EOF'
{
  "enforcement": {
    "captureHook": true,
    "secretPatterns": ["(?i)(password|token|secret|api[_-]?key)\\s*[=:]\\s*\\S+"],
    "redactedKeys": ["s3cr3t-cred-value"]
  }
}
EOF
}

TF() { echo "$WORK/.qa/runs/r1/toolstream.jsonl"; }

# ===========================================================================
# Case 1: Bash call with a secret in the command -> toolstream line has the
# secret redacted (args), full tool name preserved.
# ===========================================================================
setup_run
BASH_EVENT='{"tool_name":"Bash","tool_input":{"command":"curl --data '"'"'password=Sup3rSecret!'"'"' https://api.example.com/x"},"tool_response":{"stdout":"ok","stderr":"","exitCode":0},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$BASH_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook1.err" ); rc1=$?
check "case1: hook exit 0" "$rc1" "0"
check "case1: toolstream written" "$([[ -f "$(TF)" ]] && echo yes || echo no)" "yes"
LINE1="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case1: line is valid json" "$(echo "$LINE1" | jq -e . >/dev/null 2>&1 && echo valid || echo invalid)" "valid"
check "case1: tool == Bash" "$(echo "$LINE1" | jq -r '.tool')" "Bash"
not_contains "case1: secret redacted out of the line" "$LINE1" "Sup3rSecret!"
contains "case1: redacted marker present" "$(echo "$LINE1" | jq -r '.args.command')" "<redacted>"
check "case1: has seq" "$(echo "$LINE1" | jq -r '.seq')" "1"
check "case1: has ts" "$(echo "$LINE1" | jq -r '.ts | test("^[0-9]{4}-")')" "true"
check "case1: has resultDigest.len" "$(echo "$LINE1" | jq -r '.resultDigest.len | type')" "number"

# ===========================================================================
# Case 2: browser_* call -> args recorded IN FULL (no redaction) + a bounded
# responseBody is present.
# ===========================================================================
setup_run
BIG_SNAPSHOT="$(head -c 20000 /dev/zero | tr '\0' 'a')"
BROWSER_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_navigate","tool_input":{"url":"https://example.com/login?token=not-a-real-secret"},"tool_response":{"snapshot":"'"$BIG_SNAPSHOT"'"},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$BROWSER_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook2.err" ); rc2=$?
check "case2: hook exit 0" "$rc2" "0"
LINE2="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case2: tool == browser_navigate" "$(echo "$LINE2" | jq -r '.tool')" "mcp__plugin_playwright_playwright__browser_navigate"
check "case2: url arg kept IN FULL (not redacted)" "$(echo "$LINE2" | jq -r '.args.url')" "https://example.com/login?token=not-a-real-secret"
RESPLEN="$(echo "$LINE2" | jq -r '.responseBody | length')"
check "case2: responseBody present" "$([[ "$RESPLEN" -gt 0 ]] && echo yes || echo no)" "yes"
check "case2: responseBody bounded (<= 4200 chars incl. JSON overhead)" "$([[ "$RESPLEN" -le 4200 ]] && echo yes || echo no)" "yes"
check "case2: full response NOT stored verbatim (was truncated)" "$([[ "$RESPLEN" -lt ${#BIG_SNAPSHOT} ]] && echo yes || echo no)" "yes"

# ===========================================================================
# Case 3: no .qa/runs/latest -> no-op, no file written, exit 0.
# ===========================================================================
NOLATEST_WORK="$(mktemp -d)"
( cd "$NOLATEST_WORK" && printf '%s' "$BASH_EVENT" | bash "$HOOK" >/dev/null 2>"$NOLATEST_WORK/hook3.err" ); rc3=$?
check "case3: hook exit 0 with no active run" "$rc3" "0"
check "case3: no toolstream dir created at all" "$([[ -d "$NOLATEST_WORK/.qa/runs" ]] && echo exists || echo none)" "none"
rm -rf "$NOLATEST_WORK"

# ===========================================================================
# Case 4: empty stdin -> no-op, exit 0, no crash.
# ===========================================================================
EMPTY_WORK="$(mktemp -d)"
( cd "$EMPTY_WORK" && printf '' | bash "$HOOK" >/dev/null 2>"$EMPTY_WORK/hook4.err" ); rc4=$?
check "case4: empty stdin exit 0" "$rc4" "0"
rm -rf "$EMPTY_WORK"

# ===========================================================================
# Case 5: malformed (non-JSON) stdin -> no-op, exit 0, no crash.
# ===========================================================================
BAD_WORK="$(mktemp -d)"; mkdir -p "$BAD_WORK/.qa/runs/r1"; printf 'r1\n' > "$BAD_WORK/.qa/runs/latest"
( cd "$BAD_WORK" && printf '{not valid json' | bash "$HOOK" >/dev/null 2>"$BAD_WORK/hook5.err" ); rc5=$?
check "case5: malformed stdin exit 0" "$rc5" "0"
check "case5: no toolstream file written" "$([[ -f "$BAD_WORK/.qa/runs/r1/toolstream.jsonl" ]] && echo exists || echo none)" "none"
rm -rf "$BAD_WORK"

# ===========================================================================
# Case 6: enforcement.captureHook == false -> no-op even with an active run.
# ===========================================================================
setup_run
python3 -c "
import json
p='$WORK/.qa/config.json'
c=json.load(open(p))
c['enforcement']['captureHook']=False
json.dump(c, open(p,'w'))
"
( cd "$WORK" && printf '%s' "$BASH_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook6.err" ); rc6=$?
check "case6: hook exit 0 when captureHook=false" "$rc6" "0"
check "case6: no NEW line appended (still just the case1/2 lines... but this is a fresh setup_run, so file must not exist)" \
  "$([[ -f "$(TF)" ]] && echo exists || echo none)" "none"

# ===========================================================================
# Case 7: an unrecognized/absent tool_name -> no-op, exit 0.
# ===========================================================================
setup_run
NO_TOOLNAME_EVENT='{"tool_input":{"command":"ls"},"tool_response":{},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$NO_TOOLNAME_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook7.err" ); rc7=$?
check "case7: hook exit 0 with no tool_name" "$rc7" "0"
check "case7: no toolstream file written" "$([[ -f "$(TF)" ]] && echo exists || echo none)" "none"

# ===========================================================================
# Case 8: python3-fallback re-run of case 1 + case 2 (mask jq from PATH).
# ===========================================================================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  setup_run
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  # includes 'bash' itself -- capture-hook.sh shells out to `bash
  # "$TOOLSTREAM"` internally, and that nested invocation is looked up on
  # this same (restricted) PATH once it's forced below.
  for tool in bash date mkdir mv rm cat dirname sed wc python3 tr head awk sha256sum shasum grep; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  ( cd "$WORK" && printf '%s' "$BASH_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook8.err" ); rc8=$?
  check "py-fallback case1: hook exit 0" "$rc8" "0"
  PYLINE1="$(tail -n1 "$(TF)" 2>/dev/null)"
  check "py-fallback case1: tool == Bash" "$(echo "$PYLINE1" | jq -r '.tool')" "Bash"
  not_contains "py-fallback case1: secret redacted" "$PYLINE1" "Sup3rSecret!"

  ( cd "$WORK" && printf '%s' "$BROWSER_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook9.err" ); rc9=$?
  check "py-fallback case2: hook exit 0" "$rc9" "0"
  PYLINE2="$(tail -n1 "$(TF)" 2>/dev/null)"
  check "py-fallback case2: url arg kept in full" "$(echo "$PYLINE2" | jq -r '.args.url')" "https://example.com/login?token=not-a-real-secret"
  PYRESPLEN="$(echo "$PYLINE2" | jq -r '.responseBody | length')"
  check "py-fallback case2: responseBody bounded" "$([[ "$PYRESPLEN" -le 4200 ]] && echo yes || echo no)" "yes"

  echo "note - jq-fallback sub-case: RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case: jq or python3 not present on this host, cannot exercise fallback"
fi

# ===========================================================================
# Case 9 (Finding 1 regression): .qa/config.json has NO `enforcement` key AT
# ALL + a Bash secret in the command -> the toolstream line still has it
# redacted (the built-in default pattern set fires; redaction never
# silently no-ops just because a project's config lacks `enforcement`).
# ===========================================================================
setup_run
printf '%s' '{"baseUrl":"http://localhost:3000"}' > "$WORK/.qa/config.json"
NOENF_EVENT='{"tool_name":"Bash","tool_input":{"command":"echo password=Sup3rSecret!"},"tool_response":{"stdout":"ok","stderr":"","exitCode":0},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$NOENF_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook10.err" ); rc10=$?
check "case9: hook exit 0" "$rc10" "0"
LINE9="$(tail -n1 "$(TF)" 2>/dev/null)"
not_contains "case9: secret redacted with NO enforcement block in config" "$LINE9" "Sup3rSecret!"
contains "case9: redacted marker present (default pattern fired)" "$(echo "$LINE9" | jq -r '.args.command')" "<redacted>"

# ===========================================================================
# Case 10 (Finding 2 regression): a Bash tool_response (stdout) containing a
# secret -> the toolstream line's responseBody has it redacted too, not
# just the args. Uses the same no-`enforcement`-block config as case 9 to
# also prove the default pattern set covers tool_response.
# ===========================================================================
setup_run
printf '%s' '{"baseUrl":"http://localhost:3000"}' > "$WORK/.qa/config.json"
RESPSECRET_EVENT='{"tool_name":"Bash","tool_input":{"command":"env"},"tool_response":{"stdout":"PASSWORD=hunter2\n","stderr":"","exitCode":0},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$RESPSECRET_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook11.err" ); rc11=$?
check "case10: hook exit 0" "$rc11" "0"
LINE10="$(tail -n1 "$(TF)" 2>/dev/null)"
not_contains "case10: secret redacted out of responseBody" "$LINE10" "hunter2"
contains "case10: responseBody carries a redacted marker" "$(echo "$LINE10" | jq -r '.responseBody')" "<redacted>"

# ===========================================================================
# Case 11 (opt-out honored): an EXPLICIT `"secretPatterns": []` in
# enforcement -> the operator deliberately opted OUT of pattern-based
# redaction, so the Bash secret is NOT redacted (distinct from the absent-
# enforcement case above, which falls back to defaults).
# ===========================================================================
setup_run
cat > "$WORK/.qa/config.json" <<'EOF'
{
  "enforcement": {
    "captureHook": true,
    "secretPatterns": [],
    "redactedKeys": []
  }
}
EOF
( cd "$WORK" && printf '%s' "$NOENF_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook12.err" ); rc12=$?
check "case11: hook exit 0" "$rc12" "0"
LINE11="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case11: explicit secretPatterns:[] opt-out honored (args NOT redacted)" \
  "$(echo "$LINE11" | jq -r '.args.command')" "echo password=Sup3rSecret!"

# ===========================================================================
# Case 12 (0.8.1 -- the documented residual is CLOSED): a browser_type whose
# typed TEXT itself carries a secret-looking assignment is now redacted with
# the same effective pattern set toolstream.sh redact applies to Bash (here
# the built-in default, since the config has no enforcement block). Until
# 0.8.1 this case pinned the opposite (recorded IN FULL).
# ===========================================================================
setup_run
printf '%s' '{"baseUrl":"http://localhost:3000"}' > "$WORK/.qa/config.json"
BROWSER_PW_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_type","tool_input":{"text":"password=Sup3rSecret!"},"tool_response":{"ok":true},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$BROWSER_PW_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook13.err" ); rc13=$?
check "case12: hook exit 0" "$rc13" "0"
LINE12="$(tail -n1 "$(TF)" 2>/dev/null)"
not_contains "case12: secret-looking typed text redacted (default patterns now cover browser_type)" "$LINE12" "Sup3rSecret!"

# ===========================================================================
# Case 12b-12h (0.8.1, Defect 2): secrets TYPED into the browser are not
# recorded. A real run stored a shared login password 6x in toolstream.jsonl
# via browser_type / browser_fill_form. The TYPED VALUE of a secret field is
# replaced with "<redacted>" in args AND in the recorded responseBody (the
# Playwright MCP response echoes the generated .fill('<value>') code); the
# rest of the event -- which field, ref, tool, ts -- is kept for the audit
# trail. Non-secret fields are recorded verbatim.
# ===========================================================================
PW="Hunt3r2-Shared!pw"
# (the single quote is passed in via --arg q, keeping the jq program single-quoted)
PW_RESP="$(jq -cn --arg pw "$PW" --arg q "'" '[{type:"text",text:("### Ran Playwright code\nawait page.getByRole(\"textbox\", { name: \"Password\" }).fill(" + $q + $pw + $q + ");\n")}]')"
# 12b: browser_type into a password field (element description names it)
setup_run
EV12B="$(jq -cn --arg pw "$PW" --argjson resp "$PW_RESP" '{tool_name:"mcp__plugin_playwright_playwright__browser_type",tool_input:{element:"Password textbox",ref:"e12",text:$pw,submit:true},tool_response:$resp,session_id:"s"}')"
( cd "$WORK" && printf '%s' "$EV12B" | bash "$HOOK" >/dev/null 2>"$WORK/hook12b.err" ); rc=$?
check "case12b: hook exit 0" "$rc" "0"
L="$(tail -n1 "$(TF)" 2>/dev/null)"
not_contains "case12b: password typed into a password field is NOT in the toolstream line (args or responseBody)" "$L" "$PW"
check "case12b: args.text replaced with the stable marker" "$(echo "$L" | jq -r '.args.text')" "<redacted>"
check "case12b: audit trail kept -- element" "$(echo "$L" | jq -r '.args.element')" "Password textbox"
check "case12b: audit trail kept -- ref" "$(echo "$L" | jq -r '.args.ref')" "e12"
check "case12b: audit trail kept -- submit flag" "$(echo "$L" | jq -r '.args.submit')" "true"
contains "case12b: responseBody still recorded, secret masked in it" "$(echo "$L" | jq -r '.responseBody')" "<redacted>"

# 12c: browser_fill_form with a password field among others
setup_run
EV12C="$(jq -cn --arg pw "$PW" --argjson resp "$PW_RESP" '{tool_name:"mcp__plugin_playwright_playwright__browser_fill_form",tool_input:{fields:[{name:"Email",type:"textbox",ref:"e1",value:"qa.admin@example.test"},{name:"Password",type:"textbox",ref:"e2",value:$pw},{name:"Remember me",type:"checkbox",ref:"e3",value:"true"}]},tool_response:$resp,session_id:"s"}')"
( cd "$WORK" && printf '%s' "$EV12C" | bash "$HOOK" >/dev/null 2>"$WORK/hook12c.err" ); rc=$?
check "case12c: hook exit 0" "$rc" "0"
L="$(tail -n1 "$(TF)" 2>/dev/null)"
not_contains "case12c: fill_form password value NOT in the toolstream line" "$L" "$PW"
check "case12c: password field value -> marker" "$(echo "$L" | jq -r '.args.fields[1].value')" "<redacted>"
check "case12c: password field name kept" "$(echo "$L" | jq -r '.args.fields[1].name')" "Password"
check "case12c: password field ref kept" "$(echo "$L" | jq -r '.args.fields[1].ref')" "e2"
check "case12c: non-secret field (Email) verbatim" "$(echo "$L" | jq -r '.args.fields[0].value')" "qa.admin@example.test"
check "case12c: non-secret checkbox verbatim" "$(echo "$L" | jq -r '.args.fields[2].value')" "true"
check "case12c: field count unchanged" "$(echo "$L" | jq -r '.args.fields | length')" "3"

# 12d: a non-secret browser_type is recorded verbatim
setup_run
EV12D="$(jq -cn --arg q "'" '{tool_name:"mcp__plugin_playwright_playwright__browser_type",tool_input:{element:"Search products",ref:"e7",text:"blue widgets"},tool_response:[{type:"text",text:("fill(" + $q + "blue widgets" + $q + ")")}],session_id:"s"}')"
( cd "$WORK" && printf '%s' "$EV12D" | bash "$HOOK" >/dev/null 2>"$WORK/hook12d.err" ); rc=$?
check "case12d: hook exit 0" "$rc" "0"
L="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case12d: non-secret typed text verbatim" "$(echo "$L" | jq -r '.args.text')" "blue widgets"
contains "case12d: non-secret responseBody verbatim" "$(echo "$L" | jq -r '.responseBody')" "blue widgets"

# 12e: the field is identified by a selector / input type rather than a label
setup_run
EV12E="$(jq -cn --arg pw "$PW" '{tool_name:"mcp__plugin_playwright_playwright__browser_type",tool_input:{element:"input",selector:"input[type=password]",text:$pw},tool_response:null,session_id:"s"}')"
( cd "$WORK" && printf '%s' "$EV12E" | bash "$HOOK" >/dev/null 2>"$WORK/hook12e.err" ); rc=$?
check "case12e: hook exit 0" "$rc" "0"
not_contains "case12e: password field found via selector -> redacted" "$(tail -n1 "$(TF)")" "$PW"

# 12f: a declared credential VALUE (enforcement.redactedKeys, setup_run has
# "s3cr3t-cred-value") typed into an innocuously named field is still masked
setup_run
EV12F="$(jq -cn '{tool_name:"mcp__plugin_playwright_playwright__browser_type",tool_input:{element:"Notes",ref:"e9",text:"login with s3cr3t-cred-value please"},tool_response:{ok:true},session_id:"s"}')"
( cd "$WORK" && printf '%s' "$EV12F" | bash "$HOOK" >/dev/null 2>"$WORK/hook12f.err" ); rc=$?
check "case12f: hook exit 0" "$rc" "0"
L="$(tail -n1 "$(TF)" 2>/dev/null)"
not_contains "case12f: declared credential value masked" "$L" "s3cr3t-cred-value"
check "case12f: rest of the typed text kept" "$(echo "$L" | jq -r '.args.text')" "login with <redacted> please"

# 12g: a project-specific secretPatterns entry also marks a field secret
# (the effective pattern list is reused to classify field names)
setup_run
printf '%s' '{"enforcement":{"captureHook":true,"secretPatterns":["(ssn)\\s*[:=]\\s*\\S+"]}}' > "$WORK/.qa/config.json"
EV12G="$(jq -cn '{tool_name:"mcp__plugin_playwright_playwright__browser_type",tool_input:{element:"SSN",ref:"e4",text:"078-05-1120"},tool_response:{ok:true},session_id:"s"}')"
( cd "$WORK" && printf '%s' "$EV12G" | bash "$HOOK" >/dev/null 2>"$WORK/hook12g.err" ); rc=$?
check "case12g: hook exit 0" "$rc" "0"
check "case12g: field named by a project secretPattern -> redacted" "$(tail -n1 "$(TF)" | jq -r '.args.text')" "<redacted>"

# 12h: malformed browser_* inputs never fail the hook (and never block)
setup_run
for bad in \
  '{"tool_name":"mcp__plugin_playwright_playwright__browser_type","tool_input":{"element":"Password","text":12345},"tool_response":null}' \
  '{"tool_name":"mcp__plugin_playwright_playwright__browser_fill_form","tool_input":{"fields":"not-an-array"},"tool_response":null}' \
  '{"tool_name":"mcp__plugin_playwright_playwright__browser_fill_form","tool_input":{"fields":[null,7,{"name":"Password"}]},"tool_response":null}' \
  '{"tool_name":"mcp__plugin_playwright_playwright__browser_type","tool_input":"just a string","tool_response":null}' \
  '{"tool_name":"mcp__plugin_playwright_playwright__browser_type","tool_input":{"element":"Password","text":"x"' ; do
  ( cd "$WORK" && printf '%s' "$bad" | bash "$HOOK" >/dev/null 2>"$WORK/hook12h.err" ); rc=$?
  check "case12h: malformed browser input -> exit 0 ($(printf '%s' "$bad" | head -c 60)...)" "$rc" "0"
done
check "case12h: every recorded line is valid JSON" \
  "$(jq -c . "$(TF)" >/dev/null 2>&1 && echo valid || echo invalid)" "valid"

# 12i: dual-engine -- the same redaction under the python3 fallback
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  setup_run
  BASH_BIN="$(command -v bash)"
  FAKEBIN12="$WORK/fakebin12"
  mkdir -p "$FAKEBIN12"
  for tool in bash date mkdir mv rm cat dirname sed wc python3 tr head awk sha256sum shasum grep; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN12/$tool"
  done
  ( cd "$WORK" && printf '%s' "$EV12B" | PATH="$FAKEBIN12" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook12i.err" ); rc=$?
  check "py-fallback case12b: hook exit 0" "$rc" "0"
  L="$(tail -n1 "$(TF)" 2>/dev/null)"
  not_contains "py-fallback case12b: password NOT in the line" "$L" "$PW"
  check "py-fallback case12b: args.text -> marker" "$(echo "$L" | jq -r '.args.text')" "<redacted>"
  check "py-fallback case12b: element kept" "$(echo "$L" | jq -r '.args.element')" "Password textbox"
  ( cd "$WORK" && printf '%s' "$EV12C" | PATH="$FAKEBIN12" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook12i2.err" ); rc=$?
  check "py-fallback case12c: hook exit 0" "$rc" "0"
  L="$(tail -n1 "$(TF)" 2>/dev/null)"
  not_contains "py-fallback case12c: password NOT in the line" "$L" "$PW"
  check "py-fallback case12c: Email verbatim" "$(echo "$L" | jq -r '.args.fields[0].value')" "qa.admin@example.test"
  check "py-fallback case12c: Password -> marker" "$(echo "$L" | jq -r '.args.fields[1].value')" "<redacted>"
  ( cd "$WORK" && printf '%s' "$EV12D" | PATH="$FAKEBIN12" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook12i3.err" ); rc=$?
  check "py-fallback case12d: non-secret verbatim" "$(tail -n1 "$(TF)" | jq -r '.args.text')" "blue widgets"
  ( cd "$WORK" && printf '%s' '{"tool_name":"mcp__plugin_playwright_playwright__browser_fill_form","tool_input":{"fields":"not-an-array"},"tool_response":null}' | PATH="$FAKEBIN12" "$BASH_BIN" "$HOOK" >/dev/null 2>&1 ); rc=$?
  check "py-fallback case12h: malformed fill_form -> exit 0" "$rc" "0"
  echo "note - jq-fallback sub-case (browser secret capture): RAN"
else
  echo "SKIP - jq-fallback sub-case (browser secret capture): jq or python3 not present"
fi

# ===========================================================================
# Case 13 (Finding 1+2, python3-fallback dual-engine proof): re-run cases 9
# and 10 with jq masked from PATH.
# ===========================================================================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  setup_run
  printf '%s' '{"baseUrl":"http://localhost:3000"}' > "$WORK/.qa/config.json"
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  for tool in bash date mkdir mv rm cat dirname sed wc python3 tr head awk sha256sum shasum grep; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  ( cd "$WORK" && printf '%s' "$NOENF_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook14.err" ); rc14=$?
  check "py-fallback case9: hook exit 0" "$rc14" "0"
  PYLINE9="$(tail -n1 "$(TF)" 2>/dev/null)"
  not_contains "py-fallback case9: secret redacted with NO enforcement block" "$PYLINE9" "Sup3rSecret!"

  ( cd "$WORK" && printf '%s' "$RESPSECRET_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook15.err" ); rc15=$?
  check "py-fallback case10: hook exit 0" "$rc15" "0"
  PYLINE10="$(tail -n1 "$(TF)" 2>/dev/null)"
  not_contains "py-fallback case10: secret redacted out of responseBody" "$PYLINE10" "hunter2"

  echo "note - jq-fallback sub-case (Finding 1/2): RAN (jq masked from PATH via a restricted fakebin)"
else
  echo "SKIP - jq-fallback sub-case (Finding 1/2): jq or python3 not present on this host, cannot exercise fallback"
fi

# ===========================================================================
# Case 14 (Plan H3 Task 2 / #7): a captured browser_evaluate carrying a
# known time-control signal -> the toolstream event is stamped
# advisory:"clock-control". ADVISORY ONLY: hook still exits 0, event still
# written normally.
# ===========================================================================
setup_run
EVAL_FAKE_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_evaluate","tool_input":{"function":"() => { sinon.useFakeTimers(); return true; }"},"tool_response":{"result":true},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$EVAL_FAKE_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook14.err" ); rc14=$?
check "case14: hook exit 0 with a clock-control evaluate" "$rc14" "0"
LINE14="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case14: advisory==clock-control (sinon.useFakeTimers)" "$(echo "$LINE14" | jq -r '.advisory')" "clock-control"

# ===========================================================================
# Case 15: setTestNow( signal -> flagged.
# ===========================================================================
setup_run
SETTESTNOW_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_evaluate","tool_input":{"function":"() => { window.setTestNow(1700000000000); }"},"tool_response":{"result":null},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$SETTESTNOW_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook15.err" ); rc15b=$?
check "case15: hook exit 0 with setTestNow(" "$rc15b" "0"
LINE15="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case15: advisory==clock-control (setTestNow)" "$(echo "$LINE15" | jq -r '.advisory')" "clock-control"

# ===========================================================================
# Case 16: Date.now = override signal -> flagged.
# ===========================================================================
setup_run
DATENOW_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_evaluate","tool_input":{"code":"Date.now = () => 1700000000000;"},"tool_response":{"result":null},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$DATENOW_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook16.err" ); rc16=$?
check "case16: hook exit 0 with Date.now = override" "$rc16" "0"
LINE16="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case16: advisory==clock-control (Date.now =)" "$(echo "$LINE16" | jq -r '.advisory')" "clock-control"

# ===========================================================================
# Case 17: jest.useFakeTimers( signal -> flagged.
# ===========================================================================
setup_run
JESTFAKE_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_evaluate","tool_input":{"function":"() => { jest.useFakeTimers(); }"},"tool_response":{"result":null},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$JESTFAKE_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook17.err" ); rc17=$?
check "case17: hook exit 0 with jest.useFakeTimers(" "$rc17" "0"
LINE17="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case17: advisory==clock-control (jest.useFakeTimers)" "$(echo "$LINE17" | jq -r '.advisory')" "clock-control"

# ===========================================================================
# Case 18: browser_navigate to a clock-control route (?now=) -> flagged.
# ===========================================================================
setup_run
CLOCKNAV_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_navigate","tool_input":{"url":"https://example.com/__clock?now=1700000000000"},"tool_response":{"ok":true},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$CLOCKNAV_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook18.err" ); rc18=$?
check "case18: hook exit 0 with a clock-route navigate" "$rc18" "0"
LINE18="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case18: advisory==clock-control (/__clock?now=)" "$(echo "$LINE18" | jq -r '.advisory')" "clock-control"

# ===========================================================================
# Case 19: a normal browser_click -> NO advisory field at all (absent, not
# null/false).
# ===========================================================================
setup_run
CLICK_EVENT='{"tool_name":"mcp__plugin_playwright_playwright__browser_click","tool_input":{"element":"Submit button","ref":"e42"},"tool_response":{"ok":true},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$CLICK_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook19.err" ); rc19=$?
check "case19: hook exit 0 for a normal click" "$rc19" "0"
LINE19="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case19: no advisory key present at all" "$(echo "$LINE19" | jq -r 'has("advisory")')" "false"

# ===========================================================================
# Case 20: a Bash call hitting a clock route (/test/clock) -> flagged, AND a
# secret elsewhere in the same command is still redacted (no regression --
# the clock-scan classifies off the UNREDACTED tool_input, but the WRITTEN
# args go through the normal Bash redaction path unchanged).
# ===========================================================================
setup_run
BASHCLOCK_EVENT='{"tool_name":"Bash","tool_input":{"command":"curl -X POST http://localhost:3000/test/clock -d '"'"'password=Sup3rSecret!'"'"'"},"tool_response":{"stdout":"ok","stderr":"","exitCode":0},"cwd":"'"$WORK"'","session_id":"sess1"}'
( cd "$WORK" && printf '%s' "$BASHCLOCK_EVENT" | bash "$HOOK" >/dev/null 2>"$WORK/hook20.err" ); rc20=$?
check "case20: hook exit 0 with a Bash clock-route + secret" "$rc20" "0"
LINE20="$(tail -n1 "$(TF)" 2>/dev/null)"
check "case20: advisory==clock-control (Bash /test/clock)" "$(echo "$LINE20" | jq -r '.advisory')" "clock-control"
not_contains "case20: secret STILL redacted despite the clock-scan reading raw args" "$LINE20" "Sup3rSecret!"
contains "case20: redacted marker present" "$(echo "$LINE20" | jq -r '.args.command')" "<redacted>"

# ===========================================================================
# Case 21 (dual-engine): re-run the clock-flag + normal-no-advisory cases
# with jq masked from PATH (python3 fallback). Note: the FAKEBIN allowlist
# now includes `grep`, since the clock-scan shells out to `grep -Eqi`
# unconditionally (classification is engine-independent; only JSON field
# extraction differs by engine).
# ===========================================================================
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  setup_run
  BASH_BIN="$(command -v bash)"
  FAKEBIN="$WORK/fakebin"
  mkdir -p "$FAKEBIN"
  for tool in bash date mkdir mv rm cat dirname sed wc python3 tr head awk sha256sum shasum grep; do
    TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$TOOL_PATH" ]] && ln -sf "$TOOL_PATH" "$FAKEBIN/$tool"
  done

  ( cd "$WORK" && printf '%s' "$EVAL_FAKE_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook21.err" ); rc21=$?
  check "py-fallback case14: hook exit 0 with clock-control evaluate" "$rc21" "0"
  PYLINE21="$(tail -n1 "$(TF)" 2>/dev/null)"
  check "py-fallback case14: advisory==clock-control" "$(echo "$PYLINE21" | jq -r '.advisory')" "clock-control"

  ( cd "$WORK" && printf '%s' "$CLICK_EVENT" | PATH="$FAKEBIN" "$BASH_BIN" "$HOOK" >/dev/null 2>"$WORK/hook22.err" ); rc22=$?
  check "py-fallback case19: hook exit 0 for a normal click" "$rc22" "0"
  PYLINE22="$(tail -n1 "$(TF)" 2>/dev/null)"
  check "py-fallback case19: no advisory key present" "$(echo "$PYLINE22" | jq -r 'has("advisory")')" "false"

  echo "note - jq-fallback sub-case (clock-flag): RAN (jq masked from PATH via a restricted fakebin, grep included)"
else
  echo "SKIP - jq-fallback sub-case (clock-flag): jq or python3 not present on this host, cannot exercise fallback"
fi

# ===========================================================================
# Case 22 (plan task 5): the observe-round payload must be ordered so that
# capture-hook.sh's RESPONSE_BODY_CAP (4000 bytes, applied with `head -c`)
# eats the DOM digest rather than the findings. These cases exercise
# skills/driving-browser-qa/scripts/observe.js directly, in node, against a
# stubbed window/document. The cap itself is NOT changed -- see
# scripts/provenance.sh residual (a): it is accepted, documented evidence
# loss, and raising it would grow every toolstream file.
#
#   test_existing_capture_hook_cases_unchanged
#   test_payload_key_order_console_before_domdigest
#   test_findings_survive_4000_byte_cap_at_80_elements
#   test_testid_capped_at_64
#   test_href_capped_at_128
# ===========================================================================

# Every pre-existing case above (including case 2's 20,000-byte truncation
# assertions) must still pass; this pins that before the new observe-payload
# cases touch the counters.
check "test_existing_capture_hook_cases_unchanged: no pre-existing case failed" "$FAIL" "0"

OBSERVE_JS="$ROOT/skills/driving-browser-qa/scripts/observe.js"
check "observe.js present" "$([[ -f "$OBSERVE_JS" ]] && echo yes || echo no)" "yes"

if command -v node >/dev/null 2>&1; then
  HARNESS="$WORK/observe-harness.js"
  cat > "$HARNESS" <<'JS'
// Runs skills/driving-browser-qa/scripts/observe.js (which is a
// browser_evaluate function BODY, hence `new Function`) against a stubbed
// window/document, then reports facts about the emitted JSON as one JSON line.
var fs = require('fs');
var src = fs.readFileSync(process.argv[2], 'utf8');

var LONG_TESTID = 'order-row-primary-action-' + new Array(200).join('x'); // > 64
var LONG_HREF = '/app/tenant/acme/orders/' + new Array(300).join('y');    // > 128

function makeEl(spec) {
  return {
    tagName: spec.tag || 'BUTTON',
    value: undefined,
    textContent: spec.text || 'Open order',
    getAttribute: function (name) {
      if (name === 'data-testid') return spec.testid === undefined ? null : spec.testid;
      if (name === 'aria-label') return spec.ariaLabel === undefined ? null : spec.ariaLabel;
      if (name === 'href') return spec.href === undefined ? null : spec.href;
      return null;
    },
    getBoundingClientRect: function () { return { width: 140, height: 32 }; }
  };
}

// Worst case: 80 interactive elements with realistic testids/hrefs. The first
// one carries an over-long testid + href, which pins the two length caps.
var els = [makeEl({ tag: 'A', testid: LONG_TESTID, href: LONG_HREF, ariaLabel: 'Open order 0' })];
for (var i = 1; i < 80; i++) {
  els.push(makeEl({
    tag: i % 2 ? 'A' : 'BUTTON',
    testid: 'orders-table-row-' + i + '-primary-action-button',
    href: '/app/tenant/acme/orders/00000000-0000-4000-8000-' + (100000000000 + i) + '?tab=details&from=list',
    ariaLabel: 'Open order ' + i + ' details'
  }));
}

var liveTextSource = '';
while (liveTextSource.length < 2400) {
  liveTextSource += 'Orders dashboard row ' + liveTextSource.length + ' total 1,240.00 SAR status fulfilled ';
}

var root = { innerText: liveTextSource, querySelectorAll: function () { return els; } };
var doc = { body: root, querySelector: function () { return root; } };
var win = {
  addEventListener: function (t, h) { (this.__handlers = this.__handlers || {})[t] = h; },
  fetch: function () { return Promise.resolve({ status: 500, ok: false }); },
  XMLHttpRequest: null
};
var fakeConsole = { error: function () {}, warn: function () {}, log: function () {} };

var fn = new Function('window', 'document', 'console', src);
fn(win, doc, fakeConsole); // installs the interceptors + drains round 1

var CONSOLE_ERROR = 'TypeError: Cannot read properties of undefined (reading map) at OrderList';

fakeConsole.error(CONSOLE_ERROR);
win.fetch('/api/tenant/acme/orders/42/fulfil', { method: 'POST' }).then(function () {
  var payload = win.__qaObserve({ digestSelector: 'body', runUx: true });
  var text = JSON.stringify(payload);
  var buf = Buffer.from(text, 'utf8');
  var CAP = 4000; // capture-hook.sh RESPONSE_BODY_CAP -- `head -c 4000`, i.e. bytes
  var truncated = buf.slice(0, CAP).toString('utf8');
  var first = payload.domDigest.interactive[0];
  process.stdout.write(JSON.stringify({
    keys: Object.keys(payload),
    consoleOffset: buf.indexOf('"console"'),
    domDigestOffset: buf.indexOf('"domDigest"'),
    networkOffset: buf.indexOf('"network"'),
    totalBytes: buf.length,
    truncatedHasConsoleError: truncated.indexOf('Cannot read properties of undefined') >= 0,
    truncatedHas500: truncated.indexOf('"status":500') >= 0,
    consoleCount: payload.console.length,
    networkCount: payload.network.length,
    interactiveCount: payload.domDigest.interactive.length,
    liveTextLen: payload.domDigest.liveText.length,
    testidLen: first.testid.length,
    hrefLen: first.href.length,
    labelLen: first.label.length
  }) + '\n');
}, function (e) { process.stderr.write('harness-failed: ' + e + '\n'); process.exit(9); });
JS

  OBS_OUT="$(node "$HARNESS" "$OBSERVE_JS" 2>"$WORK/observe.err")"; obs_rc=$?
  check "observe harness ran" "$obs_rc" "0"
  if [[ "$obs_rc" -ne 0 ]]; then
    echo "note - observe harness stderr: $(cat "$WORK/observe.err")"
    OBS_OUT='{}'
  fi

  OBS() { echo "$OBS_OUT" | jq -r "$1"; }

  # --- same keys, nothing added or dropped ---
  check "observe payload keys unchanged (as a set)" \
    "$(OBS '.keys | sort | join(",")')" "axe,console,domDigest,network,round,ux"

  # --- test_payload_key_order_console_before_domdigest ---
  CONSOLE_OFF="$(OBS '.consoleOffset')"
  DIGEST_OFF="$(OBS '.domDigestOffset')"
  NETWORK_OFF="$(OBS '.networkOffset')"
  check "test_payload_key_order_console_before_domdigest: both keys present in the JSON text" \
    "$([[ "$CONSOLE_OFF" -ge 0 && "$DIGEST_OFF" -ge 0 ]] && echo yes || echo no)" "yes"
  check "test_payload_key_order_console_before_domdigest: byte offset of console < domDigest" \
    "$([[ "$CONSOLE_OFF" -lt "$DIGEST_OFF" ]] && echo yes || echo no)" "yes"
  check "test_payload_key_order_console_before_domdigest: byte offset of network < domDigest" \
    "$([[ "$NETWORK_OFF" -lt "$DIGEST_OFF" ]] && echo yes || echo no)" "yes"

  # --- test_findings_survive_4000_byte_cap_at_80_elements ---
  check "test_findings_survive_4000_byte_cap_at_80_elements: worst case really is 80 elements" \
    "$(OBS '.interactiveCount')" "80"
  check "test_findings_survive_4000_byte_cap_at_80_elements: liveText really is 1500 chars" \
    "$(OBS '.liveTextLen')" "1500"
  check "test_findings_survive_4000_byte_cap_at_80_elements: payload really exceeds the 4000-byte cap" \
    "$([[ "$(OBS '.totalBytes')" -gt 4000 ]] && echo yes || echo no)" "yes"
  check "test_findings_survive_4000_byte_cap_at_80_elements: one console error drained" \
    "$(OBS '.consoleCount')" "1"
  check "test_findings_survive_4000_byte_cap_at_80_elements: one network entry drained" \
    "$(OBS '.networkCount')" "1"
  check "test_findings_survive_4000_byte_cap_at_80_elements: console error survives head -c 4000" \
    "$(OBS '.truncatedHasConsoleError')" "true"
  check "test_findings_survive_4000_byte_cap_at_80_elements: the 500 survives head -c 4000" \
    "$(OBS '.truncatedHas500')" "true"

  # --- test_testid_capped_at_64 / test_href_capped_at_128 ---
  check "test_testid_capped_at_64" "$(OBS '.testidLen')" "64"
  check "test_href_capped_at_128" "$(OBS '.hrefLen')" "128"
  check "label cap unchanged at 40 (this label is 12 chars, well under it)" "$(OBS '.labelLen')" "12"

  echo "note - observe-payload cases: RAN (node present)"
else
  echo "SKIP - observe-payload cases: node not present on this host"
fi

# ---------------------------------------------------------------------------
# 0.9.0 (ADR-0027) — the capture-time `observed` field, built from the REAL
# Playwright MCP response (content array + "### Result" markdown), and the
# live self-checks the hook now reports through PostToolUse
# additionalContext (stdout JSON; the call is never blocked).
# ---------------------------------------------------------------------------
TSFX="$ROOT/tests/toolstream/fixtures"
MCPP="mcp__plugin_playwright_playwright__"
hook_evt() { # <tool-name> <tool-input-json> <response-fixture-file> -> stdin JSON for the hook
  jq -cn --arg t "$1" --argjson i "$2" --slurpfile r "$3" '{tool_name: $t, tool_input: $i, tool_response: $r[0], session_id: "s"}'
}
run_hook() { # <engine> <event-json> -> hook stdout (exit code checked separately)
  ( cd "$WORK" && printf '%s' "$2" | QA_ENGINE="$1" bash "$HOOK" 2>/dev/null )
}
for ENG in jq python3; do
  setup_run
  OUT="$(run_hook "$ENG" "$(hook_evt "${MCPP}browser_evaluate" '{"function":"() => window.__qaObserve({})"}' "$TSFX/mcp-observe-round.response.json")")"
  L="$(tail -n1 "$(TF)")"
  check "[$ENG] observe round: event carries observed.source observe" "$(jq -r '.observed.source' <<< "$L")" "observe"
  check "[$ENG] observe round: observed keeps the console error the 4KB cap would cut" "$(jq -r '.observed.console[0].level' <<< "$L")" "error"
  check "[$ENG] observe round: responseBody is still capped" "$(jq -r '.responseBody | length <= 4000' <<< "$L")" "true"
  check "[$ENG] observe round: a captured channel needs no canary (stdout empty)" "$OUT" ""

  OUT="$(run_hook "$ENG" "$(hook_evt "${MCPP}browser_evaluate" '{"function":"() => window.__qaObserve({}).domDigest.liveText"}' "$TSFX/mcp-observe-projection.response.json")")"
  check "[$ENG] projection AFTER a captured round: no canary" "$OUT" ""

  setup_run
  OUT="$(run_hook "$ENG" "$(hook_evt "${MCPP}browser_evaluate" '{"function":"() => window.__qaObserve({}).domDigest.liveText"}' "$TSFX/mcp-observe-projection.response.json")")"
  check "[$ENG] first observe is a projection: canary is PostToolUse additionalContext" "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$OUT")" "PostToolUse"
  contains "[$ENG] first observe is a projection: canary says the channel is not captured" "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$OUT")" "findings-channel check FAILED"
  check "[$ENG] projection event has no observed field" "$(tail -n1 "$(TF)" | jq -r 'has("observed")')" "false"

  setup_run
  OUT="$(run_hook "$ENG" "$(hook_evt "${MCPP}browser_network_requests" '{"static":false}' "$TSFX/mcp-network-requests.response.json")")"
  check "[$ENG] network list: event carries observed.source network-requests" "$(tail -n1 "$(TF)" | jq -r '.observed.source')" "network-requests"
  check "[$ENG] network list: 5 rows" "$(tail -n1 "$(TF)" | jq -r '.observed.network | length')" "5"

  setup_run
  OUT="$(run_hook "$ENG" "$(hook_evt "${MCPP}browser_navigate" '{"url":"https://app.test/x"}' "$TSFX/mcp-navigate.response.json")")"
  contains "[$ENG] navigate: load-window reminder in additionalContext" "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$OUT")" "browser_network_requests before any other navigation"

  # save-session probe: once, at the run's 3rd captured browser call
  setup_run
  printf '%s' '{"humanInteraction":{"saveSession":true,"sessionLogDir":".playwright-mcp"}}' > "$WORK/.qa/config.json"
  SNAPEVT="$(hook_evt "${MCPP}browser_snapshot" '{}' "$TSFX/mcp-navigate.response.json")"
  O1="$(run_hook "$ENG" "$SNAPEVT")"; O2="$(run_hook "$ENG" "$SNAPEVT")"; O3="$(run_hook "$ENG" "$SNAPEVT")"; O4="$(run_hook "$ENG" "$SNAPEVT")"
  check "[$ENG] save-session probe: silent on calls 1-2" "$O1$O2" ""
  contains "[$ENG] save-session probe: 3rd call says --save-session is off" "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$O3")" "--save-session"
  contains "[$ENG] save-session probe: names the opt-out" "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$O3")" "humanInteraction.saveSession:false"
  check "[$ENG] save-session probe: said once (4th call silent)" "$O4" ""
  setup_run
  printf '%s' '{"humanInteraction":{"saveSession":true,"sessionLogDir":".playwright-mcp"}}' > "$WORK/.qa/config.json"
  mkdir -p "$WORK/.playwright-mcp/session-1"; printf '### Tool call: browser_snapshot\n' > "$WORK/.playwright-mcp/session-1/session.md"
  run_hook "$ENG" "$SNAPEVT" >/dev/null; run_hook "$ENG" "$SNAPEVT" >/dev/null
  check "[$ENG] save-session probe: a fresh session log -> silent" "$(run_hook "$ENG" "$SNAPEVT")" ""
  rm -rf "$WORK/.playwright-mcp"
  setup_run
  printf '%s' '{"humanInteraction":{"saveSession":false}}' > "$WORK/.qa/config.json"
  run_hook "$ENG" "$SNAPEVT" >/dev/null; run_hook "$ENG" "$SNAPEVT" >/dev/null
  check "[$ENG] save-session probe: saveSession:false acknowledges the degrade -> silent" "$(run_hook "$ENG" "$SNAPEVT")" ""
done

# ---------------------------------------------------------------------------
# 0.10.0 (ADR-0028): a browser_take_screenshot event carries
# `screenshot: {file, path, sha256, bytes}` — the hook hashes the file the
# driver just saved; the name comes from `filename`, else the result's link.
# ---------------------------------------------------------------------------
for ENG in jq python3; do
  setup_run
  mkdir -p "$WORK/shots"
  printf '\x89PNG\r\n\x1a\nfake-png-body-%s' "$ENG" > "$WORK/shots/a.png"
  WANT_SHA="$(shasum -a 256 < "$WORK/shots/a.png" 2>/dev/null | awk '{print $1}')"
  [[ -n "$WANT_SHA" ]] || WANT_SHA="$(sha256sum < "$WORK/shots/a.png" | awk '{print $1}')"
  SHOT_EVT='{"tool_name":"mcp__plugin_playwright_playwright__browser_take_screenshot","tool_input":{"filename":"shots/a.png","fullPage":true,"scale":"css"},"tool_response":[{"type":"text","text":"### Result\n- [Screenshot of full page](shots/a.png)"}],"cwd":"'"$WORK"'","session_id":"s"}'
  ( cd "$WORK" && printf '%s' "$SHOT_EVT" | QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 )
  L="$(tail -n1 "$(TF)")"
  check "[$ENG] screenshot: file recorded from filename" "$(jq -r '.screenshot.file' <<< "$L")" "shots/a.png"
  check "[$ENG] screenshot: sha256 of the saved file" "$(jq -r '.screenshot.sha256' <<< "$L")" "$WANT_SHA"
  check "[$ENG] screenshot: bytes" "$(jq -r '.screenshot.bytes' <<< "$L")" "$(wc -c < "$WORK/shots/a.png" | tr -d ' ')"
  check "[$ENG] screenshot: resolved path" "$(jq -r '.screenshot.path' <<< "$L")" "$WORK/shots/a.png"

  setup_run
  NOFN_EVT='{"tool_name":"mcp__plugin_playwright_playwright__browser_take_screenshot","tool_input":{"scale":"css"},"tool_response":[{"type":"text","text":"### Result\n- [Screenshot of viewport](./shots/a.png)"}],"cwd":"'"$WORK"'","session_id":"s"}'
  ( cd "$WORK" && printf '%s' "$NOFN_EVT" | QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 )
  L="$(tail -n1 "$(TF)")"
  check "[$ENG] screenshot: name from the result link when no filename" "$(jq -r '.screenshot.file' <<< "$L")" "./shots/a.png"
  check "[$ENG] screenshot: link-named file hashed too" "$(jq -r '.screenshot.sha256' <<< "$L")" "$WANT_SHA"

  setup_run
  GONE_EVT='{"tool_name":"mcp__plugin_playwright_playwright__browser_take_screenshot","tool_input":{"filename":"nowhere/x.png","scale":"css"},"tool_response":[],"cwd":"'"$WORK"'","session_id":"s"}'
  ( cd "$WORK" && printf '%s' "$GONE_EVT" | QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 ); rcg=$?
  L="$(tail -n1 "$(TF)")"
  check "[$ENG] screenshot: unresolvable file -> hook still exits 0" "$rcg" "0"
  check "[$ENG] screenshot: unresolvable file -> {file} only, no sha256" "$(jq -c '.screenshot' <<< "$L")" '{"file":"nowhere/x.png"}'

  setup_run
  CLICK_EVT='{"tool_name":"mcp__plugin_playwright_playwright__browser_click","tool_input":{"element":"Save","ref":"e1"},"tool_response":[],"cwd":"'"$WORK"'","session_id":"s"}'
  ( cd "$WORK" && printf '%s' "$CLICK_EVT" | QA_ENGINE="$ENG" bash "$HOOK" >/dev/null 2>&1 )
  check "[$ENG] screenshot: no field on other tools" "$(tail -n1 "$(TF)" | jq -r 'has("screenshot")')" "false"
done

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
