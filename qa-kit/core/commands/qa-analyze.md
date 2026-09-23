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

2. **Build the surface map.** Invoke `{{SKILL_REF:analyzing-feature-ui}}` for the target to enumerate
   the actual UI surfaces/affordances. Do not reimplement it.

3. **Traceability (if a spec-kit was ingested).** If the spec's "Ingested spec-kit" section names a
   source, invoke `{{SKILL_REF:ingesting-spec-kit}}`'s traceability to map spec items → criteria.

4. **Flag gaps (advisory only).** Cross-check and list, without changing anything:
   - **Coverage gaps** — a surface/affordance or spec item with no covering criterion.
   - **Role gaps** — a `spec-roles.json` role that no scenario exercises (or a criterion whose role is
     absent from the snapshot — should have been caught by `/qa-scenarios`, re-flag if seen).
   - **Oracle gaps** — a computed/business-rule criterion whose `qa-spec.md` "Oracles" section does not
     say how "correct" is independently determined.
   - **Risk gaps** — an obvious high-stakes path (cross-tenant, destructive, money/permissions) with no
     criterion.
   - **Data gaps (TDQA)** — run
     `bash "{{PLUGIN_ROOT}}/scripts/check-fixtures.sh" .qa/specs/<target>/checklist.json` and list every
     computed criterion with no well-formed pinned expect (from `missing`), plus `llm-suggested` pins (from
     `sources`) that will run at `confidence: low`. Also cross-check `data-baseline.json` against the criteria's
     `dependsOn`: a `seeded` baseline row no criterion depends on (dead declaration), a `created` entity no
     scenario creates, and a `seeded` row with no readable surface (will be *assumed* at run → low confidence).
   - **Plan defects** — a criterion whose **oracle asserts that the application FAILED**. This is the sixth
     category, added because the five above had nowhere to put one: the originating incident's criterion
     pinned `page.rendersWithoutServerError` to `"false"`, so an HTTP 500 graded as a match, and with no
     home of its own it was filed under *Risk gaps* and **blessed** — while the same analysis reported
     "oracle gaps: 0". A plan defect is not a missing criterion; it is a **wrong** one. Two signals:
     - **Structural** — a `fixture.expect` or top-level `expect` in the reserved health namespace pinned to
       a failing value: `page.rendersWithoutServerError` = false, `page.crashed` = true,
       `console.hasError` = true, or `http.status` ≥ 500. Every spelling of the same assertion counts (the
       boolean, its string form `"false"`/`"TRUE"`/`" false "`, and the `0`/`1` form). A 3xx/4xx
       `http.status` is **legal** and is never a plan defect — a 302 to login or a 403 is the application
       *working*. The engine's `skills/generating-qa-checklist/scripts/validate-checklist-json.sh` rejects
       this shape outright (exit non-zero, one `ERROR: entry[<i>].<field>: …` line per violation), and
       `/qa-scenarios` step 3 runs it via the engine's checklist writer — so a criterion of this shape
       reaching `/qa-analyze` means the checklist was produced without that validator passing. Say so.
     - **Prose** — `expected to fail`, `known defect` or `not a regression` appearing in an **oracle/expect**
       field (`oracle`, `oracleNote`, `expected`, or a string member of `fixture.expect`/`expect`). These
       three are deliberately **not** validator rejections: they describe the *application's behaviour*, and
       *"the save is expected to fail with a validation error"* is a sound oracle for an `error-state`
       criterion, because a 4xx rejection is the application working. They are demoted to this advisory
       flag so a human decides. **Never scan `action`** — that is where an author legitimately describes a
       non-rendering state ("this list does not render until the challenge reaches Judging"), and the
       over-broad net was removed from the validator for exactly that reason. The governing line is
       **reject process language, never behaviour language**: `deferred by design` describes a backlog
       decision and stays a hard validator rejection; the three phrases above describe the application and
       are surfaced here instead.
     Remediation is never "loosen the criterion". The defect leaves the plan and is filed in the
     project-level registry `.qa/known-defects.json`:
     `bash "{{PLUGIN_ROOT}}/scripts/migrate-inverted-criterion.sh" <checklist.json> <criterion-id>`.
     Note its **inverted exit codes: exit 2 is the SUCCESS path** (written, human input pending), exit 1
     is the failure path, and exit 0 is never returned. A caller that treats any non-zero as "failed" silently loses the migration. See
     `/qa-scenarios`.

5. **Write `analysis.md`** from `{{PLUGIN_ROOT}}/templates/qa-analyze-template.md`: the gaps by
   category, each with a suggested remediation (usually "add a criterion via `/qa-scenarios`" or "add an
   oracle note via `/qa-spec`") the operator may accept or decline. The template ships **six** gap
   headings — one per category above — and then `## Verdict`, whose carve-out wording is already
   pre-printed; fill in its trailing gap-summary placeholder.

   **Plan defects print ABOVE the verdict line, never inside it — and the template already carries the
   slot.** `## Plan defects` is **pre-printed** immediately above `## Verdict`. **Fill it; never add a
   second one, and never delete it.** One line per defect: its criterion id, the signal that flagged it,
   and the `migrate-inverted-criterion.sh` remediation. **"(none)" when clean** — an empty section is the
   point, which is why the heading lives in the artifact rather than in an instruction to remember it:
   the originating incident's inverted criterion was folded into *Risk gaps* under a document whose own
   summary line read "oracle gaps: 0", and an absent heading is what let it vanish. Relying on an author
   to insert the section is the same class of mistake as relying on a run to self-report its verdicts.

   **The "advisory only" charter is carved out for this class**, and the pre-printed verdict line says so:
   *Advisory only — the run is **not** blocked; this does not extend to plan defects.* `/qa-analyze`
   itself still changes nothing and still cannot gate (see Guardrails), but a plan defect is not a
   suggestion the operator may decline into a green run: a criterion asserting that the application failed
   is a defect in the plan, and declining to fix it does not make it correct. It is also not this step's
   to bless — the engine's `validate-checklist-json.sh` rejects the structural shape at authoring time,
   and the registry (`ticket`, a 90-day-capped `expiry`, a severity floor) is what carries the defect
   afterwards.

6. **Report:** the gap counts by category — **plan defects stated first and separately**, never summed
   into a single "N gaps" figure — plus the next step (`/qa-run "<target>"`). Make clear this step never
   gates; it informs. If the plan-defect count is non-zero, say plainly that the plan asserts an
   application failure somewhere and name the criterion ids, rather than reporting a total the reader has
   to decompose.

Guardrails: read-only (never edit `scenarios.md`/`checklist.json`/`spec-roles.json`); advisory (never a
`fail`/block) — **and that advisory charter is explicitly carved out for `plan-defect`**: this step still
never blocks the run, but it must not present a plan defect as an optional, declinable suggestion;
remediation for every other category is the human's to approve, applied by re-running the relevant
earlier step.
