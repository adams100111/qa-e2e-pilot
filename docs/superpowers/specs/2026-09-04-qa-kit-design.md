# qa-kit — spec-kit-style QA process shell — design

**Status:** design (awaiting user review) · **Date:** 2026-09-04 · Supersedes the capture note `docs/specs/2026-09-02-qa-kit-plugin-idea.md` (idea → design). Brainstormed as a discussion 2026-09-04.

---

## 1. What qa-kit is (one paragraph)

`qa-kit` is a **phase-gated, artifact-producing process shell for QA**, added to *this* repo, that borrows spec-kit's *patterns* (a sequence of steps, each producing a human-reviewable Markdown artifact, each required to stay *aligned* with the steps before it — delivered as per-harness **commands** + per-harness **hooks**) but defines its own **QA-specific steps**, each powered by qa-e2e-pilot's existing skills. The steps hold **state**: the **constitution** is the living, project-level home for roles/personas + QA invariants + a machine-checkable enforcement block; each **spec** pins an immutable snapshot of that state (+ per-spec customization) for one reproducible run. Where spec-kit's constitution/spec/plan are enforced only by prose + file-existence checks, qa-kit's compile into **runtime enforcement** — the `block-hook`/`qa-verify` engine qa-e2e-pilot already ships — so the constitution/spec/plan actually *govern* the run, tiered honestly per harness.

## 2. Decisions settled in the brainstorm (binding)

1. **Model A — thin process shell, same repo.** qa-kit is new commands (+ hook config) in *this* repo that orchestrate the **existing skills unchanged**; `/qa-run` becomes the "Implement" step. No fork, no cross-repo dependency, no logic duplication. Inherits ADR-0017 portability, ADR-0020 durable run state, and the H1/H2/H4 honesty stack for free.
2. **Borrow spec-kit's patterns, not its steps.** qa-kit does **not** reuse spec-kit's `constitution→specify→plan→tasks→implement` step names/bodies. It reuses the *pattern* (phased, aligned, artifact-per-step, per-harness command+hook installers) and defines QA-specific steps.
3. **Delivered as per-harness commands + per-harness hooks.** Steps ship as commands in each harness's idiom (the existing `core/` → `dist/<h>/` build). Enforcement rides `PreToolUse`/`PostToolUse`-style hooks per harness.
4. **Enforcement of the constitution/spec/plan is `qa-verify` POST-HOC on every harness (corrected).** `block-hook.sh` sees only the tool-call payload and runs `mutates()` — it has **no criterion/role/plan context** at pre-tool time, so criterion-level rules (only-planned-criteria, allowed-roles, declared-oracle) **cannot be live-blocked**; they are enforced post-hoc by `qa-verify`, which has the journal/criterion context. **Live-blocking is limited to `block-hook`'s existing tool-*shape* absolutes** (mutating `evaluate`, `run_code_unsafe`) — universal, no per-run config. A per-run *live* constitution-block on Claude is a **later enhancement** (requires modifying `block-hook`), not v1. `qa-verify` is the universal authority; the harness divergence (H4) affects only the optional *live* tier, not this post-hoc spine.
5. **Constitution = the living, stateful home** for roles/personas + QA invariants (prose) + the machine-checkable enforcement block. Roles are discovered once and **maintained** thereafter via **regenerate → diff → confirm** (reuses ADR-0011 frontier-round HITL + ADR-0016 seed store). It compiles into the `block-hook`/`qa-verify` config.
6. **Each spec pins an immutable role snapshot.** Constitution roles are **copied** into the spec (`spec-roles.json`), editable while *authoring* the spec, **frozen at `plan_frozen`** (ADR-0020) for the run, plus per-spec overrides/additions. A live reference would break the durable-resume + reproducibility guarantee — rejected. The constitution mutates; each run is a reproducible snapshot of it.
7. **Alignment enforcement is woven into every step**, not one end-gate: each step must be consistent with the constitution + spec + plan (e.g. a scenario cannot use a role absent from the spec's frozen set; a run cannot customize away a constitution invariant). This is spec-kit's `analyze` idea, per-step.
8. **QA-specific optional gates** (`/qa-sanitize`, `/qa-assure`, `/qa-perf`, `/qa-security`, `/qa-uiux`) are opt-in plug-ins, not required spine steps. **They read the completed run's evidence (`.qa/runs/<id>/`) and emit their own gate artifact + pass/advisory — they do NOT re-drive.** Anything needing *driving* (a perf timing, a security probe) becomes a tagged **criterion** in scenarios, so the run stays the single driving surface. *(Grill Q8.)*
9. **qa-kit is a SECOND plugin in this repo** — its own `.claude-plugin/plugin.json` + marketplace entry, reusing `core/`/`skills/`/`scripts/` via the build. qa-e2e-pilot stays installable standalone; qa-kit ships as its own installable product. *(Grill Q4.)*
10. **The quick path survives.** `/qa-run` stays first-class **standalone** (no constitution required — self-discovers roles as today). The phased flow is opt-in and additive. `/qa-spec` with no constitution offers to bootstrap one **or** proceed with per-spec-only roles — never a tax on the one-shot path. *(Grill Q5.)*
11. **A dedicated `/qa-analyze` consistency+coverage gate** sits before `/qa-run` (per-step alignment catches *ordering* violations; `/qa-analyze` catches *coverage gaps* — a spec item with no scenario, an unaddressed risk — before the expensive run). *(Grill Q3.)*
12. **Enforcement compiles into the gate's EXISTING inputs, not a new rules file (corrected).** `qa-verify` reads `checklist.json` (required-kinds, criterion↔role, declared-oracle) + `.qa/config.json` (`personas[].expectedSubject`) — it does NOT read any `constitution.rules.json`. So qa-kit's phases **populate those existing shapes**; `qa-verify` stays genuinely untouched. *(Grill Q2.)*

## 3. The steps (qa-kit's own — powered by existing skills)

| Command | Artifact(s) | State | Powered by (existing) | Compiles into enforcement |
|---|---|---|---|---|
| `/qa-constitution` | `.qa/constitution.md`, `.qa/roles.json` | **stateful across runs** — roles/personas + invariants; updated via regenerate→diff→confirm | `discovering-user-roles`, `confirming-discovered-roles`, ADR-0016 seed store, `CONTEXT.md` vocab | allowed-roles / required-evidence-kinds → written into `checklist.json`+`.qa/config.json` → `qa-verify` post-hoc (all) |
| `/qa-spec` | `.qa/specs/<target>/qa-spec.md`, `spec-roles.json` | per-run snapshot — selects scenarios + roles (copied from constitution, stamped with constitution version) + per-run customization/oracles | `detecting-stack-profile`, oracle definition, `ingesting-spec-kit` (as an input path) | declared-oracle-per-criterion → `checklist.json` → `qa-verify` checks the recorded verdict used it |
| `/qa-plan` | `.qa/specs/<target>/run-plan.md` | per-run | ADR-0011/0012 persona/criteria-budget, driver pool config | run budget/parallelism bounds |
| `/qa-scenarios` | `.qa/specs/<target>/scenarios.md` / `checklist.json` | per-run | `generating-qa-checklist`, `fanning-out-criteria` | only-planned-criteria-may-act → `checklist.json` → `qa-verify` post-hoc (all) |
| `/qa-analyze` | `.qa/specs/<target>/analysis.md` | per-run (read-only gate) | `analyzing-feature-ui` surface map, `ingesting-spec-kit` traceability | consistency+coverage gaps flagged before the run (LLM-reasoned, spec-kit `analyze` pattern) |
| `/qa-run` (Implement) | `.qa/runs/<run-id>/` + `report.md`/`.html` | per-run (durable journal, ADR-0020) | the whole verification pipeline (driving-browser-qa, verifying-backend-persistence, verifying-computed-logic, walking-multistep-flows, probing-apis-through-browser, checkpointing-qa-memory, writing-qa-reports) | `qa-verify` post-hoc enforces the compiled `checklist.json`/`config.json` on all harnesses |
| optional: `/qa-sanitize` `/qa-assure` `/qa-perf` `/qa-security` `/qa-uiux` | per-gate artifact | per-run | probing rules; ADR-0018 assurance tiers; UX engine (ADR-0019); etc. | opt-in gates layered on Implement |

Every step also runs a **spec-kit-style prerequisite + alignment check** before proceeding (see §5).

## 4. The state model (the heart)

- **Constitution owns the durable role state.** `roles.json` (+ ADR-0016 cross-project seed store) is populated by discovery once, then *maintained*. Re-running `/qa-constitution` after the app changes does **regenerate → diff → confirm**: re-discover, diff against stored roles, present the delta (added/removed/scope-changed), the human confirms the merge, per-role customizations on unchanged roles are preserved. Never a silent overwrite (rejected option C), never additive-drift (rejected option B).
- **Spec pins an immutable snapshot.** `/qa-spec` **copies** the constitution's roles into `spec-roles.json` and lets the author override/add/subset for this run. While authoring, roles are soft (can re-pull from the constitution, edit). At run start, `plan_frozen` (ADR-0020) freezes them into the run's journal. **Mid-run: no changes** — that is the reproducibility guarantee. A later constitution change is picked up by the *next* `/qa-spec`, never the running one.
- **Mental model:** the *constitution* is the mutable living state; each *spec/run* is a reproducible snapshot of it. State lives in one place and evolves there; runs never mutate. This is the same freeze-and-replay principle ADR-0020's `plan_frozen`/`/qa-resume` already depend on.

## 5. The enforcement model (commands + per-harness hooks)

Three layers, reusing what already exists:

1. **Phase ordering — real file-existence checks (cheap, deterministic).** Like spec-kit's `check-prerequisites.sh` (which hard-`exit 1`s if a prior artifact is missing): `/qa-plan` requires `qa-spec.md`, `/qa-run` requires `scenarios.md`, etc. A small `qa-kit-prereqs.sh` per step.
2. **Alignment checks — per step.** Before a step proceeds, it validates consistency against the earlier artifacts (scenario roles ⊆ spec-roles ⊆ constitution roles; the run's customizations don't violate a constitution invariant). Deterministic where the data is structured (role-set membership, oracle presence); LLM-reasoned where it's prose (spec-kit's `analyze` pattern).
3. **Runtime enforcement — POST-HOC via `qa-verify`, by populating the gate's existing inputs (corrected per Grill Q1/Q2).** This is the differentiator (spec-kit built the hook socket in `events.py` and left it empty; qa-kit fills the *post-hoc* seam with qa-e2e-pilot's engine). qa-kit's phases write into the shapes `qa-verify` **already** reads — `checklist.json` (criterion↔role, required-evidence-kinds, declared-oracle-per-criterion) + `.qa/config.json` (`personas[].expectedSubject`) — so `qa-verify` (**unmodified**) enforces them after the run on **every** harness:
   - scenarios' **planned-criteria set** → `qa-verify` flags an act on a criterion not in the frozen plan (needs journal/criterion context — post-hoc only).
   - constitution's **allowed-roles / required-kinds** → `checklist.json` rows + `qa-verify`'s required-kinds re-derivation.
   - spec's **declared oracle per criterion** → `qa-verify` checks the recorded verdict used the declared oracle, not the backend's own formula (the load-bearing QA invariant).
   - **Live-block (`block-hook`) stays limited to tool-*shape* absolutes** (mutating `evaluate`, `run_code_unsafe`) — it has no criterion context, so it cannot enforce criterion-level rules live. A per-run live constitution-block on Claude is a later `block-hook` enhancement.
   - **Honest boundary:** only *machine-checkable* parts enforce; *prose* parts (e.g. "prefer minimal scenarios") stay guidance. qa-kit never pretends a prose ideal is gate-enforced.

## 6. Artifact / disk layout (reuses `.qa/`)

```
.qa/
  constitution.md              # human: invariants + roles summary (living, project-level)
  roles.json                   # stateful role/persona store (living); carries a version/hash
  config.json                  # EXISTING — personas[].expectedSubject etc; /qa-constitution populates it
  specs/<target-name>/         # one dir per spec (mirrors spec-kit's specs/<feature>/)
    qa-spec.md                 # what "correct" means for this run + selections + customization
    spec-roles.json            # FROZEN role snapshot + the constitution version/hash it was built from
    run-plan.md
    scenarios.md / checklist.json  # EXISTING checklist shape — the gate input qa-verify reads
    analysis.md                # /qa-analyze consistency+coverage report
    runs.json                  # which .qa/runs/<id> this spec produced
  runs/<run-id>/               # UNCHANGED — journal, checkpoint, bug-log, traceability, report
```

There is **no** `constitution.rules.json` gate-input (Grill Q2) — the enforcement lands in the *existing* `checklist.json` + `.qa/config.json` that `qa-verify` already reads, so `qa-verify` is untouched. `spec-roles.json` stamps the **constitution version/hash** it snapshotted (Grill Q6); re-opening a spec against a newer constitution surfaces a drift advisory (never auto-migrates).

Project-level state (constitution/roles) sits like spec-kit's `.specify/`; per-spec snapshots sit like spec-kit's `specs/<feature>/`; the durable run evidence stays exactly where ADR-0020 put it.

## 7. spec-kit grounding (implementation facts that shaped this)

From a full analysis of `github/spec-kit`'s implementation (not its README):
- spec-kit's default gating is **prompt-driven + real file-existence checks** (`check-prerequisites.sh` hard-`exit 1`); the Constitution Check / `analyze` consistency gates are **pure LLM prose**, no parser. It does **not** enforce the constitution/spec/plan at tool-call time by default.
- spec-kit **ships a per-harness native-hook installer** (`events.py`: writes real `PreToolUse`/`PostToolUse` into `.claude/settings.json`, an opencode TS plugin, `.github/hooks/*.json`, etc.) — **but plugs nothing into it** (zero default handlers). The socket exists; it's empty.
- Packaging: a `CommandRegistrar` writes commands per agent (45 integrations; Claude Code = *Skills*, Codex = TOML, opencode = Markdown); a real priority-stacking template resolver; extensions/presets/bundles are a genuine plugin system.
- **Consequence for qa-kit:** we reuse spec-kit's *patterns* (phased commands, file-existence prereqs, template artifacts, the per-harness command+hook installer shape) and **fill the enforcement socket spec-kit left empty** with qa-e2e-pilot's `block-hook`/`qa-verify`. That is precisely what makes qa-kit more than "spec-kit with QA words." We do not depend on or vendor spec-kit's code; we mirror its patterns using this repo's existing ADR-0017 build + honesty stack.

## 8. Smaller decisions — resolved with recommendations (flag any to change)

- **Per-spec dir naming:** named by target + short timestamp (e.g. `checkout-flow-20260904`), not auto-incrementing integers — matches `.qa/runs/<id>` style and avoids cross-branch numbering races. *(Rec.)*
- **`ingesting-spec-kit`'s fate:** stays, repositioned as an **input to `/qa-spec`** — when a *feature* spec-kit's `spec.md`/`tasks.md` exists, `/qa-spec` ingests it to seed oracles/criteria + the traceability matrix. Not subsumed, not required. *(Rec.)*
- **Which enforcement lands first (v1):** the **scenarios → only-planned-criteria-may-act** check (highest value, cleanest to compile, post-hoc via `qa-verify` reading `checklist.json`), then the constitution's allowed-roles/required-kinds, then the spec's declared-oracle. *(Rec.)*
- **Alignment-check implementation:** deterministic set/membership checks where data is structured (roles, criteria, kinds); LLM-reasoned for prose alignment — mirroring spec-kit's `analyze`. *(Rec.)*
- **`/qa-run` relationship:** `/qa-run` *is* qa-kit's Implement step (the existing command, invoked at the end of the chain); it also remains usable standalone (a one-shot run without the phased shell) for backward compatibility. *(Rec.)*

## 9. v1 scope vs. later

**v1 (a coherent first plan):**
- qa-kit as a **second plugin** (`.claude-plugin/plugin.json` + marketplace entry) in this repo, reusing `core/`/`skills/`/`scripts/`.
- The spine commands `/qa-constitution → /qa-spec → /qa-plan → /qa-scenarios → /qa-analyze → /qa-run`, generated per harness (ADR-0017 build). `/qa-run` remains valid standalone (quick path).
- The stateful constitution (roles.json + version/hash + regenerate→diff→confirm) + spec snapshot (spec-roles.json, frozen at plan_frozen, drift advisory).
- Phase-ordering (file-existence prereqs) + per-step alignment checks (structural = deterministic; semantic = LLM-advisory) + the `/qa-analyze` coverage gate.
- **One** runtime-enforcement compilation end-to-end — scenarios' planned-criteria written into `checklist.json` → `qa-verify` **post-hoc** (all harnesses) flags an out-of-plan act — proving the "phases populate the gate's existing inputs" seam works, `qa-verify` unmodified.
- Fixture-project phase tests (§12).

**Later (separate plans):**
- The remaining enforcement compilations (constitution allowed-roles/required-kinds, spec oracle-binding into `checklist.json`/`config.json`).
- The optional QA gates (`/qa-sanitize`, `/qa-assure`, `/qa-perf`, `/qa-security`, `/qa-uiux`) — read run evidence, don't re-drive.
- The per-run *live* constitution-block on Claude (a `block-hook` enhancement — qa-verify already covers the post-hoc floor everywhere).

## 12. Test strategy (Grill Q7)

qa-kit is validated by **fixture-project phase tests** reusing the existing test idioms:
- Run each phase command against a seeded fixture; assert the **right artifacts** are produced.
- Assert **prereq/alignment gates fire**: a missing `qa-spec.md` makes `/qa-plan` error (non-zero); a scenario referencing a role absent from `spec-roles.json` is rejected.
- Assert the compiled `checklist.json`/`.qa/config.json` are the **exact shapes `qa-verify`/`required-kinds.sh` already consume** (a schema round-trip — feed them to `qa-verify` and confirm it reads them).
- Assert a full **phased run on the accuracy-harness fixture matches a one-shot `/qa-run`'s findings** (the phased shell changes orchestration, not verdicts).
- The stateful path: `/qa-constitution` re-run after a fixture role change → the regenerate→diff→confirm delta is correct and preserves per-role customizations; a spec's `spec-roles.json` stays frozen across the change.

## 10. Honest constraints & non-goals

- **Per-harness enforcement is tiered, not uniform** — live-block on Claude, post-hoc `qa-verify` elsewhere. Stated everywhere; never claimed as identical live blocking on all four.
- **Only machine-checkable artifact parts enforce**; prose stays guidance.
- **No mid-run mutation** of roles/plan — reproducibility over live-editing.
- **Not a fork or a separate repo**; not a vendoring of spec-kit; not a rewrite of any qa-e2e-pilot skill.
- **`qa-verify` is untouched** as the authority — qa-kit *feeds* it config, never modifies it.

## 11. Open questions for the plan stage (not blocking this design)

- Do qa-kit's commands live in `core/commands/` alongside `qa-run`/`qa-roles` (generating into every `dist/<h>/`), or a `core/qa-kit/` sub-namespace? How does a second `plugin.json` in this repo select its command/skill subset from the shared `core/`? (Leaning: `core/commands/` prefixed `qa-`; the qa-kit `plugin.json` + build target picks up the `qa-*` phase commands.)
- The thin compiler that writes qa-kit's selections into `checklist.json` + `.qa/config.json` — confirm it emits exactly the shapes `qa-verify`/`required-kinds.sh` already parse (no schema change to the gate). *(Resolved in principle by Grill Q2; the plan pins the field mapping.)*
- Skill count / conventions: qa-kit adds commands (not necessarily new skills) — confirm the phase logic lives in command bodies + tiny helper scripts, reusing existing skills, so the skill surface grows minimally.
