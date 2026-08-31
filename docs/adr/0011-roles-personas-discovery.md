# ADR-0011 — Roles/personas: two-plane discovery, role×lens, frontier-round HITL, regenerate-not-reconcile

## Status

Accepted (2026-08-31). Part of the accuracy overhaul ([docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md), Settled Decisions 4/5/11), implemented in Phase 2 ([docs/plans/2026-08-31-phase2-coverage-roles.md](../plans/2026-08-31-phase2-coverage-roles.md), Workstream 2B).

Status convention (normalizes the earlier ambiguity across 0001–0010): an ADR is **Accepted** as soon as the decision it records is the one the current phase is implementing on disk — it does not wait for every downstream task in that phase to land, provided the decision itself is settled and not still forking. An ADR is **Proposed** only when the decision is genuinely future work not yet being built in the active phase. This ADR and ADR-0012 are Accepted because Phase 2 is actively implementing the role/persona model they describe.

## Context

The measured baseline treated every QA run as a single anonymous/first-user persona. This structurally cannot catch role- and authz-shaped bugs (missing scope filters, wrong-role UI leaks, permission-gated actions that silently no-op) because nothing in the pipeline ever logs in as more than one kind of user. The master plan's Decision 4 requires QA to run as discovered roles; Decision 11 requires the human-in-the-loop confirmation for that discovery to be a dependency-aware round-based frontier, not a single flat form; Decision 5 requires the resulting config to be generated fresh from the codebase, not merged into whatever a human previously hand-tuned.

Phase 2 (this plan) is the first phase that actually builds any of this. It needed to settle: what a "persona" is; how roles are found; how the human confirms them without either being asked open-ended questions ("what roles does your app have?") or being shown 20 independent yes/no toggles that hide the roles→credentials→scope dependency; and whether `.qa/config.json`'s persona block is generated once and defended, or replaced every run.

## Decision

Four settled decisions, together:

1. **Persona = discovered ROLE × review LENS** (master plan Decision 4). A persona is not just a role name — it pairs a role (who is logged in) with a lens (what kind of reviewer is looking: `skeptical-auditor` default, plus `first-time-user`, `a11y-user`). **Phase 2 populates only the ROLE axis.** `discovering-user-roles` proposes roles; the HITL rounds (Decision 2 below) confirm them; role-sensitive criteria tag against confirmed roles. The LENS axis is out of scope until Phase 5, and Phase 5 MUST add it **additively** on top of whatever role mapping Phase 2 confirms — Phase 5 does not re-run role discovery or re-grill the role list; it only asks a further "which lens(es) for this run" question layered on the existing persona set. This keeps the two axes independently versionable and means Phase 5 cannot silently invalidate Phase 2's confirmed roles.

2. **Roles are discovered on TWO planes, both by static analysis, never by asking the human.**
   - **Global plane**: an RBAC/permission source of truth — a role enum (e.g. a Spatie-style `UserType::SUPER_ADMIN/ADMIN/EVALUATOR/USER/JURY`), a permission-seeder/config, or `role:` policy/middleware guards.
   - **Contextual plane**: roles that only exist relative to another entity — a team-member role column, a pivot-table role (e.g. `team_members.role`), a per-project/per-org membership role.
   Both planes feed one proposed `roles[]` list, each entry carrying its source citation and a recommended authentication method (seeded-credential form login where a fixture user exists, else `storageState` capture). Discovery degrades to `signal: weak` (anonymous + whatever role is discoverable) rather than failing outright when the codebase gives no clean signal — this mirrors `detecting-stack-profile`'s degrade-not-fail posture for unknown stacks.

3. **HITL confirmation is a native reimplementation of `grilling`'s frontier-in-rounds pattern, not a dependency on the `grilling` skill and not `bootstrapping-qa-config`'s flat one-shot form.** Per ADR-0001 (reimplement patterns, never fork/vendor/depend-on another skill's runtime), the round/frontier *shape* — numbered items, each with a recommended default and a source citation, human confirms/edits/drops, and editing an item invalidates and recomputes every later round that depends on it — is documented and implemented from scratch in `skills/bootstrapping-qa-config/references/hitl-rounds.md`. Roles → credentials → scope is modeled explicitly as a **dependency tree**, not a flat list, because it is one: which credential strategy applies depends on which roles survived Round 1; which scope entries are even testable depends on which account got bound to each role in Round 2. Concretely, three rounds:
   - **Round 1 — Roles.** The two-plane proposal from Decision 2, each item defaulted to "include, test as this role."
   - **Round 2 — Credentials.** Per role confirmed in Round 1, a recommended auth method with its source; dropping a Round 1 role removes its Round 2 entry entirely (never orphaned).
   - **Round 3 — Scope.** Per role, its recommended role-sensitive scope derived from the FK-ownership chains the static analysis found (see ADR-0012 for how this scope is used in testing); editing a Round 2 credential recomputes whichever Round 3 entries depended on that specific account's data.
   `bootstrapping-qa-config`'s existing flat `AskUserQuestion` batch (baseUrl/environment/auth-method/allow-writes) remains correct **for its own four questions**, which have no dependency edges between them — it is explicitly not the reference implementation for role/persona confirmation, which is tree-shaped.

4. **Regenerate, not reconcile** (master plan Decision 5). Once all three rounds are confirmed, `.qa/config.json`'s `personas[]` block and the sibling authz-matrix (ADR-0012) are **written fresh** from the codebase-discovered + human-confirmed set, using the skill's existing deterministic-writer convention (never hand-authored JSON) — replacing any prior persona block wholesale rather than diffing/merging into it. The project's current codebase state is the source of truth for who its roles are; a stale, hand-tuned `.qa/config.json` from a previous run is not defended against contradicting it. Regeneration *proposes* (via the three rounds); the human confirms before anything is written.

Per-role authentication uses **seeded-credential form login** — the round proposes a seeded fixture user's credentials for a role when one exists; passwords are never guessed, brute-forced, or printed to logs/transcripts/evidence artifacts. When no seeded user exists for a role, the recommended default falls back to a captured `storageState`, per the existing driver convention in `driving-browser-qa`.

## Consequences

- Enables everything ADR-0012 depends on: per-role journeys (the same criterion walked as different logged-in users) and cross-role authz negative tests (persona B must not see persona A's owned entity).
- Role/authz recall is measured against a real multi-role application (`innovation`), not the single-user synthetic fixture — the fixture is documented (Phase 0) as single-user/localStorage and cannot exercise this axis. This is a deliberate, stated measurement-scope boundary, not an oversight.
- The lens axis (Phase 5) is deferred but explicitly not blocked: because Phase 2's confirmed role mapping is additive-compatible, Phase 5 can layer lenses on without re-touching Round 1–3's output.
- `bootstrapping-qa-config`'s SKILL.md gains a one-line pointer to `references/hitl-rounds.md` for persona confirmation, keeping its own flat-batch step untouched and correctly scoped to its four independent questions.
- No verdict-vocabulary or suspected-layer change — persona is a dimension roles/criteria run across, not a new field in the fixed `pass|fail|blocked|deferred|error` / `FE|route|service|migration|DB` enums.

## Alternatives considered

- **Reconcile into existing `.qa/config.json`** (diff/merge a newly discovered role list against whatever a human previously hand-edited): rejected — a stale block silently wins over the actual codebase, producing drift between what the config claims and what the app really has; regeneration with HITL confirmation keeps the codebase authoritative while still giving the human final say.
- **Flat one-shot HITL form** (a single `AskUserQuestion` batch listing every role/credential/scope decision at once, matching `bootstrapping-qa-config`'s existing pattern): rejected for this specific confirmation — roles→credentials→scope is a dependency tree, and a flat batch cannot express "editing this role invalidates that credential and those scope rows," so an edit would either be silently ignored downstream or require the human to manually re-derive consistency themselves.
- **Depend on the external `grilling` skill** for the round/frontier machinery: rejected per ADR-0001 — this plugin reimplements reusable *patterns*, it does not take a runtime dependency on, fork, or vendor another skill. `references/hitl-rounds.md` is a from-scratch implementation of the same shape, with no import of or call into `grilling`.
- **Persona = role only, no lens axis**: rejected — collapsing "who is logged in" and "what kind of review is being performed" into one dimension would make it impossible to later run the same role through a stricter or more accessibility-focused review pass without re-discovering roles; keeping them orthogonal (even though Phase 2 only populates one axis) avoids a future breaking change.

## References

- `skills/discovering-user-roles/SKILL.md` — two-plane discovery, `roles[]` output shape, `signal: strong|weak` degrade path.
- `skills/bootstrapping-qa-config/references/hitl-rounds.md` — the round schema and frontier-recompute algorithm this decision requires.
- `skills/bootstrapping-qa-config/SKILL.md` — Round 1/2/3 persona-confirmation step; existing flat `AskUserQuestion` batch (explicitly out of scope for this decision).
- [ADR-0001](./0001-reimplement-opslane-patterns-not-fork-or-vendor.md) — reimplement-not-depend precedent this decision follows for the frontier-rounds pattern.
- [ADR-0002](./0002-run-state-in-dot-qa-not-agent-memory.md) — run-state-on-disk convention `.qa/config.json`'s regenerated persona block extends.
- [ADR-0012](./0012-per-role-scope-and-cross-role-tests.md) — how the confirmed role set and its authz-matrix scope are consumed by test execution and cost containment.
- [CONTEXT.md](../../CONTEXT.md) — verdict/oracle/driver-session vocabulary this decision does not alter.
