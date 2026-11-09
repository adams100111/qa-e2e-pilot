---
description: Run a full-stack browser QA pass against a feature — drive the UI, bake (read persisted state back), recompute the logic, and write an evidence-backed, resumable report.
argument-hint: <target> [checklist-or-spec-path]
disable-model-invocation: false
---

Run a full-stack QA pass by dispatching the **qa-e2e-pilot** agent.

## Arguments

- `$1` — **target**: the feature/route to QA (e.g. `governance wizard`, `/cap-table`, or a URL path). Required.
- `$2` — optional path to a **hand-authored checklist** or a **spec** (spec-kit `spec.md`/`tasks.md`, or a plain acceptance checklist). When supplied, the agent ingests it instead of auto-generating one.

Full input: `$ARGUMENTS`

## What to do

1. Read `.qa/config.json` to learn `baseUrl`, the driver pool, `repos` by role, and `allowApiWrites`. **If `.qa/config.json` does not exist, invoke the `bootstrapping-qa-config` skill** — it infers defaults (DDEV/localhost baseUrl, single-repo, detected stack), asks the user only the gaps (base URL, environment, auth, allow-writes), and writes a valid config for them. Do not abort with "create it from the example"; bootstrap it.
2. Dispatch the **qa-e2e-pilot** agent (via the Agent/Task tool, `subagent_type: qa-e2e-pilot`) with:
   - the **target** (`$1`),
   - the **checklist/spec path** (`$2`) if provided — instruct the agent to **ingest** it rather than generate,
   - an instruction to **resume** the latest `.qa/runs/<run-id>/` if one is in progress for this target (read its `run-manifest` + `checkpoint` and skip completed criteria).
3. The agent runs the 6-phase pipeline (pre-flight → analyze → generate → verify → report → remember), **sequentially by default**, and writes `report.md` + `report.html` + evidence + the resumable memory-spec artifacts under `.qa/runs/<run-id>/`.
4. **Re-adjudicate when the agent could not.** When the agent returns, if `.qa/runs/<run-id>/adjudication/` holds neither `decisions.json` nor `unavailable.txt`, invoke the `re-adjudicating-verdicts` skill on that run yourself (it checks whether this harness can dispatch a fresh verifier and prints a banner when it cannot). If it applied any decision, re-run `scripts/qa-verify.sh <run-id>`, `scripts/render-report.sh .qa/runs/<run-id>` and `scripts/bug-export.sh .qa/runs/<run-id> --out .qa/runs/<run-id>/bugs [--known-defects .qa/known-defects.json]` so the verification, report and bug export reflect the final verdicts. Never judge the selected records in this context.
5. Then surface: the run directory path, the per-verdict tally (`pass/fail/blocked/deferred/error`), any **confidence: low** verdicts, the report's **Ship readiness** line when it has one, the re-adjudication outcome (re-judged / disputed, or the unavailable banner), the bug export count, and a one-line pointer to the HTML report.

Do not claim any criterion passed without the agent's on-file evidence. Honor the guardrails in the agent definition (sequential default, read-only probing unless `allowApiWrites`, secrets never printed).
