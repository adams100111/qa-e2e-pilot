# ADR-0034 — ClickUp mirrors a tracked spec: a subfolder per spec, a list per run

## Status

Accepted (2026-11-27). qa-kit 0.5.0. Design:
[`docs/superpowers/specs/2026-11-27-qa-kit-clickup-tracking-and-unattended-journey-design.md`](../superpowers/specs/2026-11-27-qa-kit-clickup-tracking-and-unattended-journey-design.md)
Part A. Extends the tracker of `docs/superpowers/specs/2026-11-10-qa-tracker-design.md`, which stays in
force for the catalog verbs. Keeps [ADR-0022](./0022-qa-kit-process-shell.md): the engine is untouched,
the tracker is qa-kit's own code under `qa-kit/scripts/trackers/`. Adds no verdict and changes no
engine gate; a ticket never reads better than the run recorded it
([ADR-0032](./0032-trusted-verdict-gates.md), [ADR-0033](./0033-independent-re-adjudication.md)).

## Context

Before 0.5.0 the tracker mirrored a hand-written test-case catalog into one ClickUp folder. The qa-kit
steps (spec, scenarios, analyze, run, verify) never reached ClickUp: scenarios were not tickets and
evidence was a text comment. The people who need to follow a QA effort (admins, testers, the team) do
not open the repository. They need to see what is tested, how each scenario went on each build, the
evidence and the open bugs, in ClickUp, written as if a person on the team wrote it.

## Decision

**A. Layout.** A spec that is tracked gets one **subfolder** inside the project's QA folder. Each run
is one **list** in that subfolder. A scenario is a ticket in the list, a check is a subtask. The first
ticket of every list is the Run summary. The subfolder also holds a Doc per spec (pages Overview,
Scenarios, and one Results page per run); the QA folder holds one project Doc that works as the
dashboard. Statuses and custom fields are made once on the QA folder (by hand where the API cannot) and
inherited. The tracker creates the subfolder, the lists, the views and the Docs. The switch is per
spec (`specs.<target>.enabled`); the catalog layout keeps working beside it.

**B. Identity is the `Ref` field.** The tool never finds a ticket by its title, which a person may edit.
Every ticket it makes carries a short-text field `Ref`: `qk1-<key>-<s>` for a scenario or check, and
`qk1-<key>-<s>-<run>` for the Run summary.

- `<key>` is the first 12 hex characters of the SHA-256 of `<target>|<list number>|<kind>|<local id>`.
  `<kind>` is `summary`, `card` or `check`. A check's local id is the length-prefixed pair
  `<len>:<card id>/<criterion>`, so two different pairs never join alike.
- `<s>` is one letter for the status the tool last wrote: `t` to test, `g` testing, `f` failed,
  `b` blocked, `p` passed, `s` skipped.
- `<run>` is the first 8 hex of the SHA-256 of the run id, or `open` for a list no run is tied to.
- Two status letters, `<from><to>`, are the pending form. The tool writes it before it changes the
  status and replaces it with `<to>` after, so a move that stopped half way is told from a person's
  change. A Ref with the same letter twice, or text around it, is not a Ref.

**C. The tool owns status in run lists, and leaves a person's change alone.** A ticket whose live status
is not the one in its `Ref` (or either letter of a pending move) was changed by a person. The tool
does not touch it, reports it, and counts that as not a failure, on a retest too. This reverses the
catalog layout's rule for run lists only: there the tester owns case status, here the run's result
does, because a run list is a record of one run and nobody should have to move 300 tickets by hand.
A pass stays in `testing` until a person confirms it, unless its recorded confidence and its
confidence after verification are both `high`; a non-pass never maps to `passed`; a needs-review
check carries a "Needs a person's review" tick.

**D. Required once set up.** A tracked spec's ClickUp step is part of the qa-kit step. When it fails the
command stops with the tracker's one-line error, after giving its own result, and says ClickUp was
not updated. A silent miss is the failure this design exists to prevent. A spec that is not tracked
never contacts ClickUp and is never nagged beyond one offer of `/qa-tracker --spec <target>`.

**E. Screenshots are named by content.** An attached screenshot is called
`screen-<first 6 hex of its SHA-256>.<ext>`. A file already attached under that name is skipped, so a
retest or a re-recorded check attaches only what is new, and the name never carries a local path.
(An earlier plan numbered attachments by round, `round-<k>-screen-<n>`. The content name replaced it:
it needs no counter and covers both cases.)

**F. No list template, no HTML report.**

- The owner asked for a list template so statuses would not be rebuilt for every run. The ClickUp API
  has no way to create statuses, custom fields or list templates, and folder inheritance already
  gives a new list the statuses and fields. The tool creates each list and its views through the API,
  as `init` does for the catalog lists. The template added a manual step and nothing else.
- The engine's HTML report is not attached. It carries check ids, suspected layers and file
  references, which the writing rules ban in ClickUp. It stays local for developers. The Results page
  is the report in ClickUp; a project that hosts reports itself can set `reportUrl`.

**G. Flat fallback.** When ClickUp refuses a subfolder (the workspace has not enabled them) or the
spec sets `layout: flat`, the spec's lists go directly in the QA folder. Sibling folders with a name
prefix were rejected, also as a fallback: a sibling inherits from the space, not from the QA folder, so
the one-time setup would repeat for every spec.

**H. Links.** A link uses the `url` ClickUp returns. When there is none, the standard forms are built
from ids: task `https://app.clickup.com/t/<task id>`, list `.../<workspace id>/v/li/<list id>`, folder
`.../v/f/<folder id>`, Doc `.../v/dc/<doc id>`, page `.../v/dc/<doc id>/<page id>`.

**I. Writing rules are code.** `tracker.sh lint` and the same check inside every verb refuse text with
emojis, forbidden words, id-like tokens (URLs are ignored), file paths, headline-style titles,
empty or repeated text, and person mentions. A failed item is skipped, never sent in part.
A person is mentioned only when the config's `notify` names one, and only for a verified run: the
run directory holds `verification.json` and the rendered report. Otherwise no mention is sent.

## Consequences

- A tracked project can be followed in ClickUp from the first spec to the last verified run, and
  an older run keeps its own results because each run has its own list.
- A second ticket never appears for the same scenario: identity survives a renamed ticket, a retried
  call and a half-finished first sync (the tool fills missing tickets on every sync).
- More lists over time. Old lists are archived (`keepRuns`), never deleted. Nothing is ever deleted.
- Subfolders must be enabled in the workspace, or the flat fallback applies.
- The tracker needs no catalog for the new verbs. The existing catalog verbs still do.
- Every string sent passes the wording lint and the redaction; comments are sent with
  `notify_all: false`; no assignee is set.
- Only qa-kit changes. The engine, `qa-verify` and the byte-oracle are byte-for-byte unchanged.

## Open verification items

Every ClickUp test in the suite uses an in-memory fake. Nothing here has run against a real
workspace. Before relying on it, a person runs the real-workspace checklist (also in
`qa-kit/README.md` and the CHANGELOG):

1. Creating a subfolder with `parent_folder_id`.
2. Reading a folder's custom fields.
3. Creating a list view.
4. The link forms in H open the right page.
5. A comment body with a user mention.
6. Reading a Doc.
7. Reading a folder that holds archived lists.
