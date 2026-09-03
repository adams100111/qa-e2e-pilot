#!/usr/bin/env bash
# run-ux-measure.sh — one-command driver for the UI/UX accuracy harness's MEASURED run.
#
# Unlike run-baseline.sh, this needs no operator-in-the-loop agent dispatch: the UX taxonomy
# fixture is scored headlessly by running the REAL detector cores + adjudicator (ux-measure.js)
# directly over the committed fixture-ux/snapshot.json, then scoring the result against
# seeds-ux.json (which declares heldOutRecallMin:1.0 in addition to the usual recall/precision
# floors — see seeds-ux.json's "gate" block and score.js's held-out check).
#
#   ./run-ux-measure.sh   # (re)produce findings/measured-ux-baseline.json, then score --gate
#
# Exit code is score.js's: 0 when the gate passes, non-zero when it fails.
set -euo pipefail
cd "$(dirname "$0")"

node scorer/ux-measure.js fixture-ux/snapshot.json > findings/measured-ux-baseline.json
node scorer/score.js findings/measured-ux-baseline.json --seeds seeds-ux.json --gate
