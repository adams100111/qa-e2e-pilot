#!/usr/bin/env bash
# mutation-flag.sh — deterministic, agent-untrusted mutation classifier.
#
# THE FLAG IS DERIVED FROM THE CRITERION'S PLAN ROW, NEVER FROM ANYTHING THE
# RUN'S AGENT WRITES DURING VERIFICATION. Whether a criterion mutates state
# (and therefore must bracket + gate its act phase) is decided from the
# checklist row's STRUCTURED fields first and its prose only as a fallback
# (0.9.0, after two real runs lost six read-only criteria to incidental words
# — "compare rows as a set", "Do NOT submit", "the change marker", a quoted
# "Edit my registration" label):
#   - structured POSITIVE signals always win and can never be overridden:
#     `kinds` containing "human-action", a mutating `httpMethod`, and
#     `humanAction: true`;
#   - then an EXPLICIT plan-level declaration decides: `mutates: true|false`,
#     or the `read-only` tag (the tag the checklist schema already defines as
#     "no write to backend", which already suppresses `bake`);
#   - only when the row declares nothing does the mutating-verb match on its
#     `action`/`title` text decide — with negated clauses ("do not submit",
#     "without saving") and URL/path tokens ("/hackathons/create") removed,
#     and the noun-prone `set` matched only as "set <x> to|on|off".
# The declaration is a property of the human-reviewed, frozen plan row
# (checklist.json), the same trust boundary the `read-only` tag's bake
# suppression and every other required-kind rule already sit on; a row that
# declares itself read-only while carrying a structured mutating signal is
# still classified mutating (validate-checklist-json.sh rejects the
# `mutates:false` + `humanAction:true` contradiction outright).
#
# The optional `reconcile` capture-hook cross-check (against a saved
# Playwright MCP session toolstream) is BEST-EFFORT and ABSENT-TOLERANT: the
# capture hook that would populate a toolstream on every run is not built
# yet, so `derive`'s rules are the guarantee today. `reconcile` degrades
# silently to the `derive` result whenever the toolstream path is absent,
# missing, or empty, or when `node` is not on PATH — `node` is NEVER a hard
# dependency of this script.
#
# USAGE:
#   mutation-flag.sh derive <criterion-json>
#       Prints `true` or `false`. Rules, FIRST MATCH WINS:
#         1. `kinds` array contains "human-action"                  -> true
#            (wins even when the action/title text is a read verb.)
#         2. `httpMethod` (case-insensitive) is one of
#            POST | PUT | PATCH | DELETE                            -> true
#         3. `humanAction` is the boolean true                      -> true
#         4. `mutates` is a boolean                                 -> its value
#         5. `tags` contains "read-only"                            -> false
#         6. `action` or `title` — after lowercasing, removing negated
#            clauses (do not / don't / does not / must not / should not /
#            never / without ... up to the next , ; : . ! ?) and every
#            token containing a "/" (URLs, route paths) — matches a
#            mutating verb, word-boundary:
#            create|add|new|update|edit|change|delete|remove|submit|
#            save|assign|transfer|approve|reject|invite|revoke|
#            upload|toggle                                          -> true
#            or "set <up to two words> to|on|off"                   -> true
#            or an UPPERCASE POST|PUT|PATCH|DELETE in the raw text  -> true
#         7. else                                                   -> false
#            (includes read-only verbs: view|list|show|read|filter|
#             sort|search|open|see|display — these never match rule 6,
#             and a bare noun "set" — "compare rows as a set" — no
#             longer does either.)
#
#   mutation-flag.sh reconcile <criterion-json> [<toolstream-path>]
#       Computes `derive` first. If <toolstream-path> is given AND exists
#       AND is non-empty AND `node` is present, AND the derive result was
#       `false`, the toolstream is parsed with parse-session-log.js's
#       `mutates()`/`parse()` classifier (the SAME classifier
#       check-action-trace.js uses). If it shows a mutating tool call
#       recorded in that toolstream, prints `true` and writes a
#       `{"rule":"mutation-observed-in-readonly"}` note to fd 3 (a
#       reconciliation record for a caller that wants to log the anomaly).
#       In every other case (path absent/missing/empty, node absent, or the
#       toolstream shows no mutation) prints the `derive` result unchanged.
#       `reconcile` only ever STRENGTHENS a false derive to true — it never
#       weakens a true derive.
#
# DEPENDENCIES: bash, coreutils, grep, and EITHER jq OR python3 (jq
# preferred; python3 fallback) to read the criterion JSON fields. `node` is
# OPTIONAL — used only by `reconcile`'s cross-check — and this script never
# hard-fails without it.
#
# Verb matching uses `grep -Ei` with `\b` word boundaries (a GNU/BSD grep
# extension, NOT `grep -P`/PCRE) — the portability suite
# (tests/portability/run.sh) forbids `grep -P`/`perl` in bundled scripts, so
# this deliberately avoids that dependency.

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

# The mutating-verb list, word-boundary, case-insensitive. Deliberately does
# NOT match inside a longer word ("settings" does not match "set"; "overview"
# does not match "view" — and "view" is not in this list anyway, it is a
# read-only verb).
VERB_RE='\b(create|add|new|update|edit|change|delete|remove|submit|save|assign|transfer|approve|reject|invite|revoke|upload|toggle)\b'
# `set` is a mutating verb only in its "set <x> to|on|off" shape — as a bare
# word it is far more often a noun ("compare rows as a set", "the full data
# set"). Up to two plain words may sit between; parentheses never do.
SET_RE='\bset[[:space:]]+([a-z0-9_-]+[[:space:]]+){0,2}(to|on|off)\b'
# The prose normalization (lowercase; drop each negated clause — the negation
# up to the next , ; : . ! ? — and every token containing a "/") is done
# INSIDE read_criterion's jq/python3 step, not with tr/sed: the dual-engine
# suites run this script under a restricted PATH, and the two engines must
# agree byte-for-byte. NEGATION_RE is the shared pattern (no \b, no
# lookaround — valid as both an Oniguruma and a Python regex).
NEGATION_RE="(do not|don't|does not|doesn't|did not|must not|mustn't|should not|shouldn't|never|without)[^,;:.!?]*"

# ---------------------------------------------------------------------------
# read_criterion <criterion-json>
#
# Validates <criterion-json> is a single JSON object, then prints four
# lines to stdout: kinds (comma-joined), httpMethod, action, title (each
# defaulting to "" when absent/non-string/non-array). Dies on invalid JSON
# or a non-object top-level value.
# ---------------------------------------------------------------------------

read_criterion() {
  local json="$1"

  if has_jq; then
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$json" \
      || die "<criterion-json> must be a single JSON object: ${json}"
    jq -r --arg neg "$NEGATION_RE" '
      def oneline: gsub("[\r\n]+"; " ");
      (if (.kinds | type) == "array" then (.kinds | map(tostring) | join(",")) else "" end),
      ((.httpMethod // "") | tostring),
      ((.action // "") | tostring | oneline),
      ((.title // "") | tostring | oneline),
      (if .humanAction == true then "true" else "" end),
      (if (.mutates | type) == "boolean" then (.mutates | tostring) else "" end),
      (if (.tags | type) == "array" then (.tags | map(tostring) | join(",")) else "" end),
      ( (((.action // "") | tostring | oneline) + " " + ((.title // "") | tostring | oneline))
        | ascii_downcase | gsub($neg; " ") | gsub("[^ \t]*/[^ \t]*"; " ") )
    ' <<< "$json" || die "jq failed to read fields from <criterion-json>: ${json}"
  elif has_py; then
    local pyout
    pyout="$(python3 -c '
import json, sys
try:
    obj = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print("__MUTATION_FLAG_PARSE_ERROR__")
    sys.exit(0)
if not isinstance(obj, dict):
    print("__MUTATION_FLAG_PARSE_ERROR__")
    sys.exit(0)
import re
def oneline(v):
    return re.sub(r"[\r\n]+", " ", v)
def jstr(v):
    # mirror jq tostring for the scalar shapes these fields carry
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, separators=(",", ":"))
    return str(v)
kinds = obj.get("kinds")
if not isinstance(kinds, list):
    kinds = []
tags = obj.get("tags")
if not isinstance(tags, list):
    tags = []
print(",".join(jstr(k) for k in kinds))
print(jstr(obj.get("httpMethod")))
print(oneline(jstr(obj.get("action"))))
print(oneline(jstr(obj.get("title"))))
print("true" if obj.get("humanAction") is True else "")
m = obj.get("mutates")
print(("true" if m else "false") if isinstance(m, bool) else "")
print(",".join(jstr(t) for t in tags))
prose = (oneline(jstr(obj.get("action"))) + " " + oneline(jstr(obj.get("title")))).lower()
prose = re.sub(sys.argv[2], " ", prose)
prose = re.sub(r"[^ \t]*/[^ \t]*", " ", prose)
print(prose)
' "$json" "$NEGATION_RE" 2>/dev/null)" || die "python3 failed to read fields from <criterion-json>: ${json}"
    if [[ "${pyout%%$'\n'*}" == "__MUTATION_FLAG_PARSE_ERROR__" ]]; then
      die "<criterion-json> must be a single JSON object: ${json}"
    fi
    printf '%s\n' "$pyout"
  else
    die "mutation-flag.sh needs either 'jq' or 'python3' to read the criterion JSON."
  fi
}

# ---------------------------------------------------------------------------
# derive <criterion-json> → stdout "true"/"false"
# ---------------------------------------------------------------------------

derive() {
  local json="$1"
  [[ -z "${json:-}" ]] && die "derive requires: <criterion-json>"

  local out kinds_csv method action title
  out="$(read_criterion "$json")" || exit 1
  _mf_lines=()
  while IFS= read -r _mf_line; do _mf_lines+=("$_mf_line"); done <<< "$out"
  kinds_csv="${_mf_lines[0]:-}"
  method="${_mf_lines[1]:-}"
  action="${_mf_lines[2]:-}"
  title="${_mf_lines[3]:-}"
  local human_action="${_mf_lines[4]:-}" declared="${_mf_lines[5]:-}" tags_csv="${_mf_lines[6]:-}"
  local prose="${_mf_lines[7]:-}"

  # Rule 1: kinds contains "human-action" — wins even over a read verb.
  if [[ ",${kinds_csv}," == *,human-action,* ]]; then
    echo true
    return 0
  fi

  # Rule 2: httpMethod is a mutating HTTP verb, case-insensitive.
  if [[ -n "$method" ]] && grep -Eiq '^(POST|PUT|PATCH|DELETE)$' <<< "$method"; then
    echo true
    return 0
  fi

  # Rule 3: the row's structured humanAction:true.
  if [[ "$human_action" == "true" ]]; then
    echo true
    return 0
  fi

  # Rule 4: an explicit plan-level `mutates` declaration.
  if [[ "$declared" == "true" || "$declared" == "false" ]]; then
    echo "$declared"
    return 0
  fi

  # Rule 5: the `read-only` tag ("no write to backend").
  if [[ ",${tags_csv}," == *,read-only,* ]]; then
    echo false
    return 0
  fi

  # Rule 6: prose fallback over the normalized prose read_criterion built
  # (lowercased; negated clauses and path tokens removed).
  if grep -Eq "$VERB_RE" <<< "$prose" || grep -Eq "$SET_RE" <<< "$prose"; then
    echo true
    return 0
  fi
  # An UPPERCASE mutating HTTP verb in the prose ("PATCH /registrations/7")
  # names a write request even when the row has no structured httpMethod.
  # Case-sensitive on purpose: lowercase "post"/"put" are ordinary words.
  if grep -Eq '(^|[^A-Za-z])(POST|PUT|PATCH|DELETE)([^A-Za-z]|$)' <<< "${action} ${title}"; then
    echo true
    return 0
  fi

  # Rule 7: no mutating signal found (includes read-only verbs).
  echo false
}

# ---------------------------------------------------------------------------
# reconcile <criterion-json> [<toolstream-path>] → stdout "true"/"false"
#
# Absent-tolerant: only ever attempts the cross-check when a non-empty
# toolstream path exists AND node is present AND the derive was false.
# Note on the "mutation-observed-in-readonly" strengthening is written to
# fd 3, never stdout (stdout stays exactly "true"/"false" in every case).
# ---------------------------------------------------------------------------

reconcile() {
  local json="$1" toolstream="${2:-}"
  local result
  result="$(derive "$json")" || exit 1

  # Only a false derive is even eligible to be strengthened.
  if [[ "$result" != "false" ]]; then
    echo "$result"
    return 0
  fi

  # Absent-tolerant degrade #1: no toolstream path, or it doesn't exist, or
  # it's empty — the capture-hook is unbuilt today; derive is the guarantee.
  if [[ -z "$toolstream" || ! -s "$toolstream" ]]; then
    echo "$result"
    return 0
  fi

  # Absent-tolerant degrade #2: node is NEVER a hard dependency.
  if ! command -v node >/dev/null 2>&1; then
    echo "$result"
    return 0
  fi

  local script_dir="${BASH_SOURCE[0]%/*}"
  [[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
  local psl="${script_dir}/../../driving-browser-qa/scripts/parse-session-log.js"

  # Absent-tolerant degrade #3: the classifier module itself is missing —
  # best-effort, never a hard failure of this script.
  if [[ ! -f "$psl" ]]; then
    echo "$result"
    return 0
  fi

  # node's require() only resolves a bare relative path (no leading './' or
  # '/') as a node_modules package lookup — resolve to an absolute path so
  # the require below works regardless of the caller's CWD.
  local psl_abs
  psl_abs="$(cd "$(dirname "$psl")" 2>/dev/null && pwd)/$(basename "$psl")"
  if [[ ! -f "$psl_abs" ]]; then
    echo "$result"
    return 0
  fi

  local has_mutation
  has_mutation="$(node -e '
    const { parse } = require(process.argv[1]);
    const fs = require("fs");
    let md = "";
    try { md = fs.readFileSync(process.argv[2], "utf8"); } catch (e) { process.stdout.write(""); process.exit(0); }
    let calls = [];
    try { calls = parse(md); } catch (e) { process.stdout.write(""); process.exit(0); }
    process.stdout.write(calls.some(function (c) { return c && c.mutating; }) ? "true" : "false");
  ' "$psl_abs" "$toolstream" 2>/dev/null)"

  if [[ "$has_mutation" == "true" ]]; then
    echo true
    printf '%s\n' '{"rule":"mutation-observed-in-readonly"}' >&3 2>/dev/null || true
    return 0
  fi

  echo "$result"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: mutation-flag.sh derive <criterion-json>\n       mutation-flag.sh reconcile <criterion-json> [<toolstream-path>]"

  case "$1" in
    derive)
      [[ $# -lt 2 ]] && die "derive requires: <criterion-json>"
      derive "$2"
      ;;
    reconcile)
      [[ $# -lt 2 ]] && die "reconcile requires: <criterion-json> [<toolstream-path>]"
      reconcile "$2" "${3:-}"
      ;;
    *)
      die "usage: mutation-flag.sh {derive|reconcile} …"
      ;;
  esac
}

main "$@"
