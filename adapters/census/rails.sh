#!/usr/bin/env bash
# rails.sh — census stack adapter for Rails apps. Parses `bin/rails routes`. Contract:
# adapters/census/README.md.
#
# USAGE:  rails.sh --repo <path> [--exec-prefix "<prefix>"]
#   --exec-prefix  config `exec.prefix`, whitespace word-split (no shell quotes) and prepended to
#                  the command, e.g. "docker compose exec -T web". Default "".
# COMMAND RUN (from --repo):  <prefix> bin/rails routes
#   Lines look like `<name> <VERB> <path>(.:format) <controller#action>` (the name and, for repeated
#   routes, the name column may be blank). Rows without a verb (mounted engines) are skipped; /rails/* and /cable
#   (framework routes) are skipped and named once in warnings.
# Path rules: "(.:format)" dropped, "(/:x)" -> "/{x?}", ":id" -> "{id}", "*rest" -> "{rest}".
#   "PATCH|PUT" -> one surface each; HEAD dropped when GET is present.
# EXIT: 0 ok:true; 3 ok:false (bin/rails missing or failing, no routes parsed, no engine); 1 usage error.
ADAPTER="rails"
USAGE_TEXT='rails.sh --repo <path> [--exec-prefix "<prefix>"]'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
parse_args "$@"
prepare

if [ "${#PFX[@]}" -eq 0 ] && [ ! -f "$REPO/bin/rails" ]; then
  fail "bin/rails not found in $REPO (set exec.prefix if Rails runs in a container or dev shell)"
fi
run_cmd "$W/routes.txt" bin/rails routes

# "VERB<TAB>path" per route row; a row with no verb token (mounted engine, match-any) is skipped.
awk '
  BEGIN { verbs = "^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)(\\|(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS))*$" }
  {
    u = 0
    for (i = 1; i <= NF; i++) if ($i ~ /^\//) { u = i; break }
    if (u > 1 && $(u - 1) ~ verbs) print $(u - 1) "\t" $u
  }' "$W/routes.txt" > "$W/rows.tsv"
[ -s "$W/rows.tsv" ] || fail "bin/rails routes printed no routes"

SKIPPED=0
while IFS="$(printf '\t')" read -r verb path; do
  case "$path" in
    /rails|/rails/*|/cable|/cable/*) SKIPPED=1; continue ;;
  esac
  p="$(printf '%s' "$path" | sed -E \
    -e 's#\(\.:format\)##g' -e 's#\(/:([A-Za-z0-9_]+)\)#/{\1?}#g' \
    -e 's#:([A-Za-z0-9_]+)#{\1}#g' -e 's#\*([A-Za-z0-9_]+)#{\1}#g')"
  p="$(norm_path "$p")"
  case "|$verb|" in *"|GET|"*) verb="$(printf '%s' "$verb" | tr '|' '\n' | grep -vx HEAD | tr '\n' '|')"; verb="${verb%|}" ;; esac
  printf '%s\n' "$verb" | tr '|' '\n' | while IFS= read -r m; do
    [ -n "$m" ] && add_surface endpoint "$m" "$p" ""
  done
done < "$W/rows.tsv"
[ "$SKIPPED" -eq 0 ] || echo "skipped framework route: /rails, /cable" >> "$W/warnings.txt"
emit_adapter_json
