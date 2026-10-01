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
#   toolstream.sh redact-browser <tool-name> <args-json> [config-json]
#       Secret-TYPING redaction for the browser tools that put a value into a
#       page field: browser_type ({element, ref, text, ...}) and
#       browser_fill_form ({fields: [{name, type, ref, value}, ...]}). Every
#       other tool name passes <args-json> through unchanged. Prints
#       {"args": <redacted args>, "secrets": [<string>, ...]}.
#         - A field is SECRET when its descriptor strings (every string in
#           the call/field object EXCEPT the typed value: element, ref,
#           selector, name, type, label, ...) match the built-in secret-FIELD
#           set ($SECRET_FIELD_PATTERN: password/passwd/passcode/passphrase/
#           pwd/secret/token/api key/credential/private key/access key/client
#           secret/otp/one-time code/cvv/cvc/security code/pin), OR a
#           descriptor (whole string, or any word of it) probed as
#           "<descriptor>=x" matches the EFFECTIVE secretPatterns (the same
#           list `redact` uses, so a project pattern like "(ssn)..." also
#           marks an "SSN" field secret). A secret field's typed value is
#           replaced WHOLESALE with "<redacted>". The built-in field set is
#           NOT disabled by `"secretPatterns": []` — that opt-out governs
#           pattern redaction of free text; a value typed into a password
#           field is never test data worth recording.
#         - A non-secret field's typed value gets the SAME string pass as
#           `redact` (redactedKeys literal substrings, then the effective
#           secretPatterns) — so a declared credential value typed into an
#           innocuously named field is still masked.
#         - Descriptors (which field, ref, submit/slowly flags) are never
#           altered, so the audit trail survives.
#       "secrets" lists every ORIGINAL typed value that was changed, plus the
#       redactedKeys, each also in its JSON-escaped and JS-quote-escaped
#       spellings (longest first) — the caller masks these literally in the
#       recorded tool_response, which echoes the generated `.fill('<value>')`
#       code. Malformed args (non-object, fields not an array, non-object
#       field entries) pass through unchanged; never dies on them.
#
#   toolstream.sh extract-observed <tool-name>    (tool_response JSON on stdin)
#       0.9.0. Print the compact `observed` findings object the capture hook
#       stores on a browser_evaluate (observe round) or
#       browser_network_requests event — unwrapped from the real MCP content
#       array — or nothing. See "OBSERVED-FINDINGS EXTRACTION" below.
#
#   toolstream.sh observed-rows <toolstream-file>
#       0.9.0. qa-verify's findings-channel reader: six lines per observed
#       network/console row, from `observed` or (pre-0.9.0) responseBody.
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
# OBSERVED-FINDINGS EXTRACTION (0.9.0, ADR-0027).
#
# ROOT CAUSE this closes (found on a real run that injected observe.js
# verbatim and still verified with findingsChannel "none"): qa-verify's
# findings channel parsed each event's `responseBody` as the RAW observe
# payload ({console[], network[]}) or a raw JSON array of requests. The real
# @playwright/mcp never returns either. Every browser tool answers with an
# MCP content array, [{"type":"text","text":"### Result\n<value>\n### Ran
# Playwright code\n..."}], so the observe JSON is a pretty-printed string
# inside markdown inside JSON; and the 4000-byte responseBody cap cuts that
# wrapper mid-string (observe's domDigest alone exceeds it), so it never
# parses at all. browser_network_requests answers with a markdown LIST
# ("12. [GET] https://... => [200] "), never a JSON array. Both channels were
# structurally dead against the real driver.
#
# The fix extracts the findings from the FULL tool_response, at capture time
# and in the capture hook's trust domain (never from anything the agent
# writes), into a compact `observed` field on the event:
#   {"source":"observe","network":[{method,url,status}],"console":[{level,text}]}
#   {"source":"network-requests","network":[{method,url,status}]}
# capped (100 network rows, non-2xx first; 50 console rows; url 1024 chars,
# text 500 chars) so an event line stays small. qa-verify reads `observed`
# first and, for toolstreams recorded before 0.9.0, unwraps the same shapes
# out of `responseBody` when it is intact (`observed-rows`).
#
# One jq library and one python3 library implement both subcommands, so the
# capture-time extraction and the verify-time reader can never drift.
# ---------------------------------------------------------------------------
OBSERVED_JQ_DEFS='
def obs_text:
  if type == "string" then (try fromjson catch .) else . end
  | if type == "array" then [ .[] | select(type == "object" and .type == "text" and (.text | type) == "string") | .text ] | join("\n")
    elif type == "object" and (.content | type) == "array" then [ .content[] | select(type == "object" and .type == "text" and (.text | type) == "string") | .text ] | join("\n")
    elif type == "string" then .
    else "" end;
def obs_result: (split("### Result\n") | if length < 2 then null else (.[1] | split("\n### ")[0]) end);
def obs_int($v): ($v | type) == "number" and ($v == ($v | floor));
def obs_netrow: select(type == "object" and (.url | type) == "string" and (.url | length) > 0 and obs_int(.status))
  | {method: ((.method // "") | tostring | .[0:16]), url: (.url | .[0:1024]), status: .status};
def obs_cap_net: (map(select(.status < 200 or .status >= 300)) + map(select(.status >= 200 and .status < 300))) | .[0:100];
def obs_from_payload:
  if type == "object" and (((.network | type) == "array") or ((.console | type) == "array")) then
    {source: "observe",
     network: ([ (.network // [])[]? | obs_netrow ] | obs_cap_net),
     console: ([ (.console // [])[]? | select(type == "object" and (.text | type) == "string" and (.level == "error" or .level == "warn"))
                 | {level: .level, text: (.text | .[0:500])} ] | .[0:50])}
  else null end;
def obs_netlines:
  [ split("\n")[] | (capture("^\\s*(?:[0-9]+\\.\\s+)?\\[(?<method>[A-Z]+)\\]\\s+(?<url>[^ \\t]+)\\s+=>\\s+\\[(?<status>[0-9]{3})\\]") // empty)
    | {method: .method, url: (.url | .[0:1024]), status: (.status | tonumber)} ];
def observed_for($tool):
  ( obs_text ) as $t
  | ( if ($t | type) == "string" then ($t | obs_result) else null end ) as $r
  | if $r == null then null
    elif ($tool | endswith("browser_network_requests")) then
      ($r | obs_netlines) as $rows
      | if ($rows | length) > 0 then {source: "network-requests", network: ($rows | obs_cap_net)} else null end
    elif ($tool | endswith("browser_evaluate")) then
      ($r | try fromjson catch null | obs_from_payload)
    else null end;
'

OBSERVED_PY_DEFS='
import json, re

def obs_text(v):
    if isinstance(v, str):
        try:
            v = json.loads(v)
        except Exception:
            return v
    items = None
    if isinstance(v, list):
        items = v
    elif isinstance(v, dict) and isinstance(v.get("content"), list):
        items = v["content"]
    elif isinstance(v, str):
        return v
    if items is None:
        return ""
    return "\n".join(i["text"] for i in items if isinstance(i, dict) and i.get("type") == "text" and isinstance(i.get("text"), str))

def obs_result(t):
    parts = t.split("### Result\n")
    if len(parts) < 2:
        return None
    return parts[1].split("\n### ")[0]

def obs_int(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == int(v)

def obs_netrow(e):
    if isinstance(e, dict) and isinstance(e.get("url"), str) and e["url"] and obs_int(e.get("status")):
        m = e.get("method")
        m = "" if m is None else (m if isinstance(m, str) else json.dumps(m))
        st = e["status"]
        return {"method": m[:16], "url": e["url"][:1024], "status": int(st) if float(st).is_integer() else st}
    return None

def obs_cap_net(rows):
    return ([r for r in rows if r["status"] < 200 or r["status"] >= 300] + [r for r in rows if 200 <= r["status"] < 300])[:100]

def obs_from_payload(o):
    if isinstance(o, dict) and (isinstance(o.get("network"), list) or isinstance(o.get("console"), list)):
        net = [r for r in (obs_netrow(e) for e in (o.get("network") or [])) if r is not None]
        con = [{"level": e["level"], "text": e["text"][:500]} for e in (o.get("console") or [])
               if isinstance(e, dict) and isinstance(e.get("text"), str) and e.get("level") in ("error", "warn")][:50]
        return {"source": "observe", "network": obs_cap_net(net), "console": con}
    return None

NETLINE = re.compile(r"^\s*(?:[0-9]+\.\s+)?\[(?P<method>[A-Z]+)\]\s+(?P<url>[^ \t]+)\s+=>\s+\[(?P<status>[0-9]{3})\]")

def obs_netlines(r):
    out = []
    for line in r.split("\n"):
        m = NETLINE.match(line)
        if m:
            out.append({"method": m.group("method"), "url": m.group("url")[:1024], "status": int(m.group("status"))})
    return out

def observed_for(tool, raw):
    t = obs_text(raw)
    r = obs_result(t) if isinstance(t, str) else None
    if r is None:
        return None
    if tool.endswith("browser_network_requests"):
        rows = obs_netlines(r)
        return {"source": "network-requests", "network": obs_cap_net(rows)} if rows else None
    if tool.endswith("browser_evaluate"):
        try:
            o = json.loads(r)
        except Exception:
            return None
        return obs_from_payload(o)
    return None
'

# ---------------------------------------------------------------------------
# cmd_extract_observed <tool-name>  (stdin: the raw tool_response JSON)
#   Prints the compact `observed` object, or NOTHING when the response
#   carries no findings shape (exit 0 either way; never dies on bad input).
# ---------------------------------------------------------------------------
cmd_extract_observed() {
  local tool="$1"
  if has_jq; then
    jq -c -R -s --arg tool "$tool" "${OBSERVED_JQ_DEFS}"'
      (try fromjson catch .) | observed_for($tool) | select(. != null)' 2>/dev/null || true
  elif has_py; then
    python3 -c "${OBSERVED_PY_DEFS}"'
import sys
raw = sys.stdin.read()
try:
    o = observed_for(sys.argv[1], raw)
except Exception:
    o = None
if o is not None:
    print(json.dumps(o, separators=(",", ":"), ensure_ascii=False))
' "$tool" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# cmd_observed_rows <toolstream-file>
#   qa-verify's findings-channel reader. Prints SIX lines per observed row:
#   kind ("net"|"console"), method, url, status, text, "" — qa-verify's
#   observe_rows contract. Per event, in priority order: the capture-time
#   `observed` field; else the LEGACY shapes this reader always accepted (a
#   responseBody that IS the observe object, or IS a JSON array of request
#   records); else the MCP-wrapped responseBody unwrapped via the shared
#   library above (pre-0.9.0 toolstreams, intact bodies only — a body the
#   4000-byte cap cut mid-wrapper still contributes nothing, which can only
#   HIDE a finding, never invent one). Console rows: level "error" only.
# ---------------------------------------------------------------------------
cmd_observed_rows() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if has_jq; then
    jq -R -r "${OBSERVED_JQ_DEFS}"'
      def sane: if type == "string" then ((. / "\n") | join(" ")) | ((. / "\r") | join(" ")) else "" end;
      def istr($v): ($v | type) == "string" and ($v | length) > 0;
      def inum($v): ($v | type) == "number" and ($v == ($v | floor)) and $v > -1000000000000000 and $v < 1000000000000000;
      def netrow: "net", (.method | sane), (.url | sane), (.status | floor | tostring), "", "";
      def legacy_net: select(type == "object") | select(istr(.url) and inum(.status)) | netrow;
      def conrow: "console", "", "", "", (.text | sane), "";
      def emit($b):
        ( ( if ($b.network | type) == "array" then $b.network[] else empty end ) | legacy_net ),
        ( ( if ($b.console | type) == "array" then $b.console[] else empty end )
          | select(type == "object") | select(.level == "error") | select((.text | type) == "string" and (.text | length) > 0) | conrow );
      (try fromjson catch null) as $o
      | if ($o | type) != "object" then empty
        elif ($o.observed | type) == "object" then emit($o.observed)
        else
          ( if ($o.responseBody | type) == "string" then ($o.responseBody | try fromjson catch null) else null end ) as $b
          | if ($b | type) == "object" and ((($b.network | type) == "array") or (($b.console | type) == "array")) then emit($b)
            elif ($b | type) == "array" and ([ $b[] | select(type == "object" and (.url | type) == "string") ] | length) > 0 then
              ( $b[] | legacy_net )
            elif ($o.tool | type) == "string" and ($o.responseBody | type) == "string" then
              ( ($o.responseBody | observed_for($o.tool)) as $u | if $u == null then empty else emit($u) end )
            else empty end
        end
    ' "$f" 2>/dev/null || true
  elif has_py; then
    python3 -c "${OBSERVED_PY_DEFS}"'
import sys

def sane(v):
    return v.replace("\n", " ").replace("\r", " ") if isinstance(v, str) else ""

def istr(v):
    return isinstance(v, str) and len(v) > 0

def fnum(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return v == int(v) and -1000000000000000 < v < 1000000000000000

out = []
def legacy_net(e):
    if isinstance(e, dict) and istr(e.get("url")) and fnum(e.get("status")):
        out.extend(["net", sane(e.get("method")), sane(e.get("url")), str(int(e["status"])), "", ""])

def emit(b):
    for e in (b.get("network") if isinstance(b.get("network"), list) else []):
        legacy_net(e)
    for e in (b.get("console") if isinstance(b.get("console"), list) else []):
        if isinstance(e, dict) and e.get("level") == "error" and isinstance(e.get("text"), str) and e["text"]:
            out.extend(["console", "", "", "", sane(e["text"]), ""])

with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        if isinstance(o.get("observed"), dict):
            emit(o["observed"])
            continue
        rb = o.get("responseBody")
        b = None
        if isinstance(rb, str):
            try:
                b = json.loads(rb)
            except Exception:
                b = None
        if isinstance(b, dict) and (isinstance(b.get("network"), list) or isinstance(b.get("console"), list)):
            emit(b)
        elif isinstance(b, list) and any(isinstance(e, dict) and isinstance(e.get("url"), str) for e in b):
            for e in b:
                legacy_net(e)
        elif isinstance(o.get("tool"), str) and isinstance(rb, str):
            try:
                u = observed_for(o["tool"], rb)
            except Exception:
                u = None
            if u is not None:
                emit(u)

for x in out:
    print(x)
' "$f" 2>/dev/null || true
  fi
  return 0
}

# SECRET_FIELD_PATTERN — built-in secret-FIELD descriptor set for
# redact-browser (Defect 2, 0.8.1). Matched case-insensitively against a
# field's descriptor strings (element/name/selector/ref/type/...), never its
# value. POSIX-ERE-safe (Oniguruma + python `re`); word boundaries use
# explicit non-alphanumeric guards rather than `\b` so both engines agree.
SECRET_FIELD_PATTERN='pass(word|wd|code|phrase)|(^|[^a-z0-9])pwd([^a-z0-9]|$)|secret|token|api[ _-]?key|credential|private[ _-]?key|access[ _-]?key|(^|[^a-z0-9])otp([^a-z0-9]|$)|one[ _-]?time[ _-]?(code|pass)|(^|[^a-z0-9])(cvv|cvc)([^a-z0-9]|$)|security[ _-]?code|(^|[^a-z0-9])pin([^a-z0-9]|$)'

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
# cmd_redact_browser <tool-name> <args-json> [config-json]
# ---------------------------------------------------------------------------
cmd_redact_browser() {
  local tool_name="$1" args_json="$2" config_json="${3:-}"
  [[ -z "$config_json" ]] && config_json='{}'

  if has_jq; then
    jq -e . >/dev/null 2>&1 <<< "$args_json"   || die "redact-browser: args-json is not valid JSON."
    jq -e . >/dev/null 2>&1 <<< "$config_json" || die "redact-browser: config-json is not valid JSON."
    jq -c --arg tool "$tool_name" --argjson cfg "$config_json" \
      --argjson defaultPats "$DEFAULT_SECRET_PATTERNS_JSON" \
      --arg fieldPat "$SECRET_FIELD_PATTERN" --arg sq "'" --arg dq '"' '
      (if ($cfg | type) == "object" then ($cfg.enforcement // {}) else {} end) as $enf0
      | (if ($enf0 | type) == "object" then $enf0 else {} end) as $enf
      | (if ($enf | has("secretPatterns"))
         then ($enf.secretPatterns // [] | if type == "array" then map(select(type == "string")) else [] end)
         else $defaultPats end
         | map(sub("^\\(\\?i\\)"; ""))) as $pats
      | (($enf.redactedKeys // []) | if type == "array" then map(select(type == "string" and length > 0)) else [] end) as $keys
      | def redact_str(s):
          (reduce $keys[] as $k (s; . / $k | join("<redacted>"))) as $s1
          | reduce $pats[] as $p ($s1; (try (. | gsub($p; "<redacted>"; "i")) catch .));
        def pat_hit(c): any($pats[]; . as $p | (try ((c + "=x") | test($p; "i")) catch false));
        def is_secret_desc(strs):
          any(strs[]; (try test($fieldPat; "i") catch false))
          or any(strs[]; . as $d | pat_hit($d) or any(($d | [scan("[A-Za-z0-9_-]+")])[]; pat_hit(.)));
        # redact one {value-key: v, ...descriptors} object -> [newObj, [changed originals]]
        def redact_field(vkey):
          . as $o
          | [ $o | to_entries[] | select(.key != vkey and .key != "values") | .value | select(type == "string") ] as $desc
          | if ($o | has(vkey)) | not then [$o, []]
            elif is_secret_desc($desc) then
              ($o[vkey]) as $v
              | if $v == null then [$o, []]
                else [($o | .[vkey] = "<redacted>"), [ ($v | if type == "string" then . else tojson end) ]] end
            elif ($o[vkey] | type) == "string" then
              ($o[vkey]) as $v | redact_str($v) as $r
              | if $r == $v then [$o, []] else [($o | .[vkey] = $r), [$v]] end
            else [$o, []] end;
        def variants(s):
          [ s,
            (s | tojson | .[1:-1]),
            (s | split("\\") | join("\\\\") | split($sq) | join("\\" + $sq)),
            (s | split("\\") | join("\\\\") | split($sq) | join("\\" + $sq) | tojson | .[1:-1]),
            (s | split("\\") | join("\\\\") | split($dq) | join("\\" + $dq)),
            (s | split("\\") | join("\\\\") | split($dq) | join("\\" + $dq) | tojson | .[1:-1]) ];
      . as $args
      | (if ($args | type) != "object" then [$args, []]
         elif ($tool | test("browser_type$")) then ($args | redact_field("text"))
         elif ($tool | test("browser_fill_form$")) then
           if ($args.fields | type) == "array" then
             ([ $args.fields[] | if type == "object" then redact_field("value") else [., []] end ]) as $rs
             | [ ($args | .fields = [ $rs[] | .[0] ]), [ $rs[] | .[1][] ] ]
           else [$args, []] end
         else [$args, []] end) as $res
      | {args: $res[0],
         secrets: ( [ ($res[1] + (if ($res[1] | length) > 0 then $keys else [] end))[]
                      | select(type == "string" and length > 0) | variants(.)[] ]
                    | unique | map(select(length > 0)) | sort_by(-length) )}
    ' <<< "$args_json"
  elif has_py; then
    python3 -c '
import json, re, sys
tool, config_json, default_pats_json, field_pat = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    args = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("ERROR: redact-browser: args-json is not valid JSON.", file=sys.stderr); sys.exit(1)
try:
    cfg = json.loads(config_json)
except json.JSONDecodeError:
    print("ERROR: redact-browser: config-json is not valid JSON.", file=sys.stderr); sys.exit(1)
try:
    default_patterns = json.loads(default_pats_json)
except json.JSONDecodeError:
    default_patterns = []
enf = cfg.get("enforcement") if isinstance(cfg, dict) else None
if not isinstance(enf, dict):
    enf = {}
if "secretPatterns" in enf:
    sp = enf.get("secretPatterns") or []
    patterns = [p for p in sp if isinstance(p, str)] if isinstance(sp, list) else []
else:
    patterns = [p for p in default_patterns if isinstance(p, str)]
rk = enf.get("redactedKeys") or []
keys = [k for k in rk if isinstance(k, str) and k] if isinstance(rk, list) else []
compiled = []
for p in patterns:
    pp = p[4:] if p.startswith("(?i)") else p
    try:
        compiled.append(re.compile(pp, re.IGNORECASE))
    except re.error as e:
        print(f"WARN: redact-browser: skipping unparseable secretPattern {p!r}: {e}", file=sys.stderr)
field_rx = re.compile(field_pat, re.IGNORECASE)

def redact_str(s):
    for k in keys:
        s = s.replace(k, "<redacted>")
    for rx in compiled:
        s = rx.sub("<redacted>", s)
    return s

def pat_hit(c):
    return any(rx.search(c + "=x") for rx in compiled)

def is_secret_desc(strs):
    if any(field_rx.search(d) for d in strs):
        return True
    for d in strs:
        if pat_hit(d) or any(pat_hit(w) for w in re.findall(r"[A-Za-z0-9_-]+", d)):
            return True
    return False

def redact_field(o, vkey):
    if vkey not in o:
        return o, []
    desc = [v for k, v in o.items() if k != vkey and k != "values" and isinstance(v, str)]
    v = o[vkey]
    if is_secret_desc(desc):
        if v is None:
            return o, []
        n = dict(o); n[vkey] = "<redacted>"
        return n, [v if isinstance(v, str) else json.dumps(v, separators=(",", ":"))]
    if isinstance(v, str):
        r = redact_str(v)
        if r != v:
            n = dict(o); n[vkey] = r
            return n, [v]
    return o, []

changed = []
out = args
if isinstance(args, dict):
    if tool.endswith("browser_type"):
        out, changed = redact_field(args, "text")
    elif tool.endswith("browser_fill_form") and isinstance(args.get("fields"), list):
        nf = []
        for f in args["fields"]:
            if isinstance(f, dict):
                nf_i, ch = redact_field(f, "value"); nf.append(nf_i); changed += ch
            else:
                nf.append(f)
        out = dict(args); out["fields"] = nf

def jsesc(s, q):
    return s.replace("\\", "\\\\").replace(q, "\\" + q)
def jsoninner(s):
    return json.dumps(s)[1:-1]
secrets = set()
for s in (changed + (keys if changed else [])):
    if isinstance(s, str) and s:
        for v in (s, jsoninner(s), jsesc(s, "\x27"), jsoninner(jsesc(s, "\x27")), jsesc(s, "\""), jsoninner(jsesc(s, "\""))):
            if v:
                secrets.add(v)
print(json.dumps({"args": out, "secrets": sorted(secrets, key=lambda x: (-len(x), x))}, separators=(",", ":")))
' "$tool_name" "$config_json" "$DEFAULT_SECRET_PATTERNS_JSON" "$SECRET_FIELD_PATTERN" <<< "$args_json"
  else
    die "toolstream.sh needs either 'jq' or 'python3' to redact browser args."
  fi
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: toolstream.sh append <run-id> <event-json>\n       toolstream.sh read <run-id>\n       toolstream.sh redact <args-json> [config-json]\n       toolstream.sh redact-browser <tool-name> <args-json> [config-json]"

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
    redact-browser)
      [[ $# -lt 3 ]] && die "redact-browser requires: <tool-name> <args-json> [config-json]"
      cmd_redact_browser "$2" "$3" "${4:-}"
      ;;
    extract-observed)
      [[ $# -lt 2 ]] && die "extract-observed requires: <tool-name> (tool_response JSON on stdin)"
      cmd_extract_observed "$2"
      ;;
    observed-rows)
      [[ $# -lt 2 ]] && die "observed-rows requires: <toolstream-file>"
      cmd_observed_rows "$2"
      ;;
    *)
      die "usage: toolstream.sh {append|read|redact|redact-browser|extract-observed|observed-rows} …"
      ;;
  esac
}

main "$@"
