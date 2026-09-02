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

# ── i18n mechanism map (data-driven) ──────────────────────────────────────────
# Locate WHERE translations live so a later localization phase can resolve a
# rendered string → key → catalog entry. Read-only filesystem scan whose roots,
# library packages, and mechanism come from stack-signatures.json (.stacks[].i18n
# + ._fallback.i18n) — the engine holds only the generic procedure. LOCATES only,
# never judges. Degrades to a present:false / signal:weak map with a distinct
# reason; never hard-fails. jq is guaranteed here (callers run after the have-jq
# guards). NOTE: LOCALE_RE is used UNQUOTED in [[ =~ ]] (quoting makes it literal).
LOCALE_RE='^[a-z]{2}([-_][A-Za-z]{2,4})?$'

i18n_absent() {  # $1 = reason
  jq -n --arg r "${1:-no i18n catalog directory found}" \
    '{present:false, libraries:[], mechanisms:[], catalogs:[], locales:[], signal:"weak", evidence:[$r]}'
}

manifest_path() {  # <repo> <manifest-glob-or-name>  → echoes the matched file or nothing
  local repo="$1" manifest="$2"
  if [[ "$manifest" == \** ]]; then
    find "$repo" -maxdepth 2 -name "$manifest" 2>/dev/null | head -1
  elif [[ -f "$repo/$manifest" ]]; then
    printf '%s' "$repo/$manifest"
  fi
}

# detect_i18n <repo>  → echoes the i18n map JSON, unioned across EVERY signature
# actually present in the repo (manifest + package match), so a fullstack repo
# reports both mechanisms and both libraries; each catalog is tagged with its
# row's mechanism, and each path points at the real file (with namespace).
detect_i18n() {
  local repo="$1"
  [[ -d "$repo" ]] || { i18n_absent "no repo path to scan"; return 0; }
  local n; n="$(jq '.stacks | length' "$SIGNATURES")"
  local cats="[]" libs="[]" locset="" rootseen=0 i
  for i in $(seq 0 $((n-1))); do
    jq -e ".stacks[$i].i18n" "$SIGNATURES" >/dev/null 2>&1 || continue
    local manifest mfile mech
    manifest="$(jq -r ".stacks[$i].manifest" "$SIGNATURES")"
    mfile="$(manifest_path "$repo" "$manifest")"
    [[ -n "$mfile" ]] || continue
    # same gate as detect_code_component: require a package signature in the manifest,
    # so a bare package.json does not fire every JS stack's i18n rows.
    local pkgmatch=0 p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      grep -q -- "$p" "$mfile" 2>/dev/null && pkgmatch=1
    done < <(jq -r ".stacks[$i].packages[]?" "$SIGNATURES")
    [[ "$pkgmatch" -eq 1 ]] || continue
    mech="$(jq -r ".stacks[$i].i18n.mechanism" "$SIGNATURES")"
    # i18n library packages from THIS manifest
    local L
    while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      if grep -q -- "\"$L\"" "$mfile" 2>/dev/null; then
        libs="$(jq -c --arg l "$L" 'if index($l) then . else . + [$l] end' <<< "$libs")"
      fi
    done < <(jq -r ".stacks[$i].i18n.libraryPackages[]?" "$SIGNATURES")
    # catalog scan across THIS stack's declared roots
    local root
    while IFS= read -r root; do
      [[ -z "$root" ]] && continue
      local dir="$repo/$root"
      [[ -d "$dir" ]] || continue
      rootseen=1
      # per-locale subdirectories: one catalog entry PER FILE (php or json), namespace=file stem
      local sub loc
      while IFS= read -r sub; do
        [[ -n "$sub" ]] || continue
        loc="$(basename "$sub")"
        [[ "$loc" =~ $LOCALE_RE ]] || continue
        local f fmt ns
        while IFS= read -r f; do
          [[ -n "$f" ]] || continue
          case "$f" in *.php) fmt="php" ;; *.json) fmt="json" ;; *) continue ;; esac
          ns="$(basename "$f")"; ns="${ns%.*}"
          cats="$(jq -c --arg r "$root" --arg l "$loc" --arg f "$fmt" --arg m "$mech" \
                     --arg p "$root/$loc/$(basename "$f")" --arg ns "$ns" \
            '. + [{root:$r, locale:$l, format:$f, mechanism:$m, path:$p, namespace:$ns}]' <<< "$cats")"
          locset="$locset $loc"
        done < <(find "$sub" -maxdepth 1 -type f \( -name '*.php' -o -name '*.json' \) 2>/dev/null | sort)
      done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
      # flat per-locale JSON files (Laravel lang/<locale>.json); namespace null
      local jf base
      while IFS= read -r jf; do
        [[ -n "$jf" ]] || continue
        base="$(basename "$jf" .json)"
        [[ "$base" =~ $LOCALE_RE ]] || continue
        cats="$(jq -c --arg r "$root" --arg l "$base" --arg m "$mech" --arg p "$root/$base.json" \
          '. + [{root:$r, locale:$l, format:"json", mechanism:$m, path:$p, namespace:null}]' <<< "$cats")"
        locset="$locset $base"
      done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
    done < <(jq -r ".stacks[$i].i18n.roots[]?" "$SIGNATURES")
  done
  if [[ "$cats" == "[]" ]]; then
    if [[ "$rootseen" -eq 1 ]]; then
      i18n_absent "i18n catalog directory present but no locale-named php/json catalog found (e.g. unsupported yml/po, or non-locale filenames)"
    else
      i18n_absent "no i18n catalog directory found"
    fi
    return 0
  fi
  cats="$(jq -c 'unique' <<< "$cats")"   # dedup when two rows share a root (e.g. next + react-router both declare "locales")
  local locs mechs evid
  locs="$(printf '%s\n' $locset | sort -u | grep -v '^$' | jq -R . | jq -sc .)"
  mechs="$(jq -c '[.[].mechanism] | unique' <<< "$cats")"
  evid="$(jq -c '[.[] | "code: " + .path] | unique' <<< "$cats")"
  jq -n --argjson cats "$cats" --argjson locs "$locs" --argjson libs "$libs" \
        --argjson mechs "$mechs" --argjson evid "$evid" \
    '{present:true, libraries:$libs, mechanisms:$mechs, catalogs:$cats, locales:$locs, signal:"strong", evidence:$evid}'
}

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
    local i18n_json; i18n_json="$(detect_i18n "$repo")"
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg repo "$repo" --arg fr "$fr" --arg ev "code: $mfile ($id)" \
          --argjson i18n "$i18n_json" '{
      role: $row.role, path: $repo, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $fr },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook, i18n: $i18n,
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
          --arg ev "runtime: header/cookie match" \
          --argjson i18n "$(i18n_absent "runtime-only component — no repo scanned")" '{
      role: $row.role, path: null, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $row.frontendRouting },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook, i18n: $i18n,
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
    fb="$(jq -n --argjson row "$(jq '._fallback' "$SIGNATURES")" \
              --argjson i18n "$(i18n_absent "no i18n catalog directory found")" '{
      role:$row.role, path:null, language:$row.language, languageVersion:"",
      framework:"generic", frameworkVersion:"", packages:[],
      router:$row.router, frontend:{routing:$row.frontendRouting},
      orm:$row.orm, auth:$row.auth, commands:$row.commands,
      buildIdSource:"none", playbook:$row.playbook, i18n:$i18n, signal:"weak", evidence:["fallback"], drift:[] }')"
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
