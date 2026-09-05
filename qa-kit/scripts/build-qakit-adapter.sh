#!/usr/bin/env bash
# build-qakit-adapter.sh <claude|pi|codex|opencode> — assemble qa-kit/dist/<h>/ from qa-kit/core +
# qa-kit/harness-profiles.qakit.json + qa-kit/harnesses/<h>/. Mirrors scripts/build-adapter.sh (ADR-0017),
# qa-kit-owned so the engine stays untouched. Renders three token families per harness:
#   {{SKILL_REF:<name>}} -> the profile's skillRef template ({name} substituted)  (the 7 engine skills)
#   {{ENGINE_RUN}}       -> the profile's engineRun string                        (the engine's qa-run command)
#   {{PLUGIN_ROOT}}      -> the profile's pluginRoot                              (qa-kit's OWN scripts/templates root)
#   {{PERSONA_BODY}}     -> qa-kit/core/persona-body.md (agent manifest only)
# Bare /qa-<step> command refs are intentionally NOT tokenized (they read fine on every harness).
# NEVER modifies the engine. Output qa-kit/dist/<h>/ is git-ignored.
set -euo pipefail
H="${1:?usage: build-qakit-adapter.sh <claude|pi|codex|opencode>}"
QAKIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$QAKIT/harness-profiles.qakit.json"
OUT="$QAKIT/dist/$H"

# --- codex TOML literal guard (mirror scripts/build-adapter.sh:78-80) ---
if [ "$H" = codex ] && grep -q "'''" "$QAKIT/core/persona-body.md"; then
  echo "ERROR: persona body contains ''' — breaks the codex TOML literal string" >&2; exit 1
fi

# --- render script (its own temp file; a heredoc into `python3 -` would consume its own program as stdin) ---
RENDER_PY="$(mktemp)"
cat > "$RENDER_PY" <<'PY'
import sys, os, re, json
h = os.environ["H"]
prof = json.load(open(os.environ["PROFILE"]))["harnesses"][h]
data = sys.stdin.read()
data = re.sub(r"\{\{SKILL_REF:([a-z0-9-]+)\}\}",
              lambda m: prof["skillRef"].replace("{name}", m.group(1)), data)
data = data.replace("{{ENGINE_RUN}}", prof["engineRun"])
data = data.replace("{{PLUGIN_ROOT}}", prof["pluginRoot"])
pbf = os.environ.get("PERSONA_BODY_FILE")
if pbf:
    data = data.replace("{{PERSONA_BODY}}", open(pbf).read().rstrip("\n"))
sys.stdout.write(data)
PY
trap 'rm -f "$RENDER_PY" "${PERSONA_BODY_FILE:-}" 2>/dev/null || true' EXIT
export H PROFILE
render() { python3 "$RENDER_PY"; }

# --- assemble ---
rm -rf "$OUT"; mkdir -p "$OUT/agent" "$OUT/commands"
# command bodies (persona token absent here, so PERSONA_BODY_FILE unset -> untouched)
for f in "$QAKIT"/core/commands/*.md; do
  render < "$f" > "$OUT/commands/$(basename "$f")"
done
# agent manifest: render persona body to a temp file, then render the harness manifest wrapper
PERSONA_BODY_FILE="$(mktemp)"; export PERSONA_BODY_FILE
render < "$QAKIT/core/persona-body.md" > "$PERSONA_BODY_FILE"
EXT="$(python3 -c "import json;print(json.load(open('$PROFILE'))['harnesses']['$H']['agentExt'])")"
render < "$QAKIT/harnesses/$H/manifest.tmpl" > "$OUT/agent/qa-kit.$EXT"
# (PERSONA_BODY_FILE stays set so the EXIT trap cleans it — do NOT unset it here, or the trap's
#  "${PERSONA_BODY_FILE:-}" expands empty and the mktemp'd file leaks. Nothing renders after this.)
# qa-kit's own scripts + templates copied verbatim (reached via {{PLUGIN_ROOT}} at run time)
cp -R "$QAKIT/scripts" "$OUT/scripts"
[ -d "$QAKIT/templates" ] && cp -R "$QAKIT/templates" "$OUT/templates"
# do not ship the generator/validator/profile into the adapter
rm -f "$OUT/scripts/build-qakit-adapter.sh" "$OUT/scripts/validate-qakit-adapters.sh"

# --- fail on any residual token in the rendered agent/commands ---
if grep -rn '{{' "$OUT/agent" "$OUT/commands"; then
  echo "ERROR: unrendered token in qa-kit/dist/$H" >&2; exit 1
fi
echo "built qa-kit/dist/$H"
