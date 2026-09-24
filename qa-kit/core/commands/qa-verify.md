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

2. **Out-of-plan acts (verify-plan — THIS command's primary job; the engine never checks this).**
   The plan argument depends on whether this run resolved to a `<target>` with a frozen spec plan:
   - **Frozen spec plan resolved** (`.qa/specs/<target>/checklist.json` exists — resolution ladder
     tiers 1-3): run
     `bash "{{PLUGIN_ROOT}}/scripts/verify-plan.sh" .qa/runs/<id>/checkpoint.json .qa/specs/<target>/checklist.json`
     — the FROZEN plan, never the run copy (the run copy is agent-amendable and would let a
     laundered out-of-plan act slip through undetected). Additionally, diff the id sets of the
     frozen plan vs `.qa/runs/<id>/checklist.json`: any id present in the run copy but absent from
     the frozen plan is a **plan-divergence finding** — list the ids and the criteria added
     in-run; never silently accepted.
   - **No spec plan resolvable** (engine-solo run, ladder tier 4): run
     `bash "{{PLUGIN_ROOT}}/scripts/verify-plan.sh" .qa/runs/<id>/checkpoint.json .qa/runs/<id>/checklist.json`
     — the run-local copy, and the report MUST carry the banner: `⚠ out-of-plan check ran against
     the run-local plan only (no frozen spec plan resolved) — weaker guarantee: an amended in-run
     checklist cannot be detected.`
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
     confidence downgrade. Point at the engine's `report.md` as the authoritative source for these
     overrides (this command restates, it does not re-adjudicate).
   - **EXCLUDE THE SYNTHETIC RUN-LEVEL RECORDS FROM THE OVERRIDE LIST.** `verification.json` carries
     up to **two** records that are not criteria at all. Both use `persona: ""` and
     `inRunVerdict: "n/a"`, so the override test above (`verifierVerdict != inRunVerdict`) matches
     them **trivially** — `n/a → pass` is not an override, it is a run-level record with no in-run
     verdict to disagree with. Counting either as a criterion override reports a defect that does not
     exist; missing a `__run-checks__` failure reports a run-scoped gate failure as an ordinary
     criterion failure. Handle each by name:
     - **`criterionId == "__phase-surface__"`** (at most one) — a tool call that fell outside every
       acting window, or one forbidden in the active phase. `verifierVerdict` is **always `"pass"`**
       and `confidence` **always `"low"`**; its `reasons` name the phase/tool/timestamp. It is
       **record-only and deliberately does NOT flip `qa-verify`'s exit code** (an ambiguous
       wall-clock correlation must degrade, never falsely override). Fold it into a one-line
       run-level note.
     - **`criterionId == "__run-checks__"`** (at most one) — the four run-scoped checks, carried as
       `runChecks: {ledgerComplete, classificationsAgree, loadWindowCovered, knownDefectsOk}` plus a
       `channel` and the known-defect registry's per-entry `knownDefects` states. `verifierVerdict`
       is `"pass"` or `"fail"`, `confidence` is `"high"` (or `"low"` when `channel` is `none`). A
       record whose `runChecks` object is **absent** means the checks did not COMPLETE — fail closed
       and say exactly that rather than naming four false checks. **Unlike `__phase-surface__`, a
       non-`pass` here DOES flip `qa-verify`'s exit code.** Report it as a **run-scoped gate
       failure**, above the criterion rows, naming **which** of the four did not pass — a check that
       is missing or non-boolean has not been proven, so it counts as not passed. An all-pass record
       is informational: the engine surfaces it as a `qa.runChecks` property rather than a failure, so
       "the gate ran and passed" stays visible — say so instead of reporting nothing.
   - **`__run-verified__` is NOT in `verification.json`** — `qa-verify.sh` never writes it, so an
     operator reading that file will never see it and must not go looking. It is a JUnit
     `<testcase name="__run-verified__">` **synthesized by the engine's `report-to-junit.sh`** for a
     run-level `UNVERIFIED` (no independent capture channel, the `capture_probed` canary absent, an
     `unparseable-line`/`seq-gap` fold anomaly, or `QA_SKIP_VERIFY=1`). It is counted into the
     suite's tests/failures, so it **does** reach the exporter's exit code and `qa-ci.sh`'s. Read it
     from the JUnit XML or the `qa.unverifiedReason` property, not from here; the two are
     independent, and a run can carry both a `__run-verified__` and a `__run-checks__` failure at
     once. See `docs/running-in-ci.md`.

4. **Write `verification.md`** from `{{PLUGIN_ROOT}}/templates/qa-verify-template.md`: out-of-plan
   list, override list, confidence downgrades, and the verified/overridden/not-verified state.

5. **Report:** counts — out-of-plan acts, overrides, confidence downgrades — plus the run-scoped
   checks' state (passed / which of the four failed / did not complete / no record) and whether the
   run was reported `UNVERIFIED`, and the next step (`/qa-status "<target>"`). Lead with out-of-plan
   acts, a run-scoped gate failure and overrides when any exist. **Never sum the synthetic run-level
   records into the override count.**

Guardrails: read-only w.r.t. artifacts (never edits `checkpoint.json`/`checklist.json`/
`verification.json`/`report.md`). This is an agent-followed command — it has no exit code; it
REPORTS. The deterministic gates for automation are read directly by CI, not from here:
`verify-plan.sh`'s exit code for out-of-plan acts, `qa-verify.sh`'s own exit code for an overridden
pass or a failed `__run-checks__`, and `report-to-junit.sh`'s for a `fail`/`error` criterion or an
`UNVERIFIED` run.
