#!/usr/bin/env bash
# Dual-engine tests for the census stack adapters (adapters/census/<stack>.sh).
# Laravel: a fake `php` on PATH (fixtures/laravel/bin/php) prints the real `route:list --json` /
# `schedule:list` shapes per argv, so no PHP is needed. Shared with Task 5's adapters.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$DIR/../.."
LARAVEL="$ROOT/adapters/census/laravel.sh"
CENSUS="$ROOT/scripts/census.sh"
FX="$DIR/fixtures"
LFX="$FX/laravel"
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || { echo "ERROR: census-adapters: neither jq nor python3 available - suite cannot run" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: census-adapters: assertions need python3" >&2; exit 1; }
BASH_BIN="$(command -v bash)"
pass=0; fail=0
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
# q <file> <python expression over `c`> — prints the expression's value (json for lists/dicts).
q(){ python3 -c '
import json,sys
c=json.load(open(sys.argv[1], encoding="utf-8"))
def s(i): return next((x for x in c.get("surfaces", []) if x["surfaceId"]==i), None)
v=eval(sys.argv[2])
print(v if isinstance(v,(str,int,bool)) or v is None else json.dumps(v, ensure_ascii=False, separators=(",",":")))
' "$1" "$2"; }

# laravel <engine> <out> [adapter args...] — runs the Laravel adapter with the fake php first on PATH.
laravel(){
  local E="$1" out="$2"; shift 2
  PATH="$LFX/bin:$PATH" QA_ENGINE=$E FAKE_ROUTES="$LFX/routes.json" FAKE_SCHEDULE="$LFX/schedule.txt" \
    "$BASH_BIN" "$LARAVEL" --repo "$LFX/repo" "$@" > "$out"
}

# stack <stack> <engine> <out> [adapter args...] — runs adapters/census/<stack>.sh.
stack(){
  local S="$1" E="$2" out="$3"; shift 3
  QA_ENGINE=$E "$BASH_BIN" "$ROOT/adapters/census/$S.sh" "$@" > "$out"
}

# A PATH holding only the tools the adapter needs (no php) — for the missing-php case.
nophp_path(){
  local E="$1" d="$2" t p
  mkdir -p "$d"
  for t in bash env find awk sed sort tr head cat rm mktemp dirname basename grep mkdir "$E"; do
    p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$d/$t"
  done
}

run_engine() {
  local E="$1" T rc; T="$(mktemp -d)"; TMPDIRS+=("$T")

  # laravel_routes_to_surfaces
  laravel "$E" "$T/a.json"; rc=$?
  check "$E laravel exit 0" "$rc" "0"
  check "$E laravel ok + adapter" "$(q "$T/a.json" "[c['adapter'], c['ok']]")" '["laravel",true]'
  check "$E laravel_routes_to_surfaces endpoint ids" \
    "$(q "$T/a.json" "[x['surfaceId'] for x in c['surfaces'] if x['kind']=='endpoint']")" \
    '["GET /","GET /admin/hackathons/{hackathon}","GET /admin/settings","GET /h/{slug}","GET /horizonte/plans","GET /reports/{year?}","GET /الأخبار/{slug}","PATCH /admin/hackathons/{hackathon}","POST /admin/hackathons","PUT /admin/hackathons/{hackathon}"]'
  check "$E laravel_routes_to_surfaces surface shape" "$(q "$T/a.json" "s('GET /admin/hackathons/{hackathon}')")" \
    '{"kind":"endpoint","method":"GET","pattern":"/admin/hackathons/{hackathon}","permissionHints":["can:hackathons.view"],"source":"adapter","surfaceId":"GET /admin/hackathons/{hackathon}"}'
  check "$E laravel_routes_to_surfaces HEAD dropped" "$(q "$T/a.json" "any(x['method']=='HEAD' for x in c['surfaces'])")" "False"
  check "$E laravel_routes_to_surfaces root uri is /" "$(q "$T/a.json" "s('GET /')['pattern']")" "/"

  # laravel_middleware_permission_hints
  check "$E laravel_middleware_permission_hints permission + license.feature" "$(q "$T/a.json" "s('POST /admin/hackathons')['permissionHints']")" \
    '["can:hackathons.create","license.feature:hackathons","permission:hackathons.create"]'
  check "$E laravel_middleware_permission_hints role" "$(q "$T/a.json" "s('PUT /admin/hackathons/{hackathon}')['permissionHints']")" '["role:admin"]'
  check "$E laravel_middleware_permission_hints resolved Authorize -> can:" "$(q "$T/a.json" "s('GET /admin/settings')['permissionHints']")" '["can:settings.view"]'
  check "$E laravel_middleware_permission_hints newline-joined string middleware" "$(q "$T/a.json" "s('GET /reports/{year?}')['permissionHints']")" '["can:reports.view"]'
  check "$E laravel_middleware_permission_hints none" "$(q "$T/a.json" "s('GET /')['permissionHints']")" '[]'

  # vendor/framework routes skipped and listed in warnings
  check "$E laravel vendor routes skipped" "$(q "$T/a.json" "[x['surfaceId'] for x in c['surfaces'] if any(v in x['pattern'] for v in ('_ignition','telescope','sanctum')) or x['pattern'].startswith('/horizon/')]")" '[]'
  check "$E laravel vendor routes warned" "$(q "$T/a.json" "c['warnings']")" \
    '["skipped vendor route: _ignition","skipped vendor route: horizon","skipped vendor route: sanctum/csrf-cookie","skipped vendor route: telescope"]'

  # laravel_pages_scanned_incl_modules
  check "$E laravel_pages_scanned_incl_modules" "$(q "$T/a.json" "[x['surfaceId'] for x in c['surfaces'] if x['kind']=='page']")" \
    '["page:Admin/Hackathons/Index","page:Admin/Hackathons/Show","page:Hackathons::Teams/Index","page:Odd&Name|x::Probe","page:Welcome"]'
  check "$E laravel page surface shape" "$(q "$T/a.json" "s('page:Welcome')")" \
    '{"kind":"page","method":null,"pattern":"Welcome","permissionHints":[],"source":"adapter","surfaceId":"page:Welcome"}'

  # jobs / mails / notifications / locales
  check "$E laravel schedule -> jobs" "$(q "$T/a.json" "c['jobs']")" \
    '[{"id":"hackathons:close-registration","schedule":"0 0 * * *"},{"id":"App\\Jobs\\SyncMetrics","schedule":"*/5 * * * *"},{"id":"Closure at: routes/console.php:12","schedule":"* * * * *"}]'
  check "$E laravel mails (namespace read, path fallback)" "$(q "$T/a.json" "[m['id'] for m in c['mails']]")" \
    '["App\\Mail\\TeamInvite","Modules\\Hackathons\\Mail\\RegistrationConfirmed"]'
  check "$E laravel notifications incl modules + subdirs" "$(q "$T/a.json" "[m['id'] for m in c['notifications']]")" \
    '["App\\Notifications\\Judging\\JudgeAssigned","Modules\\Hackathons\\Notifications\\MentorAssigned"]'
  check "$E laravel locales (vendor excluded)" "$(q "$T/a.json" "c['locales']")" '["ar","en"]'
  check "$E laravel arabic raw utf-8 in output" "$(grep -c 'الأخبار' "$T/a.json")" "1"

  # laravel_artisan_failure_is_ok_false_exit3
  FAKE_PHP_FAIL=route:list laravel "$E" "$T/f1.json"; rc=$?
  check "$E laravel_artisan_failure route:list exit 3" "$rc" "3"
  check "$E laravel_artisan_failure route:list ok:false" "$(q "$T/f1.json" "[c['adapter'], c['ok'], 'route:list' in c['error'], 'SQLSTATE' in c['error'], 'surfaces' in c]")" '["laravel",false,true,true,false]'
  FAKE_PHP_FAIL=schedule:list laravel "$E" "$T/f2.json"; rc=$?
  check "$E laravel_artisan_failure schedule:list exit 3" "$rc" "3"
  check "$E laravel_artisan_failure schedule:list ok:false" "$(q "$T/f2.json" "[c['ok'], 'schedule:list' in c['error']]")" '[false,true]'
  printf 'Deprecated: something on stdout\n[' > "$T/bad-routes.json"
  PATH="$LFX/bin:$PATH" QA_ENGINE=$E FAKE_ROUTES="$T/bad-routes.json" FAKE_SCHEDULE="$LFX/schedule.txt" \
    "$BASH_BIN" "$LARAVEL" --repo "$LFX/repo" > "$T/f3.json"; rc=$?
  check "$E laravel_artisan_failure malformed route JSON exit 3" "$rc" "3"
  check "$E laravel_artisan_failure malformed route JSON ok:false" "$(q "$T/f3.json" "c['ok']")" "False"
  nophp_path "$E" "$T/nophp"
  PATH="$T/nophp" QA_ENGINE=$E "$BASH_BIN" "$LARAVEL" --repo "$LFX/repo" > "$T/f4.json"; rc=$?
  check "$E laravel_artisan_failure missing php exit 3" "$rc" "3"
  check "$E laravel_artisan_failure missing php ok:false" "$(q "$T/f4.json" "[c['ok'], 'php' in c['error']]")" '[false,true]'
  QA_ENGINE=$E "$BASH_BIN" "$LARAVEL" --repo "$T/no-such-repo" > "$T/f5.json"; rc=$?
  check "$E laravel missing repo exit 3 ok:false" "$rc:$(q "$T/f5.json" "c['ok']")" "3:False"
  "$BASH_BIN" "$LARAVEL" > /dev/null 2>&1; check "$E laravel usage error exit 1" "$?" "1"

  # exec_prefix_applied — every artisan call is `<prefix> php artisan …`, run from --repo
  : > "$T/exec.log"; : > "$T/php.log"
  FAKE_EXEC_LOG="$T/exec.log" FAKE_PHP_LOG="$T/php.log" laravel "$E" "$T/p.json" --exec-prefix "$LFX/bin/fake-exec --"; rc=$?
  check "$E exec_prefix_applied exit 0" "$rc" "0"
  check "$E exec_prefix_applied prefix argv" "$(cat "$T/exec.log")" "$(printf '%s\n%s' '-- php artisan route:list --json' '-- php artisan schedule:list')"
  check "$E exec_prefix_applied run from --repo" "$(sed 's/|.*//' "$T/php.log" | sort -u)" "$(cd "$LFX/repo" && pwd)"
  check "$E exec_prefix_applied same census as no prefix" "$(cmp -s "$T/a.json" "$T/p.json" && echo same || echo diff)" "same"

  # laravel review fixes: module dir names never reach a sed program; a failing page scan warns;
  # engine failures are not blamed on route:list; the exec prefix is word-split only (argv, no shell).
  check "$E laravel module dir with sed/shell metacharacters kept literally" "$(q "$T/a.json" "s('page:Odd&Name|x::Probe') is not None")" "True"
  cp -R "$LFX/repo" "$T/locked-repo"; chmod 000 "$T/locked-repo/resources/js/pages"
  PATH="$LFX/bin:$PATH" QA_ENGINE=$E FAKE_ROUTES="$LFX/routes.json" FAKE_SCHEDULE="$LFX/schedule.txt" \
    "$BASH_BIN" "$LARAVEL" --repo "$T/locked-repo" > "$T/lock.json"; rc=$?
  chmod 755 "$T/locked-repo/resources/js/pages"
  check "$E laravel_unreadable_pages_dir_warns exit 0" "$rc" "0"
  check "$E laravel_unreadable_pages_dir_warns warning" "$(q "$T/lock.json" "any(w.startswith('pages: could not scan ') for w in c['warnings'])")" "True"
  check "$E laravel engine failure message is generic" "$(q "$T/f3.json" "[c['error'].startswith('adapter could not build output: '), 'did not print' in c['error']]")" "[true,false]"
  : > "$T/argv.log"
  FAKE_EXEC_LOG="$T/argv.log" laravel "$E" "$T/m.json" --exec-prefix "$LFX/bin/fake-exec-argv ; --"; rc=$?
  check "$E laravel_exec_prefix_metacharacter exit 0" "$rc" "0"
  check "$E laravel_exec_prefix_metacharacter ; is a literal argv element" "$(cat "$T/argv.log")" \
    "$(printf '%s\n%s' '[;][--][php][artisan][route:list][--json]' '[;][--][php][artisan][schedule:list]')"

  # adapter_output_feeds_census — the adapter's stdout is a valid census.sh --adapter input
  QA_ENGINE=$E bash "$CENSUS" build --adapter "$T/a.json" --crawl "$LFX/crawl" --out "$T/census.json"; rc=$?
  check "$E adapter_output_feeds_census build exit 0" "$rc" "0"
  check "$E adapter_output_feeds_census adapterOk" "$(q "$T/census.json" "[c['adapter'], c['adapterOk']]")" '["laravel",true]'
  check "$E adapter_output_feeds_census page reached via routeMatch" "$(q "$T/census.json" "s('page:Admin/Hackathons/Show')['reachedBy']")" '["admin"]'
  check "$E adapter_output_feeds_census endpoint param matched" "$(q "$T/census.json" "s('GET /admin/hackathons/{hackathon}')['reachedBy']")" '["admin"]'
  check "$E adapter_output_feeds_census encoded arabic slug matched" "$(q "$T/census.json" "s('GET /h/{slug}')['reachedBy']")" '["admin"]'
  check "$E adapter_output_feeds_census optional param absent matched" "$(q "$T/census.json" "s('GET /reports/{year?}')['reachedBy']")" '["admin"]'
  check "$E adapter_output_feeds_census crawlOnly" "$(q "$T/census.json" "c['diffs']['crawlOnly']")" '["GET /legacy/old"]'
  check "$E adapter_output_feeds_census channels + warnings carried" "$(q "$T/census.json" "[len(c['jobs']),len(c['mails']),len(c['notifications']),len(c['warnings'])]")" '[3,2,2,4]'
  QA_ENGINE=$E bash "$CENSUS" build --adapter "$T/f1.json" --crawl "$LFX/crawl" --out "$T/census-f.json"; rc=$?
  check "$E adapter_output_feeds_census ok:false degrades with warning" "$rc:$(q "$T/census-f.json" "any(w.startswith('adapter-failed: laravel: ') for w in c['warnings'])")" "0:True"

  # ---- nextjs ----
  NX="$FX/nextjs/repo"
  stack nextjs "$E" "$T/nx.json" --repo "$NX"; rc=$?
  check "$E nextjs exit 0" "$rc" "0"
  check "$E nextjs surface ids" "$(q "$T/nx.json" "[x['surfaceId'] for x in c['surfaces']]")" \
    '["DELETE /api/users/{id}","GET /","GET /about","GET /api/health","GET /api/ping","GET /blog/{slug}","GET /contact","GET /docs/{slug}","GET /legacy","GET /login","GET /shop/{cat?}","GET /users/{id}","POST /api/health"]'
  check "$E nextjs excludes _app/_document/pages-api/layout" "$(q "$T/nx.json" "any('_app' in x['surfaceId'] or '_document' in x['surfaceId'] or 'old' in x['surfaceId'] or 'layout' in x['surfaceId'] for x in c['surfaces'])")" "False"
  check "$E nextjs surfaces are static endpoints" "$(q "$T/nx.json" "sorted(set((x['confidence'],x['kind'],x['source']) for x in c['surfaces']))")" '[["static","endpoint","adapter"]]'
  check "$E nextjs surface shape" "$(q "$T/nx.json" "s('GET /users/{id}')")" '{"confidence":"static","kind":"endpoint","method":"GET","pattern":"/users/{id}","permissionHints":[],"source":"adapter","surfaceId":"GET /users/{id}"}'
  check "$E nextjs route.js without handler warns" "$(q "$T/nx.json" "c['warnings']")" '["no exported HTTP handler found in app/api/ping/route.js: assumed GET"]'
  stack nextjs "$E" "$T/nx0.json" --repo "$FX/generic/repo"; rc=$?
  check "$E nextjs without app/pages dirs: ok:false exit 3" "$rc:$(q "$T/nx0.json" "c['ok']")" "3:False"
  cp -R "$NX" "$T/nx-locked"; chmod 000 "$T/nx-locked/app/users"
  stack nextjs "$E" "$T/nxl.json" --repo "$T/nx-locked"; rc=$?
  chmod 755 "$T/nx-locked/app/users"
  check "$E nextjs_unreadable_dir_warns exit 0" "$rc" "0"
  check "$E nextjs_unreadable_dir_warns warning + rest scanned" "$(q "$T/nxl.json" "[any(w.startswith('could not scan ') and 'users' in w for w in c['warnings']), s('GET /about') is not None, s('GET /users/{id}') is None]")" "[true,true,true]"
  mkdir -p "$T/nx-dead/app"; chmod 000 "$T/nx-dead/app"
  stack nextjs "$E" "$T/nxd.json" --repo "$T/nx-dead"; rc=$?
  chmod 755 "$T/nx-dead/app"
  check "$E nextjs nothing scannable exit 3 ok:false" "$rc:$(q "$T/nxd.json" "[c['ok'], 'nothing could be scanned' in c['error']]")" "3:[false,true]"
  QA_ENGINE=$E bash "$CENSUS" build --adapter "$T/nx.json" --crawl "$LFX/crawl" --out "$T/nx-census.json"; rc=$?
  check "$E nextjs output feeds census.sh" "$rc:$(q "$T/nx-census.json" "c['adapterOk']")" "0:True"

  # ---- rails ----
  RB="$FX/rails/repo"
  stack rails "$E" "$T/rb.json" --repo "$RB"; rc=$?
  check "$E rails exit 0" "$rc" "0"
  check "$E rails surface ids" "$(q "$T/rb.json" "[x['surfaceId'] for x in c['surfaces']]")" \
    '["DELETE /users/{id}","GET /","GET /archive/{locale?}/{path}","GET /pages/{slug}/comments/{comment_id}","GET /users","GET /users/{id}","PATCH /users/{id}","POST /users","PUT /users/{id}"]'
  check "$E rails framework routes skipped + warned, engine mount skipped" "$(q "$T/rb.json" "c['warnings']")" '["skipped framework route: /rails, /cable"]'
  check "$E rails runtime surfaces have no confidence" "$(q "$T/rb.json" "any('confidence' in x for x in c['surfaces'])")" "False"
  FAKE_RAILS_FAIL=1 stack rails "$E" "$T/rbf.json" --repo "$RB"; rc=$?
  check "$E rails failure exit 3 ok:false" "$rc:$(q "$T/rbf.json" "[c['ok'], 'bin/rails routes' in c['error'], 'ConnectionBad' in c['error'], 'surfaces' in c]")" "3:[false,true,true,false]"
  stack rails "$E" "$T/rbm.json" --repo "$FX/generic/repo"; rc=$?
  check "$E rails missing bin/rails exit 3" "$rc:$(q "$T/rbm.json" "c['ok']")" "3:False"
  : > "$T/rails.log"
  FAKE_RAILS_LOG="$T/rails.log" FAKE_EXEC_LOG="$T/rbx.log" stack rails "$E" "$T/rbp.json" --repo "$RB" --exec-prefix "$LFX/bin/fake-exec --"; rc=$?
  check "$E rails exec prefix applied" "$rc:$(cat "$T/rbx.log")" "0:-- bin/rails routes"

  # ---- django ----
  DJ="$FX/django/repo"
  PATH="$FX/django/bin:$PATH" FAKE_SHOW_URLS="$FX/django/show_urls.txt" stack django "$E" "$T/dj.json" --repo "$DJ"; rc=$?
  check "$E django show_urls exit 0" "$rc" "0"
  check "$E django show_urls surface ids" "$(q "$T/dj.json" "[x['surfaceId'] for x in c['surfaces']]")" '["GET /","GET /admin/","GET /api/users/{pk}/","GET /blog/{slug}/"]'
  check "$E django show_urls is runtime (no confidence)" "$(q "$T/dj.json" "any('confidence' in x for x in c['surfaces'])")" "False"
  PATH="$FX/django/bin:$PATH" FAKE_NO_SHOW_URLS=1 FAKE_SHOW_URLS=/dev/null stack django "$E" "$T/djs.json" --repo "$DJ"; rc=$?
  check "$E django_without_show_urls_falls_back_static exit 0" "$rc" "0"
  check "$E django_without_show_urls_falls_back_static surface ids" "$(q "$T/djs.json" "[x['surfaceId'] for x in c['surfaces']]")" \
    '["GET /","GET /admin/","GET /api/users/{pk}/","GET /blog/","GET /blog/{slug}/","GET /legacy/{year}/"]'
  check "$E django_without_show_urls_falls_back_static confidence static" "$(q "$T/djs.json" "sorted(set(x['confidence'] for x in c['surfaces']))")" '["static"]'
  check "$E django_without_show_urls_falls_back_static warns fallback + unresolved include" "$(q "$T/djs.json" "[any(w.startswith('show_urls unavailable') for w in c['warnings']), any('unresolved include' in w and 'thirdparty.urls' in w for w in c['warnings'])]")" "[true,true]"
  mkdir -p "$T/dj-ml"
  printf 'from django.urls import include, path\nurlpatterns = [\n    path(\n        "a/",\n        views.a,\n    ),\n    path(\n        "b/",\n        include("dj_ml_b.urls"),\n    ),\n    path("", views.home),\n    path(\n        views.dynamic_route,\n        views.x,\n    ),\n]\n' > "$T/dj-ml/urls.py"
  mkdir -p "$T/dj-ml/dj_ml_b"; printf 'urlpatterns = [path("c/", v)]\n' > "$T/dj-ml/dj_ml_b/urls.py"
  stack django "$E" "$T/djml.json" --repo "$T/dj-ml"; rc=$?
  check "$E django_multiline_path_no_phantom_root" "$rc:$(q "$T/djml.json" "[x['surfaceId'] for x in c['surfaces']]")" '0:["GET /","GET /a/","GET /b/c/"]'
  check "$E django_multiline_path warns unparsable route" "$(q "$T/djml.json" "any(w.startswith('multi-line path() not fully scanned') for w in c['warnings'])")" "True"
  mkdir -p "$T/dj-ml2"; printf 'urlpatterns = [\n    path(\n        "only/",\n        v,\n    ),\n]\n' > "$T/dj-ml2/urls.py"
  stack django "$E" "$T/djml2.json" --repo "$T/dj-ml2"
  check "$E django_multiline_path_no_phantom_root only declared route" "$(q "$T/djml2.json" "[x['surfaceId'] for x in c['surfaces']]")" '["GET /only/"]'
  stack django "$E" "$T/djn.json" --repo "$FX/generic/repo"; rc=$?
  check "$E django no manage.py and no urls.py exit 3" "$rc:$(q "$T/djn.json" "c['ok']")" "3:False"

  # ---- express ----
  EX="$FX/express/repo"
  stack express "$E" "$T/ex.json" --repo "$EX"; rc=$?
  check "$E express exit 0" "$rc" "0"
  check "$E express surface ids" "$(q "$T/ex.json" "[x['surfaceId'] for x in c['surfaces']]")" \
    '["DELETE /users/{id}","GET /","GET /users","GET /users/{id}","PATCH /users/{id}/avatar","POST /login","PUT /users/{id}"]'
  check "$E express static + mount warning" "$(q "$T/ex.json" "[sorted(set(x['confidence'] for x in c['surfaces'])), c['warnings']]")" '[["static"],["app.use mount prefixes are not applied; router paths are as declared"]]'
  cp -R "$EX" "$T/ex-locked"; chmod 000 "$T/ex-locked/routes/users.js"
  stack express "$E" "$T/exl.json" --repo "$T/ex-locked"; rc=$?
  chmod 644 "$T/ex-locked/routes/users.js"
  check "$E express_unreadable_file_warns exit 0" "$rc" "0"
  check "$E express_unreadable_file_warns warning + rest scanned" "$(q "$T/exl.json" "[any(w.startswith('could not scan ') and 'users.js' in w for w in c['warnings']), s('GET /') is not None, s('GET /users') is None]")" "[true,true,true]"
  mkdir -p "$T/ex-dead"; echo "app.get('/x', h)" > "$T/ex-dead/a.js"; chmod 000 "$T/ex-dead/a.js"
  stack express "$E" "$T/exd.json" --repo "$T/ex-dead"; rc=$?
  chmod 644 "$T/ex-dead/a.js"
  check "$E express nothing scannable exit 3 ok:false" "$rc:$(q "$T/exd.json" "c['ok']")" "3:False"
  stack express "$E" "$T/ex0.json" --repo "$FX/generic/repo"; rc=$?
  check "$E express no routes found: ok with warning" "$rc:$(q "$T/ex0.json" "[c['ok'], len(c['surfaces']), len(c['warnings'])]")" "0:[true,0,1]"

  # ---- generic ----
  stack generic "$E" "$T/gn.json" --repo "$FX/generic/repo"; rc=$?
  check "$E generic_is_crawl_only exit 0" "$rc" "0"
  check "$E generic_is_crawl_only output" "$(cat "$T/gn.json")" '{"adapter":"generic","ok":true,"surfaces":[],"warnings":["crawl-only census"]}'
  QA_ENGINE=$E bash "$CENSUS" build --adapter "$T/gn.json" --crawl "$LFX/crawl" --out "$T/gn-census.json"; rc=$?
  check "$E generic feeds census.sh (crawl-only)" "$rc:$(q "$T/gn-census.json" "c['adapterOk']")" "0:True"

  # ---- shared usage / missing repo for every new adapter ----
  for S in nextjs rails django express; do
    "$BASH_BIN" "$ROOT/adapters/census/$S.sh" >/dev/null 2>&1; check "$E $S usage error exit 1" "$?" "1"
    stack $S "$E" "$T/nr.json" --repo "$T/no-such-repo"; rc=$?
    check "$E $S missing repo exit 3 ok:false" "$rc:$(q "$T/nr.json" "[c['adapter'], c['ok']]")" "3:[\"$S\",false]"
  done
  "$BASH_BIN" "$ROOT/adapters/census/generic.sh" --bogus >/dev/null 2>&1; check "$E generic unknown flag exit 1" "$?" "1"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  laravel jq "$X/j.json"; laravel python3 "$X/p.json"
  check "laravel cross-engine output byte-identical" "$(cmp -s "$X/j.json" "$X/p.json" && echo same || echo diff)" "same"
  FAKE_PHP_FAIL=route:list laravel jq "$X/jf.json"; FAKE_PHP_FAIL=route:list laravel python3 "$X/pf.json"
  check "laravel cross-engine failure byte-identical" "$(cmp -s "$X/jf.json" "$X/pf.json" && echo same || echo diff)" "same"
  for S in nextjs django express rails; do
    for E2 in jq python3; do
      case "$S" in
        rails) stack rails $E2 "$X/$S.$E2" --repo "$FX/rails/repo" ;;
        django) PATH="$FX/django/bin:$PATH" FAKE_NO_SHOW_URLS=1 FAKE_SHOW_URLS=/dev/null stack django $E2 "$X/$S.$E2" --repo "$FX/django/repo" ;;
        *) stack $S $E2 "$X/$S.$E2" --repo "$FX/$S/repo" ;;
      esac
    done
    check "$S cross-engine output byte-identical" "$(cmp -s "$X/$S.jq" "$X/$S.python3" && echo same || echo diff)" "same"
  done
fi
echo "census-adapters: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
