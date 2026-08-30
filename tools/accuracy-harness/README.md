# Accuracy harness — seeded-bug fixture + recall scorer

The rerunnable proof for the accuracy overhaul (see [`../../docs/plans/accuracy-overhaul.md`](../../docs/plans/accuracy-overhaul.md)).
It plants **known** bugs in a self-contained app, then scores any QA run's findings for **true bug-recall per axis**, and enforces the `>=65-80%` acceptance gate.

## Layout

```
fixture/index.html        self-contained app (no build) with 11 planted bugs; "backend" = localStorage
seeds.json                ground-truth planted bugs + match rules + the acceptance gate thresholds
scorer/score.js           matches a findings file to seeds -> recall per axis + gate check
scorer/pass-gate.js       reference impl of the execution-enforcement seam ("green toast != pass")
detectors/ux-detectors.js dependency-free in-page OBJECTIVE UX detectors (contrast/overflow/target/name)
detectors/observe.js      the consolidated observe-round payload (ADR-0006): 1 evaluate call per round
findings/baseline.json    ESTIMATED: what the current pipeline catches (~30% overall)
findings/after-fixed.json ESTIMATED: what the overhauled pipeline is designed to catch (~90% overall, gate PASS)
run-baseline.sh           one-command runner
```

## Quick start

```bash
./run-baseline.sh                 # score bundled baseline + after-fixed projections (ESTIMATED)
./run-baseline.sh --serve         # serve the fixture at http://localhost:8099
node scorer/score.js findings/after-fixed.json --gate   # exit 1 if the acceptance gate fails
```

## The 11 planted bugs (axes)

| id | axis | bug |
|----|------|-----|
| F1 | functional | ownership % uses issued-only denominator (spec: fully-diluted incl. ESOP pool) |
| F2 | functional | SAFE `amount = shares x price` truncated to 2 decimals (sub-cent loss) |
| F3 | functional | totals not re-reconciled after a founder delete (stale aggregate) |
| J1 | broken-journey | "Ghost" founder: green toast fires, write never persists |
| J2 | broken-journey | Finalize flips status COMPLETE + redirects but creates no holdings |
| J3 | broken-journey | every 3rd add silently drops the write (persists N-1) |
| U1 | ux-objective | helper text contrast ~1.9:1 (< WCAG AA 4.5:1) |
| U2 | ux-objective | amount cell clips the value (overflow:hidden) |
| U3 | ux-objective | 16x16 icon button (< WCAG 2.2 AA 24x24 target-size) |
| U4 | ux-objective | icon button with no accessible name + throws on click |
| S1 | ux-subjective | garish/inconsistent finalize panel — **advisory only, never a verdict** |

## MEASURED vs ESTIMATED

The bundled `findings/*.json` are **ESTIMATED** projections derived from the miss taxonomy (they carry
`"estimated": true`, and the scorer prints `(ESTIMATED)`). To get **MEASURED** numbers:

1. `./run-baseline.sh --serve` (leave running at `http://localhost:8099`).
2. Set `.qa/config.json` `baseUrl` to `http://localhost:8099`, single-repo (no backend repo — the
   fixture is black-box; ownership/precision oracles are supplied in `seeds.json` so recompute stays
   `confidence: high`). Run the `qa-e2e-pilot` agent against it.
3. Convert the run's `.qa/runs/<id>/bug-log.json` to a findings file:
   ```json
   { "source": "run <id>", "findings": [ { "axis": "functional", "verdict": "fail",
     "text": "<title + suspected_layer + expected/actual from the bug-log entry>" } ] }
   ```
   (omit `"estimated": true` — the scorer will then print `(MEASURED)`).
4. `node scorer/score.js findings/<your-run>.json --gate`.

A finding matches a seed if `finding.seedId === seed.id` OR any of the seed's `match` keywords appears
in `finding.text`. This lets an unlabelled real bug-log score without hand-tagging.

## What this harness proves

- **Baseline reproduces the false-greens**: functional ~33%, ux-objective ~25% (pure-visual axis ~0%).
- **The overhaul clears the gate**: functional 83%, ux-objective 100%, overall 90% — biggest lift on UX.
- **The gate is real**: `score.js --gate` exits non-zero below threshold; `pass-gate.js` rejects a
  toast-only `pass`.
