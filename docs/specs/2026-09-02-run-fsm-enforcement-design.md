# Run FSM enforcement — statechart + guarded transitions + phase surface — design (DEFERRED)

**Status:** design — **DEFERRED / blocked** (2026-09-02). Split out of the durable-Run-state effort (`2026-09-02-durable-run-state-machine-design.md`, ADR-0020) per grilling Q12. **Do not implement until its dependency lands and its core contradiction is resolved** (below). Future record: **ADR-0021** (not yet written).

## Why this is a separate, deferred spec

The durability core (journal / fold / idempotency / resume) ships independently and needs nothing. *Hard enforcement* — making the Run a machine-caged FSM where the agent physically cannot skip a phase or act off-surface — is a different, riskier thing that (a) depends on Spec 1's **not-yet-built** `PreToolUse` block-hook, and (b) contradicts Spec 1's own design. Bundling it would have blocked the durability win on an unsettled argument. It is captured here so the decisions aren't lost, to be built after Spec 1's hook lands.

## The blocking contradiction to resolve first (grilling Q1 + Q2)

- **The transition API is cooperative, not intercepting (Q1).** `checkpoint.sh` is a script the agent *chooses* to invoke; it can *decline to record* an illegal `phase_entered`, but it cannot *prevent* the agent doing off-phase work with Read/Write/browser tools. So the transition API guards **recorded state** (edge legality on the events it is given, verdict guards) — it does **not** "force" phase order. Any claim of hard phase-order enforcement must live in the **block-hook** (which intercepts tool calls), not the API.
- **Phase-*dependent* live-blocking is what Spec 1 §5.2 concluded is infeasible (Q2).** Spec 1's block-hook enforces only phase-*independent absolutes* precisely because "phase is agent-supplied and not in the tool call," and it makes the one phase-dependent case (`browser_navigate`) **record-only → `qa-verify`**. If the phase-surface hook reads "current phase" from `fold(journal)`, that file is agent-writable (Spec 1 §6: hook scripts and the files they read are user-writable on unhardened installs) — so an adversary bumps the journal's phase and the "hard bound" evaporates.

**Resolution this spec must adopt:** phase-surface enforcement is **record-only → `qa-verify`** (matching Spec 1), *not* a uniform hard bound. The live hook may *advise/flag* an off-phase tool call (best-effort, per-harness tier), but the authoritative "you acted outside the sanctioned surface" verdict comes from the out-of-agent `qa-verify` folding the toolstream against the frozen plan. State the assurance tier per harness (Codex managed = strongest; others best-effort). Do **not** ship "hard bound" language.

## What this spec will contain (once unblocked)

1. **Statechart as data** — `state-machine.json`: phases `PreFlight → Analyze → Discover → Generate → Verify → Report`; per-criterion sub-states `pending → arranging → acting → baking → reconciling → verdict` (acting skipped when the *derived* mutation flag is false — §durability-core §5, Q10, never an agent boolean). **Legal-edges-only + transition guards** validated by the transition API when it *is* invoked (e.g. `→ verdict:pass` requires the honesty gate; `acting → baking` requires `act_committed`). This guards *recorded* state; it is the "decline to record an illegal edge" mechanism, not a cage.
2. **Phase-surface enforcement (record-only → `qa-verify`)** — `qa-verify` folds the toolstream against the frozen plan + statechart and flags any tool used outside its sanctioned phase (mutating act outside Verify `acting`; `browser_*` in Report). The live block-hook may additionally best-effort-flag, per harness tier, but is not the guarantee.
3. **Backward-compat for `checkpoint.sh` (grilling Q8)** — the existing 3-arg `checkpoint.sh <run> <crit> <verdict>` upsert stays the sole state-mutation entrypoint (internally: append event + fold); enumerate exactly which sub-state transitions the agent must emit vs which the fold *infers* (if the six sub-states never appear in a `checkpoint.sh` call, they are inferred prose, not agent-emitted machine state). Ship a caller-migration ticket covering `tests/checkpoint/`, `tests/action-trace/`, and every current caller (agent md phase 3, `interaction-discipline.md`, `generating-qa-checklist`, `bootstrapping-qa-config`, `report-to-junit.sh`).

## Dependencies (all must be true before building)
- Spec 1's capture-hook + block-hook are **implemented** (ADR-0018 leaves Proposed today; no hook file exists).
- Spec 1's `qa-verify` exists (the phase-surface authority).
- The durability core (ADR-0020) has landed (journal/fold/frozen-plan are the substrate the statechart guards).

## Non-goals
- Any "hard machine cage" that a human QA tester doesn't need — the goal is a tester bounded by discipline + the honesty gate + `qa-verify`, not an un-escapable sandbox (which isn't portably achievable anyway, Spec 1 §1).

## Open questions to answer at un-defer time
- Are the six per-criterion sub-states agent-emitted through `checkpoint.sh`, or fold-inferred? (Decides whether this is a new call protocol or pure projection.)
- Per-harness assurance tier for the best-effort phase-surface flag (reuse the `harness-capability-matrix.md` tiers).
