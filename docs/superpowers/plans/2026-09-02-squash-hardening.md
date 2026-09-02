# squash() Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close gap #8 in the human-action gate — make the Check-0 content-match reconciliation collision-resistant so a disclosed decoy mutation can no longer squash-alias a *structurally different* concealed mutating call.

**Architecture:** A pure edit to one existing, dependency-free bundled script — `check-action-trace.js` — replacing the bracket-collapsing `squash()` with a **structure-preserving** normalizer (drop only whitespace + statement separators, canonicalize quote style, KEEP structural brackets), and fixing `innerCode()` so the arrow branch strips **exactly one** wrapper close-paren from the arrow body — so a bare disclosed payload still equals its `await page.evaluate(() => …)` session twin **without** corrupting a `)` that lives inside a string literal (e.g. `…"a)")`). Verified by extending the existing bash runner `tests/action-trace/run.sh`. No new files, no new dependencies.

**Tech Stack:** Node.js (dependency-free, browser-agnostic JS), bash test runner, `node` for assertions.

## Global Constraints

- **Verdict/vocabulary unchanged.** Verdicts stay exactly `pass | fail | blocked | deferred | error`; confidence `high | low`; no sixth verdict. (CLAUDE.md invariant.)
- **Bundled scripts stay dependency-free.** `check-action-trace.js` uses only Node built-ins; no npm packages. (CLAUDE.md.)
- **`mutates`/`classify` remain the single source of truth.** `check-action-trace.js` imports `mutates` from `parse-session-log.js` (`check-action-trace.js:30`). This plan does **not** touch the classifier — `squash()`/`innerCode()` are the gate's local content-comparison helpers, not the mutation lint. Do not fork or reimplement `mutates`. (Source comment `parse-session-log.js:14`.)
- **Tests are bash runners at `tests/<name>/run.sh`.** Extend `tests/action-trace/run.sh`; assertions use its `check "name" "$got" "$want"` helper. (Repo convention.)
- **Validate before every commit:**
  1. `node --check skills/checkpointing-qa-memory/scripts/check-action-trace.js` (exit 0);
  2. the full `bash tests/action-trace/run.sh` (prints `FAIL=0`, exits 0);
  3. **regenerate the dist/ adapters** so the copied-verbatim core script is in sync — `for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done`;
  4. `bash tests/portability/run.sh && bash scripts/validate-adapters.sh` (portability suite + the byte-oracle both exit 0). (CLAUDE.md "Validate before committing".)
- **Commit messages contain no Claude/Anthropic attribution and no `Co-Authored-By` trailer.** (User global rule.)
- **`check-action-trace.js` is a core script copied verbatim into `dist/<h>/`.** Per WS-1 (spec §4), `skills/**/scripts/*` are the source of truth; because this plan edits one, the `dist/` adapters must be regenerated (step 3 above) and the byte-oracle (`validate-adapters.sh`) must pass here — regenerate the `dist/` copies and run `validate-adapters.sh` + `tests/portability/run.sh` as a **CI-parity gate before committing**. `dist/` is **git-ignored and is never committed** (only the edited core file + tests are); the gate proves the copy-through still assembles cleanly.

---

### Task 1: Structure-preserving `squash()` + single wrapper-paren strip (gap #8)

The Check-0 reconciliation (`check-action-trace.js:87–97`) disclosure-matches each MUTATING `session.md` call's inner source against the squashed payload of a recorded mutating step. The current `squash()` at line 79 is:

```javascript
const squash = (x) => String(x || '').replace(/[\s(){}\[\];]+/g, '');
```

It deletes **every** whitespace char **and every** `(` `)` `{` `}` `[` `]` `;`. That paren/bracket deletion is what lets a disclosed decoy alias a different concealed call (gap #8): `localStorage.setItem("k","x")` and `localStorage.setItem("k","[x]")` both collapse to `localStorage.setItem"k","x"` — so disclosing the harmless `"x"` write falsely "covers" a concealed `"[x]"` write. (Empirically confirmed: under the old `squash` these two are byte-equal.)

But the bracket deletion was **also intentional**: it normalized the wrapper's dangling paren so a bare disclosed payload `localStorage.setItem("seed","1")` matches its session twin `await page.evaluate(() => localStorage.setItem("seed","1"))` — whose arrow-body slice keeps the outer `evaluate(`'s unbalanced trailing `)`. So we cannot simply "keep brackets" without first handling that dangling paren, or the `disclosed` test regresses.

**Fix (two coordinated edits — must land together):**
1. Make `squash()` **structure-preserving**: strip only whitespace + `;`, and canonicalize quote characters (`'` `"` `` ` `` → one sentinel `"`) while **keeping** structural brackets — so structurally-different snippets stay distinct, and quote-style-only differences still match (spec §5A: "normalize whitespace + string literals only; stop collapsing structural brackets" — here "normalize string literals" = **quote-style canonicalization**; `;` is retained from the old squash as a statement-separator ≈ whitespace).
2. In `innerCode()`, the **arrow branch** strips **exactly one** trailing wrapper `)` (`c = c.replace(/\)\s*$/, '')`) after slicing the arrow body — **not** a greedy count-balance. The arrow body `() => <body>` is self-balanced, so the slice ` <body>)` carries exactly one extra `)` from the enclosing `evaluate(`. Dropping precisely one leaves `<body>` intact even when `<body>` contains a `)` inside a string literal (`…"a)")`), which a greedy "strip while closes > opens" would corrupt (it would eat the literal's `)` too, false-rejecting an honest write).

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/check-action-trace.js:79-86` (the `squash` const and the `innerCode` const inside `main()`)
- Test: `tests/action-trace/run.sh` (add a `#8` section after line 118, i.e. immediately after the existing `disclosed` check and before the `--allow-nonui` check at line 120)

**Interfaces:**
- Consumes: `mutates` (imported at `check-action-trace.js:30`, unchanged).
- Produces: `squash(x: string) → string` (structure-preserving; same call sites at `:87-89` and `:92-93`, unchanged signature) and `innerCode(code: string) → string` (unchanged signature, now strips exactly one wrapper `)` in the arrow branch before squashing). No new helper is exported; no exported API changes — `check-action-trace.js` exports nothing, these are internal helpers of `main()`.
- **Normalization-asymmetry invariant (do not break):** the disclosed side (`disclosed = steps…map(s => squash(s.payload))`, `:87-89`) is squashed **raw**, while the session side runs through `innerCode` (wrapper-paren strip). This is correct **only because disclosed payloads are bare MCP `browser_evaluate` expressions — never wrapper-wrapped** (`page.evaluate(() => …)` / arrow forms live only in `session.md`, the independent record). Both sides therefore reduce to the same bare, quote-canonicalized, bracket-preserving form. A future change that lets a recorded payload carry a wrapper/arrow prefix would break this symmetry (fails *closed* — a miss toward rejection — but silently); if that ever happens, run the disclosed side through `innerCode` too.

- [ ] **Step 1: Write the failing tests**

Append to `tests/action-trace/run.sh` immediately after line 118 (the `check: disclosed arrange-mutation with matching content is allowed` line) and before line 120 (`# --- --allow-nonui …`):

```bash
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
```

- [ ] **Step 2: Run the tests to verify the new red tests fail (controls stay green)**

Run: `bash tests/action-trace/run.sh`

Expected against the **current** code (verified by direct Node evaluation of the old `squash`/`innerCode`). Two RED tests must fail; two GREEN controls must already pass:
- **RED — (a)** `check: bracket-differing decoy no longer squash-aliases a concealed call (#8)` → **FAIL** (`got '0' want '1'`): the old bracket-collapsing squash makes `"x"` and `"[x]"` byte-equal, so the concealed call is falsely covered and the gate exits 0.
- **RED — (c)** `check: disclosed single-quoted payload matches double-quoted session twin (#8 quote canon)` → **FAIL** (`got '1' want '0'`): the old squash keeps `'` vs `"` distinct, so the honest single-quoted disclosure does not match its double-quoted twin and the gate rejects it.
- **GREEN control — (b)** `check: genuinely disclosed bracket-containing mutation still matches its twin (#8 no over-tighten)` → already **PASS** under old code (it passes by accidental collapse; it is a regression guard that must stay green after the fix).
- **GREEN control — (d)** `check: disclosed payload with ')' inside a string literal still matches its twin (#8 no corruption)` → already **PASS** under old code (the old squash strips *all* parens symmetrically on both sides, so the literal `)` disappears identically and they match). It stays green under the fix and would go **RED only if** the fix used a greedy paren-balancer — so it is the guard that pins the "exactly one wrapper paren" choice.
- Net: the runner's final line reports `FAIL` non-zero (from the two RED tests).

- [ ] **Step 3: Replace `squash` + `innerCode` with the hardened versions**

In `skills/checkpointing-qa-memory/scripts/check-action-trace.js`, replace the whole block at lines 79–86:

```javascript
  const squash = (x) => String(x || '').replace(/[\s(){}\[\];]+/g, '');
  const innerCode = (code) => {
    let c = String(code || '');
    const a = c.indexOf('=>');
    if (a >= 0) c = c.slice(a + 2);                 // arrow body: after `() =>`
    else c = c.replace(/^\s*await\s+/, '').replace(/^page\.(evaluate|evaluateHandle|\$eval|\$\$eval|route|routeFromHAR)\s*/, '');
    return squash(c);
  };
```

with (structure-preserving squash + single wrapper-paren strip in the arrow branch):

```javascript
  // #8 squash hardening — STRUCTURE-PRESERVING normalization. The old form
  // `.replace(/[\s(){}\[\];]+/g,'')` deleted every bracket/brace/paren, so two
  // structurally-different snippets (store "x" vs store "[x]") collapsed to the
  // SAME string and a disclosed decoy could alias an UNRELATED concealed call.
  // Instead: drop only whitespace + statement separators and canonicalize quote
  // style (', ", ` -> "), KEEPING structural brackets so distinct structures stay
  // distinct while quote-style-only and whitespace-only differences still match.
  const squash = (x) => String(x || '').replace(/[\s;]+/g, '').replace(/['"`]/g, '"');
  const innerCode = (code) => {
    let c = String(code || '');
    const a = c.indexOf('=>');
    if (a >= 0) {
      // Arrow body: everything after `() =>`. The body is self-balanced, so the
      // slice carries EXACTLY ONE extra trailing ')' from the enclosing
      // `evaluate(`/`route(` wrapper. Drop precisely that one — NOT a greedy
      // "strip while unbalanced" — so a ')' inside a string literal (e.g.
      // setItem("k","a)") ) is preserved and an honest disclosure still matches
      // instead of being false-rejected.
      c = c.slice(a + 2).replace(/\)\s*$/, '');
    } else {
      c = c.replace(/^\s*await\s+/, '').replace(/^page\.(evaluate|evaluateHandle|\$eval|\$\$eval|route|routeFromHAR)\s*/, '');
    }
    return squash(c);
  };
```

- [ ] **Step 4: Run `node --check` then the full suite to verify pass + no regressions**

Run: `node --check skills/checkpointing-qa-memory/scripts/check-action-trace.js && bash tests/action-trace/run.sh`

Expected: `node --check` prints nothing (exit 0); the runner prints `action-trace tests: PASS=<N> FAIL=0` and exits 0. Specifically:
- The four new `#8` checks now pass (alias rejected → exit 1; brackets-ok allowed → exit 0; quote-ok allowed → exit 0; litparen-ok allowed → exit 0).
- **Every pre-existing Check-0 case stays green** (verified by direct Node evaluation of the new helpers):
  - `check: disclosed arrange-mutation with matching content is allowed` (line 118) → still exit 0. The arrow branch now removes exactly one wrapper `)` before squash, so the slice ` localStorage.setItem("seed","1"))` → ` localStorage.setItem("seed","1")` and the bare payload `localStorage.setItem("seed","1")` still equals its `await page.evaluate(() => …)` twin.
  - `check: recorded arrange-mutation covers its twin (not concealed)` (line 92) → still exit 0. Session code `localStorage.setItem('seed','1')` has no `=>` → else branch, no wrapper paren, single quotes canonicalized on both sides.
  - `check: decoy mutating step does not cover unrelated concealed call` (line 106) → still exit 1. `document.title="x"` and the concealed `setItem("captable:founders","[]")` are strictly more distinct now (brackets kept) — rejection preserved.
  - `check: prefix-only decoy does not cover the full concealed call` (line 112) → still exit 1. Disclosed `localStorage.setItem(` (squashed raw, paren kept) never equals the full call.
  - `check: concealed mutating workaround rejected (Check 0)` (line 98) → still exit 1. No disclosed step at all.
  - Checks 1/2/3 cases (`clean`, `observe`, `evalact`, `readact`, `fetchact`, `dispatchact`, `getfetch`, `decoy2`, `nofp`) do not reach the Check-0 disclosed-match loop with a MUTATING non-human-path session call that needs `innerCode` matching (act-phase mutating evaluates are rejected earlier at Checks 1/2; read-only session evaluates are filtered out of `mutatingSession`) and are unaffected.

If any pre-existing case flips (especially `disclosed` or `recorded`), STOP: the single wrapper-paren strip in the arrow branch is the load-bearing part — re-check the arrow branch applies `c.replace(/\)\s*$/, '')` exactly once and that `squash` no longer strips parens/brackets. Do not weaken the new tests to force green.

- [ ] **Step 5: Regenerate dist/ (CI-parity gate), then commit core + test (dist is git-ignored, not committed)**

```bash
# regenerate the four adapters so the copied-verbatim core script is in sync
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
# gate: portability suite + byte-oracle must both pass before committing
bash tests/portability/run.sh && bash scripts/validate-adapters.sh
git add skills/checkpointing-qa-memory/scripts/check-action-trace.js tests/action-trace/run.sh
git commit -m "fix(gate): structure-preserving squash so a decoy can't alias a different concealed call (#8)"
```

---

## Self-Review

- **Spec coverage:** Implements spec §5A gap **#8** ("normalize whitespace + string literals only; stop collapsing structural brackets so distinct snippets can't alias") and the §3 row 8 anchor (`check-action-trace.js:79,93`). Reading note: "normalize string literals" is implemented as **quote-style canonicalization** (`'` `"` `` ` `` → `"`); the extra `;` strip is carried over from the old squash as a statement-separator ≈ whitespace (not new scope). No other gap is in scope; #2/#3/#4/A are separate WS-1 plans.
- **Placeholder scan:** none — every step has the exact code, exact insertion point (after line 118), exact commands, and exact expected pass/fail per check (the fail/pass predictions were verified by running the old and new helpers directly in Node).
- **Type consistency:** `squash(x)→string`, `innerCode(code)→string` — names match between definition (Step 3) and use (Check-0 loop at `:87-93` calls `squash`/`innerCode` unchanged; `innerCode`'s arrow branch does the single wrapper-paren strip inline, no separate helper). No `stripWrapperParens` helper is introduced (an earlier draft's greedy balancer was dropped in favor of the exact one-paren strip). The `fingerprints`/`sessionCalls`/`steps` shapes are untouched.
- **Risk note (stated per instruction):** the subtle interaction is the disclosed/recorded ACCEPT cases, which relied on the old paren collapse; both are preserved by the arrow branch's exact one-paren strip, confirmed green in Step 4. On the string-literal-paren case, be precise: the old bracket-collapsing squash *symmetrically* deleted parens on **both** sides, so an honest disclosure whose value contains `)` (`…"a)")`) still matched its twin. The **greedy** balancer considered in an earlier draft would have introduced a **new false-reject** here (it eats the literal's `)` on only the session side) — a regression the old code did not have. The chosen exact one-paren strip resolves it (guard: test (d)). Any residual string-literal edge now **fails closed** — a mismatch can only reject, never let a concealed call alias a disclosed decoy — so it is a safety-preserving over-strict edge, not a hole.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-09-02-squash-hardening.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent for Task 1, review between steps, fast iteration.

**2. Inline Execution** — execute Task 1 in this session using executing-plans, with a checkpoint after Step 4.

**Which approach?**
