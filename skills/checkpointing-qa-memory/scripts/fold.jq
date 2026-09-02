# fold.jq — pure reducer: {events, skipped} (stdin JSON) -> {checkpoint,
# anomalies, openActs} (stdout JSON). Plan A Task 2 (AC-1/AC-2 core).
#
# Byte-for-behaviour-identical counterpart to fold.py — see that file's
# header for the shared rule table. Both engines are invoked by fold.sh,
# which does ALL line-by-line parsing/validation itself (this reducer only
# ever sees already-valid, schema-known events — see journal.sh's EVENT
# SCHEMA comment block for field names, and checkpoint.sh's upsert_jq/
# upsert_py for the EXACT checkpoint.json record shape reproduced below).
#
# INPUT:  {"events": [<valid, schema-known event objects, any order>],
#          "skipped": [<wrapper-level anomaly objects, e.g. unparseable-line
#                       / unknown-event>]}
# OUTPUT: {"checkpoint": {"run_id", "updated_at", "criteria": [...]},
#          "anomalies": [...wrapper skipped ++ engine-detected...],
#          "openActs": [...act_intent keys with no matching act_committed...],
#          "cursor": {"run_id", "phase", "criteria_total", "criteria_done",
#                     "personas": [...sorted], "scenarios": [...sorted],
#                     "cursor": {"scenarioId","criterionId"}|null}}
#          (Task 4 — cursor is a resumable projection over the SAME journal;
#          it is written to cursor.json, never merged into checkpoint.json.)
#
# ACCEPTED COST (grill Q4): this is a full O(n) fold over the journal's
# events for ONE fold.sh invocation. A caller that re-folds after EVERY
# single journal_append (rather than batching/periodic folds) turns a
# whole run into O(n^2) total work across its lifetime — accepted for
# Plan A/Task 2; no snapshot/incremental-fold cache is implemented here.
# Callers control their own fold cadence.

def tuple_key($e):
  ($e.scenarioId // "") + "" + ($e.criterionId // "") + "" + ($e.personaId // "");

(.events // []) as $events
| (.skipped // []) as $wrapper_skipped
| ($events | sort_by(.seq)) as $ev

# ---- pass 1: act_intent / act_committed key sets (order-insensitive match:
# "no matching act_intent" means no act_intent event anywhere shares the key,
# not merely none seen so far) --------------------------------------------
| (reduce $ev[] as $e ({order: [], seen: {}};
    if $e.event == "act_intent" then
      (($e.key // "")) as $k
      | if (.seen | has($k)) then . else (.order += [$k] | .seen[$k] = true) end
    else . end
  )) as $intents
| ($intents.order) as $intent_order
| ($intents.seen)  as $intent_set
| (reduce $ev[] as $e ({}; if $e.event == "act_committed" then .[($e.key // "")] = true else . end)) as $committed_set

# ---- pass 2: single ordered fold — run_id/updated_at, a "current phase"
# cursor (set by phase_entered, carried forward), per-tuple groups (first-
# seen order, last-verdict-wins), and anomalies detected inline in seq
# order (duplicate-plan-frozen, act-committed-no-intent). ------------------
| (reduce $ev[] as $e (
    {
      run_id: null, last_t: null, phase: "verify",
      order: [], groups: {},
      anomalies: [], plan_frozen_seen: 0
    };
    (.last_t = ($e.t // .last_t)) |
    if $e.event == "run_started" then
      .run_id = ($e.runId // .run_id)
    elif $e.event == "phase_entered" then
      .phase = ($e.phase // .phase)
    elif $e.event == "plan_frozen" then
      (.plan_frozen_seen += 1) |
      (if .plan_frozen_seen > 1 then .anomalies += [{rule: "duplicate-plan-frozen", seq: $e.seq}] else . end)
    elif $e.event == "act_committed" then
      (($e.key // "")) as $k
      | if ($intent_set | has($k)) then . else .anomalies += [{rule: "act-committed-no-intent", key: $k}] end
    elif $e.event == "criterion_started" then
      (tuple_key($e)) as $k
      | if (.groups | has($k)) then
          .groups[$k].started = true
        else
          .order += [$k]
          | .groups[$k] = {
              scenarioId: ($e.scenarioId // ""), criterionId: ($e.criterionId // ""), personaId: ($e.personaId // ""),
              started: true, verdict: null, phase: null, startedAtVerdict: false
            }
        end
    elif $e.event == "criterion_verdict" then
      (tuple_key($e)) as $k
      | if (.groups | has($k)) then
          .groups[$k].verdict = $e
          | .groups[$k].phase = .phase
          | .groups[$k].startedAtVerdict = (.groups[$k].started // false)
        else
          .order += [$k]
          | .groups[$k] = {
              scenarioId: ($e.scenarioId // ""), criterionId: ($e.criterionId // ""), personaId: ($e.personaId // ""),
              started: false, verdict: $e, phase: .phase, startedAtVerdict: false
            }
        end
    else . end
  )) as $state

# ---- finalize: criteria[] in $state.order order (first-seen tuple
# position); a group with no verdict at all contributes nothing.
# verdict-without-started is decided from startedAtVerdict — the started
# flag AS OF the moment the KEPT (last-wins) verdict was recorded, so a
# criterion_started that arrives AFTER the kept verdict does not retroactively
# erase the anomaly. -------------------------------------------------------
| (reduce $state.order[] as $k ({criteria: [], vws: []};
      ($state.groups[$k]) as $g
      | if $g.verdict == null then .
        else
          (.criteria += [{
            criterion_id: $g.criterionId,
            verdict: $g.verdict.verdict,
            confidence: $g.verdict.confidence,
            phase: ($g.phase // "verify"),
            last_action: ($g.verdict.lastAction // ""),
            evidence_refs: ($g.verdict.evidenceRefs // []),
            bug_ref: (if ($g.verdict.bugRef // "") == "" then null else $g.verdict.bugRef end),
            kinds: ($g.verdict.kinds // []),
            persona: $g.personaId,
            nonUiActionReason: (if ($g.verdict.nonUiActionReason // "") == "" then null else $g.verdict.nonUiActionReason end),
            checkpointed_at: $g.verdict.t
          }])
          | (if ($g.startedAtVerdict // false) then . else
              .vws += [{rule: "verdict-without-started", scenarioId: $g.scenarioId, criterionId: $g.criterionId, personaId: $g.personaId}]
            end)
        end
  )) as $finalized

# ---- openActs: act_intent keys with no matching act_committed key,
# first-seen order. ---------------------------------------------------------
| ([ $intent_order[] | select(. as $k | ($committed_set | has($k)) | not) ]) as $open_acts

# ---- seq-gap (Task 6, durable-substrate fan-out merge): the ascending
# DISTINCT global `seq` values across every valid event in this journal must
# be contiguous (1,2,3,...); a hole (e.g. 1,2,4 — 3 missing) means a
# journal-merge.sh append was skipped/lost/never landed. One anomaly per
# hole, `after` = the last contiguous seq value seen before the gap. Does
# NOT abort the fold — the rest of the checkpoint still reflects whatever
# events ARE present. -------------------------------------------------------
| ([ $ev[].seq ] | map(select(. != null)) | unique) as $seqs
| (reduce $seqs[] as $cur ({prev: null, out: []};
      if .prev == null then .prev = $cur
      elif ($cur - .prev) > 1 then
        (.out += [{rule: "seq-gap", after: .prev}]) | .prev = $cur
      else
        .prev = $cur
      end
    )) as $seqgap_state
| ($seqgap_state.out) as $seqgap_anoms

# ---- cross-child-duplicate (Task 6): a single (scenarioId,criterionId,
# personaId) tuple must not carry criterion_verdict events from TWO
# DIFFERENT fan-out childIds — that means two parallel children raced to
# verdict the SAME tuple, which is a real anomaly to surface (as opposed to
# one child verdicting the same tuple twice, which is normal last-wins and
# must NOT fire this rule — only events that themselves carry a `childId`
# are considered, and only when 2+ DISTINCT childId values appear for the
# same tuple). ---------------------------------------------------------------
| (reduce $ev[] as $e ({};
    if $e.event == "criterion_verdict" and ($e.childId != null) then
      (tuple_key($e)) as $k
      | .[$k] = {
          scenarioId: ($e.scenarioId // ""),
          criterionId: ($e.criterionId // ""),
          personaId: ($e.personaId // ""),
          childIds: (((.[$k].childIds) // []) + [$e.childId] | unique)
        }
    else . end
  )) as $tuple_childids
| ([ $tuple_childids | to_entries[] | select((.value.childIds | length) > 1)
     | {rule: "cross-child-duplicate", tuple: (.value.scenarioId + "/" + .value.criterionId + "/" + .value.personaId)} ]) as $cross_child_anoms

# ---- pass 3 (Task 4): resumable cursor projection — independent of pass 2's
# checkpoint groups. Tracks tuples touched by criterion_started, plan_frozen's
# criteria[] entries (a "planned" tuple counts the same as "started" for
# cursor purposes), and criterion_verdict, in first-seen order; also pairs
# phase_entered/phase_exited for cursor.json's top-level `phase` (this is
# NOT the same as pass 2's per-criterion `phase`, which is a carried-forward
# "last phase_entered" that never resets — this one resets to null once a
# matching phase_exited closes it, per the Task 4 brief). ------------------
| (reduce $ev[] as $e (
    {phase: null, order: [], groups: {}};
    if $e.event == "phase_entered" then
      .phase = ($e.phase // .phase)
    elif $e.event == "phase_exited" then
      (if ($e.phase != null) and ($e.phase == .phase) then .phase = null else . end)
    elif $e.event == "criterion_started" then
      (tuple_key($e)) as $k
      | if (.groups | has($k)) then
          .groups[$k].started = true
        else
          .order += [$k]
          | .groups[$k] = {
              scenarioId: ($e.scenarioId // ""), criterionId: ($e.criterionId // ""), personaId: ($e.personaId // ""),
              started: true, verdict: false
            }
        end
    elif $e.event == "plan_frozen" then
      reduce ($e.criteria // [])[] as $c (.;
        (tuple_key($c)) as $k
        | if (.groups | has($k)) then
            .groups[$k].started = true
          else
            .order += [$k]
            | .groups[$k] = {
                scenarioId: ($c.scenarioId // ""), criterionId: ($c.criterionId // ""), personaId: ($c.personaId // ""),
                started: true, verdict: false
              }
          end
      )
    elif $e.event == "criterion_verdict" then
      (tuple_key($e)) as $k
      | if (.groups | has($k)) then
          .groups[$k].verdict = true
        else
          .order += [$k]
          | .groups[$k] = {
              scenarioId: ($e.scenarioId // ""), criterionId: ($e.criterionId // ""), personaId: ($e.personaId // ""),
              started: false, verdict: true
            }
        end
    else . end
  )) as $cur

# ---- finalize the cursor doc: total/done counts, distinct sorted
# personas/scenarios (a personaId of "" — ADR-0012 legacy back-compat —
# normalizes its scenario to "__shared__" for the scenarios list and for the
# cursor pointer; personas excludes "" itself, it is not a persona), and the
# first started-or-planned-but-unverdicted tuple by seq (else null). --------
| ($cur.order) as $c_order
| ([ $c_order[] | select($cur.groups[.].verdict) ] | length) as $criteria_done
| ($c_order | length) as $criteria_total
| ([ $c_order[] | $cur.groups[.].personaId ] | map(select(. != "")) | unique) as $personas
| ([ $c_order[] | (if $cur.groups[.].personaId == "" then "__shared__" else $cur.groups[.].scenarioId end) ] | unique) as $scenarios
| ([ $c_order[] | select($cur.groups[.].started and ($cur.groups[.].verdict | not)) ] | .[0]) as $cursor_key
| (if $cursor_key == null then null else
    {
      scenarioId: (if $cur.groups[$cursor_key].personaId == "" then "__shared__" else $cur.groups[$cursor_key].scenarioId end),
      criterionId: $cur.groups[$cursor_key].criterionId
    }
  end) as $cursor_ptr
| {
    run_id: $state.run_id,
    phase: $cur.phase,
    criteria_total: $criteria_total,
    criteria_done: $criteria_done,
    personas: $personas,
    scenarios: $scenarios,
    cursor: $cursor_ptr
  } as $cursor_doc

| {
    checkpoint: {
      run_id: $state.run_id,
      updated_at: $state.last_t,
      criteria: $finalized.criteria
    },
    anomalies: ($wrapper_skipped + $state.anomalies + $finalized.vws + $seqgap_anoms + $cross_child_anoms),
    openActs: $open_acts,
    cursor: $cursor_doc
  }
