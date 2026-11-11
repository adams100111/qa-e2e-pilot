# QA tracker: local files

Test cases, runs and bugs are kept in this repository. Nothing leaves the machine.

## Where things live

- Cases: the catalog (`catalog` in `docs/agents/qa-tracker.json`, default `.qa/catalog/`).
- Runs: `.qa/runs/<run-id>/`, plus a results table in `.qa/tracker/runs/<run-id>.md`.
- Bugs: `.qa/tracker/bugs/NNN-<slug>.md`, one file per bug, with its status, severity, case and
  reference in the front matter.

## Commands

Run them as `bash <qa-kit>/scripts/tracker.sh <verb>`. Each verb is a dry run until you add `--apply`.

- `init`: creates the `.qa/tracker/runs` and `.qa/tracker/bugs` folders.
- `push-plan`: nothing to do. Cases live in the catalog, so there is nothing to send.
- `pull-plan`: nothing to do, for the same reason.
- `push-run`: writes the run's results table to `.qa/tracker/runs/<run-id>.md`. A re-run rewrites the
  file only when its content changed.
- `push-results`: writes the same table, one row per case with its result.
- `push-bug`: writes each new bug from the run as a bug file, skipping rows the export marks as a
  duplicate or that have no title. A bug that is already open gets a
  "Still happens on <build>" line instead of a second file.
- `update-retest`: for bugs in `retest`, adds a line saying whether the case passed or is still
  failing on this run. A case that was blocked, deferred or errored, or has no result in this run,
  gets no line. It never changes the status.
- `status`: shows what each verb would change.
- `validate`: checks the catalog against the schema. Exit 0 only when it is clean.
- `results`: prints each case's result for a run, as JSON.

## Config keys and flags

Flags, added after the verb:

- `--run <run-id>`: the run under `.qa/runs/` to write. Default: the newest run with a checkpoint.
- `--label <text>`: the run's name in the files. Default: the run date plus the build version.
- `--only` and `--overwrite`: no effect here. They choose catalog areas and cases for `push-plan`
  on ClickUp, and local cases never leave the catalog.

Keys in `docs/agents/qa-tracker.json`:

- `statusCeiling`: no effect here. The tool never changes a status in a bug file.
- `lists.guide`, `lists.runs`, `lists.bugs`: no effect here. They name ClickUp lists.
- `wording.allow`: phrases the forbidden-word check lets through. "AI" is a forbidden word in
  generated text (run tables and bugs), so a product named "AI …" must be listed here, or every
  item that names it is skipped.
- `bugsTo`: `same` (the default) writes bug files. `issue-tracker` leaves bugs to the project's
  issue tracker, and `push-bug` and `update-retest` do nothing.

## Rules

- A person changes a bug's status by editing its file. The tool only adds lines.
- Nothing is ever deleted.
- Keep passwords and tokens out of cases, runs and bugs.
