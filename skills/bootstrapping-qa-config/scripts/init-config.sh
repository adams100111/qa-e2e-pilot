#!/usr/bin/env bash
# init-config.sh — deterministic writer + inference for .qa/config.json.
# The agent asks the user the gaps, then calls this to WRITE valid JSON (so the
# config is never hand-authored / malformed). `--suggest` prints inferred defaults
# the agent uses to pre-fill its questions.
#
# Write mode:
#   init-config.sh --base-url URL [--environment auto|disposable|production]
#                  [--repos "a,b"] [--api-origin ORIGIN] [--storage-state PATH]
#                  [--allow-writes true|false] [--allow-crawl true|false]
#                  [--seedable-marker NAME] [--out PATH]
# Inference mode:
#   init-config.sh --suggest        # prints {baseUrl, repos, stack} as JSON
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECT="$SELF_DIR/../../detecting-stack-profile/scripts/detect-stack.sh"

BASE_URL=""; ENVIRONMENT="auto"; REPOS="."; API_ORIGIN=""
STORAGE_STATE=".qa/auth/storageState.json"; ALLOW_WRITES="false"; ALLOW_CRAWL="false"
SEEDABLE_MARKER=""; OUT=".qa/config.json"; SUGGEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)        BASE_URL="$2"; shift 2 ;;
    --environment)     ENVIRONMENT="$2"; shift 2 ;;
    --repos)           REPOS="$2"; shift 2 ;;
    --api-origin)      API_ORIGIN="$2"; shift 2 ;;
    --storage-state)   STORAGE_STATE="$2"; shift 2 ;;
    --allow-writes)    ALLOW_WRITES="$2"; shift 2 ;;
    --allow-crawl)     ALLOW_CRAWL="$2"; shift 2 ;;
    --seedable-marker) SEEDABLE_MARKER="$2"; shift 2 ;;
    --out)             OUT="$2"; shift 2 ;;
    --suggest)         SUGGEST=1; shift ;;
    *) echo "init-config: unknown arg: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo "init-config: jq is required" >&2; exit 3; }

# ── inference (--suggest) ─────────────────────────────────────────────────────
infer_base_url() {
  # DDEV: read the project name → https://<name>.ddev.site
  if [[ -f ".ddev/config.yaml" ]]; then
    local name; name="$(grep -E '^name:' .ddev/config.yaml 2>/dev/null | head -1 | sed 's/^name:[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')"
    [[ -n "$name" ]] && { echo "https://${name}.ddev.site"; return; }
  fi
  # Laravel artisan serve default; Vite/Node default; else blank (ask the user).
  if [[ -f "artisan" ]]; then echo "http://localhost:8000"; return; fi
  if [[ -f "package.json" ]]; then echo "http://localhost:3000"; return; fi
  echo ""
}

if [[ "$SUGGEST" -eq 1 ]]; then
  guess_url="$(infer_base_url)"
  stack="unknown"
  if [[ -x "$DETECT" ]]; then
    stack="$(QA_REPOS="." bash "$DETECT" --no-runtime 2>/dev/null | jq -r '.components[0].framework // "unknown"')"
  fi
  jq -n --arg url "$guess_url" --arg repos "." --arg stack "$stack" \
    '{baseUrl:$url, repos:$repos, stack:$stack}'
  exit 0
fi

# ── write mode ────────────────────────────────────────────────────────────────
[[ -n "$BASE_URL" ]] || { echo "init-config: --base-url is required (or use --suggest)" >&2; exit 2; }

# Appendix A (audit-2 W3-7a, highest-value item): --allow-writes/--allow-crawl
# are fed to jq's `--argjson` below, which REQUIRES valid JSON. An invalid
# value (a typo like "yes"/"1"/"flase") used to make that jq call fail AFTER
# the shell had already opened `> "$OUT"` in truncate mode — under this
# script's `set -uo pipefail` (no `-e`), the script did not abort on jq's
# failure, so it fell through to "Wrote $OUT" having silently TRUNCATED any
# pre-existing config at $OUT to 0 bytes. Fail closed HERE, before any file
# is touched, so a bad flag can never destroy an existing .qa/config.json.
for _flag_pair in "allow-writes:$ALLOW_WRITES" "allow-crawl:$ALLOW_CRAWL"; do
  _flag_name="${_flag_pair%%:*}"; _flag_val="${_flag_pair#*:}"
  case "$_flag_val" in
    true|false) ;;
    *) echo "init-config: --${_flag_name} must be 'true' or 'false' (got '${_flag_val}') — refusing to touch ${OUT}" >&2; exit 2 ;;
  esac
done

# repos CSV → array of {role, path}. First entry is the backend (monolith default).
repos_json="$(jq -n '[]')"
IFS=',' read -ra rps <<< "$REPOS"
first=1
for rp in "${rps[@]}"; do
  rp="${rp// /}"; [[ -z "$rp" ]] && continue
  role="reference"; [[ "$first" -eq 1 ]] && { role="backend"; first=0; }
  repos_json="$(jq -c --arg role "$role" --arg path "$rp" '. + [{role:$role, path:$path}]' <<< "$repos_json")"
done

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

# Preserve unknown top-level keys across a re-render (plan decision R14).
# This script renders a FRESH object and installs it over $OUT, so every
# top-level key it does not itself emit used to be silently destroyed on every
# re-run -- including the six keys .qa/config.json.example documents but this
# writer never emits (viewport, responsiveMatrix, persona, detection, passGate,
# fixtures), and `personas`, which only confirming-discovered-roles'
# write-persona-config.sh ever writes. Read the current file FIRST and merge the
# freshly-rendered object OVER it (shallow `$existing + $new` -- the same shape
# qa-kit/scripts/runconfig-merge.sh uses for its deltas): unknown keys survive,
# keys this script owns stay authoritative and are still overwritten. A missing,
# unreadable or non-object file degrades to `{}` (a plain fresh render, never an
# abort), so bootstrapping over a corrupt config still works.
EXISTING_JSON='{}'
if [[ -f "$OUT" ]]; then
  _existing="$(jq -c 'if type == "object" then . else empty end' "$OUT" 2>/dev/null)"
  if [[ -n "$_existing" ]]; then
    EXISTING_JSON="$_existing"
  elif [[ -s "$OUT" ]]; then
    echo "init-config: existing ${OUT} is not a readable JSON object — rendering a fresh config (its keys cannot be preserved)" >&2
  fi
fi

jq -n \
  --arg base "$BASE_URL" --arg api "$API_ORIGIN" --arg ss "$STORAGE_STATE" \
  --arg env "$ENVIRONMENT" --arg marker "$SEEDABLE_MARKER" \
  --argjson repos "$repos_json" \
  --argjson writes "$ALLOW_WRITES" --argjson crawl "$ALLOW_CRAWL" \
  --argjson existing "$EXISTING_JSON" '$existing + {
  "_doc": "Auto-generated by bootstrapping-qa-config. Edit freely; re-run /qa-run to use it.",
  baseUrl: $base,
  apiOrigin: $api,
  auth: { storageState: $ss },
  drivers: [ { id: "managed", server: (env.QA_DRIVER_SERVER // "playwright"), preset: "managed" } ],
  maxParallel: 3,
  repos: $repos,
  allowApiWrites: $writes,
  seedableEnvMarker: $marker,
  environment: $env,
  allowBlackboxCrawl: $crawl,
  fingerprintPaths: ["/openapi.json", "/swagger/v1/swagger.json"],
  noProbePaths: [],
  crawlDenyPatterns: [],
  maxRequestsPerSecond: 2,
  memory: { backend: "file" },
  humanInteraction: { enforce: true, saveSession: true, autonomousSetup: false, maxOptOutRate: 0.2, sessionLogDir: ".playwright-mcp" },
  enforcement: {
    _doc: "Layer 1 (record) of the out-of-agent evidence enforcement (ADR-0018/Plan H2). captureHook: whether the PostToolUse capture-hook (scripts/capture-hook.sh) is active. secretPatterns is left EXPLICIT here (not omitted) so a bootstrapped config never depends on the built-in fail-safe default by accident -- edit this list to fit the project; setting it to [] deliberately opts OUT of pattern-based redaction (an ABSENT secretPatterns key, e.g. if this line is deleted, falls back to the hard-coded DEFAULT_SECRET_PATTERNS_JSON in scripts/toolstream.sh instead of silently disabling redaction). redactedKeys: literal declared credential VALUES (not regexes) redacted wherever they appear as a substring. Bash args AND Bash tool_response (stdout/stderr) are both redacted; browser_* args are captured in FULL (test data) -- a browser_type into a password field can still capture a typed secret, a documented residual.",
    captureHook: true,
    secretPatterns: [
      "(password)\"?\\s*[:=]\\s*\\S+",
      "(passwd)\"?\\s*[:=]\\s*\\S+",
      "(secret)\"?\\s*[:=]\\s*\\S+",
      "(token)\"?\\s*[:=]\\s*\\S+",
      "(api[_-]?key)\"?\\s*[:=]\\s*\\S+",
      "(apikey)\"?\\s*[:=]\\s*\\S+",
      "(authorization)\"?\\s*[:=]\\s*.+",
      "(bearer)\\s+\\S+",
      "(access[_-]?key)\"?\\s*[:=]\\s*\\S+",
      "(private[_-]?key)\"?\\s*[:=]\\s*\\S+",
      "(client[_-]?secret)\"?\\s*[:=]\\s*\\S+"
    ],
    redactedKeys: []
  },
  findings: {
    _doc: "Error-honesty findings classification. benign: an allowlist of POSIX-ERE-compatible regexes (no lookaround/backreferences -- matched via jq built-in regex or python3 re, never grep -P/perl) tested against a finding URL path ONLY -- the path component, not the query string and not the whole URL. A match downgrades that finding to originClass \"benign\", so it can never fail a run; the benign check runs AFTER the origin check, so a rule here can downgrade an in-scope path too. Every entry is a deliberate, human-authored, git-tracked WAIVER of an observed application error -- keep the list short and justified (a favicon rule such as ^/favicon[.]ico$ is the canonical example). FAIL-CLOSED DEFAULT (security/honesty-critical): this list is EMPTY on a fresh bootstrap -- no waivers by default -- and an ABSENT findings block, an unparseable URL, a relative URL or a missing baseUrl all classify as \"in-scope\", never as third-party and never as benign. This block is OWNED by init-config.sh: a re-run re-renders it, so keep hand-added waivers under version control.",
    benign: []
  }
}' > "${OUT}.tmp.$$"; _jq_rc=$?

# Defense-in-depth (belt-and-suspenders alongside the --allow-writes/
# --allow-crawl validation above): write to a temp file, THEN check jq's
# exit code and validate the result parses, THEN move it over $OUT. Never
# redirect jq's stdout directly to $OUT — that truncates $OUT as part of the
# shell's redirection setup regardless of whether jq itself then succeeds,
# which is exactly how the flag-validation bug above was able to destroy a
# pre-existing config on a jq failure.
if [[ "$_jq_rc" -ne 0 ]] || ! jq -e . "${OUT}.tmp.$$" >/dev/null 2>&1; then
  rm -f "${OUT}.tmp.$$"
  echo "init-config: failed to render valid JSON for ${OUT} — nothing was written, existing file (if any) is untouched" >&2
  exit 3
fi
mv -f "${OUT}.tmp.$$" "$OUT" || { rm -f "${OUT}.tmp.$$"; echo "init-config: failed to install ${OUT}" >&2; exit 3; }

# Real-project side effects only when writing into an actual `.qa/` dir
# (skipped when tests write to a temp file).
qadir="$(dirname "$OUT")"
if [[ "$(basename "$qadir")" == ".qa" ]]; then
  mkdir -p "$qadir/auth" "$qadir/runs" 2>/dev/null || true
  if [[ -d .git || -f .gitignore ]]; then
    if ! grep -qxF '.qa/' .gitignore 2>/dev/null; then
      printf '\n# qa-e2e-pilot per-project state\n.qa/\n' >> .gitignore
    fi
  fi
fi

echo "Wrote $OUT"
