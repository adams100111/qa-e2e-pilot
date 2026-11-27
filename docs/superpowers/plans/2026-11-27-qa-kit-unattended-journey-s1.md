# qa-kit unattended journey (stage 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sdd-lanes:sdd-lanes` to implement this plan
> task-by-task (plan-lite format). Tests are written first.

**Goal:** `/qa-auto <target>` drives constitution → spec → scenarios → analyze → run → verify with
no stops, records every self-answered question, audits its own limits from files, and ends with a
handoff list.

**Architecture:** One new script, `qa-kit/scripts/auto.sh`, owns the journey files under
`.qa/specs/<target>/auto/` and decides order, limits and the result from files only. One new
command source, `qa-kit/core/commands/qa-auto.md`, loops over `auto.sh next` and follows the
existing step commands. The engine is not touched.

**Tech Stack:** bash 3.2, jq with a python3 fallback (`QA_ENGINE=jq|python3`, as `auto-seed.sh`
does), dual-engine bash tests.

**Spec:** `docs/superpowers/specs/2026-11-27-qa-kit-unattended-journey-design.md` (read it first;
D1 to D9 refer to it). Stage 2 (the headless runner) is not in this plan.

**Prerequisite:** the ClickUp plan `2026-11-27-qa-kit-clickup-spec-tracking-r1.md` has landed
(qa-kit 0.5.0): `tracker.sh spec-status`, `spec-note`, `specDefaults`.

## Global Constraints

- No file under `core/`, root `commands/`, `skills/`, `scripts/`, `agents/` or `qa-verify.sh`
  changes (ADR-0022). `bash scripts/validate-adapters.sh` still passes.
- A qa-kit script cannot call an engine script. Where `auto.sh` needs an engine script's result
  (pre-flight, `known-defects.sh validate`, `data-policy.sh list`), the command runs it and passes
  the result in as a file or flag; where the result is a gate, `auto.sh` reads the engine's output
  file itself and does not take the agent's word.
- `auto.sh` never edits `.qa/config.json`, `run-config.json`, `checklist.json`, the known-defect
  registry or anything outside `.qa/specs/<target>/auto/`.
- Nothing may turn a non-pass into a pass or raise a confidence (ADR-0032, ADR-0033).
- Every verb gives the same output under `QA_ENGINE=jq` and `QA_ENGINE=python3`.
- The word in docs and messages is "unattended journey", never bare "autonomous" (`CONTEXT.md`).
- Command sources are edited in `qa-kit/core/commands/` and regenerated (ADR-0024).
- Commits: Conventional Commits, no attribution lines. No destructive git commands.
- Gates: task = `bash tests/qa-auto/run.sh; echo rc=$?`; lane = the same plus
  `bash tests/qakit-adapters/run.sh`; milestone = `bash qa-kit/scripts/run-qakit-ci.sh &&
  bash scripts/validate-adapters.sh && bash scripts/check-suite-coverage.sh`.

## Decisions

| # | Decision | Why |
|---|---|---|
| J1 | Steps, in order: `constitution`, `spec`, `scenarios`, `analyze`, `run`, `verify`. States: `pending`, `running`, `done`. Journey state: `open`, `done`, `stopped`. | D1 |
| J2 | Stop reasons: `time-limit`, `step-failed`, `until` (resumable with `auto.sh resume`); `blocked`, `audit`, `no-sign-in`, `tracker` (not resumable; a new journey is needed after a person acts). | D2 |
| J3 | `journey.json`: `{version:1, target, profile, startedAt, deadline, until, steps:[{name,state}], analyzeRounds, runId, state, stop:{reason,detail}\|null, endedAt}`. | left to builder; fixed here |
| J4 | `decisions.json`: array of `{id:"D<n>", step, class, question, answer, evidence, confidence, criteria:[], assumption:true, needsPerson, second:null\|"stands"\|"ask", secondReason}`. | D3 |
| J5 | Decidable classes: `roles`, `surface-access`, `scope`, `role-overrides`, `journeys`, `inputs`, `expected`, `gaps`. Forbidden classes: `seed`, `exclusion`, `crawl-only`, `oracle-human`, `safety`, `known-defect`. | D3, D4 |
| J6 | Safety keys (dot paths in `.qa/config.json`): `allowApiWrites`, `seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, `gates`, `profile`, `humanInteraction.enforce`, `humanInteraction.maxOptOutRate`. | D4 |
| J7 | Production = `environment == "production"`, or `environment == "auto"` with a non-local `baseUrl` and an empty or `QA_DISPOSABLE_ENV` `seedableEnvMarker` (the rule `auto-seed.sh` mirrors). Local hosts: `localhost`, `127.0.0.1`, `[::1]`, `*.localhost`, `*.test`, `*.local`, `*.ddev.site`. | D2 |
| J8 | The engine's ship verdict is read from the run's `report.md`: a line containing `NOT SHIP-READY` → not ready; else one containing `SHIP-READY` → ready; neither → none. | J-constraint: files, not the agent's word |
| J9 | Result values: `ready`, `not confirmed`, `not ready`, `verified`, `not verified`, `stopped`. | D6 |
| J10 | The second look is rendered per harness by a new token `{{SECOND_LOOK}}` from a new `secondLook` string in `qa-kit/harness-profiles.qakit.json`: the dispatch instruction on Claude, the unavailable banner elsewhere. | D3, D7 |
| J11 | Version: qa-kit `0.6.0`. | new feature |

## File Structure

| File | Responsibility |
|---|---|
| `qa-kit/scripts/auto.sh` (create) | all journey verbs |
| `tests/qa-auto/run.sh`, `tests/qa-auto/fixtures/` (create) | dual-engine tests over fixture projects |
| `qa-kit/core/commands/qa-auto.md` (create) | the command |
| `qa-kit/core/commands/qa-{constitution,spec,scenarios,analyze,status}.md` (modify) | the open-journey line; status line |
| `qa-kit/harness-profiles.qakit.json`, `qa-kit/scripts/build-qakit-adapter.sh` (modify) | `{{SECOND_LOOK}}` |
| `qa-kit/commands/*` (regenerated), harness install files that list commands | generated |
| `qa-kit/scripts/run-qakit-ci.sh` (modify) | enrol `qa-auto` |
| `docs/adr/0035-unattended-journey.md`, `CONTEXT.md`, `qa-kit/README.md`, `CLAUDE.md`, `CHANGELOG.md`, version sites | docs and release |

## Lanes

| Wave | Lane | Tasks | Owns files | Consumes (from) |
|---|---|---|---|---|
| 1 | A | 1, 2, 3, 4, 5 | `auto.sh`, `tests/qa-auto/`, `run-qakit-ci.sh` | — |
| 1 | B | 6 | `qa-auto.md`, the other command sources, profiles, `build-qakit-adapter.sh`, generated commands, adapter tests | verb names and outputs below |
| 2 | C | 7 | ADR, CONTEXT, README, CLAUDE.md, CHANGELOG, versions | all |

Shared interface for lanes A and B (`T` = `<target>`; every verb takes `--project <dir>`, default `.`):

```
auto.sh start T [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]
auto.sh resume T [--max-hours <n>]
auto.sh next T                      -> one JSON line: {"next":"<step>"} | {"next":"done"} | {"next":"stopped","reason":…,"detail":…}
auto.sh step-start T <step>
auto.sh step-done T <step> [--run <run-id>]
auto.sh signin T                    -> {"ok":[…],"missing":[…]}
auto.sh decide T --step <s> --class <c> --question <q> --answer <a> --evidence <e|none> --confidence high|low [--criteria id,id]
auto.sh second T <decision-id> stands|ask --reason <r>
auto.sh second T --unavailable
auto.sh stop T --reason <J2 reason> --detail <text>
auto.sh audit T                     -> {"ok":bool,"violations":[…]}; exit 1 when not ok
auto.sh handoff T [--records <file>] -> writes handoff.md; prints {"result":…,"needsPerson":n}
auto.sh status T                    -> journey.json plus {"needsPerson":n}; read-only
```

Exit codes: 0 ok; 1 refused or failed (one line on stderr, `auto: <reason>`); 2 usage.

---

### Task 1: `start`, `resume`, `status`, `stop`   (Lane A, risk: high)

**Files:** Create `qa-kit/scripts/auto.sh`, `tests/qa-auto/run.sh`, `tests/qa-auto/fixtures/`.
Modify `qa-kit/scripts/run-qakit-ci.sh` (add `qa-auto` to `SUITES`).

**Exact values:** refusal lines (stderr, exit 1):
- `auto: no .qa/config.json; set the project up first`
- `auto: this environment is production; an unattended journey does not run there`
- `auto: another journey is open for <other target>`
- `auto: a journey is already open for <target>; continue it or pass --restart`
- `auto: the environment is shared and gates.dataPolicy is not enforce`
- `auto: .qa/known-defects.json is not valid` (when `--known-defects-invalid` is passed by the command)

Default `--max-hours` is `6`.

**Behaviour:**
- `start` writes `baseline.json` then `journey.json` (J3) and creates `auto/`. The lock for "one
  journey per project" is the existence of any `.qa/specs/*/auto/journey.json` with `state: open`.
- `baseline.json` holds: the J6 values from `.qa/config.json`; the ids of `checklist.json` rows
  whose `fixture.expect.oracleSource` is `human`; whether `seed.json` exists; the entries of
  `coverage-exclusions.json`; a hash of `.qa/known-defects.json`; the J6 keys present in the
  spec's `run-config.json`; the launch `profile`.
- Steps whose artifact already exists start as `done` for `constitution`, `spec`, `scenarios`
  (artifact rules in Task 2); `analyze`, `run`, `verify` always start `pending`.
- A finished journey (`done` or `stopped` with a non-resumable reason) is moved to
  `auto/history/<n>/` by the next `start`. `--restart` does the same to an open one.
- `resume` clears a resumable stop and sets a new deadline; on any other state it refuses with
  `auto: nothing to resume`.
- `stop` records J2 reasons only; an unknown reason is a usage error.
- `status` prints and writes nothing.

**Tests (write first; each runs under both engines):**
- `start_writes_journey_and_baseline` — fixture project → both files, six steps, `state: open`.
- `start_refuses_production` — `environment: production`; and `auto` + `https://app.example.sa` + empty marker.
- `start_allows_local_auto` — `environment: auto`, `http://shop.ddev.site` → ok.
- `start_refuses_shared_without_data_policy` — non-local, disposable marker set, `gates.dataPolicy` absent.
- `start_refuses_second_journey` — another target open.
- `start_refuses_open_same_target_without_restart`; `restart_moves_to_history`.
- `existing_spec_marks_steps_done` — fixture with `qa-spec.md`, `spec-roles.json` → `spec: done`.
- `baseline_records_existing_human_rows_and_exclusions`.
- `resume_only_after_resumable_stop`; `stop_rejects_unknown_reason`.
- `finished_journey_archived_on_next_start`.

### Task 2: `next`, `step-start`, `step-done`, `signin`   (Lane A, risk: high)

**Files:** Modify `auto.sh`, `tests/qa-auto/`.

**Exact values:** artifacts per step (the checks `/qa-status` makes):
- `constitution`: `.qa/constitution.state.json`
- `spec`: `.qa/specs/T/qa-spec.md` and `spec-roles.json`
- `scenarios`: `.qa/specs/T/scenarios.md` and `checklist.json`
- `analyze`: `.qa/specs/T/analysis.md`, not older than `checklist.json`
- `run`: `.qa/runs/<run-id>/run-manifest.json` and `checkpoint.json`
- `verify`: `.qa/runs/<run-id>/verification.json`

**Behaviour:**
- `next` returns the first step not `done`. Before that it returns `stopped` / `time-limit` when
  the deadline has passed, and `stopped` / `until` when the step after `--until` would be next.
- `step-done` refuses when the artifact is missing: `auto: <step> has no result yet`.
  `step-done T run --run <id>` records `runId`.
- After `analyze` is done: when `analysis.md`'s `## Verdict` is `BLOCKED`, `scenarios` and `analyze`
  go back to `pending` and `analyzeRounds` increases; at `analyzeRounds == 2` the journey becomes
  `stopped` / `blocked` instead.
- When every step is `done`, `next` returns `done` and the journey state becomes `done`.
- `signin` reads the personas from `.qa/config.json` and reports which have their sign-in
  configured (the persona auth fields as `.qa/config.json.example` and the
  `discovering-user-roles` skill define them; read both, read-only; presence of the named file or
  entry only). With none configured it stops the journey `no-sign-in`.
- `next` on a stopped journey repeats the stop; it never advances.

**Tests:** `next_walks_six_steps`; `step_done_requires_artifact`; `stale_analysis_is_not_done`;
`blocked_analysis_reopens_scenarios_once`; `blocked_twice_stops_blocked`; `deadline_stops_time_limit`
(journey with a past `deadline`); `until_scenarios_stops_before_analyze`; `signin_partial_lists_missing`;
`signin_none_stops`; `next_after_stop_does_not_advance`; `all_done_sets_state_done`.

### Task 3: `decide` and `second`   (Lane A, risk: normal)

**Files:** Modify `auto.sh`, `tests/qa-auto/`.

**Exact values:** refusal for a forbidden class:
`auto: <class> is never decided by an unattended journey`. Unknown class: usage error.

**Behaviour:**
- `decide` appends a J4 record with the next id, `assumption: true`, `needsPerson: false`, and
  prints the id. `--evidence none` is stored as `evidence: null` and sets `needsPerson: true`.
- `--confidence low` does not set `needsPerson` by itself; `second` does.
- `second T <id> ask` sets `second: "ask"`, `needsPerson: true`. `stands` sets `second: "stands"`
  and never clears a `needsPerson` that is already true.
- `second T --unavailable` marks every decision with `confidence: low` and `second: null` as
  `needsPerson: true`, and records `secondLook: "unavailable"` in `journey.json`.
- A decision can be recorded only while the journey is `open`.

**Tests:** `decide_appends_with_id`; `decide_refuses_each_forbidden_class` (six);
`evidence_none_needs_person`; `second_ask_sets_needs_person`; `second_stands_never_clears`;
`second_unavailable_marks_low_confidence`; `decide_refused_on_closed_journey`.

### Task 4: `audit`   (Lane A, risk: high)

**Files:** Modify `auto.sh`, `tests/qa-auto/`.

**Exact values:** violation codes: `safety-setting-changed:<key>`, `run-config-safety:<key>`,
`human-oracle-added:<criterion id>`, `seed-added`, `exclusion-added`, `known-defects-changed`,
`forbidden-decision:<id>`, `step-without-result:<step>`, `not-verified`, `tracker-behind`.
The ClickUp check runs `${QA_AUTO_TRACKER_CMD:-bash <qa-kit>/scripts/tracker.sh} spec-status --spec T`.

**Behaviour:**
- Each violation in D5 maps to one code above; all are collected, none short-circuits.
- `run-config-safety` ignores `profile` when it equals the launch profile in the baseline.
- `tracker-behind` only when the tracker command reports the spec as set up and `behind: true`;
  a `not-set-up` answer is not a violation; a tracker command that fails is `tracker-behind`.
- A journey stopped before `verify` is audited without `not-verified` and `step-without-result`
  for the steps it never reached.
- A failed audit sets the journey `stopped` / `audit` with the codes in `detail`.

**Tests:** one per code (ten), built by mutating a clean finished fixture;
`clean_journey_passes`; `launch_profile_is_not_a_violation`; `untracked_spec_skips_tracker_check`
(stub tracker prints `SKIP\tnot-set-up`); `tracker_failure_is_violation`;
`early_stop_audited_without_verify_checks`; `two_violations_both_reported`.

### Task 5: `handoff`   (Lane A, risk: high)

**Files:** Modify `auto.sh`, `tests/qa-auto/`.

**Exact values:** first line when any decision has `evidence: null`:
`No written requirements were found for this target. Expected results were taken from the application and need a person.`
Section titles, in order: `Result`, `Scope chosen for this spec`, `Decided without a person`,
`Needs a person`, `Records created`, `How to confirm`. Result sentences: `Ready.`;
`Not confirmed: <n> items need a person.`; `Not ready: <reasons>.`; `Verified.`; `Not verified.`;
`Stopped: <plain reason>.` Plain stop reasons: `time-limit` → `the time limit was reached`;
`step-failed` → `a step could not be completed`; `until` → `it was asked to stop before the run`;
`blocked` → `coverage could not be reached`; `audit` → `a limit was broken: <codes>`;
`no-sign-in` → `no role has sign-in set up`; `tracker` → `ClickUp could not be updated`.

**Behaviour:**
- Result rule (J8, J9): stopped → `stopped`. Launch profile without a ship verdict in
  `report.md` → `verified` when `verification.json` exists with no override that turned a pass
  into a non-pass, else `not verified`. Ship verdict not ready → `not ready` with the report's
  listed conditions. Ship verdict ready → `ready` unless a P1 check rests on a person: a decision
  with `needsPerson` and empty `criteria`, or with a `criteria` id whose checklist row is P1, or a
  P1 `computed-logic|business-rule` row whose `oracleSource` is not `human` or `spec`; then
  `not confirmed`.
- `Needs a person` lists: `needsPerson` decisions; proposal-only expected values; checks that
  passed at low confidence (from the run's files); personas missing sign-in; a seed command that
  was proposed and not run; checks left out because they assert an application failure.
- `Records created` comes from `--records <file>` (the command passes the engine's
  `data-policy.sh list` output); absent or empty → `None recorded.`
- `How to confirm` names `oracle-confirm.sh render`, `surface-access.sh confirm-table`, and
  `/qa-auto <target>` again.
- The file is plain text for people: no criterion ids in sentences (titles from
  `tracker-cards.json` when it exists, else the checklist row's own title).
- It prints `{"result", "needsPerson"}` and can be run more than once; the last write wins.

**Tests:** `ready_when_ship_ready_and_nothing_pending`; `not_confirmed_when_p1_rests_on_proposal`;
`not_confirmed_when_spec_wide_decision_needs_person`; `ready_when_only_p2_needs_person`;
`not_ready_lists_conditions`; `verified_under_full_profile`; `not_verified_without_verification`;
`stopped_time_limit_sentence`; `no_requirements_opening_line`; `records_listed`;
`no_records_sentence`; `sections_in_order`; `never_better_than_engine` (report says NOT SHIP-READY,
no pending items → `not ready`).

### Task 6: The command and the second look   (Lane B, risk: high)

**Files:** Create `qa-kit/core/commands/qa-auto.md`. Modify
`qa-kit/core/commands/qa-{constitution,spec,scenarios,analyze,status}.md`,
`qa-kit/harness-profiles.qakit.json`, `qa-kit/scripts/build-qakit-adapter.sh`; regenerate
`qa-kit/commands/`; update the harness install files and `tests/qakit-adapters/run.sh`,
`tests/qakit-install/run.sh`, `tests/qa-kit-phases/run.sh` where they list or count commands.

**Exact values:**
- Frontmatter: `description: Drive the whole qa-kit process for a target with nobody present, record every self-answered question, and end with a handoff list for a person.`
  `argument-hint: "<target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]"`
- The line added to the four step command sources: `An open unattended journey for this target
  (`bash {{PLUGIN_ROOT}}/scripts/auto.sh status <target>` shows `state: open`) counts as
  `autonomousSetup` on for this step. Record each answer you give in place of a person with
  `auto.sh decide`.`
- Banner when the second look is unavailable: `SECOND LOOK UNAVAILABLE: this harness cannot start
  a fresh agent; every low-confidence decision is left for a person.`

**Behaviour (the command source says, in order):**
- Keep the machine awake for the journey (`caffeinate -dimsu` on macOS) and release it at the end.
- Run the engine's `known-defects.sh validate` when the registry exists; then `auto.sh start` with
  the flags (and `--known-defects-invalid` if it failed). On refusal, print the line and end. If a
  resumable journey exists, `auto.sh resume`.
- Run the engine's pre-flight; a dead application → `auto.sh stop --reason step-failed`.
- Loop: `auto.sh next` → `step-start` → follow that step's own command source (never a second
  copy of its instructions) under the rules of spec D3 and D4, recording each answer with `decide`
  → `step-done` → next. After `constitution` (or at the first step if it was already done) run
  `auto.sh signin`. A step that fails is redone once, then `stop --reason step-failed`.
- The launch `--profile` is passed to the spec step, which writes it to the spec's run-config as
  `/qa-spec` does today; the command never chooses a profile and never changes one that exists.
- D3's answer rules per class, verbatim in meaning, including "when unsure whether a journey is
  P1, mark it P1" and "never `oracleSource: human`".
- D4's table as a list of things not to do, each with what happens instead.
- After `spec` and after `scenarios`: `{{SECOND_LOOK}}`. On Claude it dispatches one fresh agent
  with only that step's decisions (from `decisions.json`), their evidence and the step's artifact;
  the agent answers `stands` or `ask a person` with a reason per decision; the command records each
  with `auto.sh second`. It never includes the conversation, and the acting agent never reviews
  its own decisions. Elsewhere it prints the banner and runs `auto.sh second <target> --unavailable`.
- The `run` step follows the engine's run command including its end-of-run order (verify,
  re-adjudication, verify, bug export, render). An interrupted run continues with the engine's
  resume, never a new run.
- A required ClickUp step that fails → `stop --reason tracker`.
- End, always: `auto.sh audit`; the engine's `data-policy.sh list` into a temp file;
  `auto.sh handoff --records <file>`; on a tracked spec one `tracker.sh spec-note` built from the
  fixed sentence `<n> items need a person's review. See the results page.` (or `Nothing needs a
  person's review.`); then print the handoff's Result section and the path of `handoff.md`.
- `qa-status` gains: an open or stopped journey's step, stop reason and count of items for a person.

**Tests:** adapter suites pass after regeneration; assertions that `qa-auto.md` renders for all
four harnesses with no residual `{{`; that the Claude render contains the dispatch instruction and
the other three contain the banner; that each of the four step sources contains the open-journey
line; that the command count in the install tests matches.

**Task gate:** `bash tests/qakit-adapters/run.sh; echo rc=$?` and `bash tests/qakit-install/run.sh; echo rc=$?`
and `bash tests/qa-kit-phases/run.sh; echo rc=$?`

### Task 7: Docs and release   (Lane C, risk: normal)

**Files:** Create `docs/adr/0035-unattended-journey.md`. Modify `CONTEXT.md`, `qa-kit/README.md`,
`CLAUDE.md`, `CHANGELOG.md`, `qa-kit/.claude-plugin/plugin.json`, the qa-kit entry in
`.claude-plugin/marketplace.json`, `qa-kit/core/persona-body.md` (the agent's list of steps, then
regenerate), and the spec's status line.

**Behaviour:**
- ADR-0035: the state machine on disk; the open journey as the setup signal (no config edit);
  the never-decided list and the file audit; the stricter result; QA only.
- `CONTEXT.md`: the term **unattended journey**, with "Avoid: autonomous mode, auto mode".
- `CLAUDE.md`: one invariant, "An unattended journey never decides seed, exclusion, crawl-only,
  human oracle, safety settings or the known-defect registry; `auto.sh audit` fails the journey
  if any changed", plus `auto.sh` in the script list and the suite count.
- Version `0.6.0` in every qa-kit site. Milestone gate passes.

## Review Focus

Each is pinned by a test in the task named.

1. The journey is interrupted and started again: it continues, it does not start over — Task 1
   `start_refuses_open_same_target_without_restart`, Task 2 `next_after_stop_does_not_advance`,
   `deadline_stops_time_limit`.
2. A person already wrote the spec or has exclusions: nothing is regenerated and their choices are
   not reported as violations — Task 1 `existing_spec_marks_steps_done`,
   `baseline_records_existing_human_rows_and_exclusions`.
3. The agent loosens something to get further: the audit catches it from files — Task 4, one test
   per code.
4. The result reads better than it is: never better than the engine's, and "not confirmed" while
   a top-priority check rests on the agent alone — Task 5 `never_better_than_engine`,
   `not_confirmed_when_p1_rests_on_proposal`.
5. The project is on a shared or production environment, or has no sign-in for any role: it
   refuses or stops with one plain line — Task 1 refusal tests, Task 2 `signin_none_stops`.
