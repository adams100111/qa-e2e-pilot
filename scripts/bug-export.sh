#!/usr/bin/env bash
# bug-export.sh — turn a run's findings into a tracker-neutral bug export.
#
#   bug-export.sh <run-dir> --out <dir> [--known-defects <registry.json>] [--today YYYY-MM-DD]
#
# Writes <dir>/bugs.json (an array of
#   {id, title, severity, layer, criterionId, journeyId?, persona, steps, expected,
#    actual, evidence:[paths], duplicateOf?})
# and one plain-business-language <dir>/<id>.md per NEW bug (sections: What happened,
# What should happen, Steps, Evidence). Prints {"exported":N,"duplicates":N,"skipped":N}.
#
# SOURCES: <run-dir>/bug-log.json in any of its three accepted shapes (a bare array,
# {"entries":[...]}, {"bugs":[...]} - the same set render-report.js loadBugs reads, with
# the same field aliases) PLUS every verification.json record where the in-run verdict
# was `pass` but the independent verifier did not agree, when no bug entry already covers
# that criterion (and persona).
#
# DEDUP: a bug whose `surface` (alias url|route) path equals the `surface` of an
# `outstanding` known defect (scripts/known-defects.sh status, as of --today) gets
# duplicateOf=<defect id> and NO .md, but only when ALSO (a) the defect names a criterion
# (criterionId|criterion) and it equals the bug's, or (b) the defect names none and its
# observedClass equals the bug's class (explicit observedClass|class on the bug, else:
# layer FE + a blank/not-loading symptom -> non-rendering; a wrong/lost/stale value ->
# wrong-value; any other known layer -> degraded; no layer -> undetermined, never dedups).
# The root path "/" alone never dedups. Expired / cleared defects never dedup: an overdue
# waiver must not keep silencing a live bug.
#
# SEVERITY: the bug-log's own `severity` wins; else layer matching route|service|
# migration|db -> high, anything else (FE, unknown) -> medium.
#
# IDS: sanitised to [A-Za-z0-9._-]; an id with any non-ASCII character becomes
# BUG-<first 8 hex of sha1(original id)> (stable across runs); a name already used (compared
# case-insensitively) is bumped with -2, -3, ... until free.
#
# SECRETS: input is scrubbed before anything is written. Fields whose KEY is a configured
# enforcement.redactedKeys entry (or looks like password/secret/token/api key/
# authorization/cookie/credential) are dropped; redactedKeys literals and
# enforcement.secretPatterns matches inside any string become "<redacted>" (absent
# secretPatterns -> a built-in default, same fail-safe stance as toolstream.sh). Config is
# read from <run-dir>/../../config.json (i.e. .qa/config.json) when present.
#
# DEPENDENCIES: bash 3.2, EITHER jq OR python3 (QA_ENGINE=jq|python3 forces one). Both
# engines write byte-identical files (UTF-8 kept, never \u-escaped).
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 2; }
usage() { echo "usage: bug-export.sh <run-dir> --out <dir> [--known-defects <registry.json>] [--today YYYY-MM-DD]" >&2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN=""; OUT=""; REG=""; TODAY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || die "--out needs a path"; OUT="$2"; shift 2 ;;
    --known-defects) [ "$#" -ge 2 ] || die "--known-defects needs a path"; REG="$2"; shift 2 ;;
    --today) [ "$#" -ge 2 ] || die "--today needs a date"; TODAY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "unknown option: $1" ;;
    *) if [ -z "$RUN" ]; then RUN="$1"; else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[ -n "$RUN" ] || { usage; die "missing <run-dir>"; }
[ -n "$OUT" ] || { usage; die "missing --out <dir>"; }
[ -d "$RUN" ] || die "run dir not found: $RUN"
[ -n "$TODAY" ] || TODAY="$(date +%Y-%m-%d)"
[[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--today must be YYYY-MM-DD (got '$TODAY')"
[ -z "$REG" ] || [ -f "$REG" ] || die "known-defects registry not found: $REG"

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
if has_jq; then ENGINE=jq; else command -v python3 >/dev/null 2>&1 && ENGINE=python3 || die "need jq or python3"; fi
[ "$ENGINE" = jq ] && ! command -v jq >/dev/null 2>&1 && die "QA_ENGINE=jq requested but jq is not installed"

mkdir -p "$OUT" || die "cannot create $OUT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bug-export.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# Inputs, each normalised to one JSON document (absent -> null).
load() { if [ -f "$1" ]; then cp "$1" "$2"; else printf 'null\n' > "$2"; fi; }
load "$RUN/bug-log.json" "$TMP/bl.json"
load "$RUN/verification.json" "$TMP/ver.json"
load "$RUN/../../config.json" "$TMP/cfg.json"
printf 'null\n' > "$TMP/reg.json"; printf 'null\n' > "$TMP/st.json"
if [ -n "$REG" ]; then
  cp "$REG" "$TMP/reg.json"
  QA_ENGINE="$ENGINE" bash "$HERE/known-defects.sh" status "$REG" "$TODAY" > "$TMP/st.json" 2> "$TMP/st.err" \
    || die "known-defects status failed: $(head -c 300 "$TMP/st.err")"
fi
if [ "$ENGINE" = python3 ]; then
  python3 -I - "$TMP" "$OUT" <<'PY' || die "python engine failed"
import hashlib, json, os, re, sys
tmp, out = sys.argv[1], sys.argv[2]

def rd(n):
    with open(os.path.join(tmp, n), encoding="utf-8") as f:
        return json.load(f)
try:
    bl, ver, cfg, reg, st = rd("bl.json"), rd("ver.json"), rd("cfg.json"), rd("reg.json"), rd("st.json")
except ValueError as e:
    sys.stderr.write("ERROR: unparseable input: %s\n" % e); sys.exit(2)

CTRL = re.compile("[\x01-\x08\x0b-\x1f\x7f]")
SENS_KEY = re.compile("password|passwd|secret|token|api[_-]?key|authorization|cookie|credential", re.I)
DEFAULT_PATTERNS = ["(password|passwd|secret|token|api[_-]?key|apikey|authorization|bearer|access[_-]?key|private[_-]?key|client[_-]?secret)\\s*[=:]\\s*\\S+"]
enf = cfg.get("enforcement") if isinstance(cfg, dict) and isinstance(cfg.get("enforcement"), dict) else {}
rk = [k for k in (enf.get("redactedKeys") if isinstance(enf.get("redactedKeys"), list) else []) if isinstance(k, str) and k != ""]
AUTH_PATTERNS = ["authorization\\s*[=:]\\s*((bearer|basic)\\s+)?\\S+", "bearer\\s+[A-Za-z0-9._~+/=-]+", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"]
cfgp = enf.get("secretPatterns") if isinstance(enf.get("secretPatterns"), list) else None
pats = cfgp if cfgp is not None else DEFAULT_PATTERNS
pats = ([] if cfgp == [] else AUTH_PATTERNS) + pats
pats = [re.sub(r"^\(\?i\)", "", p) for p in pats if isinstance(p, str) and p != ""]
cpats = []
for p in pats:
    try: cpats.append(re.compile(p, re.I))
    except re.error: pass
rkl = [k.lower() for k in rk]

def red(v):
    if isinstance(v, dict):
        return {k: red(x) for k, x in v.items() if k.lower() not in rkl and not SENS_KEY.search(k)}
    if isinstance(v, list):
        return [red(x) for x in v]
    if isinstance(v, str):
        s = CTRL.sub("", v)
        for k in rk: s = s.replace(k, "<redacted>")
        for c in cpats: s = c.sub("<redacted>", s)
        return s
    return v

def first(*vs):
    for v in vs:
        if v is not None and v is not False: return v
    return None
def text(v):
    if isinstance(v, str): return v
    if v is None: return ""
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
def nsurf(s):
    s = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*", "", s)
    s = re.sub(r"[?#].*$", "", s, flags=re.S)
    if len(s) > 1: s = re.sub(r"/+$", "", s) or "/"
    return s if s.startswith("/") else ""
def sid(s):
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", s)
    s = re.sub(r"^[-.]+|[-.]+$", "", s)
    return s or "BUG"
def mkid(orig, bump=None):
    if re.search(r"[^\x00-\x7f]", orig):
        return "BUG-" + hashlib.sha1(orig.encode("utf-8")).hexdigest()[:8]
    return sid(orig)
NONRENDER = re.compile(r"blank|white screen|not render|n.t render|never load|not load|fails to load|empty page|nothing (is )?(shown|displayed|appears)", re.I)
WRONGVAL = re.compile(r"wrong|incorrect|instead of|rather than|(comes|came) back|not (saved|kept)|lost|loses|stale|mismatch", re.I)
def bug_class(b, layer, title, actual):
    for k in ("observedClass", "observed_class", "class"):
        if b.get(k) in ("non-rendering", "wrong-value", "degraded"): return b[k]
    if layer == "": return None
    t = title + " " + actual
    if re.search(r"(^|[^a-z])(fe|frontend|front-end|ui)([^a-z]|$)", layer, re.I) and NONRENDER.search(t): return "non-rendering"
    if WRONGVAL.search(t): return "wrong-value"
    return "degraded"
def sev_for(layer):
    return "high" if re.search("route|service|migration|db", layer, re.I) else "medium"

if isinstance(bl, list): raw = bl
elif isinstance(bl, dict) and isinstance(bl.get("entries"), list): raw = bl["entries"]
elif isinstance(bl, dict) and isinstance(bl.get("bugs"), list): raw = bl["bugs"]
else: raw = []
entries = [x for x in raw if isinstance(x, dict)]
skipped = len(raw) - len(entries)
entries = [red(x) for x in entries]

items = []  # (base id, bug dict, surface)
for n, b in enumerate(entries, 1):
    layer = text(first(b.get("suspected_layer"), b.get("layer"), ""))
    steps = first(b.get("steps"), b.get("repro"))
    steps = [text(x) for x in steps] if isinstance(steps, list) else ([text(steps)] if isinstance(steps, str) and steps != "" else [])
    ev = first(b.get("evidence_refs"), b.get("evidence"))
    ev = [x for x in ev if isinstance(x, str)] if isinstance(ev, list) else []
    actual = text(b.get("actual")); expected = text(b.get("expected"))
    title = text(b.get("title"))
    if title == "":
        title = re.split(r"[.\n]", actual)[0][:80].strip() if actual != "" else ""
        if title == "": title = "Problem found while checking the feature"
    sev = b.get("severity")
    sev = sev if isinstance(sev, str) and sev != "" else sev_for(layer)
    orig = text(first(b.get("bug_id"), b.get("id"), "BUG-%d" % n))
    d = {"id": mkid(orig), "title": title, "severity": sev, "layer": layer,
         "criterionId": text(first(b.get("criterion_id"), b.get("criterion"), ""))}
    j = first(b.get("journey_id"), b.get("journeyId"))
    if j is not None and text(j) != "": d["journeyId"] = text(j)
    d.update({"persona": text(first(b.get("persona"), "")), "steps": steps, "expected": expected, "actual": actual, "evidence": ev})
    items.append((d, nsurf(text(first(b.get("surface"), b.get("url"), b.get("route"), ""))), bug_class(b, layer, title, actual)))

if isinstance(ver, list):
    for r in ver:
        if not isinstance(r, dict): continue
        if r.get("inRunVerdict") != "pass" or not isinstance(r.get("verifierVerdict"), str) or r["verifierVerdict"] == "pass": continue
        r = red(r)
        crit = text(first(r.get("criterionId"), "")); per = text(first(r.get("persona"), ""))
        if any(d["criterionId"] == crit and (d["persona"] == per or d["persona"] == "" or per == "") for d, _, _c in items):
            skipped += 1; continue
        rs = [text(x) for x in r["reasons"]] if isinstance(r.get("reasons"), list) else []
        items.append(({"id": mkid("VERIFY-" + crit + ("-" + per if per else "")),
                       "title": "A step that looked fine did not hold up when re-checked",
                       "severity": "medium", "layer": "", "criterionId": crit, "persona": per, "steps": [],
                       "expected": "The step should still work when it is checked again from scratch.",
                       "actual": ("An independent re-check could not confirm this step worked. " + "; ".join(rs)).strip(),
                       "evidence": []}, "", None))

# known-defect dedup
rows = {}
for s in (st if isinstance(st, list) else []):
    if isinstance(s, dict): rows[text(s.get("id"))] = s.get("state")
outstanding = []
for e in (reg if isinstance(reg, list) else []):
    if isinstance(e, dict) and rows.get(text(e.get("id"))) == "outstanding":
        c = first(e.get("criterionId"), e.get("criterion"))
        c = None if c is None or text(c) == "" else text(c)
        outstanding.append((text(e.get("id")), nsurf(text(e.get("surface"))), c, e.get("observedClass")))

used = set()
bugs = []
for d, surf, cls in items:
    base = d["id"]; cand = base; k = 1
    while cand.lower() in used:
        k += 1; cand = "%s-%d" % (base, k)
    used.add(cand.lower()); d["id"] = cand
    if surf != "" and surf != "/":
        for eid, es, ec, eoc in outstanding:
            if es != surf: continue
            if (ec is not None and d["criterionId"] != "" and ec == d["criterionId"]) or (ec is None and cls is not None and eoc == cls):
                d["duplicateOf"] = eid; break
    bugs.append(d)

def md(d):
    L = ["# " + d["title"], "", "**Severity:** " + d["severity"]]
    if d["layer"] != "": L.append("**Area:** " + d["layer"])
    L += ["", "## What happened", "", d["actual"] or "Not recorded.", "", "## What should happen", "", d["expected"] or "Not recorded.", "", "## Steps", ""]
    L += ["%d. %s" % (i, s) for i, s in enumerate(d["steps"], 1)] or ["Steps were not recorded."]
    L += ["", "## Evidence", ""]
    L += ["- " + e for e in d["evidence"]] or ["No evidence files were attached."]
    return "\n".join(L) + "\n"

with open(os.path.join(out, "bugs.json"), "w", encoding="utf-8") as f:
    f.write(json.dumps(bugs, indent=2, ensure_ascii=False) + "\n")
exported = 0
for d in bugs:
    if "duplicateOf" in d: continue
    with open(os.path.join(out, d["id"] + ".md"), "w", encoding="utf-8") as f: f.write(md(d))
    exported += 1
print('{"exported":%d,"duplicates":%d,"skipped":%d}' % (exported, len(bugs) - exported, skipped))
PY
  exit 0
fi

# ---- jq engine -----------------------------------------------------------------
cat > "$TMP/export.jq" <<'JQ'
def first_of(xs): ([xs[] | select(. != null and . != false)] | .[0]);
def text: if type == "string" then . elif . == null then "" else tojson end;
def sid: gsub("[^A-Za-z0-9._-]+"; "-") | gsub("^[-.]+|[-.]+$"; "") | if . == "" then "BUG" else . end;
def nsurf: gsub("^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]*"; "") | gsub("[?#].*$"; "")
  | (if length > 1 then (gsub("/+$"; "") | if . == "" then "/" else . end) else . end)
  | if startswith("/") then . else "" end;
def mkid($hm): . as $o | if test("[^\u0000-\u007f]") then "BUG-" + ($hm[$o] // "00000000") else sid end;
def bug_class($b; $layer; $title; $actual):
  (first_of([$b.observedClass, $b.observed_class, $b.class]) ) as $x
  | if ($x == "non-rendering" or $x == "wrong-value" or $x == "degraded") then $x
    elif $layer == "" then null
    else ($title + " " + $actual) as $t
      | if ($layer | test("(^|[^a-z])(fe|frontend|front-end|ui)([^a-z]|$)"; "i")) and ($t | test("blank|white screen|not render|n.t render|never load|not load|fails to load|empty page|nothing (is )?(shown|displayed|appears)"; "i")) then "non-rendering"
        elif ($t | test("wrong|incorrect|instead of|rather than|(comes|came) back|not (saved|kept)|lost|loses|stale|mismatch"; "i")) then "wrong-value"
        else "degraded" end
    end;
def sev_for: if test("route|service|migration|db"; "i") then "high" else "medium" end;

($cfg[0] | if type == "object" and (.enforcement | type) == "object" then .enforcement else {} end) as $enf
| ([($enf.redactedKeys | if type == "array" then .[] else empty end) | select(type == "string" and . != "")]) as $rk
| ($rk | map(ascii_downcase)) as $rkl
| (($enf.secretPatterns | type) == "array") as $hasCfg
| (if $hasCfg then $enf.secretPatterns
   else ["(password|passwd|secret|token|api[_-]?key|apikey|authorization|bearer|access[_-]?key|private[_-]?key|client[_-]?secret)\\s*[=:]\\s*\\S+"] end
   | (if $hasCfg and ($enf.secretPatterns | length) == 0 then [] else ["authorization\\s*[=:]\\s*((bearer|basic)\\s+)?\\S+", "bearer\\s+[A-Za-z0-9._~+/=-]+", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"] end) + .
   | map(select(type == "string" and . != "") | sub("^\\(\\?i\\)"; ""))) as $pats
| def red: walk(
    if type == "object" then
      with_entries(select((.key | ascii_downcase) as $k | (($rkl | index($k)) == null) and ((.key | test("password|passwd|secret|token|api[_-]?key|authorization|cookie|credential"; "i")) | not)))
    elif type == "string" then
      gsub("[\u0001-\u0008\u000b-\u001f\u007f]"; "")
      | reduce $rk[] as $k (.; split($k) | join("<redacted>"))
      | reduce $pats[] as $p (.; try gsub($p; "<redacted>"; "i") catch .)
    else . end);
  ($bl[0]) as $b0
| (if ($b0 | type) == "array" then $b0
   elif ($b0 | type) == "object" and ($b0.entries | type) == "array" then $b0.entries
   elif ($b0 | type) == "object" and ($b0.bugs | type) == "array" then $b0.bugs
   else [] end) as $raw
| ($raw | map(select(type == "object"))) as $objs
| (($raw | length) - ($objs | length)) as $skip0
| [ $objs | to_entries[] | (.key + 1) as $n | (.value | red) as $b
    | (first_of([$b.suspected_layer, $b.layer, ""]) | text) as $layer
    | (first_of([$b.steps, $b.repro]) | if type == "array" then map(text) elif type == "string" and . != "" then [.] else [] end) as $steps
    | (first_of([$b.evidence_refs, $b.evidence]) | if type == "array" then map(select(type == "string")) else [] end) as $ev
    | ($b.actual | text) as $actual
    | (($b.title | text) | if . != "" then . else
         (if $actual != "" then ($actual | split(".")[0] | split("\n")[0] | .[0:80] | gsub("^\\s+|\\s+$"; "")) else "" end)
         | if . == "" then "Problem found while checking the feature" else . end end) as $title
    | ({id: (first_of([$b.bug_id, $b.id, "BUG-\($n)"]) | text | mkid($hm)), title: $title,
        severity: (if ($b.severity | type) == "string" and $b.severity != "" then $b.severity else ($layer | sev_for) end),
        layer: $layer, criterionId: (first_of([$b.criterion_id, $b.criterion, ""]) | text)}
       + (first_of([$b.journey_id, $b.journeyId]) as $j | if $j != null and ($j | text) != "" then {journeyId: ($j | text)} else {} end)
       + {persona: (first_of([$b.persona, ""]) | text), steps: $steps, expected: ($b.expected | text), actual: $actual, evidence: $ev}
       | {d: ., s: (first_of([$b.surface, $b.url, $b.route, ""]) | text | nsurf), c: bug_class($b; $layer; $title; $actual),
         o: (first_of([$b.bug_id, $b.id, "BUG-\($n)"]) | text)}) ] as $logItems
| (if ($ver[0] | type) == "array" then $ver[0] else [] end
   | map(select(type == "object" and .inRunVerdict == "pass" and (.verifierVerdict | type) == "string" and .verifierVerdict != "pass"))) as $over
| (reduce $over[] as $r0 ({items: $logItems, skip: $skip0};
    ($r0 | red) as $r
    | (first_of([$r.criterionId, ""]) | text) as $crit
    | (first_of([$r.persona, ""]) | text) as $per
    | if (.items | any(.d.criterionId == $crit and (.d.persona == $per or .d.persona == "" or $per == ""))) then .skip += 1
      else .items += [{d: {id: ("VERIFY-" + $crit + (if $per != "" then "-" + $per else "" end) | mkid($hm)),
             title: "A step that looked fine did not hold up when re-checked", severity: "medium", layer: "",
             criterionId: $crit, persona: $per, steps: [],
             expected: "The step should still work when it is checked again from scratch.",
             actual: (("An independent re-check could not confirm this step worked. " + ((if ($r.reasons | type) == "array" then $r.reasons | map(text) else [] end) | join("; "))) | gsub("^\\s+|\\s+$"; "")),
             evidence: []}, s: "", c: null,
             o: ("VERIFY-" + $crit + (if $per != "" then "-" + $per else "" end))}] end)) as $acc
| (($st[0] | if type == "array" then map(select(type == "object") | {key: (.id | text), value: .state}) | from_entries else {} end)) as $rows
| ([ ($reg[0] | if type == "array" then .[] else empty end) | select(type == "object")
     | select($rows[(.id | text)] == "outstanding")
     | {id: (.id | text), s: (.surface | text | nsurf), oc: .observedClass,
        c: (first_of([.criterionId, .criterion]) | if . == null then null else text end | if . == "" then null else . end)} ]) as $out
| ($acc.items) as $its
| (reduce range(0; $its | length) as $i ({used: {}, bugs: []};
      $its[$i] as $it
      | ($it.d.id) as $base
      | (def pick($k): ($base + (if $k > 1 then "-\($k)" else "" end)) as $cand
           | if .used[$cand | ascii_downcase] then pick($k + 1) else $cand end;
         pick(1)) as $name
      | .used[$name | ascii_downcase] = true
      | ($it.d | .id = $name) as $d
      | ([ $out[] | select($it.s != "" and $it.s != "/" and .s == $it.s
            and ((.c != null and $d.criterionId != "" and .c == $d.criterionId)
                 or (.c == null and $it.c != null and .oc == $it.c))) | .id ] | .[0]) as $dup
      | .bugs += [if $dup != null then $d + {duplicateOf: $dup} else $d end])) as $fin
| {skipped: $acc.skip, bugs: $fin.bugs, needs: ([$its[] | .o | select(test("[^\u0000-\u007f]"))] | unique)}
JQ
runjq() { jq -n -c --argjson hm "$1" --slurpfile bl "$TMP/bl.json" --slurpfile ver "$TMP/ver.json" --slurpfile cfg "$TMP/cfg.json" \
  --slurpfile reg "$TMP/reg.json" --slurpfile st "$TMP/st.json" -f "$TMP/export.jq" > "$TMP/result.json" 2> "$TMP/jq.err" \
  || die "jq engine failed: $(head -c 300 "$TMP/jq.err")"; }
sha8() { if command -v shasum >/dev/null 2>&1; then shasum -a 1; else sha1sum; fi | cut -c1-8; }
# Pass 1 learns which original ids are non-ASCII; they are hashed here (jq has no sha1) and pass 2 uses them.
runjq '{}'
HM='{}'; NN="$(jq '.needs | length' "$TMP/result.json")"; k=0
while [ "$k" -lt "$NN" ]; do
  H="$(jq -j --argjson k "$k" '.needs[$k]' "$TMP/result.json" | sha8)"
  HM="$(jq -c --argjson k "$k" --arg h "$H" --slurpfile r "$TMP/result.json" '. + {($r[0].needs[$k]): $h}' <<< "$HM")"
  k=$((k + 1))
done
[ "$NN" -eq 0 ] || runjq "$HM"
jq '.bugs' "$TMP/result.json" > "$OUT/bugs.json" || die "cannot write bugs.json"
cat > "$TMP/md.jq" <<'JQ'
.bugs[$i] as $d
| (["# " + $d.title, "", "**Severity:** " + $d.severity]
   + (if $d.layer != "" then ["**Area:** " + $d.layer] else [] end)
   + ["", "## What happened", "", (if $d.actual == "" then "Not recorded." else $d.actual end),
      "", "## What should happen", "", (if $d.expected == "" then "Not recorded." else $d.expected end), "", "## Steps", ""]
   + (if ($d.steps | length) == 0 then ["Steps were not recorded."] else [range(0; $d.steps | length) as $k | "\($k + 1). \($d.steps[$k])"] end)
   + ["", "## Evidence", ""]
   + (if ($d.evidence | length) == 0 then ["No evidence files were attached."] else $d.evidence | map("- " + .) end)
   ) | join("\n")
JQ
N="$(jq '.bugs | length' "$TMP/result.json")"
EXPORTED=0; i=0
while [ "$i" -lt "$N" ]; do
  if [ "$(jq --argjson i "$i" '.bugs[$i] | has("duplicateOf")' "$TMP/result.json")" = false ]; then
    ID="$(jq -r --argjson i "$i" '.bugs[$i].id' "$TMP/result.json")"
    jq -r --argjson i "$i" -f "$TMP/md.jq" "$TMP/result.json" > "$OUT/$ID.md" || die "cannot write $ID.md"
    EXPORTED=$((EXPORTED + 1))
  fi
  i=$((i + 1))
done
printf '{"exported":%d,"duplicates":%d,"skipped":%s}\n' "$EXPORTED" "$((N - EXPORTED))" "$(jq '.skipped' "$TMP/result.json")"
