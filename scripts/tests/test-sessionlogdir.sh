#!/usr/bin/env bash
# test-sessionlogdir.sh — humanInteraction.sessionLogDir config field +
# QA_DRIVER_SERVER driver server-key override (Task 7).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
python3 -c "import json;d=json.load(open('.qa/config.json.example'));\
assert d['humanInteraction']['sessionLogDir']=='.playwright-mcp',d['humanInteraction']"
IC="$root/skills/bootstrapping-qa-config/scripts/init-config.sh"
# Write mode = NO --suggest, WITH --base-url. Default server key stays 'playwright'.
tmp="$(mktemp -d)"; ( cd "$tmp" && bash "$IC" --base-url http://localhost:8099 )
python3 -c "import json;d=json.load(open('$tmp/.qa/config.json'));\
assert d['humanInteraction']['sessionLogDir']=='.playwright-mcp', d.get('humanInteraction');\
assert d['drivers'][0]['server']=='playwright', d['drivers']"
# QA_DRIVER_SERVER overrides the driver server key to playwright-qa.
tmp2="$(mktemp -d)"; ( cd "$tmp2" && QA_DRIVER_SERVER=playwright-qa bash "$IC" --base-url http://localhost:8099 )
python3 -c "import json;d=json.load(open('$tmp2/.qa/config.json'));assert d['drivers'][0]['server']=='playwright-qa', d['drivers']"
grep -q 'sessionLogDir' skills/driving-browser-qa/SKILL.md
echo "OK"
