#!/usr/bin/env bash
# capture-hook.sh — PostToolUse hook (Plan H2 Task 1, Layer 1: record).
#
# Reads the hook's stdin JSON ({tool_name, tool_input, tool_response, cwd,
# session_id}), resolves the active run via .qa/runs/latest (Plan B), and
# appends a {tool, args, resultDigest, responseBody} event to
# .qa/runs/<run>/toolstream.jsonl via toolstream.sh.
#
# REDACTION (Findings 1+2 of the security review):
#   (a) FAIL-SAFE DEFAULTS: redaction is driven by toolstream.sh's `redact`
#       command, which NEVER silently no-ops just because a project's
#       .qa/config.json has no `enforcement` block. When the effective
#       config has no `enforcement.secretPatterns` KEY AT ALL (absent — the
#       default for a bootstrapped-but-not-yet-hand-edited config), a
#       hard-coded built-in default pattern set applies (password, passwd,
#       secret, token, api[_-]?key, apikey, authorization, bearer,
#       access[_-]?key, private[_-]?key, client[_-]?secret). An operator who
#       explicitly sets `"secretPatterns": []` has opted OUT of pattern
#       redaction and that choice is honored (redactedKeys literal-substring
#       redaction still applies). See toolstream.sh's `redact` usage comment
#       for the full contract.
#   (b) Bash args AND Bash tool_response are BOTH redacted before being
#       written — a command's OUTPUT (`env`, `cat .env`, `echo $API_KEY`,
#       `curl -v` echoing an Authorization header) can leak a secret just as
#       easily as its arguments can, so `responseBody` is redacted for Bash
#       calls using the exact same toolstream.sh redact pass as tool_input.
#   (c) browser_* args (and non-Bash tool_response) are recorded in FULL
#       (test data) — DOCUMENTED RESIDUAL: a `browser_type` into a password
#       field can still capture a typed secret; this is not silently claimed
#       safe.
#
# CONTRACT: this is a PostToolUse RECORD hook, never a gate. It must NEVER
# fail (or block) the tool call it observes:
#   - malformed/empty stdin              -> log to stderr, exit 0, no write
#   - no active run (.qa/runs/latest
#     absent/empty, or its run-id
#     invalid)                           -> no-op, exit 0, no write
#   - enforcement.captureHook == false   -> no-op, exit 0, no write
#   - ANY internal error                 -> log to stderr, exit 0
# Every code path below falls through to the trailing `exit 0` — it is
# unconditional, not merely the happy-path tail.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred; python3
# fallback — QA_ENGINE honored, same as toolstream.sh). No node.
#
# NOTE: paths are relative to the current working directory (the Run's
# project root), same convention as the rest of this plugin's scripts.

set -u

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOLSTREAM="${ROOT}/scripts/toolstream.sh"
QA_BASE=".qa/runs"
# Bytes kept of tool_response before it's re-encoded as the toolstream
# event's `responseBody`. Overridable for tests; ~4KB by default per the
# plan ("a BOUNDED truncation ... cap ~4KB").
RESPONSE_BODY_CAP="${QA_CAPTURE_RESPONSE_CAP:-4000}"

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

warn() { echo "capture-hook: $*" >&2; }

# ---------------------------------------------------------------------------
# Clock/time-travel advisory scan (Plan H3 Task 2, #7).
#
# A QA run must never mock/freeze/fast-forward the clock to force a
# time-dependent assertion (see interaction-discipline.md's doctrine ban).
# Generic time-travel detection is infeasible, so this is a DETERMINISTIC,
# BEST-EFFORT pattern scan over a captured call's args -- ADVISORY ONLY. It
# NEVER changes the hook's exit code and NEVER blocks the tool call; a match
# only adds `advisory:"clock-control"` to the emitted toolstream event
# (absent, never null/false, when nothing matches). Classification reads the
# UNREDACTED tool_input (read-only, never written) -- the WRITTEN args still
# go through the normal Bash-only redaction path unaffected (a time-control
# payload isn't itself a secret, but this scan must not interfere with the
# secret-redaction contract).
#
# Matching uses `grep -Eqi` (POSIX ERE, case-insensitive) -- deliberately
# NOT `grep -P`/perl (unavailable on some hosts, same portability
# constraint as toolstream.sh's redact). This is engine-independent: it
# runs identically whether jq or python3 is the active JSON engine (those
# only affect how the .function/.code/.url/.command field is extracted).
#
# Signals:
#   browser_evaluate payload (.function and/or .code, joined) containing:
#     setTestNow, sinon.useFakeTimers, fakeTimers, Date.now\s*=,
#     __defineGetter__.*Date, jest.useFakeTimers, mockdate, timekeeper
#   browser_navigate .url OR a Bash .command hitting a known clock route:
#     /__clock, /test/clock, /_time, ?now=, &now=, x-mock-time
# ---------------------------------------------------------------------------
CLOCK_EVAL_PATTERN='setTestNow|sinon\.useFakeTimers|fakeTimers|Date\.now[[:space:]]*=|__defineGetter__.*Date|jest\.useFakeTimers|mockdate|timekeeper'
CLOCK_ROUTE_PATTERN='/__clock|/test/clock|/_time|\?now=|&now=|x-mock-time'

extract_json_field() {
  # extract_json_field <json> <field> -> stdout: string value of <field>,
  # or empty. Best-effort; never dies (2>/dev/null on both engines).
  local json="$1" field="$2"
  if has_jq; then
    jq -r --arg f "$field" '(.[$f] // "") | if type == "string" then . else "" end' <<< "$json" 2>/dev/null
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    v = d.get(sys.argv[1])
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
' "$field" <<< "$json" 2>/dev/null
  fi
}

extract_evaluate_text() {
  # extract_evaluate_text <json> -> stdout: .function + "\n" + .code
  # (either/both may be absent), for the clock-eval pattern scan.
  local json="$1"
  if has_jq; then
    jq -r '[(.function // ""), (.code // "")] | map(if type == "string" then . else "" end) | join("\n")' <<< "$json" 2>/dev/null
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
f = d.get("function")
c = d.get("code")
print((f if isinstance(f, str) else "") + "\n" + (c if isinstance(c, str) else ""))
' <<< "$json" 2>/dev/null
  fi
}

detect_clock_advisory() {
  # detect_clock_advisory <tool_name> <tool_input_json> -> stdout
  # "clock-control" (and success) on a match, prints nothing (and fails) on
  # no match. Never dies -- callers treat any failure as "no advisory".
  local tool_name="$1" tool_input="$2" text=""
  case "$tool_name" in
    *browser_evaluate)
      text="$(extract_evaluate_text "$tool_input")"
      printf '%s' "$text" | grep -Eqi "$CLOCK_EVAL_PATTERN" && { echo "clock-control"; return 0; }
      ;;
    *browser_navigate)
      text="$(extract_json_field "$tool_input" "url")"
      printf '%s' "$text" | grep -Eqi "$CLOCK_ROUTE_PATTERN" && { echo "clock-control"; return 0; }
      ;;
    Bash)
      text="$(extract_json_field "$tool_input" "command")"
      printf '%s' "$text" | grep -Eqi "$CLOCK_ROUTE_PATTERN" && { echo "clock-control"; return 0; }
      ;;
  esac
  return 1
}

main() {
  local input
  input="$(cat 2>/dev/null || true)"
  [[ -z "$input" ]] && { warn "empty stdin, no-op"; return 0; }

  if has_jq; then
    jq -e . >/dev/null 2>&1 <<< "$input" || { warn "stdin is not valid JSON, no-op"; return 0; }
  elif has_py; then
    python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$input" >/dev/null 2>&1 \
      || { warn "stdin is not valid JSON, no-op"; return 0; }
  else
    warn "neither jq nor python3 available, no-op"; return 0
  fi

  # --- resolve the active run (Plan B's .qa/runs/latest); absent/empty/
  # invalid -> no-op. This is the hook's core "never write without a run"
  # invariant. ---
  [[ -f "${QA_BASE}/latest" ]] || { warn "no active run (.qa/runs/latest absent), no-op"; return 0; }
  local run_id
  run_id="$(tr -d '[:space:]' < "${QA_BASE}/latest" 2>/dev/null || true)"
  [[ -z "$run_id" ]] && { warn "no active run (.qa/runs/latest empty), no-op"; return 0; }
  case "$run_id" in
    */*|*\\*|*..*|-*)
      warn "invalid run-id in .qa/runs/latest ('${run_id}'), no-op"; return 0 ;;
  esac
  if [[ "$run_id" =~ ^\.+$ ]]; then
    warn "invalid run-id in .qa/runs/latest ('${run_id}'), no-op"; return 0
  fi

  # --- load config (active .qa/config.json if bootstrapped, else the
  # plugin's shipped example's defaults); a missing/invalid config degrades
  # to "{}" (redact then no-ops rather than erroring). ---
  local config_json="{}"
  local cfg_file=".qa/config.json"
  [[ -f "$cfg_file" ]] || cfg_file="${ROOT}/.qa/config.json.example"
  if [[ -f "$cfg_file" ]]; then
    local raw_cfg
    raw_cfg="$(cat "$cfg_file" 2>/dev/null || echo '{}')"
    if has_jq; then
      jq -e . >/dev/null 2>&1 <<< "$raw_cfg" && config_json="$raw_cfg"
    elif has_py; then
      python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$raw_cfg" >/dev/null 2>&1 \
        && config_json="$raw_cfg"
    fi
  fi

  # --- captureHook gate (default true when unset/absent) ---
  local capture_enabled="true"
  if has_jq; then
    # NOTE: deliberately NOT `.enforcement.captureHook // true` -- jq's `//`
    # alternative operator treats `false` itself as falsy, so that idiom
    # would silently turn an explicit `false` back into `true`. Distinguish
    # "absent/null" (default true) from "explicitly false" instead.
    capture_enabled="$(jq -r '
      (.enforcement.captureHook) as $v
      | if $v == null then "true" elif $v == false then "false" else "true" end
    ' <<< "$config_json" 2>/dev/null)"
  elif has_py; then
    capture_enabled="$(python3 -c '
import json, sys
try:
    cfg = json.loads(sys.stdin.read())
except Exception:
    cfg = {}
v = (cfg.get("enforcement") or {}).get("captureHook", True)
print("true" if v else "false")
' <<< "$config_json" 2>/dev/null)"
  fi
  [[ -z "$capture_enabled" ]] && capture_enabled="true"
  [[ "$capture_enabled" == "false" ]] && { warn "enforcement.captureHook is false, no-op"; return 0; }

  # --- extract tool_name / tool_input / tool_response ---
  local tool_name tool_input tool_response
  if has_jq; then
    tool_name="$(jq -r '.tool_name // empty' <<< "$input" 2>/dev/null)"
    tool_input="$(jq -c '.tool_input // {}' <<< "$input" 2>/dev/null)"
    tool_response="$(jq -c '.tool_response // null' <<< "$input" 2>/dev/null)"
  elif has_py; then
    tool_name="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("tool_name") or "")' <<< "$input" 2>/dev/null)"
    tool_input="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d.get("tool_input") or {}, separators=(",", ":")))' <<< "$input" 2>/dev/null)"
    tool_response="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d.get("tool_response"), separators=(",", ":")))' <<< "$input" 2>/dev/null)"
  fi
  [[ -z "${tool_name:-}" ]] && { warn "stdin has no tool_name, no-op"; return 0; }
  [[ -z "${tool_input:-}" ]] && tool_input="{}"
  [[ -z "${tool_response:-}" ]] && tool_response="null"

  # --- clock/time-travel advisory scan (Plan H3 Task 2, #7): classifies the
  # UNREDACTED tool_input, before any redaction below touches the WRITTEN
  # args. Best-effort/advisory only -- a scan failure is silently "no
  # advisory", never an error path. ---
  local advisory=""
  advisory="$(detect_clock_advisory "$tool_name" "$tool_input" 2>/dev/null)" || advisory=""

  # --- redact Bash args only; browser_* (and anything else) recorded in
  # full. A redact failure falls back to the UNREDACTED args rather than
  # dropping the event -- but only for non-Bash tools would that be benign;
  # for Bash specifically, a failed redact must not silently leak secrets,
  # so treat it as: keep going with the (still fully redaction-attempted)
  # output when non-empty, else skip capturing this event's args by
  # replacing them with a marker instead of risking an unredacted leak. ---
  local args_json="$tool_input"
  if [[ "$tool_name" == "Bash" ]]; then
    local redacted
    redacted="$(bash "$TOOLSTREAM" redact "$tool_input" "$config_json" 2>/dev/null)"
    if [[ -n "$redacted" ]]; then
      args_json="$redacted"
    else
      warn "redact failed for a Bash call, recording a placeholder instead of risking an unredacted leak"
      args_json='{"_captureHookNote":"redact failed; args withheld to avoid a potential unredacted secret"}'
    fi
  fi

  # --- resultDigest: length + a hash marker of tool_response. Never embeds
  # the raw response itself (that's responseBody's job, separately capped). ---
  local resp_len resp_hash
  resp_len="$(printf '%s' "$tool_response" | wc -c | tr -d ' ')"
  if command -v sha256sum >/dev/null 2>&1; then
    resp_hash="$(printf '%s' "$tool_response" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    resp_hash="$(printf '%s' "$tool_response" | shasum -a 256 | awk '{print $1}')"
  elif has_py; then
    resp_hash="$(printf '%s' "$tool_response" | python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  else
    resp_hash=""
  fi
  [[ -z "$resp_hash" ]] && resp_hash="unavailable"

  # --- responseBody: a BOUNDED (~4KB) truncation of tool_response,
  # re-encoded as a JSON string so truncation can never corrupt the
  # toolstream line's JSON (known limitation: a byte-bounded cut can split a
  # multi-byte UTF-8 sequence at the boundary -- if that makes the truncated
  # bytes invalid UTF-8, JSON-encoding degrades to an empty string rather
  # than crashing the hook).
  #
  # Finding 2 fix: for tool_name == Bash, this truncated text is redacted via
  # the SAME toolstream.sh redact pass as the args, BEFORE being written --
  # a Bash command's stdout/stderr can echo a secret just as easily as its
  # arguments can (`env`, `cat .env`, `echo $API_KEY`, `curl -v` showing an
  # Authorization header). The truncated text is wrapped as {"body": <text>}
  # so toolstream.sh redact (which walks JSON string leaves) can run over it
  # like any other args object, then unwrapped again. Non-Bash tools are NOT
  # redacted here -- recorded in full per spec (see the header residual
  # note). A redact failure on a Bash response withholds the body rather
  # than risking an unredacted leak, mirroring the args-redact-failure
  # handling above. ---
  local truncated_response
  truncated_response="$(printf '%s' "$tool_response" | head -c "$RESPONSE_BODY_CAP")"

  if [[ "$tool_name" == "Bash" ]]; then
    local wrapped="" redacted_wrapped="" redacted_body=""
    if has_jq; then
      wrapped="$(printf '%s' "$truncated_response" | jq -Rs -c '{body: .}' 2>/dev/null)"
    elif has_py; then
      wrapped="$(printf '%s' "$truncated_response" | python3 -c 'import json,sys; print(json.dumps({"body": sys.stdin.read()}, separators=(",", ":")))' 2>/dev/null)"
    fi
    if [[ -n "$wrapped" ]]; then
      redacted_wrapped="$(bash "$TOOLSTREAM" redact "$wrapped" "$config_json" 2>/dev/null)"
    fi
    if [[ -n "$redacted_wrapped" ]]; then
      if has_jq; then
        redacted_body="$(jq -r '.body' <<< "$redacted_wrapped" 2>/dev/null)"
      elif has_py; then
        redacted_body="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["body"])' <<< "$redacted_wrapped" 2>/dev/null)"
      fi
    fi
    if [[ -n "$redacted_body" || -z "$truncated_response" ]]; then
      truncated_response="$redacted_body"
    else
      warn "redact failed for a Bash tool_response, withholding responseBody to avoid a potential unredacted leak"
      truncated_response="<redacted: responseBody withheld, redact failed>"
    fi
  fi

  local response_body_json=""
  if has_jq; then
    response_body_json="$(printf '%s' "$truncated_response" | jq -Rs '.' 2>/dev/null)"
  elif has_py; then
    response_body_json="$(printf '%s' "$truncated_response" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
  fi
  [[ -z "$response_body_json" ]] && response_body_json='""'

  # --- build + append the event ---
  local event_json=""
  if has_jq; then
    event_json="$(jq -c -n \
      --arg tool "$tool_name" \
      --argjson args "$args_json" \
      --argjson len "$resp_len" \
      --arg hash "$resp_hash" \
      --argjson body "$response_body_json" \
      --arg advisory "$advisory" \
      '{tool: $tool, args: $args, resultDigest: {len: $len, sha256: $hash}, responseBody: $body}
       + (if $advisory != "" then {advisory: $advisory} else {} end)' \
      2>/dev/null)"
  elif has_py; then
    event_json="$(python3 -c '
import json, sys
tool = sys.argv[1]
args = json.loads(sys.argv[2])
length = int(sys.argv[3])
h = sys.argv[4]
body = json.loads(sys.argv[5])
advisory = sys.argv[6] if len(sys.argv) > 6 else ""
d = {"tool": tool, "args": args, "resultDigest": {"len": length, "sha256": h}, "responseBody": body}
if advisory:
    d["advisory"] = advisory
print(json.dumps(d, separators=(",", ":")))
' "$tool_name" "$args_json" "$resp_len" "$resp_hash" "$response_body_json" "$advisory" 2>/dev/null)"
  fi
  [[ -z "$event_json" ]] && { warn "failed to build event JSON, no-op"; return 0; }

  bash "$TOOLSTREAM" append "$run_id" "$event_json" 2>/dev/null \
    || warn "toolstream append failed for run '${run_id}'"

  return 0
}

main
exit 0
