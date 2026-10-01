#!/usr/bin/env bash
# block-hook.sh — PreToolUse hook (Plan H2 Task 2, Layer 2: deny).
#
# Denies the PHASE-INDEPENDENT ABSOLUTES before they run:
#   - a MUTATING browser_evaluate (never sanctioned on any phase: arrange
#     seeds via a gated API write / browser_type; observe is read-only)
#   - browser_run_code_unsafe (RCE-equivalent; any payload)
#   - a browser_navigate while the run's PREVIOUS navigation has not yet been
#     followed by browser_network_requests (0.9.0 load-window gate — the
#     deny is lifted by making that call; see load_window_gate)
#   - EXCEPT the sanctioned recorded write probe (0.9.0, ADR-0027): a
#     mutating browser_evaluate that is exactly backend-probe.js + one
#     probe(<JSON>) call, admitted only when allowApiWrites + a disposable-env
#     marker + environment != production (see write-probe-gate.js)
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
# OBSERVE ROUND IS ALLOWED: the engine's own read-only observe payload
# (skills/driving-browser-qa/scripts/observe.js, passed verbatim as the
# evaluate body) is NOT denied — mutates() excises the shipped file's exact
# source (content-addressed, whitespace-insensitive; read from disk, never a
# name/marker match) before classifying, so observe's pass-through
# instrumentation (`window.fetch = ...` wrapper, `window.__qa*` state) is not
# a write, while a tampered copy, or observe plus appended mutating code, is
# still denied. Comparisons (`===`/`==`) are no longer mistaken for
# assignments. See parse-session-log.js for the full rationale (0.8.1).
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
WRITE_PROBE_GATE_JS="${ROOT}/skills/probing-apis-through-browser/scripts/write-probe-gate.js"

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

# load_window_gate — deny a browser_navigate when the run's PREVIOUS
# browser_navigate (per the capture hook's toolstream) has not yet been
# followed by a browser_network_requests. No active run / no toolstream / no
# prior navigation / gate disabled / any read error -> allow.
load_window_gate() {
  local qa_base=".qa/runs" run_id tsf gate=""
  [[ -f "${qa_base}/latest" ]] || return 0
  run_id="$(tr -d '[:space:]' < "${qa_base}/latest" 2>/dev/null || true)"
  [[ -z "$run_id" ]] && return 0
  case "$run_id" in */*|*\\*|*..*|-*) return 0 ;; esac
  tsf="${qa_base}/${run_id}/toolstream.jsonl"
  [[ -s "$tsf" ]] || return 0
  # Only a LIVE run is gated: .qa/runs/latest outlives the run, so a
  # toolstream untouched for QA_LOAD_WINDOW_STALE_MIN minutes (default 120)
  # belongs to a finished run and must not gate unrelated browsing.
  local stale_min="${QA_LOAD_WINDOW_STALE_MIN:-120}"
  [[ "$stale_min" =~ ^[0-9]+$ ]] || stale_min=120
  [[ -n "$(find "$tsf" -mmin "-${stale_min}" 2>/dev/null)" ]] || return 0

  if [[ -f ".qa/config.json" ]]; then
    if has_jq; then
      gate="$(jq -r 'if .enforcement.loadWindowGate == false then "off" else "" end' .qa/config.json 2>/dev/null)"
    elif has_py; then
      gate="$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print("off" if (d.get("enforcement") or {}).get("loadWindowGate") is False else "")
except Exception:
    print("")' .qa/config.json 2>/dev/null)"
    fi
  fi
  [[ "$gate" == "off" ]] && return 0

  # The ordered tool names; walk back from the end to the last navigate.
  local tools state="none" t
  if has_jq; then
    tools="$(jq -R -r 'try (fromjson | .tool // empty | strings) catch empty' "$tsf" 2>/dev/null)" || return 0
  elif has_py; then
    tools="$(python3 -c 'import json,sys
for line in open(sys.argv[1]):
    try:
        t = json.loads(line).get("tool")
    except Exception:
        continue
    if isinstance(t, str):
        print(t)' "$tsf" 2>/dev/null)" || return 0
  else
    return 0
  fi
  while IFS= read -r t; do
    case "$t" in
      *browser_network_requests) state="covered" ;;
      *browser_navigate) state="open" ;;
    esac
  done <<< "$tools"
  if [[ "$state" == "open" ]]; then
    deny "load-window gate: the previous browser_navigate in this run has not been followed by browser_network_requests. Call browser_network_requests now (it reads the load window of the page you are on, where a navigation-time 5xx lives), then retry this navigation. qa-verify fails the run on every uncovered navigation; set enforcement.loadWindowGate:false to turn this live deny off."
  fi
  return 0
}

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

  # browser_navigate -- the LOAD-WINDOW gate (0.9.0, ADR-0027). qa-verify
  # fails a run (__run-checks__) whenever a browser_navigate is not followed
  # by a browser_network_requests before the next navigation, because a
  # navigation-time 5xx is the DOCUMENT request and only the driver's request
  # list can see it. Two real runs lost 7 and 4 auxiliary navigations (login,
  # locale switch, logout recovery) to that check, discovered only at verify
  # time, when the gap can no longer be closed. Deny the NEXT navigation
  # instead, while calling browser_network_requests still fixes it.
  # browser_navigate_back is exempt (it is exempt from the check too).
  # Fail-open like every other path here; `enforcement.loadWindowGate:false`
  # turns the deny off (the capture hook's reminder and qa-verify's check
  # still apply).
  if [[ "$tool_name" == *browser_navigate ]]; then
    load_window_gate
    return 0
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
    # The ONE mutating evaluate that can be admitted: the sanctioned recorded
    # write probe (backend-probe.js verbatim + one strict-JSON probe() call),
    # and only on a disposable env that allows API writes (ADR-0027).
    if [[ -f "$WRITE_PROBE_GATE_JS" ]]; then
      local gate_out gate_rc reason
      gate_out="$(printf '%s' "$payload" | node "$WRITE_PROBE_GATE_JS" check ".qa/config.json" 2>/dev/null)"
      gate_rc=$?
      if [[ $gate_rc -eq 0 ]]; then
        warn "sanctioned write probe admitted (allowApiWrites + disposable env); it is recorded by the capture hook — bind the criterion's probe evidence to it with --source-ref seq:<N>"
        return 0
      elif [[ $gate_rc -eq 3 ]]; then
        reason="$(printf '%s' "$gate_out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).reason||""))}catch(e){}})' 2>/dev/null | tr -d '"\\')"
        deny "sanctioned write probe refused on this environment: ${reason}. API writes need allowApiWrites:true, a disposable seedableEnvMarker and environment != production; otherwise record the criterion blocked"
      fi
    fi
    deny "mutating browser_evaluate is never sanctioned (arrange via a gated API/type, observe read-only). For an API-only criterion on a disposable env, use the sanctioned write probe: backend-probe.js verbatim plus one return await probe({JSON}) call (see probing-apis-through-browser)"
  elif [[ $rc -ne 0 ]]; then
    warn "mutates() classifier errored (rc=${rc}), fail-open (allow)"
    return 0
  fi

  return 0
}

main
exit 0
