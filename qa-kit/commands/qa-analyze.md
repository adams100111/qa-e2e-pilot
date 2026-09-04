---
description: A read-only, advisory consistency + coverage gate before a qa-kit run — cross-checks the scenarios/checklist against the spec, its snapshot roles, the surface map, and any ingested spec-kit, flagging gaps for the operator to approve. Never blocks.
argument-hint: <target>
disable-model-invocation: false
---

Produce `.qa/specs/<target>/analysis.md` — a coverage/consistency review of the scenarios before the
(expensive) run. **Read-only and advisory** (the spec-kit `analyze` pattern): it reports gaps and offers
remediation the human approves; it does not modify artifacts and does not block the run. Fourth qa-kit
step. Full input: `$ARGUMENTS` — the first token is `<target>`.

## What to do

1. **Prereq.** Require `.qa/specs/<target>/scenarios.md` (+ `checklist.json`). If missing, error and
   point at `/qa-scenarios <target>`.

2. **Build the surface map.** Invoke `/qa-e2e-pilot:analyzing-feature-ui` for the target to enumerate
   the actual UI surfaces/affordances. Do not reimplement it.

3. **Traceability (if a spec-kit was ingested).** If the spec's "Ingested spec-kit" section names a
   source, invoke `/qa-e2e-pilot:ingesting-spec-kit`'s traceability to map spec items → criteria.

4. **Flag gaps (advisory only).** Cross-check and list, without changing anything:
   - **Coverage gaps** — a surface/affordance or spec item with no covering criterion.
   - **Role gaps** — a `spec-roles.json` role that no scenario exercises (or a criterion whose role is
     absent from the snapshot — should have been caught by `/qa-scenarios`, re-flag if seen).
   - **Oracle gaps** — a computed/business-rule criterion whose `qa-spec.md` "Oracles" section does not
     say how "correct" is independently determined.
   - **Risk gaps** — an obvious high-stakes path (cross-tenant, destructive, money/permissions) with no
     criterion.

5. **Write `analysis.md`** from `${CLAUDE_PLUGIN_ROOT}/templates/qa-analyze-template.md`: the gaps by
   category, each with a suggested remediation (usually "add a criterion via `/qa-scenarios`" or "add an
   oracle note via `/qa-spec`") the operator may accept or decline. End with an explicit verdict line:
   "advisory only — the run is not blocked."

6. **Report:** the gap counts by category + the next step (`/qa-run "<target>"`). Make clear this step
   never gates; it informs.

Guardrails: read-only (never edit `scenarios.md`/`checklist.json`/`spec-roles.json`); advisory (never a
`fail`/block); remediation is the human's to approve, applied by re-running the relevant earlier step.
