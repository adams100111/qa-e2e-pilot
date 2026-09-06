---
description: The post-run verification surface for a qa-kit run. Primary job — the out-of-plan-act check (verify-plan.sh), which the engine never does. Secondary — a qa-kit-flow-native restatement of the engine's deterministic overrides (verification.json), pointing at report.md as the authoritative source. Reports; the script results are the gate.
argument-hint: <target> [<run-id>]
disable-model-invocation: false
---

Produce `.qa/specs/<target>/verification.md` — the post-run verification for `<target>`. Sixth
qa-kit step: constitution → spec → scenarios → analyze → run → **verify** → status. Full input:
`$ARGUMENTS` — the first token is `<target>`, an optional second token is an explicit `<run-id>`.

## What to do

1. **Resolve the run** (most-specific first — never rely on a single agent-populated field):
   1. If a `<run-id>` was given, use `.qa/runs/<run-id>/`.
   2. Else, **deterministic content match**: among `.qa/runs/*/` whose `checklist.json` equals the
      target's frozen `.qa/specs/<target>/checklist.json` (same set of criterion `id`s — the engine
      was invoked with that exact frozen plan), take the newest. This link is a fact on disk, not an
      agent-written field.
   3. Else, **hint**: scan `.qa/runs/*/run-manifest.json` for `target_feature == <target>` and take
      the newest match. (Populated by the agent in the Remember phase, so treat it as a hint, not
      ground truth — hence it ranks below the content match.)
   4. Else, fall back to `.qa/runs/latest` **only with an explicit warning**: "could not link a run to
      target `<target>` by frozen checklist or run-manifest; assuming the most recent run globally —
      pass a `<run-id>` to disambiguate."
   Require `checkpoint.json` + `checklist.json` in the resolved dir; if no run exists at all, error
   and point at `/qa-run "<target>"`.

2. **Out-of-plan acts (verify-plan — THIS command's primary job; the engine never checks this).** Run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-plan.sh" .qa/runs/<id>/checkpoint.json .qa/runs/<id>/checklist.json`.
   Parse its JSON (`{ok, outOfPlan, planned, acted}`). A non-empty `outOfPlan[]` is a **process
   violation** — a criterion was acted that the frozen plan never authorized. List every offending
   id first; do not bury it. (The script's non-zero exit on a non-empty `outOfPlan` is the gate CI
   reads — this command reports it for the human.)

3. **Deterministic overrides (engine's re-check — a RESTATEMENT, not a re-derivation).** Read
   `.qa/runs/<id>/verification.json` (written by the engine in the Report phase).
   - **Absent** → state plainly: "deterministic re-verification not found for this run — its verdicts
     reflect the in-run agent's self-report only." Never imply verified.
   - **Present** → each record carries both `inRunVerdict` and `verifierVerdict`. An **override** is
     exactly `verifierVerdict != inRunVerdict` — no `checkpoint.json` join needed. List each override
     as `criterionId[@persona]: inRunVerdict → verifierVerdict` with its `reasons`, and each
     confidence downgrade. Skip the synthetic `criterionId == "__phase-surface__"` record as a
     criterion row; fold it into a one-line run-level note if present. Point at the engine's
     `report.md` as the authoritative source for these overrides (this command restates, it does not
     re-adjudicate).

4. **Write `verification.md`** from `${CLAUDE_PLUGIN_ROOT}/templates/qa-verify-template.md`: out-of-plan
   list, override list, confidence downgrades, and the verified/overridden/not-verified state.

5. **Report:** counts — out-of-plan acts, overrides, confidence downgrades — and the next step
   (`/qa-status "<target>"`). Lead with out-of-plan acts and overrides when any exist.

Guardrails: read-only w.r.t. artifacts (never edits `checkpoint.json`/`checklist.json`/
`verification.json`/`report.md`). This is an agent-followed command — it has no exit code; it
REPORTS. The deterministic gate for automation is `verify-plan.sh`'s exit code, read directly by CI.
