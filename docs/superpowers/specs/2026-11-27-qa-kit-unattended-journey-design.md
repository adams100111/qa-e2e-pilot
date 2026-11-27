# qa-kit unattended journey (`/qa-auto`)

Date: 2026-11-27 · Status: accepted (owner, 2026-11-27) · Plugin: qa-kit (owner). The engine is unchanged.

Related: `docs/superpowers/specs/2026-11-27-qa-kit-clickup-spec-tracking-design.md` (ClickUp tracking;
this design adds one key to it, see D8).

## Why

qa-kit is a sequence of six commands a person types, and several of them stop to ask the person
something. The owner wants one agent to drive the whole process for a target from the first step
to the verified result with nobody present: write the spec, question its own choices, write the
scenarios, check coverage, run, verify, and report, with ClickUp kept current when the spec is
tracked there.

What exists is partial. The `humanInteraction.autonomousSetup` flag removes three questions
(roles, who may reach each screen, the expected-value page). `scripts/qa-ci.sh` runs the engine
unattended from a checklist that already exists. Nothing drives the steps in order, and the other
questions still wait for a person.

## Goals

1. `/qa-auto <target>` runs constitution → spec → scenarios → analyze → run → verify without
   stopping for a person.
2. Every question a step would have asked is answered by the agent from evidence, and written down
   with the evidence, as an assumption.
3. A second, independent look at those answers that can only hand a question to a person, never
   approve one.
4. A fixed list of things the agent never decides, checked by a script after the journey.
5. The journey survives an interruption: started again, it continues where it stopped.
6. One handoff list at the end: what was decided without a person and what a person still owes.
7. It works on all four harnesses.

## Non-goals

- Fixing the application's bugs. The journey ends with a verified report and a bug list (owner
  decision: QA only).
- Setting up the project from nothing: `.qa/config.json` and working sign-in for the roles must
  exist. The journey stops with a plain message when they do not.
- Running several targets in one command.
- A headless shell runner for CI. Stage 2 (see Stages); the state machine is built so it can be
  added without change.
- Changing what `autonomousSetup` means for a person who sets it without `/qa-auto`.

## Anti-goals

- A result that looks more trustworthy than it is: an assumption shown as a confirmation, or a
  pass at high confidence that rests on a value only the agent chose.
- The agent writing to an environment, excluding coverage, or loosening a safety setting to get
  further.
- A journey that reports "done" while ClickUp, verification or the handoff list is missing.
- Any change to the engine (ADR-0022), and any step that turns a non-pass into a pass or raises a
  confidence (ADR-0032, ADR-0033).

## Constraints found

- On Claude, an agent started by a command cannot start further agents. `/qa-run` dispatches the
  engine agent and then runs re-adjudication itself. So `/qa-auto` must run in the main session and
  call each step's instructions inline, not as a nested agent.
- Only Claude can dispatch a fresh agent (`harness-profiles.json` `subagentDispatch`). The second
  look (goal 3) is therefore Claude-only, with the same "unavailable" banner pattern
  re-adjudication uses elsewhere.
- `CONTEXT.md` reserves the word "autonomous" for the setup flag and says not to use it
  unqualified. This design uses **unattended journey** for the new thing.
- Run state belongs in files, never in the agent's memory (ADR-0002).
- The questions that stop a person today, by step:
  - Constitution: which roles are real; who should reach each screen.
  - Spec: the scope, role overrides, whether to run the seed command, which journeys are P1.
  - Scenarios: tricky input values and expected results for calculated checks; coverage exclusions.
  - Analyze: fixes for the gaps it lists; accepting a census built without the stack adapter.
  - Run and verify: none.

## Approaches

**A. One instruction file** telling the agent to run the six commands in order. Smallest, but the
order, the answers and the limits live only in the agent's context. A long run loses its place
when context is compacted, and nothing outside the agent checks the limits. Rejected.

**B. A state machine in a script with a thin command over it (picked).** `auto.sh` keeps the
journey on disk and decides what is next; the agent does each step's work and records its answers
through the script; the script audits the limits at the end. Resumable, portable, testable without
a model.

**C. A headless runner only**, starting a fresh agent per step from the shell. Good for CI, no use
inside a session. Deferred to stage 2 on top of B's script.

The owner handed the choice to the author; B is the author's pick.

## The design

### D1. The command and the journey

`/qa-auto <target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]` in
`qa-kit/core/commands/qa-auto.md`.

The journey for a target lives in `.qa/specs/<target>/auto/`:

- `journey.json`: the steps with their state (`pending`, `running`, `done`, `stopped`), the run id
  once there is one, start and end times, and the stop reason if any.
- `decisions.json`: every self-answered question (D3).
- `baseline.json`: the snapshot the audit compares against (D5).
- `handoff.md`: the list for a person (D6).

`qa-kit/scripts/auto.sh` owns these files. Verbs:

| Verb | Does |
|---|---|
| `start <target>` | Checks the preconditions (D2), writes `baseline.json` and `journey.json`. Refuses if a journey is already open, unless `--restart`. |
| `next <target>` | Prints the next step and what it needs, from the files on disk (the same checks `/qa-status` makes), or `done`, or `stopped: <reason>`. |
| `decide <target>` | Records one decision (D3). Refuses a decision of a forbidden class (D4). |
| `step-done <target> <step>` | Marks a step done after checking its artifact exists. |
| `audit <target>` | Runs the checks in D5. Exit 1 on any violation. |
| `handoff <target>` | Writes `handoff.md` from the decisions and the run's files. |
| `status <target>` | Prints the journey as JSON. Read-only. |

The command is a loop: `next` → do that step following its own command source with the rules of
this design → `step-done` → `next`, until `done` or `stopped`. Then `audit`, then `handoff`. Each
step is the existing command's instructions; `/qa-auto` adds no second copy of them.

Starting `/qa-auto <target>` again while a journey is open continues from `next`. A run that was
interrupted mid-verify is continued with the engine's own resume (`/qa-resume`), not restarted.

Starting it after a journey has finished opens a new journey; the finished one moves to
`auto/history/<n>/`. The new journey keeps the spec and scenarios that exist (those steps are
already done), and runs analyze, a full new run, and verify. There is no partial re-run: the
engine runs a whole plan, and a confirmation changes the plan, so the earlier run no longer matches
it. `--restart` abandons an open journey and resets only `auto/`.

**Files a person wrote are never regenerated.** A step whose artifact exists is done, whoever
wrote it. Exclusions, a `seed.json` and `oracleSource: "human"` rows that exist at `start` are
taken into the baseline as they are; the audit only looks at what changed during the journey. To
have a step redone, a person removes its artifact or runs that step's own command.

**An existing constitution is reused.** The journey runs the constitution step only when the
project has none. Regenerating it would change project-wide state that other specs snapshot.

**The profile is the person's choice, not the agent's.** The journey runs under the project's
profile. `--profile` at launch sets it for this spec's run-config, as `/qa-spec` does today; the
agent never picks or changes it. Under `full` there is no coverage gate, no journeys and no ship
verdict, so the `journeys` and `gaps` rules in D3 do not apply and the result line is "verified"
or "not verified", with no "ready".

### D2. Preconditions and hard stops

`start` refuses, with one plain line each, when:

- `.qa/config.json` is missing. The journey does not invent a config, credentials or accounts.
- The environment resolves to production. An unattended journey does not run there.
- `.qa/known-defects.json` exists and `known-defects.sh validate` rejects it (the run could never
  verify).
- Another journey is open in this project, for any target. Journeys share browser sessions,
  accounts and data, so only one runs at a time.
- The environment is not local and `gates.dataPolicy` is not `enforce`. The data policy check is
  what keeps marked or careless data off a shared environment when nobody is watching.

The command, not the script, then runs the engine's pre-flight (a qa-kit script cannot call an
engine script); a dead application stops the journey there.

Sign-in is checked after the constitution step, when the roles are known: `auto.sh` checks that
each persona has its sign-in configured (the file or entry the config names; presence only). Real
sign-in happens in the run. A persona without it stays in the plan; the engine records its checks
as `blocked`, and the handoff lists the persona. If no persona has sign-in configured, the journey
stops.

During the journey it stops, keeps everything written so far, and writes the handoff when:

- the time limit is reached (`--max-hours`, default 6). `auto.sh next` checks it between steps and
  the command checks it between criteria batches where the engine allows a clean pause; started
  again, the journey continues from the same point;
- analyze is still `BLOCKED` after two rounds of adding scenarios (D3, "gaps");
- a step's script fails for a reason the agent cannot fix by redoing the step once;
- ClickUp is required for the spec and a ClickUp step fails (the ClickUp design's D7);
- the audit fails.

**How the setup questions are skipped.** No config is edited and nothing is written to the spec's
run-config for this (the run-config merge replaces whole top-level keys, so it would drop
`humanInteraction.enforce` and `maxOptOutRate`, and it would outlive the journey). The open
journey itself is the signal: each qa-kit command source gains one line, "an open unattended
journey for this target (`auto.sh status`) counts as `autonomousSetup` on for this step", and
`/qa-constitution` tells the engine's role-confirmation skill to take its autonomous setup path,
with the reason `unattended journey`. When the journey closes, a person running any step is asked
as usual.

### D3. Answering its own questions

Before each step the agent lists the questions that step would ask a person. For each it looks for
evidence in the project (the code, routes and permissions, an ingested spec-kit, the census, the
constitution, existing docs), answers, and records the answer with
`auto.sh decide <target> --step <step> --class <class> --question … --answer … --evidence …
--confidence high|low`. A decision is always stored as `assumption: true`.

How each class of question is answered:

| Class | Answer rule |
|---|---|
| `roles` | Accept discovered roles (the existing `autonomousSetup` behaviour). |
| `surface-access` | Assume, never deny (existing behaviour). |
| `scope` | The target's screens from the census and the routes that serve them. When unsure whether a screen belongs, include it. |
| `role-overrides` | None, unless the code shows the target treats a role differently. |
| `journeys` | Journeys from what users do end to end in the target. When unsure whether one is P1, mark it P1: the cost of a wrong P1 is extra checking, the cost of a missed one is a false "ready". |
| `inputs` | The tricky input values for a calculated check (boundaries, rounding cases), chosen by the agent. |
| `expected` | A value with `oracleSource: "spec"` only when a spec line can be cited and `check-fixtures.sh` resolves it. Otherwise the value is a proposal, the check can pass only at low confidence, and it goes on the handoff list. Never `oracleSource: "human"`. |
| `gaps` | For a gap analyze lists, add scenarios or checks that close it and run analyze again. At most two rounds. |

**The second look (Claude only).** After the spec step and after the scenarios step, a fresh agent
is given only that step's decisions, their evidence and the artifact. It answers per decision
`stands` or `ask a person`, with a reason. `ask a person` sets `needsPerson: true` on the decision;
it cannot change an answer or approve one. Where a fresh agent cannot be dispatched, the journey
prints the "second look unavailable" line, marks every low-confidence decision `needsPerson`, and
goes on. The acting agent never reviews its own decisions.

### D4. What the agent never decides

`auto.sh decide` refuses these classes, and the step goes on without them:

| Never | What happens instead |
|---|---|
| Running a seed command (`seed`) | No `seed.json` is written; the spec stays declare-and-verify. Listed on the handoff. |
| Excluding a screen or role pair from coverage (`exclusion`) | Nothing is excluded. If coverage cannot be reached, analyze stays `BLOCKED` and the journey stops. |
| Accepting a census built without the stack adapter (`crawl-only`) | Not accepted (already the rule under `autonomousSetup`). |
| Confirming an expected value as a person (`oracle-human`) | See `expected` in D3. |
| Changing a safety setting (`safety`): `allowApiWrites`, `seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, `gates.*`, `profile`, `humanInteraction.enforce`, `maxOptOutRate` | Left as the project set them. |
| Moving a check into the known-defect registry (`known-defect`) | The registry is not touched: an entry without `ticket` and `expiry` fails verification for every spec. A check that asserts an application failure is left out of the plan and listed on the handoff. |

### D5. The audit

`auto.sh audit` compares the end state with `baseline.json` and fails the journey on any of:

- a safety setting in `.qa/config.json` differs from the baseline;
- the spec's `run-config.json` sets any key of the safety list other than the `profile` given at
  launch;
- `.qa/known-defects.json` changed;
- a `checklist.json` row has `oracleSource: "human"` that it did not have at the start;
- `seed.json` appeared, or `coverage-exclusions.json` gained an entry, during the journey;
- a decision of a forbidden class is recorded;
- a step is marked done without its artifact, or the run has no `verification.json`;
- the spec is tracked in ClickUp and `spec-status` says ClickUp is behind.

The audit is a script reading files. It does not trust the agent's account of what it did. A
failed audit makes the journey `stopped: audit`, and the handoff leads with the violation.

### D6. The handoff

`handoff.md`, written at the end of every journey, complete or stopped, in plain words:

1. The result, which is never better than the engine's and is stricter in one way. It says
   "ready" only when the engine's ship verdict is SHIP-READY **and** no P1 check rests on a
   decision marked `needsPerson` or on an expected value that is only a proposal. Otherwise it
   says "not confirmed: N items need a person", even if a fresh agent agreed with the evidence
   during re-adjudication. Other results: not ready with the reasons, verified or not verified
   (under `full`), or stopped and why. `auto.sh handoff` computes this from files.
2. Decided without a person: each decision, grouped by step, with its evidence in one line.
3. Needs a person: decisions marked `needsPerson`, expected values that are only proposals, checks
   that passed at low confidence, the seed command that was not run, known defects missing a
   ticket.
4. How to confirm: the existing tools, by name. The expected-value page
   (`oracle-confirm.sh render`), the access table (`surface-access.sh confirm-table`), and
   `/qa-auto <target>` again after confirming, which starts a new journey on the confirmed plan
   (D1).
5. The scope the agent chose for the spec, always shown, because a scope that is too narrow hides
   gaps the coverage gate cannot see.

### D7. Harnesses and long runs

- `/qa-auto` is a normal qa-kit command source, generated for all four harnesses (ADR-0024).
- The second look and re-adjudication follow `subagentDispatch`; elsewhere their banners print.
- On a laptop the command's first line tells the agent to keep the machine awake for the journey
  (`caffeinate -dimsu` on macOS) and to release it at the end.
- `/qa-status` shows an open journey: the step it is on, and how many items wait for a person.

### D8. ClickUp

ClickUp is not a step of the journey. It is a setting on the spec that any step honours.

- A spec that is tracked: every step syncs as the ClickUp design describes, and a failed sync stops
  the journey.
- A spec that is not tracked: the journey never contacts ClickUp and never asks.
- A new spec written by the journey: tracked from the start only when the project file sets
  `specDefaults.enabled: true`. This is one new key in the ClickUp design's project config (P1
  order: template < machine < project < `specDefaults` < `specs.<target>`). Without it the spec is
  untracked until a person runs `/qa-tracker --spec <target>`, at any point, after which later
  steps and the next journey sync.
- When tracked, one comment is posted on the Run summary ticket (`spec-note`): how many items
  need a person's review and where the results page is. It is built from fixed sentences and
  counts, never from the agent's decision text, so it cannot fail the wording check on content.

**Build order.** This is built after the ClickUp design's first release has landed, because it
uses `spec-status`, `spec-note` and `specs.<target>.enabled`. `specDefaults` is added to that
release's plan now.

### D9. Owner decisions (2026-11-27)

- **No written requirements.** The journey still runs. Every expected result taken from the
  application is a proposal (D3 `expected`), and the handoff opens with: "No written requirements
  were found for this target. Expected results were taken from the application and need a
  person." `auto.sh decide` records `--evidence none` for these so the handoff can count them.
- **Created records.** The handoff lists every record the run created (type and id, from
  `data-policy.sh list`). The journey deletes nothing.
- **Bugs.** Filed under the existing rules only: a failure with evidence is a bug, a repeat is a
  comment, a known defect is a duplicate, an evidence gap goes to needs-recheck. No separate
  review queue.
- **Default is the whole journey.** `--until scenarios` is for reading the plan before the run.
- **Harnesses without a fresh agent** still run the journey; every low-confidence decision is
  marked `needsPerson`.
- **Finish signals:** the handoff file, the ClickUp comment on a tracked spec, and the
  `/qa-status` line. No other alert in stage 1.

## Stages

1. **Stage 1:** `auto.sh` with all verbs, `/qa-auto`, the decision rules, the second look, the
   audit, the handoff, `/qa-status` line, the `specDefaults` key.
2. **Stage 2:** a headless runner (`qa-auto-ci.sh`) that starts a fresh agent per step from the
   shell using the harness's agent command, driven by `auto.sh next`.

## Left to the builder

- The exact JSON shapes of `journey.json`, `decisions.json` and `baseline.json`.
- jq with a python3 fallback for `auto.sh`, as the other qa-kit scripts do.
- How the journey's run-config turns `autonomousSetup` on without touching `.qa/config.json`
  (`runconfig-merge.sh` exists for this).
- The fixed table that turns engine reasons into plain handoff sentences.
- Tests: a new `tests/qa-auto/run.sh` suite over fixture projects, no model and no browser; added
  to `run-qakit-ci.sh` and the suite-coverage gate.
- An ADR, the term **unattended journey** in `CONTEXT.md`, README, CHANGELOG, version bump.
