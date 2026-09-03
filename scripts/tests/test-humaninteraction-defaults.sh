#!/usr/bin/env bash
# test-humaninteraction-defaults.sh — Plan H3 Task 4 (B + T-14):
# humanInteraction.saveSession defaults to true (Check-0 reconciliation
# enabled by default, degrades gracefully when no session log is present)
# and humanInteraction.autonomousSetup is present, defaulting to false
# (interactive setup rounds unless the operator opts in for headless/CI).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"

# .qa/config.json.example: valid JSON, both flags at their new defaults.
python3 -c "
import json
d = json.load(open('.qa/config.json.example'))
hi = d['humanInteraction']
assert hi['saveSession'] is True, hi
assert hi['autonomousSetup'] is False, hi
"

# init-config.sh (write mode) emits the same defaults.
IC="$root/skills/bootstrapping-qa-config/scripts/init-config.sh"
tmp="$(mktemp -d)"
( cd "$tmp" && bash "$IC" --base-url http://localhost:8099 )
python3 -c "
import json
d = json.load(open('$tmp/.qa/config.json'))
hi = d['humanInteraction']
assert hi['saveSession'] is True, hi
assert hi['autonomousSetup'] is False, hi
"

# confirming-discovered-roles' SKILL.md documents the autonomousSetup read
# and that it is setup-phase-only (decision #8), never the Verify loop.
grep -q 'autonomousSetup' skills/confirming-discovered-roles/SKILL.md
grep -qi 'setup.*only\|SETUP PHASES ONLY\|setup-only' skills/confirming-discovered-roles/SKILL.md

echo "OK"
