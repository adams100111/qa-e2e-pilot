---
name: writing-qa-reports
description: >-
  Use when phase 4 (Report) of the qa-e2e-pilot pipeline is reached. Produces the structured run report: report.md, single-file report.html with verdict cards and screenshot slots, per-criterion evidence, honest DEFERRED entries with stated reasons, and an optional spec-kit traceability column when constitution/spec/tasks artifacts are present.
---

# Writing QA Reports

## Overview

Phase 4 of every Run. Consumes the evidence and checkpoints written during Verify (phase 3) and emits:
- `report.md` — structured markdown with tally, per-criterion sections, deferred entries, and a bug-report appendix.
- `report.html` — single self-contained file (inline CSS, no external assets) with colored verdict cards and relative-path screenshot slots.
- `evidence/<criterion-id>/` — screenshots, network body snapshots, and bake read-backs already written by earlier skills; this skill references them, not re-creates them.

All output lives under `.qa/runs/<run-id>/`. One run dir per invocation (ADR-0002).

## Run Directory Layout

```
.qa/runs/<run-id>/
  run-manifest.json          ← checkpointing skill owns this
  checkpoint.json            ← checkpointing skill owns this
  bug-log.json               ← checkpointing skill owns this
  traceability.json          ← checkpointing skill owns this (when spec-kit present)
  report.md                  ← this skill writes
  report.html                ← this skill writes
  evidence/
    <criterion-id>/
      screenshot-before.png
      screenshot-after.png
      bake-read-back.json
      network-response.json
      recompute.md
```

Reference evidence files by relative path from the run dir (`evidence/<criterion-id>/screenshot-after.png`). Never embed binary content in the report text.

## Process

### 1. Read run artifacts

Read `run-manifest.json` and `checkpoint.json` to get the full criterion list, their verdicts, confidence flags, evidence refs, and any bug entries. Also read `stack-profile.json` and fill the report's **Detected stack** header (`{{STACK}}`, `{{STACK_TIER}}` = the `playbook`, `{{STACK_SIGNAL}}` = the primary component `signal`); when `mode` is `black-box`/`source-drift` or any component is `signal: weak`, fill `{{STACK_DRIFT_NOTE}}` with an honest one-liner instead of removing it.

### 2. Compute the summary tally

Count criteria by verdict: `pass | fail | blocked | deferred | error`. State the total criterion count. This tally goes at the very top of both report files.

### 3. Write report.md

Copy `templates/report.md` into the run dir and fill every placeholder:

- `{{RUN_ID}}` — the run identifier.
- `{{DATE}}` — ISO-8601 date.
- `{{FEATURE}}` — feature/target label from the run manifest.
- `{{BUILD_ID}}` — build/deploy id captured at pre-flight.
- `{{TALLY_*}}` — per-verdict counts.
- One `## Criterion` section per criterion using the verdict-card fields below.
- A `## Deferred` section for every deferred criterion (never omit).
- A `## Bugs` appendix with one filled `templates/bug-report.md` block per failing criterion.

### 4. Verdict card fields (per criterion)

Every criterion section contains:

| Field | Content |
|---|---|
| **id** | Short stable identifier (e.g. `GOV-01`) |
| **title** | One-line description of the behavior |
| **verdict** | `pass` / `fail` / `blocked` / `deferred` / `error` |
| **confidence** | `high` / `low` — LOW when expected value came only from backend code |
| **oracle** | The spec/domain rule the result was judged against |
| **expected** | Value or behavior the oracle says should be true |
| **actual** | What the UI / API / DB returned |
| **evidence** | Relative paths to screenshots / network bodies / bake read-backs |
| **suspected layer** | On `fail`: one of `FE` / `route` / `service` / `migration` / `DB` |
| **bug-report** | On `fail`: link to the appendix entry (e.g. `[BUG-09](#bug-09)`) |

Confidence LOW signals "this can catch precision/propagation bugs but not a wrong formula."

### 5. DEFERRED — reason convention

A deferred criterion MUST appear in the `## Deferred` section with:
- The criterion id and title.
- A plain-English reason (e.g. "round-close math requires a closed round — not available in this env", "concurrency test requires two simultaneous sessions — deferred to load-test suite", "scenario modeling covers future projections — out of scope for this run").

Never silently drop a criterion. Never record `pass` for something not verified. If you chose not to verify it, it is `deferred`.

### 6. Bug reports

For every `fail` criterion, fill `templates/bug-report.md`:

- **Title** — one-line summary.
- **Environment + Build ID** — captured at pre-flight.
- **Steps to reproduce** — numbered, starting from a logged-in state.
- **Expected** — from the oracle (spec/domain rule). Show the recomputed value if computed logic is involved (e.g. `4,000,000 shares × $0.001/share = $4,000.00`).
- **Actual** — what the UI/API/DB returned (e.g. `$4.00`, truncated by `decimal(10,2)` column).
- **Severity** — `critical` / `high` / `medium` / `low`.
- **Suspected layer** — one of `FE` / `route` / `service` / `migration` / `DB`.
- **Suggested fix** — one concrete action (e.g. "Alter column to `decimal(15,4)` and add a migration test asserting no truncation at amount < $0.01/share").
- **Evidence refs** — relative paths.

Bug #9 example (cap-table governance, amount precision):
> Expected: 4,000,000 × $0.001 = $4,000.00 (domain rule: amount = shares × price_per_share).
> Actual: $4.00 displayed and stored.
> Suspected layer: DB/migration — `decimal(10,2)` column silently truncates sub-cent unit prices.

Show the recomputed-expected vs actual side-by-side whenever computed logic is involved. Never hide the arithmetic.

### 7. Write report.html

Copy `templates/report.html` into the run dir and replace all `{{…}}` tokens. Embed screenshots as `<img src="evidence/<criterion-id>/screenshot-after.png">` (relative paths). The file must open standalone in a browser with no network requests — all CSS is inline in the template.

Verdict card colors:
- `pass` → green (`#16a34a` background, white text)
- `fail` → red (`#dc2626`)
- `blocked` → amber (`#d97706`)
- `deferred` → grey (`#6b7280`)
- `error` → purple (`#7c3aed`)

### 8. Traceability column (optional)

Add only when spec-kit artifacts (`constitution.md`, `spec.md`, `tasks.md`) are present in the run dir or were supplied as `$2` to the `/qa-run` command.

In `report.md`, add a `## Traceability` section: a table mapping `criterion-id | spec-section | tasks-id | verdict`. In `report.html`, add the table after the verdict cards.

If no spec-kit artifacts exist, omit the section entirely — do not fabricate references.

## Mini-Evals

**Eval 1 — Precision bug, amount truncated (Bug #9)**
Criterion `GOV-09` verifies that creating a Series A issuance at 4,000,000 shares × $0.001/share stores amount = $4,000. Oracle: `amount = shares × price_per_share`. Actual stored: $4.00. The bug report must show `4,000,000 × $0.001 = $4,000.00 (expected) vs $4.00 (actual)` with suspected layer `DB/migration`. Verdict: `fail`, confidence: `low` (expected derivable only from backend column definition, not a public spec rule). The SKILL must surface this as a named bug appendix entry, never hide it under a vague "calculation error."

**Eval 2 — Honest DEFERRED (round-close math)**
The criterion `GOV-12` verifies round-close pro-rata math. The env has no closed round. Record as verdict `deferred` with reason: "Round-close math requires a completed round — not available in this env. Verify in staging after round close." The `## Deferred` section must contain this entry. The tally must show 1 deferred. Never record `pass` for this criterion.

**Eval 3 — Confidence LOW on a passing criterion**
Criterion `GOV-05` verifies ownership % displayed matches the computed value. The oracle is backend logic (no public spec formula for rounding). Verdict: `pass`, confidence: `low`. The verdict card must show `confidence: low` and a note: "Expected derived from backend rounding rule — can catch propagation bugs, not formula correctness."

## Templates

Copy these from `skills/writing-qa-reports/templates/` into the run dir at report time:
- `report.md` → `.qa/runs/<run-id>/report.md`
- `report.html` → `.qa/runs/<run-id>/report.html`
- `bug-report.md` is a reusable snippet — append one filled copy per failing criterion into the `## Bugs` appendix of `report.md`.
