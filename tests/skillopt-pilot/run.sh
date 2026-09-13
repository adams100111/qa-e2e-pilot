#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/tools/skillopt-pilot/run.sh"
PASS=0
FAIL=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL - $1 (got '$2' want '$3')"
    FAIL=$((FAIL + 1))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/python.log"
fake_python="$tmp/python"
cat >"$fake_python" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SKILLOPT_TEST_LOG"
exit 0
SH
chmod +x "$fake_python"

rc=0
SKILLOPT_SLEEP_REPO="$tmp/missing" SKILLOPT_PYTHON="$fake_python" \
  bash "$RUNNER" baseline >"$tmp/missing.out" 2>&1 || rc=$?
check "missing SkillOpt checkout rejected" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)" "yes"
check "missing checkout error is explicit" "$(grep -c 'SkillOpt source checkout not found' "$tmp/missing.out" || true)" "1"

export SKILLOPT_SLEEP_REPO="/home/dev/.local/share/skillopt"
export SKILLOPT_PYTHON="$fake_python"
export SKILLOPT_TEST_LOG="$log"
export SKILLOPT_OUTPUT_ROOT="$tmp/out"

(cd "$tmp" && bash "$RUNNER" baseline)
check "baseline dispatches two evaluations" "$(grep -c 'eval.py' "$log")" "2"
check "baseline evaluates selection split" "$(grep -c -- '--split valid_seen' "$log")" "1"
check "baseline evaluates sealed test split" "$(grep -c -- '--split valid_unseen' "$log")" "1"

: >"$log"
bash "$RUNNER" train
check "train dispatches one training command" "$(grep -c 'train.py' "$log")" "1"
check "train uses committed config" "$(grep -c -- '--config .*tools/skillopt-pilot/config.yaml' "$log")" "1"

mkdir -p "$SKILLOPT_OUTPUT_ROOT/train"
printf '%s\n' '# candidate' >"$SKILLOPT_OUTPUT_ROOT/train/best_skill.md"
: >"$log"
bash "$RUNNER" final
check "final evaluates exactly once" "$(grep -c 'eval.py' "$log")" "1"
check "final uses sealed test split only" "$(grep -c -- '--split valid_unseen' "$log")" "1"
check "final evaluates selected candidate" "$(grep -c -- '--skill .*train/best_skill.md' "$log")" "1"

python3 - "$ROOT/tools/skillopt-pilot/config.yaml" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "eval_test: false" in text
assert "codex_exec_network_access: false" in text
assert "codex_exec_web_search: false" in text
PY
check "training config seals test and network" "$?" "0"

echo "---"
echo "skillopt-pilot: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
