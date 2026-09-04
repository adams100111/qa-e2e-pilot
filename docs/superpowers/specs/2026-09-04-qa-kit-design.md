# qa-kit — spec-kit-style QA process shell — design

**Status:** design (awaiting user review) · **Date:** 2026-09-04 · Supersedes the capture note `docs/specs/2026-09-02-qa-kit-plugin-idea.md` (idea → design). Brainstormed as a discussion 2026-09-04.

---

## 1. What qa-kit is (one paragraph)

`qa-kit` is a **phase-gated, artifact-producing process shell for QA**, added to *this* repo, that borrows spec-kit's *patterns* (a sequence of steps, each producing a human-reviewable Markdown artifact, each required to stay *aligned* with the steps before it — delivered as per-harness **commands** + per-harness **hooks**) but defines its own **QA-specific steps**, each powered by qa-e2e-pilot's existing skills. The steps hold **state**: the **constitution** is the living, project-level home for roles/personas + QA invariants + a machine-checkable enforcement block; each **spec** pins an immutable snapshot of that state (+ per-spec customization) for one reproducible run. Where spec-kit's constitution/spec/plan are enforced only by prose + file-existence checks, qa-kit's compile into **runtime enforcement** — the `block-hook`/`qa-verify` engine qa-e2e-pilot already ships — so the constitution/spec/plan actually *govern* the run, tiered honestly per harness.

## 2. Decisions settled in the brainstorm (binding)

1. **Model A — thin process shell, same repo.** qa-kit is new commands (+ hook config) in *this* repo that orchestrate the **existing skills unchanged**; `/qa-run` becomes the "Implement" step. No fork, no cross-repo dependency, no logic duplication. Inherits ADR-0017 portability, ADR-0020 durable run state, and the H1/H2/H4 honesty stack for free.
2. **Borrow spec-kit's patterns, not its steps.** qa-kit does **not** reuse spec-kit's `constitution→specify→plan→tasks→implement` step names/bodies. It reuses the *pattern* (phased, aligned, artifact-per-step, per-harness command+hook installers) and defines QA-specific steps.
3. **Delivered as per-harness commands + per-harness hooks.** Steps ship as commands in each harness's idiom (the existing `core/` → `dist/<h>/` build). Enforcement rides `PreToolUse`/`PostToolUse`-style hooks per harness.
4. **Enforcement is honestly tiered per harness (non-negotiable reality).** Live-block on Claude (real `PreToolUse`/`PostToolUse`); post-hoc catch-and-override via `qa-verify` on Codex/opencode/Pi (their live hooks are best-effort/unverified — H4), with the documented live-hook recipes (`harnesses/<h>/hooks.md`) as opt-in hardening. **`qa-verify` is the universal floor on every harness.** One design, tiered strength — identical *live* blocking on all four is not promised because the harnesses do not allow it (confirmed by both spec-kit's own `events.py` and H4).
5. **Constitution = the living, stateful home** for roles/personas + QA invariants (prose) + the machine-checkable enforcement block. Roles are discovered once and **maintained** thereafter via **regenerate → diff → confirm** (reuses ADR-0011 frontier-round HITL + ADR-0016 seed store). It compiles into the `block-hook`/`qa-verify` config.
6. **Each spec pins an immutable role snapshot.** Constitution roles are **copied** into the spec (`spec-roles.json`), editable while *authoring* the spec, **frozen at `plan_frozen`** (ADR-0020) for the run, plus per-spec overrides/additions. A live reference would break the durable-resume + reproducibility guarantee — rejected. The constitution mutates; each run is a reproducible snapshot of it.
7. **Alignment enforcement is woven into every step**, not one end-gate: each step must be consistent with the constitution + spec + plan (e.g. a scenario cannot use a role absent from the spec's frozen set; a run cannot customize away a constitution invariant). This is spec-kit's `analyze` idea, per-step.
8. **QA-specific optional gates** (`/qa-sanitize`, `/qa-assure`, `/qa-perf`, `/qa-security`, `/qa-uiux`) are opt-in plug-ins to Implement, not required spine steps.

## 3. The steps (qa-kit's own — powered by existing skills)

| Command | Artifact(s) | State | Powered by (existing) | Compiles into enforcement |
|---|---|---|---|---|
| `/qa-constitution` | `.qa/constitution.md`, `.qa/roles.json`, `.qa/constitution.rules.json` | **stateful across runs** — roles/personas + invariants + rules; updated via regenerate→diff→confirm | `discovering-user-roles`, `confirming-discovered-roles`, ADR-0016 seed store, `CONTEXT.md` vocab | allowed-roles set, forbidden-tool-patterns, required-evidence-kinds → `block-hook` (Claude live) + `qa-verify` (all) |
| `/qa-spec` | `.qa/specs/<target>/qa-spec.md`, `spec-roles.json` | per-run snapshot — selects scenarios + roles (copied from constitution) + per-run customization/oracles | `detecting-stack-profile`, oracle definition, `ingesting-spec-kit` (as an input path) | declared-oracle-per-criterion → `qa-verify` checks the recorded verdict used it |
| `/qa-plan` | `.qa/specs/<target>/run-plan.md` | per-run | ADR-0011/0012 persona/criteria-budget, driver pool config | run budget/parallelism bounds |
| `/qa-scenarios` | `.qa/specs/<target>/scenarios.md` / `checklist.json` | per-run | `generating-qa-checklist`, `fanning-out-criteria` | only-planned-criteria-may-act → `block-hook` (Claude) + `qa-verify` (all) |
| `/qa-run` (Implement) | `.qa/runs/<run-id>/` + `report.md`/`.html` | per-run (durable journal, ADR-0020) | the whole verification pipeline (driving-browser-qa, verifying-backend-persistence, verifying-computed-logic, walking-multistep-flows, probing-apis-through-browser, checkpointing-qa-memory, writing-qa-reports) | governed by all the above at runtime |
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
3. **Runtime enforcement — the machine-checkable blocks compile into the honesty gate.** This is the differentiator (spec-kit built the hook socket in `events.py` and left it empty; qa-kit fills it with qa-e2e-pilot's engine):
   - The constitution's **allowed-roles / forbidden-tool-patterns / required-evidence-kinds** → feed the existing `block-hook` (Claude, live pre-tool deny) + `qa-verify` required-kinds/provenance (universal, post-hoc override).
   - The scenarios' **planned-criteria set** → `qa-verify` (+ Claude live-block) enforces *only-planned-criteria-may-act*.
   - The spec's **declared oracle per criterion** → `qa-verify` checks the recorded verdict used the declared oracle, not the backend's own formula (the load-bearing QA invariant).
   - **Honest boundary:** only the *machine-checkable* parts of each artifact enforce; the *prose* parts (e.g. "prefer minimal scenarios") stay guidance. qa-kit never pretends a prose ideal is hook-enforced.

## 6. Artifact / disk layout (reuses `.qa/`)

```
.qa/
  constitution.md              # human: invariants + roles summary (living, project-level)
  roles.json                   # stateful role/persona store (living)
  constitution.rules.json      # compiled machine-checkable enforcement (hooks/qa-verify read this)
  specs/<target-name>/         # one dir per spec (mirrors spec-kit's specs/<feature>/)
    qa-spec.md                 # what "correct" means for this run + selections + customization
    spec-roles.json            # the FROZEN role snapshot for this spec
    run-plan.md
    scenarios.md / checklist.json
    runs.json                  # which .qa/runs/<id> this spec produced
  runs/<run-id>/               # UNCHANGED — journal, checkpoint, bug-log, traceability, report
```

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
- **Which enforcement lands first (v1):** the **scenarios → only-planned-criteria-may-act** check (highest value, cleanest to compile, directly reuses `qa-verify` + `block-hook`), then the constitution's allowed-roles/required-kinds, then the spec's declared-oracle. *(Rec.)*
- **Alignment-check implementation:** deterministic set/membership checks where data is structured (roles, criteria, kinds); LLM-reasoned for prose alignment — mirroring spec-kit's `analyze`. *(Rec.)*
- **`/qa-run` relationship:** `/qa-run` *is* qa-kit's Implement step (the existing command, invoked at the end of the chain); it also remains usable standalone (a one-shot run without the phased shell) for backward compatibility. *(Rec.)*

## 9. v1 scope vs. later

**v1 (a coherent first plan):**
- The spine commands `/qa-constitution → /qa-spec → /qa-plan → /qa-scenarios → /qa-run`, generated per harness (ADR-0017 build).
- The stateful constitution (roles.json + regenerate→diff→confirm) + spec snapshot (spec-roles.json, frozen at plan_frozen).
- Phase-ordering (file-existence) + per-step alignment checks.
- **One** runtime-enforcement compilation end-to-end — scenarios' planned-criteria → `qa-verify` (universal) + `block-hook` (Claude) — proving the "artifacts compile into the honesty gate" seam works.

**Later (separate plans):**
- The remaining enforcement compilations (constitution rules, spec oracle-binding).
- The optional QA gates (`/qa-sanitize`, `/qa-assure`, `/qa-perf`, `/qa-security`, `/qa-uiux`).
- Full per-harness *live*-hook wiring beyond Claude (rides H4's documented recipes; qa-verify already covers the floor).

## 10. Honest constraints & non-goals

- **Per-harness enforcement is tiered, not uniform** — live-block on Claude, post-hoc `qa-verify` elsewhere. Stated everywhere; never claimed as identical live blocking on all four.
- **Only machine-checkable artifact parts enforce**; prose stays guidance.
- **No mid-run mutation** of roles/plan — reproducibility over live-editing.
- **Not a fork or a separate repo**; not a vendoring of spec-kit; not a rewrite of any qa-e2e-pilot skill.
- **`qa-verify` is untouched** as the authority — qa-kit *feeds* it config, never modifies it.

## 11. Open questions for the plan stage (not blocking this design)

- Do the qa-kit commands live in `core/commands/` alongside `qa-run`/`qa-roles` (so they generate into every `dist/<h>/`), or a `core/qa-kit/` sub-namespace? (Leaning: same `core/commands/`, prefixed `qa-`.)
- Does `constitution.rules.json` reuse the exact schema `qa-verify`/`block-hook` already consume, or a thin compiler that emits their existing config shapes? (Leaning: a thin compiler → existing shapes, so the honesty gate is unchanged.)
- Skill count / conventions: qa-kit adds commands (not necessarily new skills) — confirm the phase logic lives in command bodies + tiny helper scripts, reusing existing skills, so the "16 skills" surface grows minimally.
