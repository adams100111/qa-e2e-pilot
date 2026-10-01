---
name: writing-qa-reports
description: >-
  Use when phase 4 (Report) of the qa-e2e-pilot pipeline is reached, or to re-render the report of any existing run. Renders report.html and report.md deterministically from the run's own record (checkpoint, verification, manifest, bug-log, evidence) with scripts/render-report.sh — verdict summary, per-criterion cards with screenshot thumbnails, a full-screen screenshot viewer, honest DEFERRED entries and the bug appendix. The agent never hand-writes report HTML.
---

# Writing QA Reports

## Overview

Phase 4 of every Run. The report is **rendered, not written**: `scripts/render-report.sh` builds
both files from what the run recorded, so a report can never claim more than the record holds, and
any run — including one recorded before 0.10.0 — can be re-rendered at any time (ADR-0028).

- `report.html` — one self-contained page (inline CSS + JS, no external request; works offline from
  `file://`). Verdict summary, verification status, screenshot coverage, one card per criterion with
  a thumbnail grid; click a thumbnail for the full-screen viewer (Esc / click outside closes, ← →
  step through that criterion's screenshots), plus an **All screenshots** gallery and a verdict filter.
- `report.md` — the same content as markdown, screenshots as relative image links.

Both live in `.qa/runs/<run-id>/` (ADR-0002) and reference evidence by relative path.

## Process

### 1. Verify first

Run `scripts/qa-verify.sh <run-id>` before rendering. The renderer shows the **verifier's** verdict
wherever `verification.json` re-checked a criterion (an override is shown as such, with its
reasons), plus the run-level records (`__run-checks__`, `__phase-surface__`, `__screenshots__`).
Without `verification.json` the report says "Not independently verified" — never imply a re-check
that did not happen.

### 2. Render

```
bash "$CLAUDE_PLUGIN_ROOT/scripts/render-report.sh" .qa/runs/<run-id>          # relative image links
bash "$CLAUDE_PLUGIN_ROOT/scripts/render-report.sh" .qa/runs/<run-id> --embed  # one portable file
```

A bare `<run-id>` works from the project root. The script writes through the filesystem (Bash), so it
works when the pipeline runs as a subagent whose Write tool may not create report files. Re-run it
after anything in the run changes; output is byte-identical for an unchanged run.
(`python3 scripts/render-report.py <run-dir>`, the 0.7.1–0.9.0 entry point, still works and delegates.)

### 3. Check what it printed

The renderer prints the tally, the number of screenshots and how many pass/fail criteria carry one.
A pass/fail without a screenshot is called out on its card ("No screenshot recorded") and in the
summary — go back and take one while the run is live (`driving-browser-qa` § Screenshot Evidence).

## What the record must hold (so the render is complete)

| Shown | Comes from |
|---|---|
| verdict, confidence, result, kinds, bug ref, persona | `checkpoint.json` (checkpointing-qa-memory) |
| override + reasons, run-level checks | `verification.json` (qa-verify) |
| title, oracle, tags | `checklist.json` row, else `run-manifest.json` `checklist[]` |
| feature, build, target, dates, cost | `run-manifest.json` |
| thumbnails | `evidence/[<persona>/]<crit>/screenshot-*.{png,json}` (record-evidence.sh screenshot); loose images of older runs render marked "not provenance-bound" |
| other evidence links | the rest of the criterion's evidence dir + `evidence_refs` |
| bugs | `bug-log.json` (`entries[]`, `bugs[]` or a bare array) |
| stack line | `stack-profile.json` |

So the rules below are rules about **what to record**, not what to type into a report:

- **Verdict card fields.** Record `--last-action` with the observed result (expected vs actual for a
  fail), and the oracle on the checklist row. Confidence is `low` when the expected value could only
  come from backend code — the card shows it.
- **DEFERRED — reason.** Checkpoint `deferred` with the plain-English reason in `--last-action`
  ("Round-close math requires a completed round — not available in this env."). It renders in the
  `Deferred` section. Never drop a criterion; never record `pass` for something not verified.
- **Bugs.** One `bug-log.json` entry per failing criterion (`bug-report.md` lists the fields): title,
  steps, expected (with the recomputed arithmetic, e.g. `4,000,000 × $0.001 = $4,000.00`), actual,
  severity, suspected layer — exactly one of `FE | route | service | migration | DB` — suggested
  fix, evidence refs. Checkpoint the fail with `--bug-ref` so the card links to it.
- **Traceability.** When spec-kit artifacts are present, `traceability.json` (checkpointing-qa-memory
  Step 5) renders as a table; absent, nothing is fabricated.

## Mini-Evals

**Eval 1 — Precision bug, amount truncated (Bug #9).** `GOV-09` stores $4.00 for 4,000,000 ×
$0.001. The fail is checkpointed with `--bug-ref BUG-09`; the bug-log entry carries expected
`4,000,000 × $0.001 = $4,000.00`, actual `$4.00`, suspected layer `migration` (never `DB/migration`),
confidence `low`; the after-screenshot shows `$4.00` on screen. Rendered: a red card with the
thumbnail, a link to `BUG-09`, and the appendix entry with expected beside actual.

**Eval 2 — Honest DEFERRED (round-close math).** `GOV-12` needs a closed round the env lacks:
checkpoint `deferred` with that reason. Rendered under `Deferred` with the reason; the tally shows
1 deferred; no `pass` anywhere for it.

**Eval 3 — Confidence LOW on a pass.** `GOV-05`'s rounding oracle exists only in backend code:
checkpointed `pass --confidence low`. The card shows `confidence: low` and the summary counts it.

**Eval 4 — Report with no pictures (the 0.8.1 regression).** A run whose evidence holds only JSON
rendered a report with zero images. Now the summary says "0 of N pass/fail criteria carry a recorded
screenshot", every such card says so, and qa-verify degrades those passes to `confidence: low`.

**Eval 5 — Override must win.** The agent checkpointed `pass`; qa-verify overrode it to `fail`
(a screenshot altered after recording). The card is red, says "in-run pass → overridden by
qa-verify", and lists the reason; the tally counts it as a fail.

## Templates

- `templates/report.html` — the page shell the renderer fills (CSS, viewer markup, inline script).
- `templates/report.md` — the markdown skeleton the renderer fills.
- `templates/bug-report.md` — the field list of one bug-log entry.

Edit the templates to change the look; never hand-fill them.
