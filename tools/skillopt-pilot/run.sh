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

# ── Backend / model selection (env-overridable) ──────────────────────────────
# The committed config.yaml defaults to codex_exec + gpt-5.5. Override without
# editing any committed file:
#   SKILLOPT_BACKEND   — sets BOTH optimizer & target backend
#   SKILLOPT_MODEL     — sets BOTH optimizer & target model
# Fine-grained (win over the shorthands above):
#   SKILLOPT_OPTIMIZER_BACKEND / SKILLOPT_TARGET_BACKEND
#   SKILLOPT_OPTIMIZER_MODEL   / SKILLOPT_TARGET_MODEL
# Examples:
#   SKILLOPT_BACKEND=claude_code_exec SKILLOPT_MODEL=sonnet bash run.sh experiment
#   SKILLOPT_BACKEND=codex_exec       SKILLOPT_MODEL=gpt-5.5 bash run.sh train
OPT_BACKEND="${SKILLOPT_OPTIMIZER_BACKEND:-${SKILLOPT_BACKEND:-}}"
TGT_BACKEND="${SKILLOPT_TARGET_BACKEND:-${SKILLOPT_BACKEND:-}}"
OPT_MODEL="${SKILLOPT_OPTIMIZER_MODEL:-${SKILLOPT_MODEL:-}}"
TGT_MODEL="${SKILLOPT_TARGET_MODEL:-${SKILLOPT_MODEL:-}}"

model_opts=()
[[ -n "$OPT_BACKEND" ]] && model_opts+=("model.optimizer_backend=$OPT_BACKEND")
[[ -n "$TGT_BACKEND" ]] && model_opts+=("model.target_backend=$TGT_BACKEND")
[[ -n "$OPT_MODEL"   ]] && model_opts+=("model.optimizer=$OPT_MODEL")
[[ -n "$TGT_MODEL"   ]] && model_opts+=("model.target=$TGT_MODEL")
# Exec backends (claude_code_exec/codex_exec) also read the model from these:
[[ -n "$TGT_MODEL" ]] && export TARGET_DEPLOYMENT="$TGT_MODEL"
[[ -n "$OPT_MODEL" ]] && export OPTIMIZER_DEPLOYMENT="$OPT_MODEL"
# Let experiment.py (which spawns its own train.py) honor the same selection.
export SKILLOPT_BACKEND SKILLOPT_MODEL SKILLOPT_OPTIMIZER_BACKEND \
       SKILLOPT_TARGET_BACKEND SKILLOPT_OPTIMIZER_MODEL SKILLOPT_TARGET_MODEL 2>/dev/null || true

# The required local agent CLI depends on the selected exec backend
# (default = codex, from config.yaml). Chat backends need no local CLI.
effective_backend="${TGT_BACKEND:-${OPT_BACKEND:-codex_exec}}"
case "$effective_backend" in
  claude_code_exec) required_cli="claude" ;;
  cursor_exec)      required_cli="cursor-agent" ;;
  copilot_exec)     required_cli="copilot" ;;
  codex_exec)       required_cli="codex" ;;
  *)                required_cli="" ;;
esac
if [[ -n "$required_cli" ]] && ! command -v "$required_cli" >/dev/null 2>&1; then
  echo "Required CLI '$required_cli' for backend '$effective_backend' not found on PATH" >&2
  exit 2
fi

# For claude_code_exec, route the target/optimizer through an MCP-isolated
# wrapper so ambient MCP connectors (e.g. claude.ai account connectors) can't
# inject a tool schema the Anthropic API rejects (HTTP 400), which silently
# zeroes every rollout. NOTE: SkillOpt resets the claude path from cfg on every
# run (default "claude"), IGNORING CLAUDE_CODE_EXEC_PATH — so the wrapper MUST be
# passed as a cfg-option, not just an env var. use_sdk=cli skips the futile
# claude_agent_sdk attempt (module not installed). Opt out of MCP isolation with
# SKILLOPT_CLAUDE_ALLOW_MCP=1 (honored inside the wrapper).
if [[ "$effective_backend" == "claude_code_exec" ]]; then
  : "${SKILLOPT_CLAUDE_PATH:=$PILOT/claude-clean.sh}"
  model_opts+=("model.claude_code_exec_path=$SKILLOPT_CLAUDE_PATH")
  model_opts+=("model.claude_code_exec_use_sdk=cli")
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
  ${model_opts[@]+"${model_opts[@]}"}
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
