#!/usr/bin/env bash
# data-policy.sh — check generated test data against a project's dataPolicy and record
# created record ids for cleanup (dual-engine, byte-identical output).
#
# USAGE:
#   data-policy.sh check <config.json> <@file.json|text> [--kind <criterion-kind>]
#       Prints {ok, violations:[{rule,value,match}]} (sorted keys, 2-space indent).
#       Exit 0 ok, 1 violation, 2 usage/input error. `@file.json` is walked recursively
#       over string VALUES (keys are not checked); anything else is one plain string.
#       Pass generated record data as @file (written to the run dir), never on argv, and
#       never credentials or login fields: the policy is for data a criterion CREATES.
#       --kind input-validation skips the date-window and email-domain rules (deliberately
#       out-of-range / malformed values are that kind's point); markers still apply.
#   data-policy.sh record <run-dir> <entity> <id>
#       Appends {entity,id,at} to <run-dir>/created-records.json (run-dir must exist).
#   data-policy.sh list <run-dir>
#       Prints the recorded array ([] when none).
#
# POLICY (config.dataPolicy = {market, forbiddenMarkers, emailDomain, dateWindow:{from,to}, cleanup}):
#   - absent dataPolicy -> {"ok":true,"policy":"none","violations":[]}, nothing enforced.
#   - forbiddenMarkers default when unset: test, testing, qa, bot, agent, dummy, fake,
#     lorem ipsum, automated, playwright, claude. An explicit [] disables marker checks.
#   - markers match case-insensitively. ASCII markers match WHOLE WORDS with \b...\b in both
#     engines: "contest"/"attestation" do not match "test"; a hyphen is a boundary so
#     "QA-ready" DOES match "qa"; underscore and digits are word chars so "qa_lead" does NOT.
#     Markers containing non-ASCII (Arabic) match as plain substrings.
#   - emailDomain: every email found must end with @<emailDomain> (case-insensitive).
#   - dateWindow: every ISO YYYY-MM-DD found must satisfy from <= date <= to (either optional).
#   - rules: forbidden-marker | email-domain | date-window. `value` is the offending string and
#     `match` the marker/email/date; both truncated to 80 chars.
#   - MASKING: in @file input, a string under a key matching password|passwd|secret|token|otp|pin
#     (case-insensitive substring, any ancestor key), or inside an object whose `name`/`field`
#     matches it, is checked but never echoed: its `value` is "[masked]", and so is `match`
#     unless the rule is forbidden-marker (then `match` is the marker).
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (QA_ENGINE=jq|python3 forces one).
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 2; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }
has_jq || has_py || die "data-policy.sh needs either 'jq' or 'python3'."

usage="usage: data-policy.sh check <config.json> <@file.json|text> [--kind <kind>] | record <run-dir> <entity> <id> | list <run-dir>"
[ "$#" -ge 1 ] || die "$usage"
CMD="$1"; shift

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s' '{}' > "$TMP/empty.json"
ENGINE=py; has_jq && ENGINE=jq

case "$CMD" in
check)
  KIND=""; POS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) [ "$#" -ge 2 ] || die "$usage"; KIND="$2"; shift 2 ;;
      *) POS+=("$1"); shift ;;
    esac
  done
  [ "${#POS[@]}" -eq 2 ] || die "$usage"
  CONFIG="${POS[0]}"; INPUT="${POS[1]}"
  [ -f "$CONFIG" ] || die "data-policy: config not found: $CONFIG"
  MODE=text; IFILE="$TMP/empty.json"; TEXT="$INPUT"
  if [ "${INPUT#@}" != "$INPUT" ]; then
    MODE=file; IFILE="${INPUT#@}"; TEXT=""
    [ -f "$IFILE" ] || die "data-policy: input file not found: $IFILE"
  fi
  if [ "$ENGINE" = jq ]; then
    out="$(jq -n -S --slurpfile c "$CONFIG" --slurpfile f "$IFILE" --arg t "$TEXT" --arg mode "$MODE" --arg kind "$KIND" '
      def esc: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\" + .c);
      def trunc: .[:80];
      def default_markers: ["test","testing","qa","bot","agent","dummy","fake","lorem ipsum","automated","playwright","claude"];
      def sens: test("password|passwd|secret|token|otp|pin"; "i");
      ($c[0]) as $cfg
      | (if $mode == "file" then $f[0] else $t end) as $in
      | if ($cfg|type) != "object" then error("config must be a JSON object") else . end
      | if ($cfg|has("dataPolicy")|not) or $cfg.dataPolicy == null
        then {ok: true, policy: "none", violations: []}
        else
          $cfg.dataPolicy as $p
          | ($kind == "input-validation") as $iv
          | ($p.forbiddenMarkers // default_markers) as $markers
          | (if $iv then null else (($p.emailDomain // null) | if type == "string" then ltrimstr("@") | ascii_downcase else null end) end) as $dom
          | (if $iv then null else (($p.dateWindow // {}).from // null) end) as $from
          | (if $iv then null else (($p.dateWindow // {}).to // null) end) as $to
          | (if ($in | type) == "string" then [{s: $in, m: false}]
             else [ $in | paths(type == "string") as $pp
                    | {s: ($in | getpath($pp)),
                       m: (([$pp[] | select(type == "string") | select(sens)] | length > 0)
                           or ([range(0; $pp | length) as $i | $in | getpath($pp[:$i])
                                | select(type == "object") | (.name, .field)
                                | select(type == "string") | select(sens)] | length > 0))} ] end) as $items
          | [ $items[] | .s as $s | .m as $masked
              | ( ( $markers[] | select(type == "string" and . != "") as $m
                    | (if ($m | explode | all(. < 128))
                       then select($s | test("\\b" + ($m | esc) + "\\b"; "i"))
                       else select($s | contains($m)) end)
                    | {rule: "forbidden-marker", value: ($s | trunc), match: ($m | trunc)} ),
                  ( if $dom != null
                    then ( $s | [match("[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*"; "g").string][]
                           | select((ascii_downcase | endswith("@" + $dom)) | not)
                           | {rule: "email-domain", value: ($s | trunc), match: trunc} )
                    else empty end ),
                  ( if $from != null or $to != null
                    then ( $s | [match("(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])"; "g").string][]
                           | select(($from != null and . < $from) or ($to != null and . > $to))
                           | {rule: "date-window", value: ($s | trunc), match: .} )
                    else empty end ) )
              | if $masked then .value = "[masked]"
                  | (if .rule != "forbidden-marker" then .match = "[masked]" else . end)
                else . end
            ] as $v
          | {ok: ($v | length == 0), violations: $v}
        end
    ' 2>"$TMP/err")"
    [ -n "$out" ] || die "data-policy: jq failed (malformed JSON input or config)."
  else
    out="$(python3 - "$CONFIG" "$IFILE" "$TEXT" "$MODE" "$KIND" <<'PY'
import json, re, sys
cfg_path, in_path, text, mode, kind = sys.argv[1:6]
try:
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    if mode == "file":
        with open(in_path, encoding="utf-8") as fh:
            data = json.load(fh)
    else:
        data = text
except Exception:
    sys.exit(3)
if not isinstance(cfg, dict):
    sys.exit(3)
DEFAULT = ["test","testing","qa","bot","agent","dummy","fake","lorem ipsum","automated","playwright","claude"]
pol = cfg.get("dataPolicy")
if pol is None:
    res = {"ok": True, "policy": "none", "violations": []}
else:
    iv = kind == "input-validation"
    markers = pol.get("forbiddenMarkers")
    if markers is None:
        markers = DEFAULT
    dom = pol.get("emailDomain")
    dom = dom[1:] if isinstance(dom, str) and dom.startswith("@") else dom
    dom = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in dom) if isinstance(dom, str) else None
    dw = pol.get("dateWindow") or {}
    frm = dw.get("from"); to = dw.get("to")
    if iv:
        dom = None; frm = None; to = None
    SENS = re.compile(r"password|passwd|secret|token|otp|pin", re.IGNORECASE)
    def sens(x): return isinstance(x, str) and SENS.search(x) is not None
    items = []
    def walk(x, masked):
        if isinstance(x, str): items.append((x, masked))
        elif isinstance(x, list):
            for i in x: walk(i, masked)
        elif isinstance(x, dict):
            here = masked or sens(x.get("name")) or sens(x.get("field"))
            for k, i in x.items(): walk(i, here or sens(k))
    walk(data, False)
    email_re = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*")
    date_re = re.compile(r"(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])")
    def lower_ascii(s): return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)
    v = []
    for s, masked in items:
        found = []
        for m in markers:
            if not isinstance(m, str) or m == "": continue
            if m.isascii():
                hit = re.search(r"\b" + re.escape(m) + r"\b", s, re.IGNORECASE) is not None
            else:
                hit = m in s
            if hit:
                found.append({"rule": "forbidden-marker", "value": s[:80], "match": m[:80]})
        if dom is not None:
            for mt in email_re.finditer(s):
                e = mt.group(0)
                if not lower_ascii(e).endswith("@" + dom):
                    found.append({"rule": "email-domain", "value": s[:80], "match": e[:80]})
        if frm is not None or to is not None:
            for mt in date_re.finditer(s):
                d = mt.group(0)
                if (frm is not None and d < frm) or (to is not None and d > to):
                    found.append({"rule": "date-window", "value": s[:80], "match": d})
        if masked:
            for x in found:
                x["value"] = "[masked]"
                if x["rule"] != "forbidden-marker": x["match"] = "[masked]"
        v.extend(found)
    res = {"ok": len(v) == 0, "violations": v}
print(json.dumps(res, indent=2, sort_keys=True, ensure_ascii=False))
PY
)" || die "data-policy: invalid JSON in config or input."
  fi
  printf '%s\n' "$out"
  case "$out" in *'"ok": true'*) exit 0 ;; *) exit 1 ;; esac
  ;;
record)
  [ "$#" -eq 3 ] || die "$usage"
  RUNDIR="$1"; ENTITY="$2"; RID="$3"
  [ -d "$RUNDIR" ] || die "data-policy: run-dir not found: $RUNDIR"
  F="$RUNDIR/created-records.json"
  AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -f "$F" ] || printf '%s' '[]' > "$F"
  if [ "$ENGINE" = jq ]; then
    jq -S --arg e "$ENTITY" --arg i "$RID" --arg a "$AT" '. + [{entity: $e, id: $i, at: $a}]' "$F" > "$TMP/out.json" \
      || die "data-policy: malformed $F"
  else
    python3 - "$F" "$ENTITY" "$RID" "$AT" > "$TMP/out.json" <<'PY' || die "data-policy: malformed $F"
import json, sys
f, e, i, a = sys.argv[1:5]
with open(f, encoding="utf-8") as fh:
    d = json.load(fh)
if not isinstance(d, list):
    sys.exit(1)
d.append({"entity": e, "id": i, "at": a})
print(json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False))
PY
  fi
  mv "$TMP/out.json" "$F"
  ;;
list)
  [ "$#" -eq 1 ] || die "$usage"
  F="$1/created-records.json"
  [ -f "$F" ] || { echo "[]"; exit 0; }
  if [ "$ENGINE" = jq ]; then
    jq -S . "$F" || die "data-policy: malformed $F"
  else
    python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1],encoding="utf-8")),indent=2,sort_keys=True,ensure_ascii=False))' "$F" || die "data-policy: malformed $F"
  fi
  ;;
*) die "$usage" ;;
esac
