# QA Accuracy + Persona Overhaul — Master Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement each phase task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Phase 0 AND Phase 1 are built and merged (see their MEASURED result blocks below and in `docs/plans/2026-08-30-phase1-execution-gate.md`). Phase 2 has a granular expansion plan (`docs/plans/2026-08-31-phase2-coverage-roles.md`). Phases 3–6 remain roadmap and MUST be expanded into their own plans once the phase ahead of them produces its MEASURED result — their thresholds depend on that number.**

**Goal:** Stop `qa-e2e-pilot` from reporting false-greens — lift *measured* true-bug-recall from ~40% functional / ~15% UX toward ≥65–80% per axis (biggest lift on UX) by QA-ing as each real project role/persona with a human eye, and prove every number against a trustworthy harness before touching a single skill.

**Architecture:** Measurement-first. Phase 0 rebuilds the accuracy harness so numbers mean something (strict attribution, precision + negative controls, a real converter, a widened fixture) and captures a first *measured* baseline. Only then do the behavior changes land, each gated by that harness as a regression tripwire: an execution-enforcement gate (verdict requires fresh evidence), role/persona discovery (QA runs as each discovered role), a vision-based human-eye UX pass, the consolidated observe-round, and the detection layer.

**Tech Stack:** Node (scorer/converter/detectors, dependency-free per repo rule), `bash` + `jq`/`python3` (checkpoint/preflight scripts), Playwright MCP (`browser_evaluate`, `browser_resize`, `browser_take_screenshot`, `browser_snapshot`, `browser_console_messages`, `browser_network_requests`), axe-core (vendored, injected), the qa-e2e-pilot agent itself as the system-under-test.

## Global Constraints

Every task's requirements implicitly include these. Copied verbatim from `CLAUDE.md` / `CONTEXT.md` / ADRs:

- **Verdicts are exactly** `pass | fail | blocked | deferred | error`. **No 6th** (`skip`/`warn`/`partial`/**`advisory`**). Aesthetics are an advisory *stream*, never a verdict value.
- **Confidence** is orthogonal: `high | low` (low when the expected value could only come from backend code / a standards oracle).
- **Suspected layer** is exactly one of `FE | route | service | migration | DB`. Recorded on a `fail`.
- **The oracle is the spec/domain rule, never the backend's own formula.** Reading backend code only *localizes* a divergence.
- **Run state lives in `.qa/runs/<run-id>/`** as plain files — never agent memory (ADR-0002).
- **Verification is sequential by default** (ADR-0003). Parallel fan-out is opt-in, only for tagged independent/read-only criteria + deliberate race tests, capped at `maxParallel`.
- **Probing is read-only** unless `allowApiWrites` *and* the disposable-env marker are set. **Secrets never printed.**
- **Browser tools are called by capability**, naming the Playwright MCP tool in parens. New drivers/behavior via config, not code (ADR-0004).
- **Reuse posture (ADR-0001):** reimplement patterns, do not fork/vendor external skills. The one deliberate exception (axe-core, a third-party blob) is recorded in ADR-0007/0009.
- **Skill files:** frontmatter only `name`+`description`; `name` == dir name, lowercase-hyphen gerund; body < 500 lines; ≥3 mini-evals.
- **Bundled browser JS is dependency-free** (`document`/`window`/`fetch` only). Node scripts prefer `jq`, fall back to `python3`.

---

## Settled decisions (the design, for approval)

These came out of the grilling passes and are the spec Phase 0+ implements:

1. **Measurement is trustworthy before any skill edit.** Delete hand-authored projections; a number is either MEASURED (from a real run) or absent.
2. **Attribution is strict.** A finding credits a seed only via explicit `seedId` OR an LLM-judge assertion of the *actual defect* — never a bare keyword collision.
3. **Precision is gated, not just recall.** Negative-control seeds (correct values that must stay silent) are planted; the gate requires recall ≥ target **and** precision ≥ target. A detector that flags everything must fail the gate.
4. **Persona = discovered role × review lens (MANDATORY).** Roles are discovered from the codebase on two planes (global RBAC + contextual team roles), HITL-confirmed, and QA runs as each. Review lenses (default `skeptical-auditor`, plus `first-time-user`, `a11y-user`) are the plugin's fixed small set, selectable per run. The role/persona confirmation is a **grilling-style round** (Decision 11), not a flat form.
5. **Config is regenerated from the codebase, not reconciled.** The project is the source of truth; `.qa/config.json` personas/authz-matrix are generated fresh + HITL-confirmed (greenfield — existing hand-tuned blocks are replaced). Regeneration *proposes*; the human confirms via the grilling round (Decision 11).
6. **Per-role cost is contained.** Only `role-sensitive` criteria + authz negative tests multiply per role; shared functional/computed criteria run once as the most-privileged role. Cross-role negative tests ("role B must not see role A's data") are first-class.
7. **A real human-eye vision pass exists.** Screenshot → multimodal review via a hallmark-`audit`-style scored, read-only punch list fed by a ui-ux-pro-max-style priority rubric. Objective/visible defects → `fail`@`FE`/`confidence:low`; subjective → advisory. Vision findings pass the same precision gate and must cite a visible-evidence anchor.
8. **Behavior-first, code-as-evidence.** Every finding must manifest as an observable UI/data divergence; code is read only to localize it to a suspected layer and attached as evidence — never a standalone "codebase issue" verdict.
9. **Efficiency without recall loss.** The 6-call per-step loop consolidates to one structured `browser_evaluate` observe-round (acts stay separate). `browser_run_code_unsafe` stays OUT of the allowlist (RCE-equivalent); add only `browser_resize`. The fixture gate is the regression guard: consolidation may not drop recall.
10. **Reimplemented patterns (ADR-0001):** grilling's frontier-in-rounds (HITL confirm), verification-before-completion's Iron Law + diagnose's feedback-loop ladder (verdict/confidence + localization), hallmark `audit` + ui-ux-pro-max rubric (vision pass), dispatching-parallel-agents/swarm aggregate + wave-pilot resume (per-role fan-out + resume). Do NOT depend on: ui-ux-pro-max's asset DB, interrogate/setup-pstack's multi-model config, wave-pilot's DAG engine, axe beyond a pinned injected blob.
11. **All HITL confirmation uses grilling's rounds/frontier — NOT a flat one-shot form.** Every place the plugin puts a DECISION to the human (role list, per-role auth, role-sensitive scope, per-run persona/viewport subset) is a grilling-style round: numbered items, each with a **recommended default** (the strongest static-analysis signal, source cited); the human confirms/edits; the frontier is recomputed for dependent decisions (roles → credentials → scope is a dependency **tree**, not a flat list). **Facts are the plugin's job** (auto-discovered by a subagent), NEVER asked of the human — the plugin proposes findings for confirmation, it never asks "what roles does your app have?". **`bootstrapping-qa-config`'s flat `AskUserQuestion` batch is NOT the reference implementation** for this — its 4 questions are independent so one round is correct for it; role/persona confirmation is tree-shaped and needs the full round/frontier machinery. This is an acceptance criterion of the Phase 2 and Phase 5 expanded plans, not an attribution footnote.

---

## Phased roadmap

| Phase | Subsystem | Produces (working, testable on its own) | ADRs |
|---|---|---|---|
| **0** | **Trustworthy measurement** (this plan, granular below) | Rewritten scorer (strict attribution + precision + negative controls + enum validation), `convert-buglog.js`, widened synthetic fixture, purged fictions, **first MEASURED baseline** | revises 0006–0009; no new |
| **1** | **Execution-enforcement gate** | `checkpoint.sh` evidence schema (`evidence_refs` content-validated + criterion `kinds`), pass-gate wired in, resume-view carries `kinds`; `generating-qa-checklist` tags `kinds`/`probeNeeded` | new: 0010 (evidence gate) |
| **2** | **Role/persona discovery** | `discovering-user-roles` skill (two-plane static analysis → proposal), **HITL confirm as grilling-style rounds** (Decision 11: roles→credentials→scope frontier, numbered items + recommended defaults, facts auto-discovered), `.qa/config.json` persona+authz-matrix generation, seeded-credential login, `role-sensitive` criterion tag + cross-role negative tests | new: 0011 (roles/personas), 0012 (per-role scope) |
| **3** | **Human-eye vision pass** | Vision review pass (screenshot → scored read-only punch list + rubric), objective→verdict / subjective→advisory, precision-gated, evidence-anchored; wired into `analyzing-feature-ui` + `writing-qa-reports`; **re-enable `ux-perceptual` (P1/P2) in `score.js --gate` once the vision pass lands** (it is currently gate-excluded per Task 0.3b, `c707718`, pending exactly this phase) | revises 0007; new: 0013 (vision reviewer) |
| **4** | **Observe-round + detection layer** | Consolidated `browser_evaluate` observe-round replacing the 6-call loop in `driving-browser-qa` + `walking-multistep-flows`; axe + WCAG heuristics injected; allowlist `+browser_resize` | revises 0006, 0009 |
| **5** | **Viewport/persona wiring + cross-cutting** | `.qa/config.json.example` + `bootstrapping-qa-config` (viewport/persona/detection/passGate keys); **per-run role/persona/viewport subset = a grilling frontier question** (Decision 11; recommended default "run all discovered roles"), not a silent config read; `agents/qa-e2e-pilot.md` phase wiring; `memory-sync.sh` + `report-to-junit.sh`/CI for new artifact types | revises 0008 |
| **6** | **Packaging, dependencies & install wiring** | `package.json` (axe-core pinned, auto-`npm install`), `.mcp.json` (Playwright MCP auto-present), `SessionStart` preflight hook (blocks on missing Node/jq/python3/Playwright), `skills.json` drift fix + all new skills, README attribution, version bump | new: 0014 (packaging & prereqs) |

**Gate between phases:** each phase must leave `node tools/accuracy-harness/scorer/score.js <measured-run> --gate` non-regressed vs the prior phase's MEASURED number. No phase ships on estimated numbers.

**Fix-regardless (fold into the first phase that touches each file):**
- `findings/after-fixed.json:15` uses `"verdict":"advisory"` — a literal 6th verdict. Purged in Phase 0 (Task 0.1).
- `chrome-devtools-mcp` version in the plan/ADR-0009 is wrong (`~v0.25.0` → actual `1.8.0`); Playwright-MCP issues #1495/#1651 are **closed** — re-justify the `run_code_unsafe` exclusion on RCE-surface grounds, not "still-open hole". Fixed when Phase 4 revises ADR-0009.
- `pass-gate.js` schema (`kinds`/`evidenceRefs` camelCase) doesn't map to real `checkpoint.sh` (`evidence_refs` snake_case, no `kinds`). Reconciled in Phase 1.
- `scripts/skills.json` is drifted: it lists 11 skills but omits `detecting-stack-profile` and `bootstrapping-qa-config` (present on disk). The npx/marketplace install path misses them. Fixed in Phase 6 (Task 6.4) along with every new skill.

**Shipped fixture/driver fixes (credit, not future work):** two fixes already landed as part of Phase 0's post-baseline hardening and are what let Phase 2 even attempt its recall lift — `3b77395` exposed an **observable ESOP pool** so F1 (issued-only-denominator bug) went from undetectable black-box to detectable; `4432279` made **negative-share entry** reliably testable (seed F4) by giving the fixture's add-founder form a real validation gap to catch, alongside making N1 an honest persisted negative control. Both are referenced from `docs/plans/2026-08-31-phase2-coverage-roles.md`'s Status note so that plan doesn't re-scope them.

**Staged recall checkpoints (targets to falsify slippage against, NOT precise predicted numbers — do not treat these as promises):** functional/UX recall is measured fresh after every phase and tracked toward the master goal of **≥65–80% per axis**. Concretely: Phase 1 measured 38% functional / 25% UX (see the result block above) — precision-only, as designed. Phase 2's coverage catalog + role discovery is expected to move functional recall meaningfully (it directly targets F3/J1/J3/J4) while UX recall is expected to stay roughly flat until Phase 3/4 land, since no non-vision detector exists yet for U1–U3. Phase 3 (vision pass) is where UX recall should make its first real jump, and Phase 4 (axe + consolidated observe-round) should close most of the remainder. If a phase's MEASURED number comes back flat or regressed against this trajectory, that is a signal to stop and diagnose before the next phase, not to relabel the target.

---

## Phase 0 — Trustworthy Measurement Foundation

**Why first:** Every downstream threshold and "did it improve?" claim is unfalsifiable until the harness measures *real* runs with *both* recall and precision. Phase 0 produces working, testable software (a scorer + converter with passing unit tests) and one honest baseline number, and depends on nothing else.

**Scope note:** the synthetic fixture measures functional/journey/UX + negative-controls *deterministically*. **Role/authz recall is NOT measured on the synthetic fixture** (it is single-user localStorage) — it is measured against the real multi-role project (`innovation`) in Phase 2. Keep that boundary explicit.

## Phase 0 result (MEASURED 2026-08-30)

The current (pre-fix) `qa-e2e-pilot` agent ran black-box against the served fixture; its bug-log was converted, judge-attributed to seeds, and scored:

| Axis | Recall | Caught / Planted |
|---|---|---|
| functional (incl. broken-journey) | **33%** | F2, J2 / F1,F2,F3,J1,J2,J3 |
| ux-objective | **25%** | U4 (console error) / U1,U2,U3,U4 |
| overall | **30%** | 3 / 10 |
| precision | **75%** | 3 TP, 1 FP |

**GATE: FAIL** (targets 70/75/70/80) — expected: this is the baseline; the fixes are Phases 1–5. The MEASURED number reproduces the reported ~40% functional / ~15% UX false-greens.

Live-run learnings (feed fixture hardening / new seeds):
- **N1 is a broken negative control.** The agent correctly flagged Founder-B as a phantom rendered-but-unpersisted row (the FP above). Fix: make N1 a genuinely persisted, correctly-computed clean row so it can't be legitimately flagged.
- **Two real UNSEEDED bugs found** (0-share false-success toast; negative-share ownership) — promote to seeds to widen coverage.
- Missed: F1 (fully-diluted denominator), F3 (delete re-reconcile), J1/J3 (specific journey drops), U1–U3 (all visual/a11y — no detector yet). These are exactly what Phases 1 (gate/coverage), 3 (vision), 4 (axe) must close.

Artifacts: `tools/accuracy-harness/findings/measured-baseline-run.json` (raw), `findings/measured-baseline.json` (attributed + scored).

**Post-baseline hardening (committed):**
- Task 0.3b (`c707718`) — gate-exclude vision-only `ux-perceptual` seeds until the Phase 3 vision pass (user-approved grilling decision; see Decision 11).
- Fixture hardening (`4432279`) — N1 reworked into an honest persisted whole-cent SAFE control; the 2 unseeded bugs promoted to seeds **F4** (negative shares → invalid ownership) and **J4** (0-share false-success toast). Seed count now 18. NB: the committed `measured-baseline*.json` + `tools/accuracy-harness/README.md` are scored/worded against the *pre-hardening* 16-seed set — dated artifacts; the next measured run re-scores against the 18-seed set.

**File structure (Phase 0):**
- `tools/accuracy-harness/scorer/score.js` — Modify: strict attribution + precision + negative controls + enum validation.
- `tools/accuracy-harness/scorer/attribute.js` — Create: the judge-attribution seam (model call isolated + mockable).
- `tools/accuracy-harness/scorer/convert-buglog.js` — Create: real `.qa/runs/**/bug-log.json` → findings file, structured-field match.
- `tools/accuracy-harness/seeds.json` — Modify: add negative-control seeds, non-axe UX seeds, widen functional/journey; add `precisionMin` to gate.
- `tools/accuracy-harness/fixture/index.html` — Modify: plant the new negative-control "clean" values + non-axe UX defects.
- `tools/accuracy-harness/scorer/test/*.test.js` — Create: node built-in test runner specs.
- `tools/accuracy-harness/findings/{after-fixed,baseline}.json` — Delete (Task 0.1): hand-authored fictions.
- `tools/accuracy-harness/findings/measured-baseline.json` — Create (Task 0.7): the first real run's converted output.

**Test tooling:** node's built-in runner (`node --test`), zero deps. Run one file with `node --test tools/accuracy-harness/scorer/test/score.test.js`.

---

### Task 0.1: Purge the fictions

**Files:**
- Delete: `tools/accuracy-harness/findings/after-fixed.json`, `tools/accuracy-harness/findings/baseline.json`

**Interfaces:**
- Produces: a harness with no hand-authored numbers — the scorer will only ever run against real converted runs or explicit test fixtures.

- [ ] **Step 1: Confirm these are the untracked, session-authored projections (not user data)**

Run: `git -C /home/dev/repos/qa-e2e-pilot status --porcelain tools/accuracy-harness/findings/`
Expected: both files listed as untracked (`??`). If either is tracked/committed or contains anything you did not author this session, STOP and ask the user before deleting (global destructive-op rule).

- [ ] **Step 2: Delete the two projection files**

```bash
rm tools/accuracy-harness/findings/after-fixed.json tools/accuracy-harness/findings/baseline.json
```

- [ ] **Step 3: Grep the repo for dangling references and note them for later tasks**

Run: `grep -rn "after-fixed\|findings/baseline" tools/accuracy-harness docs/`
Expected: references in `README.md` / `score.js` header / `run-baseline.sh` — these are updated in Task 0.5/0.7, not now. Record the hits.

- [ ] **Step 4: Commit**

```bash
git add -A tools/accuracy-harness/findings/
git commit -m "chore(harness): remove hand-authored recall projections (measurement must be real)"
```

---

### Task 0.2: Seeds — negative controls, non-axe UX, precision gate

**Files:**
- Modify: `tools/accuracy-harness/seeds.json`
- Modify: `tools/accuracy-harness/fixture/index.html`

**Interfaces:**
- Produces: seed schema gains `polarity: "positive" | "negative"` (default `positive`); negative seeds are *clean* values that must NOT be flagged. `gate` gains `precisionMin`. A new UX sub-axis `ux-perceptual` holds non-axe defects (visual hierarchy, alignment, label clarity) that only the vision pass (Phase 3) can catch — seeded now so the scorer can measure the vision pass later.

- [ ] **Step 1: Write the failing scorer test for precision (drives the schema)**

Create `tools/accuracy-harness/scorer/test/precision.test.js`:

```js
const { test } = require('node:test');
const assert = require('node:assert');
const { score } = require('../score.js'); // Task 0.3 exports score()

const seeds = {
  gate: { functionalRecallMin: 0.7, uxObjectiveRecallMin: 0.75, overallVerdictRecallMin: 0.7, precisionMin: 0.8 },
  seeds: [
    { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
    { id: 'N1', axis: 'functional', polarity: 'negative', match: ['issued shares correct'] } // clean value; flagging it is a false positive
  ]
};

test('flagging a negative-control seed lowers precision', () => {
  const findings = { findings: [
    { seedId: 'F1', text: 'wrong denominator' },   // true positive
    { seedId: 'N1', text: 'issued shares correct look wrong' } // FALSE positive on a clean value
  ]};
  const r = score(findings, seeds);
  assert.equal(r.precision, 0.5); // 1 TP / (1 TP + 1 FP)
});

test('silent on negative controls yields precision 1', () => {
  const findings = { findings: [ { seedId: 'F1', text: 'wrong denominator' } ] };
  const r = score(findings, seeds);
  assert.equal(r.precision, 1);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `node --test tools/accuracy-harness/scorer/test/precision.test.js`
Expected: FAIL — `score` not exported / `precision` undefined. (Implemented in Task 0.3.)

- [ ] **Step 3: Add negative-control + `ux-perceptual` seeds to `seeds.json`**

Add to the `seeds` array (positive polarity is the default for existing seeds — add `"polarity":"positive"` explicitly to them in Task 0.3's edit; here add the new ones):

```jsonc
{ "id": "N1", "axis": "functional", "polarity": "negative",
  "title": "Founder with 250k of 750k FD shows 33.33% correctly — MUST NOT be flagged",
  "match": ["33.33 wrong", "ownership incorrect", "denominator bug on founder-b"] },
{ "id": "N2", "axis": "ux-objective", "polarity": "negative",
  "title": "Primary button label #1a1a1a on #ffffff (~17:1) passes AA — MUST NOT be flagged",
  "match": ["primary button contrast", "label unreadable"] },
{ "id": "N3", "axis": "broken-journey", "polarity": "negative",
  "title": "Editing a persisted founder DOES persist — MUST NOT be flagged as a silent drop",
  "match": ["edit not persisted", "edit silent drop"] },
{ "id": "P1", "axis": "ux-perceptual", "polarity": "positive", "stream": "advisory-eligible",
  "title": "Finalize CTA sits below the fold with no visual affordance; primary action not discoverable",
  "suspectedLayer": "FE",
  "match": ["not discoverable", "below the fold", "no affordance", "hierarchy", "primary action hidden"] },
{ "id": "P2", "axis": "ux-perceptual", "polarity": "positive", "stream": "advisory-eligible",
  "title": "Amount column right-aligned, labels left-aligned, rows visually misread as unrelated",
  "suspectedLayer": "FE",
  "match": ["misaligned", "alignment", "visually unrelated", "hard to scan"] }
```

Update `gate` to add precision:

```jsonc
"gate": {
  "functionalRecallMin": 0.70,
  "uxObjectiveRecallMin": 0.75,
  "overallVerdictRecallMin": 0.70,
  "precisionMin": 0.80,
  "_note": "Absolute per-axis recall + overall precision. Negative-control seeds (polarity:negative) must NOT be flagged; flagging one is a false positive. Subjective advisory stream reported, not gated."
}
```

- [ ] **Step 4: Plant the matching clean values + perceptual defects in the fixture**

In `tools/accuracy-harness/fixture/index.html`: add a second founder (Founder-B, 250k of 750k FD) whose ownership renders the *correct* 33.33% (the N1 clean control), ensure the primary button uses `#1a1a1a on #ffffff` (N2 clean control), and make the Finalize CTA render below the fold with no highlight (P1) and the amount column right-aligned against left-aligned labels (P2). Add a code comment above each: `<!-- SEED N1: clean control, must NOT be flagged -->` etc.

- [ ] **Step 5: Validate JSON + fixture serve**

Run: `python3 -c "import json;json.load(open('tools/accuracy-harness/seeds.json'))" && (cd tools/accuracy-harness && python3 -m http.server 8099 &>/dev/null & sleep 1; curl -sI http://localhost:8099/fixture/index.html | head -1; kill %1)`
Expected: no JSON error; `HTTP/1.0 200 OK`.

- [ ] **Step 6: Commit**

```bash
git add tools/accuracy-harness/seeds.json tools/accuracy-harness/fixture/index.html tools/accuracy-harness/scorer/test/precision.test.js
git commit -m "test(harness): seed negative controls + perceptual UX + precision gate (failing)"
```

---

### Task 0.3: Scorer rewrite — strict attribution, precision, enum validation

**Files:**
- Modify: `tools/accuracy-harness/scorer/score.js`
- Create: `tools/accuracy-harness/scorer/test/score.test.js`

**Interfaces:**
- Consumes: `seeds.json` (Task 0.2 schema: `polarity`, `stream`, `gate.precisionMin`).
- Produces: `module.exports = { score }` where `score(findingsDoc, seedsDoc) -> { perAxis, rollups, overall, precision, advisory, gate: {pass, checks} }`. A finding credits a seed ONLY if `finding.seedId === seed.id` OR `finding.judgedSeedId === seed.id` (from Task 0.4). Bare keyword match is a *hint used by the judge*, NOT a scorer credit. Any finding whose `verdict` is outside `pass|fail|blocked|deferred|error` throws. A finding attributed to a `polarity:negative` seed is a false positive.

- [ ] **Step 1: Write the failing tests**

Create `tools/accuracy-harness/scorer/test/score.test.js`:

```js
const { test } = require('node:test');
const assert = require('node:assert');
const { score } = require('../score.js');

const seeds = {
  gate: { functionalRecallMin: 0.5, uxObjectiveRecallMin: 0.5, overallVerdictRecallMin: 0.5, precisionMin: 0.8 },
  seeds: [
    { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
    { id: 'U1', axis: 'ux-objective', polarity: 'positive', match: ['contrast'] },
    { id: 'N1', axis: 'functional', polarity: 'negative', match: ['clean'] },
    { id: 'S1', axis: 'ux-subjective', polarity: 'positive', stream: 'advisory', match: ['garish'] }
  ]
};

test('bare keyword match does NOT credit a seed (strict attribution)', () => {
  const r = score({ findings: [{ text: 'the denominator is fine actually' }] }, seeds);
  assert.equal(r.rollups.functional.hit, 0); // keyword present, but no seedId/judgedSeedId
});

test('explicit seedId credits the seed', () => {
  const r = score({ findings: [{ seedId: 'F1', verdict: 'fail', text: 'wrong denominator' }] }, seeds);
  assert.equal(r.rollups.functional.hit, 1);
});

test('judgedSeedId (from attribute.js) credits the seed', () => {
  const r = score({ findings: [{ judgedSeedId: 'U1', verdict: 'fail', text: 'low contrast helper' }] }, seeds);
  assert.equal(r.perAxis['ux-objective'].hit, 1);
});

test('finding on a negative-control seed is a false positive', () => {
  const r = score({ findings: [
    { seedId: 'F1', verdict: 'fail', text: 'x' },
    { seedId: 'N1', verdict: 'fail', text: 'flagged a clean value' }
  ]}, seeds);
  assert.equal(r.precision, 0.5);
});

test('advisory-stream seeds never count in verdict recall or the gate', () => {
  const r = score({ findings: [{ seedId: 'S1', verdict: 'fail', text: 'garish' }] }, seeds);
  assert.equal(r.overall.total, 3); // F1,U1,N1 — S1 excluded from verdict recall
  assert.ok(r.advisory.total >= 1);
});

test('an out-of-enum verdict throws', () => {
  assert.throws(() => score({ findings: [{ seedId: 'F1', verdict: 'advisory', text: 'x' }] }, seeds),
    /verdict.*advisory/i);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test tools/accuracy-harness/scorer/test/score.test.js`
Expected: FAIL — `score` not exported / assertions unmet.

- [ ] **Step 3: Rewrite `score.js` to export `score()` with strict attribution + precision + enum validation**

Replace the body of `tools/accuracy-harness/scorer/score.js` with a module that exports `score` and keeps a thin CLI. Core logic:

```js
'use strict';
const VERDICTS = new Set(['pass', 'fail', 'blocked', 'deferred', 'error']);

function creditsSeed(finding, seed) {
  if (finding.seedId && finding.seedId === seed.id) return true;
  if (finding.judgedSeedId && finding.judgedSeedId === seed.id) return true;
  return false; // NOTE: keyword `match` is a judge hint (attribute.js), never a scorer credit
}

function score(findingsDoc, seedsDoc) {
  const seeds = seedsDoc.seeds;
  const findings = findingsDoc.findings || [];

  // enum guard — a demo/real finding may only carry a real verdict (or none, for advisory notes)
  for (const f of findings) {
    if (f.verdict != null && !VERDICTS.has(f.verdict)) {
      throw new Error(`invalid verdict "${f.verdict}" (allowed: ${[...VERDICTS].join('|')})`);
    }
  }

  const positive = seeds.filter(s => (s.polarity || 'positive') === 'positive' && s.stream !== 'advisory');
  const negative = seeds.filter(s => s.polarity === 'negative');
  const advisorySeeds = seeds.filter(s => s.stream === 'advisory');

  const recalled = seed => findings.some(f => creditsSeed(f, seed));

  // precision: TP = attributed to a positive seed; FP = attributed to a negative-control seed
  const tp = positive.filter(recalled).length;
  const fp = negative.filter(recalled).length;
  const precision = (tp + fp) === 0 ? 1 : tp / (tp + fp);

  const byAxis = {};
  for (const s of positive) (byAxis[s.axis] = byAxis[s.axis] || []).push(s);
  const scoreList = list => {
    const hit = list.filter(recalled).length;
    return { total: list.length, hit, ratio: list.length ? hit / list.length : 1,
             missed: list.filter(s => !recalled(s)) };
  };
  const perAxis = {}; for (const ax of Object.keys(byAxis)) perAxis[ax] = scoreList(byAxis[ax]);
  const rollups = {
    functional: scoreList([...(byAxis['functional']||[]), ...(byAxis['broken-journey']||[])]),
    ux: scoreList(byAxis['ux-objective'] || [])
  };
  const overall = scoreList(positive);
  const advisory = scoreList(advisorySeeds);

  const g = seedsDoc.gate || {};
  const checks = [
    ['functional recall', rollups.functional.ratio, g.functionalRecallMin],
    ['ux-objective recall', (perAxis['ux-objective']||{ratio:1}).ratio, g.uxObjectiveRecallMin],
    ['overall recall', overall.ratio, g.overallVerdictRecallMin],
    ['precision', precision, g.precisionMin]
  ].filter(c => c[2] != null);
  const pass = checks.every(c => c[1] >= c[2] - 1e-9);

  return { perAxis, rollups, overall, precision, advisory, gate: { pass, checks } };
}
module.exports = { score };
```

Keep the CLI (printing + `--gate` exit code) below `module.exports`, calling `score()` and rendering `precision` and each `gate.checks` row; exit `1` when `!gate.pass`. Preserve the `(MEASURED)`/`(ESTIMATED)` label off `findingsDoc.estimated`.

- [ ] **Step 4: Run both test files to verify pass**

Run: `node --test tools/accuracy-harness/scorer/test/`
Expected: PASS (all of `score.test.js` + `precision.test.js`).

- [ ] **Step 5: `node --check` the rewritten CLI**

Run: `node --check tools/accuracy-harness/scorer/score.js`
Expected: no output (valid).

- [ ] **Step 6: Commit**

```bash
git add tools/accuracy-harness/scorer/score.js tools/accuracy-harness/scorer/test/
git commit -m "feat(harness): strict seedId/judge attribution + precision + verdict-enum gate"
```

---

### Task 0.4: Judge-attribution seam (`attribute.js`)

**Files:**
- Create: `tools/accuracy-harness/scorer/attribute.js`
- Create: `tools/accuracy-harness/scorer/test/attribute.test.js`

**Interfaces:**
- Produces: `module.exports = { attribute }`. `attribute(findings, seeds, judgeFn) -> findings'` where each finding gains `judgedSeedId` (or stays unattributed) by asking `judgeFn({finding, candidateSeeds}) -> seedId|null`. `judgeFn` is injected (a real model call in production, a stub in tests) so attribution is deterministic under test. Candidate seeds are pre-filtered by keyword `match` (the hint) but the judge makes the call, asserting the *actual defect* — never a bare keyword.

- [ ] **Step 1: Write the failing test (judge rejects a keyword collision)**

Create `tools/accuracy-harness/scorer/test/attribute.test.js`:

```js
const { test } = require('node:test');
const assert = require('node:assert');
const { attribute } = require('../attribute.js');

const seeds = [{ id: 'F2', axis: 'functional', match: ['amount', 'precision'],
  title: 'SAFE amount truncates to 2 decimals (sub-cent loss)' }];

test('judge rejects keyword collision, credits real defect', () => {
  const findings = [
    { text: 'the amount field is nicely aligned' },       // keyword "amount" but NOT the defect
    { text: 'SAFE amount shows 4000.00, lost the sub-cent tail' } // the real defect
  ];
  const stubJudge = ({ finding }) =>
    /sub-cent|lost the/.test(finding.text) ? 'F2' : null;
  const out = attribute(findings, seeds, stubJudge);
  assert.equal(out[0].judgedSeedId, undefined);
  assert.equal(out[1].judgedSeedId, 'F2');
});

test('findings with no candidate seeds are left untouched', () => {
  const out = attribute([{ text: 'totally unrelated' }], seeds, () => { throw new Error('judge should not be called'); });
  assert.equal(out[0].judgedSeedId, undefined);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test tools/accuracy-harness/scorer/test/attribute.test.js`
Expected: FAIL — `attribute` not defined.

- [ ] **Step 3: Implement `attribute.js`**

```js
'use strict';
function candidates(finding, seeds) {
  const t = (finding.text || finding.message || '').toLowerCase();
  return seeds.filter(s => (s.match || []).some(kw => t.indexOf(kw.toLowerCase()) >= 0));
}
function attribute(findings, seeds, judgeFn) {
  return findings.map(f => {
    if (f.seedId || f.judgedSeedId) return f;           // already attributed
    const cand = candidates(f, seeds);
    if (cand.length === 0) return f;                    // no hint → no judge call
    const chosen = judgeFn({ finding: f, candidateSeeds: cand });
    return chosen ? { ...f, judgedSeedId: chosen } : f;
  });
}
module.exports = { attribute, candidates };
```

- [ ] **Step 4: Run to verify pass**

Run: `node --test tools/accuracy-harness/scorer/test/attribute.test.js`
Expected: PASS.

- [ ] **Step 5: Document the production `judgeFn` contract in the file header**

Add a top-of-file comment: the production `judgeFn` is a single model call per finding with candidate seeds, prompt = "Does this finding assert THIS seed's actual defect (not a keyword coincidence)? Answer the seedId or null." Cite that this reimplements interrogate's "confidence from an independent judge" pattern (ADR-0001, no dependency).

- [ ] **Step 6: Commit**

```bash
git add tools/accuracy-harness/scorer/attribute.js tools/accuracy-harness/scorer/test/attribute.test.js
git commit -m "feat(harness): injectable judge-attribution seam (keyword is a hint, judge decides)"
```

---

### Task 0.5: `convert-buglog.js` — real run → findings, structured match

**Files:**
- Create: `tools/accuracy-harness/scorer/convert-buglog.js`
- Create: `tools/accuracy-harness/scorer/test/convert.test.js`
- Modify: `tools/accuracy-harness/README.md` (fix the dangling refs found in Task 0.1)

**Interfaces:**
- Consumes: a real run's bug-log — confirm the actual shape first (see Step 1).
- Produces: `module.exports = { convert }`. `convert(bugLog) -> { source, estimated:false, findings:[{ verdict, axis, suspectedLayer, text }] }` mapping each logged bug's structured fields (`expected`/`actual`/`layer`/`title`) into a finding `text` for the judge, carrying `verdict`/`suspectedLayer` through unchanged. No hand-typed keywords.

- [ ] **Step 1: Find the real bug-log shape (fact, not assumption)**

Run: `find /home/dev/projects/innovation/.qa/runs -name 'bug-log.json' | head -1 | xargs -r python3 -m json.tool | head -40`
Expected: the concrete field names of a logged bug. If none exists, inspect `skills/writing-qa-reports/` templates for the bug-log schema. **Write the converter against the real fields you see, not the names guessed here.**

- [ ] **Step 2: Write the failing test using the real shape**

Create `tools/accuracy-harness/scorer/test/convert.test.js` with a small inline bug-log literal matching Step 1's fields, asserting `convert(log).findings[0]` has `estimated:false` on the doc, a composed `text` containing the expected/actual, and the `suspectedLayer` carried through. (Fill the literal from Step 1.)

- [ ] **Step 3: Run to verify it fails** — `node --test tools/accuracy-harness/scorer/test/convert.test.js` → FAIL.

- [ ] **Step 4: Implement `convert.js`** mapping the real fields → findings; set `estimated:false`.

- [ ] **Step 5: Run to verify pass** — `node --test tools/accuracy-harness/scorer/test/convert.test.js` → PASS.

- [ ] **Step 6: Fix README dangling refs** — replace the `findings/baseline.json`/`after-fixed.json` "Measuring a real run" section with the real path: `node scorer/convert-buglog.js <run>/bug-log.json > findings/measured-<run>.json && node scorer/score.js findings/measured-<run>.json --gate`.

- [ ] **Step 7: Commit**

```bash
git add tools/accuracy-harness/scorer/convert-buglog.js tools/accuracy-harness/scorer/test/convert.test.js tools/accuracy-harness/README.md
git commit -m "feat(harness): convert real bug-log to findings via structured fields; fix docs"
```

---

### Task 0.6: `run-baseline.sh` — one-command measured run

**Files:**
- Modify: `tools/accuracy-harness/run-baseline.sh`

**Interfaces:**
- Produces: a script that (1) serves the fixture, (2) prints the exact agent invocation to QA it, (3) after the run, converts + scores, (4) tears down. It orchestrates a MEASURED run; it does not fake one.

- [ ] **Step 1: Rewrite `run-baseline.sh`** to: start `python3 -m http.server` on the fixture dir (trap-kill on exit), echo the precise `qa-e2e-pilot` agent command + fixture URL for the operator to run (the agent needs Playwright MCP; the script cannot drive the MCP itself), then on continuation run `convert-buglog.js` on the produced `bug-log.json` and `score.js --gate`.

- [ ] **Step 2: Syntax-check** — `bash -n tools/accuracy-harness/run-baseline.sh` → no output.

- [ ] **Step 3: Dry-run the serve/teardown path** (not the agent) — run the script with an env flag `QA_DRYRUN=1` that skips the agent wait; confirm it serves 200 and tears down cleanly.

- [ ] **Step 4: Commit**

```bash
git add tools/accuracy-harness/run-baseline.sh
git commit -m "feat(harness): one-command measured baseline runner (serve→run→convert→score)"
```

---

### Task 0.7: Capture the FIRST measured baseline

**Files:**
- Create: `tools/accuracy-harness/findings/measured-baseline.json`

**Interfaces:**
- Produces: the first honest number. This is the gate reference every later phase must not regress.

- [ ] **Step 1: Serve + run the agent against the fixture**

Run: `bash tools/accuracy-harness/run-baseline.sh` and follow its printed instruction to dispatch the `qa-e2e-pilot` agent at the fixture URL (requires Playwright MCP + a minimal `.qa/config.json` pointing at the served fixture). Let it produce `.qa/runs/<id>/bug-log.json`.

- [ ] **Step 2: Convert + score**

Run: `node tools/accuracy-harness/scorer/convert-buglog.js .qa/runs/<id>/bug-log.json > tools/accuracy-harness/findings/measured-baseline.json && node tools/accuracy-harness/scorer/score.js tools/accuracy-harness/findings/measured-baseline.json`
Expected: real per-axis recall + precision, labeled `(MEASURED)`. Record the numbers in the plan's Phase-0 result note. (This is the honest replacement for the deleted 30%/90% fictions — whatever it actually is.)

- [ ] **Step 3: Commit the measured baseline**

```bash
git add tools/accuracy-harness/findings/measured-baseline.json
git commit -m "test(harness): first MEASURED baseline recall/precision on the fixture"
```

- [ ] **Step 4: Write the Phase-0 exit note**

Append a short `## Phase 0 result (MEASURED <date>)` block to this plan with the real numbers and the gate verdict. Phase 1 planning starts from this number.

---

## Self-review (against the spec)

- **Spec coverage:** settled decisions 1–3 (measurement/attribution/precision) → Tasks 0.1–0.7. Decisions 4–10 → Phases 1–5 roadmap (deferred by design: their thresholds need Phase 0's measured number — expanding them now would be false precision). Fix-regardless items → mapped to Phase 0/1/4.
- **Placeholder scan:** Phase 0 tasks carry real test code + exact commands. The only intentional "fill from reality" steps are 0.5-Step-1/2 and 0.7 (they depend on the real bug-log shape + a live run — assumptions there would be fabrication; the steps command you to read the real shape first).
- **Type consistency:** `score(findingsDoc, seedsDoc)`, `attribute(findings, seeds, judgeFn)`, `convert(bugLog)`, `creditsSeed`/`candidates` helpers, `judgedSeedId`/`seedId`/`polarity`/`stream` fields are used identically across Tasks 0.2–0.6.
- **Invariant guard:** the scorer now *enforces* the verdict enum (0.3-Step-3) — the harness can no longer itself emit a 6th verdict (the exact bug found in review).

---

## Open items to confirm at execution (not assumptions to bake now)

- The real `bug-log.json` field names (Task 0.5-Step-1) — write the converter against what's actually there.
- The first MEASURED baseline number (Task 0.7) — unknown until the run; it replaces the deleted fictions.
- Whether the synthetic fixture's Phase-0 scope (no role/authz seeds) is accepted — role/authz recall is deferred to Phase 2 against `innovation`. If you want a *measured* role dimension in Phase 0, that needs a multi-role fixture (bigger Phase 0).

---

## Phase 1 result (MEASURED 2026-08-31)

Phase 1's execution-enforcement gate (`docs/plans/2026-08-30-phase1-execution-gate.md`) shipped and was re-measured against the fixture per its own exit criterion. Three runs, same fixture/seed set:

| Run | Functional | UX | Overall | Precision |
|---|---|---|---|---|
| Baseline (ungated) | 33% | 25% | 30% | 75% |
| **Gated A** (real `qa-e2e-pilot` agent, 18 seeds) | **38%** | 25% | 33% | **100%** |
| Gated B (general-purpose agent, for comparison) | 25% | 25% | 25% | 100% |

**Honest framing:** the gate lifted **precision** (75%→100% — zero false positives on the negative-control seeds; the one false-green the ungated baseline produced is gone) — it did **not**, on its own, lift **recall** materially (33%→38% functional, UX flat at 25%). That is expected and by design: the gate forces a `pass` to carry real evidence, but it cannot force the checklist to *contain* a criterion for a bug class nobody thought to test — that is a coverage problem, not an evidence problem. Recall is the explicit target of Phase 2 (the edge-case coverage catalog — see Status note in `docs/plans/2026-08-31-phase2-coverage-roles.md`, already an 8-row catalog including terminal-idempotency and input-boundary) and Phase 3/4 (the vision pass and axe detection close the UX-objective gap, which the gate alone cannot touch since U1–U3 are visual/a11y with no non-vision detector yet).

**Gated B is a control, not a regression:** the drop to 25%/25% running the SAME gated checklist through a `general-purpose` agent (vs. the real `qa-e2e-pilot` agent) shows the gate's evidence discipline is necessary but not sufficient — an agent without this plugin's domain-specific verification skills (backend baking, independent recompute) still under-recalls even when forced to produce evidence for every pass. This is a data point for why the skill-specific pipeline exists, not a finding against the gate.

**Exit criterion satisfied:** Phase 1's plan asked for a re-measurement after the gate landed; this is that number. Phase 2 planning starts from 38%/25%/33%/100%, not the 33%/25%/30%/75% baseline.

---

## Phase 6 — Packaging, dependencies & install wiring

**Why:** The plugin must install self-contained and auto-wire its true prerequisites, failing loud if any are missing — not silently break at runtime. **Posture (decided):** reimplement external *patterns* as bundled skills (no plugin-to-plugin dependency), auto-install the real *deps* (axe-core, Playwright MCP), preflight-check the *environment* (Node/jq/python3). This phase is independent of the measured baseline, so it is granular-ready and can run in parallel with Phase 0.

**Verified plugin-system capabilities (current docs) this phase relies on:**
- `package.json` at plugin root → Claude Code runs `npm install` automatically on plugin install (source: plugin-marketplaces docs).
- `.mcp.json` at plugin root → declared MCP servers become present/enabled with the plugin (source: mcp / plugins-reference docs).
- `hooks.SessionStart` in `plugin.json` → a command hook runs each session; **exit 2 blocks** with a stderr message (source: hooks docs).
- Bundling skills into `skills/<name>/` is the recommended layout; **no auto-attribution** — credit in README/LICENSE.
- `dependencies` (plugin-to-plugin, auto-install) exists but is **deliberately NOT used** — reimplement posture (ADR-0001).

**File structure (Phase 6):**
- Create: `package.json` (axe-core pinned).
- Create: `.mcp.json` (Playwright MCP declaration).
- Create: `scripts/check-prereqs.sh` (SessionStart preflight; distinct from the run-time `preflight.sh` which checks the app-under-test).
- Modify: `.claude-plugin/plugin.json` (add `hooks.SessionStart`, bump version).
- Modify: `.claude-plugin/marketplace.json` (version bump).
- Modify: `scripts/skills.json` (add the 2 missing + all new skills).
- Modify: `README.md` (attribution section for reimplemented patterns).

**ADR:** file `docs/adr/0014-packaging-and-prereqs.md` recording: reimplement-not-depend, axe via npm, Playwright MCP via `.mcp.json`, SessionStart-blocking preflight, and the axe-core exception to the dependency-free-browser-JS rule (it is injected browser-side but sourced from an npm dep).

---

### Task 6.1: `package.json` — axe-core as an auto-installed pinned dep

**Files:** Create `package.json`

- [ ] **Step 1: Confirm the current axe-core version (fact, not memory)**

Run: `npm view axe-core version`
Expected: a concrete version (e.g. `4.13.x`). Pin to that exact minor.

- [ ] **Step 2: Write `package.json`**

```json
{
  "name": "qa-e2e-pilot",
  "version": "0.4.0",
  "private": true,
  "description": "Bundled runtime deps for qa-e2e-pilot browser QA.",
  "license": "MIT",
  "dependencies": {
    "axe-core": "4.13.0"
  }
}
```

(Replace `4.13.0` with Step 1's value.)

- [ ] **Step 3: Verify install resolves + the injectable asset exists**

Run: `npm install && test -f node_modules/axe-core/axe.min.js && echo OK`
Expected: `OK` (this is the file the vision/detection pass injects via `browser_evaluate` in Phase 3/4).

- [ ] **Step 4: Commit**

```bash
git add package.json package-lock.json
git commit -m "build: pin axe-core as auto-installed plugin dependency"
```

---

### Task 6.2: `.mcp.json` — declare the Playwright MCP prerequisite

**Files:** Create `.mcp.json`

**Interfaces:** Produces the MCP server config that becomes present when the plugin is enabled. Uses the standard Playwright MCP invocation; no bundled binary.

- [ ] **Step 1: Confirm the Playwright MCP invocation the repo already assumes**

Run: `grep -rn "playwright" .mcp.json .claude-plugin/ 2>/dev/null; grep -rn "@playwright/mcp\|playwright-mcp\|browser_navigate" skills/driving-browser-qa/ | head`
Expected: the capability mapping referencing the Playwright MCP tool names (confirms the server id/tool prefix to match).

- [ ] **Step 2: Write `.mcp.json`**

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest"]
    }
  }
}
```

(Match the server key to the tool prefix the skills call, e.g. `mcp__playwright__browser_*`; adjust `command`/`args` to the invocation confirmed in Step 1. Pin `@playwright/mcp` to a known version rather than `@latest` if the skills depend on specific tools.)

- [ ] **Step 3: Validate JSON**

Run: `python3 -c "import json;json.load(open('.mcp.json'))" && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add .mcp.json
git commit -m "feat(plugin): declare Playwright MCP server so it's present on install"
```

---

### Task 6.3: SessionStart preflight hook — block on missing prerequisites

**Files:** Create `scripts/check-prereqs.sh`; Modify `.claude-plugin/plugin.json`

**Interfaces:** Produces a hook that runs each session; exit `2` blocks with a fix message, exit `0` proceeds. Checks: `node`, (`jq` OR `python3`), `bash`, `curl`, and that `node_modules/axe-core` resolved.

- [ ] **Step 1: Write the check script**

```bash
#!/usr/bin/env bash
# check-prereqs.sh — SessionStart preflight for qa-e2e-pilot.
# exit 2 = block session with instructions; exit 0 = proceed.
set -u
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
missing=()
command -v node >/dev/null 2>&1 || missing+=("Node.js (node) — needed for the accuracy scorer")
command -v bash >/dev/null 2>&1 || missing+=("bash")
command -v curl >/dev/null 2>&1 || missing+=("curl")
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  missing+=("jq OR python3 — needed by checkpoint.sh/preflight.sh")
fi
if [ ! -f "$root/node_modules/axe-core/axe.min.js" ]; then
  missing+=("axe-core — run 'npm install' in $root (usually automatic on plugin install)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "qa-e2e-pilot: missing prerequisites:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  echo "Install the above, then reload the plugin." >&2
  exit 2
fi
exit 0
```

- [ ] **Step 2: Syntax-check + prove both branches**

Run: `bash -n scripts/check-prereqs.sh && CLAUDE_PLUGIN_ROOT="$PWD" bash scripts/check-prereqs.sh; echo "exit=$?"`
Expected: `exit=0` when axe-core is installed (Task 6.1 done); temporarily rename `node_modules/axe-core` to confirm it prints the missing list and `exit=2`, then restore.

- [ ] **Step 3: Wire the hook into `plugin.json`**

Add to `.claude-plugin/plugin.json`:

```json
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/check-prereqs.sh" } ] }
    ]
  }
```

- [ ] **Step 4: Validate JSON**

Run: `python3 -c "import json;json.load(open('.claude-plugin/plugin.json'))" && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-prereqs.sh .claude-plugin/plugin.json
git commit -m "feat(plugin): SessionStart preflight blocks on missing Node/jq/axe prerequisites"
```

---

### Task 6.4: Fix `skills.json` drift + register all new skills

**Files:** Modify `scripts/skills.json`

**Interfaces:** The marketplace/npx install path enumerates skills from here (`install.sh` globs the dir and is already correct). It must list every skill on disk.

- [ ] **Step 1: Diff the manifest against disk**

Run: `comm -3 <(python3 -c "import json;[print(s['name']) for s in json.load(open('scripts/skills.json'))['skills']]" | sort) <(ls -d skills/*/ | xargs -n1 basename | sort)`
Expected: shows `bootstrapping-qa-config` and `detecting-stack-profile` (missing today) plus any skills added by Phases 1–3 (e.g. `discovering-user-roles`, the vision-review skill). Add each missing entry with its correct `category`.

- [ ] **Step 2: Add the missing entries** to the `skills` array (category per its phase/role, e.g. `detecting-stack-profile`→`plan`, `bootstrapping-qa-config`→`plan`, `discovering-user-roles`→`plan`).

- [ ] **Step 3: Re-run the diff → empty; validate JSON**

Run: `python3 -c "import json;json.load(open('scripts/skills.json'))" && echo OK`
Expected: `OK`, and Step 1's diff now empty.

- [ ] **Step 4: Commit**

```bash
git add scripts/skills.json
git commit -m "fix(install): register bootstrapping-qa-config, detecting-stack-profile, and new skills"
```

---

### Task 6.5: README attribution + version bump

**Files:** Modify `README.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`

- [ ] **Step 1: Add an attribution section to README** crediting the reimplemented *patterns* (grilling's frontier-loop, superpowers' verification Iron Law + systematic-debugging, hallmark `audit`, ui-ux-pro-max rubric, diagnose feedback-loop ladder) as inspiration, noting they are reimplemented (not vendored) per ADR-0001, and that axe-core (MPL-2.0) is bundled via npm.

- [ ] **Step 2: Bump `version` to `0.4.0`** in both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (match `package.json`).

- [ ] **Step 3: Validate both JSON files** — `for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do python3 -c "import json;json.load(open('$f'))"; done && echo OK`

- [ ] **Step 4: Commit**

```bash
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs: attribution for reimplemented patterns; bump to 0.4.0"
```
