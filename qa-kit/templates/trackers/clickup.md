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

- The status of a case belongs to the tester. The tool never sets or changes it.
- The tool writes only its own fields, "Last check result" and "Last check run", and adds comments.
- Bugs are created in `open`. The tool never moves or closes a bug. The team owns bug status.
- If a person edits a case description in ClickUp, the tool reports it and skips that case until
  someone copies the edit into the catalog or asks for an overwrite.
- Nothing is ever deleted. A case the catalog no longer lists is tagged `retired`, gets a comment,
  and is set to `skipped`.

## Commands

Run them as `bash <qa-kit>/scripts/tracker.sh <verb>`. Each verb is a dry run until you add `--apply`.

- `init`: builds the folder from the config: guide list or doc, one list per area, a Runs list, a
  Bugs list. Prints the clicks it cannot do itself.
- `push-plan`: sends the catalog to ClickUp. Creates missing cases and updates the ones whose content
  changed.
- `pull-plan`: reads cases added in ClickUp back into the catalog as drafts. Edits are reported, not
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

## Rules

- Text sent to ClickUp is read by testers and customers. It is checked against the forbidden words in
  the config, and passwords are masked. An item that fails is skipped, not sent in part.
- ClickUp allows about 100 requests a minute. The tool waits between writes.
