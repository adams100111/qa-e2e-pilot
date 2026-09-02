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
         "openActs": [...act_intent keys with no matching act_committed...]}

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


def known_persona(p):
    return "" if p == "__shared__" else (p or "")


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
            "persona": known_persona(g["personaId"]),
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

    out = {
        "checkpoint": {
            "run_id": run_id,
            "updated_at": last_t,
            "criteria": criteria,
        },
        "anomalies": wrapper_skipped + anomalies + vws,
        "openActs": open_acts,
    }
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
