#!/usr/bin/env bash
# plan-guard.sh — record-time identity guard for a criterion verdict or a
# criterion_started event (engine 0.11.0, ADR-0029). Called by checkpoint.sh
# (before ANY gate runs or anything is appended) and by journal-emit.sh
# `started`, so a mis-shaped id is refused at the moment it is recorded
# instead of surfacing at the end of the run as an out-of-plan row, a
# duplicated row, or a verdict-without-started anomaly — none of which can be
# corrected afterwards, because editing the append-only journal is tampering.
#
# USAGE:
#   plan-guard.sh check <run-id> <criterionId> <scenarioId> <personaId> --for <verdict|started>
#
#   Exit 0, no output         — the record may proceed.
#   Exit 1, message on stderr — refuse the record (the caller dies with it).
#   Exit 2                    — usage error.
#
# RULES (each one is a real slip seen on a production run):
#   1. A criterionId containing whitespace is refused, always. A shell loop
#      that joined twenty ids into one argument recorded ONE bogus
#      criterion whose id was all twenty, which then lived forever as an
#      out-of-plan row.
#   2. When the run's journal carries a frozen plan (`plan_frozen`, plus any
#      `plan_amended`), the criterionId must be one of the planned ids.
#      `journal-emit.sh amend` is the sanctioned way to add one mid-run.
#   3. With a plan, the personaId must be one the plan lists for that
#      criterion ("" = shared). A verdict recorded under a persona the plan
#      never named is a second row for the same criterion — the resume
#      duplicate this guard exists to prevent.
#   4. `--for started` only: the scenarioId must be the one checkpoint.sh
#      derives for that persona — the persona itself, or "__shared__" with
#      personaId "" (ADR-0012). Any other pairing can never meet its verdict.
#   5. `--for verdict` only: when this exact tuple was never started but the
#      criterion has an OPEN criterion_started (no verdict yet) under a
#      different persona, the verdict is refused — the agent started it as
#      one identity and is about to record it as another.
#   No journal, or a journal with no plan, skips rules 2–3 (legacy runs and
#   plan-less unit fixtures keep working unchanged).
#
# DEPENDENCIES: bash, EITHER jq OR python3 (QA_ENGINE honored exactly like
# journal.sh/fold.sh). The engines only EXTRACT facts from the journal; every
# decision and every message is made here in bash, so the two engines cannot
# disagree on a rule.
set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

usage() { echo "Usage: plan-guard.sh check <run-id> <criterionId> <scenarioId> <personaId> --for <verdict|started>" >&2; exit 2; }
refuse() { echo "$*" >&2; exit 1; }

# facts <journal> <criterionId> <scenarioId> <personaId> -> 7 lines:
#   hasPlan(0|1) planCount inPlan(0|1) plannedPersonasDisplay personaPlanned(0|1)
#   thisStarted(0|1) openOther("<scenario> / <persona>" or "")
facts() {
  local journal="$1" cid="$2" sid="$3" pid="$4"
  if has_jq; then
    jq -R -s -r --arg cid "$cid" --arg sid "$sid" --arg pid "$pid" '
      [ split("\n")[] | select(length > 0) | (try fromjson catch null) | select(type == "object") ] as $ev
      | ([ $ev[] | select(.event == "plan_frozen") | (.criteria // [])[] | select(type == "object") ]
         + [ $ev[] | select(.event == "plan_amended") ]) as $planned
      | ([ $ev[] | select(.event == "plan_frozen") ] | length > 0) as $hasPlan
      | ([ $planned[] | (.criterionId // "") ] | unique) as $ids
      | ([ $planned[] | select((.criterionId // "") == $cid) | (.personaId // "") ] | unique) as $personas
      | ([ $ev[] | select(.event == "criterion_started" and (.criterionId // "") == $cid) ]) as $starts
      | ([ $ev[] | select(.event == "criterion_verdict" and (.criterionId // "") == $cid)
           | ((.scenarioId // "") + "\u0000" + (.personaId // "")) ]) as $verdicted
      | ([ $starts[] | select((.scenarioId // "") == $sid and (.personaId // "") == $pid) ] | length > 0) as $thisStarted
      | ([ $starts[]
           | select(((.scenarioId // "") == $sid and (.personaId // "") == $pid) | not)
           | select(((.scenarioId // "") + "\u0000" + (.personaId // "")) as $k | ($verdicted | index($k)) == null)
         ] | .[0]) as $other
      | (if $hasPlan then "1" else "0" end),
        ($ids | length | tostring),
        (if ($ids | index($cid)) != null then "1" else "0" end),
        ($personas | map(if . == "" then "\"\" (shared)" else . end) | join(", ")),
        (if ($personas | index($pid)) != null then "1" else "0" end),
        (if $thisStarted then "1" else "0" end),
        (if $other == null then "" else (($other.scenarioId // "") + " / " + ($other.personaId // "")) end)
    ' < "$journal"
  elif has_py; then
    python3 - "$journal" "$cid" "$sid" "$pid" <<'PYEOF'
import json, sys
path, cid, sid, pid = sys.argv[1:5]
ev = []
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o, dict):
            ev.append(o)
def g(o, k):
    v = o.get(k)
    return v if v is not None else ""
planned = [c for e in ev if e.get("event") == "plan_frozen" for c in (e.get("criteria") or []) if isinstance(c, dict)]
planned += [e for e in ev if e.get("event") == "plan_amended"]
has_plan = any(e.get("event") == "plan_frozen" for e in ev)
ids = sorted({g(c, "criterionId") for c in planned})
personas = sorted({g(c, "personaId") for c in planned if g(c, "criterionId") == cid})
starts = [e for e in ev if e.get("event") == "criterion_started" and g(e, "criterionId") == cid]
verdicted = {(g(e, "scenarioId"), g(e, "personaId")) for e in ev if e.get("event") == "criterion_verdict" and g(e, "criterionId") == cid}
this_started = any(g(e, "scenarioId") == sid and g(e, "personaId") == pid for e in starts)
other = None
for e in starts:
    t = (g(e, "scenarioId"), g(e, "personaId"))
    if t == (sid, pid) or t in verdicted:
        continue
    other = t
    break
print("1" if has_plan else "0")
print(str(len(ids)))
print("1" if cid in ids else "0")
print(", ".join('"" (shared)' if p == "" else p for p in personas))
print("1" if pid in personas else "0")
print("1" if this_started else "0")
print("" if other is None else other[0] + " / " + other[1])
PYEOF
  else
    echo "plan-guard.sh needs either 'jq' or 'python3' to read the journal." >&2
    exit 1
  fi
}

main() {
  [[ "${1:-}" == "check" ]] || usage
  shift
  local mode="" ; local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --for) [[ $# -lt 2 ]] && usage; mode="$2"; shift 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  [[ "${#pos[@]}" -eq 4 ]] || usage
  case "$mode" in verdict|started) ;; *) usage ;; esac
  local run_id="${pos[0]}" cid="${pos[1]}" sid="${pos[2]}" pid="${pos[3]}"

  # Rule 1 — whitespace, always.
  case "$cid" in
    *[[:space:]]*)
      refuse "criterion-id '${cid}' contains whitespace — record ONE criterion per call. A shell loop that joins several ids into one argument records a single bogus criterion that can never be removed from the run (the journal is append-only). Loop over the ids and call once per id." ;;
  esac

  # Rule 4 — scenario/persona pairing for criterion_started.
  if [[ "$mode" == "started" ]]; then
    if [[ -z "$pid" && "$sid" != "__shared__" ]]; then
      refuse "started: scenarioId '${sid}' with an empty personaId — a shared criterion's scenarioId is '__shared__' (checkpoint.sh records its verdict as __shared__ / \"\" when --persona is omitted), so this criterion_started would never meet its verdict. Use: journal-emit.sh started ${run_id} __shared__ ${cid} \"\"  — or, if the criterion runs as '${sid}', use: journal-emit.sh started ${run_id} ${sid} ${cid} ${sid}  and pass --persona ${sid} to checkpoint.sh."
    fi
    if [[ -n "$pid" && "$sid" != "$pid" ]]; then
      refuse "started: scenarioId '${sid}' does not match personaId '${pid}' — checkpoint.sh records a persona-scoped verdict under scenarioId = personaId, so this criterion_started would never meet its verdict. Use: journal-emit.sh started ${run_id} ${pid} ${cid} ${pid}  (or, for a shared criterion: journal-emit.sh started ${run_id} __shared__ ${cid} \"\")."
    fi
  fi

  local journal="${QA_BASE}/${run_id}/journal.ndjson"
  [[ -s "$journal" ]] || exit 0

  local out
  out="$(facts "$journal" "$cid" "$sid" "$pid")" || exit 1
  local has_plan plan_count in_plan personas persona_planned this_started other
  {
    IFS= read -r has_plan
    IFS= read -r plan_count
    IFS= read -r in_plan
    IFS= read -r personas
    IFS= read -r persona_planned
    IFS= read -r this_started
    IFS= read -r other
  } <<< "$out"

  local as_who
  if [[ -n "$pid" ]]; then as_who="persona '${pid}'"; else as_who="a shared criterion (no --persona)"; fi
  local what="this verdict"; [[ "$mode" == "started" ]] && what="this criterion_started"

  if [[ "$has_plan" == "1" ]]; then
    # Rule 2 — the criterion must be planned.
    if [[ "$in_plan" != "1" ]]; then
      refuse "criterion-id '${cid}' is not in this run's frozen plan (${plan_count} planned criteria) — refusing ${what}: it would be a permanent out-of-plan row. Check the id for a typo, and record ONE criterion per call. If the criterion was genuinely added mid-run, journal it first: journal-emit.sh amend ${run_id} ${cid} <scenarioId> <personaId> <true|false>."
    fi
    # Rule 3 — the persona must be one the plan names for it.
    if [[ "$persona_planned" != "1" ]]; then
      local hint
      if [[ "$personas" == '"" (shared)' ]]; then
        hint="Omit --persona (record it as shared, scenarioId __shared__)"
      else
        hint="Record it with --persona <one of: ${personas}>"
      fi
      refuse "criterion '${cid}' is planned for persona(s) [${personas}], but ${what} would be recorded as ${as_who} — a second row for the same criterion, which a resume would duplicate rather than replace. ${hint}. To run it under another persona deliberately, add that tuple first: journal-emit.sh amend ${run_id} ${cid} <scenarioId> <personaId> <true|false>."
    fi
  fi

  # Rule 5 — verdict under a different identity than the open start.
  if [[ "$mode" == "verdict" && "$this_started" != "1" && -n "$other" ]]; then
    refuse "criterion '${cid}' was started as scenario/persona '${other}' (journal-emit.sh started) and has no verdict there yet, but this verdict would be recorded as ${as_who} — the two would never pair (verdict-without-started) and the started tuple would stay open forever. Record the verdict under the identity it was started with (--persona ${other##* / } — omit --persona when that is empty), or start this identity first."
  fi
  exit 0
}

main "$@"
