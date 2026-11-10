#!/usr/bin/env bash
# bug-log.sh — the one writer of a run's bug-log.json (canonical snake_case entries).
#
# bug-log.json used to be hand-copied from templates/bug-log.md, so runs drifted into other key
# styles (criterionId, suspectedLayer, observed, ...) that the bug export and the reports then
# read as empty. This script owns the shape: it maps the known aliases to the canonical keys,
# checks the required fields, and writes atomically.
#
# USAGE:
#   bug-log.sh add <run-dir> <entry.json|->
#       Append ONE entry (a JSON object). Aliases are mapped first. Exit 1 (nothing written) when
#       a required field is missing/empty, severity is not critical|high|medium|low, or the
#       bug_id already exists. Creates bug-log.json ({"entries":[],"run_id":<dir name>}) if absent.
#       Prints {"added":"<bug_id>"}.
#   bug-log.sh normalize <run-dir>
#       Rewrite an existing bug-log.json (entries[], bugs[] or a bare array) to canonical keys.
#       The first time it changes a file it keeps the original as bug-log.pre-normalize.json.
#       Never invents values: entries that still miss required fields are listed, not dropped.
#       Prints {"entries":N,"invalid":[{"bugId","missing":[...]}],"renamed":{"<alias>":count}}.
#   bug-log.sh validate <run-dir>
#       Prints {"errors":[{"bugId","reason"}],"ok":bool}; exit 0 iff ok. Reads only canonical keys,
#       so an un-normalized log fails with "missing <key>" reasons.
#
# Canonical keys and their accepted aliases (canonical wins when both are present):
#   bug_id <- id, bugId            criterion_id <- criterionId, criterion
#   suspected_layer <- suspectedLayer, layer        actual <- observed
#   evidence_refs <- evidenceRefs, evidence         logged_at <- loggedAt, observedAt
#   journey_id <- journeyId
# Required (non-empty string): bug_id, criterion_id, title, severity, suspected_layer, expected, actual.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred; QA_ENGINE=jq|python3 forces
#   one). Both engines produce byte-identical output.
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

usage="usage: bug-log.sh add <run-dir> <entry.json|-> | normalize <run-dir> | validate <run-dir>"
[ "$#" -ge 2 ] || die "$usage"
CMD="$1"; RD="$2"; shift 2
[ -d "$RD" ] || die "bug-log: run dir not found: $RD"
LOG="$RD/bug-log.json"
if has_jq; then ENGINE=jq; elif has_py; then ENGINE=py; else die "bug-log.sh needs either 'jq' or 'python3'."; fi

# Shared jq definitions: alias map, canonicalisation, required-field check.
JQ_LIB='
def aliases: [["bug_id",["id","bugId"]],["criterion_id",["criterionId","criterion"]],
              ["suspected_layer",["suspectedLayer","layer"]],["actual",["observed"]],
              ["evidence_refs",["evidenceRefs","evidence"]],["logged_at",["loggedAt","observedAt"]],
              ["journey_id",["journeyId"]]];
def required: ["bug_id","criterion_id","title","severity","suspected_layer","expected","actual"];
def present($k): has($k) and .[$k] != null;
def canon:
  reduce aliases[] as $p ({e: ., r: []};
    reduce $p[1][] as $a (.;
      if (.e | has($a)) then
        (if (.e | present($p[0])) or (.e[$a] == null) then . else .e[$p[0]] = .e[$a] | .r += [$a] end)
        | .e |= del(.[$a])
      else . end));
def missing: . as $e | [ required[] | select(($e[.] | type) != "string" or $e[.] == "") ];
def badsev: (.severity | type) == "string" and .severity != "" and ([.severity] | inside(["critical","high","medium","low"]) | not);
def rows: if type == "array" then . elif type == "object" and (.entries|type) == "array" then .entries
          elif type == "object" and (.bugs|type) == "array" then .bugs else [] end;
'

PY_LIB='
import json, os, sys
ALIASES = [("bug_id", ["id", "bugId"]), ("criterion_id", ["criterionId", "criterion"]),
           ("suspected_layer", ["suspectedLayer", "layer"]), ("actual", ["observed"]),
           ("evidence_refs", ["evidenceRefs", "evidence"]), ("logged_at", ["loggedAt", "observedAt"]),
           ("journey_id", ["journeyId"])]
REQUIRED = ["bug_id", "criterion_id", "title", "severity", "suspected_layer", "expected", "actual"]
SEVS = ["critical", "high", "medium", "low"]
def canon(e):
    e = dict(e); r = []
    for k, al in ALIASES:
        for a in al:
            if a in e:
                if not (k in e and e[k] is not None) and e[a] is not None:
                    e[k] = e[a]; r.append(a)
                del e[a]
    return e, r
def missing(e): return [k for k in REQUIRED if not isinstance(e.get(k), str) or e.get(k) == ""]
def badsev(e): return isinstance(e.get("severity"), str) and e["severity"] != "" and e["severity"] not in SEVS
def rows(d):
    if isinstance(d, list): return d
    if isinstance(d, dict) and isinstance(d.get("entries"), list): return d["entries"]
    if isinstance(d, dict) and isinstance(d.get("bugs"), list): return d["bugs"]
    return []
def dump(o): return json.dumps(o, indent=2, sort_keys=True, ensure_ascii=False)
'

write_atomic() { # $1 = content, $2 = target
  local tmp; tmp="$(mktemp "$2.XXXXXX")" || die "bug-log: cannot write $2"
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$2" || { rm -f "$tmp"; die "bug-log: cannot write $2"; }
}

case "$CMD" in
  add)
    [ "$#" -eq 1 ] || die "$usage"
    SRC="$1"; ENTRY="$(if [ "$SRC" = - ]; then cat; else [ -f "$SRC" ] || die "bug-log: entry file not found: $SRC"; cat "$SRC"; fi)"
    RUNID="$(basename "$RD")"
    if [ -f "$LOG" ]; then CUR="$(cat "$LOG")"; else CUR='{"entries":[],"run_id":'"$(printf '%s' "$RUNID" | { if [ "$ENGINE" = jq ]; then jq -R .; else python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'; fi; })"'}'; fi
    if [ "$ENGINE" = jq ]; then
      out="$(jq -n -S --argjson e "$ENTRY" --argjson cur "$CUR" "$JQ_LIB"'
        if ($e|type) != "object" then error("entry must be a JSON object") else . end
        | ($e | canon | .e) as $c
        | ($c | missing) as $m
        | if ($m|length) > 0 then error("missing " + ($m|join(", "))) else . end
        | if ($c | badsev) then error("severity must be critical|high|medium|low, got " + ($c.severity|tojson)) else . end
        | ($cur | rows) as $rs
        | if ([ $rs[] | select(type == "object") | canon | .e.bug_id ] | index($c.bug_id)) != null
          then error("bug_id already exists: " + $c.bug_id) else . end
        | {log: ((if ($cur|type) == "object" then $cur else {} end) | del(.bugs) + {entries: ($rs + [$c])}
                 | if has("run_id") then . else .run_id = null end),
           id: $c.bug_id}' 2>&1)" || die "bug-log: ${out#jq: error (at <unknown>): }"
      id="$(printf '%s' "$out" | jq -r .id)"; body="$(printf '%s' "$out" | jq -S .log)"
    else
      out="$(python3 -c "$PY_LIB"'
e = json.loads(sys.argv[1]); cur = json.loads(sys.argv[2])
if not isinstance(e, dict): sys.exit("entry must be a JSON object")
c, _ = canon(e); m = missing(c)
if m: sys.exit("missing " + ", ".join(m))
if badsev(c): sys.exit("severity must be critical|high|medium|low, got " + json.dumps(c["severity"], ensure_ascii=False))
rs = rows(cur)
if c["bug_id"] in [canon(x)[0].get("bug_id") for x in rs if isinstance(x, dict)]: sys.exit("bug_id already exists: " + c["bug_id"])
log = dict(cur) if isinstance(cur, dict) else {}
log.pop("bugs", None); log["entries"] = rs + [c]
if "run_id" not in log: log["run_id"] = None
print(c["bug_id"]); print(dump(log))
' "$ENTRY" "$CUR" 2>&1)" || die "bug-log: $out"
      id="${out%%$'\n'*}"; body="${out#*$'\n'}"
    fi
    write_atomic "$body" "$LOG"
    printf '{"added":%s}\n' "$(printf '%s' "$id" | { if [ "$ENGINE" = jq ]; then jq -R .; else python3 -c 'import json,sys;print(json.dumps(sys.stdin.read(),ensure_ascii=False))'; fi; })"
    ;;

  normalize)
    [ "$#" -eq 0 ] || die "$usage"
    [ -f "$LOG" ] || die "bug-log: $LOG not found"
    if [ "$ENGINE" = jq ]; then
      res="$(jq -S "$JQ_LIB"'
        . as $d | ($d | rows) as $rs
        | [ $rs[] | if type == "object" then canon else {e: ., r: []} end ] as $cs
        | {log: ((if ($d|type) == "object" then $d else {} end) | del(.bugs) + {entries: [ $cs[].e ]}
                 | if has("run_id") then . else .run_id = null end),
           summary: {entries: ($cs|length),
                     renamed: (reduce ($cs[].r[]) as $a ({}; .[$a] += 1)),
                     invalid: [ $cs[].e | select(type == "object") | select((missing|length) > 0)
                                | {bugId: (.bug_id // null), missing: missing} ]}}' "$LOG")" || die "bug-log: normalize failed (is $LOG valid JSON?)"
      body="$(printf '%s' "$res" | jq -S .log)"; summary="$(printf '%s' "$res" | jq -S .summary)"
      orig="$(jq -S . "$LOG")"
    else
      res="$(python3 -c "$PY_LIB"'
d = json.load(open(sys.argv[1], encoding="utf-8"))
cs = [canon(x) if isinstance(x, dict) else (x, []) for x in rows(d)]
log = dict(d) if isinstance(d, dict) else {}
log.pop("bugs", None); log["entries"] = [c for c, _ in cs]
if "run_id" not in log: log["run_id"] = None
ren = {}
for _, r in cs:
    for a in r: ren[a] = ren.get(a, 0) + 1
inv = [{"bugId": c.get("bug_id"), "missing": missing(c)} for c, _ in cs if isinstance(c, dict) and missing(c)]
print(dump(log)); print("\x1e"); print(dump({"entries": len(cs), "invalid": inv, "renamed": ren})); print("\x1e"); print(dump(d))
' "$LOG")" || die "bug-log: normalize failed (is $LOG valid JSON?)"
      body="${res%%$'\n\x1e'*}"; rest="${res#*$'\x1e'$'\n'}"; summary="${rest%%$'\n\x1e'*}"; orig="${rest#*$'\x1e'$'\n'}"
    fi
    if [ "$body" != "$orig" ]; then
      [ -f "$RD/bug-log.pre-normalize.json" ] || cp "$LOG" "$RD/bug-log.pre-normalize.json" || die "bug-log: cannot keep the original"
      write_atomic "$body" "$LOG"
    fi
    printf '%s\n' "$summary"
    ;;

  validate)
    [ "$#" -eq 0 ] || die "$usage"
    [ -f "$LOG" ] || die "bug-log: $LOG not found"
    if [ "$ENGINE" = jq ]; then
      out="$(jq -S "$JQ_LIB"'
        (rows) as $rs
        | [ range(0; $rs|length) as $i | $rs[$i] as $e
            | (if ($e|type) == "object" then ($e.bug_id // ("#" + ($i+1|tostring))) else ("#" + ($i+1|tostring)) end) as $id
            | ( if ($e|type) != "object" then "entry is not an object"
                else ( ($e | missing[] | "missing " + .),
                       (if ($e | badsev) then "severity must be critical|high|medium|low" else empty end),
                       (if ([ $rs[0:$i][] | select(type == "object") | .bug_id ] | index($e.bug_id)) != null and ($e.bug_id|type) == "string" and $e.bug_id != ""
                        then "duplicate bug_id" else empty end) ) end )
            | {bugId: ($id|tostring), reason: .} ] as $errs
        | {ok: ($errs|length == 0), errors: $errs}' "$LOG")" || die "bug-log: validate failed (is $LOG valid JSON?)"
    else
      out="$(python3 -c "$PY_LIB"'
rs = rows(json.load(open(sys.argv[1], encoding="utf-8")))
errs = []
for i, e in enumerate(rs):
    if not isinstance(e, dict):
        errs.append({"bugId": "#%d" % (i + 1), "reason": "entry is not an object"}); continue
    bid = e.get("bug_id"); bid = bid if bid is not None else "#%d" % (i + 1)
    bid = bid if isinstance(bid, str) else json.dumps(bid, ensure_ascii=False)
    for k in missing(e): errs.append({"bugId": bid, "reason": "missing " + k})
    if badsev(e): errs.append({"bugId": bid, "reason": "severity must be critical|high|medium|low"})
    if isinstance(e.get("bug_id"), str) and e["bug_id"] != "" and e["bug_id"] in [x.get("bug_id") for x in rs[:i] if isinstance(x, dict)]:
        errs.append({"bugId": bid, "reason": "duplicate bug_id"})
print(dump({"ok": not errs, "errors": errs}))
' "$LOG")" || die "bug-log: validate failed (is $LOG valid JSON?)"
    fi
    printf '%s\n' "$out"
    case "$out" in *'"ok": true'*) exit 0 ;; *) exit 1 ;; esac
    ;;

  *) die "$usage" ;;
esac
