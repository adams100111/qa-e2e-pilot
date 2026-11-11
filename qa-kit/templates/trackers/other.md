# QA tracker: other

Test cases, runs and bugs are tracked somewhere qa-kit has no adapter for. This file is the record.
Replace the section below with the project's own description.

## How this project tracks QA

<One paragraph: the tool, where cases live, where runs are recorded, where bugs are filed, who owns
each status.>

## Commands

With `backend: "other"` nothing is sent anywhere. `validate` and `results` work for every backend,
because they read only the catalog and the run. Every other verb exits 2 with "other does not
support <verb>", and that work is done by hand following the prose above.

- `init`: exits 2.
- `push-plan`: exits 2.
- `pull-plan`: exits 2.
- `push-run`: exits 2.
- `push-results`: exits 2.
- `push-bug`: exits 2.
- `update-retest`: exits 2.
- `status`: exits 2.
- `validate`: checks the catalog against the schema. Exit 0 only when it is clean.
- `results`: prints each case's result for a run, as JSON.

## Rules

- Nothing is ever deleted, and bugs are never closed by the tool.
- Keep passwords and tokens out of anything you record.
