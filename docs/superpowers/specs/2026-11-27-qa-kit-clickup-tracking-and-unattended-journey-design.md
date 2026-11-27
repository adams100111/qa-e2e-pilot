# qa-kit ClickUp tracking per spec and run, and the unattended journey

Date: 2026-11-27 · Status: accepted (owner, 2026-11-27). Built in qa-kit 0.5.0; see ADR-0034 and ADR-0035. · Plugin: qa-kit (owner). The engine is unchanged.

One spec in two parts, built from one plan so both can be worked on in parallel:

- **Part A: ClickUp tracking per spec and run** (sections A1 to A9). Builds on
  `docs/superpowers/specs/2026-11-10-qa-tracker-design.md`, which stays in force.
- **Part B: the unattended journey, `/qa-auto`** (sections B1 to B9).

Plan: `docs/superpowers/plans/2026-11-27-qa-kit-clickup-tracking-and-unattended-journey.md`.

What the parts share: the qa-kit command sources (both add lines to the same step commands), the
`specDefaults` key (A2, used by B8), and one release (qa-kit 0.5.0). Later stages, not in the
plan: ClickUp live updates during a run and the browser-driven setup (A, second release); the
headless runner for CI (B, stage 2).

---

# Part A: ClickUp tracking per spec and run

## Why

The tracker that exists mirrors a hand-written test-case catalog into one ClickUp folder. The
qa-kit process itself (spec, scenarios, analyze, run, verify) never reaches ClickUp: no command
calls the tracker, scenarios are not tickets, and evidence is a text comment.

The owner wants non-technical people (admins, testers, the team) to follow a whole QA effort in
ClickUp from the first spec to the last verified run, without opening the repository: what is
being tested, how each scenario is going on each build, the evidence, and the open bugs. It has to
be set up once and then cost nothing per run. It has to read as if a person on the team wrote it.

## Goals

1. Setup at three levels, nearest wins: spec, then project, then machine-wide.
2. A fixed ClickUp structure: one subfolder per spec inside the project's QA folder, one list per
   run inside the spec's subfolder, one ticket per scenario, one subtask per check.
3. Statuses and custom fields are made once and inherited by every spec and run. Views are
   created by the tool.
4. Every qa-kit command updates ClickUp for a spec that has ClickUp set up.
5. Evidence (screenshots) is attached in ClickUp, and the run's report is a page in ClickUp.
6. A ClickUp Doc per spec, and one project Doc that works as the dashboard, both rewritten by the
   tool after each step.
7. The owner's ClickUp writing rules ship inside qa-kit and are checked by a script, so they hold
   on every machine and harness.
8. A setup path driven through the browser, where the person only signs in.

## Non-goals

- The autonomous mode (one agent driving the whole process). It gets its own design after this.
- GitHub and other trackers. Their state is unchanged.
- Changing the existing catalog layout. Projects that use it keep it as it is.
- Two-way sync of text. ClickUp edits are reported, never merged (as today).
- ClickUp Dashboards. No API endpoint for creating one was found; the project Doc replaces it.
- Attaching the engine's HTML report. It carries check ids, suspected layers and file references,
  which the wording rule bans. It stays local for developers; the Results page is the report in
  ClickUp. A project that hosts reports itself can set `reportUrl` (A9).

## Anti-goals

- Any change under the engine's files (`core/`, root `commands/`, `skills/`, `scripts/`,
  `qa-verify.sh`). ADR-0022 holds.
- ClickUp text that mentions AI, agents, automation, file paths, branches, ids from the code, or
  that carries emojis or headline-style titles.
- A spec that has ClickUp set up finishing a step while ClickUp silently missed the update.
- A second run overwriting the first run's results.
- Any token or password written to a file or pushed in a description.

## Constraints found

- ClickUp's API (checked 2026-11-27 against developer.clickup.com):
  - `POST /v2/space/{space_id}/folder` with `parent_folder_id` creates a subfolder. Subfolder
    support must be enabled for the workspace. A secondary source says the beta allows one layer.
  - `POST /v2/folder/{folder_id}/list_template/{template_id}` creates a list from a template;
    `options.include_views` copies its views. `GET /v2/team/{team_id}/list_template` lists templates.
  - `POST /v2/task/{task_id}/attachment` uploads a file (multipart).
  - `POST /v3/workspaces/{id}/docs` accepts `parent: {id, type: 5}` for a folder.
  - A folder that does not override statuses inherits them from its nearest ancestor folder.
  - No endpoint was found for creating statuses, custom fields, list templates or dashboards.
- The rate limit is about 100 requests a minute. A run with 300 checks takes several minutes to
  push. The existing wait-between-writes policy applies.
- `/qa-run` is an engine command and cannot be edited. Anything that happens "during the run" has
  to be done by qa-kit from outside it.
- In many projects `.qa/` is git-ignored, so shared settings cannot live there.
- qa-kit commands are generated: edit `qa-kit/core/commands/*.md`, then regenerate
  `qa-kit/commands/` (ADR-0024). The result must work on all four harnesses.

## Approaches

**A. Subfolder per spec, list per run (picked).** The project's QA folder holds one subfolder per
spec. Each run is a list in it. Scenarios are tickets, checks are subtasks. Every spec is in one
place, each run keeps its own results, and old runs can be archived as a unit. Cost: more lists
over time, and it needs subfolders enabled.

**B. One list per spec, a tag per run.** Fewer objects. But each run needs its own copy of every
scenario ticket to hold its own status, so copies from different runs sit mixed in one list and
every view needs a tag filter. Tags are shared across the whole space and cannot be archived.
Rejected.

**C. Sibling folders per spec with a name prefix.** Works without subfolders, but a sibling folder
inherits statuses and fields from the space, not from the QA folder, so the one-time setup would
have to be repeated for every spec. Rejected, also as a fallback (see A1).

Scenario above run (a list per scenario, a ticket per run) was also considered and rejected: one
run would be split across every scenario's list, so "is this build ready?" has no single place.
The scenario's history is answered by its Doc page instead.

For transport, the tool keeps direct API calls through `tracker.sh` and does not use the ClickUp
MCP: the script already has dry-run, redaction, the word filter and tests, and it runs on every
harness.

The owner picked A in conversation, with the Doc as dashboard and the browser-driven setup.

## The design

### A1. Structure in ClickUp

```
Space
└─ Folder: QA                      project folder (exists today: ids.folder)
    ├─ List: Bugs                  one for the project (exists today)
    ├─ Doc: QA overview            the dashboard
    ├─ Subfolder: <spec name>      one per spec
    │    ├─ Doc: <spec name>       pages: Overview, Scenarios (a page each), Results (a page per run)
    │    ├─ List: Run 1 · <build> · <date>
    │    │    ├─ Ticket: Run summary        counts, ready or not, link to the Results page
    │    │    └─ Ticket: <scenario>         description: the storyline
    │    │         └─ Subtask: <check>      what is checked and what should happen
    │    └─ List: Run 2 · …
    └─ Subfolder: <another spec>
```

- The switch is per spec: `specs.<target>.enabled`. There is no project-wide layout key. The
  catalog layout keeps working beside it in the same QA folder and is not fed by spec runs, except
  through the `case:<TC-id>` tag as today. The new verbs do not need a catalog; the existing
  catalog verbs still do.
- Statuses and custom fields are set once on the QA folder. Subfolders and lists inherit them.
- Run lists are plain lists created through the API; the tool then creates their views through
  the API, as `init` already does for the catalog lists. No list template is needed. (The owner
  asked for a template so statuses would not be rebuilt per run. Folder inheritance gives that
  with nothing to save or copy, so the template was dropped. `templates.list` stays as an optional
  key for a project that wants its own; a list made from it must be checked for the folder's
  statuses before it is filled, and creation from a template is asynchronous, so the tool waits
  until the list exists.)
- Bugs stay in the one project Bugs list, so a fault seen in two specs is filed once (the existing
  fingerprint rule). A bug is linked to the scenario ticket of every run it was seen in; a repeat
  adds the new run's ticket to the link and the existing "still happens" comment.
- **Fallback without subfolders** (not enabled, or the QA folder is itself a subfolder): setup
  says so and keeps everything in the QA folder. Run lists are named `<spec name> · Run N · …` and
  the spec Doc sits in the QA folder. Statuses and fields are still inherited, so nothing is set
  up twice.

### A2. Setup levels

| Level | File | Holds |
|---|---|---|
| Machine | `~/.config/qa-kit/tracker.json` | `tokenEnv` (name of the environment variable, default `CLICKUP_API_TOKEN`), workspace id, default `evidence` |
| Project | `docs/agents/qa-tracker.json` (exists) | everything today, plus optional `templates.list`, and any machine key to override |
| Spec | the same project file, under `specs.<target>` | `enabled`, `folder` (id of the spec's subfolder), `list` (an existing list to use), `listMode`, and any key to override |

A key is read from the spec entry first, then the project file's `specDefaults`, then the project
file, then the machine file. `specDefaults.enabled: true` makes every new spec tracked from the
start without a question (used by the unattended journey; see B8). The token
is only ever read from the environment. Spec settings live in the committed project file because
`.qa/` is often git-ignored (builder's call recorded here: the author's).

`/qa-tracker` gains:

- a machine-wide step (`/qa-tracker --global`) that asks for the workspace and the token's
  variable name;
- a per-spec step (`/qa-tracker --spec <target>`), also offered by `/qa-spec`, with one question:
  create the subfolder, or use a folder or list URL the person pastes. A pasted ClickUp URL is
  parsed for its id and checked through the API before it is saved.

### A3. One-time structure: statuses and fields

Needed once per project, on the QA folder:

- Statuses: the six case statuses the tracker already uses (`to test`, `testing`, `failed`,
  `blocked`, `passed`, `skipped`), or the project's own names by position, as today.
- Custom fields on tickets: Role, Needs a person's review (checkbox), Build, and Ref (see A4).
  Priority is ClickUp's own. The bug fields stay as they are.

The views of a run list (by status, by role, failed and blocked only, subtasks expanded) are
created by the tool on each new list.

Two ways to do it, both ending with the same API read-back:

1. **By hand:** `tracker.sh init` prints the numbered clicks with exact names (as today).
2. **Through the browser:** `/qa-tracker --browser`. The person signs in to ClickUp in the browser
   the engine's driver opens. The agent then creates the statuses and fields on the folder. It
   never types a credential and never asks for one. It is a setup helper, not a test, so the
   engine's act-phase rules do not apply to it. It is command prose with no recorded-response
   test; its done criterion is the API read-back below. It ships in the second release.

After either, `tracker.sh init` reads statuses and fields back through the API, writes the ids
into the config, and lists anything still missing. Nothing is assumed from the clicks.

### A4. What a ticket says

The checklist's ids, kinds and oracle lines are not readable by the audience. So `/qa-scenarios`
also writes `.qa/specs/<target>/tracker-cards.json`: for each scenario a plain title and a short
storyline, and for each check a plain title, what to do and what should happen. It is written by
the agent following the writing rules (A8), shown to the person with the scenarios, and checked by
`tracker.sh lint`. The script pushes only this text; nothing from `checklist.json` is pushed raw.

`tracker-cards.json` is also what defines a scenario for ClickUp, in every profile (the author's
call; journeys exist only under the ship profile, and `scenarios.md` is free prose):

- A scenario card has an id, one role, a title, a storyline and the list of criterion ids it
  covers. It follows a role storyline in `scenarios.md`. Where the spec has `journeys.json`, a
  journey becomes one card per role it names, with that journey's step rows.
- Every row of `checklist.json` belongs to exactly one card. Rows no storyline covers (ship-profile
  load-clean, deny and input-validation rows, for example) go into one card per role and surface.
  `tracker.sh lint` fails on a row with no card, a row in two cards, or a card naming a row the
  checklist does not have.
- A row recorded for several personas gives one subtask per persona, under that persona's card.
- Storyline checks are subtasks. Generated checks (the ship profile's load-clean, deny and
  input-validation rows, which can run to several hundred) are checklist items inside their
  role-and-surface card, ticked when passed. One that fails, is blocked or needs review is raised
  to its own subtask with its evidence, so failures are never hidden in a checklist.
- All text is in one language per project: `language` in the project file, default `en`. The
  rules file and the lint apply to whichever language is set.

Identity does not depend on a local file. Each ticket and subtask carries a short opaque key in a
`Ref` text field (the field bugs already use): spec, run and card or criterion, hashed. The tool
finds a run's list by the `Ref` of its Run summary ticket and finds tickets by their `Ref`.
`.qa/tracker-map.json` stays a cache, so a second machine or a cleaned `.qa/` never duplicates a
list. "A person changed this status" is detected from the ticket's own history: the tool records
the status it last set in a second field value on the ticket's `Ref` (the builder picks the
encoding), not only in the cache.

### A5. What each command does

Only for a spec whose `specs.<target>.enabled` is true.

| Command | ClickUp update |
|---|---|
| `/qa-spec` | Offers the per-spec setup. Creates the subfolder and the spec Doc with its Overview page. Adds the spec to the QA overview Doc. |
| `/qa-scenarios` | Writes and lints `tracker-cards.json`. Writes the Scenarios pages. Creates the first run list and fills it with scenario tickets and check subtasks in `to test`. |
| `/qa-analyze` | Comments on the Run summary ticket: coverage gaps and whether the plan is ready, in plain words. A blocked verdict sets the Run summary ticket to `blocked`. |
| run | See A6. |
| `/qa-verify` | A final sync of the run, the Results page, the Run summary ticket (counts, ready or not ready with the reasons, a link to the Results page), bugs filed and linked, the QA overview Doc. |
| `/qa-status` | Prints the ClickUp links for the spec and its latest run, and whether ClickUp is behind the local files. Read-only. |

All of it goes through new `tracker.sh` verbs, each a dry run without `--apply`, each idempotent:
`spec-init`, `push-scenarios`, `sync-run`, `push-docs`, `lint`. The existing verbs are unchanged.

### A6. During and after a run

`tracker.sh sync-run --run <id>` reads the run's files under `.qa/runs/<run-id>/` and pushes what
changed since the last sync.

- Binding: a run is tied to a list the first time it is synced. It takes the spec's open list
  (one with no run tied to it) or, when there is none, creates a new one and fills it. A new
  run always gets a new list unless it is started as a retest (`sync-run --retest`, or
  `listMode: reuse` on the spec): then the spec's last list is reset to `to test`, after each
  ticket's previous result is added to it as a comment. Nothing is guessed from the build number.
- Old lists are never edited after their run is verified and never deleted. When scenarios change
  later, only new lists follow the new plan. The tool archives all but the newest three run lists
  per spec (`keepRuns`, default 3). A removed scenario's Doc page is marked retired, not removed.
- Status from verdict: pass → `passed`, fail → `failed`, blocked → `blocked`, error → `blocked`
  with a comment that it could not be checked, deferred → `skipped` with the reason. A pass at low
  confidence stays in `testing` with "Needs a person's review" ticked and a comment saying what to
  confirm; only a person moves it to `passed`. A scenario ticket takes the worst status of its
  subtasks, and `testing` while some are still open or waiting for review.
- The run list is the tool's record. The tool sets status and sets no assignee. People read,
  comment, confirm a review, or override a result; work on a failure happens in its bug ticket. If
  a person changed a ticket's status after the tool last wrote it, the tool leaves that ticket
  alone and reports it.
- Evidence: the screenshots bound to a criterion are attached to its subtask. `evidence` is
  `standard` (default: every screenshot of a failed or blocked check, one of a passed check),
  `failures` or `none`, with a cap per ticket (default 3). Evidence text is redacted as today;
  images cannot be, so the rules file says what screenshots may show.
- Quiet by default: creating and updating tickets notifies and mentions nobody. A project may set
  `notify` to name who gets one comment and when (for example the QA lead when a run is verified).
- When it runs: `/qa-verify` always runs it, and the person or the qa-kit agent can run it at any
  time; it is safe to repeat. In the second release (see Releases), a qa-kit hook on Claude also
  runs it after each checkpoint write so the board moves while the run is going.

### A7. Required once set up

For a spec with ClickUp enabled, a failed ClickUp step is a failed step: the command stops, says
what failed in one plain line, and how to retry. `/qa-verify` does not report the run as complete
until `sync-run` and `push-docs` have succeeded. A missing token, a missing field or a missing
status is reported the same way. For a spec without ClickUp set up, no command contacts ClickUp
and nothing changes from today.

The live hook in A6 is the one exception: a failure there is reported and retried at the next
checkpoint, because the engine's run cannot be stopped from outside. `/qa-verify` is the gate.

### A8. Writing rules

`qa-kit/templates/trackers/writing-rules.md` ships in the plugin and is copied into
`docs/agents/qa-tracker.md` at setup. Every command that writes text for ClickUp reads it first.
It carries the owner's rules:

- Write like a person on the team who was in the meeting. Do not explain the product back to the
  reader or define terms they use.
- Short, plain titles: the symptom or the action, lowercase after the first word. No headline
  style, no inflating adjectives, no metaphors.
- No emojis.
- Describe what the reader will see on screen. No commit hashes, pull request numbers, version
  internals, file names, code terms, criterion ids or rule ids.
- No mention of AI, agents or automation, and no signature.
- Do not give every item the same template. A parent ticket is a one-line goal and its list.
- Never mention or tag a person unless the config names who to tag and when.
- Test data in examples follows the project's data rules.

`tracker.sh lint` enforces what a script can: emojis, the forbidden words and patterns already in
the config, id-like tokens, title length and title case, and empty or duplicated text. A failed
lint blocks the push for that item, as the wording filter does today.

### A9. The Docs

- **Spec Doc** (in the spec's subfolder): Overview (what is covered, roles, what is left out), one
  page per scenario (storyline, checks, a table of its result in every run), one Results page per
  run (summary, scenario table with ticket links, open bugs).
- **QA overview Doc** (in the QA folder): one table of specs with the latest run, counts, ready or
  not, and links; then open bugs by severity. This is the dashboard.

Pages are rewritten whole from local files on each `push-docs`, so they cannot drift. If the
project sets `reportUrl` to a place it hosts reports, the Results page links to it.

## Releases

1. **First:** the setup levels, the folder structure, `tracker-cards.json` and the lint, the
   tickets, `sync-run` at `/qa-verify`, the Docs, and the command wiring (A1, A2, A3 by hand, A4,
   A5, A6 without the hook, A7, A8, A9).
2. **Second:** the live hook during a run and the browser-driven setup (`/qa-tracker --browser`).

## Left to the builder

- Module split inside `qa-kit/scripts/trackers/` (`clickup.py` is already 1,437 lines).
- Exact view definitions, field names and the label format for run lists.
- How `sync-run` finds a run's spec from the run's manifest.
- The Claude hook's matcher and how it stays quiet when no spec has ClickUp enabled.
- Tests: recorded API responses only, no live calls, added to `tests/qa-tracker/` and the qa-kit
  CI gate; the adapters regenerated and validated.
- An ADR for the spec layout, the docs (`qa-kit/README.md`, `CLAUDE.md`, `CHANGELOG.md`), and the
  version bump with its tag.

---

# Part B: the unattended journey (`/qa-auto`)

## Why

qa-kit is a sequence of six commands a person types, and several of them stop to ask the person
something. The owner wants one agent to drive the whole process for a target from the first step
to the verified result with nobody present: write the spec, question its own choices, write the
scenarios, check coverage, run, verify, and report, with ClickUp kept current when the spec is
tracked there.

What exists is partial. The `humanInteraction.autonomousSetup` flag removes three questions
(roles, who may reach each screen, the expected-value page). `scripts/qa-ci.sh` runs the engine
unattended from a checklist that already exists. Nothing drives the steps in order, and the other
questions still wait for a person.

## Goals

1. `/qa-auto <target>` runs constitution → spec → scenarios → analyze → run → verify without
   stopping for a person.
2. Every question a step would have asked is answered by the agent from evidence, and written down
   with the evidence, as an assumption.
3. A second, independent look at those answers that can only hand a question to a person, never
   approve one.
4. A fixed list of things the agent never decides, checked by a script after the journey.
5. The journey survives an interruption: started again, it continues where it stopped.
6. One handoff list at the end: what was decided without a person and what a person still owes.
7. It works on all four harnesses.

## Non-goals

- Fixing the application's bugs. The journey ends with a verified report and a bug list (owner
  decision: QA only).
- Setting up the project from nothing: `.qa/config.json` and working sign-in for the roles must
  exist. The journey stops with a plain message when they do not.
- Running several targets in one command.
- A headless shell runner for CI. Stage 2 (see Stages); the state machine is built so it can be
  added without change.
- Changing what `autonomousSetup` means for a person who sets it without `/qa-auto`.

## Anti-goals

- A result that looks more trustworthy than it is: an assumption shown as a confirmation, or a
  pass at high confidence that rests on a value only the agent chose.
- The agent writing to an environment, excluding coverage, or loosening a safety setting to get
  further.
- A journey that reports "done" while ClickUp, verification or the handoff list is missing.
- Any change to the engine (ADR-0022), and any step that turns a non-pass into a pass or raises a
  confidence (ADR-0032, ADR-0033).

## Constraints found

- On Claude, an agent started by a command cannot start further agents. `/qa-run` dispatches the
  engine agent and then runs re-adjudication itself. So `/qa-auto` must run in the main session and
  call each step's instructions inline, not as a nested agent.
- Only Claude can dispatch a fresh agent (`harness-profiles.json` `subagentDispatch`). The second
  look (goal 3) is therefore Claude-only, with the same "unavailable" banner pattern
  re-adjudication uses elsewhere.
- `CONTEXT.md` reserves the word "autonomous" for the setup flag and says not to use it
  unqualified. This design uses **unattended journey** for the new thing.
- Run state belongs in files, never in the agent's memory (ADR-0002).
- The questions that stop a person today, by step:
  - Constitution: which roles are real; who should reach each screen.
  - Spec: the scope, role overrides, whether to run the seed command, which journeys are P1.
  - Scenarios: tricky input values and expected results for calculated checks; coverage exclusions.
  - Analyze: fixes for the gaps it lists; accepting a census built without the stack adapter.
  - Run and verify: none.

## Approaches

**A. One instruction file** telling the agent to run the six commands in order. Smallest, but the
order, the answers and the limits live only in the agent's context. A long run loses its place
when context is compacted, and nothing outside the agent checks the limits. Rejected.

**B. A state machine in a script with a thin command over it (picked).** `auto.sh` keeps the
journey on disk and decides what is next; the agent does each step's work and records its answers
through the script; the script audits the limits at the end. Resumable, portable, testable without
a model.

**C. A headless runner only**, starting a fresh agent per step from the shell. Good for CI, no use
inside a session. Deferred to stage 2 on top of B's script.

The owner handed the choice to the author; B is the author's pick.

## The design

### B1. The command and the journey

`/qa-auto <target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]` in
`qa-kit/core/commands/qa-auto.md`.

The journey for a target lives in `.qa/specs/<target>/auto/`:

- `journey.json`: the steps with their state (`pending`, `running`, `done`, `stopped`), the run id
  once there is one, start and end times, and the stop reason if any.
- `decisions.json`: every self-answered question (B3).
- `baseline.json`: the snapshot the audit compares against (B5).
- `handoff.md`: the list for a person (B6).

`qa-kit/scripts/auto.sh` owns these files. Verbs:

| Verb | Does |
|---|---|
| `start <target>` | Checks the preconditions (B2), writes `baseline.json` and `journey.json`. Refuses if a journey is already open, unless `--restart`. |
| `next <target>` | Prints the next step and what it needs, from the files on disk (the same checks `/qa-status` makes), or `done`, or `stopped: <reason>`. |
| `decide <target>` | Records one decision (B3). Refuses a decision of a forbidden class (B4). |
| `step-done <target> <step>` | Marks a step done after checking its artifact exists. |
| `audit <target>` | Runs the checks in B5. Exit 1 on any violation. |
| `handoff <target>` | Writes `handoff.md` from the decisions and the run's files. |
| `status <target>` | Prints the journey as JSON. Read-only. |

The command is a loop: `next` → do that step following its own command source with the rules of
this design → `step-done` → `next`, until `done` or `stopped`. Then `audit`, then `handoff`. Each
step is the existing command's instructions; `/qa-auto` adds no second copy of them.

Starting `/qa-auto <target>` again while a journey is open continues from `next`. A run that was
interrupted mid-verify is continued with the engine's own resume (`/qa-resume`), not restarted.

Starting it after a journey has finished opens a new journey; the finished one moves to
`auto/history/<n>/`. The new journey keeps the spec and scenarios that exist (those steps are
already done), and runs analyze, a full new run, and verify. There is no partial re-run: the
engine runs a whole plan, and a confirmation changes the plan, so the earlier run no longer matches
it. `--restart` abandons an open journey and resets only `auto/`.

**Files a person wrote are never regenerated.** A step whose artifact exists is done, whoever
wrote it. Exclusions, a `seed.json` and `oracleSource: "human"` rows that exist at `start` are
taken into the baseline as they are; the audit only looks at what changed during the journey. To
have a step redone, a person removes its artifact or runs that step's own command.

**An existing constitution is reused.** The journey runs the constitution step only when the
project has none. Regenerating it would change project-wide state that other specs snapshot.

**The profile is the person's choice, not the agent's.** The journey runs under the project's
profile. `--profile` at launch sets it for this spec's run-config, as `/qa-spec` does today; the
agent never picks or changes it. Under `full` there is no coverage gate, no journeys and no ship
verdict, so the `journeys` and `gaps` rules in B3 do not apply and the result line is "verified"
or "not verified", with no "ready".

### B2. Preconditions and hard stops

`start` refuses, with one plain line each, when:

- `.qa/config.json` is missing. The journey does not invent a config, credentials or accounts.
- The environment resolves to production. An unattended journey does not run there.
- `.qa/known-defects.json` exists and `known-defects.sh validate` rejects it (the run could never
  verify).
- Another journey is open in this project, for any target. Journeys share browser sessions,
  accounts and data, so only one runs at a time.
- The environment is not local and `gates.dataPolicy` is not `enforce`. The data policy check is
  what keeps marked or careless data off a shared environment when nobody is watching.

The command, not the script, then runs the engine's pre-flight (a qa-kit script cannot call an
engine script); a dead application stops the journey there.

Sign-in is checked after the constitution step, when the roles are known: `auto.sh` checks that
each persona has its sign-in configured (the file or entry the config names; presence only). Real
sign-in happens in the run. A persona without it stays in the plan; the engine records its checks
as `blocked`, and the handoff lists the persona. If no persona has sign-in configured, the journey
stops.

During the journey it stops, keeps everything written so far, and writes the handoff when:

- the time limit is reached (`--max-hours`, default 6). `auto.sh next` checks it between steps and
  the command checks it between criteria batches where the engine allows a clean pause; started
  again, the journey continues from the same point;
- analyze is still `BLOCKED` after two rounds of adding scenarios (B3, "gaps");
- a step's script fails for a reason the agent cannot fix by redoing the step once;
- ClickUp is required for the spec and a ClickUp step fails (A7);
- the audit fails.

**How the setup questions are skipped.** No config is edited and nothing is written to the spec's
run-config for this (the run-config merge replaces whole top-level keys, so it would drop
`humanInteraction.enforce` and `maxOptOutRate`, and it would outlive the journey). The open
journey itself is the signal: each qa-kit command source gains one line, "an open unattended
journey for this target (`auto.sh status`) counts as `autonomousSetup` on for this step", and
`/qa-constitution` tells the engine's role-confirmation skill to take its autonomous setup path,
with the reason `unattended journey`. When the journey closes, a person running any step is asked
as usual.

### B3. Answering its own questions

Before each step the agent lists the questions that step would ask a person. For each it looks for
evidence in the project (the code, routes and permissions, an ingested spec-kit, the census, the
constitution, existing docs), answers, and records the answer with
`auto.sh decide <target> --step <step> --class <class> --question … --answer … --evidence …
--confidence high|low`. A decision is always stored as `assumption: true`.

How each class of question is answered:

| Class | Answer rule |
|---|---|
| `roles` | Accept discovered roles (the existing `autonomousSetup` behaviour). |
| `surface-access` | Assume, never deny (existing behaviour). |
| `scope` | The target's screens from the census and the routes that serve them. When unsure whether a screen belongs, include it. |
| `role-overrides` | None, unless the code shows the target treats a role differently. |
| `journeys` | Journeys from what users do end to end in the target. When unsure whether one is P1, mark it P1: the cost of a wrong P1 is extra checking, the cost of a missed one is a false "ready". |
| `inputs` | The tricky input values for a calculated check (boundaries, rounding cases), chosen by the agent. |
| `expected` | A value with `oracleSource: "spec"` only when a spec line can be cited and `check-fixtures.sh` resolves it. Otherwise the value is a proposal, the check can pass only at low confidence, and it goes on the handoff list. Never `oracleSource: "human"`. |
| `gaps` | For a gap analyze lists, add scenarios or checks that close it and run analyze again. At most two rounds. |

**The second look (Claude only).** After the spec step and after the scenarios step, a fresh agent
is given only that step's decisions, their evidence and the artifact. It answers per decision
`stands` or `ask a person`, with a reason. `ask a person` sets `needsPerson: true` on the decision;
it cannot change an answer or approve one. Where a fresh agent cannot be dispatched, the journey
prints the "second look unavailable" line, marks every low-confidence decision `needsPerson`, and
goes on. The acting agent never reviews its own decisions.

### B4. What the agent never decides

`auto.sh decide` refuses these classes, and the step goes on without them:

| Never | What happens instead |
|---|---|
| Running a seed command (`seed`) | No `seed.json` is written; the spec stays declare-and-verify. Listed on the handoff. |
| Excluding a screen or role pair from coverage (`exclusion`) | Nothing is excluded. If coverage cannot be reached, analyze stays `BLOCKED` and the journey stops. |
| Accepting a census built without the stack adapter (`crawl-only`) | Not accepted (already the rule under `autonomousSetup`). |
| Confirming an expected value as a person (`oracle-human`) | See `expected` in B3. |
| Changing a safety setting (`safety`): `allowApiWrites`, `seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, `gates.*`, `profile`, `humanInteraction.enforce`, `maxOptOutRate` | Left as the project set them. |
| Moving a check into the known-defect registry (`known-defect`) | The registry is not touched: an entry without `ticket` and `expiry` fails verification for every spec. A check that asserts an application failure is left out of the plan and listed on the handoff. |

### B5. The audit

`auto.sh audit` compares the end state with `baseline.json` and fails the journey on any of:

- a safety setting in `.qa/config.json` differs from the baseline;
- the spec's `run-config.json` sets any key of the safety list other than the `profile` given at
  launch;
- `.qa/known-defects.json` changed;
- a `checklist.json` row has `oracleSource: "human"` that it did not have at the start;
- `seed.json` appeared, or `coverage-exclusions.json` gained an entry, during the journey;
- a decision of a forbidden class is recorded;
- a step is marked done without its artifact, or the run has no `verification.json`;
- the spec is tracked in ClickUp and `spec-status` says ClickUp is behind.

The audit is a script reading files. It does not trust the agent's account of what it did. A
failed audit makes the journey `stopped: audit`, and the handoff leads with the violation.

### B6. The handoff

`handoff.md`, written at the end of every journey, complete or stopped, in plain words:

1. The result, which is never better than the engine's and is stricter in one way. It says
   "ready" only when the engine's ship verdict is SHIP-READY **and** no P1 check rests on a
   decision marked `needsPerson` or on an expected value that is only a proposal. Otherwise it
   says "not confirmed: N items need a person", even if a fresh agent agreed with the evidence
   during re-adjudication. Other results: not ready with the reasons, verified or not verified
   (under `full`), or stopped and why. `auto.sh handoff` computes this from files.
2. Decided without a person: each decision, grouped by step, with its evidence in one line.
3. Needs a person: decisions marked `needsPerson`, expected values that are only proposals, checks
   that passed at low confidence, the seed command that was not run, known defects missing a
   ticket.
4. How to confirm: the existing tools, by name. The expected-value page
   (`oracle-confirm.sh render`), the access table (`surface-access.sh confirm-table`), and
   `/qa-auto <target>` again after confirming, which starts a new journey on the confirmed plan
   (B1).
5. The scope the agent chose for the spec, always shown, because a scope that is too narrow hides
   gaps the coverage gate cannot see.

### B7. Harnesses and long runs

- `/qa-auto` is a normal qa-kit command source, generated for all four harnesses (ADR-0024).
- The second look and re-adjudication follow `subagentDispatch`; elsewhere their banners print.
- On a laptop the command's first line tells the agent to keep the machine awake for the journey
  (`caffeinate -dimsu` on macOS) and to release it at the end.
- `/qa-status` shows an open journey: the step it is on, and how many items wait for a person.

### B8. ClickUp

ClickUp is not a step of the journey. It is a setting on the spec that any step honours.

- A spec that is tracked: every step syncs as part A describes, and a failed sync stops
  the journey.
- A spec that is not tracked: the journey never contacts ClickUp and never asks.
- A new spec written by the journey: tracked from the start only when the project file sets
  `specDefaults.enabled: true`. This is the `specDefaults` key of A2. Without it the spec is
  untracked until a person runs `/qa-tracker --spec <target>`, at any point, after which later
  steps and the next journey sync.
- When tracked, one comment is posted on the Run summary ticket (`spec-note`): how many items
  need a person's review and where the results page is. It is built from fixed sentences and
  counts, never from the agent's decision text, so it cannot fail the wording check on content.

**Build order.** Both parts are built together from one plan. The journey script does not need
ClickUp to exist: its only contact is the `tracker.sh spec-status` call in the audit and the
`spec-note` call in the command, and both are no-ops for an untracked spec.

### B9. Owner decisions (2026-11-27)

- **No written requirements.** The journey still runs. Every expected result taken from the
  application is a proposal (B3 `expected`), and the handoff opens with: "No written requirements
  were found for this target. Expected results were taken from the application and need a
  person." `auto.sh decide` records `--evidence none` for these so the handoff can count them.
- **Created records.** The handoff lists every record the run created (type and id, from
  `data-policy.sh list`). The journey deletes nothing.
- **Bugs.** Filed under the existing rules only: a failure with evidence is a bug, a repeat is a
  comment, a known defect is a duplicate, an evidence gap goes to needs-recheck. No separate
  review queue.
- **Default is the whole journey.** `--until scenarios` is for reading the plan before the run.
- **Harnesses without a fresh agent** still run the journey; every low-confidence decision is
  marked `needsPerson`.
- **Finish signals:** the handoff file, the ClickUp comment on a tracked spec, and the
  `/qa-status` line. No other alert in stage 1.

## Stages

1. **Stage 1:** `auto.sh` with all verbs, `/qa-auto`, the decision rules, the second look, the
   audit, the handoff, `/qa-status` line, the `specDefaults` key.
2. **Stage 2:** a headless runner (`qa-auto-ci.sh`) that starts a fresh agent per step from the
   shell using the harness's agent command, driven by `auto.sh next`.

## Left to the builder

- The exact JSON shapes of `journey.json`, `decisions.json` and `baseline.json`.
- jq with a python3 fallback for `auto.sh`, as the other qa-kit scripts do.
- How the journey's run-config turns `autonomousSetup` on without touching `.qa/config.json`
  (`runconfig-merge.sh` exists for this).
- The fixed table that turns engine reasons into plain handoff sentences.
- Tests: a new `tests/qa-auto/run.sh` suite over fixture projects, no model and no browser; added
  to `run-qakit-ci.sh` and the suite-coverage gate.
- An ADR, the term **unattended journey** in `CONTEXT.md`, README, CHANGELOG, version bump.
