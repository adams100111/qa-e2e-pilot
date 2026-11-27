# shellcheck shell=bash
# lib.sh — one python process for the value readers of the qa-auto* suites.
#
# Each suite reads values out of JSON files with `jv`, out of JSON text with `js`, and changes
# JSON files with `ed`. Those used to start python every time (about 30 ms a start, thousands of
# starts a suite), which was a large part of every suite's run time. Sourced AFTER a suite has
# defined ROOT (its scratch folder), PY (the python interpreter) and its own `jv`, `js` and `ed`,
# this file starts ONE python process, asks it over two named pipes, and replaces the three
# helpers with ones that ask it. Same arguments, same output. If the process cannot be started
# the suite keeps its own helpers. bash 3.2 safe (no coproc).
#
#   jv <file> <python expression over d>      d is the file's JSON
#   js <json text> <python expression over d> d is the text's JSON
#   ed <file> <python statements over d>      d is the file's JSON, written back afterwards
#
# A request is one line, `<op><TAB><first><TAB><second>`; an answer is one line. A line break
# inside a field travels as U+0001 and a tab as U+0002. The process ends when the suite does (its
# request pipe closes).
QA_AUTO_SERVER='
import json, sys
def dec(s):
    return s.replace("\x01", "\n").replace("\x02", "\t")
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    op, a = parts[0], [dec(x) for x in parts[1:]]
    try:
        if op == "V":
            with open(a[0], encoding="utf-8") as f:
                d = json.load(f)
            v = eval(a[1])
        elif op == "S":
            d = json.loads(a[0])
            v = eval(a[1])
        else:
            p = a[0]
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
            exec(a[1])
            with open(p, "w", encoding="utf-8") as f:
                json.dump(d, f, ensure_ascii=False)
            v = ""
        out = json.dumps(v, sort_keys=True, ensure_ascii=False) if isinstance(v, (dict, list, bool)) or v is None else str(v)
    except Exception:
        out = "<unreadable>"
    sys.stdout.write(out.replace("\n", "\x01") + "\n")
    sys.stdout.flush()
'
qa_auto_ask() {
  local a="$2" b="$3" r nl=$'\n' tab=$'\t' s1=$'\001' s2=$'\002'
  a="${a//$nl/$s1}"; a="${a//$tab/$s2}"
  b="${b//$nl/$s1}"; b="${b//$tab/$s2}"
  printf '%s\t%s\t%s\n' "$1" "$a" "$b" >&8
  IFS= read -r -t 30 -u 9 r || r="<unreadable>"
  printf '%s\n' "${r//$s1/$nl}"
}
if mkfifo "$ROOT/.ask" "$ROOT/.answer" 2>/dev/null; then
  "$PY" -X utf8 -c "$QA_AUTO_SERVER" < "$ROOT/.ask" > "$ROOT/.answer" 2>/dev/null &
  exec 8>"$ROOT/.ask" 9<"$ROOT/.answer"
  # (a file that only this shell can open, such as <(…), is read here and sent as text)
  jv() { case "$1" in /dev/fd/*|/proc/*) qa_auto_ask S "$(cat "$1")" "$2" ;; *) qa_auto_ask V "$1" "$2" ;; esac; }
  js() { qa_auto_ask S "$1" "$2"; }
  ed() { qa_auto_ask X "$1" "$2" >/dev/null; }
fi
