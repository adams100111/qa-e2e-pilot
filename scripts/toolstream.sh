#!/usr/bin/env bash
# toolstream.sh — append-only toolstream writer/reader + secret redaction for
# capture-hook.sh (Plan H2 Task 1, Layer 1: record). Mirrors journal.sh's
# has_jq/has_py/die + atomic-append idiom
# (skills/checkpointing-qa-memory/scripts/journal.sh): toolstream.jsonl is
# APPEND-ONLY (`>>`), the capture-hook is its sole writer, and QA_ENGINE
# overrides the jq-vs-python3 auto-detect the same way it does there.
#
# USAGE:
#   toolstream.sh append <run-id> <event-json>
#       Validate <event-json> is a single JSON object, stamp a monotonic
#       `seq` (max existing seq in the toolstream + 1, or 1 if absent/empty)
#       and `ts` (current UTC ISO-8601) onto it, and append exactly one
#       compact, newline-terminated line to
#       .qa/runs/<run-id>/toolstream.jsonl. Non-zero + message on malformed
#       input; nothing is written.
#
#   toolstream.sh read <run-id>
#       Print .qa/runs/<run-id>/toolstream.jsonl verbatim (one JSON object
#       per line) to stdout. Prints nothing (exit 0) if the run/file doesn't
#       exist yet — reading before any capture is not an error.
#
#   toolstream.sh redact <args-json> [config-json]
#       Recursively walk <args-json> (typically an object, e.g. a Bash
#       tool's tool_input, or a Bash tool_response wrapped as {"body": ...});
#       for every STRING leaf value:
#         1. any LITERAL occurrence of a value in [config-json]'s
#            .enforcement.redactedKeys (declared credential values) is
#            replaced with "<redacted>" (literal substring match — no regex
#            interpretation of the credential value itself);
#         2. any SUBSTRING matching a regex in the EFFECTIVE secretPatterns
#            list is replaced with "<redacted>" (case-insensitive always; a
#            leading literal "(?i)" in the pattern is stripped first since
#            case-insensitivity is already applied globally by this script,
#            not by the pattern).
#       EFFECTIVE secretPatterns (Finding 1 fail-safe — redaction must NEVER
#       silently no-op just because a project's config has no `enforcement`
#       block):
#         - .enforcement.secretPatterns KEY ABSENT (no `enforcement` block at
#           all, or an `enforcement` block that doesn't mention
#           secretPatterns) -> fall back to $DEFAULT_SECRET_PATTERNS (below):
#           a hard-coded default covering password/passwd/secret/token/
#           api[_-]?key/apikey/authorization/bearer/access[_-]?key/
#           private[_-]?key/client[_-]?secret in KEY=value, "KEY": value, and
#           "KEY":"value" forms.
#         - .enforcement.secretPatterns KEY PRESENT AND EXPLICITLY [] -> the
#           operator opted OUT of pattern-based redaction; honored as truly
#           empty (redactedKeys literal-substring redaction still applies).
#         - .enforcement.secretPatterns KEY PRESENT with a non-empty array ->
#           that array is the effective list (defaults do NOT also apply —
#           an explicit list REPLACES the default, it doesn't extend it).
#       Prints the redacted JSON (same shape; non-string values untouched;
#       array order preserved) to stdout. [config-json] defaults to "{}",
#       which — per the above — still triggers the DEFAULT pattern fallback
#       (no `enforcement` key present in "{}"); redact only becomes a true
#       no-op when secretPatterns is explicitly [] AND redactedKeys is empty
#       or absent. redact must never die mid-hook.
#
# PORTABILITY: secretPatterns MUST be POSIX-ERE-compatible (no lookaround, no
# backreferences) — the jq engine matches them via jq's built-in Oniguruma
# regex (gsub), the python3 fallback via `re`. NEITHER engine shells out to
# `grep -P` or `perl` (both unavailable on some hosts — plain BSD grep has no
# -P at all). If a config pattern uses a PCRE-only construct, only the
# ERE-safe subset is guaranteed to match identically on both engines —
# that's a config-authoring constraint, not something this script can widen.
#
# DEPENDENCIES: bash, coreutils (date, mkdir, cat, dirname), and EITHER jq OR
#               python3 for JSON handling (jq preferred; python3 fallback).
#               Deliberately does NOT depend on node.
#
# NOTE: All paths are relative to the current working directory (project
# root), same convention as journal.sh/checkpoint.sh.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE (unset by default) lets a caller force which JSON engine this
# script uses, overriding the auto-detect below — same contract as
# journal.sh's has_jq (see that file's comment for why: a caller that shells
# out with an augmented PATH needs to force the SAME engine it detected on
# its own real PATH).
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

has_py() { command -v python3 >/dev/null 2>&1; }

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ---------------------------------------------------------------------------
# DEFAULT_SECRET_PATTERNS_JSON — Finding 1 fail-safe default pattern set.
# Applied by cmd_redact ONLY when the effective config has no
# `.enforcement.secretPatterns` KEY AT ALL (absent, not an explicit empty
# array — see the `redact` usage comment above). Each entry matches a common
# secret-bearing key name followed by a `KEY=value` / `KEY: value` /
# `"KEY":"value"` assignment; case-insensitivity is applied globally by
# cmd_redact (not by these patterns). `authorization` and `bearer` use a
# broader value match since an Authorization header's value ("Bearer
# <token>") legitimately contains internal whitespace that a plain `\S+`
# would truncate at, leaking the token itself while only redacting the
# scheme word.
#
# POSIX-ERE-safe subset only (see the PORTABILITY note above this file's
# header): no lookaround, no backreferences, no PCRE-only `(?i)` (handled by
# the case-insensitive match itself, not the pattern). `\s`/`\S` are
# supported identically by jq's Oniguruma engine and Python's `re` — both
# engines used here, neither ever shells out to `grep -P`/`perl`.
# ---------------------------------------------------------------------------
DEFAULT_SECRET_PATTERNS_JSON=$(cat <<'JSONEOF'
[
  "(password)\"?\\s*[:=]\\s*\\S+",
  "(passwd)\"?\\s*[:=]\\s*\\S+",
  "(secret)\"?\\s*[:=]\\s*\\S+",
  "(token)\"?\\s*[:=]\\s*\\S+",
  "(api[_-]?key)\"?\\s*[:=]\\s*\\S+",
  "(apikey)\"?\\s*[:=]\\s*\\S+",
  "(authorization)\"?\\s*[:=]\\s*.+",
  "(bearer)\\s+\\S+",
  "(access[_-]?key)\"?\\s*[:=]\\s*\\S+",
  "(private[_-]?key)\"?\\s*[:=]\\s*\\S+",
  "(client[_-]?secret)\"?\\s*[:=]\\s*\\S+"
]
JSONEOF
)

# ---------------------------------------------------------------------------
# validate_run_id <run-id> — reject anything that could escape
# .qa/runs/<run-id>/ when interpolated into a path (mirrors checkpoint.sh's
# validate_token, Fix 28). A malformed run-id must never be used to build a
# path.
# ---------------------------------------------------------------------------
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

toolstream_file() {
  echo "${QA_BASE}/$1/toolstream.jsonl"
}

# next_seq <file> → stdout int -- max existing `.seq` across all lines + 1 (1
# if the file is absent/empty or has no parseable value). Skips any line
# that fails to parse (e.g. a torn last line — same PIPE_BUF caveat
# journal.sh documents for its own journal) rather than dying on it.
next_seq() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo 1
    return 0
  fi
  local max=0
  if has_jq; then
    local line val
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      val="$(jq -e '.seq' <<< "$line" 2>/dev/null)" || continue
      if [[ "$val" =~ ^[0-9]+$ ]] && (( val > max )); then
        max=$val
      fi
    done < "$file"
  elif has_py; then
    max="$(python3 - "$file" <<'PYEOF'
import json, sys
max_val = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        val = obj.get("seq")
        if isinstance(val, int) and val > max_val:
            max_val = val
print(max_val)
PYEOF
)"
  else
    die "toolstream.sh needs either 'jq' or 'python3' to read the toolstream."
  fi
  [[ -z "$max" ]] && max=0
  echo $((max + 1))
}

# ---------------------------------------------------------------------------
# cmd_append <run-id> <event-json>
# ---------------------------------------------------------------------------
cmd_append() {
  local run_id="$1" event_json="$2"
  validate_run_id "$run_id"
  local file dir
  file="$(toolstream_file "$run_id")"
  dir="$(dirname "$file")"

  if has_jq; then
    # Guard the input parses to EXACTLY ONE JSON value (same multi-value /
    # trailing-content guard journal_append uses — jq -e alone reflects only
    # the LAST value in a stream).
    local value_count
    value_count="$(jq -c . <<< "$event_json" 2>/dev/null | wc -l)"
    if [[ "$value_count" -ne 1 ]] || \
       ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$event_json"; then
      die "append: event JSON must be a single JSON object: ${event_json}"
    fi
  elif has_py; then
    if ! python3 -c '
import json, sys
try:
    obj = json.loads(sys.stdin.read())
except json.JSONDecodeError as e:
    print(f"not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(obj, dict):
    print("not a JSON object", file=sys.stderr)
    sys.exit(1)
' <<< "$event_json" 2>&1 1>/dev/null; then
      die "append: event JSON must be a single JSON object: ${event_json}"
    fi
  else
    die "toolstream.sh needs either 'jq' or 'python3' to validate/append toolstream events."
  fi

  mkdir -p "$dir"

  local now seq line
  now="$(ts)"
  seq="$(next_seq "$file")"
  if has_jq; then
    line="$(jq -c --argjson seq "$seq" --arg t "$now" '. + {seq: $seq, ts: $t}' <<< "$event_json")" \
      || die "append: jq failed to stamp seq/ts onto the event."
  elif has_py; then
    line="$(python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
obj["seq"] = int(sys.argv[1])
obj["ts"] = sys.argv[2]
print(json.dumps(obj, separators=(",", ":")))
' "$seq" "$now" <<< "$event_json")" \
      || die "append: python3 failed to stamp seq/ts onto the event."
  fi

  echo "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# cmd_read <run-id> — emit the toolstream verbatim; absent file = no output.
# ---------------------------------------------------------------------------
cmd_read() {
  local run_id="$1"
  validate_run_id "$run_id"
  local file
  file="$(toolstream_file "$run_id")"
  [[ -f "$file" ]] && cat "$file"
  return 0
}

# ---------------------------------------------------------------------------
# cmd_redact <args-json> [config-json]
# ---------------------------------------------------------------------------
cmd_redact() {
  local args_json="$1"
  local config_json="${2:-}"
  [[ -z "$config_json" ]] && config_json='{}'

  if has_jq; then
    jq -e . >/dev/null 2>&1 <<< "$args_json"   || die "redact: args-json is not valid JSON."
    jq -e . >/dev/null 2>&1 <<< "$config_json" || die "redact: config-json is not valid JSON."
    jq -c --argjson cfg "$config_json" --argjson defaultPats "$DEFAULT_SECRET_PATTERNS_JSON" '
      (($cfg.enforcement // {})) as $enf
      | ($enf | type == "object" and has("secretPatterns")) as $hasExplicit
      | (if $hasExplicit
         then ($enf.secretPatterns // [] | map(select(type == "string")))
         else $defaultPats
         end) as $pats
      | (($enf.redactedKeys // []) | map(select(type == "string" and length > 0))) as $keys
      | def redact_str(s):
          (reduce $keys[] as $k (s; . / $k | join("<redacted>"))) as $s1
          | reduce $pats[] as $p ($s1;
              ($p | sub("^\\(\\?i\\)"; "")) as $pp
              | (try (. | gsub($pp; "<redacted>"; "i")) catch .)
            );
      walk(if type == "string" then redact_str(.) else . end)
    ' <<< "$args_json"
  elif has_py; then
    python3 -c '
import json, re, sys
config_json = sys.argv[1]
default_pats_json = sys.argv[2]
args_json = sys.stdin.read()
try:
    args = json.loads(args_json)
except json.JSONDecodeError:
    print("ERROR: redact: args-json is not valid JSON.", file=sys.stderr)
    sys.exit(1)
try:
    cfg = json.loads(config_json)
except json.JSONDecodeError:
    print("ERROR: redact: config-json is not valid JSON.", file=sys.stderr)
    sys.exit(1)
try:
    default_patterns = json.loads(default_pats_json)
except json.JSONDecodeError:
    default_patterns = []

enforcement = cfg.get("enforcement") or {}
has_explicit = isinstance(enforcement, dict) and "secretPatterns" in enforcement
if has_explicit:
    patterns = [p for p in (enforcement.get("secretPatterns") or []) if isinstance(p, str)]
else:
    patterns = [p for p in default_patterns if isinstance(p, str)]
keys = [k for k in (enforcement.get("redactedKeys") or []) if isinstance(k, str) and k]

compiled = []
for p in patterns:
    pp = p[4:] if p.startswith("(?i)") else p
    try:
        compiled.append(re.compile(pp, re.IGNORECASE))
    except re.error as e:
        print(f"WARN: redact: skipping unparseable secretPattern {p!r}: {e}", file=sys.stderr)

def redact_str(s):
    for k in keys:
        s = s.replace(k, "<redacted>")
    for rx in compiled:
        s = rx.sub("<redacted>", s)
    return s

def walk(v):
    if isinstance(v, str):
        return redact_str(v)
    if isinstance(v, list):
        return [walk(x) for x in v]
    if isinstance(v, dict):
        return {k: walk(x) for k, x in v.items()}
    return v

print(json.dumps(walk(args), separators=(",", ":")))
' "$config_json" "$DEFAULT_SECRET_PATTERNS_JSON" <<< "$args_json"
  else
    die "toolstream.sh needs either 'jq' or 'python3' to redact args."
  fi
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: toolstream.sh append <run-id> <event-json>\n       toolstream.sh read <run-id>\n       toolstream.sh redact <args-json> [config-json]"

  case "$1" in
    append)
      [[ $# -lt 3 ]] && die "append requires: <run-id> <event-json>"
      cmd_append "$2" "$3"
      ;;
    read)
      [[ $# -lt 2 ]] && die "read requires: <run-id>"
      cmd_read "$2"
      ;;
    redact)
      [[ $# -lt 2 ]] && die "redact requires: <args-json> [config-json]"
      cmd_redact "$2" "${3:-}"
      ;;
    *)
      die "usage: toolstream.sh {append|read|redact} …"
      ;;
  esac
}

main "$@"
