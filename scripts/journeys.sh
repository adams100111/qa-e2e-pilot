#!/usr/bin/env bash
# journeys.sh — validate journeys, compute journey status from a run's checkpoint, and
# expand a journey into a viewport/locale variant (pure, dual-engine).
#
# USAGE:
#   journeys.sh validate <journeys.json> <checklist.json>
#       Prints {"errors":[{"journeyId","reason"}],"ok":bool} on stdout; exit 0 iff ok.
#       Checks: priority is P1|P2|P3; every step id exists in the checklist; the step row's
#       journey.id equals the journey id and journey.step equals its 1-based index; no step id
#       repeats within a journey or across journeys that share an id.
#   journeys.sh status <run-dir>
#       Reads <run-dir>/journeys.json and <run-dir>/checkpoint.json. Prints
#       [{id, priority, verdict: pass|fail|incomplete, steps:[{criterionId, verdict}]}].
#       A step's verdict is the authoritative one after ADR-0029 supersession (a persona-less
#       row is dropped when a persona-scoped row for the same criterion is strictly later; a
#       tie keeps both). Several persona verdicts on one step: any fail|error -> fail, all
#       pass -> pass, otherwise (none, blocked, deferred) -> incomplete. Journey: any failed
#       step -> fail; else every step pass -> pass; else incomplete.
#   journeys.sh expand-variant <journeys.json> <checklist.json> --journey <id>
#                  (--viewport-id <id> | --viewport <WxH>) --locale <code> [--color-scheme light|dark]
#       Prints a new checklist (pretty JSON, sorted keys) holding the journey's rows duplicated
#       with id suffixed "@<viewport>-<locale>[-<scheme>]", `variant` set and `journey.id`
#       suffixed the same. <viewport> is the responsiveMatrix entry's id (e.g. "mobile") when
#       --viewport-id is given -- the same convention as qa-kit's ux:* revisit rows -- else the
#       legacy WxH. Exactly one of the two. Unknown journey, missing step row or bad flag -> exit 1.
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred; QA_ENGINE=jq|python3
#   forces one). Both engines produce byte-identical output. No node/perl/grep -P.
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

usage="usage: journeys.sh validate <journeys.json> <checklist.json> | status <run-dir> | expand-variant <journeys.json> <checklist.json> --journey <id> (--viewport-id <id> | --viewport <WxH>) --locale <code> [--color-scheme light|dark]"
[ "$#" -ge 1 ] || die "$usage"
CMD="$1"; shift
if has_jq; then ENGINE=jq; elif has_py; then ENGINE=py; else die "journeys.sh needs either 'jq' or 'python3'."; fi

case "$CMD" in
  validate)
    [ "$#" -eq 2 ] || die "$usage"
    J="$1"; C="$2"
    [ -f "$J" ] || die "journeys: file not found: $J"
    [ -f "$C" ] || die "journeys: file not found: $C"
    if [ "$ENGINE" = jq ]; then
      out="$(jq -n -S --slurpfile j "$J" --slurpfile c "$C" '
        def s: if type == "string" then . else tojson end;
        ($j[0]) as $js | ($c[0]) as $cl
        | if ($js|type) != "array" then error("journeys must be a JSON array") else . end
        | if ($cl|type) != "array" then error("checklist must be a JSON array") else . end
        | ([ $cl[] | select((.id|type) == "string") | {key: .id, value: .} ] | from_entries) as $byid
        | [ range(0; $js|length) as $i
            | $js[$i] as $jn
            | ($jn.id) as $jid
            | ($jn.steps // []) as $steps
            | ( (if ([$jn.priority] | inside(["P1","P2","P3"])) then empty
                 else "invalid priority: \($jn.priority|tojson)" end),
                ( range(0; $steps|length) as $k
                  | $steps[$k] as $sid
                  | (if ($sid|type) == "string" then $byid[$sid] else null end) as $row
                  | ( if $row == null then "unknown step criterion: \($sid|s)"
                      else
                        ( if ($row.journey|type) != "object" then "step \($sid|s): row has no journey"
                          else
                            ( (if $row.journey.id != $jid then "step \($sid|s): journey.id is \($row.journey.id|tojson), expected \($jid|tojson)" else empty end),
                              (if $row.journey.step != ($k + 1) then "step \($sid|s): journey.step is \($row.journey.step|tojson), expected \($k + 1)" else empty end) )
                          end )
                      end ),
                    ( ( ($steps[0:$k] | index($sid)) != null
                        or ([ $js[0:$i][] | select(.id == $jid) | (.steps // [])[] ] | index($sid)) != null )
                      | if . then "duplicate step id: \($sid|s)" else empty end ) )
              ) as $reason
            | {journeyId: $jid, reason: $reason} ] as $errs
        | {ok: ($errs|length == 0), errors: $errs}')" || die "journeys: validate failed"
    else
      out="$(python3 - "$J" "$C" <<'PY'
import json, sys
def s(v): return v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
js = json.load(open(sys.argv[1], encoding="utf-8")); cl = json.load(open(sys.argv[2], encoding="utf-8"))
if not isinstance(js, list): sys.exit("ERROR: journeys must be a JSON array")
if not isinstance(cl, list): sys.exit("ERROR: checklist must be a JSON array")
byid = {}
for r in cl:
    if isinstance(r, dict) and isinstance(r.get("id"), str): byid[r["id"]] = r
errs = []
for i, jn in enumerate(js):
    jid = jn.get("id"); steps = jn.get("steps")
    if steps is None: steps = []
    def add(reason): errs.append({"journeyId": jid, "reason": reason})
    if jn.get("priority") not in ("P1", "P2", "P3") or not isinstance(jn.get("priority"), str):
        add("invalid priority: " + json.dumps(jn.get("priority"), ensure_ascii=False))
    for k, sid in enumerate(steps):
        row = byid.get(sid) if isinstance(sid, str) else None
        if row is None:
            add("unknown step criterion: " + s(sid))
        else:
            jr = row.get("journey")
            if not isinstance(jr, dict):
                add("step %s: row has no journey" % s(sid))
            else:
                if jr.get("id") != jid:
                    add("step %s: journey.id is %s, expected %s" % (s(sid), json.dumps(jr.get("id"), ensure_ascii=False), json.dumps(jid, ensure_ascii=False)))
                st = jr.get("step")
                if isinstance(st, bool) or st != k + 1:
                    add("step %s: journey.step is %s, expected %d" % (s(sid), json.dumps(st, ensure_ascii=False), k + 1))
        prior = list(steps[:k])
        for pj in js[:i]:
            if pj.get("id") == jid: prior += (pj.get("steps") or [])
        if sid in prior: add("duplicate step id: " + s(sid))
print(json.dumps({"ok": not errs, "errors": errs}, indent=2, sort_keys=True, ensure_ascii=False))
PY
)" || die "journeys: validate failed"
    fi
    printf '%s\n' "$out"
    case "$out" in *'"ok": true'*) exit 0 ;; *) exit 1 ;; esac
    ;;

  status)
    [ "$#" -eq 1 ] || die "$usage"
    R="$1"
    [ -f "$R/journeys.json" ] || die "journeys: $R/journeys.json not found"
    [ -f "$R/checkpoint.json" ] || die "journeys: $R/checkpoint.json not found"
    if [ "$ENGINE" = jq ]; then
      jq -n -S --slurpfile j "$R/journeys.json" --slurpfile k "$R/checkpoint.json" '
        ($j[0]) as $js | ($k[0].criteria // []) as $rows
        | if ($js|type) != "array" then error("journeys must be a JSON array") else . end
        | def stepv($id):
            [ $rows[] | select(.criterion_id == $id) ] as $mine
            | [ $mine[] | select((.persona // "") != "") ] as $pr
            | ( [ $mine[] | select((.persona // "") == "")
                  | . as $r | select( ([ $pr[] | select((.checkpointed_at // "") > ($r.checkpointed_at // "")) ] | length) == 0 ) ]
                + $pr ) as $eff
            | ($eff | map(.verdict)) as $vs
            | if ($vs|length) == 0 then "incomplete"
              elif ($vs | any(. == "fail" or . == "error")) then "fail"
              elif ($vs | all(. == "pass")) then "pass"
              else "incomplete" end;
          [ $js[]
            | . as $jn
            | [ ($jn.steps // [])[] | {criterionId: ., verdict: stepv(.)} ] as $st
            | {id: $jn.id, priority: $jn.priority, steps: $st,
               verdict: (if ($st | any(.verdict == "fail")) then "fail"
                         elif ($st | length) > 0 and ($st | all(.verdict == "pass")) then "pass"
                         else "incomplete" end)} ]' || die "journeys: status failed"
    else
      python3 - "$R/journeys.json" "$R/checkpoint.json" <<'PY' || die "journeys: status failed"
import json, sys
js = json.load(open(sys.argv[1], encoding="utf-8")); ck = json.load(open(sys.argv[2], encoding="utf-8"))
if not isinstance(js, list): sys.exit("ERROR: journeys must be a JSON array")
rows = ck.get("criteria") or []
def stepv(cid):
    mine = [r for r in rows if r.get("criterion_id") == cid]
    pr = [r for r in mine if (r.get("persona") or "") != ""]
    eff = [r for r in mine if (r.get("persona") or "") == "" and not any((p.get("checkpointed_at") or "") > (r.get("checkpointed_at") or "") for p in pr)] + pr
    vs = [r.get("verdict") for r in eff]
    if not vs: return "incomplete"
    if any(v in ("fail", "error") for v in vs): return "fail"
    if all(v == "pass" for v in vs): return "pass"
    return "incomplete"
out = []
for jn in js:
    st = [{"criterionId": c, "verdict": stepv(c)} for c in (jn.get("steps") or [])]
    if any(x["verdict"] == "fail" for x in st): v = "fail"
    elif st and all(x["verdict"] == "pass" for x in st): v = "pass"
    else: v = "incomplete"
    out.append({"id": jn.get("id"), "priority": jn.get("priority"), "steps": st, "verdict": v})
print(json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False))
PY
    fi
    ;;

  expand-variant)
    [ "$#" -ge 2 ] || die "$usage"
    J="$1"; C="$2"; shift 2
    JID=""; VP=""; VPID=""; LOC=""; SCH=""; JSET=0
    while [ "$#" -gt 0 ]; do
      [ "$#" -ge 2 ] || die "$usage"
      case "$1" in
        --journey) JID="$2"; JSET=1 ;;
        --viewport) VP="$2" ;;
        --viewport-id) VPID="$2" ;;
        --locale) LOC="$2" ;;
        --color-scheme) SCH="$2" ;;
        *) die "$usage" ;;
      esac
      shift 2
    done
    [ "$JSET" -eq 1 ] && [ -n "$LOC" ] || die "$usage"
    [ -n "$VP" ] || [ -n "$VPID" ] || die "$usage"
    [ -z "$VP" ] || [ -z "$VPID" ] || die "journeys: pass --viewport-id or --viewport, not both"
    [ -f "$J" ] || die "journeys: file not found: $J"
    [ -f "$C" ] || die "journeys: file not found: $C"
    if [ -n "$VPID" ]; then
      printf '%s' "$VPID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]*$' || die "journeys: --viewport-id must be a simple token like mobile"
      VP="$VPID"
    else
      printf '%s' "$VP" | grep -Eq '^[0-9]+x[0-9]+$' || die "journeys: --viewport must look like 390x844"
    fi
    case "$SCH" in ''|light|dark) ;; *) die "journeys: --color-scheme must be light or dark" ;; esac
    SUF="@${VP}-${LOC}"; [ -z "$SCH" ] || SUF="${SUF}-${SCH}"
    if [ "$ENGINE" = jq ]; then
      jq -n -S --slurpfile j "$J" --slurpfile c "$C" --arg jid "$JID" --arg suf "$SUF" \
         --arg vp "$VP" --arg loc "$LOC" --arg sch "$SCH" '
        ($j[0]) as $js | ($c[0]) as $cl
        | if ($js|type) != "array" then error("journeys must be a JSON array") else . end
        | if ($cl|type) != "array" then error("checklist must be a JSON array") else . end
        | ([ $js[] | select(.id == $jid) ][0]) as $jn
        | if $jn == null then error("unknown journey: \($jid)") else . end
        | ([ $cl[] | select((.id|type) == "string") | {key: .id, value: .} ] | from_entries) as $byid
        | [ ($jn.steps // [])[]
            | . as $sid
            | ($byid[$sid]) as $row
            | if $row == null then error("unknown step criterion: \($sid)") else . end
            | $row
            | .id = (.id + $suf)
            | .journey = ((.journey // {}) + {id: ($jid + $suf)})
            | .variant = ({viewport: $vp, locale: $loc} + (if $sch == "" then {} else {colorScheme: $sch} end)) ]' || exit 1
    else
      python3 - "$J" "$C" "$JID" "$SUF" "$VP" "$LOC" "$SCH" <<'PY' || exit 1
import json, sys
js = json.load(open(sys.argv[1], encoding="utf-8")); cl = json.load(open(sys.argv[2], encoding="utf-8"))
jid, suf, vp, loc, sch = sys.argv[3:8]
if not isinstance(js, list): sys.exit("ERROR: journeys must be a JSON array")
if not isinstance(cl, list): sys.exit("ERROR: checklist must be a JSON array")
jn = next((x for x in js if x.get("id") == jid), None)
if jn is None: sys.exit("ERROR: unknown journey: " + jid)
byid = {r["id"]: r for r in cl if isinstance(r, dict) and isinstance(r.get("id"), str)}
out = []
for sid in (jn.get("steps") or []):
    row = byid.get(sid)
    if row is None: sys.exit("ERROR: unknown step criterion: " + str(sid))
    r = json.loads(json.dumps(row))
    r["id"] = r["id"] + suf
    j = r.get("journey") if isinstance(r.get("journey"), dict) else {}
    j["id"] = jid + suf
    r["journey"] = j
    v = {"viewport": vp, "locale": loc}
    if sch: v["colorScheme"] = sch
    r["variant"] = v
    out.append(r)
print(json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False))
PY
    fi
    ;;

  *) die "$usage" ;;
esac
