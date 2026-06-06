#!/usr/bin/env bash
# Tests for init-config.sh — deterministic .qa/config.json writer + inference.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="$HERE/../../skills/bootstrapping-qa-config/scripts/init-config.sh"
PASS=0; FAIL=0
get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# Case 1: write a config from explicit flags
OUT="$(mktemp)"
bash "$GEN" --base-url "https://crm.ddev.site" --environment auto --repos "." \
  --storage-state ".qa/auth/storageState.json" --out "$OUT" >/dev/null 2>&1
check "valid json"      "$(jq -e . "$OUT" >/dev/null 2>&1 && echo ok)"        "ok"
check "baseUrl"         "$(get "$OUT" '.baseUrl')"                            "https://crm.ddev.site"
check "environment"     "$(get "$OUT" '.environment')"                        "auto"
check "driver managed"  "$(get "$OUT" '.drivers[0].preset')"                  "managed"
check "repos path"      "$(get "$OUT" '.repos[0].path')"                      "."
check "repos role"      "$(get "$OUT" '.repos[0].role')"                      "backend"
check "storageState"    "$(get "$OUT" '.auth.storageState')"                  ".qa/auth/storageState.json"
check "writes default"  "$(get "$OUT" '.allowApiWrites')"                     "false"
check "crawl default"   "$(get "$OUT" '.allowBlackboxCrawl')"                 "false"

# Case 2: allow-writes flag flips the gate
OUT2="$(mktemp)"
bash "$GEN" --base-url "http://localhost:8000" --allow-writes true --out "$OUT2" >/dev/null 2>&1
check "writes on"       "$(get "$OUT2" '.allowApiWrites')"                    "true"

# Case 3: --suggest infers a DDEV baseUrl from a fixture project
SUG="$(mktemp -d)"
mkdir -p "$SUG/.ddev"
printf 'name: mayocrm\ntype: laravel\n' > "$SUG/.ddev/config.yaml"
SJSON="$(cd "$SUG" && bash "$GEN" --suggest 2>/dev/null)"
check "suggest ddev url" "$(echo "$SJSON" | jq -r '.baseUrl')"               "https://mayocrm.ddev.site"
check "suggest repos"    "$(echo "$SJSON" | jq -r '.repos')"                 "."

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
