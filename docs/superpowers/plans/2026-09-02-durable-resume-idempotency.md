# Durable Resume + Idempotency (Plan B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a QA Run **resumable from the exact point of interruption and idempotent under crash** on top of Plan A's journal/fold substrate: emit the start/plan/act events Plan A defined but left unfed, bracket every mutating act with an idempotency key + write-set, build a **write-set re-bake reconciliation** so a crash mid-`human-action`-create never double-creates and never silently half-completes, and add a **portable `/qa-resume`** (+ `.qa/runs/latest` pointer + per-phase rehydrate protocol) that works on all four harnesses with no hook.

**Scope note — this is Plan B of the durable-Run-state effort (ADR-0020), the follow-up to the merged Plan A substrate.** It ships the durability spec's **D-4-remainder / D-5 / D-6 / D-7** (`docs/specs/2026-09-02-durable-run-state-machine-design.md` §5/§6/§7 + Appendix). It **explicitly does NOT** build the deferred FSM-enforcement spec (`2026-09-02-run-fsm-enforcement-design.md`): no `state-machine.json`, no legal-edge/guarded-transition layer, no six per-criterion sub-states (`arranging/acting/baking/reconciling`), no phase-name validation. Plan B only **emits** the coarse events (`plan_frozen`/`plan_amended`/`criterion_started`/`act_intent`/`act_committed`), **folds** them (Plan A's fold already handles them), **reconciles** open acts by re-baking, and **resumes**. Enforcement of legal event ordering is the deferred companion spec's job (blocked on the honesty-hardening hook + `qa-verify`, neither of which exists).

**Architecture:** A new emission entrypoint `journal-emit.sh` (subcommands `started`/`freeze`/`amend`/`act-intent`/`act-commit`) is the single place that writes the start/plan/act events, wired into the agent orchestrator prose (`core/persona-body.md`, which renders to `agents/qa-e2e-pilot.md` under the byte-oracle) at the Generate→Verify boundary (freeze) and the per-criterion Verify loop (started + act bracketing). A `rebake.sh` reconciliation script classifies a criterion's declared **write-set** read-backs into all-landed / none / partial (reusing `record-evidence.sh bake`'s `bake-read-back.json` shape and the checkpoint gate's null-vs-multiplicity-0 rule); the actual read-backs come from the **resumed session's own browser/probe capability** (not a standalone Node fetch — `backend-probe.js` is browser-context-only). A `qa-resume.sh` + new `/qa-resume` command (authored across `core/commands/` + `commands/` + `build-adapter.sh` + `validate-adapters.sh`, per the multi-harness ADR-0017 discipline) folds the latest run, reconciles open acts, and continues at the first unverdicted `(scenario, criterion)` tuple. A `.qa/runs/latest` pointer (atomic-written on run start) makes the run discoverable independent of harness session / branch / cwd.

**Tech Stack:** Bash (`set -uo pipefail`), `jq` preferred / `python3` fallback (+ Plan A's `QA_ENGINE` passthrough), Plan A's `journal.sh`/`fold.sh`/`atomic_write`, `record-evidence.sh bake`, `mutation-flag.sh derive`. Multi-harness generator (`build-adapter.sh`) + byte-oracle (`validate-adapters.sh`).

## Global Constraints

- **`jq` preferred / `python3` fallback / `die` if neither; NO `node`** for any journal/emit/fold/reconcile path. New scripts reuse Plan A's `has_jq`/`has_py`/`die` and honor `QA_ENGINE`.
- **Do NOT regress Plan A.** `journal.sh`/`fold.*`/`checkpoint.sh`/`mutation-flag.sh`/`journal-merge.sh` and their suites (journal 32, fold 63, checkpoint 248, journal-merge 45, mutation-flag 30) stay green. New emission goes through `journal.sh append` (never a second writer), so the journal invariants (monotonic seq, atomic append, torn-tail-safe) hold unchanged.
- **Idempotency key is `runId:scenarioId:criterionId`** (never per-attempt) — Plan A's schema `act_intent{key,writeSet}` / `act_committed{key,outcome}`. `journal-emit.sh act-intent` is journaled **before** the act; `act-commit` **immediately after**.
- **Mutation flag is DERIVED** (Plan A's `mutation-flag.sh derive`), never an agent boolean — it decides whether a criterion's act is bracketed. Confirmed fail-safe direction (over-brackets a read-only criterion; never skips a mutating one).
- **Re-bake reconciles the FULL write-set, never a silent "done."** `rebake.sh` classifies: **all landed** → journal `act_committed{outcome:"landed"}`; **none landed** → retry once (re-drive the act), then re-bake; **partial** → `blocked` naming the specific missing key. A write-only entity with no read path → `deferred` with reason. The journal is the resume *cursor*; the **re-bake is the authority on landed/not** (journal-says-committed but re-bake-says-not → retry once; journal-says-not but re-bake-says-landed → record done). Reuses `verifying-backend-persistence`'s ordered-multiplicity + `blocked`/`deferred` vocabulary.
- **Read-backs come from the resumed session's browser/probe capability** — `rebake.sh` is the classifier + journal writer, fed read-back JSON; it does NOT itself do authenticated HTTP (`backend-probe.js` is browser-page-context-only). Resume-time reconciliation therefore runs inside the agent's Verify capability, not standalone. Document this precondition.
- **Resume is PORTABLE-ONLY (no hooks).** Ship exactly: `/qa-resume [run-id]` (operator-invoked) + `.qa/runs/latest` + a documented **per-phase rehydrate protocol** (the agent re-reads `fold(journal)` at each phase entry). Do **NOT** build harness-specific SessionStart hooks — the durability spec's "SessionStart hook on Claude/Codex/Pi" claim is **not grounded** (`harness-profiles.json` has no hooks field; `harness-capability-matrix.md` has no session-hook row). Honor the matrix's own doctrine: portable `/qa-resume` = the floor/guarantee; a hook (where a harness has one) is a future accelerant, never built here. Document per-harness that auto-rehydrate is the protocol step, not a hook (opencode especially).
- **`plan_frozen` at the Generate→Verify boundary; Verify replays the frozen plan.** A crash BEFORE `plan_frozen` (PreFlight/Analyze/Generate) resumes by re-running those setup phases from their `phase_entered`/artifact checkpoints (setup-phase re-observation of the app is permitted; only Verify forbids re-observation). A criterion added mid-Verify is a `plan_amended` event.
- **Phase names = the AGENT's actual names** (`Pre-flight/Analyze/Generate/Verify/Report/Remember` as emitted via `--phase` today). Do NOT introduce a phase-name constant/enum or validate against the FSM spec's `PreFlight→Analyze→Discover→Generate→Verify→Report` list — that reconciliation is the deferred FSM spec's job. (Note the drift for that spec; do not fix it here.)
- **`writeSet` on the checklist is optional + best-effort.** A mutating criterion SHOULD declare its write-set (entities + natural keys) in the checklist; `plan_frozen` carries it. When absent, re-bake falls back to the criterion's single primary entity at low confidence, and records the degrade — never fails the Run for a missing write-set.
- **Multi-harness command discipline (ADR-0017).** A new `/qa-resume` requires FOUR coordinated edits: `core/commands/qa-resume.md` (tokenized source, only `{{DISPATCH}}` if needed), a `render < core/commands/qa-resume.md > "$OUT/commands/qa-resume.md"` line in `build-adapter.sh` (~line 85), the root `commands/qa-resume.md` (hand-authored byte-identical to the Claude render — the repo root IS the Claude adapter), and a `diff -q commands/qa-resume.md dist/claude/commands/qa-resume.md … || fail` line in `validate-adapters.sh` (~line 29). The agent-md changes (persona-body.md) are byte-oracled too.
- **Portability gate every task:** regenerate dist (`for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done`), `bash scripts/validate-adapters.sh` exit 0 (byte-oracle now covers the new command + the edited agent md), `bash tests/portability/run.sh` `FAIL=0` (no `grep -P`/`perl`). `dist/` git-ignored, never committed.
- **Commit messages: NO Claude/Anthropic attribution, NO `Co-Authored-By`.**

## Self-grilled decisions (my recommendations, applied)

- **Q1 emission mechanism** → a **new `journal-emit.sh`** (single emission entrypoint) rather than growing checkpoint.sh — keeps verdict-upsert and event-emission as separate concerns; both write through `journal.sh append`.
- **Q2 resume-time re-bake without a browser** → reconciliation runs **inside the resumed agent session** (which has browser/probe tools); `rebake.sh` is the classifier fed read-back JSON, not a standalone fetcher. No new Node authenticated-fetch primitive.
- **Q3 writeSet source** → optional checklist field, `plan_frozen`-carried, best-effort fallback to single primary entity when absent.
- **Q4 latest pointer** → `.qa/runs/latest` plain file with the run-id, `atomic_write`-written on `run_started`.
- **Q5 resume portability** → portable `/qa-resume` + rehydrate protocol ONLY; no SessionStart hooks (ungrounded); honest per-harness docs.
- **Q6 FSM boundary** → emit + fold + reconcile + resume only; no legal-edge guards / state-machine.json / sub-states (deferred spec).
- **Q7 phase names** → use the agent's actual names; no enum/validation; note the drift.

---

### Task 1: `journal-emit.sh` + `.qa/runs/latest` + start/plan emission wired into the orchestrator

Create the emission entrypoint and wire `plan_frozen` (Generate→Verify) + `criterion_started` (Verify loop) into the agent prose. This finally FEEDS the cursor Plan A computed (previously fixture-only) and lays the `run_started`-writes-`latest` pointer.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/journal-emit.sh`
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` — its internal `run_started` emission also writes `.qa/runs/latest` (atomic) so any run start (verdict-first or emit-first) sets the pointer.
- Modify: `core/persona-body.md` — add a `journal-emit.sh freeze` call at the end of Generate (before Verify) and a `journal-emit.sh started` call at the top of the per-criterion Verify loop. Regenerate `agents/qa-e2e-pilot.md` (byte-oracle).
- Create: `tests/journal-emit/run.sh`

**Interfaces:**
- `journal-emit.sh started <run> <scenarioId> <criterionId> <personaId>` → journals `criterion_started{scenarioId,criterionId,personaId}`.
- `journal-emit.sh freeze <run> <plan-json>` → journals `plan_frozen{criteria:[…],order:[…]}` (validates the plan-json shape). Idempotent guard: if a `plan_frozen` already exists, this is a `plan_amended` unless `--force` (a second freeze is the Plan A duplicate-plan-frozen anomaly; prefer amend).
- `journal-emit.sh amend <run> <criterionId> <scenarioId> <personaId> <mutates>` → journals `plan_amended`.
- `.qa/runs/latest` → a one-line file containing the run-id, atomic-written on run start.

- [ ] **Step 1** — write `tests/journal-emit/run.sh`: `started` appends a `criterion_started` line with the right ids; after a `started` + a `checkpoint.sh` verdict for the same tuple, `fold.sh` → `cursor.json` shows `criteria_total>=1` and (if another tuple is started-without-verdict) `cursor` points at it, and `fold-anomalies.json` has NO `verdict-without-started` for the started tuple (proving emission feeds the fold); `freeze` appends `plan_frozen`; a second `freeze` → `plan_amended` (not a duplicate); `checkpoint.sh` upsert writes `.qa/runs/latest` with the run-id. Run → FAIL.
- [ ] **Step 2** — implement `journal-emit.sh` (has_jq/has_py/die header; QA_ENGINE-honoring; each subcommand builds the event JSON and calls `journal.sh append`). Reuse `journal.sh`'s validation.
- [ ] **Step 3** — add the `.qa/runs/latest` atomic write to `checkpoint.sh`'s `run_started` branch (and to `journal-emit.sh started`/`freeze` if they can be the first event — write `latest` on the first event of a run regardless of which entrypoint emits it; factor a `write_latest <run>` helper).
- [ ] **Step 4** — edit `core/persona-body.md`: at the Generate→Verify boundary add "freeze the plan: `bash …/journal-emit.sh freeze <run> <plan-json>`"; in the Verify per-criterion loop add "at criterion start: `bash …/journal-emit.sh started <run> <scenario> <crit> <persona>`". Regenerate `agents/qa-e2e-pilot.md` from `core/persona-body.md` (via `build-adapter.sh claude`) so the byte-oracle matches.
- [ ] **Step 5** — run `tests/journal-emit/run.sh` + Plan A suites (journal/fold/checkpoint) green on both engines; `awk` persona-body/agent line parity; dist regen; `validate-adapters.sh` (agent byte-oracle must still pass — the persona-body edit is reflected in the committed `agents/qa-e2e-pilot.md`); portability.
- [ ] **Step 6** — commit: `feat(checkpointing): journal-emit.sh (started/freeze/amend) + .qa/runs/latest; wire plan_frozen + criterion_started into the orchestrator`.

---

### Task 2: Mutation-bracketed act emission (`act_intent` / `act_committed`)

Wire `mutation-flag.sh derive` so a mutating criterion's act is bracketed: `act_intent{key,writeSet}` before, `act_committed{key,outcome}` after. This is what makes a crash mid-act detectable (an open act = intent with no commit) for Task 4's reconciliation.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/journal-emit.sh` — add `act-intent <run> <scenarioId> <criterionId> <personaId> --write-set <json>` (derives `mutates`; only emits when mutating; key = `runId:scenarioId:criterionId`) and `act-commit <run> <scenarioId> <criterionId> <personaId> --outcome <landed|failed|unknown>`.
- Modify: `skills/driving-browser-qa/references/interaction-discipline.md` — document that a mutating criterion's act phase is bracketed by `act-intent`…`act-commit` (the human-path act between them). No gate weakening.
- Modify: `core/persona-body.md` — in the Verify loop's act phase for mutating criteria, add the bracket calls. Regenerate agent md.
- Create/extend: `tests/journal-emit/run.sh` — act bracket cases.

**Interfaces:**
- `journal-emit.sh act-intent … --write-set '[{"entity":"founder","key":"…"}]'` → if `mutation-flag.sh derive` on the criterion is true, journals `act_intent{key:"run:scn:crit",writeSet:[…]}`; else no-op (returns 0, prints `SKIP non-mutating`). Reuses Plan A's `mutation-flag.sh`.
- `journal-emit.sh act-commit … --outcome landed` → journals `act_committed{key,outcome}`.
- After a mutating criterion: journal has intent then commit; `fold.sh` → `openActs` empty. A crash between them leaves the intent in `openActs` (Task 4 consumes it).

- [ ] **Step 1** — tests: mutating criterion (`--write-set` + a mutating action) → `act-intent` emits `act_intent` with the composite key + writeSet; `act-commit` emits `act_committed`; `fold.sh` openActs empty after both, and NON-empty when only intent emitted (simulated crash). Non-mutating criterion → `act-intent` is a no-op (nothing journaled). Run → FAIL.
- [ ] **Step 2** — implement `act-intent`/`act-commit` in `journal-emit.sh` (derive-gated; key assembly; write-set passthrough).
- [ ] **Step 3** — document the bracket in `interaction-discipline.md`; wire the calls into `core/persona-body.md`'s act phase (mutating branch); regenerate agent md.
- [ ] **Step 4** — tests green (both engines) + Plan A suites; dist; validate-adapters (agent oracle); portability.
- [ ] **Step 5** — commit: `feat(checkpointing): mutation-bracketed act_intent/act_committed emission (derive-gated, write-set keyed)`.

---

### Task 3: Write-set re-bake classifier (`rebake.sh`)

Build the D-5 primitive: given a criterion's declared write-set and its read-back results, classify all-landed / none / partial / deferred and journal the outcome. Reuses `record-evidence.sh bake`'s shape + the checkpoint gate's null-vs-multiplicity-0 rule. The read-backs are supplied (from the resumed session's browser/probe), not fetched here.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/rebake.sh`
- Create: `tests/rebake/run.sh`

**Interfaces:**
- `rebake.sh classify --write-set <json> --readbacks <json>` where `readbacks` = `[{entity,key,found:bool,value?}]` for each write-set member → prints one of `landed` (all found), `none` (none found), `partial` (some, with the missing keys), `deferred` (a member marked write-only/no-read-path). Prints a JSON summary `{outcome, missing:[…], writeSetSize, foundCount}` on stdout.
- `rebake.sh reconcile <run> <scenarioId> <criterionId> <personaId> --write-set <json> --readbacks <json>` → calls `classify`; then: `landed`→journal `act_committed{outcome:"landed"}` (+ return `done`); `none`→return `retry` (caller re-drives once); `partial`→journal a `criterion_verdict` `blocked`+layer + return `blocked` naming missing keys; `deferred`→return `deferred` with reason. Never a silent "done."

- [ ] **Step 1** — tests: `classify` on all-found → `landed`; none-found → `none`; some-found → `partial` with the exact missing keys; a member `{writeOnly:true}` → `deferred`. `reconcile` `landed` → journals `act_committed` (fold openActs then empty); `partial` → journals a `blocked` verdict naming the missing key; `none` → returns `retry`, journals nothing. Dual-engine. Run → FAIL.
- [ ] **Step 2** — implement `rebake.sh` (classify pure function + reconcile that journals via `journal-emit.sh act-commit` / `checkpoint.sh` blocked-verdict). Reuse the `bake-read-back.json` `{readBack,multiplicity}` shape for evidence when recording.
- [ ] **Step 3** — tests green (both engines) + Plan A suites; dist; validate-adapters; portability.
- [ ] **Step 4** — commit: `feat(checkpointing): rebake.sh write-set classifier + reconcile (all/none/partial/deferred, never silent done)`.

---

### Task 4: Resume reconciliation (`qa-reconcile.sh`) — fold → openActs → re-bake

The resume-time glue: fold the run, find open acts (intent-without-commit), and for each, produce the re-bake plan the agent executes, then reconcile. Corroborates the journal against the re-bake (journal-says-committed but re-bake-says-not → retry; and vice-versa).

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/qa-reconcile.sh`
- Create: `tests/qa-reconcile/run.sh`

**Interfaces:**
- `qa-reconcile.sh plan <run>` → folds; prints the open acts (from `fold-anomalies.json` `openActs`) as `[{key, writeSet}]` — the work list the agent must re-bake (read back each write-set member). Empty ⇒ nothing to reconcile.
- `qa-reconcile.sh apply <run> <key> --readbacks <json>` → looks up the open act's write-set, calls `rebake.sh reconcile`, and returns the outcome (`done`/`retry`/`blocked`/`deferred`). On `retry` the caller re-drives the act (Task 2 bracket again) then calls `apply` once more; a second `retry` → escalate to `blocked`.

- [ ] **Step 1** — tests: a journal with an `act_intent` and no `act_committed` → `plan` lists that key + its writeSet; `apply` with all-found readbacks → `done` + `act_committed` journaled (openActs now empty on re-fold); `apply` with partial → `blocked`; a journal where the act WAS committed → `plan` is empty (nothing to do). The journal-vs-rebake corroboration: intent-committed-in-journal but readbacks show not-landed → `retry`. Dual-engine. Run → FAIL.
- [ ] **Step 2** — implement `qa-reconcile.sh` (fold, read `fold-anomalies.json.openActs`, join write-sets from the `act_intent` events, drive `rebake.sh`). Second-retry → blocked.
- [ ] **Step 3** — tests green + Plan A suites; dist; validate-adapters; portability.
- [ ] **Step 4** — commit: `feat(checkpointing): qa-reconcile.sh resume reconciliation (openActs -> write-set re-bake -> done/retry/blocked)`.

---

### Task 5: `/qa-resume` command + resume flow (`qa-resume.sh`)

The operator-facing portable resume. `qa-resume.sh` resolves the run (arg or `.qa/runs/latest`), folds, reconciles open acts, and reports the resume point (phase + first unverdicted tuple + skip-list). The `/qa-resume` command wires it across all four harnesses (ADR-0017 discipline).

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/qa-resume.sh`
- Create: `core/commands/qa-resume.md` (tokenized source)
- Create: `commands/qa-resume.md` (root, byte-identical to the Claude render)
- Modify: `scripts/build-adapter.sh` — add the `render < core/commands/qa-resume.md > "$OUT/commands/qa-resume.md"` line.
- Modify: `scripts/validate-adapters.sh` — add the `diff -q commands/qa-resume.md dist/claude/commands/qa-resume.md … || fail "claude qa-resume oracle"` line.
- Create: `tests/qa-resume/run.sh`

**Interfaces:**
- `qa-resume.sh [run-id]` → run-id = arg or the content of `.qa/runs/latest` (error clearly if neither); folds; prints `{run_id, phase, cursor:{scenarioId,criterionId}|null, openActs:[…], skip:[…completed tuples…]}` — the resume briefing. Does NOT itself drive the browser; the agent (via `/qa-resume`) reads this, runs `qa-reconcile.sh` for any open acts, and continues Verify at `cursor`.
- `/qa-resume [run-id]` command → dispatches the agent with the resume briefing + the rehydrate protocol.

- [ ] **Step 1** — tests: `qa-resume.sh` with no arg reads `.qa/runs/latest`; resolves + folds + prints the cursor and skip-list (completed tuples) correctly; with an explicit run-id overrides `latest`; errors clearly when neither exists. A run with an open act → the briefing's `openActs` is non-empty. Run → FAIL.
- [ ] **Step 2** — implement `qa-resume.sh`. Author `core/commands/qa-resume.md` (mirror `core/commands/qa-run.md` structure: frontmatter + Arguments + "What to do": read the briefing from `qa-resume.sh`, reconcile open acts via `qa-reconcile.sh` before touching UI, then continue Verify from `cursor` — Verify replays the FROZEN plan, no re-observation). Add the `build-adapter.sh` render line + the `validate-adapters.sh` diff line. Generate `commands/qa-resume.md` as the Claude render (`build-adapter.sh claude` then copy `dist/claude/commands/qa-resume.md` to `commands/qa-resume.md`).
- [ ] **Step 3** — tests green; dist regen; `validate-adapters.sh` exit 0 (the new `/qa-resume` byte-oracle line passes; residual-token guard clean for the new command across all four harnesses); portability.
- [ ] **Step 4** — commit: `feat(commands): /qa-resume portable resume (qa-resume.sh + latest pointer) across all four harnesses`.

---

### Task 6: Resume + idempotency integration test (`tests/resume-idempotency/run.sh`)

The D-7 end-to-end proof (portable, harness-agnostic bash — the per-harness accuracy run is the manual procedure in docs/harness-adapters.md, not this test). Simulate a kill mid-act on a create criterion; resume; assert (a) fold lands on the right `(scenario, criterion)`, (b) no completed criterion re-runs, (c) the open act is reconciled by full-write-set re-bake (no double-create, no silent partial). Plus an induced-compaction-without-explicit-resume assertion (the rehydrate protocol: re-fold mid-run yields the same cursor).

**Files:**
- Create: `tests/resume-idempotency/run.sh`

- [ ] **Step 1** — build the scenario in a temp run dir purely from journal events + script calls: emit `run_started`, `phase_entered Verify`, `plan_frozen` (2 criteria, one mutating with a write-set), `criterion_started`+`criterion_verdict pass` for criterion 1, then `criterion_started`+`act_intent` for the mutating criterion 2 and **stop** (simulated crash mid-act, no `act_committed`). Assert `qa-resume.sh` briefing: cursor = criterion 2's tuple, skip-list includes criterion 1, openActs = [criterion-2 key].
- [ ] **Step 2** — reconcile: `qa-reconcile.sh apply` with all-landed readbacks → `done` (act_committed journaled); re-fold → openActs empty, cursor still criterion 2 (started, not yet verdicted) → the agent would now finish its verdict. Assert no duplicate `act_intent`/no criterion-1 re-run. Then the partial-landed variant → `blocked` naming the missing key (no silent done). Then the none-landed variant → `retry`.
- [ ] **Step 3** — rehydrate-without-explicit-resume: fold the same journal twice (simulating a mid-run compaction where the agent just re-reads the fold) → identical cursor both times (compaction-safe by construction). Assert.
- [ ] **Step 4** — run green (both engines); dist (no source change but run the gate); validate-adapters; portability.
- [ ] **Step 5** — commit: `test(checkpointing): resume + idempotency integration (kill mid-act -> resume -> full-write-set reconcile, no double-create)`.

---

### Task 7: Document resume + idempotency (SKILL.md, CONTEXT, ADR-0020, harness note)

Record the resume/idempotency mechanics where they're documented; update the stale directory-scan resume protocol to the `/qa-resume` + `.qa/runs/latest` path; add CONTEXT terms; note the honest per-harness resume situation (portable-only, no hooks).

**Files:**
- Modify: `skills/checkpointing-qa-memory/SKILL.md` — replace the "Resume Protocol" (directory-scan + grep) with `/qa-resume`/`qa-resume.sh` + `.qa/runs/latest`; add `journal-emit.sh`/`rebake.sh`/`qa-reconcile.sh`/`qa-resume.sh` to the Scripts Reference; add `.qa/runs/latest` to the layout tree; a mini-eval for kill-mid-act→resume→no-double-create. Body < 500 lines.
- Modify: `CONTEXT.md` — confirm/add `idempotency probe` and `frozen plan` glossary terms (durability spec §9 says these are "added"); one line each.
- Modify: `docs/adr/0020-durable-run-state-machine.md` — note Plan A + Plan B both landed; resume is portable-only (no hooks), FSM enforcement still deferred.
- Modify: `docs/superpowers/specs/…`/`docs/harness-adapters.md` — one line that per-harness resume is the portable `/qa-resume`; auto-rehydrate is a protocol step (re-read fold at phase entry), NOT a hook (opencode has no session hook; the others' hooks are a future accelerant, not built).

- [ ] **Step 1** — SKILL.md edits (resume protocol rewrite + scripts + layout + mini-eval); `awk` < 500.
- [ ] **Step 2** — CONTEXT.md `idempotency probe` + `frozen plan` (glossary-only, no impl detail).
- [ ] **Step 3** — ADR-0020 + harness-adapters resume note (honest portable-only framing).
- [ ] **Step 4** — dist regen; validate-adapters exit 0; commit: `docs(checkpointing): document /qa-resume + idempotency; portable-only resume (no hooks); CONTEXT idempotency-probe/frozen-plan`.

---

## Self-Review

**1. Spec coverage** (durability spec §5/§6/§7 + Appendix D-4-rem/D-5/D-6/D-7):
- Emit start/plan/act events (unbuilt in Plan A) → Tasks 1 (started/freeze/amend) + 2 (act bracket). ✅
- D-5 full-write-set idempotency probe + all/none/partial + never-silent-done + journal↔re-bake corroboration → Tasks 3 (classifier) + 4 (resume reconciliation). ✅
- D-6 `/qa-resume` + `.qa/runs/latest` + `plan_frozen` + per-phase rehydrate → Tasks 1 (latest/freeze) + 5 (command/flow) + 7 (rehydrate protocol doc). ✅
- D-7 per-harness resume test incl. induced-compaction-without-explicit-resume → Task 6. ✅
- **Explicitly deferred (FSM enforcement spec, blocked):** state-machine.json, legal-edge guards, six sub-states, phase-name validation — NOT built (stated in header + Q6). ✅

**2. Grounding-gap alignment (from exploration):**
- No emitter for start/plan/act events → Tasks 1-2 add `journal-emit.sh` (single entrypoint through `journal.sh append`). ✅
- `mutation-flag.sh` unwired → Task 2 derive-gates the act bracket. ✅
- No write-set re-bake primitive → Task 3 builds the classifier (reusing `record-evidence.sh bake` shape). ✅
- `backend-probe.js` browser-only → reconciliation runs in the resumed session; `rebake.sh` is fed read-backs, doesn't fetch (constraint + Task 3/4). ✅
- No `.qa/runs/latest`/`/qa-resume` → Tasks 1 (latest) + 5 (command). ✅
- `harness-profiles.json` has no hooks field; SessionStart claim ungrounded → portable-only resume, honest per-harness docs (constraint + Task 7); no hooks built. ✅
- Phase-name drift → use agent names, no validation (constraint + Q7). ✅
- New command needs 4 coordinated edits → Task 5 does all four (core/commands + build-adapter + commands root + validate-adapters). ✅

**3. Placeholder scan:** none — each task names exact files, subcommand signatures, event shapes, test assertions, and commit messages. The re-bake read-back *fetching* is deliberately out of the scripts (browser-context) and documented as a resumed-session precondition, not a placeholder.

**4. Type consistency:** the idempotency key `runId:scenarioId:criterionId` and `writeSet` shape (`[{entity,key,…}]`) are identical across `journal-emit.sh act-intent`, `plan_frozen.criteria[].writeSet`, `rebake.sh`, and `qa-reconcile.sh`. Outcomes (`landed/none/partial/deferred` → `done/retry/blocked/deferred`) are used identically in Tasks 3-4-6. All new scripts reuse Plan A's `has_jq`/`has_py`/`die`/`QA_ENGINE`/`journal.sh append`/`fold.sh` — no second journal writer. `/qa-resume`'s four-file discipline matches `build-adapter.sh`/`validate-adapters.sh`'s existing two-command hardcoded pattern.
