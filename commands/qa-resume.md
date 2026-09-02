---
description: Resume an interrupted QA Run — read the resume briefing, reconcile any open acts by re-baking the write-set, then continue Verify at the frozen cursor with no re-observation.
argument-hint: [run-id]
disable-model-invocation: false
---

Resume a QA Run by dispatching the **qa-e2e-pilot** agent with the portable resume briefing.

## Arguments

- `$1` — optional **run-id**. When omitted, the run resolves from `.qa/runs/latest` (the run-id written on that run's first journal event). Required only when resuming a run other than the most recent one.

Full input: `$ARGUMENTS`

## What to do

1. Run `bash skills/checkpointing-qa-memory/scripts/qa-resume.sh $1` (omit `$1` when not supplied). This resolves the run (arg, else `.qa/runs/latest` — dying clearly if neither exists), folds `journal.ndjson`, and prints the resume briefing: `{run_id, phase, cursor:{scenarioId,criterionId}|null, openActs:[…], skip:[…]}`.
2. Read the briefing. If `openActs` is non-empty, **reconcile every open act BEFORE touching the UI**: for each `{key, scenarioId, criterionId, personaId, writeSet}`, read back each write-set member with your own browser/probe capability, then run `bash skills/checkpointing-qa-memory/scripts/qa-reconcile.sh apply <run_id> <key> --readbacks <json>`. Handle the outcome: `done` → move on; `blocked` → the criterion is now recorded `blocked`, move on; `retry` → re-drive the act once (through real UI affordances, bracketed by `journal-emit.sh act-intent`/`act-commit` as usual) and call `apply` again.
3. Dispatch the **qa-e2e-pilot** agent (via the Agent/Task tool, `subagent_type: qa-e2e-pilot`) with:
   - the resolved `run_id` and `phase` from the briefing — resume in that phase, not from Pre-flight,
   - the `skip` list — never re-run or re-verdict any `(scenarioId, criterionId)` tuple already in it,
   - the `cursor` — continue **Verify at exactly this tuple**. **Verify replays the FROZEN plan (`plan_frozen`/`plan_amended` events already in the journal) — no re-observation of the app** for any already-planned criterion.
4. When the agent returns, surface: the run directory path, the per-verdict tally (`pass/fail/blocked/deferred/error`), any **confidence: low** verdicts, and a one-line pointer to the HTML report.

Do not claim any criterion passed without the agent's on-file evidence. A crash mid-act is a re-bake job, not a re-run of the whole Run — never re-drive an act whose write-set already reconciles as `done`.
