# Phase 2 — Coverage + Role/Persona Discovery Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Granular expansion of Phase 2. Two workstreams: **2A Coverage** (the recall lever the re-measurement pinpointed) lands first and is testable against the fixture; **2B Roles/Personas** follows.

**Goal:** Lift true bug-recall past the 33% baseline by (2A) making the checklist generator systematically emit the edge-case criteria that catch F3/J1/J3/J4/F4, and (2B) discovering a project's user roles and QA-ing as each persona with cross-role authz negative tests.

**Autonomous-mode note:** running under `/loop` — design forks are resolved with the recommended default (logged below), not grilled. The grilling-round machinery is still BUILT into the runtime HITL (Decision 11); it just isn't used to pause this build loop.

## Global constraints (inherited)
Verdicts `pass|fail|blocked|deferred|error` (no 6th); confidence `high|low`; suspected layer `FE|route|service|migration|DB`; oracle = spec/domain rule; run state in `.qa/runs/`; sequential-by-default (ADR-0003); probing read-only + secrets never printed; browser tools by capability; skill frontmatter name+description only, body <500 lines, ≥3 mini-evals; **no Claude/Anthropic attribution in commits/PRs**.

## Settled defaults (logged, not grilled — autonomous mode)
- **Persona = discovered role × review lens** (Decision 4). Discovery is two-plane: global RBAC (enum/permission config) + contextual team roles. HITL confirm is a grilling-style round at *runtime* (Decision 11), regenerate-not-reconcile (Decision 5).
- **Per-role cost containment** (Decision 6): only `role-sensitive` criteria + authz negative tests multiply per role; shared criteria run once as the most-privileged role.
- **Coverage catalog is REQUIRED emission**, not optional prose: the generator must emit each applicable edge-case type or explicitly emit a `deferred` with a reason (no silent gaps).

---

## Workstream 2A — Systematic edge-case coverage (recall lever, lands first)

**Why first:** the re-measurement showed the gate buys precision; recall gains come from *generating the criteria in the first place*. F3/J1/J3/J4/F4 were missed because no criterion tested them. This is testable against the current fixture (a re-measurement should show recall rise).

### Task 2A.1 — Required edge-case catalog in generating-qa-checklist
**Files:** Modify `skills/generating-qa-checklist/SKILL.md` (+ `templates/checklist.md`).
- Add a REQUIRED "edge-case coverage" catalog: for every write-bearing surface the generator MUST emit criteria for — **empty/0-value input**, **negative/out-of-range value**, **every-Nth repetition** (silent-drop detection at multiplicity N≥3), **named/boundary edge** (reserved-looking values), **delete-then-reconcile** (aggregate re-reconciliation after a delete), and (when roles exist) **cross-role/tenant absence**. Each maps to the seeds it would catch (0-value→J4, negative→F4, every-Nth→J3, silent-persist→J1, delete-reconcile→F3, cross-role→authz).
- When a surface can't support a type (e.g. no delete), emit a `deferred` criterion with the reason — never a silent skip.
- Each emitted edge criterion carries its derived `Kinds` (bake/computed) + `probe-needed` per the existing Phase-1 mapping, so the gate forces evidence.
- Keep body <500 lines; update ≥1 mini-eval to show an edge-case criterion set.

### Task 2A.2 — Re-measure coverage against the fixture
**Files:** none (measurement). Serve the fixture, run the gated agent with the new catalog, convert+score. Target: functional recall rises (F3/J4 at minimum become catchable; F4 via the Task-5 negative-entry rule; J1/J3 via named/every-Nth). Record the number; precision must stay ≥ its current 100%.

---

## Workstream 2B — Role/persona discovery

### Task 2B.1 — `discovering-user-roles` skill
**Files:** Create `skills/discovering-user-roles/SKILL.md` (+ scripts/templates as needed).
- Two-plane static analysis: (1) **global roles** from an RBAC/permission source (e.g. a role enum, a permission-seeder/config, policy/middleware `role:` guards); (2) **contextual roles** (team-member role columns, pivot roles). Emit a proposed `roles[]` with, per role, its source citation + how to authenticate (seeded credential pattern / storageState). Degrades to `signal: weak` (anonymous + any discoverable role) rather than failing.
- Frontmatter name+description only; body <500 lines; ≥3 mini-evals (incl. a spatie-style Laravel case like `innovation`); gerund name = dir.

### Task 2B.2 — HITL persona confirmation as grilling rounds + config generation
**Files:** Modify `skills/bootstrapping-qa-config/` (or a new step) so discovery → **grilling-style round** (numbered roles with recommended defaults; facts auto-discovered, only the mapping confirmed) → deterministically WRITE `.qa/config.json` `personas[]` + an authz matrix (regenerate, not reconcile). Per-role auth = seeded-credential form login. NB: bootstrapping-qa-config's flat form is NOT the reference — use rounds/frontier (Decision 11).

### Task 2B.3 — role-sensitive tagging + cross-role negative tests
**Files:** Modify `skills/generating-qa-checklist/` + `agents/qa-e2e-pilot.md` phase-3.
- Criteria gain a `role-sensitive` tag; only those + authz negative tests multiply per persona. **Cross-role negative test** = "persona B must NOT see persona A's owned entity" (relational ownership per the innovation authz matrix) → a `pass` requires a `probe` bake showing absence. Shared criteria run once as most-privileged.

### Task 2B.4 — ADR-0011 (roles/personas) + ADR-0012 (per-role scope)
**Files:** Create `docs/adr/0011-*.md`, `docs/adr/0012-*.md`. Record the two-plane discovery, persona=role×lens, grilling-round HITL, regenerate-not-reconcile (0011); per-role cost containment + cross-role negative tests (0012). Normalize ADR status convention while here.

---

## Sequencing
2A.1 → 2A.2 (re-measure, land 2A as its own increment) → 2B.1 → 2B.2 → 2B.3 → 2B.4 (land 2B). Each landed via PR→merge. Re-measure after 2A (fixture) and note that role/authz recall is measured against `innovation` (a real multi-role app), not the single-user fixture.

## Acceptance
- 2A: the gated fixture run's functional recall rises vs the 33% baseline; precision stays ≥ current; no silent coverage gaps (deferred criteria carry reasons).
- 2B: `discovering-user-roles` proposes the correct roles on `innovation` (global spatie enum + team roles); config generation is deterministic; a cross-role negative test correctly fails when isolation is broken.
