#!/usr/bin/env bash
# capture-hook.sh — PostToolUse hook (Plan H2 Task 1, Layer 1: record).
#
# Reads the hook's stdin JSON ({tool_name, tool_input, tool_response, cwd,
# session_id}), resolves the active run via .qa/runs/latest (Plan B), and
# appends a {tool, args, resultDigest, responseBody} event to
# .qa/runs/<run>/toolstream.jsonl via toolstream.sh. Bash args are redacted
# against .qa/config.json's (or, absent that, the plugin's shipped
# .qa/config.json.example's) `enforcement.secretPatterns` +
# `enforcement.redactedKeys` before writing; browser_* args are recorded in
# full (test data — see the plan's documented typed-secret residual: a
# browser_type into a password field can still capture a typed secret; not
# silently claimed safe).
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
  # than crashing the hook). ---
  local response_body_json=""
  if has_jq; then
    response_body_json="$(printf '%s' "$tool_response" | head -c "$RESPONSE_BODY_CAP" | jq -Rs '.' 2>/dev/null)"
  elif has_py; then
    response_body_json="$(printf '%s' "$tool_response" | head -c "$RESPONSE_BODY_CAP" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
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
      '{tool: $tool, args: $args, resultDigest: {len: $len, sha256: $hash}, responseBody: $body}' \
      2>/dev/null)"
  elif has_py; then
    event_json="$(python3 -c '
import json, sys
tool = sys.argv[1]
args = json.loads(sys.argv[2])
length = int(sys.argv[3])
h = sys.argv[4]
body = json.loads(sys.argv[5])
print(json.dumps(
    {"tool": tool, "args": args, "resultDigest": {"len": length, "sha256": h}, "responseBody": body},
    separators=(",", ":"),
))
' "$tool_name" "$args_json" "$resp_len" "$resp_hash" "$response_body_json" 2>/dev/null)"
  fi
  [[ -z "$event_json" ]] && { warn "failed to build event JSON, no-op"; return 0; }

  bash "$TOOLSTREAM" append "$run_id" "$event_json" 2>/dev/null \
    || warn "toolstream append failed for run '${run_id}'"

  return 0
}

main
exit 0
