# UX Adjudication + Confidence-by-Oracle Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the already-shipped read-only `ux-suspicion` findings into real verdicts — `fail @ FE` with **confidence by oracle strength** (`high` for a definite oracle, `low` for a standards threshold) — or route them to the advisory stream when only a heuristic backs them, via a deterministic adjudication classifier plus the doctrine and skill wiring that consumes it.

**Architecture:** A pure, dependency-free Node core (`adjudicate.js`, dual-mode like `ux-detectors.js`) holds a data-driven **detector → oracle-grade** table and an `adjudicate(suspicion, oracleInputs)` classifier that returns either a verdict object (`{verdict, suspectedLayer, confidence, family, reason}`) or an advisory object (`{advisory:true, reason}`). The agent (via `detecting-visual-ux/SKILL.md`) runs the existing detectors, localizes each suspicion to source, gathers the oracle inputs the classifier needs (i18n-catalog lookup, the `.qa/ux-conventions.json` known-deliberate list, a `hasSource` black-box flag), and calls the classifier — it never bakes a verdict in prose. This is the plugin's existing oracle-vs-observation discipline (today used for backend correctness) generalized to the UI/UX plane, per the human-eye-UX design (spec §1–§4) and ADR-0019.

**Tech Stack:** Bash + dependency-free browser/Node JavaScript (injected via `browser_evaluate` / `require()`d in tests), `jq`-preferred/`python3`-fallback for any JSON shell handling. No new runtime dependency (no jsdom, no `package.json`). Tests are plain-Node pure-core unit tests driven by a bash runner, identical mechanism to `tests/ux-detectors/run.sh`.

## Global Constraints

- **Verdicts are exactly `pass | fail | blocked | deferred | error`; confidence is `high | low`; suspected layer is exactly one of `FE | route | service | migration | DB`.** This engine only ever emits `fail @ FE` (a UX presentation fault is always the frontend layer) or routes to advisory. Never a sixth verdict, never `warn`/`skip`/`partial`.
- **Confidence by oracle strength (spec §3, supersedes ADR-0007's blanket-low):** `high` = confirmed against a **definite oracle** (the DOM/screenshot itself for content faults, a raw i18n key, an `ar`-catalog gap, a spec/design-token divergence — the expected value comes from the domain/design contract, not backend code). `low` = a **standards threshold** with no spec reconciliation (WCAG contrast, target-size). This is the ONE unified `confidence:low` definition ("the expectation is not grounded in a spec/domain oracle") already recorded in `CONTEXT.md`'s `Confidence` entry — do not introduce a second meaning.
- **The oracle is the spec/domain rule, never the implementation itself (CONTEXT.md invariant).** "In the catalog" is the implementation's own data → a **deliberateness heuristic**, not proof of correctness. A heuristic-only suspicion becomes a verdict ONLY when a definite oracle corroborates it; otherwise it stays advisory.
- **Fully autonomous — no in-loop HITL (spec §6, decision 5).** Once Verify starts, the agent adjudicates and renders verdicts with no operator interruption. It never stops to ask "is this a bug?". A genuinely ambiguous case the code can't resolve is **advisory**, never a blocking prompt. Convention/known-deliberate data is learned by the agent from the code it already reads, into `.qa/ux-conventions.json`.
- **Degrade honestly on a black-box target (no repo/source, spec §2 last ¶).** Definite-DOM-oracle findings (`NaN`/`undefined`/raw-key/broken-image/invisible-text) need no source — the DOM IS the evidence → full confidence even black-box. Findings needing code/catalog adjudication degrade to **advisory** (observed-only) — never silently dropped.
- **Read-only.** Adjudication reads the DOM findings, the catalog, and `.qa/ux-conventions.json`; it appends to `.qa/ux-conventions.json` only (durable reference data, ADR-0002-clean — NOT per-run run-state, never the agent's personal memory).
- **`.qa/ux-conventions.json` is project-level durable reference data** at the project root (sibling to `.qa/config.json`), NOT under `.qa/runs/<id>/`. Missing file ≡ empty lists. Headless/CI runs are unaffected; human curation is possible but never required.
- **jq-preferred, python3-fallback, die-if-neither** for any shell JSON; honor `QA_ENGINE`; no `grep -P`, no `perl`, no new `node` dependency (the pure cores are dependency-free JS).
- **Portability:** all of this is **core** (skill body + scripts, copied verbatim into `dist/<h>/` by the generator). No per-harness binding is needed for adjudication (layer-3 vision, which does need one, is a separate effort). `validate-adapters.sh` byte-oracle + the portability test must stay green.
- **No Claude/Anthropic attribution** in any commit message; no `Co-Authored-By` trailer. Never commit `dist/`.

## Scope: this is sub-plan A of three

The human-eye-UX design (`docs/specs/2026-09-02-human-eye-ux-detection-design.md`, ADR-0019) is a multi-subsystem engine. It is split into three independently-shippable efforts:

- **A — Adjudication + confidence-by-oracle engine (THIS PLAN).** Consumes the shipped static suspicions; produces verdicts/advisory. Buildable now (suspicions already emit; the i18n mechanism map already ships from `detecting-stack-profile`).
- **B — Behavioral/interaction family 9** (spec §7): a new `detecting-interaction-ux` skill on `walking-multistep-flows` (overlay-stack invariants, two-criteria boundary). Its verdicts flow through THIS plan's classifier — hence A first.
- **C — Generative critic (layer 3, vision-gated) + accuracy-harness UI/UX taxonomy fixture + scorer gate** (spec §5, §9, §11): the recall/precision measurement and the long-tail multimodal read. Separate; needs a per-harness vision binding.

This plan produces working, testable software on its own: after it lands, every shipped static suspicion is adjudicated to a verdict-or-advisory with confidence-by-oracle-strength.

## Self-grilled decisions (frontier questions, my own recommended answers applied)

1. **Decomposition** → split into A/B/C, build **A first** (keystone dependency for B). *Applied.*
2. **Adjudicator = deterministic script vs agent prose** → a deterministic pure-Node classifier core (detector→grade→verdict/confidence/advisory); the agent only localizes + gathers oracle inputs. Matches the plugin's "deterministic where possible, testable headless" discipline. *Applied (Task 1).*
3. **`invisible-text` (fg≈bg) oracle grade** → **definite-dom → high.** The detector only fires when foreground ≈ background (essentially the same color), so the text is unambiguously unreadable — the DOM colors ARE the evidence, no WCAG-threshold judgment. (Contrast/target-size stay `low`; invisible-text is qualitatively "cannot be read at all," like `NaN`.)
4. **`modal-behind-backdrop` grade** → **definite-dom → high** (a modal rendered behind its own overlay is never intentional; the z-values are the evidence). Generic `overlap` → **heuristic → advisory** (adjacent/overlapping rects can be deliberate).
5. **`raw-iso` grade** → **definite-content → high** per spec §4.1, relying on the detector's existing value-position anchoring (a raw ISO in a user-facing value cell is a formatting bug).
6. **`.qa/ux-conventions.json` location** → project root, sibling to `.qa/config.json` (durable cross-run reference data, ADR-0002-clean, explicitly not per-run).
7. **"App convention = full-translation" (untranslated-fallback verdict vs advisory)** → derive it autonomously from **catalog completeness**: if the `ar` catalog is otherwise-complete (all/most keys translated) and this one value is Latin `== en` prose, convention=full-translation → `fail @ FE, high` (a gap in an otherwise-complete catalog); if the catalog is sparsely translated → advisory. Deterministic from catalog stats fed as an oracle input.
8. **Known-deliberate match key** → `{detector, rawSignal}` (a stable structural signature), NOT a volatile full CSS selector path — so a pattern judged deliberate stays matched across runs and DOM churn.

---

## File Structure

- `skills/detecting-visual-ux/scripts/adjudicate.js` **(new)** — dual-mode dependency-free module. Exports the `ORACLE_GRADES` table (detector-prefix → grade) and pure functions `oracleGradeFor(detector)`, `adjudicate(suspicion, oracleInputs)`, `adjudicateI18n(catalogResult, catalogCompleteness)`, `isKnownDeliberate(suspicion, knownDeliberate)`, `deliberateKey(suspicion)`. One responsibility: classify a suspicion into a verdict or advisory. No DOM, no I/O.
- `skills/detecting-visual-ux/references/adjudication.md` **(new)** — the oracle-vs-heuristic doctrine + the per-family oracle table (spec §2, §4 table) the classifier encodes; the human/agent-readable companion to `ORACLE_GRADES`.
- `skills/detecting-visual-ux/scripts/ux-conventions.sh` **(new)** — read the `.qa/ux-conventions.json` known-deliberate list (emit as a JSON array for the classifier) and append a newly-judged-deliberate entry (idempotent, deduped by `deliberateKey`). jq-preferred/python3-fallback.
- `tests/ux-adjudicate/run.sh` **(new)** — pure-core unit tests for `adjudicate.js` (bash runner that `require()`s the module), mirroring `tests/ux-detectors/run.sh`.
- `tests/ux-conventions/run.sh` **(new)** — read/append/dedupe/missing-file tests for `ux-conventions.sh`, both engines.
- `skills/detecting-visual-ux/SKILL.md` **(modify)** — replace the "suspicions are always advisory / adjudication is a later effort" rule (lines ~60–67) with the real 4-step pipeline (detect → localize → adjudicate → classify): run detectors, localize each suspicion, gather oracle inputs, call the classifier, route to verdict or advisory. Document confidence-by-oracle-strength and the `.qa/ux-conventions.json` read/append. Keep < 500 lines (currently 200) via `references/adjudication.md`.
- `docs/adr/0019-human-eye-ux-detection-engine.md` **(modify)** — an implementation note: the adjudication + confidence-by-oracle layer (sub-plan A) landed; the behavioral family (B) and generative critic + accuracy-harness fixture (C) remain deferred.
- `CONTEXT.md` **(modify, only if needed)** — confirm the `Confidence` entry already carries the unified definition (it does, per inspection); add `oracle grade` / `adjudication` glossary terms if not present. No dual-meaning may be introduced.

---

## Task 1: Oracle-grade table + `adjudicate()` classifier core

**Files:**
- Create: `skills/detecting-visual-ux/scripts/adjudicate.js`
- Create: `skills/detecting-visual-ux/references/adjudication.md`
- Test: `tests/ux-adjudicate/run.sh`

**Interfaces:**
- Consumes: the shipped suspicion shape from `ux-detectors.js` — `{ detector: string, axis: 'ux-suspicion', selector: string, evidence: string, rawSignal: string }` (detector names observed today: `content-null`, `content-undefined`, `content-nan`, `content-invalid-date`, `content-object-object`, `content-dollar-nan`, `content-raw-interp`, `content-raw-iso`, `content-empty-required-label`, `i18n-raw-key`, `i18n-script-mismatch`, `broken-image`, `invisible-text`, `overlap`, `modal-behind-backdrop`).
- Produces (later tasks + SKILL.md rely on these exact names/shapes):
  - `oracleGradeFor(detector: string) -> 'definite-dom' | 'definite-catalog' | 'standards' | 'heuristic'`
  - `adjudicate(suspicion, oracleInputs) -> {verdict:'fail', suspectedLayer:'FE', confidence:'high'|'low', family:string, reason:string} | {advisory:true, reason:string}` where `oracleInputs = { hasSource?:boolean, catalogResult?:string, catalogCompleteness?:number, knownDeliberate?:Array, corroborated?:boolean }` (all optional; absent ≡ black-box/none).
  - `deliberateKey(suspicion) -> string` (`"<detector>␟<rawSignal>"`).
  - `isKnownDeliberate(suspicion, knownDeliberate) -> boolean`.

- [ ] **Step 1: Write the failing tests** (`tests/ux-adjudicate/run.sh`)

Model it on `tests/ux-detectors/run.sh`: a bash runner that resolves `node`, `require()`s `adjudicate.js`, and drives the pure functions via `-e` one-liners. Include a `call`/`field` helper pair (print `JSON.stringify(result)` and a single field). Assertions:

```bash
#!/usr/bin/env bash
# Tests for adjudicate.js pure classifier (DOM-free, plain Node — no jsdom).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$DIR/../../skills/detecting-visual-ux/scripts/adjudicate.js"
NODE="$(command -v node || true)"; [ -z "$NODE" ] && { echo "SKIP: node not found"; exit 0; }
pass=0; fail=0
# field <fn> <jsonArgsArray> <key>  -> prints result[key] ("null" when result null)
field() { "$NODE" -e '
  const m=require(process.argv[1]); const [fn,args,key]=[process.argv[2],JSON.parse(process.argv[3]),process.argv[4]];
  const r=m[fn](...args); process.stdout.write(r==null?"null":String(r[key]));
' "$MOD" "$1" "$2" "$3"; }
call() { "$NODE" -e '
  const m=require(process.argv[1]); const [fn,args]=[process.argv[2],JSON.parse(process.argv[3])];
  const r=m[fn](...JSON.parse(process.argv[3])); process.stdout.write(r==null?"null":JSON.stringify(r));
' "$MOD" "$1" "$2"; }
check() { local desc="$1" got="$2" want="$3"; if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc  got=[$got] want=[$want]"; fi; }

# --- oracleGradeFor: the table ---
check "content-nan is definite-dom"      "$(field oracleGradeFor '["content-nan"]' '')"        ""   # placeholder; use call below
check "grade content-nan"     "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("content-nan"))' "$MOD")"      "definite-dom"
check "grade i18n-raw-key"    "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("i18n-raw-key"))' "$MOD")"     "definite-dom"
check "grade broken-image"    "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("broken-image"))' "$MOD")"     "definite-dom"
check "grade invisible-text"  "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("invisible-text"))' "$MOD")"   "definite-dom"
check "grade modal-behind-backdrop" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("modal-behind-backdrop"))' "$MOD")" "definite-dom"
check "grade content-raw-iso" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("content-raw-iso"))' "$MOD")"  "definite-dom"
check "grade i18n-script-mismatch" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("i18n-script-mismatch"))' "$MOD")" "definite-catalog"
check "grade overlap"         "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("overlap"))' "$MOD")"          "heuristic"
check "grade unknown->heuristic" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).oracleGradeFor("something-new"))' "$MOD")" "heuristic"

# --- adjudicate: definite-dom -> fail@FE high, needs no source ---
check "nan verdict"    "$(field adjudicate '[{"detector":"content-nan","rawSignal":"NaN"},{}]' 'verdict')"    "fail"
check "nan layer"      "$(field adjudicate '[{"detector":"content-nan","rawSignal":"NaN"},{}]' 'suspectedLayer')" "FE"
check "nan conf high"  "$(field adjudicate '[{"detector":"content-nan","rawSignal":"NaN"},{}]' 'confidence')" "high"
check "raw-key high even black-box" "$(field adjudicate '[{"detector":"i18n-raw-key","rawSignal":"deliverables.title"},{"hasSource":false}]' 'confidence')" "high"
check "invisible-text high" "$(field adjudicate '[{"detector":"invisible-text","rawSignal":"1.02"},{}]' 'confidence')" "high"

# --- adjudicate: heuristic (overlap) -> advisory unless corroborated ---
check "overlap advisory"      "$(field adjudicate '[{"detector":"overlap","rawSignal":"0.30"},{}]' 'advisory')"   "true"
check "overlap corroborated->verdict" "$(field adjudicate '[{"detector":"overlap","rawSignal":"0.30"},{"corroborated":true}]' 'verdict')" "fail"
check "overlap corroborated conf" "$(field adjudicate '[{"detector":"overlap","rawSignal":"0.30"},{"corroborated":true}]' 'confidence')" "high"

# --- adjudicate: definite-catalog -> depends on catalogResult ---
check "i18n gap -> fail high"  "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"missing"}]' 'confidence')" "high"
check "i18n legit-latin -> null (deliberate, dropped)" "$(call adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"GitHub"},{"catalogResult":"present-latin-legit"}]')" "null"
check "i18n suspected-untranslated sparse -> advisory" "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"present-latin-eq-en","catalogCompleteness":0.2}]' 'advisory')" "true"
check "i18n suspected-untranslated in complete catalog -> fail high" "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"present-latin-eq-en","catalogCompleteness":0.95}]' 'confidence')" "high"
check "i18n no-catalog (black-box) -> advisory" "$(field adjudicate '[{"detector":"i18n-script-mismatch","rawSignal":"Save"},{"catalogResult":"no-catalog"}]' 'advisory')" "true"

# --- known-deliberate short-circuit: any grade -> dropped (null) ---
KD='[{"detector":"content-raw-iso","rawSignal":"2026-09-02T00:00:00Z"}]'
check "known-deliberate -> null" "$(call adjudicate "[{\"detector\":\"content-raw-iso\",\"rawSignal\":\"2026-09-02T00:00:00Z\"},{\"knownDeliberate\":$KD}]")" "null"
check "deliberateKey shape" "$("$NODE" -e 'process.stdout.write(require(process.argv[1]).deliberateKey({detector:"content-nan",rawSignal:"NaN"}))' "$MOD")" $'content-nan␟NaN'

echo "ux-adjudicate: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/ux-adjudicate/run.sh`
Expected: FAIL (module missing / `Cannot find module adjudicate.js`).

- [ ] **Step 3: Write `adjudicate.js`** (dual-mode, dependency-free)

```javascript
// adjudicate.js — pure UX-suspicion classifier (spec §2–§4, ADR-0019).
// Dual-mode like ux-detectors.js: exports pure functions for Node tests / the
// agent's adjudication step. NO DOM, NO I/O. The oracle is the spec/domain rule,
// never the implementation itself — "in the catalog" is only a deliberateness
// heuristic, so a catalog-present Latin value never self-certifies (spec §4.2, Q1).
(function () {
  'use strict';

  // detector-prefix -> oracle grade. Longest-prefix wins so specific detector
  // ids override family defaults. Editing THIS table changes classification —
  // it is the single source the doctrine (references/adjudication.md) documents.
  var ORACLE_GRADES = [
    // definite DOM oracle: the DOM itself is the evidence; needs no source; -> high.
    ['content-', 'definite-dom'],
    ['i18n-raw-key', 'definite-dom'],
    ['broken-image', 'definite-dom'],
    ['invisible-text', 'definite-dom'],       // fg≈bg: unreadable, unambiguous (grill Q3)
    ['modal-behind-backdrop', 'definite-dom'],// z-inversion of a modal vs its own backdrop (grill Q4)
    // definite but catalog-dependent: verdict only once the catalog oracle resolves.
    ['i18n-script-mismatch', 'definite-catalog'],
    ['i18n-', 'definite-catalog'],
    // standards threshold (WCAG): a real verdict but confidence low (no spec oracle).
    ['contrast', 'standards'],
    ['target-size', 'standards'],
    // everything else (generic overlap, layout heuristics): advisory unless corroborated.
    ['overlap', 'heuristic']
  ];

  function oracleGradeFor(detector) {
    var best = null, bestLen = -1;
    for (var i = 0; i < ORACLE_GRADES.length; i++) {
      var pfx = ORACLE_GRADES[i][0];
      if (detector.indexOf(pfx) === 0 && pfx.length > bestLen) { best = ORACLE_GRADES[i][1]; bestLen = pfx.length; }
    }
    return best || 'heuristic';
  }

  var SEP = '␟'; // symbol-for-unit-separator: never appears in a detector id or rawSignal
  function deliberateKey(s) { return String(s.detector) + SEP + String(s.rawSignal == null ? '' : s.rawSignal); }
  function isKnownDeliberate(s, knownDeliberate) {
    if (!knownDeliberate || !knownDeliberate.length) return false;
    var k = deliberateKey(s);
    for (var i = 0; i < knownDeliberate.length; i++) { if (deliberateKey(knownDeliberate[i]) === k) return true; }
    return false;
  }

  function failHigh(family, reason) { return { verdict: 'fail', suspectedLayer: 'FE', confidence: 'high', family: family, reason: reason }; }
  function failLow(family, reason)  { return { verdict: 'fail', suspectedLayer: 'FE', confidence: 'low',  family: family, reason: reason }; }
  function advisory(reason)         { return { advisory: true, reason: reason }; }

  // Catalog adjudication for the i18n script-mismatch / raw-key-with-catalog path
  // (spec §4.2 table). catalogResult is one of:
  //   'missing'              key absent in target locale        -> definite gap  -> fail high
  //   'empty'                key present but empty in target     -> definite gap  -> fail high
  //   'present-latin-legit'  Latin value that is a proper-noun/brand/URL/code    -> deliberate -> null
  //   'present-latin-eq-en'  Latin value == the en string, reads as prose -> suspected untranslated
  //   'present-translated'   correctly localized                 -> pass (no finding) -> null
  //   'no-catalog'           black-box / no catalog located      -> observed-only -> advisory
  // catalogCompleteness (0..1): fraction of target-locale keys that are translated.
  // A suspected-untranslated string is a VERDICT only where the app's convention is
  // full-translation, derived autonomously from an otherwise-complete catalog (grill Q7).
  function adjudicateI18n(catalogResult, catalogCompleteness) {
    switch (catalogResult) {
      case 'missing':
      case 'empty':
        return failHigh('i18n', 'i18n key ' + catalogResult + ' in the target locale catalog (definite gap)');
      case 'present-latin-legit':
      case 'present-translated':
        return null; // deliberate / correct — no finding
      case 'present-latin-eq-en':
        if (typeof catalogCompleteness === 'number' && catalogCompleteness >= 0.9) {
          return failHigh('i18n', 'untranslated fallback: target value equals the en string in an otherwise-complete catalog (convention = full-translation)');
        }
        return advisory('suspected untranslated: target value is Latin and equals en, but the catalog is only partly translated — advisory, not a verdict');
      case 'no-catalog':
      default:
        return advisory('script-mismatch observed but no catalog to adjudicate against (black-box) — advisory');
    }
  }

  // The classifier. Returns a verdict object, an advisory object, or null (dropped:
  // known-deliberate, or a catalog-confirmed deliberate/correct value).
  function adjudicate(suspicion, oracleInputs) {
    oracleInputs = oracleInputs || {};
    if (isKnownDeliberate(suspicion, oracleInputs.knownDeliberate)) return null; // agent already judged this intentional (spec §6)
    var grade = oracleGradeFor(suspicion.detector);
    switch (grade) {
      case 'definite-dom':
        // DOM/screenshot IS the evidence — full confidence even black-box (spec §2 degrade ¶).
        return failHigh(suspicion.detector.split('-')[0] === 'i18n' ? 'i18n' : 'content-or-visual',
          'definite DOM oracle: ' + suspicion.detector + ' (' + suspicion.rawSignal + ')');
      case 'definite-catalog':
        return adjudicateI18n(oracleInputs.catalogResult, oracleInputs.catalogCompleteness);
      case 'standards':
        return failLow('standards', 'standards-threshold oracle (WCAG): ' + suspicion.detector);
      case 'heuristic':
      default:
        // Heuristic-only: advisory UNLESS a definite oracle corroborated it (spec §2).
        if (oracleInputs.corroborated) return failHigh('heuristic-corroborated', 'heuristic suspicion corroborated by a definite oracle: ' + suspicion.detector);
        return advisory('heuristic-only suspicion (' + suspicion.detector + ') — advisory unless a definite oracle corroborates');
    }
  }

  var api = { ORACLE_GRADES: ORACLE_GRADES, oracleGradeFor: oracleGradeFor, deliberateKey: deliberateKey, isKnownDeliberate: isKnownDeliberate, adjudicateI18n: adjudicateI18n, adjudicate: adjudicate };
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
  else if (typeof window !== 'undefined') { window.__adjudicate = api; }
})();
```

- [ ] **Step 4: Write `references/adjudication.md`** — the doctrine + per-family oracle table (the human/agent-readable companion to `ORACLE_GRADES`).

Cover: the oracle-vs-heuristic split (spec §2); the four grades (`definite-dom`, `definite-catalog`, `standards`, `heuristic`) and what each yields; the confidence-by-oracle-strength model (spec §3); the i18n §4.2 adjudication table verbatim (including the "in-the-catalog is not self-certifying" rule and the completeness-derived full-translation convention); the black-box degrade rule; the known-deliberate short-circuit; and a one-line note that `adjudicate.js`'s `ORACLE_GRADES` is the executable form of this table (edit both together).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/ux-adjudicate/run.sh`
Expected: `ux-adjudicate: PASS=<n> FAIL=0`. Also `node --check skills/detecting-visual-ux/scripts/adjudicate.js`.

- [ ] **Step 6: Commit**

```bash
git add skills/detecting-visual-ux/scripts/adjudicate.js skills/detecting-visual-ux/references/adjudication.md tests/ux-adjudicate/run.sh
git commit -m "feat(ux): oracle-grade table + adjudicate() classifier (suspicion -> verdict-or-advisory, confidence by oracle strength)"
```

---

## Task 2: i18n catalog-result derivation helper (the oracle input)

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/adjudicate.js` — add `deriveCatalogResult(entry)` pure helper.
- Test: `tests/ux-adjudicate/run.sh` — extend with the derivation cases.

**Interfaces:**
- Consumes: a per-suspicion **catalog lookup record** the agent assembles when localizing an `i18n-script-mismatch`/`i18n-raw-key` to the catalog — `{ presentInTarget:boolean, targetValue:string|null, enValue:string|null, isTechnical:boolean }` (`isTechnical` = the value is a proper-noun/brand/URL/code/number, reusing `ux-detectors.js`'s existing exemption reflex; the agent sets it from the same signal the detector used).
- Produces: `deriveCatalogResult(entry) -> 'missing' | 'empty' | 'present-latin-legit' | 'present-latin-eq-en' | 'present-translated' | 'no-catalog'` — the exact string `adjudicateI18n` consumes. Keeps the catalog-to-grade mapping in ONE tested place instead of agent prose.

- [ ] **Step 1: Write the failing tests** (append to `tests/ux-adjudicate/run.sh`)

```bash
# --- deriveCatalogResult: the catalog record -> canonical result string ---
dcr() { "$NODE" -e 'process.stdout.write(String(require(process.argv[1]).deriveCatalogResult(JSON.parse(process.argv[2]))))' "$MOD" "$1"; }
check "no catalog record -> no-catalog" "$(dcr 'null')" "no-catalog"
check "absent key -> missing"        "$(dcr '{"presentInTarget":false}')" "missing"
check "present empty -> empty"       "$(dcr '{"presentInTarget":true,"targetValue":""}')" "empty"
check "present technical Latin -> legit" "$(dcr '{"presentInTarget":true,"targetValue":"GitHub","enValue":"GitHub","isTechnical":true}')" "present-latin-legit"
check "present Latin == en prose -> eq-en" "$(dcr '{"presentInTarget":true,"targetValue":"Save","enValue":"Save","isTechnical":false}')" "present-latin-eq-en"
check "present Arabic (differs from en, non-latin) -> translated" "$(dcr '{"presentInTarget":true,"targetValue":"حفظ","enValue":"Save","isTechnical":false}')" "present-translated"
check "present Latin != en (localized to another latin lang) -> translated" "$(dcr '{"presentInTarget":true,"targetValue":"Enregistrer","enValue":"Save","isTechnical":false}')" "present-translated"
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash tests/ux-adjudicate/run.sh` — Expected: FAIL on the `deriveCatalogResult` cases (function undefined).

- [ ] **Step 3: Implement `deriveCatalogResult`** in `adjudicate.js` (add to the module + `api`):

```javascript
  // A Latin-script test that mirrors ux-detectors.js's script reflex: true when the
  // string contains at least one A–Z/a–z run and no non-Latin letter script.
  function isLatinProse(s) {
    if (!s) return false;
    if (!/[A-Za-z]/.test(s)) return false;
    // any letter from a major non-Latin script -> not "Latin prose"
    return !/[؀-ۿЀ-ӿ一-鿿぀-ヿ가-힯]/.test(s);
  }

  function deriveCatalogResult(entry) {
    if (!entry) return 'no-catalog';
    if (!entry.presentInTarget) return 'missing';
    var tv = entry.targetValue;
    if (tv == null || String(tv).trim() === '') return 'empty';
    if (entry.isTechnical) return 'present-latin-legit';
    // Latin value equal to en, reading as prose -> suspected untranslated fallback.
    if (isLatinProse(tv) && entry.enValue != null && String(tv).trim() === String(entry.enValue).trim()) return 'present-latin-eq-en';
    // Latin but a legitimately different value (localized to another Latin language), or non-Latin script -> translated.
    return 'present-translated';
  }
```
Add `deriveCatalogResult: deriveCatalogResult` and `isLatinProse: isLatinProse` to the `api` object.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/ux-adjudicate/run.sh` — Expected: `FAIL=0`. `node --check` clean.

- [ ] **Step 5: Commit**

```bash
git add skills/detecting-visual-ux/scripts/adjudicate.js tests/ux-adjudicate/run.sh
git commit -m "feat(ux): deriveCatalogResult — catalog lookup record -> canonical i18n adjudication result"
```

---

## Task 3: `.qa/ux-conventions.json` known-deliberate read + append helper

**Files:**
- Create: `skills/detecting-visual-ux/scripts/ux-conventions.sh`
- Test: `tests/ux-conventions/run.sh`

**Interfaces:**
- `ux-conventions.sh read [<path>]` → prints the `knownDeliberate` JSON array (`[]` when the file is missing or has no such key) to stdout. Default `<path>` = `.qa/ux-conventions.json`.
- `ux-conventions.sh add <detector> <rawSignal> [<path>]` → appends `{detector,rawSignal}` to `knownDeliberate` **idempotently** (deduped by the `<detector>␟<rawSignal>` key), creating the file (`{"knownDeliberate":[...],"conventions":[]}`) if absent. Prints a one-line confirmation. Never rewrites `conventions`.
- Feeds Task 1's `adjudicate(..., {knownDeliberate})`.

- [ ] **Step 1: Write the failing tests** (`tests/ux-conventions/run.sh`)

Both engines (`QA_ENGINE=jq` and `QA_ENGINE=python3`); use a temp dir per case:

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../skills/detecting-visual-ux/scripts/ux-conventions.sh"
pass=0; fail=0
check(){ local d="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d got=[$g] want=[$w]"; fi; }
run_engine() {
  local ENG="$1"; local T; T="$(mktemp -d)"; local F="$T/ux-conventions.json"
  check "$ENG missing-file read -> []" "$(QA_ENGINE=$ENG bash "$SH" read "$F")" "[]"
  QA_ENGINE=$ENG bash "$SH" add content-raw-iso "2026-09-02T00:00:00Z" "$F" >/dev/null
  check "$ENG after add len 1" "$(QA_ENGINE=$ENG bash "$SH" read "$F" | ( command -v jq >/dev/null && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'))" "1"
  QA_ENGINE=$ENG bash "$SH" add content-raw-iso "2026-09-02T00:00:00Z" "$F" >/dev/null   # dup
  check "$ENG dedupe still len 1" "$(QA_ENGINE=$ENG bash "$SH" read "$F" | ( command -v jq >/dev/null && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'))" "1"
  QA_ENGINE=$ENG bash "$SH" add overlap "0.30" "$F" >/dev/null
  check "$ENG second distinct -> len 2" "$(QA_ENGINE=$ENG bash "$SH" read "$F" | ( command -v jq >/dev/null && jq 'length' || python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'))" "2"
  check "$ENG conventions key preserved" "$(QA_ENGINE=$ENG python3 -c 'import json;print("conventions" in json.load(open("'"$F"'")))' 2>/dev/null || echo True)" "True"
  rm -rf "$T"
}
if command -v jq >/dev/null 2>&1; then run_engine jq; fi
if command -v python3 >/dev/null 2>&1; then run_engine python3; fi
echo "ux-conventions: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/ux-conventions/run.sh` — Expected: FAIL (script missing).

- [ ] **Step 3: Implement `ux-conventions.sh`** — follow the header/engine-resolution pattern of the existing scripts (`has_jq`/`has_py`/`die`, honor `QA_ENGINE`, atomic temp→rename write). Read returns `.knownDeliberate // []`; add builds the entry, dedupes by `detector+␟+rawSignal`, preserves `conventions`, writes atomically. Include a usage/`die` on an unknown subcommand.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/ux-conventions/run.sh` — Expected `FAIL=0`. `bash -n skills/detecting-visual-ux/scripts/ux-conventions.sh`. Validate the emitted JSON parses.

- [ ] **Step 5: Commit**

```bash
git add skills/detecting-visual-ux/scripts/ux-conventions.sh tests/ux-conventions/run.sh
git commit -m "feat(ux): .qa/ux-conventions.json known-deliberate read + idempotent append helper"
```

---

## Task 4: SKILL.md — wire the detect→localize→adjudicate→classify pipeline

**Files:**
- Modify: `skills/detecting-visual-ux/SKILL.md`

**Interfaces:**
- Consumes: `adjudicate.js` (`adjudicate`, `deriveCatalogResult`), `ux-conventions.sh` (`read`/`add`) from Tasks 1–3; the existing `ux-detectors.js` DETECT output; the i18n mechanism map from `detecting-stack-profile`.
- Produces: the agent-facing procedure that turns each `ux-suspicion` into a `fail @ FE` (confidence by oracle strength) or an advisory-stream entry — replacing the interim "always advisory" rule.

- [ ] **Step 1: Replace the interim consumer rule** (SKILL.md ~lines 60–67). The old text says `axis:"ux-suspicion"` entries are never verdicts and "adjudication … is a separate, later effort." Replace with the 4-step pipeline (spec §1):
  1. **Detect** — run `ux-detectors.js` (unchanged): collect `ux-objective` (Step 3, existing) and `ux-suspicion` findings.
  2. **Localize** — for each suspicion, map selector→source (component/style/i18n-key/data-field) via `analyzing-feature-ui`'s surface→endpoint map extended to surface→component/style/catalog. For an `i18n-*` suspicion, resolve the key against the catalog (from the stack-profile i18n mechanism map) into the `{presentInTarget,targetValue,enValue,isTechnical}` record; for `catalogCompleteness`, use the fraction of target-locale keys that are translated.
  3. **Adjudicate** — read the known-deliberate list once per run (`ux-conventions.sh read`); for each suspicion call `adjudicate(suspicion, {hasSource, catalogResult: deriveCatalogResult(record), catalogCompleteness, knownDeliberate, corroborated})`.
  4. **Classify/route** — a returned verdict object → a real `fail @ FE` criterion finding with its `confidence` (high/low) verbatim and `reason` as the message; an `{advisory:true}` object → the `## Advisory (ux-suspicions)` stream (never a verdict, never gated); `null` → dropped (deliberate/correct — no finding). When the agent reads the code and judges a flagged pattern intentional, it records it via `ux-conventions.sh add <detector> <rawSignal>` so it isn't re-flagged next run (autonomous, no HITL).

- [ ] **Step 2: Document confidence-by-oracle-strength** — a short subsection: `high` = definite oracle (content fault, raw key, catalog gap, spec/design-token, invisible-text, modal-behind-backdrop); `low` = standards threshold (WCAG contrast/target-size, retained from ADR-0007). One unified `confidence:low` meaning (link `CONTEXT.md`). Note the black-box degrade: definite-DOM findings keep full confidence with no source; catalog/code-adjudication findings degrade to advisory.

- [ ] **Step 3: Update the mini-evals** — add: (U-adj-1) raw key `deliverables.title` → `fail @ FE, high`; (U-adj-2) `ar` label whose catalog value is intentionally Latin (`GitHub`) → no finding (deliberate); (U-adj-3) untranslated fallback (`ar` renders `en`) in an otherwise-complete catalog → `fail @ FE, high`; (U-adj-4) generic overlap with no corroborating oracle → advisory only. Point each at the acceptance items in spec §11.

- [ ] **Step 4: Keep < 500 lines + reference depth one.** Move the full oracle table to `references/adjudication.md` (Task 1) and link it; SKILL.md carries only the procedure + the four mini-evals. Verify: `wc -l skills/detecting-visual-ux/SKILL.md` < 500. Confirm frontmatter unchanged (name/description only; name still `detecting-visual-ux`).

- [ ] **Step 5: Regenerate + gates.**

Run: `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (byte-oracle + residual-token gate, exit 0); the portability test; and re-run `tests/ux-adjudicate/run.sh` + `tests/ux-conventions/run.sh` (no regression).

- [ ] **Step 6: Commit**

```bash
git add skills/detecting-visual-ux/SKILL.md
git commit -m "feat(ux): wire detect->localize->adjudicate->classify in detecting-visual-ux (suspicions become verdicts by oracle strength)"
```

---

## Task 5: ADR-0019 implementation note + CONTEXT terms

**Files:**
- Modify: `docs/adr/0019-human-eye-ux-detection-engine.md`
- Modify: `CONTEXT.md` (only if terms are missing)

**Interfaces:** none (docs only).

- [ ] **Step 1: ADR-0019 implementation note** — following ADR-0020's pattern, add a dated `**Implementation note (2026-09-03):**` paragraph: sub-plan A (adjudication + confidence-by-oracle: `adjudicate.js`, `references/adjudication.md`, `ux-conventions.sh`, the SKILL.md pipeline) landed; the behavioral/interaction family (B) and the generative critic + accuracy-harness taxonomy fixture/scorer gate (C) remain deferred. State honestly that the ≥95% recall gate (§11) is NOT yet measured — it lands with effort C's fixture.

- [ ] **Step 2: CONTEXT.md terms** — confirm the `Confidence` entry already carries the unified "not grounded in a spec/domain oracle" definition (it does — no change needed unless it drifted). Add two glossary terms in the house format (bold term + definition + `_Avoid_:`) if absent: **Oracle grade** (`definite-dom | definite-catalog | standards | heuristic` — the strength of the expectation source, deciding verdict-vs-advisory and high-vs-low; not a verdict, not confidence) and **Adjudication** (the deliberate-vs-bug step: a suspicion becomes a verdict only when a definite oracle backs it, else advisory — the anti-false-positive spine). Keep sub-state/verdict/confidence vocab intact; oracle grade is an internal classification input, never a verdict.

- [ ] **Step 3: Gates + commit**

Run: `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (exit 0 — docs shouldn't affect the byte-oracle, but confirm).

```bash
git add docs/adr/0019-human-eye-ux-detection-engine.md CONTEXT.md
git commit -m "docs(ux): ADR-0019 implementation note (adjudication landed; behavioral family + critic/fixture deferred) + CONTEXT terms"
```

---

## Self-Review

**1. Spec coverage.**
- §1 pipeline (detect→localize→adjudicate→classify) → Task 4 wires all four; the deterministic adjudicate/classify is Tasks 1–2. ✅
- §2 oracle-vs-heuristic circularity fix → Task 1 `ORACLE_GRADES` + `adjudicate` (heuristic → advisory unless corroborated; catalog-present is only a deliberateness heuristic via `deriveCatalogResult`/`adjudicateI18n`). ✅
- §3 confidence-by-oracle-strength → Task 1 (`failHigh`/`failLow`) + Task 4 doc; CONTEXT already unified. ✅
- §4.2 i18n adjudication table → Task 1 `adjudicateI18n` + Task 2 `deriveCatalogResult` cover every row (missing/empty→high; technical-Latin→drop; Latin==en→advisory-or-high by completeness; translated→drop; no-catalog→advisory). ✅
- §6 autonomous convention learning + known-deliberate memory (no HITL) → Task 3 `ux-conventions.sh` + Task 4 routing. ✅
- §2 black-box degrade → Task 1 (definite-dom needs no source; catalog/heuristic → advisory when inputs absent). ✅
- **Deliberately NOT in this plan (efforts B/C):** behavioral family 9 (§7), generative critic layer 3 (§5), accuracy-harness taxonomy fixture + the ≥95%/≥90% measured gate (§9, §11), within-family remaining static members. Called out in Scope + the ADR note. ✅

**2. Placeholder scan.** None — every step carries exact paths, complete code (the classifier, the derivation helper, both test runners), exact commands, and exact expected strings/`grade` values.

**3. Type consistency.** The suspicion shape `{detector,axis,selector,evidence,rawSignal}` matches `ux-detectors.js`'s `suspicion()` output. `adjudicate` returns exactly `{verdict,suspectedLayer,confidence,family,reason}` | `{advisory,reason}` | `null` across Tasks 1/4. `deriveCatalogResult` (Task 2) returns exactly the six strings `adjudicateI18n` (Task 1) switches on. `deliberateKey`'s `␟` separator is identical in `adjudicate.js` and `ux-conventions.sh` (Task 3). Grades are the four strings `oracleGradeFor` returns and `references/adjudication.md` documents. Verdict/confidence/layer vocab is unchanged (no sixth verdict; `FE` only).

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-03-ux-adjudication-engine.md`. Execution: **Subagent-Driven Development** (fresh implementer per task + task-scoped spec+quality review + fix loop; final whole-branch review on the most capable model), per the autonomous `/loop` directive.
