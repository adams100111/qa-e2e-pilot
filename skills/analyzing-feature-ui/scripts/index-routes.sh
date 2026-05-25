#!/usr/bin/env bash
# index-routes.sh — Static route + interactive-selector indexer for qa-e2e-pilot.
# Reimplemented from opslane/verify patterns (credit: opslane, MIT).
# Emits a compact JSON inventory to stdout.
#
# Usage:
#   bash skills/analyzing-feature-ui/scripts/index-routes.sh [<frontend-path> [<backend-path>]]
#
# Argument resolution order:
#   1. CLI args: $1 = frontend path, $2 = backend path (optional).
#   2. .qa/config.json repos[] filtered by role: frontend / backend.
#   3. Default: current working directory as frontend, no backend.
#
# Requirements: bash >=4, grep, find.
# Optional: jq or node for config parsing.
# Degrades gracefully when optional tools are missing.

set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

die()  { printf '[index-routes] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[index-routes] WARN: %s\n'  "$*" >&2; }
info() { printf '[index-routes] INFO: %s\n'  "$*" >&2; }

# Minimal JSON string escaping (backslash, double-quote, newline, tab).
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ── config resolution ─────────────────────────────────────────────────────────

FRONTEND_PATH=""
BACKEND_PATH=""
CONFIG_FILE=".qa/config.json"

resolve_from_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  if command -v jq &>/dev/null; then
    FRONTEND_PATH=$(jq -r '.repos[]? | select(.role=="frontend") | .path' \
                    "$CONFIG_FILE" 2>/dev/null | head -1 || true)
    BACKEND_PATH=$(jq -r '.repos[]? | select(.role=="backend") | .path' \
                   "$CONFIG_FILE" 2>/dev/null | head -1 || true)
  elif command -v node &>/dev/null; then
    FRONTEND_PATH=$(node -e \
      'const c=JSON.parse(require("fs").readFileSync(process.env.QA_CFG,"utf8"));
       const r=(c.repos||[]).find(x=>x.role==="frontend");
       process.stdout.write(r?r.path:"")' \
      QA_CFG="$CONFIG_FILE" 2>/dev/null || true)
    BACKEND_PATH=$(node -e \
      'const c=JSON.parse(require("fs").readFileSync(process.env.QA_CFG,"utf8"));
       const r=(c.repos||[]).find(x=>x.role==="backend");
       process.stdout.write(r?r.path:"")' \
      QA_CFG="$CONFIG_FILE" 2>/dev/null || true)
  else
    # grep/sed fallback — naive, best-effort
    FRONTEND_PATH=$(grep -A2 '"frontend"' "$CONFIG_FILE" 2>/dev/null \
                    | grep '"path"' | head -1 \
                    | sed 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
    BACKEND_PATH=$(grep -A2 '"backend"' "$CONFIG_FILE" 2>/dev/null \
                   | grep '"path"' | head -1 \
                   | sed 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
  fi
}

if [[ $# -ge 1 ]]; then
  FRONTEND_PATH="$1"
  [[ $# -ge 2 ]] && BACKEND_PATH="$2"
else
  resolve_from_config
fi

[[ -z "$FRONTEND_PATH" ]] && FRONTEND_PATH="."
# Ensure BACKEND_PATH is always set (may be empty string)
BACKEND_PATH="${BACKEND_PATH:-}"

[[ -d "$FRONTEND_PATH" ]] || die "Frontend path not a directory: $FRONTEND_PATH"
if [[ -n "$BACKEND_PATH" && ! -d "$BACKEND_PATH" ]]; then
  warn "Backend path not a directory: $BACKEND_PATH — skipping backend scan"
  BACKEND_PATH=""
fi

info "Frontend: $FRONTEND_PATH"
if [[ -n "$BACKEND_PATH" ]]; then
  info "Backend:  $BACKEND_PATH"
else
  info "Backend:  (none)"
fi

# ── framework detection ───────────────────────────────────────────────────────

FW="generic"
if [[ -f "$FRONTEND_PATH/next.config.js" || -f "$FRONTEND_PATH/next.config.ts" \
   || -f "$FRONTEND_PATH/next.config.mjs" ]]; then
  FW="nextjs"
else
  # Check for react-router usage anywhere in src
  if find "$FRONTEND_PATH/src" "$FRONTEND_PATH" -maxdepth 3 \
       \( -name "*.tsx" -o -name "*.jsx" \) 2>/dev/null \
     | xargs grep -l 'react-router\|createBrowserRouter\|BrowserRouter' 2>/dev/null \
     | grep -q .; then
    FW="react-router"
  fi
fi
info "Framework detected: $FW"

# ── frontend: route collection ────────────────────────────────────────────────

ROUTES_JSON=""

# Next.js app-dir: collect page.tsx / page.jsx files
collect_nextjs_app_dir() {
  local app_dir="$1"
  local entries=""
  while IFS= read -r file; do
    local rel="${file#"$app_dir"}"
    rel="${rel%/page.*}"
    # Replace [...slug] with * and [param] with :param
    rel=$(printf '%s' "$rel" | sed 's|\[\.\.\..*\]|*|g; s|\[\([^]]*\)\]|:\1|g')
    [[ -z "$rel" ]] && rel="/"
    entries="${entries}{\"route\":\"$(json_str "$rel")\",\"source\":\"$(json_str "$file")\",\"kind\":\"nextjs-app\"},"
  done < <(find "$app_dir" \( -name "page.tsx" -o -name "page.jsx" -o -name "page.js" \) \
           2>/dev/null | sort)
  printf '%s' "${entries%,}"
}

# Next.js pages-dir: collect tsx/jsx/js files
collect_nextjs_pages_dir() {
  local pages_dir="$1"
  local entries=""
  while IFS= read -r file; do
    local rel="${file#"$pages_dir"}"
    rel="${rel%.tsx}"; rel="${rel%.jsx}"; rel="${rel%.js}"
    rel=$(printf '%s' "$rel" | sed 's|\[\.\.\..*\]|*|g; s|\[\([^]]*\)\]|:\1|g')
    [[ "$rel" == "/index" ]] && rel="/"
    rel="${rel%/index}"
    [[ -z "$rel" ]] && rel="/"
    entries="${entries}{\"route\":\"$(json_str "$rel")\",\"source\":\"$(json_str "$file")\",\"kind\":\"nextjs-pages\"},"
  done < <(find "$pages_dir" \( -name "*.tsx" -o -name "*.jsx" -o -name "*.js" \) \
           2>/dev/null | grep -v '__' | grep -v 'api/' | sort)
  printf '%s' "${entries%,}"
}

collect_nextjs_routes() {
  local entries=""
  local app_entries=""
  local pages_entries=""
  for d in "$FRONTEND_PATH/app" "$FRONTEND_PATH/src/app"; do
    if [[ -d "$d" ]]; then
      app_entries=$(collect_nextjs_app_dir "$d")
      break
    fi
  done
  for d in "$FRONTEND_PATH/pages" "$FRONTEND_PATH/src/pages"; do
    if [[ -d "$d" ]]; then
      pages_entries=$(collect_nextjs_pages_dir "$d")
      break
    fi
  done
  # Combine, stripping trailing commas before joining
  if [[ -n "$app_entries" && -n "$pages_entries" ]]; then
    entries="${app_entries},${pages_entries}"
  else
    entries="${app_entries}${pages_entries}"
  fi
  ROUTES_JSON="$entries"
}

collect_react_router_routes() {
  local entries=""
  local PATT='path='
  while IFS= read -r line; do
    local fpath="${line%%:*}"
    local content="${line#*:*:}"
    # Extract path value — single-quoted or double-quoted
    local rpath
    rpath=$(printf '%s' "$content" | grep -oP "(?<=path=')[^']+" | head -1 || true)
    if [[ -z "$rpath" ]]; then
      rpath=$(printf '%s' "$content" | grep -oP '(?<=path=")[^"]+' | head -1 || true)
    fi
    [[ -z "$rpath" ]] && continue
    entries="${entries}{\"route\":\"$(json_str "$rpath")\",\"source\":\"$(json_str "$fpath")\",\"kind\":\"react-router\"},"
  done < <(grep -rn --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
             "$PATT" \
             "$FRONTEND_PATH/src" "$FRONTEND_PATH/app" "$FRONTEND_PATH/pages" \
             "$FRONTEND_PATH/routes" "$FRONTEND_PATH/router" \
             2>/dev/null | grep -v 'node_modules' | head -200 || true)
  ROUTES_JSON="${entries%,}"
}

collect_generic_routes() {
  local entries=""
  while IFS= read -r line; do
    local fpath="${line%%:*}"
    local content="${line#*:*:}"
    local rpath
    # Try href= single-quoted, then double-quoted, then to= variants
    rpath=$(printf '%s' "$content" | grep -oP "(?<=href=')[^'?#]+" | head -1 || true)
    if [[ -z "$rpath" ]]; then
      rpath=$(printf '%s' "$content" | grep -oP '(?<=href=")[^"?#]+' | head -1 || true)
    fi
    if [[ -z "$rpath" ]]; then
      rpath=$(printf '%s' "$content" | grep -oP "(?<= to=')[^'?#]+" | head -1 || true)
    fi
    if [[ -z "$rpath" ]]; then
      rpath=$(printf '%s' "$content" | grep -oP '(?<= to=")[^"?#]+' | head -1 || true)
    fi
    [[ -z "$rpath" || "${rpath:0:1}" != "/" ]] && continue
    entries="${entries}{\"route\":\"$(json_str "$rpath")\",\"source\":\"$(json_str "$fpath")\",\"kind\":\"href\"},"
  done < <(grep -rn --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
             -E 'href=|[^a-z]to=' \
             "$FRONTEND_PATH/src" "$FRONTEND_PATH/app" "$FRONTEND_PATH/pages" \
             "$FRONTEND_PATH" \
             2>/dev/null | grep -v 'node_modules' | grep -v '\.test\.' | head -400 || true)
  ROUTES_JSON="${entries%,}"
}

case "$FW" in
  nextjs)       collect_nextjs_routes ;;
  react-router) collect_react_router_routes ;;
  *)            collect_generic_routes ;;
esac

# ── frontend: interactive selector scan ──────────────────────────────────────

SELECTORS_JSON=""
collect_selectors() {
  local entries=""
  while IFS= read -r line; do
    local fpath="${line%%:*}"
    local content="${line#*:*:}"
    local label role
    label=$(printf '%s' "$content" | grep -oP '(?<=aria-label=")[^"]+' | head -1 || true)
    if [[ -z "$label" ]]; then
      label=$(printf '%s' "$content" | grep -oP '(?<=aria-label='\'')[^'\'']+' | head -1 || true)
    fi
    if [[ -z "$label" ]]; then
      label=$(printf '%s' "$content" | grep -oP '(?<=>)[A-Z][a-zA-Z0-9 ]{2,40}(?=</)' | head -1 || true)
    fi
    [[ -z "$label" ]] && continue
    role="interactive"
    printf '%s' "$content" | grep -qi '<button'  && role="button"
    printf '%s' "$content" | grep -qi '<a '      && role="link"
    printf '%s' "$content" | grep -qi '<input\|<select\|<textarea' && role="field"
    printf '%s' "$content" | grep -qi 'Dialog\|Modal\|Sheet\|Drawer' && role="dialog-trigger"
    entries="${entries}{\"label\":\"$(json_str "$label")\",\"role\":\"$role\",\"source\":\"$(json_str "$fpath")\"},"
  done < <(grep -rn --include="*.tsx" --include="*.jsx" \
             -E '<button|<a |aria-label=|<input|<select|Dialog|Modal|Sheet' \
             "$FRONTEND_PATH/src" "$FRONTEND_PATH/app" \
             2>/dev/null | grep -v 'node_modules' | grep -v '\.test\.' | head -300 || true)
  SELECTORS_JSON="${entries%,}"
}
collect_selectors

# ── backend: endpoint scan ────────────────────────────────────────────────────

ENDPOINTS_JSON=""

collect_backend_endpoints() {
  local entries=""
  local bpath="$1"

  # Laravel/PHP: Route::get/post/put/delete/patch/apiResource
  if find "$bpath/routes" -name "*.php" 2>/dev/null | grep -q .; then
    while IFS= read -r line; do
      local fpath="${line%%:*}"
      local content="${line#*:*:}"
      local method rpath
      method=$(printf '%s' "$content" \
               | grep -oiP 'Route::\K(get|post|put|patch|delete|apiResource)' \
               | head -1 || true)
      # Extract first single-quoted string value (the route path)
      rpath=$(printf '%s' "$content" | grep -oP "(?<=')[^']+" | head -1 || true)
      [[ -z "$method" || -z "$rpath" ]] && continue
      method="${method^^}"
      entries="${entries}{\"method\":\"$(json_str "$method")\",\"path\":\"$(json_str "$rpath")\",\"source\":\"$(json_str "$fpath")\",\"lang\":\"laravel\"},"
    done < <(grep -rn --include="*.php" \
               -E 'Route::(get|post|put|patch|delete|apiResource)' \
               "$bpath/routes" 2>/dev/null | head -200 || true)
  fi

  # Express/Node: app.get/post ... or router.get/post ...
  local node_dirs=()
  for nd in "$bpath/src" "$bpath/routes" "$bpath/api"; do
    [[ -d "$nd" ]] && node_dirs+=("$nd")
  done
  if [[ ${#node_dirs[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      local fpath="${line%%:*}"
      local content="${line#*:*:}"
      local method rpath
      method=$(printf '%s' "$content" \
               | grep -oP '(?:app|router)\.\K(get|post|put|patch|delete)' \
               | head -1 || true)
      rpath=$(printf '%s' "$content" | grep -oP "(?<=')[^'()]+" | head -1 || true)
      [[ -z "$method" || -z "$rpath" ]] && continue
      method="${method^^}"
      entries="${entries}{\"method\":\"$(json_str "$method")\",\"path\":\"$(json_str "$rpath")\",\"source\":\"$(json_str "$fpath")\",\"lang\":\"express\"},"
    done < <(grep -rn --include="*.ts" --include="*.js" \
               -E '\.(get|post|put|patch|delete)\(' \
               "${node_dirs[@]}" 2>/dev/null \
             | grep -v 'node_modules' | grep -v '\.test\.' | head -200 || true)
  fi

  # tRPC: publicProcedure / protectedProcedure declarations
  if [[ -d "$bpath/src" ]] && \
     find "$bpath/src" -name "*.ts" 2>/dev/null \
       | xargs grep -l 'procedure\.' 2>/dev/null | grep -q .; then
    while IFS= read -r line; do
      local fpath="${line%%:*}"
      local content="${line#*:*:}"
      local proc kind
      proc=$(printf '%s' "$content" \
             | grep -oP '\w+(?=:\s*(?:t\.)?(?:publicProcedure|protectedProcedure|procedure))' \
             | head -1 || true)
      [[ -z "$proc" ]] && continue
      kind="query"
      printf '%s' "$content" | grep -q '\.mutation' && kind="mutation"
      entries="${entries}{\"method\":\"tRPC:$(json_str "$kind")\",\"path\":\"$(json_str "$proc")\",\"source\":\"$(json_str "$fpath")\",\"lang\":\"trpc\"},"
    done < <(grep -rn --include="*.ts" \
               -E 'publicProcedure|protectedProcedure' \
               "$bpath/src" 2>/dev/null \
             | grep -v 'node_modules' | grep -v '\.test\.' | head -200 || true)
  fi

  ENDPOINTS_JSON="${entries%,}"
}

if [[ -n "$BACKEND_PATH" ]]; then
  collect_backend_endpoints "$BACKEND_PATH"
fi

# ── assemble JSON output ──────────────────────────────────────────────────────

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
BE_PATH_SAFE=$(json_str "$BACKEND_PATH")
FE_PATH_SAFE=$(json_str "$FRONTEND_PATH")
FW_SAFE=$(json_str "$FW")
TS_SAFE=$(json_str "$TIMESTAMP")

printf '{\n'
printf '  "generatedAt": "%s",\n' "$TS_SAFE"
printf '  "frontend": {\n'
printf '    "path": "%s",\n' "$FE_PATH_SAFE"
printf '    "framework": "%s",\n' "$FW_SAFE"
printf '    "routes": [%s],\n' "$ROUTES_JSON"
printf '    "selectors": [%s]\n' "$SELECTORS_JSON"
printf '  },\n'
printf '  "backend": {\n'
printf '    "path": "%s",\n' "$BE_PATH_SAFE"
printf '    "endpoints": [%s]\n' "$ENDPOINTS_JSON"
printf '  }\n'
printf '}\n'
