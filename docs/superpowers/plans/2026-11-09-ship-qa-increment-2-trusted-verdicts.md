# Ship QA Increment 2 — Trusted Verdicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sdd-lanes:sdd-lanes to implement this plan lane-by-lane. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `pass` can only be recorded when it is grounded in persisted state and a confirmed oracle; low-confidence passes get an independent second judge; the report opens with a computed ship verdict; findings export as tracker-neutral bugs.

**Architecture:** New record-time gates in `checkpoint.sh` (oracle, state, data policy), mirrored in `qa-verify.sh` so the out-of-agent check agrees. qa-kit gets the oracle confirmation page and `spec` oracle source. A re-adjudication skill builds evidence-only bundles for a fresh-context verifier that may only downgrade. The renderer gains a ship summary; a bug exporter writes one item per finding.

**Tech Stack:** bash + jq|python3 dual engine, node (renderer, self-contained HTML), Markdown skills.

**Spec:** `docs/superpowers/specs/2026-11-09-ship-grade-qa-design.md` (Increment 2 + "Settled" sections). Depends on Increment 1 plan `docs/superpowers/plans/2026-11-09-ship-qa-increment-1-census-ship-profile.md` for: `effective-config.json` (Task 3 there), `data-policy.sh` (Task 10), `journeys.sh status` (Task 2), `coverage.json` (Task 9).

## Global Constraints

- Same as Increment 1's Global Constraints (verdict/confidence/layer enums, dual engine + `ensure_ascii=False`, qa-kit never edits engine files, no AI attribution in commits).
- Gates only ever refuse or downgrade; nothing in this plan can turn a non-pass into a pass or raise confidence.
- Plain `/qa-run` with no `oracleSource` on rows and profile `full` behaves exactly as 0.11.0 (golden tests).
- Every refusal exits 1 with a one-line message prefixed by its gate name, matching existing `EVIDENCE GATE:` style.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Oracle gate applies when the row has `fixture.expect.oracleSource` OR effective profile is `ship` and kind ∈ `computed-logic|business-rule`. | Settled #3 |
| D2 | Allowed high-confidence sources: `human`, `spec`. `spec` requires `fixture.expect.citation` = `<path>:<line>` resolving to an existing file line in the spec dir or repo. | Settled #3 |
| D3 | State gate: a `pass` on a mutating row (per existing `mutation-flag.sh`) requires `bake` or `probe` in `--kinds`. Read-only rows exempt. | spec 2b + Settled #8 |
| D4 | Data-policy gate: on `pass` of a mutating row, the `action-trace.json` typed values must pass `data-policy.sh check`; only when `gates.dataPolicy == "enforce"` in effective config. | grilling Q5 |
| D5 | Re-adjudication downgrades a disputed pass to `blocked` with `--last-action "verifier-disagrees: <reason>"`; it never upgrades. Claude Code dispatches a fresh subagent; other harnesses print a capability banner and skip. | spec 2c + Settled #6 |
| D6 | Ship verdict: `SHIP-READY` iff coverage uncovered = 0, every P1 journey `pass`, zero `fail` with layer ∈ `route|service|migration|DB` on P1 journey criteria, zero verifier overrides on P1 criteria. Otherwise `NOT SHIP-READY` with each failing condition listed. Regression line shows `not yet available` until Increment 3. | spec 2d + Goal |
| D7 | Release: engine `0.12.0`, qa-kit `0.3.0`, qa-kit dependency pinned `qa-e2e-pilot ~0.12.0`. Both increments ship in this release. | Settled #7 |

## File Structure

```
skills/checkpointing-qa-memory/scripts/checkpoint.sh       gate_oracle, gate_state, gate_data_policy
scripts/qa-verify.sh                                       mirror checks 3.6 oracle, 3.7 state, 3.8 data policy
qa-kit/scripts/check-fixtures.sh                           accepts oracleSource "spec" + citation
qa-kit/scripts/oracle-confirm.sh                           render (HTML page) / apply (decisions → checklist)
qa-kit/templates/oracle-confirm.html                       self-contained page template
skills/re-adjudicating-verdicts/SKILL.md (+ scripts/adjudication.sh)   bundle / apply
scripts/render-report.js                                   ship summary model + html/md sections
scripts/bug-export.sh                                      tracker-neutral bug export
qa-kit/commands/{qa-analyze,qa-verify}.md                  wiring
tests/{gate-oracle,gate-state,gate-data-policy,verify-ship-gates,oracle-confirm,adjudication,ship-summary,bug-export}/run.sh
release files (versions, CHANGELOG, ADRs 0032/0033, CLAUDE.md, README, persona-body, SUITES)
```

## Lanes

| Wave | Lane | Tasks | Owns files | Consumes (from) |
|---|---|---|---|---|
| 1 | F (engine gates) | 1, 2, 3, 4 | checkpoint.sh, qa-verify.sh, their tests | Inc1 T3, T10 |
| 1 | G (qa-kit oracle) | 5, 6 | check-fixtures.sh, oracle-confirm.sh, oracle-confirm.html, qa-analyze.md, tests | — |
| 1 | H (reporting) | 7, 8 | render-report.js, bug-export.sh, tests | Inc1 T2, T9 |
| 1 | I (re-adjudication) | 9 | skills/re-adjudicating-verdicts/*, qa-kit/commands/qa-verify.md, tests | F1 message format |
| 2 | J (release) | 10, 11 | persona-body, agents/, SUITES, skills.json, versions, CHANGELOG, ADRs, CLAUDE.md, README | all |

---

### Task 1: Oracle gate in checkpoint.sh   (Lane F, risk: high)

**Files:** Modify `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (new `gate_oracle`, called in `cmd_upsert` after `gate_required_kinds`, pass only). Test `tests/gate-oracle/run.sh`.
**Interfaces:** Consumes the checklist row via existing `checklist_row_for`, effective profile from `.qa/runs/<run>/effective-config.json` (`.profile`, absent file = `full`). Produces refusal message `ORACLE GATE: <criterionId> oracleSource=<value|missing> cannot ground a high-confidence pass (allowed: human, spec)`.
**Behaviour:**
- Applies per D1. `pass` + `--confidence low` is always allowed (the honest downgrade).
- `pass` + `high` with `llm-suggested` or missing (under D1 conditions) → exit 1 with the message.
- Non-pass verdicts unaffected.
- Rows outside D1 conditions unaffected (golden: 0.11.0 behaviour).
**Tests:** `llm_suggested_high_refused`, `llm_suggested_low_allowed`, `human_high_allowed`, `spec_high_allowed`, `ship_missing_source_refused`, `full_profile_missing_source_unchanged`, `fail_verdict_unaffected`, parity.
**Task gate:** `bash tests/gate-oracle/run.sh && bash tests/checkpoint/run.sh`

### Task 2: State gate   (Lane F, risk: high)

**Files:** `checkpoint.sh` (`gate_state`). Test `tests/gate-state/run.sh`.
**Exact values:** message `STATE GATE: <criterionId> is mutating; a pass needs bake or probe evidence (got: <kinds>)`.
**Behaviour:** per D3, using existing `mutation-flag.sh` on the row; runs only for `pass`; `--nonui-reason` does not bypass it.
**Tests:** `mutating_humanaction_only_refused`, `mutating_with_bake_allowed`, `mutating_with_probe_allowed`, `readonly_dom_only_allowed`, `nonui_reason_no_bypass`.
**Task gate:** `bash tests/gate-state/run.sh && bash tests/checkpoint/run.sh`

### Task 3: Data-policy gate   (Lane F, risk: normal)

**Files:** `checkpoint.sh` (`gate_data_policy`). Test `tests/gate-data-policy/run.sh`.
**Interfaces:** Consumes `scripts/data-policy.sh check <config> @<evidence/.../action-trace.json>` (Increment 1 Task 10), resolved relative to the engine root.
**Exact values:** message `DATA POLICY GATE: <criterionId> typed data violates dataPolicy: <rule>=<match>`.
**Behaviour:** per D4; when `data-policy.sh` is absent (older install) → note on stderr, no refusal; violations list only the first 3. For rows of kind `input-validation` (values deliberately invalid), `date-window` and `email-domain` violations are ignored; `forbidden-marker` still applies.
**Tests:** `forbidden_marker_refused`, `clean_data_allowed`, `gate_off_when_not_enforce`, `missing_script_degrades_with_note`, `input_validation_past_date_allowed`.
**Task gate:** `bash tests/gate-data-policy/run.sh`

### Task 4: Mirror gates in qa-verify.sh   (Lane F, risk: high)

**Files:** Modify `scripts/qa-verify.sh` (new checks 3.6 oracle, 3.7 state, 3.8 data policy, each overriding to `fail`/`high` with reason `oracle-ungrounded|no-state-evidence|data-policy-violation`). Test `tests/verify-ship-gates/run.sh`.
**Behaviour:** catches records written by an older checkpoint or a bypassed gate; same conditions as Tasks 1–3; existing verification.json shape unchanged (new `reasons` strings only).
**Tests:** `verify_overrides_llm_high_pass`, `verify_overrides_mutating_without_state`, `verify_overrides_policy_violation`, `verify_legacy_full_run_unchanged` (golden from an existing fixture run).
**Task gate:** `bash tests/verify-ship-gates/run.sh && bash tests/qa-verify/run.sh`

### Task 5: `spec` oracle source in check-fixtures   (Lane G, risk: normal)

**Files:** Modify `qa-kit/scripts/check-fixtures.sh`. Test: extend `tests/check-fixtures/run.sh`.
**Behaviour:** `oracleSource:"spec"` requires `citation` matching `^[^:]+:[0-9]+$` whose file exists (relative to the checklist's spec dir, then repo root) and has at least that many lines; output `sources` gains `spec` count.
**Tests:** `spec_with_valid_citation_ok`, `spec_missing_citation_missing`, `spec_citation_bad_line_missing`, `sources_counts_spec`.
**Task gate:** `bash tests/check-fixtures/run.sh`

### Task 6: Oracle confirmation page   (Lane G, risk: normal)

**Files:** Create `qa-kit/scripts/oracle-confirm.sh`, `qa-kit/templates/oracle-confirm.html`; modify `qa-kit/commands/qa-analyze.md`. Test `tests/oracle-confirm/run.sh`.
**Interfaces:**
- `oracle-confirm.sh render <checklist.json> <out.html>` — groups rows with `oracleSource != human|spec` by `fixture.expect.rule` (fallback: `<kind>:<fixture.expect.path>`); page shows per group: rule, criterion ids, inputs, proposed value, and per-row accept / edit (value) / unknown, with "apply to whole group". A "Save decisions" button downloads `oracle-decisions.json` `[{criterionId, decision:"accept"|"edit"|"unknown", value?}]`. No network calls; works from `file://`.
- `oracle-confirm.sh apply <checklist.json> <oracle-decisions.json>` → writes checklist in place (backup `checklist.json.bak`): accept → `oracleSource:"human"`; edit → new `value` + `human`; unknown → unchanged. Prints `{accepted, edited, unknown, unmatched:[ids]}`.
**Behaviour:** `/qa-analyze` renders the page when any computed row is unconfirmed, tells the human the path, and re-runs `check-fixtures.sh` after `apply`. Under `autonomousSetup` it skips the page and reports the unconfirmed count.
**Tests:** `render_groups_by_rule`, `render_no_external_urls` (grep `http` in output = 0 outside comments), `apply_accept_edit_unknown`, `apply_reports_unmatched`, `arabic_values_roundtrip`.
**Task gate:** `bash tests/oracle-confirm/run.sh`

### Task 7: Ship summary in the report   (Lane H, risk: normal)

**Files:** Modify `scripts/render-report.js` (`buildModel` adds `ship`; new `htmlShip(m)` / md block rendered first in both outputs). Test `tests/ship-summary/run.sh` (node-driven; fixtures = run dirs with `coverage.json`, `journeys.json`, `checkpoint.json`, `verification.json`).
**Interfaces:** Consumes `coverage.json` + `journeys.json` in the run dir; computes journey verdicts with the same rule as `journeys.sh status` (reimplemented in JS; the test asserts equality with `journeys.sh status` output on the same fixture).
**Exact values:** heading `Ship readiness`; verdict strings `SHIP-READY` / `NOT SHIP-READY`; rows: `Census coverage`, `P1 journeys`, `Coding-layer fails on P1`, `Verifier overrides on P1`, `Low-confidence passes`, `Flaky`, `Regression suite` (`not yet available`).
**Behaviour:** per D6; missing `coverage.json` → `Census coverage: unknown` and verdict `NOT SHIP-READY`; missing `journeys.json` → `P1 journeys: none declared` and `NOT SHIP-READY`; runs without either file and profile ≠ ship render no ship section (golden unchanged).
**Tests:** `ship_ready_all_green`, `uncovered_not_ready`, `p1_service_fail_not_ready`, `fe_fail_still_ready` (FE fail on P1 listed but not blocking), `missing_coverage_unknown`, `non_ship_run_golden_unchanged`, `journey_status_matches_shell`, `superseded_verdict_used`.
**Task gate:** `bash tests/ship-summary/run.sh && bash tests/render-report/run.sh`

### Task 8: Tracker-neutral bug export   (Lane H, risk: normal)

**Files:** Create `scripts/bug-export.sh`. Test `tests/bug-export/run.sh`.
**Interfaces:** `bug-export.sh <run-dir> --out <dir> [--known-defects <registry>] [--today YYYY-MM-DD]` → `<dir>/bugs.json` `[{id, title, severity, layer, criterionId, journeyId?, persona, steps, expected, actual, evidence:[paths], duplicateOf?}]` and one `<dir>/<id>.md` per bug; prints `{exported, duplicates, skipped}`.
**Behaviour:** source = `bug-log.json` (all three accepted shapes) plus verifier overrides lacking a bug entry; a bug whose `surface` + criterion matches an `outstanding` known defect gets `duplicateOf` and is not written as a new `.md`; markdown body uses plain business language sections `What happened`, `What should happen`, `Steps`, `Evidence` (no criterion jargon in titles); severity defaults: layer ∈ route|service|migration|DB → `high`, FE → `medium`, unless bug-log sets it.
**Tests:** `exports_bug_log_shapes`, `verifier_override_becomes_bug`, `known_defect_dedup`, `expired_known_defect_not_dedup`, `empty_bug_log_exports_zero`, `arabic_title_parity`.
**Task gate:** `bash tests/bug-export/run.sh`

### Task 9: Independent re-adjudication   (Lane I, risk: high)

**Files:** Create `skills/re-adjudicating-verdicts/SKILL.md`, `skills/re-adjudicating-verdicts/scripts/adjudication.sh`; modify `qa-kit/commands/qa-verify.md`. Test `tests/adjudication/run.sh`.
**Interfaces:**
- `adjudication.sh select <run-dir>` → ids to re-judge: every `pass` with `confidence: low`, plus every `fail` tagged by UX promotion (`kinds` contains no `bake|computed|probe` and row kind is a UX criterion).
- `adjudication.sh bundle <run-dir> <criterionId> <out-dir>` → copies the checklist row, `evidence/**/<crit>/*` (artifacts + screenshots), and identity.json; excludes `journal.ndjson`, `toolstream.jsonl`, and any agent prose (`lastAction`).
- `adjudication.sh apply <run-dir> <decisions.json>` with `[{criterionId, persona, agree:bool, reason}]` → for `agree:false` on a `pass`, calls `checkpoint.sh <run> <crit> blocked --confidence low --persona <p> --last-action "verifier-disagrees: <reason>" --phase adjudicate`; any decision that would raise a verdict or confidence → exit 1 `ADJUDICATION: upgrades are not allowed`.
**Behaviour (SKILL):** for each selected id, dispatch a fresh-context subagent with only the bundle dir and the rubric "judge from persisted state and network evidence; screenshots are supporting; answer agree/disagree + one-line reason"; collect decisions; `apply`. Non-Claude harness: print `re-adjudication unavailable on <harness>; <n> low-confidence passes unreviewed` and exit 0. `plan-guard.sh` has no phase allow-list, so `--phase adjudicate` needs no change there.
**Tests:** `select_low_conf_passes`, `bundle_excludes_journal_and_prose`, `apply_disagree_downgrades_to_blocked`, `apply_upgrade_refused`, `apply_agree_noop`, `apply_unknown_criterion_rejected` (entry skipped and reported, other entries still applied).
**Task gate:** `bash tests/adjudication/run.sh`

### Task 10: Release integration (both increments)   (Lane J, risk: normal)

**Files:** `core/persona-body.md` (phase verify: call re-adjudication after the run, bug-export at report) → regenerate root agent/commands via `scripts/build-adapter.sh claude`; SUITES in `scripts/run-engine-ci.sh` (`gate-oracle gate-state gate-data-policy verify-ship-gates ship-summary bug-export adjudication`) and `qa-kit/scripts/run-qakit-ci.sh` (`oracle-confirm`); `scripts/skills.json` (`re-adjudicating-verdicts`, category `verify`); `CLAUDE.md` (19 skills; invariant: gates only refuse/downgrade; oracle/state/data-policy gates); `README.md`; `CHANGELOG.md` (engine 0.12.0, qa-kit 0.3.0 entries covering Increments 1+2); `docs/adr/0032-trusted-verdict-gates.md`, `docs/adr/0033-independent-re-adjudication.md`; versions per D7 in `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (metadata + both entries), `scripts/skills.json`, `qa-kit/.claude-plugin/plugin.json` (+ `dependencies` pin `qa-e2e-pilot ~0.12.0`).
**Tests:** `bash scripts/validate-adapters.sh`, `bash scripts/check-suite-coverage.sh`.
**Task gate:** `bash scripts/run-engine-ci.sh && bash qa-kit/scripts/run-qakit-ci.sh`

### Task 11: Milestone — recall benchmark on real bugs   (Lane J, risk: data)

**Files:** Create `docs/benchmarks/2026-11-hackathons-recall.md` (results only; the benchmark key lives outside the run so the agent can't read it).
**Exact values:** target build `cdc3441cf` of the innovation project in a disposable copy; key = the 53 defect ids from `.qa/runs/20261029T052020-hackathons-lifecycle-v2/bug-log.json` + `.qa/runs/20261101T094003-hackathons-lifecycle-i1-judging/bug-log.json` (innovation repo). Pass bar: recall ≥ 85% (≥ 46 of 53 matched) and precision ≥ 90%.
**Behaviour:** operator-run (needs the app environment): install engine 0.12.0/qa-kit 0.3.0 from the branch, run `/qa-constitution` → `/qa-spec` (profile ship) → `/qa-scenarios` → `/qa-analyze` → `/qa-run` against the pre-fix build without giving the agent the key; then match findings to the key by a human-reviewed mapping table (finding id → defect id | new | false positive). Below the bar → do not release; file the misses as plugin issues by class (which detector/generator should have caught it).
**Task gate:** recall/precision table committed with the mapping.

---

## Review Focus

1. **Legacy runs replayed through new qa-verify** (an existing 0.11.0 run dir) must not suddenly fail — gates only apply under D1/D3/D4 conditions; pinned by Task 4 `verify_legacy_full_run_unchanged`.
2. **Re-adjudicator returns garbage** (missing persona, unknown criterion id) → `apply` must refuse that entry and report it, never write a partial downgrade to the wrong persona; add `apply_unknown_criterion_rejected` to Task 9.
3. **Data policy false positives** in legitimate words ("contest", "attestation", Arabic words containing a marker substring) → whole-word Latin matching; pinned in Inc1 Task 10 `contest_not_flagged`. Arabic markers match as substrings by design, so the default list holds no Arabic entries; Arabic markers are user-configured only.
4. **Confirmation page opened offline / from a file share** → no network, no external fonts/scripts; pinned by Task 6 `render_no_external_urls`.
5. **Ship summary when a P1 journey criterion was superseded** (ADR-0029: a later verdict replaces an earlier one) → journey status must use the authoritative verdict; add `superseded_verdict_used` to Task 7.
