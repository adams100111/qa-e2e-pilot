# Audit-2 Wave 3 — Skills/Gates Reconciliation + Coverage Holes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land spec items W3-1…W3-7 of `docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md`
(read each task's spec section as its authoritative requirements) plus the deferred minors from
waves 1–2 recorded in `.superpowers/sdd/progress.md`.

**Architecture:** Branch `fix/audit2-w3-reconciliation`. Batch A = T1–T6 (parallel worktree
subagents, file-disjoint). Batch B = T7–T10 (parallel, after A merges — avoids doc-file collisions
and lets T7 see the final suite state). T11 = controller gate + versions (engine 0.6.5, qa-kit
0.1.3) + final review + PR.

**Contract style:** Each task cites its spec section as the requirement source; this plan pins the
contracts (files, acceptance greps/tests, commit messages). Implementers mirror existing suite
idioms; reviewers verify against the spec section + this plan's constraints.

## Global Constraints

(Identical to Wave 1/2 — binding.)
- Verdict/confidence vocab unchanged. Never weaken a gate: over-strict gates get a sanctioned path
  + a negative test. The UX accuracy gate (`tools/accuracy-harness/run-ux-measure.sh`) must be
  GREEN after any detector change — if the measured findings shift, re-run the real measurement
  and commit the honest result; NEVER hand-edit measured files or thresholds.
- Dual-engine idiom for JSON-touching scripts. Bash-3.2 floor on gating paths. No `grep -P`/perl.
- Generated-and-committed discipline for anything under `core/`/`qa-kit/core/`; both byte-oracles
  green. Skill bodies stay <500 lines (move overflow to references/).
- New/changed suites enrolled (strictly alphabetical) + `check-suite-coverage.sh` green.
- No destructive git. Commit per task. No attribution/trailers. Push only at T11.
- **Verify-then-fix rule (batch tasks T8–T10):** every claimed defect must first be reproduced/
  confirmed against HEAD; a claim that turns out false is SKIPPED with a one-line note in the
  report (and the task's commit message body lists skipped ids). Fixes only for (a) script-
  BEHAVIOR defects and (b) doc drift; pure design-risk/nice-to-have items are NOT fixed — append
  each to `docs/doc-sync-todo.md` as tracked debt instead.

---

### Task 1 (batch A): UX detector-id ↔ oracle-grade alignment — spec **W3-2**

**Files:** `skills/detecting-visual-ux/scripts/ux-detectors.js` (+`adjudicate.js` if the chosen
authority is the grades table), `tests/ux-detectors/run.sh`, `tests/ux-adjudicate/run.sh`; re-run
(never hand-edit) `tools/accuracy-harness/run-ux-measure.sh`.
**Contract:** every detector id `ux-detectors.js` can emit must adjudicate to its intended grade —
add a completeness test enumerating all emitted ids against a committed expectation table; the two
known mismatches (`asset-broken-image` → definite-dom `broken-image` grade;
`overlap-modal-behind-backdrop` → definite-dom `modal-behind-backdrop`, currently swallowed by the
`overlap` heuristic prefix) must land as `fail@FE`/high, with fixtures proving it; existing unit
tests that grade never-emitted bare ids are corrected to the real ids. TDD.
**Acceptance:** new completeness case green under the suites; `bash tools/accuracy-harness/run-ux-measure.sh`
prints GATE: PASS; if its findings file changed, the diff is the tool's own output, committed as-is.
**Commit:** `fix(ux): align detector ids with oracle grades — broken-image + modal-behind-backdrop are definite-dom again (audit-2 W3-2)`

### Task 2 (batch A): interaction-ux dead-end false positive — spec **W3-5a**

**Files:** `skills/detecting-interaction-ux/scripts/overlay-stack.js`, `tests/interaction-ux/run.sh`.
**Contract:** `extractOverlayStack` captures a base-context descriptor (document body present /
main landmark) so `checkNoDeadEnd(afterClose)` distinguishes "all overlays correctly closed,
healthy base page" (NO suspicion) from a true dead-end (empty stack AND missing/inert base →
suspicion stands). TDD: clean-close fixture (currently false-fails) + true-dead-end fixture
(still caught — the negative control).
**Commit:** `fix(interaction-ux): dead-end check requires a missing/inert base context, not just an empty overlay stack (audit-2 W3-5a)`

### Task 3 (batch A): skill-docs ↔ gate reconciliation — spec **W3-1 + W3-3**

**Files:** `skills/driving-browser-qa/SKILL.md` + `references/interaction-discipline.md`,
`skills/generating-qa-checklist/SKILL.md` + `templates/checklist.md`,
`skills/writing-qa-reports/SKILL.md` + `templates/{report.md,bug-report.md,report.html}`,
`skills/walking-multistep-flows/SKILL.md`; new suite `tests/skill-gate-consistency/run.sh`
(+ enrol in `run-engine-ci.sh`, alphabetical).
**Contract (per spec sections):** (1) driving-browser-qa's delta-slice recipe gains the
`--fingerprint-before/--fingerprint-after` capture steps Check 3 hard-requires, cross-referenced in
interaction-discipline.md; (2) generating-qa-checklist Step 7 + template teach the FOUR-kind vocab
(`bake|computed|human-action|probe`) exactly matching `required-kinds.sh` (fixed CSV order per the
schema); (3) `recompute.md` → `recompute.json` in writing-qa-reports SKILL + all three templates;
(4) walking-multistep-flows Eval 3 re-fills via human-path tools (no read-only react-set-input.js
"set", consistent with ADR-0015).
**New suite asserts (grep-level, structural):** every flag name `check-action-trace.js` requires
appears in driving-browser-qa; `human-action` present in Step 7's derivation; zero `recompute.md`
references outside docs/ history; no skill instructs setting values via react-set-input.js. Bodies
stay <500 lines (`wc -l` check in the suite).
**Commit:** `fix(skills): reconcile skill docs with the enforcement gates — fingerprints, 4-kind vocab, recompute.json, ADR-0015 evals (audit-2 W3-1/W3-3)`

### Task 4 (batch A): write-persona-config degrade path + expectedSubject — spec **W3-4**

**Files:** `skills/confirming-discovered-roles/scripts/write-persona-config.sh`,
`skills/confirming-discovered-roles/SKILL.md` (Eval 2 wording), `tests/write-persona-config/run.sh`.
**Contract:** (a) `--allow-empty` flag permits an empty authz matrix (weak-signal/single-user
degrade); WITHOUT the flag an empty matrix still exits 4 (negative control); SKILL Eval 2 documents
passing it on the degrade path only. (b) wholesale personas regeneration preserves operator-only
keys (explicit preserve-list, at minimum `expectedSubject`) by merging per-persona id — discovered
fields regenerate, operator fields survive, personas removed upstream disappear (ADR-0011
wholesale semantics intact). Both engine legs, byte parity. TDD.
**Commit:** `fix(roles): --allow-empty degrade path + expectedSubject survives wholesale persona regeneration (audit-2 W3-4)`

### Task 5 (batch A): index-routes env-var fix — spec **W3-5b**

**Files:** `skills/analyzing-feature-ui/scripts/index-routes.sh`, `tests/index-routes/run.sh`
(new suite, enrol alphabetically) — or extend an existing suite if one already covers this script
(check first; the audit found none).
**Contract:** both node fallbacks receive `QA_CFG` as an environment variable (assignment BEFORE
`node`), and a resolution failure WARNs on stderr instead of being swallowed by `2>/dev/null || true`.
Test: jq masked from PATH + node present → `.qa/config.json` `repos[]` roles resolve (frontend +
backend paths found); a corrupt config → WARN visible.
**Commit:** `fix(analyze): index-routes node fallback gets QA_CFG as env — config role resolution works without jq (audit-2 W3-5b)`

### Task 6 (batch A): implement fingerprintPaths/noProbePaths runtime fingerprint — spec **W3-5c** (Decision: implement)

**Files:** `skills/detecting-stack-profile/scripts/detect-stack.sh` (+its `stack-signatures.json`
consumers), `skills/detecting-stack-profile/SKILL.md` (only if its claims need aligning to what
ships), `tests/detect-stack/run.sh`.
**Contract:** the runtime fingerprint actually evaluates (a) `runtime.html` markers from
stack-signatures.json against the fetched base page, and (b) the signature `openapiPaths` +
config `fingerprintPaths`, minus `noProbePaths`, capped at 4 paths, read-only GETs honoring
`maxRequestsPerSecond`; production posture unchanged (read-only always). Degrade gracefully when
curl/network absent (signal:weak, never fail). Tests use local fixture files served via a python
http.server started/stopped by the suite (or file:// contents fed through a seam — implementer's
choice, hermetic either way): marker match, openapi probe hit, noProbePaths exclusion, cap-at-4.
**Commit:** `feat(stack): runtime HTML-marker + bounded openapi/fingerprintPaths probes — the documented fingerprint now ships (audit-2 W3-5c)`

### Task 7 (batch B): orphaned test enrollment + coverage extension — spec **W3-6** + deferred minors

**Files:** `scripts/validate-adapters.sh` (or suite wrappers), `scripts/check-suite-coverage.sh`,
`scripts/run-engine-ci.sh`, `tests/qakit-adapters/run.sh`, `tests/journal-merge/run.sh`,
`scripts/provenance.sh`, `tests/installers/run.sh`.
**Contract:** (a) all 9 orphaned `scripts/tests/*.sh` run in a gate (either invoked by
validate-adapters.sh or wrapped as `tests/<name>/run.sh` suites); (b) `check-suite-coverage.sh`
additionally inventories `scripts/tests/*.sh` against an enrollment list so a future orphan fails
the meta-gate (prove by temporarily adding a dummy, then removing it); (c) fix the qakit-adapters
grep-count-vs-itself tautology (compare against an independently-derived expected count; mutation-
check once that it can fail); (d) deferred minors: SUITES `bash32-safety` strictly alphabetical;
`find` added to journal-merge FAKEBIN whitelist; provenance WARN string deduplicated into one
variable used by both engine legs (byte-parity test stays green); tests/installers jq calls gain
the `command -v jq` guard / python3-fallback idiom its sibling suites use.
**Commit:** `test(ci): enrol the 9 orphaned scripts/tests, extend the coverage meta-gate to them, fix tautological + unguarded assertions (audit-2 W3-6)`

### Task 8 (batch B): engine-script minors batch — spec Appendix A "Engine scripts" + "Skills" (verify-then-fix)

**Files:** per confirmed item (engine scripts + skills scripts/docs named in the spec's Appendix A
first two groups); tests beside each behavior fix in the owning suite.
**Contract:** apply the Verify-then-fix rule to every item in Appendix A groups "Engine scripts"
and "Skills". Behavior fixes expected (if confirmed): qa-ci.sh uses `.qa/runs/latest`;
verification.json written atomically (tmp+mv); report-to-junit surfaces `__phase-surface__`;
memory-sync gains the Fix-28 run-id validation; qa-reconcile apply stops shell-interpolating JSON;
journal-emit rejects delimiter chars in ids (fail-closed with clear error); die()-in-subshell
criterion loss in qa-verify (record the criterion as error instead of vanishing);
missing `--persona` bypass → require persona when checkpoint row carries one (tighten, don't
loosen). Doc-drift fixes: README/INSTALL perl/grep-P claim; driver-preset table vs preflight;
carve-out count; CLAUDE.md preflight fallback claim; browser_run_code_unsafe recommendation;
browser_network_request replay suggestion; react-set-input Eval-5 wording; report Eval-1 layer
vocab. Design-risk items (journal ensure_ascii, toolstream seq lock, legalPhaseEdges,
state-machine toolClasses doc, cross-origin preflight, budgetExceeded, source-drift/i18n
unreachable claims, bake-evidence naming) → verify, then FIX if trivially safe doc-drift, else log
to doc-sync-todo per the rule.
**Commit:** `fix(engine): verified minors batch — behavior fixes + doc drift; remainder logged as debt (audit-2 W3-7a)`

### Task 9 (batch B): qa-kit minors batch — spec Appendix A "qa-kit" (verify-then-fix)

**Files:** qa-kit scripts/commands/templates + their tests (spec Appendix A qa-kit group).
**Contract:** same rule. Expected behavior fixes (if confirmed): spec-snapshot atomic create +
cross-engine override parity; detect-seed cwd cross-engine parity (CONFIRMED in audit — priority,
with a byte-parity test) + error-blame message; data-baseline `is_int` rejects `1-2`;
check-fixtures missing[] ordering parity; dual-engine suites die (not vacuous-pass) when both
engines absent; mktemp leaks cleaned (trap EXIT); run-qakit-ci.sh excluded from adapter/install
payloads. Doc fixes: qa-status stale drift claim + phantom runs.json gate wording; constitution
template's five nonexistent gate commands; spine docs gain the shipped `/qa-verify` step (qa-kit
README + harness READMEs); qa-spec step-numbering cite; auto-seed header overclaim. Prose-only
rules (confidence-high oracleSource, relative multiplicity fixtures) → verify, fix docs or log.
Generated qa-kit files only via core+regenerate; qa-kit byte-oracle green.
**Commit:** `fix(qa-kit): verified minors batch — parity/atomicity/vacuous-pass fixes + spine doc updates (audit-2 W3-7b)`

### Task 10 (batch B): top-level doc-drift batch — spec Appendix A "Docs/packaging" + "Adapters" + deferred prose

**Files:** `CLAUDE.md`, `README.md`, `INSTALL.md`, `docs/{running-in-ci.md,extending-drivers.md,doc-sync-todo.md}`,
`docs/known-issues/`, `tools/accuracy-harness/README.md`, `docs/adr/0023…md` (superseded note only),
`docs/specs/2026-09-02-run-fsm-enforcement-design.md` (status header only),
`skills/{probing-apis-through-browser,verifying-backend-persistence}/SKILL.md` +
`qa-kit/commands/qa-spec.md`(via core)/`qa-kit/README.md` (sentinel prose),
`skills/bootstrapping-qa-config/SKILL.md` (marker question note), harness READMEs (CLAUDE.md
generated-list mention), `docs/harness-adapters.md`.
**Contract:** verify-then-fix each doc item: CLAUDE.md opener counts + layout (17 skills, real
script lists, tests exist) + generated-list includes qa-resume; INSTALL "nine skills"→real counts +
hooks-loss note for manual/npx installs; README ADR range + commands list; running-in-ci honest
status; extending-drivers Mem0 claim; accuracy README 18→24 seeds (count seeds.json first);
ADR-0023:77 superseded-by-ADR-0024 note; stale DEFERRED spec header; doc-sync-todo self-
contradiction cleaned + all new debt entries from T8/T9 land coherently; "non-empty
seedableEnvMarker" prose gains the sentinel exclusion in the four flagged files; bootstrapping
SKILL documents the `--seedable-marker` opt-in question. Do NOT touch the "85%/100% gate" wording
in harness READMEs (that is W4-2's). Where a target is a generated file (qa-kit command), edit
core + regenerate.
**Commit:** `docs: drift batch — counts, layouts, sentinel prose, superseded notes, tracked-debt ledger (audit-2 W3-7c)`

### Task 11 (controller): wave gate, versions, final review, PR

Full gate (engine CI, qa-kit CI, both oracles, coverage, JSON sweep, UX accuracy gate
`run-ux-measure.sh`); engine → **0.6.5**, qa-kit → **0.1.3**; whole-branch review (merge-base
package); push + PR (`Audit-2 Wave 3: skills/gates reconciliation (W3-1..W3-7)`) + merge.

## Self-review notes
- Spec coverage: W3-1→T3, W3-2→T1, W3-3→T3, W3-4→T4, W3-5a→T2, W3-5b→T5, W3-5c→T6, W3-6→T7,
  W3-7→T8/T9/T10; deferred wave-1/2 minors→T7 (mechanical) + T10 (prose).
- Batch A tasks are file-disjoint; batch B waits for A (T8/T10 touch skill docs T3 also edits —
  sequencing removes the collision; T7 needs the final suite set).
- Coarser step granularity than Wave 1 is deliberate: contracts + acceptance are pinned here, spec
  sections carry the requirement detail, and the two-stage review net (per-task + whole-branch)
  has caught every slip so far.
