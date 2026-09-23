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
OUTPUT: {"checkpoint": {"run_id", "updated_at", "criteria": [...],
                        "findings": [...keyed-set, first-seen order...]},
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

Run FSM Enforcement Task 2: fold.sh also passes the state-machine.json PATH
as argv[1] (fold.jq gets the same content via --slurpfile). This reducer
reads ONLY `legalSubStateEdges`/`guards` from it (data-driven illegal-edge
check below); it holds no hard-coded edge table itself. `act_intent`/
`act_committed` events carry an opaque `key` with NO personaId component --
journal-emit.sh's real convention is `key == "<run-id>:<scenarioId>:
<criterionId>"` (see its header comment and qa-reconcile.sh's
join_openacts_py, which already decodes keys this same way) -- so a tuple's
act-seen booleans are computed by re-deriving that same key from (run_id,
scenarioId, criterionId) and checking membership in the pass-1 intent_set/
committed_set, ignoring personaId (matching the system's actual,
persona-blind key shape; multiple personas sharing one scenario+criterion
would alias to the same key -- an existing structural property of the
journal format, not something introduced here).
"""
import json
import re
import sys

KNOWN_EVENTS = {
    "run_started", "phase_entered", "phase_exited", "plan_frozen",
    "plan_amended", "scenario_started", "criterion_started", "act_intent",
    "act_committed", "criterion_verdict", "bug_logged", "run_ended",
    "finding_observed", "capture_probed",
}


def s(e, key):
    """String field with '' fallback -- safe as `or ""` (see module docstring)."""
    v = e.get(key)
    return v if v is not None else ""


def tuple_key(e):
    return (s(e, "scenarioId"), s(e, "criterionId"), s(e, "personaId"))


# ---- findings-ledger helpers (Task 6, plan 2026-09-23-error-honesty-
# invariants). Exact mirrors of fold.jq's kstr/nmsg/finding_key. Every one is
# a TOTAL function whose result is provably identical to the jq side, because
# a findings ledger that differs between the two engines is worse than one
# that drops a malformed field.

def kstr(v):
    """The ONLY stringification used for a findingKey component or a
    projected findings field.

      str                              -> as-is
      integer-valued number, |v|<1e15  -> its decimal integer form ("500")
      anything else                    -> "" (None, bool, non-integer
                                              number, dict, list)

    `bool` is rejected BEFORE the numeric branch because Python makes
    `isinstance(True, int)` true, while jq reports `true | type` as
    "boolean" -- without the explicit bool check the two engines would
    disagree on a boolean field. The narrow number window and the ""
    default exist for the same reason: jq and python3 render a boolean, a
    non-integral float, a very large number and a container differently as
    text, so none of them is ever stringified here.
    """
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return ""
    if isinstance(v, int):
        return str(v) if -10 ** 15 < v < 10 ** 15 else ""
    if isinstance(v, float):
        if v == int(v) and -1e15 < v < 1e15:
            return str(int(v))
        return ""
    return ""


# Runs of ASCII whitespace only -- space, TAB, LF, CR, VT, FF -- written out
# EXPLICITLY rather than as the \s shorthand: python3 re is unicode-aware
# (\s there also matches NBSP, U+0085, U+2028, ...) while jq's oniguruma
# treats \s as ASCII-only, so the shorthand would silently diverge between
# the engines on exactly the kind of pasted console text a finding carries.
_WS_RUN = re.compile("[ \t\n\r\x0b\x0c]+")


def _trim1(x):
    """Strip ONE leading and ONE trailing space -- jq's
    `ltrimstr(" ") | rtrimstr(" )`, not Python's greedy strip(). After the
    _WS_RUN collapse there is never more than one consecutive space, so the
    two are equivalent on real input; matching jq's exact semantics keeps
    them equivalent on every input."""
    if x.startswith(" "):
        x = x[1:]
    if x.endswith(" "):
        x = x[:-1]
    return x


def nmsg(v):
    """`message` normalization + the 200-character cap (plan Global
    Constraints). Long detail belongs in evidence/<criterion>/findings/
    behind `detailRef`: an event above the PIPE_BUF boundary of 4096 bytes
    is not guaranteed to land torn-free, and the torn-line recovery path is
    itself a duplicate-append path. Non-str -> ""."""
    if not isinstance(v, str):
        return ""
    return _trim1(_trim1(_WS_RUN.sub(" ", v))[:200])


# URL_CAP: `url` is the one event field whose length comes from the
# application under test -- observe.js records every fetch/XHR url, so a
# `data:` URI or a long query string reaches the PIPE_BUF boundary of 4096
# bytes on its own. An event above that boundary is not guaranteed to land
# torn-free; the fold then drops the torn line, that manufactures a
# `seq-gap`, and under plan decision R15 a `seq-gap` marks the WHOLE RUN
# UNVERIFIED. One oversized URL must not be able to invalidate an otherwise
# clean run, so the event contract caps `url` at 1024 characters, carries the
# full length in the integer `urlLen`, and keeps the untruncated url in the
# detail file at `detailRef`.
#
# The bound is arithmetic over the whole documented budget, not an example:
# 16 (event name) + 64 (criterionId) + 7 (source) + 10 (channel) +
# 7 (method) + 1024 (url) + 15 (urlLen digits) + 19 (status) +
# 11 (originClass) + 9 (statusClass) + 1200 (message: 200 codepoints at the
# worst 6-byte JSON escape) + 256 (detailRef) + 15 (seq) + 20 (t) + ~180 for
# key names and punctuation < 4096. `url` is ASCII by contract, not by
# assumption: RFC 3986 defines a URI as a sequence of US-ASCII characters,
# and observe.js records the percent-encoded url the browser reports.
# tests/findings-ledger/run.sh holds every line of that arithmetic, including
# what happens when the ASCII precondition is violated.
URL_CAP = 1024


def url_len(e):
    """The FULL length of the finding's url, whether or not the emitter
    already truncated it. An emitter that caps the url itself MUST supply
    `urlLen`; when it is absent (or not a usable non-negative integer) the
    length of the url actually carried is used. This is what makes the
    derived key identical for a capped event and an uncapped one -- Task 8
    recomputes the key from the driver log, where the url is never
    truncated, so the two derivations have to agree."""
    n = e.get("urlLen")
    if isinstance(n, bool):
        return len(kstr(e.get("url")))
    if isinstance(n, int) and 0 <= n < 10 ** 15:
        return n
    if isinstance(n, float) and n == int(n) and 0 <= n < 1e15:
        return int(n)
    return len(kstr(e.get("url")))


def finding_key(e):
    """The run-scoped identity of one observed finding:

        <criterionId>|<source>|<method>|<url>|<status>

    verbatim from the plan Global Constraints. For a console finding
    (`source == "console"`) the event sets `method` and `url` to "" and the
    URL COMPONENT carries the normalized, capped `message` instead -- still
    exactly five `|`-separated components.

    When the url is TRUNCATED (its full `urlLen` exceeds URL_CAP) the URL
    component is the capped url followed by "#" and the full length. Without
    that discriminator two genuinely different long URLs sharing their first
    1024 characters would collapse into ONE finding -- a finding silently
    hiding another, which is strictly worse than the torn write the cap
    exists to prevent. The marker is appended ONLY on truncation, so an
    ordinary url keys exactly as it reads, and its position is unambiguous:
    it begins after character 1024, and truncation is independently visible
    as `urlLen > 1024` on the entry.

    ACCEPTED RESIDUAL: `urlLen` separates long URLs of DIFFERENT length. Two
    different URLs that share a 1024-character prefix AND have the same total
    length still collapse. Distinguishing those needs a digest of the full
    url, which the event contract does not carry; the case is pinned by a
    test so it is a known stopping point rather than a surprise.

    The key is DERIVED HERE; a caller-supplied `findingKey` field on the
    event is advisory and never trusted. Dedup has to be a property of the
    fold rather than of whichever emitter happened to run, or the resume
    double-count this ledger exists to prevent comes back through the
    emitter. Task 8 qa-verify recomputes the key the same way, so an emitter
    that derives it differently surfaces there as a missing finding instead
    of being silently absorbed here."""
    src = kstr(e.get("source"))
    if src == "console":
        url_component = nmsg(e.get("message"))
    else:
        capped = kstr(e.get("url"))[:URL_CAP]
        full = url_len(e)
        url_component = capped + "#" + str(full) if full > URL_CAP else capped
    return "|".join([
        kstr(e.get("criterionId")),
        src,
        kstr(e.get("method")),
        url_component,
        kstr(e.get("status")),
    ])


def main():
    payload = json.load(sys.stdin)
    events = sorted(payload.get("events") or [], key=lambda e: e.get("seq") or 0)
    wrapper_skipped = list(payload.get("skipped") or [])

    # ---- Run FSM Enforcement Task 2: statechart data + per-tuple `mutates`.
    # argv[1] (when supplied by fold.sh) is the state-machine.json path;
    # only legalSubStateEdges/guards are read (data-driven -- no edge name
    # is ever hard-coded here). mutates_map is built from EVERY plan_frozen
    # event's criteria[] entries, keyed by tuple_key, last-plan_frozen-wins
    # -- mirroring pass 3's own "process every plan_frozen" behaviour. A
    # tuple with no plan_frozen entry has no key in this map; .get() then
    # yields None ("mutates: unknown"), which the illegal-edge check below
    # treats as "cannot judge -> no anomaly" (graceful default).
    statemachine = {}
    if len(sys.argv) > 1 and sys.argv[1]:
        with open(sys.argv[1]) as f:
            statemachine = json.load(f)
    legal_substate_edges = statemachine.get("legalSubStateEdges") or []
    guards = statemachine.get("guards") or []
    mutates_map = {}
    for e in events:
        if e.get("event") == "plan_frozen":
            for c in (e.get("criteria") or []):
                mutates_map[tuple_key(c)] = c.get("mutates")

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
    # illegal-edge (Task 2): computed ONLY when startedAtVerdict is True -- a
    # tuple with no started event at all is already flagged by
    # verdict-without-started below; the two rules are DELIBERATELY distinct
    # (act-committed-no-intent/verdict-without-started stay exactly as they
    # were) and never double-fire for the same root cause. For a started
    # tuple, the sub-state it was in immediately before its KEPT verdict
    # ("from") is inferred from the SAME order-insensitive act_intent/
    # act_committed presence check act-committed-no-intent already uses (a
    # key seen ANYWHERE in the journal counts, not merely "seen so far") --
    # committed implies "baking", else intent-only implies "acting", else
    # "arranging". The observed transition (`from`, "verdict") is then
    # checked generically against `legal_substate_edges` (not a member at
    # all -> illegal, guard=None) and, if it IS a member, against any
    # LITERAL guard declared for exactly that edge (the wildcard
    # `*->verdict:honesty-gate` guard is NOT re-implemented here -- that
    # gate already lives in checkpoint.sh/required-kinds.sh): `not-mutates`
    # violated when this tuple's plan_frozen `mutates` is True; `mutates`
    # violated when it is not True. When this tuple has no plan_frozen entry
    # at all (mutates_map.get(k) is None), the guard check is skipped --
    # "cannot judge" is not "illegal" (graceful default for a legacy/
    # plan_frozen-less journal, per the Task 2 brief).
    def infer_from_state(scenario_id, criterion_id):
        ak = "{}:{}:{}".format(run_id or "", scenario_id, criterion_id)
        if ak in committed_set:
            return "baking"
        if ak in intent_set:
            return "acting"
        return "arranging"

    def literal_guard(frm, to):
        for g_ in guards:
            edge = g_.get("edge")
            if isinstance(edge, list) and len(edge) == 2 and edge[0] == frm and edge[1] == to:
                return g_.get("requires")
        return None

    criteria = []
    vws = []
    illegal_edges = []
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
        else:
            from_state = infer_from_state(g["scenarioId"], g["criterionId"])
            legal = any(
                isinstance(e, list) and len(e) == 2 and e[0] == from_state and e[1] == "verdict"
                for e in legal_substate_edges
            )
            tuple_label = "{}/{}/{}".format(g["scenarioId"], g["criterionId"], g["personaId"])
            if not legal:
                illegal_edges.append({
                    "rule": "illegal-edge", "tuple": tuple_label,
                    "from": from_state, "to": "verdict", "guard": None,
                })
            else:
                req = literal_guard(from_state, "verdict")
                mutates = mutates_map.get(k)
                if req is not None and mutates is not None:
                    violated = (req == "not-mutates" and mutates is True) or \
                               (req == "mutates" and mutates is not True)
                    if violated:
                        illegal_edges.append({
                            "rule": "illegal-edge", "tuple": tuple_label,
                            "from": from_state, "to": "verdict", "guard": req,
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

    # ---- findings ledger (Task 6): KEYED-SET reduction over
    # finding_observed. Mirrors fold.jq's $findings exactly.
    #
    # This copies the shape of the pass-1 intent_order/intent_set walk above
    # (an order list plus a seen map, skipping a key already present) -- it
    # is DELIBERATELY NOT the last-wins pattern the criterion_verdict groups
    # use, and it deliberately carries NO count/occurrence field: the set IS
    # the answer. A count would re-introduce exactly the resume
    # double-counting this ledger exists to prevent, because a resumed run
    # re-observes and re-appends the findings it already recorded (the
    # journal has no dedup of its own). First-seen order is the `events`
    # order, i.e. ascending `seq`.
    #
    # The projected entry is the event's CONTRACT FIELDS ONLY, each passed
    # through kstr/nmsg. The reserved names (`event`, `seq`, `t`, `childId`,
    # `childSeq`) are never carried -- `seq`/`t` belong to journal.sh, which
    # restamps them on append, and a caller-supplied `seq` must never travel
    # into a derived artifact. `status` is projected in its kstr form (so an
    # HTTP 500 appears as "500") precisely so the field and the key
    # component built from it can never disagree.
    #
    # `capture_probed` is registered in fold.sh but intentionally NOT
    # projected here: Task 7 emits it behind the journal-emptiness
    # once-guard and Task 10 reads its `channel` straight off the journal.
    # Registration alone is what keeps it from being discarded as an
    # `unknown-event`.
    findings_order = []
    findings_seen = {}
    findings_anoms = []
    for e in events:
        if e.get("event") != "finding_observed":
            continue
        k = finding_key(e)
        if k in findings_seen:
            continue
        raw_url = kstr(e.get("url"))
        capped_url = raw_url[:URL_CAP]
        full_len = url_len(e)
        ref = kstr(e.get("detailRef"))
        findings_order.append(k)
        findings_seen[k] = {
            "findingKey": k,
            "criterionId": kstr(e.get("criterionId")),
            "source": kstr(e.get("source")),
            "channel": kstr(e.get("channel")),
            "method": kstr(e.get("method")),
            "url": capped_url,
            "urlLen": full_len,
            "status": kstr(e.get("status")),
            "originClass": kstr(e.get("originClass")),
            "statusClass": kstr(e.get("statusClass")),
            "message": nmsg(e.get("message")),
            "detailRef": ref,
        }
        # finding-url-oversize: the EVENT ITSELF carried a url longer than
        # URL_CAP, i.e. the emitter did not cap it, i.e. that journal line
        # was already at risk of a torn append before this fold ran. The
        # fold cannot un-write it, so it reports the contract breach rather
        # than silently absorbing it -- a truncation the ledger performed
        # quietly would leave the run looking clean while its record was
        # damaged.
        if len(raw_url) > URL_CAP:
            findings_anoms.append({
                "rule": "finding-url-oversize", "findingKey": k, "urlLen": full_len,
            })
        # finding-detail-missing: the url was truncated, so the untruncated
        # form exists ONLY in the detail file -- an empty detailRef means it
        # is unrecoverable from the run record.
        if full_len > URL_CAP and ref == "":
            findings_anoms.append({"rule": "finding-detail-missing", "findingKey": k})
    findings = [findings_seen[k] for k in findings_order]

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
    # cursor subState (Task 2): looked up against pass 2's `groups` -- which
    # (unlike pass 3's cur_groups) only ever gets an entry from a REAL
    # criterion_started/criterion_verdict event, never a plan_frozen
    # listing -- so "not present in groups" precisely means "planned only,
    # never actually started" -> pending, matching the inference table
    # exactly. When present, the same order-insensitive act_intent/
    # act_committed presence check the illegal-edge rule above uses picks
    # acting/baking; g2["started"] False with no verdict falls back to
    # "pending" too (defensive; a group is only ever created with
    # started=True or a non-None verdict, so this branch is unreachable in
    # practice, never a crash risk).
    cursor_ptr = None
    for k in cur_order:
        g = cur_groups[k]
        if g["started"] and not g["verdict"]:
            g2 = groups.get(k)
            if g2 is None:
                substate = "pending"
            elif g2["verdict"] is not None:
                substate = "verdict"
            else:
                ak2 = "{}:{}:{}".format(run_id or "", g2["scenarioId"], g2["criterionId"])
                if ak2 in committed_set:
                    substate = "baking"
                elif ak2 in intent_set:
                    substate = "acting"
                elif g2["started"]:
                    substate = "arranging"
                else:
                    substate = "pending"
            cursor_ptr = {
                "scenarioId": "__shared__" if g["personaId"] == "" else g["scenarioId"],
                "criterionId": g["criterionId"],
                "subState": substate,
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
            "findings": findings,
        },
        "anomalies": wrapper_skipped + anomalies + vws + illegal_edges + seq_gap_anoms + cross_child_anoms + findings_anoms,
        "openActs": open_acts,
        "cursor": cursor_doc,
    }
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
