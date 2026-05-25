# Run state lives in `.qa/runs/`, not the agent's personal memory

A run's resumable memory-spec artifacts — `run-manifest`, `checkpoint`, `bug-log`, `traceability` — are stored as plain files under `.qa/runs/<run-id>/`, colocated with that run's report. Resumability across context compaction is achieved by the checkpointing skill reading the latest `.qa/runs/<id>/checkpoint` on resume.

## Consequences

We deliberately do **not** route run state through Claude Code's personal memory system (`~/.claude/.../memory/` + `MEMORY.md`), even though that system auto-surfaces across sessions and would make resume "free." Per-criterion checkpoints are transient run state that gets skipped on resume — the opposite of the durable facts that memory system is designed for — and writing them there would pollute the global `MEMORY.md` index that is loaded into every session, for every project. The explicit "no" is the point: a future reader will see the obvious memory tool sitting right there and should know why we passed on it. Optionally, one *durable* memory entry per project-under-test (a pointer to the latest run + known-flaky areas) may be written; never per-criterion.
