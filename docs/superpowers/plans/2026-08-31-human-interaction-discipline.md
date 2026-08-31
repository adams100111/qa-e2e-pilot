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
  - `action-trace.json` shape: `{ "actionUnderTest": string, "steps": [{ "tool": string, "target": string, "phase": "arrange"|"act"|"assert" }], "sessionCalls": [{ "tool": string, "target": string }] }` (`sessionCalls` = independent ground truth from `session.md`; omitted/`[]` only when `saveSession` is off).
  - `parse-session-log.js <session.md>` → prints a JSON array `[{ "tool": string, "target": string }]` of the tool calls the server logged.
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

# --- parse-session-log.js: extract tool calls from a Playwright session.md ----
cat > "$WORK/session.md" <<'MD'
### Tool call: browser_type
```js
await page.locator('#name').fill('Alice');
```
### Tool call: browser_click
```js
await page.locator('#add').click();
```
### Tool call: browser_evaluate
```js
await page.evaluate(() => localStorage.setItem('captable:founders','[]'));
```
MD
PARSED="$(node "$PARSE" "$WORK/session.md")"
check "parse: found 3 calls" "$(echo "$PARSED" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).length)))')" "3"

# --- check-action-trace.js: clean UI-only act -> exit 0 -----------------------
cat > "$WORK/clean.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_type","target":"#name","phase":"arrange"},{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"tool":"browser_type","target":"#name"},{"tool":"browser_click","target":"#add"}]}
J
node "$CHECK" "$WORK/clean.json"; check "check: clean UI-only act passes" "$?" "0"

# --- Check 1/2: an act-phase workaround tool -> exit 1 ------------------------
cat > "$WORK/evalact.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_evaluate","target":"setItem","phase":"act"}],"sessionCalls":[{"tool":"browser_evaluate","target":"setItem"}]}
J
node "$CHECK" "$WORK/evalact.json" 2>/dev/null; check "check: evaluate-set on act rejected" "$?" "1"

# --- Check 0: concealed workaround (in session.md, omitted from act steps) ----
cat > "$WORK/concealed.json" <<'J'
{"actionUnderTest":"add founder","steps":[{"tool":"browser_click","target":"#add","phase":"act"}],"sessionCalls":[{"tool":"browser_click","target":"#add"},{"tool":"browser_evaluate","target":"localStorage.setItem"}]}
J
node "$CHECK" "$WORK/concealed.json" 2>/dev/null; check "check: concealed session-log workaround rejected" "$?" "1"

# --- --allow-nonui lets a logged opt-out through (confidence low upstream) ----
node "$CHECK" "$WORK/evalact.json" --allow-nonui; check "check: --allow-nonui permits workaround" "$?" "0"

# --- record-evidence writes action-trace.json + checkpoint gates on it --------
RID="ht-1"
( cd "$WORK" && bash "$REC" "$RID" C1 action-trace --steps '[{"tool":"browser_click","target":"#add","phase":"act"}]' --session-calls '[{"tool":"browser_click","target":"#add"}]' --action "add founder" >/dev/null )
check "record: action-trace.json written" "$([[ -f "$WORK/.qa/runs/$RID/evidence/C1/action-trace.json" ]] && echo yes)" "yes"
( cd "$WORK" && bash "$CKPT" "$RID" C1 pass --kinds human-action --evidence-refs evidence/C1/action-trace.json >/dev/null 2>&1 ); check "checkpoint: clean human-action pass accepted" "$?" "0"

# concealed workaround at the gate -> pass REJECTED (nonzero)
RID2="ht-2"
( cd "$WORK" && bash "$REC" "$RID2" C2 action-trace --steps '[{"tool":"browser_click","target":"#add","phase":"act"}]' --session-calls '[{"tool":"browser_click","target":"#add"},{"tool":"browser_evaluate","target":"localStorage.setItem"}]' --action "add founder" >/dev/null )
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
 * emit the ordered tool calls as JSON `[{tool, target}]`. Dependency-free.
 * session.md marks each executed call with a "### Tool call: <name>" heading
 * followed by a fenced code block; `target` is a best-effort locator/arg pulled
 * from the first code line (informational — the gate matches on `tool`).
 */
const fs = require('fs');
function parse(md) {
  const lines = md.split(/\r?\n/);
  const calls = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^#+\s*Tool call:\s*([A-Za-z0-9_]+)/);
    if (!m) continue;
    let target = '';
    for (let j = i + 1; j < Math.min(i + 6, lines.length); j++) {
      const t = lines[j].trim();
      if (t && !t.startsWith('```')) { target = t.slice(0, 120); break; }
    }
    calls.push({ tool: m[1], target: target });
  }
  return calls;
}
if (require.main === module) {
  const p = process.argv[2];
  if (!p) { process.stderr.write('usage: parse-session-log.js <session.md>\n'); process.exit(2); }
  process.stdout.write(JSON.stringify(parse(fs.readFileSync(p, 'utf8'))) + '\n');
}
module.exports = { parse: parse };
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
 * Check 1/2: no act-phase step uses a workaround tool (evaluate-set / clicks-in-
 *   evaluate / run_code_unsafe / route-backend / direct write).
 * Check 0:  no MUTATING call in the independent sessionCalls (from session.md)
 *   is ABSENT from the self-reported act steps (concealed workaround).
 */
const fs = require('fs');
const HUMAN_PATH = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_file_upload','browser_navigate']);
const WORKAROUND = new Set(['browser_evaluate','browser_run_code_unsafe','browser_route']);
function isWorkaroundTool(t) { return WORKAROUND.has(t); }
function die(msg) { process.stderr.write('HUMAN-ACTION GATE: ' + msg + '\n'); process.exit(1); }

function main() {
  const path = process.argv[2];
  const allowNonUi = process.argv.indexOf('--allow-nonui') >= 0;
  if (!path) { process.stderr.write('usage: check-action-trace.js <action-trace.json> [--allow-nonui]\n'); process.exit(2); }
  let doc;
  try { doc = JSON.parse(fs.readFileSync(path, 'utf8')); }
  catch (e) { die('action-trace.json is missing or not valid JSON'); }
  const steps = Array.isArray(doc.steps) ? doc.steps : null;
  if (!steps) die('action-trace.json has no steps[] array');
  const actSteps = steps.filter(function (s) { return s && s.phase === 'act'; });
  if (actSteps.length === 0) die('action-trace has no act-phase step — the action-under-test was never performed');

  // Check 1/2 — act-phase tool-class + payload lint.
  const badAct = actSteps.filter(function (s) { return isWorkaroundTool(s.tool) || !HUMAN_PATH.has(s.tool); });
  if (badAct.length && !allowNonUi) {
    die('act performed via workaround "' + badAct[0].tool + '" — perform through the UI or record the UI-impossibility as a fail (or log nonUiActionReason)');
  }

  // Check 0 — independent session-log reconciliation (concealed workaround).
  const sessionCalls = Array.isArray(doc.sessionCalls) ? doc.sessionCalls : [];
  const actToolCounts = {};
  actSteps.forEach(function (s) { actToolCounts[s.tool] = (actToolCounts[s.tool] || 0) + 1; });
  for (let i = 0; i < sessionCalls.length; i++) {
    const c = sessionCalls[i];
    if (!c || !isWorkaroundTool(c.tool)) continue;      // only mutating/workaround calls matter
    if (allowNonUi) continue;                            // logged opt-out permits it
    if (!(actToolCounts[c.tool] > 0)) {
      die('session.md shows a "' + c.tool + '" call not present in the self-reported act steps — concealed workaround');
    }
    actToolCounts[c.tool] -= 1;                          // consume one, so N logged require N recorded
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

- [ ] **Step 2: In `driving-browser-qa/SKILL.md`** add (a) a reference to `references/interaction-discipline.md`; (b) the driver launch rule: *"Launch the managed Playwright MCP driver with `--save-session`; after each `human-action` criterion's act phase, copy the server's `session.md` for that window and run `scripts/parse-session-log.js` to produce the `sessionCalls` passed to `record-evidence.sh action-trace`."*; (c) the act/observe tool rights in one paragraph.

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
