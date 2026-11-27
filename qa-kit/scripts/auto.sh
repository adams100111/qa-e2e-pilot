#!/usr/bin/env bash
# auto.sh — the state machine of an unattended journey (qa-kit, dual-engine).
#
# An unattended journey is one agent driving the whole qa-kit process for a target:
# constitution → spec → scenarios → analyze → run → verify. This script owns the journey's
# files and nothing else:
#
#   .qa/specs/<target>/auto/journey.json     the steps, their state, the deadline, the stop reason
#   .qa/specs/<target>/auto/baseline.json    the snapshot taken at start that the audit compares against
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
#
#   start, resume, stop and status print ONE JSON line: journey.json plus {"needsPerson": n}.
#   status writes nothing.
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
# helpers below (parse_common, journey_load, journey_require_open, json_get/json_strs/json_pick/json_merge,
# stop_journey, print_status, now_iso, iso_add_hours, step_artifact_done, read_lines).
set -uo pipefail

# ---------------------------------------------------------------------------------------------
# Fixed values (plan decisions J1, J2, J6)
# ---------------------------------------------------------------------------------------------
STEPS="constitution spec scenarios analyze run verify"
RESUMABLE_REASONS="time-limit step-failed until"
FINAL_REASONS="blocked audit no-sign-in tracker"
SAFETY_KEYS="allowApiWrites seedableEnvMarker environment allowBlackboxCrawl gates profile humanInteraction.enforce humanInteraction.maxOptOutRate"
DEFAULT_MAX_HOURS=6

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
EOF
  exit 2
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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
import calendar, json, math, sys, time
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
    sys.stdout.buffer.write((s + "\n").encode("utf-8"))
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
QA_DIR=""; CONFIG=""; SPEC_DIR=""; AUTO_DIR=""; JOURNEY=""; BASELINE=""; DECISIONS=""
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
}
# flag_takes_value <flag> — true for the flags whose next word is their value (so that word is
# never mistaken for the target). Add a verb's value flags here.
flag_takes_value() {
  case "$1" in
    --profile|--until|--max-hours|--reason|--detail|--run|--step|--class|--question|--answer|--evidence|--confidence|--criteria|--records) return 0 ;;
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
target_json() { json_quote "$TARGET"; }
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
# stop_journey <reason> <detail> — close the journey as stopped. Reason must be a J2 reason.
stop_journey() {
  in_list "$1" "$RESUMABLE_REASONS $FINAL_REASONS" || die "internal: unknown stop reason $1"
  local now
  now="$(now_iso)" || exit 1
  json_merge "$JOURNEY" "{\"state\":\"stopped\",\"stop\":{\"reason\":\"$1\",\"detail\":$(json_quote "$2")},\"endedAt\":\"$now\"}"
}
# step_artifact_done <step> — exit 0 when the step's artifact is on disk. Only the three steps a
# new journey can inherit are known here; the others are never done at start.
step_artifact_done() {
  case "$1" in
    constitution) [ -f "$QA_DIR/constitution.state.json" ] ;;
    spec)         [ -f "$SPEC_DIR/qa-spec.md" ] && [ -f "$SPEC_DIR/spec-roles.json" ] ;;
    scenarios)    [ -f "$SPEC_DIR/scenarios.md" ] && [ -f "$SPEC_DIR/checklist.json" ] ;;
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
  deadline="$(iso_add_hours "$now" "$hours")"
  [ -n "$deadline" ] || die "could not work out the deadline"
  base="$(baseline_json "$profile" "$now")" || exit 1
  steps=""; sep=""
  for s in $STEPS; do
    st=pending
    step_artifact_done "$s" && st=done
    steps="$steps$sep{\"name\":\"$s\",\"state\":\"$st\"}"; sep=","
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
  *)      usage ;;
esac
