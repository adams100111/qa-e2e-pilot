# Run FSM Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Run a **statechart** — a `state-machine.json` declaring the phases and per-criterion sub-states + their legal edges — and enforce it at the two levels the design allows: **fold** infers each criterion's sub-state from the existing journal events and flags an illegal edge as an anomaly; **`qa-verify`** (the authority) temporally folds the toolstream against the frozen plan + statechart and flags any tool used outside its sanctioned phase. A cooperative **transition guard** best-effort-declines to record an illegal edge. This is **not a machine cage** — it's a tester bounded by discipline + the honesty gate + `qa-verify`, per the spec's non-goal.

**Scope note — this implements the previously-DEFERRED `docs/specs/2026-09-02-run-fsm-enforcement-design.md` (future ADR-0021), now UNBLOCKED.** Its three dependencies are satisfied: H2 shipped the capture-hook + block-hook + `qa-verify`; Plan A/B shipped the durability core (journal/fold/`plan_frozen`/toolstream). The spec's own **blocking contradiction is already resolved in its text**: phase-surface enforcement is **record-only → `qa-verify`**, NOT a hard live bound (phase is agent-supplied, not in the tool call, and the fold file is agent-writable on unhardened installs — so the live tier is best-effort, the authority is the out-of-agent verifier). This plan honors that exactly.

**Two open questions the spec left for un-defer time — resolved here (self-grill):**
1. **Sub-states are FOLD-INFERRED, never agent-emitted.** The six sub-states (`pending→arranging→acting→baking→reconciling→verdict`) are computed by the fold from Plan B's existing events (`plan_frozen`/`criterion_started`/`act_intent`/`act_committed`/`criterion_verdict`) — no new emission protocol, no `checkpoint.sh`/`journal-emit.sh` CLI change, no caller migration. (The 3-arg `checkpoint.sh` CLI is preserved byte-for-byte.)
2. **The statechart adopts the AGENT'S ACTUAL phase names.** The pipeline emits `Pre-flight / Analyze / Generate / Verify / Report / Remember` (`core/persona-body.md`); the deferred spec's `PreFlight→Analyze→Discover→Generate→Verify→Report` was aspirational (invents "Discover", omits "Remember"). `state-machine.json` uses the *emitted* names; this plan reconciles the drift by adopting reality, documented in ADR-0021.

**Architecture:** `skills/checkpointing-qa-memory/references/state-machine.json` (data, dist-copied, read by both fold and qa-verify) declares `phases[]` (the 6 real names, ordered), the per-criterion `subStates[]` + their legal edges, and the transition guards (`→verdict:pass` requires the honesty gate; `arranging→acting` requires `mutates`; `acting` skipped when `mutates=false`; `acting→baking` requires `act_committed`). `fold.jq`/`fold.py` gain a pass-2 per-tuple sub-state inference + an `illegal-edge` anomaly (7th rule) validated against the statechart's legal edges; `cursor.json` exposes the current tuple's sub-state. `qa-verify.sh` gains phase-surface enforcement: it reads the journal (the `phase_entered`/criterion-timeline with `ts`/`seq`), the toolstream (H2, `ts`/`seq`, no phase tag), and the statechart, and TEMPORALLY correlates each toolstream tool call to the phase/sub-state active at that moment, recording an off-phase finding (a mutating browser tool outside any criterion's `acting` window; a `browser_*` after Report) in `verification.json` — record-only, the authority. A cooperative pre-append guard in `journal-emit.sh` reads the journal to decline an illegal edge (e.g. `act_committed` with no prior `act_intent`) — best-effort, not a cage.

**Tech Stack:** Bash (`set -uo pipefail`), `jq`/`python3` fallback (+ `QA_ENGINE`), dependency-free reuse of Plan A/B's `fold.*`/`journal.sh`/`journal-emit.sh`, H2's `qa-verify.sh`/`toolstream.sh`. Data-driven from `state-machine.json` (the engine holds the generic edge-check; the statechart is data — same "all knowledge is data" discipline as `stack-signatures.json`).

## Global Constraints

- **NOT a hard cage (spec non-goal + §5.2 resolution):** phase-surface enforcement is **record-only → `qa-verify`**, never a live hard bound. The transition guard is COOPERATIVE (declines to *record* an illegal edge; it cannot prevent off-surface work with Read/Write/browser tools). Any "hard bound" language is forbidden. State the per-harness assurance tier (Codex managed = strongest; others best-effort; `qa-verify` the universal authority everywhere).
- **Sub-states are FOLD-INFERRED** from the existing journal events — no new event type, no `checkpoint.sh`/`journal-emit.sh` CLI change. The 3-arg `checkpoint.sh <run> <crit> <verdict>` CLI + the 265-assertion characterization suite stay green.
- **Data-driven:** the phases, sub-states, legal edges, and guards live in `state-machine.json`; `fold`/`qa-verify` READ them and hold only the generic edge-validation procedure. Adding/renaming a phase or edge is a data edit.
- **Statechart phase names = the emitted names** (`Pre-flight/Analyze/Generate/Verify/Report/Remember`, matched case-insensitively to the free-text `--phase` values). No invented "Discover"; "Remember" included. Reconcile the drift in ADR-0021.
- **`illegal-edge` is an ANOMALY, not a fold abort** — the fold stays total (an illegal-edge sequence is recorded in `fold-anomalies.json`, never aborts). The verdict/honesty vocab is unchanged (no sixth verdict; the sub-states are internal machine state, never a verdict).
- **Phase-surface = temporal correlation** (toolstream events have no phase tag — §3/§7 of grounding): qa-verify correlates by `ts`/`seq` against the journal's phase/sub-state timeline; a tool with no determinable phase window → flagged low-confidence, never a false hard override.
- **`jq`/`python3`/`die`; no new `node` dep; `QA_ENGINE` honored;** `fold.jq`/`fold.py` stay semantically identical (the dual-engine equivalence tests extend to the new anomaly). No `grep -P`/`perl`.
- **Portability:** `state-machine.json` + all scripts under `skills/`/`scripts/` are dist-copied; after edits regenerate dist, `validate-adapters.sh` exit 0 (its static sweep parses the new JSON), `tests/portability/run.sh` `FAIL=0`. `dist/` git-ignored.
- **Commit messages: NO Claude/Anthropic attribution, NO `Co-Authored-By`.**

## Self-grilled decisions (my recommendations, applied)

- **Q1 sub-states** → fold-inferred (no emission/CLI change; resolves the spec's open Q).
- **Q2 phase names** → adopt the agent's actual 6 names; the spec's list was aspirational (reconcile in ADR-0021).
- **Q3 phase-surface** → qa-verify temporally correlates toolstream↔journal (record-only → verification.json authority); no phase tag on toolstream, so correlation is by ts/seq; undeterminable window → low-confidence flag, never a false override.
- **Q4 transition guard** → cooperative pre-append decline in journal-emit (best-effort), authority is qa-verify; not a cage.
- **Q5 statechart location** → `skills/checkpointing-qa-memory/references/state-machine.json` (data, read by fold + qa-verify).
- **Q6** → NOT a hard cage; record-only phase-surface; per-harness assurance tier stated.

---

### Task 1: `state-machine.json` statechart-as-data + schema + validator

Declare the statechart and a structural validator. The data everything else reads.

**Files:**
- Create: `skills/checkpointing-qa-memory/references/state-machine.json` — `{ phases:[{id, order}], subStates:[id...], legalPhaseEdges:[[from,to]...], legalSubStateEdges:[[from,to]...], guards:[{edge:[from,to], requires:"..."}], phaseToolSurface:{<phase>:{allowedToolClasses:[...], forbiddenToolClasses:[...]}} }`. Phases = the 6 emitted names (ordered). subStates = `pending,arranging,acting,baking,reconciling,verdict`. Guards: `arranging→acting` requires `mutates`; `acting→baking` requires `act_committed`; `*→verdict:pass` requires the honesty gate; `acting` skipped (edge `arranging→baking`) when `mutates=false`. `phaseToolSurface`: e.g. `Verify` allows browser interaction + evaluate + probe; `Report`/`Remember` forbid `browser_*` mutation.
- Create: `skills/checkpointing-qa-memory/references/state-machine-schema.md` — the schema doc + the sub-state inference table (which journal events imply which sub-state).
- Create: `skills/checkpointing-qa-memory/scripts/validate-state-machine.sh` — structural validator (every legal edge references declared phases/subStates; guards reference legal edges; phaseToolSurface phases are declared).
- Create: `tests/state-machine/run.sh`

**Interfaces:**
- `validate-state-machine.sh <path>` → exit 0 if structurally valid, else non-zero naming the offending field. The statechart is the contract Task 2 (fold) + Task 3 (qa-verify) read.

- [ ] **Step 1** — write `tests/state-machine/run.sh`: the shipped `state-machine.json` validates (exit 0); a mutant with an edge referencing an undeclared subState → non-zero; a guard on a non-existent edge → non-zero; a phaseToolSurface phase not in `phases` → non-zero. Dual-engine. Run → FAIL.
- [ ] **Step 2** — author `state-machine.json` (6 emitted phases; 6 sub-states; legal phase + sub-state edges; guards; phaseToolSurface) + the schema doc + `validate-state-machine.sh`.
- [ ] **Step 3** — tests green both engines; `python3 -c json.load` the JSON; dist regen; validate-adapters exit 0; portability. Commit: `feat(fsm): state-machine.json statechart-as-data (phases, sub-states, legal edges, guards) + schema + validator`.

---

### Task 2: Fold infers per-criterion sub-state + `illegal-edge` anomaly

Extend the fold to infer each tuple's current sub-state from its journal events and flag an illegal sub-state edge, driven by `state-machine.json`.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/fold.jq` + `fold.py` — in pass 2's per-tuple state (which already tracks `started`/`verdict`), also track `act_intent`/`act_committed` for the tuple and derive `subState` per the inference table (pending/arranging/acting/baking/reconciling/verdict). Add the `illegal-edge` anomaly: an observed transition not in `state-machine.json`'s `legalSubStateEdges` (e.g. `act_committed` for a tuple with no `act_intent` → an illegal `arranging→baking`-via-commit; a `criterion_verdict` from `pending` with no intervening sub-states when `mutates` — flag). Read the legal edges from `state-machine.json` (data-driven; the engine holds the generic membership check).
- Modify: `skills/checkpointing-qa-memory/scripts/fold.sh` — pass the `state-machine.json` path into the engines; keep `atomic_write` of `cursor.json` now including the current tuple's `subState`.
- Modify: `tests/fold/run.sh` + fixtures — sub-state + illegal-edge cases.

**Interfaces:**
- `cursor.json` gains `subState` (the current cursor tuple's inferred sub-state). `fold-anomalies.json` gains `{"rule":"illegal-edge","tuple":"…","from":"…","to":"…"}` for an illegal transition. The fold stays total + dual-engine-identical.

- [ ] **Step 1** — fixtures + tests: a journal with `plan_frozen`+`criterion_started`+`act_intent`+`act_committed`+`criterion_verdict` → `cursor.json.subState` progresses correctly (and lands on the right sub-state for a mid-run cursor); a journal with `act_committed` and NO `act_intent` (illegal edge) → `illegal-edge` anomaly (in addition to the existing `act-committed-no-intent`); a non-mutating criterion (`mutates:false`) whose act was skipped (`arranging→baking` legal) → NO illegal-edge. Dual-equiv on the new anomaly. Run → FAIL.
- [ ] **Step 2** — implement the sub-state inference + `illegal-edge` rule in both engines (read `state-machine.json`'s `legalSubStateEdges`); thread the statechart path through `fold.sh`.
- [ ] **Step 3** — tests green both engines + no regression (fold's existing anomaly suite, checkpoint 265); dist; validate-adapters; portability. Commit: `feat(fsm): fold infers per-criterion sub-state + illegal-edge anomaly (data-driven from state-machine.json)`.

---

### Task 3: `qa-verify` phase-surface enforcement (temporal, record-only → authority)

Make `qa-verify` the phase-surface authority: temporally fold the toolstream against the journal timeline + statechart, flag off-phase tool use.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/qa-verify.sh` (or `scripts/qa-verify.sh` — use the real path) — add a phase-surface pass: read `journal.ndjson` (the `phase_entered`/`phase_exited`/`criterion_started`/`act_intent`/`act_committed` timeline with `seq`/`ts`), the `toolstream.jsonl` (H2, `seq`/`ts`), and `state-machine.json`'s `phaseToolSurface`; for each toolstream tool call, determine the phase/sub-state active at its `ts`/`seq` (the last `phase_entered` before it; whether it fell inside a criterion's `acting` window) and flag a **surface violation** — a mutating browser tool (per `mutates()`/the classifier) outside any `acting` window, or a `browser_*` after `Report`/`Remember` entered. Record each as a `verification.json` reason on the affected criterion (or a run-level `phase-surface` finding); a surface violation on a `pass` → confidence:low + reason (record-only authority — a hard override only for an unambiguous mutating-act-outside-Verify, matching the honesty-tier rules). Undeterminable phase window → low-confidence flag, never a false override. No toolstream → degrade (no phase-surface check), never fail.
- Create: `tests/qa-verify-phase/run.sh` + fixtures (a run + journal timeline + toolstream).

**Interfaces:**
- `qa-verify.sh <run>`: a toolstream showing a mutating `browser_evaluate`/write at a `ts` when the run was in `Report` (not any criterion's `acting`) → a `phase-surface` finding in `verification.json` (confidence:low + reason on the run/criterion). A clean run (all mutating acts inside a Verify `acting` window) → no phase-surface finding. No toolstream → skipped, no finding.

- [ ] **Step 1** — fixtures + tests: a journal timeline (run_started, phase_entered Verify, criterion_started C1, act_intent C1, act_committed C1, phase_entered Report) + a toolstream with a mutating call whose `ts`/`seq` falls AFTER Report entered → `qa-verify` records a `phase-surface` finding (confidence:low, reason names the phase); a mutating call inside C1's acting window → NO finding; no toolstream → no finding (degrade). Dual-engine. Run → FAIL.
- [ ] **Step 2** — implement the phase-surface pass (temporal correlation by seq/ts; reuse `parse-session-log.js`'s `mutates()` or the toolstream `advisory`/args to classify a mutating tool; read `state-machine.json.phaseToolSurface`). Record-only in verification.json; never a false hard override.
- [ ] **Step 3** — tests green both engines + no regression (qa-verify 77+, checkpoint 265, provenance/required-kinds); dist; validate-adapters; portability. Commit: `feat(fsm): qa-verify phase-surface enforcement — temporal toolstream-vs-plan fold flags off-phase tool use (record-only authority)`.

---

### Task 4: Cooperative transition guard (best-effort decline)

A pre-append guard in `journal-emit.sh` declines to record an obviously-illegal edge — best-effort, not a cage (the authority is Task 3).

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/journal-emit.sh` — before appending, validate the edge against `state-machine.json`'s `legalSubStateEdges` by reading the current tuple state from the journal (reuse the existing `plan_frozen_exists`/`known_plan_tuples` scan pattern): `act-commit` for a tuple with no prior `act_intent` → **decline** (non-zero + message "illegal edge: act_committed requires a prior act_intent"); `act-intent` for a tuple with no `criterion_started` → decline; etc. A `--force` escape hatch (logged) for legitimate exceptions. The 3-arg `checkpoint.sh` path is untouched (its guard stays the honesty gate).
- Modify: `tests/journal-emit/run.sh` — guard cases.

**Interfaces:**
- `journal-emit.sh act-commit …` for a key with no journaled `act_intent` → declines (non-zero, nothing appended) unless `--force`. Legal edges append as today. This GUARDS RECORDED STATE (declines to write an illegal edge); it does not prevent off-surface work — that's qa-verify's authority.

- [ ] **Step 1** — tests: `act-commit` with no prior `act_intent` → declined (non-zero, no journal line), `--force` → appended (logged); `act-intent` with no `criterion_started` → declined; a legal `act_intent`→`act_commit` sequence → appends normally; no state-machine.json / a fold-anomaly path unaffected. Existing journal-emit 67+ cases green. Run → FAIL.
- [ ] **Step 2** — implement the pre-append edge guard (read the journal for the tuple's current state; membership-check against `legalSubStateEdges`; `--force` bypass logged). Keep every legal path byte-identical to today (no regression).
- [ ] **Step 3** — tests green both engines + no regression (journal-emit, checkpoint 265, fold); dist; validate-adapters; portability. Commit: `feat(fsm): cooperative transition guard in journal-emit declines illegal sub-state edges (best-effort; qa-verify is authority)`.

---

### Task 5: ADR-0021 + docs + phase-name reconciliation

Record the statechart, the record-only authority, the fold-inferred sub-states, the phase-name reconciliation, and the per-harness assurance tier.

**Files:**
- Create: `docs/adr/0021-run-fsm-enforcement.md` — the statechart-as-data; sub-states fold-inferred (not agent-emitted); phase-surface record-only → qa-verify (NOT a hard cage); the phase-name reconciliation (adopt the agent's actual 6 names; the spec's `Discover`/missing-`Remember` list was aspirational); the cooperative transition guard; per-harness assurance tier (Codex managed strongest; others best-effort; qa-verify universal authority). Amend/close the deferred spec's open questions.
- Modify: `skills/checkpointing-qa-memory/SKILL.md` — document `state-machine.json`, the fold sub-state + illegal-edge anomaly, qa-verify phase-surface, the transition guard; add the scripts to the Scripts Reference; `state-machine.json` to the layout. (Note: SKILL.md is near its 500-line ceiling — condense; if it would exceed, put the FSM detail in a `references/` doc and link.)
- Modify: `CONTEXT.md` — add `statechart`, `sub-state`, `transition guard`, `phase surface`, `illegal-edge` glossary terms (the durability spec §9 noted `transition guard` belongs here).
- Modify: `docs/adr/0020-durable-run-state-machine.md` — a one-line pointer that the deferred FSM enforcement now landed as ADR-0021.

- [ ] **Step 1** — ADR-0021 (the full record: statechart, fold-inferred, record-only authority, phase-name reconciliation, assurance tiers).
- [ ] **Step 2** — SKILL.md (condensed; < 500 or moved to references/) + CONTEXT terms + ADR-0020 pointer.
- [ ] **Step 3** — dist regen; validate-adapters exit 0; commit: `docs(fsm): ADR-0021 run-FSM-enforcement — statechart, fold-inferred sub-states, record-only phase-surface, phase-name reconciliation`.

---

## Self-Review

**1. Spec coverage** (deferred spec §1/§2/§3 + open questions):
- Statechart-as-data (`state-machine.json`) + legal-edges + guards → Task 1. ✅
- Fold infers sub-states + validates legal edges (illegal-edge anomaly) → Task 2. ✅
- Phase-surface enforcement record-only → qa-verify (temporal toolstream-vs-plan fold) → Task 3. ✅
- Cooperative transition guard (declines illegal edge; 3-arg CLI preserved) → Task 4. ✅
- Open Q1 (sub-states emitted vs inferred) → **fold-inferred** (Task 2, constraint). Open Q2 (per-harness assurance tier) → Task 5 ADR. Phase-name drift reconciliation → Task 5. ✅
- **Non-goal honored:** NOT a hard cage — record-only phase-surface, cooperative guard, qa-verify authority (constraint + Task 3/4/5). ✅

**2. Grounding-gap alignment:**
- No state-machine.json → Task 1 (under references/, dist-copied). ✅
- No sub-state computation → Task 2 (fold pass-2 inference from Plan B events). ✅
- No legal-edge validation → Task 2 illegal-edge anomaly (data-driven). ✅
- qa-verify doesn't read journal/toolstream/plan_frozen; toolstream has no phase tag → Task 3 reads them + temporally correlates. ✅
- No transition guard beyond honesty gate → Task 4 cooperative decline. ✅
- Phase-name drift (agent's 6 vs spec's list) → adopt the agent's names, reconcile in ADR-0021 (Task 5). ✅
- Dependencies satisfied (capture/block-hook, qa-verify, durability) → confirmed. ✅

**3. Placeholder scan:** none — each task names exact files, the statechart shape, the sub-state inference table, the illegal-edge/phase-surface finding shapes, the temporal-correlation mechanism, test fixtures, and commit messages.

**4. Type consistency:** the sub-state enum (`pending,arranging,acting,baking,reconciling,verdict`) is identical in `state-machine.json`, the fold's inference, `cursor.json.subState`, and the tests. The `illegal-edge` anomaly shape (`{rule,tuple,from,to}`) matches across fold + tests. `phaseToolSurface` keys = the declared `phases` (validated by Task 1). qa-verify's `phase-surface` finding lands in the existing `verification.json` `{criterionId,…,confidence,reasons}` shape (H2). Reuses Plan A/B's `fold.*`/`journal.sh`/`journal-emit.sh` + H2's `qa-verify.sh`/`toolstream.sh` verbatim. Verdict/confidence/layer vocab unchanged; sub-states are internal machine state, never a verdict.
