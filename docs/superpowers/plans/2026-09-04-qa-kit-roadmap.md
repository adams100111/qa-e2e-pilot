# qa-kit — implementation roadmap (all increments)

**The full plan, one page.** Design: `docs/superpowers/specs/2026-09-04-qa-kit-design.md`. Each increment produces working, testable software on its own; **all five detailed plans are now written ahead** (per the chosen approach). Because later increments consume interfaces earlier ones *create* (the constitution version format, the `checklist.json` enforcement shape, the `spec-roles` snapshot), their **code steps are marked PROVISIONAL inline** — firm on scope/interface-contracts/test-contracts, with a "pin the exact shape from the landed increment before writing the code" note at the top of each dependent plan. Execute in order (1 → 2/3 → 4 → 5), re-pinning each plan's provisional bits against the prior increment's real output as you go.

---

## Increment 1 — `/qa-constitution` (stateful-roles core) · **plan written**

`docs/superpowers/plans/2026-09-04-qa-kit-01-constitution.md`

- **Scope:** `/qa-constitution` as a thin command over the existing role flow, adding `constitution.sh` (deterministic version/hash + informational diff + `constitution.md` render), the template, and ADR-0022.
- **Produces (contracts later increments consume):**
  - `.qa/constitution.md` (invariants + roles table + version block).
  - **The constitution version/hash format** + the canonical role-state tuple `id|role|plane` (auth excluded) + the authz tuple `entity|owningChain|<sorted "role:scope" pairs>` (**scope VALUES included, R2-Q6**) + the fenced ```json `{roles:[{id,role,plane}], version}` state block. *(Increment 3 stamps this version.)*
  - Confirmation that the role state IS `.qa/config.json` `personas[]` + `.qa/authz-matrix.json` (reused, not rebuilt).
- **Consumes:** existing `discovering-user-roles`, `confirming-discovered-roles`, `write-persona-config.sh`, ADR-0016 seed store.
- **Depends on:** nothing (foundation).
- **Tasks:** (1) `constitution.sh` + tests; (2) author the command + template FILES + ADR-0022 — **but do NOT wire the command into the shipped build** (R2-Q7); increment 2 packages/wires it as qa-kit so `/qa-constitution` never ships transiently in the qa-e2e-pilot plugin.

## Increment 2 — qa-kit as a second plugin + build target · **plan written** (`2026-09-04-qa-kit-02-packaging.md`)

- **Scope:** package qa-kit as its **own** installable plugin in this repo — a second `.claude-plugin/`-style manifest + a marketplace entry — that ships the `qa-*` phase commands, reusing the shared `core/`/`skills/`/`scripts/`. qa-e2e-pilot stays installable standalone.
- **Mechanism RESOLVED** (packaging investigation, 2026-09-04 — sibling plugin dir + symlinks + 2nd marketplace entry, per the Claude Code plugin docs). Formerly an open question: how a second plugin manifest coexists with Claude's repo-root `.claude-plugin/plugin.json`, and how `build-adapter.sh`/`marketplace.json` express two plugins from one repo. Decide: (a) a second manifest + a 2-entry `marketplace.json`, or (b) a `qa-kit/` subdir plugin, or (c) a build target that emits a `dist/qa-kit/` plugin. **Pin the mechanism before writing the packaging tasks.**
- **Produces:** the qa-kit install path (`/qa-constitution` et al. installable as the qa-kit plugin); the build/validate story for two plugins.
- **Consumes:** increment 1's command (the first thing packaged).
- **Depends on:** increment 1. *(Could run in parallel conceptually, but sequencing after 1 gives it a real command to package.)*
- **Tasks (mechanism resolved):** (1) qa-kit manifest + commands + engine symlinks (Claude); (2) 2nd marketplace entry; (3) `build-adapter.sh` plugin-id axis for the non-Claude dist; (4) install docs. See the detailed plan.

## Increment 3 — `/qa-spec` + spec snapshot (freeze semantics) · **plan written** (`2026-09-04-qa-kit-03-spec.md`)

- **Scope:** `/qa-spec` that (a) selects scenarios + roles from the constitution, (b) **copies** roles into `.qa/specs/<target>/spec-roles.json` and **stamps the constitution version** (increment 1's format), (c) captures per-spec overrides/customization + oracles + the **run-config** override section (drivers/budget from `.qa/config.json` defaults — the folded-in `/qa-plan`, R2-Q3), (d) records the drift advisory when the stamped version ≠ the current constitution's. The freeze itself lands at run start (`plan_frozen`, ADR-0020) — this increment authors the snapshot the run freezes. One spec → N runs (R2-Q5).
- **Produces:** `qa-spec.md`, `spec-roles.json` (frozen snapshot + version stamp), the per-spec override shape, the drift-advisory. *(Increment 4 reads spec-roles + the selected scenarios.)*
- **Consumes:** increment 1's constitution version/state; existing `detecting-stack-profile`, `ingesting-spec-kit` (as an input path).
- **Depends on:** increments 1 (+ 2 for packaging, but buildable against 1).
- **Tasks (provisional):** (1) `spec-snapshot.sh` (copy roles + stamp version + drift-check) + tests; (2) `/qa-spec` command + template; (3) docs.

## Increment 4 — `/qa-scenarios` + `/qa-analyze` + the enforcement seam · **plan written** (`2026-09-04-qa-kit-04-scenarios-enforcement.md`)

- **Scope:** the two commands (`/qa-scenarios`, `/qa-analyze` — `/qa-plan` was folded into `/qa-spec`, R2-Q3), plus the **one end-to-end enforcement compilation** — scenarios' planned-criteria written into `checklist.json` (the exact shape `qa-verify`/`required-kinds.sh` already read) so `qa-verify` **post-hoc** flags an act on an out-of-plan criterion. `/qa-analyze` = the consistency+coverage gate before the run. Per-step alignment checks (structural = deterministic set-membership: scenario roles ⊆ `spec-roles`; semantic = LLM-advisory).
- **Produces:** `scenarios.md`/`checklist.json`, `analysis.md`; **the proven "steps populate the gate's existing inputs" seam** (`qa-verify` unmodified).
- **Consumes:** increment 3's `spec-roles` + selections; existing `generating-qa-checklist`, `fanning-out-criteria`, `analyzing-feature-ui`, and critically `qa-verify` + `checklist.json`'s current schema (the compilation target).
- **Depends on:** increment 3.
- **Tasks (provisional):** (1) the scenarios→`checklist.json` compiler + a **round-trip test** (feed the output to `qa-verify` and confirm it flags an out-of-plan act); (2) the two commands + alignment checks; (3) docs.

## Increment 5 — `/qa-run` as Implement + fixture tests + quick-path/bootstrap · **plan written** (`2026-09-04-qa-kit-05-run-wiring.md`)

- **Scope:** wire `/qa-run` to consume the phased artifacts (`scenarios.md`/`checklist.json`) as its Implement input; **keep `/qa-run` first-class standalone** (the quick path — self-discovers roles, no constitution required); `/qa-spec` **bootstrap** when there's no constitution (offer `/qa-constitution` or per-spec-only roles). The **fixture-project phase tests** (design §12): artifacts produced, prereq/alignment gates fire, compiled `checklist.json` is the shape `qa-verify` consumes, and a full phased run on the accuracy-harness fixture **matches a one-shot `/qa-run`'s findings**.
- **Produces:** the complete phased pipeline + its validation harness.
- **Consumes:** all prior increments.
- **Depends on:** increments 1–4.
- **Tasks (provisional):** (1) `/qa-run` phased-input wiring + standalone preservation; (2) `/qa-spec` bootstrap + quick-path logic; (3) fixture phase tests + the phased-matches-one-shot end-to-end test; (4) final whole-effort review + docs.

---

## Sequencing + parallelism

- **Strict order:** 1 → 3 → 4 → 5 (spine: constitution → spec[+run-config] → scenarios → analyze → run) (each consumes the prior's produced interfaces). Increment **2 (packaging)** depends only on 1 and can slot after 1 (or run alongside 3) — it doesn't block the functional chain.
- **Each increment = its own branch + PR + review** (SDD), like the six efforts already merged this session.
- **The measured proof points:** increment 1 (state format is deterministic + reuses existing roles), increment 4 (the enforcement seam round-trips through `qa-verify` unmodified), increment 5 (phased run ≡ one-shot findings). If any of those fails, the design assumption behind it gets revisited before proceeding.

## Non-goals across all increments (from the design)

- Optional QA gates (`/qa-sanitize`/`/qa-assure`/`/qa-perf`/`/qa-security`/`/qa-uiux`) — a later effort after the spine ships (they read run evidence, don't re-drive).
- Per-run *live* constitution-block on Claude (a `block-hook` enhancement — `qa-verify` post-hoc covers the floor everywhere).
- Any modification to `qa-verify.sh` (it stays the untouched authority; phases feed its existing inputs).
