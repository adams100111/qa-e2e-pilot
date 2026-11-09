#!/usr/bin/env bash
# django.sh — census stack adapter for Django apps. Runs `python manage.py show_urls`
# (django-extensions) when it works; otherwise falls back to a static scan of urls.py files and says
# so in warnings. Contract: adapters/census/README.md.
#
# USAGE:  django.sh --repo <path> [--exec-prefix "<prefix>"]
#   --exec-prefix  config `exec.prefix`, whitespace word-split (no shell quotes), prepended to the
#                  command, e.g. "docker compose exec -T web". Default "".
# COMMAND RUN (from --repo):  <prefix> python manage.py show_urls   (tab-separated: url, view, name)
#   show_urls does not report HTTP methods, so each route is listed as GET (warning says so).
# FALLBACK (show_urls unavailable or failing): scan every urls.py (venv, node_modules, site-packages
#   excluded) for single-line `path(`, `re_path(` and `url(` entries with a string-literal route.
#   `include('pkg.urls')` is followed when it resolves to a urls.py under --repo and its prefix is
#   applied; an unresolved include is named in warnings. Surfaces carry "confidence":"static".
# Route rules: "<int:pk>" and "<pk>" -> "{pk}", "(?P<pk>...)" -> "{pk}", ^ and $ dropped.
# EXIT: 0 ok:true; 3 ok:false (missing repo, no engine, no manage.py and no urls.py); 1 usage error.
ADAPTER="django"
USAGE_TEXT='django.sh --repo <path> [--exec-prefix "<prefix>"]'
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
parse_args "$@"
prepare

# django_route <raw> — normalised route: params as {name}, regex anchors dropped, one leading slash.
django_route() {
  printf '%s' "$1" | sed -E \
    -e 's#\(\?P<([A-Za-z_][A-Za-z0-9_]*)>[^)]*\)#{\1}#g' \
    -e 's#<[A-Za-z_][A-Za-z0-9_]*:([A-Za-z_][A-Za-z0-9_]*)>#{\1}#g' \
    -e 's#<([A-Za-z_][A-Za-z0-9_]*)>#{\1}#g' \
    -e 's#^\^##' -e 's#\$$##' -e 's#\\\.#.#g'
}

PY="python"
command -v python >/dev/null 2>&1 || PY="python3"
USED_SHOW=0
if [ -f "$REPO/manage.py" ] || [ "${#PFX[@]}" -gt 0 ]; then
  if try_cmd "$W/show.txt" "$PY" manage.py show_urls; then
    USED_SHOW=1
  else
    reason="$(sed -e '/^[[:space:]]*$/d' "$W/stderr" | tail -n 1)"
    echo "show_urls unavailable (${reason:-no message}); static urls.py scan used" >> "$W/warnings.txt"
  fi
else
  echo "no manage.py in the repo; static urls.py scan used" >> "$W/warnings.txt"
fi

if [ "$USED_SHOW" -eq 1 ]; then
  while IFS="$(printf '\t')" read -r url _; do
    case "$url" in /*) ;; *) continue ;; esac
    add_surface endpoint GET "$(norm_path "$(django_route "$url")")" ""
  done < "$W/show.txt"
  [ -s "$W/surfaces.tsv" ] || fail "manage.py show_urls printed no routes"
  echo "show_urls does not report HTTP methods: every route listed as GET" >> "$W/warnings.txt"
else
  ( cd "$REPO" && find . \( -name venv -o -name .venv -o -name node_modules -o -name site-packages -o -name .git \) -prune -o -type f -name urls.py -print | sed -e 's#^\./##' | sort ) > "$W/urlfiles.txt"
  [ -s "$W/urlfiles.txt" ] || fail "show_urls unavailable and no urls.py found under $REPO"

  # entries <file> — "route<SOH>include-module" per path()/re_path()/url() line.
  entries() {
    awk -v Q="'" '
      function q(s,   m, re) { # first quoted string in s -> its value; "\001" when there is none
        re = "r?[\"" Q "][^\"" Q "]*[\"" Q "]"
        if (match(s, re)) { m = substr(s, RSTART, RLENGTH); sub("^r?[\"" Q "]", "", m); sub("[\"" Q "]$", "", m); return m }
        return "\001"
      }
      function depth(s,   t, o, c) { t = s; o = gsub(/\(/, "", t); t = s; c = gsub(/\)/, "", t); return 1 + o - c }
      /(^|[^A-Za-z0-9_.])(re_)?path[ \t]*\(|(^|[^A-Za-z0-9_.])url[ \t]*\(/ {
        line = $0
        sub(/^.*((re_)?path|url)[ \t]*\(/, "", line)
        n = 0
        # a call split over lines is joined (up to 4 continuation lines) until its parens close
        while (depth(line) > 0 && n < 4 && (getline nxt) > 0) { line = line " " nxt; n++ }
        route = q(line)
        inc = ""
        if (match(line, /include[ \t]*\([ \t]*\(?[ \t]*/)) { inc = q(substr(line, RSTART + RLENGTH - 1)); if (inc == "\001") inc = "" }
        if (route == "\001") route = "!"
        print route "\001" inc
      }' "$REPO/$1"
  }
  # scan <file> <prefix> <depth> — emit surfaces for one urls.py under a route prefix.
  scan() {
    local file="$1" prefix="$2" depth="$3" route inc target
    while IFS="$(printf '\001')" read -r route inc; do
      if [ "$route" = "!" ]; then
        echo "multi-line path() not fully scanned in $file" >> "$W/warnings.txt"; continue
      fi
      route="$(django_route "$route")"
      if [ -n "$inc" ]; then
        target="${inc//./\/}.py"
        if [ "$depth" -lt 6 ] && [ -f "$REPO/$target" ]; then
          scan "$target" "$prefix/$route" $((depth + 1))
        elif [ "$depth" -lt 6 ] && [ -f "$REPO/${inc//./\/}/urls.py" ]; then
          scan "${inc//./\/}/urls.py" "$prefix/$route" $((depth + 1))
        else
          echo "unresolved include('$inc') under /${prefix#/}: its routes are not listed" >> "$W/warnings.txt"
        fi
      else
        add_surface endpoint GET "$(norm_path "$prefix/$route")" static
      fi
    done < <(entries "$file")
  }
  # roots = urls.py files no other urls.py includes.
  : > "$W/included.txt"
  while IFS= read -r f; do
    entries "$f" | awk -F"$(printf '\001')" '$2 != "" { print $2 }' >> "$W/included.txt"
  done < "$W/urlfiles.txt"
  while IFS= read -r f; do
    mod="${f%.py}"; mod="${mod//\//.}"
    if grep -Fxq "$mod" "$W/included.txt"; then continue; fi
    pkg="${f%/urls.py}"; pkg="${pkg//\//.}"
    if [ "$f" != "urls.py" ] && grep -Fxq "$pkg" "$W/included.txt"; then continue; fi
    scan "$f" "" 0
  done < "$W/urlfiles.txt"
  echo "static scan: HTTP methods are not known, every route listed as GET" >> "$W/warnings.txt"
fi
emit_adapter_json
