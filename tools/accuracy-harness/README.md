# Accuracy harness — seeded-bug fixture + recall scorer

The rerunnable proof for the accuracy overhaul (see [`../../docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md`](../../docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md)).
It plants **known** bugs in a self-contained app, then scores any QA run's findings for **true bug-recall per axis**, and enforces the acceptance gate (recall thresholds + a precision floor).

## Layout

```
fixture/index.html        self-contained app (no build) with 18 planted bugs; "backend" = localStorage
seeds.json                ground-truth planted bugs + match rules + the acceptance gate thresholds
scorer/score.js           matches a findings file to seeds -> recall per axis + gate check
scorer/convert-buglog.js  converts a real run's bug-log.json -> a MEASURED findings file
scorer/pass-gate.js       reference impl of the execution-enforcement seam ("green toast != pass")
findings/                 empty until you convert a real run (see "MEASURED vs ESTIMATED" below);
                          the hand-authored baseline.json/after-fixed.json ESTIMATED projections were
                          removed — measurement must be real, not a hand-typed projection
run-baseline.sh           one-command runner
```

## Quick start

```bash
./run-baseline.sh --serve         # serve the fixture at http://localhost:8099
# then convert + score a real run (see "MEASURED vs ESTIMATED" below):
node scorer/convert-buglog.js <run>/bug-log.json > findings/measured-<run>.json
node scorer/score.js findings/measured-<run>.json --gate   # exit 1 if the acceptance gate fails
```

## UI/UX taxonomy fixture (`fixture-ux/`) — the ADR-0019 measured gate

A second, separate fixture backs ADR-0019 decision 7's "95% is a measured gate, honestly scoped."
Note the "18 planted bugs" table above describes the *original* `fixture/` (functional/journey/UX
Phase-1-4 work) — `fixture-ux/` is a distinct fixture for the UX detection engine (ADR-0019) and is
scored by its own runner and seed file, not `run-baseline.sh`/`seeds.json`.

```
fixture-ux/index.html     self-contained UI/UX taxonomy fixture: planted definite-oracle UX bugs
                           (content-rendering, i18n, image, invisible-text, modal-stacking,
                           interaction/behavioral) across the ADR-0019 detector families, plus the
                           two held-out real bugs found in the innovate-lab app (the sheet-stack
                           behavioral bug and the mm/dd/yyyy locale-date bug)
fixture-ux/snapshot.json  the committed DOM ground-truth: the detector-relevant element records
                           extracted from the fixture (one record per seed, `{seed, family, kind,
                           input}`) — headless, no browser needed to reproduce a run
scorer/ux-measure.js      the headless measured runner: dispatches the REAL shipped detector cores
                           (skills/detecting-visual-ux/scripts/ux-detectors.js,
                           skills/detecting-interaction-ux/scripts/overlay-stack.js) and the REAL
                           skills/detecting-visual-ux/scripts/adjudicate.js over snapshot.json's
                           records -> a findings file, scored by scorer/score.js against
                           seeds-ux.json. Dependency-free, deterministic, no browser — a record
                           whose core returns no signal, or whose adjudication comes back
                           known-deliberate/catalog-clean, contributes NO finding (never fabricated)
seeds-ux.json              ground truth for fixture-ux/ + the gate thresholds (recall/precision/
                           heldOutRecallMin), mirroring seeds.json's schema
run-ux-measure.sh          the one-command gate: runs ux-measure.js then score.js --gate
```

Run it:

```bash
bash tools/accuracy-harness/run-ux-measure.sh   # -> per-axis recall + held-out + precision + GATE: PASS/FAIL
```

**Gate thresholds (`seeds-ux.json`'s `gate` block):** ≥95% `ux-objective`/`overall` recall, ≥90%
precision, 100% held-out recall. **Currently measured — green — at 100% recall (12/12 gated
definite-oracle seeds), 100% precision, and 100% held-out recall (2/2)**: the two held-out seeds are
the sheet-stack behavioral bug (`SS1`, caught by `checkStackIntegrity` in `overlay-stack.js`) and the
`mm/dd/yyyy` locale-date bug (`D1`, caught by the `localeDateSignal` i18n detector added in this
effort). The generic overlap-rect heuristic (`O2`, `rect-collision`) is deliberately excluded from the
gated recall denominator — it lands in the advisory stream (`stream:"advisory"`), consistent with the
oracle-vs-heuristic split (ADR-0019 decision 1): a heuristic-only suspicion never becomes a verdict on
its own.

**Honest-measurement + `knownGap` discipline.** Findings are always PRODUCED by `ux-measure.js` running
the real cores over `snapshot.json` — never hand-edited into a findings file. If a shipped detector
can't yet catch a planted definite-oracle bug, the honest move is to mark that seed `knownGap: true` in
`seeds-ux.json` (excluding it from the gated set) rather than fake a pass; **there are none today** —
every planted definite-oracle bug in `fixture-ux/` is caught by a shipped detector. Heuristic-only
suspicions (`stream: "advisory"` seeds) are likewise excluded from the gated recall count, whether or
not the heuristic happens to fire on them.

**Scope of the 100%, honestly stated.** This measures recall/precision on the *seeded* taxonomy —
layers 1–2 of ADR-0019 (definite-oracle + code-adjudicated findings) — reproduced deterministically
from a committed snapshot. It is **not** a guarantee about unknown, in-the-wild bugs; ADR-0019 §11's
generative-critic layer 3 (sub-plan C2) remains estimated, not measured, for exactly that reason — you
cannot measure recall on unseeded bugs.

**CI-wiring follow-up.** The gate is manual/local today: `run-ux-measure.sh` is run by hand (or by an
agent) on demand. Wiring it into `.github/workflows` so it runs automatically on every PR is a
follow-up, not yet done.

## The 18 planted bugs (axes)

| id | axis | bug |
|----|------|-----|
| F1 | functional | ownership % uses issued-only denominator (spec: fully-diluted incl. ESOP pool) |
| F2 | functional | SAFE `amount = shares x price` truncated to 2 decimals (sub-cent loss) |
| F3 | functional | totals not re-reconciled after a founder delete (stale aggregate) |
| F4 | functional | negative share count accepted with no validation (ownership goes negative / exceeds 100%) |
| J1 | broken-journey | "Ghost" founder: green toast fires, write never persists |
| J2 | broken-journey | Finalize flips status COMPLETE + redirects but creates no holdings |
| J3 | broken-journey | every 3rd add silently drops the write (persists N-1) |
| J4 | broken-journey | 0-share submit shows a false success toast but persists nothing |
| U1 | ux-objective | helper text contrast ~1.9:1 (< WCAG AA 4.5:1) |
| U2 | ux-objective | amount cell clips the value (overflow:hidden) |
| U3 | ux-objective | 16x16 icon button (< WCAG 2.2 AA 24x24 target-size) |
| U4 | ux-objective | icon button with no accessible name + throws on click |
| S1 | ux-subjective | garish/inconsistent finalize panel — **advisory only, never a verdict** |
| N1 | functional (negative control) | whole-cent SAFE amount computes correctly — must NOT be flagged |
| N2 | ux-objective (negative control) | primary button contrast ~17:1 passes AA — must NOT be flagged |
| N3 | broken-journey (negative control) | editing a persisted founder does persist — must NOT be flagged as a silent drop |
| P1 | ux-perceptual (advisory-eligible) | Finalize CTA below the fold with no affordance — vision-pass only |
| P2 | ux-perceptual (advisory-eligible) | amount column right-aligned vs. left-aligned labels — vision-pass only |

## MEASURED vs ESTIMATED

Earlier, bundled `findings/*.json` were **ESTIMATED** projections derived from the miss taxonomy
(carrying `"estimated": true`, printed by the scorer as `(ESTIMATED)`) — these hand-authored
projections have since been removed; measurement must be real. To get **MEASURED** numbers:

1. `./run-baseline.sh --serve` (leave running at `http://localhost:8099`).
2. Set `.qa/config.json` `baseUrl` to `http://localhost:8099`, single-repo (no backend repo — the
   fixture is black-box; ownership/precision oracles are supplied in `seeds.json` so recompute stays
   `confidence: high`). Run the `qa-e2e-pilot` agent against it.
3. Convert the run's `.qa/runs/<id>/bug-log.json` to a findings file with `scorer/convert-buglog.js`
   (it reads the bug-log's real structured fields — title/expected/actual/suspected_layer — and
   composes each into a finding's `text`, carrying `verdict`/`suspectedLayer` through unchanged; no
   hand-typed keywords, and it sets `"estimated": false` so the scorer prints `(MEASURED)`):
   ```bash
   node scorer/convert-buglog.js <run>/bug-log.json > findings/measured-<run>.json
   node scorer/score.js findings/measured-<run>.json --gate
   ```

The converted findings carry no `seedId` — scoring against `seeds.json` attributes them to fixture
seeds via the judge seam (`scorer/attribute.js`): a seed's `match` keywords are only a HINT that gates
a judge call, never a bare-keyword scorer credit (see `score.js` for the strict-attribution rule).

## What this harness proves

All numbers below are **MEASURED** (`findings/measured-*.json`, `"estimated": false`), not projected.

| run | functional | ux-objective | overall | precision |
|-----|-----------:|-------------:|--------:|----------:|
| Baseline (ungated, old fixture) | 33% | 25% | 30% | 75% |
| Gated run A (real `qa-e2e-pilot` agent, 18-seed set) | 38% | 25% | 33% | 100% |
| Gated run B (general-purpose agent, gated flow) | 25% | 25% | 25% | 100% |
| Post-fix full pipeline (fixture-ASSISTED — see caveat) | 88% | 100% | 92% | 100% |
| Truly-blind, BEFORE coverage fixes (browser-only, no source read) | 56% | 75% | 62% | 100% |
| **Truly-blind, AFTER coverage fixes (v0.6.x)** | **78%** | **100%** | **85%** | **100%** |

> **The honest blind number is 78% functional / 100% ux-objective / 85% overall / 100% precision — GATE PASS.** Reaching it took two corrections. (1) The served fixture used to leak its seeds (comments describing each bug, "planted bugs" title, "(N4)" labels) — stripping those + requiring browser-only interaction dropped the inflated 88–100% to a real **62% (gate FAIL)**. (2) That blind run exposed genuine coverage gaps — the checklist checked "was invalid input rejected" but not "did a false success toast fire" (J4/F4), and the icon-button was never click-probed (U4). Sharpening those assertions (toast-vs-persistence baked check; required icon click-probe) lifted blind recall to **85% (gate PASS)**. The only two remaining misses are the `Ghost` magic-name drop (J1 — nearly unfindable black-box, a contrived seed) and F4 (the fixture appears to *reject* negatives with a false toast, which is caught as the J4 class, so F4-as-specified may not reproduce). This is the trustworthy, defensible number.

> **⚠️ (historical) The 88–100% rows are fixture-ASSISTED, not blind.** The served fixture used to leak its own seeds — HTML/CSS/JS comments described each planted bug, the `<title>` said "planted bugs", a "Negative controls" heading + `(N4)` labels named the controls. Any agent that `curl`-ed the page saw those hints, inflating recall to 88–100%. After stripping the tells AND requiring the agent to interact **browser-only (no source read)**, the honest recall is **56% functional / 62% overall (gate FAIL)** at 100% precision. Caught blind: ownership/precision/stale-total (F1/F2/F3), finalize (J2), UI-impossible archive (H1), contrast/target-size/clip (U1/U2/U3). Missed blind: the `Ghost` magic-name drop (J1 — nearly unfindable black-box, a contrived seed), the intermittent every-3rd drop (J3), the 0-share/negative-share **toast-vs-persistence** discrepancy (J4/F4 — a real coverage gap: the checklist checked "was it rejected" but not "did a false success toast fire"), and the `?` icon-button's click-time console error + missing name (U4 — caught its contrast/size but never clicked it). This is the trustworthy number; the coverage gaps (toast-vs-persistence on invalid input, icon-button click-probes) are the improvement target.

- **Baseline reproduces the false-greens**: functional 33%, ux-objective 25%, overall 30% (3/10) — the
  MEASURED number that reproduces the reported ~40% functional / ~15% UX false-greens, at only 75%
  precision (1 false positive).
- **Honest framing — the Phase-1 gate lifted precision, not yet recall**: the execution-enforcement
  evidence gate (ADR-0010) took precision from 75% -> **100%** on both gated runs (zero false greens);
  it did not yet move functional/UX recall (38% and 25% respectively, ux flat at 25%). Recall gains are
  **deferred to Phase 2 (coverage/roles) and Phase 3/4 (vision + detection layer)** — this harness is
  the regression tripwire each of those phases must clear without giving back the precision win.
- Seed set = 18 (`F1`-`F4`, `J1`-`J4`, `U1`-`U4` functional/journey/UX-objective; `S1` subjective-advisory;
  `N1`-`N3` negative controls that must stay silent; `P1`-`P2` perceptual, vision-pass-only and excluded
  from the verdict-recall gate).
- **The gate is real**: `score.js --gate` exits non-zero below threshold; `pass-gate.js` rejects a
  toast-only `pass`.
