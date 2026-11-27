# ADR-0035 — The unattended journey: one agent drives the qa-kit process, a script owns the state and audits the limits

## Status

Accepted (2026-11-27). qa-kit 0.5.0. Design:
[`docs/superpowers/specs/2026-11-27-qa-kit-clickup-tracking-and-unattended-journey-design.md`](../superpowers/specs/2026-11-27-qa-kit-clickup-tracking-and-unattended-journey-design.md)
Part B. Keeps [ADR-0002](./0002-run-state-in-dot-qa-not-agent-memory.md) (state in files),
[ADR-0022](./0022-qa-kit-process-shell.md) (the engine is untouched; `auto.sh` calls no engine script),
and [ADR-0032](./0032-trusted-verdict-gates.md) / [ADR-0033](./0033-independent-re-adjudication.md)
(nothing may turn a non-pass into a pass or raise a confidence). Companion to
[ADR-0034](./0034-clickup-spec-layout.md). Adds no verdict.

## Context

qa-kit is six commands a person types, and several stop to ask something: which roles are real, who
may reach each screen, the scope, the P1 journeys, whether to run a seed command, the tricky inputs
and expected values, coverage exclusions, whether to accept a census built without the stack adapter.
The owner wants one agent to drive the whole process for a target with nobody present and hand a person
a short list at the end. `humanInteraction.autonomousSetup` removes three of those questions and the
engine's `qa-ci.sh` runs an existing checklist headless; nothing drives the steps in order or answers
the rest. `CONTEXT.md` reserves "autonomous" for that flag, so the new thing is the **unattended
journey**.

Two risks shape it. A long run loses its place when context is compacted, and nothing outside the agent
checks what it did. And the agent can make a run look more trustworthy than it is by answering a
question in the way that gets it further.

## Decision

**A. A state machine in a script, a thin command over it.** `qa-kit/scripts/auto.sh` owns the journey
on disk in `.qa/specs/<target>/auto/`: `journey.json` (the steps and their state, the run id, the
deadline, the stop reason), `baseline.json` (the snapshot the audit compares against),
`decisions.json` (every answer given in place of a person), `notes.json` (facts for a person that are not
decisions), `handoff.md` and `history/<n>/` (earlier journeys of the target). `/qa-auto` is a loop over
`auto.sh next`; each step is the existing command's own instructions, with no second copy. Steps are
`constitution`, `spec`, `scenarios`, `analyze`, `run`, `verify`. `step-done` looks for the step's result
on disk and never takes the caller's word. The journey survives an interruption: started again it
continues from `next`, and an interrupted run is continued with the engine's resume, never restarted.
A journey that stopped for the time limit, a step failure or `--until` resumes; a restart is explicit
(`--restart`) and the old journey moves to `history/`. The script writes only under `auto/`. It never
edits `.qa/config.json`, the spec's `run-config.json`, `checklist.json` or the known-defect registry.
Only one journey is open in a project at a time; they share sessions, accounts and data.

**B. The open journey is the setup signal.** No config is edited and nothing is written to the spec's
run-config to skip the setup questions: the run-config merge replaces whole top-level keys, so a
written flag would drop sibling keys such as `humanInteraction.enforce`, and it would outlive the
journey. Each qa-kit step command instead treats an open journey for the target as
`autonomousSetup` on for that step. When the journey closes, a person running any step is asked as
usual.

**C. Every self-answered question is recorded, as an assumption.** Before a step the agent lists the
questions it would ask a person, looks for evidence in the project, answers by a fixed rule for the
class (`roles`, `surface-access`, `scope`, `role-overrides`, `journeys`, `inputs`, `expected`, `gaps`),
and records it with `auto.sh decide`: question, answer, evidence (or the word `none`), confidence, and
the criteria it decides. Without evidence, or at low confidence, the decision needs a person. A
decision is never described as confirmed.

**D. The never-decided list.** A journey never decides: **seed** (it never runs a seed command and
never writes `seed.json`), **exclusion** (it never excludes a screen or a role and screen pair from
coverage), **crawl-only** (it never accepts a census built without the stack adapter), **oracle-human**
(it never marks an expected value as confirmed by a person), **safety** (`allowApiWrites`,
`seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, anything under `gates`, `profile`,
`humanInteraction.enforce`, `humanInteraction.maxOptOutRate`, in the config or the run-config) and
**known-defect** (the registry). `auto.sh decide` refuses a decision of those classes. A seed command
that was proposed and not run, and a check left out of the plan because it asserts an application
failure, are facts: they go in with `auto.sh note`. The profile is the person's choice; the journey
writes `--profile` at launch and never picks or changes one. A step whose files already exist is done,
whoever wrote them, and a scenarios step on an existing plan only appends rows that close the gaps
analyze listed.

**E. The second look can only hand a question to a person.** After the spec and the scenarios steps, one
fresh agent (never a fork, never a resumed one) reads the recorded decisions and answers per decision
`stands` or `ask`. `ask` marks the decision as needing a person; `stands` never clears it; an
`ask` stays `ask`. It cannot change an answer or approve one, and the acting agent never reviews its own
decisions in its place. Only Claude can start such an agent (`subagentDispatch`). Elsewhere, or when
the agent call fails, `second --unavailable` leaves every low-confidence decision for a person and the
journey says so. The handoff counts every low-confidence decision that has no `stands` verdict as
needing a person, on every harness.

**F. The file audit.** `auto.sh audit` compares the files as they are now with `baseline.json` and with
the journey's own record, and fails the journey (`stopped`, reason `audit`, with the codes in the stop
detail) if any of these changed: a safety setting of the config or the run-config, the address of the
application, the known-defect registry, a seed file, a coverage exclusion, a person-confirmed expected
value (added, removed or its expected value changed), a row of the starting plan (removed), or when a
decision of a forbidden class is on record, a step is marked done without its result, the run has no
`verification.json`, or ClickUp is behind the results (`tracker.sh spec-status`). The codes are
`baseline-missing`, `baseline-changed`, `base-url-changed`, `safety-setting-changed:<key>`, `run-config-safety:<key>`, `known-defects-changed`, `human-oracle-added:<id>`, `human-oracle-removed:<id>`, `human-oracle-changed:<id>`, `plan-row-removed:<id>`, `plan-unreadable`, `seed-added`, `exclusion-added`, `forbidden-decision:<id>`, `decisions-unreadable`, `step-without-result:<step>`, `not-verified`, `tracker-behind`. Once failed it stays failed.

What the audit cannot detect, stated plainly. It reads files on the same machine the agent can write.
It does not see:

- a value changed and changed back before the audit;
- `baseline.json` and `journey.json` rewritten together so they agree;
- a fresh baseline taken with `start --restart` after a change (the new journey says `restartedFrom`,
  and the handoff says it was restarted, so a person can see it; the files alone cannot prove it);
- a safety key that went from absent to an explicit null;
- a plan row without a string id;
- a tracker command replaced through the environment.

It is a tripwire against drift and mistakes. It is not a guard against an agent that sets out to
defeat it. Making it tamper-proof needs a record outside the agent's reach (a log written elsewhere,
or a hash held by a person or a CI job); that is not built.

**G. The result rule is stricter than the engine's.** `auto.sh handoff` works the result out from files
only and never reports better than what the engine recorded: `stopped` for any stop; `not verified`
when the journey is open, has no run, a file it decides from cannot be read, or verification is missing
or leaves a pass that was recorded; `not ready` when the report says NOT SHIP-READY; `not confirmed`
when the report says SHIP-READY but a top-priority check rests on a person (a decision that needs a
person, or an expected value that is only a proposal); `ready` only when none of that holds; and under
`full`, with no ship section, `verified` or `not verified`. The sentence carries the count of items
waiting for a person. A passing audit is recorded; a handoff with no audit record says the audit did
not run and is `not verified`. `step-done run` refuses a run that is unfinished, has no rendered
report, has no checkpoint row from this plan, or started before the journey.

**H. QA only.** The journey ends with a verified report and a bug list. It does not fix the application,
and it deletes none of the records the run created (the handoff lists them).

**I. It refuses production, and the merged settings decide.** `start` and every `resume` refuse, with
one plain line, when the environment is production: `environment: production`; or no usable `baseUrl`;
or a host that is not local without a real `seedableEnvMarker` (the same rule as the engine's
pre-flight, stricter than the design's B2). `environment` is compared lower-cased and anything other
than `auto`, `production` or `disposable` is refused. The gate judges the **merged** settings: the
spec's run-config replaces top-level keys of the config, as the engine's profile resolution does, so a
run-config cannot move the journey past it. On a host that is not local the run's
`gates.dataPolicy` must be `enforce` (`ship` and `smoke` count as enforce when unset). It also refuses
when the known-defect registry does not validate, when any journey file in the project cannot be read,
or when another journey is open. `--max-hours` is 0.1 to 72 (default 6); the deadline and `--until` are
enforced by `next`, `step-start` and `step-done` alike.

**J. ClickUp is required, as in ADR-0034.** A tracked spec's ClickUp step failing stops the journey with
reason `tracker`. The journey leaves one comment on the run summary ticket at the end, a fixed sentence
chosen from the handoff, only when the journey has a run and the stop reason is not `tracker`.

## Consequences

- The order, the answers and the limits do not live in the agent's context: a compacted or killed
  session continues from `auto.sh next`.
- A person reads one file, `handoff.md`, and sees what was decided without them, what still needs them,
  the records the run created, and how to confirm.
- The audit finds the common ways a journey goes wrong (a safety key touched, a seed written, a row
  dropped, a value confirmed). It does not make the journey safe against a hostile agent, and docs must
  not say it does.
- The second look exists only on Claude. Other harnesses get the banner and a longer handoff list.
- A headless runner for CI is not built. The state machine is a script, so one can be added on top
  without changing it.
- Only qa-kit changes; the engine is byte-for-byte unchanged.

## Alternatives rejected

- One instruction file that lists the six commands. The order, the answers and the limits would live in
  the agent's context only, and nothing outside it would check them.
- A headless runner only. Good for CI, no use inside a session. Deferred.
- Writing `autonomousSetup` into a file. See B.
