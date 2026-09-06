# checkpointing-qa-memory — extended mini-evals

Evals 4–8 (the full bug-class set). Evals 1–3 stay in [`../SKILL.md`](../SKILL.md); these are the remainder, moved out to keep the skill body under 500 lines. Behavior unchanged — reference-grade material only.

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

### Eval 6 — Torn journal tail: fold still lands on the right cursor

**Given:** `journal.ndjson` has a complete `criterion_started`/`criterion_verdict` pair recording `C1`'s `fail` verdict, a complete unrelated `C3` `pass` entry, and then a further `criterion_verdict` superseding `C1` to `pass` whose line was cut off mid-append (process killed mid-flush) — a torn last line.

**Do:**
1. Run `scripts/fold.sh <run-id>` (this is also what `checkpoint.sh` calls internally).
2. Confirm exit 0 — a torn line is never a crash.
3. Confirm `fold-anomalies.json` records exactly one `unparseable-line` anomaly for the torn line.
4. Confirm `checkpoint.json` still has `C1` at its last VALID verdict (`fail`) — the torn superseding line is discarded, not partially applied — and `C3` untouched (`pass`).
5. Confirm `cursor.json`'s `(scenarioId, criterionId)` cursor reflects only the valid lines (no phantom in-progress tuple manufactured from the torn line), and that `checkpoint.json`/`cursor.json`/`fold-anomalies.json` are each fully the new content, never a half-written file at their destination path.

**Must not do:** apply a partially-parsed event, leave a half-written derived JSON file at its destination path, or abort the fold/resume.

---

### Eval 7 — Kill mid-act, resume, full-write-set reconcile, no double-create

**Given:** Run `20241115T143022-founder-cap-table` is mid-Verify. Criterion `C-004`
(create-founder-persists, mutating, write-set `[{"entity":"founder","key":"founder-42"}]`) has a
journaled `criterion_started` and `act_intent` (from `journal-emit.sh act-intent`) but the process
is killed before `journal-emit.sh act-commit` ever runs — a crash mid-act, no `act_committed`.
`C-001`–`C-003` already have recorded verdicts.

**Do:**
1. New session. Run `/qa-resume` (or `bash .../qa-resume.sh` with no run-id) — it resolves
   `20241115T143022-founder-cap-table` from `.qa/runs/latest`, folds, and prints the briefing.
   Confirm `skip` contains `C-001`–`C-003` and `cursor` points at `C-004`; confirm `openActs`
   contains exactly one entry keyed to `C-004`'s write-set.
2. **Before touching the UI**, read back `founder-42` with the resumed session's own browser/probe
   capability. It IS found (the create actually landed before the crash; only the commit event was
   lost). Call `qa-reconcile.sh apply <run-id> <key> --readbacks '[{"entity":"founder","key":"founder-42","found":true}]'`.
   Confirm it returns `done` and journals `act_committed{outcome:"landed"}` — re-fold shows
   `openActs` now empty for `C-004`.
3. Confirm the agent does NOT re-drive the create action for `C-004` (the reconciled act already
   landed) and does NOT re-run or re-verdict `C-001`–`C-003`.
4. Continue Verify at `C-004`'s remaining steps (bake/compute-logic) using the reconciled write-back,
   then record its verdict and move to `C-005`.
5. **Contrast:** repeat from step 1 with the read-back showing `found:false` instead. `apply`
   returns `retry` — the agent re-drives the create ONCE (through real UI affordances, bracketed by
   a fresh `act-intent`/`act-commit`) and calls `apply` again. A SECOND consecutive `not-found`
   auto-escalates to a `blocked` verdict naming the key — `apply` never loops.

**Must not do:** re-create `founder-42` when the reconciled read-back already shows it landed
(double-create), silently mark `C-004` `done` without the write-set read-back, or re-verify
`C-001`–`C-003` from scratch.

---

### Eval 8 — #2 required-kinds binding rejects a dropped kind

**Given:** `.qa/runs/20241115T143022-founder-cap-table/checklist.json` has a row for
`C-004` (create-founder-persists): `{"id":"C-004","kind":"happy-path","tags":["human-action"],"action":"click Add Founder to submit the form","requiredKinds":["bake","human-action"],"assertedState":{"entity":"Founder","readBackPath":"count","expectChange":true},"humanAction":true}`.
`required-kinds.sh derive` on this row's `kind`/`tags`/`action` independently lands on
`bake,human-action` (a mutating action verb plus a `happy-path` kind not tagged
`read-only`) — the row's own `requiredKinds` field is never consulted.

**Do:**
1. The driver skipped the real click and API-injected the founder instead. Suppose it
   still checkpoints: `scripts/checkpoint.sh 20241115T143022-founder-cap-table C-004 pass --kinds bake`
   (dropping `human-action`).
2. Confirm `checkpoint.sh` rejects with a message naming the missing kind, e.g.
   `EVIDENCE GATE: pass rejected for criterion 'C-004' — checklist.json row requires
   kind(s) 'human-action' ... not present in recorded --kinds 'bake'`.
3. Re-run with `scripts/checkpoint.sh 20241115T143022-founder-cap-table C-004 pass --kinds bake,human-action`
   (plus the corresponding evidence files on disk) → accepted.

**Must not do:** accept a `pass` for a `checklist.json`-tracked criterion whose recorded
`--kinds` is missing any kind `required-kinds.sh derive` independently produced, or trust
the row's own `requiredKinds` field to decide the outcome.

**Why this eval is not the whole story:** it shows the gate catching a *dropped* kind. It
does not show the gate catching a *dishonest* `kind`/`tags` value in the row — see the
honest-tier note above ("Evidence-Kind Gate (#2) and Fingerprint-Target (#4)").
