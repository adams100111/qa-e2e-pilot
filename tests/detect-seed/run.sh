#!/usr/bin/env bash
# Dual-engine tests for qa-kit/scripts/detect-seed.sh (propose).
# Fixtures are REAL stack-profile.json shapes: components[] + primary, orm an object.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/detect-seed.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  # laravel backend component (primary.backend index) -> artisan
  printf '%s' '{"components":[{"role":"backend","framework":"laravel","orm":{"name":"eloquent"}}],"primary":{"backend":0}}' > "$T/laravel.json"
  check "$E laravel -> artisan" "$(QA_ENGINE=$E bash "$SH" propose "$T/laravel.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"])')" "php artisan db:seed"
  # rails
  printf '%s' '{"components":[{"role":"backend","framework":"rails","orm":{"name":"active-record"}}],"primary":{"backend":0}}' > "$T/rails.json"
  check "$E rails -> bin/rails db:seed" "$(QA_ENGINE=$E bash "$SH" propose "$T/rails.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"])')" "bin/rails db:seed"
  # prisma via orm.name on a JS framework
  printf '%s' '{"components":[{"role":"backend","framework":"express","orm":{"name":"prisma"}}],"primary":{"backend":0}}' > "$T/prisma.json"
  check "$E prisma -> prisma db seed" "$(QA_ENGINE=$E bash "$SH" propose "$T/prisma.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"])')" "npx prisma db seed"
  # django -> null command (no universal seed command; honest)
  printf '%s' '{"components":[{"role":"backend","framework":"django","orm":{"name":"django-orm"}}],"primary":{"backend":0}}' > "$T/django.json"
  check "$E django -> null command" "$(QA_ENGINE=$E bash "$SH" propose "$T/django.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"] is None)')" "True"
  # multi-component: pick backend via primary.backend index (frontend listed first)
  printf '%s' '{"components":[{"role":"frontend","framework":"nextjs","orm":{"name":"unknown"}},{"role":"backend","framework":"laravel","orm":{"name":"eloquent"}}],"primary":{"backend":1}}' > "$T/multi.json"
  check "$E multi picks backend via primary" "$(QA_ENGINE=$E bash "$SH" propose "$T/multi.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mechanism"])')" "laravel"
  # fullstack fallback (no backend role, no primary.backend) -> role fullstack
  printf '%s' '{"components":[{"role":"fullstack","framework":"rails","orm":{"name":"active-record"}}],"primary":{}}' > "$T/fs.json"
  check "$E fullstack fallback" "$(QA_ENGINE=$E bash "$SH" propose "$T/fs.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mechanism"])')" "rails"
  # unknown framework + unknown orm -> null mechanism
  printf '%s' '{"components":[{"role":"backend","framework":"flask","orm":{"name":"sqlalchemy"}}],"primary":{"backend":0}}' > "$T/unk.json"
  check "$E unknown -> null mechanism" "$(QA_ENGINE=$E bash "$SH" propose "$T/unk.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mechanism"] is None)')" "True"
  # cwd: config repos[] role=backend precedence
  printf '%s' '{"repos":[{"role":"frontend","path":"/srv/ui"},{"role":"backend","path":"/srv/api"}]}' > "$T/cfg.json"
  check "$E cwd from backend repo" "$(QA_ENGINE=$E bash "$SH" propose "$T/laravel.json" "$T/cfg.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cwd"])')" "/srv/api"
  # cwd: fullstack fallback when no backend repo
  printf '%s' '{"repos":[{"role":"fullstack","path":"/srv/app"}]}' > "$T/cfg2.json"
  check "$E cwd fullstack fallback" "$(QA_ENGINE=$E bash "$SH" propose "$T/laravel.json" "$T/cfg2.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cwd"])')" "/srv/app"
  # cwd: default '.' with no config
  check "$E cwd default dot" "$(QA_ENGINE=$E bash "$SH" propose "$T/laravel.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cwd"])')" "."
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' '{"components":[{"role":"backend","framework":"laravel","orm":{"name":"eloquent"}}],"primary":{"backend":0}}' > "$X/s.json"
  vj="$(QA_ENGINE=jq bash "$SH" propose "$X/s.json")"; vp="$(QA_ENGINE=python3 bash "$SH" propose "$X/s.json")"
  check "cross-engine proposal identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"; rm -rf "$X"
fi
echo "detect-seed: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
