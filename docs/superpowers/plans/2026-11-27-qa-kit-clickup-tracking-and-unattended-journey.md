# qa-kit ClickUp tracking and unattended journey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sdd-lanes:sdd-lanes` to implement this plan
> task-by-task (plan-lite format). Tests are written first.

**Goal:** (A) A spec with ClickUp set up gets a subfolder, a list per run with scenario tickets and
check subtasks, end-of-run status and evidence sync, and Docs. (B) `/qa-auto <target>` drives the
whole qa-kit process with no stops, records every self-answered question, audits its own limits
from files, and ends with a handoff list.

**Architecture:** (A) New python modules beside the existing tracker (`qa-kit/scripts/trackers/`),
dispatched from `cli.py` through a verb → `module:function` table, reusing `clickup._Mirror`.
(B) One bash script, `qa-kit/scripts/auto.sh`, owns the journey files under
`.qa/specs/<target>/auto/`; one command source loops over `auto.sh next` and follows the existing
step commands. The two parts meet only in the qa-kit command sources and the release. The engine
is not touched.

**Tech Stack:** python3 ≥ 3.9 standard library and `unittest` (A); bash 3.2 with jq and a python3
fallback, dual-engine bash tests (B).

**Spec:** `docs/superpowers/specs/2026-11-27-qa-kit-clickup-tracking-and-unattended-journey-design.md`
(read it first; A1 to A9 and B1 to B9 refer to its sections).

## Global Constraints

- No file under `core/`, root `commands/`, `skills/`, `scripts/`, `agents/` or `qa-verify.sh`
  changes (ADR-0022). `bash scripts/validate-adapters.sh` must still pass.
- qa-kit commands are edited in `qa-kit/core/commands/*.md` and regenerated; never edit
  `qa-kit/commands/*.md` by hand (ADR-0024).
- No test calls a live tracker, a model or a browser. No new python dependency.
- Nothing may turn a non-pass into a pass or raise a confidence (ADR-0032, ADR-0033).
- Commits: Conventional Commits, no attribution lines. No destructive git commands.
- Part A:
  - Every new tracker verb is a dry run without `--apply`, and safe to repeat.
  - The token is read only from the environment variable named by `tokenEnv`. It is never written,
    logged or put in an error message.
  - Every string sent to ClickUp passes `core.outbound(..., source="generated")` and the new lint.
  - Existing verbs, config files and the 0.4.2 behaviour of projects without `specs` stay unchanged.
  - Nothing in ClickUp is deleted. Lists are archived, tickets are set to the `skipped` status.
- Part B:
  - A qa-kit script cannot call an engine script. Where `auto.sh` needs an engine script's result,
    the command runs it and passes the result in; where the result is a gate, `auto.sh` reads the
    engine's output file itself and does not take the agent's word.
  - `auto.sh` never edits `.qa/config.json`, `run-config.json`, `checklist.json`, the known-defect
    registry or anything outside `.qa/specs/<target>/auto/`.
  - Every verb gives the same output under `QA_ENGINE=jq` and `QA_ENGINE=python3`.
  - The word in docs and messages is "unattended journey", never bare "autonomous" (`CONTEXT.md`).
- Gates: task = the task's own gate line; lane = `bash tests/qa-tracker/run.sh` (A lanes),
  `bash tests/qa-auto/run.sh` (lane G), the three adapter suites (lane E); milestone =
  `bash qa-kit/scripts/run-qakit-ci.sh && bash qa-kit/scripts/validate-qakit-adapters.sh &&
  bash scripts/validate-adapters.sh && bash scripts/check-suite-coverage.sh`.

## Decisions

Part A:

| # | Decision | Why |
|---|---|---|
| P1 | Settings order: template < machine file < project file < project `specDefaults` < `specs.<target>`. A target with no `specs` entry is enabled when `specDefaults.enabled` is true. Machine file is `~/.config/qa-kit/tracker.json`, overridable by env `QA_KIT_TRACKER_CONFIG` (tests use it). | A2 |
| P2 | New verbs: `lint`, `spec-init`, `push-scenarios`, `sync-run`, `push-docs`, `spec-note`, `spec-status`. All take `--spec <target>`. If omitted and exactly one spec is enabled, that one; else exit 1 `error: name the spec with --spec`. | A5; no guessing a run's spec |
| P3 | A spec verb on a spec that is not enabled prints `SKIP	not-set-up	<target>` and exits 0. On a backend other than `clickup` it exits 2. | A7, optional when not set up |
| P4 | A spec verb exits 1 when any item was skipped for wording, lint or a failed call, after printing the summary. | A7, required once set up |
| P5 | Ticket identity is the `Ref` custom field: `qk1-<key>-<s>` for tickets and subtasks, `qk1-<key>-<s>-<run>` for the Run summary ticket. `<key>` = first 12 hex of sha256 of `<target>\|<N>\|<kind>\|<local id>` (N = the list's run number, kind = `summary`, `card`, `check`). `<s>` = one letter for the status role the tool last wrote: `t` to test, `g` testing, `f` failed, `b` blocked, `p` passed, `s` skipped. `<run>` = first 8 hex of sha256 of the run id, or `open`. | A4: no local file needed; a person's status change is detected when the live status role differs from `<s>` |
| P6 | A run's list is found by its Run summary ticket's `<run>`; else the list whose summary says `open` is bound; else list N+1 is created. `.qa/tracker-map.json` (kind `spec`) only caches ids. | A6 |
| P7 | Folder-level custom fields, exact names: `Ref` (short text), `Role` (short text), `Needs a person's review` (checkbox), `Build` (short text). Ids saved in config `fields` under keys `folder:<name>`. | A3 |
| P8 | `tracker-cards.json` schema as in Task 4. A (criterion, role) pair belongs to exactly one card. A card has `as`: `subtasks` or `checklist`. | A4 |
| P9 | Without subfolders (the QA folder has `parent_folder`, or the subfolder create call fails with a 4xx) the spec is recorded as `specs.<target>.layout: "flat"`; lists are created in the QA folder and named `<spec title> · Run N · …`. | A1 fallback |
| P10 | Bugs: `/qa-verify` runs the existing `push-bug`, then `sync-run` links each of the run's bugs to its scenario ticket with a ClickUp task link. | A1 |
| P11 | A missing screenshot file is reported and does not fail the sync; a failed upload does. | Review Focus |
| P12 | Version: qa-kit `0.5.0`, one release for both parts. | new feature |

Part B:

| # | Decision | Why |
|---|---|---|
| J1 | Steps, in order: `constitution`, `spec`, `scenarios`, `analyze`, `run`, `verify`. States: `pending`, `running`, `done`. Journey state: `open`, `done`, `stopped`. | B1 |
| J2 | Stop reasons: `time-limit`, `step-failed`, `until` (resumable with `auto.sh resume`); `blocked`, `audit`, `no-sign-in`, `tracker` (not resumable; a new journey is needed after a person acts). | B2 |
| J3 | `journey.json`: `{version:1, target, profile, startedAt, deadline, until, steps:[{name,state}], analyzeRounds, runId, state, stop:{reason,detail}\|null, endedAt}`. | left to builder; fixed here |
| J4 | `decisions.json`: array of `{id:"D<n>", step, class, question, answer, evidence, confidence, criteria:[], assumption:true, needsPerson, second:null\|"stands"\|"ask", secondReason}`. | B3 |
| J5 | Decidable classes: `roles`, `surface-access`, `scope`, `role-overrides`, `journeys`, `inputs`, `expected`, `gaps`. Forbidden classes: `seed`, `exclusion`, `crawl-only`, `oracle-human`, `safety`, `known-defect`. | B3, B4 |
| J6 | Safety keys (dot paths in `.qa/config.json`): `allowApiWrites`, `seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, `gates`, `profile`, `humanInteraction.enforce`, `humanInteraction.maxOptOutRate`. | B4 |
| J7 | Production = `environment == "production"`, or `environment == "auto"` with a non-local `baseUrl` and an empty or `QA_DISPOSABLE_ENV` `seedableEnvMarker` (the rule `auto-seed.sh` mirrors). Local hosts: `localhost`, `127.0.0.1`, `[::1]`, `*.localhost`, `*.test`, `*.local`, `*.ddev.site`. | B2 |
| J8 | The engine's ship verdict is read from the run's `report.md`: a line containing `NOT SHIP-READY` → not ready; else one containing `SHIP-READY` → ready; neither → none. | J-constraint: files, not the agent's word |
| J9 | Result values: `ready`, `not confirmed`, `not ready`, `verified`, `not verified`, `stopped`. | B6 |
| J10 | The second look is rendered per harness by a new token `{{SECOND_LOOK}}` from a new `secondLook` string in `qa-kit/harness-profiles.qakit.json`: the dispatch instruction on Claude, the unavailable banner elsewhere. | B3, B7 |

## File Structure

| File | Responsibility |
|---|---|
| `qa-kit/scripts/trackers/core.py` (modify) | machine-file merge and new key validation in `load_config`; `spec_settings`; `criterion_rows` extracted from `case_results` |
| `qa-kit/templates/qa-tracker-config.json` (modify) | new default keys |
| `qa-kit/scripts/trackers/clickup_api.py` (modify) | `token_from_env(name)`, `Transport.upload`, fake upload recording |
| `qa-kit/scripts/trackers/clickup.py` (modify, 2 small edits) | `transport_for` reads `tokenEnv`; `init` also reports folder fields |
| `qa-kit/scripts/trackers/cli.py` (modify) | new verbs, flags, dispatch table, exit rules P3/P4 |
| `qa-kit/scripts/trackers/wording.py` (create) | lint of one string |
| `qa-kit/scripts/trackers/cards.py` (create) | load and validate `tracker-cards.json`; the `lint` verb |
| `qa-kit/scripts/trackers/spec_runs.py` (create) | pure: run results → ticket states, evidence picks, counts |
| `qa-kit/scripts/trackers/spec_docs.py` (create) | pure: Doc page markdown |
| `qa-kit/scripts/trackers/clickup_spec.py` (create) | ClickUp side of every spec verb |
| `qa-kit/templates/trackers/writing-rules.md` (create), `clickup.md` (modify) | A8 rules, verb docs |
| `qa-kit/templates/tracker-cards.json` (create) | example cards file |
| `qa-kit/core/commands/qa-{tracker,spec,scenarios,analyze,verify,status}.md` (modify) + regenerated `qa-kit/commands/` | command wiring |
| `tests/qa-tracker/test_spec_*.py`, `tests/qa-tracker/fixtures/spec/` (create) | tests |
| `qa-kit/scripts/auto.sh` (create) | all journey verbs |
| `tests/qa-auto/run.sh`, `tests/qa-auto/fixtures/` (create) | dual-engine tests over fixture projects |
| `qa-kit/core/commands/qa-auto.md` (create) | the command |
| `qa-kit/core/commands/qa-{constitution,spec,scenarios,analyze,status}.md` (modify) | the open-journey line; status line |
| `qa-kit/harness-profiles.qakit.json`, `qa-kit/scripts/build-qakit-adapter.sh` (modify) | `{{SECOND_LOOK}}` |
| `qa-kit/commands/*` (regenerated), harness install files that list commands | generated |
| `qa-kit/scripts/run-qakit-ci.sh` (modify) | enrol `qa-auto` |
| `docs/adr/0034-clickup-spec-layout.md`, `docs/adr/0035-unattended-journey.md`, `CONTEXT.md`, `qa-kit/README.md`, `CLAUDE.md`, `CHANGELOG.md`, version sites | docs and release |

## Lanes

Lanes A, B and G start together and share no file. Lane E holds every command-source change of
both parts, so no command file has two owners.

| Wave | Lane | Tasks | Owns files | Consumes (from) |
|---|---|---|---|---|
| 1 | A | 1, 2 | `core.py`, `qa-tracker-config.json`, `clickup_api.py`, `clickup.py`, `cli.py`, `test_spec_settings.py`, `test_spec_cli.py` | — |
| 1 | B | 3, 4 | `wording.py`, `cards.py`, `templates/tracker-cards.json`, `test_spec_wording.py`, `test_spec_cards.py`, `fixtures/spec/cards/` | — |
| 1 | G | 12, 13, 14, 15, 16 | `auto.sh`, `tests/qa-auto/`, `run-qakit-ci.sh` | — (the tracker call is stubbed by `QA_AUTO_TRACKER_CMD`) |
| 2 | C | 5, 6 | `spec_runs.py`, `spec_docs.py`, `test_spec_runs.py`, `test_spec_docs.py`, `fixtures/spec/run/` | A (`criterion_rows`), B (`Cards`) |
| 2 | D | 7 | `clickup_spec.py`, `test_spec_clickup_structure.py`, `fixtures/spec/project/` | A, B |
| 2 | E | 10, then 17 | `writing-rules.md`, `clickup.md`, every `qa-kit/core/commands/*` and generated `qa-kit/commands/*`, `harness-profiles.qakit.json`, `build-qakit-adapter.sh`, harness install files, `tests/qa-kit-phases/`, `tests/qakit-adapters/`, `tests/qakit-install/` | tracker verb names (P2), the `auto.sh` interface below |
| 3 | D | 8, 9 | same lane; adds `test_spec_clickup_sync.py`, `test_spec_clickup_docs.py` | C |
| 4 | F | 11 | ADRs, CONTEXT, README, CLAUDE.md, CHANGELOG, `persona-body.md`, version sites | all |

`auto.sh` interface shared by lanes G and E (`T` = `<target>`; every verb takes `--project <dir>`, default `.`):

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

### Task 1: Settings levels and criterion rows   (Lane A, risk: normal)

**Files:** Modify `qa-kit/scripts/trackers/core.py`, `qa-kit/templates/qa-tracker-config.json`. Test
`tests/qa-tracker/test_spec_settings.py`.

**Interfaces — Produces:**
- `core.MACHINE_ENV = "QA_KIT_TRACKER_CONFIG"`; `core.machine_config_path() -> Path`.
- `core.load_config(project)`: unchanged signature; now merges template < machine file < project file.
- `core.spec_settings(cfg: dict, target: str) -> dict`: `cfg` with `cfg["specs"][target]` merged over
  it, plus `"target"`. Raises `ConfigError` if `specs[target]` is not an object.
- `core.enabled_specs(cfg) -> List[str]` (sorted targets with `enabled: true`).
- `core.criterion_rows(run_dir: Path) -> Dict[Tuple[str, str], dict]`: key `(criterion id, persona)`,
  value `{"verdict", "confidence", "row"}` after supersession and verifier overrides.

**Exact values:** new template keys and defaults: `"tokenEnv": "CLICKUP_API_TOKEN"`,
`"language": "en"`, `"evidence": "standard"`, `"evidenceCap": 3`, `"keepRuns": 3`, `"notify": null`,
`"reportUrl": null`, `"specs": {}`, `"specDefaults": {}`. Allowed: `evidence` ∈ `standard|failures|none`; spec keys
`enabled` (bool), `folder`, `doc`, `list`, `layout` (`subfolder|flat`), `listMode` (`fresh|reuse`),
`title`.

**Behaviour:**
- A missing machine file is fine. A machine file that is not a JSON object raises `ConfigError`
  naming the file.
- The machine file may not set `specs` or `ids.folder`; if it does, `ConfigError`.
- `tokenEnv` must match `^[A-Z][A-Z0-9_]*$`; a value that looks like a token (`pk_…`) is refused
  with `tokenEnv must be the name of an environment variable, not the token`.
- `case_results` keeps its exact output; it is rebuilt on `criterion_rows`.
- A config with no new keys loads exactly as before (equal to the 0.4.2 result plus defaults).

**Tests (write first):**
- `test_project_overrides_machine` — machine `language: ar`, project `language: en` → `en`.
- `test_spec_overrides_project` — `specs.judging.evidence: none` → `spec_settings(...)["evidence"] == "none"`.
- `test_spec_defaults_enable_new_spec` — `specDefaults.enabled: true`, no `specs.judging` → `spec_settings(cfg, "judging")["enabled"] is True`; `specs.judging.enabled: false` wins over it.
- `test_machine_file_cannot_set_specs` — raises `ConfigError`.
- `test_token_env_rejects_token_value` — `tokenEnv: "pk_123…"` raises, message does not echo the value.
- `test_case_results_unchanged` — the existing fixtures give byte-identical `case_results` JSON.
- `test_criterion_rows_verifier_downgrade` — a pass the verifier blocked comes out `blocked`.
- `test_criterion_rows_persona_supersession` — a persona-less row older than a persona row is dropped.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_settings.py tests/qa-tracker/test_core.py`

### Task 2: Transport upload, token name, verb dispatch   (Lane A, risk: high)

**Files:** Modify `clickup_api.py`, `clickup.py`, `cli.py`. Test `tests/qa-tracker/test_spec_cli.py`.

**Interfaces — Produces:**
- `clickup_api.token_from_env(name: str = "CLICKUP_API_TOKEN") -> str`.
- `Transport.upload(self, path: str, file_path: Path, filename: str) -> dict` (multipart, field name
  `attachment`). `FakeTransport.upload` appends `("UPLOAD", path, filename)` to `calls`.
- `cli.SPEC_VERBS: Dict[str, str]`, exactly:
  `{"lint": "trackers.cards:lint_verb", "spec-init": "trackers.clickup_spec:spec_init",
  "push-scenarios": "trackers.clickup_spec:push_scenarios", "sync-run": "trackers.clickup_spec:sync_run",
  "push-docs": "trackers.clickup_spec:push_docs", "spec-note": "trackers.clickup_spec:spec_note",
  "spec-status": "trackers.clickup_spec:spec_status"}`. Each handler is `fn(ctx) -> None`.
- New flags: `--spec <target>`, `--retest`, `--file <path>` (text for `spec-note`), `--blocked`.
- `ctx.args.spec` is always resolved to a target before a spec handler runs; `ctx.cfg` is then
  `core.spec_settings(cfg, target)`.

**Exact values:** upload endpoint `POST /v2/task/{task_id}/attachment`. Messages: P2 and P3 strings
verbatim. Exit codes: 0 ok, 1 error or skipped items (P4), 2 unsupported backend.

**Behaviour:**
- Spec verbs never load the catalog. `lint` needs no backend and no token.
- `clickup.transport_for` passes `cfg["tokenEnv"]`; the missing-token message names that variable.
- `push-bug` and `update-retest` run without a catalog when `--spec` is given (today they stop with
  `catalog error`). Read `clickup._push_bug` first; if it dereferences `ctx.catalog`, guard it.
- `clickup.init` ends by calling `clickup_spec.report_folder_fields(ctx)` when any spec is enabled
  (lazy import); with none enabled its output is unchanged.
- `upload` retries only on 429, never sends the token in an error, and redacts it like `request`.
- The API hint for 401/403 names the configured variable.

**Tests (write first):**
- `test_spec_verb_not_set_up_exits_0` — no `specs` → stdout has `SKIP\tnot-set-up`, rc 0.
- `test_spec_verb_other_backend_exits_2` — backend `local`, spec enabled → rc 2.
- `test_spec_required_when_two_enabled` — two enabled, no `--spec` → rc 1 with the P2 message.
- `test_skips_make_exit_1` — a handler that logs one skip → rc 1, summary still printed.
- `test_token_env_name_used` — `tokenEnv: QA_TOKEN`, only `QA_TOKEN` set → transport built.
- `test_upload_multipart_shape` — opener stub receives a `multipart/form-data` body with the file bytes.
- `test_push_bug_without_catalog_with_spec` — no catalog dir, `--spec` → no `catalog error`.
- `test_old_verbs_unchanged` — `test_clickup_runs.py` and `test_clickup_init.py` still pass.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_cli.py tests/qa-tracker/test_clickup_api.py tests/qa-tracker/test_clickup_runs.py tests/qa-tracker/test_clickup_init.py`

### Task 3: Wording lint   (Lane B, risk: normal)

**Files:** Create `qa-kit/scripts/trackers/wording.py`. Test `tests/qa-tracker/test_spec_wording.py`.

**Interfaces — Produces:** `wording.lint_text(text: str, kind: str, cfg: dict) -> List[str]`
(`kind` ∈ `title|body`; returns reasons, empty when clean). `wording.clean(text, kind, cfg) -> str`
returns `core.outbound(text, cfg)` or raises `core.WordingError` with the first reason.

**Exact values:** reasons (stable strings tests match): `emoji`, `forbidden word: <w>`,
`looks like an id: <token>`, `title too long (max 90)`, `title in headline case`, `empty`,
`mentions a person`.

**Behaviour:**
- `emoji`: any character in the emoji and pictograph ranges, including the status symbols ✅ ❌ ⚠.
- Id-like tokens: criterion and rule ids (`[A-Z]{1,5}-?\d+` such as `C-012`, `J1`, `AC12`), commit
  hashes (7 to 40 hex with a digit and a letter), `#123`, `v1.2.3`-style versions, snake_case and
  camelCase identifiers, anything matching `wording.patterns`. Phrases in `wording.allow` are exempt.
- Headline case: a title of 4 or more words where every word of 4+ letters starts with a capital.
  Skipped when `language` is not `en`.
- `mentions a person`: an `@` followed by a letter.
- Arabic text passes untouched by the Latin-only rules.

**Tests (write first):** one per reason, plus `test_plain_sentence_passes` ("Judge can save a score
for a submission"), `test_allow_phrase_exempts` (`wording.allow: ["AI Lab"]`),
`test_arabic_title_passes`, `test_number_alone_is_not_an_id` ("Shows 3 teams per page").

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_wording.py`

### Task 4: Cards file and the `lint` verb   (Lane B, risk: normal)

**Files:** Create `qa-kit/scripts/trackers/cards.py`, `qa-kit/templates/tracker-cards.json`,
`tests/qa-tracker/fixtures/spec/cards/`. Test `tests/qa-tracker/test_spec_cards.py`.

**Interfaces — Consumes:** `wording.lint_text`. **Produces:**
- `cards.CARDS_NAME = "tracker-cards.json"`; `cards.spec_dir(project, target) -> Path` (`.qa/specs/<target>`).
- `cards.load(project: Path, target: str) -> Cards` with `.spec` (`title`, `overview`, `outOfScope`),
  `.cards: List[Card]`; `Card`: `id, role, roleName, title, storyline, priority, as_, checks`;
  `Check`: `criterion, title, do, expect`. Raises `cards.CardsError`.
- `cards.problems(c: Cards, checklist_rows: List[dict], cfg) -> List[dict]` (`{"card","criterion","reason"}`).
- `cards.card_for(c: Cards, criterion: str, persona: str) -> Optional[Card]`.
- `cards.lint_verb(ctx) -> None`: prints `{"ok": bool, "problems": [...]}` as one JSON line; logs one
  skip per problem (so P4 gives rc 1).

**Exact values:** file shape:
`{"spec": {"title", "overview", "outOfScope": []}, "cards": [{"id", "role", "roleName", "title",
"storyline", "priority": "P1|P2|P3", "as": "subtasks|checklist", "checks": [{"criterion", "title",
"do", "expect"}]}]}`. Reasons: `no card for this check`, `check is in two cards`,
`check is not in the plan`, `duplicate card id`, plus the wording reasons.

**Behaviour:**
- The plan is `.qa/specs/<target>/checklist.json`. Read the row's id and role fields the way
  `skills/generating-qa-checklist/scripts/validate-checklist-json.sh` defines them (read-only); a
  row with several roles needs one check per role, each in a card of that role.
- Every `title` is linted as `title`; `storyline`, `do`, `expect`, `overview` as `body`.
- A missing cards file is `CardsError("…/tracker-cards.json: not found; run /qa-scenarios")`.
- `card_for` with an empty persona returns the card only when exactly one card holds the criterion.

**Tests (write first):** `test_valid_fixture_clean`; `test_row_without_card`;
`test_pair_in_two_cards`; `test_card_names_unknown_row`; `test_two_role_row_needs_two_checks`;
`test_title_with_emoji_reported_with_card_id`; `test_lint_verb_rc1_on_problem` (through `cli.main`);
`test_missing_file_message`.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_cards.py`

### Task 5: Run results to ticket states   (Lane C, risk: high)

**Files:** Create `qa-kit/scripts/trackers/spec_runs.py`, `tests/qa-tracker/fixtures/spec/run/`.
Test `tests/qa-tracker/test_spec_runs.py`.

**Interfaces — Consumes:** `core.criterion_rows`, `cards.Cards`, `cards.card_for`. **Produces:**
- `spec_runs.CheckState` (dataclass): `card_id, criterion, persona, role` (status role or `None`
  when not run yet), `needs_review: bool`, `note: Optional[str]`, `evidence: List[Path]`, `raised: bool`.
- `spec_runs.states(run_dir: Path, c: Cards, cfg: dict) -> List[CheckState]`.
- `spec_runs.card_role(states_of_card: List[CheckState]) -> str`.
- `spec_runs.counts(states) -> Dict[str, int]` (keys = the six roles plus `needs_review`).
- `spec_runs.missing_evidence(run_dir, c, cfg) -> List[Tuple[str, str]]` (criterion, persona).
- `spec_runs.ready(run_dir) -> Tuple[Optional[bool], List[str]]` (ship verdict and plain reasons;
  `None` when the run has no ship readiness).

**Exact values:** verdict → role: `pass`→`passed`, `fail`→`failed`, `blocked`→`blocked`,
`error`→`blocked`, `deferred`→`skipped`. A pass with `confidence` other than `high` → `testing` with
`needs_review=True`. Notes (go through lint, so plain): error → `Could not be checked on this run.`;
low-confidence pass → `Passed on this run. A person needs to confirm the expected result.`
Card roll-up order, worst first: `failed, blocked, testing, to_test, skipped, passed`.

**Behaviour:**
- A check with no row yet has `role=None` and counts as `to_test`.
- Evidence: find a criterion's screenshots the way `scripts/render-report.js` does (read it; do not
  edit it). `standard`: all for failed and blocked, the first one for passed; `failures`: none for
  passed; `none`: none. Never more than `evidenceCap`. A referenced file that does not exist is left out
  of `evidence` and returned by `missing_evidence` (P11).
- In a `checklist` card, a check is `raised` when its role is `failed`, `blocked` or it needs review.
- `ready` reads the run's ship readiness from the files the engine already writes
  (`verification.json`, `coverage.json`, the bug export); it never computes a verdict of its own and
  returns `None` when they are absent. Reasons are rewritten into plain words from a fixed table;
  an unknown reason becomes `Another condition is not met; see the Results page.`

**Tests (write first):** `test_verdict_mapping` (table above); `test_low_confidence_pass_is_testing`;
`test_unrun_check_is_to_test`; `test_card_rollup_worst_wins`; `test_card_testing_while_open`;
`test_evidence_standard_cap`; `test_evidence_failures_mode_skips_passed`;
`test_missing_screenshot_reported_not_raised` (P11); `test_checklist_card_raises_only_failures`;
`test_persona_rows_join_their_own_card`; `test_ready_none_without_ship_files`.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_runs.py`

### Task 6: Doc pages   (Lane C, risk: normal)

**Files:** Create `qa-kit/scripts/trackers/spec_docs.py`. Test `tests/qa-tracker/test_spec_docs.py`.

**Interfaces — Consumes:** `Cards`, `CheckState`, `counts`, `ready`. **Produces** (all return
markdown, all pure):
- `overview_page(c: Cards) -> str`
- `scenario_page(card, history: List[dict]) -> str` (`history` rows: `{"run": label, "result": role}`)
- `results_page(label: str, states, c, links: Dict[str, str], bugs: List[dict], ready, report_url) -> str`
- `project_page(specs: List[dict], bugs: List[dict]) -> str` (the QA overview Doc)
- `PAGE_OVERVIEW = "Overview"`, `PAGE_SCENARIOS = "Scenarios"`, `PAGE_RESULTS = "Results"`,
  `PROJECT_DOC = "QA overview"`.

**Behaviour:**
- Status words shown to readers are the project's own status names (`core.status_name`).
- Tables only where there are 2+ rows; a spec with no run yet says `No run yet.`
- A retired scenario page starts with `No longer part of the plan.` and keeps its history.
- No ids, run ids or file names appear; `links` values are ClickUp URLs only.
- Output is deterministic (sorted by card order, then check order) so a re-push with no change
  produces identical text.

**Tests (write first):** `test_results_page_counts_and_links`; `test_scenario_history_table`;
`test_retired_scenario_keeps_history`; `test_project_page_lists_specs_latest_run`;
`test_pages_pass_lint` (every page through `wording.lint_text(..., "body")`);
`test_deterministic_output`; `test_no_run_yet`.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_docs.py`

### Task 7: ClickUp structure: `spec-init` and `push-scenarios`   (Lane D, risk: high)

**Files:** Create `qa-kit/scripts/trackers/clickup_spec.py`, `tests/qa-tracker/fixtures/spec/project/`.
Test `tests/qa-tracker/test_spec_clickup_structure.py`.

**Interfaces — Consumes:** `clickup._Mirror`, `clickup.transport_for`, `clickup._save_ids` pattern,
`core.spec_settings`, `cards.*`, `wording.clean`. **Produces:**
- `clickup_spec.ref(target, n, kind, local_id, status_letter="t", run=None) -> str` (P5) and
  `clickup_spec.parse_ref(value) -> Optional[dict]`.
- `clickup_spec.report_folder_fields(ctx) -> List[str]` (missing statuses and fields, as click steps).
- `clickup_spec.spec_init(ctx)`, `clickup_spec.push_scenarios(ctx)`.
- `class SpecSync(clickup._Mirror)` with `.run_lists() -> List[dict]` (`{"id","n","run","summary"}`),
  `.open_list()`, `.new_list()`, `.fill(list_id, n)`, `.tickets(list_id) -> Dict[str, dict]` (by `<key>`).

**Exact values:**
- Subfolder: `POST /v2/space/{space_id}/folder` body `{"name": <spec title>, "parent_folder_id": <ids.folder>}`.
- Folder read: `GET /v2/folder/{folder_id}` (`parent_folder` present → flat, P9); fields
  `GET /v2/folder/{folder_id}/field`.
- List: `POST /v2/folder/{folder_id}/list` `{"name": …}`; from a template when `templates.list` is
  set: `POST /v2/folder/{folder_id}/list_template/{template_id}` `{"name": …, "options":
  {"return_immediately": false, "include_views": true}}`, then poll `GET /v2/list/{id}` until it answers.
- Views: `POST /v2/list/{list_id}/view`, built as `clickup.py` lines 888 to 943 do. Names:
  `By status`, `By role`, `Failed and blocked`.
- Subtask: `POST /v2/list/{list_id}/task` with `"parent": <ticket id>`.
- Checklist: `POST /v2/task/{task_id}/checklist` `{"name": "Checks"}`;
  `POST /v2/checklist/{checklist_id}/checklist_item` `{"name": …}`. Confirm both, and list archiving,
  against the ClickUp reference with `ctx7` before coding; if a path differs, the reference wins.
- Doc: `POST /v3/workspaces/{workspace_id}/docs` `{"name": <spec title>, "parent": {"id": <folder id>, "type": 5}}`.
- List name: `Run <N> · <label>`; before a run is bound: `Run <N> · next`. Flat layout prefixes
  `<spec title> · `. Summary ticket title: `Run summary`.

**Behaviour:**
- `spec-init`: stop with the click list (rc 1) when a status or a P7 field is missing on the QA
  folder. Else create or adopt the subfolder (`specs.<t>.folder` if set, never by name), create the
  spec Doc, write `folder`, `doc`, `layout` back into `docs/agents/qa-tracker.json` under
  `specs.<target>` without touching other keys.
- `specs.<t>.list` set (the person pasted a list): that list is used as run 1 and no list is created.
- `push-scenarios`: runs `cards.problems` first; any problem → nothing is sent, rc 1. Then ensures
  the open list, its views, the Run summary ticket, one ticket per card (description = storyline,
  `Role` field = `roleName`, ClickUp priority from `priority`), one subtask per check for
  `subtasks` cards (description = `do`, blank line, `expect`), one checklist item per check for
  `checklist` cards. Everything is created in the `to test` status.
- Re-running finds every item by `Ref` key and creates only what is missing; a changed title or
  description is updated; a ticket whose description a person edited is reported and skipped.
- A card or check removed from the plan before the run: its ticket is set to `skipped` with the
  comment `No longer part of the plan.` Never deleted.
- A create call that may have landed (`ApiError` status ≥ 500 or 0) is re-read by `Ref` before any
  retry (`_Mirror.safe_create`).
- No assignee is set and every comment uses `notify_all: false`.

**Tests (write first)** (in-memory folder fake modelled on `FolderFake` in `test_clickup_runs.py`,
extended with subfolders, folder fields, checklists and docs):
- `test_spec_init_creates_subfolder_and_doc_and_saves_ids`
- `test_spec_init_missing_field_prints_clicks_rc1_no_writes`
- `test_spec_init_flat_when_folder_is_subfolder` and `test_spec_init_flat_on_4xx`
- `test_spec_init_uses_pasted_list`
- `test_push_scenarios_tree` — cards fixture → tickets, subtasks, checklist items, all `to test`, Refs parse
- `test_push_scenarios_twice_creates_nothing`
- `test_push_scenarios_resumes_after_failure` — fake fails the 5th create → second run completes, no duplicate
- `test_push_scenarios_without_map_cache` — `.qa/tracker-map.json` deleted → no duplicate
- `test_removed_check_is_skipped_with_comment`
- `test_lint_problem_sends_nothing`
- `test_dry_run_writes_nothing`
- `test_person_edited_description_reported_not_overwritten`
- `test_own_status_names` — project statuses renamed → tickets created in the renamed first status

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_clickup_structure.py`

### Task 8: `sync-run`   (Lane D, risk: high)

**Files:** Modify `clickup_spec.py`. Test `tests/qa-tracker/test_spec_clickup_sync.py`.

**Interfaces — Consumes:** `spec_runs.states/card_role/counts/ready/missing_evidence`,
`ctx.run_dir_for`, `ctx.run_label`, `Transport.upload`. **Produces:** `clickup_spec.sync_run(ctx)`;
`SpecSync.bind(run_id) -> dict` (the run's list); `SpecSync.ticket_links(list_id) -> Dict[str, str]`.

**Exact values:** status change `PUT /v2/task/{task_id}` `{"status": …}`; field
`POST /v2/task/{task_id}/field/{field_id}` `{"value": …}`; checklist item
`PUT /v2/checklist/{checklist_id}/checklist_item/{item_id}` `{"resolved": true}`; task link
`POST /v2/task/{task_id}/link/{links_to}`; archive `PUT /v2/list/{list_id}` `{"archived": true}`
(confirm the last three with `ctx7`). Retest comment: `Earlier result: <status name> (<run label>).`
Person-changed report line: `SKIP\tchanged-by-person\t<ticket title>`.

**Behaviour:**
- Binding per P6. On binding, the list is renamed to `Run <N> · <label>` and the summary Ref gets
  the run hash. `--retest` or `listMode: reuse` binds the spec's newest list instead: every ticket
  first gets the retest comment, then goes back to `to test`.
- For each `CheckState` with a role: set the status, rewrite the Ref's status letter, add `note` as
  a comment once, tick `Needs a person's review` when set, set `Build` from the run's build token.
- A ticket whose live status role differs from its Ref letter was changed by a person: skip it,
  print the report line; this is not a P4 failure.
- Card tickets take `spec_runs.card_role`. Checklist cards: resolve passed items; a `raised` check
  becomes a subtask (found by Ref on a re-run) with its status and evidence.
- Evidence files are uploaded once (the attachment's file name is remembered on the ticket: list
  the task's attachments and skip names already there). File names sent are `screen-1.png`,
  `screen-2.png`, never the local name.
- Run summary ticket: description = counts and ready or not with reasons; status = worst card role.
- Bugs (P10): for each bug of this run found in the Bugs list by its `Ref` fingerprint, link it to
  the card ticket that holds its criterion. A bug with no card is left unlinked and reported.
- After a successful sync, lists older than the newest `keepRuns` bound lists are archived.
- A run whose checklist has criteria no card covers stops before any write with
  `error: the plan changed since the tickets were made; run push-scenarios`.

**Tests (write first):** `test_first_sync_binds_open_list_and_renames`;
`test_second_run_creates_list_2`; `test_retest_reuses_and_comments_earlier_result`;
`test_statuses_follow_verdicts`; `test_low_confidence_pass_stays_testing_with_tick`;
`test_person_changed_status_is_left`; `test_sync_twice_no_writes`;
`test_checklist_failure_raised_to_subtask`; `test_evidence_uploaded_once_with_neutral_names`;
`test_missing_screenshot_reported_rc0` (P11); `test_upload_failure_rc1`;
`test_bug_linked_to_card_ticket`; `test_old_lists_archived_beyond_keep_runs`;
`test_plan_changed_stops_before_writes`; `test_other_machine_finds_bound_list_without_cache`.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_clickup_sync.py`

### Task 9: `push-docs`, `spec-note`, `spec-status`   (Lane D, risk: normal)

**Files:** Modify `clickup_spec.py`. Test `tests/qa-tracker/test_spec_clickup_docs.py`.

**Interfaces — Consumes:** `spec_docs.*`, `SpecSync`. **Produces:** `push_docs(ctx)`,
`spec_note(ctx)`, `spec_status(ctx)`.

**Exact values:** pages `GET|POST /v3/workspaces/{ws}/docs/{doc_id}/pages`,
`PUT /v3/workspaces/{ws}/docs/{doc_id}/pages/{page_id}` (as `clickup.py` 555 to 615). `spec-status`
prints one JSON line: `{"spec", "folderUrl", "docUrl", "list": {"n","url","bound"}, "behind": bool,
"reasons": []}`.

**Behaviour:**
- `push-docs` writes the spec Doc (Overview, a Scenarios page with one sub-page per card, a Results
  page with one sub-page per bound run) and the project `QA overview` Doc in the QA folder (created
  on first use, id saved as `ids.overviewDoc`). A page is written only when its text hash changed.
- Scenario history is built from every bound list's card ticket status, read from ClickUp, so it
  is right on any machine.
- `spec-note --file <path> [--blocked]`: lints the text, adds it once as a comment on the open or
  latest Run summary ticket (same text is not posted twice); `--blocked` also sets that ticket to
  the `blocked` status.
- `spec-status` is read-only. `behind` is true when cards, a verified run or a Doc page differ from
  what ClickUp holds; `reasons` are plain phrases.
- `notify` (when set to `{"user": <id>, "on": "verified"}`) adds one mention comment on the Run
  summary ticket from `push-docs --run <id>` after a verified run, once per run. Unset: no mention.

**Tests (write first):** `test_push_docs_creates_pages`; `test_push_docs_unchanged_no_writes`;
`test_history_from_two_runs`; `test_project_doc_created_once_and_id_saved`;
`test_spec_note_posts_once`; `test_spec_note_blocked_sets_status`; `test_spec_note_lint_failure_rc1`;
`test_spec_status_behind_when_cards_changed`; `test_spec_status_makes_no_writes`;
`test_notify_once_per_run`; `test_no_notify_by_default`.

**Task gate:** `python3 -m unittest tests/qa-tracker/test_spec_clickup_docs.py`

### Task 10: Rules file and command wiring   (Lane E, risk: normal)

**Files:** Create `qa-kit/templates/trackers/writing-rules.md`. Modify
`qa-kit/templates/trackers/clickup.md`, `qa-kit/core/commands/qa-{tracker,spec,scenarios,analyze,verify,status}.md`;
regenerate `qa-kit/commands/` with `bash qa-kit/scripts/build-qakit-adapter.sh claude` as ADR-0024
describes. Update assertions in `tests/qa-kit-phases/run.sh` and `tests/qakit-adapters/run.sh`.

**Exact values:** the rules in `writing-rules.md` are the eight bullets of spec A8, verbatim in
meaning, plus one line on screenshots: `Screenshots are sent as they are. Use test accounts and
test data only.` Every command addition starts with the same guard sentence: `Only when
docs/agents/qa-tracker.json has specs.<target>.enabled: true. If the step below exits non-zero,
stop and report its one-line error; do not continue the command.`

**Behaviour (what each command source gains):**
- `qa-tracker`: `--global` (asks workspace and token variable name, writes the machine file, never
  the token); `--spec <target>` (create the subfolder, or paste a folder or list URL; parse the id
  from the URL and confirm it with a GET before saving; then `spec-init`, dry first, `--apply`
  after a yes). Step 5 also appends `writing-rules.md` to `docs/agents/qa-tracker.md`.
- `qa-spec`: after the spec is written, offer `/qa-tracker --spec <target>`; if already enabled,
  run `spec-init --apply` and `push-docs --apply`.
- `qa-scenarios`: read the rules file, write `tracker-cards.json` in the configured `language`
  (schema of Task 4, `checklist` for cards made of generated ship rows), show it with the scenarios, run `lint` until clean, then
  `push-scenarios --apply` and `push-docs --apply`.
- `qa-analyze`: write the plain coverage note to a temp file, `spec-note --file … --apply`
  (`--blocked` when the verdict is BLOCKED).
- `qa-verify`: after its existing checks, `push-bug --spec … --apply`, `sync-run --spec … --run … --apply`,
  `push-docs --spec … --run … --apply`; the run is reported complete only if all three exit 0.
- `qa-status`: print `spec-status` links and the behind reasons.
- Under `autonomousSetup` no question is asked: an enabled spec is synced, a spec that is not
  enabled is left alone.

**Tests:** the adapter suites pass after regeneration; add one assertion per command source that
the guard sentence and its verb are present; `validate-qakit-adapters.sh` shows no residual tokens.

**Task gate:** `bash tests/qa-kit-phases/run.sh; echo rc=$?` and `bash tests/qakit-adapters/run.sh; echo rc=$?`

### Task 11: Docs and release, both parts   (Lane F, risk: normal)

**Files:** Create `docs/adr/0034-clickup-spec-layout.md`, `docs/adr/0035-unattended-journey.md`.
Modify `CONTEXT.md`, `qa-kit/README.md`, `CLAUDE.md`, `CHANGELOG.md`,
`qa-kit/.claude-plugin/plugin.json`, the qa-kit entry in `.claude-plugin/marketplace.json`,
`qa-kit/core/persona-body.md` (the agent's list of steps, then regenerate).

**Behaviour:**
- ADR-0034 records: subfolder per spec and list per run; `Ref` as identity (P5); the tool owns
  status in run lists; required once set up; why the template and the HTML report were dropped.
- ADR-0035 records: the journey state machine on disk; the open journey as the setup signal (no
  config edit); the never-decided list and the file audit; the stricter result; QA only.
- `CONTEXT.md`: the term **unattended journey**, with "Avoid: autonomous mode, auto mode".
- `CLAUDE.md`: the tracker verbs, `auto.sh` and the new files in the Layout block and script
  list, the suite count, and one invariant: "An unattended journey never decides seed, exclusion,
  crawl-only, human oracle, safety settings or the known-defect registry; `auto.sh audit` fails
  the journey if any changed."
- Version `0.5.0` in every qa-kit site; the engine's version is not changed.
- Milestone gate (Global Constraints) passes. Tagging and merging follow the owner's finish
  workflow and are not part of this task.

### Task 12: `start`, `resume`, `status`, `stop`   (Lane G, risk: high)

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
  (artifact rules in Task 13); `analyze`, `run`, `verify` always start `pending`.
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

### Task 13: `next`, `step-start`, `step-done`, `signin`   (Lane G, risk: high)

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

### Task 14: `decide` and `second`   (Lane G, risk: normal)

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

### Task 15: `audit`   (Lane G, risk: high)

**Files:** Modify `auto.sh`, `tests/qa-auto/`.

**Exact values:** violation codes: `safety-setting-changed:<key>`, `run-config-safety:<key>`,
`human-oracle-added:<criterion id>`, `seed-added`, `exclusion-added`, `known-defects-changed`,
`forbidden-decision:<id>`, `step-without-result:<step>`, `not-verified`, `tracker-behind`.
The ClickUp check runs `${QA_AUTO_TRACKER_CMD:-bash <qa-kit>/scripts/tracker.sh} spec-status --spec T`.

**Behaviour:**
- Each violation in B5 maps to one code above; all are collected, none short-circuits.
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

### Task 16: `handoff`   (Lane G, risk: high)

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

### Task 17: The command and the second look   (Lane E, risk: high)

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
  copy of its instructions) under the rules of spec B3 and B4, recording each answer with `decide`
  → `step-done` → next. After `constitution` (or at the first step if it was already done) run
  `auto.sh signin`. A step that fails is redone once, then `stop --reason step-failed`.
- The launch `--profile` is passed to the spec step, which writes it to the spec's run-config as
  `/qa-spec` does today; the command never chooses a profile and never changes one that exists.
- B3's answer rules per class, verbatim in meaning, including "when unsure whether a journey is
  P1, mark it P1" and "never `oracleSource: human`".
- B4's table as a list of things not to do, each with what happens instead.
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

## Review Focus

Each is pinned by a test in the task named.

1. A push that stops half-way (rate limit, network) is run again: nothing is created twice — Task 7
   `test_push_scenarios_resumes_after_failure`.
2. A second machine or a cleaned `.qa/` syncs the same run: it finds the same list and tickets —
   Tasks 7 and 8 `…_without_map_cache`, `test_other_machine_finds_bound_list_without_cache`.
3. A person moved or edited a ticket in ClickUp: the tool leaves it and says so — Task 7
   `test_person_edited_description_reported_not_overwritten`, Task 8 `test_person_changed_status_is_left`.
4. The plan was re-frozen after tickets were made: the sync stops before writing — Task 8
   `test_plan_changed_stops_before_writes`; a removed check is skipped, not deleted — Task 7.
5. A screenshot is missing, or the project uses its own status names: the sync still completes
   correctly — Task 8 `test_missing_screenshot_reported_rc0`, Task 7 `test_own_status_names`.
6. The journey is interrupted and started again: it continues, it does not start over — Task 12
   `start_refuses_open_same_target_without_restart`, Task 13 `next_after_stop_does_not_advance`,
   `deadline_stops_time_limit`.
7. A person already wrote the spec or has exclusions: nothing is regenerated and their choices are
   not reported as violations — Task 12 `existing_spec_marks_steps_done`,
   `baseline_records_existing_human_rows_and_exclusions`.
8. The agent loosens something to get further: the audit catches it from files — Task 15, one test
   per code.
9. The result reads better than it is: never better than the engine's, and "not confirmed" while
   a top-priority check rests on the agent alone — Task 16 `never_better_than_engine`,
   `not_confirmed_when_p1_rests_on_proposal`.
10. The project is on a shared or production environment, or has no sign-in for any role: it
   refuses or stops with one plain line — Task 12 refusal tests, Task 13 `signin_none_stops`.
