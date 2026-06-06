#!/usr/bin/env bash
# detect-stack.sh — dual-source stack detector for qa-e2e-pilot.
# Emits stack-profile.json (schema: docs/superpowers/specs/2026-06-06-stack-auto-detection-design.md).
# Sources: runtime fingerprint (read-only GETs to baseUrl) + code-based (local manifests),
# merged with a defined precedence. Deps: jq preferred (python3 fallback for config reads),
# curl for live runtime. Degrades gracefully — never hard-fails.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGNATURES="${QA_SIGNATURES:-$SELF_DIR/../references/stack-signatures.json}"
CONFIG_FILE="${QA_CONFIG:-.qa/config.json}"
OUT=""; NO_RUNTIME=0; NO_CODE=0
BASE_URL="${QA_BASE_URL:-}"; REPOS="${QA_REPOS:-}"; HEADERS_FILE="${QA_HEADERS_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --base-url)     BASE_URL="$2"; shift 2 ;;
    --repos)        REPOS="$2"; shift 2 ;;
    --headers-file) HEADERS_FILE="$2"; shift 2 ;;
    --no-runtime)   NO_RUNTIME=1; shift ;;
    --no-code)      NO_CODE=1; shift ;;
    *) echo "detect-stack: unknown arg: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
emit() { if [[ -n "$OUT" ]]; then cat > "$OUT"; else cat; fi; }

# Read a top-level/nested value from config when not overridden by env/args.
cfg() { # jq-filter default
  local f="$1" d="${2:-}"
  [[ -f "$CONFIG_FILE" ]] || { printf '%s' "$d"; return; }
  if have jq; then
    local v; v="$(jq -r "$f // empty" "$CONFIG_FILE" 2>/dev/null)"
    printf '%s' "${v:-$d}"
  else
    python3 - "$CONFIG_FILE" "$f" "$d" <<'PY'
import json,sys
try:
  c=json.load(open(sys.argv[1])); ks=[k for k in sys.argv[2].lstrip('.').split('.') if k]
  for k in ks: c=c[k] if isinstance(c,dict) else None
  print(c if c not in (None,) else sys.argv[3])
except Exception: print(sys.argv[3])
PY
  fi
}

[[ -z "$BASE_URL" ]] && BASE_URL="$(cfg '.baseUrl' '')"
if [[ -z "$REPOS" && -f "$CONFIG_FILE" ]] && have jq; then
  REPOS="$(jq -r '.repos[]?.path' "$CONFIG_FILE" 2>/dev/null | paste -sd, -)"
fi

# ── code-based detection ──────────────────────────────────────────────────────
# Detect one repo path against signatures. Echoes a JSON component or nothing.
detect_code_component() {
  local repo="$1"
  [[ -d "$repo" ]] || return 0
  have jq || return 0
  local n; n="$(jq '.stacks | length' "$SIGNATURES")"
  local i
  for i in $(seq 0 $((n-1))); do
    local id manifest
    id="$(jq -r ".stacks[$i].id" "$SIGNATURES")"
    manifest="$(jq -r ".stacks[$i].manifest" "$SIGNATURES")"
    local mfile=""
    if [[ "$manifest" == \** ]]; then
      mfile="$(find "$repo" -maxdepth 2 -name "$manifest" 2>/dev/null | head -1)"
    elif [[ -f "$repo/$manifest" ]]; then
      mfile="$repo/$manifest"
    fi
    [[ -n "$mfile" ]] || continue
    local match=0 p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      grep -q -- "$p" "$mfile" 2>/dev/null && match=1
    done < <(jq -r ".stacks[$i].packages[]?" "$SIGNATURES")
    [[ "$match" -eq 1 ]] || continue
    local fr; fr="$(jq -r ".stacks[$i].frontendRouting" "$SIGNATURES")"
    local imp ipkg ifr
    while IFS= read -r imp; do
      [[ -z "$imp" ]] && continue
      ipkg="$(jq -r '.package // empty' <<< "$imp")"
      ifr="$(jq -r '.frontendRouting // empty' <<< "$imp")"
      if [[ -n "$ipkg" ]] && grep -q -- "$ipkg" "$mfile" 2>/dev/null && [[ -n "$ifr" ]]; then
        fr="$ifr"
      fi
    done < <(jq -c ".stacks[$i].implies[]?" "$SIGNATURES")
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg repo "$repo" --arg fr "$fr" --arg ev "code: $mfile ($id)" '{
      role: $row.role, path: $repo, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $fr },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook,
      signal: "strong", evidence: [$ev], drift: [] }'
    return 0
  done
}

# ── runtime fingerprint detection ─────────────────────────────────────────────
fetch_headers() {
  if [[ -n "$HEADERS_FILE" ]]; then cat "$HEADERS_FILE" 2>/dev/null; return; fi
  [[ -n "$BASE_URL" ]] && have curl || return 0
  curl -sI --max-time 8 "$BASE_URL" 2>/dev/null || true
}

# Match captured headers against signature runtime cookies/headers. Echoes a component or nothing.
detect_runtime_component() {
  local hdr; hdr="$(fetch_headers)"
  [[ -n "$hdr" ]] || return 0
  have jq || return 0
  local n; n="$(jq '.stacks | length' "$SIGNATURES")"
  local i
  for i in $(seq 0 $((n-1))); do
    local matched=0 c h
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      grep -qi "$c" <<< "$hdr" && matched=1
    done < <(jq -r ".stacks[$i].runtime.cookies[]?" "$SIGNATURES")
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      grep -qi "$h" <<< "$hdr" && matched=1
    done < <(jq -r ".stacks[$i].runtime.headers | to_entries[]? | .key" "$SIGNATURES")
    [[ "$matched" -eq 1 ]] || continue
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg ev "runtime: header/cookie match" '{
      role: $row.role, path: null, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $row.frontendRouting },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook,
      signal: "weak", evidence: [$ev], drift: [] }'
    return 0
  done
}

# ── assemble ──────────────────────────────────────────────────────────────────
main() {
  have jq || { echo '{"error":"jq required for detection"}' | emit; return 0; }
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local comps="[]"

  if [[ "$NO_CODE" -eq 0 && -n "$REPOS" ]]; then
    IFS=',' read -ra paths <<< "$REPOS"
    local rp c
    for rp in "${paths[@]}"; do
      [[ -z "$rp" ]] && continue
      c="$(detect_code_component "$rp")"
      [[ -n "$c" ]] && comps="$(jq -c ". + [$c]" <<< "$comps")"
    done
  fi

  if [[ "$NO_RUNTIME" -eq 0 ]]; then
    local rc rfw
    rc="$(detect_runtime_component)"
    if [[ -n "$rc" ]]; then
      rfw="$(jq -r '.framework' <<< "$rc")"
      if ! jq -e --arg f "$rfw" 'any(.[]; .framework == $f)' <<< "$comps" >/dev/null; then
        comps="$(jq -c ". + [$rc]" <<< "$comps")"
      else
        comps="$(jq -c --arg f "$rfw" 'map(if .framework==$f then .evidence += ["runtime: corroborated"] else . end)' <<< "$comps")"
      fi
    fi
  fi

  if [[ "$comps" == "[]" ]]; then
    local fb
    fb="$(jq -n --argjson row "$(jq '._fallback' "$SIGNATURES")" '{
      role:$row.role, path:null, language:$row.language, languageVersion:"",
      framework:"generic", frameworkVersion:"", packages:[],
      router:$row.router, frontend:{routing:$row.frontendRouting},
      orm:$row.orm, auth:$row.auth, commands:$row.commands,
      buildIdSource:"none", playbook:$row.playbook, signal:"weak", evidence:["fallback"], drift:[] }')"
    comps="$(jq -c ". + [$fb]" <<< "$comps")"
  fi

  # mode: code present and not forced black-box → local-matched; else black-box.
  local mode="black-box"
  if [[ "$NO_CODE" -eq 0 ]] && jq -e 'any(.[]; .path != null)' <<< "$comps" >/dev/null; then
    mode="local-matched"
  fi

  # environment: explicit config override (disposable|production) wins; "auto"
  # (or unset) infers production from a non-localhost baseUrl with no seed marker.
  local env_cfg; env_cfg="$(cfg '.environment' 'auto')"
  local env="disposable"
  if [[ "$env_cfg" == "production" || "$env_cfg" == "disposable" ]]; then
    env="$env_cfg"
  elif [[ -n "$BASE_URL" ]]; then
    case "$BASE_URL" in
      *localhost*|*127.0.0.1*|*.ddev.site*) env="disposable" ;;
      *) [[ -z "$(cfg '.seedableEnvMarker' '')" ]] && env="production" ;;
    esac
  fi

  # primary indices.
  local pb pf
  pb="$(jq -c '(map(.role) | (index("backend") // index("fullstack"))) // (if length>0 then 0 else null end)' <<< "$comps")"
  pf="$(jq -c '(map(.role) | index("frontend")) // (if length>0 then 0 else null end)' <<< "$comps")"

  local repoRoot="null"
  [[ "$mode" == "local-matched" ]] && repoRoot="$(jq -c '[.[] | .path] | map(select(. != null)) | (.[0] // null)' <<< "$comps")"

  # Production guardrails (ADR / design): writes hard-off, write-confirm required,
  # black-box crawl off unless explicitly allowed in config.
  local notes="[]" guardrails="null"
  if [[ "$env" == "production" ]]; then
    notes='["allowApiWrites forced off (production)","recommend a dedicated test account/tenant"]'
    local crawl="false"
    [[ "$(cfg '.allowBlackboxCrawl' 'false')" == "true" ]] && crawl="true"
    guardrails="$(jq -n --argjson crawl "$crawl" '{allowApiWrites:false, requireWriteConfirm:true, blackboxCrawl:$crawl}')"
  fi

  jq -n --arg ts "$ts" --arg mode "$mode" --arg env "$env" \
        --argjson comps "$comps" --argjson pb "$pb" --argjson pf "$pf" --argjson root "$repoRoot" \
        --argjson notes "$notes" --argjson guardrails "$guardrails" '{
    generatedAt:$ts, mode:$mode, environment:$env, repoRoot:$root,
    components:$comps, primary:{ backend:$pb, frontend:$pf },
    guardrails:$guardrails, notes:$notes }' | emit
}

main
