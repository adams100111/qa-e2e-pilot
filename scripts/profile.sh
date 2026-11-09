#!/usr/bin/env bash
# profile.sh — resolve a run's ship|smoke|full profile into its EFFECTIVE config
# (pure, dual-engine). Every later phase reads the printed config.
#
# USAGE:
#   profile.sh resolve <config.json> [--run-config <run-config.json>]
#                      [--stack-profile <stack-profile.json>] [--profile ship|smoke|full]
#       Prints the effective config as pretty JSON (sorted keys) on stdout.
#
# RESOLUTION:
#   1. merged = config shallow-merged with run-config (run-config keys win; same as
#      qa-kit/scripts/runconfig-merge.sh).
#   2. profile = --profile flag > run-config.profile > config.profile > "full".
#      Anything else -> exit 1 "unknown profile: <x>".
#   3. Profile defaults fill ONLY keys the user did not set. A key counts as set when it
#      is present in merged, whatever its value (explicit [] / false / null are kept).
#      Object defaults (detection.ux, gates) are filled per leaf.
#        ship : responsiveMatrix desktop 1440x900 + mobile 390x844; colorSchemes
#               [light,dark]; locales from stack-profile (primary.frontend component's
#               i18n.locales, else primary.backend's, else [] -- empty means "app
#               default locale, single pass"; never a placeholder string);
#               detection.ux {objective,advisoryAesthetics,critic,axe} all true;
#               gates {coverage:block, oracle:enforce, dataPolicy:enforce}; maxParallel 3.
#        smoke: ship, but responsiveMatrix desktop only, colorSchemes [light], first
#               locale only, gates.coverage advise.
#        full : no defaults added (today's behaviour).
#   4. Output adds `profile` (the resolved name) and `profileSources`
#      ({<key or dotted leaf>: "user"|"profile-default"}) for every profile-managed key
#      present in the output, so the report can say what the profile turned on.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred; QA_ENGINE=jq|python3
#   forces one). Both engines produce byte-identical output. No node/perl/grep -P.
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

usage="usage: profile.sh resolve <config.json> [--run-config <run-config.json>] [--stack-profile <stack-profile.json>] [--profile ship|smoke|full]"
[ "$#" -ge 2 ] || die "$usage"
[ "$1" = "resolve" ] || die "$usage"
CONFIG="$2"; shift 2
RUNCFG=""; STACK=""; FLAG=""; FLAG_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-config) [ "$#" -ge 2 ] || die "$usage"; RUNCFG="$2"; shift 2 ;;
    --stack-profile) [ "$#" -ge 2 ] || die "$usage"; STACK="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || die "$usage"; FLAG="$2"; FLAG_SET=1; shift 2 ;;
    *) die "$usage" ;;
  esac
done
[ -f "$CONFIG" ] || die "profile: config not found: $CONFIG"
[ -z "$RUNCFG" ] || [ -f "$RUNCFG" ] || die "profile: run-config not found: $RUNCFG"
[ -z "$STACK" ] || [ -f "$STACK" ] || die "profile: stack-profile not found: $STACK"

# Empty-file placeholders keep a single invocation shape for both engines.
EMPTY_OBJ="$(mktemp)"; trap 'rm -f "$EMPTY_OBJ"' EXIT
printf '%s' '{}' > "$EMPTY_OBJ"
RC_FILE="${RUNCFG:-$EMPTY_OBJ}"
SP_FILE="${STACK:-$EMPTY_OBJ}"
SP_GIVEN=0; [ -n "$STACK" ] && SP_GIVEN=1

if has_jq; then
  jq -n -S --slurpfile c "$CONFIG" --slurpfile r "$RC_FILE" --slurpfile s "$SP_FILE" \
     --arg flag "$FLAG" --argjson flagSet "$FLAG_SET" --argjson spGiven "$SP_GIVEN" '
    ($c[0]) as $cfg | ($r[0]) as $rc | ($s[0]) as $sp
    | if ($cfg|type) != "object" then error("config must be a JSON object") else . end
    | if ($rc|type) != "object" then error("run-config must be a JSON object") else . end
    | if ($sp|type) != "object" then error("stack-profile must be a JSON object") else . end
    | ($cfg + $rc) as $merged
    | (if $flagSet == 1 then $flag
       elif ($rc|has("profile")) and $rc.profile != null then $rc.profile
       elif ($cfg|has("profile")) and $cfg.profile != null then $cfg.profile
       else "full" end) as $p
    | if ($p|type) != "string" or ([$p] - ["ship","smoke","full"] | length) > 0
      then error("unknown profile: " + ($p|if type=="string" then . else tojson end)) else . end
    | def locs($i): if ($i|type)=="number" then (($sp.components // [])[$i].i18n.locales // null) else null end
                    | if (type=="array") and length > 0 then . else null end;
      (if $spGiven == 1 then (locs($sp.primary.frontend) // locs($sp.primary.backend)) else null end
       // []) as $locales
    | def present($path): try (getpath($path[:-1]) as $parent
                               | ($parent|type)=="object" and ($parent|has($path[-1]))) catch false;
      def settable($path): [range(1; $path|length) as $i
                            | try (getpath($path[:$i]) | (type=="object" or type=="null")) catch false]
                           | all;
      ([ ["responsiveMatrix"], ["colorSchemes"], ["locales"],
         ["detection","ux","objective"], ["detection","ux","advisoryAesthetics"],
         ["detection","ux","critic"], ["detection","ux","axe"],
         ["gates","coverage"], ["gates","oracle"], ["gates","dataPolicy"],
         ["maxParallel"] ]) as $tracked
    | (if $p == "full" then {}
       else {
         "responsiveMatrix": (if $p=="smoke" then [{"id":"desktop","width":1440,"height":900}]
                              else [{"id":"desktop","width":1440,"height":900},{"id":"mobile","width":390,"height":844}] end),
         "colorSchemes": (if $p=="smoke" then ["light"] else ["light","dark"] end),
         "locales": (if $p=="smoke" then $locales[:1] else $locales end),
         "detection.ux.objective": true, "detection.ux.advisoryAesthetics": true,
         "detection.ux.critic": true, "detection.ux.axe": true,
         "gates.coverage": (if $p=="smoke" then "advise" else "block" end),
         "gates.oracle": "enforce", "gates.dataPolicy": "enforce",
         "maxParallel": 3 } end) as $defaults
    | reduce $tracked[] as $path ({cfg: $merged, src: {}};
        ($path|join(".")) as $key
        | (.cfg | present($path)) as $isSet
        | if $isSet or (.cfg | settable($path) | not) then
            (if $isSet or ($defaults|has($key)) then .src[$key] = "user" else . end)
          elif ($defaults|has($key)) then
            .cfg |= setpath($path; $defaults[$key]) | .src[$key] = "profile-default"
          else . end)
    | .cfg + {profile: $p, profileSources: .src}
  ' 2>"$EMPTY_OBJ.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(sed -n 's/.*unknown profile: \(.*\)$/\1/p' "$EMPTY_OBJ.err" | head -n1)"
    rm -f "$EMPTY_OBJ.err"
    [ -n "$msg" ] && die "unknown profile: $msg"
    die "profile: jq failed (malformed or non-object input)."
  fi
  rm -f "$EMPTY_OBJ.err"
elif has_py; then
  python3 - "$CONFIG" "$RC_FILE" "$SP_FILE" "$FLAG" "$FLAG_SET" "$SP_GIVEN" <<'PY' || exit 1
import json, sys
cfg_path, rc_path, sp_path, flag, flag_set, sp_given = sys.argv[1:7]
def load(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        sys.exit("ERROR: profile: invalid JSON in " + what)
    if not isinstance(data, dict):
        sys.exit("ERROR: profile: " + what + " must be a JSON object")
    return data
cfg = load(cfg_path, "config"); rc = load(rc_path, "run-config"); sp = load(sp_path, "stack-profile")
merged = dict(cfg); merged.update(rc)
if flag_set == "1":
    p = flag
elif rc.get("profile") is not None:
    p = rc["profile"]
elif cfg.get("profile") is not None:
    p = cfg["profile"]
else:
    p = "full"
if not isinstance(p, str) or p not in ("ship", "smoke", "full"):
    shown = p if isinstance(p, str) else json.dumps(p, ensure_ascii=False, separators=(",", ":"))
    sys.exit("ERROR: unknown profile: " + shown)

def locs(i):
    if not isinstance(i, int) or isinstance(i, bool):
        return None
    comps = sp.get("components") or []
    if not isinstance(comps, list) or not (-len(comps) <= i < len(comps)):
        return None
    comp = comps[i]
    val = ((comp or {}).get("i18n") or {}).get("locales") if isinstance(comp, dict) else None
    return val if isinstance(val, list) and len(val) > 0 else None
primary = sp.get("primary") or {}
locales = None
if sp_given == "1" and isinstance(primary, dict):
    locales = locs(primary.get("frontend")) or locs(primary.get("backend"))
if locales is None:
    locales = []

tracked = [["responsiveMatrix"], ["colorSchemes"], ["locales"],
           ["detection", "ux", "objective"], ["detection", "ux", "advisoryAesthetics"],
           ["detection", "ux", "critic"], ["detection", "ux", "axe"],
           ["gates", "coverage"], ["gates", "oracle"], ["gates", "dataPolicy"],
           ["maxParallel"]]
if p == "full":
    defaults = {}
else:
    smoke = p == "smoke"
    desktop = {"id": "desktop", "width": 1440, "height": 900}
    mobile = {"id": "mobile", "width": 390, "height": 844}
    defaults = {
        "responsiveMatrix": [desktop] if smoke else [desktop, mobile],
        "colorSchemes": ["light"] if smoke else ["light", "dark"],
        "locales": locales[:1] if smoke else locales,
        "detection.ux.objective": True, "detection.ux.advisoryAesthetics": True,
        "detection.ux.critic": True, "detection.ux.axe": True,
        "gates.coverage": "advise" if smoke else "block",
        "gates.oracle": "enforce", "gates.dataPolicy": "enforce",
        "maxParallel": 3,
    }

def walk(obj, path):
    """Return (ok, value) for the container at `path`; ok False when a step is not an object."""
    cur = obj
    for k in path:
        if cur is None:
            return True, None
        if not isinstance(cur, dict):
            return False, None
        cur = cur.get(k)
    return True, cur
def present(obj, path):
    ok, parent = walk(obj, path[:-1])
    return ok and isinstance(parent, dict) and path[-1] in parent
def settable(obj, path):
    for i in range(1, len(path)):
        ok, val = walk(obj, path[:i])
        if not ok or not (val is None or isinstance(val, dict)):
            return False
    return True
def setpath(obj, path, value):
    cur = obj
    for k in path[:-1]:
        nxt = cur.get(k)
        nxt = dict(nxt) if isinstance(nxt, dict) else {}
        cur[k] = nxt
        cur = nxt
    cur[path[-1]] = value

src = {}
for path in tracked:
    key = ".".join(path)
    if present(merged, path) or not settable(merged, path):
        if present(merged, path) or key in defaults:
            src[key] = "user"
    elif key in defaults:
        setpath(merged, path, defaults[key])
        src[key] = "profile-default"
merged["profile"] = p
merged["profileSources"] = src
print(json.dumps(merged, indent=2, sort_keys=True, ensure_ascii=False))
PY
else
  die "profile.sh needs either 'jq' or 'python3'."
fi
