# QA tracker: other

Test cases, runs and bugs are tracked somewhere qa-kit has no adapter for. This file is the record.
Replace the section below with the project's own description.

## How this project tracks QA

<One paragraph: the tool, where cases live, where runs are recorded, where bugs are filed, who owns
each status.>

## Commands

With `backend: "other"` nothing runs automatically. Every verb below exits 2 with "other does not
support <verb>", and the work is done by hand following the prose above.

- `init`: exits 2.
- `push-plan`: exits 2.
- `pull-plan`: exits 2.
- `push-run`: exits 2.
- `push-results`: exits 2.
- `push-bug`: exits 2.
- `update-retest`: exits 2.
- `status`: exits 2.
- `validate`: exits 2.
- `results`: exits 2.

## Rules

- Nothing is ever deleted, and bugs are never closed by the tool.
- Keep passwords and tokens out of anything you record.
