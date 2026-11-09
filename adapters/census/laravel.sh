#!/usr/bin/env bash
# laravel.sh — census stack adapter for Laravel apps. Reads the app's own route list, front-end page
# directories, mail/notification classes, lang dirs and schedule, and prints the adapter JSON that
# scripts/census.sh consumes. Contract: adapters/census/README.md. Dual-engine (jq | python3,
# byte-identical output).
#
# USAGE:
#   laravel.sh --repo <path> [--exec-prefix "<prefix>"]
#
#   --repo          the Laravel app root (holds `artisan`); every artisan call runs from here.
#   --exec-prefix   config `exec.prefix` (D4), prepended word-split to every artisan call, e.g.
#                   "ddev exec", "devenv shell --", "docker compose exec -T app". Default "".
#
# COMMANDS RUN (from --repo):  <prefix> php artisan route:list --json
#                              <prefix> php artisan schedule:list
#
# SCANNED (relative to --repo, read-only):
#   pages          resources/js/pages, resources/js/Pages        -> page:<Path/Name>
#                  Modules/<M>/resources/js/pages                -> page:<M>::<Path/Name>
#                  (*.tsx|*.jsx|*.vue|*.svelte; *.test.*, *.spec.*, *.stories.* and anything under a
#                  components|partials|hooks|lib|utils|types|__tests__ dir are not pages)
#   mails          app/Mail, Modules/*/app/Mail                  -> FQCN (file namespace, else path)
#   notifications  app/Notifications, Modules/*/app/Notifications
#   locales        lang/, resources/lang/ (*.json names + subdirs, `vendor` excluded)
#
# OUTPUT (stdout, compact, keys sorted, raw UTF-8):
#   {adapter:"laravel", ok:true, surfaces:[{surfaceId, kind, pattern, method, permissionHints, source}],
#    jobs:[{id, schedule}], mails:[{id}], notifications:[{id}], locales:[...], warnings:[...]}
#   Endpoints: one surface per method ("GET|HEAD" -> GET; "PUT|PATCH" -> PUT and PATCH), surfaceId
#   "<METHOD> /<uri>". permissionHints = middleware matching can:|permission:|role:|license.feature:
#   (a resolved `...\Authorize:<ability>` is reported as `can:<ability>`). Routes under _ignition,
#   telescope, horizon, sanctum/csrf-cookie are skipped and named in warnings.
#
# EXIT: 0 ok:true printed; 3 ok:false printed ({adapter, ok:false, error}) — missing php, non-zero
#       artisan, malformed route JSON, missing repo, no engine; 1 usage error (stderr only).
#       A jq/python3 failure while building the output reports "adapter could not build output: <engine
#       message>"; the exec prefix is split on whitespace only (no shell quoting).
# DEPENDENCIES: bash (3.2-safe), coreutils, find, awk, sed, EITHER jq OR python3. QA_ENGINE=jq|python3.
set -uo pipefail

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
  printf '{"adapter":"laravel","error":%s,"ok":false}\n' "$(json_str "$1")"
  exit 3
}
usage() { echo "usage: laravel.sh --repo <path> [--exec-prefix \"<prefix>\"]" >&2; exit 1; }

REPO=""; EXEC_PREFIX=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)        [ "$#" -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --exec-prefix) [ "$#" -ge 2 ] || usage; EXEC_PREFIX="$2"; shift 2 ;;
    *) echo "laravel.sh: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$REPO" ] || usage
[ -d "$REPO" ] || fail "repo not found: $REPO"
REPO="$(cd "$REPO" && pwd)" || fail "repo not readable: $REPO"
has_jq || has_py || fail "needs jq or python3"

PFX=()
[ -n "$EXEC_PREFIX" ] && read -r -a PFX <<< "$EXEC_PREFIX"
if [ "${#PFX[@]}" -eq 0 ] && ! command -v php >/dev/null 2>&1; then
  fail "php: command not found (set exec.prefix if PHP runs in a container or dev shell)"
fi

W="$(mktemp -d 2>/dev/null)" || fail "cannot create a temp dir"
trap 'rm -rf "$W"' EXIT
export LC_ALL=C

# artisan <outfile> <args...> — `<prefix> php artisan <args>` from the repo; ok:false on non-zero.
artisan() {
  local out="$1" rc msg; shift
  ( cd "$REPO" && ${PFX[@]+"${PFX[@]}"} php artisan "$@" ) > "$out" 2> "$W/stderr"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    msg="$(sed -e '/^[[:space:]]*$/d' "$W/stderr" | head -n 3 | tr '\n' ' ')"
    [ -n "$msg" ] || msg="$(sed -e '/^[[:space:]]*$/d' "$out" | head -n 3 | tr '\n' ' ')"
    fail "php artisan $* failed (exit $rc): ${msg:-no output}"
  fi
}

artisan "$W/routes.json" route:list --json
artisan "$W/schedule.txt" schedule:list

# schedule:list text -> "<id>\t<cron>" per task. A line is 5 cron fields (+ optional 6th seconds
# field when more text follows), then the command; the "..... Next Due: …" leader is dropped and a
# leading `php artisan` (plain or quoted) is stripped so the id is the artisan command name.
ESC="$(printf '\033')"
sed -e "s/${ESC}\[[0-9;]*[A-Za-z]//g" "$W/schedule.txt" | awk '
  function iscron(t) { return t ~ /^[0-9*\/,?LW#-]+$/ }
  {
    n = 0
    while (n < NF && n < 6 && iscron($(n + 1))) n++
    if (n == 6 && NF == 6) n = 5
    if (n < 5 || n >= NF) next
    cron = $1; for (i = 2; i <= n; i++) cron = cron " " $i
    cmd = $(n + 1); for (i = n + 2; i <= NF; i++) cmd = cmd " " $i
    sub(/[ ]*\.\.+.*$/, "", cmd)
    sub(/[ ]*Next Due:.*$/, "", cmd)
    sub(/^'"'"'?[^ ]*php[^ ]*'"'"'?[ ]+'"'"'?artisan'"'"'?[ ]+/, "", cmd)
    if (cmd != "") printf "%s\t%s\n", cmd, cron
  }' > "$W/jobs.tsv"

: > "$W/pages.txt"; : > "$W/mails.txt"; : > "$W/notifications.txt"; : > "$W/locales.txt"; : > "$W/warnings.txt"

# list_pages <dir> <prefix> — page component names under one page dir. A failing find is a warning,
# never silently fewer pages. The prefix reaches awk through ENVIRON (not -v, which interprets backslash escapes), never a program text.
list_pages() {
  if ! ( cd "$1" && find . -type f \( -name '*.tsx' -o -name '*.jsx' -o -name '*.vue' -o -name '*.svelte' \) ) > "$W/found-pages.txt" 2> "$W/find.err"; then
    echo "pages: could not scan $1: $(sed -e '/^[[:space:]]*$/d' "$W/find.err" | head -n 1)" >> "$W/warnings.txt"
    return 0
  fi
  sed -e 's|^\./||' "$W/found-pages.txt" \
    | grep -Ev '(^|/)(components|partials|hooks|lib|utils|types|__tests__)/' \
    | grep -Ev '\.(test|spec|stories)\.[^./]+$' \
    | sed -e 's/\.[^./]*$//' \
    | PAGE_PREFIX="$2" awk '{ print ENVIRON["PAGE_PREFIX"] $0 }' >> "$W/pages.txt"
}
FOUND_PAGES=0
for d in "$REPO/resources/js/pages" "$REPO/resources/js/Pages"; do
  [ -d "$d" ] && { list_pages "$d" ""; FOUND_PAGES=1; }
done
for d in "$REPO"/Modules/*/resources/js/pages; do
  [ -d "$d" ] || continue
  m="${d#"$REPO"/Modules/}"; m="${m%%/*}"
  list_pages "$d" "$m::"; FOUND_PAGES=1
done
[ "$FOUND_PAGES" -eq 1 ] || echo "pages: no resources/js/pages, resources/js/Pages or Modules/*/resources/js/pages directory" >> "$W/warnings.txt"

# list_classes <dir> <namespace-root> <outfile> — FQCN per PHP class file (declared namespace, else
# derived from the path under the namespace root).
list_classes() {
  local dir="$1" root="$2" out="$3" f rel ns
  [ -d "$dir" ] || return 0
  find "$dir" -type f -name '*.php' | sort | while IFS= read -r f; do
    ns="$(sed -n 's/^[[:space:]]*namespace[[:space:]][[:space:]]*\([A-Za-z0-9_\\]*\)[[:space:]]*;.*/\1/p' "$f" | head -n 1)"
    if [ -z "$ns" ]; then
      rel="${f#"$dir"/}"; rel="${rel%/*}"
      [ "$rel" = "${f#"$dir"/}" ] && rel="" || rel="/$rel"
      ns="$(printf '%s%s' "$root" "$rel" | tr '/' '\\')"
    fi
    f="${f##*/}"
    printf '%s\\%s\n' "$ns" "${f%.php}"
  done >> "$out"
}
for kind in Mail Notifications; do
  out="$W/mails.txt"; [ "$kind" = "Notifications" ] && out="$W/notifications.txt"
  list_classes "$REPO/app/$kind" "App/$kind" "$out"
  for d in "$REPO"/Modules/*/app/"$kind"; do
    [ -d "$d" ] || continue
    m="${d#"$REPO"/Modules/}"; m="${m%%/*}"
    list_classes "$d" "Modules/$m/$kind" "$out"
  done
done

for d in "$REPO/lang" "$REPO/resources/lang"; do
  [ -d "$d" ] || continue
  for e in "$d"/*; do
    [ -e "$e" ] || continue
    n="${e##*/}"
    if [ -d "$e" ]; then
      [ "$n" = "vendor" ] || echo "$n" >> "$W/locales.txt"
    else
      case "$n" in *.json) echo "${n%.json}" >> "$W/locales.txt" ;; esac
    fi
  done
done

OUT="$W/out.json"
if has_jq; then
  jq -n -S -c \
    --slurpfile routes "$W/routes.json" \
    --rawfile jobs "$W/jobs.tsv" --rawfile pages "$W/pages.txt" --rawfile mails "$W/mails.txt" \
    --rawfile notifs "$W/notifications.txt" --rawfile locales "$W/locales.txt" --rawfile warns "$W/warnings.txt" '
    def lines: split("\n") | map(select(length > 0));
    def vendor: . as $u | ["_ignition", "telescope", "horizon", "sanctum/csrf-cookie"]
      | map(. as $v | select($u == $v or ($u | startswith($v + "/")))) | first // null;
    def hint: if test("^(can|permission|role|license\\.feature):") then .
              elif test("^Illuminate\\\\Auth\\\\Middleware\\\\Authorize:") then "can:" + sub("^[^:]*:"; "")
              else empty end;
    def mw: if type == "array" then map(select(type == "string"))
            elif type == "string" then split("\n")
            else [] end;
    if ($routes | length) != 1 or ($routes[0] | type) != "array" then error("route:list --json is not an array of routes") else . end
    | [$routes[0][] | select(type == "object" and (.uri | type) == "string" and (.method | type) == "string")
        | (.uri | sub("^/+"; "")) as $u | {u: $u, v: ($u | vendor), r: .}] as $rs
    | [$rs[] | select(.v == null) | .r
        | ("/" + (.uri | sub("^/+"; ""))) as $p
        | (.method | ascii_upcase | split("|") | map(select(length > 0))) as $ms
        | (if ($ms | index("GET")) != null then $ms - ["HEAD"] else $ms end) as $ms
        | [(.middleware | mw)[] | hint] as $h
        | $ms[] | {surfaceId: (. + " " + $p), kind: "endpoint", pattern: $p, method: ., permissionHints: $h, source: "adapter"}]
      | group_by(.surfaceId) | map(.[0] + {permissionHints: ([.[].permissionHints[]] | unique)}) as $endpoints
    | [$pages | lines | unique[] | {surfaceId: ("page:" + .), kind: "page", pattern: ., method: null, permissionHints: [], source: "adapter"}] as $pagesurf
    | {adapter: "laravel", ok: true,
       surfaces: (($endpoints + $pagesurf) | sort_by(.surfaceId)),
       jobs: [$jobs | lines[] | split("\t") | {id: .[0], schedule: .[1]}],
       mails: [$mails | lines | unique[] | {id: .}],
       notifications: [$notifs | lines | unique[] | {id: .}],
       locales: ($locales | lines | unique),
       warnings: (([$rs[] | .v | select(. != null)] | unique | map("skipped vendor route: " + .)) + ($warns | lines))}
  ' > "$OUT" 2> "$W/engine.err" || fail "adapter could not build output: $(sed -e '/^[[:space:]]*$/d' "$W/engine.err" | head -n 1)"
else
  python3 - "$W" "$OUT" <<'PY' 2> "$W/engine.err" || fail "adapter could not build output: $(sed -e '/^[[:space:]]*$/d' "$W/engine.err" | head -n 1)"
import json, os, re, sys
w, out = sys.argv[1], sys.argv[2]
def raw(name):
    with open(os.path.join(w, name), encoding="utf-8") as fh:
        return fh.read()
def lines(s): return [x for x in s.split("\n") if len(x) > 0]
try:
    routes = json.loads(raw("routes.json"))
except Exception as e:
    sys.exit("route:list --json is not valid JSON: " + str(e))
if not isinstance(routes, list): sys.exit("route:list --json is not an array of routes")
VENDOR = ["_ignition", "telescope", "horizon", "sanctum/csrf-cookie"]
HINT = re.compile(r"^(can|permission|role|license\.feature):")
AUTHZ = re.compile(r"^Illuminate\\Auth\\Middleware\\Authorize:")
def vendor(u):
    for v in VENDOR:
        if u == v or u.startswith(v + "/"): return v
    return None
def mw(m):
    if isinstance(m, list): return [x for x in m if isinstance(x, str)]
    if isinstance(m, str): return m.split("\n")
    return []
def hints(m):
    h = []
    for x in mw(m):
        if HINT.search(x): h.append(x)
        elif AUTHZ.search(x): h.append("can:" + re.sub(r"^[^:]*:", "", x, count=1))
    return h
rs = []
for r in routes:
    if isinstance(r, dict) and isinstance(r.get("uri"), str) and isinstance(r.get("method"), str):
        u = re.sub(r"^/+", "", r["uri"], count=1)
        rs.append((u, vendor(u), r))
groups = {}
for u, v, r in rs:
    if v is not None: continue
    p = "/" + u
    ms = [x for x in r["method"].upper().split("|") if len(x) > 0]
    if "GET" in ms: ms = [x for x in ms if x != "HEAD"]
    h = hints(r.get("middleware"))
    for m in ms:
        sid = m + " " + p
        if sid in groups:
            groups[sid]["permissionHints"].extend(h)
        else:
            groups[sid] = {"surfaceId": sid, "kind": "endpoint", "pattern": p, "method": m,
                           "permissionHints": list(h), "source": "adapter"}
for g in groups.values(): g["permissionHints"] = sorted(set(g["permissionHints"]))
pages = [{"surfaceId": "page:" + x, "kind": "page", "pattern": x, "method": None, "permissionHints": [],
          "source": "adapter"} for x in sorted(set(lines(raw("pages.txt"))))]
jobs = []
for l in lines(raw("jobs.tsv")):
    parts = l.split("\t")
    jobs.append({"id": parts[0], "schedule": parts[1] if len(parts) > 1 else None})
res = {"adapter": "laravel", "ok": True,
       "surfaces": sorted(list(groups.values()) + pages, key=lambda s: s["surfaceId"]),
       "jobs": jobs,
       "mails": [{"id": x} for x in sorted(set(lines(raw("mails.txt"))))],
       "notifications": [{"id": x} for x in sorted(set(lines(raw("notifications.txt"))))],
       "locales": sorted(set(lines(raw("locales.txt")))),
       "warnings": ["skipped vendor route: " + x for x in sorted(set(v for _, v, _ in rs if v is not None))]
                   + lines(raw("warnings.txt"))}
with open(out, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(res, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
PY
fi
cat "$OUT"
