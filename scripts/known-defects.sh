#!/usr/bin/env bash
# known-defects.sh — validate the project-level known-defect registry and compute
# each entry's status (pure, deterministic, dual-engine: jq preferred, python3 fallback).
#
# WHY THIS EXISTS. A known-but-unfixed application defect used to be smuggled into a QA
# checklist as a criterion that EXPECTS a crash — which grades the crash correct. Defects
# now live in ONE project-level registry (`.qa/known-defects.json`, decision R16: a defect
# is a property of the APPLICATION, not of a QA target; per-spec copies drift and whichever
# copy is most convenient gets renewed), with a named owner (`ticket`), a capped deadline
# (`expiry`) and a STRUCTURED severity floor. A known defect is never a verdict: it has no
# pass/fail and contributes nothing to the tally.
#
# USAGE:
#   known-defects.sh validate <registry.json> [today-YYYY-MM-DD]
#       Exit 0 iff every entry is well-formed. Otherwise prints one
#       `ERROR: entry[<i>].<field>: ...` line per violation to STDERR and exits 1.
#       EVERY violation is reported, not just the first.
#
#   known-defects.sh status <registry.json> <today-YYYY-MM-DD> [--evidence <file>]
#       Prints a JSON array of {"id":...,"state":"outstanding"|"expired"|"cleared"} on
#       STDOUT, in registry order. Exit 0.
#
# SCHEMA. Required: id, title, ticket, expiry, severity, observedClass, surface,
# observedBehaviour (each a non-blank string). Optional: observedStatus (a number).
#   observedClass in {non-rendering, wrong-value, degraded}
#   severity      in {low, medium, high, critical}
#
# THE THREE RULES THAT CARRY THE WEIGHT:
#   * EXPIRY CAP = 90 days from <today> (R2). Without a cap, `2099-01-01` makes the gate a
#     paper rule. Renewal needs an explicit new date - a deliberate act, visible in a diff.
#   * SEVERITY FLOOR gates on the STRUCTURED `observedClass` enum, never on prose (R3):
#     observedClass "non-rendering" => severity must be `high` or `critical`. A gate that
#     greps `observedBehaviour` is defeated by rewording. This is the check that rejects
#     the originating incident's `severity: "low"`.
#   * CLEARING REQUIRES POSITIVE EVIDENCE (R4). An entry becomes `cleared` ONLY when the
#     supplied evidence shows a 2xx navigation to its `surface` AND no fatal finding on
#     that surface. ABSENCE OF A FINDING NEVER CLEARS ANYTHING - a run that never reached
#     the surface produces exactly the same silence as a fixed defect. With no evidence
#     supplied, every entry stays `outstanding`.
#
# FAIL-CLOSED CHOICES in `status` (it must exit 0, so it cannot report them as errors):
#   * `expired` is decided BEFORE `cleared`: an overdue entry surfaces even when evidence
#     suggests a fix, so a human removes it from the registry deliberately.
#   * An entry whose `expiry` is absent or unparseable counts as `expired` - an entry with
#     no valid deadline is overdue by definition. (`validate` rejects it outright.)
#   * A fatal finding carrying no `url` blocks clearing: it cannot be proven to be off the
#     surface, and the burden of proof is on clearing.
#   * `expiry == today` is NOT yet expired (the entry has until the end of its day).
#
# EVIDENCE SHAPE (what qa-verify.sh renders out of the findings journal, spec 5.1/5.3):
#   { "navigations": [ {"url": "<absolute or path>", "status": <int>}, ... ],
#     "findings":    [ {"url": "<absolute or path>", "statusClass": "fatal"|"non-fatal",
#                       "status": <int>}, ... ] }
#   A finding counts as fatal when statusClass == "fatal" OR status >= 500.
#
# SURFACE MATCHING is deterministic and identical in both engines: the surface pattern is
# compared against the navigation/finding URL's path (and query, when - and only when - the
# surface itself carries one). Scheme+host and any `#fragment` are stripped from both. A
# `{placeholder}` segment matches one-or-more characters that are not `/`, `?` or `&`, so
# `/admin/challenges/{challenge}?tab=gates` matches
# `https://app.test/admin/challenges/1?tab=gates`.
#
# DATES are computed ARITHMETICALLY inside the jq/python3 layer (a days-from-civil
# conversion). The script NEVER shells out to `date -d`, which is GNU-only and absent on
# macOS/BSD; the only `date` call is `date +%Y-%m-%d` for the default <today>, which is
# portable across both.
#
# DEPENDENCIES: bash 3.2 (no mapfile/readarray/declare -A), EITHER jq OR python3.
# ENGINE SELECTION: QA_ENGINE=jq|python3 forces one; unset auto-selects jq when present.
set -uo pipefail

TAB="$(printf '\t')"

die() { echo "ERROR: $*" >&2; exit 2; }

usage() {
  echo "usage: known-defects.sh validate <registry.json> [today-YYYY-MM-DD]" >&2
  echo "       known-defects.sh status   <registry.json> <today-YYYY-MM-DD> [--evidence <file>]" >&2
}

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq)      return 0 ;;
    *)       command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

# ---- argument parsing --------------------------------------------------------
[ "$#" -ge 1 ] || { usage; exit 2; }
CMD="$1"; shift
case "$CMD" in
  validate|status) ;;
  *) usage; die "unknown subcommand: $CMD" ;;
esac

REGISTRY=""
TODAY=""
EVIDENCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --evidence)
      [ "$#" -ge 2 ] || die "--evidence needs a path"
      EVIDENCE="$2"; shift 2 ;;
    --evidence=*)
      EVIDENCE="${1#--evidence=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "unknown option: $1" ;;
    *)
      if [ -z "$REGISTRY" ]; then REGISTRY="$1"
      elif [ -z "$TODAY" ]; then TODAY="$1"
      else die "unexpected argument: $1"
      fi
      shift ;;
  esac
done

[ -n "$REGISTRY" ] || { usage; die "missing <registry.json>"; }
[ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
[ -n "$TODAY" ] || TODAY="$(date +%Y-%m-%d)"
if ! [[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  die "<today> must be YYYY-MM-DD (got '$TODAY')"
fi
if [ -n "$EVIDENCE" ] && [ ! -f "$EVIDENCE" ]; then
  die "evidence file not found: $EVIDENCE"
fi

# ---- the engines -------------------------------------------------------------
# Both engines emit the SAME line-oriented stream on stdout, so the bash layer never has
# to re-parse JSON and the two engines are trivially byte-comparable:
#   E<TAB><one `ERROR: entry[i].field: ...` line>
#   S<TAB><one compact {"id":...,"state":...} object, in registry order>

JQ_PROG="$(cat <<'JQ_EOF'
def chars: explode | map([.] | implode);

# Escape only true regex metacharacters. Escaping arbitrary punctuation ("\=") is an
# error in some regex flavours, so the set is explicit and shared with the python leg.
def escre:
  chars
  | map(. as $c
        | if (["\\", ".", "^", "$", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"] | index($c)) != null
          then "\\" + $c else $c end)
  | join("");

# "/a/{id}/b" -> "^/a/[^/?&]+/b$"
def pat2re($s): "^" + ([ $s | splits("\\{[^}]*\\}") ] | map(escre) | join("[^/?&]+")) + "$";

def leap($y): ((($y % 4) == 0) and (($y % 100) != 0)) or (($y % 400) == 0);
def dim($y; $m):
  if $m == 2 then (if leap($y) then 29 else 28 end)
  elif ($m == 4 or $m == 6 or $m == 9 or $m == 11) then 30
  else 31 end;

# Howard Hinnant days-from-civil: pure integer arithmetic, no libc, no `date -d`.
def dfc($y; $m; $d):
  (if $m <= 2 then $y - 1 else $y end) as $yy
  | (($yy / 400) | floor) as $era
  | ($yy - ($era * 400)) as $yoe
  | ((((153 * (if $m > 2 then ($m - 3) else ($m + 9) end)) + 2) / 5) | floor) as $mp
  | ($mp + $d - 1) as $doy
  | (($yoe * 365) + (($yoe / 4) | floor) - (($yoe / 100) | floor) + $doy) as $doe
  | (($era * 146097) + $doe - 719468);

def okdate($s):
  (($s | type) == "string")
  and ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and ( (($s[0:4]) | tonumber) as $y
        | (($s[5:7]) | tonumber) as $m
        | (($s[8:10]) | tonumber) as $d
        | ($m >= 1 and $m <= 12 and $d >= 1 and $d <= dim($y; $m)) );

def dnum($s):
  (($s[0:4]) | tonumber) as $y | (($s[5:7]) | tonumber) as $m | (($s[8:10]) | tonumber) as $d
  | dfc($y; $m; $d);

# non-empty string (whitespace-only counts as empty)
def nes($v): (($v | type) == "string") and ((($v | gsub("^[ \t\r\n]+|[ \t\r\n]+$"; "")) | length) > 0);

def pathpart($u):
  (if ($u | type) == "string" then $u else "" end)
  | sub("#.*$"; "")
  | (if test("^[A-Za-z][A-Za-z0-9+.-]*://") then sub("^[A-Za-z][A-Za-z0-9+.-]*://[^/]*"; "") else . end)
  | (if . == "" then "/" else . end);

def surfmatch($surface; $u):
  (pathpart($surface)) as $sp
  | (pathpart($u)) as $up
  | (if ($sp | test("\\?")) then $up else ($up | sub("\\?.*$"; "")) end) as $cand
  | ($cand | test(pat2re($sp)));

def fatalFinding:
  (.statusClass == "fatal")
  or (((((.status) // null) | type) == "number") and ((((.status) // 0)) >= 500));

def clearedBy($e; $ev):
  if (($ev | type) != "object") then false
  elif (nes($e.surface) | not) then false
  else
    ([ (($ev.navigations // [])[])
       | select((type == "object") and (((((.status) // null) | type) == "number")))
       | select(((.status) >= 200) and ((.status) < 300))
       | select(surfmatch($e.surface; .url)) ] | length) > 0
    and
    ([ (($ev.findings // [])[])
       | select(type == "object")
       | select(fatalFinding)
       # fail-closed: a fatal finding with no url cannot be proven off this surface
       | select(((((.url) // null) | type) != "string") or surfmatch($e.surface; .url)) ] | length) == 0
  end;

def entryState($e; $today; $ev):
  if (($e | type) != "object") then "expired"
  elif ((nes($e.expiry) | not) or (okdate($e.expiry) | not)) then "expired"
  elif (dnum($e.expiry) < dnum($today)) then "expired"
  elif clearedBy($e; $ev) then "cleared"
  else "outstanding" end;

def entryErrors($i; $e; $today; $seen):
  if (($e | type) != "object") then [ "ERROR: entry[\($i)]: not a JSON object" ]
  else
    ( ["id","title","ticket","expiry","severity","observedClass","surface","observedBehaviour"]
      | map(. as $f | if nes($e[$f]) then empty else "ERROR: entry[\($i)].\($f): missing or empty" end) )
    + ( if (nes($e.id) and (($seen | index($e.id)) != null))
        then [ "ERROR: entry[\($i)].id: duplicate id '\($e.id)'" ] else [] end )
    + ( if (nes($e.expiry) and (okdate($e.expiry) | not))
        then [ "ERROR: entry[\($i)].expiry: not a YYYY-MM-DD calendar date: '\($e.expiry)'" ] else [] end )
    + ( if (nes($e.expiry) and okdate($e.expiry) and ((dnum($e.expiry) - dnum($today)) > 90))
        then [ "ERROR: entry[\($i)].expiry: \($e.expiry) is more than 90 days after \($today) (cap: 90 days)" ] else [] end )
    + ( if (nes($e.observedClass) and ((["non-rendering","wrong-value","degraded"] | index($e.observedClass)) == null))
        then [ "ERROR: entry[\($i)].observedClass: not one of non-rendering, wrong-value, degraded (got '\($e.observedClass)')" ] else [] end )
    + ( if (nes($e.severity) and ((["low","medium","high","critical"] | index($e.severity)) == null))
        then [ "ERROR: entry[\($i)].severity: not one of low, medium, high, critical (got '\($e.severity)')" ] else [] end )
    + ( if (($e.observedClass == "non-rendering") and nes($e.severity)
            and ((["low","medium","high","critical"] | index($e.severity)) != null)
            and ($e.severity != "high") and ($e.severity != "critical"))
        then [ "ERROR: entry[\($i)].severity: observedClass 'non-rendering' requires severity high or critical (got '\($e.severity)')" ] else [] end )
    + ( if (($e | has("observedStatus")) and (($e.observedStatus) != null) and ((($e.observedStatus) | type) != "number"))
        then [ "ERROR: entry[\($i)].observedStatus: must be a number when present" ] else [] end )
  end;

if (type != "array") then error("registry must be a JSON array") else . end
| . as $reg
| [ range(0; ($reg | length)) as $i
    | ($reg[$i]) as $e
    | ([ ($reg[0:$i][]) | (if (type == "object") then .id else null end) ]) as $seen
    | (entryErrors($i; $e; $today; $seen)[]) | "E\t" + . ]
  +
  [ range(0; ($reg | length)) as $i
    | ($reg[$i]) as $e
    | "S\t" + ({ id: (if (($e | type) == "object") then (($e.id) // null) else null end),
                 state: entryState($e; $today; $ev) } | tojson) ]
| .[]
JQ_EOF
)"

PY_PROG="$(cat <<'PY_EOF'
import json, re, sys

registry_path, today, evidence_path = sys.argv[1], sys.argv[2], sys.argv[3]

def bail(msg):
    sys.stderr.write("ERROR: " + msg + "\n"); sys.exit(2)

try:
    reg = json.load(open(registry_path))
except Exception:
    bail("registry is not valid JSON: " + registry_path)
if not isinstance(reg, list):
    bail("registry must be a JSON array")

ev = None
if evidence_path:
    try:
        ev = json.load(open(evidence_path))
    except Exception:
        bail("evidence is not valid JSON: " + evidence_path)

META = set("\\.^$|?*+()[]{}")

def escre(s):
    return "".join(("\\" + c) if c in META else c for c in s)

def pat2re(s):
    return "^" + "[^/?&]+".join(escre(p) for p in re.split(r"\{[^}]*\}", s)) + "$"

def leap(y):
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)

def dim(y, m):
    if m == 2:
        return 29 if leap(y) else 28
    if m in (4, 6, 9, 11):
        return 30
    return 31

# Howard Hinnant days-from-civil: pure integer arithmetic, no libc, no `date -d`.
def dfc(y, m, d):
    yy = y - 1 if m <= 2 else y
    era = yy // 400
    yoe = yy - era * 400
    mp = ((153 * (m - 3 if m > 2 else m + 9)) + 2) // 5
    doy = mp + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468

DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

def okdate(s):
    if not isinstance(s, str) or not DATE_RE.match(s):
        return False
    y, m, d = int(s[0:4]), int(s[5:7]), int(s[8:10])
    return 1 <= m <= 12 and 1 <= d <= dim(y, m)

def dnum(s):
    return dfc(int(s[0:4]), int(s[5:7]), int(s[8:10]))

def nes(v):
    return isinstance(v, str) and len(v.strip(" \t\r\n")) > 0

SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")

def pathpart(u):
    u = u if isinstance(u, str) else ""
    u = re.sub(r"#.*$", "", u)
    if SCHEME_RE.match(u):
        u = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://[^/]*", "", u)
    return u if u != "" else "/"

def surfmatch(surface, u):
    sp = pathpart(surface)
    up = pathpart(u)
    cand = up if "?" in sp else re.sub(r"\?.*$", "", up)
    return re.search(pat2re(sp), cand) is not None

def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)

def fatal_finding(f):
    if not isinstance(f, dict):
        return False
    return f.get("statusClass") == "fatal" or (is_num(f.get("status")) and f.get("status") >= 500)

def cleared_by(e, ev):
    if not isinstance(ev, dict):
        return False
    if not nes(e.get("surface")):
        return False
    surface = e["surface"]
    navs = ev.get("navigations") or []
    ok_nav = any(isinstance(n, dict) and is_num(n.get("status"))
                 and 200 <= n["status"] < 300 and surfmatch(surface, n.get("url"))
                 for n in navs)
    if not ok_nav:
        return False
    for f in (ev.get("findings") or []):
        if not fatal_finding(f):
            continue
        # fail-closed: a fatal finding with no url cannot be proven off this surface
        if not isinstance(f.get("url"), str) or surfmatch(surface, f.get("url")):
            return False
    return True

def entry_state(e, today, ev):
    if not isinstance(e, dict):
        return "expired"
    exp = e.get("expiry")
    if not nes(exp) or not okdate(exp):
        return "expired"
    if dnum(exp) < dnum(today):
        return "expired"
    if cleared_by(e, ev):
        return "cleared"
    return "outstanding"

REQUIRED = ["id", "title", "ticket", "expiry", "severity", "observedClass", "surface", "observedBehaviour"]
CLASSES = ["non-rendering", "wrong-value", "degraded"]
SEVS = ["low", "medium", "high", "critical"]

def entry_errors(i, e, today, seen):
    if not isinstance(e, dict):
        return ["ERROR: entry[%d]: not a JSON object" % i]
    out = []
    for f in REQUIRED:
        if not nes(e.get(f)):
            out.append("ERROR: entry[%d].%s: missing or empty" % (i, f))
    if nes(e.get("id")) and e.get("id") in seen:
        out.append("ERROR: entry[%d].id: duplicate id '%s'" % (i, e.get("id")))
    exp = e.get("expiry")
    if nes(exp) and not okdate(exp):
        out.append("ERROR: entry[%d].expiry: not a YYYY-MM-DD calendar date: '%s'" % (i, exp))
    if nes(exp) and okdate(exp) and (dnum(exp) - dnum(today)) > 90:
        out.append("ERROR: entry[%d].expiry: %s is more than 90 days after %s (cap: 90 days)" % (i, exp, today))
    oc = e.get("observedClass")
    if nes(oc) and oc not in CLASSES:
        out.append("ERROR: entry[%d].observedClass: not one of non-rendering, wrong-value, degraded (got '%s')" % (i, oc))
    sev = e.get("severity")
    if nes(sev) and sev not in SEVS:
        out.append("ERROR: entry[%d].severity: not one of low, medium, high, critical (got '%s')" % (i, sev))
    if oc == "non-rendering" and nes(sev) and sev in SEVS and sev not in ("high", "critical"):
        out.append("ERROR: entry[%d].severity: observedClass 'non-rendering' requires severity high or critical (got '%s')" % (i, sev))
    if "observedStatus" in e and e.get("observedStatus") is not None and not is_num(e.get("observedStatus")):
        out.append("ERROR: entry[%d].observedStatus: must be a number when present" % i)
    return out

lines = []
for i, e in enumerate(reg):
    seen = [r.get("id") if isinstance(r, dict) else None for r in reg[:i]]
    for msg in entry_errors(i, e, today, seen):
        lines.append("E\t" + msg)
for i, e in enumerate(reg):
    row = {"id": (e.get("id") if isinstance(e, dict) else None),
           "state": entry_state(e, today, ev)}
    lines.append("S\t" + json.dumps(row, separators=(",", ":"), ensure_ascii=False))
sys.stdout.write("".join(l + "\n" for l in lines))
PY_EOF
)"

# ---- run the selected engine -------------------------------------------------
if has_jq; then
  EV_JSON="null"
  if [ -n "$EVIDENCE" ]; then
    EV_JSON="$(cat "$EVIDENCE")"
    printf '%s' "$EV_JSON" | jq -e . >/dev/null 2>&1 || die "evidence is not valid JSON: $EVIDENCE"
  fi
  STREAM="$(jq -r --arg today "$TODAY" --argjson ev "$EV_JSON" "$JQ_PROG" "$REGISTRY" 2>/dev/null)" \
    || die "registry is not a valid JSON array of entries: $REGISTRY"
elif has_py; then
  STREAM="$(python3 -c "$PY_PROG" "$REGISTRY" "$TODAY" "$EVIDENCE")" || exit $?
else
  die "known-defects.sh needs either 'jq' or 'python3'."
fi

# ---- render ------------------------------------------------------------------
if [ "$CMD" = "validate" ]; then
  RC=0
  while IFS= read -r line; do
    case "$line" in
      "E$TAB"*) printf '%s\n' "${line#E$TAB}" >&2; RC=1 ;;
    esac
  done <<EOF
$STREAM
EOF
  # Never exit 0 while errors were printed (the data-baseline.sh bug class).
  exit "$RC"
fi

# status
JSON="["
FIRST=1
while IFS= read -r line; do
  case "$line" in
    "S$TAB"*)
      if [ "$FIRST" -eq 1 ]; then FIRST=0; else JSON="$JSON,"; fi
      JSON="$JSON${line#S$TAB}" ;;
  esac
done <<EOF
$STREAM
EOF
printf '%s]\n' "$JSON"
exit 0
