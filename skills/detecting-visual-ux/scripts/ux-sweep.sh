#!/usr/bin/env bash
# ux-sweep.sh — the run artifact `ux-sweep.json`: objective UX defects the always-on UX sweep saw on a
# surface that has no visual-ux criterion in the frozen plan (pure, dual-engine).
#
# USAGE:
#   ux-sweep.sh add <run-dir> <json-finding | @file>
#       Appends one finding to <run-dir>/ux-sweep.json ({"version":1,"outsidePlan":[...]}), unless an
#       entry with the same surfaceId + detector + selector is already there (then nothing changes).
#       The finding is a JSON object with non-empty strings `surfaceId`, `detector`, `selector`;
#       optional string `message` (capped at 200 characters), `axis`, `observedIn` (the criterion
#       whose page visit saw it) and object `variant` {viewport?, locale?, colorScheme?}. Other keys
#       are dropped. Prints `added` or `exists`. The file is rewritten atomically (temp file in the
#       run dir, then mv) under a lock directory, so parallel lanes cannot lose an entry.
#   ux-sweep.sh list <run-dir>
#       Prints the outsidePlan array (compact, sorted keys, raw UTF-8); `[]` when the file is absent.
#
# These entries are never verdicts and are never added to the frozen plan; the report lists them under
# "UX defects outside the plan" (render-report.js), outside the tally.
#
# EXIT: 0 ok; 1 invalid finding or malformed existing file (nothing written); 2 usage error.
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (QA_ENGINE=jq|python3 forces one).
set -uo pipefail

usage() { echo "usage: ux-sweep.sh add <run-dir> <json-finding|@file> | list <run-dir>" >&2; exit 2; }
fail() { echo "ERROR: ux-sweep: $*" >&2; exit 1; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

[ "$#" -ge 2 ] || usage
cmd="$1"; run_dir="$2"
[ -d "$run_dir" ] || fail "run dir not found: $run_dir"
file="$run_dir/ux-sweep.json"
has_jq || has_py || fail "needs jq or python3"

# ---------------------------------------------------------------- list
if [ "$cmd" = "list" ]; then
  [ "$#" -eq 2 ] || usage
  if [ ! -f "$file" ]; then echo "[]"; exit 0; fi
  if has_jq; then
    jq -S -c 'if type == "object" and ((.outsidePlan // null) | type) == "array" then .outsidePlan
              elif type == "array" then . else error("malformed ux-sweep.json") end' "$file" 2>/dev/null \
      || fail "malformed $file"
  else
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(d, dict) and isinstance(d.get("outsidePlan"), list): d = d["outsidePlan"]
elif not isinstance(d, list): raise SystemExit(1)
print(json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
' "$file" 2>/dev/null || fail "malformed $file"
  fi
  exit 0
fi

[ "$cmd" = "add" ] || usage
[ "$#" -eq 3 ] || usage
arg="$3"
if [ "${arg#@}" != "$arg" ]; then
  [ -f "${arg#@}" ] || fail "finding file not found: ${arg#@}"
  finding="$(cat "${arg#@}")"
else
  finding="$arg"
fi

lock="$run_dir/.ux-sweep.lock"
tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 200 ] || fail "could not take the lock $lock (remove it if no run is writing)"
  sleep 0.05
done
tmp=""
cleanup() { rmdir "$lock" 2>/dev/null; [ -n "$tmp" ] && rm -f "$tmp"; }
trap cleanup EXIT INT TERM
tmp="$(mktemp "$run_dir/.ux-sweep.XXXXXX")" || fail "cannot create a temp file in $run_dir"

existing="$file"
[ -f "$file" ] || existing=""

if has_jq; then
  out="$(printf '%s' "$finding" | jq -S -c --arg ex "$existing" --slurpfile cur "${existing:-/dev/null}" '
    def nes: type == "string" and length > 0;
    . as $f
    | if ($f | type) != "object" then error("finding must be a JSON object") else . end
    | if ($f.surfaceId | nes) and ($f.detector | nes) and ($f.selector | nes) then .
      else error("finding needs non-empty string surfaceId, detector and selector") end
    | ({surfaceId: $f.surfaceId, detector: $f.detector, selector: $f.selector}
       + (if ($f.message | type) == "string" then {message: ($f.message | .[0:200])} else {} end)
       + (if ($f.axis | nes) then {axis: $f.axis} else {} end)
       + (if ($f.observedIn | nes) then {observedIn: $f.observedIn} else {} end)
       + (if ($f.variant | type) == "object"
            then {variant: ($f.variant | with_entries(select((.key == "viewport" or .key == "locale" or .key == "colorScheme") and (.value | nes))))}
          else {} end)) as $e
    | (if $ex == "" then [] else ($cur[0]
         | if type == "object" and ((.outsidePlan // null) | type) == "array" then .outsidePlan
           elif type == "array" then . else error("malformed ux-sweep.json") end) end) as $list
    | if any($list[]; type == "object" and .surfaceId == $e.surfaceId and .detector == $e.detector and .selector == $e.selector)
      then {status: "exists"} else {status: "added", doc: {version: 1, outsidePlan: ($list + [$e])}} end
  ' 2>&1)" || fail "$(printf '%s' "$out" | sed -n '1p')"
  status="$(printf '%s' "$out" | jq -r '.status')"
  if [ "$status" = "added" ]; then
    printf '%s' "$out" | jq -S -c '.doc' > "$tmp" || fail "write failed"
  fi
else
  out="$(printf '%s' "$finding" | python3 -c '
import json, sys
def nes(v): return isinstance(v, str) and len(v) > 0
try:
    f = json.loads(sys.stdin.read())
except Exception:
    sys.stderr.write("finding is not valid JSON\n"); sys.exit(1)
if not isinstance(f, dict):
    sys.stderr.write("finding must be a JSON object\n"); sys.exit(1)
if not (nes(f.get("surfaceId")) and nes(f.get("detector")) and nes(f.get("selector"))):
    sys.stderr.write("finding needs non-empty string surfaceId, detector and selector\n"); sys.exit(1)
e = {"surfaceId": f["surfaceId"], "detector": f["detector"], "selector": f["selector"]}
if isinstance(f.get("message"), str): e["message"] = f["message"][:200]
if nes(f.get("axis")): e["axis"] = f["axis"]
if nes(f.get("observedIn")): e["observedIn"] = f["observedIn"]
if isinstance(f.get("variant"), dict):
    e["variant"] = {k: v for k, v in f["variant"].items() if k in ("viewport", "locale", "colorScheme") and nes(v)}
lst = []
if sys.argv[1]:
    try:
        d = json.load(open(sys.argv[1], encoding="utf-8"))
    except Exception:
        sys.stderr.write("malformed ux-sweep.json\n"); sys.exit(1)
    if isinstance(d, dict) and isinstance(d.get("outsidePlan"), list): lst = d["outsidePlan"]
    elif isinstance(d, list): lst = d
    else:
        sys.stderr.write("malformed ux-sweep.json\n"); sys.exit(1)
if any(isinstance(x, dict) and x.get("surfaceId") == e["surfaceId"] and x.get("detector") == e["detector"]
       and x.get("selector") == e["selector"] for x in lst):
    print("exists"); sys.exit(0)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"version": 1, "outsidePlan": lst + [e]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
print("added")
' "$existing" "$tmp" 2>&1)" || fail "$(printf '%s' "$out" | sed -n '1p')"
  status="$out"
fi

if [ "$status" = "added" ]; then
  mv -f "$tmp" "$file" || fail "could not replace $file"
  tmp=""
fi
echo "$status"
