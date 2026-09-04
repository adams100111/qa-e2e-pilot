# ADR-0024 — qa-kit multi-harness portability (Codex · Pi · opencode)

## Status

Accepted, 2026-09-05. Implements `docs/superpowers/specs/2026-09-05-qa-kit-multi-harness-portability-design.md`
(grill-hardened ×2). Increment **7** of qa-kit. **Supersedes** ADR-0022's "v1 qa-kit is Claude-only" limitation.
Builds on ADR-0017 (engine multi-harness portability), ADR-0022 (qa-kit process shell), ADR-0001 (reimplement,
don't fork/vendor).

## Context

The verification **engine** already runs on all four harnesses (ADR-0017: shared `core/` + `harness-profiles.json`
+ `build-adapter.sh` → `dist/<h>/`). **qa-kit**, the step-gated process shell, was Claude-only (ADR-0022) —
non-Claude users got the engine but not the `/qa-constitution → … → /qa-run` process. The locked surface was
small: qa-kit's 7 scripts are pure and portable already; only the 5 command bodies + agent persona carried two
Claude idioms — `${CLAUDE_PLUGIN_ROOT}` (a path token) and 8 `/qa-e2e-pilot:<skill>` cross-plugin references
(the only genuine coupling, existing because Claude has a plugin/skill namespace + `dependencies`).

## Decision

1. **Mirror ADR-0017, qa-kit-owned.** A parallel, qa-kit-owned pipeline: `qa-kit/core/` (tokenized persona +
   5 command bodies), `qa-kit/harness-profiles.qakit.json` (per-harness `skillRef`/`engineRun`/`pluginRoot`/
   install dirs), `qa-kit/scripts/build-qakit-adapter.sh`, `qa-kit/scripts/validate-qakit-adapters.sh`, and
   `qa-kit/harnesses/<h>/` glue. The engine's `harness-profiles.json`/`build-adapter.sh` are **read-only**
   inputs at most — never modified.
2. **Claude becomes generated-and-committed.** `build-qakit-adapter.sh claude` reproduces the committed
   `qa-kit/commands/*` + `agents/qa-kit.md` **byte-for-byte**; `validate-qakit-adapters.sh` enforces it (the
   Claude byte-oracle). `qa-kit/core/` is the single source of truth for all four harnesses.
3. **Skill composition = reference the engine's skills the same per-harness way the engine's own commands do**
   (the hard decision; corrected by a docs-grounded grill). The engine installs its skills into a fixed
   **shared** dir per harness and references them by bare name; qa-kit does the same. `{{SKILL_REF:<name>}}`
   renders: Claude `/qa-e2e-pilot:<name>` (plugin slug); **Pi/Codex** `` the `<name>` skill `` (bare — the agent
   reads `.pi/agents/skills/<name>/` resp. `.agents/skills/<name>/`); **opencode** `skills_<name>` (a tool
   exposed by the community `opencode-skills` plugin). The engine's `qa-run` **command** renders via
   `{{ENGINE_RUN}}`. **No install-resolved paths, no vendoring, no fork** (ADR-0001).
4. **Co-install contract.** Non-Claude qa-kit REQUIRES the engine adapter for that harness installed first (it
   populates the shared skills dir); each `install-<h>.sh` aborts if the engine's skills dir is absent, and
   installs qa-kit's agent + step commands into the SAME per-harness dirs so bare names resolve. opencode
   additionally requires the `opencode-skills` plugin enabled.
5. **Packaging/composition only.** The 7 qa-kit scripts are copied verbatim into each adapter; no script
   behaviour changes. qa-kit's enforcement stays the prose-driven `verify-plan.sh` call (no per-harness hook).

## Consequences

- **Engine untouched, verified.** The whole increment touches only `qa-kit/`, `tests/qakit-adapters/`, docs,
  and `.gitignore` (+ `CLAUDE.md`). `scripts/validate-adapters.sh` (the engine byte-oracle) still passes.
- **Deliberate simplification vs the plan:** the `{{QAKIT_CMD}}` token was dropped — bare `/qa-<step>` command
  references read fine on every harness and tokenizing them risked over-tokenization; the Claude byte-oracle
  constrains correctness regardless.
- **Grill-2 reversal, logged not hidden.** An earlier self-grill proposed install-resolved `SKILL.md` **paths**
  for Pi/opencode. Grounding the grill in the engine's real `harnesses/<h>/` adapters refuted it (shared skills
  dir + bare-name resolution), and corrected a codex↔opencode mix-up (codex reads files; opencode is the
  `skills_<name>`-tool harness). Simpler and correct.
- **Honest limits.** The generator + composition are unit-tested (`tests/qakit-adapters/run.sh`, 30 checks) and
  the installers are smoke-tested (co-install guard + file placement), but a **live end-to-end qa-kit run on
  each non-Claude harness is the manual accuracy run**, not a headless test. Non-Claude enforcement hooks remain
  deferred (ADR-0022), orthogonal to this increment.
- **Reversibility.** Additive: `qa-kit/core/` + generator + validator + per-harness glue + one test. Claude
  behaviour is byte-identical to before. Reverting removes the non-Claude path; the engine and Claude qa-kit are
  unaffected.
