# QA Tracker (phases 1–2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `sdd-lanes:sdd-lanes` to execute this plan
> task by task. It is written in plan-lite format.

**Goal:** Give qa-kit a `/qa-tracker` setup and a `tracker.sh` that mirror the local QA store
(catalog cases, runs, results, bugs) into local files or ClickUp, using five idempotent operations.

**Architecture:**
- One python3 package, `qa-kit/scripts/trackers/`, holds the logic.
- `core.py` is pure: config, catalog, roll-ups, hashes, fingerprints and outbound filters.
- One adapter module per backend.
- `cli.py` dispatches the verbs, and `qa-kit/scripts/tracker.sh` is the entry point.
- The ClickUp adapter talks through an injectable transport. Tests replay recorded responses and
  never call the live API.

**Tech stack:**
- Python ≥ 3.9, stdlib only (urllib, json, hashlib, argparse, unittest). There is no `tomllib`
  and no third-party package.
- YAML is read through `yaml` (PyYAML) when it is importable. Otherwise the code falls back to a
  JSON catalog. Innovation's sync already depends on PyYAML.
- The bash wrappers follow the repo's bash 3.2 rules.

**Spec:** `docs/superpowers/specs/2026-11-10-qa-tracker-design.md`. Read D1–D7 and the owner
decisions.

## Global Constraints

- Default mode is dry run. Only `--apply` writes to the tracker or the local tracker files. Every
  verb prints one line per action, `DRY|APPLY\t<kind>\t<detail>`, then
  `SUMMARY <json counts> dry-run|apply`.
- Never delete anything, remote or local.
- Never set a case status beyond `statusCeiling`: `none` by default, or `testing`.
- Never move a bug out of `open`.
- Every string sent to a tracker passes `core.outbound(text, cfg)`:
  - redaction first;
  - then the wording check;
  - a wording hit fails that one item, with `SKIP\twording\t<id>: <word>`, and nothing is sent
    for it.
- Default forbidden words, case-insensitive and whole word: `AI`, `agent`, `agents`, `automated`,
  `automation`, `Claude`, `Playwright`, `bot`.
- The forbidden patterns, which are regexes, are fixed as follows:
  - a file path (`(?:^|\s)(?:\.{0,2}/)?[\w.-]+/[\w./-]+\.\w{1,5}\b`);
  - a branch (`\b(?:feat|fix|docs|chore)/[\w.-]+`);
  - a PR (`\bPR ?#\d+\b`).
- `refs[]`, evidence paths and run ids never appear in pushed text.
- No test calls a live tracker. ClickUp tests use `tests/qa-tracker/fixtures/clickup/*.json`
  replayed through `FakeTransport`.
- The engine is not modified. Only qa-kit, tests, docs, the CHANGELOG and the qa-kit version
  change.
- qa-kit version goes from `0.3.1` to `0.4.0`, in `qa-kit/.claude-plugin/plugin.json` and the
  qa-kit entry of `.claude-plugin/marketplace.json`.
- Commands are authored in `qa-kit/core/commands/` and regenerated into `qa-kit/commands/` with
  `qa-kit/scripts/build-qakit-adapter.sh claude`. `validate-qakit-adapters.sh` must stay green.
- Commits follow Conventional Commits and carry no AI attribution.

## Decisions

| # | Decision | Why |
|---|---|---|
| P1 | Machine config lives at `docs/agents/qa-tracker.json`, next to `docs/agents/qa-tracker.md`, not at `.qa/tracker.json` as the spec says. | `.qa/` is git-ignored, so a team would not share the ids. The spec is amended in Task 8. |
| P2 | Remote identity comes from what a person can see in the tracker: case name `TC-… · title`; run name `Run <label>`, with `label` from `--label` or `<YYYY-MM-DD> <build>`; bug custom field `Ref` holding the 12-char fingerprint. `.qa/tracker-map.json` (ignored) is only a cache of remote ids plus last-pushed hashes. | A second machine with an empty cache must not create duplicates. |
| P3 | A criterion joins a case through tag `case:<TC-id>` or field `catalogRef` (a string or list). Both are read. | The v3 run uses `catalogRef` on 143 rows. |
| P4 | A case's result in a run is the worst verdict of its criteria, ranked `fail` > `error` > `blocked` > `deferred` > `pass`. Verdicts come from `verification.json` `verifierVerdict` when present, else `checkpoint.json`. Rows that have no case are ignored. | This matches the engine's override rule. |
| P5 | Fingerprint = `sha1("<case-or-criterion>\|<persona>\|<normalised title>")[:12]`. To normalise: lowercase, strip digits, collapse non-letters to one space, trim. | The same defect on the next run then keeps the same Ref. |
| P6 | Severity maps to ClickUp priority as `critical→1`, `high→2`, `medium→3`, `low→4`. | One table, so the two can't contradict each other. |
| P7 | Guide Doc: one Doc named `QA Guide` in the folder's space, one page per `guide/*.md` file except `07*`, page name = the file's H1. `07` stays as the `Sign-off · Criterion N: …` tasks. Old `Guide · …` tasks are retired: tag `retired`, a comment pointing to the Doc, and status `skipped`. | Owner decision, 2026-11-11. |

## File Structure

| File | Responsibility |
|---|---|
| `qa-kit/scripts/tracker.sh` | Entry point: `exec python3 "$DIR/trackers/cli.py" "$@"`. Exits 1 with a clear message when python3 is below 3.9. |
| `qa-kit/scripts/trackers/core.py` | Pure helpers: config, catalog, roll-up, hashes, fingerprint, outbound filter, map cache, action log. |
| `qa-kit/scripts/trackers/local.py` | Local backend: `.qa/tracker/runs/*.md`, `.qa/tracker/bugs/NNN-slug.md`. |
| `qa-kit/scripts/trackers/clickup_api.py` | `Transport` and `HttpTransport`: retries on 429/5xx, 0.35 s pacing between writes. `FakeTransport` for tests. |
| `qa-kit/scripts/trackers/clickup.py` | ClickUp backend: `init`, `push_plan`, `pull_plan`, `push_run`, `push_results`, `push_bug`, `update_retest`, `status`. |
| `qa-kit/scripts/trackers/cli.py` | argparse; loads config and catalog; dispatches to the backend. |
| `qa-kit/templates/catalog-schema.json` | JSON Schema for one catalog area file and for `manifest.yaml`. |
| `qa-kit/templates/qa-tracker-config.json` | Default config seed. |
| `qa-kit/templates/trackers/{local,clickup,github,other}.md` | Seeds for the rules file. |
| `qa-kit/core/commands/qa-tracker.md` and generated `qa-kit/commands/qa-tracker.md` | The setup command. |
| `tests/qa-tracker/run.sh` and `tests/qa-tracker/test_*.py` | Suite: `python3 -m unittest` over the test files, `PASS=n FAIL=m` summary. |
| `tests/qa-tracker/fixtures/` | Catalog, runs and ClickUp replay fixtures. |

## Lanes

| Wave | Lane | Tasks | Owns files | Consumes (from) |
|---|---|---|---|---|
| 1 | A | 1, 2 | core.py, local.py, cli.py, tracker.sh, catalog-schema.json, tests/qa-tracker/test_core.py, test_local.py, run.sh, fixtures/catalog, fixtures/runs | — |
| 1 | C | 4 | clickup_api.py, tests/qa-tracker/test_clickup_api.py | — |
| 2 | B | 3 | core/commands/qa-tracker.md, commands/qa-tracker.md, templates/trackers/*, templates/qa-tracker-config.json, tests/qa-tracker/test_setup.py | Task 1 config keys |
| 2 | C | 5, 6, 7 | clickup.py, tests/qa-tracker/test_clickup_*.py (except _api), fixtures/clickup/* | Tasks 1, 2 (core, cli registration hook), 4 |
| 3 | D | 8 | run-qakit-ci.sh, qa-kit plugin.json, marketplace.json, CHANGELOG.md, qa-kit README, the spec (P1 amendment) | all |
| 4 | E | 9 | Innovation repo: docs/agents/qa-tracker.{json,md}, docs/qa/sync_clickup.py, CLAUDE.md pointer | 8 released |

`cli.py` is owned by Lane A. Task 2 registers backends through `BACKENDS = {"local": ..., "clickup": ...}`, importing `clickup` lazily. Lane C does not edit `cli.py`.

---

### Task 1: core helpers and catalog schema   (Lane A, risk: high)

**Files:**
- Create: `qa-kit/scripts/trackers/__init__.py` (empty), `qa-kit/scripts/trackers/core.py`,
  `qa-kit/templates/catalog-schema.json`, `tests/qa-tracker/test_core.py`,
  `tests/qa-tracker/fixtures/catalog/` (manifest plus 2 areas, one case retired),
  `tests/qa-tracker/fixtures/runs/r1/` (checklist, checkpoint, verification, bugs/bugs.json)
- Create: `tests/qa-tracker/run.sh`

**Interfaces (Produces):**
- `load_config(project: Path) -> dict`: reads `docs/agents/qa-tracker.json` and fills defaults
  from the template. Keys: `backend`, `catalog`, `guideDir`, `ids{workspace,space,folder}`,
  `lists{}`, `statuses{case[],bug[]}`, `fields{}`, `statusCeiling`, `secrets[]`,
  `wording{forbidden[],patterns[]}`, `guideAs`. Raises `ConfigError` with the path in the message.
- `load_catalog(project: Path, cfg) -> Catalog`. `Catalog` holds `areas: list[Area]`, and
  `Area(file, prefix, list, order, intro, cases: list[dict])`.
- `validate_catalog(cat) -> list[dict]`, returning `[{file, id, reason}]`.
- `case_index(cat) -> dict[str, tuple[Area, dict]]`
- `content_hash(text: str) -> str`: sha1 hex of `norm(text)`.
- `norm(s) -> str`: the `sync_clickup.py` `norm`. It drops markdown links to their text, removes
  every non-word character and lowercases.
- `fingerprint(key: str, persona: str, title: str) -> str` (P5)
- `case_results(run_dir: Path) -> dict[str, dict]`. Per case:
  `{verdict, criteria:[{id, verdict, persona}], confidence}` (P3, P4).
- `outbound(text: str, cfg) -> str`: raises `WordingError(word)`.
- `redact(text, cfg) -> str`
- `MapCache(project)`: `.get(kind, key)`, `.put(kind, key, remote_id, hash)`, `.save()`, written
  atomically to `.qa/tracker-map.json`.
- `ActionLog(apply: bool)`: `.act(kind, detail, fn=None)` and `.summary() -> str`, giving the
  exact line format from Global Constraints.

**Exact values:**
- Schema-required case keys: `id` (`^TC-[A-Z]+-\d{3}$`), `title`, `priority` (`P1|P2|P3`),
  `preconditions`, `steps` (non-empty list), `expected` (non-empty list).
- Optional keys: `type`, `level` (`beginner|needs-setup|technical`), `audience`, `run_last`,
  `roles`, `refs`, `retired`, `retired_reason`, `draft`.
- `redact` masks:
  - every value of the keys listed in `cfg.secrets`, looked up in
    `<guideDir>/02-test-accounts.md` under a fenced block after "same password", and replaced with
    `the shared QA password`;
  - any `pk_[A-Za-z0-9_]{20,}` token, replaced with `[redacted]`.

**Behaviour:**
- `validate_catalog` reports each of these:
  - a duplicate id across files;
  - an id prefix that doesn't match the area `prefix`;
  - a manifest `counts` value that doesn't match the per-priority count of non-retired cases;
  - a manifest file that is missing;
  - a yaml file that isn't listed in the manifest.
- `case_results` ignores rows that have no case. It applies the `verification.json` override per
  criterion and persona.
- A missing `verification.json` is not an error.

**Tests (write first):**
- `test_validate_clean_catalog`: fixture catalog → `[]`.
- `test_validate_reports_duplicate_and_count_drift`: mutated temp copy → both reasons present.
- `test_case_results_rollup_worst_and_override`: r1, where TC-A-001 has criteria pass+fail and
  TC-A-002's pass is overridden by verification → `fail`, `fail`.
- `test_catalogref_list_joins_two_cases`: one row with `catalogRef: [TC-A-001, TC-A-003]` → the
  row appears under both cases.
- `test_fingerprint_stable_across_digits`: `"Total off by 3"` and `"Total off by 7"` → same value.
- `test_outbound_blocks_word_and_path`: "the agent saw" → `WordingError("agent")`;
  "see app/Http/X.php" → `WordingError`; "Agentur" → passes, because matching is whole-word.
- `test_redact_shared_password_from_guide`: guide fixture holds `S3cret!x`, and text containing it
  → `the shared QA password`.
- `test_action_log_format`: two acts, dry → exact lines plus `SUMMARY {"create": 1, "update": 1} dry-run`.

**Task gate:** `bash tests/qa-tracker/run.sh`

### Task 2: CLI, entry point and local backend   (Lane A, risk: normal)

**Files:**
- Create: `qa-kit/scripts/trackers/cli.py`, `qa-kit/scripts/trackers/local.py`,
  `qa-kit/scripts/tracker.sh`, `tests/qa-tracker/test_local.py`

**Interfaces:**
- Consumes: everything from Task 1.
- Produces:
  - `tracker.sh <verb> [--project DIR] [--apply] [--run RUN_ID] [--label TEXT] [--only FILE...] [--overwrite ID...]`
  - verbs: `validate`, `results`, `status`, `init`, `push-plan`, `pull-plan`, `push-run`,
    `push-results`, `push-bug`, `update-retest`;
  - the backend protocol: a module exposing those verbs as
    `def <verb>(ctx: Ctx) -> None`, where `Ctx(project, cfg, catalog, log: ActionLog, cache: MapCache, args)`.

**Behaviour:**
- `validate` prints `{"errors":[...],"ok":bool}` and exits 0 only when ok. The same holds for
  `results --run`, which prints the `case_results` JSON.
- A verb the backend lacks exits 2 with `<backend> does not support <verb>`.
- `--run` defaults to the newest `.qa/runs/*` that has a `checkpoint.json`.
- Local `push-run`/`push-results` write `.qa/tracker/runs/<run-id>.md`:
  - a heading with the label, then a table `Case | Title | Result | Criteria` sorted by case id;
  - re-running it rewrites the file only when its content hash changed.
- Local `push-bug` reads `<run>/bugs/bugs.json` and writes `.qa/tracker/bugs/NNN-<slug>.md`:
  - front matter: `status: open`, `severity`, `case`, `ref` (the fingerprint), `found_in`;
  - `NNN` is the next free 3-digit number;
  - an existing ref with status not `closed` gets a `- Still happens on <label>` line appended
    instead of a new file.
- Local `update-retest` appends `- Retest on <label>: passed|still failing` to each bug whose
  status is `retest` and whose case is in the run. Status is not changed.
- Local `init` creates `.qa/tracker/{runs,bugs}`.
- Local `push-plan`/`pull-plan` report `nothing to do: cases live in the catalog` and exit 0.

**Tests (write first):**
- `test_cli_validate_exit_codes`: clean catalog → exit 0; bad → exit 1.
- `test_local_push_run_writes_table_once`: apply twice → one file, and the second run logs no
  `update`.
- `test_local_push_bug_dedupes_by_fingerprint`: export the same bug twice in two runs → one file
  plus one "Still happens" line.
- `test_local_retest_never_changes_status`: a bug in `retest` and its case passed → line appended,
  `status: retest` kept.
- `test_dry_run_writes_nothing`: no `--apply` → `.qa/tracker` absent.
- `test_unsupported_verb_exit_2`: fake backend without `pull_plan` → exit 2 and the message.

**Task gate:** `bash tests/qa-tracker/run.sh`

### Task 3: `/qa-tracker` setup command and rule seeds   (Lane B, risk: normal)

**Files:**
- Create: `qa-kit/core/commands/qa-tracker.md`, `qa-kit/templates/qa-tracker-config.json`,
  `qa-kit/templates/trackers/{local,clickup,github,other}.md`, `tests/qa-tracker/test_setup.py`
- Generate: `qa-kit/commands/qa-tracker.md`, via `build-qakit-adapter.sh claude` and a copy, the
  same way the other commands are produced.

**Exact values:**
- Frontmatter: `description: Pick where test cases, runs and bugs live (local files, GitHub or ClickUp) and write the project's QA tracker rules and config.`
  and `argument-hint: "[--reconfigure]"`.
- The three questions, verbatim and in this order:
  1. "Where do test cases, runs and bugs live?"
  2. "Where do bugs go?"
  3. "Keep the default statuses?"
- Default statuses, case: `to test, testing, failed, blocked, passed, skipped`.
- Default statuses, bug: `open, triaged, fixing, retest, closed`.
- The CLAUDE.md/AGENTS.md pointer, under `## Agent skills`:
  `### QA tracker` then `Test cases, runs and bugs are tracked in <Backend>. See docs/agents/qa-tracker.md.`

**Behaviour:**
- The command follows the Matt Pocock order:
  1. explore: git remote, `docs/agents/issue-tracker.md`, existing `docs/agents/qa-tracker.*`,
     any catalog;
  2. present what it found;
  3. ask one question at a time, recommended answer first;
  4. write.
- For ClickUp it asks for the workspace and the folder (it may list them through the API), then
  runs `tracker.sh init` dry and shows the result. It writes `--apply` only after the user says
  yes.
- It never writes the token into any file. It names `CLICKUP_API_TOKEN` in the rules file instead.
- "Other" writes only the rules file, with the user's prose, and `backend: "other"`. Every verb
  then exits 2.
- The rules seeds describe each verb in plain language, plus this tracker's quirks. The ClickUp
  seed explains the field-ownership rule from spec D5.

**Tests (write first):**
- `test_config_template_matches_load_config_defaults`: `load_config` on an empty project equals
  the template.
- `test_command_mentions_three_questions_in_order`: grep the three strings in order in the core
  command.
- `test_generated_command_in_sync`: run `validate-qakit-adapters.sh` → exit 0.

**Task gate:** `bash tests/qa-tracker/run.sh && bash qa-kit/scripts/validate-qakit-adapters.sh`

### Task 4: ClickUp transport   (Lane C, risk: normal)

**Files:**
- Create: `qa-kit/scripts/trackers/clickup_api.py`, `tests/qa-tracker/test_clickup_api.py`

**Interfaces (Produces):**
- `class Transport`: `request(method, path, body=None) -> dict`.
- `HttpTransport(token)`:
  - base `https://api.clickup.com/api` (paths start `/v2/...` or `/v3/...`);
  - header `Authorization: <token>`;
  - JSON body;
  - up to 5 tries, sleeping `15*(n)` s on 429/5xx;
  - sleeps 0.35 s after every non-GET call;
  - raises `ApiError(method, path, status, body)`.
- `FakeTransport(fixture_dir)` serves `GET` from `<dir>/<method>_<path with / → _>.json` and
  records every non-GET call in `.calls: list[tuple]`. An unknown GET raises.
- `token_from_env() -> str`: reads `CLICKUP_API_TOKEN`. When it's missing, raises `ConfigError`
  with "set CLICKUP_API_TOKEN (a personal token)".

**Tests:**
- `test_retry_on_429_then_success`: stub opener → called twice.
- `test_fake_records_writes`.
- `test_token_missing_message`.
- `test_token_never_in_error_text`: an ApiError's string has no `pk_` value.

**Task gate:** `bash tests/qa-tracker/run.sh`

### Task 5: ClickUp `push-plan` and `pull-plan` (port of sync_clickup.py, guide Doc)   (Lane C, risk: high)

**Files:**
- Create: `qa-kit/scripts/trackers/clickup.py` (the `push_plan`, `pull_plan`, `status` part),
  `tests/qa-tracker/test_clickup_plan.py`, `tests/qa-tracker/fixtures/clickup/plan/`, a replay of a
  small folder (2 area lists + guide list, 6 tasks)

**Interfaces:**
- Consumes: Task 1 (`Catalog`, `outbound`, `content_hash`, `MapCache`, `ActionLog`) and Task 4.
- Produces:
  - `clickup.push_plan(ctx)`, `clickup.pull_plan(ctx)`, `clickup.status(ctx)`;
  - `clickup.load_folder(ctx) -> Folder`, holding `lists{name:id}`, `tasks[]`, `by_tc{}` and
    `by_name{}`. Tasks 6 and 7 reuse it.

**Exact values (carried over from Innovation's `docs/qa/sync_clickup.py`, behaviour kept):**
- Task name format `f"{id} · {title}"`; id regex `^(TC-[A-Z]+-\d+) · `.
- Priority `{"P1":1,"P2":2,"P3":3}`; new status `to test`; retired status `skipped`.
- Managed tags `beginner`, `needs setup`, `technical`, `run last`; retired tag `retired`.
- Description layout (`describe`), in this order:
  1. Level;
  2. Run last;
  3. `**Preconditions:**`;
  4. `**Steps:**` (numbered);
  5. `**Expected results:**` (bullets);
  6. `**Evidence:**\n- [ ] Screenshot / recording attached (or n/a)`.
- Comment on a content change to a task not in `to test`:
  `Updated from the catalog on <YYYY-MM-DD> — re-verify if already passed.`
- Retire comments:
  - `Retired from the catalog on <date>: <retired_reason>`;
  - for an orphan: `Retired on <date>: this case is no longer part of the test plan; the feature it covered was replaced.`
- Move endpoint: `PUT /v3/workspaces/{ws}/tasks/{id}/home_list/{list}`.
- Docs:
  - `POST /v3/workspaces/{ws}/docs` with `{"name":"QA Guide","parent":{"id":<space>,"type":4}}`;
  - pages: `POST /v3/workspaces/{ws}/docs/{doc}/pages` and
    `PUT /v3/workspaces/{ws}/docs/{doc}/pages/{page}`, with `content_format: "text/md"`.
- Guide-task retire comment: `This guide now lives in the "QA Guide" doc.`

**Behaviour:**
- Every pushed name, description and intro goes through `outbound`. A wording hit skips that item
  and doesn't stop the run.
- A task whose live description hash ≠ the cache's last-pushed hash **and** ≠ the catalog hash is a
  human edit:
  - log `drift\t<id>` and skip it;
  - `--overwrite <id>` forces it.
  - With an empty cache, no drift is assumed. This matches today's behaviour.
- Orphans and retirement work as in today's script (full sync only, never with `--only`).
  Retired cases are also moved to their area list.
- With `guideAs: doc`:
  - the Doc is found by name, and created only if absent;
  - each page is upserted by name;
  - the `Guide · …` tasks are retired once;
  - the `07` sign-off tasks are kept as tasks.
- With `guideAs: tasks`, today's guide-task behaviour is kept.
- `pull_plan` lists TC tasks that aren't in the catalog (`draft candidates`) and catalog cases
  whose live content drifted. It writes `.qa/tracker/pulled/<area-file>.yaml` with `draft: true`
  entries only under `--apply`. It never edits the catalog.
- `status` is `push_plan` forced to dry run, plus `pull_plan` drift counts.

**Tests (write first):**
- `test_dry_run_matches_expected_actions`: fixture → the exact action list (create 1, update 1
  description, move 1, retire orphan 1, tag+ 1).
- `test_second_run_after_apply_is_empty`: apply against a fake that reflects writes → the next
  dry run gives `SUMMARY {}`.
- `test_wording_hit_skips_item_only`: one case says "automated" → that item skipped, the others
  are still created.
- `test_human_edit_is_drift_not_overwrite`: cache hash differs from live → `drift`, no PUT;
  `--overwrite` → PUT.
- `test_guide_doc_created_and_tasks_retired`: `guideAs: doc` → one Doc POST, N page POSTs,
  `Guide ·` tasks retired, sign-off tasks untouched.
- `test_only_never_retires_other_areas`.

**Task gate:** `bash tests/qa-tracker/run.sh`

### Task 6: ClickUp `init` (lists, views, fields check, ids read back)   (Lane C, risk: normal)

**Files:**
- Modify: `qa-kit/scripts/trackers/clickup.py` (adds `init`)
- Create: `tests/qa-tracker/test_clickup_init.py`, plus fixtures

**Exact values:**
- Lists created when absent: one per catalog area (manifest `list`), `00 – Guide & Sign-off`,
  `Runs`, `Bugs`.
- Required custom fields:
  - per area list: `Role`, `Level`, `Last check result`, `Last check run`, `Linked bugs`;
  - Bugs: `Severity`, `Case`, `Found in run`, `Retest result`, `Ref`;
  - Runs: `Build`, `Environment`, `Language`, `Passed`, `Failed`, `Blocked`.
- Views created when absent (`POST /v2/list/{id}/view`, type `list`):
  - per area: `By status` (grouping status), `By priority`, `By level`;
  - Runs: `Results by run`;
  - Bugs: `Open by severity` and `By case`.

**Behaviour:**
- Fields are read with `GET /v2/list/{id}/field`. A missing field or status is printed as a
  numbered click list, `MANUAL\t<n>. In list "<list>": add custom field "<name>" (<type>)`, and is
  never created through the API.
- Ids that are found are written into `docs/agents/qa-tracker.json` (`lists`, `fields`), and only
  under `--apply`.
- Re-running after the manual steps fills in the remaining ids and prints no `MANUAL` lines.

**Tests:**
- `test_init_creates_missing_lists_and_views_only`
- `test_missing_field_prints_manual_step_and_no_post`
- `test_ids_written_back_on_apply`

**Task gate:** `bash tests/qa-tracker/run.sh`

### Task 7: ClickUp run, results, bugs and retest   (Lane C, risk: high)

**Files:**
- Modify: `qa-kit/scripts/trackers/clickup.py`
- Create: `tests/qa-tracker/test_clickup_runs.py`, plus fixtures

**Behaviour:**
- `push_run`:
  - upserts the task `Run <label>` in `Runs`;
  - sets the Build/Environment/Language fields from `--label`/`run-manifest.json` (missing means
    left empty);
  - sets Passed/Failed/Blocked from `case_results`.
- `push_results`, for each case that has a result:
  - sets `Last check result` (the dropdown option by verdict name) and `Last check run`
    (the run label);
  - adds one comment `Checked on <label>: <verdict> (<n> checks).` only when the result changed
    since the cache. The comment passes `outbound` like everything else, with no exemptions.
  - The status is never touched unless `statusCeiling: testing` and the status is `to test`; then
    it moves to `testing`.
- `push_bug`, for each bug in `<run>/bugs/bugs.json`:
  - computes the fingerprint and searches the Bugs list for `Ref` equal to it;
  - **found, status ≠ `closed`**: add the comment `Still happens on <label>.`;
  - **not found**: create with name = title, description = what happened / what should happen /
    steps, priority (P6), and `Severity`, `Case` (the case task id from `Folder.by_tc`),
    `Found in run` and `Ref`; status `open`;
  - **found and `closed`**: create a new bug whose description starts `Seen again after it was closed: <old name>.`
- `update_retest`: for bugs with status `retest` whose `Case` has a result in this run, set
  `Retest result` to `passed`/`still failing` and add a comment. The status is never changed.

**Tests (write first):**
- `test_push_run_idempotent_by_label`
- `test_results_never_change_status_by_default`
- `test_results_ceiling_moves_to_testing_only_from_to_test`
- `test_bug_dedupe_comments_instead_of_creating`
- `test_closed_bug_reappears_as_new_with_note`
- `test_retest_sets_field_never_status`
- `test_priority_follows_severity_table`

**Task gate:** `bash tests/qa-tracker/run.sh`

### Task 8: integration, release notes, spec amendment   (Lane D, risk: data)

**Files:** `qa-kit/scripts/run-qakit-ci.sh` (add `qa-tracker` to `SUITES`), the qa-kit version
sites (0.4.0), `CHANGELOG.md` (qa-kit v0.4.0 "Track QA where your team works"), the qa-kit README
section, and the spec: the P1 path amendment, a "Plan" link, and renaming the D5/D6 fields from
"automated" to "check" (`Last check result`, `Last check run`), so the field names pass D7.

**Behaviour:**
- `bash scripts/check-suite-coverage.sh` → OK.
- `bash qa-kit/scripts/run-qakit-ci.sh` → green.
- Milestone gate: `bash scripts/run-engine-ci.sh` (portability failure only, as before).
- Finish: push, PR, merge, tag `qa-kit--v0.4.0`.

### Task 9: Innovation cutover   (Lane E, risk: high; Innovation repo, branch off `next`)

**Files:** `docs/agents/qa-tracker.json` (backend `clickup`, catalog `docs/qa/catalog`, guideDir
`docs/qa/guide`, `guideAs: doc`, ids `90182916999`/folder `901815853475`), `docs/agents/qa-tracker.md`
(from the ClickUp seed), the `CLAUDE.md` pointer, and `docs/qa/sync_clickup.py`, which becomes a
wrapper that runs `tracker.sh push-plan` with the same flags.

**Behaviour:**
- Install the qa-kit 0.4.0 plugin cache.
- `tracker.sh validate` → ok.
- `tracker.sh init` (dry) → lists the manual field steps. Give them to the owner. Never click
  them yourself.
- `tracker.sh push-plan` (dry) → only the guide Doc actions and the guide-task retirements. Any
  case-level action is a port bug: stop and fix it in Lane C. Then `--apply`.
- `QaCatalogIntegrityTest` stays green.
- Finish: PR into `next`, then merge.

## Review Focus

1. **A second machine with an empty `.qa/tracker-map.json`.** Every verb must find existing remote
   items by visible identity (P2) and create no duplicates. Covered by
   `test_second_run_after_apply_is_empty` run with a cleared cache. Add that case to Task 5.
2. **A tester edits a case description in ClickUp.** The next push must report drift and leave it.
   Covered by `test_human_edit_is_drift_not_overwrite`.
3. **Forbidden wording inside real catalog text.** Words like "automated" or a file path, such as
   the run-metadata guide's env-var lines. The item must be skipped visibly, not sent and not
   crashed. Covered by `test_wording_hit_skips_item_only`. Also add a guide-page case to Task 5.
4. **A run with no `verification.json` and rows tagged with several cases.** The roll-up must
   still work. Covered by `test_catalogref_list_joins_two_cases`. Add a variant without the file
   to Task 1.
5. **Rate limit mid-push.** A 429 on the 50th write must retry and continue without
   double-creating. Covered by `test_retry_on_429_then_success`. Add a test to Task 5 where a POST
   raises once after the server accepted it: the next dry run must find the item by name and not
   create it again.
