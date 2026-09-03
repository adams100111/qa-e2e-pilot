# UI/UX Taxonomy Fixture + Measured Recall Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the deferred **measured** recall/precision gate for the human-eye-UX engine (ADR-0019 §11): a UI/UX taxonomy fixture with planted bugs across the definite-oracle families (content-rendering, i18n, assets, invisible-text, overlap, interaction/sheet-stack) plus the two held-out real innovate-lab bugs (sheet-stack + `mm/dd/yyyy`), scored **headlessly and deterministically** by running the real shipped detector cores + `adjudicate.js` against a committed DOM snapshot, gated at **≥95% recall on the taxonomy set, 100% on the held-out pair, precision ≥90%** — on definite-oracle + code-adjudicated findings only (heuristic-only suspicions excluded from recall).

**Architecture:** A static HTML taxonomy fixture (`tools/accuracy-harness/fixture-ux/index.html`, same no-build/localStorage pattern as the existing `fixture/`) encodes the planted bugs. A committed **DOM snapshot** (`fixture-ux/snapshot.json`) captures the detector-relevant element records (text, computed styles, roles, image state, rects, overlay stacks) — the ground-truth input for headless scoring, extracted once from the fixture. A new headless runner (`scorer/ux-measure.js`) dispatches the **real** shipped detector cores (`ux-detectors.js`, `overlay-stack.js`) + the **real** `adjudicate.js` over that snapshot, producing a findings file that the **existing** `score.js` scores against a new `seeds-ux.json` (reusing its per-axis recall + precision + advisory-exclusion plumbing) with the ≥95%/≥90% gate block. Where the measured gate exposes a shipped-detector gap (notably the `mm/dd/yyyy` locale-date bug, a deferred within-family i18n member), this plan closes the minimal detector needed — or, if a gap is genuinely out of scope, records it as an **honest known-gap** (a logged, excluded seed with a follow-up) rather than faking the number.

**Tech Stack:** Dependency-free Node (the scorer/runner — `node`, no jsdom/puppeteer/package.json), `python3 -m http.server` (serving the fixture for the optional full-agent-run path), static HTML/vanilla-JS fixture, `node:test` for the runner's tests (matching the harness convention). No `jq` in the harness (it is jq-free — use `python3 -c`/node for any JSON shell handling).

## Global Constraints

- **This is sub-plan C1 of the human-eye-UX design (ADR-0019).** Sub-plans A (adjudication, PR #42) and B (behavioral family, PR #43) are merged. This plan lands the **accuracy-harness measured gate** (§9, §11). Sub-plan **C2** (the vision-gated generative critic, layer 3) remains deferred — this plan does NOT build the critic and does NOT claim the estimated long-tail coverage.
- **Honest measurement — never fake a number (the governing rule).** The gate reflects what the detectors + adjudicator actually catch. If a planted bug is not caught, either close the minimal detector gap (in scope) or mark that seed a **known-gap** with a logged reason and a follow-up — never remove/weaken a seed to inflate recall, never hand-write a finding the detectors didn't produce. The measured findings file is produced by the runner, never hand-authored (matching the harness's existing "no ESTIMATED findings kept" discipline).
- **Definite-oracle + code-adjudicated findings only are scored for recall (§11).** Heuristic-only suspicions (advisory) are excluded — reuse `score.js`'s existing `stream:"advisory"` / `ux-perceptual` gate-exclusion (no new exclusion logic). A seed for a heuristic-only family carries `stream:"advisory"`.
- **Headless + deterministic + autonomous (no HITL).** The measured gate runs the pure cores + adjudicate over a committed snapshot with no browser and no human judgment — reproducible in CI. (The full-agent-run path against the served fixture remains available for end-to-end DOM-walk validation but is NOT the CI gate.)
- **Reuse, don't rebuild, the scorer.** `score.js` already computes per-axis recall + precision + the gate against a `seeds` file's `gate` block and excludes advisory/negative seeds. Extend seed DATA and add a new `gate` number; change `score.js` only if a genuine gap (e.g. a `ux` axis roll-up that must include the new families) requires it — and minimally.
- **Real detectors only.** The runner invokes the actual `ux-detectors.js` / `overlay-stack.js` cores and the actual `adjudicate.js` — never a reimplementation. A snapshot element-record is shaped so the real core applies to it directly.
- **Dependency-free; jq-free harness.** No new npm dependency, no jsdom/puppeteer. `tools/` is copied verbatim into every `dist/<h>/` — new fixture/scorer files ship in every adapter automatically (no `build-adapter.sh` change needed).
- **Verdicts/confidence/layer vocab unchanged** (`pass|fail|blocked|deferred|error`; `high|low`; `FE|route|service|migration|DB`). No sixth verdict.
- **No Claude/Anthropic attribution** in any commit; no `Co-Authored-By` trailer. Never commit `dist/`.

## Self-grilled decisions (my own recommended answers applied)

1. **Headless scoring path** → run the **real detector cores + adjudicate over a committed DOM snapshot** (not a full browser, not a reimplementation). Dependency-free, deterministic, CI-able. The snapshot is a flat list of typed element-records so the real core applies directly (no DOM-selector engine needed). *Applied.*
2. **What the snapshot contains** → per family, the detector-relevant inputs: content-text records `{text}`; i18n records `{text, expectedLocale}`; image records `{naturalWidth, src}`; color records `{fg, bg}`; overlap records `{rectA, rectB}`/`{modalZ, backdropZ}`; overlay-stack records `{before, afterOpenChild, childId}` etc. Extracted ONCE from the fixture (a documented `browser_evaluate` extraction or a small deterministic extractor), committed. *Applied (Task 1).*
3. **Reuse `score.js`** → the runner emits a findings file with `judgedSeedId` set by DIRECT seed-linkage (each snapshot record carries its seed id), and `score.js --gate` scores it against `seeds-ux.json`. Minimal/no `score.js` change. *Applied (Tasks 3–4).*
4. **The `mm/dd/yyyy` held-out bug has no shipped detector** → add the minimal **locale-date-format** i18n detector (a deferred within-family member): flag a `mm/dd/yyyy`-style date rendered in a locale whose convention differs (e.g. an RTL/`ar` context) as an `i18n-locale-date` suspicion → definite-catalog/`i18n` grade. Scope it tightly (one core + its DETECT hook + tests). *Applied (Task 2).*
5. **Gate numbers** → `seeds-ux.json.gate`: `overallVerdictRecallMin: 0.95`, `precisionMin: 0.90`, plus a `heldOutRecallMin: 1.0` on the held-out pair (a distinct seed subset, `heldOut:true`). Heuristic seeds `stream:"advisory"` excluded from recall. *Applied (Task 3).*
6. **Known-gap discipline** → if a planted family member can't be caught by a shipped detector within C1's scope, mark its seed `knownGap:true` with a `gapReason`, EXCLUDE it from the gated positive set (like advisory), and log a follow-up. The gate measures what ships; the excluded set is reported, not hidden. *Applied (Task 3).*
7. **CI wiring** → out of scope for C1 (the harness gate is manual/local today; wiring it into `.github/workflows` is a separate follow-up). C1 delivers a one-command `run-ux-measure.sh` + a committed measured findings file + a green gate; note the CI-wiring follow-up. *Applied (Task 4 + follow-up note).*

---

## File Structure

- `tools/accuracy-harness/fixture-ux/index.html` **(new)** — the taxonomy fixture: planted bugs across the definite-oracle families + the two held-out real bugs + negative controls. Same no-build/localStorage/`data-testid` pattern as `fixture/index.html`.
- `tools/accuracy-harness/fixture-ux/snapshot.json` **(new)** — the committed DOM snapshot: a `{records:[...]}` array of typed, seed-linked detector inputs extracted from the fixture. The headless ground-truth.
- `tools/accuracy-harness/seeds-ux.json` **(new)** — ground-truth seeds (one per planted bug, `axis`/`kind`/`polarity`/`stream`/`heldOut`/`knownGap`/`match`) + the `gate` block (≥95%/≥90%/held-out 100%).
- `tools/accuracy-harness/scorer/ux-measure.js` **(new)** — the headless runner: loads `snapshot.json`, applies the real `ux-detectors.js`/`overlay-stack.js` cores per record, adjudicates via the real `adjudicate.js`, emits a findings file (`findings/measured-ux-<tag>.json`) with `judgedSeedId` + `axis` + `verdict`.
- `tools/accuracy-harness/scorer/test/ux-measure.test.js` **(new)** — `node:test` for the runner (each family record → the expected finding; negative controls → none).
- `skills/detecting-visual-ux/scripts/ux-detectors.js` **(modify)** — add the minimal `localeDateSignal(text, expectedLocale)` core + its DETECT hook (Task 2), emitting `i18n-locale-date`.
- `tests/ux-detectors/run.sh` **(modify)** — cases for `localeDateSignal`.
- `skills/detecting-visual-ux/scripts/adjudicate.js` **(modify, only if needed)** — ensure `i18n-locale-date` maps to a grade (it already will via the `i18n-` → `definite-catalog` prefix; add a test asserting it).
- `tools/accuracy-harness/run-ux-measure.sh` **(new)** — one-command: run `ux-measure.js` → score with `--gate`. Mirrors `run-baseline.sh`'s `--score` path.
- `tools/accuracy-harness/findings/measured-ux-baseline.json` **(new)** — the committed MEASURED findings from the runner (produced, not hand-authored).
- `tools/accuracy-harness/README.md` **(modify)** — document the UX taxonomy fixture, the headless measured path, and the gate.
- `docs/adr/0019-human-eye-ux-detection-engine.md` **(modify)** — implementation note: C1 (the measured gate) landed; C2 (critic) deferred; state the measured recall/precision actually achieved.
- `scorer/score.js` **(modify, only if required)** — extend the axis roll-up / gate to recognize the new `ux` families + `heldOut` subset, minimally.

---

## Task 1: The UI/UX taxonomy fixture + committed DOM snapshot

**Files:**
- Create: `tools/accuracy-harness/fixture-ux/index.html`
- Create: `tools/accuracy-harness/fixture-ux/snapshot.json`

**Interfaces:**
- Produces: the planted-bug HTML (each bug tagged with a `data-seed` attribute for the full-agent-run path AND traceability) and the `snapshot.json` `{records:[{seed, family, kind, input}]}` where `input` is the exact shape the corresponding real core consumes (Task 3 relies on this).

- [ ] **Step 1: Author the fixture HTML** — plant, each as a small vanilla-JS/CSS defect with a `data-seed="<id>"` hook, at minimum one member per definite-oracle family the shipped detectors catch:
  - content-rendering: a cell rendering `NaN`, one `undefined`, one `[object Object]`, one raw `{{interp}}`, one raw ISO timestamp.
  - i18n: a raw translation key (`deliverables.title`), a script-mismatch (Latin text on an `ar`/RTL surface), and the **held-out `mm/dd/yyyy` date** in an Arabic RTL form.
  - assets: a broken image (`src` that 404s / `naturalWidth==0`).
  - invisible-text: fg≈bg text.
  - overlap: two colliding text elements + a modal-behind-backdrop.
  - interaction (held-out sheet-stack): a deliverables list sheet whose "add" button REPLACES the list (destroys the parent) instead of stacking.
  - negative controls: clean rendered values, a correctly-translated `ar` label, a legitimately-Latin brand (`GitHub`), a properly-stacked child overlay, a high-contrast text — each `polarity:"negative"`.
- [ ] **Step 2: Extract + commit the DOM snapshot** — `snapshot.json` with one record per planted bug AND per negative control, each `{seed, family, kind, input}` where `input` matches the real core's argument shape (e.g. content → `{text:"NaN"}`; i18n script-mismatch → `{text:"Save", expectedLocale:"ar"}`; i18n locale-date → `{text:"03/09/2026", expectedLocale:"ar"}`; image → `{naturalWidth:0}`; invisible → `{fg:"#fff", bg:"#fefefe"}`; overlap → `{rectA, rectB}`; sheet-stack → `{before:[…], afterOpenChild:[…], childId:"…"}`). Document (a comment/README note) that the snapshot is extracted from the fixture via a one-time `browser_evaluate` (the fixture is the source of truth; the snapshot is its detector-relevant projection).
- [ ] **Step 3: Validate** — `python3 -c "import json;json.load(open('tools/accuracy-harness/fixture-ux/snapshot.json'))"`; open the HTML has no `<script>` syntax error (`node --check` won't parse HTML — instead grep that every `data-seed` id in the HTML has a matching record in `snapshot.json` and vice-versa, via a `python3` one-liner).
- [ ] **Step 4: Commit**
```bash
git add tools/accuracy-harness/fixture-ux/index.html tools/accuracy-harness/fixture-ux/snapshot.json
git commit -m "test(ux): UI/UX taxonomy fixture + committed DOM snapshot (definite-oracle families + held-out pair + negatives)"
```

---

## Task 2: The minimal locale-date-format i18n detector (close the held-out `mm/dd/yyyy` gap)

**Files:**
- Modify: `skills/detecting-visual-ux/scripts/ux-detectors.js`
- Modify: `tests/ux-detectors/run.sh`
- Test (adjudication): `tests/ux-adjudicate/run.sh` (assert `i18n-locale-date` grades to `definite-catalog`)

**Interfaces:**
- Produces: `localeDateSignal(text, expectedLocale) -> {rawSignal}|null` — flags an `mm/dd/yyyy`- (or `m/d/yyyy`-) formatted date string when `expectedLocale` is a locale whose date convention is NOT month-first (e.g. `ar`, `en-GB`, most non-`en-US`), emitting via `suspicion('i18n-locale-date', …)`. Consumed by the fixture's held-out date seed. Grades to `definite-catalog` (via the existing `i18n-` prefix in `ORACLE_GRADES`).

- [ ] **Step 1: Write the failing tests** (`tests/ux-detectors/run.sh`): `localeDateSignal("03/09/2026","ar")` → non-null (`mm/dd/yyyy` in a non-month-first locale); `localeDateSignal("2026-09-03","ar")` → null (ISO is locale-neutral); `localeDateSignal("03/09/2026","en-US")` → null (month-first is the convention there); adversarial: `localeDateSignal("v1.2.3","ar")` → null (not a date). Run → FAIL.
- [ ] **Step 2: Implement `localeDateSignal`** — a pure core: match a `^\d{1,2}/\d{1,2}/\d{4}$` (slash-separated) date; return `{rawSignal:text}` only when `expectedLocale` is not in the month-first set (`en-US`, `en-CA`-ish — keep the month-first allowlist tiny and explicit); else null. Add its DETECT hook where the i18n family walks locale-bearing text (reuse the existing `expectedLocale` resolution). Add `localeDateSignal` to `module.exports`.
- [ ] **Step 3: Adjudication test** — in `tests/ux-adjudicate/run.sh`, assert `oracleGradeFor("i18n-locale-date")` → `definite-catalog` (no adjudicate.js change expected — the `i18n-` prefix already maps it; confirm).
- [ ] **Step 4: Run tests** — `bash tests/ux-detectors/run.sh` + `bash tests/ux-adjudicate/run.sh` → `FAIL=0`; `node --check skills/detecting-visual-ux/scripts/ux-detectors.js`.
- [ ] **Step 5: Commit**
```bash
git add skills/detecting-visual-ux/scripts/ux-detectors.js tests/ux-detectors/run.sh tests/ux-adjudicate/run.sh
git commit -m "feat(ux): locale-date-format i18n detector (mm/dd/yyyy in a non-month-first locale) — closes the held-out date gap"
```

---

## Task 3: The headless measured runner + `seeds-ux.json`

**Files:**
- Create: `tools/accuracy-harness/scorer/ux-measure.js`
- Create: `tools/accuracy-harness/seeds-ux.json`
- Test: `tools/accuracy-harness/scorer/test/ux-measure.test.js`

**Interfaces:**
- `ux-measure.js` exports `measure(snapshotDoc)` → `{findings:[{judgedSeedId, axis, verdict, confidence, text}]}` — for each snapshot record, dispatch the matching real core (`require('../../../skills/detecting-visual-ux/scripts/ux-detectors.js')` / `overlay-stack.js`) to produce a suspicion (or null), then `require('.../adjudicate.js').adjudicate(suspicion, oracleInputs)` → a verdict/advisory/null; a verdict → a finding with `judgedSeedId = record.seed`, `axis` per the family, `verdict:'fail'`, `confidence`. Advisory/null → no gated finding (advisory ones may be emitted with `stream:"advisory"` for reporting). CLI: `node ux-measure.js <snapshot.json> > findings/measured-ux-<tag>.json`.
- `seeds-ux.json`: `{fixture:"ux-taxonomy", gate:{overallVerdictRecallMin:0.95, precisionMin:0.90, heldOutRecallMin:1.0}, seeds:[{id, axis, kind, polarity?, stream?, heldOut?, knownGap?, gapReason?, match:[…]}]}`.

- [ ] **Step 1: Write `seeds-ux.json`** — one seed per fixture planted bug (matching the `data-seed` ids), `axis` in the harness vocab (`ux-objective` for definite-oracle UX; `broken-journey`/a new `ux-interaction` for the sheet-stack — pick per how `score.js` rolls up, see Task 4), `heldOut:true` on the sheet-stack + `mm/dd/yyyy` seeds, `stream:"advisory"` on any heuristic-only family (generic overlap), negative controls `polarity:"negative"`. The `gate` block with the ≥95%/≥90%/100%-held-out numbers.
- [ ] **Step 2: Write the failing test** (`ux-measure.test.js`, `node:test`): feed a small snapshot with a `content-nan` record → `measure` yields one finding `{judgedSeedId, verdict:'fail', confidence:'high'}`; a negative-control clean-value record → no finding; the sheet-stack record → an `interaction-overlay-destroyed` → `fail`. Run → FAIL.
- [ ] **Step 3: Implement `ux-measure.js`** — a `FAMILY_DISPATCH` map from `record.family` to `(input) -> suspicion|null` using the real cores (content → `contentOracleSignal`; i18n-raw-key → `rawTranslationKeySignal`; i18n-script → `scriptMismatchSignal`; i18n-locale-date → `localeDateSignal`; image → `isBrokenImage`; invisible → `invisibleTextSignal` + a threshold; overlap → `rectOverlapFraction`/`modalBehindBackdrop`; interaction → the `overlay-stack.js` checkers). Wrap each into a suspicion object of the shape `adjudicate` consumes (`{detector, rawSignal}`), adjudicate (pass `corroborated:true` for the sheet-stack held-out seed since the fixture's shared-open state is known; pass `catalogResult` for i18n where the snapshot provides it), and collect verdicts. Never fabricate a finding a core didn't produce.
- [ ] **Step 4: Run + produce the findings** — `node scorer/ux-measure.js fixture-ux/snapshot.json > findings/measured-ux-baseline.json`; `node --test scorer/test/ux-measure.test.js` → pass.
- [ ] **Step 5: Commit**
```bash
git add tools/accuracy-harness/scorer/ux-measure.js tools/accuracy-harness/seeds-ux.json tools/accuracy-harness/scorer/test/ux-measure.test.js tools/accuracy-harness/findings/measured-ux-baseline.json
git commit -m "test(ux): headless measured runner (real cores + adjudicate over snapshot) + seeds-ux with the 95/90 gate"
```

---

## Task 4: Wire the gate + close/exclude gaps honestly

**Files:**
- Create: `tools/accuracy-harness/run-ux-measure.sh`
- Modify: `tools/accuracy-harness/scorer/score.js` (only if the axis roll-up / held-out check needs it)
- Modify: `tools/accuracy-harness/scorer/test/score.test.js` (if score.js changed)

**Interfaces:**
- `run-ux-measure.sh`: `node scorer/ux-measure.js fixture-ux/snapshot.json > findings/measured-ux-baseline.json && node scorer/score.js findings/measured-ux-baseline.json --seeds seeds-ux.json --gate`. Exit non-zero on gate failure.

- [ ] **Step 1: Run the gate** — `bash tools/accuracy-harness/run-ux-measure.sh`. Read the per-axis recall + precision + held-out result.
- [ ] **Step 2: Close or honestly exclude each miss.** For every planted positive seed NOT recalled: if it's a shipped-detector gap closeable in scope (a small core), close it (extend Task 2's pattern) and re-run; if genuinely out of scope, mark that seed `knownGap:true` + `gapReason` in `seeds-ux.json`, ensure `score.js` excludes `knownGap` from the gated positive set (mirror the `advisory`/`negative` exclusion — a minimal, tested `score.js` change), and record a follow-up. **Do NOT hand-edit the findings file to fake recall.** For any false positive (a negative-control seed flagged): fix the detector/threshold or the snapshot record — a real precision regression is a defect, not something to exclude.
- [ ] **Step 3: Make the gate green honestly** — iterate Steps 1–2 until `overallVerdictRecallMin:0.95` (on the non-excluded positive set), `precisionMin:0.90`, and `heldOutRecallMin:1.0` all pass. If a held-out bug cannot be caught, that is a BLOCKING finding to escalate (the held-out 100% is the hard requirement) — do not exclude a held-out seed.
- [ ] **Step 4: If `score.js` changed** — extend `scorer/test/score.test.js` to cover the new roll-up/exclusion (`knownGap` excluded; `heldOut` subset gated at 1.0). `node --test scorer/test/*.test.js` → pass.
- [ ] **Step 5: Commit**
```bash
git add tools/accuracy-harness/run-ux-measure.sh tools/accuracy-harness/seeds-ux.json tools/accuracy-harness/findings/measured-ux-baseline.json tools/accuracy-harness/scorer/score.js tools/accuracy-harness/scorer/test/score.test.js
git commit -m "test(ux): wire the 95/90 measured UX gate (run-ux-measure) — green on shipped detectors; gaps honestly excluded"
```

---

## Task 5: Docs — ADR-0019 note + harness README + the honest measured numbers

**Files:**
- Modify: `docs/adr/0019-human-eye-ux-detection-engine.md`
- Modify: `tools/accuracy-harness/README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: ADR-0019 implementation note** — sub-plan **C1 (the accuracy-harness measured gate) landed**: the UI/UX taxonomy fixture + committed snapshot, the headless `ux-measure.js` runner (real cores + adjudicate), `seeds-ux.json` + the ≥95%/≥90%/held-out-100% gate. State the **actual measured numbers achieved** (recall/precision/held-out) and list any `knownGap` seeds honestly. Sub-plan **C2** (the generative critic layer 3) remains deferred; its long-tail coverage stays **estimated, not measured**. The ≥95% gate is now **measured** for layers 1–2 (definite-oracle + code-adjudicated).
- [ ] **Step 2: README** — document `fixture-ux/`, `run-ux-measure.sh`, the headless measured path (real cores + adjudicate over `snapshot.json`), the gate numbers, the `knownGap` discipline, and the CI-wiring follow-up (the gate is manual/local today).
- [ ] **Step 3: Commit**
```bash
git add docs/adr/0019-human-eye-ux-detection-engine.md tools/accuracy-harness/README.md
git commit -m "docs(ux): ADR-0019 note (C1 measured gate landed, actual numbers) + accuracy-harness README"
```

---

## Self-Review

**1. Spec coverage (§9, §11).**
- New UI/UX taxonomy fixture across the definite-oracle families + the two held-out real bugs → Task 1. ✅
- Recall/precision gate runs against it, ≥95%/≥90%, 100% held-out → Tasks 3–4. ✅
- Scored on definite-oracle + code-adjudicated findings only; heuristic-only excluded → reuse `score.js` advisory exclusion + `stream:"advisory"` seeds + the runner only counting verdicts (Task 3). ✅
- Headless-reproducible, autonomous, no HITL → the pure-core+adjudicate-over-snapshot runner (Task 3). ✅
- The held-out `mm/dd/yyyy` bug needs a detector → the minimal locale-date core (Task 2). ✅
- Real bugs feed the fixture → the two held-out bugs are fixture #1 (Task 1). ✅
- **Deliberately NOT here (C2):** the generative critic layer 3 (vision-gated) and its estimated long-tail coverage — called out in Global Constraints + the ADR note. Honest-measurement discipline forbids faking the number.

**2. Placeholder scan.** The fixture/snapshot/seeds are large DATA artifacts authored in-task (per writing-plans "don't inline large artifacts") with exact schemas + the exact per-family record shapes and the exact gate numbers specified here; the code tasks (locale-date core, runner dispatch, gate) carry exact function signatures, inputs, and commands. No "TBD".

**3. Type consistency.** The snapshot record `{seed, family, kind, input}` shape (Task 1) is exactly what `ux-measure.js`'s `FAMILY_DISPATCH` consumes (Task 3). The suspicion `{detector, rawSignal}` the runner builds is what `adjudicate` reads. `localeDateSignal(text, expectedLocale)` (Task 2) matches the i18n snapshot record's `input`. `seeds-ux.json`'s `axis`/`polarity`/`stream`/`heldOut`/`knownGap` fields match `score.js`'s partitioning (Task 4 extends it minimally if needed). Verdict/confidence/layer vocab unchanged.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-03-ux-accuracy-gate.md`. Execution: **Subagent-Driven Development** (fresh implementer per task + task-scoped review + fix loop; final whole-branch review on the most capable model), per the autonomous `/loop` directive. **Note the honest-measurement discipline is binding on Task 4** — a green gate must reflect real detector performance; escalate (don't fake) if a held-out bug can't be caught.
