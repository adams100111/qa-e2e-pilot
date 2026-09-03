# ADR-0021 — Run FSM enforcement: statechart-as-data, fold-inferred sub-states, record-only phase-surface

## Status

Accepted, 2026-09-03. Implements the deferred `docs/specs/2026-09-02-run-fsm-enforcement-design.md`
and the plan `docs/superpowers/plans/2026-09-03-run-fsm-enforcement.md`. Un-blocks ADR-0020's
scope note (the durability core shipped without this; this ADR closes the gap it left open).
Depends on ADR-0020 (journal/fold/`plan_frozen`/idempotent acts) and Plan H2 (capture-hook,
block-hook, `qa-verify.sh`, `toolstream.jsonl`) — both now shipped.

## Context

ADR-0020 made the journal the source of truth for a Run but explicitly deferred the harder
question: does the pipeline actually have a *machine*, and if so, what enforces it? The deferred
spec (`2026-09-02-run-fsm-enforcement-design.md`) identified a contradiction that had to be
resolved before any of this could be built: the obvious-looking "guarded transition API" is
**cooperative, not intercepting** — `checkpoint.sh`/`journal-emit.sh` are scripts the agent
*chooses* to invoke, so they can decline to *record* an illegal edge but cannot *prevent* the
agent doing off-phase work with Read/Write/browser tools directly. And a phase-*dependent* live
block-hook is exactly what Spec 1 (ADR-0018) §5.2 already concluded is infeasible: "current
phase" is agent-supplied, not present in a tool call, and reading it back out of `fold(journal)`
doesn't help because that file is agent-writable on an unhardened install — a hard bound built on
it evaporates the moment an adversarial agent bumps its own phase pointer.

The deferred spec's resolution was to make phase-surface enforcement **record-only → `qa-verify`**
(the pipeline's existing out-of-agent, deterministic authority — ADR-0018), never a live hard
bound, and to leave two open questions for un-defer time: are the six per-criterion sub-states
agent-emitted or inferred, and what per-harness assurance tier applies to a best-effort live flag.
This ADR records how those questions were answered and what actually shipped.

## Decision

1. **The statechart is data, not code.** `skills/checkpointing-qa-memory/references/state-machine.json`
   declares the Run's 6 `phases` (with `order`), the 6 per-criterion `subStates`
   (`pending, arranging, acting, baking, reconciling, verdict`), `legalPhaseEdges` (the pipeline's
   strictly linear phase sequence), `legalSubStateEdges` (the sub-state grammar — mutating,
   non-mutating-but-baked, and pure-observe paths, all converging on `verdict`), `guards`
   (`{edge, requires}` — `arranging→acting` requires `mutates`; `arranging→baking` and
   `arranging→verdict` require `not-mutates`; `acting→baking` requires an observed `act_committed`;
   the wildcard `*→verdict` requires the honesty gate), `toolClasses` (the closed tool-class
   vocabulary — `browser-navigate`, `browser-snapshot`, `browser-interaction`,
   `browser-evaluate-readonly`, `browser-evaluate-mutating`, `browser-mutation`, `probe`, `bash`),
   and `phaseToolSurface` (per-phase allowed/forbidden tool classes). `state-machine-schema.md`
   documents the shape plus the sub-state inference table; `validate-state-machine.sh` checks the
   file is structurally well-formed and internally cross-referenced (every edge references a
   declared phase/sub-state, every guard references a declared edge or a `["*", to]` wildcard,
   every `phaseToolSurface` key is a declared phase, `phaseToolSurface` classes are members of
   `toolClasses`). All three consuming mechanisms — fold, `qa-verify`, and the transition guard —
   read this one file and hold only the generic edge-check procedure; renaming or adding a phase,
   sub-state, edge, or tool-surface rule is a data edit here, never a code change in three places.

2. **Sub-states are fold-inferred, never agent-emitted (closes deferred-spec Open Q1).**
   `fold.jq`/`fold.py`'s existing pass-2 per-tuple state tracking (`started`/`verdict`) was
   extended to also track `act_intent`/`act_committed` for the tuple and derive its current
   `subState` from that plus the frozen plan's `mutates` field — purely by replaying journal
   events Plan B (ADR-0020) already emits (`plan_frozen`, `criterion_started`, `act_intent`,
   `act_committed`, `criterion_verdict`). No new event type, no CLI change: the 3-arg
   `checkpoint.sh <run> <crit> <verdict>` path is byte-for-byte unchanged, and neither
   `checkpoint.sh` nor `journal-emit.sh` grew a "declare your sub-state" argument. `cursor.json`
   gained a `subState` field (the current cursor tuple's inferred sub-state) purely as fold
   output. Fold also gained an `illegal-edge` anomaly (`{rule:"illegal-edge", tuple, from, to,
   guard}`), added to `fold-anomalies.json` — never a fold abort, matching the existing
   "record-the-anomaly, stay total" discipline every other fold rule follows (torn lines,
   duplicate `plan_frozen`, `act_committed` with no `act_intent`, `verdict-without-started`).
   Reasoning for inferring rather than emitting: emission would have meant a new call protocol
   threaded through every existing caller of `checkpoint.sh`/`journal-emit.sh` (the agent
   persona prose, `interaction-discipline.md`, `generating-qa-checklist`, `bootstrapping-qa-config`,
   `report-to-junit.sh`) for a fact fold could already derive for free from events already being
   written. Sub-states remain **internal machine state** — the verdict vocabulary
   (`pass|fail|blocked|deferred|error`) and confidence (`high|low`) are completely unchanged and
   orthogonal; a sub-state is never reported to a human as an outcome.

3. **Phase-name reconciliation: the statechart adopts the agent's actual emitted names.**
   `core/persona-body.md` names and numbers the pipeline's phases `Pre-flight`(0), `Analyze`(1),
   `Generate`(2), `Verify`(3), `Report`(4), `Remember`(5). The deferred spec's phase list —
   `PreFlight → Analyze → Discover → Generate → Verify → Report` — was **aspirational, not
   descriptive**: it invented a "Discover" phase the pipeline never emits, and omitted "Remember"
   (the pipeline's actual phase 5, owned by `checkpointing-qa-memory`). `state-machine.json`'s
   `phases` array uses the six real, emitted names, matched case-insensitively to the free-text
   `--phase` value a caller supplies. This is stated explicitly here so a future reader comparing
   the deferred spec against the shipped statechart does not conclude the implementation drifted
   from the design — the design's phase list was the part that was wrong, and this ADR is the
   record of adopting reality over the earlier aspiration.

4. **Phase-surface enforcement is record-only, and its authority is `qa-verify` — never a hard
   cage.** `qa-verify.sh` gained a phase-surface pass: it reads `journal.ndjson`'s
   `phase_entered` timeline and each criterion's `act_intent`/`act_committed` acting-windows, the
   H2 `toolstream.jsonl` (tool calls carry `ts`/`seq` but no phase tag), and
   `state-machine.json`'s `phaseToolSurface`, and temporally correlates each toolstream call to
   the phase active at its timestamp (the last `phase_entered` at or before that `ts`) plus
   whether it fell inside some criterion's acting window. Two rules fire independently: (a) a
   **mutating** tool call that falls outside every criterion's acting window is flagged, but
   **only when at least one acting window was actually recorded** (`windows_active`) — the 3-arg
   `checkpoint.sh` CLI path emits no `act_intent`/`act_committed` events at all, so on a run using
   only that path this rule is silently inapplicable rather than firing a false positive against
   a window that could never have existed; (b) a tool call whose class is in the *active phase's*
   `forbiddenToolClasses` fires regardless of `windows_active` (e.g. `browser_*` after `Report`
   was entered) — this needs only the `phase_entered` timeline, which every run using
   `journal-emit.sh` produces. Either finding is written to `verification.json` as a single
   synthetic `criterionId:"__phase-surface__"` record with **`verifierVerdict:"pass"` and
   `confidence:"low"`, always** — it is deliberately never a hard override of any criterion's
   verdict. No `toolstream.jsonl` present degrades to no phase-surface check at all (never a
   false positive from absent data), matching every other H2 mechanism's fail-open/degrade
   posture. This is the record-only design Spec 1 §5.2 required: `qa-verify` runs out-of-agent,
   after the fact, on data the agent cannot retroactively edit without also editing the toolstream
   it is being checked against — the honest, achievable form of "phase surface," as opposed to a
   live bound that a hardened phase pointer could never actually deliver.

5. **The transition guard is cooperative — it declines to write, it cannot prevent acting.**
   `journal-emit.sh`'s `act-intent` and `act-commit` subcommands gained a pre-append guard: before
   appending, they infer the tuple's current sub-state from the journal exactly as fold would, and
   check the edge the new event implies against `state-machine.json`'s `legalSubStateEdges` (read
   via an overridable `STATE_MACHINE_JSON` path, so tests can point it at a mutated copy without
   touching the shipped file). An illegal edge — `act-commit` with no matching prior `act-intent`
   for the tuple, or `act-intent` with no prior `criterion_started` — is **declined**: nothing is
   appended, the command exits non-zero, and a message names the violated edge. A `--force` flag
   bypasses the decline (logged as a NOTE on stderr) for legitimate exceptions. If
   `state-machine.json` is absent, the guard skips entirely and the call proceeds as it did before
   this ADR — deliberately the opposite posture from `fold.sh`, which dies on a missing statechart,
   because this guard is best-effort scaffolding, not the authority, and its absence must never
   block a run. The existing 3-arg `checkpoint.sh <run> <crit> <verdict>` path is untouched; its
   only guard remains the honesty gate it already had. This mechanism guards **recorded** state —
   it declines to let an illegal edge enter the journal — but it does nothing to stop an agent from
   doing off-surface work with Read/Write/browser tools directly, bypassing `journal-emit.sh`
   altogether. That gap is exactly why decision 4 exists: `qa-verify`, not this guard, is the
   authority on whether the agent actually stayed on-surface.

6. **Per-harness assurance tier (closes deferred-spec Open Q2).** The three mechanisms above have
   different live-enforcement strength depending on harness, and this ADR states that honestly
   rather than implying a uniform guarantee:
   - **Codex** — the managed-sandbox harness; its execution environment is agent-proof at the OS
     level, giving phase-independent absolutes (the block-hook's mutating-`browser_evaluate`/
     `browser_run_code_unsafe` denials) the strongest live backing of any harness today.
   - **Claude, Pi, opencode** — best-effort. The plugin-bundled capture-hook/block-hook exist and
     run identically to Codex's (Plan H2's logic is copied verbatim into every `dist/<h>/`), but
     the hook *script files* themselves are user-writable on an unhardened install — there is no
     hash-chain or other tamper-evidence on the hook code, so an adversarial agent could in
     principle edit its own guard. Porting Codex-grade managed-sandbox live enforcement to these
     three harnesses is tracked as **pending H4 work** — it has not shipped as of this ADR.
   - **`qa-verify` is the universal deterministic authority on every harness, unconditionally.**
     It runs out-of-agent (a separate process, no LLM in its core), reads the same
     `toolstream.jsonl`/`journal.ndjson`/`state-machine.json` shape on all four harnesses, and its
     override of a forged `pass` does not depend on which harness produced the run. Every harness's
     assurance floor is `qa-verify`; the live hooks above it are an accelerant, not the guarantee,
     and Codex's is a stronger accelerant than the other three's today.

7. **Closing the deferred spec's open questions, explicitly.** Q1 ("agent-emitted or
   fold-inferred?") → **fold-inferred** (decision 2). Q2 ("per-harness assurance tier?") →
   **tiered, Codex strongest, others best-effort, `qa-verify` universal** (decision 6). The
   spec's phase-name list (`PreFlight → Analyze → Discover → Generate → Verify → Report`) is
   **reconciled to the pipeline's real 6 emitted names** (decision 3) — not an open question the
   spec posed, but a drift this ADR closes so it is not mistaken for an unresolved gap by a future
   reader. The spec's non-goal — "any hard machine cage a human QA tester doesn't need" — is
   honored throughout: nothing shipped here can *prevent* an agent from acting off-surface, only
   detect it (fold's `illegal-edge` anomaly, after the fact), record-only-flag it (`qa-verify`'s
   phase-surface pass), or decline to *write* it (the cooperative transition guard).

## Consequences

- A Run now has a declared, data-driven statechart that three independent mechanisms read
  consistently — editing `state-machine.json` (e.g. adding a phase, tightening a phase's tool
  surface) changes fold's anomaly detection, `qa-verify`'s phase-surface pass, and the transition
  guard's decline behavior simultaneously, with no code change in any of them.
- **Still not a cage, by design.** An agent that never calls `journal-emit.sh`/`checkpoint.sh` at
  all, and instead does off-phase work directly with Read/Write/browser tools, leaves no
  `illegal-edge` for fold to flag and no illegal edge for the transition guard to decline — the
  only mechanism that can still catch it is `qa-verify`'s temporal toolstream-vs-phase correlation,
  and only when a toolstream was actually captured (H2's capture-hook, best-effort on
  Claude/Pi/opencode, strongest on Codex per decision 6). This is the honestly-scoped floor Spec 1
  §5.2 already accepted; this ADR does not raise it, only builds correctly to it.
- **Honest residual: live-hook porting to Claude/Pi/opencode is pending (H4).** Decision 6's tier
  statement is accurate as of this ADR, not aspirational — a future ADR or plan should update it
  if/when that porting work lands, rather than this document being silently stale.
- `checkpoint.sh`'s 3-arg CLI and its 265-assertion characterization suite are unaffected; runs
  that never touch `journal-emit.sh act-intent`/`act-commit` simply never populate acting windows,
  which decision 4's `windows_active` gate accounts for rather than misreporting as a violation.
- Verdict (`pass|fail|blocked|deferred|error`) and confidence (`high|low`) vocabularies are
  unchanged; sub-states are additive internal machine state, never surfaced as a verdict.
- **Reversibility:** the statechart, fold's sub-state/illegal-edge inference, `qa-verify`'s
  phase-surface pass, and the transition guard are all additive on top of ADR-0020's durability
  core and Plan H2's out-of-agent enforcement — none of them change what a `pass`/`fail` means or
  how a run resumes. Reverting means deleting `state-machine.json` and its three call sites
  (fold degrades to no `subState`/`illegal-edge` output, `qa-verify` degrades to no phase-surface
  pass, `journal-emit.sh`'s guard skips per its documented absent-file posture) — a clean,
  low-risk rollback if this layer is ever judged not worth its complexity.
