#!/usr/bin/env bash
# auto.sh — the state machine of an unattended journey (qa-kit, dual-engine).
#
# An unattended journey is one agent driving the whole qa-kit process for a target:
# constitution → spec → scenarios → analyze → run → verify. This script owns the journey's
# files and nothing else:
#
#   .qa/specs/<target>/auto/journey.json     the steps, their state, the deadline, the stop reason
#   .qa/specs/<target>/auto/baseline.json    the snapshot taken at start that the audit compares against
#   .qa/specs/<target>/auto/decisions.json   every answer the journey gave in place of a person (an array)
#   .qa/specs/<target>/auto/notes.json       things left for a person that are not decisions (an array)
#   .qa/specs/<target>/auto/handoff.md       what a person reads at the end (written by `handoff`)
#   .qa/specs/<target>/auto/history/<n>/     earlier journeys of the same target
#
# It NEVER writes outside `.qa/specs/<target>/auto/` and never edits `.qa/config.json`, the spec's
# `run-config.json`, `checklist.json` or the known-defect registry; it only reads them. It never
# calls an engine script (ADR-0022): where an engine result is needed the command passes it in
# (for example `--known-defects-invalid`). The two scripts it does call are qa-kit's own, beside
# this one: `tracker.sh spec-status` (the audit) and `verify-plan.sh` (`step-done verify`).
#
# USAGE (every verb takes `--project <dir>`, default `.`):
#   auto.sh start  <target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>]
#                           [--restart] [--known-defects-invalid]
#   auto.sh resume <target> [--max-hours <n>] [--known-defects-invalid]
#   auto.sh stop   <target> --reason <reason> --detail <text>
#   auto.sh status <target>
#   auto.sh next       <target>                    -> {"next":"<step>"} | {"next":"done"}
#                                                     | {"detail":…,"next":"stopped","reason":…}
#   auto.sh step-start <target> <step>
#   auto.sh step-done  <target> <step> [--run <run-id>]
#   auto.sh signin     <target>                    -> {"missing":[…],"ok":[…]}
#   auto.sh decide <target> --step <step> --class <class> --question <text> --answer <text>
#                           --evidence <text|none> --confidence high|low [--criteria id,id]
#                                                  -> the new decision's id (`D<n>`)
#   auto.sh second <target> <decision-id> stands|ask --reason <text>
#                                                  -> {"id":…,"needsPerson":…,"second":…}
#   auto.sh second <target> --unavailable          -> {"marked":[<ids newly left for a person>]}
#   auto.sh note   <target> --kind seed-not-run|check-left-out --text <text>
#                                                  -> the new note's id (`N<n>`)
#   auto.sh audit  <target>                        -> {"ok":bool,"violations":[…]}; exit 1 when not ok
#   auto.sh handoff <target> [--records <file>]    -> writes auto/handoff.md; {"result":…,"needsPerson":n}
#
#   start, resume, stop, status, step-start and step-done print ONE JSON line, the STATUS LINE:
#   journey.json plus {"needsPerson": n}. status writes nothing. next and signin print their own
#   one line. step-start and step-done print the `next` line of a stop, with exit 1, when a limit
#   stops the journey (see STEP ORDER).
#
# THE TWO `needsPerson` NUMBERS are not the same count:
#   - the status line (`status`, and the verbs that print it): the number of DECISIONS in
#     decisions.json that need a person, and nothing else;
#   - `handoff`: the number of ITEMS listed under "Needs a person" in handoff.md: those same
#     decisions, plus expected results that are only a proposal, checks that passed at low
#     confidence, roles without sign-in, notes, and one item per file that could not be read.
#   So the handoff's number is never smaller. Both use one rule for which decision needs a person
#   (JQ_NEEDS): marked `needsPerson`, or the second look said `ask`, or made at low confidence with
#   no second look that let it stand.
#
# journey.json: {version, target, profile, startedAt, deadline, until, steps: [{name, state,
#   attempts}], analyzeRounds, runId, state: open|done|stopped, stop: null|{reason, detail},
#   endedAt, baselineHash} plus, when they apply:
#   stepsChangedAt    when a step verb last changed a step
#   resumes           one {at, maxHours, from} per `resume`: when, the new time limit, the stop it
#                     resumed from
#   replacedFrom      the history number of the journey this one took the place of (any state)
#   restartedFrom     the same number, when that journey was still open (`start --restart`)
#   replacedAfterAudit  true when that journey had stopped with reason `audit`
#   secondLook        "unavailable" after `second --unavailable`
#   audit             {ok, at}: the last audit's verdict and time
#   auditViolations, stopBeforeAudit   after a failed audit
#
# THE GATE (`start`, and again on every `resume`), in this order; nothing is written before all hold.
# The settings it judges are the MERGED ones: `.qa/config.json` with each top-level key of the
# spec's `run-config.json` replacing the config's key of the same name, an explicit null included.
# That is how the engine resolves a run's effective config (scripts/profile.sh, a shallow merge),
# so the gate and the baseline see what the run will see.
#   - `.qa/config.json` is there and is one JSON document (a leading byte order mark is accepted);
#     the spec's run-config.json, when there is one, is one JSON object.
#   - `environment` is `auto`, `production` or `disposable` in any letter case; a missing key reads
#     as `auto`; any other word or a value that is not text is refused.
#   - the environment is not production. Production is `environment: production`; or a project
#     with no `baseUrl` (missing, empty, blank, not text) unless it is `disposable` with a real
#     `seedableEnvMarker`; or any environment other than `disposable` on a host that is not local
#     with no real marker. A marker that is empty, blank or the bootstrap word QA_DISPOSABLE_ENV is
#     not real. A host is local only when it is exactly `localhost`, `127.0.0.1`, `[::1]` or ends in
#     `.localhost`, `.test`, `.local`, `.ddev.site`, and the address holds nothing unusual: a
#     backslash, a blank, a host character outside `a-z 0-9 . -`, a port that is not digits or
#     anything after `[::1]` other than a port makes it not local.
#   - `--known-defects-invalid` was not passed.
#   - no journey of ANY target in the project is unreadable (its journey.json is not one JSON
#     object whose `state` is open, done or stopped; or its spec folder or journey folder cannot
#     be looked into), and no other target's journey is open. Folders whose name starts with a dot
#     are looked at too.
#   - on a host that is not local, the run's `gates.dataPolicy` will be `enforce` (judged under the
#     launch profile; on `resume`, the profile recorded in journey.json).
#   - (`start`) no safety setting, exclusion or person-confirmed expected value holds a number the
#     two engines could not compare alike (see NUMBERS below).
#   - (`start`) this target has no journey, or its journey is finished (`done`). Any other journey
#     of the target (open, or stopped for ANY reason: the three that can be resumed, and blocked,
#     audit, no-sign-in, tracker) is replaced only with `--restart`; a plain `start` is refused. A
#     new journey takes a new baseline, so replacing one that is not finished is a person's choice.
# The launch profile is `--profile`, else the run-config's `profile`, else the config's, else `full`.
# A target must be a plain name (`^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`), for every verb.
# `--max-hours` is between 0.1 and 72.
#
# WRITES: every file is written whole to a temporary name beside it and moved into place. A write
# that fails ends the verb with exit 1 and the one line `auto: could not write <path>`; nothing
# that reads as a result is printed, and `start` never writes journey.json after a failed baseline.
# A folder at the path of a journey file is a failed write. The spec folder and the journey folder
# must be real folders, and so must `auto/history`: when any of them is a link, every verb that
# writes refuses with `auto: the journey folder must be a real folder` (reading through the link
# still works).
#
# DECISIONS: `decide` appends one record to decisions.json:
#   {id, step, class, question, answer, evidence, confidence, criteria:[], assumption:true,
#    needsPerson, second:null|"stands"|"ask", secondReason}
# `--evidence none` (the word in any letter case, blanks around it ignored) stores `evidence: null`
# and `needsPerson: true`; an evidence value that is empty after trimming is a usage error. A class
# the journey must never decide (FORBIDDEN_CLASSES) is refused. `second` records the second look:
# `ask` sets `needsPerson: true`; `stands` never clears it; once a decision is `ask` it stays `ask`.
# `second --unavailable` leaves every low-confidence decision without a second look for a person
# and writes `secondLook: "unavailable"` into journey.json; from then on `second <id> stands` is
# refused for that journey (`ask` is still taken). `note` appends {id, kind, text, at} to
# notes.json. All three verbs need an open journey. Free text is passed to the engines as
# arguments, never as program text, so it is stored exactly as given.
#
# SIGN-IN: `signin` lists the personas of .qa/config.json by whether their `auth` entry says how
# they sign in. Only these count as configured (auth_configured): a text naming a `.json` file
# (any letter case of the ending) that exists inside the project and is not a link; a seeded login
# pattern (a word with `@`); `login as …`; `none needed`. Empty, `unknown…`, and words such as
# TODO, none, not configured or `?` do not. With no persona at all the one sign-in is
# `auth.storageState`, under the same file rule. When nobody is configured the journey stops
# (`no-sign-in`).
#
# AUDIT: `audit` compares the files as they are now with baseline.json and with the journey's own
# record, and never takes the caller's word. It may run on an open, done or stopped journey. Every
# check runs; the codes are printed sorted. Every audit leaves its record in journey.json,
# `audit: {ok, at}`; a passing audit changes nothing else. A failed audit makes the journey
# `stopped` / `audit` (also a journey that was done), with the codes joined by `, ` in
# `stop.detail`, the list in `auditViolations` and the earlier stop, if any, in `stopBeforeAudit`.
# Once failed it stays failed: a later audit reports the earlier codes plus what it finds (and
# writes nothing when that is the same list). Codes:
#   baseline-missing                    there is no baseline.json
#   baseline-changed                    baseline.json is not the file `start` wrote (its SHA-256 is kept
#                                       in journey.json as `baselineHash`), or it no longer parses
#   base-url-changed                    the MERGED `baseUrl` (config, then run-config) is not the one
#                                       recorded at the start, or the settings cannot be read. Skipped
#                                       for a baseline written before the address was recorded.
#   safety-setting-changed:<key>        a SAFETY_KEYS value of the MERGED settings differs from the
#                                       baseline: changed, added (an explicit null included) or
#                                       removed, through either file. By value: key order and number
#                                       spelling do not count; a changed type does; a number that is
#                                       not plain (NUMBERS) always does. `profile` equal to the launch
#                                       profile is not a change. Settings that cannot be read (the
#                                       config or the run-config) fail every key.
#   run-config-safety:<top-level key>   the spec's run-config.json gained, changed or lost one of its
#                                       own RC_KEYS keys (the top-level parent of every safety key:
#                                       allowApiWrites, seedableEnvMarker, environment,
#                                       allowBlackboxCrawl, gates, profile, humanInteraction; and
#                                       baseUrl), except `profile` set to the launch profile. A
#                                       run-config that cannot be read, or is not an object, fails
#                                       every key.
#   known-defects-changed               .qa/known-defects.json has other bytes, appeared or is gone
#   human-oracle-added:<criterion id>   a plan row is `oracleSource: "human"` and was not at the start
#   human-oracle-removed:<criterion id> a row that was `human` at the start still exists and is not now
#   human-oracle-changed:<criterion id> a row is still `human` and its `fixture.expect` is not the one
#                                       recorded at the start (SHA-256 of its canonical JSON: keys
#                                       sorted, compact, numbers normalised), or holds a number that
#                                       is not plain. Skipped for a baseline without `humanOracleHashes`.
#   plan-row-removed:<criterion id>     a row of the starting plan is gone (adding rows is allowed)
#   plan-unreadable                     checklist.json is not one JSON array
#   seed-added                          seed.json exists and did not at the start
#   exclusion-added                     coverage-exclusions.json has an entry the baseline does not
#                                       (or is unreadable, or no longer an array)
#   forbidden-decision:<id>             decisions.json holds a record whose class is not one a journey
#                                       may decide (`#<n>`, its place in the file, when it has no id)
#   decisions-unreadable                decisions.json is not one JSON array
#   step-without-result:<step>          a step other than verify is marked done and its result is not
#                                       on disk
#   not-verified                        the journey is done, or its verify step is, and the recorded
#                                       run's verification.json is missing, does not parse, or holds
#                                       no rows (`null`, `[]`, `{}`; see STEP ORDER)
#   tracker-behind                      `bash <this directory>/tracker.sh spec-status --spec <target>
#                                       --project <dir>` failed, gave no answer, or answered anything
#                                       other than: a JSON line whose `behind` is the boolean false
#                                       (a set-up spec; the line may also say `"setUp": true`); or
#                                       its not-set-up answer, which is one JSON object, alone, with
#                                       `"setUp": false` (`{"setUp": false, "target": "<target>"}`),
#                                       or, as earlier trackers printed it, exactly
#                                       `SKIP<TAB>not-set-up<TAB>…` on the first line (alone, or
#                                       followed by one `SUMMARY …` line). The tracker is not asked
#                                       at all when the project has no `docs/agents/qa-tracker.json`:
#                                       then no spec is tracked. Its stderr is never shown. It is
#                                       stopped after QA_AUTO_TRACKER_TIMEOUT seconds (default 60)
#                                       when `timeout` or `gtimeout` is installed; without either
#                                       there is no time guard. `QA_AUTO_TRACKER_CMD` replaces the
#                                       command only when `QA_AUTO_TEST=1` is set too (the suites).
# The baseline carries `safety` (the merged value of every safety key the settings HAD; a key they
# did not have is left out), `baseUrl` (merged) and `runConfig` (the run-config's own RC_KEYS keys
# as they were). A baseline written before this (no `runConfig` key: config-only `safety` values
# with null for an absent key, and `runConfigSafety`) is still audited, the earlier way: config
# values against `safety`, the run-config's dotted safety keys against `runConfigSafety`.
# What the audit does not check: two of the classes a journey never decides leave no file of
# their own for it to compare. `crawl-only` (a census accepted without the stack adapter) and a
# seed command that was run without writing `seed.json` are refused by `decide` and forbidden by
# the command, and nothing here detects them afterwards.
# What the audit cannot see: a value changed and changed back before the audit; a baseline.json
# and journey.json rewritten together to agree (or a new baseline taken with `start --restart`
# after a change; the new journey then says `replacedFrom`); a plan row without a string id; two
# numbers that differ only beyond the precision of a double; a `QA_AUTO_TEST=1` set in the
# journey's own environment together with a tracker command, a plan check command or a clock
# (`QA_AUTO_TRACKER_CMD`, `QA_AUTO_VERIFY_PLAN_CMD`, `QA_AUTO_NOW`: all are read from the
# environment, so whoever controls it controls those answers); a tracker.sh or verify-plan.sh
# replaced on disk.
#
# NUMBERS: both engines must print and compare a number alike. A number is plain when it is finite
# and either whole with at most 15 digits before the point, or not whole and at least 0.0001 in
# size; plain numbers are compared as IEEE doubles (0.2 and 0.2000000000000000001 are one number).
# Any other number (1e16, an integer above 10^15, 1e-7) is never compared: `start` refuses a safety
# setting, an exclusion or a person-confirmed expected value that holds one, and the audit reports
# a value that holds one as changed.
#
# HANDOFF: `handoff` writes auto/handoff.md, the plain list a person reads at the end: the result,
# the scope chosen, what was decided without a person, what still needs a person, the records the
# run created (`--records <file>`: the output of the engine's `data-policy.sh list`, passed in by
# the command) and how to confirm. It prints {"result":…,"needsPerson":n}; `needsPerson` is the
# number of items listed under "Needs a person" (see THE TWO `needsPerson` NUMBERS). The result is
# one of ready, not confirmed, not ready, verified, not verified, stopped; it is worked out from
# files only and is never better than what the engine recorded (the exact rule is above
# cmd_handoff). A verifier override on the run (a pass that verification did not leave a pass) is
# `not verified`, never `ready`, whatever the report says. Without an audit record that passed and is not older than the last change to the
# journey's steps the Result section says `The audit has not run for this journey.` and the result
# is `not verified` (a stopped journey stays `stopped`, with the same sentence). The Result
# sentence carries the count whenever items wait for a person (`Verified. 3 items need a person.`).
# It may run on any journey and more than once; it changes no other file and never the state of
# the journey.
#
# STEP ORDER AND LIMITS: `next` names the first step that is not done; `step-start` and `step-done`
# take only that step. The time limit and `--until` hold for all three: `next`, `step-start` and
# `step-done` stop the journey (`until`, or `time-limit`) when the step comes after the `--until`
# step or the deadline has passed, and print the stop line; the two step verbs then end with
# exit 1. One allowance: `step-done` for a step that is `running` (it was started before the
# deadline) is still recorded after the deadline, because the work is done; the journey then
# stops at the next `next` or `step-start`. `step-done` looks for the step's result on disk and
# never takes the caller's word: analyze reads the ONE machine-readable line /qa-analyze writes
# under `## Verdict` (`Verdict: BLOCKED` or `Verdict: PASS (advisory)`; anything else is no result);
# run wants a run-manifest.json and a checkpoint.json that parse, a report.md that is not empty
# (one with only blanks is empty), a manifest whose `status` is text and is not `in-progress` (a
# status that is missing, null, blank or not text is refused: `that run has no status`), at least
# one checkpoint row for a row of this spec's checklist.json, and a start inside this journey;
# verify wants a verification.json that parses and holds rows (a list of objects, at the top level
# or under `rows` or `criteria`, at least one: `null`, `[]` and `{}` are not a result), and then
# runs qa-kit's own verify-plan.sh for the recorded run, plain and `--drift`, and refuses when
# either does not exit 0 (`the plan check did not pass for this run`, `the plan drift check did
# not pass for this run`): the script decides, not the caller. `QA_AUTO_VERIFY_PLAN_CMD` replaces
# that command only when `QA_AUTO_TEST=1` is set too (the suites). A step's `attempts` counts its `step-start` calls, so a second `step-start` on a running
# step is a redo.
#
# EXIT CODES: 0 ok; 1 refused or failed (one line on stderr, `auto: <reason>`; for a step verb
# stopped by a limit, the stop line on stdout); 2 usage.
#
# CLOCK: "now" is the system clock. `QA_AUTO_NOW` (ISO-8601 UTC, `YYYY-MM-DDTHH:MM:SSZ`) replaces it
# only when `QA_AUTO_TEST=1` is set too (the suites); without that the variable is ignored.
# Timestamps are always written in that one format, so two of them compare as strings.
#
# DEPENDENCIES: bash (3.2 safe), coreutils, EITHER jq OR python3 (jq preferred; `QA_ENGINE=jq|python3`
# overrides). Both engines give byte-identical files and output. No node/perl/grep -P. The python3
# side is auto_helpers.py, beside this script (one python process per engine call).
#
# ENGINE CALLS PER VERB (each is one jq or one python3 process): status 1; stop 1; next 1;
# step-start 1; step-done 1 (run 3: the journey, the run's files, the change; verify 3, and
# verify-plan.sh twice);
# signin 1 (2 when it stops the journey); decide, note, second 1 (`second --unavailable` 2);
# audit 2 (one more when the tracker answers in JSON); handoff 2; start 3 (4 when the target already
# has a journey; one more per other target that has one); resume 3 (plus one per other target).
# The jq engine cannot hash, so with a plan `start` and `audit` run one more jq to list the
# person-confirmed rows, and `sha256sum` once per such row.
#
# ADDING A VERB: write `cmd_<verb>`, add it to the dispatch `case` at the bottom, and reuse the
# helpers below (parse_common, journey_load, journey_read, journey_read_open, journey_fs,
# journey_gate, journey_require_open_strict, journey_apply, journey_step, stop_journey,
# rows_commit, atomic_write, real_folders, one_of, text_given, json_valid, json_strs, file_state,
# now_iso, hours_json, iso_epoch, time_epoch, step_artifact_done, step_state, signin_from,
# read_lines, plan_hashes, hash_or). Register every option a verb takes in VALUE_FLAGS or
# SWITCH_FLAGS: parse_common refuses any other `--word`. Keep the engine calls of a verb few: a
# verb that changes the journey should read, judge and write it in ONE call (journey_apply's
# `require`, or a program of its own like JQ_STEP). Every jq program has a python twin in
# auto_helpers.py, kept line for line alike. A new audit check goes into BOTH JQ_AUDIT and
# op_audit, or, when it needs no JSON, into audit_steps with `code <fixed word>`.
set -uo pipefail

# ---------------------------------------------------------------------------------------------
# Fixed values (plan decisions J1, J2, J6)
# ---------------------------------------------------------------------------------------------
STEPS="constitution spec scenarios analyze run verify"
RESUMABLE_REASONS="time-limit step-failed until"
FINAL_REASONS="blocked audit no-sign-in tracker"
SAFETY_KEYS="allowApiWrites seedableEnvMarker environment allowBlackboxCrawl gates profile humanInteraction.enforce humanInteraction.maxOptOutRate"
# The run-config's own top-level keys the audit watches: the top-level parent of every safety key,
# and the address.
RC_KEYS="allowApiWrites seedableEnvMarker environment allowBlackboxCrawl gates profile humanInteraction baseUrl"
DEFAULT_MAX_HOURS=6
ENVIRONMENTS="auto production disposable"
# Every option of every verb, in one place. parse_common refuses a `--word` that is in neither
# list, so an option that was not registered fails loudly instead of being read as the target.
VALUE_FLAGS="--profile --until --max-hours --reason --detail --run --step --class --question --answer --evidence --confidence --criteria --records --kind --text"
SWITCH_FLAGS="--restart --known-defects-invalid --unavailable"
# Plan decision J5: what a journey may answer for itself, and what it never decides.
DECIDABLE_CLASSES="roles surface-access scope role-overrides journeys inputs expected gaps"
FORBIDDEN_CLASSES="seed exclusion crawl-only oracle-human safety known-defect"
NOTE_KINDS="seed-not-run check-left-out"

# ---------------------------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------------------------
die()   { echo "auto: $*" >&2; exit 1; }
usage() {
  [ "$#" -gt 0 ] && echo "auto: $*" >&2
  cat >&2 <<'EOF'
usage: auto.sh start  <target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart] [--known-defects-invalid] [--project <dir>]
       auto.sh resume <target> [--max-hours <n>] [--known-defects-invalid] [--project <dir>]
       auto.sh stop   <target> --reason time-limit|step-failed|until|blocked|audit|no-sign-in|tracker --detail <text> [--project <dir>]
       auto.sh status <target> [--project <dir>]
       auto.sh next   <target> [--project <dir>]
       auto.sh step-start <target> <step> [--project <dir>]
       auto.sh step-done  <target> <step> [--run <run-id>] [--project <dir>]
       auto.sh signin <target> [--project <dir>]
       auto.sh decide <target> --step <step> --class <class> --question <text> --answer <text> --evidence <text|none> --confidence high|low [--criteria id,id] [--project <dir>]
       auto.sh second <target> <decision-id> stands|ask --reason <text> [--project <dir>]
       auto.sh second <target> --unavailable [--project <dir>]
       auto.sh note   <target> --kind seed-not-run|check-left-out --text <text> [--project <dir>]
       auto.sh audit  <target> [--project <dir>]
       auto.sh handoff <target> [--records <file>] [--project <dir>]
EOF
  exit 2
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# one_of <word> "<space list>" — in_list for a word that came from outside: one word, no blanks.
one_of() { case "$1" in ""|*[[:space:]]*) return 1 ;; esac; in_list "$1" "$2"; }
# text_given <text> — true when the text has something other than blanks in it.
text_given() { case "$1" in *[![:space:]]*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------------------------
# Engine selection
# ---------------------------------------------------------------------------------------------
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }
ENGINE=""
if has_jq; then ENGINE=jq; elif has_py; then ENGINE=python3; fi
need_engine() { [ -n "$ENGINE" ] || die "this script needs either jq or python3"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The python3 side of every engine call is auto_helpers.py, beside this script: one process per
# call, started on a file (starting python on a long `-c` program is several times slower). Its
# output is always UTF-8, keys sorted, so it matches `jq -S` byte for byte. -B: python writes no
# cache beside the script.
py() { PYTHONUTF8=1 python3 -B "$SCRIPT_DIR/auto_helpers.py" "$@"; }
# NUMBERS. The jq side normalises numbers as the python side does (0.20 → 0.2, 1.0 → 1). A number
# is PLAIN when it is finite and either whole with at most 15 digits before the point, or not
# whole and at least 0.0001 in size: both engines print and compare such a number alike (as an
# IEEE double, so 0.2 and 0.2000000000000000001 are one number). Any other number (1e16, an
# integer above 10^15, 1e-7) is ODD and is never compared: `start` refuses a safety setting, an
# exclusion or a person-confirmed expected value that holds one, and the audit reports a value
# that holds one as changed. `eq` is equality after `norm`; `sorted` orders every object's keys.
JQ_DEFS='def norm: walk(if type == "number" then . + 0 else . end);
  def plain: (. + 0) as $v | if ($v | isnan) or ($v | isinfinite) then false
    elif $v == ($v | floor) then ($v | fabs) <= 1000000000000000 else ($v | fabs) >= 0.0001 end;
  def odd: any(.. | numbers; plain | not);
  def eq($a; $b): ($a | norm) == ($b | norm);
  def sorted: walk(if type == "object" then (to_entries | sort_by(.key) | from_entries) else . end);'
JQ_ONE='if length != 1 then error("not one JSON document") else .[0] end'
# rd($state; $text; $empty_ok) — {ok, v}: the one JSON document in the text of a file read with
# --rawfile. $state is "1" (a file), "0" (absent) or "!" (there, not a readable file). One leading
# byte order mark is dropped. An empty file is not a document, unless $empty_ok (then it is []).
JQ_RD='def rd($state; $text; $empty_ok):
    ($text | ltrimstr("\ufeff")) as $t
    | if $state != "1" then {ok: false, v: null}
      elif ($t | test("\\A[ \t\r\n]*\\z")) then (if $empty_ok then {ok: true, v: []} else {ok: false, v: null} end)
      else (try {ok: true, v: ($t | fromjson)} catch {ok: false, v: null}) end;
  def look($d; $p): ($p | split(".")) as $k
    | if (try ($d | getpath($k[:-1]) | (type == "object" and has($k[-1]))) catch false)
      then {found: true, v: ($d | getpath($k))} else {found: false, v: null} end;
  def merged($c; $r): (if ($c | type) == "object" then $c else {} end) + $r;'
# has_rows — true for a verification.json that holds a result: the rows the handoff reads (the
# document itself when it is a list, else the list under `rows` or `criteria`), at least one, every
# one an object. `null`, `[]`, `{}` and an object without such a list are not a result. (The python
# side is has_rows in auto_helpers.py.)
JQ_VRES='def has_rows: (if type == "array" then . elif type == "object" then (first((.rows, .criteria) | select(type == "array")) // null) else null end)
    | (type == "array" and length > 0 and all(.[]; type == "object"));'
# The array of a rows file read with `jq -s` (nothing at all, no file yet, is an empty array), and
# the next free id with a one-letter prefix.
JQ_ROWS='def rows_in: (if length == 0 then [] elif length == 1 then .[0] else error("not one JSON document") end)
    | if type == "array" then . else error("not an array") end;
  def next_id($p): $p + (([ .[] | objects | .id | strings | select(test("\\A" + $p + "[0-9]+\\z")) | .[1:] | tonumber ] | (max // 0) + 1) | tostring);'
# JQ_NEEDS — a decision a person still has to look at: marked `needsPerson`, sent on by the second
# look, or made at low confidence with no second look that let it stand. `status` and `handoff`
# both use this one rule (the python side is needs_person in auto_helpers.py).
JQ_NEEDS='def needs_person: .needsPerson == true or .second == "ask" or (.confidence == "low" and .second != "stands");'

# ---------------------------------------------------------------------------------------------
# JSON helpers (both engines; reuse these in new verbs)
# ---------------------------------------------------------------------------------------------
# json_valid <file> — exit 0 when the file parses as one JSON document.
json_valid() {
  if [ "$ENGINE" = jq ]; then jq -es 'length == 1' "$1" >/dev/null 2>&1; else py valid "$1" >/dev/null 2>&1; fi
}
# json_strs <file> <dot.path>… — one line per path: the string there, or an empty line when it is
# absent or not a string (line breaks inside a value become spaces). Fails when the file is not
# one JSON document, so it doubles as the validity check. Read it with `read_lines`.
json_strs() {
  local f="$1"; shift
  if [ "$ENGINE" = jq ]; then
    jq -rs "$JQ_ONE"' | . as $d | $ARGS.positional[] | . as $p
      | (try ($d | getpath($p | split("."))) catch null)
      | if type == "string" then gsub("[\r\n]"; " ") else "" end' --args "$@" < "$f" 2>/dev/null
  else py strs "$f" "$@" 2>/dev/null; fi
}
# verification_ok <file> — exit 0 when the file is one JSON document that holds a verification
# result (has_rows). One engine call.
verification_ok() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  if [ "$ENGINE" = jq ]; then jq -en --rawfile vt "$1" "$JQ_RD $JQ_VRES"' rd("1"; $vt; false) | .ok and (.v | has_rows)' >/dev/null 2>&1
  else py verified "$1" >/dev/null 2>&1; fi
}
# file_state <path> — sets FS_STATE (`1` a file, `0` nothing there, `!` there but not a file that
# can be read, such as a link that leads nowhere) and FS_PATH (the path, or /dev/null).
FS_STATE=0; FS_PATH=/dev/null
file_state() {
  if [ -f "$1" ] && [ -r "$1" ]; then FS_STATE=1; FS_PATH="$1"
  elif [ -e "$1" ] || [ -L "$1" ]; then FS_STATE="!"; FS_PATH=/dev/null
  else FS_STATE=0; FS_PATH=/dev/null; fi
}
# real_folders — die when the spec folder, the journey folder or its history folder is a link: the
# script writes only under `.qa/specs/<target>/auto/`, and through a link that would be somewhere
# else (`start` moves the earlier journey into `auto/history/`).
real_folders() {
  if [ -L "$SPEC_DIR" ] || [ -L "$AUTO_DIR" ] || [ -L "$AUTO_DIR/history" ]; then die "the journey folder must be a real folder"; fi
}
# atomic_write <file> <text> — THE writer: every file this script writes goes through here. The
# text plus a final line break goes to a temporary name beside the file, which is then moved into
# place. Refuses any path outside the journey directory, and a journey directory (or spec
# directory) that is a link. On any failure, a destination that is a directory included, it
# removes the temporary file and ends the script with exit 1 and the one line
# `auto: could not write <path>` (the shell's own complaint is not shown). ALWAYS call it, and
# every function that calls it, as a plain command: at the end of a pipeline or inside `$(…)` its
# exit would only end a subshell and the verb would carry on as if the write had worked.
atomic_write() {
  local dest="$1" tmp="$1.tmp.$$" rel="${1#"$PROJECT"/}"
  case "$dest" in "$AUTO_DIR"/*) ;; *) die "internal: refused to write outside the journey directory" ;; esac
  real_folders
  [ -n "$2" ] || die "could not write $rel"
  # a directory at the file's path would swallow the move and look like a write that worked
  [ ! -d "$dest" ] || die "could not write $rel"
  if ! { printf '%s\n' "$2" > "$tmp"; } 2>/dev/null; then rm -f "$tmp" 2>/dev/null; die "could not write $rel"; fi
  if ! mv -f "$tmp" "$dest" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; die "could not write $rel"; fi
}
# JQ_PLAN — jq side of the plan readers. `plan_rows` is the rows of a plan that have a string id;
# `human_rows` those whose fixture.expect.oracleSource is "human" (of two with one id, the first),
# `human_ids` their sorted ids; `row_ids` all ids.
JQ_PLAN='def plan_rows: [ (if type == "array" then .[] else empty end) | select(type == "object" and (.id | type) == "string") ];
  def human_rows: [ .[] | select((.fixture | type) == "object" and (.fixture.expect | type) == "object"
                                 and .fixture.expect.oracleSource == "human") ]
                  | to_entries | group_by(.value.id) | map(min_by(.key) | .value);
  def human_ids: human_rows | map(.id);
  def row_ids: [ .[] | .id ] | unique;'
# sha256_text <text> — hex SHA-256 of the text's bytes (no line break added).
sha256_text() {
  local out=""
  if command -v sha256sum >/dev/null 2>&1; then out="$(printf '%s' "$1" | sha256sum 2>/dev/null)"
  elif command -v shasum >/dev/null 2>&1; then out="$(printf '%s' "$1" | shasum -a 256 2>/dev/null)"
  elif command -v openssl >/dev/null 2>&1; then out="$(printf '%s' "$1" | openssl dgst -sha256 -r 2>/dev/null)"
  elif has_py; then out="$(printf '%s' "$1" | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  fi
  out="${out%% *}"
  [ "${#out}" -eq 64 ] || return 1
  printf '%s\n' "$out"
}
# plan_hashes <checklist.json> — the jq engine's way to the hashes of the person-confirmed rows
# (jq cannot hash; the python side works them out inside its own call). One compact JSON object,
# {"<row id>": "<SHA-256>"}: for every person-confirmed row, the hash of its `fixture.expect` in
# canonical form (keys sorted, compact, numbers normalised: the bytes `jq -cS` and the python side
# both print). `{}` for a plan that is not a list. Fails when the plan is not readable. Row ids
# travel as the JSON string literals the engine printed; they are never read by the shell.
plan_hashes() {
  local out idj ex h acc=""
  out="$(jq -cSs "$JQ_DEFS $JQ_PLAN $JQ_ONE"' | plan_rows | human_rows[] | .id, (.fixture.expect | norm)' < "$1" 2>/dev/null)" || return 1
  while IFS= read -r idj && IFS= read -r ex; do
    h="$(sha256_text "$ex")" || return 1
    acc="$acc,$idj:\"$h\""
  done <<EOT
$out
EOT
  printf '{%s}\n' "${acc#,}"
}

# ---------------------------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------------------------
# now_iso — "now", `YYYY-MM-DDTHH:MM:SSZ`: the system clock. `QA_AUTO_NOW` replaces it only when
# `QA_AUTO_TEST=1` is set too (the suites set both); in a real journey the variable is ignored, so
# it cannot move the deadline.
now_iso() {
  if [ "${QA_AUTO_TEST:-}" = 1 ] && [ -n "${QA_AUTO_NOW:-}" ]; then
    case "$QA_AUTO_NOW" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s\n' "$QA_AUTO_NOW" ;;
      *) die "QA_AUTO_NOW must look like 2026-11-27T08:00:00Z" ;;
    esac
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}
# valid_hours <text> — a whole or decimal number between 0.1 and 72, both included. Worked out on
# the digits, so no engine is needed and no rounding can move the edge.
valid_hours() {
  local i f=""
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  i="${1%%.*}"
  case "$1" in *.*) f="${1#*.}" ;; esac
  while [ "${#i}" -gt 1 ] && [ "${i:0:1}" = 0 ]; do i="${i:1}"; done
  [ "${#i}" -le 2 ] || return 1
  if [ "$i" -eq 0 ]; then
    case "$f" in [1-9]*) return 0 ;; *) return 1 ;; esac
  fi
  [ "$i" -lt 72 ] && return 0
  [ "$i" -eq 72 ] || return 1
  case "$f" in *[1-9]*) return 1 ;; *) return 0 ;; esac
}
# hours_json <valid hours> — the hours as a JSON number (no leading or trailing zeros).
hours_json() {
  local i="${1%%.*}" f=""
  case "$1" in *.*) f="${1#*.}" ;; esac
  while [ "${#i}" -gt 1 ] && [ "${i:0:1}" = 0 ]; do i="${i:1}"; done
  while [ -n "$f" ] && [ "${f%0}" != "$f" ]; do f="${f%0}"; done
  if [ -n "$f" ]; then printf '%s.%s\n' "$i" "$f"; else printf '%s\n' "$i"; fi
}
HOURS_RULE="--max-hours must be between 0.1 and 72"

# ---------------------------------------------------------------------------------------------
# Paths and arguments
# ---------------------------------------------------------------------------------------------
PROJECT="."; TARGET=""
QA_DIR=""; CONFIG=""; SPEC_DIR=""; AUTO_DIR=""; JOURNEY=""; BASELINE=""; DECISIONS=""; NOTES=""
REST=()

# parse_common "$@" — takes the target (first bare word) and `--project <dir>` out of a verb's
# arguments, sets the path variables, and leaves everything else, in order, in REST. Every verb
# calls it first, so the rules here hold for all of them: an option that is not registered
# (VALUE_FLAGS, SWITCH_FLAGS) is a usage error and never the target, and the target must be a
# plain name.
parse_common() {
  REST=()
  local seen_target=0 expect_value=0
  while [ "$#" -gt 0 ]; do
    if [ "$expect_value" -eq 1 ]; then REST+=("$1"); expect_value=0; shift; continue; fi
    case "$1" in
      --project) [ "$#" -ge 2 ] || usage "--project needs a directory"; PROJECT="$2"; shift 2 ;;
      --*) if flag_takes_value "$1"; then expect_value=1
           elif ! one_of "$1" "$SWITCH_FLAGS"; then usage "$VERB does not take: $1"; fi
           REST+=("$1"); shift ;;
      *) if [ "$seen_target" -eq 0 ]; then TARGET="$1"; seen_target=1; else REST+=("$1"); fi; shift ;;
    esac
  done
  [ "$seen_target" -eq 1 ] || usage "a target is needed"
  plain_name "$TARGET" || usage "the target must be a plain name"
  [ -d "$PROJECT" ] || die "no such project directory: $PROJECT"
  PROJECT="${PROJECT%/}"; [ -n "$PROJECT" ] || PROJECT="/"
  # A relative directory that starts with a dash would be read as an option by every tool below.
  case "$PROJECT" in -*) PROJECT="./$PROJECT" ;; esac
  QA_DIR="$PROJECT/.qa"
  CONFIG="$QA_DIR/config.json"
  SPEC_DIR="$QA_DIR/specs/$TARGET"
  AUTO_DIR="$SPEC_DIR/auto"
  JOURNEY="$AUTO_DIR/journey.json"
  BASELINE="$AUTO_DIR/baseline.json"
  DECISIONS="$AUTO_DIR/decisions.json"
  NOTES="$AUTO_DIR/notes.json"
}
# flag_takes_value <flag> — true for the options whose next word is their value (so that word is
# never mistaken for the target): the ones registered in VALUE_FLAGS.
flag_takes_value() { one_of "$1" "$VALUE_FLAGS"; }
# plain_name <text> — true for a name that is safe as one directory under .qa/specs/: it starts
# with a letter or a digit, holds only letters, digits, `.`, `_` and `-` (ASCII), and no `..`.
# The characters are listed one by one: a range such as A-Z means other letters in some locales.
NAME_FIRST='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
plain_name() {
  case "$1" in
    ""|*..*|*[!${NAME_FIRST}._-]*) return 1 ;;
    [${NAME_FIRST}]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Journey helpers
# ---------------------------------------------------------------------------------------------
# read_lines <text> <var>… — assign the text's lines, in order, to the named variables.
read_lines() {
  local text="$1" v; shift
  {
    for v in "$@"; do IFS= read -r "$v" || true; done
  } <<EOT
$text
EOT
}
# TARGET_JSON — the target as a JSON string literal (gate_config works it out).
TARGET_JSON=""
# journey_load — reads the journey once into J_STATE (`open`, `done`, `stopped`, or empty when
# there is no readable journey), J_REASON (the stop reason, or empty) and J_PROFILE (the launch
# profile, or empty).
J_STATE=""; J_REASON=""; J_PROFILE=""
journey_load() {
  J_STATE=""; J_REASON=""; J_PROFILE=""
  [ -f "$JOURNEY" ] || return 0
  read_lines "$(json_strs "$JOURNEY" state stop.reason profile)" J_STATE J_REASON J_PROFILE
}
# journey_require_open_strict — the same, telling "no journey at all" from "not open".
journey_require_open_strict() {
  journey_load
  [ -n "$J_STATE" ] || die "no journey for $TARGET"
  [ "$J_STATE" = open ] || die "no open journey for $TARGET"
}
# rows_commit <file> <engine output> — an engine op that changes a rows file (decisions.json,
# notes.json) prints one result line and then the whole array, pretty-printed. This keeps the
# result line in ROWS_LINE and replaces the file atomically with the array. Output that is only
# a result line (a refusal such as `!missing`) writes nothing. A plain command only (see
# atomic_write); print ROWS_LINE after it has returned, never before.
ROWS_LINE=""
rows_commit() {
  local dest="$1" out="$2" nl=$'\n'
  case "$dest" in "$AUTO_DIR"/*) ;; *) die "internal: refused to write outside the journey directory" ;; esac
  ROWS_LINE="${out%%"$nl"*}"
  case "$out" in *"$nl"*) ;; *) return 0 ;; esac
  atomic_write "$dest" "${out#*"$nl"}"
}
# rows_source <file> — the file to read a rows file from: itself, or /dev/null when it is not there yet.
rows_source() { if [ -f "$1" ]; then printf '%s\n' "$1"; else printf '/dev/null\n'; fi; }
# run_facts <run id> — what `step-done run` needs from a run, in one engine call. Sets R_MANIFEST
# and R_CHECKPOINT (`ok` when the file parses as JSON, else `bad`), R_STATUS (`=` and the manifest's
# `status` in small letters when it is text; empty when it is missing, null or anything else), R_STARTED (its `started_at`), R_ROWS (1 when a checkpoint row is
# about a row of this spec's plan, else 0) and R_TIMES (every `checkpointed_at`, one per line).
# A checkpoint is a list of rows or an object holding one under `criteria`; a row names its check
# in `criterion_id`, `criterionId` or `id`.
JQ_RUNFACTS='
  def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
  def cid: first((.criterion_id, .criterionId, .id) | select(type == "string" and length > 0)) // null;
  rd("1"; $mt; false) as $m | rd("1"; $kt; false) as $k | rd($ps; $pt; false) as $p
  | [ (if $k.ok then ($k.v | if type == "array" then .[] elif type == "object" and (.criteria | type) == "array" then .criteria[] else empty end) else empty end)
      | objects ] as $rows
  | (if $p.ok then ($p.v | plan_rows | row_ids) else [] end) as $ids
  | (if ($m.v | type) == "object" then $m.v else {} end) as $man
  | (if $m.ok then "ok" else "bad" end),
    ($man.status | if type == "string" then "=" + (ascii_downcase | s) else "" end), ($man.started_at | s),
    (if $k.ok then "ok" else "bad" end),
    (if any($rows[] | cid; . as $i | $i != null and any($ids[]; . == $i)) then "1" else "0" end),
    ($rows[] | .checkpointed_at | strings | gsub("[\r\n]"; " "))'
R_MANIFEST=bad; R_STATUS=""; R_STARTED=""; R_CHECKPOINT=bad; R_ROWS=0; R_TIMES=""
run_facts() {
  local dir="$QA_DIR/runs/$1" out="" i
  R_MANIFEST=bad; R_STATUS=""; R_STARTED=""; R_CHECKPOINT=bad; R_ROWS=0; R_TIMES=""
  file_state "$SPEC_DIR/checklist.json"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rn --rawfile mt "$dir/run-manifest.json" --rawfile kt "$dir/checkpoint.json" --rawfile pt "$FS_PATH" --arg ps "$FS_STATE" "$JQ_RD $JQ_PLAN $JQ_RUNFACTS" 2>/dev/null)" || return 1
  else
    out="$(py runfacts "$dir/run-manifest.json" "$dir/checkpoint.json" "$FS_STATE" "$FS_PATH" 2>/dev/null)" || return 1
  fi
  read_lines "$out" R_MANIFEST R_STATUS R_STARTED R_CHECKPOINT R_ROWS
  for i in 1 2 3 4 5; do
    case "$out" in *"$NL"*) out="${out#*"$NL"}" ;; *) out="" ;; esac
  done
  R_TIMES="$out"
}
# run_start_epoch — after run_facts: seconds since 1970 of the run's start: the manifest's
# `started_at` when it names its zone, else the earliest `checkpointed_at` of the run's
# checkpoint.json (the engine writes those in UTC with `Z`). Fails when neither is readable.
run_start_epoch() {
  local e line min=""
  if e="$(time_epoch "$R_STARTED")"; then printf '%s\n' "$e"; return 0; fi
  while IFS= read -r line; do
    e="$(time_epoch "$line")" || continue
    if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min="$e"; fi
  done <<EOT
$R_TIMES
EOT
  [ -n "$min" ] || return 1
  printf '%s\n' "$min"
}
# journey_file_state <journey.json> — prints `open`, `done` or `stopped`; `none` when nothing is
# at that path; `unreadable` for anything else (not a file, no permission, not one JSON object,
# a state that is not one of the three).
journey_file_state() {
  local st=""
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then echo none; return 0; fi
  [ -f "$1" ] && [ -r "$1" ] && st="$(json_strs "$1" state)"
  case "$st" in open|done|stopped) printf '%s\n' "$st" ;; *) echo unreadable ;; esac
}
# lock_check — the "one journey per project" lock, failing closed. Dies when the journey of ANY
# target in this project (this one included) cannot be read: its journey.json is there and is not
# a readable journey, or its spec folder or journey folder cannot be looked into (no read or no
# search permission), so a journey in it could not be seen. Dies when another target's journey is
# open. Folders whose name starts with a dot are looked at too.
lock_check() {
  local d t st own="${1:-}"
  [ "$own" = own-loaded ] || { J_STATE=""; J_REASON=""; J_PROFILE=""; }
  for d in "$QA_DIR"/specs/*/ "$QA_DIR"/specs/.[!.]*/ "$QA_DIR"/specs/..?*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; t="${d##*/}"
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then die "the journey for $t cannot be read"; fi
    if [ -d "$d/auto" ] && { [ ! -r "$d/auto" ] || [ ! -x "$d/auto" ]; }; then die "the journey for $t cannot be read"; fi
    if [ "$t" = "$TARGET" ]; then
      # this target's journey is read once, here, into J_STATE, J_REASON and J_PROFILE
      [ "$own" = own-loaded ] || journey_load
      st="$J_STATE"
      case "$st" in
        open|done|stopped) ;;
        *) if [ -e "$JOURNEY" ] || [ -L "$JOURNEY" ]; then st=unreadable; else st=none; fi ;;
      esac
    else
      st="$(journey_file_state "$d/auto/journey.json")"
    fi
    [ "$st" = none ] && continue
    [ "$st" != unreadable ] || die "the journey for $t cannot be read"
    [ "$t" = "$TARGET" ] && continue
    [ "$st" != open ] || die "another journey is open for $t"
  done
  return 0
}
# print_status — the line of the `status` verb: journey.json plus {"needsPerson": n}, where n is
# the number of DECISIONS that need a person (JQ_NEEDS). Writes nothing. One engine call. A file
# that is not a journey (no state) is `no journey`; decisions that cannot be read are a refusal. (The verbs that change the journey print the same line from journey_apply,
# with 0 for decisions that cannot be read, so a journey can always be stopped.)
JQ_STATUS='
  (rd("1"; $jt; false) | if .ok and (.v | type) == "object" and (.v.state | type) == "string" and .v.state != "" then .v else error("not a journey") end) as $j
  | (if $ds == "0" then 0
     else (rd($ds; $dt; true) | if .ok and (.v | type) == "array" then ([ .v[] | objects | select(needs_person) ] | length) else null end) end) as $n
  | if $n == null then "!decisions" else ($j + {needsPerson: $n} | norm | sorted | tojson) end'
print_status() {
  local out
  file_state "$DECISIONS"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rn --rawfile jt "$JOURNEY" --rawfile dt "$FS_PATH" --arg ds "$FS_STATE" "$JQ_DEFS $JQ_RD $JQ_NEEDS $JQ_STATUS" 2>/dev/null)" || out=""
  else
    out="$(py status "$JOURNEY" "$FS_STATE" "$FS_PATH" 2>/dev/null)" || out=""
  fi
  [ "$out" != "!decisions" ] || die "decisions.json for $TARGET is not readable"
  [ -n "$out" ] || die "no journey for $TARGET"
  printf '%s\n' "$out"
}
# journey_read — what the verbs that look at a run need from the journey, in one engine call:
# J_STATE, J_RUN (the recorded run id), J_STARTED (when the journey started) and J_STEPS
# (`name:state:attempts` words in journey order; read them with step_state). All empty when there
# is no readable journey. Line breaks inside a value become spaces.
J_RUN=""; J_STARTED=""; J_STEPS=""
journey_read() {
  local out=""
  J_STATE=""; J_RUN=""; J_STARTED=""; J_STEPS=""
  [ -f "$JOURNEY" ] || return 0
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rs 'def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
      def n: if type == "number" then floor else 0 end;
      '"$JQ_ONE"' | if type != "object" then error("not an object") else . end
      | (.state | s), (.runId | s), (.startedAt | s),
        ([ (.steps | if type == "array" then .[] else empty end) | select(type == "object")
           | "\(.name | s):\(.state | s):\(.attempts | n)" ] | join(" "))' < "$JOURNEY" 2>/dev/null)" || return 0
  else
    out="$(py journey "$JOURNEY" 2>/dev/null)" || return 0
  fi
  read_lines "$out" J_STATE J_RUN J_STARTED J_STEPS
}
# journey_read_open — journey_read, then die unless the journey is open.
journey_read_open() {
  journey_read
  [ "$J_STATE" = open ] || die "no open journey for $TARGET"
  [ -n "$J_STEPS" ] || die "journey.json for $TARGET is not readable"
}
# step_state <step> — the step's state as journey_read saw it (empty when the step is not there).
step_state() {
  local w r
  for w in $J_STEPS; do
    if [ "${w%%:*}" = "$1" ]; then r="${w#*:}"; printf '%s\n' "${r%%:*}"; return 0; fi
  done
  return 0
}
# JQ_CHANGE — the jq side of the journey's own logic (the python side is change, limit, step_state
# and first_open in auto_helpers.py). `change` applies a change (see journey_apply); `limit` gives
# the journey stopped for `--until` or the time limit, or null; `step_state` and `first_open` read
# the steps as `next` does.
JQ_CHANGE='
  def text($v): $v | if type == "string" then gsub("[\r\n]"; " ") else "" end;
  def change($p; $text; $mode):
    . + ($p.set // {})
    | (if $p.stop then .stop = {reason: $p.stop, detail: $text} else . end)
    | (if $p.runId then .runId = $text else . end)
    | (if ($p | has("steps")) or $mode == "new" then
         (if (.steps | type) == "array" then . else error("not a journey") end)
         | .steps |= map(. as $x | (if type == "object" then ($p.steps // {})[$x.name // ""] else null end) as $u
             | if $u then (if $u.state then .state = $u.state else . end)
                          | (if $u.bump then .attempts = ((.attempts // 0) + 1) else . end)
               else . end)
       else . end)
    | reduce (($p.append // {}) | to_entries[]) as $e (.; .[$e.key] = ((.[$e.key] | if type == "array" then . else [] end) + [$e.value]))
    | norm;
  def stopline: {detail: .stop.detail, next: "stopped", reason: .stop.reason} | norm | sorted | tojson;
  def status_line($ds; $dt): . as $j
    | (rd($ds; $dt; true) | if .ok and (.v | type) == "array" then ([ .v[] | objects | select(needs_person) ] | length) else 0 end) as $n
    | ($j + {needsPerson: $n} | sorted | tojson);
  def journey_of($t): rd("1"; $t; false) | if .ok and (.v | type) == "object" then .v else null end;
  def has_steps($j): ([ ($j.steps | if type == "array" then .[] else empty end) | objects ] | length) > 0;
  def step_state($j; $n): first(($j.steps | if type == "array" then .[] else empty end) | objects | select(text(.name) == $n) | text(.state)) // "";
  def first_open($j; $order): first($order[] | . as $n | select(step_state($j; $n) != "done")) // "";
  # the asked-for stop comes before the time limit: the asked-for work is complete
  def limit($j; $order; $step; $now; $late):
    text($j.until) as $until | text($j.deadline) as $deadline
    | ($order | index($step)) as $i | ($order | index($until)) as $u
    | if $u != null and $i > $u
      then $j + {state: "stopped", endedAt: $now, stop: {reason: "until", detail: ("stopped after " + $until + ", as asked")}} | norm
      elif $late and $now > $deadline
      then $j + {state: "stopped", endedAt: $now, stop: {reason: "time-limit", detail: ("the deadline " + $deadline + " has passed")}} | norm
      else null end;'
# journey_apply <change> [new|old] [text] — the general way journey.json changes: one engine call
# that applies the change, and prints one result line and then the whole journey, which is written
# back atomically. The change is JSON:
#   {"require": "open",                 refuse (`no open journey`) unless the journey is in that state
#    "set": {<top-level keys>},
#    "stop": "<reason>",                set `stop` to that reason with <text> as its detail
#    "runId": true,                     set `runId` to <text>
#    "steps": {"<name>": {"state": "<state>", "bump": true}},
#    "append": {"<key>": <item to add to that list>},
#    "print": "stop"}                   the result line is the `next` line of the stop
# Every part is optional; `bump` adds one to the step's attempts. Free text (a stop detail, a run
# id) travels as <text>, an argument, never inside the JSON. With `new` (the `start` verb) there
# is no journey yet and `set` is the whole of it. The result line, by default the status line
# (the journey plus needsPerson), is left in STATUS_LINE; print it after this has returned. A plain
# command only (see atomic_write).
JQ_APPLY='
  (if $mode == "new" then {} else journey_of($jt) end) as $j0
  | if $j0 == null then (if $p.require then "!notopen" else error("not a journey") end)
    elif $p.require and $j0.state != $p.require then "!notopen"
    else ($j0 | change($p; $text; $mode)) as $j
      | (if $p.print == "stop" then ($j | stopline) else ($j | status_line($ds; $dt)) end), $j
    end'
STATUS_LINE=""
journey_apply() {
  local out mode=old jf="$JOURNEY" keep="$ROWS_LINE"
  if [ "${2:-}" = new ]; then mode=new; jf=/dev/null; fi
  file_state "$DECISIONS"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rnS --rawfile jt "$jf" --arg mode "$mode" --argjson p "$1" --arg text "${3:-}" --rawfile dt "$FS_PATH" --arg ds "$FS_STATE" "$JQ_DEFS $JQ_RD $JQ_NEEDS $JQ_CHANGE $JQ_APPLY" 2>/dev/null)" || out=""
  else
    out="$(py apply "$jf" "$mode" "$1" "${3:-}" "$FS_STATE" "$FS_PATH" 2>/dev/null)" || out=""
  fi
  [ "$out" != "!notopen" ] || die "no open journey for $TARGET"
  [ -n "$out" ] || die "could not update ${JOURNEY#"$PROJECT"/}"
  # (rows_commit leaves the first line in ROWS_LINE; a verb that has its own result line there keeps it)
  rows_commit "$JOURNEY" "$out"
  STATUS_LINE="$ROWS_LINE"; ROWS_LINE="$keep"
}
# journey_step <start|done> <step> <now> <refusal> [blocked 1|0] [run id] — `step-start` and
# `step-done` as ONE engine call that reads the journey, judges it and writes it. In this order:
#   - the journey is open (`no open journey`) and its steps can be read;
#   - the step is not done yet and is the step `next` would name;
#   - THE LIMITS, which hold for every step verb and not only for `next`: a step that comes after
#     `--until` stops the journey (`until`); a step-start after the deadline, or a step-done for a
#     step that was never started, stops it (`time-limit`). The journey is written as stopped, the
#     `next` line of the stop is printed and the verb ends with exit 1. A step that is `running`
#     was started inside the time limit, so its step-done is still recorded after the deadline (the
#     work is done); the journey then stops at the next `next` or `step-start`;
#   - <refusal>: the line the shell found for the step's result (empty when the result is there);
#     it is printed here, after the checks above, so the order of refusals is one order;
#   - the change: `start` marks the step running and counts the attempt; `done` marks it done
#     (with <run id> as `runId`); `done` with `blocked` is a BLOCKED analysis: the first round
#     sends scenarios and analyze back to pending, the second stops the journey (`blocked`).
# Every change sets `stepsChangedAt`. STATUS_LINE is the status line. A plain command only.
JQ_STEP='
  journey_of($jt) as $j
  | ($order | split(" ")) as $order
  | if $j == null or $j.state != "open" then "!notopen"
    elif (has_steps($j) | not) then "!unreadable"
    elif step_state($j; $step) == "done" then "!done"
    elif first_open($j; $order) != $step then "!next " + first_open($j; $order)
    else
      limit($j; $order; $step; $now; ($kind == "start" or step_state($j; $step) != "running")) as $stopped
      | if $stopped != null then "!stopped " + ($stopped | stopline), $stopped
        elif $refuse != "" then "!refuse"
        elif $kind == "start" then
          ($j | change({set: {stepsChangedAt: $now}, steps: {($step): {state: "running", bump: true}}}; ""; "old")) as $n
          | ($n | status_line($ds; $dt)), $n
        elif $blocked == "1" then
          (($j.analyzeRounds | if type == "number" and . >= 0 then floor else 0 end) + 1) as $rounds
          | ($j | if $rounds >= 2
                  then change({set: {stepsChangedAt: $now, analyzeRounds: $rounds, state: "stopped", endedAt: $now,
                                     stop: {reason: "blocked", detail: "the analysis is still BLOCKED after \($rounds) rounds"}},
                               steps: {analyze: {state: "done"}}}; ""; "old")
                  else change({set: {stepsChangedAt: $now, analyzeRounds: $rounds},
                               steps: {scenarios: {state: "pending"}, analyze: {state: "pending"}}}; ""; "old") end) as $n
          | ($n | status_line($ds; $dt)), $n
        else
          ($j | change({set: {stepsChangedAt: $now}, runId: ($runid == "1"), steps: {($step): {state: "done"}}}; $text; "old")) as $n
          | ($n | status_line($ds; $dt)), $n
        end
    end'
journey_step() {
  local kind="$1" step="$2" now="$3" refuse="$4" blocked="${5:-0}" run="${6:-}" runid=0 out="" first keep="$ROWS_LINE"
  [ -n "$run" ] && runid=1
  [ -f "$JOURNEY" ] || die "no open journey for $TARGET"
  file_state "$DECISIONS"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rnS --rawfile jt "$JOURNEY" --rawfile dt "$FS_PATH" --arg ds "$FS_STATE" --arg kind "$kind" --arg step "$step" --arg order "$STEPS" \
      --arg now "$now" --arg refuse "$refuse" --arg blocked "$blocked" --arg runid "$runid" --arg text "$run" \
      "$JQ_DEFS $JQ_RD $JQ_NEEDS $JQ_CHANGE $JQ_STEP" 2>/dev/null)" || out=""
  else
    out="$(py step "$JOURNEY" "$FS_STATE" "$FS_PATH" "$kind" "$step" "$STEPS" "$now" "$refuse" "$blocked" "$runid" "$run" 2>/dev/null)" || out=""
  fi
  first="${out%%"$NL"*}"
  case "$first" in
    ""|"!notopen") die "no open journey for $TARGET" ;;
    "!unreadable") die "journey.json for $TARGET is not readable" ;;
    "!done")       die "$step is already done" ;;
    "!next "*)     die "$step is not the next step; next is ${first#!next }" ;;
    "!refuse")     die "$refuse" ;;
    "!stopped "*)  rows_commit "$JOURNEY" "$out"; printf '%s\n' "${first#!stopped }"; exit 1 ;;
  esac
  rows_commit "$JOURNEY" "$out"
  STATUS_LINE="$ROWS_LINE"; ROWS_LINE="$keep"
}
# JQ_NEXT — `next` as one engine call (the python side is op_next): the `next` line, then the
# journey when this call changed it (every step done: the journey becomes done; a limit reached:
# it becomes stopped). `!unreadable` alone for a journey that cannot be walked.
JQ_NEXT='
  journey_of($jt) as $j
  | ($order | split(" ")) as $order
  | if $j == null or text($j.state) == "" then error("no journey")
    elif $j.state == "stopped" then
      (if ($j.stop | type) == "object" and ($j.stop | has("detail")) and ($j.stop.reason | type) == "string" then ($j | stopline) else "!unreadable" end)
    elif $j.state == "done" then "{\"next\":\"done\"}"
    elif $j.state != "open" or (has_steps($j) | not) then "!unreadable"
    else
      first_open($j; $order) as $step
      | if $step == "" then "{\"next\":\"done\"}", ($j + {state: "done", endedAt: $now} | norm)
        else
          limit($j; $order; $step; $now; true) as $stopped
          | if $stopped != null then ($stopped | stopline), $stopped else "{\"next\":\"\($step)\"}" end
        end
    end'
# JQ_OPEN — open_or($js; $jt; f): f when the journey (state and text of journey.json) is open, else
# the marker `!nojourney` (no journey that can be read) or `!notopen`. journey_gate <engine output>
# turns a marker into the refusal; journey_fs sets J_FS and J_PATH for the engine call.
JQ_OPEN='def open_or($js; $jt; f):
    (rd($js; $jt; false) | if .ok and (.v | type) == "object" and (.v.state | type) == "string" then .v.state else "" end) as $s
    | if $s == "" then "!nojourney" elif $s != "open" then "!notopen" else f end;'
J_FS=0; J_PATH=/dev/null
journey_fs() { file_state "$JOURNEY"; J_FS="$FS_STATE"; J_PATH="$FS_PATH"; }
journey_gate() {
  case "$1" in
    "!nojourney") die "no journey for $TARGET" ;;
    "!notopen")   die "no open journey for $TARGET" ;;
  esac
}
# iso_epoch <YYYY-MM-DDTHH:MM:SS…> — seconds since 1970 of the first 19 characters read as UTC.
# Plain arithmetic, so both engines agree. Fails on a field out of range.
iso_epoch() {
  local y m d H M S era yoe doy doe
  y=$((10#${1:0:4})); m=$((10#${1:5:2})); d=$((10#${1:8:2}))
  H=$((10#${1:11:2})); M=$((10#${1:14:2})); S=$((10#${1:17:2}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] && [ "$H" -le 23 ] && [ "$M" -le 59 ] && [ "$S" -le 60 ] || return 1
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400)); yoe=$((y - era * 400))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s\n' $(( (era * 146097 + doe - 719468) * 86400 + H * 3600 + M * 60 + S ))
}
# time_epoch <text> — seconds since 1970 of a timestamp that names its zone:
# `YYYY-MM-DD(T| )HH:MM:SS[.fff](Z|±HH:MM|±HHMM)`. Fails on anything else (a time without a zone
# is not readable: it cannot be compared).
time_epoch() {
  local re='^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$'
  local t="$1" z e off=0
  [[ "$t" =~ $re ]] || return 1
  e="$(iso_epoch "$t")" || return 1
  case "$t" in
    *Z) ;;
    *)  z="${t:$((${#t} - 6))}"
        case "$z" in
          [+-][0-9][0-9]:[0-9][0-9]) z="${z:0:3}${z:4:2}" ;;
          *) z="${t:$((${#t} - 5))}" ;;
        esac
        off=$(( 10#${z:1:2} * 3600 + 10#${z:3:2} * 60 ))
        [ "${z:0:1}" = "-" ] && off=$(( -off )) ;;
  esac
  printf '%s\n' $((e - off))
}
# analysis_verdict <analysis.md> — `blocked`, `clear` or `none`, failing closed. /qa-analyze writes
# ONE machine-readable line as the first line that is not blank under the `## Verdict` heading:
# exactly `Verdict: BLOCKED` or `Verdict: PASS (advisory)`. Only that line is read. Blanks at the
# end of the heading and of the line are tolerated and nothing else is: any other first line (the
# sentence the template used to carry, other letter case, blanks in front), a verdict written on
# the heading line, no heading, or more than one `## Verdict` heading is `none`.
analysis_verdict() {
  local line t heads=0 in=0 got=none
  while IFS= read -r line || [ -n "$line" ]; do
    t="${line%"${line##*[![:space:]]}"}"
    if [ "$t" = "## Verdict" ]; then heads=$((heads + 1)); in=1; got=none; continue; fi
    [ "$in" -eq 1 ] || continue
    [ -n "$t" ] || continue
    in=0
    case "$t" in
      "Verdict: BLOCKED")         got=blocked ;;
      "Verdict: PASS (advisory)") got=clear ;;
    esac
  done < "$1"
  [ "$heads" -eq 1 ] || got=none
  echo "$got"
}
# inside_project <file> — exit 0 when the path (relative to the project unless absolute) is a
# file, is not a link, and its folder resolves to somewhere inside the project.
inside_project() {
  local f="$1" dir proj
  case "$f" in /*) ;; *) f="$PROJECT/$f" ;; esac
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  dir="$(cd "${f%/*}" 2>/dev/null && pwd -P)" || return 1
  proj="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || return 1
  [ "$proj" = / ] && return 0
  case "$dir/" in "$proj"/*) return 0 ;; *) return 1 ;; esac
}
# auth_configured <auth text> — exit 0 when a persona's `auth` entry says how it signs in. Only
# these count (the forms skills/discovering-user-roles/SKILL.md step 4 and
# skills/confirming-discovered-roles/SKILL.md write):
#   - a text that names a `.json` file (a captured storageState; any letter case of the ending):
#     the file must exist inside the project (inside_project); a path that leaves the project, or
#     a link, does not count;
#   - a seeded login pattern: a word with `@` in it (`qa.admin@<host> (seeded credential…)`);
#   - `login as …` (a contextual role reached through another account);
#   - `none needed` (the anonymous persona).
# Anything else does not: empty, `unknown…`, and words such as TODO, none, not configured, `?`.
# Presence only; nothing is opened or signed in.
auth_configured() {
  local a w f="" l
  a="$(trimmed "$1")"
  l="$(lower "$a")"
  case "$l" in ""|unknown*) return 1 ;; esac
  set -f
  for w in $a; do
    while :; do case "$w" in [\"\'\(\[\<\`]*) w="${w#?}" ;; *) break ;; esac; done
    while :; do case "$w" in *[\"\'\)\]\>\`,.\;:]) w="${w%?}" ;; *) break ;; esac; done
    case "$w" in *.[Jj][Ss][Oo][Nn]) f="$w"; break ;; esac
  done
  set +f
  if [ -n "$f" ]; then inside_project "$f"; return; fi
  case "$l" in
    "none needed"|"none needed"[!a-z0-9]*) return 0 ;;
    "login as "?*) return 0 ;;
    *[!\ @]@[!\ @]*) return 0 ;;
  esac
  return 1
}
# signin_facts — the sign-in facts of .qa/config.json for an OPEN journey, in one engine call: the
# lines signin_from reads. One line instead when there is nothing to read: `!nojourney` or
# `!notopen` (the journey is not open), `!noconfig` (no config). Fails when the config is not one
# JSON object.
signin_facts() {
  local cs cf
  file_state "$CONFIG"; cs="$FS_STATE"; cf="$FS_PATH"
  journey_fs
  if [ "$ENGINE" = jq ]; then
    jq -rn --rawfile jt "$J_PATH" --arg js "$J_FS" --rawfile ct "$cf" --arg cs "$cs" "$JQ_RD $JQ_OPEN"'
      def s: if type == "string" then gsub("[\r\n\t]"; " ") else "" end;
      open_or($js; $jt;
        if $cs == "0" then "!noconfig"
        else (rd($cs; $ct; false) | if .ok and (.v | type) == "object" then .v else error("not an object") end)
          | ((.auth | if type == "object" then .storageState else null end) | s),
            ((.personas | if type == "array" then .[] else empty end)
              | select(type == "object" and (.id | type) == "string") | "\(.id | tojson)\t\(.auth | s)")
        end)' 2>/dev/null
  else
    py personas "$J_FS" "$J_PATH" "$cs" "$cf" 2>/dev/null
  fi
}
# signin_from <facts> — the {"missing":[…],"ok":[…]} line from the sign-in facts of the config: a
# first line with `auth.storageState`, then one line per persona, `<id as JSON><tab><auth text>`.
signin_from() {
  local facts="$1" ss line idj ok="" missing="" n=0
  {
    IFS= read -r ss || true
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1)); idj="${line%%	*}"
      if auth_configured "${line#*	}"; then ok="$ok,$idj"; else missing="$missing,$idj"; fi
    done
  } <<EOT
$facts
EOT
  if [ "$n" -eq 0 ]; then
    if [ -n "$ss" ] && inside_project "$ss"; then ok=',"default"'; else missing=',"default"'; fi
  fi
  printf '{"missing":[%s],"ok":[%s]}\n' "${missing#,}" "${ok#,}"
}
# stop_journey <reason> <detail> [status] — close the open journey as stopped, in one engine call
# that refuses (`no open journey`) when it is not open. Reason must be a J2 reason. STATUS_LINE is
# then the `next` line of the stop, or with `status` the status line.
stop_journey() {
  in_list "$1" "$RESUMABLE_REASONS $FINAL_REASONS" || die "internal: unknown stop reason $1"
  local now print=',"print":"stop"'
  [ "${3:-}" = status ] && print=""
  now="$(now_iso)" || exit 1
  journey_apply "{\"require\":\"open\",\"set\":{\"state\":\"stopped\",\"endedAt\":\"$now\"},\"stop\":\"$1\"$print}" old "$2"
}
# has_text <file> — exit 0 when the file holds something other than blanks and line breaks.
has_text() { LC_ALL=C grep -q '[^[:space:]]' "$1" 2>/dev/null; }
# step_artifact_done <step> [run id] — exit 0 when the step's result is on disk (the checks
# /qa-status makes; `run` also wants a report that is not empty: one with only blanks is empty). `run` and `verify` need the run
# id. `start` asks only for the three steps a new journey can inherit. What `step-done` asks on
# top of this for `run` and `verify` (files that parse, results for this spec, a run that has
# ended) is in cmd_step_done.
step_artifact_done() {
  case "$1" in
    constitution) [ -f "$QA_DIR/constitution.state.json" ] ;;
    spec)         [ -f "$SPEC_DIR/qa-spec.md" ] && [ -f "$SPEC_DIR/spec-roles.json" ] ;;
    scenarios)    [ -f "$SPEC_DIR/scenarios.md" ] && [ -f "$SPEC_DIR/checklist.json" ] ;;
    analyze)      [ -f "$SPEC_DIR/analysis.md" ] && ! [ "$SPEC_DIR/analysis.md" -ot "$SPEC_DIR/checklist.json" ] ;;
    run)          [ -n "${2:-}" ] && [ -f "$QA_DIR/runs/$2/run-manifest.json" ] && [ -f "$QA_DIR/runs/$2/checkpoint.json" ] && [ -f "$QA_DIR/runs/$2/report.md" ] && has_text "$QA_DIR/runs/$2/report.md" ;;
    verify)       [ -n "${2:-}" ] && [ -f "$QA_DIR/runs/$2/verification.json" ] ;;
    *) return 1 ;;
  esac
}
# archive_journey — move everything in auto/ except history/ to auto/history/<n>/. Sets
# ARCHIVED_N to that number, or 0 when there was nothing to move. A plain command only.
ARCHIVED_N=0
archive_journey() {
  local n=0 d b f moved=0
  ARCHIVED_N=0
  [ -d "$AUTO_DIR" ] || return 0
  for d in "$AUTO_DIR"/history/*/; do
    [ -d "$d" ] || continue
    b="${d%/}"; b="${b##*/}"
    case "$b" in ""|*[!0-9]*) continue ;; esac
    [ "$b" -gt "$n" ] && n="$b"
  done
  n=$((n + 1))
  for f in "$AUTO_DIR"/* "$AUTO_DIR"/.[!.]*; do
    [ -e "$f" ] || continue
    [ "${f##*/}" = history ] && continue
    if [ "$moved" -eq 0 ]; then mkdir -p "$AUTO_DIR/history/$n" 2>/dev/null || die "could not write .qa/specs/$TARGET/auto/history/$n"; moved=1; fi
    mv "$f" "$AUTO_DIR/history/$n/" 2>/dev/null || die "could not write .qa/specs/$TARGET/auto/history/$n"
  done
  [ "$moved" -eq 0 ] || ARCHIVED_N="$n"
}

# ---------------------------------------------------------------------------------------------
# Environment rules (plan decision J7; design B2)
# ---------------------------------------------------------------------------------------------
LOWER='abcdefghijklmnopqrstuvwxyz'; UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
# lower <text> — the text with ASCII capitals made small.
lower() { printf '%s' "$1" | tr "$UPPER" "$LOWER"; }
# trimmed <text> — the text without blanks at either end.
trimmed() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; printf '%s' "${t%"${t##*[![:space:]]}"}"; }
# url_host <url> — the lower-case host of a URL, or nothing when the address is not plainly
# `[scheme://][user[:password]@]host[:port][/…]`: a backslash or a blank anywhere before the
# path, an unusual character in the user part, a host character outside `a-z 0-9 . -` (the one
# bracketed host accepted is `[::1]`), or a port that is not digits. Strict on purpose: the answer
# decides whether an environment counts as local, and browsers read such addresses in other ways.
url_host() {
  local u="$1" ui="" h port=""
  case "$u" in *://*) u="${u#*://}" ;; esac
  u="${u%%/*}"; u="${u%%\?*}"; u="${u%%#*}"
  case "$u" in *\\*|*[[:space:]]*|*[[:cntrl:]]*) return 0 ;; esac
  case "$u" in *@*) ui="${u%@*}"; u="${u##*@}" ;; esac
  case "$ui" in *[!${LOWER}${UPPER}0123456789._~!\$\&\'\(\)*+,\;=:%-]*) return 0 ;; esac
  case "$u" in
    '[::1]') h="$u" ;;
    '[::1]':*) h='[::1]'; port="${u:6}" ;;
    \[*) return 0 ;;
    *:*) h="${u%%:*}"; port="${u#*:}" ;;
    *) h="$u" ;;
  esac
  case "$port" in *[!0123456789]*) return 0 ;; esac
  h="$(lower "$h")"
  case "$h" in
    '[::1]') ;;
    ""|*[!${LOWER}0123456789.-]*) return 0 ;;
  esac
  printf '%s' "$h"
}
# is_local_url <url> — exit 0 for a local host. A missing or empty address is not local.
is_local_url() {
  case "$(url_host "$1")" in
    localhost|127.0.0.1|'[::1]'|*.localhost|*.test|*.local|*.ddev.site) return 0 ;;
    *) return 1 ;;
  esac
}
# real_marker <seedableEnvMarker> — exit 0 when the marker says something: not empty, not blank,
# not the bootstrap word.
real_marker() {
  local m; m="$(trimmed "$1")"
  [ -n "$m" ] && [ "$m" != QA_DISPOSABLE_ENV ]
}
# env_is_production <environment> <baseUrl> <seedableEnvMarker> — the environment is one of the
# three words, lower-case (gate_config sees to that). Production is:
#   - `production`;
#   - a project with no baseUrl (empty or blank), unless it is `disposable` with a real marker;
#   - any environment other than `disposable` on a host that is not local with no real marker
#     (the rule the engine's pre-flight applies).
env_is_production() {
  [ "$1" = production ] && return 0
  if ! text_given "$2"; then
    [ "$1" = disposable ] && real_marker "$3" && return 1
    return 0
  fi
  [ "$1" = disposable ] && return 1
  is_local_url "$2" && return 1
  ! real_marker "$3"
}
# gate_config <now> <hours> — the refusals about the settings that `start` and `resume` share, in
# order: no config, config not JSON, a run-config that is not one JSON object, an environment that
# is not one of the three words, production. The settings judged are the MERGED ones: the project
# config with each top-level key of `.qa/specs/<target>/run-config.json` replacing the config's
# key of the same name, which is how the engine resolves a run's effective config
# (scripts/profile.sh, a shallow merge; an explicit null replaces too). One engine call. Sets
# G_BASE (the merged baseUrl as text), G_RC_PROFILE and G_CFG_PROFILE (the run-config's and the
# config's `profile`, empty when not text), G_DP (the merged gates.dataPolicy: enforce, other,
# unset, bad), G_DEADLINE (now plus the hours) and TARGET_JSON.
JQ_GATE='
  def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
  rd("1"; $ct; false) as $c
  | (if $rs == "0" then {ok: true, v: {}} else rd($rs; $rt; false) end) as $r
  | if ($c.ok | not) then "config-bad"
    elif ($r.ok | not) then "rc-bad"
    elif ($r.v | type) != "object" then "rc-shape"
    else
      (if ($c.v | type) == "object" then $c.v else {} end) as $cfg
      | merged($cfg; $r.v) as $d
      | "ok",
        (if ($d | has("environment") | not) then "absent" elif ($d.environment | type) == "string" then "string" else "other" end),
        ($d.environment | s), ($d.baseUrl | s), ($d.seedableEnvMarker | s), ($r.v.profile | s), ($cfg.profile | s),
        ($d.gates | if type == "object" then (if has("dataPolicy") then (if .dataPolicy == "enforce" then "enforce" else "other" end) else "unset" end)
                    elif . == null then "unset" else "bad" end),
        ((($now | fromdateiso8601) + ((($h | tonumber) * 3600) | floor)) | todateiso8601),
        ($target | tojson)
    end'
G_BASE=""; G_RC_PROFILE=""; G_CFG_PROFILE=""; G_DP="unset"; G_DEADLINE=""
gate_config() {
  local facts="" status="" kind="" env="" marker=""
  [ -f "$CONFIG" ] || die "no .qa/config.json; set the project up first"
  file_state "$SPEC_DIR/run-config.json"
  if [ "$ENGINE" = jq ]; then
    facts="$(jq -rn --rawfile ct "$CONFIG" --rawfile rt "$FS_PATH" --arg rs "$FS_STATE" --arg now "$1" --arg h "$2" --arg target "$TARGET" "$JQ_RD $JQ_GATE" 2>/dev/null)" || facts=""
  else
    facts="$(py gate "$CONFIG" "$FS_STATE" "$FS_PATH" "$1" "$2" "$TARGET" 2>/dev/null)" || facts=""
  fi
  read_lines "$facts" status kind env G_BASE marker G_RC_PROFILE G_CFG_PROFILE G_DP G_DEADLINE TARGET_JSON
  case "$status" in
    ok) ;;
    rc-bad)   die ".qa/specs/$TARGET/run-config.json is not valid JSON" ;;
    rc-shape) die ".qa/specs/$TARGET/run-config.json is not a JSON object" ;;
    *)        die ".qa/config.json is not valid JSON" ;;
  esac
  case "$kind" in
    absent) env=auto ;;
    string) env="$(lower "$env")"; one_of "$env" "$ENVIRONMENTS" || die "environment must be auto, production or disposable" ;;
    *) die "environment must be auto, production or disposable" ;;
  esac
  env_is_production "$env" "$G_BASE" "$marker" && die "this environment is production; an unattended journey does not run there"
  [ -n "$G_DEADLINE" ] && [ -n "$TARGET_JSON" ] || die "could not work out the deadline"
  return 0
}
# gate_data_policy <profile> — on a host that is not local the run must enforce the data policy:
# the merged `gates.dataPolicy` is `enforce`, or it is not set and the profile is ship or smoke
# (those profiles fill `gates.dataPolicy: enforce` only when it is not set; scripts/profile.sh).
gate_data_policy() {
  is_local_url "$G_BASE" && return 0
  case "$G_DP" in
    enforce) return 0 ;;
    unset)   if [ "$1" = ship ] || [ "$1" = smoke ]; then return 0; fi ;;
  esac
  die "the environment is shared and gates.dataPolicy is not enforce"
}
# file_sha256 <file> — hex SHA-256 of the file's bytes.
file_sha256() {
  local out=""
  if command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum "$1" 2>/dev/null)"
  elif command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256 "$1" 2>/dev/null)"
  elif command -v openssl >/dev/null 2>&1; then out="$(openssl dgst -sha256 -r "$1" 2>/dev/null)"
  elif has_py; then out="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null)"
  fi
  out="${out%% *}"
  [ "${#out}" -eq 64 ] || die "could not hash ${1#"$PROJECT"/}"
  printf '%s\n' "$out"
}
# baseline_text <profile> <now> — sets BASE_TEXT to the baseline, pretty-printed, from the files as
# they are now (one engine call; the jq engine hashes the person-confirmed rows first). The
# baseline records the MERGED settings (see gate_config): `safety` holds every SAFETY_KEYS key the
# merged settings have (a key they do not have is left out, so a later explicit null is a change),
# `baseUrl` the merged address, and `runConfig` the run-config's own RC_KEYS keys as they were. A
# plain command only: it ends the script when a file cannot be read or holds an odd number.
JQ_BASELINE='
  rd("1"; $ct; false) as $c
  | (if $rs == "0" then {ok: true, v: {}} else rd($rs; $rt; false) end) as $r
  | (if $ps == "0" then {ok: true, v: null} else rd($ps; $pt; false) end) as $p
  | (if $es == "0" then {ok: true, v: []} else rd($es; $et; false) end) as $e
  | if ($c.ok | not) then "config-bad"
    elif ($r.ok | not) then "rc-bad"
    elif ($r.v | type) != "object" then "rc-shape"
    elif ($p.ok | not) then "plan-bad"
    elif $ps != "0" and ($p.v | type) != "array" then "plan-shape"
    elif ($e.ok | not) then "excl-bad"
    else
      merged($c.v; $r.v) as $d
      | (reduce ($keys | split(" "))[] as $k ({}; look($d; $k) as $l | if $l.found then .[$k] = $l.v else . end)) as $saf
      | (reduce ($rckeys | split(" "))[] as $k ({}; if ($r.v | has($k)) then .[$k] = $r.v[$k] else . end)) as $rc
      | ($p.v | plan_rows) as $rows
      | if ($saf | odd) or ($rc | odd) then "odd-safety"
        elif any($rows | human_rows[]; .fixture.expect | odd) then "odd-plan"
        elif ($e.v | odd) then "odd-excl"
        else "ok",
          ({version: 1, target: $target, takenAt: $now, profile: $profile,
            baseUrl: ($d.baseUrl | if type == "string" then . else null end), safety: $saf, runConfig: $rc,
            humanOracleIds: ($rows | human_ids), humanOracleHashes: $hh,
            planRowIds: (if $ps == "0" then null else ($rows | row_ids) end), seedExists: ($seed == "true"),
            exclusions: $e.v, knownDefectsHash: (if $kd == "" then null else $kd end)} | norm)
        end
    end'
BASE_TEXT=""
baseline_text() {
  local profile="$1" now="$2" rs rf ps pf es ef seed=false kd="" hh="{}" out=""
  file_state "$SPEC_DIR/run-config.json"; rs="$FS_STATE"; rf="$FS_PATH"
  file_state "$SPEC_DIR/checklist.json"; ps="$FS_STATE"; pf="$FS_PATH"
  file_state "$SPEC_DIR/coverage-exclusions.json"; es="$FS_STATE"; ef="$FS_PATH"
  [ -f "$SPEC_DIR/seed.json" ] && seed=true
  if [ -f "$QA_DIR/known-defects.json" ]; then kd="$(file_sha256 "$QA_DIR/known-defects.json")" || exit 1; fi
  if [ "$ENGINE" = jq ]; then
    if [ "$ps" = 1 ]; then hh="$(plan_hashes "$pf")" || hh=""; fi
    [ -n "$hh" ] || hh="{}"
    out="$(jq -rnS --rawfile ct "$CONFIG" --rawfile rt "$rf" --rawfile pt "$pf" --rawfile et "$ef" --arg rs "$rs" --arg ps "$ps" --arg es "$es" \
      --arg keys "$SAFETY_KEYS" --arg rckeys "$RC_KEYS" --arg target "$TARGET" --arg now "$now" --arg profile "$profile" --arg seed "$seed" \
      --arg kd "$kd" --argjson hh "$hh" "$JQ_DEFS $JQ_RD $JQ_PLAN $JQ_BASELINE" 2>/dev/null)" || out=""
  else
    out="$(py baseline "$CONFIG" "$rs" "$rf" "$ps" "$pf" "$es" "$ef" "$SAFETY_KEYS" "$RC_KEYS" "$TARGET" "$now" "$profile" "$seed" "$kd" 2>/dev/null)" || out=""
  fi
  case "${out%%"$NL"*}" in
    ok)         BASE_TEXT="${out#*"$NL"}" ;;
    rc-bad)     die ".qa/specs/$TARGET/run-config.json is not valid JSON" ;;
    rc-shape)   die ".qa/specs/$TARGET/run-config.json is not a JSON object" ;;
    plan-bad)   die ".qa/specs/$TARGET/checklist.json is not valid JSON" ;;
    plan-shape) die ".qa/specs/$TARGET/checklist.json is not a list of rows" ;;
    excl-bad)   die ".qa/specs/$TARGET/coverage-exclusions.json is not valid JSON" ;;
    odd-safety) die "a number in the safety settings cannot be compared; write a plain number" ;;
    odd-plan)   die "a number in a person-confirmed expected value of .qa/specs/$TARGET/checklist.json cannot be compared; write it as text" ;;
    odd-excl)   die "a number in .qa/specs/$TARGET/coverage-exclusions.json cannot be compared; write it as text" ;;
    *)          die ".qa/config.json is not valid JSON" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------------------------
cmd_start() {
  parse_common "$@"
  local profile_flag="" until="" hours="$DEFAULT_MAX_HOURS" restart=0 kd_invalid=0
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)   [ "$#" -ge 2 ] || usage "--profile needs ship, smoke or full"; profile_flag="$2"; shift 2 ;;
      --until)     [ "$#" -ge 2 ] || usage "--until needs a step"; until="$2"; shift 2 ;;
      --max-hours) [ "$#" -ge 2 ] || usage "--max-hours needs a number"; hours="$2"; shift 2 ;;
      --restart)   restart=1; shift ;;
      --known-defects-invalid) kd_invalid=1; shift ;;
      *) usage "start does not take: $1" ;;
    esac
  done
  [ -z "$profile_flag" ] || in_list "$profile_flag" "ship smoke full" || usage "--profile must be ship, smoke or full"
  [ -z "$until" ] || in_list "$until" "$STEPS" || usage "--until must be one of: $STEPS"
  valid_hours "$hours" || usage "$HOURS_RULE"
  need_engine

  # Preconditions (design B2; "THE GATE" in the header), in order. Nothing is written until all
  # of them hold.
  local now was_open=0 had=0 after_audit=0
  now="$(now_iso)" || exit 1
  gate_config "$now" "$hours"
  [ "$kd_invalid" -eq 0 ] || die ".qa/known-defects.json is not valid"
  lock_check
  [ "$J_STATE" = open ] && was_open=1
  [ -n "$J_STATE" ] && had=1
  if [ "$restart" -eq 0 ]; then
    if [ "$J_STATE" = open ]; then
      die "a journey is already open for $TARGET; continue it or pass --restart"
    elif [ "$J_STATE" = stopped ] && in_list "$J_REASON" "$RESUMABLE_REASONS"; then
      die "a journey for $TARGET is stopped ($J_REASON); resume it or pass --restart"
    elif [ "$J_STATE" = stopped ]; then
      # Any other stop (blocked, audit, no-sign-in, tracker, or a reason that was not recorded) is
      # not finished either: a new journey takes a fresh baseline, so a person has to ask for it.
      die "a journey for $TARGET is stopped (${J_REASON:-no reason recorded}); pass --restart to start a new one"
    fi
  fi
  [ "$J_STATE" = stopped ] && [ "$J_REASON" = audit ] && after_audit=1
  # The launch profile: --profile, else the spec's run-config, else the project's config, else
  # `full` (the precedence scripts/profile.sh documents).
  local profile="$profile_flag"
  [ -n "$profile" ] || profile="$G_RC_PROFILE"
  [ -n "$profile" ] || profile="$G_CFG_PROFILE"
  one_of "$profile" "ship smoke full" || profile=full
  gate_data_policy "$profile"

  local steps sep s st until_json extra=""
  baseline_text "$profile" "$now"
  steps=""; sep=""
  for s in $STEPS; do
    st=pending
    # Only these three can be inherited; analyze, run and verify are always this journey's own.
    in_list "$s" "constitution spec scenarios" && step_artifact_done "$s" && st=done
    steps="$steps$sep{\"name\":\"$s\",\"state\":\"$st\",\"attempts\":0}"; sep=","
  done
  until_json=null; [ -z "$until" ] || until_json="\"$until\""

  # Writes start here: the earlier journey (finished, or any other with --restart) goes to history,
  # then the baseline, then the journey. Each is a plain command that ends the script when it
  # fails, so the journey is never written unless the baseline was.
  real_folders
  archive_journey
  mkdir -p "$AUTO_DIR" 2>/dev/null || die "could not write .qa/specs/$TARGET/auto"
  atomic_write "$BASELINE" "$BASE_TEXT"
  # The journey keeps the hash of the baseline as written, so the audit can tell a rewritten one.
  local bhash
  bhash="$(file_sha256 "$BASELINE")" || exit 1
  # A journey that took the place of an earlier one says so (`replacedFrom`: the history number
  # the earlier journey went to), whatever state that one was in; when it was still open the
  # journey also says `restartedFrom`, and when it had stopped for `audit`, `replacedAfterAudit`.
  # The handoff tells the person each.
  if [ "$had" -eq 1 ] && [ "$ARCHIVED_N" -gt 0 ]; then
    extra=",\"replacedFrom\":$ARCHIVED_N"
    [ "$was_open" -eq 0 ] || extra="$extra,\"restartedFrom\":$ARCHIVED_N"
    # The earlier journey had failed its audit: the new one starts from a fresh baseline, so it
    # says so and the handoff tells the person.
    [ "$after_audit" -eq 0 ] || extra="$extra,\"replacedAfterAudit\":true"
  fi
  journey_apply "{\"set\":{\"version\":1,\"target\":$TARGET_JSON,\"profile\":\"$profile\",\"startedAt\":\"$now\",\"deadline\":\"$G_DEADLINE\",\"until\":$until_json,\"steps\":[$steps],\"analyzeRounds\":0,\"runId\":null,\"state\":\"open\",\"stop\":null,\"endedAt\":null,\"baselineHash\":\"$bhash\"$extra}}" new
  printf '%s\n' "$STATUS_LINE"
}

cmd_resume() {
  parse_common "$@"
  local hours="$DEFAULT_MAX_HOURS" kd_invalid=0
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-hours) [ "$#" -ge 2 ] || usage "--max-hours needs a number"; hours="$2"; shift 2 ;;
      --known-defects-invalid) kd_invalid=1; shift ;;
      *) usage "resume does not take: $1" ;;
    esac
  done
  valid_hours "$hours" || usage "$HOURS_RULE"
  need_engine
  local reason now fields profile
  journey_load
  case "$J_STATE" in
    open|done|stopped) ;;
    *) if [ -e "$JOURNEY" ] || [ -L "$JOURNEY" ]; then die "the journey for $TARGET cannot be read"; fi ;;
  esac
  [ "$J_STATE" = stopped ] || die "nothing to resume"
  reason="$J_REASON"
  in_list "$reason" "$RESUMABLE_REASONS" || die "nothing to resume"
  # The gate again, as at `start`: the settings may have changed while the journey was stopped.
  now="$(now_iso)" || exit 1
  gate_config "$now" "$hours"
  [ "$kd_invalid" -eq 0 ] || die ".qa/known-defects.json is not valid"
  lock_check own-loaded
  # The data policy is judged under the profile this journey was launched with.
  profile="$J_PROFILE"
  one_of "$profile" "ship smoke full" || profile=full
  gate_data_policy "$profile"
  fields="\"state\":\"open\",\"stop\":null,\"endedAt\":null,\"deadline\":\"$G_DEADLINE\""
  # A journey that stopped at its --until step goes on past it when resumed.
  [ "$reason" = until ] && fields="$fields,\"until\":null"
  # Every resume leaves a trace: when, with how many hours, and from which stop.
  journey_apply "{\"set\":{$fields},\"append\":{\"resumes\":{\"at\":\"$now\",\"maxHours\":$(hours_json "$hours"),\"from\":\"$reason\"}}}"
  printf '%s\n' "$STATUS_LINE"
}

cmd_stop() {
  parse_common "$@"
  local reason="" detail="" have_reason=0 have_detail=0
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || usage "--reason needs a value"; reason="$2"; have_reason=1; shift 2 ;;
      --detail) [ "$#" -ge 2 ] || usage "--detail needs a value"; detail="$2"; have_detail=1; shift 2 ;;
      *) usage "stop does not take: $1" ;;
    esac
  done
  [ "$have_reason" -eq 1 ] || usage "stop needs --reason"
  [ "$have_detail" -eq 1 ] || usage "stop needs --detail"
  in_list "$reason" "$RESUMABLE_REASONS $FINAL_REASONS" || usage "--reason must be one of: $RESUMABLE_REASONS $FINAL_REASONS"
  need_engine
  [ -f "$JOURNEY" ] || die "no open journey for $TARGET"
  stop_journey "$reason" "$detail" status
  printf '%s\n' "$STATUS_LINE"
}

cmd_status() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "status does not take: ${REST[0]}"
  need_engine
  [ -f "$JOURNEY" ] || die "no journey for $TARGET"
  print_status
}

cmd_next() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "next does not take: ${REST[0]}"
  need_engine
  [ -f "$JOURNEY" ] || die "no journey for $TARGET"
  local now out=""
  now="$(now_iso)" || exit 1
  # One engine call reads the journey, picks the step and, when every step is done or a limit is
  # reached (see journey_step), writes the journey as done or stopped.
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rnS --rawfile jt "$JOURNEY" --arg order "$STEPS" --arg now "$now" "$JQ_DEFS $JQ_RD $JQ_CHANGE $JQ_NEXT" 2>/dev/null)" || out=""
  else
    out="$(py next "$JOURNEY" "$STEPS" "$now" 2>/dev/null)" || out=""
  fi
  [ -n "$out" ] || die "no journey for $TARGET"
  [ "$out" != "!unreadable" ] || die "journey.json for $TARGET is not readable"
  rows_commit "$JOURNEY" "$out"
  printf '%s\n' "$ROWS_LINE"
}

cmd_step_start() {
  parse_common "$@"
  set -- ${REST[@]+"${REST[@]}"}
  [ "$#" -ge 1 ] || usage "step-start needs a step"
  [ "$#" -eq 1 ] || usage "step-start does not take: $2"
  in_list "$1" "$STEPS" || usage "the step must be one of: $STEPS"
  need_engine
  local now
  now="$(now_iso)" || exit 1
  journey_step "start" "$1" "$now" ""
  printf '%s\n' "$STATUS_LINE"
}

# run_refusal <run id> — after journey_read: the refusal for a run that is not this journey's
# finished result (empty when it is). In order: the run's files are there, they parse, and the
# report says something; the engine has closed the run; at least one of its results is for a row
# of this spec's plan; it started inside this journey.
run_refusal() {
  local r_epoch j_epoch st=""
  step_artifact_done run "$1" || { echo "run has no result yet"; return 0; }
  run_facts "$1" || { echo "run has no result yet"; return 0; }
  if [ "$R_MANIFEST" != ok ] || [ "$R_CHECKPOINT" != ok ]; then echo "run has no result yet"; return 0; fi
  # A run the engine has not closed is not a result: the manifest must say so itself, with a
  # `status` that is text and is not `in-progress`. A status that is missing, null, blank or not
  # text says nothing, and nothing is not "ended".
  case "$R_STATUS" in =*) st="$(trimmed "${R_STATUS#=}")" ;; *) st="" ;; esac
  if [ -z "$st" ]; then echo "that run has no status"; return 0; fi
  if [ "$st" = in-progress ]; then echo "that run is still in progress"; return 0; fi
  # The run must be about this spec: at least one of its results is for a row of this plan.
  if [ "$R_ROWS" != 1 ]; then echo "that run has no results for this spec"; return 0; fi
  # The run must have started inside this journey; an earlier run is another plan's result.
  # A manifest start time without a zone cannot be compared: the first checkpoint stands in.
  r_epoch="$(run_start_epoch)" || { echo "that run has no start time"; return 0; }
  j_epoch="$(time_epoch "$J_STARTED")" || { echo "journey.json for $TARGET is not readable"; return 0; }
  [ "$r_epoch" -ge "$j_epoch" ] || echo "that run started before this journey"
}

# verify_plan_refusal <run id> — runs qa-kit's own plan checks for the journey's run and prints the
# refusal when one does not pass (nothing when both pass). The script is verify-plan.sh beside this
# one (qa-kit's file, not the engine's), run twice, as /qa-verify runs it:
#   verify-plan.sh <run>/checkpoint.json <spec>/checklist.json           a check acted outside the plan
#   verify-plan.sh --drift <run>/checklist.json <spec>/checklist.json    the run's plan differs from the spec's
# Only the exit code is used; any exit other than 0 (a finding, a missing file, input that does not
# parse) is a refusal. `QA_AUTO_VERIFY_PLAN_CMD` replaces the command only when `QA_AUTO_TEST=1` is
# set too (the suites set both); in a real journey the variable is ignored.
verify_plan_refusal() {
  local run="$QA_DIR/runs/$1" plan="$SPEC_DIR/checklist.json"
  if [ "${QA_AUTO_TEST:-}" = 1 ] && [ -n "${QA_AUTO_VERIFY_PLAN_CMD+x}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- $QA_AUTO_VERIFY_PLAN_CMD
    set +f
  else
    set -- bash "$SCRIPT_DIR/verify-plan.sh"
  fi
  if [ "$#" -eq 0 ]; then echo "the plan check did not pass for this run"; return 0; fi
  if ! "$@" "$run/checkpoint.json" "$plan" >/dev/null 2>&1 </dev/null; then echo "the plan check did not pass for this run"; return 0; fi
  if ! "$@" --drift "$run/checklist.json" "$plan" >/dev/null 2>&1 </dev/null; then echo "the plan drift check did not pass for this run"; fi
  return 0
}

cmd_step_done() {
  parse_common "$@"
  local step="" run="" have_run=0
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run) [ "$#" -ge 2 ] || usage "--run needs a run id"; run="$2"; have_run=1; shift 2 ;;
      --*)   usage "step-done does not take: $1" ;;
      *)     [ -z "$step" ] || usage "step-done does not take: $1"; step="$1"; shift ;;
    esac
  done
  [ -n "$step" ] || usage "step-done needs a step"
  in_list "$step" "$STEPS" || usage "the step must be one of: $STEPS"
  if [ "$step" = run ]; then
    [ "$have_run" -eq 1 ] || usage "step-done run needs --run <run-id>"
    case "$run" in ""|.|..|*/*|-*) usage "not a usable run id: $run" ;; esac
  else
    [ "$have_run" -eq 0 ] || usage "--run goes with the run step only"
  fi
  need_engine

  # The shell looks for the step's result on disk and hands journey_step the refusal it found, if
  # any; journey_step judges the journey first (open, the next step, the limits) and only then
  # prints that refusal, so a step out of order or past a limit is reported as that.
  local refuse="" blocked=0 verdict now
  now="$(now_iso)" || exit 1
  case "$step" in
    run)
      journey_read_open
      refuse="$(run_refusal "$run")"
      ;;
    verify)
      journey_read_open
      case "$J_RUN" in ""|.|..|*/*|-*) J_RUN="" ;; esac
      if [ -z "$J_RUN" ]; then refuse="no run is recorded for this journey"
      # An empty or broken verification.json, or one that holds no rows (`null`, `[]`, `{}`), is no result.
      elif ! verification_ok "$QA_DIR/runs/$J_RUN/verification.json"; then refuse="verify has no result yet"
      # The plan checks decide, not the caller: qa-kit's own verify-plan.sh, plain and --drift.
      else refuse="$(verify_plan_refusal "$J_RUN")"; fi
      ;;
    analyze)
      verdict=none
      step_artifact_done analyze && verdict="$(analysis_verdict "$SPEC_DIR/analysis.md")"
      case "$verdict" in
        none)    refuse="analyze has no result yet" ;;
        blocked) blocked=1 ;;
      esac
      ;;
    *)
      step_artifact_done "$step" || refuse="$step has no result yet"
      ;;
  esac
  journey_step "done" "$step" "$now" "$refuse" "$blocked" "$run"
  printf '%s\n' "$STATUS_LINE"
}

cmd_signin() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "signin does not take: ${REST[0]}"
  need_engine
  local out
  out="$(signin_facts)" || die ".qa/config.json is not valid JSON"
  case "$out" in
    "!nojourney"|"!notopen") die "no open journey for $TARGET" ;;
    "!noconfig") die "no .qa/config.json; set the project up first" ;;
  esac
  out="$(signin_from "$out")"
  case "$out" in
    *'"ok":[]}') stop_journey no-sign-in "no persona has sign-in configured" status ;;
  esac
  printf '%s\n' "$out"
}

cmd_decide() {
  parse_common "$@"
  local step="" class="" question="" answer="" evidence="" confidence="" criteria="" seen=""
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --step|--class|--question|--answer|--evidence|--confidence|--criteria)
        [ "$#" -ge 2 ] || usage "$1 needs a value"
        case "$1" in
          --step) step="$2" ;; --class) class="$2" ;; --question) question="$2" ;; --answer) answer="$2" ;;
          --evidence) evidence="$2" ;; --confidence) confidence="$2" ;; --criteria) criteria="$2" ;;
        esac
        seen="$seen $1"; shift 2 ;;
      *) usage "decide does not take: $1" ;;
    esac
  done
  local f
  for f in --step --class --question --answer --evidence --confidence; do
    in_list "$f" "$seen" || usage "decide needs $f"
  done
  one_of "$step" "$STEPS" || usage "--step must be one of: $STEPS"
  one_of "$class" "$DECIDABLE_CLASSES $FORBIDDEN_CLASSES" || usage "--class must be one of: $DECIDABLE_CLASSES"
  one_of "$confidence" "high low" || usage "--confidence must be high or low"
  text_given "$question" || usage "--question cannot be empty"
  text_given "$answer" || usage "--answer cannot be empty"
  text_given "$evidence" || usage "--evidence cannot be empty; pass the word none when there is no evidence"
  need_engine
  # (a class the journey never decides is refused after the journey itself has been looked at)
  if in_list "$class" "$FORBIDDEN_CLASSES"; then
    journey_require_open_strict
    die "$class is never decided by an unattended journey"
  fi
  journey_fs
  # No evidence is the word `none` in any letter case, blanks around it ignored.
  local none=0 src out
  [ "$(lower "$(trimmed "$evidence")")" = none ] && none=1
  src="$(rows_source "$DECISIONS")"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rsS --arg step "$step" --arg class "$class" --arg q "$question" --arg a "$answer" --arg ev "$evidence" \
      --arg none "$none" --arg conf "$confidence" --arg crit "$criteria" --rawfile jt "$J_PATH" --arg js "$J_FS" "$JQ_DEFS $JQ_RD $JQ_ROWS $JQ_OPEN"' open_or($js; $jt; rows_in
      | next_id("D") as $id
      | . + [{id: $id, step: $step, class: $class, question: $q, answer: $a,
              evidence: (if $none == "1" then null else $ev end), confidence: $conf,
              criteria: ($crit | split(",") | map(gsub("^[ \t\r\n]+|[ \t\r\n]+$"; "")) | map(select(length > 0))),
              assumption: true, needsPerson: ($none == "1"), second: null, secondReason: null}]
      | $id, norm)' < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  else
    out="$(py decide "$J_FS" "$J_PATH" "$step" "$class" "$question" "$answer" "$evidence" "$none" "$confidence" "$criteria" < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  fi
  journey_gate "$out"
  rows_commit "$DECISIONS" "$out"
  printf '%s\n' "$ROWS_LINE"
}

cmd_second() {
  parse_common "$@"
  local id="" verdict="" reason="" have_reason=0 unavailable=0 words=0
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || usage "--reason needs a value"; reason="$2"; have_reason=1; shift 2 ;;
      --unavailable) unavailable=1; shift ;;
      --*) usage "second does not take: $1" ;;
      *) words=$((words + 1))
         case "$words" in 1) id="$1" ;; 2) verdict="$1" ;; *) usage "second does not take: $1" ;; esac
         shift ;;
    esac
  done
  local src out
  if [ "$unavailable" -eq 1 ]; then
    [ "$words" -eq 0 ] && [ "$have_reason" -eq 0 ] || usage "--unavailable goes alone"
    need_engine
    journey_fs
    src="$(rows_source "$DECISIONS")"
    if [ "$ENGINE" = jq ]; then
      out="$(jq -rsS --rawfile jt "$J_PATH" --arg js "$J_FS" "$JQ_DEFS $JQ_RD $JQ_ROWS $JQ_OPEN"' open_or($js; $jt; rows_in
        | [ .[] | objects | select(.confidence == "low" and .second == null and .needsPerson != true) | .id ] as $ids
        | map(if type == "object" and .confidence == "low" and .second == null then .needsPerson = true else . end)
        | "{\"marked\":[\($ids | map(tojson) | join(","))]}", norm)' < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
    else
      out="$(py unavailable "$J_FS" "$J_PATH" < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
    fi
    journey_gate "$out"
    # Without a decisions file there is nothing to mark and no file is made.
    if [ -f "$DECISIONS" ]; then rows_commit "$DECISIONS" "$out"; else ROWS_LINE='{"marked":[]}'; fi
    journey_apply '{"set":{"secondLook":"unavailable"}}'
    printf '%s\n' "$ROWS_LINE"
    return 0
  fi
  [ "$words" -ge 1 ] || usage "second needs a decision id, or --unavailable"
  [ "$words" -eq 2 ] || usage "second needs stands or ask"
  one_of "$verdict" "stands ask" || usage "the second look is stands or ask"
  [ "$have_reason" -eq 1 ] || usage "second needs --reason"
  text_given "$reason" || usage "--reason cannot be empty"
  need_engine
  journey_fs
  src="$(rows_source "$DECISIONS")"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rsS --arg id "$id" --arg v "$verdict" --arg r "$reason" --rawfile jt "$J_PATH" --arg js "$J_FS" "$JQ_DEFS $JQ_RD $JQ_ROWS $JQ_OPEN"' open_or($js; $jt; rows_in
      | (map(type == "object" and .id == $id) | index(true)) as $i
      | if $v == "stands" and (rd($js; $jt; false).v.secondLook == "unavailable") then "!unavailable"
        elif $i == null then "!missing"
        else
          (if .[$i].second == null or (.[$i].second == "stands" and $v == "ask")
           then .[$i] |= (.second = $v | .secondReason = $r | if $v == "ask" then .needsPerson = true else . end)
           else . end)
          | (.[$i] | "{\"id\":\(.id | tojson),\"needsPerson\":\(.needsPerson | tojson),\"second\":\(.second | tojson)}"), norm
        end)' < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  else
    out="$(py second "$J_FS" "$J_PATH" "$id" "$verdict" "$reason" < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  fi
  journey_gate "$out"
  # Once the second look was recorded as unavailable nobody independent can let a decision stand.
  [ "$out" != "!unavailable" ] || die "the second look was recorded as unavailable; a decision cannot be let stand"
  [ "$out" != "!missing" ] || die "no decision $id"
  rows_commit "$DECISIONS" "$out"
  printf '%s\n' "$ROWS_LINE"
}

cmd_note() {
  parse_common "$@"
  local kind="" text="" have_kind=0 have_text=0
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || usage "--kind needs a value"; kind="$2"; have_kind=1; shift 2 ;;
      --text) [ "$#" -ge 2 ] || usage "--text needs a value"; text="$2"; have_text=1; shift 2 ;;
      *) usage "note does not take: $1" ;;
    esac
  done
  [ "$have_kind" -eq 1 ] || usage "note needs --kind"
  [ "$have_text" -eq 1 ] || usage "note needs --text"
  one_of "$kind" "$NOTE_KINDS" || usage "--kind must be one of: $NOTE_KINDS"
  text_given "$text" || usage "--text cannot be empty"
  need_engine
  journey_fs
  local now src out
  now="$(now_iso)" || exit 1
  src="$(rows_source "$NOTES")"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rsS --arg kind "$kind" --arg text "$text" --arg at "$now" --rawfile jt "$J_PATH" --arg js "$J_FS" "$JQ_DEFS $JQ_RD $JQ_ROWS $JQ_OPEN"' open_or($js; $jt; rows_in
      | next_id("N") as $id
      | . + [{id: $id, kind: $kind, text: $text, at: $at}]
      | $id, norm)' < "$src" 2>/dev/null)" || die "notes.json for $TARGET is not readable"
  else
    out="$(py note "$J_FS" "$J_PATH" "$kind" "$text" "$now" < "$src" 2>/dev/null)" || die "notes.json for $TARGET is not readable"
  fi
  journey_gate "$out"
  rows_commit "$NOTES" "$out"
  printf '%s\n' "$ROWS_LINE"
}

# ---------------------------------------------------------------------------------------------
# The audit (design B5): files against the baseline, never the caller's account
# ---------------------------------------------------------------------------------------------
# The codes the shell finds itself (steps, tracker): fixed words only, kept as one space list.
CODES=""
code() { CODES="$CODES $1"; }
# hash_or <file> — the file's SHA-256, or the word `unreadable` (never dies).
hash_or() {
  local h
  h="$(file_sha256 "$1" 2>/dev/null)" || h=""
  [ -n "$h" ] || h=unreadable
  printf '%s\n' "$h"
}
# The jq side of the audit's file checks (the python side is op_audit in auto_helpers.py; the two
# are kept line for line alike). See the header for what each code means.
JQ_AUDIT='
  def strs: if type == "array" then map(strings) else null end;
  rd("1"; $jt; false) as $jr
  | (if $jr.ok and ($jr.v | type) == "object" then $jr.v else error("not a journey") end) as $j
  | ($keys | split(" ")) as $keys
  | ($rckeys | split(" ")) as $rckeys
  | ($classes | split(" ")) as $classes
  | [ $extra | split(" ")[] | select(length > 0) ] as $extra
  | (if $bs == "0" then ["baseline-missing"]
     else
       rd($bs; $bt; false) as $b
       | ($b.ok and ($b.v | type) == "object") as $ok
       | (if ($ok | not) or $j.baselineHash != $bhash then ["baseline-changed"] else [] end)
       + (if ($ok | not) then [] else
           $b.v as $base
           | rd($cs; $ct; false) as $c
           | (if $rs == "0" then {ok: true, v: {}} else rd($rs; $rt; false) end) as $r0
           | (if $r0.ok and ($r0.v | type) == "object" then $r0 else {ok: false, v: {}} end) as $r
           | ($base.safety | if type == "object" then . else null end) as $bsaf
           # a baseline that carries `runConfig` recorded the MERGED settings; an earlier one
           # recorded the project config alone and is compared the earlier way
           | ($base | has("runConfig")) as $new
           | ($base.runConfig | if type == "object" then . else null end) as $brc
           | ($base.profile | if type == "string" then . else null end) as $launch
           | (if $new then {ok: ($c.ok and $r.ok), v: merged($c.v; $r.v)} else $c end) as $m
           # the address the journey runs against (only a baseline that recorded it)
           | (if ($base | has("baseUrl") | not) then []
              elif ($m.ok | not) or (look($m.v; "baseUrl").v | if type == "string" then . else null end) != $base.baseUrl
              then ["base-url-changed"] else [] end)
           # the safety settings
           + [ $keys[] | . as $k | look($m.v; $k) as $l
               | select(if ($m.ok | not) or $bsaf == null then true
                        elif $new then
                          (if $k == "profile" and $l.found and $launch != null and eq($l.v; $launch) then false
                           else ($l.found != ($bsaf | has($k))) or ($l.found and (($l.v | odd) or (eq($l.v; $bsaf[$k]) | not))) end)
                        else ($bsaf | has($k) | not) or (eq($l.v; $bsaf[$k]) | not) end)
               | "safety-setting-changed:" + $k ]
           # the run-config of the spec
           + (if $new then
                [ $rckeys[] | . as $k | ($r.v | has($k)) as $found | $r.v[$k] as $v
                  | select(if ($r.ok | not) or $brc == null then true
                           elif $k == "profile" and $found and $launch != null and eq($v; $launch) then false
                           else ($found != ($brc | has($k))) or ($found and (($v | odd) or (eq($v; $brc[$k]) | not))) end)
                  | "run-config-safety:" + $k ]
              else
                ($base.runConfigSafety | if type == "object" then . else null end) as $old
                | [ $keys[] | . as $k | look($r0.v; $k) as $l
                    | select(if ($r0.ok | not) or $old == null then true
                             elif $k == "profile" and $l.found and $launch != null and eq($l.v; $launch) then false
                             else ($l.found != ($old | has($k))) or ($l.found and (eq($l.v; $old[$k]) | not)) end)
                    | "run-config-safety:" + $k ]
              end)
           # the known-defect registry, by its bytes
           + (if (if $kdhash == "" then null else $kdhash end) != $base.knownDefectsHash then ["known-defects-changed"] else [] end)
           # the plan
           + ((if $ps == "0" then {ok: true, v: []} else rd($ps; $pt; false) end) as $pl
              | if ($pl.ok and ($pl.v | type) == "array") | not then ["plan-unreadable"]
                else
                  (($base.humanOracleIds | strs) // []) as $bh
                  | ($base.planRowIds | strs) as $br
                  | ($pl.v | plan_rows) as $rows
                  | ($rows | human_ids) as $ch
                  | ($rows | row_ids) as $cr
                  | (if $br == null then [] else $br - $cr end) as $gone
                  | [ ($ch - $bh)[] | "human-oracle-added:" + . ] + [ $gone[] | "plan-row-removed:" + . ]
                    + [ ($bh - $ch - $gone)[] | "human-oracle-removed:" + . ]
                    + (($base.humanOracleHashes | if type == "object" then . else null end) as $bhh
                       | if $bhh == null then []
                         else [ $rows | human_rows[] | select(.fixture.expect | odd) | .id ] as $oddids
                           | [ ($ch - ($ch - $bh))[] | select(. as $i | ($bhh | has($i)) and (any($oddids[]; . == $i) or $bhh[$i] != $hh[$i]))
                                | "human-oracle-changed:" + . ] end)
                end)
           + (if $seed == "1" and $base.seedExists != true then ["seed-added"] else [] end)
           + (if $es == "0" then []
              else
                rd($es; $et; false) as $e
                | $base.exclusions as $be
                | if ($e.ok | not) then ["exclusion-added"]
                  elif ($be | type) == "array" and ($e.v | type) == "array"
                  then (if any($e.v[]; . as $x | ($x | odd) or all($be[]; eq(.; $x) | not)) then ["exclusion-added"] else [] end)
                  elif ($e.v | odd) or (eq($e.v; $be) | not) then ["exclusion-added"] else [] end
              end)
         end)
     end) as $files
  | (if $ds == "0" then []
     else
       rd($ds; $dt; true) as $d
       | if ($d.ok and ($d.v | type) == "array") | not then ["decisions-unreadable"]
         else [ $d.v | to_entries[] | select(.value | type == "object")
                | select(.value.class as $c | (($c | type) == "string" and any($classes[]; . == $c)) | not)
                | "forbidden-decision:" + (if (.value.id | type) == "string" then .value.id else "#\(.key + 1)" end) ]
         end
     end) as $decided
  # a journey that is done, or whose verify step is, needs a verification that holds a result
  | (if $needv == "1" and (rd($vs; $vt; false) | (.ok and (.v | has_rows)) | not) then ["not-verified"] else [] end) as $verified
  | ($j.state == "stopped" and ($j.stop | type) == "object" and $j.stop.reason == "audit") as $failed
  | ($files + $decided + $verified + $extra + (if $failed then (($j.auditViolations | strs) // []) else [] end) | unique) as $all
  | ($failed or ($all | length) > 0) as $bad
  | "{\"ok\":\($bad | not),\"violations\":\($all | tojson)}",
    (if ($bad | not) then $j + {audit: {ok: true, at: $now}} | norm
     elif $failed and $j.auditViolations == $all then empty
     else
       $j + (if $failed then {} else {state: "stopped", endedAt: $now, stopBeforeAudit: $j.stop} end)
          + {stop: {reason: "audit", detail: ($all | join(", "))}, auditViolations: $all, audit: {ok: false, at: $now}}
       | norm
     end)'
# audit_files — every check that reads the project's files against baseline.json and the journey's
# own record, in one engine call. Prints the result line and then the new journey.json (the shape
# rows_commit takes); only an audit that had already failed and finds the same codes prints no
# journey.
audit_files() {
  local bs bf cs cf rs rf ps pf es ef ds df vs=0 vf=/dev/null bhash="" kdhash="" seed=0 needv=0 now hh=""
  file_state "$BASELINE"; bs="$FS_STATE"; bf="$FS_PATH"
  [ "$bs" = 1 ] && bhash="$(hash_or "$BASELINE")"
  file_state "$CONFIG"; cs="$FS_STATE"; cf="$FS_PATH"
  file_state "$SPEC_DIR/run-config.json"; rs="$FS_STATE"; rf="$FS_PATH"
  file_state "$SPEC_DIR/checklist.json"; ps="$FS_STATE"; pf="$FS_PATH"
  file_state "$SPEC_DIR/coverage-exclusions.json"; es="$FS_STATE"; ef="$FS_PATH"
  file_state "$DECISIONS"; ds="$FS_STATE"; df="$FS_PATH"
  file_state "$QA_DIR/known-defects.json"; [ "$FS_STATE" = 0 ] || kdhash="$(hash_or "$QA_DIR/known-defects.json")"
  file_state "$SPEC_DIR/seed.json"; [ "$FS_STATE" = 0 ] || seed=1
  # A finished journey, or one whose verify step is done, needs the recorded run's verification.
  if [ "$J_STATE" = done ] || [ "$(step_state verify)" = done ]; then
    needv=1
    case "$J_RUN" in ""|.|..|*/*|-*) ;; *) file_state "$QA_DIR/runs/$J_RUN/verification.json"; vs="$FS_STATE"; vf="$FS_PATH" ;; esac
  fi
  now="$(now_iso)" || exit 1
  if [ "$ENGINE" = jq ]; then
    # jq cannot hash: the hashes of the person-confirmed rows as they are now are handed in.
    # (The python side works them out itself, from the same rows.)
    if [ "$bs" = 1 ] && [ "$ps" = 1 ]; then hh="$(plan_hashes "$pf")" || hh=""; fi
    [ -n "$hh" ] || hh="{}"
    jq -rnS --argjson hh "$hh" --rawfile jt "$JOURNEY" --rawfile bt "$bf" --rawfile ct "$cf" --rawfile rt "$rf" --rawfile pt "$pf" \
      --rawfile et "$ef" --rawfile dt "$df" --rawfile vt "$vf" --arg bs "$bs" --arg cs "$cs" --arg rs "$rs" --arg ps "$ps" --arg es "$es" \
      --arg ds "$ds" --arg vs "$vs" --arg bhash "$bhash" --arg kdhash "$kdhash" --arg seed "$seed" --arg needv "$needv" --arg now "$now" \
      --arg keys "$SAFETY_KEYS" --arg rckeys "$RC_KEYS" --arg classes "$DECIDABLE_CLASSES" --arg extra "$CODES" \
      "$JQ_DEFS $JQ_RD $JQ_VRES $JQ_PLAN $JQ_AUDIT" 2>/dev/null
  else
    py audit "$JOURNEY" "$bs" "$bf" "$cs" "$cf" "$rs" "$rf" "$ps" "$pf" "$es" "$ef" "$ds" "$df" "$vs" "$vf" \
      "$bhash" "$kdhash" "$seed" "$needv" "$now" "$SAFETY_KEYS" "$RC_KEYS" "$DECIDABLE_CLASSES" "$CODES" 2>/dev/null
  fi
}
# audit_steps — a step marked done whose result is not on disk. A step the journey never reached
# is not looked at. (A finished journey nobody verified is found by audit_files.)
audit_steps() {
  local s
  for s in constitution spec scenarios analyze run; do
    [ "$(step_state "$s")" = done ] || continue
    step_artifact_done "$s" "$J_RUN" || code "step-without-result:$s"
  done
}
# tracker_answer <output> — what the tracker's `spec-status` output says: `ok`, `behind` or `none`.
#   - a JSON line with a `behind` key decides: `ok` when every such value is the boolean false,
#     `behind` for anything else (true, a word, a number);
#   - without one, `ok` only for the tracker's own not-set-up answer, which is EXACTLY
#     `SKIP<TAB>not-set-up<TAB>…` on the first line, alone or followed by one `SUMMARY …` line,
#     or one JSON object, alone, with `"setUp": false`;
#   - any other output is `none`.
tracker_answer() {
  local out="$1" first rest verdict tab="	"
  case "$out" in
    *'"behind"'*|*'"setUp"'*)
      if [ "$ENGINE" = jq ]; then
        verdict="$(printf '%s\n' "$out" | jq -Rrn '[ inputs ] as $lines
          | [ $lines[] | (try fromjson catch null) | objects ] as $objs
          | [ $objs[] | select(has("behind")) | .behind ] as $seen
          | if ($seen | length) > 0 then (if all($seen[]; . == false) then "ok" else "behind" end)
            elif ([ $lines[] | select(test("[^ \t\r]")) ] | length) == 1 and ($objs | length) == 1 and $objs[0].setUp == false then "ok"
            else "none" end' 2>/dev/null)" || verdict=none
      else
        verdict="$(printf '%s\n' "$out" | py behind 2>/dev/null)" || verdict=none
      fi
      case "$verdict" in ok|behind) printf '%s\n' "$verdict" ;; *) echo none ;; esac
      return 0 ;;
  esac
  first="${out%%"$NL"*}"
  rest=""; case "$out" in *"$NL"*) rest="${out#*"$NL"}" ;; esac
  case "$first" in
    "SKIP${tab}not-set-up${tab}"*)
      case "$rest" in ""|"SUMMARY "*) case "$rest" in *"$NL"*) ;; *) echo ok; return 0 ;; esac ;; esac ;;
  esac
  echo none
}
# audit_tracker — ask the tracker whether the spec's cards are behind. Only its exit code and its
# stdout are used; its stderr is dropped, because it can carry an API error line. The command is
# the tracker script beside this one. `QA_AUTO_TRACKER_CMD` replaces it only when `QA_AUTO_TEST=1`
# is also set (the suites set both); in a real journey the variable is ignored.
audit_tracker() {
  local out rc guard="" secs="${QA_AUTO_TRACKER_TIMEOUT:-60}"
  # Without the project's tracker settings no spec is tracked (the machine file cannot turn
  # tracking on), so the tracker is not asked at all.
  if [ ! -e "$PROJECT/docs/agents/qa-tracker.json" ] && [ ! -L "$PROJECT/docs/agents/qa-tracker.json" ]; then return 0; fi
  case "$secs" in ""|*[!0-9]*) secs=60 ;; esac
  # A time guard only where one is installed (macOS has no `timeout` of its own).
  if command -v timeout >/dev/null 2>&1; then guard=timeout
  elif command -v gtimeout >/dev/null 2>&1; then guard=gtimeout; fi
  if [ "${QA_AUTO_TEST:-}" = 1 ] && [ -n "${QA_AUTO_TRACKER_CMD+x}" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- $QA_AUTO_TRACKER_CMD
    set +f
  else
    set -- bash "$SCRIPT_DIR/tracker.sh"
  fi
  if [ "$#" -eq 0 ]; then code tracker-behind; return 0; fi
  if [ -n "$guard" ]; then
    out="$("$guard" "$secs" "$@" spec-status --spec "$TARGET" --project "$PROJECT" 2>/dev/null </dev/null)"; rc=$?
  else
    out="$("$@" spec-status --spec "$TARGET" --project "$PROJECT" 2>/dev/null </dev/null)"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then code tracker-behind; return 0; fi
  [ "$(tracker_answer "$out")" = ok ] || code tracker-behind
}

cmd_audit() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "audit does not take: ${REST[0]}"
  need_engine
  [ -f "$JOURNEY" ] || die "no journey for $TARGET"
  journey_read
  in_list "$J_STATE" "open done stopped" || die "journey.json for $TARGET is not readable"
  CODES=""
  audit_steps
  audit_tracker
  local out
  out="$(audit_files)" && [ -n "$out" ] || die "journey.json for $TARGET is not readable"
  # The audit leaves its record in the journey: `audit: {ok, at}`. A failed audit also closes the
  # journey as stopped / audit. Nothing else changes on a pass.
  rows_commit "$JOURNEY" "$out"
  printf '%s\n' "$ROWS_LINE"
  case "$ROWS_LINE" in '{"ok":true,'*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------------------------
# The handoff (design B6): what a person reads at the end, worked out from files only
# ---------------------------------------------------------------------------------------------
NL='
'
US="$(printf '\037')"
# The jq side of the handoff facts (the python side is op_facts in auto_helpers.py; the two are
# kept alike). One fact per line, fields split by U+001F, every text made one line by `clean`:
#   S <file> <ok|absent|bad>      decisions, notes, plan, results (checkpoint.json), second
#                                 (verification.json; also `override`: a row that is not about a
#                                 recorded non-pass does not say pass)
#   J <1|0> <1|0>                 the journey was restarted; the journey it replaced had failed its audit
#   V <code word> <text>          one audit violation; the text is its key, step, check title or question
#   D <step> <class> <needs 1|0> <a top priority check rests on it 1|0> <no evidence 1|0> <question> <answer> <evidence>
#   O <top priority 1|0> <title>            an expected value that is only a proposal
#   L <top priority 1|0> <title> <persona>  a check that passed at low confidence
#   P <persona id>                sign-in is not set up
#   N <kind> <text>               a note
#   R <type> <id>                 a record the run created
JQ_HANDOFF='
  def b: if . then "1" else "0" end;
  def clean: if type == "string"
    then (explode | map(if . < 32 or (. >= 127 and . < 160) then 32 else . end) | implode | gsub(" +"; " ") | sub("^ "; "") | sub(" $"; ""))
    else "" end;
  def low: if type == "string" then ascii_downcase else "" end;
  def isverdict: . == "pass" or . == "fail" or . == "blocked" or . == "deferred" or . == "error";
  def rows_of($keys): . as $d
    | if type == "array" then . elif type == "object" then (first($keys[] | $d[.] | select(type == "array")) // null) else null end;
  def cid: first((.criterion_id, .criterionId, .id) | select(type == "string" and length > 0)) // null;
  def who: .persona | if type == "string" then . else "" end;
  def rtext: if type == "string" then clean elif type == "number" then (. + 0 | tojson) else "" end;
  rd("1"; $jt; false) as $jr
  | (if $jr.ok and ($jr.v | type) == "object" then $jr.v else error("not a journey") end) as $j
  | rd($ds; $dt; true) as $d | rd($ns; $nt; true) as $n | rd($ps; $pt; false) as $p | rd($cs; $ct; false) as $c
  | rd($ks; $kt; false) as $k | rd($vs; $vt; false) as $v | rd($rs; $rt; true) as $r | rd($ys; $yt; false) as $y
  # the plan: of two rows with one id the first counts
  | (reduce ((if $p.ok and ($p.v | type) == "array" then $p.v else [] end)[] | select(type == "object" and (.id | type) == "string")) as $x
       ({ids: [], by: {}}; if (.by | has($x.id)) then . else (.ids += [$x.id] | .by[$x.id] = $x) end)) as $plan
  # the title of a check: the cards file, else the row itself, else its id
  | (reduce ((if $c.ok and ($c.v | type) == "object" and ($c.v.cards | type) == "array" then $c.v.cards else [] end)[]
             | select(type == "object") | .checks | select(type == "array") | .[]
             | select(type == "object" and (.criterion | type) == "string" and (.title | clean) != "")) as $x
       ({}; if has($x.criterion) then . else .[$x.criterion] = ($x.title | clean) end)) as $titles
  # top priority, failing closed: a row of the plan marked P1, a row with no priority, a step of a
  # P1 journey of the run, and any id the plan does not have
  | (reduce ((if $y.ok and ($y.v | type) == "array" then $y.v else [] end)[]
             | select(type == "object" and .priority == "P1" and (.steps | type) == "array") | .steps[]
             | (if type == "object" then .criterionId else . end) | strings) as $s ({}; .[$s] = true)) as $jp1
  | def title: . as $i
      | if ($titles | has($i)) then $titles[$i]
        else (if ($plan.by | has($i)) then ($plan.by[$i] | (.title | clean) as $t | if $t != "" then $t else (.label | clean) end) else "" end) as $t
             | if $t != "" then $t else ($i | clean) end
        end;
    def p1: . as $i
      | if ($plan.by | has($i)) then (($plan.by[$i].priority | (type != "string" or . == "P1")) or ($jp1 | has($i))) else true end;
    (if $ds == "0" then "absent" elif $d.ok and ($d.v | type) == "array" then "ok" else "bad" end) as $dstat
  | (if $dstat == "ok" then [ $d.v[] | select(type == "object") ] else [] end) as $decs
  | (if $ns == "0" then "absent" elif $n.ok and ($n.v | type) == "array" then "ok" else "bad" end) as $nstat
  | (if $ps == "0" then "absent" elif $p.ok and ($p.v | type) == "array" then "ok" else "bad" end) as $pstat
  | (if $k.ok then ($k.v | rows_of(["criteria"])) else null end) as $krows
  | (if $ks == "0" then "absent" elif $krows != null then "ok" else "bad" end) as $kstat
  | (if $v.ok then ($v.v | rows_of(["rows", "criteria"])) else null end) as $vrows
  # the second check: `override` when a row that is not about a recorded non-pass does not say pass
  | (if $vs == "0" then "absent"
     elif $vrows == null or any($vrows[]; type != "object") then "bad"
     elif any($vrows[]; (.inRunVerdict | low) as $in
                | (($in == "fail" or $in == "blocked" or $in == "deferred" or $in == "error") | not) and ((.verifierVerdict | low) != "pass"))
     then "override" else "ok" end) as $vstat
  # expected values that are only a proposal: a calculated check, or any check that names a source,
  # whose source is neither a person nor a cited spec line
  | ($plan.ids | map(select(. as $i | $plan.by[$i] as $x
        | (if ($x.fixture | type) == "object" and ($x.fixture.expect | type) == "object" then $x.fixture.expect.oracleSource else null end) as $src
        | (($x.kind == "computed-logic" or $x.kind == "business-rule") or $src != null) and $src != "human" and $src != "spec"))) as $oids
  | (reduce $oids[] as $i ({}; .[$i] = true)) as $oset
  # checks that passed at low confidence: the latest record of each check and role, after the
  # second check; a confidence is never read as better than either file says
  | (reduce (($vrows // [])[] | select(type == "object") | select(cid != null and (.verifierVerdict | type) == "string")) as $x
       ({}; .[[($x | cid), ($x | who)] | tojson] = $x)) as $ov
  | (reduce (($krows // [])[] | select(type == "object") | select(cid != null)) as $x
       ({keys: [], by: {}}; ([($x | cid), ($x | who)] | tojson) as $key
          | (if (.by | has($key)) then . else .keys += [$key] end) | .by[$key] = $x)) as $cp
  | [ ["S", "decisions", $dstat], ["S", "notes", $nstat], ["S", "plan", $pstat], ["S", "results", $kstat], ["S", "second", $vstat],
      ["J", ($j.restartedFrom != null | b), ($j.replacedAfterAudit == true | b)],
      # what the audit found: the code word, and its key, step, check title or question
      ( ($j.auditViolations | if type == "array" then .[] else empty end) | strings
        | split(":") as $parts | ($parts[0] // "") as $w | ($parts[1:] | join(":")) as $arg
        | ["V", ($w | clean),
           (if $w == "human-oracle-added" or $w == "human-oracle-removed" or $w == "human-oracle-changed" or $w == "plan-row-removed" then ($arg | title)
            elif $w == "forbidden-decision" then ((first($decs[] | select(.id == $arg) | .question) // null) | clean)
            else ($arg | clean) end)] ),
      # decisions: needs a person, and whether a top priority check rests on it (no checks named
      # means the whole spec)
      ( $decs[] | needs_person as $needs
        | [ (.criteria | if type == "array" then .[] else empty end) | strings ] as $ids
        | ($needs and (($ids | length) == 0 or any($ids[]; p1))) as $rests
        | ["D", (.step | clean), (.class | clean), ($needs | b), ($rests | b), (.evidence == null | b),
           (.question | clean), (.answer | clean), (.evidence | clean)] ),
      ( $oids[] | ["O", (p1 | b), title] ),
      ( $cp.keys[] as $key | $cp.by[$key] as $x | ($x | cid) as $i | ($x | who) as $persona
        | ($x.verdict | low) as $v0 | ($ov[$key] // null) as $o
        | ($o != null and $o.inRunVerdict == $v0) as $applies
        | (if $applies and ($o.verifierVerdict | isverdict) then $o.verifierVerdict else $v0 end) as $verdict
        | ($x.confidence != "high"
           or ($applies and ($o.confidence | type) == "string" and $o.confidence != "" and $o.confidence != "high")) as $lowc
        | select($verdict == "pass" and $lowc and ($oset | has($i) | not))
        | ["L", ($i | p1 | b), ($i | title), ($persona | clean)] ),
      ( (try ($signin | fromjson) catch null) | (if type == "object" then .missing else null end)
        | (if type == "array" then .[] else empty end) | strings | ["P", clean] ),
      ( (if $nstat == "ok" then $n.v else [] end)[] | select(type == "object" and (.text | clean) != "") | ["N", (.kind | clean), (.text | clean)] ),
      ( (if $r.ok and ($r.v | type) == "array" then $r.v else [] end)[] | select(type == "object") | [(.entity | rtext), (.id | rtext)]
        | select(.[0] != "" or .[1] != "") | ["R", .[0], .[1]] )
    ] | .[] | join("\u001f")'
# The jq side of `head` (the python side is op_head). Lines: the journey state, its stop reason,
# its launch profile, its run id, the stop it had before a failed audit, how many times it was
# resumed, 1|0 it replaced an earlier journey, its audit (1 passed, 2 failed, 0 none: no record, or
# one older than the last change to its steps); then 1 or 0 (the project config is one JSON object); then, after a 1, the
# lines signin_from reads (the storageState, then one line per persona).
JQ_HANDOFF_HEAD='
  def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
  def s2: if type == "string" then gsub("[\r\n\t]"; " ") else "" end;
  ($jt | ltrimstr("\ufeff") | fromjson) as $j
  | (if ($j | type) == "object" then $j else error("not a journey") end) as $j
  | ($j.stop | if type == "object" then . else {} end) as $st
  | ($j.stopBeforeAudit | if type == "object" then . else {} end) as $sb
  | ($j.state | s), ($st.reason | s), ($j.profile | s), ($j.runId | s), ($sb.reason | s),
    ($j.resumes | if type == "array" then length else 0 end | tostring),
    (if $j.replacedFrom != null then "1" else "0" end),
    (if ($j.audit | type) == "object" and ($j.audit.at | type) == "string"
        and (($j.stepsChangedAt | type) != "string" or $j.audit.at >= $j.stepsChangedAt)
     then (if $j.audit.ok == true then "1" elif $j.audit.ok == false then "2" else "0" end) else "0" end),
    ((if $cs == "1" then (try ($ct | ltrimstr("\ufeff") | fromjson) catch null) else null end) as $c
     | if ($c | type) != "object" then "0"
       else "1", (($c.auth | if type == "object" then .storageState else null end) | s2),
            (($c.personas | if type == "array" then .[] else empty end)
             | select(type == "object" and (.id | type) == "string") | "\(.id | tojson)\t\(.auth | s2)") end)'
# handoff_head — the journey and the sign-in facts of the config, in one engine call.
handoff_head() {
  file_state "$CONFIG"
  if [ "$ENGINE" = jq ]; then
    jq -rn --rawfile jt "$JOURNEY" --rawfile ct "$FS_PATH" --arg cs "$FS_STATE" "$JQ_HANDOFF_HEAD" 2>/dev/null
  else
    py head "$JOURNEY" "$FS_STATE" "$FS_PATH" 2>/dev/null
  fi
}
# handoff_facts <run id or empty> <records file or empty> <sign-in line or empty> — every fact the
# handoff is written from, in one engine call (the lines JQ_HANDOFF describes).
handoff_facts() {
  local run="$1" records="$2" signin="$3" ds df ns nf ps pf cs cf ks=0 kf=/dev/null vs=0 vf=/dev/null rs=0 rf=/dev/null ys=0 yf=/dev/null
  file_state "$DECISIONS"; ds="$FS_STATE"; df="$FS_PATH"
  file_state "$NOTES"; ns="$FS_STATE"; nf="$FS_PATH"
  file_state "$SPEC_DIR/checklist.json"; ps="$FS_STATE"; pf="$FS_PATH"
  file_state "$SPEC_DIR/tracker-cards.json"; cs="$FS_STATE"; cf="$FS_PATH"
  if [ -n "$run" ]; then
    file_state "$QA_DIR/runs/$run/checkpoint.json"; ks="$FS_STATE"; kf="$FS_PATH"
    file_state "$QA_DIR/runs/$run/verification.json"; vs="$FS_STATE"; vf="$FS_PATH"
    file_state "$QA_DIR/runs/$run/journeys.json"; ys="$FS_STATE"; yf="$FS_PATH"
  fi
  if [ -n "$records" ]; then file_state "$records"; rs="$FS_STATE"; rf="$FS_PATH"; fi
  if [ "$ENGINE" = jq ]; then
    jq -rn --rawfile jt "$JOURNEY" --rawfile dt "$df" --rawfile nt "$nf" --rawfile pt "$pf" --rawfile ct "$cf" --rawfile kt "$kf" \
      --rawfile vt "$vf" --rawfile rt "$rf" --rawfile yt "$yf" --arg ds "$ds" --arg ns "$ns" --arg ps "$ps" --arg cs "$cs" \
      --arg ks "$ks" --arg vs "$vs" --arg rs "$rs" --arg ys "$ys" --arg signin "$signin" "$JQ_RD $JQ_NEEDS $JQ_HANDOFF" 2>/dev/null
  else
    py facts "$JOURNEY" "$ds" "$df" "$ns" "$nf" "$ps" "$pf" "$cs" "$cf" "$ks" "$kf" "$vs" "$vf" "$rs" "$rf" "$ys" "$yf" "$signin" 2>/dev/null
  fi
}
# ship_read <report.md> — the engine's ship verdict as it rendered it into the run's report, never
# worked out here. Sets SHIP to `ready`, `notready`, `none` (the report has no "## Ship readiness"
# section) or `odd` (no report, a section that is not in the engine's shape, or more than one
# section), and SHIP_WHY to the plain words of the listed conditions (one per line). The heading
# and the verdict line are matched at the start of the line, as scripts/render-report.js writes
# them; a section that says NOT SHIP-READY anywhere, or lists a condition, is never read as ready
# (the rules of `ready` in trackers/spec_runs.py). Pure bash, so both engines agree.
SHIP=none; SHIP_WHY=""
S_OPEN=0; S_NOT=0; S_HEAD=""; S_PHASE=""; S_CONDS=""; SHIP_NOT=0; SHIP_READY_N=0; SHIP_SECTIONS=0
ship_close() {
  [ "$S_OPEN" -eq 1 ] || return 0
  SHIP_SECTIONS=$((SHIP_SECTIONS + 1))
  if [ "$S_HEAD" = ok ]; then
    if [ "$S_NOT" -eq 1 ] || [ -n "$S_CONDS" ]; then SHIP_NOT=1; SHIP_WHY="$SHIP_WHY$S_CONDS"; else SHIP_READY_N=$((SHIP_READY_N + 1)); fi
  elif [ "$S_NOT" -eq 1 ]; then SHIP_NOT=1
  fi
  S_OPEN=0
}
# ship_clause <condition> — an engine ship condition (scripts/render-report.js buildShip) in plain
# words; first match wins. The engine's own text, and any id in it, is never shown.
ship_clause() {
  case "$1" in
    *"census surface(s) uncovered") echo "some screens have not been checked yet" ;;
    "census is empty"|"census coverage unknown"|"census adapter failed") echo "the list of screens to check is not complete" ;;
    "no P1 journeys declared") echo "no main user journey is listed for this run" ;;
    "P1 journey "*) echo "a main user journey did not pass" ;;
    "coding-layer fail on P1 "*|"fail on P1 with unknown layer "*) echo "a top priority check failed" ;;
    "not independently verified") echo "the results have not had their second check yet" ;;
    "verifier override on P1 "*) echo "the second check did not confirm a top priority result" ;;
    "verification out of date on P1 "*) echo "the second check is out of date for a top priority result" ;;
    "verifier disputed P1 "*) echo "a reviewer did not confirm a top priority result" ;;
    *"P1 low-confidence pass(es) not re-judged"*|*"P1 low-confidence pass(es) unreviewed"*) echo "a top priority result still needs a person to confirm it" ;;
    "re-adjudication decision on P1 "*" was not applied") echo "a review of a top priority result was not recorded" ;;
    "adjudication/decisions.json is not a JSON array") echo "the review of the results could not be read" ;;
    *) echo "another condition is not met (see the report of the run)" ;;
  esac
}
ship_read() {
  local LC_ALL=C line t clause re='^#{1,6}([[:space:]]|$)'
  SHIP=none; SHIP_WHY=""; S_OPEN=0; SHIP_NOT=0; SHIP_READY_N=0; SHIP_SECTIONS=0
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then SHIP=odd; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    t="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" =~ $re ]]; then
      ship_close
      if [ "$t" = "## Ship readiness" ]; then S_OPEN=1; S_NOT=0; S_HEAD=""; S_PHASE=head; S_CONDS=""; fi
      continue
    fi
    [ "$S_OPEN" -eq 1 ] || continue
    case "$line" in *"NOT SHIP-READY"*) S_NOT=1 ;; esac
    case "$S_PHASE" in
      head)
        [ -n "$t" ] || continue
        case "$t" in
          '**SHIP-READY**'|'**NOT SHIP-READY**') S_HEAD=ok; S_PHASE=conds ;;
          *) S_HEAD=bad; S_PHASE=end ;;
        esac ;;
      conds)
        if [ -z "$t" ]; then
          [ -z "$S_CONDS" ] || S_PHASE=end
        elif [ -z "$S_CONDS" ] && { [ "$t" = '**SHIP-READY**' ] || [ "$t" = '**NOT SHIP-READY**' ]; }; then
          :
        elif [ "${t#- }" != "$t" ]; then
          t="${t#- }"; t="${t#"${t%%[![:space:]]*}"}"
          clause="$(ship_clause "$t")"
          case "$NL$SHIP_WHY$S_CONDS" in *"$NL$clause$NL"*) [ -n "$S_CONDS" ] || S_CONDS="$NL" ;; *) S_CONDS="$S_CONDS$clause$NL" ;; esac
        else
          S_PHASE=end
        fi ;;
    esac
  done < "$1"
  ship_close
  if [ "$SHIP_NOT" -eq 1 ]; then SHIP=notready
  elif [ "$SHIP_SECTIONS" -eq 0 ]; then SHIP=none
  elif [ "$SHIP_SECTIONS" -eq 1 ] && [ "$SHIP_READY_N" -eq 1 ]; then SHIP=ready
  else SHIP=odd; fi
}
# stop_plain <J2 reason> — why a journey stopped, in plain words (empty for an unknown reason).
stop_plain() {
  case "$1" in
    time-limit)  echo "the time limit was reached" ;;
    step-failed) echo "a step could not be completed" ;;
    until)       echo "it was asked to stop before the run" ;;
    blocked)     echo "coverage could not be reached" ;;
    audit)       echo "a limit was broken" ;;
    no-sign-in)  echo "no role has sign-in set up" ;;
    tracker)     echo "ClickUp could not be updated" ;;
  esac
}
# step_plain <step> — a step's name for people (empty for anything that is not a step).
step_plain() {
  case "$1" in
    constitution) echo "project rules" ;;
    spec)         echo "spec" ;;
    scenarios)    echo "scenarios" ;;
    analyze)      echo "analysis" ;;
    run)          echo "run" ;;
    verify)       echo "verification" ;;
  esac
}
# violation_plain <code word> <text> — one audit violation as a sentence. The text is what
# handoff_facts found for the part after the colon: a setting name, a check title, a question.
violation_plain() {
  local s="" a="$2"
  case "$1" in
    baseline-missing)       s="The record of the starting settings is missing."; a="" ;;
    baseline-changed)       s="The record of the starting settings was changed during the journey."; a="" ;;
    base-url-changed)       s="The address of the application under test was changed during the journey."; a="" ;;
    safety-setting-changed) s="A safety setting was changed during the journey" ;;
    run-config-safety)      s="A safety setting was changed in the run settings of this spec" ;;
    known-defects-changed)  s="The list of known defects was changed during the journey."; a="" ;;
    human-oracle-added)     s="An expected result was marked as confirmed by a person during the journey" ;;
    human-oracle-removed)   s="An expected result that a person had confirmed is no longer marked as confirmed" ;;
    human-oracle-changed)   s="An expected result that a person had confirmed was changed" ;;
    plan-row-removed)       s="A check from the starting plan was removed" ;;
    plan-unreadable)        s="The plan of checks could not be read."; a="" ;;
    seed-added)             s="A data setup command was added during the journey."; a="" ;;
    exclusion-added)        s="A screen was left out of coverage during the journey."; a="" ;;
    forbidden-decision)     s="A decision was recorded that this journey may not make" ;;
    decisions-unreadable)   s="The record of decisions could not be read."; a="" ;;
    step-without-result)    s="A step was marked as done without its result"; a="$(step_plain "$a")"; [ -z "$a" ] || a="the $a step" ;;
    not-verified)           s="The run was not verified."; a="" ;;
    tracker-behind)         s="ClickUp is behind the results."; a="" ;;
    *)                      s="A limit was broken; see the journey record."; a="" ;;
  esac
  case "$s" in
    *.) printf '%s\n' "$s" ;;
    *)  if [ -n "$a" ]; then printf '%s: %s\n' "$s" "$a"; else printf '%s.\n' "$s"; fi ;;
  esac
}

# cmd_handoff — writes auto/handoff.md and prints {"result":…,"needsPerson":n}. It reads files only,
# changes no other file and never the journey's state, and may run on any journey, any number of
# times (the last write wins). THE RESULT is never better than what the engine recorded:
#   stopped        the journey's state is `stopped`, for any reason (the audit included)
#   not verified   the journey is still open; or its audit has not run (no `audit` record in
#                  journey.json, one that did not pass, or one older than the last change to the
#                  journey's steps: `The audit has not run for this journey.`), whatever the run's
#                  files say; or it has no run; or a file the result is decided from cannot be read
#                  (see below); or, with no ship verdict in the report, the run has no
#                  verification.json or it records a pass that verification did not leave a pass
#   not ready      the run's report says NOT SHIP-READY (ship_read), with its conditions in plain words
#   verified       the report has no ship section, the journey was not launched as `ship`, and
#                  verification.json is there, readable and records no such override
#   not confirmed  the report says SHIP-READY and a top priority check rests on a person: a
#                  decision that needs a person (JQ_NEEDS) and names no check, or names a top
#                  priority check; or a top priority expected value that is only a proposal
#   ready          the report says SHIP-READY and none of that holds, and verification.json records
#                  no override (a pass that verification did not leave a pass is `not verified`)
# Under a SHIP-READY report the result is `not verified` when verification.json is absent or
# unreadable, or checkpoint.json, decisions.json (when there is one) or the plan cannot be read.
# The first sentence of the Result section is the fixed sentence of the result; whenever items
# wait for a person their count follows it (`Verified. 3 items need a person.`), except after
# `Not confirmed: <n> items need a person.`, which already says it. Further sentences: one when the
# journey was restarted (`restartedFrom`), one when it took the place of an earlier journey
# (`replacedFrom`), one when that earlier journey had stopped for `audit` (`replacedAfterAudit`),
# one when it was continued after stopping (`resumes`, with how many times). The last line of "How
# to confirm" names the command that works next: `/qa-auto <target>` after a finished journey,
# `/qa-auto <target> --restart` after any other (a plain start is refused there); a journey that
# can be resumed also gets the line that continues it.
cmd_handoff() {
  parse_common "$@"
  local records=""
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --records) [ "$#" -ge 2 ] || usage "--records needs a file"; records="$2"; shift 2 ;;
      *) usage "handoff does not take: $1" ;;
    esac
  done
  need_engine
  [ -f "$JOURNEY" ] || die "no journey for $TARGET"
  local facts v state="" reason="" profile="" run="" before="" resumes=0 replaced=0 audited=0 cfgok=0 signin=""
  facts="$(handoff_head)" && [ -n "$facts" ] || die "journey.json for $TARGET is not readable"
  for v in state reason profile run before resumes replaced audited cfgok; do
    printf -v "$v" '%s' "${facts%%"$NL"*}"
    case "$facts" in *"$NL"*) facts="${facts#*"$NL"}" ;; *) facts="" ;; esac
  done
  one_of "$state" "open done stopped" || die "journey.json for $TARGET is not readable"
  case "$resumes" in ""|*[!0-9]*) resumes=0 ;; esac
  # A run id is one plain directory name; anything else is no run.
  case "$run" in ""|.|..|*/*|-*) run="" ;; esac
  # Personas whose sign-in is not set up (nothing is said about them when the config cannot be read).
  [ "$cfgok" != 1 ] || signin="$(signin_from "$facts")"
  facts="$(handoff_facts "$run" "$records" "$signin")" && [ -n "$facts" ] || die "journey.json for $TARGET is not readable"

  # ---- read the facts ----
  local k f1 f2 f3 f4 f5 f6 f7 f8 item
  local dstat=absent nstat=absent pstat=absent kstat=absent vstat=absent restarted=0 after_audit=0
  local viol="" scope="" needs="" recs="" count=0 noev=0 p1pending=0 counted=0
  local d_constitution="" d_spec="" d_scenarios="" d_analyze="" d_run="" d_verify="" d_other=""
  while IFS="$US" read -r k f1 f2 f3 f4 f5 f6 f7 f8; do
    case "$k" in
      S) case "$f1" in
           decisions) dstat="$f2" ;; notes) nstat="$f2" ;; plan) pstat="$f2" ;; results) kstat="$f2" ;; second) vstat="$f2" ;;
         esac ;;
      J) restarted="$f1"; after_audit="$f2" ;;
      V) viol="$viol- $(violation_plain "$f1" "$f2")$NL" ;;
      D) # step class needs rests no-evidence question answer evidence
         [ "$f5" = 1 ] && noev=1
         [ -n "$f8" ] || f8="nothing written"
         item="- Asked: $f6; decided: $f7; based on: $f8$NL"
         case "$f1" in
           constitution) d_constitution="$d_constitution$item" ;; spec) d_spec="$d_spec$item" ;;
           scenarios) d_scenarios="$d_scenarios$item" ;; analyze) d_analyze="$d_analyze$item" ;;
           run) d_run="$d_run$item" ;; verify) d_verify="$d_verify$item" ;; *) d_other="$d_other$item" ;;
         esac
         [ "$f2" = scope ] && scope="$scope- $f7$NL"
         if [ "$f3" = 1 ]; then
           needs="$needs- Decision to confirm. Asked: $f6; decided: $f7$NL"; count=$((count + 1))
           [ "$f4" = 1 ] && p1pending=1
         fi ;;
      O) needs="$needs- Expected result to confirm: $f2$NL"; count=$((count + 1))
         [ "$f1" = 1 ] && p1pending=1 ;;
      L) if [ -n "$f3" ]; then needs="$needs- Passed with low confidence: $f2 (as $f3)$NL"; else needs="$needs- Passed with low confidence: $f2$NL"; fi
         count=$((count + 1)) ;;
      P) needs="$needs- Sign-in is not set up for this role: $f1$NL"; count=$((count + 1)) ;;
      N) case "$f1" in
           seed-not-run)   needs="$needs- A data setup command was proposed and not run: $f2$NL" ;;
           check-left-out) needs="$needs- A check was left out because it expects the application to fail: $f2$NL" ;;
           *)              needs="$needs- $f2$NL" ;;
         esac
         count=$((count + 1)) ;;
      R) if [ -z "$f1" ]; then recs="$recs- $f2$NL"; elif [ -z "$f2" ]; then recs="$recs- $f1$NL"; else recs="$recs- $f1: $f2$NL"; fi ;;
    esac
  done <<EOT
$facts
EOT
  # A file that cannot be read is itself something a person has to look at.
  if [ "$dstat" = bad ]; then needs="$needs- The record of decisions could not be read.$NL"; count=$((count + 1)); fi
  if [ "$nstat" = bad ]; then needs="$needs- The notes of this journey could not be read.$NL"; count=$((count + 1)); fi
  if [ -n "$run" ] && [ "$pstat" != ok ]; then needs="$needs- The plan of checks could not be read.$NL"; count=$((count + 1)); fi
  if [ -n "$run" ] && [ "$kstat" != ok ]; then needs="$needs- The results of the run could not be read.$NL"; count=$((count + 1)); fi

  # ---- the result (see the rule above) ----
  local result="not verified" line="Not verified." why="" clause no_audit="The audit has not run for this journey."
  if [ "$state" = stopped ]; then
    result=stopped
    clause="$(stop_plain "$reason")"
    [ -n "$clause" ] || clause="the reason was not recorded"
    line="Stopped: $clause."
    # a stop stays a stop; the sentence is still said when no audit looked at this journey
    if [ "$audited" = 0 ] && [ "$reason" != audit ]; then why="$no_audit"; fi
  elif [ "$state" = open ]; then
    why="This journey has not finished."
    [ "$audited" = 1 ] || why="$why$NL$NL$no_audit"
  elif [ "$audited" != 1 ]; then
    # No audit record, a failed one, or one older than the last change to the steps: whatever the
    # run's files say, nobody checked the limits of this journey, so the result is never better.
    why="$no_audit"
  elif [ -z "$run" ]; then
    why="This journey has no run."
  else
    ship_read "$QA_DIR/runs/$run/report.md"
    case "$SHIP" in
      notready)
        result="not ready"; clause=""
        while IFS= read -r k; do
          [ -n "$k" ] || continue
          clause="$clause; $k"
        done <<EOT
$SHIP_WHY
EOT
        [ -n "$clause" ] || clause="; the report does not say why"
        line="Not ready: ${clause#; }." ;;
      odd)
        why="The readiness result in the report of the run could not be read." ;;
      none)
        if [ "$profile" = ship ]; then why="The report of the run has no readiness result."
        elif [ "$kstat" != ok ]; then why="The results of the run could not be read."
        elif [ "$vstat" = absent ]; then why="The results have not had their second check."
        elif [ "$vstat" = override ]; then why="The second check did not confirm every passed result."
        elif [ "$vstat" != ok ]; then why="The second check could not be read."
        else result=verified; line="Verified."; fi ;;
      ready)
        if [ "$vstat" = absent ]; then why="The results have not had their second check."
        elif [ "$vstat" = bad ]; then why="The second check could not be read."
        # a pass the second check did not leave a pass is never ready, whatever the report says
        elif [ "$vstat" = override ]; then why="The second check did not confirm every passed result."
        elif [ "$kstat" != ok ]; then why="The results of the run could not be read."
        elif [ "$dstat" = bad ] || [ "$pstat" != ok ]; then why="The decisions or the plan of checks could not be read."
        elif [ "$p1pending" -eq 1 ]; then result="not confirmed"; line="Not confirmed: $count items need a person."; counted=1
        else
          result=ready; line="Ready."
          [ "$count" -eq 0 ] || why="Some items still need a person. They are listed below, and none rests on a top priority check."
        fi ;;
    esac
  fi

  # The count goes with every result, after its fixed sentence (`Verified. 3 items need a person.`);
  # `not confirmed` already says it.
  if [ "$count" -gt 0 ] && [ "$counted" -eq 0 ]; then line="$line $count items need a person."; fi

  # ---- the file: blocks separated by one empty line ----
  local out="" decided=""
  [ "$noev" -eq 0 ] || out="No written requirements were found for this target. Expected results were taken from the application and need a person.$NL$NL"
  out="$out## Result$NL$NL$line"
  if [ "$state" = stopped ] && [ "$reason" = audit ]; then
    [ -z "$viol" ] || out="$out$NL$NL${viol%"$NL"}"
    clause="$(stop_plain "$before")"
    [ -z "$clause" ] || out="$out$NL${NL}Before the limits were checked, this journey had stopped because $clause."
  fi
  [ -z "$why" ] || out="$out$NL$NL$why"
  [ "$restarted" != 1 ] || out="$out$NL${NL}This journey was restarted; the earlier one is kept in its history."
  [ "$replaced" != 1 ] || out="$out$NL${NL}An earlier journey for this target was replaced; it is kept in the history."
  [ "$after_audit" != 1 ] || out="$out$NL${NL}The earlier journey had stopped because a limit was broken; this one started from the settings as they were after that."
  [ "$resumes" -eq 0 ] || out="$out$NL${NL}This journey was continued $resumes times after stopping."
  out="$out$NL$NL## Scope chosen for this spec$NL$NL"
  if [ -n "$scope" ]; then out="$out${scope%"$NL"}"; else out="${out}No scope was recorded."; fi
  out="$out$NL$NL## Decided without a person"
  for k in constitution spec scenarios analyze run verify other; do
    case "$k" in
      constitution) item="$d_constitution" ;; spec) item="$d_spec" ;; scenarios) item="$d_scenarios" ;; analyze) item="$d_analyze" ;;
      run) item="$d_run" ;; verify) item="$d_verify" ;; *) item="$d_other" ;;
    esac
    [ -n "$item" ] || continue
    clause="$(step_plain "$k")"
    if [ -n "$clause" ]; then clause="$(printf '%s' "${clause:0:1}" | tr "$LOWER" "$UPPER")${clause:1} step:"; else clause="Other:"; fi
    decided="$decided$NL$NL$clause$NL$NL${item%"$NL"}"
  done
  [ -n "$decided" ] || decided="$NL${NL}Nothing was decided without a person."
  out="$out$decided$NL$NL## Needs a person$NL$NL"
  if [ -n "$needs" ]; then out="$out${needs%"$NL"}"; else out="${out}Nothing needs a person."; fi
  out="$out$NL$NL## Records created$NL$NL"
  if [ -n "$recs" ]; then out="$out${recs%"$NL"}"; else out="${out}None recorded."; fi
  out="$out$NL$NL## How to confirm$NL$NL"
  out="$out- Expected results: run \`oracle-confirm.sh render\` and confirm each value on the page it writes.$NL"
  out="$out- Who may reach each screen: run \`surface-access.sh confirm-table\` and confirm the table.$NL"
  # The next action must be a command that works: only a finished journey gives way to a plain
  # start; any other needs --restart, and a new journey is needed because a confirmed value
  # changes the plan this one started from.
  if [ "$state" = "done" ]; then
    out="$out- Then run \`/qa-auto $TARGET\` again. It starts a new journey on the confirmed plan."
  else
    out="$out- Then run \`/qa-auto $TARGET --restart\`. It starts a new journey on the confirmed plan."
    if [ "$state" = stopped ] && in_list "$reason" "$RESUMABLE_REASONS"; then
      out="$out$NL- To continue this journey with nothing confirmed, run \`/qa-auto $TARGET\`."
    fi
  fi
  atomic_write "$AUTO_DIR/handoff.md" "$out"
  printf '{"result":"%s","needsPerson":%s}\n' "$result" "$count"
}

# ---------------------------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------------------------
VERB="${1:-}"
[ "$#" -gt 0 ] && shift
case "$VERB" in
  start)  cmd_start "$@" ;;
  resume) cmd_resume "$@" ;;
  stop)   cmd_stop "$@" ;;
  status) cmd_status "$@" ;;
  next)       cmd_next "$@" ;;
  step-start) cmd_step_start "$@" ;;
  step-done)  cmd_step_done "$@" ;;
  signin)     cmd_signin "$@" ;;
  decide)     cmd_decide "$@" ;;
  second)     cmd_second "$@" ;;
  note)       cmd_note "$@" ;;
  audit)      cmd_audit "$@" ;;
  handoff)    cmd_handoff "$@" ;;
  *)      usage ;;
esac
