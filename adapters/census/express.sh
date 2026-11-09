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
# An unreadable dir or file adds a "could not scan <path>: <reason>" warning; when nothing could be
# scanned at all the result is ok:false.
# EXIT: 0 ok:true; 3 ok:false (missing repo, nothing scannable, no engine); 1 usage error.
ADAPTER="express"
USAGE_TEXT='express.sh --repo <path> [--exec-prefix "<prefix>"]'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
parse_args "$@"
prepare

scan_find "$REPO" "$W/files.txt" \( -name node_modules -o -name dist -o -name build -o -name coverage -o -name .next -o -name __tests__ -o -name test -o -name tests -o -name .git \) -prune -o \
    -type f \( -name '*.js' -o -name '*.ts' -o -name '*.mjs' -o -name '*.cjs' \) \
    ! -name '*.test.*' ! -name '*.spec.*' ! -name '*.d.ts' -print
sort -o "$W/files.txt" "$W/files.txt"

: > "$W/mounts.txt"; : > "$W/found.tsv"
NFILES=0
while IFS= read -r f; do
  NFILES=$((NFILES + 1))
  grep -Eh '\b(app|[A-Za-z0-9_]*[Rr]outer)\.(get|post|put|patch|delete)[[:space:]]*\([[:space:]]*['"'"'"`]/' "$REPO/$f" > "$W/g.out" 2> "$W/g.err"
  grc=$?
  if [ "$grc" -ge 2 ]; then
    SCAN_FAILED=$((SCAN_FAILED + 1))
    echo "could not scan $f: $(sed -e '/^[[:space:]]*$/d' "$W/g.err" | head -n 1 | sed -e 's/^grep: //')" >> "$W/warnings.txt"
    continue
  fi
  awk '{
        s = $0
        while (match(s, /\.(get|post|put|patch|delete)[ \t]*\([ \t]*['"'"'"`]\/[^'"'"'"`]*['"'"'"`]/)) {
          t = substr(s, RSTART, RLENGTH)
          m = t; sub(/^\./, "", m); sub(/[ \t]*\(.*$/, "", m)
          p = t; sub(/^[^'"'"'"`]*['"'"'"`]/, "", p); sub(/['"'"'"`]$/, "", p)
          print toupper(m) "\t" p
          s = substr(s, RSTART + RLENGTH)
        }
      }' "$W/g.out" >> "$W/found.tsv"
  grep -Eq '\.use[[:space:]]*\([[:space:]]*['"'"'"`]/' "$REPO/$f" 2>/dev/null && echo x >> "$W/mounts.txt"
done < "$W/files.txt"
if [ "$SCAN_FAILED" -gt 0 ] && [ ! -s "$W/found.tsv" ] && { [ "$NFILES" -eq 0 ] || [ "$(grep -c '^could not scan' "$W/warnings.txt")" -ge "$NFILES" ]; }; then
  fail "nothing could be scanned: $(head -n 1 "$W/warnings.txt")"
fi

while IFS="$(printf '\t')" read -r m p; do
  p="$(printf '%s' "$p" | sed -E -e 's#:([A-Za-z0-9_]+)\??#{\1}#g')"
  add_surface endpoint "$m" "$(norm_path "$p")" static
done < "$W/found.tsv"
[ -s "$W/mounts.txt" ] && echo "app.use mount prefixes are not applied; router paths are as declared" >> "$W/warnings.txt"
[ -s "$W/surfaces.tsv" ] || echo "no app.<method>('/path') or router.<method>('/path') routes found" >> "$W/warnings.txt"
emit_adapter_json
