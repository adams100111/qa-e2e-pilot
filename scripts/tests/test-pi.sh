#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
bash scripts/build-adapter.sh pi
python3 -c "import json;d=json.load(open('dist/pi/mcp.snippet'));\
s=d['mcpServers']['playwright-qa'];assert '--save-session' in s['args'],s"
# agent frontmatter parses and grants the proxy tool
python3 - <<'PY'
import re
t=open('dist/pi/agent/qa-e2e-pilot.md').read()
fm=t.split('---',2)[1]
assert re.search(r'^\s*tools:.*\bmcp\b', fm, re.M), "pi agent must grant the mcp proxy tool"
PY
bash -n harnesses/pi/install-pi.sh
echo "OK"
