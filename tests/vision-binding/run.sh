#!/usr/bin/env bash
# tests/vision-binding/run.sh — resolve/banner smoke tests for
# vision-binding.sh (skills/detecting-visual-ux/scripts/vision-binding.sh),
# exercised against both the jq and python3 engines (whichever is available
# on this host). Mirrors the dual-engine run_engine() shape of
# tests/ux-conventions/run.sh.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../skills/detecting-visual-ux/scripts/vision-binding.sh"
ROOT="$DIR/../.."
pass=0; fail=0
check(){ local d="$1" g="$2" w="$3"; if [ "$g" = "$w" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d got=[$g] want=[$w]"; fi; }

BANNER='NOTE: layer-3 generative critic SKIPPED — vision unavailable for this harness/model; ran layers 1-2 (definite-oracle detectors + adjudication) only.'

run_engine() {
  local ENG="$1"

  check "$ENG resolve claude" "$(QA_ENGINE=$ENG bash "$SH" resolve claude)" "Read"
  check "$ENG resolve codex"  "$(QA_ENGINE=$ENG bash "$SH" resolve codex)"  "localImage"
  check "$ENG resolve opencode" "$(QA_ENGINE=$ENG bash "$SH" resolve opencode)" "Read"
  check "$ENG resolve pi"     "$(QA_ENGINE=$ENG bash "$SH" resolve pi)"     "adapter"

  # default harness comes from QA_HARNESS when no arg is given
  check "$ENG QA_HARNESS=codex no-arg -> localImage" \
    "$(QA_ENGINE=$ENG QA_HARNESS=codex bash "$SH" resolve)" "localImage"

  # default harness with neither arg nor QA_HARNESS -> claude
  check "$ENG no-arg no-QA_HARNESS -> claude's Read" \
    "$(QA_ENGINE=$ENG bash "$SH" resolve)" "Read"

  # synthetic vision-absent profile (capable:false), via the QA_PROFILES override
  local T; T="$(mktemp -d)"; local F="$T/harness-profiles.json"
  if command -v jq >/dev/null 2>&1; then
    jq '.harnesses.claude.vision.capable = false' "$ROOT/harness-profiles.json" > "$F"
  else
    python3 -c '
import json
doc = json.load(open("'"$ROOT"'/harness-profiles.json"))
doc["harnesses"]["claude"]["vision"]["capable"] = False
json.dump(doc, open("'"$F"'", "w"))
'
  fi
  check "$ENG capable:false -> absent" \
    "$(QA_ENGINE=$ENG QA_PROFILES=$F bash "$SH" resolve claude)" "absent"

  # synthetic missing-vision-object harness -> absent
  local F2="$T/harness-profiles-novision.json"
  if command -v jq >/dev/null 2>&1; then
    jq 'del(.harnesses.claude.vision)' "$ROOT/harness-profiles.json" > "$F2"
  else
    python3 -c '
import json
doc = json.load(open("'"$ROOT"'/harness-profiles.json"))
del doc["harnesses"]["claude"]["vision"]
json.dump(doc, open("'"$F2"'", "w"))
'
  fi
  check "$ENG missing vision object -> absent" \
    "$(QA_ENGINE=$ENG QA_PROFILES=$F2 bash "$SH" resolve claude)" "absent"

  # unknown harness -> absent
  check "$ENG unknown harness -> absent" \
    "$(QA_ENGINE=$ENG bash "$SH" resolve nonexistent-harness)" "absent"

  rm -rf "$T"
}

if command -v jq >/dev/null 2>&1; then run_engine jq; fi
if command -v python3 >/dev/null 2>&1; then run_engine python3; fi

# banner: engine-independent, single fixed line
check "banner text" "$(bash "$SH" banner)" "$BANNER"

# unknown subcommand -> non-zero exit
bash "$SH" bogus >/dev/null 2>&1
check "unknown subcommand exit != 0" "$([ $? -ne 0 ] && echo yes || echo no)" "yes"

echo "vision-binding: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
