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
#       STDOUT stays empty. EVERY violation is reported, not just the first.
#
#   known-defects.sh status <registry.json> <today-YYYY-MM-DD> [--evidence <file>]
#       Prints a JSON array of {"id":...,"state":"outstanding"|"expired"|"cleared"} on
#       STDOUT, in registry order. Exit 0.
#
# EXIT CODES: 0 ok · 1 validation failed (validate only) · 2 the inputs are unusable
# (missing/unparseable/wrongly-typed registry or evidence, a registry carrying control
# characters, a bad argument, no engine available). Both engines agree on the exit code
# AND on the stderr text for every one of these.
#
# SCHEMA. Required: id, title, ticket, expiry, severity, observedClass, surface,
# observedBehaviour (each a non-blank, single-line string). Optional: observedStatus (a
# number). No string field may contain a control character (see "INJECTION" below).
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
# FAIL-CLOSED CHOICES in `status` (it must exit 0 on usable input, so it cannot report
# these as errors), all deliberate:
#   * `expired` is decided BEFORE `cleared`: an overdue entry surfaces even when evidence
#     suggests a fix, so a human removes it from the registry deliberately.
#   * An entry whose `expiry` is absent or unparseable counts as `expired` - an entry with
#     no valid deadline is overdue by definition. (`validate` rejects it outright.)
#   * A navigation row with no string `url` is IGNORED: it is not positive evidence of
#     reaching anything, and `pathpart("")` would otherwise degrade to "/" and clear every
#     entry whose surface is "/" (review finding 2).
#   * A fatal finding carrying no `url` BLOCKS clearing: it cannot be proven to be off the
#     surface, and the burden of proof is on clearing.
#   * `expiry == today` is NOT yet expired (the entry has until the end of its day).
#
# EVIDENCE SHAPE (what qa-verify.sh renders out of the findings journal, spec 5.1/5.3):
#   { "navigations": [ {"url": "<absolute or path>", "status": <int>}, ... ],
#     "findings":    [ {"url": "<absolute or path>", "statusClass": "fatal"|"non-fatal",
#                       "status": <int>}, ... ] }
#   The top level MUST be a JSON object; `navigations`/`findings`, when present and
#   non-null, MUST be arrays of objects. Anything else is exit 2 in BOTH engines — never
#   silently iterated (review finding 1: iterating a JSON object yields values in jq and
#   KEYS in python, which let python3 clear a defect that had a fatal finding).
#   A finding counts as fatal when statusClass == "fatal" (exact, case-sensitive) OR
#   status >= 500.
#
# INJECTION. `validate` interpolates registry values into its error lines, and `status`
# builds a JSON array out of per-entry rows. If both ever shared one stream, a newline
# inside a registry value could forge a `cleared` row (review finding 3). Two structural
# defences, not one:
#   1. THE CHANNELS NEVER COEXIST. The engine is told its mode. In `validate` mode it emits
#      error lines and NO status rows; in `status` mode it emits `S<TAB>`-prefixed rows and
#      NO error lines. The bash layer rejects any `status`-mode line that is not
#      `S<TAB>`-prefixed, so nothing unexpected can reach the JSON it prints. Row payloads
#      come from tojson/json.dumps, which escape newlines, so a row is always one line.
#   2. CONTROL CHARACTERS ARE REJECTED. Any string field containing a character below
#      U+0020, or U+007F, is a validation error in `validate` and a hard exit 2 in
#      `status`. Registry prose is single-line by contract.
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
# Both engines take (registry, today, evidence-path, mode) and speak ONE protocol:
#
#   mode=validate : STDOUT = zero or more `ERROR: ...` lines, nothing else. Exit 0.
#   mode=status   : STDOUT = exactly one `S<TAB>{"id":...,"state":...}` line per entry,
#                   nothing else. Exit 0.
#   either mode   : structurally unusable input -> `ERROR: ...` on STDERR, exit 4.
#                   control characters in a registry string, in status mode only
#                   -> `ERROR: ...` lines on STDERR, exit 3.
#
# The two content channels are never open at the same time, which is what makes an
# injected newline unable to forge a row (see "INJECTION" above). Every stderr text and
# every exit code below is identical in both engines; the parity suite asserts that across
# the malformed-input space, not just the happy path.

JQ_PROG="$(cat <<'JQ_EOF'
def fail($m): ("ERROR: " + $m + "\n") | halt_error(4);

def chars: explode | map([.] | implode);

# Escape only true regex metacharacters. Escaping arbitrary punctuation is an error in
# some regex flavours, so the set is explicit and shared with the python leg.
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

# any character below U+0020, or U+007F
def hasctl($s): (($s | type) == "string") and ((($s | explode | map(select((. < 32) or (. == 127))) | length)) > 0);

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

# Structural gate on the evidence document. Anything unusable exits 4 rather than being
# iterated: iterating a JSON OBJECT yields its values here and its KEYS in python, which
# is exactly how a fatal finding became invisible to one engine (review finding 1).
def evcheck:
  if ($evpath == "") then null
  elif (($ev | type) != "object") then fail("evidence must be a JSON object: " + $evpath)
  elif (($ev | has("navigations")) and (($ev.navigations) != null) and ((($ev.navigations) | type) != "array"))
    then fail("evidence.navigations must be a JSON array")
  elif (($ev | has("findings")) and (($ev.findings) != null) and ((($ev.findings) | type) != "array"))
    then fail("evidence.findings must be a JSON array")
  elif ((([ (($ev.navigations // [])[]) | select((type) != "object") ]) | length) > 0)
    then fail("evidence.navigations[] entries must be JSON objects")
  elif ((([ (($ev.findings // [])[]) | select((type) != "object") ]) | length) > 0)
    then fail("evidence.findings[] entries must be JSON objects")
  else null end;

def clearedBy($e; $ev):
  if (($ev | type) != "object") then false
  elif (nes($e.surface) | not) then false
  else
    ([ (($ev.navigations // [])[])
       # fail-open guard (review finding 2): a navigation with no string url is not
       # evidence of reaching anything, and pathpart("") would degrade to "/".
       | select((((.url) // null) | type) == "string")
       | select(((((.status) // null) | type) == "number") and ((.status) >= 200) and ((.status) < 300))
       | select(surfmatch($e.surface; .url)) ] | length) > 0
    and
    ([ (($ev.findings // [])[])
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

def ctlErrors($i; $e):
  if (($e | type) != "object") then []
  else [ ($e | keys[]) as $k
         | select(hasctl($e[$k]))
         | "ERROR: entry[\($i)].\($k): contains a control character" ]
  end;

def entryErrors($i; $e; $today; $seen):
  if (($e | type) != "object") then [ "ERROR: entry[\($i)]: not a JSON object" ]
  else
    ( ["id","title","ticket","expiry","severity","observedClass","surface","observedBehaviour"]
      | map(. as $f | if nes($e[$f]) then empty else "ERROR: entry[\($i)].\($f): missing or empty" end) )
    + ctlErrors($i; $e)
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

(if (type != "array") then fail("registry must be a JSON array") else null end) as $_regchk
| (evcheck) as $_evchk
| . as $reg
| ([ range(0; ($reg | length)) as $i | (ctlErrors($i; $reg[$i])[]) ]) as $ctl
| if ($mode == "status") then
    (if (($ctl | length) > 0) then (($ctl | map(. + "\n") | join("")) | halt_error(3)) else null end) as $_ctlchk
    | [ range(0; ($reg | length)) as $i
        | ($reg[$i]) as $e
        | "S\t" + ({ id: (if (($e | type) == "object") then (($e.id) // null) else null end),
                     state: entryState($e; $today; $ev) } | tojson) ]
    | .[]
  else
    [ range(0; ($reg | length)) as $i
      | ($reg[$i]) as $e
      | ([ ($reg[0:$i][]) | (if (type == "object") then .id else null end) ]) as $seen
      | (entryErrors($i; $e; $today; $seen)[]) ]
    | .[]
  end
JQ_EOF
)"

PY_PROG="$(cat <<'PY_EOF'
import json, re, sys

registry_path, today, evidence_path, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def fail(msg):
    sys.stderr.write("ERROR: " + msg + "\n")
    sys.exit(4)

try:
    reg = json.load(open(registry_path))
except Exception:
    fail("registry is not valid JSON: " + registry_path)
if not isinstance(reg, list):
    fail("registry must be a JSON array")

ev = None
if evidence_path:
    try:
        ev = json.load(open(evidence_path))
    except Exception:
        fail("evidence is not valid JSON: " + evidence_path)
    # Structural gate (review finding 1): iterating a JSON object yields VALUES in jq and
    # KEYS here, which is how a fatal finding became invisible to one engine. Never iterate
    # a container we have not proven to be a list of objects.
    if not isinstance(ev, dict):
        fail("evidence must be a JSON object: " + evidence_path)
    for key in ("navigations", "findings"):
        if key in ev and ev[key] is not None and not isinstance(ev[key], list):
            fail("evidence.%s must be a JSON array" % key)
        for item in (ev.get(key) or []):
            if not isinstance(item, dict):
                fail("evidence.%s[] entries must be JSON objects" % key)

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

def hasctl(v):
    return isinstance(v, str) and any(ord(c) < 32 or ord(c) == 127 for c in v)

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
    return f.get("statusClass") == "fatal" or (is_num(f.get("status")) and f.get("status") >= 500)

def cleared_by(e, ev):
    if not isinstance(ev, dict):
        return False
    if not nes(e.get("surface")):
        return False
    surface = e["surface"]
    # fail-open guard (review finding 2): a navigation with no string url is not evidence
    # of reaching anything, and pathpart("") would degrade to "/".
    ok_nav = any(isinstance(n.get("url"), str) and is_num(n.get("status"))
                 and 200 <= n["status"] < 300 and surfmatch(surface, n["url"])
                 for n in (ev.get("navigations") or []))
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

def ctl_errors(i, e):
    if not isinstance(e, dict):
        return []
    return ["ERROR: entry[%d].%s: contains a control character" % (i, k)
            for k in sorted(e.keys()) if hasctl(e.get(k))]

def entry_errors(i, e, today, seen):
    if not isinstance(e, dict):
        return ["ERROR: entry[%d]: not a JSON object" % i]
    out = []
    for f in REQUIRED:
        if not nes(e.get(f)):
            out.append("ERROR: entry[%d].%s: missing or empty" % (i, f))
    out.extend(ctl_errors(i, e))
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

ctl = []
for i, e in enumerate(reg):
    ctl.extend(ctl_errors(i, e))

lines = []
if mode == "status":
    if ctl:
        sys.stderr.write("".join(l + "\n" for l in ctl))
        sys.exit(3)
    for i, e in enumerate(reg):
        row = {"id": (e.get("id") if isinstance(e, dict) else None),
               "state": entry_state(e, today, ev)}
        lines.append("S\t" + json.dumps(row, separators=(",", ":"), ensure_ascii=False))
else:
    for i, e in enumerate(reg):
        seen = [r.get("id") if isinstance(r, dict) else None for r in reg[:i]]
        lines.extend(entry_errors(i, e, today, seen))
sys.stdout.write("".join(l + "\n" for l in lines))
PY_EOF
)"

# ---- run the selected engine -------------------------------------------------
ERRF="$(mktemp)" || die "cannot create a temporary file"
cleanup() { rm -f "$ERRF"; }
trap cleanup EXIT

if has_jq; then
  command -v jq >/dev/null 2>&1 || die "QA_ENGINE=jq was requested but jq is not installed"
  # Pre-parse both documents so a syntax error reports as itself, instead of being
  # relabelled by a catch-all (review finding 7).
  jq empty "$REGISTRY" >/dev/null 2>&1 || die "registry is not valid JSON: $REGISTRY"
  EV_JSON="null"
  if [ -n "$EVIDENCE" ]; then
    jq empty "$EVIDENCE" >/dev/null 2>&1 || die "evidence is not valid JSON: $EVIDENCE"
    EV_JSON="$(cat "$EVIDENCE")"
  fi
  STREAM="$(jq -r --arg today "$TODAY" --arg mode "$CMD" --arg evpath "$EVIDENCE" \
                  --argjson ev "$EV_JSON" "$JQ_PROG" "$REGISTRY" 2>"$ERRF")"
  ERC=$?
elif has_py; then
  STREAM="$(python3 -c "$PY_PROG" "$REGISTRY" "$TODAY" "$EVIDENCE" "$CMD" 2>"$ERRF")"
  ERC=$?
else
  die "known-defects.sh needs either 'jq' or 'python3'."
fi

case "$ERC" in
  0) : ;;
  3|4)
    # A structural input problem, or control characters in `status` mode. The engine has
    # already written the exact ERROR text; both engines write the same bytes.
    cat "$ERRF" >&2
    exit 2 ;;
  *)
    # Anything else is a genuine engine fault: surface its real diagnostic rather than
    # relabelling it (review finding 7).
    cat "$ERRF" >&2
    die "engine failed (exit $ERC) on $REGISTRY" ;;
esac

# ---- render ------------------------------------------------------------------
if [ "$CMD" = "validate" ]; then
  RC=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" >&2
    RC=1
  done <<EOF
$STREAM
EOF
  # Never exit 0 while errors were printed (the data-baseline.sh bug class).
  exit "$RC"
fi

# status: STDOUT carries S-rows and nothing else. Any other line means the engine did
# something unexpected, so refuse rather than fold it into the JSON.
JSON="["
FIRST=1
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "S$TAB"*)
      if [ "$FIRST" -eq 1 ]; then FIRST=0; else JSON="$JSON,"; fi
      JSON="$JSON${line#S$TAB}" ;;
    *)
      die "unexpected engine output in status mode: $line" ;;
  esac
done <<EOF
$STREAM
EOF
printf '%s]\n' "$JSON"
exit 0
