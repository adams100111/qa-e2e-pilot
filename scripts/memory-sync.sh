#!/usr/bin/env bash
# memory-sync.sh — optional write-through of a run's DURABLE QA memory to a
# Mem0/vector backend, for cross-run recall ("have we seen this bug before?").
#
# Syncs ONLY durable artifacts — the bug-log entries (now enriched, additively,
# with the persona(s) they reproduced under and a compact excerpt of their
# bake/computed/probe evidence — content that makes "have we seen this
# before?" actually answerable), an optional advisory-stream record per
# subjective-aesthetics finding (ADR-0007 — durable because a recurring visual
# defect is worth recalling across runs even though it never gates a verdict),
# and one per-project pointer (latest run id + status + the personas exercised).
# It deliberately does NOT sync per-criterion checkpoints wholesale (verdict/
# phase/last_action/kinds for every criterion): those stay transient resume
# state (ADR-0002) and belong only in .qa/runs/ — this script only reads
# checkpoint.json to CROSS-REFERENCE which persona(s)/kinds/evidence a given
# bug or advisory item is attached to, never to re-emit the full criteria list.
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
advisory = load("advisory.json")  # optional; no producer writes this yet (additive)

bugs = bug_log.get("bugs", bug_log.get("entries", [])) if isinstance(bug_log, dict) else (bug_log or [])
criteria = checkpoint.get("criteria", [])

# criterion_id -> list of checkpoint records that reference it (any persona).
# Used only to enrich a durable bug/advisory record with persona + evidence —
# never to re-emit the transient checkpoint list itself.
by_criterion = {}
for c in criteria:
    by_criterion.setdefault(c.get("criterion_id"), []).append(c)

EVIDENCE_KIND_FILES = {"bake-read-back.json", "recompute.json", "network-response.json"}

def compact_evidence(evidence_refs):
    """Read only the small, structured kind artifacts (bake/computed/probe) a
    ref list points at — never screenshots/binaries — and return their
    already-compact JSON content (readBack/multiplicity, oracle/observed/
    match, status/shape). No secrets: these artifacts are written by
    record-evidence.sh, which never captures credentials/tokens."""
    out = []
    for ref in evidence_refs or []:
        if os.path.basename(ref) not in EVIDENCE_KIND_FILES:
            continue
        p = os.path.join(run_dir, ref)
        try:
            out.append(json.load(open(p)))
        except Exception:
            continue
    return out

records = []
all_personas = set()

# Durable: one record per bug (cross-run "have we seen this?"), now carrying
# which persona(s) it reproduced under and a compact evidence excerpt.
for b in bugs:
    matches = by_criterion.get(b.get("criterion_id"), [])
    personas = sorted({m.get("persona") for m in matches if m.get("persona")})
    all_personas.update(personas)
    kinds = sorted({k for m in matches for k in (m.get("kinds") or [])})
    evidence = compact_evidence(b.get("evidence_refs"))
    records.append({
        "type": "bug",
        "run_id": run_id,
        "title": b.get("title"),
        "severity": b.get("severity"),
        "suspected_layer": b.get("suspected_layer"),
        "expected": b.get("expected"),
        "actual": b.get("actual"),
        "personas": personas,     # [] when the criterion was shared (no --persona)
        "kinds": kinds,
        "evidence": evidence,     # [] when no bake/computed/probe artifact was attached
    })

# Durable: one record per advisory (aesthetics) finding, when present — never
# a verdict, never gated (ADR-0007), but worth recalling if the same visual
# defect keeps recurring run over run.
adv_items = advisory.get("items", []) if isinstance(advisory, dict) else (advisory or [])
for item in adv_items:
    if not isinstance(item, dict):
        continue
    records.append({
        "type": "advisory_finding",
        "run_id": run_id,
        "criterion_id": item.get("criterion_id") or item.get("surface"),
        "message": item.get("message"),
        "selector": item.get("selector"),
    })

# Durable: exactly one per-project pointer (latest run + status + known-flaky
# areas + which personas this run actually exercised).
records.append({
    "type": "project_pointer",
    "run_id": run_id,
    "target": manifest.get("target"),
    "status": manifest.get("status") or checkpoint.get("status"),
    "criteria_total": len(criteria),
    "known_flaky": manifest.get("known_flaky", []),
    "personas_exercised": sorted(all_personas),
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
