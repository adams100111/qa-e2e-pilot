#!/usr/bin/env bash
# provenance.sh — provenance binding on evidence artifacts (Plan H2 Task 3,
# spec §5.4). Given an evidence artifact (bake-read-back.json,
# network-response.json, or action-trace.json — the shapes written by
# skills/checkpointing-qa-memory/scripts/record-evidence.sh), determine
# whether it corresponds to a REAL captured toolstream call
# (scripts/toolstream.sh's .qa/runs/<run>/toolstream.jsonl, written by the
# capture-hook). A `pass` whose evidence corresponds to NO captured call is
# the AC-1 forgery signal qa-verify (Plan H2 Task 4) rejects.
#
# USAGE:
#   provenance.sh check <run-id> <artifact-json-or-path>
#       <artifact-json-or-path> is EITHER a path to an existing evidence
#       artifact file (the common case — the exact path record-evidence.sh
#       printed/wrote, e.g. .qa/runs/<run>/evidence/C1/bake-read-back.json)
#       OR, when that path does not exist on disk, the artifact's JSON text
#       given directly on the command line.
#
#       Prints exactly ONE of:
#         bound         — the artifact's read-back corresponds to a captured
#                          toolstream call (containment match, OR an explicit
#                          provenance.sourceRef resolved to a real entry).
#         unbound       — a toolstream exists for this run, but NOTHING in it
#                          corresponds to this artifact's evidence — the
#                          forgery signal. Includes: a dangling
#                          provenance.sourceRef (claims a call that was never
#                          captured); a bake/probe value that appears in NO
#                          captured responseBody; an action-trace whose
#                          sessionCalls (or act steps) is empty or has no
#                          corresponding captured browser_* call.
#         no-toolstream — .qa/runs/<run-id>/toolstream.jsonl does not exist
#                          at all (no capture-hook ever ran for this run —
#                          common on non-Claude harnesses, or Claude runs
#                          predating this feature, or capture-hook disabled
#                          via enforcement.captureHook:false). This is a
#                          BEST-EFFORT DEGRADE, NOT a hard fail here — the
#                          caller (qa-verify, Task 4) decides how much to
#                          discount confidence. A toolstream file that EXISTS
#                          but is empty (the hook ran, captured nothing) is
#                          NOT this case — it falls through to the normal
#                          bound/unbound logic (and, having no captures to
#                          match against, ends up unbound), because "absent"
#                          and "present-but-empty" are different signals: the
#                          former means "we don't know", the latter means
#                          "we looked and found nothing".
#
# CONTAINMENT, NOT EQUALITY (spec §5.4): a value the UI formatted for display
# (currency-formatted, re-cased, whitespace-trimmed, wrapped in surrounding
# JSON) will almost never appear byte-for-byte in a captured backend
# response. The check is SUBSTRING containment of a candidate string inside
# some captured `responseBody`, never exact equality. This is deliberately
# permissive (a real bake IS expected to sometimes pass this check when it
# theoretically "shouldn't" on a coincidental short substring) — that's the
# accepted tradeoff of a best-effort, no-LLM, deterministic check per spec
# decision #2 (no hash-chain / no false assurance from an overly-clever
# check that itself becomes a thing to game).
#
# CANDIDATE EXTRACTION per kind:
#   bake     — the `readBack` value. If it's a scalar, the candidate is its
#              string form. If it's an object or array, candidates are every
#              scalar LEAF VALUE found recursively inside it (its "entity
#              key" in the identifying-value sense, e.g. an `id`/`slug`
#              VALUE, plus any other scalar leaf) — deliberately NOT the
#              object's property/key NAMES themselves ("name", "id", "status"
#              — generic identifiers that recur across unrelated JSON
#              payloads and would produce false "bound" verdicts having
#              nothing to do with correspondence). ANY ONE candidate found as
#              a substring of ANY ONE captured responseBody -> bound.
#   probe    — same leaf extraction over `shape`, plus `status` (as a
#              string) as an extra candidate.
#   action-trace — its `sessionCalls` (preferred — the independent,
#              session.md-derived record) if the artifact HAS a
#              `sessionCalls` key at all (even an empty array — an EXPLICIT
#              empty sessionCalls is itself the forgery signal: the
#              independent trace shows no browser activity, so this is
#              `unbound` regardless of any self-reported `steps`, which are
#              agent-controlled and must never launder a genuinely empty
#              independent record). Only when `sessionCalls` is entirely
#              ABSENT from the artifact does this fall back to `steps`
#              filtered to `phase == "act"`. An empty resulting call list ->
#              unbound immediately (nothing to bind — no captured browser_*
#              call could possibly correspond to zero acts). Otherwise: bound
#              iff ANY call corresponds to ANY captured browser_* toolstream
#              event of a matching class — a sessionCall with class
#              "human-path" matches a captured click/type/fill/press/select/
#              hover/drag/upload tool; class "evaluate" matches a captured
#              browser_evaluate; class "route" matches a captured
#              browser_route; anything else matches any captured browser_*
#              call at all. A bare `steps` entry matches by its own `.tool`
#              name appearing as a substring of a captured tool name (the
#              toolstream's `.tool` is the full MCP tool name, e.g.
#              "mcp__plugin_playwright_playwright__browser_click" — a
#              substring match against the short "browser_click" is
#              intentional, not a bug).
#
# EXPLICIT provenance.sourceRef (optional, written by record-evidence.sh's
# --source-ref): when the artifact carries `.provenance.sourceRef`, THAT is
# authoritative and containment is NOT also consulted — the selector is
# `seq:<N>` (or a bare integer `<N>`, an accepted shorthand for the same
# thing), referencing a captured toolstream event's `seq` field. It resolves
# ("bound") only if a toolstream event with that exact seq was actually
# captured; anything else (malformed selector, or a seq no capture ever
# wrote) -> "unbound" (a dangling sourceRef is itself a forgery signal — the
# agent's claim of "this came from call N" is checked against reality, not
# taken on faith). sourceRef only asserts the CALL is real, not that its
# content matches the evidence value — deliberately: this is the agent
# pointing at ground truth ("that", not "something like that"), and having
# pointed at a REAL entry is what's being verified.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred; python3
#               fallback — QA_ENGINE overrides the auto-detect, same
#               contract as toolstream.sh). Deliberately does NOT depend on
#               node. Containment is plain jq/python3 STRING substring
#               checks (`contains()` / Python `in`) — never a regex, so
#               there is no grep -P/perl portability concern here at all.
#
# NOTE: all paths are relative to the current working directory (project
#       root), matching toolstream.sh/record-evidence.sh's convention.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLSTREAM="${TOOLSTREAM:-$HERE/toolstream.sh}"

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE honored exactly like toolstream.sh — see that file's comment.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

# Mirrors toolstream.sh's validate_run_id (Fix 28 lineage) — a malformed
# run-id must never be used to build a path.
validate_run_id() {
  local value="$1"
  [[ -z "$value" ]] && die "run-id must not be empty."
  case "$value" in
    */*|*\\*) die "run-id '${value}' contains a path separator — must be a simple token." ;;
  esac
  case "$value" in
    *..*) die "run-id '${value}' contains '..' — must be a simple token." ;;
  esac
  if [[ "$value" =~ ^\.+$ ]]; then
    die "run-id '${value}' is '.' or consists only of dots — must be a simple token."
  fi
  case "$value" in
    -*) die "run-id '${value}' starts with '-' — must be a simple token." ;;
  esac
  return 0
}

toolstream_file() { echo "${QA_BASE}/$1/toolstream.jsonl"; }

# ---------------------------------------------------------------------------
# the jq implementation of the check — see the header comment above for the
# full semantics; this is a straight transliteration of it.
# ---------------------------------------------------------------------------
check_jq() {
  local artifact_json="$1" events_json="$2"
  jq -n -r --argjson art "$artifact_json" --argjson events "$events_json" '
    def scalar_str: if . == null then empty else tostring end;
    # leaves: recursively collect scalar VALUES only — NOT object key names.
    # Key names (e.g. name, id, status) are generic and recur across
    # unrelated JSON payloads, so including them as candidates produces
    # false bound verdicts (a forged readBack key would coincidentally
    # match some unrelated captured responses same-named field). Only the
    # actual scalar content is evidence of correspondence.
    def leaves:
      if type == "object" then
        [ .[] | leaves ] | flatten
      elif type == "array" then
        [ .[] | leaves ] | flatten
      elif . == null then
        []
      else
        [ tostring ]
      end;
    def response_bodies:
      [ .[] | (.responseBody // empty) | select(type == "string" and length > 0) ];
    def contained_in_any($cands; $bodies):
      any($cands[]; . as $c | ($c | length) > 0 and any($bodies[]; contains($c)));
    def resolve_source_ref($ref; $events):
      ( $ref | if startswith("seq:") then .[4:] else . end ) as $numstr
      | ( $numstr | test("^-?[0-9]+$") ) as $isnum
      | if $isnum then
          ( $numstr | tonumber ) as $n
          | any($events[]; (.seq? ) == $n)
        else
          false
        end;
    def human_tools: ["browser_click","browser_type","browser_fill_form","browser_press_key","browser_select_option","browser_hover","browser_drag","browser_file_upload"];
    def captured_tool_names($events):
      [ $events[] | (.tool // empty) | select(type == "string" and contains("browser_")) ];
    def call_matches($call; $toolNames):
      if (($call | type) == "object" and ($call | has("class"))) then
        ( $call.class ) as $cls
        | if $cls == "human-path" then
            any($toolNames[]; . as $t | any(human_tools[]; $t | contains(.)))
          elif $cls == "evaluate" then
            any($toolNames[]; contains("browser_evaluate"))
          elif $cls == "route" then
            any($toolNames[]; contains("browser_route"))
          else
            ($toolNames | length) > 0
          end
      else
        ( (($call | type) == "object") and ($call.tool // "" | length > 0) ) as $hasTool
        | if $hasTool then any($toolNames[]; contains($call.tool)) else false end
      end;

    ($art.kind // "") as $kind
    | ( ($art.provenance.sourceRef // null) | if . == null then "" elif type == "string" then . else tostring end ) as $sourceRef
    | if ($sourceRef | length) > 0 then
        if resolve_source_ref($sourceRef; $events) then "bound" else "unbound" end
      elif $kind == "bake" then
        ( ($art.readBack // null) | leaves ) as $cands
        | ( $events | response_bodies ) as $bodies
        | if contained_in_any($cands; $bodies) then "bound" else "unbound" end
      elif $kind == "probe" then
        ( ( ($art.shape // null) | leaves ) + ( if ($art.status != null) then [($art.status | tostring)] else [] end ) ) as $cands
        | ( $events | response_bodies ) as $bodies
        | if contained_in_any($cands; $bodies) then "bound" else "unbound" end
      elif $kind == "action-trace" then
        ( if ($art | type == "object" and has("sessionCalls")) then ($art.sessionCalls // [])
          else ( ($art.steps // []) | map(select((type == "object") and (.phase == "act"))) )
          end ) as $calls
        | if ($calls | length) == 0 then "unbound"
          else
            ( captured_tool_names($events) ) as $toolNames
            | if any($calls[]; call_matches(.; $toolNames)) then "bound" else "unbound" end
          end
      else
        ( ($art) | leaves ) as $cands
        | ( $events | response_bodies ) as $bodies
        | if contained_in_any($cands; $bodies) then "bound" else "unbound" end
      end
  '
}

# ---------------------------------------------------------------------------
# the python3 fallback — same semantics as check_jq, see the header.
# ---------------------------------------------------------------------------
check_py() {
  local artifact_json="$1" events_json="$2"
  python3 - "$artifact_json" "$events_json" <<'PYEOF'
import json, re, sys

def scalar_str(x):
    if x is None:
        return None
    if isinstance(x, bool):
        return "true" if x else "false"
    return str(x)

# leaves: recursively collect scalar VALUES only -- NOT object key names.
# Key names (e.g. "name", "id", "status") are generic and recur across
# unrelated JSON payloads, so including them as candidates produces false
# "bound" verdicts. Only the actual scalar content is evidence of
# correspondence.
def leaves(v):
    out = []
    if isinstance(v, dict):
        for val in v.values():
            out.extend(leaves(val))
    elif isinstance(v, list):
        for el in v:
            out.extend(leaves(el))
    else:
        s = scalar_str(v)
        if s is not None:
            out.append(s)
    return out

def response_bodies(events):
    out = []
    for e in events:
        if not isinstance(e, dict):
            continue
        rb = e.get("responseBody")
        if isinstance(rb, str) and rb:
            out.append(rb)
    return out

def contained_in_any(cands, bodies):
    for c in cands:
        if not c:
            continue
        for b in bodies:
            if c in b:
                return True
    return False

def resolve_source_ref(ref, events):
    ref = str(ref)
    num = ref[4:] if ref.startswith("seq:") else ref
    if not re.match(r'^-?[0-9]+$', num):
        return False
    n = int(num)
    return any(isinstance(e, dict) and e.get("seq") == n for e in events)

HUMAN_TOOLS = ["browser_click", "browser_type", "browser_fill_form", "browser_press_key",
               "browser_select_option", "browser_hover", "browser_drag", "browser_file_upload"]

def captured_tool_names(events):
    out = []
    for e in events:
        if not isinstance(e, dict):
            continue
        t = e.get("tool")
        if isinstance(t, str) and "browser_" in t:
            out.append(t)
    return out

def call_matches(call, tool_names):
    if not isinstance(call, dict):
        return False
    if "class" in call:
        cls = call.get("class")
        if cls == "human-path":
            return any(any(h in t for h in HUMAN_TOOLS) for t in tool_names)
        if cls == "evaluate":
            return any("browser_evaluate" in t for t in tool_names)
        if cls == "route":
            return any("browser_route" in t for t in tool_names)
        return len(tool_names) > 0
    tool = call.get("tool") or ""
    if not tool:
        return False
    return any(tool in t for t in tool_names)

art = json.loads(sys.argv[1])
events = json.loads(sys.argv[2])

kind = art.get("kind") or ""
prov = art.get("provenance") or {}
source_ref = prov.get("sourceRef") if isinstance(prov, dict) else None

if source_ref:
    print("bound" if resolve_source_ref(source_ref, events) else "unbound")
    sys.exit(0)

bodies = response_bodies(events)

if kind == "bake":
    cands = leaves(art.get("readBack"))
    print("bound" if contained_in_any(cands, bodies) else "unbound")
elif kind == "probe":
    cands = leaves(art.get("shape"))
    s = scalar_str(art.get("status"))
    if s is not None:
        cands.append(s)
    print("bound" if contained_in_any(cands, bodies) else "unbound")
elif kind == "action-trace":
    if "sessionCalls" in art:
        calls = art.get("sessionCalls") or []
    else:
        steps = art.get("steps") or []
        calls = [s for s in steps if isinstance(s, dict) and s.get("phase") == "act"]
    if not calls:
        print("unbound")
    else:
        tool_names = captured_tool_names(events)
        matched = any(call_matches(c, tool_names) for c in calls)
        print("bound" if matched else "unbound")
else:
    cands = leaves(art)
    print("bound" if contained_in_any(cands, bodies) else "unbound")
PYEOF
}

# ---------------------------------------------------------------------------
# cmd_check <run-id> <artifact-json-or-path>
# ---------------------------------------------------------------------------
cmd_check() {
  local run_id="$1" artifact_arg="$2"
  validate_run_id "$run_id"
  [[ -n "$artifact_arg" ]] || die "check requires: <run-id> <artifact-json-or-path>"

  local tf
  tf="$(toolstream_file "$run_id")"
  if [[ ! -f "$tf" ]]; then
    echo "no-toolstream"
    return 0
  fi

  local artifact_json
  if [[ -f "$artifact_arg" ]]; then
    artifact_json="$(cat "$artifact_arg")" || die "check: failed to read artifact file: ${artifact_arg}"
  else
    artifact_json="$artifact_arg"
  fi

  if has_jq; then
    jq -e . >/dev/null 2>&1 <<< "$artifact_json" \
      || die "check: artifact is not valid JSON: ${artifact_arg}"
  elif has_py; then
    python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$artifact_json" >/dev/null 2>&1 \
      || die "check: artifact is not valid JSON: ${artifact_arg}"
  else
    die "provenance.sh needs either 'jq' or 'python3'."
  fi

  # events_json: the toolstream's JSONL lines slurped into one JSON array.
  local raw_events events_json
  raw_events="$(bash "$TOOLSTREAM" read "$run_id" 2>/dev/null)"

  if has_jq; then
    events_json="$(printf '%s\n' "$raw_events" | jq -s -c '.' 2>/dev/null)"
    [[ -z "$events_json" ]] && events_json="[]"
    check_jq "$artifact_json" "$events_json"
  elif has_py; then
    events_json="$(python3 -c '
import json, sys
events = []
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        continue
print(json.dumps(events))
' <<< "$raw_events")"
    check_py "$artifact_json" "$events_json"
  else
    die "provenance.sh needs either 'jq' or 'python3'."
  fi
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: provenance.sh check <run-id> <artifact-json-or-path>"
  case "$1" in
    check)
      [[ $# -lt 3 ]] && die "check requires: <run-id> <artifact-json-or-path>"
      cmd_check "$2" "$3"
      ;;
    *)
      die "usage: provenance.sh check <run-id> <artifact-json-or-path>"
      ;;
  esac
}

main "$@"
