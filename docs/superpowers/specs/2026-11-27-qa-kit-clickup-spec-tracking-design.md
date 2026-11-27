# qa-kit ClickUp tracking per spec and run

Date: 2026-11-27 · Status: accepted (owner, 2026-11-27) · Plugin: qa-kit (owner). The engine is unchanged.

Builds on `docs/superpowers/specs/2026-11-10-qa-tracker-design.md` (the tracker shipped in qa-kit
0.4.0 to 0.4.2). That design stays in force. This one adds a second ClickUp layout beside it.

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
  ClickUp. A project that hosts reports itself can set `reportUrl` (D9).

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
have to be repeated for every spec. Rejected, also as a fallback (see D1).

Scenario above run (a list per scenario, a ticket per run) was also considered and rejected: one
run would be split across every scenario's list, so "is this build ready?" has no single place.
The scenario's history is answered by its Doc page instead.

For transport, the tool keeps direct API calls through `tracker.sh` and does not use the ClickUp
MCP: the script already has dry-run, redaction, the word filter and tests, and it runs on every
harness.

The owner picked A in conversation, with the Doc as dashboard and the browser-driven setup.

## The design

### D1. Structure in ClickUp

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

### D2. Setup levels

| Level | File | Holds |
|---|---|---|
| Machine | `~/.config/qa-kit/tracker.json` | `tokenEnv` (name of the environment variable, default `CLICKUP_API_TOKEN`), workspace id, default `evidence` |
| Project | `docs/agents/qa-tracker.json` (exists) | everything today, plus optional `templates.list`, and any machine key to override |
| Spec | the same project file, under `specs.<target>` | `enabled`, `folder` (id of the spec's subfolder), `list` (an existing list to use), `listMode`, and any key to override |

A key is read from the spec entry first, then the project file's `specDefaults`, then the project
file, then the machine file. `specDefaults.enabled: true` makes every new spec tracked from the
start without a question (used by the unattended journey; see
`2026-11-27-qa-kit-unattended-journey-design.md` D8). The token
is only ever read from the environment. Spec settings live in the committed project file because
`.qa/` is often git-ignored (builder's call recorded here: the author's).

`/qa-tracker` gains:

- a machine-wide step (`/qa-tracker --global`) that asks for the workspace and the token's
  variable name;
- a per-spec step (`/qa-tracker --spec <target>`), also offered by `/qa-spec`, with one question:
  create the subfolder, or use a folder or list URL the person pastes. A pasted ClickUp URL is
  parsed for its id and checked through the API before it is saved.

### D3. One-time structure: statuses and fields

Needed once per project, on the QA folder:

- Statuses: the six case statuses the tracker already uses (`to test`, `testing`, `failed`,
  `blocked`, `passed`, `skipped`), or the project's own names by position, as today.
- Custom fields on tickets: Role, Needs a person's review (checkbox), Build, and Ref (see D4).
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

### D4. What a ticket says

The checklist's ids, kinds and oracle lines are not readable by the audience. So `/qa-scenarios`
also writes `.qa/specs/<target>/tracker-cards.json`: for each scenario a plain title and a short
storyline, and for each check a plain title, what to do and what should happen. It is written by
the agent following the writing rules (D8), shown to the person with the scenarios, and checked by
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

### D5. What each command does

Only for a spec whose `specs.<target>.enabled` is true.

| Command | ClickUp update |
|---|---|
| `/qa-spec` | Offers the per-spec setup. Creates the subfolder and the spec Doc with its Overview page. Adds the spec to the QA overview Doc. |
| `/qa-scenarios` | Writes and lints `tracker-cards.json`. Writes the Scenarios pages. Creates the first run list and fills it with scenario tickets and check subtasks in `to test`. |
| `/qa-analyze` | Comments on the Run summary ticket: coverage gaps and whether the plan is ready, in plain words. A blocked verdict sets the Run summary ticket to `blocked`. |
| run | See D6. |
| `/qa-verify` | A final sync of the run, the Results page, the Run summary ticket (counts, ready or not ready with the reasons, a link to the Results page), bugs filed and linked, the QA overview Doc. |
| `/qa-status` | Prints the ClickUp links for the spec and its latest run, and whether ClickUp is behind the local files. Read-only. |

All of it goes through new `tracker.sh` verbs, each a dry run without `--apply`, each idempotent:
`spec-init`, `push-scenarios`, `sync-run`, `push-docs`, `lint`. The existing verbs are unchanged.

### D6. During and after a run

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

### D7. Required once set up

For a spec with ClickUp enabled, a failed ClickUp step is a failed step: the command stops, says
what failed in one plain line, and how to retry. `/qa-verify` does not report the run as complete
until `sync-run` and `push-docs` have succeeded. A missing token, a missing field or a missing
status is reported the same way. For a spec without ClickUp set up, no command contacts ClickUp
and nothing changes from today.

The live hook in D6 is the one exception: a failure there is reported and retried at the next
checkpoint, because the engine's run cannot be stopped from outside. `/qa-verify` is the gate.

### D8. Writing rules

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

### D9. The Docs

- **Spec Doc** (in the spec's subfolder): Overview (what is covered, roles, what is left out), one
  page per scenario (storyline, checks, a table of its result in every run), one Results page per
  run (summary, scenario table with ticket links, open bugs).
- **QA overview Doc** (in the QA folder): one table of specs with the latest run, counts, ready or
  not, and links; then open bugs by severity. This is the dashboard.

Pages are rewritten whole from local files on each `push-docs`, so they cannot drift. If the
project sets `reportUrl` to a place it hosts reports, the Results page links to it.

## Releases

1. **First:** the setup levels, the folder structure, `tracker-cards.json` and the lint, the
   tickets, `sync-run` at `/qa-verify`, the Docs, and the command wiring (D1, D2, D3 by hand, D4,
   D5, D6 without the hook, D7, D8, D9).
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
