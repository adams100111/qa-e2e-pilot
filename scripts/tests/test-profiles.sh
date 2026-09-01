#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$root/harness-profiles.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
caps=d["capabilities"]; hs=d["harnesses"]
assert len(caps)==20, f"want 20 capabilities, got {len(caps)}"
assert caps[0]=="browser_navigate" and caps[-1]=="browser_close"
# browser_network_requests (list) and browser_network_request (read one body) are DISTINCT — both required, in this order
assert "browser_network_requests" in caps and "browser_network_request" in caps
assert caps.index("browser_network_requests") < caps.index("browser_network_request")
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
# Drift guard: capabilities MUST equal the browser tools in the agent frontmatter, in order
# (this is the exact invariant the Task 3 byte-oracle depends on).
python3 - "$root/harness-profiles.json" "$root/agents/qa-e2e-pilot.md" <<'PY'
import json,sys
caps=json.load(open(sys.argv[1]))["capabilities"]
line=[l for l in open(sys.argv[2]) if l.startswith("tools:")][0]
fm=[t.strip().split("__")[-1] for t in line.split("tools:",1)[1].split(",") if "browser_" in t]
assert caps==fm, f"capabilities drift from agent frontmatter:\n caps={caps}\n  fm={fm}"
print("OK (frontmatter order match)")
PY
