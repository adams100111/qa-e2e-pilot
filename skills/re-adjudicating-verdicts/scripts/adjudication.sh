#!/usr/bin/env bash
# adjudication.sh — independent re-adjudication of a finished run (D5, ADR-0033).
# A fresh-context verifier re-judges the run's weakest verdicts from an
# evidence-only bundle; this script selects them, builds the bundles and
# applies the verifier's decisions. It can only ever DOWNGRADE.
#
# USAGE:
#   adjudication.sh select <run-dir>
#       One line per record to re-judge: <criterionId>\t<persona>\t<why>
#       why = low-confidence-pass  (verdict pass, confidence low)
#           | ux-promoted-fail     (verdict fail whose recorded kinds hold none
#                                   of bake|computed|probe, on a UX criterion:
#                                   checklist row tag/kind/stepType visual-ux |
#                                   interaction-ux | ux-revisit)
#       Prints nothing when there is nothing to re-judge. Exit 0.
#
#   adjudication.sh bundle <run-dir> <criterionId> <out-dir> [--persona <id>]
#       Writes an evidence-only bundle into <out-dir> (created; must be empty):
#         criterion.json   the checklist row (null when the run has no row)
#         claim.json       {criterionId, claims:[{persona,verdict,confidence,kinds}]}
#         evidence/...     evidence/[<persona>/]<criterionId>/** (artifacts and
#                          screenshots) + the persona's identity.json (for a
#                          shared criterion: the checklist row role's)
#       Never copied: journal.ndjson, toolstream.jsonl, any *.ndjson/*.jsonl,
#       any *.md, and the agent's prose (last_action, nonUiActionReason,
#       evidence_refs are left out of claim.json). Without --persona every
#       persona's record of the criterion is bundled. Exit 1 on an unknown
#       criterion (or persona).
#
#   adjudication.sh apply <run-dir> <decisions.json>
#       decisions.json = [{criterionId, persona, agree:bool, reason}, ...]
#       (persona "" for a shared criterion; the key is required). Per entry:
#         agree:true                     -> no change
#         agree:false on a pass          -> checkpoint.sh blocked --confidence low
#                                           --last-action "verifier-disagrees: <reason>"
#                                           --phase adjudicate
#         agree:false on a fail          -> stays fail, confidence low, same
#                                           last-action (kinds/bug-ref/refs kept)
#         agree:false on blocked|deferred|error -> no change (already not a pass)
#       An entry that is malformed or names a criterion/persona with no record
#       is REJECTED: skipped, reported on stderr, the other entries still apply,
#       exit 1. An entry that would RAISE a verdict or a confidence (an optional
#       `verdict` key of pass on a non-pass record or anything but fail on a
#       fail record, or `confidence: high` on a low record) refuses the WHOLE
#       batch before anything is written: exit 1 "ADJUDICATION: upgrades are
#       not allowed". A lower `verdict`/`confidence` key is accepted and
#       ignored — the write is always the fixed downgrade above.
#
#   adjudication.sh capability <harness> [<run-dir>]
#       Prints "available" when the harness can dispatch a fresh-context
#       subagent (its harness-profiles.json `dispatch` uses the Agent/Task
#       tool), else the banner
#       "re-adjudication unavailable on <harness>; <n> low-confidence passes unreviewed"
#       (n counted from <run-dir> when given, else 0). Exit 0 either way.
#       QA_HARNESS_PROFILES overrides the profiles path; with no profiles
#       file only `claude` is treated as capable.
#
# <run-dir> is <project>/.qa/runs/<run-id>; apply runs checkpoint.sh from
# <project> so the write goes through every record-time gate.
#
# DEPENDENCIES: bash (3.2-safe), coreutils, EITHER jq OR python3
#               (QA_ENGINE=jq|python3 forces one). Both engines only EXTRACT
#               fields; every decision and message is made here in bash, so the
#               engines cannot disagree.
set -uo pipefail

die()  { echo "ERROR: $*" >&2; exit 2; }
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }
has_jq || has_py || die "adjudication.sh needs either 'jq' or 'python3'."

US=$'\037'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CHECKPOINT_SH="${QA_CHECKPOINT_SH:-$ENGINE_ROOT/skills/checkpointing-qa-memory/scripts/checkpoint.sh}"

usage() {
  die "usage: adjudication.sh select <run-dir> | bundle <run-dir> <criterionId> <out-dir> [--persona <id>] | apply <run-dir> <decisions.json> | capability <harness> [<run-dir>]"
}

# safe_token <value> — criterion/persona ids interpolated into paths.
safe_token() {
  case "$1" in
    */*|*\\*|*..*|-*) return 1 ;;
  esac
  return 0
}

require_run() {
  local rd="$1"
  [ -d "$rd" ] || die "run dir not found: $rd"
  [ -f "$rd/checkpoint.json" ] || die "no checkpoint.json in $rd"
}

# records <run-dir> — one US-separated line per checkpoint record:
#   crit persona verdict confidence kinds(csv) bug_ref evidence_refs(compact json) last_action
records() {
  local f="$1/checkpoint.json"
  if has_jq; then
    jq -r --arg us "$US" '
      def clean: tostring | gsub("[\t\r\n\u001f]"; " ");
      (.criteria // [])[] | select(type == "object") |
      [ (.criterion_id // "" | clean), (.persona // "" | clean), (.verdict // "" | clean),
        (.confidence // "" | clean),
        ((.kinds // []) | if type == "array" then map(clean) | join(",") else "" end),
        (.bug_ref // "" | clean),
        ((.evidence_refs // []) | if type == "array" then tojson else "[]" end),
        (.last_action // "" | clean) ] | join($us)' "$f"
  else
    PYTHONIOENCODING=utf-8 python3 - "$f" "$US" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); us = sys.argv[2]
def clean(v):
    if v is None: v = ""
    if not isinstance(v, str): v = json.dumps(v, ensure_ascii=False) if not isinstance(v, (int, float)) else str(v)
    return re.sub("[\t\r\n\x1f]", " ", v)
for r in d.get("criteria") or []:
    if not isinstance(r, dict): continue
    kinds = r.get("kinds") or []
    refs = r.get("evidence_refs") or []
    print(us.join([clean(r.get("criterion_id")), clean(r.get("persona")), clean(r.get("verdict")),
                   clean(r.get("confidence")),
                   ",".join(clean(k) for k in kinds) if isinstance(kinds, list) else "",
                   clean(r.get("bug_ref")),
                   json.dumps(refs, ensure_ascii=False, separators=(",", ":")) if isinstance(refs, list) else "[]",
                   clean(r.get("last_action"))]))
PY
  fi
}

# rows <run-dir> — one line per checklist row: id kind stepType role tags(csv)
rows() {
  local f="$1/checklist.json"
  [ -f "$f" ] || return 0
  if has_jq; then
    jq -r --arg us "$US" '
      def clean: tostring | gsub("[\t\r\n\u001f,]"; " ");
      (if type == "array" then .[] else empty end) | select(type == "object") |
      [ (.id // "" | clean), (.kind // "" | clean), (.stepType // "" | clean), (.role // "" | clean),
        ((.tags // []) | if type == "array" then map(clean) | join(",") else "" end) ] | join($us)' "$f"
  else
    PYTHONIOENCODING=utf-8 python3 - "$f" "$US" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); us = sys.argv[2]
def clean(v):
    if v is None: v = ""
    if not isinstance(v, str): v = str(v)
    return re.sub("[\t\r\n\x1f,]", " ", v)
for r in (d if isinstance(d, list) else []):
    if not isinstance(r, dict): continue
    tags = r.get("tags") or []
    print(us.join([clean(r.get("id")), clean(r.get("kind")), clean(r.get("stepType")), clean(r.get("role")),
                   ",".join(clean(t) for t in tags) if isinstance(tags, list) else ""]))
PY
  fi
}

# row_json <run-dir> <crit> — the checklist row, pretty (sorted keys), or null.
row_json() {
  local f="$1/checklist.json" cid="$2"
  if [ ! -f "$f" ]; then echo "null"; return 0; fi
  if has_jq; then
    jq -S --arg cid "$cid" '(if type == "array" then [ .[] | select(type == "object" and .id == $cid) ] else [] end) | (.[0] // null)' "$f"
  else
    PYTHONIOENCODING=utf-8 python3 - "$f" "$cid" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
m = [r for r in (d if isinstance(d, list) else []) if isinstance(r, dict) and r.get("id") == sys.argv[2]]
print(json.dumps(m[0] if m else None, indent=2, sort_keys=True, ensure_ascii=False))
PY
  fi
}

# is_ux_row <kind> <stepType> <tags-csv>
is_ux_row() {
  local k="$1" st="$2" tags=",$3,"
  case "$k" in visual-ux|interaction-ux|ux-revisit) return 0 ;; esac
  case "$st" in visual-ux|interaction-ux) return 0 ;; esac
  case "$tags" in *,visual-ux,*|*,interaction-ux,*|*,ux-revisit,*) return 0 ;; esac
  return 1
}

# has_state_kind <kinds-csv> — true when bake|computed|probe is among them.
has_state_kind() {
  case ",$1," in *,bake,*|*,computed,*|*,probe,*) return 0 ;; esac
  return 1
}

cmd_select() {
  [ "$#" -eq 1 ] || usage
  local rd="$1"; require_run "$rd"
  local tmp; tmp="$(mktemp)"
  rows "$rd" > "$tmp" || { rm -f "$tmp"; die "cannot read $rd/checklist.json"; }
  local recs; recs="$(records "$rd")" || { rm -f "$tmp"; die "cannot read $rd/checkpoint.json"; }
  local cid persona verdict conf kinds bug refs la
  while IFS="$US" read -r cid persona verdict conf kinds bug refs la; do
    [ -n "$cid" ] || continue
    if [ "$verdict" = "pass" ] && [ "$conf" = "low" ]; then
      printf '%s\t%s\t%s\n' "$cid" "$persona" "low-confidence-pass"
    elif [ "$verdict" = "fail" ] && ! has_state_kind "$kinds"; then
      local rid rk rst rrole rtags
      while IFS="$US" read -r rid rk rst rrole rtags; do
        if [ "$rid" = "$cid" ] && is_ux_row "$rk" "$rst" "$rtags"; then
          printf '%s\t%s\t%s\n' "$cid" "$persona" "ux-promoted-fail"
          break
        fi
      done < "$tmp"
    fi
  done <<EOF
$recs
EOF
  rm -f "$tmp"
  return 0
}

# claims_json <crit> <lines-of-records> — via the engine, from US lines on stdin.
claims_json() {
  local cid="$1"
  if has_jq; then
    jq -R -s -S --arg cid "$cid" --arg us "$US" '
      { criterionId: $cid,
        claims: [ split("\n")[] | select(length > 0) | split($us)
                  | { persona: .[1], verdict: .[2], confidence: .[3],
                      kinds: (if .[4] == "" then [] else (.[4] | split(",")) end) } ] }'
  else
    PYTHONIOENCODING=utf-8 python3 -c '
import json, sys
cid, us = sys.argv[1], sys.argv[2]
claims = []
for line in sys.stdin.read().split("\n"):
    if not line: continue
    f = line.split(us)
    claims.append({"persona": f[1], "verdict": f[2], "confidence": f[3],
                   "kinds": f[4].split(",") if f[4] else []})
print(json.dumps({"criterionId": cid, "claims": claims}, indent=2, sort_keys=True, ensure_ascii=False))
' "$cid" "$US"
  fi
}

# copy_dir <src> <dst> — recursive copy, then drop journals/toolstreams/prose.
copy_dir() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  cp -R "$src/." "$dst/"
  find "$dst" -type f \( -name 'journal.ndjson' -o -name 'toolstream.jsonl' -o -name '*.ndjson' \
    -o -name '*.jsonl' -o -name '*.md' \) -exec rm -f {} +
}

cmd_bundle() {
  [ "$#" -ge 3 ] || usage
  local rd="$1" cid="$2" out="$3"; shift 3
  local want_persona="" persona_set=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --persona) [ "$#" -ge 2 ] || usage; want_persona="$2"; persona_set=1; shift 2 ;;
      *) usage ;;
    esac
  done
  require_run "$rd"
  safe_token "$cid" || die "unsafe criterion id: $cid"
  [ -z "$want_persona" ] || safe_token "$want_persona" || die "unsafe persona: $want_persona"

  local recs matched=""
  recs="$(records "$rd")" || die "cannot read $rd/checkpoint.json"
  local c p v cf k b r la
  while IFS="$US" read -r c p v cf k b r la; do
    [ "$c" = "$cid" ] || continue
    if [ "$persona_set" -eq 1 ] && [ "$p" != "$want_persona" ]; then continue; fi
    matched="${matched}${c}${US}${p}${US}${v}${US}${cf}${US}${k}"$'\n'
  done <<EOF
$recs
EOF
  if [ -z "$matched" ]; then
    echo "ADJUDICATION: unknown criterion '${cid}'${want_persona:+ (persona ${want_persona})} — no record in $rd/checkpoint.json" >&2
    exit 1
  fi

  if [ -e "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    die "bundle out-dir is not empty: $out"
  fi
  mkdir -p "$out/evidence" || die "cannot create $out"

  row_json "$rd" "$cid" > "$out/criterion.json" || die "cannot read checklist row"
  printf '%s' "$matched" | claims_json "$cid" > "$out/claim.json" || die "cannot write claim.json"

  local role=""
  local rid rk rst rrole rtags
  while IFS="$US" read -r rid rk rst rrole rtags; do
    if [ "$rid" = "$cid" ]; then role="$rrole"; break; fi
  done <<EOF
$(rows "$rd")
EOF

  local ev="$rd/evidence"
  while IFS="$US" read -r c p v cf k; do
    [ -n "$c" ] || continue
    if [ -n "$p" ]; then
      copy_dir "$ev/$p/$cid" "$out/evidence/$p/$cid"
      [ -f "$ev/$p/identity.json" ] && cp "$ev/$p/identity.json" "$out/evidence/$p/identity.json"
    else
      copy_dir "$ev/$cid" "$out/evidence/$cid"
      if [ -n "$role" ] && safe_token "$role" && [ -f "$ev/$role/identity.json" ]; then
        mkdir -p "$out/evidence/$role"
        cp "$ev/$role/identity.json" "$out/evidence/$role/identity.json"
      fi
    fi
  done <<EOF
$matched
EOF
  echo "$out"
}

# decisions <file> — one US line per entry:
#   idx shape cidType cid personaType persona agree reasonType reason verdictType verdict confType conf
# type = string|missing|other ; agree = true|false|bad ; shape = object|other
decisions() {
  local f="$1"
  if has_jq; then
    jq -r --arg us "$US" '
      def clean: tostring | gsub("[\t\r\n\u001f]"; " ");
      def ty(k): if has(k) | not then "missing" elif (.[k] | type) == "string" then "string" else "other" end;
      def val(k): if (has(k) and (.[k] | type) == "string") then (.[k] | clean) else "" end;
      if type != "array" then error("decisions must be a JSON array") else . end
      | to_entries[] | .key as $i | .value
      | if type != "object" then [($i | tostring), "other", "", "", "", "", "bad", "", "", "", "", "", ""]
        else [ ($i | tostring), "object", ty("criterionId"), val("criterionId"), ty("persona"), val("persona"),
               (if (.agree | type) == "boolean" then (.agree | tostring) else "bad" end),
               ty("reason"), (val("reason") | .[0:200]), ty("verdict"), val("verdict"), ty("confidence"), val("confidence") ]
        end | join($us)' "$f"
  else
    PYTHONIOENCODING=utf-8 python3 - "$f" "$US" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); us = sys.argv[2]
if not isinstance(d, list):
    sys.stderr.write("decisions must be a JSON array\n"); sys.exit(5)
def clean(v): return re.sub("[\t\r\n\x1f]", " ", v)
def ty(o, k):
    if k not in o: return "missing"
    return "string" if isinstance(o[k], str) else "other"
def val(o, k): return clean(o[k]) if isinstance(o.get(k), str) else ""
for i, o in enumerate(d):
    if not isinstance(o, dict):
        print(us.join([str(i), "other", "", "", "", "", "bad", "", "", "", "", "", ""])); continue
    a = o.get("agree")
    agree = ("true" if a else "false") if isinstance(a, bool) else "bad"
    print(us.join([str(i), "object", ty(o, "criterionId"), val(o, "criterionId"), ty(o, "persona"), val(o, "persona"),
                   agree, ty(o, "reason"), val(o, "reason")[:200], ty(o, "verdict"), val(o, "verdict"),
                   ty(o, "confidence"), val(o, "confidence")]))
PY
  fi
}

# find_record <recs> <crit> <persona> -> "verdict US conf US kinds US bug US refs US last_action", rc 1 if none
find_record() {
  local recs="$1" want_c="$2" want_p="$3"
  local c p v cf k b r la
  while IFS="$US" read -r c p v cf k b r la; do
    if [ "$c" = "$want_c" ] && [ "$p" = "$want_p" ]; then
      printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$v" "$US" "$cf" "$US" "$k" "$US" "$b" "$US" "$r" "$US" "$la"
      return 0
    fi
  done <<EOF
$recs
EOF
  return 1
}

label() { if [ -n "$2" ]; then printf '%s@%s' "$1" "$2"; else printf '%s' "$1"; fi; }

cmd_apply() {
  [ "$#" -eq 2 ] || usage
  local rd="$1" df="$2"
  require_run "$rd"
  [ -f "$df" ] || die "decisions file not found: $df"
  rd="$(cd "$rd" && pwd)"
  local run_id runs_dir qa_dir project
  run_id="$(basename "$rd")"; runs_dir="$(dirname "$rd")"; qa_dir="$(dirname "$runs_dir")"
  [ "$(basename "$runs_dir")" = "runs" ] && [ "$(basename "$qa_dir")" = ".qa" ] \
    || die "run dir must be <project>/.qa/runs/<run-id>: $rd"
  project="$(dirname "$qa_dir")"
  [ -f "$CHECKPOINT_SH" ] || die "checkpoint.sh not found at $CHECKPOINT_SH"

  local recs lines
  recs="$(records "$rd")" || die "cannot read $rd/checkpoint.json"
  lines="$(decisions "$df")" || die "cannot parse decisions: $df (must be a JSON array)"

  # Pass 1: classify every entry; nothing is written until the whole batch is
  # known to hold no upgrade.
  local plan="" rejected=0 upgrade=""
  local i shape ct cid pt persona agree rt reason vt vv cft cfv
  while IFS="$US" read -r i shape ct cid pt persona agree rt reason vt vv cft cfv; do
    [ -n "$i" ] || continue
    local why=""
    if [ "$shape" != "object" ]; then why="entry is not an object"
    elif [ "$ct" != "string" ] || [ -z "$cid" ]; then why="criterionId missing or not a string"
    elif [ "$pt" != "string" ]; then why="persona missing or not a string (use \"\" for a shared criterion)"
    elif [ "$agree" = "bad" ]; then why="agree missing or not a boolean"
    elif [ "$agree" = "false" ] && { [ "$rt" != "string" ] || [ -z "${reason// /}" ]; }; then why="a disagreement needs a non-empty reason"
    elif [ "$vt" = "other" ] || [ "$cft" = "other" ]; then why="verdict/confidence must be strings"
    elif [ "$cft" = "string" ] && [ "$cfv" != "high" ] && [ "$cfv" != "low" ]; then why="confidence must be high|low"
    elif [ "$vt" = "string" ]; then
      case "$vv" in pass|fail|blocked|deferred|error) ;; *) why="verdict must be pass|fail|blocked|deferred|error" ;; esac
    fi
    local rec=""
    if [ -z "$why" ]; then
      rec="$(find_record "$recs" "$cid" "$persona")" || why="unknown criterion — no record for $(label "$cid" "$persona") in checkpoint.json"
    fi
    if [ -n "$why" ]; then
      echo "ADJUDICATION: rejected entry ${i}${cid:+ ($(label "$cid" "$persona"))}: ${why}" >&2
      rejected=$((rejected+1))
      continue
    fi
    local cur_v cur_c cur_k cur_b cur_r cur_la
    IFS="$US" read -r cur_v cur_c cur_k cur_b cur_r cur_la <<EOF
$rec
EOF
    # Upgrade detection.
    if [ "$cft" = "string" ] && [ "$cfv" = "high" ] && [ "$cur_c" = "low" ]; then
      upgrade="entry ${i} ($(label "$cid" "$persona")): confidence low -> high"
    elif [ "$vt" = "string" ] && [ "$vv" = "pass" ] && [ "$cur_v" != "pass" ]; then
      upgrade="entry ${i} ($(label "$cid" "$persona")): verdict ${cur_v} -> pass"
    elif [ "$vt" = "string" ] && [ "$cur_v" = "fail" ] && [ "$vv" != "fail" ]; then
      upgrade="entry ${i} ($(label "$cid" "$persona")): verdict fail -> ${vv} lifts a fail"
    fi
    [ -z "$upgrade" ] || break
    local act="noop"
    if [ "$agree" = "false" ]; then
      case "$cur_v" in
        pass) act="downgrade-pass" ;;
        fail) case "$cur_la" in verifier-disagrees:*) [ "$cur_c" = "low" ] || act="downgrade-fail" ;; *) act="downgrade-fail" ;; esac ;;
      esac
    fi
    plan="${plan}${act}${US}${cid}${US}${persona}${US}${reason}${US}${cur_v}${US}${cur_c}${US}${cur_k}${US}${cur_b}${US}${cur_r}"$'\n'
  done <<EOF
$lines
EOF

  if [ -n "$upgrade" ]; then
    echo "ADJUDICATION: upgrades are not allowed — ${upgrade}; nothing was written" >&2
    exit 1
  fi

  # Pass 2: apply.
  local applied=0 noop=0 failed=0
  local act c p r cv cc ck cb cr
  while IFS="$US" read -r act c p r cv cc ck cb cr; do
    [ -n "$act" ] || continue
    local la="verifier-disagrees: ${r}"
    case "$act" in
      noop)
        echo "noop: $(label "$c" "$p") ${cv}/${cc}"
        noop=$((noop+1)) ;;
      downgrade-pass)
        if (cd "$project" && "$BASH" "$CHECKPOINT_SH" "$run_id" "$c" blocked --confidence low \
              ${p:+--persona "$p"} --last-action "$la" --phase adjudicate >/dev/null 2>"$project/.qa/runs/$run_id/.adjudication.err"); then
          echo "applied: $(label "$c" "$p") pass/${cc} -> blocked/low (${la})"
          applied=$((applied+1))
        else
          echo "ADJUDICATION: checkpoint.sh refused $(label "$c" "$p"): $(tr '\n' ' ' < "$project/.qa/runs/$run_id/.adjudication.err")" >&2
          failed=$((failed+1))
        fi ;;
      downgrade-fail)
        if (cd "$project" && "$BASH" "$CHECKPOINT_SH" "$run_id" "$c" fail --confidence low \
              ${p:+--persona "$p"} ${ck:+--kinds "$ck"} ${cb:+--bug-ref "$cb"} --evidence-refs "${cr:-[]}" \
              --last-action "$la" --phase adjudicate >/dev/null 2>"$project/.qa/runs/$run_id/.adjudication.err"); then
          echo "applied: $(label "$c" "$p") fail/${cc} -> fail/low (${la})"
          applied=$((applied+1))
        else
          echo "ADJUDICATION: checkpoint.sh refused $(label "$c" "$p"): $(tr '\n' ' ' < "$project/.qa/runs/$run_id/.adjudication.err")" >&2
          failed=$((failed+1))
        fi ;;
    esac
  done <<EOF
$plan
EOF
  rm -f "$project/.qa/runs/$run_id/.adjudication.err"
  echo "adjudication: applied=${applied} noop=${noop} rejected=${rejected} failed=${failed}"
  [ "$rejected" -eq 0 ] && [ "$failed" -eq 0 ] || exit 1
  exit 0
}

cmd_capability() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  local h="$1" rd="${2:-}" prof="${QA_HARNESS_PROFILES:-$ENGINE_ROOT/harness-profiles.json}"
  local dispatch="" capable=0
  if [ -f "$prof" ]; then
    if has_jq; then
      dispatch="$(jq -r --arg h "$h" '.harnesses[$h].dispatch // ""' "$prof")" || die "cannot read $prof"
    else
      dispatch="$(PYTHONIOENCODING=utf-8 python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); print(((d.get("harnesses") or {}).get(sys.argv[2]) or {}).get("dispatch") or "")' "$prof" "$h")" || die "cannot read $prof"
    fi
    case "$dispatch" in *"Agent/Task tool"*) capable=1 ;; esac
  else
    [ "$h" = "claude" ] && capable=1
  fi
  if [ "$capable" -eq 1 ]; then echo "available"; exit 0; fi
  local n=0
  if [ -n "$rd" ]; then
    require_run "$rd"
    n="$(cmd_select "$rd" | grep -c "$(printf '\t')low-confidence-pass\$")" || n=0
  fi
  echo "re-adjudication unavailable on ${h}; ${n} low-confidence passes unreviewed"
  exit 0
}

[ "$#" -ge 1 ] || usage
CMD="$1"; shift
case "$CMD" in
  select) cmd_select "$@" ;;
  bundle) cmd_bundle "$@" ;;
  apply) cmd_apply "$@" ;;
  capability) cmd_capability "$@" ;;
  *) usage ;;
esac
