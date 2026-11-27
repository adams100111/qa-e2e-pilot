---
description: Drive the whole qa-kit process for a target with nobody present, record every self-answered question, and end with a handoff list for a person.
argument-hint: "<target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]"
disable-model-invocation: false
---

Run an **unattended journey** for `<target>`: constitution → spec → scenarios → analyze → run → verify,
with nobody present. Full input: `$ARGUMENTS` — the first token is `<target>`; the flags are passed to
`auto.sh start` as they are.

The journey lives on disk in `.qa/specs/<target>/auto/` (`journey.json`, `decisions.json`,
`baseline.json`, `handoff.md`) and belongs to `${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh`. Never write those
files yourself and never keep the journey's place in your own memory: `auto.sh next` says what is next.
Below, `auto.sh <verb> …` is short for `bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" <verb> …`. Every verb exits
0 when it worked, 1 when it refused or failed (one line on stderr, `auto: <reason>`), 2 on a usage error.
`stop`, `decide`, `second` and `note` work only on an open journey; on any other they exit 1 with
`auto: no open journey for <target>`.

This command is a loop over `auto.sh next`. For each step it sends you to that step's own command
source. It holds no copy of any step's instructions: read the step's command and follow it.

**Run this command in the main session**, never inside an agent you started. An agent that was started
by another agent cannot start agents itself, and both the run step and the second look need to start
one where the harness can.

## Start

1. **Keep the machine awake.** On macOS start `caffeinate -dimsu` in the background and keep its
   process id; on another system use its equivalent, or go on without one. Release it at the end
   (step 12), whatever the outcome.

2. **Check the known-defect registry.** Only when `.qa/known-defects.json` exists, run the engine's
   `known-defects.sh validate .qa/known-defects.json` (an engine script: resolve it against the engine's
   checkout or plugin root, ADR-0022; qa-kit cannot address it). Remember whether it exited 0. Do not
   change the file, whatever it says.

3. **Open or continue the journey.** Run `auto.sh status <target>`. Exit 1 with
   `auto: no journey for <target>` means there is no journey yet; that is not an error.
   - It shows `state: open`, and `--restart` was not given → the journey continues. Go to step 4.
   - It shows `state: stopped` with a `stop.reason` of `time-limit`, `step-failed` or `until`, and
     `--restart` was not given → `auto.sh resume <target>` (add `--max-hours <n>` when it was given).
   - Anything else, no journey included → `auto.sh start <target>` with the flags from the input
     (`--profile`, `--until`, `--max-hours`, `--restart`), plus `--known-defects-invalid` when step 2 exited non-zero.

   If `start` or `resume` exits 1, print its one line, release the machine (step 12) and end. There is
   no journey, so there is nothing to audit or hand off. Do not try to remove the cause yourself.

4. **Pre-flight.** Run the engine's pre-flight (`scripts/preflight.sh` of its `driving-browser-qa`
   skill; an engine script, resolved as in step 2). If the application is down or the pre-flight aborts,
   run `auto.sh stop <target> --reason step-failed --detail "<the pre-flight's one-line reason>"` and go to
   the end (step 9).

## The loop

5. Repeat until `next` says `done` or `stopped`:

   1. `auto.sh next <target>` prints one JSON line: `{"next":"<step>"}`, `{"next":"done"}` or
      `{"next":"stopped","reason":…,"detail":…}`. On `done` or `stopped` leave the loop and go to the
      end (step 9). A stop for `time-limit` or `until` is not a failure: the journey continues the next
      time `/qa-auto <target>` is started.
   2. **Sign-in, once.** Before the first step that is not `constitution` (so: right after
      `constitution` is done, or at the first step when it was already done), run `auto.sh signin <target>`.
      It prints `{"ok":[…],"missing":[…]}`. A role in `missing` stays in the plan; do not create
      accounts, credentials or sign-in files for it. When no role has sign-in, `signin` stops the
      journey and the next `next` says so.
   3. `auto.sh step-start <target> <step>`.
   4. **Do the step by following its own command source**, under the answer rules and the never list
      below:

      | Step | Follow |
      |---|---|
      | `constitution` | `/qa-constitution` |
      | `spec` | `/qa-spec <target>` |
      | `scenarios` | `/qa-scenarios <target>` |
      | `analyze` | `/qa-analyze <target>` |
      | `run` | the engine's run command (step 6) |
      | `verify` | `/qa-verify <target> <run-id>` |

      Each of those commands treats the open journey as `autonomousSetup` on, so it asks nobody. Where
      it would have asked a person, answer by the rules below and record the answer (step 7).
   5. `auto.sh step-done <target> <step>`; for the run step `auto.sh step-done <target> run --run <run-id>`.
      It refuses (`auto: <step> has no result yet`) when the step's files are missing.
   6. After `spec` and after `scenarios`, take the second look (step 8), then go back to 5.1.

   **A step that fails** (its command stops on an error, or `step-done` refuses) is redone once from
   5.3. If it fails again: `auto.sh stop <target> --reason step-failed --detail "<one line>"`, then the end.

   **A required ClickUp step that fails.** The step commands sync a spec that is tracked in ClickUp.
   When a sync fails, the step command still gives its own result first and then says ClickUp was not
   updated. Do not redo the step and do not go on without the sync:
   `auto.sh stop <target> --reason tracker --detail "<the tracker's one-line error>"`, then the end.
   `lint` reporting problems is not a failed sync: fix the cards and run it again, as `/qa-scenarios`
   says. A spec that is not tracked is never offered tracking and never contacts ClickUp.

   **When analyze ends `BLOCKED`**, `step-done` reopens `scenarios` and `analyze` itself, and stops the
   journey after the second round. Follow `next`; never mark the analysis anything other than what the
   gate's exit code says.

6. **The run step.** It has no qa-kit command source. Follow the engine's run command,
   /qa-e2e-pilot:qa-run, with the arguments `"<target>" .qa/specs/<target>/checklist.json` (the hand-off
   `/qa-spec` step 8 describes), exactly as a person typing it would: every step of that command, in
   this session, including where it starts the engine's agent and its whole end-of-run order
   (`qa-verify` → re-adjudication → `qa-verify` again → bug export → render report). Skip none of it
   and reorder none of it. The run id is the run directory that command reports.
   - **An interrupted run is continued, never started again.** When the step is `run` and a run of this
     plan is already in progress under `.qa/runs/` (its `checkpoint.json` holds this checklist's
     criteria and it has no finished report), follow the engine's resume command (`/qa-resume <run-id>`)
     the same way, including its end-of-run order. Never start a second run for the same journey.
   - **The time limit.** Each time the run hands control back to you before it has finished, run
     `auto.sh next <target>`. If it says `stopped` with `time-limit`, leave the run where it is (it is
     resumable) and go to the end.
   - Change no verdict, no confidence and no file of the run by hand. The result is what the engine's
     files say.

## Answering in place of a person

7. Before each step, list the questions that step's command would ask a person. For each one look for
   evidence in the project (the code, routes and permissions, an ingested spec-kit, the census, the
   constitution, existing docs), answer by its class rule, and record it before you act on it:

   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" decide <target> --step <step> --class <class> \
       --question "<the question>" --answer "<your answer>" \
       --evidence "<file:line, route, census entry or document>" --confidence high|low \
       [--criteria <id>,<id>]
   ```

   Use `--evidence none` when there is no evidence, and `--confidence low` whenever the answer rests on
   your own reading and not on something written. `--criteria` names the checklist rows the answer
   decides. Every recorded answer is an assumption a person may overturn; never describe one as
   confirmed. `decide` prints the decision id.

   **Answer rules, by class:**
   - `roles` — Accept the discovered roles (what `autonomousSetup` already does).
   - `surface-access` — Assume, never deny (what `autonomousSetup` already does).
   - `scope` — The target's screens from the census and the routes that serve them. When unsure whether
     a screen belongs, include it.
   - `role-overrides` — None, unless the code shows the target treats a role differently.
   - `journeys` — The things users do end to end in the target.
     When unsure whether a journey is P1, mark it P1: a wrong P1 costs extra checking, a missed one
     costs a false "ready".
   - `inputs` — You choose the tricky input values for a calculated check (boundaries, rounding cases).
   - `expected` — Write `oracleSource: "spec"` only when you can cite a spec line and `check-fixtures.sh`
     resolves the citation. Otherwise the value is a proposal: leave it `llm-suggested`, so the check
     can pass only at low confidence and goes on the handoff list. Never `oracleSource: "human"`. When
     the target has no written requirements at all, still record each expected value, with
     `--evidence none`.
   - `gaps` — For a gap analyze lists, add scenarios or checks that close it, then let analyze run
     again. Two rounds at most; `auto.sh` counts them.

   Under the `full` profile there is no coverage gate and there are no journeys, so the `journeys` and
   `gaps` rules do not apply.

   **The profile is the person's choice.** When the journey was started with `--profile`, the spec step
   writes that value as `profile` in the spec's run-config, as `/qa-spec` does. Without the flag write
   no `profile`. Never pick a profile yourself and never change one that exists.

   **Files that exist are kept.** A step whose files exist is already done, whoever wrote them. Do not
   regenerate a spec, a plan or a constitution, and leave existing exclusions, an existing `seed.json`
   and existing person-confirmed expected values as they are.

   **Never do these.** `auto.sh decide` refuses each class, the audit at the end checks each from the
   files, and the step goes on without it:
   - Never run a seed command, and never write `seed.json` (`seed`). The spec stays declare-and-verify.
     When a seed command was proposed and not run, record that with `note --kind seed-not-run` (below).
   - Never exclude a screen or a screen and role pair from coverage, and never add to
     `coverage-exclusions.json` (`exclusion`). If coverage cannot be reached, analyze stays `BLOCKED`
     and the journey stops.
   - Never accept a census built without the stack adapter, and never pass `--accept-crawl-only`
     (`crawl-only`).
   - Never confirm an expected value as a person: never set `oracleSource: "human"` and never run
     `oracle-confirm.sh apply` (`oracle-human`). See `expected` above.
   - Never change a safety setting (`safety`), in `.qa/config.json` or in the spec's run-config:
     `allowApiWrites`, `seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, anything under `gates`,
     `profile`, `humanInteraction.enforce`, `humanInteraction.maxOptOutRate`. They stay as the project
     set them. Do not turn `autonomousSetup` on in a file either: the open journey is the signal.
   - Never add to, edit or migrate a check into the known-defect registry (`known-defect`). A check
     that asserts an application failure is left out of the plan; record that with
     `note --kind check-left-out` (below), naming the check in plain words.
   - Never delete a record the run created, and never weaken a gate, a criterion or an expected value
     to get further. A step that cannot go on within these rules stops the journey.

   **Facts for the handoff.** A seed command that was proposed and not run, and a check left out of the
   plan because it asserts an application failure, are facts, not answers. Record each with `note`,
   never with `decide`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" note <target> --kind seed-not-run|check-left-out --text "<plain sentence>"
   ```

## The second look

8. After the `spec` step and after the `scenarios` step:

   Take this step's decisions: the records in `.qa/specs/<target>/auto/decisions.json` whose `step` is the
   step just done and whose `second` is `null`. If there are none, skip the second look for this step.

   Start one fresh agent for this step (the Agent/Task tool, a general-purpose agent; one agent per
   step, never one shared between steps). Give it ONLY:
   - those decisions, each with its `id`, `class`, `question`, `answer`, `evidence` and `confidence`;
   - the evidence each decision names, as paths and lines it reads itself;
   - the step's artifact: after `spec`, `.qa/specs/<target>/qa-spec.md`, `spec-roles.json` and, when they
     exist, `journeys.json` and `coverage-scope.txt`; after `scenarios`, `.qa/specs/<target>/scenarios.md`
     and `checklist.json`.

   It never receives this conversation, a summary of it, your reasoning, or what you expect it to say.
   Ask it for one line per decision: the decision id, then `stands` or `ask a person`, then a reason.
   Record each line as it answered, changing nothing:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" second <target> <decision-id> stands --reason "<its reason>"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" second <target> <decision-id> ask --reason "<its reason>"
   ```
   `ask a person` is recorded as `ask`. A decision it did not answer, or answered with anything else, is
   recorded as `ask` with the reason `no answer from the second look`.

   If the fresh agent cannot be started (for example this command is itself running inside an agent),
   do not review the decisions yourself. Say so with the line below and run the command under it:
   ```
   SECOND LOOK UNAVAILABLE: this harness cannot start a fresh agent; every low-confidence decision is left for a person.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto.sh" second <target> --unavailable
   ```

   The second look can only hand a decision to a person. It never changes an answer and never approves
   one, and you never review your own decisions in its place. It runs only here, after these two steps,
   while the journey is open: never at the end and never on a closed journey. `auto.sh handoff` itself
   counts every low-confidence decision that has no second-look verdict as needing a person, on every
   harness.

## The end, always

9. **Audit.** `auto.sh audit <target>` prints `{"ok":bool,"violations":[…]}` and exits 1 when a limit was
   broken; it then stops the journey itself. Do not undo anything to make it pass and do not run it a
   second time to get a better answer. Go on to step 10 either way.

10. **Handoff.** When the journey has a run (`runId` in `auto.sh status <target>`), write the engine's
    `data-policy.sh list .qa/runs/<run-id>` output (an engine script, resolved as in step 2) to a temp
    file. Then `auto.sh handoff <target> --records <file>` (without `--records` when there is no run). It
    writes `.qa/specs/<target>/auto/handoff.md` and prints `{"result":…,"needsPerson":n}`. The journey
    deletes none of those records.

11. **ClickUp note.** Only when docs/agents/qa-tracker.json has specs.<target>.enabled: true. Write one
    sentence to a file under the session's temp directory, nothing else and none of your own words:
    `<n> items need a person's review. See the results page.` with `<n>` from step 10, or
    `Nothing needs a person's review.` when it is 0. Then:
    ```
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/tracker.sh" spec-note --spec <target> --file <note-file> --apply
    ```
    If it exits non-zero, do not try to stop the journey (it is closed by now) and do not run the
    handoff again. Keep its one-line error for step 12.

12. **Close.** Release the machine (stop the `caffeinate` process from step 1). Print the `Result`
    section of `handoff.md` word for word and the path `.qa/specs/<target>/auto/handoff.md`. Add
    nothing that reads better than that section: the result is the one `auto.sh handoff` computed from
    the files, never your own summary of how the journey went. When step 11 failed, end with one more
    line: `The ClickUp comment was not posted: <its one-line error>`.

Guardrails: one journey per project at a time; the journey's files are written only by `auto.sh`; every
answer given in place of a person is recorded with `decide` before it is used; the never list holds for
every step; a stopped journey is still audited and handed off; an unattended journey ends with a
verified report and a bug list, it does not fix the application.
