#!/usr/bin/env bash
# classify-finding.sh — deterministic disposition of ONE observed browser
# error (plan 2026-09-23-error-honesty-invariants, Task 2). It replaces agent
# judgement about whether an observed error belongs to the application under
# test: the findings ledger and `qa-verify.sh` consume its two output strings,
# so they are a CONTRACT — never reword them.
#
# USAGE:
#   classify-finding.sh <config-path> <url> <status>
#       Prints exactly two lines, in this order:
#           originClass=<in-scope|third-party|benign>
#           statusClass=<fatal|non-fatal>
#       Exit 0 on any successful classification. Non-zero ONLY on unusable
#       arguments (wrong arg count, config file missing) — an error that
#       cannot be classified confidently is NOT an argument error, it is a
#       fail-closed `in-scope`.
#
# RULES:
#   statusClass=fatal IFF <status> is numeric and >= 500, or is the literal
#   `unhandled-exception`, or the literal `page-crash`. 3xx and 4xx are
#   recorded, never fatal (plan decision R1: observe.js's isOkStatus is
#   2xx-only, so failing on any in-scope non-2xx would fail the spec's own
#   authz criteria).
#
#   originClass: the URL's origin (scheme + host + port, default :443/https
#   and :80/http normalized away, scheme+host lowercased) equal to
#   `.baseUrl`'s origin => `in-scope`; a different origin => `third-party`.
#   A URL PATH matching any POSIX-ERE in `.findings.benign[]` => `benign`,
#   checked AFTER origin so a benign rule can downgrade an in-scope path
#   (and a third-party one).
#
#   FAIL-CLOSED. An unparseable URL, a relative URL, an absent/unusable
#   `baseUrl`, an unparseable config, or an absent `findings` block all
#   yield `in-scope` — never `third-party`, never `benign`. With no findings
#   policy in the config NOTHING is excused: Lane A does not depend on the
#   `findings` key another lane adds, and its absence must never be the
#   reason an application error went unattributed.
#
# DEPENDENCIES: bash 3.2-safe (no associative arrays, no mapfile, no ${x^^}),
# EITHER jq OR python3 (jq preferred, `QA_ENGINE` overrides the auto-detect,
# same idiom as toolstream.sh / check-fixtures.sh). Regex matching is done by
# `grep -E` in this script — NOT by the JSON engine — so the two engines
# cannot diverge on regex semantics, and `.findings.benign[]` is POSIX-ERE
# exactly like the redaction layer's patterns (toolstream.sh:116-131).
# `grep -P` is never used. Neither engine present => still classifies, fail
# closed, with a warning on stderr.
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 2; }

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

[ "$#" -eq 3 ] || die "usage: classify-finding.sh <config-path> <url> <status>"
CONFIG="$1"; URL="$2"; STATUS="$3"
[ -f "$CONFIG" ] || die "classify-finding: config not found: $CONFIG"

TMP="$(mktemp "${TMPDIR:-/tmp}/classify-finding.XXXXXX")" || die "classify-finding: cannot create temp file"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# read_config — emit a NUL-delimited record to stdout:
#   <baseUrl> NUL <present|absent> NUL <benign-regex> NUL ...
# NUL-delimited because a regex may contain anything but NUL. A config that
# is missing, malformed, not an object, or has no usable `findings.benign`
# array yields an empty baseUrl and the `absent` policy — i.e. fail closed.
# ---------------------------------------------------------------------------
read_config() {
  if has_jq; then
    jq -j '
      def base: if (.baseUrl|type)=="string" then .baseUrl else "" end;
      def policy: if ((.findings|type)=="object" and ((.findings.benign|type)=="array"))
                  then "present" else "absent" end;
      base, "\u0000", policy, "\u0000",
      ( if policy=="present"
        then (.findings.benign[] | if type=="string" then (., "\u0000") else empty end)
        else empty end )
    ' "$CONFIG" 2>/dev/null
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = None
if not isinstance(d, dict):
    d = {}
b = d.get("baseUrl")
b = b if isinstance(b, str) else ""
f = d.get("findings")
arr = f.get("benign") if isinstance(f, dict) else None
present = isinstance(arr, list)
out = [b, "present" if present else "absent"]
if present:
    out += [x for x in arr if isinstance(x, str)]
sys.stdout.write("".join(s + "\0" for s in out))
' "$CONFIG" 2>/dev/null
  else
    echo "WARN: classify-finding: neither jq nor python3 available - failing closed to in-scope" >&2
    return 1
  fi
}

read_config > "$TMP" || true

BASE_URL=""; POLICY="absent"
exec 3< "$TMP"
IFS= read -r -d '' BASE_URL <&3 || BASE_URL=""
IFS= read -r -d '' POLICY   <&3 || POLICY="absent"
[ -n "$POLICY" ] || POLICY="absent"

# ---------------------------------------------------------------------------
# parse_url <url> — sets P_SCHEME/P_HOST/P_PORT/P_PATH from an ABSOLUTE URL,
# with the origin already normalized (scheme+host lowercased, a default port
# for the scheme dropped). Returns 1 for anything not confidently parseable
# — a relative URL, an empty authority, whitespace, a non-numeric port — and
# every such return is a fail-closed `in-scope` at the call site.
# ---------------------------------------------------------------------------
P_SCHEME=""; P_HOST=""; P_PORT=""; P_PATH=""
parse_url() {
  local u="$1" scheme rest authority hostport host port remainder path
  [ -n "$u" ] || return 1
  case "$u" in
    *[[:space:]]*) return 1 ;;
  esac
  case "$u" in
    *://*) ;;
    *) return 1 ;;
  esac
  scheme="${u%%://*}"
  rest="${u#*://}"
  printf '%s' "$scheme" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*$' || return 1

  authority="$rest"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%#*}"
  [ -n "$authority" ] || return 1
  remainder="${rest#"$authority"}"

  hostport="${authority##*@}"          # drop any userinfo
  case "$hostport" in
    \[*\]*)                            # IPv6 literal: [::1] or [::1]:8080
      host="${hostport%%\]*}]"
      port="${hostport#*\]}"
      port="${port#:}"
      ;;
    *:*)
      host="${hostport%%:*}"
      port="${hostport#*:}"
      ;;
    *)
      host="$hostport"; port=""
      ;;
  esac
  [ -n "$host" ] || return 1
  if [ -n "$port" ]; then
    printf '%s' "$port" | grep -Eq '^[0-9]+$' || return 1
  fi

  scheme="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  if [ "$scheme" = "https" ] && [ "$port" = "443" ]; then port=""; fi
  if [ "$scheme" = "http" ]  && [ "$port" = "80"  ]; then port=""; fi

  path="${remainder%%\?*}"
  path="${path%%#*}"
  [ -n "$path" ] || path="/"

  P_SCHEME="$scheme"; P_HOST="$host"; P_PORT="$port"; P_PATH="$path"
  return 0
}

origin_string() {
  if [ -n "$P_PORT" ]; then printf '%s://%s:%s' "$P_SCHEME" "$P_HOST" "$P_PORT"
  else printf '%s://%s' "$P_SCHEME" "$P_HOST"; fi
}

# --- statusClass -----------------------------------------------------------
STATUS_CLASS="non-fatal"
case "$STATUS" in
  unhandled-exception|page-crash) STATUS_CLASS="fatal" ;;
  *)
    if printf '%s' "$STATUS" | grep -Eq '^[0-9]+$'; then
      if [ "$STATUS" -ge 500 ] 2>/dev/null; then STATUS_CLASS="fatal"; fi
    fi
    ;;
esac

# --- originClass -----------------------------------------------------------
ORIGIN_CLASS="in-scope"                # fail-closed default; only a fully
                                       # resolved comparison may change it
if [ "$POLICY" = "present" ] && parse_url "$URL"; then
  URL_ORIGIN="$(origin_string)"
  URL_PATH="$P_PATH"
  if parse_url "$BASE_URL"; then
    if [ "$URL_ORIGIN" = "$(origin_string)" ]; then
      ORIGIN_CLASS="in-scope"
    else
      ORIGIN_CLASS="third-party"
    fi
    # benign is checked AFTER origin so it can downgrade either class.
    while IFS= read -r -d '' BENIGN_RE <&3; do
      [ -n "$BENIGN_RE" ] || continue   # an empty rule would match everything
      printf '%s\n' "$URL_PATH" | grep -Eq -e "$BENIGN_RE" 2>/dev/null
      GREP_RC=$?
      if [ "$GREP_RC" -eq 0 ]; then
        ORIGIN_CLASS="benign"
        break
      elif [ "$GREP_RC" -gt 1 ]; then
        echo "WARN: classify-finding: skipping invalid findings.benign POSIX-ERE" >&2
      fi
    done
  fi
fi
exec 3<&-

printf 'originClass=%s\n' "$ORIGIN_CLASS"
printf 'statusClass=%s\n' "$STATUS_CLASS"
exit 0
