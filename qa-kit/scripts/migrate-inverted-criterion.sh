#!/usr/bin/env bash
# migrate-inverted-criterion.sh — move an INVERTED criterion out of a frozen plan
# and into the project-level known-defect registry, then REFUSE to report success.
#
# WHY THIS EXISTS. The originating incident authored `EC10` with
# `page.rendersWithoutServerError` pinned to "false", so an HTTP 500 was graded
# `match: true` — the crash WAS the expected answer. Task 3's
# `validate-checklist-json.sh` now rejects that shape, which leaves an author holding
# a real, known, unfixed application defect and no legal place to put it. This is that
# place: the criterion leaves the plan and the defect is filed in
# `.qa/known-defects.json` (Task 4's registry — project-level per decision R16), where
# it has no pass/fail and contributes nothing to the tally.
#
# AND THEN IT EXITS 2. The entry is written with `ticket: ""` and `expiry: ""`, because
# this script cannot invent an owner or a deadline. A known defect with neither is
# "deferred by design" under a new name — exactly the disposition the whole spec exists
# to remove — so the command prints the two fields a human must supply and exits
# NON-ZERO. A caller that treats exit 2 as success has recreated the original hole.
#
# USAGE:
#   migrate-inverted-criterion.sh <checklist.json> <criterion-id> [--known-defects <path>]
#     <checklist.json>  the frozen plan (a top-level JSON array of criteria). NEVER a
#                       run-local copy under `.qa/runs/` — see HISTORY below.
#     <criterion-id>    the `id` of the criterion to migrate. Every row with that id is
#                       removed (a duplicate id is already invalid per the validator, and
#                       leaving one behind would leave the crash assertion in the plan).
#     --known-defects   registry path. Default: `.qa/known-defects.json`.
#
# EXIT CODES:
#   2  the migration is recorded (or was already recorded) and HUMAN INPUT IS PENDING.
#      This is the ONLY success path; stdout carries the `REQUIRED-FIELDS:` line.
#   1  nothing was written: bad usage, unusable input, a criterion that is in neither
#      the plan nor the registry, an unreadable source or an unwritable target.
#   0  never returned. There is no "done" state for this command.
#
# WHAT IS DERIVED, AND WHAT IS NOT:
#   title             <- the criterion's `action`, control characters stripped
#   surface           <- the criterion's `surface`
#   observedClass     <- `non-rendering` when the criterion's expect path is in the
#                        reserved health namespace (`page.rendersWithoutServerError`,
#                        `page.crashed`, `console.hasError`, `http.status`), else
#                        `wrong-value`
#   severity          <- `high` for `non-rendering` (the registry's severity FLOOR
#                        requires high|critical there), else `medium`
#   observedBehaviour <- the pinned health assertion, or the criterion's oracle prose
#   observedStatus    <- the pinned `http.status`, when it is an integer
#   migratedFrom      <- the criterion id. This is what makes a re-run idempotent.
#   ticket, expiry    <- ALWAYS "". Not derivable. This is why the exit code is 2.
#
# EVERY DERIVED STRING IS SANITISED (control characters -> space, runs collapsed,
# trimmed, length-capped) and falls back to a non-blank placeholder. The registry
# rejects control characters and blank required fields, so an unsanitised `action`
# would make `known-defects.sh validate` fail for a reason the operator was never told
# to fix and cannot act on. After this script runs, the registry must fail validation
# for EXACTLY two reasons: `ticket` and `expiry` are empty.
#
# HISTORY IS READ-ONLY. Nothing under `.qa/runs/` is ever written — not the run's
# checkpoint, not its journal, not the original incident's `match: true`. A run happened;
# rewriting what it recorded is the falsification this spec exists to prevent. A target
# path under `.qa/runs/` is refused outright (exit 1), which also blocks the laundering
# shape `tests/qa-kit-enforcement/run.sh` already guards for `verify-plan.sh`: the frozen
# SPEC plan is the thing that gets edited, never the agent-amendable run copy.
#
# WRITE ORDER is registry-then-checklist, and each write is atomic (temp file in the
# same directory + rename), so an interruption can leave a filed defect whose criterion
# is still in the plan — never a deleted criterion with no defect filed. A re-run
# finishes the job: the append is skipped when `migratedFrom` already names the
# criterion, so the second pass only removes the row.
#
# DEPENDENCIES: bash 3.2 (no mapfile/readarray/declare -A), EITHER jq OR python3.
# ENGINE SELECTION: QA_ENGINE=jq|python3 forces one; unset auto-selects jq when present.
# The two engines are asserted byte-identical (stdout AND both written files) in
# `tests/qa-kit-enforcement/run.sh`; they are two implementations, so parity is tested,
# not assumed.
set -uo pipefail

TITLE_MAX=200
SURFACE_MAX=200
BEHAV_MAX=300

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  echo "usage: migrate-inverted-criterion.sh <checklist.json> <criterion-id> [--known-defects <path>]" >&2
}

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq)      return 0 ;;
    *)       command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

# ---- arguments ---------------------------------------------------------------
CHECKLIST=""; CID=""; REGISTRY=""; NPOS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --known-defects)
      [ "$#" -ge 2 ] || { usage; die "--known-defects requires a path"; }
      REGISTRY="$2"; shift 2 ;;
    --known-defects=*)
      REGISTRY="${1#*=}"
      [ -n "$REGISTRY" ] || { usage; die "--known-defects requires a path"; }
      shift ;;
    -h|--help) usage; exit 1 ;;
    -*) usage; die "unknown option: $1" ;;
    *)
      NPOS=$((NPOS+1))
      case "$NPOS" in
        1) CHECKLIST="$1" ;;
        2) CID="$1" ;;
        *) usage; die "unexpected extra argument: $1" ;;
      esac
      shift ;;
  esac
done

[ -n "$CHECKLIST" ] || { usage; die "a checklist.json path is required"; }
[ -n "$CID" ]       || { usage; die "a criterion id is required"; }
REGISTRY="${REGISTRY:-.qa/known-defects.json}"

# A criterion id carrying a control character would be copied verbatim into
# `migratedFrom` (it must match exactly for idempotency), and the registry rejects
# control characters. Refuse it here rather than write an entry that fails validation
# for an unfixable reason.
case "$CID" in
  *[[:cntrl:]]*) die "criterion id must not contain control characters" ;;
esac

# HISTORY IS READ-ONLY: refuse either target under `.qa/runs/`.
for p in "$CHECKLIST" "$REGISTRY"; do
  case "$p" in
    .qa/runs/*|*/.qa/runs/*)
      die "refusing to write under .qa/runs/ (run history is read-only): $p" ;;
  esac
done

# ---- preconditions (all of them, before anything is written) -----------------
[ -f "$CHECKLIST" ] || die "checklist not found: $CHECKLIST"
[ -r "$CHECKLIST" ] || die "checklist not readable: $CHECKLIST"
CL_DIR="$(dirname "$CHECKLIST")"
[ -w "$CL_DIR" ] || die "cannot write in the checklist's directory: $CL_DIR"

RG_DIR="$(dirname "$REGISTRY")"
if [ -e "$REGISTRY" ]; then
  [ -f "$REGISTRY" ] || die "registry is not a regular file: $REGISTRY"
  [ -r "$REGISTRY" ] || die "registry not readable: $REGISTRY"
fi
[ -d "$RG_DIR" ] || mkdir -p "$RG_DIR" 2>/dev/null || die "cannot create the registry directory: $RG_DIR"
[ -w "$RG_DIR" ] || die "cannot write in the registry's directory: $RG_DIR"

has_jq || has_py || die "migrate-inverted-criterion.sh needs either 'jq' or 'python3' on PATH."

WORK="$(mktemp -d)" || die "cannot create a temp directory"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cat "$CHECKLIST" > "$WORK/cl.in" 2>/dev/null || die "cannot read the checklist: $CHECKLIST"
if [ -f "$REGISTRY" ]; then
  cat "$REGISTRY" > "$WORK/rg.in" 2>/dev/null || die "cannot read the registry: $REGISTRY"
else
  printf '%s' '[]' > "$WORK/rg.in"
fi

# ---- jq engine ---------------------------------------------------------------
# `--slurpfile` (never `--argjson` fed from a filter) is what gates BOTH inputs to
# exactly one JSON document: its length IS the document count, so a concatenated
# `[...] [...]` is rejected instead of silently processed twice, and an empty file is
# rejected as zero documents.
cat > "$WORK/prog.jq" <<'JQEOF'
def fail($m): ("ERROR: " + $m + "\n") | halt_error(1);

# Trim ASCII spaces only. Deliberately not a regex: this script must not depend on a
# jq built with Oniguruma (the same reason validate-checklist-json.sh avoids one).
def trimSp:
  if type != "string" then .
  else
    ( explode ) as $c
    | ( [ range(0; ($c|length)) | select($c[.] != 32) ] ) as $idx
    | if ($idx|length) == 0 then ""
      else ( $c[ $idx[0] : ($idx[($idx|length) - 1] + 1) ] | implode ) end
  end;

# Control character -> space, collapse runs, trim, cap. Mirrored EXACTLY in the python
# engine; the registry rejects control characters, so this is a correctness gate, not
# cosmetics.
def sanit($max):
  if type != "string" then ""
  else
    ( explode | map( if (. < 32) or (. == 127) then 32 else . end ) ) as $c
    | ( reduce $c[] as $x ( [];
          if ($x == 32) and ((. | length) > 0) and (.[-1] == 32) then . else . + [$x] end ) )
    | implode
    | trimSp
    | if (length > $max) then ( ( .[0:$max] | trimSp ) + "..." ) else . end
  end;

def nonblank($v; $fallback):
  ( $v ) as $s | if ($s | length) > 0 then $s else $fallback end;

# Render a pinned value for prose. Restricted on purpose: a non-integral number renders
# differently in jq and python (500 vs 500.0), so anything outside
# string/bool/null/integer becomes a fixed token rather than an engine-dependent string.
def rendval:
  if type == "string" then ( "\"" + (sanit(120)) + "\"" )
  elif . == true then "true"
  elif . == false then "false"
  elif . == null then "null"
  elif type == "number" then
    ( if ((floor) == .) and (. < 1000000000000000) and (. > -1000000000000000)
      then (floor | tostring) else "<unrenderable>" end )
  else "<unrenderable>" end;

def healthNames: ["page.rendersWithoutServerError","page.crashed","console.hasError","http.status"];

def hitOf($e):
  ( [ ( $e.fixture | if type == "object" then .expect else null end ), ( $e.expect ) ]
    | map( select(type == "object") )
    | map( { p: ( if ((.path | type) == "string") then (.path | trimSp) else null end ), v: .value } )
    | map( select(.p != null) | select( ((([.p] - healthNames)) | length) == 0 ) ) ) as $hits
  | if ($hits | length) > 0 then $hits[0] else null end;

def oracleProse($e):
  ( [ $e.oracle, $e.oracleNote, $e.expected ]
    | map( select(type == "string") | sanit(200) )
    | map( select(length > 0) ) ) as $ps
  | if ($ps | length) > 0 then $ps[0] else "" end;

( $cl | length ) as $cln
| ( $rg | length ) as $rgn
| ( if $cln != 1 then fail("checklist must be exactly one JSON document (got \($cln)): \($clpath)") else . end )
| ( if $rgn != 1 then fail("registry must be exactly one JSON document (got \($rgn)): \($rgpath)") else . end )
| ( $cl[0] ) as $C
| ( $rg[0] ) as $R
| ( if ($C | type) != "array" then fail("checklist must be a JSON array (got \($C|type)): \($clpath)") else . end )
| ( if ($R | type) != "array" then fail("registry must be a JSON array (got \($R|type)): \($rgpath)") else . end )
| ( [ $C[] | select((type == "object") and (.id == $cid)) ] ) as $matches
| ( [ $R[] | select((type == "object") and (.migratedFrom == $cid)) ] ) as $prior
| ( if (($matches | length) == 0) and (($prior | length) == 0)
    then fail("criterion '\($cid)' is not in \($clpath) and no registry entry was migrated from it")
    else . end )
| ( [ $C[] | select(((type == "object") and (.id == $cid)) | not) ] ) as $newC
| ( ($C | length) - ($newC | length) ) as $removed
| ( if ($matches | length) > 0 then $matches[0] else null end ) as $crit
| ( if $crit == null then null else hitOf($crit) end ) as $hit
| ( if $hit == null then "wrong-value" else "non-rendering" end ) as $derivedClass
| ( if $derivedClass == "non-rendering" then "high" else "medium" end ) as $derivedSeverity
| ( if $crit == null then "unknown"
    else nonblank(($crit.surface | sanit($smax)); "unknown") end ) as $derivedSurface
| ( if $crit == null then "" else nonblank(($crit.action | sanit($tmax)); "inverted criterion '\($cid)'") end ) as $derivedTitle
| ( if $hit != null then
      ( "criterion '\($cid)' pinned \($hit.p) to \($hit.v | rendval); describe the observed application failure here" | sanit($bmax) )
    elif ($crit != null) and ((oracleProse($crit) | length) > 0) then
      ( "criterion '\($cid)' asserted: \(oracleProse($crit)); describe the observed application behaviour here" | sanit($bmax) )
    else
      ( "migrated from criterion '\($cid)'; describe the observed application behaviour here" | sanit($bmax) )
    end ) as $derivedBehaviour
| ( if ($hit != null) and ($hit.p == "http.status") and (($hit.v | type) == "number")
      and (($hit.v | floor) == $hit.v) and ($hit.v < 1000000000000000) and ($hit.v > -1000000000000000)
    then ($hit.v | floor) else null end ) as $obsStatus
| ( [ $R[] | select(type == "object") | (.id) | select(type == "string")
      | select(startswith("KD-")) | (.[3:])
      | select((length > 0) and (length <= 9) and ((explode | map((. >= 48) and (. <= 57)) | all)))
      | tonumber ] ) as $nums
| ( if ($nums | length) > 0 then (($nums | max) + 1) else 1 end ) as $next
| ( if ($prior | length) > 0 then false else true end ) as $append
| ( if $append then
      ( { id: "KD-\($next)", title: $derivedTitle, ticket: "", expiry: "",
          severity: $derivedSeverity, observedClass: $derivedClass, surface: $derivedSurface,
          observedBehaviour: $derivedBehaviour }
        + ( if $obsStatus != null then { observedStatus: $obsStatus } else {} end )
        + { migratedFrom: $cid } )
    else null end ) as $entry
| ( if $append then ($R + [$entry]) else $R end ) as $newR
| ( if $append then "KD-\($next)"
    else nonblank((($prior[0].id) | sanit(80)); "(entry with no id)") end ) as $kdid
| ( if $append then $derivedClass else nonblank((($prior[0].observedClass) | sanit(40)); "unknown") end ) as $mClass
| ( if $append then $derivedSeverity else nonblank((($prior[0].severity) | sanit(40)); "unknown") end ) as $mSeverity
| ( if $append then $derivedSurface else nonblank((($prior[0].surface) | sanit($smax)); "unknown") end ) as $mSurface
| { checklist: $newC,
    registry: $newR,
    meta: { kdid: $kdid,
            appended: (if $append then "yes" else "no" end),
            removed: $removed,
            observedClass: $mClass,
            severity: $mSeverity,
            surface: $mSurface } }
JQEOF

engine_jq() {
  jq -n \
    --slurpfile cl "$WORK/cl.in" \
    --slurpfile rg "$WORK/rg.in" \
    --arg cid "$CID" \
    --arg clpath "$CHECKLIST" \
    --arg rgpath "$REGISTRY" \
    --argjson tmax "$TITLE_MAX" \
    --argjson smax "$SURFACE_MAX" \
    --argjson bmax "$BEHAV_MAX" \
    -f "$WORK/prog.jq" > "$WORK/all.json" || return 1
  jq '.checklist' "$WORK/all.json" > "$WORK/checklist.new" || return 1
  jq '.registry'  "$WORK/all.json" > "$WORK/registry.new" || return 1
  jq -r '.meta | to_entries[] | "\(.key)=\(.value)"' "$WORK/all.json" > "$WORK/meta" || return 1
  return 0
}

# ---- python3 engine (fallback) ----------------------------------------------
engine_py() {
  python3 - "$WORK" "$CID" "$CHECKLIST" "$REGISTRY" "$TITLE_MAX" "$SURFACE_MAX" "$BEHAV_MAX" <<'PYEOF'
import json, sys

work, cid, clpath, rgpath = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
TMAX, SMAX, BMAX = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])

HEALTH = ("page.rendersWithoutServerError", "page.crashed", "console.hasError", "http.status")
INT_CAP = 1000000000000000


def fail(msg):
    sys.stderr.write("ERROR: " + msg + "\n")
    sys.exit(1)


def one_doc(path, what):
    """Gate to exactly one JSON document. json.load raises on a concatenated
    `[...] [...]` and on an empty file, which is the same verdict the jq leg reaches
    via --slurpfile length."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        fail("%s must be exactly one JSON document: %s" % (what, path))


def trim_sp(s):
    if not isinstance(s, str):
        return s
    i, j = 0, len(s)
    while i < j and s[i] == " ":
        i += 1
    while j > i and s[j - 1] == " ":
        j -= 1
    return s[i:j]


def sanit(v, mx):
    """Mirrors the jq engine's sanit EXACTLY: control character -> space, collapse
    runs of spaces, trim, cap."""
    if not isinstance(v, str):
        return ""
    out = []
    for ch in v:
        o = ord(ch)
        c = " " if (o < 32 or o == 127) else ch
        if c == " " and out and out[-1] == " ":
            continue
        out.append(c)
    s = trim_sp("".join(out))
    if len(s) > mx:
        s = trim_sp(s[:mx]) + "..."
    return s


def nonblank(s, fallback):
    return s if len(s) > 0 else fallback


def rendval(v):
    if isinstance(v, str):
        return '"' + sanit(v, 120) + '"'
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        if float(v).is_integer() and v < INT_CAP and v > -INT_CAP:
            return str(int(v))
        return "<unrenderable>"
    return "<unrenderable>"


def hit_of(e):
    fx = e.get("fixture")
    cands = [fx.get("expect") if isinstance(fx, dict) else None, e.get("expect")]
    for x in cands:
        if not isinstance(x, dict):
            continue
        p = trim_sp(x.get("path")) if isinstance(x.get("path"), str) else None
        if p is not None and p in HEALTH:
            return {"p": p, "v": x.get("value")}
    return None


def oracle_prose(e):
    for key in ("oracle", "oracleNote", "expected"):
        v = e.get(key)
        if isinstance(v, str):
            s = sanit(v, 200)
            if len(s) > 0:
                return s
    return ""


C = one_doc(work + "/cl.in", "checklist")
R = one_doc(work + "/rg.in", "registry")
if not isinstance(C, list):
    fail("checklist must be a JSON array (got %s): %s" % (type(C).__name__, clpath))
if not isinstance(R, list):
    fail("registry must be a JSON array (got %s): %s" % (type(R).__name__, rgpath))

matches = [e for e in C if isinstance(e, dict) and e.get("id") == cid]
prior = [e for e in R if isinstance(e, dict) and e.get("migratedFrom") == cid]
if not matches and not prior:
    fail("criterion '%s' is not in %s and no registry entry was migrated from it" % (cid, clpath))

newC = [e for e in C if not (isinstance(e, dict) and e.get("id") == cid)]
removed = len(C) - len(newC)
crit = matches[0] if matches else None
hit = hit_of(crit) if crit is not None else None

derived_class = "wrong-value" if hit is None else "non-rendering"
derived_severity = "high" if derived_class == "non-rendering" else "medium"
derived_surface = "unknown" if crit is None else nonblank(sanit(crit.get("surface"), SMAX), "unknown")
derived_title = "" if crit is None else nonblank(sanit(crit.get("action"), TMAX),
                                                 "inverted criterion '%s'" % cid)
if hit is not None:
    derived_behaviour = sanit("criterion '%s' pinned %s to %s; describe the observed "
                              "application failure here" % (cid, hit["p"], rendval(hit["v"])), BMAX)
elif crit is not None and len(oracle_prose(crit)) > 0:
    derived_behaviour = sanit("criterion '%s' asserted: %s; describe the observed "
                              "application behaviour here" % (cid, oracle_prose(crit)), BMAX)
else:
    derived_behaviour = sanit("migrated from criterion '%s'; describe the observed "
                              "application behaviour here" % cid, BMAX)

obs_status = None
if (hit is not None and hit["p"] == "http.status" and isinstance(hit["v"], (int, float))
        and not isinstance(hit["v"], bool) and float(hit["v"]).is_integer()
        and hit["v"] < INT_CAP and hit["v"] > -INT_CAP):
    obs_status = int(hit["v"])

nums = []
for e in R:
    if not isinstance(e, dict):
        continue
    i = e.get("id")
    if not isinstance(i, str) or not i.startswith("KD-"):
        continue
    rest = i[3:]
    if 0 < len(rest) <= 9 and all("0" <= c <= "9" for c in rest):
        nums.append(int(rest))
nxt = (max(nums) + 1) if nums else 1

append = len(prior) == 0
if append:
    entry = {"id": "KD-%d" % nxt, "title": derived_title, "ticket": "", "expiry": "",
             "severity": derived_severity, "observedClass": derived_class,
             "surface": derived_surface, "observedBehaviour": derived_behaviour}
    if obs_status is not None:
        entry["observedStatus"] = obs_status
    entry["migratedFrom"] = cid
    newR = R + [entry]
    kdid = "KD-%d" % nxt
    m_class, m_severity, m_surface = derived_class, derived_severity, derived_surface
else:
    newR = R
    kdid = nonblank(sanit(prior[0].get("id"), 80), "(entry with no id)")
    m_class = nonblank(sanit(prior[0].get("observedClass"), 40), "unknown")
    m_severity = nonblank(sanit(prior[0].get("severity"), 40), "unknown")
    m_surface = nonblank(sanit(prior[0].get("surface"), SMAX), "unknown")


def dump(obj, path):
    with open(path, "w") as f:
        f.write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


dump(newC, work + "/checklist.new")
dump(newR, work + "/registry.new")
with open(work + "/meta", "w") as f:
    f.write("kdid=%s\n" % kdid)
    f.write("appended=%s\n" % ("yes" if append else "no"))
    f.write("removed=%d\n" % removed)
    f.write("observedClass=%s\n" % m_class)
    f.write("severity=%s\n" % m_severity)
    f.write("surface=%s\n" % m_surface)
PYEOF
}

if has_jq; then
  engine_jq || exit 1
else
  engine_py || exit 1
fi

# ---- read back what the engine decided --------------------------------------
[ -f "$WORK/meta" ] || die "internal: the engine produced no meta"
M_kdid=""; M_appended=""; M_removed=""; M_class=""; M_severity=""; M_surface=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  k="${line%%=*}"; v="${line#*=}"
  case "$k" in
    kdid)          M_kdid="$v" ;;
    appended)      M_appended="$v" ;;
    removed)       M_removed="$v" ;;
    observedClass) M_class="$v" ;;
    severity)      M_severity="$v" ;;
    surface)       M_surface="$v" ;;
    *) die "internal: unexpected meta key from the engine: $k" ;;
  esac
done < "$WORK/meta"
case "$M_appended" in yes|no) ;; *) die "internal: bad meta appended='$M_appended'" ;; esac
case "$M_removed" in ''|*[!0-9]*) die "internal: bad meta removed='$M_removed'" ;; esac
[ -n "$M_kdid" ] || die "internal: the engine named no known-defect id"

# ---- write (registry FIRST, atomically) -------------------------------------
# Registry before checklist: an interruption then leaves a filed defect whose criterion
# is still in the plan, never a removed criterion with nothing filed.
atomic_write() { # <target> <source>
  local t="$1" src="$2" dir tmp
  dir="$(dirname "$t")"
  tmp="$(mktemp "$dir/.migrate-inverted.XXXXXX")" || die "cannot create a temp file in $dir"
  if [ -f "$t" ]; then
    cp -p "$t" "$tmp" 2>/dev/null || cp "$t" "$tmp" 2>/dev/null || { rm -f "$tmp"; die "cannot stage $t"; }
  fi
  cat "$src" > "$tmp" || { rm -f "$tmp"; die "write failed: $t"; }
  mv "$tmp" "$t" || { rm -f "$tmp"; die "rename failed: $t"; }
}

if [ "$M_appended" = "yes" ]; then
  atomic_write "$REGISTRY" "$WORK/registry.new"
fi
if [ "$M_removed" -gt 0 ]; then
  atomic_write "$CHECKLIST" "$WORK/checklist.new"
fi

# ---- report, then REFUSE to report success ----------------------------------
if [ "$M_removed" -gt 0 ]; then
  echo "migrated: removed criterion '$CID' from $CHECKLIST ($M_removed row(s))"
fi
if [ "$M_appended" = "yes" ]; then
  echo "migrated: appended known defect $M_kdid to $REGISTRY"
fi
if [ "$M_removed" -eq 0 ] && [ "$M_appended" = "no" ]; then
  echo "already migrated: criterion '$CID' is known defect $M_kdid (no changes written)"
fi
echo "  derived: observedClass=$M_class severity=$M_severity surface=$M_surface"
echo "REQUIRED-FIELDS: ticket expiry"
echo "  ticket - the tracking ticket that owns the fix (e.g. PROJ-123)"
echo "  expiry - the fix deadline as YYYY-MM-DD, at most 90 days from today (the registry caps it there)"
echo "NOT DONE: $M_kdid has no owner and no deadline, so nothing is fixed and nothing is"
echo "scheduled. A known defect without both is \"deferred by design\" under a new name."
echo "Fill both fields in, then: known-defects.sh validate $REGISTRY"
exit 2
