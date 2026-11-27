---
description: Show where a project (or a specific target) stands in the qa-kit process — which artifacts exist, which step is next, and any constitution-drift advisory. Read-only.
argument-hint: [<target>]
disable-model-invocation: false
---

Report the qa-kit process state for this project. **Read-only** — inspect artifact presence only;
never create, modify, or run anything. Full input: `$ARGUMENTS` (an optional `<target>` scopes the
spec-level checks to `.qa/specs/<target>/`; with no target, list every `.qa/specs/*/`).

## What to do

1. **Constitution (project-level).** Check for `.qa/constitution.state.json` (authoritative machine
   state) and `.qa/constitution.md` (human policy).
   - Absent → the project has no constitution. Next step: **`/qa-constitution`**. Stop here (nothing
     downstream can exist meaningfully yet); say so.
   - Present → read its `version` from `.qa/constitution.state.json` and report it + the role count.

2. **Specs.** For the target (or each `.qa/specs/<t>/` directory), check, in order:
   - `qa-spec.md` + `spec-roles.json` → the spec step is done. If absent → next step: **`/qa-spec`**.
   - `scenarios.md` + `checklist.json` → scenarios done. If absent (but spec present) → next step:
     **`/qa-scenarios`**.
   - `analysis.md` → analyze done. If absent (but scenarios present) → next step: **`/qa-analyze`**.
     Read the first line under its `## Verdict`. `Verdict: BLOCKED` (the ship coverage gate) → show
     `analyze BLOCKED`; the next step is **`/qa-scenarios`** (add criteria or exclusions) and then
     `/qa-analyze` again — never `/qa-run` while the analysis is `BLOCKED`. `Verdict: PASS (advisory)` →
     analyze done. A missing or different line → the analysis is not finished: say so, next step
     **`/qa-analyze`**. An `analysis.md` older than `checklist.json` is stale: next
     step `/qa-analyze`.
   - a `.qa/runs/<id>/run-manifest.json` whose `target_feature` matches this spec's target (the same
     resolution `/qa-verify` uses) → at least one run happened. If none (but scenarios present) →
     next step: **`/qa-run "<target>"`**.
   - `.qa/specs/<t>/verification.md` → post-run verify done. If absent (but a run exists) → next step:
     **`/qa-verify "<target>"`**.

3. **Drift advisory (per spec).** For each spec with a `spec-roles.json`, compare its stamped
   `constitutionVersion` to the current `.qa/constitution.state.json` `version`. Use qa-kit's
   `spec-snapshot.sh drift <spec-roles.json> <current-constitution-version>` helper for this
   comparison (it prints `{stale, stamped, current}`):
   - equal → in sync.
   - different → **advisory** (not a block): "spec `<target>` was snapshotted from constitution
     `<stamped>`, but the constitution is now `<current>` — its frozen roles may be stale; re-run
     `/qa-spec` for `<target>` if you want the current roles."

4. **Print a compact summary:** one line for the constitution (version + role count, or "none"), then
   one line per spec — `<target>: spec ✓ / scenarios ✓ / analyze ✗ / runs 0 · next: /qa-analyze
   [· drift: stale]`. End with the single **next step** for the requested scope. Never invent an
   artifact you did not find; report only what is present on disk.

5. **ClickUp links (per spec).** Only when docs/agents/qa-tracker.json has specs.<target>.enabled: true. If the step below exits non-zero, stop and report its one-line error; do not continue the command.
   Run `bash "{{PLUGIN_ROOT}}/scripts/tracker.sh" spec-status --spec <target>` (it reads only) once per tracked spec. Print one ClickUp line
   per tracked spec, under the summary lines and before the final **next step** line: the links it
   returns for the spec and its latest run, plus each reason it gives for ClickUp being behind the
   local files.

6. **Unattended journey (per spec).** For each spec run
   `bash "{{PLUGIN_ROOT}}/scripts/auto.sh" status <target>` (it reads only). Exit 1 with
   `auto: no journey for <target>` means no unattended journey was started for this spec with
   `/qa-auto`: add nothing for it. Otherwise it prints the journey plus `needsPerson`. Add to that
   spec's summary line:
   - `state: open` → `journey: open at <step>`, the first step in `steps` whose `state` is not `done`;
   - `state: stopped` → `journey: stopped at <step> (<stop.reason>)`, and say whether starting
     `/qa-auto <target>` again continues it (`time-limit`, `step-failed`, `until`) or a person has to
     act first (`blocked`, `audit`, `no-sign-in`, `tracker`);
   - `state: done` → `journey: done`;

   then `<needsPerson> items for a person`, and point at `.qa/specs/<target>/auto/handoff.md` when that
   file exists. While a journey is open, the next step for that spec is the journey's own; say so
   instead of telling a person to run a step by hand.

## Going further: the dashboard

`/qa-status` answers "which step is next". For run-level detail — each run's progress, rate and ETA,
verdict counts, bugs by severity, ship readiness, the live cursor of a running run, a stalled
warning, trends across runs and the known-defect registry — point the user at the engine's
**`/qa-dashboard`** (`/qa-e2e-pilot:qa-dashboard`; `scripts/qa-dashboard.sh html|tui|json` in the
qa-e2e-pilot plugin). It is read-only too. Mention it in one line at the end of the summary; do not
run it from here.
