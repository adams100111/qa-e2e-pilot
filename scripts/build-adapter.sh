#!/usr/bin/env bash
# scripts/build-adapter.sh <harness> — assemble dist/<harness>/ from core + profile + glue.
set -euo pipefail
H="${1:?usage: build-adapter.sh <claude|codex|pi|opencode>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES="$ROOT/harness-profiles.json"
OUT="$ROOT/dist/$H"

# --- read the profile fields for this harness via python3 (jq-free) ---
read_field() { python3 -c "import json,sys;print(json.load(open('$PROFILES'))['harnesses']['$H']['$1'])"; }
PREFIX="$(read_field toolPrefix)"; SERVER_KEY="$(read_field serverKey)"
GRANT="$(read_field grantStyle)"; MODEL_FIELD="$(read_field modelField)"
TIER_DEFAULT="$(read_field tierDefault)"; TIER_HEAVY="$(read_field tierHeavy)"
DISPATCH="$(read_field dispatch)"; ROLES_DIR="$(read_field globalRolesDir)"

# --- render the browser-tools grant per grantStyle ---
render_browser_tools() {
  local caps; caps="$(python3 -c "import json;print(' '.join(json.load(open('$PROFILES'))['capabilities']))")"
  case "$GRANT" in
    list)  local out=""; for c in $caps; do out="${out:+$out, }${PREFIX}${c}"; done; printf '%s' "$out" ;;
    scope) printf '%s' "" ;;   # server-scoped: handled by mcp_servers in the template
    proxy) printf '%s' "" ;;   # proxy tool 'mcp' already in the template
    glob)  printf '%s' "" ;;   # glob '<server>*' already in the template
  esac
}
BROWSER_TOOLS="$(render_browser_tools)"

# --- render the model-field line (Claude pins; others inherit) ---
if [ -n "$MODEL_FIELD" ]; then MODEL_FIELD_LINE="model: $MODEL_FIELD"$'\n'; else MODEL_FIELD_LINE=""; fi

# --- detokenize a file from stdin using the resolved values ---
# NOTE: the render script is written to its own temp file (not fed to `python3 -` via a
# heredoc) — `python3 - <<'PY' ... PY` makes the heredoc BE python's stdin (the program
# source), leaving nothing for the script's own `sys.stdin.read()` to consume, so a naive
# `python3 - <<'PY'` here would silently render everything to empty output regardless of
# what was piped in via `render < file`.
RENDER_PY="$(mktemp)"
cat > "$RENDER_PY" <<'PY'
import sys,os
data=sys.stdin.read()
repl={
 "{{PERSONA_BODY}}":  open(os.environ["PERSONA_BODY_FILE"]).read().rstrip("\n"),
 "{{BROWSER_TOOLS}}": os.environ["BROWSER_TOOLS"],
 "{{MODEL_FIELD_LINE}}": os.environ["MODEL_FIELD_LINE"],
 "{{TIER_DEFAULT}}":  os.environ["TIER_DEFAULT"],
 "{{TIER_HEAVY}}":    os.environ["TIER_HEAVY"],
 "{{DISPATCH}}":      os.environ["DISPATCH"],
 "{{GLOBAL_ROLES_DIR}}": os.environ["ROLES_DIR"],
 "{{SERVER_KEY}}":    os.environ["SERVER_KEY"],
}
for k,v in repl.items(): data=data.replace(k,v)
sys.stdout.write(data)
PY
render() { python3 "$RENDER_PY"; }
export BROWSER_TOOLS MODEL_FIELD_LINE TIER_DEFAULT TIER_HEAVY DISPATCH ROLES_DIR SERVER_KEY

# --- persona body: detokenize tiers first, into a temp file the manifest render inlines ---
PERSONA_BODY_FILE="$(mktemp)"; export PERSONA_BODY_FILE
# both mktemp temp files (RENDER_PY above, PERSONA_BODY_FILE here) now exist — trap their
# cleanup on every exit path (success, or an `exit 1` from the codex ''' guard or the
# residual-token check below), not just the happy-path tail.
trap 'rm -f "$PERSONA_BODY_FILE" "$RENDER_PY" 2>/dev/null || true' EXIT
TIER_DEFAULT="$TIER_DEFAULT" TIER_HEAVY="$TIER_HEAVY" \
  render < "$ROOT/core/persona-body.md" > "$PERSONA_BODY_FILE"

# --- assemble dist/<h> ---
rm -rf "$OUT"; mkdir -p "$OUT/agent" "$OUT/commands"
# core copied verbatim
cp -R "$ROOT/skills" "$ROOT/scripts" "$ROOT/docs" "$ROOT/CONTEXT.md" "$OUT/" 2>/dev/null || true
cp -R "$ROOT/tools" "$OUT/" 2>/dev/null || true
# internal planning docs (docs/plans, docs/specs) are authoring scratch for this repo's own
# development, not grounding material the shipped agent needs — never bundle them into an
# adapter's dist/<h>/docs/.
rm -rf "$OUT/docs/plans" "$OUT/docs/specs"
# agent manifest (extension per harness)
case "$H" in claude|pi|opencode) EXT=md ;; codex) EXT=toml ;; esac
# codex embeds the body in a TOML literal '''...''' string — assert the body has no literal '''
if [ "$H" = codex ] && grep -q "'''" "$ROOT/core/persona-body.md"; then
  echo "ERROR: persona body contains ''' which breaks the codex TOML literal string" >&2; exit 1
fi
render < "$ROOT/harnesses/$H/manifest.tmpl" > "$OUT/agent/qa-e2e-pilot.$EXT"
# commands
render < "$ROOT/core/commands/qa-run.md"    > "$OUT/commands/qa-run.md"
render < "$ROOT/core/commands/qa-roles.md"  > "$OUT/commands/qa-roles.md"
render < "$ROOT/core/commands/qa-resume.md" > "$OUT/commands/qa-resume.md"
# mcp snippet (created in Tasks 4-6; claude has none — uses the official plugin)
[ -f "$ROOT/harnesses/$H/mcp.snippet" ] && cp "$ROOT/harnesses/$H/mcp.snippet" "$OUT/mcp.snippet"

# --- fail if any token survived in the RENDERED output ---
# (only agent/ and commands/ are templated by this script; skills/scripts/docs/tools are
# copied verbatim and may legitimately contain unrelated {{...}} — e.g. writing-qa-reports'
# runtime report templates, filled by the agent at run time, not by this build step)
if grep -rn '{{' "$OUT/agent" "$OUT/commands" ; then echo "ERROR: unrendered token in dist/$H" >&2; exit 1; fi
echo "built dist/$H"
