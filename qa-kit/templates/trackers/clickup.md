# QA tracker: ClickUp

Test cases, runs and bugs are mirrored into a ClickUp folder. The catalog in this repository stays
the source of truth for cases.

## Setup

- The token comes from the environment variable `CLICKUP_API_TOKEN`. It is never written to a file.
- The workspace, space and folder ids are in `docs/agents/qa-tracker.json`.
- Some parts of the layout cannot be created through the ClickUp API: custom fields and
  list-specific statuses. `tracker.sh init` prints a numbered click list with exact names. Do those
  clicks by hand, then run `init` again so it reads the ids back into the config.
- When `guideAs` is `doc`, the guides live in the "QA Guide" doc in the folder's space, one page per
  guide file. Sign-off criteria stay as tasks in the guide list.

## Who owns what

- The status of a case belongs to the tester. The tool changes it in two cases only:
  `push-results` moves a case from `to test` to `testing` when `statusCeiling` is `testing`, and
  `push-plan` sets retired or orphaned cases, and guide tasks retired into the doc, to `skipped`.
  With your own status names, the first and second case statuses and the last one play those roles.
- The tool writes only its own fields, "Last check result" and "Last check run", and adds comments.
- Bugs are created in `open` (the first bug status). The tool never moves or closes a bug. The
  team owns bug status.
- If a person edits a case description in ClickUp, the tool reports it as drift and skips that case
  until someone copies the edit into the catalog or passes `--overwrite`. Drift detection works on a
  machine that holds the last-pushed cache (`.qa/tracker-map.json`); without it, the catalog wins.
- Nothing is ever deleted. A case the catalog no longer lists is tagged `retired`, gets a comment,
  and is set to `skipped`.

## Commands

Run them as `bash <qa-kit>/scripts/tracker.sh <verb>`. Each verb is a dry run until you add `--apply`.

- `init`: builds the folder from the config: guide list or doc, one list per area, a Runs list, a
  Bugs list. Prints the clicks it cannot do itself.
- `push-plan`: sends the catalog to ClickUp. Creates missing cases and updates the ones whose content
  changed.
- `pull-plan`: reads cases added in ClickUp and writes them as drafts to `.qa/tracker/pulled/`,
  never into the catalog. Copy what you want into the catalog by hand. Edits are reported, not
  merged.
- `push-run`: creates the run record with its build, environment and counts.
- `push-results`: writes each case's result into "Last check result" and "Last check run" and adds
  a comment with the evidence summary.
- `push-bug`: files each new bug with its case link, severity, steps, expected and actual. A bug that
  is already open gets a "still happens" comment instead of a second task.
- `update-retest`: for bugs in `retest`, comments whether the linked case passed on this run. It
  never closes the bug.
- `status`: shows what each verb would change, including drift.
- `validate`: checks the catalog against the schema. Exit 0 only when it is clean.
- `results`: prints each case's result for a run, as JSON.

## Config keys and flags

Flags, added after the verb:

- `--run <run-id>`: the run under `.qa/runs/` to send. Default: the newest run with a checkpoint.
- `--label <text>`: the run's name in ClickUp. Default: the run date plus the build version.
- `--only <area file> ...`: `push-plan` sends only these catalog areas, and retires nothing.
- `--overwrite <case id> ...`: `push-plan` replaces these cases' descriptions even when someone
  edited them in ClickUp.

Keys in `docs/agents/qa-tracker.json`:

- `statusCeiling`: `none` (the default) never moves a case. `testing` lets `push-results` move a
  case from `to test` to `testing`, and no further.
- `lists.guide`, `lists.runs`, `lists.bugs`: list names, when you want something other than
  "00 – Guide & Sign-off", "Runs" and "Bugs".
- `wording.allow`: phrases the forbidden-word check lets through. "AI" is a forbidden word in
  generated text (run names, results, comments and bugs), so a product named "AI …" must be listed
  here, or every item that names it is skipped.
- `bugsTo`: `same` (the default) files bugs in the Bugs list. `issue-tracker` leaves bugs to the
  project's issue tracker, and `push-bug` and `update-retest` do nothing.

## Rules

- Text sent to ClickUp is read by testers and customers. It is checked against the forbidden words in
  the config, and passwords are masked. An item that fails is skipped, not sent in part.
- ClickUp allows about 100 requests a minute. The tool waits between writes.
