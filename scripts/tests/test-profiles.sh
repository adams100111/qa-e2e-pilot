#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$root/harness-profiles.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
caps=d["capabilities"]; hs=d["harnesses"]
assert len(caps)==19, f"want 19 capabilities, got {len(caps)}"
assert caps[0]=="browser_navigate" and caps[-1]=="browser_close"
assert set(hs)=={"claude","codex","pi","opencode"}, set(hs)
req={"toolPrefix","serverKey","grantStyle","modelField","tierDefault","tierHeavy","dispatch","globalRolesDir","agentCmd"}
for k,p in hs.items():
    miss=req-set(p); assert not miss, f"{k} missing {miss}"
    assert p["grantStyle"] in {"list","scope","proxy","glob"}, (k,p["grantStyle"])
assert hs["claude"]["serverKey"]=="playwright", "Claude must keep official 'playwright' key"
for k in ("codex","pi","opencode"):
    assert hs[k]["serverKey"]=="playwright-qa", f"{k} must use playwright-qa"
print("OK")
PY
