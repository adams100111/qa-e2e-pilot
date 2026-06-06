#!/usr/bin/env bash
# Portability regression: the PCRE patterns used in the bundled scripts must
# produce identical output via GNU `grep -oP` and the perl fallback (the path
# taken on macOS/BSD where grep has no -P). If these diverge, route/selector
# extraction silently breaks on macOS.
set -uo pipefail
PASS=0; FAIL=0
oP_grep() { grep -oP "$1"; }
oP_perl() { PAT="$1" perl -ne 'print "$&\n" while /$ENV{PAT}/g'; }
oPi_grep(){ grep -oiP "$1"; }
oPi_perl(){ PAT="$1" perl -ne 'print "$&\n" while /$ENV{PAT}/gi'; }

eq() { # label input pattern [i]
  local label="$1" in="$2" pat="$3" mode="${4:-}"
  local a b
  if [[ "$mode" == "i" ]]; then
    a="$(printf '%s' "$in" | oPi_grep "$pat" | head -1)"; b="$(printf '%s' "$in" | oPi_perl "$pat" | head -1)"
  else
    a="$(printf '%s' "$in" | oP_grep "$pat" | head -1)";  b="$(printf '%s' "$in" | oP_perl "$pat" | head -1)"
  fi
  if [[ "$a" == "$b" ]]; then echo "ok   - $label [$a]"; PASS=$((PASS+1));
  else echo "FAIL - $label grep=[$a] perl=[$b]"; FAIL=$((FAIL+1)); fi
}

# One case per distinct PCRE construct used across index-routes.sh / find-spec-kit.sh.
eq "lookbehind single-quote" "Route::get('/leads', x)"          "(?<=')[^']+"
eq "lookbehind href dq"      '<a href="/dashboard?x#y">'        '(?<=href=")[^"?#]+'
eq "lookbehind to sq"        "render( to='/path' )"             "(?<= to=')[^'?#]+"
eq "K-reset route verb"      "Route::POST('/x')"                'Route::\K(get|post|put|patch|delete|apiResource)' i
eq "K-reset express verb"    "router.delete('/x')"              '(?:app|router)\.\K(get|post|put|patch|delete)'
eq "lookahead trpc proc"     "  myList: protectedProcedure"     '\w+(?=:\s*(?:t\.)?(?:publicProcedure|protectedProcedure|procedure))'
eq "aria-label dq"           '<button aria-label="Save lead">'  '(?<=aria-label=")[^"]+'
eq "text node title-case"    '<span>Add Founder</span>'         '(?<=>)[A-Z][a-zA-Z0-9 ]{2,40}(?=</)'
eq "spec-kit path/root K"    '"path": "../backend"'             '"(?:path|root)"\s*:\s*"\K[^"]+'

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
