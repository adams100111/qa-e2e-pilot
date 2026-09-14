#!/usr/bin/env bash
# Copy this benchmark into a SkillOpt checkout so `skillopt-train` can load it.
#
# The repo copy is the source of truth; this only *adds* files to the SkillOpt
# checkout (a new env dir + a config dir). It never edits SkillOpt's own source.
# The one manual step it cannot do safely for you — patching the env registry —
# is PRINTED at the end for you to paste. Re-runnable (idempotent copy).
#
# Usage: SKILLOPT_REPO=~/.local/share/skillopt \
#        bash install-into-skillopt.sh
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_REPO="$(cd "$BENCH_DIR/../../.." && pwd)"
SKILLOPT_REPO="${SKILLOPT_REPO:-$HOME/.local/share/skillopt}"
ENV_NAME="detecting_stack_profile"          # underscores: valid Python package
DEST="$SKILLOPT_REPO/skillopt/envs/$ENV_NAME"
CFG_DEST="$SKILLOPT_REPO/configs/$ENV_NAME"

[ -d "$SKILLOPT_REPO/skillopt/envs" ] || { echo "Not a SkillOpt checkout: $SKILLOPT_REPO" >&2; exit 1; }

echo "Copying benchmark -> $DEST"
mkdir -p "$DEST" "$CFG_DEST"
cp "$BENCH_DIR"/{__init__.py,env.py,dataloader.py,scorer.py} "$DEST/"
cp -r "$BENCH_DIR/data" "$DEST/data"
cp -r "$BENCH_DIR/fixtures" "$DEST/fixtures"

# Point env.py's fixture lookup at the copied fixtures (it resolves relative to
# its own file, so the copy Just Works — no rewrite needed).

# Render config with the real repo path substituted for <REPO>.
sed "s#<REPO>#$QA_REPO#g" "$BENCH_DIR/config/default.yaml" > "$CFG_DEST/default.yaml"
echo "Wrote $CFG_DEST/default.yaml (skill_init -> $QA_REPO/skills/detecting-stack-profile/SKILL.md)"

cat <<EOF

── FINAL MANUAL STEP (register the env) ─────────────────────────────────────
Add this block to _register_builtins() in BOTH files:
  $SKILLOPT_REPO/scripts/train.py
  $SKILLOPT_REPO/scripts/eval_only.py

    try:
        from skillopt.envs.$ENV_NAME.env import DetectingStackProfileEnv
        _ENV_REGISTRY["$ENV_NAME"] = DetectingStackProfileEnv
    except ImportError:
        pass

Then, from $SKILLOPT_REPO:
    # zero-spend structure check first (uses the qa-e2e-pilot detector):
    python3 "$QA_REPO/benchmarks/skillopt/detecting-stack-profile/sanity.py"
    # then a real (spending) optimization run:
    skillopt-train --config configs/$ENV_NAME/default.yaml
─────────────────────────────────────────────────────────────────────────────
EOF
