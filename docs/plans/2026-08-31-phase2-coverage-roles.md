# Phase 2 — Coverage + Role/Persona Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking. This is the granular expansion of Phase 2 from `docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md` (master), written after Phase 1's MEASURED result (see that plan's `## Phase 1 result (MEASURED)` block: functional 38% / precision 100% gated vs. 33%/75% ungated baseline). Two workstreams: **2A Coverage** (the recall lever the re-measurement pinpointed) lands first and is testable against the fixture; **2B Roles/Personas** follows.

**Goal:** Lift true bug-recall past the 33% ungated / 38% gated baseline by (2A) making the checklist generator systematically emit the edge-case criteria that catch F3/J1/J3/J4/F4, and (2B) discovering a project's user roles and QA-ing as each persona with cross-role authz negative tests.

**Autonomous-mode note:** running under `/loop` — design forks are resolved with the recommended default (logged below), not grilled. The grilling-ROUND *pattern* (numbered items, recommended defaults, frontier recompute on edit) is not yet implemented anywhere in this plugin — `grep -rn "grilling\|frontier" skills/ agents/` returns nothing. Every place this plan says "grilling-style round" is a REQUIREMENT to reimplement that pattern natively (Task 2B.0), per ADR-0001 (reimplement, don't fork/vendor/depend-on the `grilling` skill); it is not describing existing runtime behavior.

## Status as of 2026-08-31 (already shipped, do not re-do)

- **Edge-case coverage catalog is LIVE** in `skills/generating-qa-checklist/SKILL.md` Step 3 — 8 rows: empty/0-value, negative/out-of-range, every-Nth repetition, named/boundary, delete-then-reconcile, cross-role/tenant absence, **terminal/locked-state repeat action**, and **input-boundary** (oversized/decimal/unicode/whitespace). The last two were added after the original Task 2A.1 was scoped and are already in place — Task 2A.1 below is scoped down to the remaining gap (the criteria-budget guard), not the catalog itself.
- **Fixture hardening for F1/F4 is LIVE**: `3b77395` exposed an observable ESOP pool so F1 (issued-only-denominator bug) is black-box-detectable; `4432279` made N1 an honest persisted control and seeded F4 (negative shares, no validation) + J4 (0-share false-success toast).
- Neither of these needs a task below; they are listed so re-reads of this plan don't duplicate the work.

## Global constraints (inherited)
Verdicts `pass|fail|blocked|deferred|error` (no 6th); confidence `high|low`; suspected layer `FE|route|service|migration|DB`; oracle = spec/domain rule; run state in `.qa/runs/`; sequential-by-default (ADR-0003); probing read-only + secrets never printed; browser tools by capability; skill frontmatter name+description only, body <500 lines, ≥3 mini-evals; **no Claude/Anthropic attribution in commits/PRs**.

## Settled defaults (logged, not grilled — autonomous mode)
- **Persona = discovered role × review lens** (Decision 4, master plan). **Phase 2 populates only the ROLE axis** — `discovering-user-roles` (2B.1) proposes roles, 2B.2 confirms them, 2B.4 tags role-sensitive criteria. The LENS axis (`skeptical-auditor`/`first-time-user`/`a11y-user`) is Phase 5 scope and MUST be added **additively** on top of the confirmed role mapping — Phase 5 must not regenerate or re-grill the role mapping Phase 2 already confirmed; it only asks a further "which lens(es) this run" question.
- Discovery is two-plane: global RBAC (enum/permission config) + contextual team roles. HITL confirm is a **grilling-style round at runtime** (Decision 11) — reimplemented by Task 2B.0, consumed by Task 2B.2. Regenerate-not-reconcile (Decision 5).
- **Per-role cost containment** (Decision 6): only `role-sensitive` criteria + authz negative tests multiply per role; shared criteria run once as the **most-privileged role**. "Most-privileged" needs an explicit total order because the source enum is not a clean ladder — Task 2B.4 defines it, it is not assumed here.
- **Coverage catalog is REQUIRED emission** (shipped, see Status above), not optional prose: the generator must emit each applicable edge-case type or explicitly emit a `deferred` with a reason (no silent gaps).
- **Criteria budget** (new, folds in the combinatorial-explosion finding): 8 edge-case rows × up to ~8 discovered personas × N surfaces can produce hundreds of criteria under ADR-0003's sequential-by-default execution. Task 2A.1 adds an explicit budget guard — see its Interfaces.

---

## Workstream 2A — Systematic edge-case coverage (recall lever, lands first)

**Why first:** the re-measurement showed the gate buys precision; recall gains come from *generating the criteria in the first place*. F3/J1/J3/J4/F4 were missed because no criterion tested them. This is testable against the current fixture (a re-measurement should show recall rise).

### Task 2A.1 — Criteria budget guard in generating-qa-checklist

**Scope note:** the 8-row edge-case catalog itself already shipped (see Status above) — this task is scoped to the one gap left in it: an explicit cap so the catalog doesn't combinatorially explode once 2B's persona multiplication lands on top of it.

**Files:** Modify `skills/generating-qa-checklist/SKILL.md` (Step 3 area) + `templates/checklist.md`.

**Interfaces:**
- Produces: after walking the catalog for all write-bearing surfaces (and, once 2B lands, multiplying `role-sensitive` rows per persona), the generator computes a **total emitted-criteria count**. If that count exceeds a **BUDGET** — default **60**, overridable via `.qa/config.json`'s `criteriaBudget` — the generator MUST STOP before finalizing the checklist and present a numbered confirm-or-prioritize prompt rather than silently emitting all of them: list the count, the breakdown by edge-case type × surface, and a **recommended priority order** (write-bearing + role-sensitive + previously-missed-bug-class rows first; read-only/cosmetic edge rows last), then ask the human to confirm the full set, confirm the recommended trimmed subset, or hand-pick.
- This is a **simple threshold-and-confirm** implementation now (a single question, not a multi-round frontier) so 2A ships standalone without depending on 2B.0. Once Task 2B.0's frontier-rounds helper lands, this prompt MAY be upgraded to use it (same recommended-default-with-citation shape) — note that as a follow-on, do not block 2A on it.

- [ ] **Step 1: Confirm there is no existing cap** — `grep -n "budget\|criterion count\|combinat" skills/generating-qa-checklist/SKILL.md` → expect no hits (confirms this is new scope, not a duplicate).
- [ ] **Step 2: Add the budget guard to Step 3 of `generating-qa-checklist/SKILL.md`** — a REQUIRED sub-step: after the catalog walk, count emitted criteria; if `> criteriaBudget` (default 60, read from `.qa/config.json` if present), stop and present the prioritized confirm prompt described above instead of finalizing.
- [ ] **Step 3: Add one mini-eval** showing a would-be-120-criteria checklist (8 edge rows × 3 surfaces × 5 personas) getting capped: the generator proposes a 45-criterion prioritized subset and asks for confirmation before proceeding. Keep the skill's ≥3-mini-eval minimum intact (this is additive).
- [ ] **Step 4: Add a `Criteria Budget` note to `templates/checklist.md`** — a header field recording the computed count, the budget, and whether the human confirmed the full set or a trimmed one.
- [ ] **Step 5: Validate** — skill body still `<500` lines (`wc -l skills/generating-qa-checklist/SKILL.md`); frontmatter unchanged (`name`+`description` only); `templates/checklist.md` still parses as valid Markdown (visual check, no linter in-repo).
- [ ] **Step 6: Commit** — `docs(checklist): add criteria-budget guard so edge-case x persona coverage can't silently explode`.

### Task 2A.2 — Re-measure coverage against the fixture

**Files:** none (measurement only — this task produces a number, not code).

**Interfaces:** Produces a fresh MEASURED score via the existing harness: `node tools/accuracy-harness/scorer/convert-buglog.js <run>/bug-log.json > tools/accuracy-harness/findings/measured-phase2a.json && node tools/accuracy-harness/scorer/score.js tools/accuracy-harness/findings/measured-phase2a.json --gate`.

- [ ] **Step 1: Serve the fixture and run the gated agent** exactly as Phase 0/1's baseline runs did (`bash tools/accuracy-harness/run-baseline.sh`), now with the shipped catalog + Task 2A.1's budget guard in effect.
- [ ] **Step 2: Convert + score** per the command above.
- [ ] **Step 3: Acceptance is the gate exit code, not a vague "recall rises"** — the task is DONE when `node scorer/score.js <run> --gate` exits 0 for functional/ux-objective/overall recall thresholds **and** precision stays ≥ its current 100%. If it exits non-zero, the task is not done — diagnose which catalog row is still not catching its target bug (F3/J1/J3/J4 at minimum) before moving to 2B.
- [ ] **Step 4: Record the number** in a `## Phase 2A result (MEASURED)` note appended to this plan (mirrors the Phase 0/1 result-block convention) — actual recall/precision, not an estimate.
- [ ] **Step 5: Commit** — `test(harness): measured Phase 2A coverage recall vs 33%/38% baseline`.

---

## Workstream 2B — Role/persona discovery

### Task 2B.0 — Reimplement `grilling`'s frontier-in-rounds pattern as a QA-native HITL helper (NEW — blocker, closes the false-claim finding)

**Why this task exists:** an earlier draft of this plan incorrectly claimed the grilling-round machinery already existed in the runtime HITL (Decision 11). That claim was false and has been retracted — `grep -rn "grilling\|frontier" skills/ agents/` returns nothing; it has never been implemented. Every downstream task that says "grilling-style round" (2B.2's roles→credentials→scope frontier, Phase 5's per-run subset question) depends on this pattern actually existing. Per ADR-0001 (reimplement patterns, never fork/vendor/depend-on another skill), this is a from-scratch reimplementation of `grilling`'s reusable *shape* — numbered items with a recommended default, human confirm/edit, recompute the frontier for dependent decisions — not a copy of its file.

**Files:** Create `skills/bootstrapping-qa-config/references/hitl-frontier-rounds.md` (the reusable pattern doc + worked algorithm, consumed by Task 2B.2 and, later, Phase 5's per-run subset question); extend `skills/bootstrapping-qa-config/SKILL.md` with a one-line pointer to it.

**Interfaces:**
- Produces: a documented **round schema** — `{ roundName, items: [{ id, sourceCitation, recommendedDefault }], onConfirm, onEdit }` — and a **frontier-recompute rule**: editing any item in round *N* invalidates and regenerates every round *N+1..* that depends on it (roles → credentials → scope is a dependency TREE, not a flat list — an edited role changes which credential round entry applies to it, which changes which scope-round entries are even possible). Facts (roles, permission sources, FK chains) are always auto-discovered by static analysis BEFORE the round is rendered — the human is never asked "what roles does your app have," only asked to confirm/edit a numbered, sourced proposal.
- This is a **prompt-pattern + render/recompute algorithm**, not a new interactive tool — it is consumed by whichever skill needs a multi-round HITL confirm (2B.2 today) via `AskUserQuestion`-shaped rounds, one round per host prompt.

- [ ] **Step 1: Write the eval scenario FIRST (drives the design)** — before writing the pattern doc, write down a concrete 3-round worked example against `innovation`'s discovered roles (e.g., `super-admin`, `admin`, `evaluator`, `jury`, `user` from a Spatie-style enum) with a deliberately-edited Round 1 item (the human demotes a proposed `admin`→`evaluator` mapping) and the EXPECTED Round 2 (credentials) and Round 3 (scope) outputs after that edit recomputes. Save this as the eval fixture text at the bottom of the new reference file (this is the doc-task equivalent of a failing test).
- [ ] **Step 2: Confirm the eval currently has no implementation to satisfy it** — `test -f skills/bootstrapping-qa-config/references/hitl-frontier-rounds.md` → expect missing (nothing to recompute yet).
- [ ] **Step 3: Write `references/hitl-frontier-rounds.md`** — the round schema, the frontier-recompute rule, and three worked mini-evals: (a) roles→credentials edit-cascade (Step 1's scenario), (b) credentials→scope edit-cascade (editing a credential's seeded-user changes which scope entries are testable), (c) an all-defaults-accepted pass-through (no edits — frontier is unchanged, all three rounds render once, no re-prompting).
- [ ] **Step 4: Validate against the eval** — walk Step 1's scenario by hand against the written algorithm; confirm Round 2/3 change exactly as predicted when Round 1 is edited, and that an unrelated Round 1 item's credential/scope entries are untouched (frontier recompute is scoped to the dependency subtree, not a full re-ask).
- [ ] **Step 5: Add the pointer** — one line in `skills/bootstrapping-qa-config/SKILL.md` noting that persona/role confirmation (Task 2B.2) uses this reference's round/frontier machinery, NOT the skill's own flat `AskUserQuestion` batch (that batch stays correct for its own 4 independent questions — see the master plan's Decision 11 note).
- [ ] **Step 6: Validate file limits** — this is a `references/` file (not a `SKILL.md`), so the <500-line body cap doesn't strictly apply, but keep it tight; confirm `skills/bootstrapping-qa-config/SKILL.md` itself is still <500 lines after Step 5's addition.
- [ ] **Step 7: Commit** — `feat(hitl): reimplement grilling's frontier-in-rounds pattern as a QA-native reference (ADR-0001)`.

### Task 2B.1 — `discovering-user-roles` skill

**Files:** Create `skills/discovering-user-roles/SKILL.md` (+ scripts/templates as needed).

**Interfaces:** Two-plane static analysis: (1) **global roles** from an RBAC/permission source (e.g. a role enum, a permission-seeder/config, policy/middleware `role:` guards); (2) **contextual roles** (team-member role columns, pivot roles). Emits a proposed `roles[]` with, per role, its source citation + how to authenticate (seeded credential pattern / storageState). Degrades to `signal: weak` (anonymous + any discoverable role) rather than failing. Populates the ROLE half of persona=role×lens only (see Settled defaults) — it does not touch review lenses.

- [ ] **Step 1: Write the skill body** — two-plane discovery steps (global RBAC scan; contextual/pivot-role scan), the `roles[]` output shape (`{ id, source, plane: "global"|"contextual", authMethod }`), and the `signal: strong|weak` degrade path.
- [ ] **Step 2: Write ≥3 mini-evals** — (a) a Spatie-style Laravel enum case (e.g. `innovation`'s `UserType`: `super-admin/admin/evaluator/user/jury`) discovered from the global plane; (b) a contextual case (a `team_members.role` pivot column) discovered from the contextual plane; (c) a signal-weak single-user app that degrades to `anonymous` only, with a `deferred` reason recorded rather than a failure.
- [ ] **Step 3: Validate** — frontmatter is `name`+`description` only, `name` == dir name (`discovering-user-roles`), lowercase-hyphen gerund, no "claude" in the name; body `<500` lines (`wc -l`).
- [ ] **Step 4: Commit** — `feat(skills): add discovering-user-roles (two-plane RBAC + contextual role discovery)`.

### Task 2B.2 — HITL persona confirmation as 3 explicit rounds + config generation + authz-matrix shape

**Files:** Modify `skills/bootstrapping-qa-config/` (new step, consuming Task 2B.0's reference) so discovery → **3 explicit grilling-style rounds** → deterministically WRITE `.qa/config.json` `personas[]` + an authz matrix (regenerate, not reconcile).

**Interfaces:**
- The 3 rounds are Decision-11's roles→credentials→scope frontier, made concrete (not left as a one-line mention):
  1. **Round 1 — Roles.** Numbered list of `discovering-user-roles`' proposed `roles[]`, each with its source citation and a recommended default of "include, test as this role." Human confirms/edits/removes.
  2. **Round 2 — Credentials.** For each role confirmed in Round 1, a recommended default authentication method (seeded-credential form login if a seed/fixture user exists for that role, else `storageState` capture) with its source citation. Frontier recompute: removing a role in Round 1 removes its Round 2 entry entirely, never orphaned.
  3. **Round 3 — Scope.** For each role, its recommended `role-sensitive` scope (which surfaces/entities that role can own vs. only read vs. never see), derived from the FK-ownership chains the codebase scan found (see Task 2B.4's chain-following requirement — 2B.2 consumes whatever chain data 2B.1/2B.4's static analysis surfaces). Frontier recompute: editing a Round 2 credential (e.g., swapping which seeded user a role uses) recomputes Round 3's entries that depended on that specific account's data.
  - **NB (repeated from the master plan, made explicit here so it isn't missed again):** `bootstrapping-qa-config`'s existing flat `AskUserQuestion` batch (4 independent baseUrl/env/auth/writes questions) is **NOT** the reference implementation for this — those 4 questions have no dependency edges between them, so one flat round is correct there. Roles→credentials→scope IS a dependency tree and MUST use Task 2B.0's round/frontier machinery.
- **Authz-matrix artifact shape (concrete deliverable of this task, not deferred to 2B.4):** written to `.qa/config.json` (or a sibling `.qa/authz-matrix.json`) as an array of `{ entity, owningChain: [fk1, fk2, ...], roleScope: { <roleId>: "owns"|"read-scoped"|"none" } }` rows — e.g. for `innovation`: `{ entity: "submission", owningChain: ["team_id", "hackathon_id"], roleScope: { "team-member": "owns", "evaluator": "read-scoped", "jury": "read-scoped", "admin": "owns", "user": "none" } }`. This is the artifact Task 2B.4's cross-role negative tests read to know which entity/role pairs must show absence.

- [ ] **Step 1: Write the 3-round spec into `skills/bootstrapping-qa-config/SKILL.md`** (a new numbered step, e.g. "Step 3 — Persona confirmation (roles→credentials→scope frontier)"), citing `references/hitl-frontier-rounds.md` for the render/recompute mechanics rather than re-describing them inline.
- [ ] **Step 2: Define the authz-matrix JSON shape** (above) in the skill body or a `templates/authz-matrix.json.example`, with the `innovation` row as the worked example.
- [ ] **Step 3: Wire deterministic config writing** — after all 3 rounds confirm, the skill's existing `init-config.sh`-style deterministic writer (never hand-authored JSON, per the skill's existing convention) gains a `personas[]` + `authzMatrix` block populated from the confirmed rounds.
- [ ] **Step 4: Add/extend a mini-eval** showing the full 3-round flow against `innovation`: Round 1 proposes 5 roles from the `UserType` enum + a `team_members` pivot role; the human demotes one; Round 2/3 recompute per Task 2B.0's algorithm; the written `.qa/config.json` reflects the edited set.
- [ ] **Step 5: Validate** — skill body still `<500` lines after the addition; `.qa/config.json.example` (or the new `authz-matrix.json.example`) is valid JSON (`python3 -c "import json;json.load(open(...))"`).
- [ ] **Step 6: Commit** — `feat(bootstrap): persona confirmation as roles→credentials→scope frontier rounds; authz-matrix generation`.

### Task 2B.3 — Persona-keyed checkpoint/evidence (NEW — blocker, must land before or with 2B.4)

**Why:** today `checkpoint.sh` keys every record purely by `criterion_id` (confirmed: `grep -n "criterion_id" skills/checkpointing-qa-memory/scripts/checkpoint.sh` shows it as the sole lookup key in `cmd_upsert`/`--resume`/`--list`). Once 2B.4 makes role-sensitive criteria run once **per persona**, a criterion checkpointed `pass` while QA-ing as persona A would read back as "already done" on resume when the orchestrator is actually about to run the SAME criterion ID as persona B — silently skipping real per-persona work. The key must become `(criterion_id, persona_id)` before role multiplication ships.

**Files:** Modify `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (both `jq` and `python3` code paths); extend `tests/checkpoint/run.sh`; the evidence dir layout moves from `evidence/<crit>/` to `evidence/<crit>/<persona>/` when a persona is supplied (back-compat: no `--persona` flag = today's layout, unchanged).

**Interfaces:** `checkpoint.sh <run> <crit> <verdict> [--persona <persona-id>] ...` — when `--persona` is given, the upsert/lookup key is the pair `(criterion_id, persona_id)`, not `criterion_id` alone; `--resume`/`--list` surface `persona_id` per row (blank/`shared` when omitted, meaning the criterion is not role-sensitive and ran once for the most-privileged role per Task 2B.4's ordering). `record-evidence.sh` gains the matching `--persona` passthrough so `evidence/<crit>/<persona>/<artifact>.json` doesn't collide across personas.

**Acceptance criterion:** resuming a run after checkpointing `(C7, admin)` as `pass` must NOT report `(C7, evaluator)` as done — the orchestrator must still execute C7 for `evaluator`.

- [ ] **Step 1: Write failing tests in `tests/checkpoint/run.sh`** — `checkpoint.sh R C7 pass --persona admin` then `checkpoint.sh R C7 pass --persona evaluator` must produce TWO distinct records (not a replace); `--resume` for `R` must list both `(C7, admin)` and `(C7, evaluator)` as separate cursor rows; a plain `checkpoint.sh R C9 pass` (no `--persona`) must behave exactly as before (regression guard — reuse Task 1.1's characterization assertions unchanged for the no-persona path).
- [ ] **Step 2: Run to verify it fails** — `bash tests/checkpoint/run.sh` → the two-persona case currently collapses to one record (today's `criterion_id`-only key). Record the failure.
- [ ] **Step 3: Implement the compound key** in both the `jq` and `python3` code paths of `cmd_upsert`/`--resume`/`--list`: the lookup/replace predicate becomes `.criterion_id == $cid and (.persona_id // null) == ($pid // null)`; add `persona_id` to the written record (defaulting to `null`, rendered as `shared` in human-readable output) and to `record-evidence.sh`'s evidence path when `--persona` is passed.
- [ ] **Step 4: Run to verify pass**, AND re-run Task 1.1/1.2/1.3/1.4's original characterization + gate tests to confirm the no-persona path is byte-for-byte unchanged (this is the regression guard the acceptance criterion above depends on).
- [ ] **Step 5: Update `agents/qa-e2e-pilot.md` phase-3/phase-5 checkpoint calls** to pass `--persona <persona-id>` for every role-sensitive criterion (shared criteria omit it, per Task 2B.4's most-privileged-once rule).
- [ ] **Step 6: Commit** — `feat(checkpoint): key evidence/checkpoint records by (criterion_id, persona_id) so per-persona resume can't be silently skipped`.

### Task 2B.4 — Role-sensitive tagging + relational cross-role negative tests (was 2B.3; renumbered — depends on 2B.3's compound key)

**Files:** Modify `skills/generating-qa-checklist/` (Step 6's cross-tenant heuristic) + `agents/qa-e2e-pilot.md` phase-3.

**Interfaces:**
- Criteria gain a `role-sensitive` tag; only those + authz negative tests multiply per persona (using Task 2B.3's compound key so resume is safe). Shared criteria run once as the **most-privileged role**.
- **Generalize the cross-tenant heuristic from a single hardcoded `tenant_id` column to arbitrary relational FK-ownership CHAINS.** Confirmed today (`skills/generating-qa-checklist/SKILL.md` Step 6, "Cross-tenant isolation") the heuristic is written as a single "re-run authenticated as a different tenant, assert absence" step assuming one `tenant_id`-shaped filter column. `innovation` has NO `tenant_id` column at all — ownership is a multi-hop chain (`submission` → `team_id` → `team` → `hackathon_id` → `hackathon`). The heuristic must walk the SAME static-analysis chain-following Task 2B.1 uses for contextual-role discovery and Task 2B.2's authz-matrix `owningChain` field, and assert absence at whichever hop the persona under test does not own — not assume a single flat column.
- **Cross-role negative test** = "persona B must NOT see persona A's owned entity, per the innovation authz matrix's `owningChain`" → a `pass` requires a `probe` bake showing absence at the correct hop. Tag `cross-tenant: true` is kept as an alias for the flat-column case (e.g. a genuinely multi-tenant SaaS); the new general case is tagged `cross-role-fk-chain: true` and carries the specific chain being asserted.
- **Explicit role-privilege ORDERING (required — Decision 6 depends on it and the source enum is not a clean ladder):** for `innovation`'s `UserType` (`super-admin/admin/evaluator/user/jury`), define the total order used ONLY to pick which single role runs a *shared* (non-role-sensitive) criterion: **`super-admin > admin > evaluator > jury > user`**. State explicitly in the skill body that this ordering is a **selection convenience, not a claim of a real permission lattice** — `evaluator` and `jury` are lateral, scope-limited roles (each sees only their assigned submissions), not strict supersets of `user`; the ordering exists purely so "run once as the most-privileged role" has a deterministic answer, and it does NOT exempt `evaluator`-vs-`jury` isolation from being tested as an explicit `cross-role-fk-chain` pair regardless of this ordering. Any project without a discovered ordering hint (no obvious "admin" naming) defaults to declaring ties and requires a Round-1 (Task 2B.2) confirm of the order.

- [ ] **Step 1: Rewrite Step 6's cross-tenant heuristic** in `skills/generating-qa-checklist/SKILL.md` to walk an `owningChain` (array of FK hops) instead of assuming a single `tenant_id` column; keep the flat-column case as the chain-length-1 special case so existing single-tenant projects still work unchanged.
- [ ] **Step 2: Add the role-privilege ordering** (above) to the same section, with the explicit "selection convenience, not a lattice" caveat and the standing requirement that lateral roles still get pairwise `cross-role-fk-chain` tests.
- [ ] **Step 3: Add a mini-eval** using `innovation`'s real chain (`submission → team_id → team → hackathon_id → hackathon`): a jury member's cross-role probe must assert absence of another team's submission at the `team_id` hop, not fail-open because there's no `tenant_id` column to check.
- [ ] **Step 4: Wire `agents/qa-e2e-pilot.md` phase-3`** to pass the resolved `persona_id` (Task 2B.3) to `checkpoint.sh`/`record-evidence.sh` for every `role-sensitive`/`cross-role-fk-chain` criterion, and to run shared criteria once using Step 2's ordering.
- [ ] **Step 5: Validate** — skill body `<500` lines; existing ≥3 mini-evals preserved, new one added; `bash tests/checkpoint/run.sh` still green (confirms 2B.3's compound key is actually being exercised, not bypassed).
- [ ] **Step 6: Commit** — `feat(qa): generalize cross-tenant heuristic to FK-ownership chains; define most-privileged ordering; wire persona-keyed checkpointing`.

### Task 2B.5 — Measured authz gate (NEW — a number, not a vibe check)

**Why:** the master plan requires every phase to leave the harness non-regressed, but 2B's role/authz recall has no measured acceptance today — "the cross-role negative test correctly fails when isolation is broken" (the original plan's only 2B acceptance line) is qualitative. This task defines a minimal, repeatable, MEASURED authz check against the real multi-role project (`innovation`), since the synthetic fixture is single-user (Phase 0's documented scope boundary) and cannot host this measurement.

**Files:** none created ahead of time in this repo beyond a small innovation-specific seed file — see Step 4 (exact path decided at execution, since it depends on reading `innovation`'s actual endpoints).

**Interfaces:** a MEASURED pass/fail (not estimated) for: (a) a deliberately seeded, minimal, revertible authz defect gets caught by the new cross-role-fk-chain criterion, and (b) the SAME criterion stays silent (no false positive) once the defect is reverted — i.e., a tiny recall+precision pair scoped to authz, using the harness's existing attribution machinery (`tools/accuracy-harness/scorer/score.js`/`attribute.js`) rather than a fresh ad hoc script.

- [ ] **Step 1: Identify ONE minimal, revertible authz defect to seed in `innovation`** at execution time — e.g., temporarily removing the `team_id`/`hackathon_id` scope filter on a single list/detail endpoint the authz-matrix (Task 2B.2) already documents as `role-scope: read-scoped` for the persona under test. Do this on a disposable local branch/checkout, never merged, never pushed — this is a measurement fixture, not a real change.
- [ ] **Step 2: Run the gated agent as two personas against the seeded-defective endpoint** — expect the new `cross-role-fk-chain` criterion (Task 2B.4) for that entity to record `fail` with `suspectedLayer` pointing at the layer holding the missing filter (typically `route` or `service`), citing the leaked entity by ID in its evidence.
- [ ] **Step 3: Revert the seeded defect; re-run the same criterion** — expect `pass` with `probe` evidence showing absence at the correct FK hop (Task 2B.4). This is the precision half — the criterion must NOT still flag the clean state.
- [ ] **Step 4: Add a one-seed scorer input** — e.g. `tools/accuracy-harness/seeds-innovation-authz.json` with a single `polarity:"positive"` seed `AUTHZ1` describing the defect from Step 1, and reuse `score.js` against a hand-converted findings doc from the two runs (defective + reverted) so the result is a numeric recall(1/1 or 0/1) + precision pair, not prose.
- [ ] **Step 5: Record the measured result** as a `## Phase 2B authz gate result (MEASURED)` note appended to this plan: which endpoint, which criterion, caught: yes/no, false-positive-on-clean: yes/no.
- [ ] **Step 6: Commit** — `test(harness): measured authz recall/precision on a seeded innovation defect (cross-role-fk-chain)`.

### Task 2B.6 — ADR-0011 (roles/personas) + ADR-0012 (per-role scope) (was 2B.4)

**Files:** Create `docs/adr/0011-role-persona-discovery-and-hitl-rounds.md`, `docs/adr/0012-per-role-scope-and-authz-matrix.md`.

**Interfaces:** Record the two-plane discovery, persona=role×lens (role axis only in Phase 2), grilling-round HITL (citing Task 2B.0's reimplementation, not an external dependency), regenerate-not-reconcile (0011); per-role cost containment + the explicit most-privileged ordering + cross-role-fk-chain negative tests (0012).

- **Normalize the ADR status convention, made concrete (not a vague aspiration):** every existing ADR (0001–0010) is `Accepted` because its work already shipped (confirmed: `docs/adr/0005*.md` and `0010*.md` both read `## Status\n\nAccepted (<date>).`). ADR-0011/0012 describe work this very plan has NOT yet executed at the time the ADR file is created — so their `## Status` MUST read **`Proposed (2026-08-31) — implemented by docs/plans/2026-08-31-phase2-coverage-roles.md Tasks 2B.0–2B.5`**, and MUST be hand-flipped to `Accepted (<merge-date>)` in the SAME commit that lands Task 2B.4/2B.5 (the last tasks that make their content true). Repoint provenance (linking the ADR to this plan file) is already the pattern `0010` uses — reuse it verbatim, just with `Proposed` instead of `Accepted` until the work lands.

- [ ] **Step 1: Write ADR-0011** — two-plane discovery, persona=role×lens (role axis only this phase), grilling-round HITL via Task 2B.0's reimplementation, regenerate-not-reconcile; `## Status` = `Proposed (2026-08-31)` per the convention above.
- [ ] **Step 2: Write ADR-0012** — per-role cost containment (shared criteria run once as most-privileged, Task 2B.4's explicit ordering), cross-role-fk-chain negative tests generalizing the old flat-tenant heuristic, the authz-matrix artifact shape (Task 2B.2); `## Status` = `Proposed (2026-08-31)`.
- [ ] **Step 3: Validate** — filenames/numbering don't collide with 0001–0010; both files open with `# ADR-00NN — <title>` and a `## Status` section matching every other ADR's format (`grep -n "^## Status" docs/adr/0011*.md docs/adr/0012*.md`).
- [ ] **Step 4: Commit** — `docs(adr): 0011 role/persona discovery + HITL rounds, 0012 per-role scope + authz matrix (Proposed)`.
- [ ] **Step 5 (deferred to whichever commit lands 2B.4+2B.5):** flip both ADRs' `## Status` to `Accepted (<date>)` once their content is true on disk. Note it here so it isn't forgotten; do not do it in this task's commit.

---

## Sequencing
2A.1 → 2A.2 (re-measure, land 2A as its own increment) → 2B.0 → 2B.1 → 2B.2 → 2B.3 → 2B.4 → 2B.5 (measured authz gate) → 2B.6 (land 2B). Each landed via PR→merge. Re-measure after 2A (fixture) and note that role/authz recall is measured against `innovation` (a real multi-role app, Task 2B.5), not the single-user fixture.

## Acceptance
- 2A: `node tools/accuracy-harness/scorer/score.js <run> --gate` exits 0 on the gated fixture run with the new catalog + budget guard in effect; precision stays ≥ current 100%; no silent coverage gaps (deferred criteria carry reasons).
- 2B: `discovering-user-roles` proposes the correct roles on `innovation` (global spatie-style enum + team roles); the 3-round HITL (2B.0/2B.2) correctly recomputes dependent rounds on an edit; config generation is deterministic; checkpoint/evidence resume is safe per-persona (2B.3's acceptance criterion); a cross-role-fk-chain negative test correctly fails when a seeded isolation defect is present and stays silent once it's reverted (2B.5's MEASURED result, not a qualitative claim).

## Self-review (against the audit findings folded in)
- **Blocker — false grilling-built claim:** removed from the autonomous-mode note; replaced with the grep-verified fact plus Task 2B.0 to actually build the pattern.
- **Blocker — persona-keyed checkpoint:** Task 2B.3, sequenced before 2B.4, with an explicit resume-safety acceptance criterion and a regression guard against Phase 1's existing characterization tests.
- **Major — combinatorial cap:** Task 2A.1's budget guard (default 60, configurable, prioritized confirm prompt).
- **Major — relational cross-role:** Task 2B.4 Step 1 generalizes the single-`tenant_id` heuristic to FK-ownership chains; Task 2B.2 defines the authz-matrix shape carrying `owningChain`.
- **Major — HITL as 3 explicit rounds:** Task 2B.2 spells out roles→credentials→scope as three named rounds with recommended defaults and frontier recompute, explicitly disclaiming `bootstrapping-qa-config`'s flat form as the reference.
- **Major — measured authz gate:** Task 2B.5 (seeded/reverted defect + scorer path) and Task 2B.4's explicit `super-admin > admin > evaluator > jury > user` ordering (with the lateral-role caveat).
- **Minor — persona=role×lens boundary:** stated in Settled defaults (Phase 2 = role axis only, Phase 5 extends additively). 2A acceptance reworded to the gate command. ADR status convention made concrete in Task 2B.6.
- **Reflected shipped work:** Status-as-of section credits the 8-row catalog and the F1/F4 fixture fixes so this rewrite doesn't re-scope work that's already done.
