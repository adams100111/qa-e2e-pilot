#!/usr/bin/env bash
# runconfig-merge.sh — compute a run's EFFECTIVE config by shallow-merging a spec's
# run-config deltas over .qa/config.json (pure, dual-engine). Delta keys win.
#
# WHY (R3-Q2): a qa-kit spec records per-run config DELTAS (drivers/maxParallel/
# criteriaBudget/viewport) over the project's .qa/config.json defaults. This helper
# turns (config + deltas) into the effective config for ONE run WITHOUT mutating
# .qa/config.json on disk. How the run consumes it: the operator (or a future engine
# integration) applies the printed config for that run; the engine's /qa-run reads
# .qa/config.json, so today qa-kit either previews the effective config or the operator
# writes it for the run. Per-run auto-application inside the unmodified engine /qa-run
# is a documented deferral (engine stays untouched under the dependencies model).
#
# USAGE:
#   runconfig-merge.sh <config.json> <run-config-deltas.json>
#       Both must be JSON objects. Prints the shallow merge (deltas over config) as
#       pretty JSON, sorted keys for determinism. Exit nonzero on non-object input.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred). No node/perl/grep -P.
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

[ "$#" -eq 2 ] || die "usage: runconfig-merge.sh <config.json> <run-config-deltas.json>"
CONFIG="$1"; DELTAS="$2"
[ -f "$CONFIG" ] || die "runconfig-merge: config not found: $CONFIG"
[ -f "$DELTAS" ] || die "runconfig-merge: deltas not found: $DELTAS"

if has_jq; then
  jq -n --slurpfile c "$CONFIG" --slurpfile d "$DELTAS" '
    ($c[0]) as $cfg | ($d[0]) as $delta
    | if ($cfg | type) != "object" then error("config must be a JSON object") else . end
    | if ($delta | type) != "object" then error("run-config deltas must be a JSON object") else . end
    | ($cfg + $delta)
  ' --sort-keys || die "runconfig-merge: jq failed (non-object input)."
elif has_py; then
  python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1])); delta = json.load(open(sys.argv[2]))
if not isinstance(cfg, dict): sys.exit("config must be a JSON object")
if not isinstance(delta, dict): sys.exit("run-config deltas must be a JSON object")
eff = dict(cfg); eff.update(delta)
print(json.dumps(eff, indent=2, sort_keys=True))
' "$CONFIG" "$DELTAS" || die "runconfig-merge: python3 failed (non-object input)."
else
  die "runconfig-merge.sh needs either 'jq' or 'python3'."
fi
