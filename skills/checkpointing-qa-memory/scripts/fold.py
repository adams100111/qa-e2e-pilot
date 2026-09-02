#!/usr/bin/env python3
"""fold.py -- pure reducer: {events, skipped} (stdin JSON) -> {checkpoint,
anomalies, openActs} (stdout JSON). Plan A Task 2 (AC-1/AC-2 core).

Byte-for-behaviour-identical counterpart to fold.jq -- same rule table, same
field defaults, same ordering rules. Both engines are invoked by fold.sh,
which does ALL line-by-line parsing/validation itself (this reducer only
ever sees already-valid, schema-known events -- see journal.sh's EVENT
SCHEMA comment block for field names, and checkpoint.sh's upsert_jq/
upsert_py for the EXACT checkpoint.json record shape reproduced below).

INPUT:  {"events": [<valid, schema-known event objects, any order>],
         "skipped": [<wrapper-level anomaly objects, e.g. unparseable-line
                      / unknown-event>]}
OUTPUT: {"checkpoint": {"run_id", "updated_at", "criteria": [...]},
         "anomalies": [...wrapper skipped ++ engine-detected...],
         "openActs": [...act_intent keys with no matching act_committed...],
         "cursor": {"run_id", "phase", "criteria_total", "criteria_done",
                    "personas": [...sorted], "scenarios": [...sorted],
                    "cursor": {"scenarioId","criterionId"}|None}}
         (Task 4 -- cursor is a resumable projection over the SAME journal; it
         is written to cursor.json, never merged into checkpoint.json.)

ACCEPTED COST (grill Q4): this is a full O(n) fold over the journal's events
for ONE fold.sh invocation. A caller that re-folds after EVERY single
journal_append (rather than batching/periodic folds) turns a whole run into
O(n^2) total work across its lifetime -- accepted for Plan A/Task 2; no
snapshot/incremental-fold cache is implemented here. Callers control their
own fold cadence.

NOTE on null-coalescing precision: jq's `//` operator only falls back on
`null`/`false` (an explicit "" or [] is truthy and kept as-is); Python's
`or` falls back on ANY falsy value (also "", [], 0). For run_id/phase --
state carried FORWARD across events, where an explicit "" would be a real
(if unusual) value distinct from "absent" -- this file uses explicit
`is not None` checks to match jq's semantics exactly. For the other fields
below (scenarioId/criterionId/personaId/evidence_refs/kinds/last_action/
bug_ref/nonUiActionReason), the fallback value is identical to the falsy
trigger value (e.g. `x or ""` when the fallback IS ""), so the two engines'
results are provably identical regardless of the operator used -- see the
inline comments at each site.
"""
import json
import sys

KNOWN_EVENTS = {
    "run_started", "phase_entered", "phase_exited", "plan_frozen",
    "plan_amended", "scenario_started", "criterion_started", "act_intent",
    "act_committed", "criterion_verdict", "bug_logged", "run_ended",
}


def s(e, key):
    """String field with '' fallback -- safe as `or ""` (see module docstring)."""
    v = e.get(key)
    return v if v is not None else ""


def tuple_key(e):
    return (s(e, "scenarioId"), s(e, "criterionId"), s(e, "personaId"))


def main():
    payload = json.load(sys.stdin)
    events = sorted(payload.get("events") or [], key=lambda e: e.get("seq") or 0)
    wrapper_skipped = list(payload.get("skipped") or [])

    # ---- pass 1: act_intent / act_committed key sets (order-insensitive
    # match: "no matching act_intent" means no act_intent event anywhere
    # shares the key, not merely none seen so far) -------------------------
    intent_order = []
    intent_set = set()
    committed_set = set()
    for e in events:
        if e.get("event") == "act_intent":
            k = s(e, "key")
            if k not in intent_set:
                intent_set.add(k)
                intent_order.append(k)
        elif e.get("event") == "act_committed":
            committed_set.add(s(e, "key"))

    # ---- pass 2: single ordered fold — run_id/updated_at, a "current
    # phase" cursor (set by phase_entered, carried forward), per-tuple
    # groups (first-seen order, last-verdict-wins), and anomalies detected
    # inline in seq order (duplicate-plan-frozen, act-committed-no-intent).
    run_id = None
    last_t = None
    phase = "verify"
    order = []
    groups = {}
    anomalies = []
    plan_frozen_seen = 0

    for e in events:
        t = e.get("t")
        if t is not None:
            last_t = t

        ev = e.get("event")
        if ev == "run_started":
            rid = e.get("runId")
            run_id = rid if rid is not None else run_id
        elif ev == "phase_entered":
            ph = e.get("phase")
            phase = ph if ph is not None else phase
        elif ev == "plan_frozen":
            plan_frozen_seen += 1
            if plan_frozen_seen > 1:
                anomalies.append({"rule": "duplicate-plan-frozen", "seq": e.get("seq")})
        elif ev == "act_committed":
            k = s(e, "key")
            if k not in intent_set:
                anomalies.append({"rule": "act-committed-no-intent", "key": k})
        elif ev == "criterion_started":
            k = tuple_key(e)
            if k in groups:
                groups[k]["started"] = True
            else:
                order.append(k)
                groups[k] = {
                    "scenarioId": s(e, "scenarioId"),
                    "criterionId": s(e, "criterionId"),
                    "personaId": s(e, "personaId"),
                    "started": True,
                    "verdict": None,
                    "phase": None,
                    "startedAtVerdict": False,
                }
        elif ev == "criterion_verdict":
            k = tuple_key(e)
            if k in groups:
                # Snapshot "started" AS OF THIS MOMENT (before this verdict
                # can itself affect it) -- mirrors fold.jq's startedAtVerdict.
                groups[k]["startedAtVerdict"] = groups[k]["started"]
                groups[k]["verdict"] = e
                groups[k]["phase"] = phase
            else:
                order.append(k)
                groups[k] = {
                    "scenarioId": s(e, "scenarioId"),
                    "criterionId": s(e, "criterionId"),
                    "personaId": s(e, "personaId"),
                    "started": False,
                    "verdict": e,
                    "phase": phase,
                    "startedAtVerdict": False,
                }
        # else: no-op for phase_exited/plan_amended/scenario_started/
        # act_intent/bug_logged/run_ended -- not projected into checkpoint.

    # ---- finalize: criteria[] in `order` (first-seen tuple position); a
    # group with no verdict at all contributes nothing. verdict-without-
    # started is decided from startedAtVerdict -- the started flag AS OF the
    # moment the KEPT (last-wins) verdict was recorded, so a criterion_started
    # that arrives AFTER the kept verdict does not retroactively erase the
    # anomaly. --------------------------------------------------------------
    criteria = []
    vws = []
    for k in order:
        g = groups[k]
        v = g["verdict"]
        if v is None:
            continue
        # bug_ref/nonUiActionReason: jq does `(x // "") == "" then null else
        # x` -- null, missing, AND explicit "" all become null. `x or None`
        # is exactly that (both None and "" are falsy in Python), so this is
        # provably identical to the jq side, not merely a convenient analog.
        bug_ref = v.get("bugRef") or None
        nonui = v.get("nonUiActionReason") or None
        criteria.append({
            "criterion_id": g["criterionId"],
            "verdict": v.get("verdict"),
            "confidence": v.get("confidence"),
            "phase": g["phase"] or "verify",
            "last_action": v.get("lastAction") or "",
            "evidence_refs": v.get("evidenceRefs") or [],
            "bug_ref": bug_ref,
            "kinds": v.get("kinds") or [],
            "persona": g["personaId"],
            "nonUiActionReason": nonui,
            "checkpointed_at": v.get("t"),
        })
        if not g["startedAtVerdict"]:
            vws.append({
                "rule": "verdict-without-started",
                "scenarioId": g["scenarioId"],
                "criterionId": g["criterionId"],
                "personaId": g["personaId"],
            })

    open_acts = [k for k in intent_order if k not in committed_set]

    # ---- seq-gap (Task 6, durable-substrate fan-out merge): the ascending
    # DISTINCT global `seq` values across every valid event in this journal
    # must be contiguous (1,2,3,...); a hole (e.g. 1,2,4 -- 3 missing) means
    # a journal-merge.sh append was skipped/lost/never landed. One anomaly
    # per hole, `after` = the last contiguous seq value seen before the gap.
    # Does NOT abort the fold. Mirrors fold.jq's $seqgap_anoms exactly.
    seqs = sorted({e.get("seq") for e in events if isinstance(e.get("seq"), int)})
    seq_gap_anoms = []
    prev = None
    for cur in seqs:
        if prev is not None and cur - prev > 1:
            seq_gap_anoms.append({"rule": "seq-gap", "after": prev})
        prev = cur

    # ---- cross-child-duplicate (Task 6): a single (scenarioId,criterionId,
    # personaId) tuple must not carry criterion_verdict events from TWO
    # DIFFERENT fan-out childIds -- that means two parallel children raced
    # to verdict the SAME tuple. One child verdicting the same tuple twice
    # is normal last-wins and must NOT fire this rule -- only events that
    # themselves carry a `childId` are considered, and only when 2+ DISTINCT
    # childId values appear for the same tuple. Mirrors fold.jq's
    # $cross_child_anoms exactly (same insertion-order-preserving dict walk
    # as jq's to_entries, so both engines emit anomalies in the same order).
    tuple_childids = {}
    for e in events:
        if e.get("event") == "criterion_verdict" and e.get("childId") is not None:
            k = tuple_key(e)
            entry = tuple_childids.setdefault(k, {
                "scenarioId": s(e, "scenarioId"),
                "criterionId": s(e, "criterionId"),
                "personaId": s(e, "personaId"),
                "childIds": [],
            })
            if e["childId"] not in entry["childIds"]:
                entry["childIds"].append(e["childId"])

    cross_child_anoms = []
    for v in tuple_childids.values():
        if len(v["childIds"]) > 1:
            cross_child_anoms.append({
                "rule": "cross-child-duplicate",
                "tuple": "{}/{}/{}".format(v["scenarioId"], v["criterionId"], v["personaId"]),
            })

    # ---- pass 3 (Task 4): resumable cursor projection -- independent of
    # pass 2's checkpoint groups. Tracks tuples touched by criterion_started,
    # plan_frozen's criteria[] entries (a "planned" tuple counts the same as
    # "started" for cursor purposes), and criterion_verdict, in first-seen
    # order; also pairs phase_entered/phase_exited for cursor.json's
    # top-level `phase` (NOT the same as pass 2's per-criterion `phase`,
    # which is a carried-forward "last phase_entered" that never resets --
    # this one resets to None once a matching phase_exited closes it, per
    # the Task 4 brief).
    cur_phase = None
    cur_order = []
    cur_groups = {}

    def touch(k, sid, cid, pid, started=False, verdict=False):
        if k in cur_groups:
            if started:
                cur_groups[k]["started"] = True
            if verdict:
                cur_groups[k]["verdict"] = True
        else:
            cur_order.append(k)
            cur_groups[k] = {
                "scenarioId": sid, "criterionId": cid, "personaId": pid,
                "started": started, "verdict": verdict,
            }

    for e in events:
        ev = e.get("event")
        if ev == "phase_entered":
            ph = e.get("phase")
            cur_phase = ph if ph is not None else cur_phase
        elif ev == "phase_exited":
            ph = e.get("phase")
            if ph is not None and ph == cur_phase:
                cur_phase = None
        elif ev == "criterion_started":
            k = tuple_key(e)
            touch(k, s(e, "scenarioId"), s(e, "criterionId"), s(e, "personaId"), started=True)
        elif ev == "plan_frozen":
            for c in (e.get("criteria") or []):
                k = tuple_key(c)
                touch(k, s(c, "scenarioId"), s(c, "criterionId"), s(c, "personaId"), started=True)
        elif ev == "criterion_verdict":
            k = tuple_key(e)
            touch(k, s(e, "scenarioId"), s(e, "criterionId"), s(e, "personaId"), verdict=True)
        # else: run_started/act_intent/act_committed/scenario_started/
        # bug_logged/run_ended -- not projected into the cursor.

    # finalize the cursor doc: total/done counts, distinct sorted
    # personas/scenarios (a personaId of "" -- ADR-0012 legacy back-compat --
    # normalizes its scenario to "__shared__" for the scenarios list and for
    # the cursor pointer; personas excludes "" itself, it is not a persona),
    # and the first started-or-planned-but-unverdicted tuple by seq (else
    # None).
    criteria_total = len(cur_order)
    criteria_done = sum(1 for k in cur_order if cur_groups[k]["verdict"])
    personas = sorted({cur_groups[k]["personaId"] for k in cur_order if cur_groups[k]["personaId"] != ""})
    scenarios = sorted({
        ("__shared__" if cur_groups[k]["personaId"] == "" else cur_groups[k]["scenarioId"])
        for k in cur_order
    })
    cursor_ptr = None
    for k in cur_order:
        g = cur_groups[k]
        if g["started"] and not g["verdict"]:
            cursor_ptr = {
                "scenarioId": "__shared__" if g["personaId"] == "" else g["scenarioId"],
                "criterionId": g["criterionId"],
            }
            break

    cursor_doc = {
        "run_id": run_id,
        "phase": cur_phase,
        "criteria_total": criteria_total,
        "criteria_done": criteria_done,
        "personas": personas,
        "scenarios": scenarios,
        "cursor": cursor_ptr,
    }

    out = {
        "checkpoint": {
            "run_id": run_id,
            "updated_at": last_t,
            "criteria": criteria,
        },
        "anomalies": wrapper_skipped + anomalies + vws + seq_gap_anoms + cross_child_anoms,
        "openActs": open_acts,
        "cursor": cursor_doc,
    }
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
