---
name: checkpointing-qa-memory
description: >-
  Use when starting, running, or resuming a qa-e2e-pilot Run. Manages all resumable memory-spec artifacts (run-manifest, checkpoint, bug-log, traceability) as plain files under `.qa/runs/<run-id>/`. Ensures a long Run survives context compaction by checkpointing every criterion to disk so completed work is skipped on resume. Enforces ADR-0002: per-criterion state NEVER goes to the agent's personal memory.
---

# Checkpointing QA Memory

## Overview

Every Run produces four memory-spec artifacts in `.qa/runs/<run-id>/`:

| Artifact | Purpose | Owner |
|---|---|---|
| `run-manifest.json` | Run identity, target, driver pool, checklist, overall status | this skill |
| `checkpoint.json` | Per-criterion resume record (verdict, evidence refs, last action) | this skill |
| `bug-log.json` | Append-only findings discovered during the run | this skill |
| `traceability.json` | Criterion ↔ spec/constitution/tasks ↔ verdict mapping | this skill (only when spec-kit artifacts exist) |

The sibling skill `writing-qa-reports` owns `report.md` and `report.html` in the same run dir. This skill owns everything above.

## Run Directory Layout

```
.qa/runs/
  latest                      ← one-line file: the run-id of the run whose first journal
                                 event was written most recently (atomic-written); the
                                 default target for `/qa-resume` when no run-id is given
  <run-id>/
    journal.ndjson              ← append-only event log; source of truth (see ADR-0002 Boundary)
    run-manifest.json
    checklist.json               ← generating-qa-checklist's PROPOSAL (per-criterion
                                     kind/tags/action/requiredKinds/assertedState); this
                                     skill's pass-gate reads it read-only for the #2/#4
                                     bindings — see "Evidence-Kind Gate" below; absent
                                     entirely on a run predating Plan H1, or one with no
                                     spec-kit/checklist emission step
    checkpoint.json              ← derived: fold(journal)
    cursor.json                  ← derived: fold(journal) — resume position
    fold-anomalies.json          ← derived: fold(journal) — torn/malformed-line report; also
                                     carries `openActs` (act_intent with no matching
                                     act_committed — the resume-time reconciliation work-list)
    bug-log.json
    traceability.json          ← only when spec-kit artifacts are present
    toolstream.jsonl            ← append-only; capture-hook.sh's sole writer (Plan H2 below);
                                     absent when capture is disabled or unsupported on this harness
    verification.json          ← qa-verify.sh's output (one record per re-checked `pass`);
                                     absent until `qa-verify.sh <run-id>` is run
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

**Optional cross-run recall:** when `memory.backend: "mem0"` is set in `.qa/config.json`, run `bash scripts/memory-sync.sh <run-id>` (top-level scripts) after a run to write-through ONLY the durable artifacts — bug-log entries + one per-project pointer — to a Mem0/vector endpoint for cross-run recall. It NEVER syncs per-criterion checkpoints (those are transient; ADR-0002), and the `.qa/runs/<run-id>/checkpoint.json` file stays the authoritative resume record. Default `backend: "file"` makes it a no-op. The file-based layout is the interface; the storage backend is pluggable — see [extending-drivers.md](../../docs/extending-drivers.md).

**Position is `fold(journal)`, never agent memory:** `journal.ndjson` is the append-only source of truth for a Run's state; `checkpoint.json` and `cursor.json` are computed by replaying it (`scripts/fold.sh`) — never re-derived from the agent's own recollection. This is what makes resume reliable across a context compaction, which is a silent partial restart from the agent's point of view.

**Fold ownership:** `scripts/fold.sh` OWNS `checkpoint.json`, `cursor.json`, and `fold-anomalies.json` — it recomputes and overwrites all three on every call. `run-manifest.json` and `bug-log.json` remain agent-authored; the fold never writes them, and no future change should wire a fold overwrite of either file.

**Expected `fold-anomalies.json` entries (not errors):** the orchestrator now emits `plan_frozen`/`plan_amended` (Generate→Verify boundary), `criterion_started` (per-criterion, at Verify's start), and `act_intent`/`act_committed` (bracketing a mutating criterion's act) via `journal-emit.sh` — see the Scripts Reference below — so a clean run normally shows NO `verdict-without-started` anomalies. If a caller writes a verdict via `checkpoint.sh` without ever having called `journal-emit.sh started` for that tuple (e.g. a script or fixture driving `checkpoint.sh` directly, bypassing the orchestrator prose), the fold still records the verdict and flags it with a benign `verdict-without-started` anomaly rather than rejecting it — the "record-the-verdict + flag" rule, never a suppressed verdict. Genuine problems are the other rules (`unparseable-line`, `seq-gap`, `cross-child-duplicate`, `fsync-unavailable`, `act-committed-no-intent`).

---

## Evidence-Kind Gate (#2) and Fingerprint-Target (#4)

Plan H1 closed two specific gaps in the pass-gate. **Read the honest-tier note at the
end of this section before treating either as a sound guarantee** — they are in-script,
best-effort checks, not an adversary-proof verifier.

### #2 — required-kinds binding

When `generating-qa-checklist` has written `.qa/runs/<run-id>/checklist.json` (its
per-criterion **proposal** — see that skill's `references/checklist-json-schema.md`),
`checkpoint.sh`'s pass-gate reads the criterion's row and independently re-derives its
required evidence kinds via `scripts/required-kinds.sh derive <row>` — from the row's
*structural* fields (`kind`, `tags`, and, through `mutation-flag.sh`, the action shape)
— **never** from the row's own `requiredKinds` field, which the gate ignores outright.
A checkpointed `pass` is rejected unless the recorded `--kinds` is a **superset** of
that independent re-derivation; the rejection names the missing kind(s). Absent
`checklist.json`, or no row for this criterion, falls back to today's behavior (the
un-gated "--kinds omitted" note) — full back-compat with runs that predate Plan H1.

### #4 — fingerprint-target

When a criterion's `checklist.json` row carries `assertedState
{entity, readBackPath, expectChange}`, that target is threaded through
`record-evidence.sh action-trace ... --fingerprint-target '<json>'` into
`action-trace.json.fingerprintTarget`. `check-action-trace.js` Check 3 then requires the
before/after state fingerprint to **cover** `readBackPath` (the key/path must be present
in both) and, when `expectChange` is `true`, to show the target's value **differ**
before→after (`expectChange: false` instead requires the target be present and
**unchanged**). `expectChange` must be a strict JSON boolean — a truthy-but-non-boolean
value (e.g. the string `"true"`, or `1`) is rejected as malformed rather than silently
coerced. No `fingerprintTarget` (the field absent, or `assertedState: null`) is
back-compat — Check 3's existing aggregate-`changed` behavior applies unchanged.

### THE HONEST TIER (read before relying on either check)

Both #2 and #4 are **in-script and best-effort**. They close two specific holes: "drop a
required evidence kind at checkpoint time" (#2), and "fingerprint an irrelevant field
while the asserted state itself never changed" (#4). They do **NOT** close:

- **"Lie about the criterion's `kind`/`tags`."** `required-kinds.sh` re-derives from the
  *declared* shape in `checklist.json` — a row whose `kind`/`tags` were themselves
  written dishonestly re-derives a dishonestly-narrow required set. The gate has no
  independent signal about what the criterion actually is, only what the row claims it
  is.
- **"Fabricate the fingerprint's values."** Check 3 checks that the fingerprint
  *covers* and *changes* the asserted target — it never re-reads the backend itself to
  confirm the fingerprint's own numbers are real.

**Specific residual — the `read-only` tag / a missing probe tag.**
`required-kinds.sh` Rule 3 suppresses the derived `bake` requirement whenever the row is
tagged `read-only`, and Rule 4 only derives `probe` when the row is explicitly tagged
`cross-tenant`/`cross-role-fk-chain`/`probe-needed`. Both are agent-declared `tags`
values in the very file being policed — so a genuinely-mutating, cross-tenant criterion
tagged `read-only` (or simply missing its probe tag) evades `bake`/`probe` without
tripping the gate. This is **asymmetric** with the `human-action` rule, which is immune
to tag-spoofing: `mutation-flag.sh` never reads `tags` at all, it fires off the action
verb / `kinds` / `httpMethod` shape alone. Closing the tag-honesty hole needs an
independent read of what the criterion actually does, not what it claims to be — that
is `qa-verify`'s job, not this gate's.

**Fourth residual — row omission.** Because there is no hard `checklist.json`
dependency (a criterion with no matching row falls through to the un-gated back-compat
note), an adversary can simply never emit a `checklist.json` row for a criterion to
un-gate #2 for it entirely. This is the same family as lie-about-`kind`/`tags`: it is
closed only by `qa-verify` re-deriving from the captured toolstream independent of
`checklist.json`, never by this in-script gate.

**The authoritative tier is `qa-verify`** (out-of-agent, Plan H2, ADR-0018 — see
"Out-of-Agent Enforcement" below). **Its deterministic core now exists**: required-kinds
re-derivation, evidence re-validation, and provenance binding, overriding a forged `pass`.
Still missing: the **independent LLM re-drive/re-bake** of high-stakes criteria (a fresh,
out-of-band agent session) — a **pluggable, not-yet-wired-in** operator/CI step
(`QA_VERIFY_REDRIVE_CMD`). A run relying on #2/#4 alone, with no `qa-verify` run yet, is
still `confidence: low` ("verdict pending `qa-verify`"); once `qa-verify.sh <run-id>` has
run and every pass survived, that framing no longer applies (see `verification.json`).

---

## Out-of-Agent Enforcement (Plan H2 / ADR-0018)

Everything above runs **inside** the agent's own process on evidence it wrote itself. Plan H2 adds a layer that runs **outside** that trust domain — Claude Code today; Codex/Pi/opencode hook adapters are Plan H3.

- **Capture-hook** (`scripts/capture-hook.sh`, `PostToolUse`, in `plugin.json`) appends
  every `Bash`/`browser_*` call to append-only `toolstream.jsonl` (`scripts/toolstream.sh`),
  run resolved from `.qa/runs/latest`. `Bash` args **and** `tool_response` are redacted
  (stdout leaks as easily as args) via `enforcement.secretPatterns`, or a built-in
  default when absent (never a silent no-redact fallback); `[]` opts out deliberately.
  `browser_*` args are recorded in full — a `browser_type` into a password field can
  still capture a typed secret (documented residual). Fail-open always.
- **Block-hook** (`scripts/block-hook.sh`, `PreToolUse`) denies, pre-run, only the
  phase-independent absolutes: a **mutating** `browser_evaluate` (via the `mutates()`
  classifier `parse-session-log.js` uses) and `browser_run_code_unsafe` — exit 2 + deny
  JSON. `browser_navigate` and all else is never live-blocked (record-only → `qa-verify`); fail-open on any internal error.
- **Provenance** (`scripts/provenance.sh check <run-id> <artifact>`) is **containment, not
  equality**: the read-back value must appear in a captured `responseBody` → `bound` /
  `unbound` (AC-1 forgery signal) / `no-toolstream` (best-effort degrade).
- **`qa-verify`** (`scripts/qa-verify.sh <run-id>`) — deterministic, no LLM. Per recorded
  `pass`: re-derives required-kinds, re-validates evidence, binds provenance; any miss →
  `verifierVerdict: fail` in `verification.json`, exit non-zero. Bare `no-toolstream`
  degrades confidence to `low` once, unless `QA_VERIFY_STRICT` — a high-stakes
  no-toolstream pass (`human-action`/`cross-tenant`) then hard-fails, closing the "forge +
  `rm toolstream.jsonl`" residual for opted-in callers. Wired into `qa-ci.sh`
  (`QA_VERIFY_CMD`/`QA_SKIP_VERIFY`) + `report-to-junit.sh` (override → JUnit `<failure>`;
  tier in `<properties>`) — see `docs/harness-adapters.md` / `docs/running-in-ci.md`.

**Honest residuals:** **(1)** live hooks are best-effort, not sound — bundled *config*
can't be silently disabled, but *script files* are user-writable unhardened (no
hash-chain — agent-recomputable is false assurance); `qa-verify`, not hook presence, is
trusted. **(2)** lie-about-`kind`/`tags` + row-omission close only via `qa-verify`. **(3)**
toolstream-suppression (`rm toolstream.jsonl` alongside forged evidence) lands on the
genuine-no-capture path; `QA_VERIFY_STRICT`/hardened-tier mitigates, doesn't fully close
it. **(4)** regex-classifier obfuscation — `mutates()` pattern-matches source text; an
indirect construction that never literally spells `method:'POST'`/`.setItem(` evades both
the block-hook and `check-action-trace.js`'s reuse of it — `qa-verify` re-runs it
unchanged, inheriting the gap.

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

On any restart (context compaction, interrupted run, new session), resume is **portable and
operator-invoked**: `/qa-resume [run-id]` (or, run directly, `bash
skills/checkpointing-qa-memory/scripts/qa-resume.sh [run-id]`). There is no directory scan and no
grep over `run-manifest.json` files — the run resolves via `.qa/runs/latest`.

```
1. Resolve + fold + brief:
   bash skills/checkpointing-qa-memory/scripts/qa-resume.sh [run-id]
   run-id defaults to the (trimmed) content of `.qa/runs/latest` when omitted — the pointer
   is atomic-written on a run's first journal event, so it always names the most recently
   STARTED run, not necessarily the last one you personally touched; pass an explicit run-id
   to target any other run. This folds journal.ndjson (scripts/fold.sh) and prints ONE line
   of JSON, the resume briefing:
     {run_id, phase, cursor: {scenarioId, criterionId} | null, openActs: [...], skip: [...]}
   - `phase`  — the phase cursor.json last recorded (e.g. Verify).
   - `cursor` — the first (scenario, criterion) tuple that is started/planned but has no
     criterion_verdict yet; null when every planned tuple already has one.
   - `openActs` — every act_intent with no matching act_committed (qa-reconcile.sh plan's
     output verbatim): a crash mid-act leaves its key here.
   - `skip`   — every (scenarioId, criterionId) tuple that ALREADY has a criterion_verdict —
     completed work the resumed Verify loop must never re-run or re-verdict.

2. Reconcile every open act BEFORE touching the UI (skip this step when openActs is empty):
   for each {key, scenarioId, criterionId, personaId, writeSet} in openActs, read back every
   write-set member with your OWN browser/probe capability (qa-resume.sh does not drive the
   browser or fetch anything itself), then:
     bash skills/checkpointing-qa-memory/scripts/qa-reconcile.sh apply <run_id> <key> \
       --readbacks <json>
   Handle the outcome: `done` -> move on; `blocked` -> the criterion is now recorded blocked,
   move on; `retry` -> re-drive the act once (through real UI affordances, bracketed by
   `journal-emit.sh act-intent`/`act-commit` as usual) and call `apply` again — a SECOND
   consecutive `retry` for the same key auto-escalates to `blocked`, so `apply` never loops;
   `deferred` -> a write-only write-set member with no read path — landing cannot be
   confirmed — record a low-confidence deferred note and move on, never re-drive the act for
   this outcome.

3. SKIP every tuple in the briefing's `skip` list. Continue Verify at exactly the `cursor`
   tuple, replaying the FROZEN plan (the `plan_frozen`/`plan_amended` events already in the
   journal) — no re-observation of the app for any already-planned criterion. A crash BEFORE
   `plan_frozen` (Pre-flight/Analyze/Generate) instead resumes by re-running those setup
   phases from their own checkpoints; only Verify forbids re-observation.

4. Re-verify only the IMMEDIATE preconditions for the cursor criterion itself (auth, env up)
   — never re-derive the plan or re-check already-skipped criteria.
```

**Auto-rehydrate is a protocol step, not a hook.** At every phase entry the agent re-reads
`fold(journal)` (the same fold `/qa-resume` runs) rather than trusting its own recollection —
this is what makes an *induced* compaction (no explicit `/qa-resume` call) land on the same
cursor a manual resume would. `harness-profiles.json` has no hooks field today: there is no
Claude/Codex/Pi SessionStart hook wired up for resume, and opencode has no session-hook mechanism at all —
a future harness-specific hook is a possible accelerant on top of this protocol step, never a
substitute for it. `/qa-resume` + the rehydrate-at-phase-entry protocol is the guaranteed floor
on every harness today.

This is the mechanism that made the original governance QA run survive context compaction: the
agent re-reads the fold on every resume and jumps straight to the first unverdicted
`(scenario, criterion)` tuple, reconciling any act a crash left open along the way.

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
| `scripts/checkpoint.sh <run-id> <crit-id> <verdict>` | Upsert checkpoint for one criterion (appends to the journal, then folds) |
| `scripts/checkpoint.sh --resume <run-id>` | Print last completed criterion + status for resume |
| `scripts/checkpoint.sh --list <run-id>` | Print all checkpointed criteria and verdicts |
| `scripts/journal.sh append <run-id> <event-json>` | Append one validated, seq-stamped event to `journal.ndjson` — the append-only source of truth |
| `scripts/fold.sh <run-id>` | Replay `journal.ndjson` into `checkpoint.json` + `cursor.json` + `fold-anomalies.json`; dispatches to `fold.jq`/`fold.py`, its jq/python3 reducer engines |
| `scripts/mutation-flag.sh derive <criterion-json>` | Derive whether a criterion mutates state from its action shape (`kinds`/`httpMethod`/verb) — never trusts an agent-declared flag |
| `scripts/required-kinds.sh derive <criterion-json>` | Independently re-derive a criterion's required evidence kinds (⊆ `bake,computed,probe,human-action`) from its `kind`/`tags`/action shape, reusing `mutation-flag.sh` for the mutates→`human-action` rule; never reads the agent's own `requiredKinds` field. Consumed by `checkpoint.sh`'s pass-gate against a `checklist.json` row (the #2 binding, see "Evidence-Kind Gate" above) |
| `scripts/journal-merge.sh <run-id>` | Fan-out only: merge child journals (`journal.<name>.ndjson`) into `journal.ndjson` under a lock, after all children have joined |
| `scripts/journal-emit.sh started\|freeze\|amend\|act-intent\|act-commit ...` | The single emission entrypoint for start/plan/act events: `started` journals `criterion_started`; `freeze` journals `plan_frozen` (or `plan_amended` per new criterion if a plan is already frozen); `amend` journals one `plan_amended`; `act-intent`/`act-commit` bracket a mutating criterion's act (`act-intent` is derive-gated via `mutation-flag.sh` — a no-op for a non-mutating criterion). Also atomic-writes `.qa/runs/latest` on a run's first event |
| `scripts/rebake.sh classify\|reconcile --write-set <json> --readbacks <json>` | The write-set re-bake classifier: given a criterion's declared write-set and read-back results (supplied by the caller — this script never fetches), classifies `landed`/`none`/`partial`/`deferred`; `reconcile` also journals the outcome (`act_committed` on landed, a `blocked` verdict naming the missing key on partial) — never a silent "done" |
| `scripts/qa-reconcile.sh plan <run-id>` | Fold the run and list every open act (`act_intent` with no matching `act_committed`) as the resume-time reconciliation work-list |
| `scripts/qa-reconcile.sh apply <run-id> <key> --readbacks <json>` | Reconcile one open act via `rebake.sh reconcile`; returns `done`/`retry`/`blocked`/`deferred` (a second consecutive `retry` for the same key auto-escalates to `blocked`) |
| `scripts/qa-resume.sh [run-id]` | Resolve a run (arg, else `.qa/runs/latest`), fold it, and print the resume briefing `{run_id, phase, cursor, openActs, skip}` — the primitive behind `/qa-resume` |
| `scripts/capture-hook.sh` | `PostToolUse` hook (stdin = hook JSON): append a redacted `Bash`/`browser_*` event to `toolstream.jsonl` via `toolstream.sh`; no-op + exit 0 on no active run or any error (Plan H2) |
| `scripts/block-hook.sh` | `PreToolUse` hook (stdin = hook JSON): exit 2 + deny JSON for a mutating `browser_evaluate` or `browser_run_code_unsafe`; fail-open (exit 0) otherwise (Plan H2) |
| `scripts/toolstream.sh append\|read\|redact <run-id> ...` | Append-only `toolstream.jsonl` writer/reader + the secret-redaction pass `capture-hook.sh` calls |
| `scripts/provenance.sh check <run-id> <artifact>` | Containment check: does an evidence artifact correspond to a captured `toolstream.jsonl` call? → `bound`\|`unbound`\|`no-toolstream` |
| `scripts/qa-verify.sh <run-id>` | The out-of-agent authority: re-derives required-kinds, re-validates evidence, binds provenance for every recorded `pass`; writes `verification.json`, exits non-zero on any override |
