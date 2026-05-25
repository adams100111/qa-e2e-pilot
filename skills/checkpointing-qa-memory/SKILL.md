---
name: checkpointing-qa-memory
description: Use when starting, running, or resuming a qa-e2e-pilot Run. Manages all resumable memory-spec artifacts (run-manifest, checkpoint, bug-log, traceability) as plain files under `.qa/runs/<run-id>/`. Ensures a long Run survives context compaction by checkpointing every criterion to disk so completed work is skipped on resume. Enforces ADR-0002: per-criterion state NEVER goes to the agent's personal memory.
---

# Checkpointing QA Memory

## Overview

Every Run produces four memory-spec artifacts in `.qa/runs/<run-id>/`:

| Artifact | Purpose | Owner |
|---|---|---|
| `run-manifest.json` | Run identity, target, driver pool, checklist, overall status | this skill |
| `checkpoint.json` | Per-criterion resume cursor (verdict, evidence refs, last action) | this skill |
| `bug-log.json` | Append-only findings discovered during the run | this skill |
| `traceability.json` | Criterion ↔ spec/constitution/tasks ↔ verdict mapping | this skill (only when spec-kit artifacts exist) |

The sibling skill `writing-qa-reports` owns `report.md` and `report.html` in the same run dir. This skill owns everything above.

## Run Directory Layout

```
.qa/runs/<run-id>/
  run-manifest.json
  checkpoint.json
  bug-log.json
  traceability.json          ← only when spec-kit artifacts are present
  report.md                  ← writing-qa-reports skill
  report.html                ← writing-qa-reports skill
  evidence/
    <criterion-id>/
      screenshot-after.png
      bake-read-back.json
      network-response.json
```

## ADR-0002 Boundary (read this first)

> **NEVER write per-criterion state to the agent's personal memory** (`~/.claude/.../memory/` + `MEMORY.md`).

Why: per-criterion checkpoints are transient run state that gets skipped on resume — the opposite of the durable facts that system is designed for. Writing them to `MEMORY.md` pollutes the global index loaded into every session for every project.

**What IS allowed (optional):** one durable entry per project-under-test in personal memory — a pointer to the latest run-id and any known-flaky areas. One entry, never per-criterion.

**Future note:** a Mem0/vector backend is a documented optional swap for the `.qa/` file store — not a v1 dependency. The file-based layout is the interface; the storage backend is pluggable.

---

## Process

### Step 1 — Start a Run

1. Generate a run-id: `<YYYYMMDDTHHMMSS>-<slug>` where slug is a short kebab-case feature label (e.g. `20241115T143022-founder-cap-table`).
2. Create `.qa/runs/<run-id>/`.
3. Copy `templates/run-manifest.md` into `.qa/runs/<run-id>/run-manifest.json` and fill every `{{TOKEN}}`.
4. Copy `templates/bug-log.md` into `.qa/runs/<run-id>/bug-log.json` and set `entries: []`.
5. If spec-kit artifacts (spec, constitution, tasks files) exist in the project, also copy `templates/traceability.md` → `traceability.json` and populate the criterion rows from the checklist. Skip this file entirely if no spec-kit artifacts exist.
6. Set `run-manifest.status` to `in-progress`.

**Run-id generation (copy-paste):**
```bash
RUN_ID="$(date -u +%Y%m%dT%H%M%S)-<your-slug>"
mkdir -p ".qa/runs/$RUN_ID"
```

### Step 2 — Checkpoint After Every Criterion

After completing each criterion (any verdict: pass/fail/blocked/deferred/error):

1. Call `scripts/checkpoint.sh <run-id> <criterion-id> <verdict>` to upsert the checkpoint record.
2. Set `evidence_refs` to relative paths of any files written under `evidence/<criterion-id>/`.
3. Set `last_action` to a one-line description of the final action taken.
4. If verdict is `fail` or `error`: append a new entry to `bug-log.json` (copy the entry shape from `templates/bug-log.md`). Fill `title`, `steps`, `expected`, `actual`, `severity`, `suspected_layer`, `fix`.
5. If `traceability.json` exists: update the row for this criterion with `verdict` and `confidence`.
6. Update `run-manifest.json` — increment `criteria_done`, update `status` if all criteria are resolved.

**Severity scale:** `critical` | `high` | `medium` | `low`
**Suspected layer:** `FE` | `route` | `service` | `migration` | `DB` (the canonical set from CONTEXT.md)

### Step 3 — Resume Protocol

On any restart (context compaction, interrupted run, new session):

```
1. Find the latest in-progress run for this target:
   ls -t .qa/runs/ | head -20
   grep -l '"status": "in-progress"' .qa/runs/*/run-manifest.json | tail -1

2. Read run-manifest:
   cat .qa/runs/<run-id>/run-manifest.json

3. Read the last completed checkpoint:
   scripts/checkpoint.sh --resume <run-id>
   (prints: last completed criterion-id, verdict, phase, evidence_refs, last_action)

4. SKIP all criteria whose checkpoint verdict is already recorded.
   Continue from the FIRST criterion with no checkpoint entry.

5. Re-verify the immediate preconditions for that criterion
   (the environment may have changed; don't assume prior state holds).
```

This is the mechanism that made the original governance QA run survive context compaction: the agent re-reads checkpoint.json on every resume and jumps straight to the first unfinished criterion.

### Step 4 — Close a Run

1. Set `run-manifest.status` to `complete` (or `aborted` if stopped early).
2. Record `ended_at` (ISO-8601).
3. Hand off to `writing-qa-reports` for `report.md` / `report.html`.
4. (Optional) Write ONE durable entry to personal memory:
   ```
   Project: <project-name>
   Latest run: <run-id>
   Known flaky: <comma-separated criterion-ids or "none">
   ```
   One line per project. Never per-criterion. Update the existing line if one exists.

### Step 5 — Spec-Kit Ingestion Hook (Traceability)

Only when spec-kit artifacts exist (spec doc, constitution, tasks file):

1. At Step 1, copy `templates/traceability.md` → `traceability.json`.
2. For each criterion in the checklist, populate:
   - `criterion_id`
   - `spec_refs` — list of spec/section IDs the criterion exercises
   - `constitution_refs` — list of constitution rules checked (if applicable)
   - `task_refs` — list of task IDs (if applicable)
   - `verdict` / `confidence` — filled as criteria complete
3. Leave `verdict` and `confidence` as `null` until the criterion is resolved.
4. If no spec-kit artifacts exist, do NOT create `traceability.json`. The absence of the file is the signal.

---

## Mini-Evals

### Eval 1 — Resume after context compaction

**Given:** A run `20241115T143022-founder-cap-table` has 12 criteria. The agent completes 7 (criteria `C-001` through `C-007`), then context compaction fires and the session restarts.

**Do:**
1. Run `scripts/checkpoint.sh --resume 20241115T143022-founder-cap-table` → output shows `C-007 pass`.
2. Read `run-manifest.json` → `criteria_done: 7`, `status: in-progress`.
3. Skip `C-001`–`C-007` entirely.
4. Resume at `C-008`. Re-verify its preconditions (auth, env state).
5. Do NOT re-run any already-checkpointed criterion.

**Must not do:** re-verify `C-001`–`C-007` from scratch, or read `~/.claude/.../MEMORY.md` to find run state.

---

### Eval 2 — ADR-0002: do not write per-criterion state to personal memory

**Given:** Criterion `C-004` (create-founder-persists) finishes with verdict `pass`. The agent is about to write the checkpoint.

**Do:**
1. Call `scripts/checkpoint.sh 20241115T143022-founder-cap-table C-004 pass`.
2. Verify `.qa/runs/20241115T143022-founder-cap-table/checkpoint.json` is updated.
3. Proceed to the next criterion.

**Must not do:** write "C-004 passed" to `MEMORY.md`, call any personal-memory tool with this verdict, or store any per-criterion fact in `~/.claude/`.

**Why:** `MEMORY.md` is loaded in every session for every project. Polluting it with transient run state breaks every unrelated session and violates ADR-0002.

---

### Eval 3 — Optional single durable pointer to personal memory

**Given:** The run `20241115T143022-founder-cap-table` is now complete. The agent wants to record a pointer so future sessions can quickly find the latest run.

**Do:**
1. Check personal memory for an existing entry for `cap-table-app`. If found, update the `Latest run` field. If not found, add ONE new entry:
   ```
   Project: cap-table-app
   Latest run: 20241115T143022-founder-cap-table
   Known flaky: C-009-equity-waterfall
   ```
2. That is the only write to personal memory for this entire run.

**Must not do:** write one entry per criterion, write verdict details, write evidence refs, or write bug log entries to personal memory.

---

### Eval 4 — Traceability skipped when no spec-kit artifacts

**Given:** A project has no spec doc, no constitution, and no tasks file in the repo.

**Do:**
1. At run start, check for spec-kit artifacts. Find none.
2. Skip creating `traceability.json` entirely.
3. Proceed with `run-manifest.json`, `checkpoint.json`, and `bug-log.json` only.

**Must not do:** create an empty `traceability.json`, error out, or prompt the user to supply spec-kit artifacts.

---

### Eval 5 — Bug found mid-run

**Given:** Criterion `C-006` (ownership-percentage-display) finishes with verdict `fail`. The displayed ownership is 33.4% but the oracle (spec formula) requires 33.33%.

**Do:**
1. Call `scripts/checkpoint.sh 20241115T143022-founder-cap-table C-006 fail`.
2. Append to `bug-log.json`:
   - `title`: "Ownership % rounds to 33.4 instead of 33.33"
   - `severity`: `medium`
   - `suspected_layer`: `FE`
   - `evidence_refs`: `["evidence/C-006/screenshot-after.png", "evidence/C-006/network-response.json"]`
3. If `traceability.json` exists, set `C-006.verdict = "fail"`, `C-006.confidence = "high"`.
4. Continue to `C-007` without stopping the run (bugs are logged, not blocking by default unless verdict is `blocked`).

---

## Templates Reference

| Template | Used at |
|---|---|
| `templates/run-manifest.md` | Step 1: copy → `run-manifest.json` |
| `templates/checkpoint.md` | Reference shape; `checkpoint.sh` writes the live file |
| `templates/bug-log.md` | Step 1: copy → `bug-log.json`; Step 2: append entries |
| `templates/traceability.md` | Step 1 (spec-kit only): copy → `traceability.json` |

## Scripts Reference

| Script | Usage |
|---|---|
| `scripts/checkpoint.sh <run-id> <crit-id> <verdict>` | Upsert checkpoint for one criterion |
| `scripts/checkpoint.sh --resume <run-id>` | Print last completed criterion + status for resume |
| `scripts/checkpoint.sh --list <run-id>` | Print all checkpointed criteria and verdicts |
