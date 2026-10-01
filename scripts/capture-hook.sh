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
#   (c) SECRETS TYPED INTO THE BROWSER are redacted (0.8.1 — this was a
#       documented residual until a real run stored a shared login password
#       6x in toolstream.jsonl). For browser_type and browser_fill_form,
#       toolstream.sh's `redact-browser` replaces the typed value of any
#       SECRET field (its element/name/selector/ref/type names a password,
#       passcode, secret, token, api key, credential, OTP, PIN, CVV, ... —
#       the built-in field set plus the effective secretPatterns) with
#       "<redacted>", and runs the normal redactedKeys + secretPatterns pass
#       over every other typed value. Which field, ref and flags were used
#       stay recorded (the audit trail). The same values are masked in the
#       recorded responseBody, which echoes the generated `.fill('<value>')`
#       code — masked on the FULL response, before the 4KB truncation, so a
#       cut can never leave a secret's prefix behind. A redact failure
#       withholds the args/body rather than recording them unredacted.
#   (d) every OTHER browser_* call's args (and non-Bash tool_response) are
#       recorded in FULL (test data): URLs, clicks, evaluate payloads (which
#       qa-verify re-classifies, so they must not be pattern-mangled). A
#       secret only reaches those if the agent puts one there itself (e.g. a
#       credential in a navigate URL) — `redactedKeys` is the knob for
#       declared credential values, and it is not applied to them.
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
# OBSERVED + LIVE SELF-CHECKS (0.9.0, ADR-0027): for browser_evaluate and
# browser_network_requests the event also carries `observed` — the findings
# unwrapped from the FULL MCP response by `toolstream.sh extract-observed`
# (see that file for the root cause it closes). After appending, the hook may
# print ONE PostToolUse `additionalContext` JSON on stdout (findings-channel
# canary, load-window reminder after a navigate, a one-time --save-session
# probe — see live_nudges below). That output is advisory: it never blocks
# the call, and the exit code stays 0.
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

# ---------------------------------------------------------------------------
# Live self-checks (0.9.0, ADR-0027). Each returns a one-paragraph message on
# stdout (or nothing). All are best-effort and read-only.
#
#   (a) findings-channel canary — an observe round (an evaluate naming
#       __qaObserve) or a browser_network_requests call whose response yielded
#       no `observed` findings, while no earlier event in this run's
#       toolstream carries one: the run's findings channel is not being
#       captured and qa-verify would report findingsChannel "none"
#       (UNVERIFIED). Silent once the channel has been proven once.
#   (b) load-window reminder — after every browser_navigate: the next browser
#       call must be browser_network_requests (block-hook.sh denies the next
#       navigate otherwise; qa-verify fails the run on the gap).
#   (c) save-session probe — at the run's 3rd captured browser call, when
#       humanInteraction.saveSession is not false and no session log under
#       humanInteraction.sessionLogDir (default .playwright-mcp) changed in
#       the last 10 minutes: the Playwright MCP is not running with
#       --save-session, so Check 0 will be unavailable for every human-action
#       pass. Said once, early, with how to enable it.
#   (d) unjournaled-finding reminder (0.11.0, ADR-0029) — an in-scope fatal
#       network row (5xx / unhandled-exception / page-crash, per
#       classify-finding.sh) or an `error`-level console row captured in a
#       call's `observed`, with NO matching `finding_observed` in the journal
#       N captured calls later (N = enforcement.findingNudgeAfter, default 3;
#       0 disables), and again at 2N and 3N: qa-verify's ledger check fails
#       the run on exactly that gap at the end, when it can no longer be
#       fixed. Names the observation and the journal.sh append to make.
# ---------------------------------------------------------------------------
cfg_get() { # cfg_get <config-json> <jq-path> -> string (python3 fallback)
  if has_jq; then
    # not `// empty`: jq's alternative operator would swallow an explicit false
    jq -r "($2) as \$v | if \$v == null then empty else (\$v | tostring) end" <<< "$1" 2>/dev/null
  elif has_py; then
    python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
cur = d
for k in sys.argv[1].split("."):
    if not k:
        continue
    cur = cur.get(k) if isinstance(cur, dict) else None
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
' "${2#.}" <<< "$1" 2>/dev/null
  fi
}

# finding_nudge <run-id> <config-json> <config-path> -> a reminder paragraph
# on stdout for the FIRST observed in-scope fatal finding that is N, 2N or 3N
# captured calls old and still has no finding_observed in the journal; else
# nothing. Read-only, best-effort, bounded: only toolstream lines carrying
# `observed` are parsed.
finding_nudge() {
  local run_id="$1" config_json="$2" cfg_path="$3"
  local tsf="${QA_BASE}/${run_id}/toolstream.jsonl" jf="${QA_BASE}/${run_id}/journal.ndjson"
  [[ -s "$tsf" ]] || return 0
  local n; n="$(cfg_get "$config_json" '.enforcement.findingNudgeAfter')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=3
  [[ "$n" -eq 0 ]] && return 0
  local last cur
  last="$(tail -n 1 "$tsf" 2>/dev/null)"
  if has_jq; then
    cur="$(jq -r '.seq // empty' <<< "$last" 2>/dev/null)"
  else
    cur="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("seq",""))' <<< "$last" 2>/dev/null)"
  fi
  [[ "$cur" =~ ^[0-9]+$ ]] || return 0

  # candidates: kind<TAB>seq<TAB>method<TAB>url<TAB>status<TAB>text — only
  # those whose age (cur - seq) is exactly N, 2N or 3N.
  local cands
  if has_jq; then
    cands="$(grep '"observed":' "$tsf" 2>/dev/null | jq -r --argjson cur "$cur" --argjson n "$n" '
      def sane: if type == "string" then gsub("[\t\n\r]"; " ") else "" end;
      select(type == "object" and (.seq | type) == "number")
      | .seq as $s | (($cur - $s)) as $d
      | select($d > 0 and ($d % $n) == 0 and $d <= (3 * $n))
      | (.observed.network // [])[]?, (.observed.console // [])[]? | select(type == "object")
      | if has("level") then select(.level == "error") | ["console", ($s|tostring), "", "", "", (.text | sane | .[0:200])]
        else select(((.status | type) == "number" and .status >= 500) or (.status == "unhandled-exception") or (.status == "page-crash"))
             | ["net", ($s|tostring), (.method | sane), (.url | sane), (.status | tostring), ""]
        end
      | @tsv' 2>/dev/null)"
  else
    cands="$(grep '"observed":' "$tsf" 2>/dev/null | python3 -c '
import json, sys
cur, n = int(sys.argv[1]), int(sys.argv[2])
def sane(v):
    return v.replace("\t", " ").replace("\n", " ").replace("\r", " ") if isinstance(v, str) else ""
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if not isinstance(e, dict) or not isinstance(e.get("seq"), int):
        continue
    d = cur - e["seq"]
    if not (d > 0 and d % n == 0 and d <= 3 * n):
        continue
    ob = e.get("observed") or {}
    for r in (ob.get("network") or []):
        if not isinstance(r, dict):
            continue
        st = r.get("status")
        if (isinstance(st, int) and not isinstance(st, bool) and st >= 500) or st in ("unhandled-exception", "page-crash"):
            print("\t".join(["net", str(e["seq"]), sane(r.get("method")), sane(r.get("url")), str(st), ""]))
    for r in (ob.get("console") or []):
        if isinstance(r, dict) and r.get("level") == "error":
            print("\t".join(["console", str(e["seq"]), "", "", "", sane(r.get("text"))[:200]]))
' "$cur" "$n" 2>/dev/null)"
  fi
  [[ -z "$cands" ]] && return 0

  local journaled=""
  if [[ -s "$jf" ]]; then
    if has_jq; then
      journaled="$(grep '"finding_observed"' "$jf" 2>/dev/null | jq -r '
        select(type == "object" and .event == "finding_observed")
        | if .source == "console" then "console\t" + ((.message // "") | gsub("[ \t\n\r]+"; " ") | .[0:60])
          else "net\t" + ((.url // "") | .[0:1024]) + "\t" + (.status | tostring) end' 2>/dev/null)"
    else
      journaled="$(grep '"finding_observed"' "$jf" 2>/dev/null | python3 -c '
import json, re, sys
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if not isinstance(e, dict) or e.get("event") != "finding_observed":
        continue
    if e.get("source") == "console":
        print("console\t" + re.sub(r"[ \t\n\r]+", " ", e.get("message") or "")[:60])
    else:
        st = e.get("status")
        print("net\t" + (e.get("url") or "")[:1024] + "\t" + (json.dumps(st) if not isinstance(st, str) else st))
' 2>/dev/null)"
    fi
  fi

  local kind seq method url status text key cls age
  while IFS=$'\t' read -r kind seq method url status text; do
    [[ -z "$kind" ]] && continue
    if [[ "$kind" == "net" ]]; then
      key="net"$'\t'"${url:0:1024}"$'\t'"${status}"
      printf '%s\n' "$journaled" | grep -qxF -- "$key" && continue
      cls="$(bash "${ROOT}/scripts/classify-finding.sh" "$cfg_path" "$url" "$status" 2>/dev/null | tr '\n' ' ')"
      [[ "$cls" == *"originClass=in-scope"* && "$cls" == *"statusClass=fatal"* ]] || continue
    else
      key="console"$'\t'"$(printf '%s' "$text" | tr -s ' \t' ' ' | cut -c1-60)"
      printf '%s\n' "$journaled" | grep -qxF -- "$key" && continue
    fi
    age=$(( cur - seq ))
    local crit
    crit="$(open_criterion "$jf")"
    [[ -z "$crit" ]] && crit="<criterion-id>"
    if [[ "$kind" == "net" ]]; then
      printf '%s' "Unjournaled finding: ${method} ${url} returned ${status} (captured at toolstream seq ${seq}, ${age} calls ago) and the journal has no finding_observed for it. qa-verify's ledger check fails the run at the end on exactly this gap, when it can no longer be fixed — journal it now: bash ${ROOT}/skills/checkpointing-qa-memory/scripts/journal.sh append ${run_id} '{\"event\":\"finding_observed\",\"criterionId\":\"${crit}\",\"source\":\"net\",\"channel\":\"toolstream\",\"method\":\"${method}\",\"url\":\"<the url, capped at 1024>\",\"status\":${status},\"originClass\":\"in-scope\",\"statusClass\":\"fatal\",\"message\":\"<one line>\",\"detailRef\":\"evidence/${crit}/findings/<name>.json\"}' (and log the bug)."
    else
      printf '%s' "Unjournaled finding: a console error (\"${text:0:120}\") was captured at toolstream seq ${seq} (${age} calls ago) and the journal has no finding_observed for it. qa-verify's ledger check fails the run at the end on exactly this gap — journal it now with journal.sh append ${run_id} '{\"event\":\"finding_observed\",\"criterionId\":\"${crit}\",\"source\":\"console\",\"channel\":\"toolstream\",\"method\":\"\",\"url\":\"\",\"status\":\"\",\"message\":\"<the console text>\",...}' (classify it with scripts/classify-finding.sh)."
    fi
    return 0
  done <<< "$cands"
  return 0
}

# open_criterion <journal> -> the criterionId of the most recent
# criterion_started that has no criterion_verdict after it, else "".
open_criterion() {
  local jf="$1"
  [[ -s "$jf" ]] || return 0
  if has_jq; then
    grep -E '"criterion_(started|verdict)"' "$jf" 2>/dev/null | jq -rs '
      reduce .[] as $e (""; if $e.event == "criterion_started" then ($e.criterionId // "")
        elif $e.event == "criterion_verdict" and ($e.criterionId // "") == . then "" else . end)' 2>/dev/null
  else
    grep -E '"criterion_(started|verdict)"' "$jf" 2>/dev/null | python3 -c '
import json, sys
cur = ""
for line in sys.stdin:
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("event") == "criterion_started":
        cur = e.get("criterionId") or ""
    elif e.get("event") == "criterion_verdict" and (e.get("criterionId") or "") == cur:
        cur = ""
print(cur)
' 2>/dev/null
  fi
}

live_nudges() {
  local run_id="$1" tool_name="$2" tool_input="$3" response="$4" observed="$5" config_json="$6" cfg_path="${7:-}"
  local tsf="${QA_BASE}/${run_id}/toolstream.jsonl" out=""

  # (a) findings-channel canary
  local is_observe=0
  case "$tool_name" in
    *browser_evaluate) [[ "$tool_input" == *__qaObserve* ]] && is_observe=1 ;;
    *browser_network_requests) is_observe=2 ;;
  esac
  if [[ "$is_observe" -ne 0 && -z "$observed" ]] && ! grep -q '"observed":' "$tsf" 2>/dev/null; then
    if [[ "$is_observe" -eq 1 ]]; then
      out="${out}qa-e2e-pilot findings-channel check FAILED on this observe round: its result carried no console[]/network[] arrays, so nothing was captured for qa-verify (it will report findingsChannel \"none\" and mark the run UNVERIFIED). Return the FULL __qaObserve({...}) object — not a projection such as .domDigest.liveText — and pass observe.js verbatim. "
    else
      out="${out}qa-e2e-pilot findings-channel check FAILED: this browser_network_requests result could not be parsed into request rows (expected lines like \"[GET] https://... => [200]\"), so the driver channel is not being captured. Report this; qa-verify will degrade the run. "
    fi
  fi

  # (b) load-window reminder
  case "$tool_name" in
    *browser_navigate)
      out="${out}Load-window rule: call browser_network_requests before any other navigation — the document request (where a navigation-time 5xx lives) is only visible there. The next browser_navigate is denied until you do, and an uncovered navigation fails __run-checks__. "
      ;;
  esac

  # (c) save-session probe, once, at the 3rd captured browser call
  case "$tool_name" in
    *browser_*)
      local save_session n_browser log_dir recent=""
      save_session="$(cfg_get "$config_json" '.humanInteraction.saveSession')"
      if [[ "$save_session" != "false" ]]; then
        n_browser="$(grep -c '"tool":"mcp__[^"]*browser_' "$tsf" 2>/dev/null || echo 0)"
        if [[ "$n_browser" == "3" ]]; then
          log_dir="$(cfg_get "$config_json" '.humanInteraction.sessionLogDir')"
          [[ -z "$log_dir" ]] && log_dir=".playwright-mcp"
          if [[ -n "${QA_SESSION_LOG:-}" && -s "${QA_SESSION_LOG}" ]]; then
            recent="yes"
          elif [[ -d "$log_dir" ]]; then
            recent="$(find "$log_dir" -name '*.md' -mmin -10 2>/dev/null | head -1)"
          fi
          if [[ -z "$recent" ]]; then
            out="${out}Independent action log unavailable: no Playwright MCP session log under ${log_dir}/ was written during this run, so the Playwright MCP is not running with --save-session and Check 0 (independent reconciliation of every human-action act) will be unavailable — human-action passes keep only the act lint + fingerprints. To enable it, restart the harness with PLAYWRIGHT_MCP_SAVE_SESSION=true PLAYWRIGHT_MCP_OUTPUT_DIR=${log_dir} in its environment (or add \"--save-session\", \"--output-dir\", \"${log_dir}\" to a Playwright MCP server you configure); to accept the degrade, set humanInteraction.saveSession:false in .qa/config.json. "
          fi
        fi
      fi
      ;;
  esac

  # (d) unjournaled-finding reminder
  local fn=""
  [[ -n "$cfg_path" ]] && fn="$(finding_nudge "$run_id" "$config_json" "$cfg_path" 2>/dev/null)"
  [[ -n "$fn" ]] && out="${out}${fn} "

  printf '%s' "${out% }"
}

# emit_context <text> — the Claude PostToolUse channel for telling the model
# something: {"hookSpecificOutput":{"hookEventName":"PostToolUse",
# "additionalContext":...}} on stdout, exit 0 (never blocks the call).
emit_context() {
  local text="$1"
  if has_jq; then
    jq -cn --arg t "$text" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $t}}' 2>/dev/null
  elif has_py; then
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": sys.argv[1]}}))' "$text" 2>/dev/null
  fi
}

# screenshot_capture <tool_input> <tool_response> <hook-cwd> — 0.10.0,
# ADR-0028. Prints {"file":<as requested/reported>[,"path":<resolved>,
# "sha256":..,"bytes":..]} for a browser_take_screenshot call, or nothing.
# The file is the call's `filename` argument, else the first markdown link
# in its result ("- [Screenshot of viewport](./page-1.png)"). The Playwright
# MCP resolves a relative name against its workspace root, which is normally
# the project root but need not be, so the candidates are: as given (when
# absolute), the hook's `cwd`, $CLAUDE_PROJECT_DIR, $PWD and
# $PLAYWRIGHT_MCP_OUTPUT_DIR — the first regular file wins.
screenshot_capture() {
  local tool_input="$1" tool_response="$2" hook_cwd="$3" file=""
  if has_jq; then
    file="$(jq -r '.filename // empty | tostring' <<< "$tool_input" 2>/dev/null)"
  elif has_py; then
    file="$(python3 -c 'import json,sys
d = json.loads(sys.stdin.read())
v = d.get("filename") if isinstance(d, dict) else None
print(v if isinstance(v, str) else "")' <<< "$tool_input" 2>/dev/null)"
  fi
  if [[ -z "$file" ]]; then
    local re='\]\(([^)"\\]+)\)'
    [[ "$tool_response" =~ $re ]] && file="${BASH_REMATCH[1]}"
  fi
  [[ -n "$file" ]] || return 1

  local path="" base cand
  if [[ "$file" == /* ]]; then
    [[ -f "$file" ]] && path="$file"
  else
    for base in "$hook_cwd" "${CLAUDE_PROJECT_DIR:-}" "$PWD" "${PLAYWRIGHT_MCP_OUTPUT_DIR:-}"; do
      [[ -n "$base" ]] || continue
      cand="${base%/}/${file#./}"
      if [[ -f "$cand" ]]; then path="$cand"; break; fi
    done
  fi

  local sha="" bytes=""
  if [[ -n "$path" ]]; then
    sha="$(bash "${ROOT}/skills/checkpointing-qa-memory/scripts/screenshot-evidence.sh" sha256 "$path" 2>/dev/null)" || sha=""
    bytes="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=""
  fi
  if has_jq; then
    jq -cn --arg file "$file" --arg path "$path" --arg sha "$sha" --arg bytes "$bytes" \
      '{file: $file}
       + (if $path != "" then {path: $path} else {} end)
       + (if $sha != "" then {sha256: $sha} else {} end)
       + (if $bytes != "" then {bytes: ($bytes | tonumber)} else {} end)'
  elif has_py; then
    python3 -c 'import json,sys
f, p, s, b = sys.argv[1:5]
d = {"file": f}
if p: d["path"] = p
if s: d["sha256"] = s
if b: d["bytes"] = int(b)
print(json.dumps(d, separators=(",", ":")))' "$file" "$path" "$sha" "$bytes"
  fi
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

  # --- redact Bash args; browser_type/browser_fill_form typed values (secret
  # fields + redactedKeys/secretPatterns, see header (c)); every other tool's
  # args are recorded in full. A redact failure never records the args
  # unredacted: for Bash and the browser typing tools alike, a failed/empty
  # redact output is replaced by a placeholder marker instead. ---
  local args_json="$tool_input"
  local browser_secrets="[]" browser_redact_failed="false"
  if [[ "$tool_name" == "Bash" ]]; then
    local redacted
    redacted="$(bash "$TOOLSTREAM" redact "$tool_input" "$config_json" 2>/dev/null)"
    if [[ -n "$redacted" ]]; then
      args_json="$redacted"
    else
      warn "redact failed for a Bash call, recording a placeholder instead of risking an unredacted leak"
      args_json='{"_captureHookNote":"redact failed; args withheld to avoid a potential unredacted secret"}'
    fi
  elif [[ "$tool_name" == *browser_type || "$tool_name" == *browser_fill_form ]]; then
    local rb="" rb_args="" rb_secrets=""
    rb="$(bash "$TOOLSTREAM" redact-browser "$tool_name" "$tool_input" "$config_json" 2>/dev/null)"
    if [[ -n "$rb" ]]; then
      if has_jq; then
        rb_args="$(jq -c '.args' <<< "$rb" 2>/dev/null)"
        rb_secrets="$(jq -c '.secrets // []' <<< "$rb" 2>/dev/null)"
      elif has_py; then
        rb_args="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["args"], separators=(",", ":")))' <<< "$rb" 2>/dev/null)"
        rb_secrets="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()).get("secrets") or [], separators=(",", ":")))' <<< "$rb" 2>/dev/null)"
      fi
    fi
    if [[ -n "$rb_args" && -n "$rb_secrets" ]]; then
      args_json="$rb_args"
      browser_secrets="$rb_secrets"
    else
      warn "redact-browser failed for ${tool_name}, recording a placeholder instead of risking a typed secret"
      args_json='{"_captureHookNote":"redact failed; args withheld to avoid a potential unredacted secret"}'
      browser_redact_failed="true"
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
  # pattern-redacted here -- browser_type/browser_fill_form responses were
  # already masked of their typed secrets above (header (c)); everything else
  # is recorded in full (header (d)). A redact failure on a Bash response
  # withholds the body rather than risking an unredacted leak, mirroring the
  # args-redact-failure handling above. ---
  # --- browser typing tools: mask the typed secrets in the FULL response
  # BEFORE truncation (header (c)). Literal replacement of every spelling
  # redact-browser returned. If masking fails -- or redact-browser itself
  # failed -- the body is withheld, never recorded unredacted. ---
  local response_for_body="$tool_response"
  if [[ "$browser_redact_failed" == "true" ]]; then
    response_for_body='"<redacted: responseBody withheld, redact failed>"'
  elif [[ "$browser_secrets" != "[]" ]]; then
    local masked=""
    # The body goes in on STDIN, never argv/env: a browser response carries a
    # page snapshot and can exceed Linux's 128KB MAX_ARG_STRLEN (the v0.7.1
    # provenance.sh "Argument list too long" lesson).
    if has_jq; then
      masked="$(printf '%s' "$tool_response" | jq -Rrs --argjson secrets "$browser_secrets" \
        'reduce $secrets[] as $s (.; split($s) | join("<redacted>"))' 2>/dev/null)"
    elif has_py; then
      masked="$(printf '%s' "$tool_response" | python3 -c '
import json, sys
body = sys.stdin.read()
for s in json.loads(sys.argv[1]):
    if isinstance(s, str) and s:
        body = body.replace(s, "<redacted>")
sys.stdout.write(body)
' "$browser_secrets" 2>/dev/null)"
    fi
    if [[ -n "$masked" ]]; then
      response_for_body="$masked"
    else
      warn "masking typed secrets in the ${tool_name} response failed, withholding responseBody"
      response_for_body='"<redacted: responseBody withheld, redact failed>"'
    fi
  fi

  # --- observed findings (0.9.0, ADR-0027): the observe round's
  # console[]/network[] and browser_network_requests' request list, unwrapped
  # from the real MCP content array of the FULL response (before the cap
  # below can cut the wrapper mid-string) into a compact `observed` field.
  # Shared extractor: toolstream.sh extract-observed — the same library
  # qa-verify's findings channel reads with. Best-effort: empty on failure. ---
  local observed_json=""
  case "$tool_name" in
    *browser_evaluate|*browser_network_requests)
      observed_json="$(printf '%s' "$response_for_body" | bash "$TOOLSTREAM" extract-observed "$tool_name" 2>/dev/null)" || observed_json=""
      ;;
  esac

  # --- screenshot (0.10.0, ADR-0028): for browser_take_screenshot, hash the
  # file the driver just saved, NOW — before the agent can touch it — into a
  # `screenshot: {file, path, sha256, bytes}` field. record-evidence.sh
  # refuses an image whose hash differs; provenance.sh binds by it. Best-
  # effort: unresolvable -> {file} only (binding falls back to the name). ---
  local screenshot_json=""
  case "$tool_name" in
    *browser_take_screenshot)
      local hook_cwd=""
      if has_jq; then
        hook_cwd="$(jq -r '.cwd // empty' <<< "$input" 2>/dev/null)"
      elif has_py; then
        hook_cwd="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("cwd") or "")' <<< "$input" 2>/dev/null)"
      fi
      screenshot_json="$(screenshot_capture "$tool_input" "$tool_response" "$hook_cwd" 2>/dev/null)" || screenshot_json=""
      ;;
  esac

  local truncated_response
  truncated_response="$(printf '%s' "$response_for_body" | head -c "$RESPONSE_BODY_CAP")"

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
      --arg observed "$observed_json" \
      --arg screenshot "$screenshot_json" \
      '{tool: $tool, args: $args, resultDigest: {len: $len, sha256: $hash}, responseBody: $body}
       + (if $advisory != "" then {advisory: $advisory} else {} end)
       + (if $observed != "" then {observed: ($observed | fromjson)} else {} end)
       + (if $screenshot != "" then {screenshot: ($screenshot | fromjson)} else {} end)' \
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
observed = sys.argv[7] if len(sys.argv) > 7 else ""
screenshot = sys.argv[8] if len(sys.argv) > 8 else ""
d = {"tool": tool, "args": args, "resultDigest": {"len": length, "sha256": h}, "responseBody": body}
if advisory:
    d["advisory"] = advisory
if observed:
    d["observed"] = json.loads(observed)
if screenshot:
    d["screenshot"] = json.loads(screenshot)
print(json.dumps(d, separators=(",", ":")))
' "$tool_name" "$args_json" "$resp_len" "$resp_hash" "$response_body_json" "$advisory" "$observed_json" "$screenshot_json" 2>/dev/null)"
  fi
  [[ -z "$event_json" ]] && { warn "failed to build event JSON, no-op"; return 0; }

  bash "$TOOLSTREAM" append "$run_id" "$event_json" 2>/dev/null \
    || warn "toolstream append failed for run '${run_id}'"

  # --- live self-checks (0.9.0, ADR-0027): tell the agent NOW, at the call
  # that shows the problem, instead of letting qa-verify discover it after
  # the run. Advisory only — additionalContext never blocks the call. ---
  local nudge=""
  nudge="$(live_nudges "$run_id" "$tool_name" "$tool_input" "$response_for_body" "$observed_json" "$config_json" "$cfg_file" 2>/dev/null)" || nudge=""
  [[ -n "$nudge" ]] && emit_context "$nudge"

  return 0
}

main
exit 0
