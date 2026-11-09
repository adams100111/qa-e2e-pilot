#!/usr/bin/env bash
# nextjs.sh — census stack adapter for Next.js apps. Static scan only (no runtime tool, so
# --exec-prefix is accepted and unused). Contract: adapters/census/README.md.
#
# USAGE:  nextjs.sh --repo <path> [--exec-prefix "<prefix>"]
#
# SCANNED (relative to --repo, also under src/):
#   app/**/page.{tsx,jsx,ts,js}      -> GET <route>
#   pages/**/*.{tsx,jsx}             -> GET <route>  (_app, _document and everything under api/ excluded)
#   app/api/**/route.{ts,js,tsx,jsx} -> one <METHOD> <route> per exported GET|POST|PUT|PATCH|DELETE
#                                       handler (none found -> GET plus a warning)
# Route rules: route groups "(g)" and parallel slots "@s" vanish, "index" collapses, "[id]" -> {id},
# "[...rest]" -> {rest*} (catch-all: one or more segments), "[[...rest]]" -> {rest*?} (zero or more). Pages are reported as GET endpoints because file
# routing names URLs, not components. Every surface carries "confidence":"static".
# An unreadable dir or file adds a "could not scan <path>: <reason>" warning; nothing scannable, or
# neither app/ nor pages/ present, is ok:false.
# EXIT: 0 ok:true; 3 ok:false (missing repo, no app/pages dir, nothing scannable, no engine); 1 usage error.
ADAPTER="nextjs"
USAGE_TEXT='nextjs.sh --repo <path> [--exec-prefix "<prefix>"]'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
parse_args "$@"
prepare

# route_of <path relative to the router dir, no extension, no trailing /page|/route|/index>
route_of() {
  [ -n "$1" ] || { echo "/"; return; }
  printf '%s' "$1" | sed -E \
    -e 's#(^|/)\([^/]*\)##g' -e 's#(^|/)@[^/]*##g' \
    -e 's#\[\[\.\.\.([^]/]+)\]\]#{\1*?}#g' -e 's#\[\.\.\.([^]/]+)\]#{\1*}#g' -e 's#\[([^]/]+)\]#{\1}#g' \
    | sed -E -e 's#/+#/#g' -e 's#^([^/])#/\1#' -e 's#^$#/#'
}

FOUND=0
for base in app src/app; do
  [ -d "$REPO/$base" ] || continue
  FOUND=1
  scan_find "$REPO/$base" "$W/pages.txt" -type f \( -name 'page.tsx' -o -name 'page.jsx' -o -name 'page.ts' -o -name 'page.js' \)
  sort -o "$W/pages.txt" "$W/pages.txt"
  while IFS= read -r f; do
    rel="${f#./}"; rel="${rel%/*}"; [ "$rel" = "${f#./}" ] && rel=""
    add_surface endpoint GET "$(route_of "$rel")" static
  done < "$W/pages.txt"
  scan_find "$REPO/$base" "$W/routes.txt" -type f \( -name 'route.ts' -o -name 'route.js' -o -name 'route.tsx' -o -name 'route.jsx' \)
  sort -o "$W/routes.txt" "$W/routes.txt"
  while IFS= read -r f; do
    rel="${f#./}"; rel="${rel%/*}"; [ "$rel" = "${f#./}" ] && rel=""
    case "$rel" in api|api/*) ;; *) continue ;; esac
    grep -Eho 'export[[:space:]]+(async[[:space:]]+)?(function|const)[[:space:]]+(GET|POST|PUT|PATCH|DELETE)\b' "$REPO/$base/${f#./}" > "$W/h.out" 2> "$W/h.err"
    grc=$?
    if [ "$grc" -ge 2 ]; then
      SCAN_FAILED=$((SCAN_FAILED + 1))
      echo "could not scan $base/${f#./}: $(sed -e '/^[[:space:]]*$/d' "$W/h.err" | head -n 1 | sed -e 's/^grep: //')" >> "$W/warnings.txt"
      continue
    fi
    methods="$(sed -E 's/.*[[:space:]](GET|POST|PUT|PATCH|DELETE)$/\1/' "$W/h.out" | sort -u)"
    if [ -z "$methods" ]; then
      methods="GET"; echo "no exported HTTP handler found in $base/${f#./}: assumed GET" >> "$W/warnings.txt"
    fi
    for m in $methods; do add_surface endpoint "$m" "$(route_of "$rel")" static; done
  done < "$W/routes.txt"
done
for base in pages src/pages; do
  [ -d "$REPO/$base" ] || continue
  FOUND=1
  scan_find "$REPO/$base" "$W/pp.txt" -type f \( -name '*.tsx' -o -name '*.jsx' \)
  sort -o "$W/pp.txt" "$W/pp.txt"
  while IFS= read -r f; do
    rel="${f#./}"; rel="${rel%.*}"
    case "$rel" in api|api/*|_app|_document) continue ;; esac
    rel="${rel%/index}"; [ "$rel" = "index" ] && rel=""
    add_surface endpoint GET "$(route_of "$rel")" static
  done < "$W/pp.txt"
done
[ "$FOUND" -eq 1 ] || fail "no app/ or pages/ directory in $REPO (also checked src/): wrong --repo?"
if [ "$SCAN_FAILED" -gt 0 ] && [ ! -s "$W/surfaces.tsv" ]; then
  fail "nothing could be scanned: $(head -n 1 "$W/warnings.txt")"
fi
emit_adapter_json
