#!/usr/bin/env bash
# _lib.sh — shared helpers for the census stack adapters other than laravel.sh (sourced, not run).
# A caller sets ADAPTER=<stack> and USAGE_TEXT before sourcing, then calls parse_args "$@",
# prepare, ... , emit_adapter_json. Contract: adapters/census/README.md.
#
#   parse_args      sets REPO and EXEC_PREFIX (usage error -> exit 1, stderr only)
#   prepare         validates REPO, picks the JSON engine, builds PFX[] from EXEC_PREFIX (whitespace
#                   word-split only, no shell quoting) and creates the work dir W (removed on exit)
#   run_cmd <out> <cmd...>   runs `<prefix> <cmd...>` from REPO into <out>; ok:false + exit 3 on failure
#   emit_adapter_json        prints the adapter JSON from $W/surfaces.tsv ("kind<TAB>METHOD<TAB>pattern
#                            <TAB>confidence", confidence may be empty) and $W/warnings.txt
set -uo pipefail
export LC_ALL=C

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

# json_str <text> — a JSON string literal; control chars become spaces.
json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\t\n\r' '   ' | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}
fail() {
  printf '{"adapter":%s,"error":%s,"ok":false}\n' "$(json_str "$ADAPTER")" "$(json_str "$1")"
  exit 3
}
usage() { echo "usage: $USAGE_TEXT" >&2; exit 1; }

REPO=""; EXEC_PREFIX=""
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)        [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
      --exec-prefix) [ "$#" -ge 2 ] || usage; EXEC_PREFIX="$2"; shift 2 ;;
      *) echo "$ADAPTER.sh: unknown argument: $1" >&2; usage ;;
    esac
  done
  [ -n "$REPO" ] || usage
}

PFX=()
W=""
prepare() {
  [ -d "$REPO" ] || fail "repo not found: $REPO"
  REPO="$(cd "$REPO" && pwd)" || fail "repo not readable: $REPO"
  has_jq || has_py || fail "needs jq or python3"
  [ -n "$EXEC_PREFIX" ] && read -r -a PFX <<< "$EXEC_PREFIX"
  W="$(mktemp -d 2>/dev/null)" || fail "cannot create a temp dir"
  trap 'rm -rf "$W"' EXIT
  : > "$W/surfaces.tsv"; : > "$W/warnings.txt"
}

# run_cmd <outfile> <cmd...> — `<prefix> <cmd...>` from the repo; ok:false (exit 3) on non-zero.
run_cmd() {
  local out="$1" rc msg; shift
  ( cd "$REPO" && ${PFX[@]+"${PFX[@]}"} "$@" ) > "$out" 2> "$W/stderr"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(sed -e '/^[[:space:]]*$/d' "$W/stderr" | head -n 3 | tr '\n' ' ')"
    [ -n "$msg" ] || msg="$(sed -e '/^[[:space:]]*$/d' "$out" | head -n 3 | tr '\n' ' ')"
    fail "$* failed (exit $rc): ${msg:-no output}"
  fi
}

# Same as run_cmd but returns the exit code instead of failing (stderr first line in $W/stderr).
try_cmd() {
  local out="$1"; shift
  ( cd "$REPO" && ${PFX[@]+"${PFX[@]}"} "$@" ) > "$out" 2> "$W/stderr"
}

# add_surface <kind> <METHOD> <pattern> <confidence> — appends to surfaces.tsv.
add_surface() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$W/surfaces.tsv"; }

emit_adapter_json() {
  local out="$W/out.json" err
  if has_jq; then
    jq -n -S -c --arg adapter "$ADAPTER" --rawfile tsv "$W/surfaces.tsv" --rawfile warns "$W/warnings.txt" '
      def lines: split("\n") | map(select(length > 0));
      {adapter: $adapter, ok: true,
       surfaces: ([$tsv | lines[] | split("\t")
                   | {kind: .[0], method: .[1], pattern: .[2], conf: .[3]}]
                  | map({surfaceId: (.method + " " + .pattern), kind, pattern, method,
                         permissionHints: [], source: "adapter"}
                        + (if .conf != "" then {confidence: .conf} else {} end))
                  | unique_by(.surfaceId)),
       jobs: [], mails: [], notifications: [], locales: [],
       warnings: ($warns | lines | unique)}' > "$out" 2> "$W/engine.err"
  else
    python3 - "$W" "$out" "$ADAPTER" <<'PY' 2> "$W/engine.err"
import json, os, sys
w, out, adapter = sys.argv[1:4]
def lines(name):
    with open(os.path.join(w, name), encoding="utf-8") as fh:
        return [x for x in fh.read().split("\n") if len(x) > 0]
seen = {}
for l in lines("surfaces.tsv"):
    p = l.split("\t")
    p += [""] * (4 - len(p))
    s = {"surfaceId": p[1] + " " + p[2], "kind": p[0], "pattern": p[2], "method": p[1],
         "permissionHints": [], "source": "adapter"}
    if p[3] != "": s["confidence"] = p[3]
    seen.setdefault(s["surfaceId"], s)
res = {"adapter": adapter, "ok": True,
       "surfaces": sorted(seen.values(), key=lambda s: s["surfaceId"]),
       "jobs": [], "mails": [], "notifications": [], "locales": [],
       "warnings": sorted(set(lines("warnings.txt")))}
with open(out, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(res, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
PY
  fi
  if [ "$?" -ne 0 ] || [ ! -s "$out" ]; then
    err="$(sed -e '/^[[:space:]]*$/d' "$W/engine.err" | head -n 1)"
    fail "adapter could not build output: ${err:-no engine message}"
  fi
  cat "$out"
}

# Path helpers (sed -E programs, shared by the scanners).
# norm_path: squeeze slashes, ensure one leading slash (empty -> "/").
norm_path() { [ -n "$1" ] || { echo "/"; return; }; printf '%s' "$1" | sed -E -e 's|/+|/|g' -e 's|^([^/])|/\1|' -e 's|^$|/|'; }
