#!/usr/bin/env bash
# block-hook.sh — PreToolUse hook (Plan H2 Task 2, Layer 2: deny).
#
# Denies the PHASE-INDEPENDENT ABSOLUTES before they run:
#   - a MUTATING browser_evaluate (never sanctioned on any phase: arrange
#     seeds via a gated API write / browser_type; observe is read-only)
#   - browser_run_code_unsafe (RCE-equivalent; any payload)
#
# Everything else — browser_navigate (legit arrange-entry), a read-only
# evaluate, human-path act tools, Bash, ... — is NEVER live-blocked here.
# Record-only capture is the capture-hook's job (Task 1); all NUANCED /
# phase-dependent checks (provenance, fingerprint-target, persona-identity,
# required-kinds, act-phase browser_navigate URL-skip) are qa-verify's job
# (Task 4), which has the recorded phase tags this hook does not.
#
# CLASSIFIER REUSE: the mutating-evaluate check reuses
# skills/driving-browser-qa/scripts/parse-session-log.js's `mutates()` — the
# SAME semantic mutation classifier WS-1 #3 hardened and check-action-trace.js
# already depends on for the identical judgment. It is NOT re-implemented
# here. This hook is a JS-capable path (like check-action-trace.js), so
# shelling out to a tiny `node -e` invocation that `require()`s it is the
# sanctioned reuse pattern (see the plan's Global Constraints: "no NEW hard
# node dep" — parse-session-log.js is an EXISTING dependency-free node
# script; block-hook.sh only calls it, same as check-action-trace.js does).
#
# CONTRACT (Claude PreToolUse): stdin JSON carries {tool_name, tool_input,
# ...}. DENY = print `{hookSpecificOutput:{hookEventName:"PreToolUse",
# permissionDecision:"deny",permissionDecisionReason:"..."}}` on stdout and
# exit 2. ALLOW = exit 0 (stdout is ignored on allow).
#
# FAIL-OPEN, ALWAYS: this is a live, best-effort gate — the authoritative
# check is qa-verify, run out-of-agent. malformed/empty stdin, a missing
# tool_name, a missing/uninspectable evaluate payload, no node, no
# parse-session-log.js, or ANY internal error -> ALLOW (exit 0), never
# crash and never wrongly deny. A mutating evaluate that slips past this
# live hook is still caught by qa-verify + the existing act-trace gate.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 for the stdin JSON
# parse (jq preferred; python3 fallback; QA_ENGINE honored, same idiom as
# capture-hook.sh/toolstream.sh), and `node` ONLY for the mutates()
# classification step (its absence fails open, it does not error the hook).

set -u

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MUTATES_JS="${ROOT}/skills/driving-browser-qa/scripts/parse-session-log.js"

warn() { echo "block-hook: $*" >&2; }

# Emit the deny JSON on stdout and exit 2. Called from within main(); `exit`
# inside a sourced function terminates the whole script (not just main), so
# this reliably short-circuits everything after it.
deny() {
  local reason="$1"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 2
}

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }
has_node() { command -v node >/dev/null 2>&1; }

main() {
  local input
  input="$(cat 2>/dev/null || true)"
  [[ -z "$input" ]] && { warn "empty stdin, fail-open (allow)"; return 0; }

  if has_jq; then
    jq -e . >/dev/null 2>&1 <<< "$input" || { warn "stdin is not valid JSON, fail-open (allow)"; return 0; }
  elif has_py; then
    python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$input" >/dev/null 2>&1 \
      || { warn "stdin is not valid JSON, fail-open (allow)"; return 0; }
  else
    warn "neither jq nor python3 available, fail-open (allow)"; return 0
  fi

  local tool_name tool_input
  if has_jq; then
    tool_name="$(jq -r '.tool_name // empty' <<< "$input" 2>/dev/null)"
    tool_input="$(jq -c '.tool_input // {}' <<< "$input" 2>/dev/null)"
  elif has_py; then
    tool_name="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("tool_name") or "")' <<< "$input" 2>/dev/null)"
    tool_input="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d.get("tool_input") or {}, separators=(",", ":")))' <<< "$input" 2>/dev/null)"
  fi
  [[ -z "${tool_name:-}" ]] && { warn "stdin has no tool_name, fail-open (allow)"; return 0; }
  [[ -z "${tool_input:-}" ]] && tool_input="{}"

  # browser_run_code_unsafe -- ALWAYS denied, ANY payload, no classification
  # needed (it is RCE-equivalent Playwright-server code, not app-page JS the
  # mutation classifier understands).
  if [[ "$tool_name" == *browser_run_code_unsafe ]]; then
    deny "browser_run_code_unsafe is never sanctioned on any phase (RCE-equivalent; arrange via a gated API/type, observe read-only)"
  fi

  # Only browser_evaluate is further inspected. Everything else --
  # browser_navigate, human-path act tools (click/type/...), Bash, browser_route,
  # anything unmatched -- is NEVER live-blocked here.
  if [[ "$tool_name" != *browser_evaluate ]]; then
    return 0
  fi

  # Extract the evaluate payload. CONFIRMED arg name (current @playwright/mcp
  # browser_evaluate schema): `function` — "() => { ... }" or
  # "(element) => { ... }", REQUIRED. `code`/`expression` are also checked in
  # case of a differently-shaped harness/tool-version payload (defensive, per
  # the task brief). A `filename`-only call (no inline payload) has nothing
  # to classify here -- that is a genuine gap in this live, best-effort
  # check; fail OPEN (allow). qa-verify's record-only re-check (against the
  # captured toolstream) is the authoritative backstop for anything that
  # slips past this hook.
  local payload=""
  if has_jq; then
    payload="$(jq -r '(.function // .code // .expression // empty)' <<< "$tool_input" 2>/dev/null)"
  elif has_py; then
    payload="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d.get("function") or d.get("code") or d.get("expression") or "")
' <<< "$tool_input" 2>/dev/null)"
  fi
  [[ -z "$payload" ]] && { warn "browser_evaluate call has no inspectable payload (function/code/expression), fail-open (allow)"; return 0; }

  if ! has_node; then
    warn "node not available, cannot run the mutates() classifier, fail-open (allow)"
    return 0
  fi
  [[ -f "$MUTATES_JS" ]] || { warn "parse-session-log.js not found at ${MUTATES_JS}, fail-open (allow)"; return 0; }

  # Exit codes are DELIBERATELY 3-way, not a bare 0/1: node's default
  # behavior on an UNCAUGHT exception is also exit code 1 -- indistinguishable
  # from a genuine "mutates() said true" if we let that happen, which would
  # turn a classifier CRASH into a wrongful DENY (the exact anti-pattern the
  # fail-open contract forbids). The try/catch + exit-2-on-error makes a
  # crash unambiguous: 0 = allow, 1 = deny, 2 (or anything else) = fail open.
  local rc
  QA_BLOCK_HOOK_PAYLOAD="$payload" node -e '
    try {
      const { mutates } = require(process.argv[1]);
      process.exit(mutates(process.env.QA_BLOCK_HOOK_PAYLOAD) ? 1 : 0);
    } catch (e) {
      process.exit(2);
    }
  ' "$MUTATES_JS" 2>/dev/null
  rc=$?

  if [[ $rc -eq 1 ]]; then
    deny "mutating browser_evaluate is never sanctioned (arrange via a gated API/type, observe read-only)"
  elif [[ $rc -ne 0 ]]; then
    warn "mutates() classifier errored (rc=${rc}), fail-open (allow)"
    return 0
  fi

  return 0
}

main
exit 0
