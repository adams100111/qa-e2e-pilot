# QA tracker: test cases, runs and bugs in local files, GitHub or ClickUp

Plan: `docs/superpowers/plans/2026-11-11-qa-tracker.md`. Amended 2026-11-11: config lives in
`docs/agents/qa-tracker.json` (`.qa/` is git-ignored), and field names say "check", not
"automated", so they pass D7.

Date: 2026-11-10 · Status: accepted · Plugins: qa-kit (owner), qa-e2e-pilot (unchanged contracts)

## Why

A QA effort needs a place where people see the test plan, which cases passed on which build, and
which bugs are open. Today the plugin keeps all of that in `.qa/` and stops there. Projects then
build their own bridge. The Innovation project's bridge is `docs/qa/sync_clickup.py`: a catalog of
1,065 YAML test cases that it syncs into a ClickUp folder, one list per area.

An audit of that folder (2026-11-10) found the cases good and the tracking missing:

- One status per case and no run dimension, so a second test run overwrites the first.
- No custom fields, views or dashboard, so the sign-off rules can only be checked by hand.
- Evidence is a checkbox written into the description.
- Bugs live in three places and none links to a case.
- The catalog and ClickUp had drifted apart. The 0.12.2 clean-up fixed that drift and removed a
  shared password from 101 task descriptions.

The plugin should make this setup something a project picks, not something it builds. The pick
should work the way the setup step in Matt Pocock's skills works: ask once, write the answer into
the repo, and every later step reads it.

## Goals

1. `/qa-tracker` asks which tracker the project uses: local files (default), GitHub or ClickUp. It
   writes the answer in two forms: rules a person can read, and config a script can read.
2. One local store is the source of truth: cases, runs, per-case results and bugs. Every tracker
   is a mirror of it, written by deterministic scripts. No language model writes tracker content.
3. Five operations, the same for every tracker: pull plan, push run, push results, push bug,
   update retest. Each has an idempotency key, so a re-run never creates a duplicate.
4. The ClickUp layout the Innovation folder uses can be generated for any project: guide list,
   one list per area, Bugs list, statuses, fields and views, built from config.
5. People's work is safe: the agent never overwrites a status a person set, never closes a bug,
   and never deletes anything.

## Non-goals

- Jira, Linear and other trackers. As in Matt Pocock's setup, "Other" is recorded as prose rules
  and nothing runs automatically.
- Two-way sync of free text. Edits a person makes to a case in ClickUp are not merged back into
  the catalog. The adapter reports them as drift.
- Replacing the engine's run record. `.qa/runs/<run-id>/` and the 0.12.2 `bugs/` export stay as
  they are, and the tracker reads them.

## Anti-goals (these would make it a failure even if it works)

- Tracker content that mentions AI, agents, automation, file paths, branches or code identifiers.
  Trackers are read by testers and customers.
- A tracker that silently diverges from the catalog again, the way TC-REP and TC-RPTS did.
- Any secret in a pushed description.

## The decisions

### D1. Where it lives

qa-kit owns trackers, because the tracker belongs to the process (plan, cases, sign-off), not to
verification. The engine's contracts don't change: `bug-log.sh` (0.12.2), `bug-export.sh`
(`bugs.json`), `checkpoint.json`, `journeys.sh status`, `verification.json`.

New in qa-kit:

- `commands/qa-tracker.md`
- `scripts/tracker.sh <verb>`, the dispatcher
- `scripts/trackers/{local,github,clickup}.py`
- `templates/trackers/*`

The adapters for remote trackers are python3-only. They call the network, so the engine's jq
parity rule does not apply. Everything they compute from local files goes through pure functions
that have tests.

### D2. Setup: `/qa-tracker`

It runs in Matt Pocock's order:

1. Look at what exists: the git remote, `docs/agents/issue-tracker.md`, `docs/agents/qa-tracker.json`, any
   existing catalog.
2. Say what it found.
3. Ask one question at a time, with the recommended answer first:
   1. **Where do test cases, runs and bugs live?** Local files (recommended without a remote),
      GitHub (recommended for a GitHub remote), ClickUp (asks for the workspace and, if one
      exists, the folder), or Other (described as prose).
   2. **Where do bugs go?** The same tracker (recommended), or the issue tracker the project
      already uses. If `docs/agents/issue-tracker.md` exists, the setup reads it and offers it.
   3. **Keep the default statuses?** Yes is recommended: `to test`, `testing`, `failed`,
      `blocked`, `passed`, `skipped` for cases, and `open`, `triaged`, `fixing`, `retest`,
      `closed` for bugs. If not, it collects the project's names so nothing is created twice.

It writes:

- `docs/agents/qa-tracker.md`: rules a person or agent reads. It says how each operation is done
  on this tracker and lists the tracker's quirks. It is seeded from
  `templates/trackers/<backend>.md`.
- `docs/agents/qa-tracker.json`: config the scripts read. Example:
  `{backend, catalog: "docs/qa/catalog", ids: {...}, statuses: {...}, fields: {...}, statusCeiling, wording: {forbidden: [...]}}`.
- A short "QA tracker" entry under `## Agent skills` in `CLAUDE.md` or `AGENTS.md`, pointing at the
  rules file.

Re-running the setup shows the current answers and changes only what the user changes.

### D3. The local store (the source of truth)

| What | Where | Written by |
|---|---|---|
| Cases | Catalog YAML. `catalog` in tracker.json (default `.qa/catalog/`; Innovation keeps `docs/qa/catalog/`): `manifest.yaml` plus one file per area | People, or `pull-plan` as drafts |
| Runs | `.qa/runs/<run-id>/` (engine, unchanged). A manual run by a tester is `.qa/runs/<run-id>/manual-results.json` | Engine / `tracker.sh record` |
| Results per case | Derived. A case's result in a run is rolled up from the run's criteria tagged `case:<TC-id>` (worst verdict wins), or taken from `manual-results.json` | `tracker.sh results <run-id>` (pure) |
| Bugs | Each run's `bugs/bugs.json` (engine export) plus `.qa/bugs/` for bugs filed by hand. Each bug carries a `fingerprint` (criterion or case, persona, normalised title) | Engine / `tracker.sh file-bug` |
| Id map | `.qa/tracker-map.json`: local id → remote id, plus the content hash last pushed | Adapters only |

The catalog schema is the Innovation one, made generic. A case has:

- `id`, `title`, `priority` (P1–P3), `type`, `level`, `preconditions`, `steps[]`, `expected[]`;
- optionally `roles[]`, `retired` and `retired_reason`, and `refs[]` (code pointers, never pushed).

An area has an `intro` (what the area covers, accounts, before you start, run order). The schema
lives in `qa-kit/templates/catalog-schema.json`, and `tracker.sh validate` checks it. This
replaces the project-local integrity test.

Engine criteria join a case through a `case:<TC-id>` tag, the same way `journey:<id>` works. The
v3 run's `catalogRef` becomes that tag.

### D4. The five operations

Every adapter implements the same verbs. Each is dry-run by default and writes only with
`--apply`.

| Verb | Does | Idempotency key |
|---|---|---|
| `init` | Builds the tracker's structure from config (D6). | Names in tracker.json |
| `push-plan` | Catalog → tracker. Creates missing cases. Updates title, description, priority and tags when the content hash changes. Retires cases the catalog no longer lists or marks retired (tag, comment, `skipped`). Moves a case to its area. This is today's `sync_clickup.py`, generalised. | Case id |
| `pull-plan` | Tracker → catalog, as drafts. A case added in the tracker becomes a catalog entry with `draft: true`. An edited case is reported as drift, never merged. Drafts need a person to confirm the expected result before a run may use them, because the oracle is the spec. | Case id |
| `push-run` | Creates the run record: build, environment, dates, who ran it, counts. | Run id |
| `push-results` | Writes each case's result for the run into the agent's own fields (D5) and adds a comment with the evidence summary. | Run id + case id |
| `push-bug` | Files each new bug from the run's export with its case link, severity, steps, expected and actual. A bug whose fingerprint is already open gets a "still happens on <build>" comment instead of a new ticket. | Fingerprint |
| `update-retest` | For bugs in `retest`, records whether the linked case passed on the new run, as a comment plus the retest field. It never closes the bug. | Bug id + run id |

`tracker.sh status` prints what would change for each verb, so drift is visible before anyone
syncs.

### D5. Who owns which field

- The case **status** belongs to the tester. The agent writes only its own fields: last check
  result, last check run, check evidence link. It also comments.
- `statusCeiling` (default `none`) allows a project to let the agent move `to test` → `testing`,
  and nothing beyond that.
- **Bug status** belongs to the team. The agent creates bugs in `open` and comments, nothing more.
- A person's edit to a pushed description is detected by comparing it to the last pushed content
  hash in `tracker-map.json`. The adapter reports the edit and skips that task until someone runs
  `push-plan --overwrite <id>` or copies the edit into the catalog.

### D6. Generating the ClickUp template

`init --backend clickup` reads the catalog manifest and tracker.json. In the folder it creates:

- a guide list with tasks generated from `guide/*.md`, or a ClickUp Doc when `guideAs: doc`;
- one list per catalog area, with its intro as the list description;
- a Runs list;
- one Bugs list;
- saved views:
  - per area: by status, by priority, by tester level;
  - on Runs: results by run;
  - on Bugs: open bugs by severity, bugs per case.

The public API cannot reliably create some of this: custom fields, and statuses that differ from
the folder's. For those, `init` checks what exists. When something is missing it prints a short,
numbered list of clicks with exact names, then reads the ids back into tracker.json. It never
guesses an id.

Custom fields:

- On cases: Role, Level, Last check result, Last check run, Linked bugs.
- On bugs: Severity (critical / high / medium / low), Case (relationship), Found in run, Retest
  result.
- On runs: Build, Environment, Language, Passed / Failed / Blocked counts.

Priority is derived from severity through one table, so the two can't contradict each other. The
audit found 29 that did.

The GitHub adapter keeps cases local, because a thousand issues is noise:

- a run is one issue with a results table;
- bugs are issues labelled `qa-bug` with `severity:*`;
- retest notes are comments.

The local adapter writes:

- `.qa/tracker/runs/<run-id>.md` (a results table);
- `.qa/tracker/bugs/NNN-<slug>.md`, with front matter for status, severity, case and fingerprint.

### D7. What may leave the machine

Every pushed string passes two filters before an API call:

1. **Redaction.** The same filter `bug-export.sh` uses for secrets. In addition, the value of any
   key named in tracker.json's `secrets` list is masked, so a shared test password cannot be pushed.
2. **Wording.** Any of the `wording.forbidden` words fails the push for that item, and nothing
   partial is sent. The defaults are: AI, agent, automated, automation, Claude, Playwright, bot,
   file paths, and branch or PR references.

`refs[]`, evidence file paths and run ids stay local. Evidence is attached as files, never linked
by path.

## Order of work

1. **Local backend, setup command and catalog schema.** `/qa-tracker`, tracker.json, the rules
   file, `tracker.sh validate|results|status`, and the local adapter. Done when a project can pick
   local and get run and bug files from the hackathons v3 run.
2. **ClickUp adapter.** Port `sync_clickup.py` into `push-plan` with its current behaviour and
   tests against recorded API responses. Then add `init`, `push-run`, `push-results`, `push-bug`
   and `update-retest`. Done when the Innovation folder is driven by `tracker.sh` and
   `sync_clickup.py` becomes a one-line wrapper.
3. **GitHub adapter.**
4. **Dashboard.** The QA console shows the tracker's link and its drift count.

## Left to the builder

- Exact field names and the view filter definitions.
- The fingerprint normalisation.
- The retry and backoff policy. The ClickUp limit is 100 requests a minute; today's script sleeps
  0.35 s between writes.
- How tests record API responses, as long as no test calls a live tracker.

## Owner decisions (2026-11-11)

- **Innovation's catalog stays in `docs/qa/catalog/`.** It is reviewed with the code it describes, and
  its integrity test runs in the app's suite. `catalog` in tracker.json points there; `.qa/catalog/`
  stays the default for new projects.
- **Guides move to one ClickUp Doc** (`guideAs: doc`), one page per `guide/*.md` file, so they stop
  counting as test work. **Sign-off criteria stay as tasks** in the guide list: they are pass/fail
  items someone marks at release time. The old `Guide · …` tasks are retired (tag, comment,
  `skipped`), never deleted, and their description points at the Doc.
