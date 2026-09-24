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
# empty or PARSEABLE-but-not-an-object file degrades to `{}` (a plain fresh
# render, never an abort), so bootstrapping over a corrupt config still works --
# but a file that exists and cannot be READ is refused outright (below).
EXISTING_JSON='{}'
if [[ -f "$OUT" ]]; then
  # A config we cannot READ must never be overwritten: that would destroy its
  # keys PRECISELY BECAUSE they were unreadable -- the exact failure class this
  # preservation exists to remove. Refuse, loudly, before anything is written.
  # (`head -c 1` is the honest probe: it reflects what this process can actually
  # read, unlike `[[ -r ]]`, which lies for root.)
  if [[ -s "$OUT" ]] && ! head -c 1 "$OUT" >/dev/null 2>&1; then
    echo "init-config: cannot read the existing ${OUT} (permission denied / unreadable) — refusing to overwrite a config whose contents could not be preserved. Fix its permissions (e.g. chmod u+r ${OUT}) or move it aside, then re-run." >&2
    exit 3
  fi
  # `jq -c` runs its program once PER input, so a JSON *stream* (two
  # concatenated objects in one file) emits TWO values and would make the
  # --argjson below reject the lot with raw jq noise. Slurp (-s) and take only
  # the FIRST value: a stream degrades to its first object instead of aborting
  # the bootstrap. An unparseable file makes jq fail => empty => `{}`.
  _existing="$(jq -c -s 'if (.[0] | type) == "object" then .[0] else empty end' "$OUT" 2>/dev/null)"
  if [[ -n "$_existing" ]]; then
    EXISTING_JSON="$_existing"
  elif [[ -s "$OUT" ]]; then
    echo "init-config: existing ${OUT} is not a parseable JSON object — rendering a fresh config (its keys cannot be preserved)" >&2
  fi
fi

# `findings.benign` is SEED-IF-ABSENT, PRESERVE-IF-PRESENT -- the one owned key
# that a re-render does NOT reset. Its entries are human-authored waivers, and
# this script appends `.qa/` to the project's .gitignore, so the config is NOT
# version-controlled by default: a reset would destroy a waiver with no recovery
# path. A stale waiver stays visible (the report still records the finding and
# the rule that downgraded it); a vanished one does not. Every OTHER owned key
# (maxParallel, enforcement, ...) keeps its authoritative overwrite behaviour.
PRESERVED_BENIGN='[]'
_benign="$(jq -c '.findings.benign // empty' <<< "$EXISTING_JSON" 2>/dev/null)"
if [[ -n "$_benign" ]]; then
  if jq -e 'type == "array"' <<< "$_benign" >/dev/null 2>&1; then
    PRESERVED_BENIGN="$_benign"
  else
    echo "init-config: existing ${OUT} has a non-array findings.benign — seeding an empty (fail-closed) allowlist instead; re-add your waivers as a JSON array" >&2
  fi
fi

jq -n \
  --arg base "$BASE_URL" --arg api "$API_ORIGIN" --arg ss "$STORAGE_STATE" \
  --arg env "$ENVIRONMENT" --arg marker "$SEEDABLE_MARKER" \
  --argjson repos "$repos_json" \
  --argjson writes "$ALLOW_WRITES" --argjson crawl "$ALLOW_CRAWL" \
  --argjson existing "$EXISTING_JSON" --argjson benign "$PRESERVED_BENIGN" '$existing + {
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
  findings: (($existing.findings // {}) + {
    _doc: "Error-honesty findings classification. benign: an allowlist of POSIX ERE regexes (no lookaround/backreferences) matched by grep -E in scripts/classify-finding.sh -- deliberately grep, NOT the JSON engine, so the jq and python3 paths cannot diverge on regex semantics; grep -P is never used, and an invalid pattern is skipped with a warning rather than silently matching. Tested against a finding URL path ONLY -- the path component, not the query string and not the whole URL. A match downgrades that finding to originClass \"benign\", so it can never fail a run; the benign check runs AFTER the origin check, so a rule here can downgrade an in-scope path too. Every entry is a deliberate, human-authored WAIVER of an observed application error -- keep the list short and justified (a favicon rule such as ^/favicon[.]ico$ is the canonical example). FAIL-CLOSED DEFAULT (honesty-critical): this list is EMPTY on a fresh bootstrap -- no waivers by default -- and an ABSENT findings block is the same empty allowlist, never a permissive one. Origin still decides originClass on its own: a cross-origin URL is third-party whether or not this block exists, and only a genuinely unknowable origin (an unparseable URL, a relative URL, or a missing baseUrl) is forced fail-closed to \"in-scope\". PERSISTENCE: unlike every other key this script owns, benign is SEED-IF-ABSENT and PRESERVE-IF-PRESENT -- a re-run of the bootstrap will NOT reset your waivers. It cannot rely on you having them in git: this same script gitignores this file (it writes a .qa/* rule into the project .gitignore), so .qa/config.json is untracked by default. The ONE .qa/ file that rule deliberately keeps TRACKED is .qa/known-defects.json, whose 90-day expiry cap depends on a renewal being a visible diff.",
    benign: $benign
  })
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
    # `.qa/` is scratch state, with ONE exception: `.qa/known-defects.json` must
    # stay TRACKED. The registry's 90-day expiry cap (ruling R2) is enforced by
    # a renewal being a deliberate act, visible in a diff and reviewable in a
    # PR; an untracked registry makes a renewal invisible and turns the cap back
    # into "deferred by design" under a new name.
    #
    # THE ORDER AND THE EXACT PATTERNS BELOW ARE LOAD-BEARING (verified with
    # `git check-ignore -v`, not reasoned about; see tests/init-config):
    #   * git CANNOT re-include a file whose PARENT DIRECTORY is excluded, so a
    #     bare `.qa/` makes `!.qa/known-defects.json` DEAD (the directory rule
    #     still wins). Exclude the directory's ENTRIES -- `.qa/*` -- instead.
    #   * appending `.qa/*` is NOT enough on its own when a bare `.qa/` (or a
    #     slashless `.qa`) is ALREADY present from an older bootstrap or a hand
    #     edit -- that directory rule still wins. `!.qa/` un-excludes the
    #     directory first so the entry-level rules can take effect. It is a
    #     harmless no-op when nothing excluded `.qa` in the first place.
    # Each line is added only if absent, so a second bootstrap duplicates
    # nothing and a hand-edited .gitignore is only ever appended to.
    _gi_add=""
    grep -qxF '!.qa/' .gitignore 2>/dev/null                   || _gi_add="${_gi_add}!.qa/"$'\n'
    grep -qxF '.qa/*' .gitignore 2>/dev/null                   || _gi_add="${_gi_add}.qa/*"$'\n'
    grep -qxF '!.qa/known-defects.json' .gitignore 2>/dev/null || _gi_add="${_gi_add}!.qa/known-defects.json"$'\n'
    if [[ -n "$_gi_add" ]]; then
      printf '\n# qa-e2e-pilot per-project state. `.qa/` is scratch (runs, auth,\n# config) EXCEPT the known-defects registry, which stays tracked on purpose:\n# the 90-day expiry cap only bites if renewing a waiver is a visible diff.\n# `.qa/*` + `!.qa/` (not a bare `.qa/`) because git cannot re-include a file\n# inside an excluded directory -- do not "simplify" these three lines.\n%s' "$_gi_add" >> .gitignore
    fi
  fi
fi

echo "Wrote $OUT"
