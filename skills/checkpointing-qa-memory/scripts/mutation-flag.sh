#!/usr/bin/env bash
# mutation-flag.sh — deterministic, agent-untrusted mutation classifier.
#
# THE FLAG IS DERIVED, NEVER TRUSTED FROM AN AGENT-AUTHORED BOOLEAN. Whether a
# criterion mutates state (and therefore must bracket + gate its act phase) is
# decided ONLY from the criterion's ACTION SHAPE — its evidence `kinds`, its
# `httpMethod`, and a mutating-verb match on its `action`/`title` text. An
# agent can never mark a mutating criterion "read-only" to dodge the
# act-phase workaround lint + fingerprint gate: this script does not accept,
# read, or trust any agent-supplied `mutates`/`readOnly` field at all.
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
#         3. `action` or `title` matches a mutating verb, word-
#            boundary, case-insensitive:
#            create|add|new|update|edit|change|delete|remove|submit|
#            save|assign|transfer|approve|reject|invite|revoke|
#            upload|toggle|set                                      -> true
#         4. else                                                   -> false
#            (includes read-only verbs: view|list|show|read|filter|
#             sort|search|open|see|display — these never match rule 3.)
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
VERB_RE='\b(create|add|new|update|edit|change|delete|remove|submit|save|assign|transfer|approve|reject|invite|revoke|upload|toggle|set)\b'

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
    jq -r '
      (if (.kinds | type) == "array" then (.kinds | map(tostring) | join(",")) else "" end),
      ((.httpMethod // "") | tostring),
      ((.action // "") | tostring),
      ((.title // "") | tostring)
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
kinds = obj.get("kinds")
if not isinstance(kinds, list):
    kinds = []
print(",".join(str(k) for k in kinds))
print(str(obj.get("httpMethod") or ""))
print(str(obj.get("action") or ""))
print(str(obj.get("title") or ""))
' "$json" 2>/dev/null)" || die "python3 failed to read fields from <criterion-json>: ${json}"
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
  mapfile -t _mf_lines <<< "$out"
  kinds_csv="${_mf_lines[0]:-}"
  method="${_mf_lines[1]:-}"
  action="${_mf_lines[2]:-}"
  title="${_mf_lines[3]:-}"

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

  # Rule 3: action/title text matches a mutating verb, word-boundary,
  # case-insensitive.
  if grep -Eiq "$VERB_RE" <<< "${action} ${title}"; then
    echo true
    return 0
  fi

  # Rule 4: no mutating signal found (includes read-only verbs).
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
