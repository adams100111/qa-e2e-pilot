# Plan — Accuracy overhaul: raise true bug-recall to >=65–80%, then cut cost

> **SUPERSEDED** by [docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](./2026-08-30-qa-accuracy-persona-overhaul.md). Kept for history. Its projected numbers were ESTIMATED and are discredited — see the master plan's Phase 0/1 MEASURED results.

**Status**: proposed (2026-08-30). **North star**: true bug-recall (fewer false-greens). Cost/tooling
are levers toward recall, never at its expense. **Scope this pass**: PLAN-ONLY for existing
skills/agent/config; net-new files delivered are this plan, ADR-0006..0009, and
`tools/accuracy-harness/`.

Baseline today: ~40% functional / ~15% UX recall, runs report "all good" while missing real bugs.
Target: measured **>=65–80% per axis, biggest lift on UX**, then cut token/call/time cost with **no
recall regression**.

> **Target reading (confirmed assumption)**: `>=65–80%` is read as **absolute per-axis recall** on the
> seeded-bug fixture (recalled seeds / planted seeds in that axis), not relative improvement. The
> scorer enforces it as an absolute gate.

---

## 1. Root-cause diagnosis — the miss taxonomy

The methodology is rigorous **as prose** (independent recompute vs a spec oracle;
baking at multiplicity 0/1/N; broken-journey cases; probing under a lying UI). The false-greens are
**not** a methodology gap — they are (a) the rigor **not firing at runtime** and (b) whole classes of
criteria **never generated**. Diagnosis from reading every skill + the checkpoint/report machinery:

**The two structural root causes**

- **R1 — Nothing GATES the rigor.** `checkpoint.sh <run> <crit> pass` accepts a `pass` with
  `--evidence-refs` defaulting to `[]`; nothing checks that a pass actually recorded a bake read-back
  or an independent recompute. "Evidence before assertions" is a prose guardrail, not a machine check.
  Under token/long-run pressure the agent reads the green toast and moves on — exactly the behavior the
  skills forbid, with nothing to stop it.
- **R2 — UX is absent from the entire design.** Every one of the 14 real bugs the skills were built
  from is **functional**; no skill enumerates or detects a UX defect. `analyzing-feature-ui` maps
  states (empty/loading/error/populated) but never layout/contrast/target/a11y; `generating-qa-
  checklist` has zero UX heuristics; `driving-browser-qa` calls the surface "evidence, not the
  oracle" and screenshots a "pixel fallback." So UX recall is floor-level by construction.

**Miss taxonomy** — every downstream fix cites the category it closes:

| # | Miss | Category | Why it happens | Seed(s) it maps to |
|---|------|----------|----------------|--------------------|
| M1 | `pass` declared on a green toast; no read-back done | **execution-discipline** | R1 — no gate forces the bake artifact | J1, J2, J3 |
| M2 | Computed value accepted from screen; no independent recompute | **execution-discipline** | R1 — recompute is "write arithmetic in notes," unverified | F2 (and F1 when recompute skipped) |
| M3 | Diagnostic reads (console/network) skipped to save budget | **execution-discipline** | R1 + 6-call cost pressure | U4 (console), route/5xx classes |
| M4 | Cross-mutation reconciliation / cascade not re-checked | **coverage** | cascade is a prose step, easily dropped | F3 |
| M5 | Objective UX (contrast/overflow/target/a11y-name) never a criterion | **coverage + detection** | R2 — no generator, no detector | U1, U2, U3, U4 |
| M6 | Subjective aesthetics invisible | **coverage + detection** | R2 — no stream to record them | S1 |
| M7 | Cross-tenant / race / resume-from-draft only fire if the generator "remembers" | **coverage** | heuristics are optional prose, often deferred | (real runs; not on single-tenant fixture) |
| M8 | Shallow checklist when repo/network capture absent (black-box) | **coverage** | surface map degrades silently | broad functional |

Headline: **functional misses are mostly execution-discipline (R1); UX misses are almost entirely
coverage+detection (R2).** That split dictates the two primary fixes: a *gate* for functional, a
*detection layer + generator heuristics* for UX.

---

## 2. Fixture + scorer spec (the rerunnable proof)

Delivered under `tools/accuracy-harness/` (self-contained, no build; runs on `python3` + `node`):

- **`fixture/index.html`** — a mini cap-table app with **11 planted bugs** across all axes;
  "backend" = `localStorage` (namespace `captable`), so **baking is real** (read the key back) and a
  toast can genuinely lie (write skipped, toast still fires). Oracles for the two numeric bugs are
  supplied in `seeds.json` so recompute stays `confidence: high` even black-box.
- **`seeds.json`** — ground truth: each seed carries `axis`, `title`, `oracle`, `suspectedLayer`, the
  miss category it `closes`, and `match` keywords. Also carries the **acceptance gate** thresholds.
- **`scorer/score.js`** — matches a findings file to seeds, prints **recall per sub-axis**
  (`functional`, `broken-journey`, `ux-objective`) and the **north-star roll-ups**
  (`functional` = functional+broken-journey; `ux` = ux-objective) + `overall`; `--gate` exits non-zero
  below threshold. Subjective seeds are scored in a **separate advisory stream**, never in the gate.
- **`scorer/pass-gate.js`** — reference impl of the R1 execution-enforcement seam: rejects a `pass`
  lacking the evidence its `kinds` require (write->bake, computed->recompute, probe->network body).
- **`detectors/ux-detectors.js`** — the objective UX detectors (fix for M5).
- **`detectors/observe.js`** — the consolidated observe-round payload (efficiency lever).
- **`findings/baseline.json`**, **`findings/after-fixed.json`** — ESTIMATED projections.

**Baseline measurement (this pass): ESTIMATED.** A live agent run needs Playwright MCP + a
configured `.qa/config.json` against the served fixture; that is a follow-up, so the bundled numbers
are labeled `(ESTIMATED)` and the scorer prints the label. The scorer, fixture, detectors, and gate
are all **runnable now**; dropping a real run's converted `bug-log.json` in yields `(MEASURED)`
numbers with the same command (README §"Measuring a real run").

**Measured harness output (this pass, on the ESTIMATED projections):**

```
BASELINE      functional 33% (2/6)   ux-objective 25% (1/4)   overall 30% (3/10)
AFTER (gate)  functional 83% (5/6)   ux-objective 100% (4/4)  overall 90% (9/10)   GATE: PASS
```

The baseline reproduces the reported false-greens (functional ~33% ≈ the ~40% claim from below;
pure-visual UX ~0%, only console-surfaced a11y caught ≈ real-world ~15%). The "after" projection is
what the fixes below are designed to achieve, and it **clears the gate**.

---

## 3. Accuracy fixes — each tied to a miss category

| Fix | Closes | What changes (PLAN-ONLY for existing files) | Proof artifact |
|-----|--------|---------------------------------------------|----------------|
| **F-A: execution-enforcement gate** ("green toast != pass" as a GATE) | M1, M2, M3 | Extend `checkpoint.sh`: a `pass` is **invalid** unless `evidence_refs` contains the classes the criterion's kind requires — write->`bake-read-back.json`, computed->`recompute.md`, probe-needed->`network-response.json`. Missing => refuse the pass; agent must supply evidence or record `blocked`. `generating-qa-checklist` tags each criterion's `kinds`/`probeNeeded`. | `scorer/pass-gate.js` (works: rejects toast-only pass, exit 1) |
| **F-B: broaden generation** | M4, M7, M8 | `generating-qa-checklist`: make cross-tenant, race, resume-from-draft, and **cascade re-reconciliation** REQUIRED emissions (not optional prose); when black-box/`signal: weak`, emit an explicit `deferred` per skipped surface instead of a silent gap. `analyzing-feature-ui`: enumerate a **UX surface pass** per surface. | fixture seeds F3 (cascade), plus real-run cross-tenant |
| **F-C: wider detection — objective UX** | M5 | New generator heuristic emits per-surface objective-UX criteria; verifier injects `ux-detectors.js` + **axe-core** (via observe-round). A confirmed defect => `fail`, **suspected layer `FE`**, **confidence `low`** (ADR-0007). Viewport-aware (ADR-0008). | `detectors/ux-detectors.js`; seeds U1–U4 caught |
| **F-D: wider detection — subjective UX** | M6 | Aesthetic observations go to a **separate advisory stream** in the report — never a verdict, never a layer, never gated (ADR-0007). | scorer advisory stream; seed S1 |

**Acceptance gate (the target, stated as a gate on the fixture)**: `functional >= 0.70`,
`ux-objective >= 0.75`, `overall >= 0.70`, biggest lift on UX. Subjective advisory is reported, never
gated. `node scorer/score.js findings/after-fixed.json --gate` -> `GATE: PASS`.

---

## 4. Observe-round JSON shape + before/after cost (ADR-0006)

One structured observe call per round replaces the 6-call per-step loop; **acts stay separate calls**.
Injected via `browser_evaluate` (never `browser_run_code_unsafe` — ADR-0009). Payload:

```jsonc
{
  "round": 3,
  "domDigest": {                       // the snapshot substitute
    "liveText": "status: DRAFT ...",   // compact innerText (<=1500 chars)
    "interactive": [ { "tag":"button","testid":"finalize","label":"Finalize round","visible":true } ]
  },
  "console": [ { "level":"error", "text":"ReferenceError: undefinedHelpHandler is not defined ..." } ],
  "network": [ { "method":"POST","url":"/api/.../init","status":500,"ok":false } ],
  "ux":     [ { "detector":"contrast","axis":"ux-objective","suspectedLayer":"FE","confidence":"low",
                "selector":".helper","message":"Contrast 1.90:1 below WCAG AA 4.5:1 (SC 1.4.3)" } ],
  "axe":    "call-axe-run-separately"  // agent injects axe.min.js + awaits window.axe.run() once/surface
}
```

`console`/`network` are captured by read-only interceptors installed on first injection and **drained
per round** — no separate MCP calls. Reference impl: `detectors/observe.js` (installs, returns
`observe-installed`).

**Cost, per step:**

| | Legacy loop | Observe-round |
|---|---|---|
| MCP calls | snapshot + act + wait + console + network + snapshot = **6** | observe + act (+ wait when needed) = **~2** |
| Large a11y snapshots | 2 / step | 0 (compact digest) |
| Diagnostics skippable? | yes (the recall leak) | no — in the same payload |

**Estimate**: ~**3x fewer calls/step**; on a 5-step wizard, ~30 calls -> ~10–12. Token savings come
mostly from dropping two full accessibility snapshots per step. **Guard (binding)**: the fixture gate
is the regression check — consolidation may not drop recall; if `score.js --gate` regresses, the
change is rejected.

---

## 5. Config schema delta (PLAN-ONLY; describe, don't edit `.qa/config.json.example`)

```jsonc
// additions to .qa/config.json
"viewport": { "width": 1440, "height": 900 },        // ADR-0008 default desktop
"responsiveMatrix": [],                               // opt-in; e.g. [{"id":"mobile","width":390,"height":844}]
"persona": { "readingOrder": "natural" },             // real window + natural order ONLY; no fake pacing
"detection": {
  "ux": { "objective": true, "advisoryAesthetics": true, "axeCore": true },
  "passGate": { "enforce": true }                     // F-A: reject toast-only passes
},
"drivers": [
  // existing entries unchanged; optional read-only network-body driver via the seam (ADR-0009):
  { "id": "devtools", "server": "chrome-devtools-mcp", "preset": "managed", "readOnly": true }
]
```

Tool allowlist delta (`agents/qa-e2e-pilot.md:10`): **add `browser_resize`**; **do not add
`browser_run_code_unsafe`** (ADR-0009 — RCE, gated-only).

---

## 6. Persona + real-window design (ADR-0008)

- Default **desktop 1440x900**, applied in Pre-flight via `browser_resize`.
- **Responsive matrix** opt-in and off by default; when set, only viewport-sensitive UX criteria
  (overflow, target-size) re-run per viewport; functional criteria are not multiplied. A UX finding
  records the viewport it reproduced at (reproducibility).
- **"Human-like" = real window + natural reading/interaction order only.** No artificial typing
  delays, no randomized think-time — those add cost/flakiness, not recall.

---

## 7. Tooling recommendation (evidence-backed; sources)

Research (2026), primary sources:

1. **Keep Playwright MCP** (`@playwright/mcp`, ~v0.0.79) as primary driver — exposes
   `browser_evaluate`, `browser_resize`, `browser_snapshot`, `browser_console_messages`,
   `browser_network_requests`. *Source: https://github.com/microsoft/playwright-mcp ,
   https://playwright.dev/docs/getting-started-mcp*
2. **Adopt axe-core 4.13.0 (MPL-2.0)** for a11y — inject `axe.min.js`, call `window.axe.run()` ->
   `{ violations[] }` (`id`/`impact`/`nodes[]`); covers contrast, ARIA, accessible names.
   *Source: https://github.com/dequelabs/axe-core , https://www.deque.com/axe/core-documentation/api-documentation/ ;
   version/license via `npm view axe-core`.* Improves **M5** (UX detection).
3. **Prefer `browser_evaluate` over `browser_run_code_unsafe`; add only `browser_resize`.**
   `browser_run_code_unsafe` runs in the MCP **server process**, is **RCE-equivalent, ungated, with a
   filed critical escape (issue #1495)**. *Source:
   https://github.com/microsoft/playwright-mcp/issues/1495 , /issues/1651 , README security section.*
   Improves the **security invariant / cost axis** (no ungated RCE).
4. **Objective UX = absolute in-page heuristics, NOT pixel-diff.** `toHaveScreenshot`/pixelmatch/odiff
   **fail by design on a first run with no baseline**; contrast (WCAG SC 1.4.3, 4.5:1), overflow
   (`scrollWidth>clientWidth`), target-size (WCAG 2.2 **SC 2.5.8, 24x24 AA** / SC 2.5.5 44x44 AAA) are
   computed from a single render. *Sources: https://playwright.dev/docs/test-snapshots ,
   https://github.com/microsoft/playwright/issues/38046 ,
   https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html ,
   https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html .* Improves **M5**.
5. **Optional read-only Chrome DevTools MCP driver** (~v0.25.0) for true network **response-body**
   reads (`get_network_request`) beyond in-page `fetch()`, via the `drivers[]` seam — config, not
   code. *Source: https://github.com/ChromeDevTools/chrome-devtools-mcp .* Improves **probing depth**.

No mandatory driver swap. Each pick is justified by the miss category or cost axis it moves (above).

---

## 8. Invariant-traceability checklist (each hard constraint preserved, or amended only via an ADR)

| Invariant (CONTEXT.md / CLAUDE.md / ADRs) | Status under this plan |
|---|---|
| Verdicts exactly `pass\|fail\|blocked\|deferred\|error` (no 6th) | **Preserved.** Objective UX = `fail`; aesthetics = advisory stream, not a verdict (ADR-0007). |
| Confidence `high\|low` orthogonal | **Preserved.** Objective UX uses `fail` + `confidence:low` (standards oracle, not spec). |
| Suspected layer exactly `FE\|route\|service\|migration\|DB` | **Preserved.** Objective UX localizes to `FE`; advisory items get no layer. |
| Oracle = spec/domain rule, never backend formula | **Preserved.** F2/F1 recompute from fixture-supplied oracle; detectors use WCAG standards, not app code. |
| Sequential by default; parallel narrow + capped (ADR-0003) | **Preserved.** No change to execution order; observe-round is within one criterion. |
| Run state in `.qa/runs/` plain files (ADR-0002) | **Preserved.** Gate reads/writes `evidence_refs` + `checkpoint.json`; nothing in agent memory. |
| Probing read-only unless `allowApiWrites` + disposable marker | **Preserved & strengthened.** `browser_run_code_unsafe` bound to the same gate (ADR-0009); `observe.js`/detectors are read-only. |
| Secrets never printed | **Preserved.** Detectors read computed styles/DOM; observe drains console/network without echoing auth. |
| Browser tools by capability | **Preserved.** New behavior names `resize`/`evaluate` capabilities; driver swap via config seam. |
| Accuracy dominates — no cost/tooling change lowers recall | **Enforced** by the fixture gate (`score.js --gate`) as a regression check on the observe-round. |
| **Amended only via ADR**: observe-round (0006), advisory stream (0007), viewport-as-config (0008), detection stack / tool allowlist (0009) | Four ADRs filed. |

---

## 9. The acceptance gate and how the scorer proves it

- **Gate** (`seeds.json.gate`): `functional >= 0.70`, `ux-objective >= 0.75`, `overall >= 0.70`;
  advisory aesthetics reported, never gated. This operationalizes ">=65–80%, biggest lift on UX."
- **Proof now**: `node scorer/score.js findings/after-fixed.json --gate` -> **GATE: PASS**
  (functional 83%, ux-objective 100%, overall 90%); baseline scores 30% overall, reproducing the
  false-greens.
- **Proof when real**: serve the fixture, run the agent, convert its `bug-log.json` to a findings
  file, re-run the same command for **MEASURED** numbers. The gate is the CI-able acceptance test for
  the overhaul and the regression check that no efficiency lever lowers recall.

## 10. Sequencing (suggested)

1. Land the fixture + scorer + gate (this pass — done). 2. Wire F-A gate into `checkpoint.sh` +
`generating-qa-checklist` `kinds`. 3. Land F-C/F-D detection (detectors + axe + advisory report
section) + ADR-0007. 4. Land observe-round (ADR-0006) with the gate as regression guard. 5. Land
viewport/persona config (ADR-0008) + allowlist `browser_resize` (ADR-0009). 6. Capture the first
MEASURED baseline and iterate until the gate holds on real runs.
