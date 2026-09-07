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

# --- audit-2 W1-5: marker defaults EMPTY; only explicit opt-in writes one ---
WORK="$(mktemp -d)"
bash "$GEN" --base-url http://localhost:3000 --out "$WORK/c-default.json" >/dev/null
check "default seedableEnvMarker is empty" "$(jq -r '.seedableEnvMarker' "$WORK/c-default.json")" ""
bash "$GEN" --base-url http://localhost:3000 --environment production --out "$WORK/c-prod.json" >/dev/null
check "production bootstrap: marker stays empty" "$(jq -r '.seedableEnvMarker' "$WORK/c-prod.json")" ""
bash "$GEN" --base-url http://localhost:3000 --seedable-marker MY_DISPOSABLE --out "$WORK/c-opt.json" >/dev/null
check "explicit --seedable-marker is honored" "$(jq -r '.seedableEnvMarker' "$WORK/c-opt.json")" "MY_DISPOSABLE"

# ---------------------------------------------------------------------------
# Appendix A (audit-2 W3-7a, highest-value): init-config.sh:85 used to feed
# --allow-writes/--allow-crawl straight into jq's --argjson (which requires
# valid JSON), with jq's stdout redirected DIRECTLY to $OUT via `>`. Under
# invalid input jq failed, but the shell's `>` had ALREADY truncated $OUT to
# 0 bytes as part of setting up the redirection (before jq ran) — and since
# this script has no `set -e`, it fell through to "Wrote $OUT" anyway,
# silently DESTROYING a pre-existing config. Prove: (a) an invalid flag value
# is rejected (nonzero exit, clear error), (b) a PRE-EXISTING config at $OUT
# survives byte-for-byte when a later call passes a bad flag, (c) no stray
# .tmp.$$ sibling is left behind either on the reject path or the atomic
# success path.
# ---------------------------------------------------------------------------
TRUNC_OUT="$WORK/c-trunc.json"
bash "$GEN" --base-url http://localhost:3000 --out "$TRUNC_OUT" >/dev/null
PRE_EXISTING_CONTENT="$(cat "$TRUNC_OUT")"
check "sanity: pre-existing config was written" "$(jq -e . "$TRUNC_OUT" >/dev/null 2>&1 && echo ok)" "ok"

BAD_ALLOW_OUT="$( bash "$GEN" --base-url http://localhost:3000 --allow-writes yes --out "$TRUNC_OUT" 2>&1 )"
BAD_ALLOW_RC=$?
check "invalid --allow-writes value is rejected (nonzero exit)" "$([[ "$BAD_ALLOW_RC" -ne 0 ]] && echo yes)" "yes"
check "invalid --allow-writes error names the flag" "$([[ "$BAD_ALLOW_OUT" == *"allow-writes"* ]] && echo yes || echo no)" "yes"
check "invalid --allow-writes: pre-existing config is UNCHANGED, not truncated" \
  "$(cat "$TRUNC_OUT")" "$PRE_EXISTING_CONTENT"

BAD_CRAWL_OUT="$( bash "$GEN" --base-url http://localhost:3000 --allow-crawl 1 --out "$TRUNC_OUT" 2>&1 )"
BAD_CRAWL_RC=$?
check "invalid --allow-crawl value is rejected (nonzero exit)" "$([[ "$BAD_CRAWL_RC" -ne 0 ]] && echo yes)" "yes"
check "invalid --allow-crawl: pre-existing config is UNCHANGED, not truncated" \
  "$(cat "$TRUNC_OUT")" "$PRE_EXISTING_CONTENT"

check "no stray .tmp.\$\$ sibling left after the reject path" \
  "$(find "$WORK" -maxdepth 1 -name 'c-trunc.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

bash "$GEN" --base-url http://localhost:3000 --allow-writes true --out "$TRUNC_OUT" >/dev/null
check "a valid --allow-writes call still succeeds after prior rejections" "$(jq -r '.allowApiWrites' "$TRUNC_OUT")" "true"
check "no stray .tmp.\$\$ sibling left after a successful write" \
  "$(find "$WORK" -maxdepth 1 -name 'c-trunc.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
