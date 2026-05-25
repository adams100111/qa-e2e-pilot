#!/usr/bin/env bash
# memory-sync.sh — optional write-through of a run's DURABLE QA memory to a
# Mem0/vector backend, for cross-run recall ("have we seen this bug before?").
#
# Syncs ONLY durable artifacts — the bug-log entries and one per-project pointer
# (latest run id + status). It deliberately does NOT sync per-criterion checkpoints:
# those are transient resume state (ADR-0002) and belong only in .qa/runs/.
#
# This is an OPT-IN swap. With memory.backend = "file" (the default) it is a no-op.
# The file checkpoint remains the authoritative resume cursor regardless.
#
# USAGE:
#   memory-sync.sh <run-id> [--dry-run]
#     --dry-run   print the payload + the request that WOULD be sent (key redacted); send nothing
#
# CONFIG (.qa/config.json):
#   "memory": {
#     "backend": "file" | "mem0",
#     "mem0": { "endpoint": "https://...", "apiKeyEnv": "MEM0_API_KEY", "userId": "qa-e2e-pilot" }
#   }
#
# DEPENDENCIES: bash + python3 (JSON), curl (only for a real send). Exit 0 on no-op/success.
set -euo pipefail

CONFIG_FILE="${QA_CONFIG:-.qa/config.json}"
QA_BASE=".qa/runs"

RUN_ID="${1:-}"
DRY_RUN="no"
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN="yes"
[[ -n "$RUN_ID" ]] || { echo "Usage: memory-sync.sh <run-id> [--dry-run]" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "memory-sync.sh requires python3" >&2; exit 2; }
[[ -f "$CONFIG_FILE" ]] || { echo "[memory-sync] no $CONFIG_FILE — nothing to sync (default backend is file)"; exit 0; }

RUN_DIR="${QA_BASE}/${RUN_ID}"
[[ -d "$RUN_DIR" ]] || { echo "[memory-sync] run dir not found: $RUN_DIR" >&2; exit 2; }

# Build the payload + read the backend config in one python pass. Prints, on stdout:
#   line 1: backend
#   line 2: endpoint  (empty if not mem0)
#   line 3: apiKeyEnv (empty if not mem0)
#   remaining: the JSON payload (only when backend == mem0)
read_plan() {
python3 - "$CONFIG_FILE" "$RUN_DIR" "$RUN_ID" <<'PYEOF'
import json, sys, os
cfg_path, run_dir, run_id = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(cfg_path))
mem = cfg.get("memory", {}) or {}
backend = mem.get("backend", "file")
mem0 = mem.get("mem0", {}) or {}
endpoint = mem0.get("endpoint", "") if backend == "mem0" else ""
api_key_env = mem0.get("apiKeyEnv", "") if backend == "mem0" else ""
user_id = mem0.get("userId", "qa-e2e-pilot")

print(backend)
print(endpoint)
print(api_key_env)

if backend != "mem0":
    sys.exit(0)

def load(name):
    p = os.path.join(run_dir, name)
    try:
        return json.load(open(p))
    except Exception:
        return None

bug_log = load("bug-log.json") or {}
manifest = load("run-manifest.json") or {}
checkpoint = load("checkpoint.json") or {}

bugs = bug_log.get("bugs", bug_log.get("entries", [])) if isinstance(bug_log, dict) else (bug_log or [])

records = []
# Durable: one record per bug (cross-run "have we seen this?").
for b in bugs:
    records.append({
        "type": "bug",
        "run_id": run_id,
        "title": b.get("title"),
        "severity": b.get("severity"),
        "suspected_layer": b.get("suspected_layer"),
        "expected": b.get("expected"),
        "actual": b.get("actual"),
    })
# Durable: exactly one per-project pointer (latest run + status + known-flaky areas).
records.append({
    "type": "project_pointer",
    "run_id": run_id,
    "target": manifest.get("target"),
    "status": manifest.get("status") or checkpoint.get("status"),
    "criteria_total": len(checkpoint.get("criteria", [])),
    "known_flaky": manifest.get("known_flaky", []),
})

payload = {"user_id": user_id, "records": records}
print(json.dumps(payload, indent=2))
PYEOF
}

PLAN="$(read_plan)"
BACKEND="$(printf '%s\n' "$PLAN" | sed -n '1p')"
ENDPOINT="$(printf '%s\n' "$PLAN" | sed -n '2p')"
APIKEY_ENV="$(printf '%s\n' "$PLAN" | sed -n '3p')"
PAYLOAD="$(printf '%s\n' "$PLAN" | sed -n '4,$p')"

if [[ "$BACKEND" != "mem0" ]]; then
  echo "[memory-sync] memory.backend is '${BACKEND:-file}' (default); nothing to sync. The file checkpoint in $RUN_DIR is authoritative."
  exit 0
fi

[[ -n "$ENDPOINT" ]] || { echo "[memory-sync] memory.backend=mem0 but memory.mem0.endpoint is unset in $CONFIG_FILE" >&2; exit 2; }

# Resolve the API key from the named env var WITHOUT printing it.
API_KEY=""
if [[ -n "$APIKEY_ENV" ]]; then API_KEY="${!APIKEY_ENV:-}"; fi

if [[ "$DRY_RUN" == "yes" ]]; then
  echo "[memory-sync] DRY RUN — would POST to: $ENDPOINT"
  echo "[memory-sync] auth: ${APIKEY_ENV:-<none>} -> $([[ -n "$API_KEY" ]] && echo '<set, redacted>' || echo '<MISSING>')"
  echo "[memory-sync] payload:"
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "memory-sync.sh needs curl for a real send" >&2; exit 2; }
[[ -n "$API_KEY" ]] || { echo "[memory-sync] env var '$APIKEY_ENV' is empty — cannot authenticate to $ENDPOINT" >&2; exit 2; }

HTTP_CODE=$(printf '%s' "$PAYLOAD" | curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  --data-binary @- 2>/dev/null || echo "000")

case "$HTTP_CODE" in
  2*) echo "[memory-sync] synced durable memory for run $RUN_ID to $ENDPOINT (HTTP $HTTP_CODE)";;
  000) echo "[memory-sync] endpoint unreachable ($ENDPOINT) — file checkpoint is unaffected" >&2; exit 1;;
  *)  echo "[memory-sync] endpoint returned HTTP $HTTP_CODE — file checkpoint is unaffected" >&2; exit 1;;
esac
