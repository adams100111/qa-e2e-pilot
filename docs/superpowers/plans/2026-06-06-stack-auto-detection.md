# Stack Auto-Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dual-source (runtime fingerprint + code-based) stack detector that emits a reviewable `stack-profile.json`, then make the analyze/bake/probe/preflight/report phases adapt to it — for any stack, against local dev or production.

**Architecture:** A new `detecting-stack-profile` skill owns detection: a generic engine (`detect-stack.sh`) reads a Wappalyzer-style data file (`stack-signatures.json`) plus local manifests, merges runtime+code facts, and writes `stack-profile.json`. Per-stack markdown playbooks are executable recipes the agent walks. Existing skills are rewired to consume the profile; `index-routes.sh` loses its framework guessing and becomes a profile-driven static-parse rung.

**Tech Stack:** Bash (jq→python3 fallback, matching existing scripts), JSON data files, markdown skills, the Playwright MCP for live signals.

---

## File Structure

**New (Slice A):**
- `skills/detecting-stack-profile/SKILL.md` — the detection recipe + mini-evals.
- `skills/detecting-stack-profile/scripts/detect-stack.sh` — engine: dual-source detect + merge → `stack-profile.json`.
- `skills/detecting-stack-profile/references/stack-signatures.json` — DATA: Wappalyzer-style runtime patterns + manifest/package signatures per stack.
- `tests/detect-stack/` — fixtures + a bash test runner.
- `docs/adr/0005-stack-profile-cache.md` — run-dir authoritative + revalidated cache.

**New (Slice B):**
- `skills/detecting-stack-profile/references/playbooks/laravel.md`
- `skills/detecting-stack-profile/references/playbooks/openapi-generic.md`
- `skills/detecting-stack-profile/references/playbooks/generic.md`

**Modified (Slice B):**
- `skills/analyzing-feature-ui/scripts/index-routes.sh` — strip framework detection; consume `router.strategy`/`frontend.routing`.
- `skills/analyzing-feature-ui/SKILL.md` — invoke detection first; dispatch frontend enumeration.
- `skills/verifying-backend-persistence/SKILL.md` — read `orm.*` from profile.
- `skills/probing-apis-through-browser/SKILL.md` — read `auth.*` from profile.
- `agents/qa-e2e-pilot.md` — add detection as first action of Analyze; reference profile in later phases.
- `skills/writing-qa-reports/SKILL.md` + `templates/report.md` — surface tier/`signal`/drift.
- `CONTEXT.md` — add vocab (`stack-profile`, `playbook`, `signal`, `runtime fingerprint`).

**Modified (Slice C):**
- `skills/driving-browser-qa/scripts/preflight.sh` — build-match check, prod warning, cache revalidation hook.
- `skills/detecting-stack-profile/scripts/detect-stack.sh` — prod-mode guardrails, fingerprint throttling.
- `.qa/config.json.example` — `environment`, `allowBlackboxCrawl`, `fingerprintPaths`, `crawlDenyPatterns`, `maxRequestsPerSecond`.

---

# SLICE A — Detection only (zero behavior change)

Nothing consumes the profile yet, so this slice cannot break verify. It ends as a standalone, safely mergeable PR.

### Task A1: Test harness + first fixture (Laravel)

**Files:**
- Create: `tests/detect-stack/run.sh`
- Create: `tests/detect-stack/fixtures/laravel/composer.json`
- Create: `tests/detect-stack/fixtures/laravel/artisan`

- [ ] **Step 1: Write the failing test runner**

`tests/detect-stack/run.sh`:
```bash
#!/usr/bin/env bash
# Smoke tests for detect-stack.sh. Each case: run the engine against a fixture
# (and/or a fake baseUrl) and assert fields in the emitted stack-profile.json.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../../skills/detecting-stack-profile/scripts/detect-stack.sh"
FIX="$HERE/fixtures"
PASS=0; FAIL=0
get() { jq -r "$2" "$1"; }
check() { # desc, actual, expected
  if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1));
  else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi
}

# Case 1: Laravel fixture, code-based only (no baseUrl)
OUT="$(mktemp)"
QA_REPOS="$FIX/laravel" bash "$ENGINE" --no-runtime --out "$OUT" >/dev/null 2>&1
check "laravel framework"   "$(get "$OUT" '.components[0].framework')"          "laravel"
check "laravel playbook"    "$(get "$OUT" '.components[0].playbook')"           "laravel"
check "laravel orm"         "$(get "$OUT" '.components[0].orm.name')"           "eloquent"
check "laravel frontend"    "$(get "$OUT" '.components[0].frontend.routing')"   "server-bridge"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

`tests/detect-stack/fixtures/laravel/composer.json`:
```json
{ "require": { "php": "^8.4", "laravel/framework": "^12.0", "inertiajs/inertia-laravel": "^2.0" } }
```

`tests/detect-stack/fixtures/laravel/artisan`:
```
#!/usr/bin/env php
<?php // fixture marker
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/detect-stack/run.sh`
Expected: FAIL (engine does not exist yet — every check fails / script errors).

- [ ] **Step 3: Commit the failing harness**

```bash
git add tests/detect-stack
git commit -m "test: stack detector harness + laravel fixture (red)"
```

### Task A2: Engine skeleton — config/args + JSON reader

**Files:**
- Create: `skills/detecting-stack-profile/scripts/detect-stack.sh`

- [ ] **Step 1: Write the engine skeleton**

`skills/detecting-stack-profile/scripts/detect-stack.sh`:
```bash
#!/usr/bin/env bash
# detect-stack.sh — dual-source stack detector for qa-e2e-pilot.
# Emits stack-profile.json (schema: docs/superpowers/specs/2026-06-06-stack-auto-detection-design.md).
# Sources: runtime fingerprint (GETs to baseUrl) + code-based (local manifests).
# Deps: jq preferred, python3 fallback; curl for runtime. Degrades, never hard-fails.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGNATURES="${QA_SIGNATURES:-$SELF_DIR/../references/stack-signatures.json}"
CONFIG_FILE="${QA_CONFIG:-.qa/config.json}"
OUT=""; NO_RUNTIME=0; NO_CODE=0; BASE_URL="${QA_BASE_URL:-}"; REPOS="${QA_REPOS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)        OUT="$2"; shift 2 ;;
    --base-url)   BASE_URL="$2"; shift 2 ;;
    --repos)      REPOS="$2"; shift 2 ;;
    --no-runtime) NO_RUNTIME=1; shift ;;
    --no-code)    NO_CODE=1; shift ;;
    *) echo "detect-stack: unknown arg: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
emit() { if [[ -n "$OUT" ]]; then cat > "$OUT"; else cat; fi; }

# Read a value from config when not overridden by env/args.
cfg() { # jq-filter default
  local f="$1" d="${2:-}"
  [[ -f "$CONFIG_FILE" ]] || { printf '%s' "$d"; return; }
  if have jq; then jq -r "$f // empty" "$CONFIG_FILE" 2>/dev/null || printf '%s' "$d"
  else python3 - "$CONFIG_FILE" "$f" "$d" <<'PY'
import json,sys
try:
  c=json.load(open(sys.argv[1])); ks=sys.argv[2].lstrip('.').split('.')
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

main # defined in later tasks
```

- [ ] **Step 2: Add `main` stub returning an empty-but-valid profile**

Append:
```bash
main() {
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -n --arg ts "$ts" '{generatedAt:$ts, mode:"black-box", environment:"disposable",
    repoRoot:null, components:[], primary:{backend:null,frontend:null}, notes:[]}' | emit
}
```
Move the `main` call to the end of the file (after the function is defined).

- [ ] **Step 3: Run the harness**

Run: `bash tests/detect-stack/run.sh`
Expected: still FAIL on framework checks (components empty) but the script now runs and emits valid JSON.

- [ ] **Step 4: Commit**

```bash
git add skills/detecting-stack-profile/scripts/detect-stack.sh
git commit -m "feat: detect-stack engine skeleton (args, config, empty profile)"
```

### Task A3: `stack-signatures.json` (data) + code-based detection

**Files:**
- Create: `skills/detecting-stack-profile/references/stack-signatures.json`
- Modify: `skills/detecting-stack-profile/scripts/detect-stack.sh`

- [ ] **Step 1: Write the signatures data file**

`skills/detecting-stack-profile/references/stack-signatures.json` (seed rows; extend later). Runtime patterns adopt the Wappalyzer field names (`cookies`/`headers`/`html`/`implies`):
```json
{
  "_credit": "Runtime fingerprint patterns inspired by Wappalyzer (MIT).",
  "stacks": [
    {
      "id": "laravel", "language": "php", "role": "backend",
      "manifest": "composer.json", "packages": ["laravel/framework"],
      "implies": [{ "package": "inertiajs/inertia-laravel", "frontendRouting": "server-bridge" }],
      "runtime": { "cookies": ["laravel_session", "XSRF-TOKEN"], "headers": {} },
      "playbook": "laravel",
      "router": { "strategy": "local-cli", "rung1": "php artisan route:list --json" },
      "frontendRouting": "server-bridge",
      "orm": { "name": "eloquent", "modelsPath": "app/Models", "migrationsPath": "database/migrations" },
      "auth": { "scheme": "session-cookie", "csrf": "laravel-xsrf" },
      "commands": { "dev": "composer dev", "test": "composer test", "build": "npm run build" }
    },
    {
      "id": "django", "language": "python", "role": "backend",
      "manifest": "pyproject.toml", "packages": ["django", "Django"],
      "runtime": { "cookies": ["csrftoken", "sessionid"], "headers": {} },
      "playbook": "openapi-generic",
      "router": { "strategy": "local-cli", "rung1": "python manage.py show_urls" },
      "frontendRouting": "server-bridge",
      "orm": { "name": "django-orm", "modelsPath": ".", "migrationsPath": "migrations" },
      "auth": { "scheme": "session-cookie", "csrf": "django-csrf" },
      "commands": { "dev": "python manage.py runserver", "test": "pytest", "build": "" }
    },
    {
      "id": "fastapi", "language": "python", "role": "backend",
      "manifest": "pyproject.toml", "packages": ["fastapi"],
      "runtime": { "headers": {}, "openapiPaths": ["/openapi.json"] },
      "playbook": "openapi-generic",
      "router": { "strategy": "runtime-openapi", "rung1": "GET /openapi.json" },
      "frontendRouting": "black-box",
      "orm": { "name": "sqlalchemy", "modelsPath": ".", "migrationsPath": "alembic/versions" },
      "auth": { "scheme": "bearer", "csrf": null },
      "commands": { "dev": "uvicorn app:app --reload", "test": "pytest", "build": "" }
    },
    {
      "id": "aspnet", "language": "csharp", "role": "backend",
      "manifest": "*.csproj", "packages": ["Microsoft.AspNetCore"],
      "runtime": { "headers": { "X-Powered-By": "ASP.NET" }, "openapiPaths": ["/swagger/v1/swagger.json"] },
      "playbook": "openapi-generic",
      "router": { "strategy": "runtime-openapi", "rung1": "GET /swagger/v1/swagger.json" },
      "frontendRouting": "black-box",
      "orm": { "name": "ef-core", "modelsPath": ".", "migrationsPath": "Migrations" },
      "auth": { "scheme": "bearer", "csrf": null },
      "commands": { "dev": "dotnet run", "test": "dotnet test", "build": "dotnet build" }
    },
    {
      "id": "express", "language": "javascript", "role": "backend",
      "manifest": "package.json", "packages": ["express"],
      "runtime": { "cookies": ["connect.sid"], "headers": { "X-Powered-By": "Express" } },
      "playbook": "generic",
      "router": { "strategy": "static-parse", "rung1": "grep app.get/post" },
      "frontendRouting": "black-box",
      "orm": { "name": "unknown", "modelsPath": ".", "migrationsPath": "." },
      "auth": { "scheme": "bearer", "csrf": null },
      "commands": { "dev": "npm run dev", "test": "npm test", "build": "npm run build" }
    },
    {
      "id": "hono", "language": "javascript", "role": "backend",
      "manifest": "package.json", "packages": ["hono"],
      "implies": [{ "package": "@hono/zod-openapi", "openapiPaths": ["/doc", "/openapi.json"] }],
      "runtime": { "headers": {} },
      "playbook": "openapi-generic",
      "router": { "strategy": "runtime-openapi", "rung1": "GET /openapi.json" },
      "frontendRouting": "black-box",
      "orm": { "name": "drizzle", "modelsPath": ".", "migrationsPath": "drizzle" },
      "auth": { "scheme": "bearer", "csrf": null },
      "commands": { "dev": "npm run dev", "test": "npm test", "build": "npm run build" }
    },
    {
      "id": "nextjs", "language": "typescript", "role": "frontend",
      "manifest": "package.json", "packages": ["next"],
      "runtime": { "html": ["__NEXT_DATA__"], "headers": {} },
      "playbook": "generic",
      "router": { "strategy": "static-parse", "rung1": "file-based app/pages dir" },
      "frontendRouting": "file-based",
      "orm": { "name": "unknown", "modelsPath": ".", "migrationsPath": "." },
      "auth": { "scheme": "none", "csrf": null },
      "commands": { "dev": "npm run dev", "test": "npm test", "build": "npm run build" }
    }
  ],
  "_fallback": {
    "id": "generic", "language": "unknown", "role": "fullstack",
    "playbook": "generic",
    "router": { "strategy": "live-nav", "rung1": "browse + snapshot" },
    "frontendRouting": "black-box",
    "orm": { "name": "unknown", "modelsPath": ".", "migrationsPath": "." },
    "auth": { "scheme": "none", "csrf": null },
    "commands": { "dev": "", "test": "", "build": "" }
  }
}
```

- [ ] **Step 2: Implement code-based detection in the engine**

Add to `detect-stack.sh` (before `main`):
```bash
# Detect one repo path against signatures. Echoes a JSON component or nothing.
detect_code_component() {
  local repo="$1"
  [[ -d "$repo" ]] || return 0
  have jq || return 0
  local n; n="$(jq '.stacks | length' "$SIGNATURES")"
  for i in $(seq 0 $((n-1))); do
    local id manifest pkgs
    id="$(jq -r ".stacks[$i].id" "$SIGNATURES")"
    manifest="$(jq -r ".stacks[$i].manifest" "$SIGNATURES")"
    # Resolve manifest file (supports a *.ext glob).
    local mfile=""
    if [[ "$manifest" == \** ]]; then
      mfile="$(find "$repo" -maxdepth 2 -name "$manifest" 2>/dev/null | head -1)"
    elif [[ -f "$repo/$manifest" ]]; then mfile="$repo/$manifest"; fi
    [[ -n "$mfile" ]] || continue
    # Require at least one package signature present in the manifest text.
    local match=0 p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      grep -q -- "$p" "$mfile" 2>/dev/null && match=1
    done < <(jq -r ".stacks[$i].packages[]?" "$SIGNATURES")
    [[ "$match" -eq 1 ]] || continue
    # Apply `implies` (e.g. inertia → server-bridge) by scanning the manifest text.
    local fr; fr="$(jq -r ".stacks[$i].frontendRouting" "$SIGNATURES")"
    while IFS= read -r imp; do
      [[ -z "$imp" ]] && continue
      local ipkg ifr
      ipkg="$(echo "$imp" | jq -r '.package // empty')"
      ifr="$(echo "$imp" | jq -r '.frontendRouting // empty')"
      if [[ -n "$ipkg" ]] && grep -q -- "$ipkg" "$mfile" 2>/dev/null && [[ -n "$ifr" ]]; then fr="$ifr"; fi
    done < <(jq -c ".stacks[$i].implies[]?" "$SIGNATURES")
    # Build the component from the signature row + evidence.
    jq -n --argjson row "$(jq ".stacks[$i]" "$SIGNATURES")" \
          --arg repo "$repo" --arg fr "$fr" --arg ev "code: $mfile $id" '{
      role: $row.role, path: $repo, language: $row.language, languageVersion: "",
      framework: $row.id, frameworkVersion: "", packages: [],
      router: $row.router, frontend: { routing: $fr },
      orm: $row.orm, auth: $row.auth, commands: $row.commands,
      buildIdSource: "none", playbook: $row.playbook,
      signal: "strong", evidence: [$ev], drift: [] }'
    return 0
  done
}
```

- [ ] **Step 3: Wire code detection into `main`**

Replace `main`:
```bash
main() {
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local comps="[]"
  if [[ "$NO_CODE" -eq 0 && -n "$REPOS" ]]; then
    IFS=',' read -ra paths <<< "$REPOS"
    for rp in "${paths[@]}"; do
      [[ -z "$rp" ]] && continue
      local c; c="$(detect_code_component "$rp")"
      [[ -n "$c" ]] && comps="$(jq -c ". + [$c]" <<< "$comps")"
    done
  fi
  local mode="black-box"; [[ "$comps" != "[]" ]] && mode="local-matched"
  jq -n --arg ts "$ts" --arg mode "$mode" --argjson comps "$comps" '{
    generatedAt:$ts, mode:$mode, environment:"disposable", repoRoot:null,
    components:$comps,
    primary:{ backend:( ($comps|map(.role)|index("backend")) // ($comps|length>0|if . then 0 else null end) ),
              frontend:( ($comps|map(.frontend.routing)|index("file-based")) // 0 ) },
    notes:[] }' | emit
}
```

- [ ] **Step 4: Run the harness**

Run: `bash tests/detect-stack/run.sh`
Expected: PASS — laravel framework/playbook/orm/frontend all match (`server-bridge` via the inertia `implies`).

- [ ] **Step 5: Commit**

```bash
git add skills/detecting-stack-profile/references/stack-signatures.json skills/detecting-stack-profile/scripts/detect-stack.sh
git commit -m "feat: code-based detection + stack signatures data"
```

### Task A4: Runtime fingerprint detection

**Files:**
- Modify: `skills/detecting-stack-profile/scripts/detect-stack.sh`
- Create: `tests/detect-stack/fixtures/server/laravel-headers.txt`
- Modify: `tests/detect-stack/run.sh`

- [ ] **Step 1: Add a runtime fingerprint test (offline, header-file driven)**

The engine must accept a captured headers file so tests don't need a live server. Append to `run.sh` before the summary:
```bash
# Case 2: runtime-only fingerprint from a captured headers file → laravel
OUT2="$(mktemp)"
bash "$ENGINE" --no-code --headers-file "$FIX/server/laravel-headers.txt" --out "$OUT2" >/dev/null 2>&1
check "runtime laravel" "$(get "$OUT2" '.components[0].framework')" "laravel"
check "runtime signal"  "$(get "$OUT2" '.components[0].signal')"     "weak"
```

`tests/detect-stack/fixtures/server/laravel-headers.txt`:
```
HTTP/1.1 200 OK
Set-Cookie: XSRF-TOKEN=eyJ...; path=/
Set-Cookie: laravel_session=abc; path=/; httponly
Content-Type: text/html
```

- [ ] **Step 2: Run to verify the new case fails**

Run: `bash tests/detect-stack/run.sh`
Expected: Case 2 FAILs (no runtime detection yet).

- [ ] **Step 3: Implement runtime fingerprinting**

Add `--headers-file` to the arg parser (`--headers-file) HEADERS_FILE="$2"; shift 2 ;;` and `HEADERS_FILE="${HEADERS_FILE:-}"`). Add:
```bash
# Fetch response headers from baseUrl (read-only) unless a captured file is given.
fetch_headers() {
  if [[ -n "$HEADERS_FILE" ]]; then cat "$HEADERS_FILE"; return; fi
  [[ -n "$BASE_URL" ]] && have curl || return 0
  curl -sI --max-time 8 "$BASE_URL" 2>/dev/null || true
}

# Match captured headers against signature runtime cookies/headers. Echoes a component or nothing.
detect_runtime_component() {
  local hdr; hdr="$(fetch_headers)"
  [[ -n "$hdr" ]] || return 0
  have jq || return 0
  local n; n="$(jq '.stacks | length' "$SIGNATURES")"
  for i in $(seq 0 $((n-1))); do
    local matched=0 c
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      grep -qi "$c" <<< "$hdr" && matched=1
    done < <(jq -r ".stacks[$i].runtime.cookies[]?" "$SIGNATURES")
    # header name:value substrings
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
```

- [ ] **Step 4: Merge runtime into `main`**

In `main`, after the code-detection loop, add runtime detection and a merge (code wins on identity when both agree; runtime adds a component when no code component matched its framework):
```bash
  if [[ "$NO_RUNTIME" -eq 0 ]]; then
    local rc; rc="$(detect_runtime_component)"
    if [[ -n "$rc" ]]; then
      local rfw; rfw="$(jq -r '.framework' <<< "$rc")"
      if ! jq -e --arg f "$rfw" 'any(.[]; .framework == $f)' <<< "$comps" >/dev/null; then
        comps="$(jq -c ". + [$rc]" <<< "$comps")"
      else
        # code already found this framework — record runtime as corroborating evidence
        comps="$(jq -c --arg f "$rfw" 'map(if .framework==$f then .evidence += ["runtime: corroborated"] else . end)' <<< "$comps")"
      fi
    fi
  fi
  [[ "$comps" != "[]" && "$NO_CODE" -eq 1 ]] && mode="black-box"
```

- [ ] **Step 5: Run the harness**

Run: `bash tests/detect-stack/run.sh`
Expected: PASS — both Case 1 (code) and Case 2 (runtime, `signal: weak`).

- [ ] **Step 6: Commit**

```bash
git add -A tests/detect-stack skills/detecting-stack-profile/scripts/detect-stack.sh
git commit -m "feat: runtime fingerprint detection + merge"
```

### Task A5: Generic fallback + unknown/prod fixtures

**Files:**
- Modify: `skills/detecting-stack-profile/scripts/detect-stack.sh`
- Modify: `tests/detect-stack/run.sh`
- Create: `tests/detect-stack/fixtures/unknown/README.md`

- [ ] **Step 1: Add fallback + environment tests**

`tests/detect-stack/fixtures/unknown/README.md`: `# not a recognised stack`

Append to `run.sh`:
```bash
# Case 3: unknown repo → generic / weak, still valid JSON
OUT3="$(mktemp)"
QA_REPOS="$FIX/unknown" bash "$ENGINE" --no-runtime --out "$OUT3" >/dev/null 2>&1
check "unknown playbook" "$(get "$OUT3" '.components[0].playbook // "generic"')" "generic"
check "unknown valid"    "$(jq -e . "$OUT3" >/dev/null 2>&1 && echo ok)"          "ok"

# Case 4: prod baseUrl + no repo → environment=production, mode=black-box
OUT4="$(mktemp)"
bash "$ENGINE" --no-code --base-url "https://app.example.com" --headers-file "$FIX/server/laravel-headers.txt" --out "$OUT4" >/dev/null 2>&1
check "prod env"  "$(get "$OUT4" '.environment')" "production"
check "prod mode" "$(get "$OUT4" '.mode')"        "black-box"
```

- [ ] **Step 2: Run to verify new cases fail**

Run: `bash tests/detect-stack/run.sh`
Expected: Cases 3 & 4 FAIL.

- [ ] **Step 3: Implement fallback + environment inference**

In `main`, when `comps` is still `[]` after both sources, append the `_fallback` row as a `weak` component. Add environment inference: `production` when `BASE_URL` is non-empty, not `localhost`/`127.0.0.1`/`*.ddev.site`, and no `seedableEnvMarker` in config; else `disposable`.
```bash
  if [[ "$comps" == "[]" ]]; then
    local fb; fb="$(jq -n --argjson row "$(jq '._fallback' "$SIGNATURES")" '{
      role:$row.role, path:null, language:$row.language, languageVersion:"",
      framework:"generic", frameworkVersion:"", packages:[],
      router:$row.router, frontend:{routing:$row.frontendRouting},
      orm:$row.orm, auth:$row.auth, commands:$row.commands,
      buildIdSource:"none", playbook:$row.playbook, signal:"weak", evidence:["fallback"], drift:[] }')"
    comps="$(jq -c ". + [$fb]" <<< "$comps")"
  fi
  local env="disposable"
  if [[ -n "$BASE_URL" ]]; then
    case "$BASE_URL" in
      *localhost*|*127.0.0.1*|*.ddev.site*) env="disposable" ;;
      *) [[ -z "$(cfg '.seedableEnvMarker' '')" ]] && env="production" ;;
    esac
  fi
```
Thread `--arg env "$env"` into the final `jq -n` and set `environment:$env`.

- [ ] **Step 4: Run the harness**

Run: `bash tests/detect-stack/run.sh`
Expected: PASS — all four cases.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: generic fallback + production environment inference"
```

### Task A6: SKILL.md, ADR-0005, repo validation suite

**Files:**
- Create: `skills/detecting-stack-profile/SKILL.md`
- Create: `docs/adr/0005-stack-profile-cache.md`

- [ ] **Step 1: Write `detecting-stack-profile/SKILL.md`**

Frontmatter `name: detecting-stack-profile`, third-person `description` starting "Use when…", body < 500 lines, checklist-structured (plan→validate→execute), with **≥3 mini-evals** from the bug list: (1) an Inertia page href-grep misses but server-bridge enumeration finds it; (2) a wrong-model map a profile `orm.migrationsPath` prevents; (3) a stale route a deterministic `route:list`/OpenAPI includes that grep missed. Document the run-dir write (`.qa/runs/<run-id>/stack-profile.json`), the `signal`→verdict-`confidence` one-way mapping, and that detection is the first action of Analyze, unconditional.

- [ ] **Step 2: Write ADR-0005**

`docs/adr/0005-stack-profile-cache.md`: context (re-detecting every run is wasteful; prod probing should be minimal), decision (run-dir authoritative copy always written; optional `.qa/stack-profile.cache.json` revalidated at preflight against build-id + one homepage fingerprint; black-box never skips runtime re-check), consequences, and how it preserves ADR-0002.

- [ ] **Step 3: Run the repo's own validation suite**

Run:
```bash
for f in $(find . -name '*.sh' -not -path './.git/*'); do bash -n "$f" || echo "BADSH $f"; done
for f in $(find . -name '*.json' -not -path './.git/*'); do python3 -c "import json;json.load(open('$f'))" || echo "BADJSON $f"; done
awk 'END{print NR}' skills/detecting-stack-profile/SKILL.md   # must be < 500
```
Expected: no `BADSH`/`BADJSON`; line count < 500.

- [ ] **Step 4: Commit (Slice A complete)**

```bash
git add -A
git commit -m "docs: detecting-stack-profile skill + ADR-0005; slice A complete"
```

---

# SLICE B — Adaptation (behavior change)

### Task B1: Playbooks (laravel, openapi-generic, generic)

**Files:**
- Create: `skills/detecting-stack-profile/references/playbooks/{laravel,openapi-generic,generic}.md`

- [ ] **Step 1: Write `laravel.md`**

Sections: **route enumeration ladder** (1 runtime-openapi if present → 2 `php artisan route:list --json` [strong only on build-match] → 3 grep `routes/*.php` → 4 live-nav); **frontend enumeration** = server-bridge: frontend surfaces = backend GET routes returning Inertia, cross-mapped to `resources/js/pages/<x>.tsx` and the controller; **backend mapping** via `orm.migrationsPath`; **baking** read-back via list/detail VIEW or in-page authed GET; **probe/auth** = `session-cookie` + `laravel-xsrf` (send `X-XSRF-TOKEN`); **commands/build-id**; **≥3 mini-evals**.

- [ ] **Step 2: Write `openapi-generic.md`**

Rung-1 = fetch the OpenAPI doc (`router.rung1`), treat `paths` as the authoritative route list and component schemas as the shape oracle for baking. Frontend = black-box (live-crawl, opt-in). `auth` from profile. ≥3 mini-evals (e.g. a route present in `paths` the UI never links to; a schema `required` field that bakes NULL).

- [ ] **Step 3: Write `generic.md`**

Rung-1 = live-nav + grep; explicitly `signal: weak`. Black-box frontend. ≥3 mini-evals.

- [ ] **Step 4: Validate + commit**

```bash
for f in skills/detecting-stack-profile/references/playbooks/*.md; do awk 'END{if(NR>=500)print "TOOLONG '"$f"'"}' "$f"; done
git add -A && git commit -m "feat: laravel, openapi-generic, generic playbooks"
```

### Task B2: Strip detection from `index-routes.sh`; consume the profile

**Files:**
- Modify: `skills/analyzing-feature-ui/scripts/index-routes.sh`

- [ ] **Step 1: Add a profile reader + dispatch**

At the top (after config resolution), read `.qa/runs/<run-id>/stack-profile.json` (path via `QA_PROFILE` env, default newest under `.qa/runs/*/stack-profile.json`). Read `primary.frontend`/`primary.backend` components' `frontend.routing` and `router.strategy`.

- [ ] **Step 2: Replace the `FW` heuristic with profile-driven dispatch**

Delete the `# framework detection` block (the `next.config`/`react-router` guessing). Replace with:
```bash
FR="$(profile_get '.components[(.primary.frontend // 0)].frontend.routing' 'black-box')"
case "$FR" in
  server-bridge) collect_server_bridge_routes ;;   # from backend GET routes (new)
  file-based)    collect_nextjs_routes ;;
  config-router) collect_react_router_routes ;;
  *)             collect_generic_routes ;;
esac
```
Add `collect_server_bridge_routes` that lists backend GET routes from the profile's backend component (via its `router.rung1` output captured by the detector, or by greppping the backend `routes/` dir as a fallback) and maps each to a page-component path under the frontend repo's pages dir.

- [ ] **Step 3: Smoke test against the CRM**

Run `bash skills/analyzing-feature-ui/scripts/index-routes.sh` from a config pointing `repos[]` at the CRM; expect routes derived from Laravel GET routes, not href-grep.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor: index-routes consumes profile; server-bridge route discovery"
```

### Task B3: Wire bake, probe, analyze, report, agent, CONTEXT

**Files:**
- Modify: `skills/verifying-backend-persistence/SKILL.md` (read `orm.modelsPath`/`migrationsPath` from the profile when locating the model/migration).
- Modify: `skills/probing-apis-through-browser/SKILL.md` (read `auth.scheme`/`csrf` to form requests; e.g. attach `X-XSRF-TOKEN` for `laravel-xsrf`).
- Modify: `skills/analyzing-feature-ui/SKILL.md` (Step 0: invoke `detecting-stack-profile` first; dispatch frontend enumeration on `frontend.routing`).
- Modify: `agents/qa-e2e-pilot.md` (Phase 1 begins with stack detection, unconditional; later phases reference the profile).
- Modify: `skills/writing-qa-reports/SKILL.md` + `templates/report.md` (a header line showing detected stack, tier, `signal`, and any `drift`).
- Modify: `CONTEXT.md` (add `stack-profile`, `playbook`, `signal: strong|weak` with the one-way mapping to verdict `confidence`, `runtime fingerprint` vs `code-based detection`).

- [ ] **Step 1: Make each edit above** (one commit per file is fine).

- [ ] **Step 2: Validate suite** (`bash -n`, JSON validity, SKILL line counts < 500).

- [ ] **Step 3: Commit (Slice B complete)**

```bash
git add -A && git commit -m "feat: wire profile into bake/probe/analyze/report/agent + CONTEXT vocab; slice B complete"
```

---

# SLICE C — Production / black-box hardening

### Task C1: Production guardrails in the engine

**Files:**
- Modify: `skills/detecting-stack-profile/scripts/detect-stack.sh`
- Modify: `tests/detect-stack/run.sh`

- [ ] **Step 1: Test that prod env forces guardrail flags into the profile**

Append to `run.sh`:
```bash
check "prod writes off" "$(get "$OUT4" '.notes | index("allowApiWrites forced off (production)") != null')" "true"
```

- [ ] **Step 2: Implement** — when `env=production`: push notes `allowApiWrites forced off (production)` and `recommend dedicated test account/tenant`; set a top-level `guardrails:{allowApiWrites:false, requireWriteConfirm:true, blackboxCrawl:false}` unless `allowBlackboxCrawl` true in config.

- [ ] **Step 3: Run harness → PASS. Commit.**

```bash
git add -A && git commit -m "feat: production guardrails in stack profile"
```

### Task C2: Fingerprint throttling + config surface

**Files:**
- Modify: `skills/detecting-stack-profile/scripts/detect-stack.sh` (serialize fingerprint GETs; cap to `fingerprintPaths` ≤4 from config, default `[/openapi.json,/swagger/v1/swagger.json]`; honor `noProbePaths`; `maxRequestsPerSecond` delay).
- Modify: `.qa/config.json.example` (add `environment`, `allowBlackboxCrawl`, `fingerprintPaths`, `noProbePaths`, `crawlDenyPatterns`, `maxRequestsPerSecond` with the `_doc` note).

- [ ] **Step 1: Implement throttled, allowlisted fingerprint probing.**
- [ ] **Step 2: Validate JSON of `config.json.example`.**
- [ ] **Step 3: Commit.**

```bash
git add -A && git commit -m "feat: throttled allowlisted fingerprint probing + config surface"
```

### Task C3: Black-box crawl guidance + preflight build-match

**Files:**
- Modify: `skills/detecting-stack-profile/references/playbooks/generic.md` + `openapi-generic.md` (black-box crawl section: GET-only, same-origin, `maxDepth`/`maxPages`, destructive-link denylist `logout|sign-out|delete|remove|destroy|revoke|cancel|archive` + `?_method=`/`data-method`/`data-confirm`; off unless `allowBlackboxCrawl`).
- Modify: `skills/driving-browser-qa/scripts/preflight.sh` (after build-id capture, compare to the profile's backend component; on mismatch, downgrade `local-cli` rung to `signal: weak` by writing a `drift` note into the run profile; warn on production target).

- [ ] **Step 1–2: Implement + validate suite.**
- [ ] **Step 3: Commit (Slice C complete).**

```bash
git add -A && git commit -m "feat: black-box crawl guidance + preflight build-match drift; slice C complete"
```

---

## Self-Review

- **Spec coverage:** dual-source detection (A3/A4) ✔; merge precedence (A4) ✔; `signal` not `confidence` + CONTEXT vocab (A6/B3) ✔; `frontend.routing` + Inertia server-bridge (A3/B2) ✔; one detector + signatures=data/playbook=procedure (A2–A6/B1) ✔; route ladder runtime-first (B1 playbooks) ✔; run-dir + cache + ADR-0005 (A6, C3) ✔; prod safety (C1–C3) ✔; three slices, A no-behavior-change (structure) ✔; tiered support (signatures `playbook` mapping) ✔.
- **Placeholder scan:** code shown for every engine step; playbook/SKILL/CONTEXT tasks specify exact sections + required mini-evals rather than prose stubs.
- **Type consistency:** profile field names (`signal`, `frontend.routing`, `router.strategy`/`rung1`, `orm.modelsPath`/`migrationsPath`, `auth.scheme`/`csrf`, `playbook`, `drift`, `mode`, `environment`) match the spec schema and are used identically across A→B→C.
