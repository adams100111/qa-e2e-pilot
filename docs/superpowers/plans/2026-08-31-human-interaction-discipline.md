# Human-Interaction Discipline + Hardened Round-Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Force the QA agent to perform every action-under-test through genuine human UI affordances — machine-verified against an independent Playwright `--save-session` log — treat a UI-impossible action as a `fail@FE`, wire per-run role/scenario selection into the orchestrator, and turn the grilling round-pattern into a tested frontier engine.

**Architecture:** Extend the existing Phase-1 evidence gate (`checkpoint.sh`) with a new evidence **kind `human-action`** whose value-check is delegated to one dependency-free Node module (`check-action-trace.js`) so the complex act/observe reconciliation lives in a single tested unit, not duplicated across checkpoint.sh's jq/python paths. The independent ground truth is Playwright MCP's `--save-session` `session.md`, pre-parsed to JSON by `parse-session-log.js` so bash never parses markdown. The round-engine becomes a standalone `frontier.js` module with fixture tests. All new logic is dependency-free JS + bash tests matching the repo's existing `tests/<name>/run.sh` harness.

**Tech Stack:** Bash (checkpoint.sh/record-evidence.sh, jq-or-python3), dependency-free Node (browser-context + gate helpers), Playwright MCP (`--save-session`), Markdown skills/ADRs, JSON config. No new runtime dependencies (Node is already a hard prereq via `scripts/check-prereqs.sh`).

## Global Constraints

- Verdicts are EXACTLY `pass | fail | blocked | deferred | error`. `human-action` is an evidence **kind**, never a sixth verdict. (CLAUDE.md invariant.)
- Suspected layer is EXACTLY one of `FE | route | service | migration | DB`. UI-impossible actions are `fail @ FE`, confidence `high`.
- The **oracle** is the spec/domain rule, never the backend's own formula. The oracle — not the agent — decides UI-impossible (bug) vs correct-rejection (pass).
- Run state lives in `.qa/runs/<run-id>/` as plain files (ADR-0002), never agent memory. Verification is sequential by default (ADR-0003).
- Evidence gate stays REJECT-not-downgrade: a `pass` lacking/contradicted-by evidence is rejected; the honest fallback is `blocked` (or the true verdict). Never drop `--kinds` to force a pass through.
- New evidence kind name is exactly `human-action`; its canonical artifact is exactly `action-trace.json` (mirrors the `bake→bake-read-back.json` / `computed→recompute.json` / `probe→network-response.json` convention).
- Bundled scripts depend on `jq` OR `python3`; browser/gate-helper JS is dependency-free Node (`document`/`window`/`fetch` in-page; `process`/`fs` for gate helpers). Secrets never printed.
- Skill frontmatter has ONLY `name` + `description`; `name` == directory name, lowercase-hyphen gerund, no "claude". Skill body < 500 lines.
- Commit messages: NO Claude/Anthropic attribution, NO `Co-Authored-By: Claude`, NO "Generated with Claude Code" (user global rule overrides the repo trailer convention).
- Tool allowlist for the **act** phase (human-path): `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_select_option`, `browser_hover`, `browser_drag`, `browser_file_upload`, plus real link/button navigation (`browser_navigate` only to a URL reached by activating a real affordance — NOT to skip a gated step). Everything else on the act path is a workaround.
- Workaround tools (rejected on the act path unless `nonUiActionReason` present): `browser_evaluate` that sets `.value`/clicks/calls app fns/dispatches events, `browser_run_code_unsafe`, `browser_route` intercepting the backend-under-test, any direct API/DB/localStorage write.

---

## File Structure

**New files:**
- `skills/confirming-discovered-roles/scripts/frontier.js` — dependency-free frontier-state engine (Task 2).
- `tests/frontier/run.sh` — frontier engine tests (Task 2).
- `skills/checkpointing-qa-memory/scripts/check-action-trace.js` — the `human-action` reconciliation (Check 0∧1∧2) as one Node unit (Task 3).
- `skills/driving-browser-qa/scripts/parse-session-log.js` — parse Playwright `session.md` → JSON call list (Task 3).
- `tests/action-trace/run.sh` — gate + reconciliation tests (Task 3).
- `skills/driving-browser-qa/references/interaction-discipline.md` — the act/observe rules, tool matrix, UI-impossible→fail, reconciliations, driver-optimization rules (Task 5).
- `docs/adr/0015-human-interaction-discipline.md` — the ADR (Task 1).

**Modified files:**
- `skills/checkpointing-qa-memory/scripts/checkpoint.sh` — register `human-action` kind + delegate its value-check to `check-action-trace.js` (Task 3).
- `skills/checkpointing-qa-memory/scripts/record-evidence.sh` — add the `action-trace` writer (Task 3).
- `skills/generating-qa-checklist/SKILL.md` — derive the `human-action` kind for action-bearing criteria (Task 4).
- `skills/driving-browser-qa/SKILL.md` — launch `--save-session`, copy `session.md` into the run dir, reference `interaction-discipline.md` (Task 5).
- `skills/driving-browser-qa/scripts/react-set-input.js`, `skills/driving-browser-qa/scripts/click-by-text.js` — demote to read-only per 2C (Task 5).
- `.qa/config.json.example` — `humanInteraction` + isolation keys (Task 6).
- `agents/qa-e2e-pilot.md` — per-run selection wiring + `--save-session` launch + gate note (Task 7).
- `skills/confirming-discovered-roles/SKILL.md`, `skills/bootstrapping-qa-config/references/hitl-rounds.md` — drive `frontier.js`; review pass (Tasks 2 + 9).
- `tools/accuracy-harness/fixture/index.html`, `.../seeds.json` — concealed-workaround + UI-impossible fixture cases (Task 8).

---

## Task 1: ADR-0015 (records the hard-to-reverse decisions)

**Files:**
- Create: `docs/adr/0015-human-interaction-discipline.md`

**Interfaces:**
- Produces: the canonical record every later task cites. No code.

- [ ] **Step 1: Write the ADR** (follow the numbering/format of `docs/adr/0010-*.md`)

```markdown
# 0015. Human-Interaction Discipline — act through the UI only, UI-impossible is a bug

Status: Accepted
Date: 2026-08-31

## Context
The QA agent could pass a criterion by driving the app through non-human paths
(`browser_evaluate` setting `.value`/clicking, `run_code_unsafe`, direct
localStorage/API writes, URL-skipping a gated step). That manufactures greens a
real user could never reach, and hides genuine FE defects (a missing/broken
affordance). The agent must behave like a human tester and never work around the UI.

## Decision
1. Every criterion runs **Arrange → Act → Assert**. The **Act** phase (the
   action-under-test) uses ONLY human-path tools (click/type/fill/press/select/
   hover/drag/file_upload + real link/button nav). **Observe** may read anything
   (read-only `browser_evaluate`, console/network, screenshots, read-only probe).
2. If the action-under-test cannot be done through a real affordance, that IS a
   bug: **`fail @ FE`, confidence `high`** — never `blocked`, never a workaround.
   The **oracle** distinguishes UI-impossible (bug) from a control correctly
   rejecting invalid input (pass).
3. Enforcement is a new evidence **kind `human-action`** on the Phase-1 gate
   (`checkpoint.sh`). Its artifact is `action-trace.json`. The gate reconciles the
   agent's self-reported act steps against Playwright MCP's INDEPENDENT
   `--save-session` `session.md` (parsed to JSON): a mutating call present in the
   session log but absent from the self-reported act trace is a **concealed
   workaround → REJECT**. This closes the self-report hole (the agent cannot grade
   its own homework). Residual trust: phase attribution is still agentic, bounded
   by the independent act-window and an optional reviewer spot-check.
4. A per-criterion **`nonUiActionReason`** logs a genuine tool limitation (e.g.
   `browser_type` coercing `-500` on `type=number`), permitting the workaround for
   that criterion at **confidence `low`**. A run whose opt-out rate exceeds ~20% of
   `human-action` criteria is flagged (opt-out-abuse guard).
5. Isolation boundary is the **(identity, session)**, not the criterion and not the
   data: one context per session, reused across its criteria; handoffs use separate
   sessions over a SHARED backend; ≈1 context open at a time under ADR-0003;
   `maxOpenContexts` caps fan-out.

## Consequences
- `react-set-input.js` and `click-by-text.js` are demoted to read-only helpers;
  act-path value entry/clicks use `browser_type`/`browser_fill_form`/`browser_click`.
- F4 (negative-share entry) uses the logged opt-out (tool limitation), staying
  catchable at confidence `low`.
- `browser_route` intercepting the backend-under-test is a forbidden workaround
  (manufactures a pass, violates oracle-independence).
- Verdict enum, oracle rule, ADR-0002 file-state, and ADR-0003 sequential default
  are unchanged. `human-action` is a kind, not a verdict.
```

- [ ] **Step 2: Validate + commit**

Run: `python3 -c "print(open('docs/adr/0015-human-interaction-discipline.md').read()[:1])"`
Expected: prints `#` (file exists/readable).

```bash
git add docs/adr/0015-human-interaction-discipline.md
git commit -m "docs(adr): 0015 human-interaction discipline — act-UI-only, UI-impossible=fail, session.md gate"
```

---

## Task 2: `frontier.js` round-engine module + tests (spec §2F / A5)

**Files:**
- Create: `skills/confirming-discovered-roles/scripts/frontier.js`
- Test: `tests/frontier/run.sh`
- Modify (docs only): `skills/bootstrapping-qa-config/references/hitl-rounds.md` (add a one-line pointer that the pattern is now executable via `frontier.js`)

**Interfaces:**
- Produces (CommonJS exports consumed by Task 7's wiring and Task 9's review):
  - `computeFrontier(tree, settled) -> { frontier: string[], deferred: string[], settledIds: string[] }`
  - `recommendedDefault(tree, id) -> any` (the node's `default`, or `null`)
  - `applyAnswers(tree, settled, answers) -> settled'` (adds answers; unsettles dependents of any edited node)
  - `budgetExceeded(rounds, budget) -> boolean`
  - Tree shape: `{ nodes: [ { id: string, prereqs: string[], default?: any } ] }`; `settled` is an object `{ [id]: answer }`.

- [ ] **Step 1: Write the failing test** — `tests/frontier/run.sh`

```bash
#!/usr/bin/env bash
# Tests for frontier.js — the HITL topological round engine (spec §2F / A5).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/confirming-discovered-roles/scripts/frontier.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# The role decision graph: roles -> credentials -> scope.
TREE='{"nodes":[{"id":"roles","prereqs":[],"default":["admin","user"]},{"id":"credentials","prereqs":["roles"],"default":"seeded"},{"id":"scope","prereqs":["credentials"],"default":"owns"}]}'

run() { node -e '
  const f=require(process.argv[1]);
  const tree=JSON.parse(process.argv[2]); const settled=JSON.parse(process.argv[3]);
  const op=process.argv[4];
  if(op==="frontier"){process.stdout.write(computeStr(f.computeFrontier(tree,settled)));}
  if(op==="default"){process.stdout.write(String(f.recommendedDefault(tree,process.argv[5])));}
  if(op==="apply"){const s=f.applyAnswers(tree,settled,JSON.parse(process.argv[5]));process.stdout.write(computeStr(f.computeFrontier(tree,s)));}
  if(op==="budget"){process.stdout.write(String(f.budgetExceeded(Number(process.argv[5]),Number(process.argv[6]))));}
  function computeStr(r){return r.frontier.join(",")+"|"+r.deferred.join(",");}
  ' "$MOD" "$1" "$2" "$3" "${4:-}" "${5:-}"; }

# (a) credentials/scope are DEFERRED until roles settle; only roles is on the frontier.
check "a: only roles on frontier initially" "$(run "$TREE" '{}' frontier)" "roles|credentials,scope"
# (b) every frontier node has a recommended default.
check "b: roles has a default" "$(run "$TREE" '{}' default roles)" "admin,user"
# (c) after settling roles, credentials surfaces (prereq met); scope still deferred.
check "c: credentials unblocks after roles" "$(run "$TREE" '{}' apply '{"roles":["admin"]}')" "credentials|scope"
# (d) editing a settled prereq unsettles its dependents (credentials returns to frontier).
check "d: editing roles re-defers downstream" "$(run "$TREE" '{"roles":["admin"],"credentials":"seeded"}' apply '{"roles":["admin","user"]}')" "credentials|scope"
# (e) budget: rounds>budget -> true (auto-settle-and-proceed trigger).
check "e: budget exceeded true"  "$(run "$TREE" '{}' budget 6 5)" "true"
check "f: budget not exceeded"   "$(run "$TREE" '{}' budget 3 5)" "false"

echo; echo "frontier tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/frontier/run.sh`
Expected: FAIL — `Cannot find module '.../frontier.js'` (module not written yet).

- [ ] **Step 3: Write minimal implementation** — `skills/confirming-discovered-roles/scripts/frontier.js`

```javascript
'use strict';
/*
 * frontier.js — HITL topological round engine (spec §2F / algorithms A5).
 * Dependency-free. Kahn-style waves: the frontier is every decision whose
 * prereqs are all settled and which is not itself settled; everything else
 * with an unmet prereq is deferred. Editing a settled node unsettles its
 * transitive dependents so the frontier recomputes. No I/O, no prompting —
 * confirming-discovered-roles drives the rounds around this pure core.
 */
function nodeMap(tree) {
  const m = {};
  (tree.nodes || []).forEach(function (n) { m[n.id] = n; });
  return m;
}
function computeFrontier(tree, settled) {
  settled = settled || {};
  const settledIds = Object.keys(settled);
  const isSettled = function (id) { return Object.prototype.hasOwnProperty.call(settled, id); };
  const frontier = [], deferred = [];
  (tree.nodes || []).forEach(function (n) {
    if (isSettled(n.id)) return;
    const ready = (n.prereqs || []).every(isSettled);
    if (ready) frontier.push(n.id); else deferred.push(n.id);
  });
  return { frontier: frontier, deferred: deferred, settledIds: settledIds };
}
function recommendedDefault(tree, id) {
  const n = nodeMap(tree)[id];
  return n && Object.prototype.hasOwnProperty.call(n, 'default') ? n.default : null;
}
// direct + transitive dependents of a node id.
function dependentsOf(tree, id) {
  const out = new Set();
  let grew = true;
  const seed = new Set([id]);
  while (grew) {
    grew = false;
    (tree.nodes || []).forEach(function (n) {
      if (out.has(n.id)) return;
      if ((n.prereqs || []).some(function (p) { return seed.has(p) || out.has(p); })) {
        out.add(n.id); grew = true;
      }
    });
  }
  return out;
}
function applyAnswers(tree, settled, answers) {
  const next = Object.assign({}, settled || {});
  Object.keys(answers || {}).forEach(function (id) {
    const edited = Object.prototype.hasOwnProperty.call(next, id) && next[id] !== answers[id];
    next[id] = answers[id];
    if (edited) {
      dependentsOf(tree, id).forEach(function (dep) { delete next[dep]; });
    }
  });
  return next;
}
function budgetExceeded(rounds, budget) { return Number(rounds) > Number(budget); }
module.exports = { computeFrontier: computeFrontier, recommendedDefault: recommendedDefault, applyAnswers: applyAnswers, budgetExceeded: budgetExceeded };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --check skills/confirming-discovered-roles/scripts/frontier.js && bash tests/frontier/run.sh`
Expected: `frontier tests: PASS=6 FAIL=0`.

- [ ] **Step 5: Add the executable-pattern pointer to `hitl-rounds.md`**

Add one line under its intro (exact text):
```markdown
> **Now executable:** this round pattern is implemented and tested as `skills/confirming-discovered-roles/scripts/frontier.js` (`computeFrontier`/`applyAnswers`/`recommendedDefault`/`budgetExceeded`); `confirming-discovered-roles` drives the rounds around it. See `tests/frontier/run.sh`.
```

- [ ] **Step 6: Commit**

```bash
git add skills/confirming-discovered-roles/scripts/frontier.js tests/frontier/run.sh skills/bootstrapping-qa-config/references/hitl-rounds.md
git commit -m "feat(roles): frontier.js round engine + tests (spec 2F) — topological HITL waves"
```

---

## Task 3: `human-action` gate — action-trace writer, session-log parse, Check 0∧1∧2 reconciliation

**Files:**
- Create: `skills/driving-browser-qa/scripts/parse-session-log.js`
- Create: `skills/checkpointing-qa-memory/scripts/check-action-trace.js`
- Modify: `skills/checkpointing-qa-memory/scripts/record-evidence.sh` (add the `action-trace` writer)
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (register `human-action` kind; delegate its value-check)
- Test: `tests/action-trace/run.sh`

**Interfaces:**
- Consumes: run-dir layout `evidence/[<persona>/]<crit>/` (from checkpoint.sh's `gate_pass`); the human-path/workaround tool sets (Global Constraints).
- Produces:
  - `record-evidence.sh <run> <crit> action-trace [--persona <id>] --steps <json> [--session-calls <json>] [--action <desc>]` → writes `action-trace.json`, prints its run-relative path (mirrors the other kinds).
  - `action-trace.json` shape: `{ "actionUnderTest": string, "steps": [{ "tool": string, "target": string, "phase": "arrange"|"act"|"assert", "payload"?: string }], "sessionCalls": [{ "class": "human-path"|"evaluate"|"route"|"other", "mutating": boolean, "code": string }] }`. **`payload`** is the evaluate/route code the agent ran (needed to classify an act-phase `browser_evaluate` read-vs-write — spec A1 Check 2). **`sessionCalls`** is the INDEPENDENT ground truth: the classified Playwright-code calls parsed from `session.md` (NOT tool names — the real `session.md` records generated Playwright JS, see `parse-session-log.js`). Omitted/`[]` only when `saveSession` is off.
  - `parse-session-log.js <session.md>` → prints a JSON array `[{ class, mutating, code }]` classified from the real `session.md` `Ran Playwright code` ` ```js ` blocks (the pinned `@playwright/mcp@0.0.79` format — verified in `playwright-core/lib/coreBundle.js`: sections `Result` / `Ran Playwright code` / `Page` / `Snapshot`, code rendered as ` ```js `). `class` ∈ human-path (`.click()/.fill()/.type()/.selectOption()/.press()/.hover()/.setInputFiles()/.dragTo()`), `evaluate` (`.evaluate(`/`.$eval(`/`.evaluateHandle(`), `route` (`.route(`/`.routeFromHAR(`), else `other`; `mutating` = the code writes app state (`.setItem(`/`.removeItem(`/`.value =`/`.dispatchEvent(`/`.click(`/`.submit(`/`.setAttribute(`/assignment into `document`/`window`) — a read-only evaluate is `mutating:false` and is IGNORED by the gate.
  - `check-action-trace.js <action-trace.json> [--allow-nonui]` → exit 0 (valid) or exit 1 with a one-line reason on stderr. This is the `human-action` value-check.
  - `checkpoint.sh ... pass --kinds ...,human-action [--persona P]` gates the pass on `check-action-trace.js`.

- [ ] **Step 1: Write the failing test** — `tests/action-trace/run.sh`

```bash
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

echo; echo "action-trace tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/action-trace/run.sh`
Expected: FAIL — `parse-session-log.js`/`check-action-trace.js` missing, `record-evidence.sh` rejects unknown kind `action-trace`.

- [ ] **Step 3a: Implement `parse-session-log.js`**

```javascript
'use strict';
/*
 * parse-session-log.js — read a Playwright MCP `--save-session` session.md and
 * emit the ordered calls as classified JSON `[{class, mutating, code}]`.
 * Dependency-free. VERIFIED format (@playwright/mcp@0.0.79,
 * playwright-core/lib/coreBundle.js): each executed step is a section titled
 * "Ran Playwright code" followed by a ```js fenced block of GENERATED PLAYWRIGHT
 * CODE (e.g. `await page.locator('#add').click();`) — NOT MCP tool names. So we
 * classify by code pattern, and (crucially) flag `mutating` ONLY when the code
 * writes app state, so read-only observation evaluate is never a workaround.
 *
 * The `classify(code)` here is the SINGLE source of truth also used by
 * check-action-trace.js for act-phase evaluate payloads (Check 2) — keep them
 * one function via the shared export.
 */
const fs = require('fs');

// Does this snippet WRITE app/DOM/storage state? (read-only reads are ignored.)
const MUTATION_RE = /\.setItem\(|\.removeItem\(|localStorage\.clear\(|sessionStorage\.(set|remove|clear)|\.value\s*=|\.checked\s*=|\.innerHTML\s*=|\.textContent\s*=|\.setAttribute\(|\.dispatchEvent\(|\.click\(\)|\.submit\(\)|\.remove\(\)|document\.\w+\s*=|window\.\w+\s*=/;

// True iff a raw JS snippet writes state. Used BOTH for full session.md code
// AND for a bare action-trace evaluate `payload` (which has no `page.evaluate(`
// wrapper) — so a payload is judged by what it does, not by its wrapper.
function mutates(src) { return MUTATION_RE.test(String(src || '')); }

// Classify one Playwright code snippet into a behavior class + mutating flag.
function classify(code) {
  const c = String(code || '');
  const isEval  = /\.(evaluate|evaluateHandle|\$eval|\$\$eval)\s*\(/.test(c);
  const isRoute = /\.route(FromHAR)?\s*\(/.test(c);
  const isHuman = /\.(click|dblclick|fill|type|press|selectOption|hover|check|uncheck|setInputFiles|dragTo|tap)\s*\(/.test(c);
  let cls = 'other';
  if (isRoute) cls = 'route';
  else if (isEval) cls = 'evaluate';
  else if (isHuman) cls = 'human-path';
  // human-path acts are inherently state-driving (that's the point) and are the
  // SANCTIONED path — mutating:true but class human-path => never a workaround.
  // evaluate/route are workarounds ONLY when they mutate; route is treated as
  // mutating (backend interception manufactures state) unless it is a passive
  // read. `other` (navigation, waits) is not mutating.
  let mutating;
  if (cls === 'human-path') mutating = true;
  else if (cls === 'route') mutating = true;
  else if (cls === 'evaluate') mutating = mutates(c);
  else mutating = false;
  return { class: cls, mutating: mutating, code: c.slice(0, 200) };
}

function parse(md) {
  const text = String(md || '');
  const calls = [];
  // Match each "Ran Playwright code" section's fenced js code block. The fence
  // marker is built from char codes so this SOURCE contains no literal triple
  // backtick (keeps the code copy-pasteable inside a markdown code block).
  const FENCE = String.fromCharCode(96, 96, 96); // three backticks
  const re = new RegExp('Ran Playwright code[\\s\\S]*?' + FENCE + '(?:js|javascript)?\\s*([\\s\\S]*?)' + FENCE, 'g');
  let m;
  while ((m = re.exec(text)) !== null) {
    const code = m[1].trim();
    if (code) calls.push(classify(code));
  }
  return calls;
}

if (require.main === module) {
  const p = process.argv[2];
  if (!p) { process.stderr.write('usage: parse-session-log.js <session.md>\n'); process.exit(2); }
  process.stdout.write(JSON.stringify(parse(fs.readFileSync(p, 'utf8'))) + '\n');
}
module.exports = { parse: parse, classify: classify, mutates: mutates };
```

- [ ] **Step 3b: Implement `check-action-trace.js` (Check 0∧1∧2)**

```javascript
'use strict';
/*
 * check-action-trace.js — the human-action evidence value-check (spec A1).
 * exit 0 = valid (act performed through the UI, no concealed workaround);
 * exit 1 = REJECT with a one-line reason on stderr. `--allow-nonui` permits a
 * logged opt-out (checkpoint forces confidence low upstream).
 *
 * Representations bridged here:
 *   - steps[]        = agent self-report, MCP-tool-level {tool,target,phase,payload?}
 *   - sessionCalls[] = INDEPENDENT ground truth, Playwright-code-level
 *                      {class,mutating,code} parsed from session.md by
 *                      parse-session-log.js (real @playwright/mcp format).
 *
 * Check 2 (act-phase payload lint): an act-phase browser_evaluate is a
 *   workaround ONLY if its payload MUTATES (read-only observe evaluate is fine);
 *   browser_run_code_unsafe / a backend browser_route on the act path are always
 *   workarounds.
 * Check 1 (act-phase tool class): an act step whose tool is not a human-path
 *   tool and is not a read-only evaluate is a workaround.
 * Check 0 (concealed-workaround reconciliation): a MUTATING evaluate/route call
 *   in session.md that has NO corresponding recorded step (of ANY phase) is a
 *   concealed workaround. session.md is phase-less and timestamp-thin, so we
 *   reconcile the WHOLE criterion window against ALL recorded steps — this still
 *   catches "took a mutating shortcut and didn't record it"; phase-mislabeling
 *   is the acknowledged residual (reviewer spot-check), per spec §2B.
 */
const fs = require('fs');
const path = require('path');
// Reuse the ONE classifier so act-payloads and session code are judged identically.
const { mutates } = require(path.join(__dirname, '..', '..', 'driving-browser-qa', 'scripts', 'parse-session-log.js'));
const HUMAN_PATH_TOOLS = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_file_upload','browser_navigate']);
function die(msg) { process.stderr.write('HUMAN-ACTION GATE: ' + msg + '\n'); process.exit(1); }

// Is this self-reported act step a workaround? human-path tools are fine; an
// evaluate is a workaround only if its bare payload MUTATES (read-only observe
// evaluate is allowed); anything else on the act path (run_code_unsafe / route /
// unknown) is a workaround. `mutates()` is the same lint used on session.md.
function actStepIsWorkaround(s) {
  if (HUMAN_PATH_TOOLS.has(s.tool)) return false;
  if (s.tool === 'browser_evaluate') return mutates(s.payload || '') === true;
  return true; // browser_run_code_unsafe, browser_route, or any non-human-path tool
}

function main() {
  const p = process.argv[2];
  const allowNonUi = process.argv.indexOf('--allow-nonui') >= 0;
  if (!p) { process.stderr.write('usage: check-action-trace.js <action-trace.json> [--allow-nonui]\n'); process.exit(2); }
  let doc;
  try { doc = JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { die('action-trace.json is missing or not valid JSON'); }
  const steps = Array.isArray(doc.steps) ? doc.steps : null;
  if (!steps) die('action-trace.json has no steps[] array');
  const actSteps = steps.filter(function (s) { return s && s.phase === 'act'; });
  if (actSteps.length === 0) die('action-trace has no act-phase step — the action-under-test was never performed');

  if (allowNonUi) process.exit(0); // logged tool-limitation opt-out (confidence low upstream)

  // Check 1/2 — act-phase steps must be human-path (or read-only evaluate).
  const badAct = actSteps.filter(actStepIsWorkaround);
  if (badAct.length) {
    die('act performed via workaround "' + (badAct[0].tool) + '"' +
        (badAct[0].payload ? ' (' + String(badAct[0].payload).slice(0, 60) + ')' : '') +
        ' — perform through the UI, or record the UI-impossibility as a fail (or log nonUiActionReason)');
  }

  // Check 0 — reconcile MUTATING session.md calls against ALL recorded steps.
  // A recorded step "covers" a session call if it is a human-path act (covers a
  // .click()/.fill() etc.) or an evaluate step whose payload also mutates
  // (covers a recorded mutating evaluate opt-out). We count coverage capacity so
  // N concealed mutating calls need N covering steps.
  const sessionCalls = Array.isArray(doc.sessionCalls) ? doc.sessionCalls : [];
  // CONTENT-MATCH disclosure (spoof-resistant). A bare COUNT of recorded mutating
  // steps was defeatable: a fabricated decoy mutating step (e.g. document.title='x',
  // never run) would "cover" an unrelated genuine concealed workaround. Instead,
  // each MUTATING session call's inner source must EQUAL a recorded mutating step's
  // payload (squashing whitespace + all brackets so wrapper parens are noise) —
  // a decoy that doesn't equal the concealed call provides no cover. A human-path
  // session mutation is the sanctioned act and is never concealable.
  const squash = (x) => String(x || '').replace(/[\s(){}\[\];]+/g, '');
  const innerCode = (code) => {
    let c = String(code || '');
    const a = c.indexOf('=>');
    if (a >= 0) c = c.slice(a + 2);                 // arrow body: after `() =>`
    else c = c.replace(/^\s*await\s+/, '').replace(/^page\.(evaluate|evaluateHandle|\$eval|\$\$eval|route|routeFromHAR)\s*/, '');
    return squash(c);
  };
  const disclosed = steps
    .filter((s) => (s.tool === 'browser_evaluate' && mutates(s.payload || '')) || s.tool === 'browser_run_code_unsafe' || s.tool === 'browser_route')
    .map((s) => squash(s.payload || ''));
  const mutatingSession = sessionCalls.filter((c) => c && c.mutating && c.class !== 'human-path');
  for (let i = 0; i < mutatingSession.length; i++) {
    const inner = innerCode(mutatingSession[i].code);
    const idx = inner ? disclosed.indexOf(inner) : -1;
    if (idx >= 0) { disclosed.splice(idx, 1); continue; }  // disclosed one-to-one
    die('session.md shows a mutating "' + mutatingSession[i].class + '" call NOT DISCLOSED by any recorded step (' +
        String(mutatingSession[i].code).slice(0, 60) + ') — concealed workaround');
  }
  process.exit(0);
}
main();
```

- [ ] **Step 3c: Add the `action-trace` writer to `record-evidence.sh`**

In the USAGE header add the line (after the `probe` usage line ~9):
```
#   record-evidence.sh <run-id> <criterion-id> action-trace [--persona <id>] --steps <json-array> [--session-calls <json-array>] [--action <desc>]
```
In `artifact_for_kind()` (~line 131) add before the `*)` default:
```bash
    action-trace) echo "action-trace.json" ;;
```
Add a `cmd_action_trace` function mirroring `cmd_probe`'s structure (arg-parse `--steps`/`--session-calls`/`--action`, require `--steps`, then write via the jq AND python3 writer paths used by the other kinds — store `steps`/`sessionCalls` as parsed JSON arrays and `actionUnderTest` as a string; default `sessionCalls` to `[]` and `actionUnderTest` to `""` when absent). Then add to the dispatch `case` (~line 415):
```bash
    action-trace) cmd_action_trace "$run_id" "$crit_id" "$PERSONA" "$@" ;;
```
Match the file's existing jq/python parity discipline exactly (both writer paths produce identical JSON — the lesson of Fix #27). The `--steps`/`--session-calls` values are JSON arrays passed through as parsed JSON (like `--read-back` when it is JSON), not re-quoted strings.

- [ ] **Step 3d: Register `human-action` in `checkpoint.sh`**

`kind_artifact()` (~line 488): add before `*)`:
```bash
    human-action) echo "action-trace.json" ;;
```
`kind_required_keys()` (~line 501): add before `*)`:
```bash
    human-action) echo "steps" ;;
```
`gate_pass()` allowed-kind case (~line 651): change to include the new kind:
```bash
      bake|computed|probe|human-action) ;;
```
`gate_value_check()` (~line 599): add a `human-action` branch that shells out to the Node checker (single source of truth, no jq/python duplication). Insert before the closing `esac`:
```bash
    human-action)
      # Delegate the act/observe + session.md reconciliation to the Node unit
      # (Check 0∧1∧2). --allow-nonui when the criterion logged a tool-limit opt-out.
      local allow=""
      if criterion_has_nonui_reason "$crit_id" "$persona"; then allow="--allow-nonui"; fi
      if ! node "$(dirname "${BASH_SOURCE[0]}")/check-action-trace.js" "$full_path" $allow; then
        return 1   # check-action-trace.js already printed the reason to stderr
      fi
      ;;
```
Because `gate_value_check` currently takes `(crit_id, kind, rel_path, full_path)`, thread the optional `persona` through from `gate_pass` (it already computes `persona`) by adding a 5th positional arg to the `gate_value_check` call site and signature. Add a small helper `criterion_has_nonui_reason <crit_id> <persona>` that greps the persisted checkpoint record for a non-empty `nonUiActionReason` on that `(criterion_id[,persona])` — return 0 if present. (If the field is not yet persisted at gate time, default to absent → strict.) Keep it jq/python dual-path like the rest of the file.

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --check skills/driving-browser-qa/scripts/parse-session-log.js && node --check skills/checkpointing-qa-memory/scripts/check-action-trace.js && bash -n skills/checkpointing-qa-memory/scripts/checkpoint.sh && bash -n skills/checkpointing-qa-memory/scripts/record-evidence.sh && bash tests/action-trace/run.sh && bash tests/checkpoint/run.sh`
Expected: `action-trace tests: PASS=... FAIL=0` AND `tests/checkpoint/run.sh` still `FAIL=0` (no regression — the new kind is additive; bake/computed/probe untouched).

- [ ] **Step 5: Commit**

```bash
git add skills/driving-browser-qa/scripts/parse-session-log.js skills/checkpointing-qa-memory/scripts/check-action-trace.js skills/checkpointing-qa-memory/scripts/record-evidence.sh skills/checkpointing-qa-memory/scripts/checkpoint.sh tests/action-trace/run.sh
git commit -m "feat(gate): human-action kind — action-trace + session.md reconciliation (Check 0/1/2)"
```

---

## Task 4: `generating-qa-checklist` derives the `human-action` kind

**Files:**
- Modify: `skills/generating-qa-checklist/SKILL.md`

**Interfaces:**
- Consumes: the checklist's existing per-criterion `Kinds` derivation (bake/computed/probe) and `Tags`.
- Produces: `human-action` appended to `Kinds` for any criterion whose action mutates state or drives a control; a per-criterion `actionUnderTest` label the trace records.

- [ ] **Step 1: Add the derivation rule** to the Kinds section of the SKILL (exact text):

```markdown
- **`human-action`** — add this kind to any criterion whose Act phase **mutates
  state or drives a control** (create/edit/delete/finalize/submit, toggling,
  any click/type that changes the app). Record the criterion's `actionUnderTest`
  (a one-line description of the single action being tested). A criterion that is
  purely a read/observe (a computed-value check, a contrast/overflow detection,
  a read-only bake) does NOT get `human-action`. The gate then requires the act
  to be performed through the UI and reconciles it against `session.md`
  (checkpointing-qa-memory / ADR-0015). A genuine tool limitation is recorded per
  criterion as `nonUiActionReason` (confidence drops to low).
```

- [ ] **Step 2: Add a coverage-catalog row** (mirror the existing catalog table format) so `human-action` shows up in generated checklists:

```markdown
| action-through-UI (any state-mutating action) | the action-under-test is performed via a real affordance; a UI-impossible action is fail@FE, not a workaround | interaction | `business-rule` | `human-action` |
```

- [ ] **Step 3: Add a mini-eval** (the skill requires ≥3; add one drawn from the discipline):

```markdown
- Eval: a criterion "add a founder" whose only Act step is `browser_click` on the
  Add button → Kinds includes `bake,human-action`; a criterion "founders list
  shows correct totals" (read-only) → Kinds is `computed` only, NO `human-action`.
```

- [ ] **Step 4: Validate + commit**

Run: `awk 'END{print NR}' skills/generating-qa-checklist/SKILL.md` (confirm < 500 lines) and `grep -c 'human-action' skills/generating-qa-checklist/SKILL.md` (≥3).
Expected: line count < 500; match count ≥ 3.

```bash
git add skills/generating-qa-checklist/SKILL.md
git commit -m "feat(checklist): derive human-action kind for state-mutating criteria + coverage row"
```

---

## Task 5: Interaction rules + driver launch + workaround-script reconciliations (§2A/2C/§9)

**Files:**
- Create: `skills/driving-browser-qa/references/interaction-discipline.md`
- Modify: `skills/driving-browser-qa/SKILL.md`
- Modify: `skills/driving-browser-qa/scripts/react-set-input.js`, `skills/driving-browser-qa/scripts/click-by-text.js`

**Interfaces:**
- Consumes: the tool matrix + workaround/human-path sets (Global Constraints); `check-action-trace.js` tool sets must stay in sync with this doc.
- Produces: the human-readable discipline the agent follows; read-only-demoted helpers.

- [ ] **Step 1: Write `interaction-discipline.md`** — the act/observe split table (copy the design §1 table verbatim), the UI-impossible→`fail@FE` rule with the A2 decision procedure, the 2C reconciliations, and the §9 driver-optimization rules (locator order `data-testid → ARIA role → label/text → CSS`; `browser_route` backend-interception is a forbidden workaround; origin lists are not a write gate; web-first waiting). Keep < 500 lines, reference one level deep.

- [ ] **Step 2: In `driving-browser-qa/SKILL.md`** add (a) a reference to `references/interaction-discipline.md`; (b) the driver launch + **per-criterion delta-slice** rule: *"Launch the managed Playwright MCP driver with `--save-session`. It writes generated Playwright code to a SINGLE per-run `session.md` in the MCP output dir (default `./.playwright-mcp/session.md`) — every criterion's calls are appended to the same file. So each criterion must be sliced out: BEFORE a `human-action` criterion's act phase, snapshot the baseline `N = parse-session-log.js(session.md).length`; AFTER the act, this criterion's `sessionCalls = parse-session-log.js(session.md).slice(N)` — the delta. Under ADR-0003 sequential execution exactly one criterion acts at a time, so the delta is exactly this criterion's calls. Pass that slice (plus the phase-tagged `steps`, including each evaluate step's `payload`) to `record-evidence.sh action-trace`, and copy `session.md` into the run dir for audit. For a tagged-parallel fan-out criterion (the rare non-sequential case), launch that criterion with its OWN `--output-dir` so its `session.md` is naturally scoped instead of delta-sliced. NOTE: `session.md` records Playwright CODE, not MCP tool names — the classifier bridges the two representations."*; (c) the act/observe tool rights in one paragraph (read-only `browser_evaluate` is OBSERVE and always allowed; a mutating evaluate on the act path is a workaround).

- [ ] **Step 3: Demote `react-set-input.js` to read-only** — change its exported behavior so it READS a field's current value/validity and returns it, and REMOVE any code path that sets `.value` or dispatches input/change events. Add a header comment: *"read-only (ADR-0015): value entry on the act path uses browser_type/browser_fill_form; this helper only reads a field back for assertion."* Verify with `node --check`.

- [ ] **Step 4: Demote `click-by-text.js` to resolve-only** — it returns the matched element's selector/ref (and its existing `{ambiguous, count, candidates}` shape), and must NOT call `.click()` in-evaluate. Add a header comment: *"resolve-only (ADR-0015): returns a selector to click via browser_click; never clicks in-evaluate."* Verify with `node --check`.

- [ ] **Step 5: Commit**

```bash
git add skills/driving-browser-qa/references/interaction-discipline.md skills/driving-browser-qa/SKILL.md skills/driving-browser-qa/scripts/react-set-input.js skills/driving-browser-qa/scripts/click-by-text.js
git commit -m "feat(driver): interaction-discipline reference + --save-session launch + read-only helper reconciliations"
```

---

## Task 6: Config — `humanInteraction` + isolation keys (§2E/§9.1/§9.2)

**Files:**
- Modify: `.qa/config.json.example`

**Interfaces:**
- Consumes: nothing.
- Produces: the config keys the gate (Task 3), driver (Task 5), and orchestrator (Task 7) read.

- [ ] **Step 1: Add the config block** after the `passGate` key (keep the `_doc`-style inline documentation the file uses):

```json
  "humanInteraction": { "enforce": true, "saveSession": true, "maxOptOutRate": 0.2 },
  "isolation": { "maxOpenContexts": 1, "mechanism": "isolated" },
```
And extend the nearest `_doc` string to explain: `humanInteraction.enforce` (gate the act via ADR-0015; audit-only fallback, never silently off), `saveSession` (launch Playwright MCP with `--save-session` for the independent `session.md`; false → trace-only with a printed self-report-hole warning), `maxOptOutRate` (flag a run whose `nonUiActionReason` rate exceeds it — opt-out-abuse guard); `isolation.maxOpenContexts` (cap concurrent browser contexts; default = effective concurrency, ≈1 under ADR-0003), `mechanism` (`isolated` in-memory profile vs `user-data-dir`; never `shared-browser-context` for fan-out). Note that `allowApiWrites`+disposable-marker remain the ONLY write gate — origin lists are not a write boundary (§9.2).

- [ ] **Step 2: Validate + commit**

Run: `python3 -c "import json;json.load(open('.qa/config.json.example'))" && echo OK`
Expected: `OK`.

```bash
git add .qa/config.json.example
git commit -m "feat(config): humanInteraction (enforce/saveSession/maxOptOutRate) + isolation (maxOpenContexts/mechanism)"
```

---

## Task 7: Orchestrator — per-run role/scenario selection + `--save-session` launch (§2D)

**Files:**
- Modify: `agents/qa-e2e-pilot.md`

**Interfaces:**
- Consumes: `frontier.js` (Task 2), `.qa/config.json` `personas[]`/`humanInteraction`/`isolation` (Task 6), the `human-action` gate (Task 3).
- Produces: the orchestrator's pre-run selection step + discipline wiring.

- [ ] **Step 1: Add a pre-run selection step** to the orchestrator's phase list (before Verify): *"invoke the round engine (`frontier.js`) to select which confirmed personas run this pass, confirm each role's scenario (its role-sensitive + cross-role criteria), and choose lens + viewport. Defaults: all discovered personas / `skeptical-auditor` / 1440×900. Each persona runs its scenario under the interaction discipline, persona-keyed (existing)."*

- [ ] **Step 2: Add the discipline wiring** to the Pre-flight and Verify phases: launch the managed driver with `--save-session` when `humanInteraction.saveSession` (default true); for each `human-action` criterion, record `action-trace` (steps with phase tags + `sessionCalls` from `parse-session-log.js`) before checkpointing the pass; the gate rejects a concealed/act-phase workaround. Respect `isolation.maxOpenContexts` (≈1 open context under sequential default; lazy-create per session, recycle on handoff). Note the UI-impossible→`fail@FE` rule and the `nonUiActionReason` opt-out (confidence low; run flagged past `maxOptOutRate`).

- [ ] **Step 3: Validate + commit**

Run: `grep -c 'save-session\|human-action\|frontier' agents/qa-e2e-pilot.md`
Expected: ≥ 3.

```bash
git add agents/qa-e2e-pilot.md
git commit -m "feat(orchestrator): per-run role/scenario selection (frontier) + --save-session + human-action wiring"
```

---

## Task 8: Fixture cases + re-measure (§5 acceptance)

**Files:**
- Modify: `tools/accuracy-harness/fixture/index.html` (+ a tiny script hook)
- Modify: `tools/accuracy-harness/seeds.json`

**Interfaces:**
- Consumes: the harness scorer (`score.js`, unchanged) + the `human-action` gate.
- Produces: fixture seeds that prove the discipline: (H1) a spec'd action with NO working affordance → must be `fail@FE`, not evaluate-around; (H2) a control that correctly rejects invalid input → `pass` through the UI (negative control — must NOT be flagged).

- [ ] **Step 1: Add H1 — a missing/broken affordance.** Add a section with a labeled action the spec requires (e.g. an "Archive founder" button) whose click handler is absent/no-ops (throws no error, does nothing). Seed it in `seeds.json` as `{ "id":"H1", "axis":"broken-journey", "kind":"ui-impossible", "polarity":"positive", "title":"Archive action has no working affordance — spec requires it; must be fail@FE, never evaluate-around", "suspectedLayer":"FE", "match":[...] }`.

- [ ] **Step 2: Add H2 — correct-rejection negative control.** A field that correctly rejects an out-of-spec value through the UI (shows an inline error, persists nothing). Seed `{ "id":"H2", "axis":"broken-journey", "polarity":"negative", "title":"Control correctly rejects invalid input per the oracle — a UI-reached pass, MUST NOT be flagged", "match":[...] }`.

- [ ] **Step 3: Validate the fixture + seeds** (mirrors the repo's smoke pattern):

Run: `python3 -c "import json;json.load(open('tools/accuracy-harness/seeds.json'))" && node --check <(printf '') 2>/dev/null; echo seeds-ok`
Then serve and eyeball H1/H2 render:
Run: `python3 -m http.server 8099 --directory tools/accuracy-harness/fixture >/dev/null 2>&1 &` then `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8099/index.html`
Expected: `200`; `seeds-ok`.

- [ ] **Step 4: Re-measure note (deferred to a real gated run, not a code step).** Record in the plan's execution log that the post-implementation acceptance is a real `qa-e2e-pilot` gated run over the fixture confirming: H1 → `fail@FE` (no evaluate-around), H2 → not flagged, the concealed-workaround case → gate REJECT, and **no silent recall regression** from the current functional 100% / overall 92% (any drop must be an explicit "now correctly unreachable via UI" recategorization, logged). Do not fabricate these numbers — they come from the run.

- [ ] **Step 5: Commit**

```bash
git add tools/accuracy-harness/fixture/index.html tools/accuracy-harness/seeds.json
git commit -m "test(fixture): H1 UI-impossible (fail@FE) + H2 correct-rejection control for the discipline"
```

---

## Task 9: Review pass over the round-engine + `confirming-discovered-roles` (§2F)

**Files:**
- Modify (as findings require): `skills/confirming-discovered-roles/SKILL.md`, `skills/bootstrapping-qa-config/references/hitl-rounds.md`

**Interfaces:**
- Consumes: `frontier.js` (Task 2) and the shipped role skills (which landed review-free in the earlier loop).
- Produces: a reviewed, consistent round-engine + role-confirmation flow.

- [ ] **Step 1: Wire `confirming-discovered-roles` to drive `frontier.js`.** Update the SKILL to describe each round as: `computeFrontier` → render frontier items numbered, each with `recommendedDefault` → `applyAnswers` → recompute, with `budgetExceeded` triggering auto-settle + logged assumptions (never block). Cross-reference `write-persona-config.sh` (which now validates the `roleScope` enum + unique persona ids — the authz-matrix producer these rounds feed).

- [ ] **Step 2: Read `confirming-discovered-roles/SKILL.md` and `hitl-rounds.md` end-to-end** for correctness now that the engine is real; fix any contradiction between the prose and `frontier.js`'s actual behavior (e.g. defaults, unsettle-on-edit).

- [ ] **Step 3: Validate + commit**

Run: `bash tests/frontier/run.sh` (still green) and confirm `grep -c 'frontier.js' skills/confirming-discovered-roles/SKILL.md` ≥ 1.
Expected: `PASS=6 FAIL=0`; match ≥ 1.

```bash
git add skills/confirming-discovered-roles/SKILL.md skills/bootstrapping-qa-config/references/hitl-rounds.md
git commit -m "docs(roles): drive frontier.js from confirming-discovered-roles + reviewed round prose"
```

---

## Final acceptance (after all tasks)

Run the full repo validation sweep, then a real gated fixture run:
```bash
for f in $(find . -name '*.json' -not -path './.git/*' -not -path './.qa/runs/*' -not -path './tools/accuracy-harness/findings/*'); do python3 -c "import json;json.load(open('$f'))" || echo "BAD: $f"; done
for f in $(find . -name '*.sh' -not -path './.git/*'); do bash -n "$f" || echo "BAD: $f"; done
for f in $(find . -name '*.js' -not -path './.git/*' -not -path './node_modules/*'); do node --check "$f" || echo "BAD: $f"; done
bash tests/checkpoint/run.sh && bash tests/action-trace/run.sh && bash tests/frontier/run.sh && bash tests/write-persona-config/run.sh
```
Then dispatch the `qa-e2e-pilot` agent over the served fixture and confirm the §5 acceptance list (H1 fail@FE, H2 not flagged, concealed-workaround REJECT, no silent recall regression). These numbers come from the run — never hand-authored.
