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

# ---------------------------------------------------------------------------
# Task 9 (Lane E): the `findings` block + a NON-DESTRUCTIVE re-render.
#
# init-config.sh renders a fresh object and `mv -f`s it over $OUT, so every
# top-level key it does not itself emit used to be silently destroyed on every
# re-run. That already lost the six keys `.qa/config.json.example` documents
# but the writer never emits (viewport, responsiveMatrix, persona, detection,
# passGate, fixtures), plus `personas` -- which is written ONLY by
# confirming-discovered-roles' write-persona-config.sh, never by this script.
# A re-render must now merge the freshly-rendered object OVER the existing one:
# unknown keys survive, keys the script owns stay authoritative.
# ---------------------------------------------------------------------------

# --- fresh bootstrap writes the findings block -----------------------------
FIND_OUT="$WORK/c-findings.json"
bash "$GEN" --base-url http://localhost:3000 --out "$FIND_OUT" >/dev/null 2>&1
check "fresh bootstrap writes a findings block"     "$(get "$FIND_OUT" '.findings | type')"           "object"
check "findings block is documented (_doc)"         "$(get "$FIND_OUT" '(.findings._doc // "") | length > 0')" "true"
check "findings._doc names the benign semantics"    "$(get "$FIND_OUT" '(.findings._doc // "") | test("POSIX-ERE") and test("path")')" "true"

# --- benign defaults EMPTY (fail-closed: no waivers by default) ------------
check "findings.benign is an array"                 "$(get "$FIND_OUT" '.findings.benign | type')"    "array"
check "findings.benign defaults empty (fail-closed)" "$(get "$FIND_OUT" 'if (.findings | type == "object") and (.findings | has("benign")) then (.findings.benign | length | tostring) else "absent" end')" "0"

# --- re-render preserves unknown top-level keys ----------------------------
PRES="$WORK/c-preserve.json"
bash "$GEN" --base-url http://localhost:3000 --out "$PRES" >/dev/null 2>&1
jq '. + {
      myCustomKey: {"a": 1},
      viewport: {"width": 1440, "height": 900},
      responsiveMatrix: [{"id": "mobile", "width": 390, "height": 844}],
      persona: {"lens": "first-time-user"},
      detection: {"ux": {"objective": true, "advisoryAesthetics": false}},
      passGate: {"enforce": true},
      fixtures: {"hardBlock": true},
      personas: [{"id": "admin", "role": "admin", "plane": "global", "auth": "qa.admin@example (seeded credential)"}],
      maxParallel: 99
    }' "$PRES" > "$PRES.hand" && mv -f "$PRES.hand" "$PRES"
check "sanity: hand-edited config parses"           "$(jq -e . "$PRES" >/dev/null 2>&1 && echo ok)"   "ok"

# re-run the bootstrap over the hand-edited file (this is the destructive path)
bash "$GEN" --base-url http://localhost:3000 --allow-writes true --out "$PRES" >/dev/null 2>&1

check "re-render output is still valid JSON"        "$(jq -e . "$PRES" >/dev/null 2>&1 && echo ok)"   "ok"
check "unknown top-level key survives re-render"    "$(get "$PRES" '.myCustomKey.a')"                 "1"

# the six keys config.json.example documents but the writer never emits
check "viewport survives re-render"                 "$(get "$PRES" '.viewport.width')"                "1440"
check "responsiveMatrix survives re-render"         "$(get "$PRES" '.responsiveMatrix[0].id')"        "mobile"
check "persona survives re-render"                  "$(get "$PRES" '.persona.lens')"                  "first-time-user"
check "detection survives re-render"                "$(get "$PRES" '.detection.ux.advisoryAesthetics')" "false"
check "passGate survives re-render"                 "$(get "$PRES" '.passGate.enforce')"              "true"
check "fixtures survives re-render"                 "$(get "$PRES" '.fixtures.hardBlock')"            "true"

# personas is written by write-persona-config.sh, NEVER by this script
check "personas survives re-render"                 "$(get "$PRES" '.personas[0].id')"                "admin"
check "personas entry keeps its auth descriptor"    "$(get "$PRES" '.personas[0].auth')"              "qa.admin@example (seeded credential)"

# --- keys the script OWNS are still authoritative --------------------------
check "owned maxParallel is reset by a re-run"      "$(get "$PRES" '.maxParallel')"                   "3"
check "owned allowApiWrites reflects the new flag"  "$(get "$PRES" '.allowApiWrites')"                "true"
check "owned baseUrl is re-rendered"                "$(get "$PRES" '.baseUrl')"                       "http://localhost:3000"
check "findings block is present after re-render"   "$(get "$PRES" '.findings.benign | type')"        "array"

# --- a corrupt/unparseable existing file does not block a fresh render -----
CORRUPT="$WORK/c-corrupt.json"
printf 'not json at all' > "$CORRUPT"
bash "$GEN" --base-url http://localhost:3000 --out "$CORRUPT" >/dev/null 2>&1
check "unparseable existing config is replaced, output valid" "$(jq -e . "$CORRUPT" >/dev/null 2>&1 && echo ok)" "ok"
check "unparseable existing config: baseUrl written" "$(get "$CORRUPT" '.baseUrl')"                   "http://localhost:3000"

# ---------------------------------------------------------------------------
# Fix round 1, item 1: a JSON *STREAM* must not abort the bootstrap.
# `jq -c '<prog>' file` runs the program once PER input, so a file holding two
# concatenated objects emitted TWO values -> --argjson got invalid JSON text ->
# raw jq noise + exit 3. That was a REGRESSION (before the merge, such a file
# was simply replaced). Slurp + first value: degrade to the first object.
# ---------------------------------------------------------------------------
STREAM="$WORK/c-stream.json"
printf '{"streamKeyA": 1, "maxParallel": 99}\n{"streamKeyB": 2}\n' > "$STREAM"
STREAM_OUT="$( bash "$GEN" --base-url http://localhost:3000 --out "$STREAM" 2>&1 )"
STREAM_RC=$?
check "JSON stream input does not abort the bootstrap"  "$([[ "$STREAM_RC" -eq 0 ]] && echo yes || echo no)" "yes"
check "JSON stream input emits no raw jq --argjson noise" \
  "$([[ "$STREAM_OUT" == *"--argjson"* ]] && echo leaked || echo clean)" "clean"
check "JSON stream: output is valid JSON"           "$(jq -e . "$STREAM" >/dev/null 2>&1 && echo ok)"  "ok"
check "JSON stream: first object's unknown key is preserved" "$(get "$STREAM" '.streamKeyA')"          "1"
check "JSON stream: second object is dropped"       "$(get "$STREAM" '.streamKeyB')"                   "null"
check "JSON stream: owned key still re-rendered"    "$(get "$STREAM" '.maxParallel')"                  "3"

# ---------------------------------------------------------------------------
# Fix round 1, item 2: a present-but-UNREADABLE config is REFUSED, not
# overwritten. Overwriting it would destroy its keys precisely because they
# could not be read -- the exact failure class this task exists to remove.
# (Skipped as root, which can read mode-000 files.)
# ---------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  UNREADABLE="$WORK/c-unreadable.json"
  printf '{"secretOperatorKey": "keep-me"}' > "$UNREADABLE"
  UNREADABLE_BEFORE="$(cat "$UNREADABLE")"
  chmod 000 "$UNREADABLE"
  UNREADABLE_OUT="$( bash "$GEN" --base-url http://localhost:3000 --out "$UNREADABLE" 2>&1 )"
  UNREADABLE_RC=$?
  check "unreadable existing config is REFUSED (nonzero exit)" \
    "$([[ "$UNREADABLE_RC" -ne 0 ]] && echo yes || echo no)" "yes"
  check "unreadable-config error names the path"    "$([[ "$UNREADABLE_OUT" == *"c-unreadable.json"* ]] && echo yes || echo no)" "yes"
  check "unreadable-config error names the permission problem" \
    "$([[ "$UNREADABLE_OUT" == *"permission"* || "$UNREADABLE_OUT" == *"cannot read"* ]] && echo yes || echo no)" "yes"
  chmod 644 "$UNREADABLE"
  check "unreadable existing config is NOT overwritten, byte-for-byte" \
    "$(cat "$UNREADABLE")" "$UNREADABLE_BEFORE"
  check "unreadable existing config kept its contents" "$(get "$UNREADABLE" '.secretOperatorKey')"     "keep-me"
  check "no stray .tmp.\$\$ sibling after the refusal" \
    "$(find "$WORK" -maxdepth 1 -name 'c-unreadable.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0"
else
  echo "skip - unreadable-config refusal (running as root)"
fi

# ---------------------------------------------------------------------------
# Fix round 1, item 3: findings.benign is SEED-IF-ABSENT, PRESERVE-IF-PRESENT.
# It is the ONE owned key a re-render must not reset: entries are human-authored
# waivers, and this script gitignores `.qa/`, so a reset destroys them with no
# recovery path. Every OTHER owned key keeps its authoritative overwrite.
# ---------------------------------------------------------------------------
WAIVER="$WORK/c-waiver.json"
bash "$GEN" --base-url http://localhost:3000 --out "$WAIVER" >/dev/null 2>&1
jq '.findings.benign = ["^/favicon\\.ico$", "^/__vite_ping$"] | .maxParallel = 99' "$WAIVER" > "$WAIVER.hand"
mv -f "$WAIVER.hand" "$WAIVER"
bash "$GEN" --base-url http://localhost:3000 --out "$WAIVER" >/dev/null 2>&1
check "hand-added findings.benign SURVIVES a re-render"  "$(get "$WAIVER" '.findings.benign | length')" "2"
check "preserved waiver keeps its exact regex"      "$(get "$WAIVER" '.findings.benign[0]')"           "^/favicon\\.ico$"
check "preserved waiver keeps the second regex"     "$(get "$WAIVER" '.findings.benign[1]')"           "^/__vite_ping$"
check "findings._doc is still re-rendered (owned)"  "$(get "$WAIVER" '(.findings._doc // "") | test("PERSISTENCE")')" "true"
check "maxParallel is STILL reset alongside it"     "$(get "$WAIVER" '.maxParallel')"                  "3"

# absent findings block on an existing config is SEEDED empty (fail-closed)
SEED="$WORK/c-seed.json"
bash "$GEN" --base-url http://localhost:3000 --out "$SEED" >/dev/null 2>&1
jq 'del(.findings)' "$SEED" > "$SEED.hand" && mv -f "$SEED.hand" "$SEED"
bash "$GEN" --base-url http://localhost:3000 --out "$SEED" >/dev/null 2>&1
check "absent findings block is re-seeded"          "$(get "$SEED" '.findings.benign | type')"         "array"
check "re-seeded benign is empty (fail-closed)"     "$(get "$SEED" '.findings.benign | length')"       "0"

# a malformed (non-array) benign falls back to the fail-closed empty list, loudly
BADB="$WORK/c-badbenign.json"
bash "$GEN" --base-url http://localhost:3000 --out "$BADB" >/dev/null 2>&1
jq '.findings.benign = "oops-a-string"' "$BADB" > "$BADB.hand" && mv -f "$BADB.hand" "$BADB"
BADB_OUT="$( bash "$GEN" --base-url http://localhost:3000 --out "$BADB" 2>&1 )"
check "non-array findings.benign degrades to []"    "$(get "$BADB" '.findings.benign | length')"       "0"
check "non-array findings.benign is an array again" "$(get "$BADB" '.findings.benign | type')"         "array"
check "non-array findings.benign warns on stderr"   "$([[ "$BADB_OUT" == *"non-array findings.benign"* ]] && echo yes || echo no)" "yes"

# unknown sub-keys of the findings block survive too
SUBK="$WORK/c-findings-subkey.json"
bash "$GEN" --base-url http://localhost:3000 --out "$SUBK" >/dev/null 2>&1
jq '.findings.someFutureKnob = "keep-me"' "$SUBK" > "$SUBK.hand" && mv -f "$SUBK.hand" "$SUBK"
bash "$GEN" --base-url http://localhost:3000 --out "$SUBK" >/dev/null 2>&1
check "unknown findings sub-key survives re-render" "$(get "$SUBK" '.findings.someFutureKnob')"        "keep-me"

# --- existing cases unchanged: a re-run over Case 1's output keeps them ----
bash "$GEN" --base-url "https://crm.ddev.site" --environment auto --repos "." \
  --storage-state ".qa/auth/storageState.json" --out "$OUT" >/dev/null 2>&1
check "existing cases unchanged: baseUrl"           "$(get "$OUT" '.baseUrl')"                        "https://crm.ddev.site"
check "existing cases unchanged: driver preset"     "$(get "$OUT" '.drivers[0].preset')"              "managed"
check "existing cases unchanged: repos role"        "$(get "$OUT" '.repos[0].role')"                  "backend"
check "existing cases unchanged: writes default"    "$(get "$OUT" '.allowApiWrites')"                 "false"
check "no stray .tmp.\$\$ sibling after re-render"   "$(find "$WORK" -maxdepth 1 -name 'c-preserve.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- the shipped example documents the findings block ----------------------
EXAMPLE="$HERE/../../.qa/config.json.example"
check "config.json.example is valid JSON"           "$(jq -e . "$EXAMPLE" >/dev/null 2>&1 && echo ok)" "ok"
check "example documents findings.benign"           "$(get "$EXAMPLE" '.findings.benign | type')"     "array"
check "example findings block carries a _doc"        "$(get "$EXAMPLE" '(.findings._doc // "") | length > 0')" "true"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
