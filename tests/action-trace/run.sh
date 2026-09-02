#!/usr/bin/env bash
# Tests for the human-action gate: parse-session-log.js, check-action-trace.js,
# record-evidence action-trace writer, and checkpoint.sh's human-action kind.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CKPT="$HERE/../../skills/checkpointing-qa-memory/scripts/checkpoint.sh"
REC="$HERE/../../skills/checkpointing-qa-memory/scripts/record-evidence.sh"
CHECK="$HERE/../../skills/checkpointing-qa-memory/scripts/check-action-trace.js"
PARSE="$HERE/../../skills/driving-browser-qa/scripts/parse-session-log.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
get() { jq -r "$2" "$1" 2>/dev/null; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- parse-session-log.js: classify calls from a REAL Playwright session.md ---
# Real @playwright/mcp@0.0.79 format: sections titled "Ran Playwright code" with
# a ```js block of generated Playwright code (NOT tool names).
cat > "$WORK/session.md" <<'MD'
### Tool call: call
- Result
```json
{"code": "await page.locator('#name').fill('Alice');"}
```
### Tool call: call
- Result
```json
{"code": "await page.locator('#add').click();"}
```
### Tool call: call
- Result
```json
{"code": "await page.evaluate(() => getComputedStyle(document.body).color);"}
```
### Tool call: call
- Result
```json
{"code": "await page.evaluate(() => localStorage.setItem('captable:founders','[]'));"}
```
MD
PARSED="$(node "$PARSE" "$WORK/session.md")"
jlen() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s);process.stdout.write(String('"$1"'))})'; }
check "parse: found 4 code calls"          "$(echo "$PARSED" | jlen 'a.length')" "4"
check "parse: 2 human-path clicks/fills"   "$(echo "$PARSED" | jlen 'a.filter(c=>c.class==="human-path").length')" "2"
check "parse: read-only evaluate mutating=false" "$(echo "$PARSED" | jlen 'a.filter(c=>c.class==="evaluate"&&!c.mutating).length')" "1"
check "parse: setItem evaluate mutating=true"    "$(echo "$PARSED" | jlen 'a.filter(c=>c.class==="evaluate"&&c.mutating).length')" "1"

# --- #3 semantic mutation classifier: writes the old regex missed ------------
mut() { node -e 'const{mutates}=require(process.argv[1]);process.stdout.write(String(mutates(process.argv[2])))' "$PARSE" "$1"; }
check "classify: fetch POST uppercase mutates"      "$(mut "fetch('/x',{method:'POST'})")"            "true"
check "classify: fetch post lowercase mutates"      "$(mut "fetch('/x',{method:'post'})")"            "true"
check "classify: fetch method backtick mutates"     "$(mut 'fetch("/x",{method:`POST`})')"            "true"
check "classify: page.request.post mutates"         "$(mut "page.request.post('/x',{data:{}})")"      "true"
check "classify: axios.post mutates"                "$(mut "axios.post('/x',{})")"                    "true"
check "classify: axios.delete mutates"              "$(mut "axios.delete('/x/1')")"                   "true"
check "classify: XHR open('post') mutates"          "$(mut "x.open('post','/x')")"                    "true"
check "classify: GET fetch NOT mutating"            "$(mut "fetch('/x').then(r=>r.json())")"          "false"
check "classify: page.request.get NOT mutating"     "$(mut "page.request.get('/x')")"                 "false"
check "classify: getComputedStyle NOT mutating"     "$(mut "getComputedStyle(document.body).color")"  "false"
# negative control: `.post|put|patch|delete` must require the call delimiter, so a
# substring method like postMessage is NOT flagged (guards against dropping `\s*\(`)
check "classify: .postMessage NOT mutating"         "$(mut "window.postMessage('x','*')")"            "false"

# --- #3 act-path integration: a NEW mutation form on the ACT PATH (through the
#     gate, not just the classifier unit) is workaround-rejected — spec §5A/#2 ---
cat > "$WORK/axiosact.json" <<'J'
{"actionUnderTest":"create via axios","steps":[{"tool":"browser_evaluate","target":"post","phase":"act","payload":"axios.post('/x',{})"}],"sessionCalls":[],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/axiosact.json" 2>/dev/null; check "check: axios.post on act rejected (new-form act-path)" "$?" "1"
# a read-only page.request.get on the act path stays allowed (no false-reject)
cat > "$WORK/reqget.json" <<'J'
{"actionUnderTest":"read via request","steps":[{"tool":"browser_evaluate","target":"get","phase":"act","payload":"page.request.get('/x')"}],"sessionCalls":[],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/reqget.json"; check "check: page.request.get on act allowed (no false-reject)" "$?" "0"

# --- check-action-trace.js: clean UI-only act -> exit 0 -----------------------
cat > "$WORK/clean.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_type","target":"#name","phase":"arrange"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/clean.json"; check "check: clean UI-only act passes" "$?" "0"

# --- Q2 (fatal FP guard): a read-only observe evaluate in session.md is IGNORED
cat > "$WORK/observe.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"},{"class":"evaluate","mutating":false,"code":"getComputedStyle(document.body)"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/observe.json"; check "check: read-only observe evaluate NOT flagged (Q2)" "$?" "0"

# --- Check 1/2: an act-phase MUTATING evaluate -> exit 1 (payload classifies) --
cat > "$WORK/evalact.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"setItem","phase":"act","payload":"localStorage.setItem('captable:founders','[]')"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"localStorage.setItem('captable:founders','[]')"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/evalact.json" 2>/dev/null; check "check: mutating evaluate on act rejected" "$?" "1"

# --- a READ-ONLY evaluate ON the act path is allowed (payload doesn't mutate) --
cat > "$WORK/readact.json" <<'J'
{"actionUnderTest":"read total","steps":[{"tool":"browser_evaluate","target":"read","phase":"act","payload":"getComputedStyle(document.body).color"}],"sessionCalls":[{"class":"evaluate","mutating":false,"code":"getComputedStyle"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/readact.json"; check "check: read-only evaluate on act allowed" "$?" "0"

# --- CRITICAL regression: a concealed NON-DOM write on the act path (backend
#     fetch POST / XHR / framework dispatch) must be caught by the mutation lint,
#     not just DOM/storage writes (final-review Critical) ---
cat > "$WORK/fetchact.json" <<'J'
{"actionUnderTest":"create item","steps":[{"tool":"browser_evaluate","target":"post","phase":"act","payload":"fetch('/api/items',{method:'POST',body:'{}'})"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => fetch('/api/items',{method:'POST',body:'{}'}))"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/fetchact.json" 2>/dev/null; check "check: backend fetch POST on act rejected (network-write lint)" "$?" "1"
cat > "$WORK/dispatchact.json" <<'J'
{"actionUnderTest":"add via store","steps":[{"tool":"browser_evaluate","target":"dispatch","phase":"act","payload":"store.dispatch({type:'ADD_ITEM'})"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => store.dispatch({type:'ADD_ITEM'}))"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/dispatchact.json" 2>/dev/null; check "check: framework store.dispatch on act rejected" "$?" "1"
# a read-only GET fetch on the act path stays allowed (must NOT false-reject)
cat > "$WORK/getfetch.json" <<'J'
{"actionUnderTest":"read list","steps":[{"tool":"browser_evaluate","target":"get","phase":"act","payload":"fetch('/api/items').then(r=>r.json())"}],"sessionCalls":[{"class":"evaluate","mutating":false,"code":"await page.evaluate(() => fetch('/api/items'))"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/getfetch.json"; check "check: read-only GET fetch on act allowed (no false-reject)" "$?" "0"

# --- a RECORDED mutating evaluate (e.g. arrange seed) covers its session twin --
cat > "$WORK/recorded.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem('seed','1')"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"localStorage.setItem('seed','1')"},{"class":"human-path","mutating":true,"code":"await page.locator('#add').click()"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/recorded.json"; check "check: recorded arrange-mutation covers its twin (not concealed)" "$?" "0"

# --- Check 0: concealed MUTATING workaround (in session.md, no recorded step) --
cat > "$WORK/concealed.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"},{"class":"evaluate","mutating":true,"code":"localStorage.setItem('captable:founders','[]')"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/concealed.json" 2>/dev/null; check "check: concealed mutating workaround rejected (Check 0)" "$?" "1"

# --- Check 0 (CONTENT-MATCH): a fabricated DECOY mutating step must NOT cover
# an unrelated genuine concealed workaround — a bare count would let this
# through (the "grades its own homework" bypass this gate exists to stop).
cat > "$WORK/decoy.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"decoy","phase":"arrange","payload":"document.title=\"x\""},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"},{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"captable:founders\",\"[]\"))"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/decoy.json" 2>/dev/null; check "check: decoy mutating step does not cover unrelated concealed call" "$?" "1"

# --- Check 0 (CONTENT-MATCH): a PREFIX of the concealed call must not match --
cat > "$WORK/prefix-decoy.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"decoy","phase":"arrange","payload":"localStorage.setItem("},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"},{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"captable:founders\",\"[]\"))"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/prefix-decoy.json" 2>/dev/null; check "check: prefix-only decoy does not cover the full concealed call" "$?" "1"

# --- Check 0 (CONTENT-MATCH): a genuinely disclosed arrange-mutation IS allowed
cat > "$WORK/disclosed.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem(\"seed\",\"1\")"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"seed\",\"1\"))"},{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/disclosed.json"; check "check: disclosed arrange-mutation with matching content is allowed" "$?" "0"

# --- #8 squash hardening: structure-preserving content match ------------------
# (a) ALIAS ATTACK: a disclosed decoy that stores "x" must NOT cover a concealed
#     call that stores the STRUCTURALLY-different "[x]". The old bracket-collapsing
#     squash aliased these (both -> localStorage.setItem"k","x"); the hardened,
#     structure-preserving squash keeps them distinct -> concealed call rejected.
cat > "$WORK/alias.json" <<'J'
{"actionUnderTest":"alias attack","steps":[{"tool":"browser_evaluate","target":"decoy","phase":"arrange","payload":"localStorage.setItem(\"k\",\"x\")"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"},{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"k\",\"[x]\"))"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/alias.json" 2>/dev/null; check "check: bracket-differing decoy no longer squash-aliases a concealed call (#8)" "$?" "1"

# (b) POSITIVE CONTROL (no over-tightening): a genuinely disclosed mutation whose
#     inner content CONTAINS brackets ("[]") is still matched to its wrapped
#     session twin -> allowed. Guards against the hardening rejecting real writes.
cat > "$WORK/brackets-ok.json" <<'J'
{"actionUnderTest":"seed empty array","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem(\"founders\",\"[]\")"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"founders\",\"[]\"))"},{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/brackets-ok.json"; check "check: genuinely disclosed bracket-containing mutation still matches its twin (#8 no over-tighten)" "$?" "0"

# (c) QUOTE-STYLE CANONICALIZATION: a disclosed single-quoted payload matches its
#     double-quoted session twin (same inner content) -> allowed. The old squash
#     kept quote chars verbatim and FALSE-REJECTED this honest disclosure.
cat > "$WORK/quote-ok.json" <<'J'
{"actionUnderTest":"seed city","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem('city','riyadh')"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"city\",\"riyadh\"))"},{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/quote-ok.json"; check "check: disclosed single-quoted payload matches double-quoted session twin (#8 quote canon)" "$?" "0"

# (d) STRING-LITERAL PAREN (no content corruption): a disclosed payload whose string
#     VALUE contains a ')' must still match its wrapped twin. innerCode's arrow branch
#     drops EXACTLY ONE wrapper ')', leaving the literal ')' intact -> allowed. A greedy
#     "strip while closes > opens" balancer would eat the literal ')' and FALSE-REJECT
#     this honest write; this control guards that regression.
cat > "$WORK/litparen-ok.json" <<'J'
{"actionUnderTest":"seed label","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem(\"k\",\"a)\")"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"k\",\"a)\"))"},{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/litparen-ok.json"; check "check: disclosed payload with ')' inside a string literal still matches its twin (#8 no corruption)" "$?" "0"

# --- --allow-nonui lets a logged opt-out through (confidence low upstream) ----
node "$CHECK" "$WORK/evalact.json" --allow-nonui; check "check: --allow-nonui permits workaround" "$?" "0"

# --- record-evidence writes action-trace.json + checkpoint gates on it --------
RID="ht-1"
( cd "$WORK" && bash "$REC" "$RID" C1 action-trace --steps '[{"tool":"browser_click","target":"#add","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"click"}]' --fingerprint-before '0' --fingerprint-after '0' --action "add founder" >/dev/null )
check "record: action-trace.json written" "$([[ -f "$WORK/.qa/runs/$RID/evidence/C1/action-trace.json" ]] && echo yes)" "yes"
( cd "$WORK" && bash "$CKPT" "$RID" C1 pass --kinds human-action --evidence-refs evidence/C1/action-trace.json >/dev/null 2>&1 ); check "checkpoint: clean human-action pass accepted" "$?" "0"

# concealed workaround at the gate -> pass REJECTED (nonzero)
RID2="ht-2"
( cd "$WORK" && bash "$REC" "$RID2" C2 action-trace --steps '[{"tool":"browser_click","target":"#add","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"click"},{"class":"evaluate","mutating":true,"code":"localStorage.setItem(...)"}]' --action "add founder" >/dev/null )
( cd "$WORK" && bash "$CKPT" "$RID2" C2 pass --kinds human-action --evidence-refs evidence/C2/action-trace.json >/dev/null 2>&1 ); check "checkpoint: concealed workaround pass rejected" "$([[ $? -ne 0 ]] && echo yes)" "yes"

# --- opt-out END-TO-END: a mutating act-phase evaluate WITH --nonui-reason is
#     ACCEPTED at confidence low (F4/§2E). Without the reason it is REJECTED. ---
RID3="ht-3"
( cd "$WORK" && bash "$REC" "$RID3" C3 action-trace --steps '[{"tool":"browser_evaluate","phase":"act","payload":"el.value=-500"}]' --session-calls '[{"class":"evaluate","mutating":true,"code":"el.value=-500"}]' --action "enter -500" >/dev/null )
( cd "$WORK" && bash "$CKPT" "$RID3" C3 pass --kinds human-action --evidence-refs evidence/C3/action-trace.json --nonui-reason "tool: browser_type coerces -500 on type=number" >/dev/null 2>&1 ); check "checkpoint: opt-out (--nonui-reason) accepts a tool-limited workaround" "$?" "0"
check "checkpoint: opt-out forced confidence low" "$(cd "$WORK" && get ".qa/runs/$RID3/checkpoint.json" '.criteria[] | select(.criterion_id=="C3") | .confidence')" "low"
check "checkpoint: opt-out persisted nonUiActionReason" "$(cd "$WORK" && get ".qa/runs/$RID3/checkpoint.json" '.criteria[] | select(.criterion_id=="C3") | (.nonUiActionReason != null)')" "true"
# control: the SAME mutating act WITHOUT --nonui-reason is rejected (the gate still bites)
( cd "$WORK" && bash "$CKPT" "$RID3" C4 pass --kinds human-action --evidence-refs evidence/C3/action-trace.json >/dev/null 2>&1 ); check "checkpoint: same workaround WITHOUT opt-out is rejected" "$([[ $? -ne 0 ]] && echo yes)" "yes"

# --- #2 tamper-evidence: sessionCalls DERIVED from the real session.md via
#     --session-log overrides an agent's hidden --session-calls '[]' ---
RID4="ht-4"
cat > "$WORK/session4.md" <<'MD'
### Tool call: call
- Result
```json
{"code": "await page.locator('#add').click();"}
```
### Tool call: call
- Result
```json
{"code": "await page.evaluate(() => fetch('/api/items',{method:'POST',body:'{}'}));"}
```
MD
( cd "$WORK" && bash "$REC" "$RID4" C5 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[]' --session-log "$WORK/session4.md" --session-from 0 --action "add" >/dev/null )
check "record: --session-log derived the concealed POST into sessionCalls" "$(get "$WORK/.qa/runs/$RID4/evidence/C5/action-trace.json" '[.sessionCalls[] | select(.class=="evaluate" and .mutating==true)] | length')" "1"
( cd "$WORK" && bash "$CKPT" "$RID4" C5 pass --kinds human-action --evidence-refs evidence/C5/action-trace.json >/dev/null 2>&1 ); check "checkpoint: concealed POST caught via real session.md despite empty agent --session-calls" "$([[ $? -ne 0 ]] && echo yes)" "yes"

# --- #3 Check 3 (state-fingerprint net): an OPAQUE non-UI mutator the lint
#     cannot enumerate (window.app.create()) is caught when state changed with
#     no human-path act; a legit UI act with a state change is allowed. ---
RID5="ht-5"
( cd "$WORK" && bash "$REC" "$RID5" C6 action-trace --steps '[{"tool":"browser_evaluate","phase":"act","payload":"window.app.create()"}]' --session-calls '[{"class":"evaluate","mutating":false,"code":"window.app.create()"}]' --fingerprint-before '{"items":0}' --fingerprint-after '{"items":1}' --action "opaque create" >/dev/null )
( cd "$WORK" && bash "$CKPT" "$RID5" C6 pass --kinds human-action --evidence-refs evidence/C6/action-trace.json >/dev/null 2>&1 ); check "checkpoint: opaque non-UI mutator caught by Check 3 (state changed, no human-path act)" "$([[ $? -ne 0 ]] && echo yes)" "yes"
( cd "$WORK" && bash "$REC" "$RID5" C7 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"click"}]' --fingerprint-before '{"items":0}' --fingerprint-after '{"items":1}' --action "click add" >/dev/null )
( cd "$WORK" && bash "$CKPT" "$RID5" C7 pass --kinds human-action --evidence-refs evidence/C7/action-trace.json >/dev/null 2>&1 ); check "checkpoint: legit UI act with a state change is allowed (Check 3 no false-reject)" "$?" "0"

# --- capstone re-review regressions (N1/N2/R1) ---
# N1: --session-from past the log length must be REFUSED (not a silent empty slice)
cat > "$WORK/session6.md" <<'MD'
### Tool call: call
- Result
```json
{"code": "await page.locator('#add').click();"}
```
### Tool call: call
- Result
```json
{"code": "await page.evaluate(() => fetch('/api/items',{method:'POST'}));"}
```
MD
( cd "$WORK" && bash "$REC" "$RID5" C8 action-trace --steps '[{"tool":"browser_click","phase":"act"}]' --session-log "$WORK/session6.md" --session-from 999 --fingerprint-before 0 --fingerprint-after 0 >/dev/null 2>&1 ); check "record: --session-from past end is refused (N1)" "$([[ $? -ne 0 ]] && echo yes)" "yes"
# N2: a decoy human-path act step must NOT launder an opaque non-UI mutator act step when state changed
cat > "$WORK/decoy2.json" <<'J'
{"actionUnderTest":"opaque+decoy","steps":[{"tool":"browser_evaluate","phase":"act","payload":"window.app.store.createItem({n:1})"},{"tool":"browser_click","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":false,"code":"window.app.store.createItem({n:1})"}],"fingerprints":{"before":{"items":0},"after":{"items":1}}}
J
node "$CHECK" "$WORK/decoy2.json" 2>/dev/null; check "check: decoy click does not launder an opaque mutator act step (N2)" "$?" "1"
# R1: a human-action pass with NO fingerprints is rejected (Check 3 can't be skipped)
cat > "$WORK/nofp.json" <<'J'
{"actionUnderTest":"axios","steps":[{"tool":"browser_evaluate","phase":"act","payload":"window.app.create()"}],"sessionCalls":[{"class":"evaluate","mutating":false,"code":"window.app.create()"}]}
J
node "$CHECK" "$WORK/nofp.json" 2>/dev/null; check "check: missing fingerprints rejects a human-action pass (R1)" "$?" "1"

# --- gap A: act-phase browser_navigate is fail-closed unless carve-out-tagged -
cat > "$WORK/nav-bare.json" <<'J'
{"actionUnderTest":"open deliverables","steps":[{"tool":"browser_navigate","target":"/track?dialog=deliverables","phase":"act"}],"sessionCalls":[],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/nav-bare.json" 2>/dev/null; check "check: bare act-phase navigate (URL-skip) rejected" "$?" "1"

cat > "$WORK/nav-deeplink.json" <<'J'
{"actionUnderTest":"open emailed reset link","steps":[{"tool":"browser_navigate","target":"/password/reset/abc","phase":"act","carveout":"deep-link"}],"sessionCalls":[],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/nav-deeplink.json"; check "check: deep-link-tagged act navigate allowed" "$?" "0"

cat > "$WORK/nav-authbound.json" <<'J'
{"actionUnderTest":"blocked route negative","steps":[{"tool":"browser_navigate","target":"/admin/settings","phase":"act","carveout":"auth-boundary"}],"sessionCalls":[],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/nav-authbound.json"; check "check: auth-boundary-tagged act navigate allowed" "$?" "0"

# an INVALID carve-out value must NOT pass — this pins NAV_CARVEOUTS.has() set
# membership, not a truthy `s.carveout` check (which would accept any non-empty tag)
cat > "$WORK/nav-badtag.json" <<'J'
{"actionUnderTest":"bogus tag","steps":[{"tool":"browser_navigate","target":"/x","phase":"act","carveout":"nope"}],"sessionCalls":[],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/nav-badtag.json" 2>/dev/null; check "check: invalid carve-out value on act navigate rejected" "$?" "1"

# an ARRANGE-phase navigate is not an act step and never triggers gap A
cat > "$WORK/nav-arrange.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_navigate","target":"/feature","phase":"arrange"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"}],"fingerprints":{"before":0,"after":0}}
J
node "$CHECK" "$WORK/nav-arrange.json"; check "check: arrange-phase navigate + human-path act passes" "$?" "0"

echo; echo "action-trace tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
