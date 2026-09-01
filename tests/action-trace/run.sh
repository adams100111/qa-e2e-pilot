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
### Ran Playwright code
```js
await page.locator('#name').fill('Alice');
```
### Ran Playwright code
```js
await page.locator('#add').click();
```
### Ran Playwright code
```js
await page.evaluate(() => getComputedStyle(document.body).color);
```
### Ran Playwright code
```js
await page.evaluate(() => localStorage.setItem('captable:founders','[]'));
```
MD
PARSED="$(node "$PARSE" "$WORK/session.md")"
jlen() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s);process.stdout.write(String('"$1"'))})'; }
check "parse: found 4 code calls"          "$(echo "$PARSED" | jlen 'a.length')" "4"
check "parse: 2 human-path clicks/fills"   "$(echo "$PARSED" | jlen 'a.filter(c=>c.class==="human-path").length')" "2"
check "parse: read-only evaluate mutating=false" "$(echo "$PARSED" | jlen 'a.filter(c=>c.class==="evaluate"&&!c.mutating).length')" "1"
check "parse: setItem evaluate mutating=true"    "$(echo "$PARSED" | jlen 'a.filter(c=>c.class==="evaluate"&&c.mutating).length')" "1"

# --- check-action-trace.js: clean UI-only act -> exit 0 -----------------------
cat > "$WORK/clean.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_type","target":"#name","phase":"arrange"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"}]}
J
node "$CHECK" "$WORK/clean.json"; check "check: clean UI-only act passes" "$?" "0"

# --- Q2 (fatal FP guard): a read-only observe evaluate in session.md is IGNORED
cat > "$WORK/observe.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"},{"class":"evaluate","mutating":false,"code":"getComputedStyle(document.body)"}]}
J
node "$CHECK" "$WORK/observe.json"; check "check: read-only observe evaluate NOT flagged (Q2)" "$?" "0"

# --- Check 1/2: an act-phase MUTATING evaluate -> exit 1 (payload classifies) --
cat > "$WORK/evalact.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"setItem","phase":"act","payload":"localStorage.setItem('captable:founders','[]')"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"localStorage.setItem('captable:founders','[]')"}]}
J
node "$CHECK" "$WORK/evalact.json" 2>/dev/null; check "check: mutating evaluate on act rejected" "$?" "1"

# --- a READ-ONLY evaluate ON the act path is allowed (payload doesn't mutate) --
cat > "$WORK/readact.json" <<'J'
{"actionUnderTest":"read total","steps":[{"tool":"browser_evaluate","target":"read","phase":"act","payload":"getComputedStyle(document.body).color"}],"sessionCalls":[{"class":"evaluate","mutating":false,"code":"getComputedStyle"}]}
J
node "$CHECK" "$WORK/readact.json"; check "check: read-only evaluate on act allowed" "$?" "0"

# --- CRITICAL regression: a concealed NON-DOM write on the act path (backend
#     fetch POST / XHR / framework dispatch) must be caught by the mutation lint,
#     not just DOM/storage writes (final-review Critical) ---
cat > "$WORK/fetchact.json" <<'J'
{"actionUnderTest":"create item","steps":[{"tool":"browser_evaluate","target":"post","phase":"act","payload":"fetch('/api/items',{method:'POST',body:'{}'})"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => fetch('/api/items',{method:'POST',body:'{}'}))"}]}
J
node "$CHECK" "$WORK/fetchact.json" 2>/dev/null; check "check: backend fetch POST on act rejected (network-write lint)" "$?" "1"
cat > "$WORK/dispatchact.json" <<'J'
{"actionUnderTest":"add via store","steps":[{"tool":"browser_evaluate","target":"dispatch","phase":"act","payload":"store.dispatch({type:'ADD_ITEM'})"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => store.dispatch({type:'ADD_ITEM'}))"}]}
J
node "$CHECK" "$WORK/dispatchact.json" 2>/dev/null; check "check: framework store.dispatch on act rejected" "$?" "1"
# a read-only GET fetch on the act path stays allowed (must NOT false-reject)
cat > "$WORK/getfetch.json" <<'J'
{"actionUnderTest":"read list","steps":[{"tool":"browser_evaluate","target":"get","phase":"act","payload":"fetch('/api/items').then(r=>r.json())"}],"sessionCalls":[{"class":"evaluate","mutating":false,"code":"await page.evaluate(() => fetch('/api/items'))"}]}
J
node "$CHECK" "$WORK/getfetch.json"; check "check: read-only GET fetch on act allowed (no false-reject)" "$?" "0"

# --- a RECORDED mutating evaluate (e.g. arrange seed) covers its session twin --
cat > "$WORK/recorded.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem('seed','1')"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"localStorage.setItem('seed','1')"},{"class":"human-path","mutating":true,"code":"await page.locator('#add').click()"}]}
J
node "$CHECK" "$WORK/recorded.json"; check "check: recorded arrange-mutation covers its twin (not concealed)" "$?" "0"

# --- Check 0: concealed MUTATING workaround (in session.md, no recorded step) --
cat > "$WORK/concealed.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#add').click();"},{"class":"evaluate","mutating":true,"code":"localStorage.setItem('captable:founders','[]')"}]}
J
node "$CHECK" "$WORK/concealed.json" 2>/dev/null; check "check: concealed mutating workaround rejected (Check 0)" "$?" "1"

# --- Check 0 (CONTENT-MATCH): a fabricated DECOY mutating step must NOT cover
# an unrelated genuine concealed workaround — a bare count would let this
# through (the "grades its own homework" bypass this gate exists to stop).
cat > "$WORK/decoy.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"decoy","phase":"arrange","payload":"document.title=\"x\""},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"},{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"captable:founders\",\"[]\"))"}]}
J
node "$CHECK" "$WORK/decoy.json" 2>/dev/null; check "check: decoy mutating step does not cover unrelated concealed call" "$?" "1"

# --- Check 0 (CONTENT-MATCH): a PREFIX of the concealed call must not match --
cat > "$WORK/prefix-decoy.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"decoy","phase":"arrange","payload":"localStorage.setItem("},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"},{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"captable:founders\",\"[]\"))"}]}
J
node "$CHECK" "$WORK/prefix-decoy.json" 2>/dev/null; check "check: prefix-only decoy does not cover the full concealed call" "$?" "1"

# --- Check 0 (CONTENT-MATCH): a genuinely disclosed arrange-mutation IS allowed
cat > "$WORK/disclosed.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"seed","phase":"arrange","payload":"localStorage.setItem(\"seed\",\"1\")"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"class":"evaluate","mutating":true,"code":"await page.evaluate(() => localStorage.setItem(\"seed\",\"1\"))"},{"class":"human-path","mutating":true,"code":"await page.locator(\"#add\").click()"}]}
J
node "$CHECK" "$WORK/disclosed.json"; check "check: disclosed arrange-mutation with matching content is allowed" "$?" "0"

# --- --allow-nonui lets a logged opt-out through (confidence low upstream) ----
node "$CHECK" "$WORK/evalact.json" --allow-nonui; check "check: --allow-nonui permits workaround" "$?" "0"

# --- record-evidence writes action-trace.json + checkpoint gates on it --------
RID="ht-1"
( cd "$WORK" && bash "$REC" "$RID" C1 action-trace --steps '[{"tool":"browser_click","target":"#add","phase":"act"}]' --session-calls '[{"class":"human-path","mutating":true,"code":"click"}]' --action "add founder" >/dev/null )
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

echo; echo "action-trace tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
