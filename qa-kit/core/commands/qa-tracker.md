---
description: Pick where test cases, runs and bugs live (local files, GitHub or ClickUp) and write the project's QA tracker rules and config.
argument-hint: "[--reconfigure]"
disable-model-invocation: false
---

Set up the QA tracker for this project. You ask a few questions, then write two files: rules a
person can read (`docs/agents/qa-tracker.md`) and config the scripts read
(`docs/agents/qa-tracker.json`). Full input: `$ARGUMENTS`. With `--reconfigure`, show the current
answers first and change only what the user changes.

This is a conversation, not a script. Explore, say what you found, ask one question at a time, then
write. Never write a file before the user has seen what goes into it.

## 1. Explore

Read what exists. Do not assume.

- `git remote -v`: is there a remote, and is it GitHub?
- `docs/agents/issue-tracker.md`: where the project already tracks issues.
- `docs/agents/qa-tracker.md` and `docs/agents/qa-tracker.json`: a previous setup.
- Any catalog: the `catalog` path in an existing config, else `.qa/catalog/`, else `docs/qa/catalog/`.
- `CLAUDE.md` and `AGENTS.md` at the repo root, and whether either has an `## Agent skills` section.

## 2. Say what you found

Two or three lines: the remote, the issue tracker file if any, whether a catalog or an earlier
setup exists. Then start the questions.

## 3. Ask, one at a time

Lead each question with the recommended answer so the user can accept it in a word. Wait for the
answer before the next question.

**Question 1. "Where do test cases, runs and bugs live?"**
- Local files: recommended when there is no remote. Cases stay in the catalog; runs and bugs are
  written as Markdown files under `.qa/tracker/`.
- GitHub: recommended when the remote is GitHub. Not yet available in this version: the rules are
  written and the config is saved, but the scripts exit 2 until the adapter ships. Say so plainly.
- ClickUp: ask for the workspace, and for the folder if one already exists. You may list them
  through the ClickUp API with the token in `CLICKUP_API_TOKEN`. Never ask the user to paste the
  token, and never write it into any file.
- Other: ask the user to describe the workflow in one paragraph. Record it as prose.

**Question 2. "Where do bugs go?"**
- The same tracker: recommended.
- The issue tracker the project already uses. If `docs/agents/issue-tracker.md` exists, read it and
  offer that tracker by name.

Record the answer as `bugsTo` in `docs/agents/qa-tracker.json`: `same` for the same tracker,
`issue-tracker` for the project's issue tracker. With `issue-tracker`, `push-bug` and `update-retest`
do nothing and say so.

**Question 3. "Keep the default statuses?"**
Recommended: yes.
- Case statuses: `to test`, `testing`, `failed`, `blocked`, `passed`, `skipped`.
- Bug statuses: `open`, `triaged`, `fixing`, `retest`, `closed`.

If the user says no, collect the project's own names for each list so nothing is created twice.

## 4. Draft and confirm

Show the user the draft of each file below. Let them edit it. Write only after they agree.

## 5. Write

1. `docs/agents/qa-tracker.md`: copy `{{PLUGIN_ROOT}}/templates/trackers/<backend>.md` for the chosen
   backend, then add this project's answers (workspace and folder names, where bugs go, any custom
   statuses). For "Other", write only this file, with the user's prose in place of the seed.
2. `docs/agents/qa-tracker.json`: start from `{{PLUGIN_ROOT}}/templates/qa-tracker-config.json` and set
   `backend` (`local`, `clickup`, `github` or `other`), `catalog` if it is not the default, the
   statuses if the user changed them, and `ids` if you have them. Keep every other key. For "Other",
   write `backend: "other"` and nothing else beyond the template defaults. Every verb then exits 2.
   Never put the ClickUp token, or any other secret, in this file.
3. The pointer in `CLAUDE.md` if it exists, else `AGENTS.md` if it exists, else ask which to create.
   Never create one when the other exists. Add or update this under `## Agent skills`:

   ```
   ### QA tracker

   Test cases, runs and bugs are tracked in <Backend>. See docs/agents/qa-tracker.md.
   ```

## 6. ClickUp only: build the structure

After the files are written, run the setup dry:

```
bash {{PLUGIN_ROOT}}/scripts/tracker.sh init
```

Show the user the output: what it would create, and the numbered list of clicks for the parts the
ClickUp API cannot create (custom fields, list-specific statuses). Run
`bash {{PLUGIN_ROOT}}/scripts/tracker.sh init --apply` only after the user says yes. Then tell the
user to do the listed clicks by hand and re-run `init`, which reads the ids back into the config.

## 7. Finish

Say what was written, one line per file. Remind the user that the token, if any, comes from the
environment variable `CLICKUP_API_TOKEN` and is never stored in the repo.
