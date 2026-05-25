#!/usr/bin/env bash
# preflight.sh — QA pre-flight gate for qa-e2e-pilot.
# Inspired by opslane/verify's pure-bash preflight pattern (credited in README);
# reimplemented with driver enumeration, build-id capture, and cross-origin detection.
#
# Reads: .qa/config.json (baseUrl, drivers[], auth.storageState)
# Exits 0 = all clear; non-zero = abort (reason printed).
#
# Degrades gracefully when jq is absent — falls back to node if present, else grep.

set -euo pipefail

CONFIG_FILE="${QA_CONFIG:-.qa/config.json}"
WARN_STALE_MINUTES="${QA_BUILD_STALE_MINUTES:-30}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; RESET='\033[0m'
info()  { printf "${GREEN}[preflight]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[preflight WARN]${RESET} %s\n" "$*"; }
abort() { printf "${RED}[preflight ABORT]${RESET} %s\n" "$*" >&2; exit 1; }

# ── 1. Config file ──────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || abort "Config not found: $CONFIG_FILE — create it from .qa/config.json.example"

# ── 2. JSON reader (jq → node → grep fallback) ──────────────────────────────
jq_get() {
  # $1 = jq filter (e.g. '.baseUrl'), $2 = default value
  local filter="$1" default="${2:-}"
  if command -v jq &>/dev/null; then
    jq -r "$filter // empty" "$CONFIG_FILE" 2>/dev/null || echo "$default"
  elif command -v node &>/dev/null; then
    node -e "
      try {
        const c = require('fs').readFileSync('$CONFIG_FILE','utf8');
        // simple dotted key extraction (built-ins only — no external deps)
        const keys = '$filter'.replace(/^\./,'').split('.');
        let cur = JSON.parse(c);
        for (const k of keys) { cur = cur == null ? null : cur[k]; }
        process.stdout.write(cur == null ? '' : String(cur));
      } catch(e) { process.stdout.write(''); }
    " 2>/dev/null || echo "$default"
  else
    # last resort: grep for quoted value on a best-effort basis
    grep -o "\"${filter##*.}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG_FILE" \
      | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || echo "$default"
  fi
}

BASE_URL=$(jq_get '.baseUrl' '')
[[ -n "$BASE_URL" ]] || abort "baseUrl is empty in $CONFIG_FILE"

AUTH_STATE=$(jq_get '.auth.storageState' '')

# ── 3. App liveness ──────────────────────────────────────────────────────────
info "Checking app liveness: $BASE_URL"
# curl prints "000" to stdout on a connection failure; capture it cleanly without
# appending a second "000" (|| true keeps set -e happy on curl's non-zero exit).
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL" 2>/dev/null || true)
[[ -n "$HTTP_STATUS" ]] || HTTP_STATUS="000"
case "$HTTP_STATUS" in
  2*|3*) info "App responded: HTTP $HTTP_STATUS" ;;
  000)   abort "App unreachable at $BASE_URL (curl timed out or connection refused)" ;;
  *)     abort "App returned HTTP $HTTP_STATUS at $BASE_URL — is it running?" ;;
esac

# ── 4. Auth / storageState check ─────────────────────────────────────────────
if [[ -n "$AUTH_STATE" ]]; then
  if [[ -f "$AUTH_STATE" ]]; then
    info "storageState found: $AUTH_STATE"
    # Warn if file is older than WARN_STALE_MINUTES (sessions expire).
    if command -v find &>/dev/null; then
      STALE=$(find "$AUTH_STATE" -mmin +"$WARN_STALE_MINUTES" 2>/dev/null || true)
      [[ -z "$STALE" ]] || warn "storageState is older than ${WARN_STALE_MINUTES}m — session may have expired"
    fi
  else
    abort "auth.storageState path set but file not found: $AUTH_STATE — run auth capture first"
  fi
else
  warn "auth.storageState not configured — criteria requiring auth will be blocked"
fi

# ── 5. Driver enumeration and ping ───────────────────────────────────────────
# Resolve CDP endpoint per platform preset.
resolve_cdp_endpoint() {
  local preset="$1"
  case "$preset" in
    managed)       echo "managed" ;;
    windows+wsl)
      # Reach the Windows host's Chrome from inside WSL. On mirrored networking,
      # localhost bridges to Windows (set cdpEndpoint to override with localhost);
      # on NAT-mode WSL2 the Windows host is the resolv.conf nameserver.
      local host
      host=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
      [[ -n "$host" ]] && echo "http://${host}:9222" || echo "http://localhost:9222" ;;
    windows)       echo "http://localhost:9222" ;;
    wsl)           echo "http://localhost:9222" ;;   # a CDP server running inside WSL itself
    linux)         echo "http://localhost:9222" ;;
    mac)           echo "http://localhost:9222" ;;
    *)             echo "http://localhost:9222" ;;
  esac
}

ping_driver() {
  local label="$1" endpoint="$2"
  if [[ "$endpoint" == "managed" ]]; then
    info "Driver [$label]: managed Playwright (zero-config) — OK"
    return 0
  fi
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${endpoint}/json/version" 2>/dev/null || true)
  [[ -n "$status" ]] || status="000"
  case "$status" in
    2*) info  "Driver [$label]: CDP at $endpoint — OK (HTTP $status)" ;;
    000) warn "Driver [$label]: CDP at $endpoint — unreachable (HTTP 000); criteria using this driver will be blocked" ;;
    *)   warn "Driver [$label]: CDP at $endpoint — HTTP $status; may not be available" ;;
  esac
}

# Extract driver array with jq, node, or a simple grep-based approach.
if command -v jq &>/dev/null; then
  DRIVER_COUNT=$(jq '.drivers | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  for idx in $(seq 0 $((DRIVER_COUNT - 1))); do
    DRV_ID=$(jq -r ".drivers[$idx].id // \"driver-$idx\"" "$CONFIG_FILE")
    DRV_PRESET=$(jq -r ".drivers[$idx].preset // \"managed\"" "$CONFIG_FILE")
    DRV_CDP=$(jq -r ".drivers[$idx].cdpEndpoint // empty" "$CONFIG_FILE")
    # An explicit cdpEndpoint overrides the preset-resolved endpoint.
    if [[ -n "$DRV_CDP" ]]; then ENDPOINT="$DRV_CDP"; else ENDPOINT=$(resolve_cdp_endpoint "$DRV_PRESET"); fi
    ping_driver "$DRV_ID" "$ENDPOINT"
  done
elif command -v node &>/dev/null; then
  node -e "
    const c = JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'));
    const drivers = c.drivers || [];
    drivers.forEach((d,i) => {
      process.stdout.write((d.id||'driver-'+i) + '|' + (d.preset||'managed') + '|' + (d.cdpEndpoint||'') + '\n');
    });
  " 2>/dev/null | while IFS='|' read -r id preset cdp; do
    if [[ -n "$cdp" ]]; then ENDPOINT="$cdp"; else ENDPOINT=$(resolve_cdp_endpoint "$preset"); fi
    ping_driver "$id" "$ENDPOINT"
  done
else
  warn "jq and node not found — skipping driver enumeration; defaulting to managed Playwright"
fi

# ── 6. Cross-origin capability detection ─────────────────────────────────────
API_ORIGIN=$(jq_get '.apiOrigin' '')
if [[ -n "$API_ORIGIN" ]] && [[ "$API_ORIGIN" != "$BASE_URL" ]]; then
  info "Cross-origin API detected: $API_ORIGIN — probing will use session cookies; verify CORS allows credentials"
fi

# ── 7. Build / deploy ID freshness ───────────────────────────────────────────
info "Checking deployed build ID..."
# Try Vercel dpl_ hash in headers or well-known asset.
BUILD_ID=""
BUILD_SOURCE=""

# Vercel: x-vercel-deployment-url or x-deployment-id header.
VERCEL_HDR=$(curl -sI --max-time 8 "$BASE_URL" 2>/dev/null \
  | grep -i 'x-vercel-deployment-id\|x-deployment-id\|x-vercel-id' \
  | head -1 | tr -d '\r' || true)
if [[ -n "$VERCEL_HDR" ]]; then
  BUILD_ID=$(echo "$VERCEL_HDR" | sed 's/.*: *//')
  BUILD_SOURCE="Vercel header"
fi

# Next.js: /_next/static/chunks/main-*.js build hash.
if [[ -z "$BUILD_ID" ]]; then
  NEXT_MANIFEST=$(curl -s --max-time 8 "${BASE_URL}/_next/static/chunks/main-app.js" 2>/dev/null \
    | grep -o '"buildId":"[^"]*"' | head -1 | sed 's/"buildId":"//;s/"//' || true)
  if [[ -n "$NEXT_MANIFEST" ]]; then
    BUILD_ID="$NEXT_MANIFEST"
    BUILD_SOURCE="Next.js buildId"
  fi
fi

# Generic: ETag or Last-Modified.
if [[ -z "$BUILD_ID" ]]; then
  ETAG=$(curl -sI --max-time 8 "$BASE_URL" 2>/dev/null | grep -i '^etag:' | head -1 | tr -d '\r' | sed 's/.*: *//' || true)
  if [[ -n "$ETAG" ]]; then
    BUILD_ID="$ETAG"
    BUILD_SOURCE="ETag"
  fi
fi

if [[ -n "$BUILD_ID" ]]; then
  PREVIOUS_ID_FILE=".qa/runs/.last-build-id"
  if [[ -f "$PREVIOUS_ID_FILE" ]]; then
    PREVIOUS_ID=$(cat "$PREVIOUS_ID_FILE")
    if [[ "$PREVIOUS_ID" == "$BUILD_ID" ]]; then
      warn "Build ID unchanged since last run ($BUILD_ID via $BUILD_SOURCE) — if a fix was expected, it may not be deployed yet"
    else
      info "Build ID changed: $PREVIOUS_ID → $BUILD_ID ($BUILD_SOURCE) — fix appears deployed"
    fi
  else
    info "Build ID: $BUILD_ID ($BUILD_SOURCE) — recorded for next run"
  fi
  mkdir -p .qa/runs
  printf '%s' "$BUILD_ID" > "$PREVIOUS_ID_FILE"
else
  warn "Could not detect build/deploy ID — cannot confirm fix is live"
fi

# ── 8. Final verdict ─────────────────────────────────────────────────────────
info "Pre-flight complete — app is live, drivers enumerated. Proceed with the run."
exit 0
