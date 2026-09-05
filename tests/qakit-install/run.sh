#!/usr/bin/env bash
# Install-wrapper tests: positive placement, co-install abort, and D2 fail-loud on a missing profile field.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$DIR/../.."
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
skdir(){ case "$1" in pi) echo .pi/agents/skills;; codex) echo .agents/skills;; opencode) echo .opencode/skills;; esac; }
PROF="$REPO/qa-kit/harness-profiles.qakit.json"
for h in pi codex opencode; do
  SK="$(skdir "$h")"; ext=md; [ "$h" = codex ] && ext=toml
  # positive: fake engine skills present -> files land in the profile-declared dirs
  T="$(mktemp -d)"; mkdir -p "$T/$SK/detecting-stack-profile"
  bash "$REPO/qa-kit/harnesses/$h/install-$h.sh" "$T" >/dev/null 2>&1
  agentdir="$(python3 -c "import json;print(json.load(open('$PROF'))['harnesses']['$h']['agentDir'])")"
  cmddir="$(python3 -c "import json;print(json.load(open('$PROF'))['harnesses']['$h']['cmdDir'])")"
  check "$h positive: agent placed" "$([ -f "$T/$agentdir/qa-kit.$ext" ] && echo y)" "y"
  check "$h positive: 5 commands"   "$(ls "$T/$cmddir" 2>/dev/null | wc -l | tr -d ' ')" "5"
  rm -rf "$T"
  # abort: no engine skills -> non-zero
  T2="$(mktemp -d)"; bash "$REPO/qa-kit/harnesses/$h/install-$h.sh" "$T2" >/dev/null 2>&1; check "$h abort guard" "$?" "1"; rm -rf "$T2"
  # D2 fail-loud: profile missing agentDir -> non-zero + stderr names the field (QAKIT_PROFILE override, temp copy)
  T3="$(mktemp -d)"; mkdir -p "$T3/$SK/detecting-stack-profile"
  P="$(mktemp)"; python3 -c "import json;d=json.load(open('$PROF'));d['harnesses']['$h'].pop('agentDir',None);json.dump(d,open('$P','w'))"
  err="$(QAKIT_PROFILE="$P" bash "$REPO/qa-kit/harnesses/$h/install-$h.sh" "$T3" 2>&1 >/dev/null)"; rc=$?
  check "$h missing-field exits non-zero" "$rc" "1"
  check "$h missing-field names field" "$(printf '%s' "$err" | grep -c "agentDir")" "1"
  rm -rf "$T3" "$P"
done
echo "qakit-install: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
