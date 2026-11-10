# QA tracker: GitHub

Test cases stay in the catalog. Runs and bugs are meant to live in GitHub Issues.

**Not yet available in this version.** The GitHub adapter is not shipped. This file and the config
record the choice, but every verb that needs GitHub exits 2 with "github does not support <verb>".
Use the local backend or ClickUp until it ships.

## Planned layout

- A run is one issue with a results table.
- Bugs are issues labelled `qa-bug` with a `severity:*` label.
- Retest notes are comments.

## Commands

- `init`: not yet available.
- `push-plan`: not yet available. Cases stay in the catalog.
- `pull-plan`: not yet available.
- `push-run`: not yet available.
- `push-results`: not yet available.
- `push-bug`: not yet available.
- `update-retest`: not yet available.
- `status`: not yet available.
- `validate`: checks the catalog against the schema. Works today.
- `results`: prints each case's result for a run, as JSON. Works today.

## Rules

- Nothing is ever deleted, and bugs are never closed by the tool.
- Keep passwords and tokens out of anything you file by hand.
