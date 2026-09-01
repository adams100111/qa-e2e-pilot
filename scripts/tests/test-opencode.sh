#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
bash scripts/build-adapter.sh opencode
python3 -c "import json;d=json.load(open('dist/opencode/mcp.snippet'));\
s=d['mcp']['playwright-qa'];assert s['type']=='local' and '--save-session' in s['command'],s"
# agent frontmatter: mode primary + glob tool grant present
python3 - <<'PY'
t=open('dist/opencode/agent/qa-e2e-pilot.md').read(); fm=t.split('---',2)[1]
assert 'mode: primary' in fm
assert '"playwright-qa*": true' in fm, "opencode agent must glob-allow the playwright-qa server"
PY
bash -n harnesses/opencode/install-opencode.sh
echo "OK"
