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
    '["page:Admin/Hackathons/Index","page:Admin/Hackathons/Show","page:Hackathons::Teams/Index","page:Welcome"]'
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
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; TMPDIRS+=("$X")
  laravel jq "$X/j.json"; laravel python3 "$X/p.json"
  check "laravel cross-engine output byte-identical" "$(cmp -s "$X/j.json" "$X/p.json" && echo same || echo diff)" "same"
  FAKE_PHP_FAIL=route:list laravel jq "$X/jf.json"; FAKE_PHP_FAIL=route:list laravel python3 "$X/pf.json"
  check "laravel cross-engine failure byte-identical" "$(cmp -s "$X/jf.json" "$X/pf.json" && echo same || echo diff)" "same"
fi
echo "census-adapters: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
