#!/usr/bin/env bash
# scripts/session-preflight.sh — the preflight that produces
# .qa/runs/<run-id>/toolstream.jsonl from a Playwright MCP --save-session
# log BEFORE qa-verify.sh runs (portable-enforcement H4/T-13, Task 2).
#
# WHY: Task 1 (skills/driving-browser-qa/scripts/session-to-toolstream.js)
# converts a saved session.md into toolstream events, but something has to
# actually RUN it before qa-verify looks for a toolstream. On Claude, a
# live capture-hook already writes .qa/runs/<run-id>/toolstream.jsonl as
# the run happens. Non-Claude harnesses (Codex/Pi/opencode) have no such
# hook — without this preflight they'd hit qa-verify's honest
# no-toolstream degrade (confidence:low) on every bake/probe/human-action
# pass, even though a --save-session log with the real evidence exists.
# This script closes that gap.
#
# USAGE:
#   session-preflight.sh <run-id>
#
#     - If .qa/runs/<run-id>/toolstream.jsonl ALREADY EXISTS (a live
#       capture-hook wrote it) -> NO-OP. This script NEVER overwrites a
#       live-hook toolstream.
#     - Else resolve a session log: $QA_SESSION_LOG if set, else the
#       newest *.md under .playwright-mcp/ (the --output-dir every harness
#       profile uses for `--save-session`).
#     - No session log resolvable -> NO-OP. qa-verify's honest
#       no-toolstream degrade still applies — this is not an error.
#     - Else: run session-to-toolstream.js on the resolved log and pipe
#       each emitted ndjson line through `toolstream.sh append <run-id>`
#       (the canonical writer — it stamps seq/ts and applies redaction;
#       this script never writes toolstream.jsonl directly).
#
#   Idempotent: re-running after a toolstream already exists (whether
#   written by a live hook or by a prior run of this same script) is
#   always a no-op.
#
# ENV:
#   QA_BASE          runs dir (default: .qa/runs) — same convention as
#                     toolstream.sh/journal.sh/checkpoint.sh.
#   QA_SESSION_LOG    explicit path to a session.md, overriding the
#                     .playwright-mcp/*.md auto-discovery.
#   QA_ENGINE         forwarded to toolstream.sh's own jq-vs-python3
#                     auto-detect (this script itself needs neither jq nor
#                     python3 — it only orchestrates node + toolstream.sh).
#
# EXIT: 0 on every recognized case, including both no-op cases (already-
#       present toolstream, no resolvable session log) — those are honest
#       degrades, not failures. Non-zero only on a malformed run-id or a
#       genuine failure to run the converter/writer.
#
# DEPENDENCIES: bash, coreutils (ls, mkdir), node (for the converter — its
# own toolstream.sh append calls need jq or python3, per that script's own
# header).
#
# NOTE: all paths are relative to the current working directory (project
# root), same convention as toolstream.sh/journal.sh/checkpoint.sh.
set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

die() { echo "ERROR: $*" >&2; exit 1; }

# validate_token <run-id> — mirrors journal-emit.sh's validate_token (Fix
# 28): reject anything that could escape .qa/runs/<run-id>/ when
# interpolated into a path. Nothing is read/written on a rejected run-id.
validate_token() {
  local value="$1"
  [[ -z "$value" ]] && die "run-id must not be empty."
  case "$value" in
    */*|*\\*) die "run-id '${value}' contains a path separator ('/' or '\\') — must be a simple token." ;;
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

# Locate sibling scripts relative to THIS file (pure-bash parameter
# expansion, no external `dirname`), so this script works regardless of
# the caller's cwd — same trick journal-emit.sh/checkpoint.sh use.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
CONVERTER="${SCRIPT_DIR}/../skills/driving-browser-qa/scripts/session-to-toolstream.js"
TOOLSTREAM_SH="${SCRIPT_DIR}/toolstream.sh"

# resolve_session_log -> stdout the resolved session log path, or nothing
# if none is resolvable. $QA_SESSION_LOG wins when set (and exists); else
# the newest *.md under .playwright-mcp/ (mtime order, matches every
# harness profile's --save-session --output-dir convention).
resolve_session_log() {
  if [[ -n "${QA_SESSION_LOG:-}" ]]; then
    if [[ -f "$QA_SESSION_LOG" ]]; then
      echo "$QA_SESSION_LOG"
      return 0
    fi
    return 1
  fi
  if [[ -d ".playwright-mcp" ]]; then
    local newest
    newest="$(ls -t .playwright-mcp/*.md 2>/dev/null | head -1 || true)"
    if [[ -n "$newest" && -f "$newest" ]]; then
      echo "$newest"
      return 0
    fi
  fi
  return 1
}

main() {
  [[ $# -eq 1 ]] || die "Usage: session-preflight.sh <run-id>"
  local run_id="$1"
  validate_token "$run_id"

  local toolstream_file="${QA_BASE}/${run_id}/toolstream.jsonl"
  if [[ -f "$toolstream_file" ]]; then
    echo "session-preflight: toolstream already present for ${run_id} (live capture) — skipping"
    exit 0
  fi

  local session_log
  if ! session_log="$(resolve_session_log)"; then
    echo "session-preflight: no session log for ${run_id} — qa-verify will run with no toolstream (honest degrade)"
    exit 0
  fi

  command -v node >/dev/null 2>&1 || {
    echo "session-preflight: node not available — cannot derive a toolstream for ${run_id} — qa-verify will run with no toolstream (honest degrade)"
    exit 0
  }

  local events
  events="$(node "$CONVERTER" "$session_log")" || die "session-preflight: session-to-toolstream.js failed on ${session_log}"

  local line n=0
  if [[ -n "$events" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      bash "$TOOLSTREAM_SH" append "$run_id" "$line" >/dev/null \
        || die "session-preflight: toolstream.sh append failed for run ${run_id} (event: ${line})"
      n=$((n + 1))
    done <<< "$events"
  fi

  echo "session-preflight: derived ${n} toolstream events for ${run_id} from ${session_log}"
}

main "$@"
