#!/usr/bin/env bash
# Tests for frontier.js — the HITL topological round engine (spec §2F / A5).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MOD="$HERE/../../skills/confirming-discovered-roles/scripts/frontier.js"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

# The role decision graph: roles -> credentials -> scope.
TREE='{"nodes":[{"id":"roles","prereqs":[],"default":["admin","user"]},{"id":"credentials","prereqs":["roles"],"default":"seeded"},{"id":"scope","prereqs":["credentials"],"default":"owns"}]}'

run() { node -e '
  const f=require(process.argv[1]);
  const tree=JSON.parse(process.argv[2]); const settled=JSON.parse(process.argv[3]);
  const op=process.argv[4];
  if(op==="frontier"){process.stdout.write(computeStr(f.computeFrontier(tree,settled)));}
  if(op==="default"){process.stdout.write(String(f.recommendedDefault(tree,process.argv[5])));}
  if(op==="apply"){const s=f.applyAnswers(tree,settled,JSON.parse(process.argv[5]));process.stdout.write(computeStr(f.computeFrontier(tree,s)));}
  if(op==="budget"){process.stdout.write(String(f.budgetExceeded(Number(process.argv[5]),Number(process.argv[6]))));}
  function computeStr(r){return r.frontier.join(",")+"|"+r.deferred.join(",");}
  ' "$MOD" "$1" "$2" "$3" "${4:-}" "${5:-}"; }

# (a) credentials/scope are DEFERRED until roles settle; only roles is on the frontier.
check "a: only roles on frontier initially" "$(run "$TREE" '{}' frontier)" "roles|credentials,scope"
# (b) every frontier node has a recommended default.
check "b: roles has a default" "$(run "$TREE" '{}' default roles)" "admin,user"
# (c) after settling roles, credentials surfaces (prereq met); scope still deferred.
check "c: credentials unblocks after roles" "$(run "$TREE" '{}' apply '{"roles":["admin"]}')" "credentials|scope"
# (d) editing a settled prereq unsettles its dependents (credentials returns to frontier).
check "d: editing roles re-defers downstream" "$(run "$TREE" '{"roles":["admin"],"credentials":"seeded"}' apply '{"roles":["admin","user"]}')" "credentials|scope"
# (e) budget: rounds>budget -> true (auto-settle-and-proceed trigger).
check "e: budget exceeded true"  "$(run "$TREE" '{}' budget 6 5)" "true"
check "f: budget not exceeded"   "$(run "$TREE" '{}' budget 3 5)" "false"

echo; echo "frontier tests: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
