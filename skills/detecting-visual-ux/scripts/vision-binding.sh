#!/usr/bin/env bash
# vision-binding.sh — resolve the per-harness vision-capability binding from
# harness-profiles.json (ADR-0017's naming/model table, extended with a
# "vision" descriptor per harness) for the layer-3 generative critic (ADR-0019
# §5). Mirrors the header/engine-resolution idiom of the sibling
# skills/detecting-visual-ux/scripts/ux-conventions.sh (die/has_jq/has_py/
# QA_ENGINE) and the SCRIPT_DIR self-location trick used across
# skills/checkpointing-qa-memory/scripts/*.sh.
#
# USAGE:
#   vision-binding.sh resolve [<harness>]
#       Reads harnesses.<harness>.vision from harness-profiles.json and
#       prints its "read" binding (Read|localImage|adapter) when
#       vision.capable is true. Prints "absent" when vision.capable is
#       false, OR the vision object / harness entry is missing. Default
#       <harness> is ${QA_HARNESS:-claude}.
#
#   vision-binding.sh banner
#       Prints the fixed honest-degrade line for when layer-3 is skipped
#       because vision is unavailable for this harness/model.
#
# ENV:
#   QA_ENGINE    unset (auto: jq if present else python3) | jq | python3
#   QA_HARNESS   default harness for `resolve` when none is given (default: claude)
#   QA_PROFILES  override path to harness-profiles.json (default: the repo's
#                own harness-profiles.json, resolved relative to this script
#                so it does NOT depend on cwd). Tests use this to point at a
#                temp copy with a synthetic vision-absent harness.
#
# DEPENDENCIES: bash, coreutils, and EITHER jq OR python3 (jq preferred;
#               python3 fallback). No node, no perl, no grep -P.

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE (unset by default): python3 forces the python3 branch even if jq
# is on PATH; jq forces the jq branch; unset/anything else = auto-detect (jq
# if present, else python3) — same contract as ux-conventions.sh's has_jq.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}

has_py() { command -v python3 >/dev/null 2>&1; }

# Locate harness-profiles.json relative to THIS script (pure bash parameter
# expansion, no external `dirname` needed) — the script lives at
# skills/detecting-visual-ux/scripts/, so the repo root is three levels up.
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
DEFAULT_PROFILES="${SCRIPT_DIR}/../../../harness-profiles.json"
PROFILES="${QA_PROFILES:-$DEFAULT_PROFILES}"

BANNER='NOTE: layer-3 generative critic SKIPPED — vision unavailable for this harness/model; ran layers 1-2 (definite-oracle detectors + adjudication) only.'

# ---------------------------------------------------------------------------
# cmd_resolve [<harness>]
# ---------------------------------------------------------------------------
cmd_resolve() {
  local harness="${1:-${QA_HARNESS:-claude}}"

  [[ -s "$PROFILES" ]] || die "resolve: profiles file '${PROFILES}' is missing or empty."

  if has_jq; then
    jq -r --arg h "$harness" '
      (.harnesses[$h].vision) as $v
      | if ($v != null and $v.capable == true) then ($v.read // "absent") else "absent" end
    ' "$PROFILES" 2>/dev/null || die "resolve: '${PROFILES}' is not valid JSON."
  elif has_py; then
    python3 -c '
import json, sys
path, harness = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        doc = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)
v = (doc.get("harnesses") or {}).get(harness, {}).get("vision")
if isinstance(v, dict) and v.get("capable") is True:
    print(v.get("read") or "absent")
else:
    print("absent")
' "$PROFILES" "$harness" || die "resolve: '${PROFILES}' is not valid JSON."
  else
    die "vision-binding.sh needs either 'jq' or 'python3' to read '${PROFILES}'."
  fi
}

# ---------------------------------------------------------------------------
# cmd_banner
# ---------------------------------------------------------------------------
cmd_banner() { printf '%s\n' "$BANNER"; }

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -ge 1 ]] || die "Usage: vision-binding.sh resolve [<harness>]\n       vision-binding.sh banner"
  local cmd="$1"; shift
  case "$cmd" in
    resolve) cmd_resolve "$@" ;;
    banner)
      [[ $# -eq 0 ]] || die "Usage: vision-binding.sh banner (takes no arguments)."
      cmd_banner
      ;;
    *) die "Unknown subcommand '${cmd}' (expected: resolve|banner)." ;;
  esac
}

main "$@"
