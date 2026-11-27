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
# (for example `--known-defects-invalid`).
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
#   start, resume, stop, status, step-start and step-done print ONE JSON line: journey.json plus
#   {"needsPerson": n} (the decisions that need a person; see HANDOFF). status writes nothing.
#   next and signin print their own one line.
#
# THE GATE (`start`, and again on every `resume`), in this order; nothing is written before all hold:
#   - `.qa/config.json` is there and is one JSON document (a leading byte order mark is accepted).
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
#   - no journey.json of ANY target in the project is unreadable (not one JSON object whose
#     `state` is open, done or stopped), and no other target's journey is open. Directories whose
#     name starts with a dot are looked at too.
#   - on a host that is not local, the run's `gates.dataPolicy` will be `enforce` (judged under the
#     launch profile; on `resume`, the profile recorded in journey.json).
# A target must be a plain name (`^[A-Za-z0-9][A-Za-z0-9._-]*$`, no `..`), for every verb.
# `--max-hours` is between 0.1 and 72. `start --restart` on a journey that was open writes
# `restartedFrom: <history number>` into the new journey.json.
#
# WRITES: every file is written whole to a temporary name beside it and moved into place. A write
# that fails ends the verb with exit 1 and the one line `auto: could not write <path>`; nothing
# that reads as a result is printed, and `start` never writes journey.json after a failed baseline.
#
# DECISIONS: `decide` appends one record to decisions.json:
#   {id, step, class, question, answer, evidence, confidence, criteria:[], assumption:true,
#    needsPerson, second:null|"stands"|"ask", secondReason}
# `--evidence none` (the literal word) stores `evidence: null` and `needsPerson: true`. A class the
# journey must never decide (FORBIDDEN_CLASSES) is refused. `second` records the second look: `ask`
# sets `needsPerson: true`; `stands` never clears it; once a decision is `ask` it stays `ask`.
# `second --unavailable` leaves every low-confidence decision without a second look for a person
# and writes `secondLook: "unavailable"` into journey.json. `note` appends {id, kind, text, at} to
# notes.json. All three verbs need an open journey. Free text is passed to the engines as
# arguments, never as program text, so it is stored exactly as given.
#
# AUDIT: `audit` compares the files as they are now with baseline.json and with the journey's own
# record, and never takes the caller's word. It may run on an open, done or stopped journey. Every
# check runs; the codes are printed sorted. A passing audit writes nothing. A failed audit makes
# the journey `stopped` / `audit` (also a journey that was done), with the codes joined by `, ` in
# `stop.detail`, the list in `auditViolations` and the earlier stop, if any, in `stopBeforeAudit`.
# Once failed it stays failed: a later audit reports the earlier codes plus what it finds. Codes:
#   baseline-missing                    there is no baseline.json
#   baseline-changed                    baseline.json is not the file `start` wrote (its SHA-256 is kept
#                                       in journey.json as `baselineHash`), or it no longer parses
#   base-url-changed                    the `baseUrl` of .qa/config.json is not the one recorded at the
#                                       start (or the config is unreadable). Skipped for a baseline
#                                       written before the address was recorded (no `baseUrl` key).
#   safety-setting-changed:<key>        a SAFETY_KEYS value of .qa/config.json differs from the baseline
#                                       (by value: key order and number spelling do not count; a
#                                       changed type does). An unreadable config fails every key.
#   run-config-safety:<key>             the spec's run-config.json differs from the baseline in that
#                                       safety key (added, changed or removed), except `profile` set
#                                       to the launch profile
#   known-defects-changed               .qa/known-defects.json has other bytes, appeared or is gone
#   human-oracle-added:<criterion id>   a plan row is `oracleSource: "human"` and was not at the start
#   human-oracle-removed:<criterion id> a row that was `human` at the start still exists and is not now
#   human-oracle-changed:<criterion id> a row is still `human` and its `fixture.expect` is not the one
#                                       recorded at the start (SHA-256 of its canonical JSON: keys
#                                       sorted, compact, numbers normalised). Skipped for a baseline
#                                       without `humanOracleHashes`.
#   plan-row-removed:<criterion id>     a row of the starting plan is gone (adding rows is allowed)
#   plan-unreadable                     checklist.json is not one JSON array
#   seed-added                          seed.json exists and did not at the start
#   exclusion-added                     coverage-exclusions.json has an entry the baseline does not
#                                       (or is unreadable, or no longer an array)
#   forbidden-decision:<id>             decisions.json holds a record whose class is not one a journey
#                                       may decide (`#<n>`, its place in the file, when it has no id)
#   decisions-unreadable                decisions.json is not one JSON array
#   step-without-result:<step>          a step other than verify is marked done and its result is not
#                                       on disk (the checks `step-done` makes)
#   not-verified                        the journey is done, or its verify step is, and the recorded
#                                       run has no verification.json
#   tracker-behind                      `${QA_AUTO_TRACKER_CMD:-bash <this directory>/tracker.sh}
#                                       spec-status --spec <target> --project <dir>` failed, gave no
#                                       answer, or printed a JSON line whose `behind` is not false.
#                                       Output with `not-set-up` and exit 0 is not a violation. The
#                                       command's stderr is never shown. It is stopped after
#                                       QA_AUTO_TRACKER_TIMEOUT seconds (default 60) when `timeout` or
#                                       `gtimeout` is installed; without either there is no time guard.
# What the audit cannot see: a value changed and changed back before the audit; a baseline.json
# and journey.json rewritten together to agree (or a new baseline taken with `start --restart`
# after a change; the new journey then says `restartedFrom`); a safety key that went from absent
# to an explicit null (both read as null); a plan row without a string id; a tracker command
# replaced through the environment.
#
# HANDOFF: `handoff` writes auto/handoff.md, the plain list a person reads at the end: the result,
# the scope chosen, what was decided without a person, what still needs a person, the records the
# run created (`--records <file>`: the output of the engine's `data-policy.sh list`, passed in by
# the command) and how to confirm. It prints {"result":…,"needsPerson":n}; `needsPerson` is the
# number of items listed under "Needs a person". The result is one of ready, not confirmed, not
# ready, verified, not verified, stopped; it is worked out from files only and is never better
# than what the engine recorded (the exact rule is above cmd_handoff). It may run on any journey
# and more than once; it changes no other file and never the state of the journey. A decision
# needs a person when it is marked `needsPerson`, when the second look said `ask`, or when it was
# made at low confidence and no second look let it stand; `status` counts with the same rule.
#
# STEP ORDER: `next` names the first step that is not done; `step-start` and `step-done` take only
# that step. `step-done` looks for the step's result on disk (the checks /qa-status makes) and
# never takes the caller's word. A step's `attempts` counts its `step-start` calls, so a second
# `step-start` on a running step is a redo.
#
# EXIT CODES: 0 ok; 1 refused or failed (one line on stderr, `auto: <reason>`); 2 usage.
#
# CLOCK: "now" is `QA_AUTO_NOW` (ISO-8601 UTC, `YYYY-MM-DDTHH:MM:SSZ`) when set, else the system
# clock. Timestamps are always written in that one format, so two of them compare as strings.
#
# DEPENDENCIES: bash (3.2 safe), coreutils, EITHER jq OR python3 (jq preferred; `QA_ENGINE=jq|python3`
# overrides). Both engines give byte-identical files and output. No node/perl/grep -P.
#
# ADDING A VERB: write `cmd_<verb>`, add it to the dispatch `case` at the bottom, and reuse the
# helpers below (parse_common, journey_load, journey_read, journey_require_open, journey_require_open_strict,
# rows_commit, atomic_write, one_of, text_given, json_get/json_strs/
# json_pick/json_merge, journey_stepset, stop_journey, print_status, print_stopped, now_iso,
# iso_add_hours, iso_epoch, step_artifact_done, step_state, first_open_step, signin_json, read_lines,
# checklist_ids, plan_hashes, file_state, hash_or). Register every option a verb takes in
# VALUE_FLAGS or SWITCH_FLAGS: parse_common refuses any other `--word`. A new audit check goes into BOTH JQ_AUDIT and the `audit` op
# of PY_HELPERS, or, when it needs no JSON, into audit_steps with `code <fixed word>`.
set -uo pipefail

# ---------------------------------------------------------------------------------------------
# Fixed values (plan decisions J1, J2, J6)
# ---------------------------------------------------------------------------------------------
STEPS="constitution spec scenarios analyze run verify"
RESUMABLE_REASONS="time-limit step-failed until"
FINAL_REASONS="blocked audit no-sign-in tracker"
SAFETY_KEYS="allowApiWrites seedableEnvMarker environment allowBlackboxCrawl gates profile humanInteraction.enforce humanInteraction.maxOptOutRate"
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

# The python3 side of every JSON helper, one small program with sub-commands. Output is always
# UTF-8, keys sorted, so it matches `jq -S` byte for byte.
# PY_NEEDS — a decision a person still has to look at: marked `needsPerson`, sent on by the second
# look, or made at low confidence with no second look that let it stand. `status` and `handoff`
# both count with this one rule (the jq side is JQ_NEEDS).
PY_NEEDS='
def needs_person(r):
    return r.get("needsPerson") is True or r.get("second") == "ask" or (r.get("confidence") == "low" and r.get("second") != "stands")
'
PY_HELPERS="$PY_NEEDS"'
import calendar, hashlib, json, math, re, sys, time
op, a = sys.argv[1], sys.argv[2:]
def load(p):
    # utf-8-sig: one leading byte order mark is dropped, as jq drops it
    with open(p, encoding="utf-8-sig") as f:
        return json.load(f)
def norm(v):
    # whole-valued floats print as integers, as jq prints them
    if isinstance(v, float) and v.is_integer() and abs(v) < 1e17:
        return int(v)
    if isinstance(v, dict):
        return dict((k, norm(x)) for k, x in v.items())
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v
def dumps(v, pretty=False):
    v = norm(v)
    if pretty:
        s = json.dumps(v, sort_keys=True, indent=2, ensure_ascii=False)
    else:
        s = json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    # jq writes U+007F as an escape; a raw one can only be inside a string, so this is safe
    return s.replace("\x7f", "\\u007f")
def emit(v, pretty=False):
    sys.stdout.buffer.write((dumps(v, pretty) + "\n").encode("utf-8"))
def jstr(v):
    return json.dumps(v, ensure_ascii=False).replace("\x7f", "\\u007f")
def rows_in():
    # the array on stdin; nothing at all (no file yet) is an empty array
    t = sys.stdin.buffer.read().decode("utf-8-sig")
    rows = json.loads(t) if t.strip(" \t\r\n") else []
    if not isinstance(rows, list):
        sys.exit(1)
    return rows
def next_id(rows, prefix):
    n = 0
    for r in rows:
        i = r.get("id") if isinstance(r, dict) else None
        if isinstance(i, str) and re.fullmatch(prefix + "[0-9]+", i):
            n = max(n, int(i[1:]))
    return prefix + str(n + 1)
def rows_out(line, rows):
    # the result line, then the whole array as it goes back to the file
    sys.stdout.buffer.write((line + "\n").encode("utf-8"))
    emit(rows, pretty=True)
def plan_ids(rows):
    # (ids of the rows whose expected value a person confirmed, every row id) of a plan
    human, every = set(), set()
    for r in (rows if isinstance(rows, list) else []):
        if not isinstance(r, dict) or not isinstance(r.get("id"), str):
            continue
        every.add(r["id"])
        fx = r.get("fixture")
        ex = fx.get("expect") if isinstance(fx, dict) else None
        if isinstance(ex, dict) and ex.get("oracleSource") == "human":
            human.add(r["id"])
    return human, every
def plan_hashes(rows):
    # {id: SHA-256 of the canonical JSON of fixture.expect} for the person-confirmed rows; of two
    # such rows with one id the first counts
    out = {}
    for r in (rows if isinstance(rows, list) else []):
        if not isinstance(r, dict) or not isinstance(r.get("id"), str):
            continue
        fx = r.get("fixture")
        ex = fx.get("expect") if isinstance(fx, dict) else None
        if isinstance(ex, dict) and ex.get("oracleSource") == "human" and r["id"] not in out:
            out[r["id"]] = hashlib.sha256(dumps(ex).encode("utf-8")).hexdigest()
    return out
def walk(d, path):
    if path == "":
        return True, d
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d:
            return False, None
        d = d[k]
    return True, d
try:
    if op == "valid":
        load(a[0])
    elif op == "get":
        emit(walk(load(a[0]), a[1])[1])
    elif op == "str":
        v = walk(load(a[0]), a[1])[1]
        if isinstance(v, str):
            sys.stdout.buffer.write((v + "\n").encode("utf-8"))
    elif op == "strs":
        d = load(a[0])
        for p in a[1:]:
            v = walk(d, p)[1]
            v = v.replace("\r", " ").replace("\n", " ") if isinstance(v, str) else ""
            sys.stdout.buffer.write((v + "\n").encode("utf-8"))
    elif op == "pick":
        d = load(a[0])
        o = {}
        for p in a[2:]:
            found, v = walk(d, p)
            if found or a[1] == "all":
                o[p] = v
        emit(o)
    elif op == "has":
        sys.exit(0 if walk(load(a[0]), a[1])[0] else 1)
    elif op == "pretty":
        emit(json.loads(sys.stdin.buffer.read().decode("utf-8")), pretty=True)
    elif op == "patch":
        d = load(a[0])
        p = json.loads(a[1])
        if not isinstance(d, dict) or not isinstance(p, dict):
            sys.exit(1)
        d.update(p)
        emit(d)
    elif op == "quote":
        emit(a[0])
    elif op == "addhours":
        t = calendar.timegm(time.strptime(a[0], "%Y-%m-%dT%H:%M:%SZ")) + math.floor(float(a[1]) * 3600)
        sys.stdout.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) + "\n")
    elif op == "planids":
        # two lines: the ids of the person-confirmed rows, then every row id; `"!shape"` alone
        # when the plan is not a list
        rows = load(a[0])
        if not isinstance(rows, list):
            emit("!shape")
        else:
            human, every = plan_ids(rows)
            emit(sorted(human))
            emit(sorted(every))
    elif op == "planhashes":
        emit(plan_hashes(load(a[0])))
    elif op == "cfacts":
        # what the gate needs from the config, one per line: how `environment` is given (absent, string,
        # other), then environment, baseUrl, seedableEnvMarker, profile as text (empty when not
        # text), then baseUrl as JSON (null when not text)
        d = load(a[0])
        d = d if isinstance(d, dict) else {}
        def s(v):
            return v.replace("\r", " ").replace("\n", " ") if isinstance(v, str) else ""
        kind = "absent" if "environment" not in d else ("string" if isinstance(d["environment"], str) else "other")
        b = d.get("baseUrl")
        out = [kind, s(d.get("environment")), s(b), s(d.get("seedableEnvMarker")), s(d.get("profile")), dumps(b if isinstance(b, str) else None)]
        sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
    elif op == "needs":
        # how many decisions of the array on stdin need a person
        emit(len([r for r in rows_in() if isinstance(r, dict) and needs_person(r)]))
    elif op == "audit":
        # The file checks of `audit`, in one pass. Arguments: journey, then a state (1 there,
        # 0 absent, ! there but not a readable file) and a path for each of baseline, config,
        # run-config, plan, exclusions and decisions, then: the hash of the baseline now, the
        # hash of the known-defect registry now (empty when absent), 1|0 seed.json exists, now, the
        # safety keys, the decidable classes, and the codes the shell already found (space lists).
        # Prints the result line, then (only when the journey changes) the new journey.json.
        jf, bs, bf, cs, cf, rs, rf, ps, pf, es, ef, ds, df, bhash, kdhash, seed, now, keys, classes, extra = a[:20]
        # (the jq side is also handed the hashes of the person-confirmed rows as they are now; here
        # they are worked out in place, from the same rows)
        keys = keys.split(" ")
        classes = classes.split(" ")
        def rd(state, path, empty_ok=False):
            # (readable, value) of one JSON document
            if state != "1":
                return False, None
            try:
                with open(path, "rb") as f:
                    t = f.read().decode("utf-8")
                if t.startswith("\ufeff"):
                    t = t[1:]
                if t.strip(" \t\r\n") == "":
                    return (True, []) if empty_ok else (False, None)
                return True, json.loads(t)
            except Exception:
                return False, None
        def same(x, y):
            # equality as jq has it: no bool/number mixing, numbers by value, objects by content
            if isinstance(x, bool) or isinstance(y, bool):
                return isinstance(x, bool) and isinstance(y, bool) and x == y
            if isinstance(x, (int, float)) and isinstance(y, (int, float)):
                return x == y
            if isinstance(x, dict) and isinstance(y, dict):
                return x.keys() == y.keys() and all(same(x[k], y[k]) for k in x)
            if isinstance(x, list) and isinstance(y, list):
                return len(x) == len(y) and all(same(p, q) for p, q in zip(x, y))
            return type(x) == type(y) and x == y
        def strs(v):
            return set(x for x in v if isinstance(x, str)) if isinstance(v, list) else None
        ok, j = rd("1", jf)
        if not ok or not isinstance(j, dict):
            sys.exit(1)
        codes = set(x for x in extra.split(" ") if x)
        if bs == "0":
            codes.add("baseline-missing")
        else:
            ok, b = rd(bs, bf)
            ok = ok and isinstance(b, dict)
            if not ok or j.get("baselineHash") != bhash:
                codes.add("baseline-changed")
            if ok:
                # safety settings of the project config
                okc, c = rd(cs, cf)
                # the address the journey runs against (only a baseline that recorded it)
                if "baseUrl" in b:
                    found, v = walk(c, "baseUrl")
                    if not okc or not same(v if isinstance(v, str) else None, b["baseUrl"]):
                        codes.add("base-url-changed")
                bsaf = b.get("safety") if isinstance(b.get("safety"), dict) else None
                for k in keys:
                    found, v = walk(c, k)
                    if not okc or bsaf is None or k not in bsaf or not same(v if found else None, bsaf[k]):
                        codes.add("safety-setting-changed:" + k)
                # safety keys of the run-config of the spec
                okr, r = (True, {}) if rs == "0" else rd(rs, rf)
                brc = b.get("runConfigSafety") if isinstance(b.get("runConfigSafety"), dict) else None
                for k in keys:
                    found, v = walk(r, k)
                    if not okr or brc is None:
                        codes.add("run-config-safety:" + k)
                    elif k == "profile" and found and isinstance(b.get("profile"), str) and same(v, b["profile"]):
                        pass
                    elif found != (k in brc) or (found and not same(v, brc[k])):
                        codes.add("run-config-safety:" + k)
                # the known-defect registry, by its bytes
                if not same(kdhash if kdhash else None, b.get("knownDefectsHash")):
                    codes.add("known-defects-changed")
                # the plan
                okp, rows = (True, []) if ps == "0" else rd(ps, pf)
                if not okp or not isinstance(rows, list):
                    codes.add("plan-unreadable")
                else:
                    bh = strs(b.get("humanOracleIds")) or set()
                    br = strs(b.get("planRowIds"))
                    ch, cr = plan_ids(rows)
                    gone = (br - cr) if br is not None else set()
                    codes.update("human-oracle-added:" + i for i in ch - bh)
                    codes.update("plan-row-removed:" + i for i in gone)
                    codes.update("human-oracle-removed:" + i for i in bh - ch - gone)
                    bhh = b.get("humanOracleHashes") if isinstance(b.get("humanOracleHashes"), dict) else None
                    if bhh is not None:
                        hh = plan_hashes(rows)
                        codes.update("human-oracle-changed:" + i for i in ch & bh if i in bhh and not same(bhh[i], hh.get(i)))
                if seed == "1" and b.get("seedExists") is not True:
                    codes.add("seed-added")
                if es != "0":
                    oke, cur = rd(es, ef)
                    base = b.get("exclusions")
                    if not oke:
                        codes.add("exclusion-added")
                    elif isinstance(base, list) and isinstance(cur, list):
                        if any(not any(same(x, y) for y in base) for x in cur):
                            codes.add("exclusion-added")
                    elif not same(cur, base):
                        codes.add("exclusion-added")
        if ds != "0":
            okd, rows = rd(ds, df, empty_ok=True)
            if not okd or not isinstance(rows, list):
                codes.add("decisions-unreadable")
            else:
                for n, r in enumerate(rows):
                    if isinstance(r, dict) and not (isinstance(r.get("class"), str) and r["class"] in classes):
                        i = r.get("id")
                        codes.add("forbidden-decision:" + (i if isinstance(i, str) else "#%d" % (n + 1)))
        st = j.get("stop")
        failed = j.get("state") == "stopped" and isinstance(st, dict) and st.get("reason") == "audit"
        if failed:
            codes.update(strs(j.get("auditViolations")) or set())
        allc = sorted(codes)
        bad = failed or len(allc) > 0
        line = "{\"ok\":%s,\"violations\":%s}" % ("false" if bad else "true", json.dumps(allc, separators=(",", ":"), ensure_ascii=False).replace("\x7f", "\\u007f"))
        if not bad or (failed and j.get("auditViolations") == allc):
            sys.stdout.buffer.write((line + "\n").encode("utf-8"))
        else:
            if not failed:
                j.update({"state": "stopped", "endedAt": now, "stopBeforeAudit": st})
            j.update({"stop": {"reason": "audit", "detail": ", ".join(allc)}, "auditViolations": allc})
            rows_out(line, j)
    elif op == "behind":
        # tracker output on stdin -> behind | ok | none
        seen = []
        for line in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n"):
            try:
                v = json.loads(line)
            except Exception:
                continue
            if isinstance(v, dict) and "behind" in v:
                seen.append(v["behind"])
        sys.stdout.write("none\n" if not seen else ("ok\n" if all(x is False for x in seen) else "behind\n"))
    elif op == "journey":
        d = load(a[0])
        if not isinstance(d, dict):
            sys.exit(1)
        def s(v):
            return v.replace("\r", " ").replace("\n", " ") if isinstance(v, str) else ""
        def n(v):
            return math.floor(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0
        st = d.get("stop") if isinstance(d.get("stop"), dict) else {}
        steps = d.get("steps") if isinstance(d.get("steps"), list) else []
        out = [s(d.get("state")), s(st.get("reason")), s(st.get("detail")), s(d.get("deadline")), s(d.get("until")),
               s(d.get("runId")), s(d.get("startedAt")), str(n(d.get("analyzeRounds"))),
               " ".join("%s:%s:%d" % (s(x.get("name")), s(x.get("state")), n(x.get("attempts"))) for x in steps if isinstance(x, dict))]
        sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
    elif op == "stepset":
        d = load(a[0])
        p = json.loads(a[1])
        if not isinstance(d, dict) or not isinstance(d.get("steps"), list):
            sys.exit(1)
        d.update(p.get("set") or {})
        for x in d["steps"]:
            u = (p.get("steps") or {}).get(x.get("name")) if isinstance(x, dict) else None
            if u:
                if u.get("state"):
                    x["state"] = u["state"]
                if u.get("bump"):
                    x["attempts"] = (x.get("attempts") or 0) + 1
        emit(d, pretty=True)
    elif op == "personas":
        d = load(a[0])
        if not isinstance(d, dict):
            sys.exit(1)
        def s(v):
            return v.replace("\r", " ").replace("\n", " ").replace("\t", " ") if isinstance(v, str) else ""
        au = d.get("auth")
        out = [s(au.get("storageState")) if isinstance(au, dict) else ""]
        for x in (d.get("personas") if isinstance(d.get("personas"), list) else []):
            if isinstance(x, dict) and isinstance(x.get("id"), str):
                out.append(json.dumps(x["id"], ensure_ascii=False) + "\t" + s(x.get("auth")))
        sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
    elif op == "decide":
        # step class question answer evidence no-evidence(1|0) confidence criteria
        rows = rows_in()
        i = next_id(rows, "D")
        none = a[5] == "1"
        rows.append({"id": i, "step": a[0], "class": a[1], "question": a[2], "answer": a[3],
                     "evidence": None if none else a[4], "confidence": a[6],
                     "criteria": [c.strip(" \t\r\n") for c in a[7].split(",") if c.strip(" \t\r\n")],
                     "assumption": True, "needsPerson": none, "second": None, "secondReason": None})
        rows_out(i, rows)
    elif op == "note":
        # kind text at
        rows = rows_in()
        i = next_id(rows, "N")
        rows.append({"id": i, "kind": a[0], "text": a[1], "at": a[2]})
        rows_out(i, rows)
    elif op == "second":
        # id verdict reason
        rows = rows_in()
        r = None
        for x in rows:
            if isinstance(x, dict) and x.get("id") == a[0]:
                r = x
                break
        if r is None:
            sys.stdout.write("!missing\n")
        else:
            if r.get("second") is None or (r.get("second") == "stands" and a[1] == "ask"):
                r["second"] = a[1]
                r["secondReason"] = a[2]
                if a[1] == "ask":
                    r["needsPerson"] = True
            rows_out("{\"id\":%s,\"needsPerson\":%s,\"second\":%s}" % (jstr(r.get("id")), jstr(r.get("needsPerson")), jstr(r.get("second"))), rows)
    elif op == "unavailable":
        rows = rows_in()
        ids = []
        for x in rows:
            if isinstance(x, dict) and x.get("confidence") == "low" and x.get("second") is None:
                if x.get("needsPerson") is not True:
                    ids.append(x.get("id"))
                x["needsPerson"] = True
        rows_out("{\"marked\":[%s]}" % ",".join(jstr(i) for i in ids), rows)
    elif op == "cptimes":
        d = load(a[0])
        cs = d.get("criteria") if isinstance(d, dict) else None
        for c in (cs if isinstance(cs, list) else []):
            v = c.get("checkpointed_at") if isinstance(c, dict) else None
            if isinstance(v, str):
                sys.stdout.buffer.write((v.replace("\r", " ").replace("\n", " ") + "\n").encode("utf-8"))
    else:
        sys.exit(2)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
'
py() { PYTHONUTF8=1 python3 -c "$PY_HELPERS" "$@"; }
# The jq side normalises numbers the same way (0.20 → 0.2, 1.0 → 1), so both engines agree.
JQ_DEFS='def norm: walk(if type == "number" then . + 0 else . end);'
JQ_ONE='if length != 1 then error("not one JSON document") else .[0] end'
# The array of a rows file read with `jq -s` (nothing at all, no file yet, is an empty array), and
# the next free id with a one-letter prefix.
JQ_ROWS='def rows_in: (if length == 0 then [] elif length == 1 then .[0] else error("not one JSON document") end)
    | if type == "array" then . else error("not an array") end;
  def next_id($p): $p + (([ .[] | objects | .id | strings | select(test("\\A" + $p + "[0-9]+\\z")) | .[1:] | tonumber ] | (max // 0) + 1) | tostring);'

# ---------------------------------------------------------------------------------------------
# JSON helpers (both engines; reuse these in new verbs)
# ---------------------------------------------------------------------------------------------
# json_valid <file> — exit 0 when the file parses as one JSON document.
json_valid() {
  if [ "$ENGINE" = jq ]; then jq -es 'length == 1' "$1" >/dev/null 2>&1; else py valid "$1" >/dev/null 2>&1; fi
}
# json_get <file> <dot.path> — the value at the path as compact, key-sorted JSON; `null` when the
# path is absent. An empty path is the whole document. Path parts are object keys only. Fails
# when the file is not one JSON document.
json_get() {
  if [ "$ENGINE" = jq ]; then
    jq -Sc --arg p "$2" "$JQ_DEFS"' (try getpath(if $p == "" then [] else ($p | split(".")) end) catch null) | norm' "$1" 2>/dev/null
  else py get "$1" "$2" 2>/dev/null; fi
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
# json_pick <file> all|present <dot.path>… — one compact object keyed by the paths as written
# ({"humanInteraction.enforce": true, …}). `all` gives null for an absent path; `present` leaves it out.
json_pick() {
  local f="$1" mode="$2"; shift 2
  if [ "$ENGINE" = jq ]; then
    jq -Scs --arg mode "$mode" "$JQ_DEFS $JQ_ONE"' | . as $d
      | reduce $ARGS.positional[] as $p ({};
          ($p | split(".")) as $k
          | (try ($d | getpath($k[:-1]) | (type == "object" and has($k[-1]))) catch false) as $has
          | if $has then .[$p] = ($d | getpath($k)) elif $mode == "all" then .[$p] = null else . end)
      | norm' --args "$@" < "$f" 2>/dev/null
  else py pick "$f" "$mode" "$@" 2>/dev/null; fi
}
# json_str <file> <dot.path> — the raw string at the path; prints nothing when it is absent or not a string.
json_str() {
  if [ "$ENGINE" = jq ]; then
    jq -r --arg p "$2" 'try (getpath($p | split(".")) | strings) catch empty' "$1" 2>/dev/null
  else py str "$1" "$2" 2>/dev/null; fi
}
# json_has <file> <dot.path> — exit 0 when the key is present (even with a null value).
json_has() {
  if [ "$ENGINE" = jq ]; then
    jq -e --arg p "$2" '($p | split(".")) as $k
      | try (getpath($k[:-1]) | (type == "object" and has($k[-1]))) catch false' "$1" >/dev/null 2>&1
  else py has "$1" "$2" >/dev/null 2>&1; fi
}
# json_quote <text> — the text as a JSON string literal.
json_quote() {
  if [ "$ENGINE" = jq ]; then jq -cn --arg s "$1" '$s'; else py quote "$1"; fi
}
# json_patch <file> <json object> — prints the file's object with the patch's top-level keys set
# (compact, key-sorted). Writes nothing.
json_patch() {
  if [ "$ENGINE" = jq ]; then
    jq -Sc --argjson p "$2" "$JQ_DEFS"' if type == "object" and ($p | type) == "object" then . + $p | norm else error("not an object") end' "$1" 2>/dev/null
  else py patch "$1" "$2" 2>/dev/null; fi
}
# atomic_write <file> <text> — THE writer: every file this script writes goes through here. The
# text plus a final line break goes to a temporary name beside the file, which is then moved into
# place. Refuses any path outside the journey directory. On any failure it removes the temporary
# file and ends the script with exit 1 and the one line `auto: could not write <path>` (the
# shell's own complaint is not shown). ALWAYS call it, and every function that calls it, as a
# plain command: at the end of a pipeline or inside `$(…)` its exit would only end a subshell and
# the verb would carry on as if the write had worked.
atomic_write() {
  local dest="$1" tmp="$1.tmp.$$" rel="${1#"$PROJECT"/}"
  case "$dest" in "$AUTO_DIR"/*) ;; *) die "internal: refused to write outside the journey directory" ;; esac
  [ -n "$2" ] || die "could not write $rel"
  if ! { printf '%s\n' "$2" > "$tmp"; } 2>/dev/null; then rm -f "$tmp" 2>/dev/null; die "could not write $rel"; fi
  if ! mv -f "$tmp" "$dest" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; die "could not write $rel"; fi
}
# json_write <file> <json text> — the JSON text → the file, pretty-printed with sorted keys,
# through atomic_write. A plain command only (see atomic_write).
json_write() {
  local out
  if [ "$ENGINE" = jq ]; then out="$(printf '%s\n' "$2" | jq -S "$JQ_DEFS norm" 2>/dev/null)"; else out="$(printf '%s\n' "$2" | py pretty 2>/dev/null)"; fi
  # shellcheck disable=SC2181
  if [ "$?" -ne 0 ] || [ -z "$out" ]; then die "could not write ${1#"$PROJECT"/}"; fi
  atomic_write "$1" "$out"
}
# json_merge <file> <json object> — set top-level keys of a journey file in place. A plain command
# only (see atomic_write).
json_merge() {
  local out
  out="$(json_patch "$1" "$2")" && [ -n "$out" ] || die "could not update ${1#"$PROJECT"/}"
  json_write "$1" "$out"
}
# JQ_NEEDS — the jq side of PY_NEEDS: a decision a person still has to look at.
JQ_NEEDS='def needs_person: .needsPerson == true or .second == "ask" or (.confidence == "low" and .second != "stands");'
# json_needs_person <decisions.json> — how many of its decisions need a person. Fails when the
# file is not one JSON array (an empty file is an empty array, as for `decide`).
json_needs_person() {
  if [ "$ENGINE" = jq ]; then
    jq -cs "$JQ_ROWS $JQ_NEEDS"' rows_in | [ .[] | objects | select(needs_person) ] | length' < "$1" 2>/dev/null
  else py needs < "$1" 2>/dev/null; fi
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
# checklist_ids <checklist.json> — two lines: the sorted ids of the rows whose
# fixture.expect.oracleSource is "human", then the sorted ids of every row. One line, `"!shape"`,
# when the file is JSON and not a list. Nothing when it is not one JSON document.
checklist_ids() {
  if [ "$ENGINE" = jq ]; then
    jq -cs "$JQ_PLAN $JQ_ONE"' | if type == "array" then (plan_rows | human_ids, row_ids) else "!shape" end' < "$1" 2>/dev/null
  else py planids "$1" 2>/dev/null; fi
}
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
# plan_hashes <checklist.json> — one compact JSON object, {"<row id>": "<SHA-256>"}: for every
# person-confirmed row, the hash of its `fixture.expect` in canonical form (keys sorted, compact,
# numbers normalised: the bytes `jq -cS` and the python side both print). `{}` for a plan that is
# not a list. Fails when the plan is not readable. Row ids travel as the JSON string literals the
# engine printed; they are never read by the shell.
plan_hashes() {
  local out idj ex h acc=""
  if [ "$ENGINE" != jq ]; then py planhashes "$1" 2>/dev/null; return; fi
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
# now_iso — the injected or real "now", `YYYY-MM-DDTHH:MM:SSZ`.
now_iso() {
  if [ -n "${QA_AUTO_NOW:-}" ]; then
    case "$QA_AUTO_NOW" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s\n' "$QA_AUTO_NOW" ;;
      *) die "QA_AUTO_NOW must look like 2026-11-27T08:00:00Z" ;;
    esac
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}
# iso_add_hours <iso> <hours> — the time that many hours later (hours may be a decimal).
iso_add_hours() {
  if [ "$ENGINE" = jq ]; then
    jq -rn --arg t "$1" --arg h "$2" '(($t | fromdateiso8601) + ((($h | tonumber) * 3600) | floor)) | todateiso8601' 2>/dev/null
  else py addhours "$1" "$2" 2>/dev/null; fi
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
# target_json — the target as a JSON string literal (worked out once per call site).
TARGET_JSON=""
target_json() { if [ -n "$TARGET_JSON" ]; then printf '%s\n' "$TARGET_JSON"; else json_quote "$TARGET"; fi; }
# journey_load — reads the journey once into J_STATE (`open`, `done`, `stopped`, or empty when
# there is no readable journey), J_REASON (the stop reason, or empty) and J_PROFILE (the launch
# profile, or empty).
J_STATE=""; J_REASON=""; J_PROFILE=""
journey_load() {
  J_STATE=""; J_REASON=""; J_PROFILE=""
  [ -f "$JOURNEY" ] || return 0
  read_lines "$(json_strs "$JOURNEY" state stop.reason profile)" J_STATE J_REASON J_PROFILE
}
# journey_require — die unless the target has a readable journey.
journey_require() {
  journey_load
  [ -n "$J_STATE" ] || die "no journey for $TARGET"
}
# journey_require_open — die unless the target's journey is open.
journey_require_open() {
  journey_load
  [ "$J_STATE" = open ] || die "no open journey for $TARGET"
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
# run_start_epoch <run id> — seconds since 1970 of the run's start: the manifest's `started_at`
# when it names its zone, else the earliest `checkpointed_at` of the run's checkpoint.json (the
# engine writes those in UTC with `Z`). Fails when neither is readable.
run_start_epoch() {
  local dir="$QA_DIR/runs/$1" started e times line min=""
  started="$(json_strs "$dir/run-manifest.json" started_at)" || started=""
  if e="$(time_epoch "$started")"; then printf '%s\n' "$e"; return 0; fi
  if [ "$ENGINE" = jq ]; then
    times="$(jq -r '(.criteria? | if type == "array" then .[] else empty end) | objects | .checkpointed_at | strings | gsub("[\r\n]"; " ")' "$dir/checkpoint.json" 2>/dev/null)" || return 1
  else
    times="$(py cptimes "$dir/checkpoint.json" 2>/dev/null)" || return 1
  fi
  while IFS= read -r line; do
    e="$(time_epoch "$line")" || continue
    if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min="$e"; fi
  done <<EOT
$times
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
# lock_check — the "one journey per project" lock, failing closed. Dies when the journey.json of
# ANY target in this project (this one included) cannot be read, or when another target's journey
# is open. Directories whose name starts with a dot are looked at too.
lock_check() {
  local f t st
  for f in "$QA_DIR"/specs/*/auto/journey.json "$QA_DIR"/specs/.[!.]*/auto/journey.json "$QA_DIR"/specs/..?*/auto/journey.json; do
    st="$(journey_file_state "$f")"
    [ "$st" = none ] && continue
    t="${f%/auto/journey.json}"; t="${t##*/}"
    [ "$st" != unreadable ] || die "the journey for $t cannot be read"
    [ "$t" = "$TARGET" ] && continue
    [ "$st" != open ] || die "another journey is open for $t"
  done
  return 0
}
# needs_person_count — decisions that need a person (0 without a decisions file). Fails when
# decisions.json is there and is not one JSON array.
needs_person_count() {
  local n=0
  if [ -f "$DECISIONS" ]; then
    n="$(json_needs_person "$DECISIONS")" || return 1
    case "$n" in ""|*[!0-9]*) return 1 ;; esac
  fi
  printf '%s\n' "$n"
}
# print_status [strict] — one line: journey.json plus {"needsPerson": n}. Writes nothing. With
# `strict` (the `status` verb) decisions that cannot be read are a refusal; the verbs that have
# just written the journey print 0 for them instead, as before (the audit reports the file).
print_status() {
  local out n
  if ! n="$(needs_person_count)"; then
    [ "${1:-}" != strict ] || die "decisions.json for $TARGET is not readable"
    n=0
  fi
  out="$(json_patch "$JOURNEY" "{\"needsPerson\":$n}")" && [ -n "$out" ] || die "journey.json for $TARGET is not readable"
  printf '%s\n' "$out"
}
# journey_read — reads the whole journey once: J_STATE, J_REASON, J_DETAIL (line breaks as spaces),
# J_DEADLINE, J_UNTIL, J_RUN, J_STARTED, J_ROUNDS and J_STEPS (`name:state:attempts` words in
# journey order). All empty when there is no readable journey.
J_DETAIL=""; J_DEADLINE=""; J_UNTIL=""; J_RUN=""; J_STARTED=""; J_ROUNDS=0; J_STEPS=""
journey_read() {
  local out=""
  J_STATE=""; J_REASON=""; J_DETAIL=""; J_DEADLINE=""; J_UNTIL=""; J_RUN=""; J_STARTED=""; J_ROUNDS=0; J_STEPS=""
  [ -f "$JOURNEY" ] || return 0
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rs 'def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
      def n: if type == "number" then floor else 0 end;
      '"$JQ_ONE"' | if type != "object" then error("not an object") else . end
      | (.stop | if type == "object" then . else {} end) as $st
      | (.state | s), ($st.reason | s), ($st.detail | s), (.deadline | s), (.until | s), (.runId | s), (.startedAt | s),
        (.analyzeRounds | n | tostring),
        ([ (.steps | if type == "array" then .[] else empty end) | select(type == "object")
           | "\(.name | s):\(.state | s):\(.attempts | n)" ] | join(" "))' < "$JOURNEY" 2>/dev/null)" || return 0
  else
    out="$(py journey "$JOURNEY" 2>/dev/null)" || return 0
  fi
  read_lines "$out" J_STATE J_REASON J_DETAIL J_DEADLINE J_UNTIL J_RUN J_STARTED J_ROUNDS J_STEPS
  case "$J_ROUNDS" in ""|*[!0-9]*) J_ROUNDS=0 ;; esac
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
# step_index <step> — its place in STEPS, from 1.
step_index() {
  local s i=0
  for s in $STEPS; do i=$((i + 1)); [ "$s" = "$1" ] && break; done
  printf '%s\n' "$i"
}
# first_open_step — the first step, in J1 order, that is not done; empty when all are done.
first_open_step() {
  local s
  for s in $STEPS; do
    if [ "$(step_state "$s")" != done ]; then printf '%s\n' "$s"; return 0; fi
  done
  return 0
}
# require_next_step <step> — die unless this is the step `next` would name.
require_next_step() {
  local first
  [ "$(step_state "$1")" = done ] && die "$1 is already done"
  first="$(first_open_step)"
  [ "$first" = "$1" ] || die "$1 is not the next step; next is $first"
}
# journey_stepset <json> — change the journey in place. The JSON is
# {"set": {<top-level keys>}, "steps": {"<name>": {"state": "<state>", "bump": true}}}; both parts
# are optional, `bump` adds one to the step's attempts. A plain command only (see atomic_write).
journey_stepset() {
  local out
  if [ "$ENGINE" = jq ]; then
    out="$(jq -S --argjson p "$1" "$JQ_DEFS"' if type == "object" and (.steps | type) == "array" then . else error("not a journey") end
      | . + ($p.set // {})
      | .steps |= map(. as $x | (if type == "object" then ($p.steps // {})[$x.name // ""] else null end) as $u
          | if $u then (if $u.state then .state = $u.state else . end)
                       | (if $u.bump then .attempts = ((.attempts // 0) + 1) else . end)
            else . end)
      | norm' "$JOURNEY" 2>/dev/null)" || out=""
  else
    out="$(py stepset "$JOURNEY" "$1" 2>/dev/null)" || out=""
  fi
  [ -n "$out" ] || die "could not update ${JOURNEY#"$PROJECT"/}"
  atomic_write "$JOURNEY" "$out"
}
# print_stopped <reason> — the `next` line of a stopped journey:
# {"detail":…,"next":"stopped","reason":…}. Writes nothing.
print_stopped() {
  local st
  st="$(json_get "$JOURNEY" stop)"
  case "$st" in
    '{"detail":'*",\"reason\":\"$1\"}") printf '%s,"next":"stopped","reason":"%s"}\n' "${st%,\"reason\":*}" "$1" ;;
    *) die "journey.json for $TARGET is not readable" ;;
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
# analysis_verdict <analysis.md> — `blocked`, `clear`, or `none` when the file has no `## Verdict`
# section with a line in it. The verdict is the first non-empty line under the heading: BLOCKED
# when it has that word and does not open with PASS.
analysis_verdict() {
  local line in=0 t
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$in" -eq 0 ]; then
      case "$line" in '## Verdict'|'## Verdict '*) in=1 ;; esac
      continue
    fi
    case "$line" in '#'*) break ;; esac
    t="${line#"${line%%[!	 *_\`>-]*}"}"
    [ -n "$t" ] || continue
    case "$t" in
      PASS*) echo clear ;;
      *BLOCKED*) echo blocked ;;
      *) echo clear ;;
    esac
    return 0
  done < "$1"
  echo none
}
# auth_configured <auth text> — exit 0 when a persona's `auth` entry says how it signs in: any
# text other than empty or `unknown…`; when the text names a `.json` file (a captured
# storageState), that file must exist. Presence only; nothing is opened or signed in.
auth_configured() {
  local a="$1" w f=""
  a="${a#"${a%%[! ]*}"}"
  case "$a" in ""|[Uu][Nn][Kk][Nn][Oo][Ww][Nn]*) return 1 ;; esac
  set -f
  for w in $a; do
    while :; do case "$w" in [\"\'\(\[\<\`]*) w="${w#?}" ;; *) break ;; esac; done
    while :; do case "$w" in *[\"\'\)\]\>\`,.\;:]) w="${w%?}" ;; *) break ;; esac; done
    case "$w" in *.json) f="$w"; break ;; esac
  done
  set +f
  [ -n "$f" ] || return 0
  case "$f" in /*) ;; *) f="$PROJECT/$f" ;; esac
  [ -f "$f" ]
}
# signin_json — one line, {"missing":[…],"ok":[…]}: the personas of .qa/config.json (ids, in the
# config's order) by whether their sign-in is configured (auth_configured on `personas[].auth`).
# A config without personas has one sign-in, `auth.storageState`, reported as the persona
# `default`: configured when that file exists. Fails when the config is not one JSON object.
signin_json() {
  local facts
  if [ "$ENGINE" = jq ]; then
    facts="$(jq -rs 'def s: if type == "string" then gsub("[\r\n\t]"; " ") else "" end;
      '"$JQ_ONE"' | if type != "object" then error("not an object") else . end
      | ((.auth | if type == "object" then .storageState else null end) | s),
        ((.personas | if type == "array" then .[] else empty end)
          | select(type == "object" and (.id | type) == "string") | "\(.id | tojson)\t\(.auth | s)")' < "$CONFIG" 2>/dev/null)" || return 1
  else
    facts="$(py personas "$CONFIG" 2>/dev/null)" || return 1
  fi
  signin_from "$facts"
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
    case "$ss" in ""|/*) ;; *) ss="$PROJECT/$ss" ;; esac
    if [ -n "$ss" ] && [ -f "$ss" ]; then ok=',"default"'; else missing=',"default"'; fi
  fi
  printf '{"missing":[%s],"ok":[%s]}\n' "${missing#,}" "${ok#,}"
}
# stop_journey <reason> <detail> — close the journey as stopped. Reason must be a J2 reason.
stop_journey() {
  in_list "$1" "$RESUMABLE_REASONS $FINAL_REASONS" || die "internal: unknown stop reason $1"
  local now
  now="$(now_iso)" || exit 1
  json_merge "$JOURNEY" "{\"state\":\"stopped\",\"stop\":{\"reason\":\"$1\",\"detail\":$(json_quote "$2")},\"endedAt\":\"$now\"}"
}
# step_artifact_done <step> [run id] — exit 0 when the step's result is on disk (the checks
# /qa-status makes). `run` and `verify` need the run id. `start` asks only for the three steps a
# new journey can inherit.
step_artifact_done() {
  case "$1" in
    constitution) [ -f "$QA_DIR/constitution.state.json" ] ;;
    spec)         [ -f "$SPEC_DIR/qa-spec.md" ] && [ -f "$SPEC_DIR/spec-roles.json" ] ;;
    scenarios)    [ -f "$SPEC_DIR/scenarios.md" ] && [ -f "$SPEC_DIR/checklist.json" ] ;;
    analyze)      [ -f "$SPEC_DIR/analysis.md" ] && ! [ "$SPEC_DIR/analysis.md" -ot "$SPEC_DIR/checklist.json" ] ;;
    run)          [ -n "${2:-}" ] && [ -f "$QA_DIR/runs/$2/run-manifest.json" ] && [ -f "$QA_DIR/runs/$2/checkpoint.json" ] && [ -f "$QA_DIR/runs/$2/report.md" ] ;;
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
# gate_config — the refusals about .qa/config.json that `start` and `resume` share, in order:
# no config, not JSON, an environment that is not one of the three words, production. Sets G_BASE
# (baseUrl as text), G_BASE_JSON (baseUrl as JSON, null when it is not text) and G_PROFILE.
G_BASE=""; G_BASE_JSON=null; G_PROFILE=""
gate_config() {
  local facts kind env marker
  [ -f "$CONFIG" ] || die "no .qa/config.json; set the project up first"
  if [ "$ENGINE" = jq ]; then
    facts="$(jq -rs 'def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
      '"$JQ_ONE"' | (if type == "object" then . else {} end) as $d
      | (if ($d | has("environment") | not) then "absent" elif ($d.environment | type) == "string" then "string" else "other" end),
        ($d.environment | s), ($d.baseUrl | s), ($d.seedableEnvMarker | s), ($d.profile | s),
        ($d.baseUrl | if type == "string" then . else null end | tojson)' < "$CONFIG" 2>/dev/null)" || facts=""
  else
    facts="$(py cfacts "$CONFIG" 2>/dev/null)" || facts=""
  fi
  [ -n "$facts" ] || die ".qa/config.json is not valid JSON"
  read_lines "$facts" kind env G_BASE marker G_PROFILE G_BASE_JSON
  case "$kind" in
    absent) env=auto ;;
    string) env="$(lower "$env")"; one_of "$env" "$ENVIRONMENTS" || die "environment must be auto, production or disposable" ;;
    *) die "environment must be auto, production or disposable" ;;
  esac
  env_is_production "$env" "$G_BASE" "$marker" && die "this environment is production; an unattended journey does not run there"
  return 0
}
# gate_data_policy <profile> — on a host that is not local the run must enforce the data policy.
gate_data_policy() {
  is_local_url "$G_BASE" || data_policy_enforced "$1" || die "the environment is shared and gates.dataPolicy is not enforce"
}
# data_policy_enforced <profile> — exit 0 when the run's gates.dataPolicy will be `enforce`.
# The spec's run-config replaces the whole `gates` key when it has one (runconfig-merge.sh); the
# ship and smoke profiles fill `gates.dataPolicy: enforce` only when it is not set (profile.sh).
data_policy_enforced() {
  local o=""
  [ -f "$SPEC_DIR/run-config.json" ] && o="$(json_pick "$SPEC_DIR/run-config.json" present gates gates.dataPolicy)"
  case "$o" in ""|"{}") o="$(json_pick "$CONFIG" present gates gates.dataPolicy)" ;; esac
  case "$o" in
    *'"gates.dataPolicy":"enforce"}') return 0 ;;
    *'"gates.dataPolicy":'*) return 1 ;;
    '{}'|'{"gates":{'*|'{"gates":null}') [ "$1" = ship ] || [ "$1" = smoke ] ;;
    *) return 1 ;;
  esac
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
# baseline_json <profile> <now> — prints the baseline (compact JSON) from the files as they are now.
# gate_config has run, so G_BASE_JSON is the config's baseUrl.
baseline_json() {
  local profile="$1" now="$2" safety rcs ids rows excl kd seed hashes
  # shellcheck disable=SC2086
  safety="$(json_pick "$CONFIG" all $SAFETY_KEYS)"
  [ -n "$safety" ] || die ".qa/config.json is not valid JSON"
  rcs="{}"
  if [ -f "$SPEC_DIR/run-config.json" ]; then
    # shellcheck disable=SC2086
    rcs="$(json_pick "$SPEC_DIR/run-config.json" present $SAFETY_KEYS)"
    [ -n "$rcs" ] || die ".qa/specs/$TARGET/run-config.json is not valid JSON"
  fi
  # planRowIds is null when there is no plan yet: the audit then has no starting rows to miss.
  ids="[]"; rows=null; hashes="{}"
  if [ -f "$SPEC_DIR/checklist.json" ]; then
    read_lines "$(checklist_ids "$SPEC_DIR/checklist.json")" ids rows
    [ "$ids" != '"!shape"' ] || die ".qa/specs/$TARGET/checklist.json is not a list of rows"
    [ -n "$ids" ] && [ -n "$rows" ] || die ".qa/specs/$TARGET/checklist.json is not valid JSON"
    # the expected value of each person-confirmed row, as a hash (nothing to hash without such rows)
    if [ "$ids" != "[]" ]; then
      hashes="$(plan_hashes "$SPEC_DIR/checklist.json")" && [ -n "$hashes" ] || die ".qa/specs/$TARGET/checklist.json is not valid JSON"
    fi
  fi
  excl="[]"
  if [ -f "$SPEC_DIR/coverage-exclusions.json" ]; then
    excl="$(json_get "$SPEC_DIR/coverage-exclusions.json" "")"
    [ -n "$excl" ] || die ".qa/specs/$TARGET/coverage-exclusions.json is not valid JSON"
  fi
  seed=false; [ -f "$SPEC_DIR/seed.json" ] && seed=true
  kd=null; [ -f "$QA_DIR/known-defects.json" ] && kd="\"$(file_sha256 "$QA_DIR/known-defects.json")\""
  printf '{"version":1,"target":%s,"takenAt":"%s","profile":"%s","baseUrl":%s,"safety":%s,"runConfigSafety":%s,"humanOracleIds":%s,"humanOracleHashes":%s,"planRowIds":%s,"seedExists":%s,"exclusions":%s,"knownDefectsHash":%s}\n' \
    "$(target_json)" "$now" "$profile" "$G_BASE_JSON" "$safety" "$rcs" "$ids" "$hashes" "$rows" "$seed" "$excl" "$kd"
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
  local facts was_open=0
  gate_config
  [ "$kd_invalid" -eq 0 ] || die ".qa/known-defects.json is not valid"
  lock_check
  journey_load
  [ "$J_STATE" = open ] && was_open=1
  if [ "$restart" -eq 0 ]; then
    if [ "$J_STATE" = open ]; then
      die "a journey is already open for $TARGET; continue it or pass --restart"
    elif [ "$J_STATE" = stopped ] && in_list "$J_REASON" "$RESUMABLE_REASONS"; then
      die "a journey for $TARGET is stopped ($J_REASON); resume it or pass --restart"
    fi
  fi
  # The launch profile: --profile, else the spec's run-config, else the project's config, else
  # `full` (the precedence scripts/profile.sh documents).
  local profile="$profile_flag"
  if [ -f "$SPEC_DIR/run-config.json" ]; then
    facts="$(json_strs "$SPEC_DIR/run-config.json" profile)" || die ".qa/specs/$TARGET/run-config.json is not valid JSON"
    [ -n "$profile" ] || profile="$facts"
  fi
  [ -n "$profile" ] || profile="$G_PROFILE"
  in_list "$profile" "ship smoke full" || profile=full
  gate_data_policy "$profile"

  local now deadline base steps sep s st until_json restarted=""
  now="$(now_iso)" || exit 1
  TARGET_JSON="$(json_quote "$TARGET")"
  deadline="$(iso_add_hours "$now" "$hours")"
  [ -n "$deadline" ] || die "could not work out the deadline"
  base="$(baseline_json "$profile" "$now")" || exit 1
  steps=""; sep=""
  for s in $STEPS; do
    st=pending
    # Only these three can be inherited; analyze, run and verify are always this journey's own.
    in_list "$s" "constitution spec scenarios" && step_artifact_done "$s" && st=done
    steps="$steps$sep{\"name\":\"$s\",\"state\":\"$st\",\"attempts\":0}"; sep=","
  done
  until_json=null; [ -z "$until" ] || until_json="\"$until\""

  # Writes start here: the earlier journey (finished, or open with --restart) goes to history,
  # then the baseline, then the journey. Each is a plain command that ends the script when it
  # fails, so the journey is never written unless the baseline was.
  archive_journey
  mkdir -p "$AUTO_DIR" 2>/dev/null || die "could not write .qa/specs/$TARGET/auto"
  json_write "$BASELINE" "$base"
  # The journey keeps the hash of the baseline as written, so the audit can tell a rewritten one.
  local bhash
  bhash="$(file_sha256 "$BASELINE")" || exit 1
  # A journey that replaced one still open says so: the handoff tells the person it was restarted.
  if [ "$was_open" -eq 1 ] && [ "$ARCHIVED_N" -gt 0 ]; then restarted=",\"restartedFrom\":$ARCHIVED_N"; fi
  json_write "$JOURNEY" "$(printf '{"version":1,"target":%s,"profile":"%s","startedAt":"%s","deadline":"%s","until":%s,"steps":[%s],"analyzeRounds":0,"runId":null,"state":"open","stop":null,"endedAt":null,"baselineHash":"%s"%s}' \
    "$(target_json)" "$profile" "$now" "$deadline" "$until_json" "$steps" "$bhash" "$restarted")"
  print_status
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
  local reason now deadline patch profile
  [ "$(journey_file_state "$JOURNEY")" != unreadable ] || die "the journey for $TARGET cannot be read"
  journey_load
  [ "$J_STATE" = stopped ] || die "nothing to resume"
  reason="$J_REASON"
  in_list "$reason" "$RESUMABLE_REASONS" || die "nothing to resume"
  # The gate again, as at `start`: the config may have changed while the journey was stopped.
  gate_config
  [ "$kd_invalid" -eq 0 ] || die ".qa/known-defects.json is not valid"
  lock_check
  # The data policy is judged under the profile this journey was launched with.
  profile="$J_PROFILE"
  in_list "$profile" "ship smoke full" || profile=full
  if [ -f "$SPEC_DIR/run-config.json" ]; then
    json_valid "$SPEC_DIR/run-config.json" || die ".qa/specs/$TARGET/run-config.json is not valid JSON"
  fi
  gate_data_policy "$profile"
  now="$(now_iso)" || exit 1
  deadline="$(iso_add_hours "$now" "$hours")"
  [ -n "$deadline" ] || die "could not work out the deadline"
  patch="{\"state\":\"open\",\"stop\":null,\"endedAt\":null,\"deadline\":\"$deadline\""
  # A journey that stopped at its --until step goes on past it when resumed.
  [ "$reason" = until ] && patch="$patch,\"until\":null"
  json_merge "$JOURNEY" "$patch}"
  print_status
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
  journey_require_open
  stop_journey "$reason" "$detail"
  print_status
}

cmd_status() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "status does not take: ${REST[0]}"
  need_engine
  journey_require
  print_status strict
}

cmd_next() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "next does not take: ${REST[0]}"
  need_engine
  journey_read
  [ -n "$J_STATE" ] || die "no journey for $TARGET"
  case "$J_STATE" in
    stopped) print_stopped "$J_REASON"; return 0 ;;
    done)    printf '{"next":"done"}\n'; return 0 ;;
    open)    ;;
    *)       die "journey.json for $TARGET is not readable" ;;
  esac
  [ -n "$J_STEPS" ] || die "journey.json for $TARGET is not readable"
  local step now
  step="$(first_open_step)"
  now="$(now_iso)" || exit 1
  if [ -z "$step" ]; then
    # Nothing is left to do, so a passed deadline no longer matters.
    json_merge "$JOURNEY" "{\"state\":\"done\",\"endedAt\":\"$now\"}"
    printf '{"next":"done"}\n'
    return 0
  fi
  # The stop the person asked for comes before the time limit: the asked-for work is complete.
  if in_list "$J_UNTIL" "$STEPS" && [ "$(step_index "$step")" -gt "$(step_index "$J_UNTIL")" ]; then
    stop_journey until "stopped after $J_UNTIL, as asked"
    print_stopped until
    return 0
  fi
  if [[ "$now" > "$J_DEADLINE" ]]; then
    stop_journey time-limit "the deadline $J_DEADLINE has passed"
    print_stopped time-limit
    return 0
  fi
  printf '{"next":"%s"}\n' "$step"
}

cmd_step_start() {
  parse_common "$@"
  set -- ${REST[@]+"${REST[@]}"}
  [ "$#" -ge 1 ] || usage "step-start needs a step"
  [ "$#" -eq 1 ] || usage "step-start does not take: $2"
  in_list "$1" "$STEPS" || usage "the step must be one of: $STEPS"
  need_engine
  journey_read_open
  require_next_step "$1"
  journey_stepset "{\"steps\":{\"$1\":{\"state\":\"running\",\"bump\":true}}}"
  print_status
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
  journey_read_open
  require_next_step "$step"

  local top="" verdict now j_epoch r_epoch rounds
  case "$step" in
    run)
      step_artifact_done run "$run" || die "run has no result yet"
      # The run must have started inside this journey; an earlier run is another plan's result.
      # A manifest start time without a zone cannot be compared: the first checkpoint stands in.
      r_epoch="$(run_start_epoch "$run")" || die "that run has no start time"
      j_epoch="$(time_epoch "$J_STARTED")" || die "journey.json for $TARGET is not readable"
      [ "$r_epoch" -ge "$j_epoch" ] || die "that run started before this journey"
      top="\"runId\":$(json_quote "$run")"
      ;;
    verify)
      [ -n "$J_RUN" ] || die "no run is recorded for this journey"
      step_artifact_done verify "$J_RUN" || die "verify has no result yet"
      ;;
    analyze)
      step_artifact_done analyze || die "analyze has no result yet"
      verdict="$(analysis_verdict "$SPEC_DIR/analysis.md")"
      [ "$verdict" != none ] || die "analyze has no result yet"
      if [ "$verdict" = blocked ]; then
        rounds=$((J_ROUNDS + 1))
        if [ "$rounds" -ge 2 ]; then
          # Still BLOCKED after the second round: the journey stops; a person has to act.
          now="$(now_iso)" || exit 1
          journey_stepset "{\"set\":{\"analyzeRounds\":$rounds,\"state\":\"stopped\",\"stop\":{\"reason\":\"blocked\",\"detail\":\"the analysis is still BLOCKED after $rounds rounds\"},\"endedAt\":\"$now\"},\"steps\":{\"analyze\":{\"state\":\"done\"}}}"
        else
          journey_stepset "{\"set\":{\"analyzeRounds\":$rounds},\"steps\":{\"scenarios\":{\"state\":\"pending\"},\"analyze\":{\"state\":\"pending\"}}}"
        fi
        print_status
        return 0
      fi
      ;;
    *)
      step_artifact_done "$step" || die "$step has no result yet"
      ;;
  esac
  journey_stepset "{\"set\":{$top},\"steps\":{\"$step\":{\"state\":\"done\"}}}"
  print_status
}

cmd_signin() {
  parse_common "$@"
  [ "${#REST[@]}" -eq 0 ] || usage "signin does not take: ${REST[0]}"
  need_engine
  journey_read_open
  [ -f "$CONFIG" ] || die "no .qa/config.json; set the project up first"
  local out
  out="$(signin_json)" || die ".qa/config.json is not valid JSON"
  case "$out" in
    *'"ok":[]}') stop_journey no-sign-in "no persona has sign-in configured" ;;
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
  journey_require_open_strict
  in_list "$class" "$FORBIDDEN_CLASSES" && die "$class is never decided by an unattended journey"
  local none=0 src out
  [ "$evidence" = none ] && none=1
  src="$(rows_source "$DECISIONS")"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rsS --arg step "$step" --arg class "$class" --arg q "$question" --arg a "$answer" --arg ev "$evidence" \
      --arg none "$none" --arg conf "$confidence" --arg crit "$criteria" "$JQ_DEFS $JQ_ROWS"' rows_in
      | next_id("D") as $id
      | . + [{id: $id, step: $step, class: $class, question: $q, answer: $a,
              evidence: (if $none == "1" then null else $ev end), confidence: $conf,
              criteria: ($crit | split(",") | map(gsub("^[ \t\r\n]+|[ \t\r\n]+$"; "")) | map(select(length > 0))),
              assumption: true, needsPerson: ($none == "1"), second: null, secondReason: null}]
      | $id, norm' < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  else
    out="$(py decide "$step" "$class" "$question" "$answer" "$evidence" "$none" "$confidence" "$criteria" < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  fi
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
    journey_require_open_strict
    src="$(rows_source "$DECISIONS")"
    if [ "$ENGINE" = jq ]; then
      out="$(jq -rsS "$JQ_DEFS $JQ_ROWS"' rows_in
        | [ .[] | objects | select(.confidence == "low" and .second == null and .needsPerson != true) | .id ] as $ids
        | map(if type == "object" and .confidence == "low" and .second == null then .needsPerson = true else . end)
        | "{\"marked\":[\($ids | map(tojson) | join(","))]}", norm' < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
    else
      out="$(py unavailable < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
    fi
    # Without a decisions file there is nothing to mark and no file is made.
    if [ -f "$DECISIONS" ]; then rows_commit "$DECISIONS" "$out"; else ROWS_LINE='{"marked":[]}'; fi
    journey_stepset '{"set":{"secondLook":"unavailable"}}'
    printf '%s\n' "$ROWS_LINE"
    return 0
  fi
  [ "$words" -ge 1 ] || usage "second needs a decision id, or --unavailable"
  [ "$words" -eq 2 ] || usage "second needs stands or ask"
  one_of "$verdict" "stands ask" || usage "the second look is stands or ask"
  [ "$have_reason" -eq 1 ] || usage "second needs --reason"
  text_given "$reason" || usage "--reason cannot be empty"
  need_engine
  journey_require_open_strict
  src="$(rows_source "$DECISIONS")"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rsS --arg id "$id" --arg v "$verdict" --arg r "$reason" "$JQ_DEFS $JQ_ROWS"' rows_in
      | (map(type == "object" and .id == $id) | index(true)) as $i
      | if $i == null then "!missing"
        else
          (if .[$i].second == null or (.[$i].second == "stands" and $v == "ask")
           then .[$i] |= (.second = $v | .secondReason = $r | if $v == "ask" then .needsPerson = true else . end)
           else . end)
          | (.[$i] | "{\"id\":\(.id | tojson),\"needsPerson\":\(.needsPerson | tojson),\"second\":\(.second | tojson)}"), norm
        end' < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  else
    out="$(py second "$id" "$verdict" "$reason" < "$src" 2>/dev/null)" || die "decisions.json for $TARGET is not readable"
  fi
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
  journey_require_open_strict
  local now src out
  now="$(now_iso)" || exit 1
  src="$(rows_source "$NOTES")"
  if [ "$ENGINE" = jq ]; then
    out="$(jq -rsS --arg kind "$kind" --arg text "$text" --arg at "$now" "$JQ_DEFS $JQ_ROWS"' rows_in
      | next_id("N") as $id
      | . + [{id: $id, kind: $kind, text: $text, at: $at}]
      | $id, norm' < "$src" 2>/dev/null)" || die "notes.json for $TARGET is not readable"
  else
    out="$(py note "$kind" "$text" "$now" < "$src" 2>/dev/null)" || die "notes.json for $TARGET is not readable"
  fi
  rows_commit "$NOTES" "$out"
  printf '%s\n' "$ROWS_LINE"
}

# ---------------------------------------------------------------------------------------------
# The audit (design B5): files against the baseline, never the caller's account
# ---------------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# file_state <path> — sets FS_STATE (`1` a file, `0` nothing there, `!` there but not a file that
# can be read, such as a link that leads nowhere) and FS_PATH (the path, or /dev/null).
FS_STATE=0; FS_PATH=/dev/null
file_state() {
  if [ -f "$1" ] && [ -r "$1" ]; then FS_STATE=1; FS_PATH="$1"
  elif [ -e "$1" ] || [ -L "$1" ]; then FS_STATE="!"; FS_PATH=/dev/null
  else FS_STATE=0; FS_PATH=/dev/null; fi
}
# The jq side of the audit's file checks (the python side is the `audit` op of PY_HELPERS; the two
# are kept line for line alike). See the header for what each code means.
JQ_AUDIT='
  def rd($state; $text):
    ($text | ltrimstr("\ufeff")) as $text
    | if $state != "1" or ($text | test("^[ \t\r\n]*$")) then {ok: false, v: null}
      else (try {ok: true, v: ($text | fromjson)} catch {ok: false, v: null}) end;
  def look($d; $p): ($p | split(".")) as $k
    | if (try ($d | getpath($k[:-1]) | (type == "object" and has($k[-1]))) catch false)
      then {found: true, v: ($d | getpath($k))} else {found: false, v: null} end;
  def strs: if type == "array" then map(strings) else null end;
  rd("1"; $jt) as $jr
  | (if $jr.ok and ($jr.v | type) == "object" then $jr.v else error("not a journey") end) as $j
  | ($keys | split(" ")) as $keys
  | ($classes | split(" ")) as $classes
  | [ $extra | split(" ")[] | select(length > 0) ] as $extra
  | (if $bs == "0" then ["baseline-missing"]
     else
       rd($bs; $bt) as $b
       | ($b.ok and ($b.v | type) == "object") as $ok
       | (if ($ok | not) or $j.baselineHash != $bhash then ["baseline-changed"] else [] end)
       + (if ($ok | not) then [] else
           $b.v as $base
           # safety settings of the project config
           | rd($cs; $ct) as $c
           | ($base.safety | if type == "object" then . else null end) as $bsaf
           # the address the journey runs against (only a baseline that recorded it)
           | (if ($base | has("baseUrl") | not) then []
              elif ($c.ok | not) or (look($c.v; "baseUrl").v | if type == "string" then . else null end) != $base.baseUrl
              then ["base-url-changed"] else [] end)
           + [ $keys[] | . as $k | look($c.v; $k) as $l
               | select(($c.ok | not) or $bsaf == null or ($bsaf | has($k) | not) or $l.v != $bsaf[$k])
               | "safety-setting-changed:" + $k ]
           # safety keys of the spec run-config
           + ((if $rs == "0" then {ok: true, v: {}} else rd($rs; $rt) end) as $r
              | ($base.runConfigSafety | if type == "object" then . else null end) as $brc
              | [ $keys[] | . as $k | look($r.v; $k) as $l
                  | select(if ($r.ok | not) or $brc == null then true
                           elif $k == "profile" and $l.found and ($base.profile | type) == "string" and $l.v == $base.profile then false
                           else ($l.found != ($brc | has($k))) or ($l.found and $l.v != $brc[$k]) end)
                  | "run-config-safety:" + $k ])
           # the known-defect registry, by its bytes
           + (if (if $kdhash == "" then null else $kdhash end) != $base.knownDefectsHash then ["known-defects-changed"] else [] end)
           # the plan
           + ((if $ps == "0" then {ok: true, v: []} else rd($ps; $pt) end) as $pl
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
                         else [ ($ch - ($ch - $bh))[] | select(. as $i | ($bhh | has($i)) and $bhh[$i] != $hh[$i])
                                | "human-oracle-changed:" + . ] end)
                end)
           + (if $seed == "1" and $base.seedExists != true then ["seed-added"] else [] end)
           + (if $es == "0" then []
              else
                rd($es; $et) as $e
                | $base.exclusions as $be
                | if ($e.ok | not) then ["exclusion-added"]
                  elif ($be | type) == "array" and ($e.v | type) == "array"
                  then (if any($e.v[]; . as $x | all($be[]; . != $x)) then ["exclusion-added"] else [] end)
                  elif $e.v != $be then ["exclusion-added"] else [] end
              end)
         end)
     end) as $files
  | (if $ds == "0" then []
     else
       (if $ds == "1" and ($dt | test("^[ \t\r\n]*$")) then {ok: true, v: []} else rd($ds; $dt) end) as $d
       | if ($d.ok and ($d.v | type) == "array") | not then ["decisions-unreadable"]
         else [ $d.v | to_entries[] | select(.value | type == "object")
                | select(.value.class as $c | (($c | type) == "string" and any($classes[]; . == $c)) | not)
                | "forbidden-decision:" + (if (.value.id | type) == "string" then .value.id else "#\(.key + 1)" end) ]
         end
     end) as $decided
  | ($j.state == "stopped" and ($j.stop | type) == "object" and $j.stop.reason == "audit") as $failed
  | ($files + $decided + $extra + (if $failed then (($j.auditViolations | strs) // []) else [] end) | unique) as $all
  | ($failed or ($all | length) > 0) as $bad
  | "{\"ok\":\($bad | not),\"violations\":\($all | tojson)}",
    (if ($bad | not) or ($failed and $j.auditViolations == $all) then empty
     else
       $j + (if $failed then {} else {state: "stopped", endedAt: $now, stopBeforeAudit: $j.stop} end)
          + {stop: {reason: "audit", detail: ($all | join(", "))}, auditViolations: $all}
       | norm
     end)'
# audit_files — every check that reads the project's files against baseline.json and the journey's
# own record, in one engine call. Prints the result line and, when the journey changes, the new
# journey.json after it (the shape rows_commit takes).
audit_files() {
  local bs bf cs cf rs rf ps pf es ef ds df bhash="" kdhash="" seed=0 now hh=""
  file_state "$BASELINE"; bs="$FS_STATE"; bf="$FS_PATH"
  [ "$bs" = 1 ] && bhash="$(hash_or "$BASELINE")"
  file_state "$CONFIG"; cs="$FS_STATE"; cf="$FS_PATH"
  file_state "$SPEC_DIR/run-config.json"; rs="$FS_STATE"; rf="$FS_PATH"
  file_state "$SPEC_DIR/checklist.json"; ps="$FS_STATE"; pf="$FS_PATH"
  file_state "$SPEC_DIR/coverage-exclusions.json"; es="$FS_STATE"; ef="$FS_PATH"
  file_state "$DECISIONS"; ds="$FS_STATE"; df="$FS_PATH"
  file_state "$QA_DIR/known-defects.json"; [ "$FS_STATE" = 0 ] || kdhash="$(hash_or "$QA_DIR/known-defects.json")"
  file_state "$SPEC_DIR/seed.json"; [ "$FS_STATE" = 0 ] || seed=1
  now="$(now_iso)" || exit 1
  if [ "$ENGINE" = jq ]; then
    # jq cannot hash: the hashes of the person-confirmed rows as they are now are handed in.
    # (The python side works them out itself, from the same rows.)
    if [ "$bs" = 1 ] && [ "$ps" = 1 ]; then hh="$(plan_hashes "$pf")" || hh=""; fi
    [ -n "$hh" ] || hh="{}"
    jq -rnS --argjson hh "$hh" --rawfile jt "$JOURNEY" --rawfile bt "$bf" --rawfile ct "$cf" --rawfile rt "$rf" --rawfile pt "$pf" \
      --rawfile et "$ef" --rawfile dt "$df" --arg bs "$bs" --arg cs "$cs" --arg rs "$rs" --arg ps "$ps" --arg es "$es" \
      --arg ds "$ds" --arg bhash "$bhash" --arg kdhash "$kdhash" --arg seed "$seed" --arg now "$now" \
      --arg keys "$SAFETY_KEYS" --arg classes "$DECIDABLE_CLASSES" --arg extra "$CODES" "$JQ_DEFS $JQ_PLAN $JQ_AUDIT" 2>/dev/null
  else
    py audit "$JOURNEY" "$bs" "$bf" "$cs" "$cf" "$rs" "$rf" "$ps" "$pf" "$es" "$ef" "$ds" "$df" \
      "$bhash" "$kdhash" "$seed" "$now" "$SAFETY_KEYS" "$DECIDABLE_CLASSES" "$CODES" 2>/dev/null
  fi
}
# audit_steps — a step marked done whose result is not on disk; a finished journey nobody verified.
# A step the journey never reached is not looked at.
audit_steps() {
  local s
  for s in constitution spec scenarios analyze run; do
    [ "$(step_state "$s")" = done ] || continue
    step_artifact_done "$s" "$J_RUN" || code "step-without-result:$s"
  done
  if [ "$J_STATE" = done ] || [ "$(step_state verify)" = done ]; then
    step_artifact_done verify "$J_RUN" || code not-verified
  fi
}
# audit_tracker — ask the tracker whether the spec's cards are behind. Only its exit code and its
# stdout are used; its stderr is dropped, because it can carry an API error line.
audit_tracker() {
  local out rc guard="" secs="${QA_AUTO_TRACKER_TIMEOUT:-60}" verdict
  case "$secs" in ""|*[!0-9]*) secs=60 ;; esac
  # A time guard only where one is installed (macOS has no `timeout` of its own).
  if command -v timeout >/dev/null 2>&1; then guard=timeout
  elif command -v gtimeout >/dev/null 2>&1; then guard=gtimeout; fi
  if [ -n "${QA_AUTO_TRACKER_CMD+x}" ]; then
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
  case "$out" in
    *'"behind"'*)
      if [ "$ENGINE" = jq ]; then
        verdict="$(printf '%s\n' "$out" | jq -Rrn '[ inputs | (try fromjson catch null) | objects | select(has("behind")) | .behind ]
          | if length == 0 then "none" elif all(.[]; . == false) then "ok" else "behind" end' 2>/dev/null)" || verdict=none
      else
        verdict="$(printf '%s\n' "$out" | py behind 2>/dev/null)" || verdict=none
      fi
      [ "$verdict" = ok ] || code tracker-behind ;;
    *not-set-up*) ;;
    *) code tracker-behind ;;
  esac
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
  # A failed audit closes the journey as stopped / audit; a passing one writes nothing.
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
# The jq side of the handoff facts (the python side is the `facts` op of PY_HANDOFF; the two are
# kept alike). One fact per line, fields split by U+001F, every text made one line by `clean`:
#   S <file> <ok|absent|bad>      decisions, notes, plan, results (checkpoint.json), second
#                                 (verification.json; also `override`: a row that is not about a
#                                 recorded non-pass does not say pass)
#   J <1|0>                       the journey was restarted
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
  def rd($state; $text; $empty_ok):
    ($text | ltrimstr("﻿")) as $t
    | if $state != "1" then {ok: false, v: null}
      elif ($t | test("\\A[ \t\r\n]*\\z")) then (if $empty_ok then {ok: true, v: []} else {ok: false, v: null} end)
      else (try {ok: true, v: ($t | fromjson)} catch {ok: false, v: null}) end;
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
      ["J", ($j.restartedFrom != null | b)],
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
# The python side of the handoff, a program of its own (the other verbs do not pay for compiling
# it). `head`: what cmd_handoff needs first (HANDOFF_HEAD below). `facts`: the lines JQ_HANDOFF
# describes.
PY_HANDOFF='
import json, re, sys
op, a = sys.argv[1], sys.argv[2:]
def num(v):
    # whole-valued floats print as integers, as jq prints them
    if isinstance(v, float) and v.is_integer() and abs(v) < 1e17:
        v = int(v)
    return json.dumps(v)
try:
    if op == "head":
        # journey, the state of the config (1 there), the config
        def load(p):
            with open(p, encoding="utf-8-sig") as f:
                return json.load(f)
        def s(v):
            return v.replace("\r", " ").replace("\n", " ") if isinstance(v, str) else ""
        def s2(v):
            return s(v).replace("\t", " ")
        j = load(a[0])
        if not isinstance(j, dict):
            sys.exit(1)
        st = j.get("stop") if isinstance(j.get("stop"), dict) else {}
        sb = j.get("stopBeforeAudit") if isinstance(j.get("stopBeforeAudit"), dict) else {}
        out = [s(j.get("state")), s(st.get("reason")), s(j.get("profile")), s(j.get("runId")), s(sb.get("reason"))]
        c = None
        if a[1] == "1":
            try:
                c = load(a[2])
            except Exception:
                c = None
        if not isinstance(c, dict):
            out.append("0")
        else:
            out.append("1")
            au = c.get("auth")
            out.append(s2(au.get("storageState")) if isinstance(au, dict) else "")
            for x in (c.get("personas") if isinstance(c.get("personas"), list) else []):
                if isinstance(x, dict) and isinstance(x.get("id"), str):
                    out.append(json.dumps(x["id"], ensure_ascii=False) + "\t" + s2(x.get("auth")))
        sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
    elif op == "facts":
        # What `handoff` writes its list from: one fact per line, fields split by U+001F, every
        # text on one line (clean). Arguments: journey, then a state (1 there, 0 absent, ! there
        # but not a readable file) and a path for each of decisions, notes, the plan, the cards
        # file, the checkpoint and the verification of the run, the records file and the journeys
        # of the run, then the sign-in line. The jq side is JQ_HANDOFF; the two are kept alike.
        jf = a[0]
        ds, df, ns, nf, ps, pf, cs, cf, ks, kf, vs, vf, rs, rf, ys, yf, signin = a[1:18]
        out = []
        def put(*f):
            out.append("\x1f".join(f))
        def rd(state, path, empty_ok=False):
            if state != "1":
                return False, None
            try:
                with open(path, "rb") as f:
                    t = f.read().decode("utf-8")
                if t.startswith("﻿"):
                    t = t[1:]
                if t.strip(" \t\r\n") == "":
                    return (True, []) if empty_ok else (False, None)
                return True, json.loads(t)
            except Exception:
                return False, None
        def clean(v):
            # one line of text: control characters are blanks, runs of blanks are one, none at the ends
            if not isinstance(v, str):
                return ""
            s = "".join(" " if (ord(c) < 32 or 127 <= ord(c) < 160) else ("�" if 0xD800 <= ord(c) < 0xE000 else c) for c in v)
            return re.sub(" +", " ", s).strip(" ")
        def low(v):
            return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in v) if isinstance(v, str) else ""
        def b(x):
            return "1" if x else "0"
        def rows_of(doc, keys):
            if isinstance(doc, list):
                return doc
            if isinstance(doc, dict):
                for k in keys:
                    if isinstance(doc.get(k), list):
                        return doc[k]
            return None
        def cid(r):
            for k in ("criterion_id", "criterionId", "id"):
                if isinstance(r.get(k), str) and r[k] != "":
                    return r[k]
            return None
        def who(r):
            return r["persona"] if isinstance(r.get("persona"), str) else ""
        def rtext(v):
            if isinstance(v, str):
                return clean(v)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                return num(v)
            return ""
        ok, j = rd("1", jf)
        if not ok or not isinstance(j, dict):
            sys.exit(1)
        okd, dec = rd(ds, df, True)
        okn, notes = rd(ns, nf, True)
        okp, plan = rd(ps, pf)
        okc, cards = rd(cs, cf)
        okk, cp = rd(ks, kf)
        okv, ver = rd(vs, vf)
        okr, recs = rd(rs, rf, True)
        oky, jour = rd(ys, yf)
        # the plan: of two rows with one id the first counts
        prow = {}
        for r in (plan if okp and isinstance(plan, list) else []):
            if isinstance(r, dict) and isinstance(r.get("id"), str) and r["id"] not in prow:
                prow[r["id"]] = r
        # the title of a check: the cards file, else the row itself, else its id
        titles = {}
        cl = cards.get("cards") if okc and isinstance(cards, dict) else None
        for c in (cl if isinstance(cl, list) else []):
            ch = c.get("checks") if isinstance(c, dict) else None
            for x in (ch if isinstance(ch, list) else []):
                if isinstance(x, dict) and isinstance(x.get("criterion"), str) and clean(x.get("title")) != "" and x["criterion"] not in titles:
                    titles[x["criterion"]] = clean(x["title"])
        def title(i):
            if i in titles:
                return titles[i]
            r = prow.get(i)
            t = (clean(r.get("title")) or clean(r.get("label"))) if r is not None else ""
            return t or clean(i)
        # top priority, failing closed: a row of the plan marked P1, a row with no priority, a
        # step of a P1 journey of the run, and any id the plan does not have
        jp1 = set()
        for x in (jour if oky and isinstance(jour, list) else []):
            if isinstance(x, dict) and x.get("priority") == "P1" and isinstance(x.get("steps"), list):
                for s in x["steps"]:
                    s = s.get("criterionId") if isinstance(s, dict) else s
                    if isinstance(s, str):
                        jp1.add(s)
        def p1(i):
            r = prow.get(i)
            return r is None or not isinstance(r.get("priority"), str) or r["priority"] == "P1" or i in jp1
        dstat = "absent" if ds == "0" else ("ok" if okd and isinstance(dec, list) else "bad")
        decs = [r for r in dec if isinstance(r, dict)] if dstat == "ok" else []
        nstat = "absent" if ns == "0" else ("ok" if okn and isinstance(notes, list) else "bad")
        pstat = "absent" if ps == "0" else ("ok" if okp and isinstance(plan, list) else "bad")
        krows = rows_of(cp, ["criteria"]) if okk else None
        kstat = "absent" if ks == "0" else ("ok" if krows is not None else "bad")
        vrows = rows_of(ver, ["rows", "criteria"]) if okv else None
        # the second check: `override` when a row that is not about a recorded non-pass does not say pass
        if vs == "0":
            vstat = "absent"
        elif vrows is None or any(not isinstance(r, dict) for r in vrows):
            vstat = "bad"
        elif any(low(r.get("inRunVerdict")) not in ("fail", "blocked", "deferred", "error") and low(r.get("verifierVerdict")) != "pass" for r in vrows):
            vstat = "override"
        else:
            vstat = "ok"
        put("S", "decisions", dstat)
        put("S", "notes", nstat)
        put("S", "plan", pstat)
        put("S", "results", kstat)
        put("S", "second", vstat)
        put("J", b(j.get("restartedFrom") is not None))
        # what the audit found: the code word, and its key, step, check title or question
        av = j.get("auditViolations")
        for code in (av if isinstance(av, list) else []):
            if not isinstance(code, str):
                continue
            parts = code.split(":")
            w, arg = parts[0], ":".join(parts[1:])
            if w in ("human-oracle-added", "human-oracle-removed", "human-oracle-changed", "plan-row-removed"):
                arg = title(arg)
            elif w == "forbidden-decision":
                arg = clean(next((r.get("question") for r in decs if r.get("id") == arg), None))
            else:
                arg = clean(arg)
            put("V", clean(w), arg)
        # decisions: needs a person, and whether a top priority check rests on it (no checks named
        # means the whole spec)
        for r in decs:
            needs = needs_person(r)
            cr = r.get("criteria")
            ids = [c for c in cr if isinstance(c, str)] if isinstance(cr, list) else []
            rests = needs and (len(ids) == 0 or any(p1(c) for c in ids))
            put("D", clean(r.get("step")), clean(r.get("class")), b(needs), b(rests), b(r.get("evidence") is None),
                clean(r.get("question")), clean(r.get("answer")), clean(r.get("evidence")))
        # expected values that are only a proposal: a calculated check, or any check that names a
        # source, whose source is neither a person nor a cited spec line
        oset = set()
        for i, r in prow.items():
            fx = r.get("fixture")
            ex = fx.get("expect") if isinstance(fx, dict) else None
            src = ex.get("oracleSource") if isinstance(ex, dict) else None
            if (r.get("kind") in ("computed-logic", "business-rule") or src is not None) and src not in ("human", "spec"):
                oset.add(i)
                put("O", b(p1(i)), title(i))
        # checks that passed at low confidence: the latest record of each check and role, after
        # the second check; a confidence is never read as better than either file says
        ov = {}
        for r in (vrows or []):
            if isinstance(r, dict) and cid(r) is not None and isinstance(r.get("verifierVerdict"), str):
                ov[(cid(r), who(r))] = r
        latest = {}
        for r in (krows or []):
            if isinstance(r, dict) and cid(r) is not None:
                latest[(cid(r), who(r))] = r
        for (i, persona), r in latest.items():
            verdict = low(r.get("verdict"))
            lowc = r.get("confidence") != "high"
            o = ov.get((i, persona))
            if o is not None and o.get("inRunVerdict") == verdict:
                if o["verifierVerdict"] in ("pass", "fail", "blocked", "deferred", "error"):
                    verdict = o["verifierVerdict"]
                if isinstance(o.get("confidence"), str) and o["confidence"] not in ("", "high"):
                    lowc = True
            if verdict == "pass" and lowc and i not in oset:
                put("L", b(p1(i)), title(i), clean(persona))
        try:
            si = json.loads(signin)
        except Exception:
            si = None
        ms = si.get("missing") if isinstance(si, dict) else None
        for x in (ms if isinstance(ms, list) else []):
            if isinstance(x, str):
                put("P", clean(x))
        for r in (notes if nstat == "ok" else []):
            if isinstance(r, dict) and clean(r.get("text")) != "":
                put("N", clean(r.get("kind")), clean(r.get("text")))
        for r in (recs if okr and isinstance(recs, list) else []):
            if isinstance(r, dict):
                e, i = rtext(r.get("entity")), rtext(r.get("id"))
                if e != "" or i != "":
                    put("R", e, i)
        sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
    else:
        sys.exit(2)
except SystemExit:
    raise
except Exception:
    sys.exit(1)
'
py_handoff() { PYTHONUTF8=1 python3 -c "$PY_NEEDS$PY_HANDOFF" "$@"; }
# The jq side of `head`. Lines: the journey state, its stop reason, its launch profile, its run
# id, the stop it had before a failed audit; then 1 or 0 (the project config is one JSON object);
# then, after a 1, the lines signin_from reads (the storageState, then one line per persona).
JQ_HANDOFF_HEAD='
  def s: if type == "string" then gsub("[\r\n]"; " ") else "" end;
  def s2: if type == "string" then gsub("[\r\n\t]"; " ") else "" end;
  ($jt | ltrimstr("\ufeff") | fromjson) as $j
  | (if ($j | type) == "object" then $j else error("not a journey") end) as $j
  | ($j.stop | if type == "object" then . else {} end) as $st
  | ($j.stopBeforeAudit | if type == "object" then . else {} end) as $sb
  | ($j.state | s), ($st.reason | s), ($j.profile | s), ($j.runId | s), ($sb.reason | s),
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
    py_handoff head "$JOURNEY" "$FS_STATE" "$FS_PATH" 2>/dev/null
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
      --arg ks "$ks" --arg vs "$vs" --arg rs "$rs" --arg ys "$ys" --arg signin "$signin" "$JQ_NEEDS $JQ_HANDOFF" 2>/dev/null
  else
    py_handoff facts "$JOURNEY" "$ds" "$df" "$ns" "$nf" "$ps" "$pf" "$cs" "$cf" "$ks" "$kf" "$vs" "$vf" "$rs" "$rf" "$ys" "$yf" "$signin" 2>/dev/null
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
#   not verified   the journey is still open; or it has no run; or a file the result is decided
#                  from cannot be read (see below); or, with no ship verdict in the report, the
#                  run has no verification.json or it records a pass that verification did not
#                  leave a pass
#   not ready      the run's report says NOT SHIP-READY (ship_read), with its conditions in plain words
#   verified       the report has no ship section, the journey was not launched as `ship`, and
#                  verification.json is there, readable and records no such override
#   not confirmed  the report says SHIP-READY and a top priority check rests on a person: a
#                  decision that needs a person (JQ_NEEDS) and names no check, or names a top
#                  priority check; or a top priority expected value that is only a proposal
#   ready          the report says SHIP-READY and none of that holds
# Under a SHIP-READY report the result is `not verified` when verification.json is absent or
# unreadable, or checkpoint.json, decisions.json (when there is one) or the plan cannot be read.
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
  local facts v state="" reason="" profile="" run="" before="" cfgok=0 signin=""
  facts="$(handoff_head)" && [ -n "$facts" ] || die "journey.json for $TARGET is not readable"
  for v in state reason profile run before cfgok; do
    printf -v "$v" '%s' "${facts%%"$NL"*}"
    case "$facts" in *"$NL"*) facts="${facts#*"$NL"}" ;; *) facts="" ;; esac
  done
  one_of "$state" "open done stopped" || die "journey.json for $TARGET is not readable"
  # A run id is one plain directory name; anything else is no run.
  case "$run" in ""|.|..|*/*|-*) run="" ;; esac
  # Personas whose sign-in is not set up (nothing is said about them when the config cannot be read).
  [ "$cfgok" != 1 ] || signin="$(signin_from "$facts")"
  facts="$(handoff_facts "$run" "$records" "$signin")" && [ -n "$facts" ] || die "journey.json for $TARGET is not readable"

  # ---- read the facts ----
  local k f1 f2 f3 f4 f5 f6 f7 f8 item
  local dstat=absent nstat=absent pstat=absent kstat=absent vstat=absent restarted=0
  local viol="" scope="" needs="" recs="" count=0 noev=0 p1pending=0
  local d_constitution="" d_spec="" d_scenarios="" d_analyze="" d_run="" d_verify="" d_other=""
  while IFS="$US" read -r k f1 f2 f3 f4 f5 f6 f7 f8; do
    case "$k" in
      S) case "$f1" in
           decisions) dstat="$f2" ;; notes) nstat="$f2" ;; plan) pstat="$f2" ;; results) kstat="$f2" ;; second) vstat="$f2" ;;
         esac ;;
      J) restarted="$f1" ;;
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
  local result="not verified" line="Not verified." why="" clause
  if [ "$state" = stopped ]; then
    result=stopped
    clause="$(stop_plain "$reason")"
    [ -n "$clause" ] || clause="the reason was not recorded"
    line="Stopped: $clause."
  elif [ "$state" = open ]; then
    why="This journey has not finished."
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
        elif [ "$kstat" != ok ]; then why="The results of the run could not be read."
        elif [ "$dstat" = bad ] || [ "$pstat" != ok ]; then why="The decisions or the plan of checks could not be read."
        elif [ "$p1pending" -eq 1 ]; then result="not confirmed"; line="Not confirmed: $count items need a person."
        else
          result=ready; line="Ready."
          [ "$count" -eq 0 ] || why="Some items still need a person. They are listed below, and none rests on a top priority check."
        fi ;;
    esac
  fi

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
  out="$out- Then run \`/qa-auto $TARGET\` again. It starts a new journey on the confirmed plan."
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
