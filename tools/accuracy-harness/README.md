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
| Post-fix full pipeline (coverage catalog + computed-logic + visual-UX detection, hardened fixture) | **88%** | **100%** | **92%** | **100%** |

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
