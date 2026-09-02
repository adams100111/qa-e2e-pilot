# Static UX Detector Families Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add five pure, in-page, read-only DETECTION families to `skills/detecting-visual-ux/scripts/ux-detectors.js` — content/data-rendering, i18n-script, assets, invisible-text, and overlap/z-index — each emitting a *suspicion* (`{detector, selector, evidence, rawSignal}`), never a verdict.

**Architecture:** `ux-detectors.js` becomes a **dual-mode module**. Every family's decision logic is factored into a *pure, DOM-free core* (a predicate over primitives — strings, numbers, `{r,g,b}` colors, `{left,top,right,bottom}` rects, `{naturalWidth,complete}` image shapes). The existing browser walk (renamed `DETECT()`) extracts those primitives from the live DOM and wraps a non-null core result into a suspicion. A final `typeof document !== 'undefined' ? DETECT() : (module.exports = {…cores…})` expression preserves the exact `browser_evaluate` contract (its value is still the findings array) while letting plain Node `require()` the cores — so the cores are unit-testable headlessly with **no new dependency**.

**Tech Stack:** Dependency-free browser JS (`document`/`window`/`getComputedStyle` only, injected via Playwright MCP `browser_evaluate`); plain Node (built-ins only) for the pure cores; a bash test runner at `tests/ux-detectors/run.sh` following the repo's existing `tests/<name>/run.sh` convention (cf. `tests/frontier/run.sh`, `tests/action-trace/run.sh`).

## Global Constraints

- **Detectors emit SUSPICIONS, never verdicts.** Each new-family finding is shaped `{detector, axis:"ux-suspicion", selector, text, evidence, rawSignal}` — it carries **no** `verdict`, `suspectedLayer`, or `confidence`. Adjudication/localization/confidence (design §1–§3) is a SEPARATE, out-of-scope effort; do not bake it in. (spec `docs/specs/2026-09-02-human-eye-ux-detection-design.md` §1: "a detector emits a *suspicion* `{family, selector, evidence, rawSignal}` — never a verdict".) The existing four detectors (`contrast`/`overflow`/`target-size`/`accessible-name`) keep their current shape unchanged — this plan does not touch their behavior.
- **Consumer rule — ship detection WITH its consumer (Q1, KEYSTONE).** `SKILL.md` is today the sole consumer of the findings array and its Step 3 turns **every** array element into `fail@FE, confidence:low`. Emitting the new suspicions into that array *without* a consumer rule would mint live false-fails (every script-mismatch, `raw-iso`, overlap, `null`-word). So this plan adds a minimal `SKILL.md` rule **in Task 1, before any suspicion family lands**: *an entry whose `axis` is `"ux-suspicion"` is NEVER a verdict — route it to the `## Advisory (aesthetics)` stream (or a `## Advisory (ux-suspicions)` subsection), never to the pass/fail tally, until the adjudication effort (design §1 steps 2–4) lands.* This is the same "hint entries carry no verdict" carve-out `SKILL.md` already applies to `overflow-ellipsis-hint` / `accessible-name-probe`, generalized to the new axis.
- **Detectors must behave like a human tester (Q2/Q3/Q4).** The north star is "an agent that behaves exactly like a human QA tester." A human does **not** flag `GitHub` or `PDF` on an Arabic page, `The null hypothesis` prose, `v1.2.3`, or `example.co.uk` as bugs. The human-likeness exemptions therefore live **inside the pure cores now** (not deferred to adjudication): bare-literal content words match standalone/value-position only; script-mismatch exempts obvious proper-noun/brand/acronym/URL/code; the dotted-key core rejects version strings, ccTLD domains, and file extensions. Each exemption ships with an **adversarial negative-control test** so precision is exercised, not asserted.
- **`ux-detectors.js` is dependency-free browser JS.** Only `document`/`window`/`getComputedStyle`/`fetch` — no npm packages, no axe-core, no jsdom, no build step. (CLAUDE.md "Bundled scripts depend on jq OR python3" / "Browser-context JS … write it as dependency-free browser code".)
- **The `browser_evaluate` contract is preserved.** The script's completion value stays the JSON-serializable findings array (SKILL.md Step 1: "It returns a JSON array of findings"). The dual-entry ternary's browser branch is `DETECT()`, so the completion value is identical to the previous IIFE form.
- **Precision discipline (ADR-0007 Step 5, spec §11.8).** A clean input must produce ZERO findings. Because the DOM walk only emits when a core returns non-null, the headless-runnable form of "a clean negative-control *element* produces zero findings" is "a clean value/color/rect fed to the core returns `null`." Every family task includes such negative-control core tests. Never loosen a threshold to inflate recall.
- **No sixth verdict / no vocabulary drift.** These are suspicions on a new `axis:"ux-suspicion"`; they never introduce `skip`/`warn`/`partial` and never a sixth verdict. (CLAUDE.md invariant.)
- **Validate before every commit:** `node --check skills/detecting-visual-ux/scripts/ux-detectors.js` (exit 0) and `bash tests/ux-detectors/run.sh` (prints `PASS=<N> FAIL=0`, exits 0). **`ux-detectors.js` is a core script copied verbatim into `dist/<harness>/`**, so any commit that touches it MUST also regenerate `dist/` and re-run the portability gates: `for h in claude codex opencode pi; do bash scripts/build-adapter.sh "$h"; done` then `bash tests/portability/run.sh && bash scripts/validate-adapters.sh` (both exit 0) as a **CI-parity gate**. Do **not** commit `dist/` — it is git-ignored; the regeneration + byte-oracle only proves the copy-through assembles cleanly. (`build-adapter.sh` does `cp -R skills … dist/<h>/`, so `dist/<h>/skills/detecting-visual-ux/scripts/ux-detectors.js` is a verbatim copy; skipping the regen silently drifts all four harness copies from the source. `tests/portability/run.sh` guards the PCRE grep/perl equivalence and `validate-adapters.sh` guards the rendered agent/commands manifests — run both so the whole adapter build stays green after the edit.)
- **Harness precision gate must not regress (Q7).** `tools/accuracy-harness/run-baseline.sh` drives the `qa-e2e-pilot` agent, which invokes `detecting-visual-ux` and injects *this* file against `fixture/index.html` (scored against `seeds.json`'s 11 seeded objective bugs). Because the new suspicions carry `axis:"ux-suspicion"` and the consumer rule routes them to **advisory** (never a verdict), they never enter the scored `bug-log.json` verdict set — so the current precision gate is unaffected. Seeding new-family fixtures + scorer wiring is the SEPARATE deferred deliverable (§9/§11). Acceptance: a baseline run's scored precision/recall on the existing 11 seeds is **unchanged**, with any new-family hits appearing only in the advisory stream. If a new suspicion is ever found in the scored bug-log, the scorer/convert step must filter `axis:"ux-suspicion"` — do not let it count as a false positive.
- **Commit messages contain no Claude/Anthropic attribution and no `Co-Authored-By` trailer.** (User global rule.)
- **Test-strategy note (linchpin) — cores ≠ detectors.** The pure cores are unit-tested, and `DETECT()` is now **exported in the Node branch** so one cheap end-to-end test (Task 1) stubs the handful of globals it touches (`document.querySelectorAll → []`, `documentElement.getAttribute → null`, `getComputedStyle → {}`) and asserts `DETECT()` runs without throwing and **returns an array** — the browser completion-value contract, exercised in Node, not merely `node --check`'d for syntax. **But a passing core test is NOT a passing detector.** The DOM *extraction* around several cores is where the real risk lives and is only smoke-covered by the empty-document assertion: label resolution for `content-empty-required-label` (`label[for]` / `aria-label` / `aria-labelledby` / `closest('label')`), `z-index`/backdrop-sibling identification for `overlap-modal-behind-backdrop`, `getBoundingClientRect` geometry for `overlap-controls`, and `effectiveBg` alpha-compositing for `invisible-text`. That extraction is **unverified against real markup until the accuracy-harness fixture + scorer wiring lands** (a SEPARATE deliverable, spec §9/§11); trivial cores (`isEmptyRequiredLabel` = `trim===''`, `modalBehindBackdrop` = `a<b`) give confidence only in the arithmetic, not the extraction. Until then the DOM walk is exercised ad hoc via `tools/accuracy-harness/run-baseline.sh --serve` + a `qa-e2e-pilot` browser pass.

---

### Task 1: Dual-mode module scaffold + shared color cores + test runner

Convert the current single IIFE into `DETECT()` (browser DOM walk) plus top-level pure cores, add the dual-entry expression, and bootstrap the `tests/ux-detectors/run.sh` runner. This locks the test strategy every later task depends on. After this task the file is `require()`-able in plain Node without a `document`, exporting the three shared color helpers.

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/ux-detectors.js:34-53` (lift color helpers to top level, open `DETECT()`), `:271` (the closing `})();` → `}` + dual-entry)
- Modify: `skills/detecting-visual-ux/SKILL.md` (add the Q1 consumer rule: `axis:"ux-suspicion"` entries are never verdicts)
- Create: `tests/ux-detectors/run.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces (Node exports): `relLuminance(r:number,g:number,b:number) → number`, `parseRGB(s:string) → {r,g,b,a}|null`, `contrastRatio(fg:{r,g,b}, bg:{r,g,b}) → number`, and `DETECT()` (exported in the Node branch for the end-to-end assertion; only callable when `document`/`getComputedStyle` globals are present). Browser completion value: the findings array from `DETECT()` (unchanged).

- [ ] **Step 1: Write the failing test (runner bootstrap)**

Create `tests/ux-detectors/run.sh` with exactly:

```bash
#!/usr/bin/env bash
# Tests for ux-detectors.js PURE family cores (DOM-free, plain Node — no jsdom).
# The browser DOM walk (DETECT) is validated by node --check + the accuracy-harness
# fixture browser run; these tests exercise the pure predicate cores behind each family.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/detecting-visual-ux/scripts/ux-detectors.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# call <exportName> <jsonArgsArray>  -> prints JSON.stringify(result); "null" when null.
call() { node -e 'const m=require(process.argv[1]);const f=m[process.argv[2]];const a=JSON.parse(process.argv[3]);const r=f.apply(null,a);process.stdout.write(r===null?"null":JSON.stringify(r));' "$MOD" "$1" "$2" 2>/dev/null; }
# field <exportName> <jsonArgsArray> <key> -> prints result[key]; "null" when result is null.
field() { node -e 'const m=require(process.argv[1]);const f=m[process.argv[2]];const a=JSON.parse(process.argv[3]);const r=f.apply(null,a);process.stdout.write(r==null?"null":String(r[process.argv[4]]));' "$MOD" "$1" "$2" "$4" 2>/dev/null; }

# --- Task 1: dual-mode module loads under Node and shared color cores work -------
check "module requires under node (no document)" \
  "$(node -e 'require(process.argv[1]);process.stdout.write("ok")' "$MOD" 2>/dev/null)" "ok"
check "contrastRatio black-on-white ~21" \
  "$(node -e 'const{contrastRatio}=require(process.argv[1]);process.stdout.write(contrastRatio({r:0,g:0,b:0},{r:255,g:255,b:255}).toFixed(1))' "$MOD" 2>/dev/null)" "21.0"
check "parseRGB parses rgb()" \
  "$(field parseRGB '["rgb(255, 0, 0)"]' r)" "255"
# Q6: DETECT() end-to-end — stub the handful of globals it touches on an EMPTY document
# and assert it runs without throwing and returns an array (the browser completion-value
# contract, exercised in Node — not just node --check syntax).
check "DETECT() returns an array on an empty document" \
  "$(node -e 'const m=require(process.argv[1]);
    global.document={querySelectorAll:function(){return [];},querySelector:function(){return null;},getElementById:function(){return null;},documentElement:{getAttribute:function(){return null;}}};
    global.getComputedStyle=function(){return {};};
    const r=m.DETECT();process.stdout.write(Array.isArray(r)?"array":"NOT-ARRAY");' "$MOD" 2>/dev/null)" "array"

echo; echo "ux-detectors tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

Then make it executable:

```bash
chmod +x tests/ux-detectors/run.sh
```

- [ ] **Step 2: Run the runner to verify it fails**

Run: `bash tests/ux-detectors/run.sh`
Expected: FAIL. The current file is an IIFE that runs on `require` and touches `document`, so `require()` throws `ReferenceError: document is not defined`; all four checks print empty and fail — e.g. `FAIL - module requires under node (no document) (got '' want 'ok')`. Final line: `ux-detectors tests: PASS=0 FAIL=4`, non-zero exit.

- [ ] **Step 3: Lift the color cores to top level and open `DETECT()`**

In `skills/detecting-visual-ux/scripts/ux-detectors.js`, replace lines 34–53 (from `(function () {` through the end of `contrastRatio`) with:

```javascript
// ===== Pure, DOM-free cores (shared by the browser walk AND the node unit tests) =====
function relLuminance(r, g, b) {
  const a = [r, g, b].map(function (v) {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
}
function parseRGB(s) {
  const m = (s || '').match(/rgba?\(([^)]+)\)/);
  if (!m) return null;
  const p = m[1].split(',').map(function (x) { return parseFloat(x.trim()); });
  return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
}
function contrastRatio(fg, bg) {
  const L1 = relLuminance(fg.r, fg.g, fg.b);
  const L2 = relLuminance(bg.r, bg.g, bg.b);
  const hi = Math.max(L1, L2), lo = Math.min(L1, L2);
  return (hi + 0.05) / (lo + 0.05);
}

// ===== Browser-only DOM walk. Returns the findings array (browser_evaluate completion value). =====
function DETECT() {
```

Everything from the old `compositeOver` (line 54) through `return findings;` (line 270) is now the body of `DETECT()` and is unchanged — it references `relLuminance`/`parseRGB`/`contrastRatio` via the top-level scope (function declarations hoist).

- [ ] **Step 4: Replace the IIFE close with the dual entry point**

In the same file, replace the final line 271 `})();` with:

```javascript
}

// ===== Dual entry point =====
// Browser (injected via browser_evaluate): run the DOM walk — the ternary's VALUE is the
// findings array, exactly like the previous IIFE form, so the evaluate() contract is preserved.
// Node (unit tests / tooling): export the pure cores; DETECT() is never called, so `document`
// is never referenced on require.
typeof document !== 'undefined'
  ? DETECT()
  : (typeof module !== 'undefined' && module.exports &&
     (module.exports = {
       relLuminance: relLuminance,
       parseRGB: parseRGB,
       contrastRatio: contrastRatio,
       DETECT: DETECT
     }));
```

`DETECT` is exported alongside the pure cores so the Q6 end-to-end test can call it under stubbed globals. It is a harmless function reference in Node — its body resolves `document`/`getComputedStyle` at CALL time, so requiring the module (no `document`) never touches the DOM; only the explicit test call does, after stubbing.

- [ ] **Step 5: Add the Q1 consumer rule to `SKILL.md` (ship detection WITH its consumer)**

In `skills/detecting-visual-ux/SKILL.md`, in **Step 1** (right after the paragraph describing the returned findings array and before Step 2), add:

```markdown
**Suspicion entries are NEVER verdicts (`axis:"ux-suspicion"`).** Alongside the four objective
detectors, `ux-detectors.js` may return entries whose `axis` is `"ux-suspicion"` (the new
content/i18n/assets/invisible-text/overlap families). These carry **no** `verdict`,
`suspectedLayer`, or `confidence`. Do **not** apply Step 3 to them — an `axis:"ux-suspicion"`
entry never becomes a `fail` and is never counted in the pass/fail tally. Route each into the
report's advisory stream as `- [selector] <evidence> (ux-suspicion — not a verdict; awaiting
adjudication)`, exactly like the `overflow-ellipsis-hint` / `accessible-name-probe` hint carve-out.
Turning suspicions into verdicts (adjudication — design §1 steps 2–4) is a separate, later effort.
```

Then in **Step 3** ("Objective finding -> criterion verdict"), change its opening so it applies only to `axis:"ux-objective"` findings: add the clause "*(applies only to `axis:"ux-objective"` findings from the four detectors above; `axis:"ux-suspicion"` entries are handled by the Step 1 rule and never reach a verdict).*"

- [ ] **Step 6: Run to verify pass**

Run: `node --check skills/detecting-visual-ux/scripts/ux-detectors.js && bash tests/ux-detectors/run.sh`
Expected: `node --check` prints nothing (exit 0); the runner prints `ux-detectors tests: PASS=4 FAIL=0` and exits 0.

- [ ] **Step 7: Regenerate `dist/` + commit**

```bash
for h in claude codex opencode pi; do bash scripts/build-adapter.sh "$h"; done
bash tests/portability/run.sh && bash scripts/validate-adapters.sh
git add skills/detecting-visual-ux/scripts/ux-detectors.js skills/detecting-visual-ux/SKILL.md tests/ux-detectors/run.sh
git commit -m "refactor(ux-detectors): dual-mode module (browser DETECT + node-exported pure cores) + suspicion consumer rule"
```

---

### Task 2: Content / data-rendering family

Flag rendered content-oracle artifacts a human would spot instantly: `undefined`, `null`, `NaN`, `$NaN`, `Invalid Date`, `[object Object]`, raw `{{interp}}` template markers, raw ISO datetimes, and required form controls with an empty label. The design classes these as a **definite content oracle** (spec §2), but this detector still only *suspects* — adjudication assigns any verdict.

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/ux-detectors.js` — add cores after `contrastRatio` (before `function DETECT() {`), add the `suspicion()` helper + DOM block inside `DETECT()`, add the two cores to `module.exports`.
- Test: `tests/ux-detectors/run.sh` (append a Task-2 section before the summary line)

**Interfaces:**
- Consumes: nothing new.
- Produces: `contentOracleSignal(text:string) → {kind:string, rawSignal:string} | null`; `isEmptyRequiredLabel(labelText:string) → boolean`. `kind` ∈ `object-object|currency-nan|nan|invalid-date|undefined|null|raw-interp|raw-iso`. DOM emits `detector` values `content-<kind>` and `content-empty-required-label`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ux-detectors/run.sh` immediately before the `echo; echo "ux-detectors tests:"` summary line:

```bash
# --- Task 2: content / data-rendering ------------------------------------------
check "content: [object Object] kind"   "$(field contentOracleSignal '["Owner: [object Object]"]' kind)"       "object-object"
check "content: $NaN kind"              "$(field contentOracleSignal '["Total: $NaN"]' kind)"                  "currency-nan"
check "content: NaN kind"               "$(field contentOracleSignal '["Total: NaN"]' kind)"                   "nan"
check "content: NaN rawSignal clean"    "$(field contentOracleSignal '["Total: NaN"]' rawSignal)"             "NaN"
check "content: Invalid Date kind"      "$(field contentOracleSignal '["Due Invalid Date"]' kind)"             "invalid-date"
check "content: undefined kind"         "$(field contentOracleSignal '["Name: undefined"]' kind)"              "undefined"
check "content: null kind"              "$(field contentOracleSignal '["Value null"]' kind)"                   "null"
check "content: raw interp kind"        "$(field contentOracleSignal '["Hello {{ user.name }}"]' kind)"        "raw-interp"
check "content: raw ISO kind"           "$(field contentOracleSignal '["2026-09-02T14:33:00Z"]' kind)"         "raw-iso"
# negative controls: clean rendered values -> null (zero findings)
check "content: clean name -> null"     "$(call contentOracleSignal '["Alice Smith"]')"                        "null"
check "content: clean money -> null"    "$(call contentOracleSignal '["$1,240.00"]')"                          "null"
check "content: clean count -> null"    "$(call contentOracleSignal '["12 items"]')"                           "null"
check "content: bare date -> null"      "$(call contentOracleSignal '["2026-09-02"]')"                         "null"
check "content: humanized date -> null" "$(call contentOracleSignal '["Jan 3, 2026"]')"                        "null"
# Q2 adversarial: prose containing a bare literal NOT in value position -> null (a human
# reads "The null hypothesis" as prose, never a rendering bug). Value-position stays flagged.
check "content: prose null -> null"     "$(call contentOracleSignal '["The null hypothesis"]')"                "null"
check "content: prose undefined -> null" "$(call contentOracleSignal '["a truly undefined concept in math"]')" "null"
# empty-required-label core
check "content: empty label -> true"    "$(call isEmptyRequiredLabel '["   "]')"                               "true"
check "content: real label -> false"    "$(call isEmptyRequiredLabel '["Email"]')"                             "false"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/ux-detectors/run.sh`
Expected: FAIL. `contentOracleSignal`/`isEmptyRequiredLabel` are not exported yet, so `f.apply` throws (`f is not a function`) and every new check prints empty — e.g. `FAIL - content: NaN kind (got '' want 'nan')`. Task-1 checks still pass. Final line reports `FAIL>0`, non-zero exit.

- [ ] **Step 3: Add the cores**

In `ux-detectors.js`, insert immediately after the `contrastRatio` function and before the `// ===== Browser-only DOM walk` comment:

```javascript
// content/data-rendering: definite content-oracle artifacts in a rendered value.
// Q2 (human-like precision): the bare literals `undefined`/`null`/`NaN`/`$NaN` are flagged ONLY
// in VALUE POSITION — i.e. as the trailing token of the rendered value (`(?=\s*$)`), which is
// how they leak from a data slot ("Name: undefined", "Value null", "Total: NaN"). A human does
// NOT flag them mid-prose ("The null hypothesis", "a truly undefined concept"), so those must
// NOT match. `[object Object]`, `Invalid Date`, raw `{{interp}}`, and raw ISO never occur in
// legitimate prose, so they stay position-independent. Lookbehind/lookahead keep boundaries clean.
function contentOracleSignal(text) {
  const t = String(text == null ? '' : text);
  const checks = [
    ['object-object', /\[object [A-Z]\w*\]/],                 // [object Object], [object Array]
    ['currency-nan', /\$NaN(?=\s*$)/],                        // value-position; before generic nan
    ['nan', /(?<![A-Za-z])NaN(?![A-Za-z])(?=\s*$)/],          // value-position only
    ['invalid-date', /\bInvalid Date\b/],
    ['undefined', /(?<![A-Za-z])undefined(?![A-Za-z])(?=\s*$)/], // value-position only (not prose)
    ['null', /(?<![A-Za-z])null(?![A-Za-z])(?=\s*$)/],           // value-position only (not prose)
    ['raw-interp', /\{\{[^}]+\}\}/],                          // unrendered {{ interpolation }}
    ['raw-iso', /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/]
  ];
  for (let i = 0; i < checks.length; i++) {
    const m = t.match(checks[i][1]);
    if (m) return { kind: checks[i][0], rawSignal: m[0].trim() };
  }
  return null;
}
// A required control whose resolved label is empty is a content gap.
function isEmptyRequiredLabel(labelText) {
  return String(labelText == null ? '' : labelText).trim() === '';
}
```

- [ ] **Step 4: Add the `suspicion()` helper and the DOM block**

In the same file, inside `DETECT()`, immediately after the existing `finding(...)` function (the block that ends `}, extra || {});\n  }`) add:

```javascript
  // A SUSPICION carries NO verdict/suspectedLayer/confidence — adjudication assigns those.
  function suspicion(detector, el, evidence, rawSignal) {
    return {
      detector: detector,
      axis: 'ux-suspicion',
      selector: cssPath(el),
      text: visibleText(el),
      evidence: evidence,
      rawSignal: rawSignal
    };
  }
  // Direct (own) text of an element, whitespace-collapsed — avoids double-flagging on ancestors.
  function directText(el) {
    let s = '';
    Array.prototype.forEach.call(el.childNodes, function (n) { if (n.nodeType === 3) s += n.textContent; });
    return s.replace(/\s+/g, ' ').trim();
  }
```

Then, in the same file, insert immediately before `return findings;` (the last line of `DETECT()`):

```javascript
  // ---- Content / data-rendering suspicions ----
  all.forEach(function (el) {
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) return;
    const direct = directText(el);
    if (!direct) return;
    const sig = contentOracleSignal(direct);
    if (sig) findings.push(suspicion('content-' + sig.kind, el, direct, sig.rawSignal));
  });
  Array.prototype.slice.call(document.querySelectorAll('[required], [aria-required="true"]'))
    .forEach(function (el) {
      let lbl = '';
      if (el.id) {
        const forLbl = document.querySelector('label[for="' + el.id + '"]');
        if (forLbl) lbl = (forLbl.textContent || '').trim();
      }
      if (!lbl && el.getAttribute('aria-label')) lbl = el.getAttribute('aria-label').trim();
      // Q5: aria-labelledby is a first-class labelling mechanism — resolve referenced elements'
      // text, else a properly-labelled required control is falsely flagged as label-less.
      if (!lbl && el.getAttribute('aria-labelledby')) {
        lbl = el.getAttribute('aria-labelledby').split(/\s+/).map(function (id) {
          const t = document.getElementById(id);
          return t ? (t.textContent || '').trim() : '';
        }).filter(Boolean).join(' ').trim();
      }
      if (!lbl && el.closest) { const wrap = el.closest('label'); if (wrap) lbl = (wrap.textContent || '').trim(); }
      if (isEmptyRequiredLabel(lbl)) {
        findings.push(suspicion('content-empty-required-label', el, 'required control has no visible/aria label', ''));
      }
    });
```

- [ ] **Step 5: Add the cores to `module.exports`**

In the same file, replace the export object in the dual-entry ternary with (adds the two new names):

```javascript
     (module.exports = {
       relLuminance: relLuminance,
       parseRGB: parseRGB,
       contrastRatio: contrastRatio,
       DETECT: DETECT,
       contentOracleSignal: contentOracleSignal,
       isEmptyRequiredLabel: isEmptyRequiredLabel
     }));
```

- [ ] **Step 6: Run to verify pass**

Run: `node --check skills/detecting-visual-ux/scripts/ux-detectors.js && bash tests/ux-detectors/run.sh`
Expected: `node --check` exit 0; runner prints `ux-detectors tests: PASS=<N> FAIL=0` (all Task-1 + Task-2 checks green) and exits 0.

- [ ] **Step 7: Regenerate `dist/` + commit**

```bash
for h in claude codex opencode pi; do bash scripts/build-adapter.sh "$h"; done
bash tests/portability/run.sh && bash scripts/validate-adapters.sh
git add skills/detecting-visual-ux/scripts/ux-detectors.js tests/ux-detectors/run.sh
git commit -m "feat(ux-detectors): content/data-rendering suspicion family"
```

---

### Task 3: i18n-script family

Two related i18n suspicions over rendered text: a **raw translation key** leaking through (a definite pattern oracle — spec §4 row 1), and a **Unicode-script mismatch** versus the expected locale (a *heuristic* suspicion — spec §2, "script-mismatch is a suspicion"). The expected locale is read in-page from `<html lang>`; when absent the script check safely no-ops (no false positives).

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/ux-detectors.js` — add cores after `contentOracleSignal`/`isEmptyRequiredLabel`, add DOM block inside `DETECT()`, extend `module.exports`.
- Test: `tests/ux-detectors/run.sh` (append a Task-3 section before the summary line)

**Interfaces:**
- Consumes: nothing new.
- Produces: `rawTranslationKeySignal(text:string) → {rawSignal:string} | null`; `scriptMismatchSignal(text:string, expectedLocale:string) → {expectedScript:string, fraction:number, rawSignal:string} | null`. DOM emits `detector` values `i18n-raw-key` and `i18n-script-mismatch`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ux-detectors/run.sh` immediately before the summary line:

```bash
# --- Task 3: i18n-script -------------------------------------------------------
# raw translation key (whole-label dotted identifier)
check "i18n: raw key rawSignal"          "$(field rawTranslationKeySignal '["deliverables.title"]' rawSignal)"   "deliverables.title"
check "i18n: nested raw key"             "$(field rawTranslationKeySignal '["common.buttons.save"]' rawSignal)"  "common.buttons.save"
check "i18n: label with space -> null"   "$(call rawTranslationKeySignal '["Save changes"]')"                    "null"
check "i18n: domain -> null"             "$(call rawTranslationKeySignal '["www.example.com"]')"                  "null"
check "i18n: email -> null"              "$(call rawTranslationKeySignal '["user@site.com"]')"                    "null"
check "i18n: decimal -> null"            "$(call rawTranslationKeySignal '["3.14"]')"                             "null"
# Q4 adversarial: version strings, ccTLD domains, and file names are NOT translation keys
check "i18n: version v1.2.3 -> null"     "$(call rawTranslationKeySignal '["v1.2.3"]')"                           "null"
check "i18n: ccTLD domain -> null"       "$(call rawTranslationKeySignal '["example.co.uk"]')"                    "null"
check "i18n: source file -> null"        "$(call rawTranslationKeySignal '["Component.tsx"]')"                    "null"
# script mismatch vs expected locale
check "i18n: ar expected, latin text"    "$(field scriptMismatchSignal '["Save changes","ar"]' expectedScript)"  "Arabic"
check "i18n: ar expected, arabic text"   "$(call scriptMismatchSignal '["حفظ التغييرات","ar"]')"                 "null"
check "i18n: en expected (latin) -> null" "$(call scriptMismatchSignal '["Save changes","en"]')"                  "null"
check "i18n: too short -> null"          "$(call scriptMismatchSignal '["OK","ar"]')"                             "null"
check "i18n: ru expected, latin text"    "$(field scriptMismatchSignal '["Sohranit izmeneniya","ru"]' expectedScript)" "Cyrillic"
# Q3 adversarial: a human does NOT flag a brand/acronym on an Arabic page as untranslated
check "i18n: ar + brand GitHub -> null"  "$(call scriptMismatchSignal '["GitHub","ar"]')"                        "null"
check "i18n: ar + acronym PDF -> null"   "$(call scriptMismatchSignal '["PDF","ar"]')"                           "null"
check "i18n: ar + URL -> null"           "$(call scriptMismatchSignal '["https://example.com","ar"]')"           "null"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/ux-detectors/run.sh`
Expected: FAIL. `rawTranslationKeySignal`/`scriptMismatchSignal` are not exported yet, so the new checks print empty and fail. Task-1/2 checks stay green. Final line `FAIL>0`, non-zero exit.

- [ ] **Step 3: Add the cores**

In `ux-detectors.js`, insert immediately after `isEmptyRequiredLabel` (still before the `// ===== Browser-only DOM walk` comment):

```javascript
// i18n: a bare translation key rendered as a label (whole-text dotted identifier),
// excluding URLs / emails / domains / file names / numbers to hold precision.
function rawTranslationKeySignal(text) {
  const t = String(text == null ? '' : text).trim();
  if (!t || /\s/.test(t)) return null;                       // real labels have spaces
  if (t.indexOf('@') !== -1 || t.indexOf('://') !== -1) return null;   // email / URL
  // Q4 (human-like precision): version strings, ccTLD domains, and file names are NOT keys.
  if (/^v\d/i.test(t)) return null;                          // v1.2.3, v2 — a version, not a key
  if (/^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2}$/.test(t)) return null;  // ccTLD domain: example.co.uk
  if (/\.(com|org|net|io|dev|co|gov|edu|app|html?|js|mjs|cjs|jsx|ts|tsx|vue|css|scss|less|json|ya?ml|toml|xml|md|txt|csv|pdf|png|jpe?g|gif|webp|svg|ico|py|rb|go|rs|java|kt|swift|php)$/i.test(t)) return null;
  if (!/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/.test(t)) return null;  // dotted identifier
  return { rawSignal: t };
}
// i18n: locale -> expected Unicode script. Latin/unknown locales carry no script oracle.
const LOCALE_SCRIPT = {
  ar: 'Arabic', fa: 'Arabic', ur: 'Arabic', ps: 'Arabic',
  he: 'Hebrew', yi: 'Hebrew',
  ru: 'Cyrillic', uk: 'Cyrillic', bg: 'Cyrillic', sr: 'Cyrillic',
  el: 'Greek', ja: 'Han', zh: 'Han', ko: 'Hangul',
  hi: 'Devanagari', mr: 'Devanagari', th: 'Thai'
};
function scriptMismatchSignal(text, expectedLocale) {
  const loc = String(expectedLocale || '').toLowerCase().split(/[-_]/)[0];
  const script = LOCALE_SCRIPT[loc];
  if (!script) return null;                                  // no non-Latin script expected
  const trimmed = String(text == null ? '' : text).trim();
  const letters = trimmed.match(/\p{L}/gu) || [];
  if (letters.length < 3) return null;                       // abbrev/brand/symbol — precision guard
  // Q3 (human-like precision): a human does NOT read a brand / acronym / URL / code identifier as
  // "untranslated" just because it's Latin on an Arabic page (GitHub, PDF, https://…, api.v2).
  // Exempt when NO token reads as translatable lowercase prose. A brand/acronym/CamelCase token
  // ("GitHub", "PDF", "iPhone") has no lowercase-initial all-lowercase word; a translatable phrase
  // ("Save changes", "Sohranit izmeneniya") does. URLs/emails/code punctuation are exempt outright.
  if (/:\/\/|[@<>{}=;\\]|www\./.test(trimmed)) return null;  // URL / email / code
  const proseToken = trimmed.split(/\s+/).some(function (tok) {
    return /^[a-z][a-z]+$/.test(tok);                        // a lowercase word => reads as prose
  });
  if (!proseToken) return null;                              // all brand/acronym/proper-noun -> not a bug
  const re = new RegExp('\\p{Script=' + script + '}', 'u');
  let inScript = 0;
  for (let i = 0; i < letters.length; i++) if (re.test(letters[i])) inScript++;
  const frac = inScript / letters.length;
  if (frac >= 0.5) return null;                              // predominantly correct script
  return { expectedScript: script, fraction: Number(frac.toFixed(2)), rawSignal: trimmed.slice(0, 40) };
}
```

- [ ] **Step 4: Add the DOM block**

In the same file, inside `DETECT()`, insert immediately before `return findings;` (after the Task-2 content block):

```javascript
  // ---- i18n-script suspicions ----
  const EXPECTED_LOCALE = (document.documentElement.getAttribute('lang') || '').trim();
  all.forEach(function (el) {
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) return;
    const direct = directText(el);
    if (!direct) return;
    const key = rawTranslationKeySignal(direct);
    if (key) { findings.push(suspicion('i18n-raw-key', el, direct, key.rawSignal)); return; }
    const mm = scriptMismatchSignal(direct, EXPECTED_LOCALE);
    if (mm) {
      findings.push(suspicion('i18n-script-mismatch', el,
        'expected ' + mm.expectedScript + ' script; ' + Math.round(mm.fraction * 100) + '% in-script',
        mm.rawSignal));
    }
  });
```

- [ ] **Step 5: Extend `module.exports`**

Replace the export object in the dual-entry ternary with:

```javascript
     (module.exports = {
       relLuminance: relLuminance,
       parseRGB: parseRGB,
       contrastRatio: contrastRatio,
       DETECT: DETECT,
       contentOracleSignal: contentOracleSignal,
       isEmptyRequiredLabel: isEmptyRequiredLabel,
       rawTranslationKeySignal: rawTranslationKeySignal,
       scriptMismatchSignal: scriptMismatchSignal
     }));
```

- [ ] **Step 6: Run to verify pass**

Run: `node --check skills/detecting-visual-ux/scripts/ux-detectors.js && bash tests/ux-detectors/run.sh`
Expected: `node --check` exit 0; runner prints `ux-detectors tests: PASS=<N> FAIL=0` and exits 0.

- [ ] **Step 7: Regenerate `dist/` + commit**

```bash
for h in claude codex opencode pi; do bash scripts/build-adapter.sh "$h"; done
bash tests/portability/run.sh && bash scripts/validate-adapters.sh
git add skills/detecting-visual-ux/scripts/ux-detectors.js tests/ux-detectors/run.sh
git commit -m "feat(ux-detectors): i18n raw-key + script-mismatch suspicion family"
```

---

### Task 4: Assets (broken images) + invisible-text families

Two single-element leaf checks paired in one task. **Assets:** an `<img>` that finished loading with `naturalWidth === 0` failed to load (spec §4.5). **Invisible-text:** foreground ≈ background (contrast ratio ≤ 1.1) so text is effectively unreadable — a distinct suspicion from the existing `contrast` detector (they may co-fire; that is fine).

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/ux-detectors.js` — add cores after the i18n cores, add DOM blocks inside `DETECT()`, extend `module.exports`.
- Test: `tests/ux-detectors/run.sh` (append a Task-4 section before the summary line)

**Interfaces:**
- Consumes: `contrastRatio` (Task 1) for the invisible-text core.
- Produces: `isBrokenImage(img:{naturalWidth:number, complete:boolean}) → boolean`; `invisibleTextSignal(fg:{r,g,b}, bg:{r,g,b}) → {ratio:number} | null`. DOM emits `detector` values `asset-broken-image` and `invisible-text`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ux-detectors/run.sh` immediately before the summary line:

```bash
# --- Task 4: assets + invisible-text -------------------------------------------
check "asset: failed image -> true"     "$(call isBrokenImage '[{"naturalWidth":0,"complete":true}]')"          "true"
check "asset: loaded image -> false"    "$(call isBrokenImage '[{"naturalWidth":120,"complete":true}]')"        "false"
check "asset: still-loading -> false"   "$(call isBrokenImage '[{"naturalWidth":0,"complete":false}]')"         "false"
check "invisible: white-on-white ratio" "$(field invisibleTextSignal '[{"r":255,"g":255,"b":255},{"r":255,"g":255,"b":255}]' ratio)" "1"
check "invisible: near-equal fires"     "$(field invisibleTextSignal '[{"r":118,"g":118,"b":118},{"r":119,"g":119,"b":119}]' ratio)" "1.01"
check "invisible: black-on-white -> null" "$(call invisibleTextSignal '[{"r":0,"g":0,"b":0},{"r":255,"g":255,"b":255}]')"           "null"
check "invisible: mid-contrast -> null" "$(call invisibleTextSignal '[{"r":17,"g":17,"b":17},{"r":255,"g":255,"b":255}]')"          "null"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/ux-detectors/run.sh`
Expected: FAIL. `isBrokenImage`/`invisibleTextSignal` are not exported yet; the new checks print empty and fail. Earlier tasks stay green. Final line `FAIL>0`, non-zero exit.

- [ ] **Step 3: Add the cores**

In `ux-detectors.js`, insert immediately after `scriptMismatchSignal` (before the `// ===== Browser-only DOM walk` comment):

```javascript
// assets: an <img> that completed loading with zero intrinsic width failed to load.
// complete:false is still in-flight — do NOT flag (precision guard).
function isBrokenImage(img) {
  if (!img) return false;
  return img.complete === true && img.naturalWidth === 0;
}
// invisible-text: foreground ≈ background. Contrast ratio ~1.0 means the text is effectively
// the same color as its backdrop — distinct from (and stronger than) the WCAG contrast check.
function invisibleTextSignal(fg, bg) {
  if (!fg || !bg) return null;
  const ratio = contrastRatio(fg, bg);
  if (ratio > 1.1) return null;
  return { ratio: Number(ratio.toFixed(2)) };
}
```

- [ ] **Step 4: Add the DOM blocks**

In the same file, inside `DETECT()`, insert immediately before `return findings;` (after the Task-3 i18n block):

```javascript
  // ---- Asset (broken-image) suspicions ----
  Array.prototype.slice.call(document.querySelectorAll('img')).forEach(function (img) {
    if (isBrokenImage(img)) {
      findings.push(suspicion('asset-broken-image', img,
        (img.getAttribute('src') || img.currentSrc || '(no src)'),
        'naturalWidth=0 (failed to load)'));
    }
  });

  // ---- Invisible-text suspicions (fg ≈ bg) ----
  all.forEach(function (el) {
    const hasText = el.childNodes.length && Array.prototype.some.call(el.childNodes, function (n) {
      return n.nodeType === 3 && n.textContent.trim();
    });
    if (!hasText) return;
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) return;
    const fg = parseRGB(st.color);
    if (!fg) return;
    const bg = effectiveBg(el);
    const sig = invisibleTextSignal(fg, bg);
    if (sig) findings.push(suspicion('invisible-text', el, 'fg≈bg contrast ' + sig.ratio + ':1', String(sig.ratio)));
  });
```

- [ ] **Step 5: Extend `module.exports`**

Replace the export object in the dual-entry ternary with:

```javascript
     (module.exports = {
       relLuminance: relLuminance,
       parseRGB: parseRGB,
       contrastRatio: contrastRatio,
       DETECT: DETECT,
       contentOracleSignal: contentOracleSignal,
       isEmptyRequiredLabel: isEmptyRequiredLabel,
       rawTranslationKeySignal: rawTranslationKeySignal,
       scriptMismatchSignal: scriptMismatchSignal,
       isBrokenImage: isBrokenImage,
       invisibleTextSignal: invisibleTextSignal
     }));
```

- [ ] **Step 6: Run to verify pass**

Run: `node --check skills/detecting-visual-ux/scripts/ux-detectors.js && bash tests/ux-detectors/run.sh`
Expected: `node --check` exit 0; runner prints `ux-detectors tests: PASS=<N> FAIL=0` and exits 0.

- [ ] **Step 7: Regenerate `dist/` + commit**

```bash
for h in claude codex opencode pi; do bash scripts/build-adapter.sh "$h"; done
bash tests/portability/run.sh && bash scripts/validate-adapters.sh
git add skills/detecting-visual-ux/scripts/ux-detectors.js tests/ux-detectors/run.sh
git commit -m "feat(ux-detectors): broken-image + invisible-text suspicion families"
```

---

### Task 5: Overlap / z-index family

Two geometry cores: a modal/overlay stacked BELOW its backdrop (`z-index` inversion — spec §4.3 "z-index (modal behind overlay)") and interactive controls whose rendered boxes collide (spec §4.3 "overlap/collision"). The DOM walk scopes overlap narrowly — skipping ancestor/descendant nesting and requiring >50% overlap of interactive controls — to hold precision.

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/ux-detectors.js` — add cores after the Task-4 cores, add DOM block inside `DETECT()`, extend `module.exports`.
- Test: `tests/ux-detectors/run.sh` (append a Task-5 section before the summary line)

**Interfaces:**
- Consumes: nothing new.
- Produces: `modalBehindBackdrop(modalZ:number, backdropZ:number) → boolean`; `rectsCollide(a:Rect, b:Rect) → boolean`; `rectOverlapFraction(a:Rect, b:Rect) → number` where `Rect = {left,top,right,bottom}`. DOM emits `detector` values `overlap-modal-behind-backdrop` and `overlap-controls`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ux-detectors/run.sh` immediately before the summary line:

```bash
# --- Task 5: overlap / z-index -------------------------------------------------
check "z: modal below backdrop -> true"  "$(call modalBehindBackdrop '[10,100]')"    "true"
check "z: modal above backdrop -> false" "$(call modalBehindBackdrop '[1000,999]')"  "false"
check "z: equal -> false"                "$(call modalBehindBackdrop '[50,50]')"     "false"
check "collide: overlapping -> true"     "$(call rectsCollide '[{"left":0,"top":0,"right":50,"bottom":50},{"left":25,"top":25,"right":75,"bottom":75}]')" "true"
check "collide: adjacent -> false"       "$(call rectsCollide '[{"left":0,"top":0,"right":50,"bottom":50},{"left":50,"top":0,"right":100,"bottom":50}]')" "false"
check "frac: contained -> 1"             "$(call rectOverlapFraction '[{"left":0,"top":0,"right":100,"bottom":100},{"left":10,"top":10,"right":30,"bottom":30}]')" "1"
check "frac: adjacent -> 0"              "$(call rectOverlapFraction '[{"left":0,"top":0,"right":50,"bottom":50},{"left":50,"top":0,"right":100,"bottom":50}]')" "0"
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `bash tests/ux-detectors/run.sh`
Expected: FAIL. `modalBehindBackdrop`/`rectsCollide`/`rectOverlapFraction` are not exported yet; the new checks print empty and fail. Earlier tasks stay green. Final line `FAIL>0`, non-zero exit.

- [ ] **Step 3: Add the cores**

In `ux-detectors.js`, insert immediately after `invisibleTextSignal` (before the `// ===== Browser-only DOM walk` comment):

```javascript
// overlap/z-index: a modal painted below its backdrop is invisible behind it.
function modalBehindBackdrop(modalZ, backdropZ) {
  return Number.isFinite(modalZ) && Number.isFinite(backdropZ) && modalZ < backdropZ;
}
// AABB intersection over {left,top,right,bottom} rects.
function rectsCollide(a, b) {
  if (!a || !b) return false;
  return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
}
function rectArea(r) { return Math.max(0, r.right - r.left) * Math.max(0, r.bottom - r.top); }
// Intersection area as a fraction of the SMALLER rect's area (0..1).
function rectOverlapFraction(a, b) {
  if (!rectsCollide(a, b)) return 0;
  const ix = Math.min(a.right, b.right) - Math.max(a.left, b.left);
  const iy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
  const inter = Math.max(0, ix) * Math.max(0, iy);
  const minA = Math.min(rectArea(a), rectArea(b));
  return minA > 0 ? inter / minA : 0;
}
```

- [ ] **Step 4: Add the DOM block**

In the same file, inside `DETECT()`, insert immediately before `return findings;` (after the Task-4 blocks):

```javascript
  // ---- Overlap / z-index suspicions ----
  // (a) a dialog/overlay whose stacking sits below a sibling backdrop/scrim
  Array.prototype.slice.call(document.querySelectorAll('[role="dialog"], [aria-modal="true"], .modal, .dialog, .overlay'))
    .forEach(function (modal) {
      const mz = parseInt(getComputedStyle(modal).zIndex, 10);
      const parent = modal.parentElement;
      if (!parent) return;
      Array.prototype.slice.call(parent.children).forEach(function (sib) {
        if (sib === modal) return;
        if (!/backdrop|overlay|scrim|mask/i.test(sib.className ? sib.className.toString() : '')) return;
        const bz = parseInt(getComputedStyle(sib).zIndex, 10);
        if (modalBehindBackdrop(mz, bz)) {
          findings.push(suspicion('overlap-modal-behind-backdrop', modal,
            'modal z-index ' + mz + ' below backdrop z-index ' + bz, String(mz)));
        }
      });
    });
  // (b) interactive controls whose boxes collide by more than half the smaller box.
  // Q9: hoist every getBoundingClientRect ONCE before the O(n^2) pair loop — computing rects
  // inside the inner loop forces a layout reflow per pair (O(n^2) reflows) on a read-only sweep.
  // NOTE (precision, stacked-controls FP): legitimately overlapping controls exist — segmented
  // controls, a custom-select trigger layered over a native <select>, overlapping avatar buttons.
  // This is an advisory `ux-suspicion` (routed per the Q1 consumer rule), never a standalone
  // verdict; adjudication (deferred) clears the deliberate cases. Keep the >50% threshold strict.
  const controls = Array.prototype.slice.call(
    document.querySelectorAll('button, a[href], [role="button"], input, select'));
  const rects = controls.map(function (c) { return c.getBoundingClientRect(); });
  for (let i = 0; i < controls.length; i++) {
    const A = controls[i], ra = rects[i];
    if (ra.width === 0 || ra.height === 0) continue;
    for (let j = i + 1; j < controls.length; j++) {
      const B = controls[j], rb = rects[j];
      if (rb.width === 0 || rb.height === 0) continue;
      if (A.contains(B) || B.contains(A)) continue;          // nesting isn't a collision
      if (rectOverlapFraction(ra, rb) > 0.5) {
        findings.push(suspicion('overlap-controls', A, 'overlaps ' + cssPath(B) + ' by >50%', cssPath(B)));
      }
    }
  }
```

- [ ] **Step 5: Extend `module.exports`**

Replace the export object in the dual-entry ternary with the final full set:

```javascript
     (module.exports = {
       relLuminance: relLuminance,
       parseRGB: parseRGB,
       contrastRatio: contrastRatio,
       DETECT: DETECT,
       contentOracleSignal: contentOracleSignal,
       isEmptyRequiredLabel: isEmptyRequiredLabel,
       rawTranslationKeySignal: rawTranslationKeySignal,
       scriptMismatchSignal: scriptMismatchSignal,
       isBrokenImage: isBrokenImage,
       invisibleTextSignal: invisibleTextSignal,
       modalBehindBackdrop: modalBehindBackdrop,
       rectsCollide: rectsCollide,
       rectOverlapFraction: rectOverlapFraction
     }));
```

- [ ] **Step 6: Run to verify pass + full suite green**

Run: `node --check skills/detecting-visual-ux/scripts/ux-detectors.js && bash tests/ux-detectors/run.sh`
Expected: `node --check` exit 0; runner prints `ux-detectors tests: PASS=<N> FAIL=0` (all five families' cores green) and exits 0.

- [ ] **Step 7: Regenerate `dist/` + commit**

```bash
for h in claude codex opencode pi; do bash scripts/build-adapter.sh "$h"; done
bash tests/portability/run.sh && bash scripts/validate-adapters.sh
git add skills/detecting-visual-ux/scripts/ux-detectors.js tests/ux-detectors/run.sh
git commit -m "feat(ux-detectors): overlap + z-index suspicion family"
```

---

## Follow-on (explicitly out of scope here)

- **Adjudication / localization / confidence-by-oracle** (spec §1 steps 2–4, §3) — turns these suspicions into verdicts; a separate effort. This plan deliberately stops at the suspicion boundary.
- **Behavioral / interaction family (family 9)** and the **generative critic (layer 3)** — spec §5, §7; held/separate.
- **SKILL.md restructure + `references/adjudication.md`** (spec §9) — documenting the new families/pipeline; separate. (The *minimal* consumer rule — `axis:"ux-suspicion"` is never a verdict — ships **in this plan**, Task 1 Step 5, so no live false-fails; the full 4-step-pipeline restructure is the deferred piece.)
- **Within-family remaining members** — i18n untranslated-fallback + RTL-correctness (§4.2, acceptance §11.3), content leftover-placeholders, layout truncation/off-viewport/responsive, readability FOUT/absurd-size, assets missing-icons — deferred; this plan lands one representative member per family (see Self-Review).
- **Accuracy-harness fixture seeding + scorer wiring** for the new families (spec §9, §11) — the browser-level recall/precision gate; separate. The DOM walk added here is validated ad hoc via `tools/accuracy-harness/run-baseline.sh --serve` + a `qa-e2e-pilot` browser pass until that fixture lands.

## Self-Review

- **Spec coverage (honest — one representative member per family, not full families):** each task lands **a representative static member** of its family, not the whole family — content/data-rendering (Task 2, spec §4.1), i18n raw-key + script-mismatch (Task 3, spec §4.2), broken-image assets (Task 4, spec §4.5), invisible-text (Task 4, spec §4.4), overlap/z-index (Task 5, spec §4.3). **Explicitly deferred within these families:** i18n untranslated-fallback (`ar` renders `en`) and RTL-correctness (both catalog/cross-state dependent — spec §4.2, acceptance §11.3); content leftover-placeholders / Lorem-ipsum; layout truncation / off-viewport / responsive-breakage; readability FOUT / absurd-font-size; assets missing-icons. Those, plus all catalog-dependent adjudication, are separate deliverables (see Follow-on). The definite-vs-heuristic distinction (spec §2) is honored by emitting *suspicions only* — no family bakes a verdict, and the **Q1 consumer rule** in `SKILL.md` ensures those suspicions are routed to advisory (never a `fail`) until the separate adjudicator assigns confidence (spec §3).
- **Test-strategy linchpin resolved concretely:** no jsdom / no `package.json` exists, so the pure cores are unit-tested in plain Node via a bash runner (`tests/ux-detectors/run.sh`) that `require()`s the dual-mode module — identical mechanism to `tests/frontier/run.sh` and `tests/action-trace/run.sh`. No dependency added. `DETECT()` is additionally exercised end-to-end in Node (Q6) by stubbing its few globals and asserting it returns an array — but **cores ≠ detectors**: the DOM *extraction* around the label/z-index/backdrop/geometry cores stays unverified against real markup until the deferred accuracy-harness fixture lands (see the linchpin note in Global Constraints). No new dependency; the harness browser run remains the real DOM-walk gate.
- **Precision discipline (human-like, adversarial):** every family task ships negative-control core tests that must return `null`/`false` (clean name/money/count/date; correct-script text; loaded image; high-contrast colors; adjacent rects; equal z-index), plus the **adversarial** controls that make the detectors behave like a human tester rather than a linter: prose `The null hypothesis` / `a truly undefined concept` (Q2, value-position anchoring); `GitHub` / `PDF` / a URL on an `ar` page (Q3, brand/acronym/URL exemption); `v1.2.3` / `example.co.uk` / `Component.tsx` (Q4, version/ccTLD/extension rejection). The exemptions live **inside the cores**, so precision is exercised headlessly, not asserted.
- **Placeholder scan:** none — every step carries exact paths, complete code, exact commands, and exact expected output/`kind` strings.
- **Type consistency:** `suspicion(detector, el, evidence, rawSignal)` and `directText(el)` are defined once (Task 2) and reused by Tasks 3–5; `contrastRatio` (Task 1) is reused by `invisibleTextSignal` (Task 4); `rectsCollide`/`rectArea` (Task 5) back `rectOverlapFraction`; the `module.exports` object grows monotonically (with `DETECT` present from Task 1 onward for the Q6 assertion) and every exported name matches its definition and its test call. Core return shapes (`{kind,rawSignal}`, `{rawSignal}`, `{expectedScript,fraction,rawSignal}`, boolean, `{ratio}`, number) are consistent between definition, DOM use, and tests.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-02-static-ux-detectors.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration (superpowers:subagent-driven-development).
2. **Inline Execution** — execute tasks in this session with checkpoints (superpowers:executing-plans).
