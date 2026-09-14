#!/usr/bin/env bash
set -euo pipefail

PILOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$PILOT/../.." && pwd)"
SOURCE="${SKILLOPT_SLEEP_REPO:-/home/dev/.local/share/skillopt}"
OUTPUT="${SKILLOPT_OUTPUT_ROOT:-$ROOT/outputs/skillopt/stack-profile}"
CONFIG="$PILOT/config.yaml"
SEED_SKILL="$ROOT/skills/detecting-stack-profile/SKILL.md"

# Zero-spend deterministic baseline / consistency gate. Dispatched BEFORE the
# codex + SkillOpt-venv guards below because it needs neither — only python3 +
# the skill's own detect-stack.sh. Forwards remaining args (e.g. --gate).
if [[ "${1:-}" == "detect-baseline" ]]; then
  shift
  exec python3 "$PILOT/baseline_offline.py" "$@"
fi

if [[ ! -f "$SOURCE/scripts/train.py" || ! -f "$SOURCE/scripts/eval_only.py" ]]; then
  echo "SkillOpt source checkout not found: $SOURCE" >&2
  exit 2
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI is required but was not found on PATH" >&2
  exit 2
fi

if [[ -n "${SKILLOPT_PYTHON:-}" ]]; then
  PYTHON="$SKILLOPT_PYTHON"
elif [[ -x "$SOURCE/.venv/bin/python" ]]; then
  PYTHON="$SOURCE/.venv/bin/python"
else
  echo "SkillOpt Python environment not found; run: uv sync --project $SOURCE" >&2
  exit 2
fi

common=(
  --config "$CONFIG"
  --cfg-options
  "env.split_dir=$PILOT/data"
  "env.fixtures_dir=$PILOT/fixtures"
  "env.runtime_dir=$ROOT/skills/detecting-stack-profile"
)

mode="${1:-verify}"
case "$mode" in
  verify)
    exec python3 -m unittest \
      "$ROOT/tests/skillopt-pilot/test_core.py" \
      "$ROOT/tests/skillopt-pilot/test_integration.py" -v
    ;;
  baseline)
    mkdir -p "$OUTPUT/baseline/validation" "$OUTPUT/baseline/test"
    "$PYTHON" "$PILOT/eval.py" "${common[@]}" \
      --skill "$SEED_SKILL" --split valid_seen --out_root "$OUTPUT/baseline/validation"
    "$PYTHON" "$PILOT/eval.py" "${common[@]}" \
      --skill "$SEED_SKILL" --split valid_unseen --out_root "$OUTPUT/baseline/test"
    ;;
  train)
    mkdir -p "$OUTPUT/train"
    "$PYTHON" "$PILOT/train.py" "${common[@]}" \
      "env.skill_init=$SEED_SKILL" "env.out_root=$OUTPUT/train"
    ;;
  experiment)
    exec "$PYTHON" "$PILOT/experiment.py" \
      --python "$PYTHON" --root "$ROOT" --pilot "$PILOT" \
      --output "$OUTPUT/iteration-2"
    ;;
  final)
    candidate="$OUTPUT/train/best_skill.md"
    if [[ ! -f "$candidate" ]]; then
      echo "Selected candidate not found: $candidate" >&2
      exit 3
    fi
    mkdir -p "$OUTPUT/final/test"
    "$PYTHON" "$PILOT/eval.py" "${common[@]}" \
      --skill "$candidate" --split valid_unseen --out_root "$OUTPUT/final/test"
    ;;
  *)
    echo "Usage: $0 {verify|detect-baseline|baseline|train|experiment|final}" >&2
    exit 2
    ;;
esac
