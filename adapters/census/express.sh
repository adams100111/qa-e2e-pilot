#!/usr/bin/env bash
# express.sh — census stack adapter for Express apps. Static scan only (--exec-prefix accepted,
# unused). Contract: adapters/census/README.md.
#
# USAGE:  express.sh --repo <path> [--exec-prefix "<prefix>"]
# SCANNED: *.js *.ts *.mjs *.cjs under --repo (node_modules, dist, build, coverage, .next, test and
#   __tests__ dirs and *.test.*/*.spec.* files excluded) for single-line
#   `app.<get|post|put|patch|delete>('/path'` and `<name>Router|router.<method>('/path'` calls with a
#   string-literal path. ":id" -> "{id}". Surface "confidence":"static".
# LIMITS (reported in warnings): `app.use('/prefix', router)` mounts are not applied, so router paths
#   are as declared; regex / computed paths are not seen.
# EXIT: 0 ok:true; 3 ok:false (missing repo, no engine); 1 usage error.
ADAPTER="express"
USAGE_TEXT='express.sh --repo <path> [--exec-prefix "<prefix>"]'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
parse_args "$@"
prepare

( cd "$REPO" && find . \( -name node_modules -o -name dist -o -name build -o -name coverage -o -name .next -o -name __tests__ -o -name test -o -name tests -o -name .git \) -prune -o \
    -type f \( -name '*.js' -o -name '*.ts' -o -name '*.mjs' -o -name '*.cjs' \) \
    ! -name '*.test.*' ! -name '*.spec.*' ! -name '*.d.ts' -print | sort ) > "$W/files.txt"

: > "$W/mounts.txt"
while IFS= read -r f; do
  grep -Ehs '\b(app|[A-Za-z0-9_]*[Rr]outer)\.(get|post|put|patch|delete)[[:space:]]*\([[:space:]]*['"'"'"`]/' "$REPO/$f" \
    | awk '{
        s = $0
        while (match(s, /\.(get|post|put|patch|delete)[ \t]*\([ \t]*['"'"'"`]\/[^'"'"'"`]*['"'"'"`]/)) {
          t = substr(s, RSTART, RLENGTH)
          m = t; sub(/^\./, "", m); sub(/[ \t]*\(.*$/, "", m)
          p = t; sub(/^[^'"'"'"`]*['"'"'"`]/, "", p); sub(/['"'"'"`]$/, "", p)
          print toupper(m) "\t" p
          s = substr(s, RSTART + RLENGTH)
        }
      }' >> "$W/found.tsv"
  grep -Eqs '\.use[[:space:]]*\([[:space:]]*['"'"'"`]/' "$REPO/$f" && echo x >> "$W/mounts.txt"
done < "$W/files.txt"
[ -f "$W/found.tsv" ] || : > "$W/found.tsv"

while IFS="$(printf '\t')" read -r m p; do
  p="$(printf '%s' "$p" | sed -E -e 's#:([A-Za-z0-9_]+)\??#{\1}#g')"
  add_surface endpoint "$m" "$(norm_path "$p")" static
done < "$W/found.tsv"
[ -s "$W/mounts.txt" ] && echo "app.use mount prefixes are not applied; router paths are as declared" >> "$W/warnings.txt"
[ -s "$W/surfaces.tsv" ] || echo "no app.<method>('/path') or router.<method>('/path') routes found" >> "$W/warnings.txt"
emit_adapter_json
