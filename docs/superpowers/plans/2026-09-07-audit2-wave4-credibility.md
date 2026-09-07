# Audit-2 Wave 4 — Product Credibility — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land spec items W4-1…W4-5 of `docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md`
(each task's spec section is its authoritative requirement).

**Architecture:** Branch `fix/audit2-w4-credibility`. Batch A = T1–T4 (parallel worktrees,
file-disjoint code/doc work). Batch B = the live-run items, sequenced: T5 (firewalled second
fixture) → T6 (blind measured run + publish) → T7 (Pi accuracy run attempt). T8 = controller gate
+ versions (engine 0.7.0, qa-kit 0.1.4 — 0.7.0 per the spec's versioning decision since W4's
credibility items land here) + final review + PR.

## Global Constraints

(Same binding set as Waves 1–3: no gate weakening, dual-engine, bash-3.2 floor on gating paths,
generated-and-committed via core/+regenerate with both byte-oracles green, suites enrolled +
coverage green, no destructive git / no stash / never commit .superpowers/, no attribution, push
only at T8.)
- **Honest-measurement discipline (paramount this wave):** measured findings files are produced
  ONLY by the tools; seeds/thresholds never tuned to make a number pass; a failing measured number
  is published as the failing number plus gap analysis.

---

### T1 (batch A): Per-run cost telemetry — spec **W4-3**

**Files:** `skills/checkpointing-qa-memory/` (run-manifest template + a new
`scripts/cost-summary.sh` deriving per-criterion tool-call counts from `.qa/runs/<id>/toolstream.jsonl`),
`skills/writing-qa-reports/SKILL.md` + `templates/report.md`/`report.html` (cost summary block),
`scripts/report-to-junit.sh` (cost line), `skills/checkpointing-qa-memory/SKILL.md` (recording
instructions incl. the criteriaBudget 80% warn), `.qa/config.json.example` (only if a doc line
needs it), new `tests/cost-summary/run.sh` enrolled alphabetically.
**Contract:** run-manifest records `startedAt`/`finishedAt` (ISO) and totals
`{criteria, toolCalls, toolCallsByCriterion}` derived deterministically from the toolstream
(dual-engine script, agent-untrusted derivation); report.md/html render a cost block ("tool-calls"
label; optional `tokens` field rendered only when present); report-to-junit emits one properties
line; the checkpointing SKILL instructs the agent to warn at ≥80% criteriaBudget consumption.
Engine persona/core untouched (skills carry the instructions) — if a core edit proves unavoidable,
STOP and report NEEDS_CONTEXT.
**Commit:** `feat(telemetry): per-run wall-clock + tool-call cost derived from the toolstream; cost block in reports (audit-2 W4-3)`

### T2 (batch A): "When NOT to use this" README boundary — spec **W4-4**

**Files:** `README.md` (new section), `qa-kit/README.md` (cross-link), grep-sweep for
contradicting marketing claims.
**Contract:** states plainly: first-pass exploratory + periodic deep passes = yes; per-commit
regression gating = no (deterministic suites win); shared-staging = degraded mode (write-gated
features off); intermittent/timing bugs = structurally out of scope; a green run means "no
divergence found at measured same-fixture recall" (link the accuracy README), never "verified
correct". No claim elsewhere may contradict it (sweep + fix or report).
**Commit:** `docs(readme): the honest usage boundary — when this tool is the wrong choice (audit-2 W4-4)`

### T3 (batch A): Accuracy gates into CI — spec **W4-5**

**Files:** `.github/workflows/adapters.yml` (or the CI workflow that exists — read it first),
`docs/running-in-ci.md`; possibly a tiny wrapper script.
**Contract:** (a) `tools/accuracy-harness/run-ux-measure.sh` (headless, deterministic) runs on
every PR; (b) a scorer-regression gate runs `node tools/accuracy-harness/scorer/score.js` over the
committed reference `findings/measured-blind-final.json` (or the file the README names as the
current blind reference — verify) with `--gate` so a scorer/seed regression turns CI red while the
live agent run stays manual; (c) docs/running-in-ci.md updated. Mutation-check locally once
(seeded detector regression → red), revert.
**Commit:** `ci(accuracy): UX measured gate + scorer-regression gate on every PR (audit-2 W4-5)`

### T4 (batch A): Harness accuracy banners + gate-wording — spec **W4-2** (banner half)

**Files:** `harnesses/{codex,pi,opencode}/install-*.sh` (banner echo), `README.md` harness
section, `harnesses/*/README.md` (banner + fix the "85%/100% gate" wording — those are measured
reference numbers, not enforced thresholds; state the real thresholds from seeds.json's gate
block), `tests/installers/run.sh` (assert the banner prints).
**Contract:** every non-Claude install path prints and documents "accuracy-unvalidated on this
harness — see docs/harness-adapters.md (manual accuracy run required)"; wording removed later
per-harness only when a measured-<harness> findings file lands. Claude path untouched.
**Commit:** `docs(harness): accuracy-unvalidated banners + honest gate-threshold wording (audit-2 W4-2a)`

### T5 (batch B): Second seeded fixture, firewalled — spec **W4-1** (decision: in-repo + firewall)

**Files:** `tools/accuracy-harness/fixture2/` (self-contained index.html app, no build,
localStorage "backend" — same style as fixture/), `tools/accuracy-harness/seeds2.json` (schema of
seeds.json incl. gate block), `tools/accuracy-harness/run-baseline2.sh` (thin copy of
run-baseline.sh pointing at fixture2/seeds2), README section.
**Contract (FIREWALL — binding):** the fixture author agent must NOT read
`skills/generating-qa-checklist/`, `skills/analyzing-feature-ui/`, or any `skills/*/SKILL.md` —
only `tools/accuracy-harness/{README.md,fixture/index.html,seeds.json,scorer/}` for format/schema.
A DIFFERENT domain than cap-table (e.g. invoicing/inventory), 12–20 planted bugs across
functional/journey/ux-objective + ≥2 negative controls, no self-leaking tells (no bug-describing
comments, no "planted" strings — the fixture/README documents the historical leak lesson). Seeds
stay UNpublished to the run agent (T6's runner is never shown seeds2.json).
**Commit:** `feat(accuracy): second seeded fixture (fixture2, <domain>) + seeds2 + runner — generator-untuned measurement target (audit-2 W4-1a)`

### T6 (batch B): Blind measured run on fixture2 + publish — spec **W4-1** (measurement half)

Controller-orchestrated: serve fixture2 (`run-baseline2.sh --serve` or python http.server), write a
scratch `.qa/config.json` (black-box, single-repo, oracles per seeds2's supplied-oracle convention
mirrored from seeds.json), dispatch the **qa-e2e-pilot agent** (browser-only, source-read forbidden
— blind discipline per the accuracy README) against it, then
`node scorer/convert-buglog.js <run>/bug-log.json > findings/measured-fixture2-blind.json` and
`node scorer/score.js findings/measured-fixture2-blind.json --seeds seeds2.json --gate`.
**Publish the honest number** beside the 85% in tools/accuracy-harness/README.md with the current
number labeled "same-fixture, post-tuning" — pass or fail, no threshold tuning.
**Commit:** `docs(accuracy): fixture2 blind measured run published — generator-untuned recall (audit-2 W4-1b)`

### T7 (batch B): Pi accuracy run attempt — spec **W4-2** (measurement half)

Per the mandated procedure in docs/harness-adapters.md (Pi named first). Attempt on this machine;
if the Pi harness run is infeasible in this session (harness not driveable non-interactively),
record the attempt + exact blocker in docs/harness-adapters.md's manual-accuracy-run section and
keep the T4 banners (that is the honest fallback the spec allows: "banners go up immediately").
**Commit (if run lands):** `docs(accuracy): measured-pi run published (audit-2 W4-2b)`; else a doc
note commit.

### T8: gate, versions (engine **0.7.0**, qa-kit **0.1.4**), final whole-branch review, PR.

## Self-review notes
- W4-1→T5+T6 (firewall + honest publish), W4-2→T4+T7, W4-3→T1, W4-4→T2, W4-5→T3. Versioning per
  grill Q9 (0.7.0 when W4 lands).
- T1–T4 file-disjoint (T2/T4 both touch README.md — T4 edits only the harness section, T2 adds a
  new section; merge risk low, controller resolves). T5 must precede T6; T6/T7 are live runs the
  controller drives.
