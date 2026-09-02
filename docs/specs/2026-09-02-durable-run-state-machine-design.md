# Durable Run state — journal, fold, idempotency, resume — design

**Status:** design (awaiting review) · **Date:** 2026-09-02 · **Topic:** make a QA **Run** crash/compaction/interruption-safe from start to end — resumable from the exact point of interruption, never double-creating — by refactoring `checkpointing-qa-memory` so an append-only journal is the single source of truth. This is the **durability core**; the contested *hard-enforcement statechart* (guarded transition API + phase-surface block-hook) is split into a **deferred companion spec** — `2026-09-02-run-fsm-enforcement-design.md` — because it depends on Spec 1's not-yet-built hook and must reconcile a design contradiction with it. This core ships with no such dependency.

Companions: honesty hardening (`2026-09-02-qa-honesty-hardening-design.md`, ADR-0018) — reuses its re-bake for idempotency reconciliation; human-eye UX (ADR-0019) — governed by this. Harness grounding: `harness-capability-matrix.md`. Record: **ADR-0020**.

> **Split rationale (grilling Q12):** the journal + fold + idempotency + resume are self-contained, high-value, and depend on nothing — they make a Run *reliably finish despite interruption*, which is what a human QA tester needs. The statechart *enforcement* is contested (its phase-surface hook contradicts Spec 1 §5.2, which concludes phase-dependent live-blocking is infeasible) and blocked on Spec 1. Splitting lets the durability win ship clean; enforcement follows once its dependency lands.

---

## 0. Goal

A Run is long (many criteria × roles, minutes-to-hours) and spans LLM context compaction and possible crashes. Today "where am I" is scattered across a mutable `checkpoint.json` + run-manifest + persona-keying. Goal: make position **durable and computed** — a Run resumes correctly from any interruption because its truth is an append-only journal in files, folded deterministically, never the agent's (compaction-prone) memory; and a crash mid-write never double-creates.

## 1. What breaks today
- **Mutable state tears:** `checkpoint.json` is overwritten in place; a crash mid-write yields an unparseable half-file — resume can't read its position.
- **Compaction is a silent partial restart:** the agent's sense of position degrades across compactions; if that (not a durable fold) drives resume, it drifts.
- **No idempotency:** a crash mid-`human-action`-create + a naïve re-drive double-creates; before/after fingerprints alone can't tell "did my earlier create land?".

## 2. What holds (build on)
`.qa/runs/<id>/` files never agent memory (ADR-0002); `checkpoint.sh` cursor + memory-spec artifacts; sequential-by-default + narrow fan-out (ADR-0003); personas (ADR-0011/0012); `frontier.js`; the honesty gate (ADR-0010/0015/0018).

## 3. Source of truth: the journal + fold

- **`.qa/runs/<id>/journal.ndjson`** — append-only, one event per line: `run_started` · `phase_entered` · `plan_frozen` · `scenario_started` · `criterion_started` · `act_intent{key,writeSet}` · `act_committed{outcome}` · `criterion_verdict{verdict,confidence,layer,evidenceRefs}` · `bug_logged` · `phase_exited` · `run_ended`. Every event carries its own timestamp (so fold is time-deterministic).
- **`checkpoint.json` / `run-manifest` / `bug-log` / `traceability` are DERIVED** by `fold(journal)`; the journal wins on disagreement. Existing file *shapes* are preserved (readers/tests unaffected), gaining durability underneath.
- **Fold is total (grilling Q6):** it is defined over every malformed-event class, not just a torn tail — a torn/partial last line is discarded; a `criterion_verdict` with no preceding `criterion_started`, a duplicate `plan_frozen`, or an `act_committed` with no `act_intent` are each handled by an explicit rule (skip-with-warning / last-wins / flag-for-reconcile), recorded in a `fold-anomalies` note, never a silent mis-parse.
- **Atomic derived writes:** temp → `fsync` → `rename` → parent-dir `fsync`. The journal is append + flush.
- **Serialization is canonical (grilling Q7):** derived files use ONE pinned serializer (sorted keys, timestamps sourced from journal events). Fold-equivalence is judged **semantically** (canonicalized-JSON compare), never byte-for-byte (jq vs python3 differ) — see AC.
- **Concurrency under fan-out (grilling Q6):** the opt-in parallel path (ADR-0003) does **not** append to the shared journal directly — each fan-out child writes a per-child `journal.<child>.ndjson`, and the parent merges them under an advisory `flock` with a monotonic sequence number so fold can detect gaps. `O_APPEND` interleave on NFS/container-bind mounts (DDEV targets) is thereby avoided.
- **"Where am I" = `fold(journal)`** — never agent memory. Compaction-safe by construction.

## 4. State tracking (scenario / role / criterion)

The fold exposes the **cursor**: current phase, current scenario+role, current criterion. (Tracking only — *hard-gating* transitions is the deferred enforcement spec; here transitions are recorded, not machine-prevented.)

- **Scenario ↔ persona (grilling Q3):** `scenarioId == persona_id`. A **scenario = one role's ordered storyline of criteria** (a role-sensitive/authz criterion). Per ADR-0012, **shared criteria run once, as the most-privileged role** — they live under a synthetic `__shared__` scenario keyed to the most-privileged persona, so the `(scenario, criterion)` atomic unit covers the whole Run without duplicating shared criteria per role. The fold reconciles this with ADR-0012's existing `(criterion_id, persona="")` back-compat records (empty persona ⇒ the `__shared__` scenario).
- **Atomic resumable unit:** `(scenario, criterion)`; fold → skip tuples with a recorded verdict → re-enter the first without one.

## 5. Idempotency + crash-safe acts

- **Mutation flag is DERIVED, not agent-declared (grilling Q10):** whether a criterion mutates (and therefore must bracket its act) is derived from its declared action shape by deterministic rules (the same discipline ADR-0018 uses to re-derive `requiredKinds`), never trusted from an agent-authored boolean — and cross-checked by the capture-hook when available (any mutating tool observed during a "no-mutation" criterion → flag). This closes the "mark it read-only to skip the bracket + gate" hole.
- **Full write-set probe (grilling Q4):** a mutating criterion declares its **write-set** — every entity + natural key it is expected to persist (e.g. founder-row **and** shareholder-row). `act_intent{key,writeSet}` is journaled *before* the act; `act_committed{outcome}` *immediately after*. Key = `runId:scenarioId:criterionId` (never per-attempt).
- **Resume reconciliation:** fold finds an `act_intent` with no `act_committed` → probe (re-bake, reusing ADR-0018) the **full write-set**: **all landed** → journal `act_committed` (done); **none landed** → retry once; **partial** → `blocked`/`error` naming the specific missing key — **never a silent "done."** A write-only entity with no read path (deferred-bake) is stated explicitly: reconciliation is `deferred` with reason, not a blind retry.
- **Journal ↔ ground-truth authority (grilling Q11):** the journal is the resume *cursor*, but the `act_committed` decision is **corroborated by the re-bake** (and the toolstream where present): journal-says-committed but re-bake-says-not-landed → retry once; journal-says-not-committed but re-bake-says-landed → record done. The agent-authored journal never overrides the independent re-bake on the landed/not question.

## 6. Resume — first-class + portable

- **`/qa-resume [run-id]`** (operator-invoked, portable, needs no hook) + `.qa/runs/latest` pointer, so the run is discoverable independent of harness session / git branch / cwd.
- **Plan frozen at the Generate→Verify boundary (grilling Q5)** — `plan_frozen` records the frozen criterion set + order + personas/scenarios, emitted *after* Generate (not at Run start; the plan doesn't exist earlier). **Verify** replays against the frozen plan, never a re-observed app. A crash *before* `plan_frozen` (in PreFlight/Analyze/Discover/Generate) resumes by re-running those setup phases from their own `phase_entered`/artifact checkpoints — and setup-phase discovery is inherently a *re-observation* of the app, which is permitted there (only Verify forbids it). A criterion added mid-Verify is an explicit `plan_amended` event.
- **Two distinct resume mechanisms (grilling Q9):** (a) **explicit `/qa-resume`** — portable, hook-free, the guaranteed path everywhere; (b) **automatic mid-run rehydrate** — a per-phase re-read of the fold so a mid-phase compaction is harmless. On Claude/Codex/Pi a SessionStart-style hook can trigger (b); **opencode has no such hook**, so there (b) is a **documented protocol step** — the agent re-reads the fold at each phase entry — and the guarantee is stated as "correct on explicit resume; mid-compaction correctness rests on the per-phase re-read protocol, not a hook."
- **Portable invariant:** assume **only** that `.qa/runs/<id>/` survived and the scripts can re-derive position; never trust harness restore, a stable session id, a fired hook, linear (non-forked) history, or an unchanged model. Checkpoint after every criterion; **write-through synchronously** (never defer a durable write to an exit/idle hook — opencode can't block idle).

## 7. Per-harness resume verification
Each adapter ships a resume test: kill mid-`act` on a create criterion → resume → assert (a) fold lands on the right `(scenario, criterion)`, (b) no completed criterion re-runs, (c) the open act is reconciled by full-write-set re-bake (no double-create, no silent partial). **Plus** an induced-**compaction-without-explicit-resume** test on each harness (the §6-b path), including opencode's protocol-step variant.

## 8. Scope + the deferred companion
- **Refactor + hardening of `checkpointing-qa-memory`:** journal = truth; existing artifacts = derived folds; atomic writes; idempotency; portable resume. `checkpoint.sh` continues to write state, now by **appending events + folding** — its existing 3-arg CLI is preserved (backward-compat is a first-class concern; the transition-*guard* semantics are the deferred spec's).
- **Deferred companion — `2026-09-02-run-fsm-enforcement-design.md`:** the statechart-as-data, the guarded transition API (legal-edges-only), and the phase-surface block-hook. Deferred because it depends on Spec 1's hook and must reconcile with Spec 1 §5.2 (phase-dependent live-blocking → record-only + `qa-verify`, not a hard bound). This core does not block on it.
- Verdict/vocabulary unchanged.

## 9. CONTEXT terms
`journal`, `fold`, `scenario`, `idempotency probe`, `frozen plan` (added). (`transition guard` belongs to the deferred enforcement spec.)

## 10. Acceptance criteria
1. **Fold is authoritative + semantically equivalent:** delete `checkpoint.json`; `fold(journal)` regenerates it **canonically-equal** (sorted-key JSON compare, timestamps from events) — not byte-equal. A run with a corrupt `checkpoint.json` but intact journal resumes correctly.
2. **Torn/malformed-safe:** truncating the last journal line, and each malformed-event class (§3), is handled by fold per its rule with a `fold-anomalies` note; no derived file left half-written.
3. **No double-create / no silent partial on resume:** kill mid-act on a multi-write create; resume → the full-write-set probe finds all/none/partial and records done / retries once / `blocked`-with-missing-key respectively; multiplicity count is correct.
4. **Derived mutation flag:** a criterion the agent marks "no mutation" but whose action shape mutates is still bracketed + gated (not skipped).
5. **Resume without harness help:** with the harness session discarded, `/qa-resume` finds the run via `.qa/runs/latest`, folds, and continues — on all four harnesses; plus the induced-compaction-without-explicit-resume test passes (opencode via the protocol step).
6. **Pre-freeze resume defined:** a crash during Analyze/Discover/Generate resumes by re-running those phases from their checkpoints; only Verify replays the frozen plan.
7. **Concurrency-safe journal:** a fan-out run writes per-child sub-journals merged under lock; fold detects no gap and drops no committed verdict.
8. **No recall/verdict regression** on the accuracy-harness; the refactor changes durability, not verdicts.

## 11. Out of scope
- The hard statechart enforcement (deferred companion spec).
- A server-backed durable-execution engine; time-travel replay; cross-run/distributed orchestration.

## 12. Decisions locked
1. Append-only `journal.ndjson` = source of truth; checkpoint/manifest derived; fold total over malformed events; atomic + canonical derived writes; per-child sub-journals under fan-out (§3).
2. `scenarioId == persona_id`; shared criteria under a synthetic `__shared__`/most-privileged scenario, ADR-0012-reconciled (§4).
3. Mutation flag derived (not agent-declared); full-write-set idempotency probe; partial → `blocked`, never silent done; re-bake corroborates `act_committed` (§5).
4. `plan_frozen` at Generate→Verify; pre-freeze resume re-runs setup phases; `/qa-resume` (portable) vs auto-rehydrate (hook or opencode protocol-step) separated (§6).
5. Byte-equivalence downgraded to **semantic** equivalence (§10).
6. **Split:** hard-enforcement statechart deferred to `2026-09-02-run-fsm-enforcement-design.md`; this durability core ships independently (§8).

## Appendix — ticket-sized cut
- **D-1:** journal schema + `fold` (total over malformed events) + atomic-write + canonical-serializer helpers. *(§3)*
- **D-2:** `checkpoint.sh` writes via append-event + fold, 3-arg CLI preserved. *(§3, §8)*
- **D-3:** scenario/persona mapping in the fold (`__shared__`, ADR-0012 back-compat). *(§4)*
- **D-4:** derived mutation-flag rules + full-write-set idempotency (`act_intent`/`act_committed`). *(§5)*
- **D-5:** resume reconciliation (fold → open-act → full-write-set re-bake → done/retry/blocked; re-bake corroboration). *(§5, reuses ADR-0018 re-bake)*
- **D-6:** `/qa-resume` + `.qa/runs/latest` + `plan_frozen`/`plan_amended` + per-phase rehydrate protocol. *(§6)*
- **D-7:** per-harness resume tests incl. induced-compaction-without-resume. *(§7)*
- **D-8:** fan-out sub-journal + lock + sequence-gap detection. *(§3)*
- **ADR-0020** + CONTEXT terms.
