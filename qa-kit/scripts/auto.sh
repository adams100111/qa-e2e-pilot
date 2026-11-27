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
#   auto.sh resume <target> [--max-hours <n>]
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
#
#   start, resume, stop, status, step-start and step-done print ONE JSON line: journey.json plus
#   {"needsPerson": n}. status writes nothing. next and signin print their own one line.
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
# rows_commit, one_of, text_given, json_get/json_strs/
# json_pick/json_merge, journey_stepset, stop_journey, print_status, print_stopped, now_iso,
# iso_add_hours, iso_epoch, step_artifact_done, step_state, first_open_step, signin_json, read_lines).
set -uo pipefail

# ---------------------------------------------------------------------------------------------
# Fixed values (plan decisions J1, J2, J6)
# ---------------------------------------------------------------------------------------------
STEPS="constitution spec scenarios analyze run verify"
RESUMABLE_REASONS="time-limit step-failed until"
FINAL_REASONS="blocked audit no-sign-in tracker"
SAFETY_KEYS="allowApiWrites seedableEnvMarker environment allowBlackboxCrawl gates profile humanInteraction.enforce humanInteraction.maxOptOutRate"
DEFAULT_MAX_HOURS=6
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
       auto.sh resume <target> [--max-hours <n>] [--project <dir>]
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
PY_HELPERS='
import calendar, json, math, re, sys, time
op, a = sys.argv[1], sys.argv[2:]
def load(p):
    with open(p, encoding="utf-8") as f:
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
def emit(v, pretty=False):
    v = norm(v)
    if pretty:
        s = json.dumps(v, sort_keys=True, indent=2, ensure_ascii=False)
    else:
        s = json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    # jq writes U+007F as an escape; a raw one can only be inside a string, so this is safe
    sys.stdout.buffer.write((s.replace("\x7f", "\\u007f") + "\n").encode("utf-8"))
def jstr(v):
    return json.dumps(v, ensure_ascii=False).replace("\x7f", "\\u007f")
def rows_in():
    # the array on stdin; nothing at all (no file yet) is an empty array
    t = sys.stdin.buffer.read().decode("utf-8")
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
    elif op == "humanids":
        rows = load(a[0])
        ids = set()
        for r in (rows if isinstance(rows, list) else []):
            if not isinstance(r, dict):
                continue
            fx = r.get("fixture")
            ex = fx.get("expect") if isinstance(fx, dict) else None
            if isinstance(ex, dict) and ex.get("oracleSource") == "human" and isinstance(r.get("id"), str):
                ids.add(r["id"])
        emit(sorted(ids))
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
    elif op == "counttrue":
        rows = load(a[0])
        emit(len([r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict) and r.get(a[1]) is True]))
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
# json_write <file> — stdin (JSON text) → the file, pretty-printed with sorted keys, replaced
# atomically. Refuses any path outside the journey directory.
json_write() {
  local dest="$1" tmp
  case "$dest" in "$AUTO_DIR"/*) ;; *) die "internal: refused to write outside the journey directory" ;; esac
  tmp="$dest.tmp.$$"
  if [ "$ENGINE" = jq ]; then jq -S "$JQ_DEFS norm" > "$tmp" 2>/dev/null; else py pretty > "$tmp" 2>/dev/null; fi
  if [ "$?" -ne 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp"; die "could not write ${dest#"$PROJECT"/}"; fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "could not write ${dest#"$PROJECT"/}"; }
}
# json_merge <file> <json object> — set top-level keys of a journey file in place.
json_merge() {
  local out
  out="$(json_patch "$1" "$2")" && [ -n "$out" ] || die "could not update ${1#"$PROJECT"/}"
  printf '%s\n' "$out" | json_write "$1"
}
# json_count_true <file> <key> — how many objects of a top-level array have <key> == true.
json_count_true() {
  if [ "$ENGINE" = jq ]; then
    jq -c --arg k "$2" '[ (if type == "array" then .[] else empty end) | select(type == "object") | select(.[$k] == true) ] | length' "$1" 2>/dev/null
  else py counttrue "$1" "$2" 2>/dev/null; fi
}
# checklist_human_ids <checklist.json> — sorted ids of the rows whose fixture.expect.oracleSource is "human".
checklist_human_ids() {
  if [ "$ENGINE" = jq ]; then
    jq -c '[ (if type == "array" then .[] else empty end) | select(type == "object")
             | select((.fixture | type) == "object" and (.fixture.expect | type) == "object"
                      and .fixture.expect.oracleSource == "human")
             | .id | strings ] | unique' "$1" 2>/dev/null
  else py humanids "$1" 2>/dev/null; fi
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
# valid_hours <text> — a positive whole or decimal number.
valid_hours() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  case "$1" in *[1-9]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------------------------
# Paths and arguments
# ---------------------------------------------------------------------------------------------
PROJECT="."; TARGET=""
QA_DIR=""; CONFIG=""; SPEC_DIR=""; AUTO_DIR=""; JOURNEY=""; BASELINE=""; DECISIONS=""; NOTES=""
REST=()

# parse_common "$@" — takes the target (first bare word) and `--project <dir>` out of a verb's
# arguments, sets the path variables, and leaves everything else, in order, in REST.
parse_common() {
  REST=()
  local seen_target=0 expect_value=0
  while [ "$#" -gt 0 ]; do
    if [ "$expect_value" -eq 1 ]; then REST+=("$1"); expect_value=0; shift; continue; fi
    case "$1" in
      --project) [ "$#" -ge 2 ] || usage "--project needs a directory"; PROJECT="$2"; shift 2 ;;
      --*) REST+=("$1"); flag_takes_value "$1" && expect_value=1; shift ;;
      *) if [ "$seen_target" -eq 0 ]; then TARGET="$1"; seen_target=1; else REST+=("$1"); fi; shift ;;
    esac
  done
  [ "$seen_target" -eq 1 ] || usage "a target is needed"
  case "$TARGET" in
    ""|.|..|*/*|-*) usage "not a usable target name: $TARGET" ;;
  esac
  [ -d "$PROJECT" ] || die "no such project directory: $PROJECT"
  PROJECT="${PROJECT%/}"; [ -n "$PROJECT" ] || PROJECT="/"
  QA_DIR="$PROJECT/.qa"
  CONFIG="$QA_DIR/config.json"
  SPEC_DIR="$QA_DIR/specs/$TARGET"
  AUTO_DIR="$SPEC_DIR/auto"
  JOURNEY="$AUTO_DIR/journey.json"
  BASELINE="$AUTO_DIR/baseline.json"
  DECISIONS="$AUTO_DIR/decisions.json"
  NOTES="$AUTO_DIR/notes.json"
}
# flag_takes_value <flag> — true for the flags whose next word is their value (so that word is
# never mistaken for the target). Add a verb's value flags here.
flag_takes_value() {
  case "$1" in
    --profile|--until|--max-hours|--reason|--detail|--run|--step|--class|--question|--answer|--evidence|--confidence|--criteria|--records|--kind|--text) return 0 ;;
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
# there is no readable journey) and J_REASON (the stop reason, or empty).
J_STATE=""; J_REASON=""
journey_load() {
  J_STATE=""; J_REASON=""
  [ -f "$JOURNEY" ] || return 0
  read_lines "$(json_strs "$JOURNEY" state stop.reason)" J_STATE J_REASON
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
# a result line (a refusal such as `!missing`) writes nothing.
ROWS_LINE=""
rows_commit() {
  local dest="$1" out="$2" nl=$'\n' tmp
  case "$dest" in "$AUTO_DIR"/*) ;; *) die "internal: refused to write outside the journey directory" ;; esac
  ROWS_LINE="${out%%"$nl"*}"
  case "$out" in *"$nl"*) ;; *) return 0 ;; esac
  tmp="$dest.tmp.$$"
  if ! printf '%s\n' "${out#*"$nl"}" > "$tmp" || [ ! -s "$tmp" ]; then rm -f "$tmp"; die "could not write ${dest#"$PROJECT"/}"; fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "could not write ${dest#"$PROJECT"/}"; }
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
# other_open_target — the name of another target whose journey is open in this project, if any.
# This is the "one journey per project" lock: any .qa/specs/*/auto/journey.json with state open.
other_open_target() {
  local f t
  for f in "$QA_DIR"/specs/*/auto/journey.json; do
    [ -f "$f" ] || continue
    t="${f%/auto/journey.json}"; t="${t##*/}"
    [ "$t" = "$TARGET" ] && continue
    if [ "$(json_strs "$f" state)" = open ]; then printf '%s\n' "$t"; return 0; fi
  done
  return 0
}
# needs_person_count — decisions that need a person (0 without a decisions file).
needs_person_count() {
  local n=""
  [ -f "$DECISIONS" ] && n="$(json_count_true "$DECISIONS" needsPerson)"
  case "$n" in ""|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}
# print_status — one line: journey.json plus {"needsPerson": n}. Writes nothing.
print_status() {
  local out
  out="$(json_patch "$JOURNEY" "{\"needsPerson\":$(needs_person_count)}")" && [ -n "$out" ] || die "journey.json for $TARGET is not readable"
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
# are optional, `bump` adds one to the step's attempts.
journey_stepset() {
  local tmp="$JOURNEY.tmp.$$" rc
  if [ "$ENGINE" = jq ]; then
    jq -S --argjson p "$1" "$JQ_DEFS"' if type == "object" and (.steps | type) == "array" then . else error("not a journey") end
      | . + ($p.set // {})
      | .steps |= map(. as $x | (if type == "object" then ($p.steps // {})[$x.name // ""] else null end) as $u
          | if $u then (if $u.state then .state = $u.state else . end)
                       | (if $u.bump then .attempts = ((.attempts // 0) + 1) else . end)
            else . end)
      | norm' "$JOURNEY" > "$tmp" 2>/dev/null; rc=$?
  else
    py stepset "$JOURNEY" "$1" > "$tmp" 2>/dev/null; rc=$?
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp"; die "could not update ${JOURNEY#"$PROJECT"/}"; fi
  mv -f "$tmp" "$JOURNEY" || { rm -f "$tmp"; die "could not update ${JOURNEY#"$PROJECT"/}"; }
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
  local facts ss line idj ok="" missing="" n=0
  if [ "$ENGINE" = jq ]; then
    facts="$(jq -rs 'def s: if type == "string" then gsub("[\r\n\t]"; " ") else "" end;
      '"$JQ_ONE"' | if type != "object" then error("not an object") else . end
      | ((.auth | if type == "object" then .storageState else null end) | s),
        ((.personas | if type == "array" then .[] else empty end)
          | select(type == "object" and (.id | type) == "string") | "\(.id | tojson)\t\(.auth | s)")' < "$CONFIG" 2>/dev/null)" || return 1
  else
    facts="$(py personas "$CONFIG" 2>/dev/null)" || return 1
  fi
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
# archive_journey — move everything in auto/ except history/ to auto/history/<n>/.
archive_journey() {
  local n=0 d b f moved=0
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
    if [ "$moved" -eq 0 ]; then mkdir -p "$AUTO_DIR/history/$n" || die "could not create the history directory"; moved=1; fi
    mv "$f" "$AUTO_DIR/history/$n/" || die "could not move the earlier journey to history"
  done
}

# ---------------------------------------------------------------------------------------------
# Environment rules (plan decision J7; design B2)
# ---------------------------------------------------------------------------------------------
# url_host <url> — the lower-case host of a URL.
url_host() {
  local u="$1" h
  case "$u" in *://*) u="${u#*://}" ;; esac
  u="${u%%/*}"; u="${u%%\?*}"; u="${u%%#*}"; u="${u##*@}"
  case "$u" in
    \[*) h="${u%%]*}]" ;;
    *)   h="${u%%:*}" ;;
  esac
  printf '%s' "$h" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}
# is_local_url <url> — exit 0 for a local host.
is_local_url() {
  case "$(url_host "$1")" in
    localhost|127.0.0.1|'[::1]'|*.localhost|*.test|*.local|*.ddev.site) return 0 ;;
    *) return 1 ;;
  esac
}
# env_is_production <environment> <baseUrl> <seedableEnvMarker> — production is
# `environment: production`, or any environment other than `disposable` on a non-local baseUrl
# whose seedableEnvMarker is empty or the bootstrap sentinel (the rule the engine's pre-flight
# applies; `auto` is the default).
env_is_production() {
  local env="${1:-auto}"
  [ "$env" = production ] && return 0
  [ "$env" = disposable ] && return 1
  is_local_url "$2" && return 1
  [ -z "$3" ] || [ "$3" = QA_DISPOSABLE_ENV ]
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
  if command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256 "$1" 2>/dev/null)"
  elif command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum "$1" 2>/dev/null)"
  elif command -v openssl >/dev/null 2>&1; then out="$(openssl dgst -sha256 -r "$1" 2>/dev/null)"
  elif has_py; then out="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null)"
  fi
  out="${out%% *}"
  [ "${#out}" -eq 64 ] || die "could not hash ${1#"$PROJECT"/}"
  printf '%s\n' "$out"
}
# baseline_json <profile> <now> — prints the baseline (compact JSON) from the files as they are now.
baseline_json() {
  local profile="$1" now="$2" safety rcs ids excl kd seed
  # shellcheck disable=SC2086
  safety="$(json_pick "$CONFIG" all $SAFETY_KEYS)"
  [ -n "$safety" ] || die ".qa/config.json is not valid JSON"
  rcs="{}"
  if [ -f "$SPEC_DIR/run-config.json" ]; then
    # shellcheck disable=SC2086
    rcs="$(json_pick "$SPEC_DIR/run-config.json" present $SAFETY_KEYS)"
    [ -n "$rcs" ] || die ".qa/specs/$TARGET/run-config.json is not valid JSON"
  fi
  ids="[]"
  if [ -f "$SPEC_DIR/checklist.json" ]; then
    ids="$(checklist_human_ids "$SPEC_DIR/checklist.json")"
    [ -n "$ids" ] || die ".qa/specs/$TARGET/checklist.json is not valid JSON"
  fi
  excl="[]"
  if [ -f "$SPEC_DIR/coverage-exclusions.json" ]; then
    excl="$(json_get "$SPEC_DIR/coverage-exclusions.json" "")"
    [ -n "$excl" ] || die ".qa/specs/$TARGET/coverage-exclusions.json is not valid JSON"
  fi
  seed=false; [ -f "$SPEC_DIR/seed.json" ] && seed=true
  kd=null; [ -f "$QA_DIR/known-defects.json" ] && kd="\"$(file_sha256 "$QA_DIR/known-defects.json")\""
  printf '{"version":1,"target":%s,"takenAt":"%s","profile":"%s","safety":%s,"runConfigSafety":%s,"humanOracleIds":%s,"seedExists":%s,"exclusions":%s,"knownDefectsHash":%s}\n' \
    "$(target_json)" "$now" "$profile" "$safety" "$rcs" "$ids" "$seed" "$excl" "$kd"
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
  valid_hours "$hours" || usage "--max-hours must be a number above zero"
  need_engine

  # Preconditions (design B2), in order. Nothing is written until all of them hold.
  [ -f "$CONFIG" ] || die "no .qa/config.json; set the project up first"
  local facts c_env c_base c_marker c_profile
  facts="$(json_strs "$CONFIG" environment baseUrl seedableEnvMarker profile)" || die ".qa/config.json is not valid JSON"
  read_lines "$facts" c_env c_base c_marker c_profile
  env_is_production "$c_env" "$c_base" "$c_marker" && die "this environment is production; an unattended journey does not run there"
  [ "$kd_invalid" -eq 0 ] || die ".qa/known-defects.json is not valid"
  local other
  other="$(other_open_target)"
  [ -z "$other" ] || die "another journey is open for $other"
  journey_load
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
  [ -n "$profile" ] || profile="$c_profile"
  in_list "$profile" "ship smoke full" || profile=full
  if ! is_local_url "$c_base"; then
    data_policy_enforced "$profile" || die "the environment is shared and gates.dataPolicy is not enforce"
  fi

  local now deadline base steps sep s st until_json
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
  # then the baseline, then the journey.
  archive_journey
  mkdir -p "$AUTO_DIR" || die "could not create .qa/specs/$TARGET/auto"
  printf '%s\n' "$base" | json_write "$BASELINE"
  printf '{"version":1,"target":%s,"profile":"%s","startedAt":"%s","deadline":"%s","until":%s,"steps":[%s],"analyzeRounds":0,"runId":null,"state":"open","stop":null,"endedAt":null}\n' \
    "$(target_json)" "$profile" "$now" "$deadline" "$until_json" "$steps" \
    | json_write "$JOURNEY"
  print_status
}

cmd_resume() {
  parse_common "$@"
  local hours="$DEFAULT_MAX_HOURS"
  set -- ${REST[@]+"${REST[@]}"}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-hours) [ "$#" -ge 2 ] || usage "--max-hours needs a number"; hours="$2"; shift 2 ;;
      *) usage "resume does not take: $1" ;;
    esac
  done
  valid_hours "$hours" || usage "--max-hours must be a number above zero"
  need_engine
  local reason other now deadline patch
  journey_load
  [ "$J_STATE" = stopped ] || die "nothing to resume"
  reason="$J_REASON"
  in_list "$reason" "$RESUMABLE_REASONS" || die "nothing to resume"
  other="$(other_open_target)"
  [ -z "$other" ] || die "another journey is open for $other"
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
  print_status
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
  *)      usage ;;
esac
