#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$root"
bash scripts/build-adapter.sh codex
python3 -c "import tomllib;tomllib.load(open('dist/codex/agent/qa-e2e-pilot.toml','rb'))"
python3 -c "import tomllib;d=tomllib.load(open('dist/codex/mcp.snippet','rb'));\
assert 'playwright-qa' in d['mcp_servers'], d; \
assert '--save-session' in d['mcp_servers']['playwright-qa']['args']"
bash -n harnesses/codex/install-codex.sh
echo "OK"
