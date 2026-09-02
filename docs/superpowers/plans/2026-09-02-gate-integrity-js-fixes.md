# Gate-Integrity JS Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two honest-agent gaps in the human-action gate — a mutation classifier that misses lowercase/template-literal/`axios`/`page.request` writes (gap #3), and an act-phase `browser_navigate` URL-skip that the gate treats as a legitimate human action (gap A).

**Architecture:** Both fixes are pure edits to two existing, dependency-free bundled scripts — `parse-session-log.js` (the shared mutation classifier) and `check-action-trace.js` (the human-action gate) — verified by extending the existing bash test runner `tests/action-trace/run.sh`. No new files, no new dependencies, no new infrastructure.

**Tech Stack:** Node.js (dependency-free, browser-agnostic JS), bash test runners, `jq`/`node` for assertions.

## Global Constraints

- **Verdict/vocabulary unchanged.** Verdicts stay exactly `pass | fail | blocked | deferred | error`; confidence `high | low`; no sixth verdict. (Spec §13.7 / CLAUDE.md invariant.)
- **Bundled scripts stay dependency-free.** `parse-session-log.js` and `check-action-trace.js` use only Node built-ins; no npm packages. (CLAUDE.md.)
- **`classify`/`mutates` remain the single source of truth.** `check-action-trace.js` imports `mutates` from `parse-session-log.js` (`check-action-trace.js:30`). Do not fork the classifier. (Source comment `parse-session-log.js:14`.)
- **Tests are bash runners at `tests/<name>/run.sh`.** Extend `tests/action-trace/run.sh`; assertions use its `check "name" "$got" "$want"` helper. (Repo convention.)
- **Validate before every commit:** `node --check <file.js>` for JS, `bash -n <file.sh>` for shell, the full `bash tests/action-trace/run.sh` must exit 0, and — because both edited scripts are core files copied verbatim into `dist/<harness>/` — `bash tests/portability/run.sh && bash scripts/validate-adapters.sh` must also exit 0. (CLAUDE.md "Validate before committing" + portability byte-oracle.)
- **Regenerate `dist/` after editing a core script.** `parse-session-log.js` and `check-action-trace.js` are copied verbatim into `dist/{claude,codex,pi,opencode}/` by the generator. After the edits, regenerate all four adapters — `for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done` (this is exactly what `scripts/validate-adapters.sh:25` does before it diffs the byte-oracle, so running `validate-adapters.sh` both regenerates and checks). `dist/` is git-ignored (not committed), so this is a CI-parity gate, not a commit artifact: the edited scripts change no committed root file (the byte-oracle diffs only `agents/`+`commands/`, generated from `core/` prose), but running the portability gate proves the copy-through still assembles cleanly. Do this in each task's final commit step, before committing.
- **Commit messages contain no Claude/Anthropic attribution and no `Co-Authored-By` trailer.** (User global rule.)
- **`carveout` field provenance is out of scope here.** This plan makes the gate *read* an optional `step.carveout` tag; the persona/doctrine change that makes the agent *set* it (`deep-link`/`auth-boundary`) is WS-2 (a separate plan). Until then, an act-phase navigate is simply rejected — fail-closed, which is the intended default.

---

### Task 1: Semantic mutation classifier (gap #3)

Make `mutates()` recognize state-writing network calls it currently misses: lowercase HTTP methods (`method:'post'`), template-literal methods (`` method:`POST` ``), and `.post(`/`.put(`/`.patch(`/`.delete(` call forms (`axios.post(...)`, `page.request.post(...)`, XHR `.open('post', …)`). Read-only reads (`GET`, `getComputedStyle`, `.get(`) must stay non-mutating.

**Files:**
- Modify: `skills/driving-browser-qa/scripts/parse-session-log.js:21` (the `MUTATION_RE` constant)
- Test: `tests/action-trace/run.sh` (extend the parse/classify section, after line 45)

**Interfaces:**
- Consumes: nothing new.
- Produces: `mutates(src: string) → boolean` (unchanged signature, `parse-session-log.js:26`) and `classify(code)` (unchanged) — behavior widened so more write forms return `mutating: true`. `check-action-trace.js` consumes `mutates` unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `tests/action-trace/run.sh` immediately after line 45 (`check "parse: setItem evaluate mutating=true" …`):

```bash
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
```

**Also modify the pre-existing R1 test (`nofp.json`, currently at run.sh:193-194) in this same task.** Task 1 widens the classifier, which changes what `nofp.json` actually tests. Today its act payload `axios.post('/api/items',{})` is classified non-mutating, so the gate reaches Check 3 and rejects for *missing fingerprints* — the R1 case. After Task 1, `axios.post(` mutates → the gate rejects at Check 1/2 (workaround) and **never reaches the fingerprint branch**, silently gutting the R1 regression (it still exits 1, so it stays green for the wrong reason). Change the payload — and the twin `sessionCalls[].code` — to an **opaque, non-linted** mutator that survives Check 1/2 so the case still pins Check 3:

```javascript
// run.sh nofp.json — replace both `axios.post('/api/items',{})` occurrences with:
"window.app.create()"
```

`window.app.create()` is not matched by `MUTATION_RE` (before or after Task 1), so it passes Check 1/2, and with no `fingerprints` key the gate dies at the R1 branch — exactly what the "missing fingerprints rejects a human-action pass (R1)" case must exercise.

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bash tests/action-trace/run.sh`
Expected: FAIL lines for `fetch post lowercase`, `fetch method backtick`, `page.request.post`, `axios.post`, `axios.delete`, `XHR open('post')` (they print `got 'false' want 'true'`), **and** for `axios.post on act rejected (new-form act-path)` (currently exits 0 → `got '0' want '1'`); the uppercase, the `.postMessage`, the `page.request.get on act`, and the other negative-control cases already pass; the modified `nofp.json` (R1) still passes (now for the right reason — opaque payload → Check 3). The final line reports `FAIL` non-zero.

- [ ] **Step 3: Widen `MUTATION_RE`**

In `skills/driving-browser-qa/scripts/parse-session-log.js`, replace the whole `MUTATION_RE` constant at line 21 with:

```javascript
const MUTATION_RE = /\.setItem\(|\.removeItem\(|localStorage\.clear\(|sessionStorage\.(set|remove|clear)|\.value\s*=|\.checked\s*=|\.innerHTML\s*=|\.innerText\s*=|\.textContent\s*=|\.setAttribute\(|\.dispatchEvent\(|\.click\(\)|\.submit\(\)|\.requestSubmit\(|\.remove\(\)|\[['"`](value|checked|innerHTML|innerText|textContent)['"`]\]\s*=|document\.\w+\s*=|window\.\w+\s*=|method\s*:\s*['"`]\s*(POST|PUT|PATCH|DELETE)|\.open\(\s*['"`]\s*(POST|PUT|PATCH|DELETE)|\.(post|put|patch|delete)\s*\(|sendBeacon\(|\.dispatch\(|setState\(/i;
```

Changes from the original: a trailing `/i` flag (matches lowercase `post`); a backtick added to the two method char-classes `['"`]` (matches template literals); and one new alternative `\.(post|put|patch|delete)\s*\(` (matches `axios.post(`, `page.request.post(`, `client.delete(`). `GET`/`.get(`/`.head(` are deliberately not listed, so reads stay non-mutating.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --check skills/driving-browser-qa/scripts/parse-session-log.js && bash tests/action-trace/run.sh && bash tests/portability/run.sh && bash scripts/validate-adapters.sh`
Expected: `node --check` prints nothing (exit 0); the runner prints `action-trace tests: PASS=<N> FAIL=0` and exits 0. In particular the pre-existing case `check: backend fetch POST on act rejected` (line 77) still passes, the modified `nofp.json` R1 case still passes (opaque payload → Check 3), and the new lowercase/backtick/`.post(` classifier cases + the `axios.post` act-path integration case now pass. The portability gate regenerates `dist/{claude,codex,pi,opencode}/` (re-copying the edited `parse-session-log.js`) and confirms the byte-oracle still holds — both exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/driving-browser-qa/scripts/parse-session-log.js tests/action-trace/run.sh
git commit -m "fix(gate): semantic mutation classifier catches lowercase/template/axios/page.request writes"
```

---

### Task 2: Navigate fail-closed (gap A)

An act-phase `browser_navigate` is a URL-skip workaround unless the step carries a carve-out tag (`deep-link` or `auth-boundary`). Today `browser_navigate` sits in `HUMAN_PATH_TOOLS`, so the gate accepts any act-phase navigate as a legitimate human action. Following a real link is a `browser_click` side effect, never a `browser_navigate` call — so an act-path `browser_navigate` is an address-bar jump by nature.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/check-action-trace.js:31` (the `HUMAN_PATH_TOOLS` set), `:38-42` (`actStepIsWorkaround`), `:124` (Check 3's non-human-path finder)
- Test: `tests/action-trace/run.sh` (add a navigate section before the final summary, after line 196)

**Interfaces:**
- Consumes: `mutates` (from Task 1, unchanged).
- Produces: an act-phase `browser_navigate` step now needs an optional `carveout` field on the step object (`{tool:"browser_navigate", phase:"act", carveout:"deep-link"|"auth-boundary"}`) to pass; absent/other value → rejected. No change to any other tool's handling.

- [ ] **Step 1: Write the failing tests**

Append to `tests/action-trace/run.sh` immediately before the summary line (before line 198 `echo; echo "action-trace tests: …"`):

```bash
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
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `bash tests/action-trace/run.sh`
Expected: FAIL on `bare act-phase navigate (URL-skip) rejected` **and** on `invalid carve-out value on act navigate rejected` — both currently exit 0 (navigate is in `HUMAN_PATH_TOOLS`, `carveout` ignored), so `got '0' want '1'`. The two valid-carve-out cases and the arrange case already pass. Final line reports `FAIL` non-zero.

- [ ] **Step 3: Remove `browser_navigate` from the human-path set and add the carve-out rule**

In `skills/checkpointing-qa-memory/scripts/check-action-trace.js`, replace line 31:

```javascript
const HUMAN_PATH_TOOLS = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_file_upload','browser_navigate']);
```

with (drop `browser_navigate`; add the carve-out set + helper):

```javascript
const HUMAN_PATH_TOOLS = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_file_upload']);
// browser_navigate is NOT a human-path act tool: following a real link is a
// browser_click side effect, so an act-phase browser_navigate is an address-bar
// URL-skip (gap A) — fail-closed unless the step is carve-out-tagged.
const NAV_CARVEOUTS = new Set(['deep-link', 'auth-boundary']);
function navIsCarvedOut(s) { return s.tool === 'browser_navigate' && NAV_CARVEOUTS.has(s.carveout); }
```

- [ ] **Step 4: Make `actStepIsWorkaround` reject a bare act navigate**

In the same file, replace the `actStepIsWorkaround` body at lines 38-42:

```javascript
function actStepIsWorkaround(s) {
  if (HUMAN_PATH_TOOLS.has(s.tool)) return false;
  if (s.tool === 'browser_evaluate') return mutates(s.payload || '') === true;
  return true; // browser_run_code_unsafe, browser_route, or any non-human-path tool
}
```

with:

```javascript
function actStepIsWorkaround(s) {
  if (s.tool === 'browser_navigate') return !navIsCarvedOut(s); // act-phase URL-skip unless carve-out-tagged
  if (HUMAN_PATH_TOOLS.has(s.tool)) return false;
  if (s.tool === 'browser_evaluate') return mutates(s.payload || '') === true;
  return true; // browser_run_code_unsafe, browser_route, or any non-human-path tool
}
```

- [ ] **Step 5: Keep Check 3 consistent (a carve-out navigate is a legitimate cause)**

In the same file, replace the Check-3 finder at line 124:

```javascript
    const bad = actSteps.find((s) => !HUMAN_PATH_TOOLS.has(s.tool));
```

with (a carve-out navigate counts as a human-attributable cause; a bare navigate does not — though a bare act navigate is already rejected at Check 1/2 above):

```javascript
    const bad = actSteps.find((s) => !HUMAN_PATH_TOOLS.has(s.tool) && !navIsCarvedOut(s));
```

- [ ] **Step 6: Run the full suite to verify pass + no regressions**

Run: `node --check skills/checkpointing-qa-memory/scripts/check-action-trace.js && bash tests/action-trace/run.sh && bash tests/portability/run.sh && bash scripts/validate-adapters.sh`
Expected: `node --check` exit 0; runner prints `action-trace tests: PASS=<N> FAIL=0` and exits 0. All pre-existing cases (clean UI-only act, mutating-evaluate rejection, Check 0 concealed/decoy, Check 3 opaque-mutator, R1 missing-fingerprints) still pass — none of them used `browser_navigate`, so removing it from `HUMAN_PATH_TOOLS` does not affect them; the new bare/invalid-tag navigate cases now reject and the valid-carve-out cases still pass. The portability gate regenerates `dist/{claude,codex,pi,opencode}/` (re-copying the edited `check-action-trace.js`) and confirms the byte-oracle still holds — both exit 0.

- [ ] **Step 7: Commit**

```bash
git add skills/checkpointing-qa-memory/scripts/check-action-trace.js tests/action-trace/run.sh
git commit -m "fix(gate): fail-closed on act-phase browser_navigate URL-skip unless carve-out-tagged"
```

---

## Follow-on plans (not in this plan — scoped separately)
- **#8 squash hardening** — delicate: the current `squash()` strips wrapper parens on purpose so a disclosed arrange-mutation matches its `session.md` twin; hardening it must preserve the existing decoy/prefix/disclosure tests. Its own plan.
- **#2 `--kinds` binding + `checklist.json` required-kinds** — touches `checkpoint.sh` + `generating-qa-checklist` + a new deterministic kind-derivation; the *authoritative* enforcement is `qa-verify`. Its own plan.
- **#4 fingerprint-target** — the in-script coverage check is weak (agent declares the asserted state); the sound enforcement is `qa-verify`'s re-bake. Folded into the `qa-verify` plan.
- **Capture-hook / block-hook / `qa-verify`** — new plugin infrastructure; separate plan(s) per Spec 1 §5.
- **Stale doctrine row in `docs/specs/human-interaction-discipline.md:82`** — the row `browser_navigate to a link/button destination reached via UI | ✅ act` contradicts gap A's new rule (following a real link is a `browser_click` side effect; an act-path `browser_navigate` is a URL-skip). Not fixed here: it is prose/doctrine, which this plan scopes to **WS-2** (same bucket as the persona change that *sets* `carveout`). The skills-embodied reference `skills/driving-browser-qa/references/interaction-discipline.md` is already consistent (it lists navigate only under *Arrange*), so the gate and its live doc agree today; only the older spec table lags.

## Self-Review
- **Spec coverage:** This plan implements Spec 1 gaps **#3** (Task 1) and **A** (Task 2) — the two in-script fixes with no dependency on new infra. Spec §5A/#2's "each §3-#3 payload *on the act path* → workaround-rejected" is now proven end-to-end through `$CHECK` (the `axios.post` act-path integration case), not just at the classifier unit; acceptance-#4 (invalid carve-out rejected) is pinned by the `nav-badtag` case that forces `NAV_CARVEOUTS.has()` set-membership. Remaining WS-1 items (#8, #2, #4) are explicitly deferred above with reasons; no silent gap.
- **Cross-task effect (guarded):** Task 1 widening `MUTATION_RE` changes which branch the pre-existing R1 test (`nofp.json`) exits on — so Task 1 also re-points that test's payload to an opaque non-linted mutator (`window.app.create()`) to keep it exercising Check 3's missing-fingerprint branch rather than silently degrading to a Check-1/2 rejection.
- **Placeholder scan:** none — every step has the exact code, exact commands, and exact expected output.
- **Type consistency:** `mutates(src)→boolean` and `navIsCarvedOut(s)→boolean` are used consistently; `NAV_CARVEOUTS`/`HUMAN_PATH_TOOLS` names match between definition (Step 3) and use (Steps 4-5). The `carveout` step field name matches between the tests (Task 2 Step 1) and the gate (`navIsCarvedOut`).
- **Dist parity:** both edited scripts are copied verbatim into `dist/<harness>/`; each task's validation step now regenerates all four adapters and runs the portability byte-oracle (`tests/portability/run.sh` + `scripts/validate-adapters.sh`), so a CI byte-drift can't slip through. `dist/` stays git-ignored.
