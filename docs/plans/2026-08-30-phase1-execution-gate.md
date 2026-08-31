# Phase 1 — Execution-Enforcement Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. This is the granular expansion of Phase 1 from `docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md`, written after the MEASURED baseline (functional 33%) was captured.

**Goal:** Make "a green toast is not a pass" a machine fact — a `pass` verdict is INVALID unless the criterion recorded the real evidence its kind requires (bake read-back / independent recompute / probe body), enforced at the single chokepoint every verdict flows through.

**Architecture:** `checkpoint.sh cmd_upsert` becomes the gate: on a `pass`, it derives the required evidence from the criterion's `--kinds`, and rejects (non-zero, actionable message) unless each required artifact exists, is non-empty, and has a minimal valid shape. A new `record-evidence.sh` helper writes those structured artifacts so the check is content-aware, not filename-theater. `kinds` are derived from the checklist's existing `Kind`+`Tags` via one mapping table — no hand-authored redundant field.

**Tech Stack:** bash + jq (python3 fallback), the existing `.qa/runs/<id>/` plain-file convention (ADR-0002).

## Global Constraints (from the master plan + settled Phase-1 grilling)

- Verdicts exactly `pass|fail|blocked|deferred|error`; confidence `high|low`; suspected layer `FE|route|service|migration|DB`. No 6th verdict.
- Run state stays in `.qa/runs/<id>/` plain files; `checkpoint.json` remains the authoritative resume cursor (ADR-0002). The schema change must not break resume/list.
- `checkpoint.sh` prefers `jq`, falls back to `python3`, errors clearly if neither — both code paths must stay in lockstep.
- Secrets never printed; the evidence gate must not echo captured response bodies/values to stdout beyond a pass/fail reason.
- **Settled Phase-1 design (grilled 2026-08-30, all recommended):** (1) kinds DERIVED from existing `Kind`+`Tags` mapping; (2) gate enforced INSIDE `checkpoint.sh` upsert; (3) content-aware check + a `record-evidence.sh` writer; (4) reject-with-actionable-message on failure (no auto-downgrade).

## Settled evidence model

**Kind/Tags → required evidence kinds** (the mapping, applied by the generator; passed to checkpoint.sh as `--kinds`):

| Criterion `Kind` / `Tag` | Required kind(s) | Artifact (content-checked) |
|---|---|---|
| `computed-logic`, `business-rule` | `computed` | `evidence/<crit>/recompute.json` — non-empty JSON with `{oracle, observed, match}` |
| `multiplicity-N`, `happy-path` (with a write), any write criterion | `bake` | `evidence/<crit>/bake-read-back.json` — non-empty JSON with `{readBack, multiplicity}` |
| Tag `cross-tenant`, or `probeNeeded` | `probe` | `evidence/<crit>/network-response.json` — non-empty JSON with `{status, shape}` |

A criterion may require several kinds (e.g. a computed write → `bake,computed`). Non-`pass` verdicts (`fail|blocked|deferred|error`) are exempt — they are honest non-passes.

## File structure (Phase 1)

- Create: `tests/checkpoint/run.sh` — characterization + gate tests for `checkpoint.sh` (none exist today).
- Create: `skills/checkpointing-qa-memory/scripts/record-evidence.sh` — writes structured evidence artifacts.
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` — `--kinds` arg, `kinds` in the record, the gate in `cmd_upsert`, kinds+evidence-status in resume/list.
- Modify: `skills/generating-qa-checklist/SKILL.md` + `templates/checklist.md` — document the Kind/Tags→kinds mapping; emit derived kinds.
- Modify: `agents/qa-e2e-pilot.md` — phase-3 writes evidence via `record-evidence.sh` and passes `--kinds` to checkpoint before the next criterion.
- Modify: `tools/accuracy-harness/scorer/pass-gate.js` — align to the real snake_case schema OR mark as the superseded prototype.
- Create: `docs/adr/0010-execution-enforcement-evidence-gate.md`.

---

### Task 1.1: Characterization tests for current checkpoint.sh

**Files:** Create `tests/checkpoint/run.sh`

**Interfaces:** Produces a runnable test harness (bash, exit non-zero on failure) covering TODAY's behavior so the migration can't silently regress it: upsert insert, upsert replace, resume view, list, verdict-enum rejection, valid-JSON output. Mirrors the existing `tests/*/run.sh` convention.

- [ ] **Step 1: Write the harness** exercising a temp `.qa/runs/<id>/` — assert: `checkpoint.sh <run> C1 pass` creates valid JSON with `criterion_id=C1`; a second upsert of C1 replaces (not appends); `--resume` prints C1; `--list` TSV has C1; an invalid verdict `foo` exits non-zero; `python3 -c json.load` parses the checkpoint file. Use `jq`-present and (if available) a `PATH`-masked `jq` run to exercise the python3 fallback.
- [ ] **Step 2: Run it against unmodified checkpoint.sh** → PASS (this is characterization; it must pass on current code). Run: `bash tests/checkpoint/run.sh`. Record output.
- [ ] **Step 3: Commit** — `test(checkpoint): characterization harness for insert/upsert/resume/list before the gate`.

---

### Task 1.2: `record-evidence.sh` — structured evidence writer

**Files:** Create `skills/checkpointing-qa-memory/scripts/record-evidence.sh`; extend `tests/checkpoint/run.sh`.

**Interfaces:** `record-evidence.sh <run-id> <criterion-id> <kind> [--key val ...]` writes `.qa/runs/<id>/evidence/<crit>/<artifact>.json` for `kind ∈ {bake,computed,probe}` with the settled minimal shape. Prefers `jq`, python3 fallback. Returns the written path on stdout (for the agent to add to `evidence_refs`). Secrets: values are stored in the run dir but never echoed.

- [ ] **Step 1: Write failing tests** (in `tests/checkpoint/run.sh`): `record-evidence.sh R C1 bake --read-back '{"founders":3}' --multiplicity N` writes `evidence/C1/bake-read-back.json` that is valid JSON, non-empty, and contains `readBack` + `multiplicity`; `computed` writes `recompute.json` with `oracle/observed/match`; `probe` writes `network-response.json` with `status/shape`; an unknown kind exits non-zero.
- [ ] **Step 2: Run → FAIL** (script missing). Record.
- [ ] **Step 3: Implement `record-evidence.sh`** (jq + python3 fallback, `mkdir -p` the evidence dir, write the shaped JSON, echo the path).
- [ ] **Step 4: Run → PASS.** `bash -n` + `bash tests/checkpoint/run.sh`.
- [ ] **Step 5: Commit** — `feat(checkpoint): record-evidence.sh writes structured bake/recompute/probe artifacts`.

---

### Task 1.3: The gate — `--kinds` + evidence enforcement in `cmd_upsert`

**Files:** Modify `skills/checkpointing-qa-memory/scripts/checkpoint.sh`; extend `tests/checkpoint/run.sh`.

**Interfaces:** `checkpoint.sh <run> <crit> pass --kinds bake,computed --evidence-refs <csv|json>` — stores `kinds` in the record; on `pass`, for each kind requires its artifact to (a) be referenced OR discoverable at `evidence/<crit>/<artifact>.json`, (b) exist, (c) be non-empty, (d) parse as JSON with the kind's required keys. Any miss → **reject**: non-zero exit + stderr message naming exactly which kind/artifact is missing, and the reminder "supply the evidence or record `blocked`." Non-`pass` verdicts skip the gate. `--kinds` absent on a pass = no evidence required (back-compat for untagged criteria), but log a one-line stderr note.

- [ ] **Step 1: Write failing tests** (extend harness): pass+`--kinds bake` with NO bake artifact → exit non-zero, stderr names `bake-read-back.json`; pass+`--kinds bake` with an EMPTY bake file → still rejected (non-empty check); pass+`--kinds bake` after `record-evidence.sh ... bake` wrote a valid artifact → ACCEPTED, record has `kinds:["bake"]`; `blocked --kinds bake` with no evidence → ACCEPTED (non-pass exempt); pass with no `--kinds` → accepted + stderr note.
- [ ] **Step 2: Run → FAIL.** Record.
- [ ] **Step 3: Implement** the gate in both jq and python3 paths: parse `--kinds`, add `kinds` to the record object, and a `gate_pass()` that validates each kind's artifact (exists+non-empty+required keys) using the same Task-1.1 mapping; reject before writing the record.
- [ ] **Step 4: Run → PASS**, and re-run Task 1.1 characterization assertions (still green — non-pass and untagged-pass paths unchanged).
- [ ] **Step 5: Commit** — `feat(checkpoint): reject an unevidenced pass at upsert (evidence gate)`.

---

### Task 1.4: Surface `kinds` + evidence status in resume/list

**Files:** Modify `skills/checkpointing-qa-memory/scripts/checkpoint.sh`; extend `tests/checkpoint/run.sh`.

**Interfaces:** `--resume` and `--list` additionally emit each criterion's `kinds` and an `evidence: complete|missing` flag, so a resumed run (post-compaction) knows which passes are still ungated. Existing columns unchanged (append only).

- [ ] **Step 1: Write failing tests:** after a gated pass, `--resume` line for that criterion includes its kinds and `evidence:complete`; a criterion checkpointed `blocked` shows `evidence:n/a`.
- [ ] **Step 2: Run → FAIL.** **Step 3: Implement** (append fields in both jq/python3 resume+list). **Step 4: Run → PASS** (prior resume/list assertions unchanged).
- [ ] **Step 5: Commit** — `feat(checkpoint): resume/list surface kinds + evidence status for post-compaction resume`.

---

### Task 1.5: Wire the generator + orchestrator to the gate

**Files:** Modify `skills/generating-qa-checklist/SKILL.md` + `templates/checklist.md`; `agents/qa-e2e-pilot.md`.

**Interfaces:** The generator documents the Kind/Tags→kinds mapping (the table above) and emits each criterion's derived kinds. The orchestrator's phase-3 loop: after verifying, call `record-evidence.sh` for each kind, then `checkpoint.sh ... --kinds <derived> --evidence-refs <paths>` — so the gate fires every criterion. No new verdict; a rejected pass makes the agent supply evidence or record `blocked`.

- [ ] **Step 1: Edit `generating-qa-checklist`** — add the mapping table to Step 6, and state each criterion carries derived `kinds`/`probeNeeded`. Keep body <500 lines; ≥3 mini-evals updated to show a criterion with kinds.
- [ ] **Step 2: Edit `checklist.md` template** — add a `Kinds` row derived from `Kind`+`Tags`.
- [ ] **Step 3: Edit `agents/qa-e2e-pilot.md:42-53`** — phase-3 writes evidence via `record-evidence.sh` and passes `--kinds` to checkpoint; state the gate may reject and how the agent responds (evidence or `blocked`).
- [ ] **Step 4: Validate** — skill frontmatter/body limits; `checklist.md` still parses; the agent md references tools by capability. Run `bash tests/checkpoint/run.sh` (unaffected, still green).
- [ ] **Step 5: Commit** — `feat(qa): generate derived kinds and enforce the evidence gate in the verify loop`.

---

### Task 1.6: ADR-0010 + reconcile the pass-gate.js prototype

**Files:** Create `docs/adr/0010-execution-enforcement-evidence-gate.md`; Modify `tools/accuracy-harness/scorer/pass-gate.js`.

**Interfaces:** ADR-0010 records the four settled decisions + why (closes the R1 execution-discipline miss-class from the master plan). `pass-gate.js` is aligned to the real snake_case `evidence_refs`/`kinds` OR clearly marked as the superseded prototype now that the real gate lives in `checkpoint.sh`.

- [ ] **Step 1: Write ADR-0010** in the repo's ADR format, next in sequence — decisions: derive-kinds-from-Kind, gate-in-checkpoint-upsert, content-aware+writer, reject-not-downgrade; consequences for resume/compaction; alternatives rejected.
- [ ] **Step 2: Reconcile `pass-gate.js`** — update its header + logic to match the real schema (snake_case, content-aware) so the reference and the shipped gate agree, or add a top-of-file note "superseded by checkpoint.sh's built-in gate; kept as the unit-testable spec." Keep its node tests (if any) green.
- [ ] **Step 3: Validate** — `node --check pass-gate.js`; ADR JSON/paths sound; `python3 -c json.load` on any JSON touched.
- [ ] **Step 4: Commit** — `docs(adr): 0010 execution-enforcement evidence gate; align pass-gate prototype`.

---

## Self-review (against Phase-1 scope)

- **Coverage:** settled decisions 1–4 → Tasks 1.1–1.4 (gate) + 1.5 (derivation/wiring) + 1.6 (ADR/reconcile). The master-plan fix-regardless "pass-gate.js schema mismatch" → Task 1.6.
- **No placeholders:** each task carries concrete interfaces, the mapping table, and named artifacts/keys; test steps name the exact assertions.
- **Type consistency:** `--kinds` csv, kinds ∈ `{bake,computed,probe}`, artifacts `bake-read-back.json`/`recompute.json`/`network-response.json`, record field `kinds`, snake_case throughout — used identically across 1.2–1.5.
- **Invariant guard:** the gate never introduces a verdict; it only rejects an unevidenced `pass` (the agent then chooses evidence or `blocked`).

## Out of scope / verify at execution

- The broadened-coverage half of the master plan's Phase 1 (required cross-tenant/race/resume emissions in `generating-qa-checklist`) is a SEPARATE follow-on — this plan does the evidence GATE. Sequence coverage after the gate holds.
- **Re-measure:** after Task 1.5, a fresh MEASURED fixture run should show functional recall rising (the gate converts unevidenced passes into `blocked`, forcing the agent to actually bake/recompute) — capture it and compare to the 33% baseline. Confirm no recall regression on the fixture gate.

---

## Phase 1 result (MEASURED)

The re-measurement this plan's own exit criterion asked for was run: baseline (ungated) vs. gated, on the same fixture/18-seed set.

| Run | Functional | UX | Overall | Precision |
|---|---|---|---|---|
| Baseline (ungated) | 33% | 25% | 30% | 75% |
| **Gated A** (real `qa-e2e-pilot` agent, 18 seeds) | **38%** | 25% | 33% | **100%** |
| Gated B (general-purpose agent, comparison run) | 25% | 25% | 25% | 100% |

**Recorded verdict:** the gate did what it was designed to do — **precision rose from 75% to 100%** (the ungated run's one false-green is gone; no negative-control seed was ever flagged across either gated run). **Recall did not rise materially** on its own (functional 33%→38%, UX flat at 25%) — expected, because the gate enforces that a `pass` carries real evidence, it does not add new criteria that test previously-untested bug classes. That is coverage work, explicitly deferred to Phase 2 (`docs/plans/2026-08-31-phase2-coverage-roles.md`) for functional/journey recall and to Phase 3/4 for UX-objective recall (no non-vision detector exists yet for U1–U3). This exit criterion is satisfied: the number is captured, compared to baseline, and confirmed non-regressed (100% ≥ 75% precision; 38% ≥ 33% functional recall — no regression on either axis carried forward from this gate).
