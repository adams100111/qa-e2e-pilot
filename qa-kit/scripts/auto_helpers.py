# auto_helpers.py — the python3 side of auto.sh (the unattended journey's state machine).
#
# auto.sh runs this file, one process per engine call, when the engine is python3:
#     python3 auto_helpers.py <op> <arguments…>
# It lives in a file of its own because starting python with a long `-c` program costs far more
# than starting it on a file. It is not a command of its own: every op is the python twin of a jq
# program in auto.sh, kept alike line for line, and both must print the same bytes.
#
# Rules that hold for every op:
#   - values arrive as arguments or as files, never as program text;
#   - output is UTF-8, keys sorted, numbers normalised, so it matches `jq -S` byte for byte;
#   - nothing is written to disk here: auto.sh writes what an op prints (atomically);
#   - exit 0 with output, or exit 1 (unreadable input) / 2 (unknown op) with none.
import json
import re
import sys

op, a = sys.argv[1], sys.argv[2:]

# A number is PLAIN when both engines print and compare it alike: finite, and either whole with at
# most 15 digits before the point, or not whole and at least 0.0001 in size. Everything else (1e16,
# an integer above 10^15, 1e-7, NaN, Infinity) is ODD and is never compared: `start` refuses it and
# the audit reports the value that holds it as changed. Plain numbers are compared as IEEE doubles,
# so 0.2 and 0.2000000000000000001 are the same number in both engines.
WHOLE_MAX = 10 ** 15
FRAC_MIN = 0.0001


def needs_person(r):
    # a decision a person still has to look at (the jq side is JQ_NEEDS)
    return r.get("needsPerson") is True or r.get("second") == "ask" or (r.get("confidence") == "low" and r.get("second") != "stands")


def plain(v):
    if isinstance(v, int):
        return abs(v) <= WHOLE_MAX
    if v != v or v in (float("inf"), float("-inf")):
        return False
    if v.is_integer():
        return abs(v) <= WHOLE_MAX
    return abs(v) >= FRAC_MIN


def odd(v):
    # true when the value holds a number that is not plain
    if isinstance(v, bool):
        return False
    if isinstance(v, (int, float)):
        return not plain(v)
    if isinstance(v, dict):
        return any(odd(x) for x in v.values())
    if isinstance(v, list):
        return any(odd(x) for x in v)
    return False


SURROGATE_ESCAPE = re.compile(r"\\u[dD][89a-fA-F]")


def whole_text(v):
    # A value read from JSON, as jq reads it: half of a surrogate pair written as an escape cannot
    # stand alone. jq refuses the document for a first half with no second half after it
    # (`\ud800`), and reads a second half on its own (`\udc00`) as U+FFFD. Python would keep
    # either as a character that cannot be written out again.
    if isinstance(v, str):
        if any("\ud800" <= c <= "\udbff" for c in v):
            raise ValueError("half a surrogate pair")
        return "".join("\ufffd" if "\udc00" <= c <= "\udfff" else c for c in v)
    if isinstance(v, dict):
        return dict((whole_text(k), whole_text(x)) for k, x in v.items())
    if isinstance(v, list):
        return [whole_text(x) for x in v]
    return v


def loads(t):
    # json.loads, reading surrogate escapes as jq does (whole_text); only a text that holds such
    # an escape is walked
    v = json.loads(t)
    return whole_text(v) if SURROGATE_ESCAPE.search(t) else v


def load(p):
    # utf-8-sig: one leading byte order mark is dropped, as jq drops it
    with open(p, encoding="utf-8-sig") as f:
        return loads(f.read())


def norm(v):
    # whole-valued floats print as integers, as jq prints them
    if isinstance(v, float) and v.is_integer() and abs(v) <= WHOLE_MAX:
        return int(v)
    if isinstance(v, dict):
        return dict((k, norm(x)) for k, x in v.items())
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v


def dumps(v, pretty=False):
    v = norm(v)
    if pretty:
        s = json.dumps(v, sort_keys=True, indent=2, ensure_ascii=False)
    else:
        s = json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    # jq writes U+007F as an escape; a raw one can only be inside a string, so this is safe
    return s.replace("\x7f", "\\u007f")


def out(text):
    sys.stdout.buffer.write((text + "\n").encode("utf-8"))


def emit(v, pretty=False):
    out(dumps(v, pretty))


def jstr(v):
    return json.dumps(v, ensure_ascii=False).replace("\x7f", "\\u007f")


def one_line(v):
    return v.replace("\r", " ").replace("\n", " ") if isinstance(v, str) else ""


def rd(state, path, empty_ok=False):
    # (readable, value) of one JSON document; state is 1 (a file), 0 (absent) or ! (not readable)
    if state != "1":
        return False, None
    try:
        with open(path, "rb") as f:
            t = f.read().decode("utf-8")
        if t.startswith("\ufeff"):
            t = t[1:]
        if t.strip(" \t\r\n") == "":
            return (True, []) if empty_ok else (False, None)
        return True, loads(t)
    except Exception:
        return False, None


def same(x, y):
    # equality as jq has it after `norm`: no bool/number mixing, numbers as doubles, objects by content
    if isinstance(x, bool) or isinstance(y, bool):
        return isinstance(x, bool) and isinstance(y, bool) and x == y
    if isinstance(x, (int, float)) and isinstance(y, (int, float)):
        try:
            return float(x) == float(y)
        except OverflowError:
            return False
    if isinstance(x, dict) and isinstance(y, dict):
        return x.keys() == y.keys() and all(same(x[k], y[k]) for k in x)
    if isinstance(x, list) and isinstance(y, list):
        return len(x) == len(y) and all(same(p, q) for p, q in zip(x, y))
    return type(x) == type(y) and x == y


def walk(d, path):
    if path == "":
        return True, d
    for k in path.split("."):
        if not isinstance(d, dict) or k not in d:
            return False, None
        d = d[k]
    return True, d


def strs(v):
    return set(x for x in v if isinstance(x, str)) if isinstance(v, list) else None


def low(v):
    # ASCII capitals made small, as jq's ascii_downcase
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in v) if isinstance(v, str) else ""


def rows_in():
    # the array on stdin; nothing at all (no file yet) is an empty array
    t = sys.stdin.buffer.read().decode("utf-8-sig")
    rows = loads(t) if t.strip(" \t\r\n") else []
    if not isinstance(rows, list):
        sys.exit(1)
    return rows


def next_id(rows, prefix):
    n = 0
    for r in rows:
        i = r.get("id") if isinstance(r, dict) else None
        if isinstance(i, str) and re.fullmatch(prefix + "[0-9]+", i):
            n = max(n, int(i[1:]))
    return prefix + str(n + 1)


def rows_out(line, rows):
    # the result line, then the whole document as it goes back to the file
    out(line)
    emit(rows, pretty=True)


def plan_rows(rows):
    # the rows of a plan that have a string id
    return [r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict) and isinstance(r.get("id"), str)]


def human_expect(r):
    # the row's fixture.expect when a person confirmed it, else None
    fx = r.get("fixture")
    ex = fx.get("expect") if isinstance(fx, dict) else None
    return ex if isinstance(ex, dict) and ex.get("oracleSource") == "human" else None


def plan_ids(rows):
    # (ids of the rows whose expected value a person confirmed, every row id) of a plan
    human, every = set(), set()
    for r in plan_rows(rows):
        every.add(r["id"])
        if human_expect(r) is not None:
            human.add(r["id"])
    return human, every


def plan_hashes(rows):
    # ({id: SHA-256 of the canonical JSON of fixture.expect}, ids whose expect holds an odd number)
    # for the person-confirmed rows; of two such rows with one id the first counts
    import hashlib
    hashes, odd_ids = {}, set()
    for r in plan_rows(rows):
        ex = human_expect(r)
        if ex is not None and r["id"] not in hashes:
            hashes[r["id"]] = hashlib.sha256(dumps(ex).encode("utf-8")).hexdigest()
            if odd(ex):
                odd_ids.add(r["id"])
    return hashes, odd_ids


def merged_config(c, r):
    # the project config with each top-level key of the run-config replacing the config's key of
    # the same name (the rule of scripts/profile.sh); a config that is not an object reads as empty
    d = dict(c) if isinstance(c, dict) else {}
    d.update(r)
    return d


def needs_count(ds, df):
    # decisions that need a person; 0 without the file; None when it is not one JSON array
    if ds == "0":
        return 0
    ok, rows = rd(ds, df, True)
    if not ok or not isinstance(rows, list):
        return None
    return len([r for r in rows if isinstance(r, dict) and needs_person(r)])


def add_hours(now, hours):
    import calendar
    import math
    import time
    t = calendar.timegm(time.strptime(now, "%Y-%m-%dT%H:%M:%SZ")) + math.floor(float(hours) * 3600)
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def op_gate():
    # What the gate needs, from the MERGED config. Arguments: config, state and path of the
    # run-config, now, hours, target. Lines: ok | config-bad | rc-bad | rc-shape; then how `environment` is
    # given (absent, string, other), environment, baseUrl, seedableEnvMarker, the run-config's
    # profile, the config's profile (text, empty when not text), the data policy (enforce, other,
    # unset, bad), the deadline, the target as JSON.
    cf, rs, rf, now, hours, target = a[:6]
    okc, c = rd("1", cf)
    okr, r = (True, {}) if rs == "0" else rd(rs, rf)
    if not okc:
        out("config-bad")
        return
    if not okr:
        out("rc-bad")
        return
    if not isinstance(r, dict):
        out("rc-shape")
        return
    cfg = c if isinstance(c, dict) else {}
    d = merged_config(cfg, r)
    kind = "absent" if "environment" not in d else ("string" if isinstance(d["environment"], str) else "other")
    b = d.get("baseUrl")
    g = d.get("gates")
    if isinstance(g, dict):
        dp = ("enforce" if g["dataPolicy"] == "enforce" else "other") if "dataPolicy" in g else "unset"
    else:
        dp = "unset" if g is None else "bad"
    out("\n".join(["ok", kind, one_line(d.get("environment")), one_line(b), one_line(d.get("seedableEnvMarker")),
                   one_line(r.get("profile")), one_line(cfg.get("profile")), dp, add_hours(now, hours), jstr(target)]))


def op_baseline():
    # The baseline `start` writes. Arguments: config; state and path of the run-config, the plan
    # and the exclusions; the safety keys; the watched run-config keys; target, now, profile,
    # true|false (seed.json exists), the hash of the known-defect registry (empty when absent).
    # Prints one status line and, after `ok`, the baseline pretty-printed.
    cf, rs, rf, ps, pf, es, ef, keys, rckeys, target, now, profile, seed, kd = a[:14]
    okc, c = rd("1", cf)
    okr, r = (True, {}) if rs == "0" else rd(rs, rf)
    okp, p = (True, None) if ps == "0" else rd(ps, pf)
    oke, e = (True, []) if es == "0" else rd(es, ef)
    if not okc:
        out("config-bad")
    elif not okr:
        out("rc-bad")
    elif not isinstance(r, dict):
        out("rc-shape")
    elif not okp:
        out("plan-bad")
    elif ps != "0" and not isinstance(p, list):
        out("plan-shape")
    elif not oke:
        out("excl-bad")
    else:
        d = merged_config(c, r)
        saf = {}
        for k in keys.split(" "):
            found, v = walk(d, k)
            if found:
                saf[k] = v
        rc = dict((k, r[k]) for k in rckeys.split(" ") if k in r)
        human, every = plan_ids(p)
        hashes, odd_ids = plan_hashes(p)
        if odd(saf) or odd(rc):
            out("odd-safety")
        elif odd_ids:
            out("odd-plan")
        elif odd(e):
            out("odd-excl")
        else:
            b = d.get("baseUrl")
            rows_out("ok", {"version": 1, "target": target, "takenAt": now, "profile": profile,
                            "baseUrl": b if isinstance(b, str) else None, "safety": saf, "runConfig": rc,
                            "humanOracleIds": sorted(human), "humanOracleHashes": hashes,
                            "planRowIds": None if ps == "0" else sorted(every), "seedExists": seed == "true",
                            "exclusions": e, "knownDefectsHash": kd if kd else None})


def stop_line(st):
    # the `next` line of a stopped journey
    return dumps({"detail": st.get("detail"), "next": "stopped", "reason": st.get("reason")})


def status_line(d, ds, df):
    # the journey plus needsPerson (0 for decisions that cannot be read)
    line = dict(d)
    line["needsPerson"] = needs_count(ds, df) or 0
    return dumps(line)


def journey_of(path):
    ok, d = rd("1", path)
    return d if ok and isinstance(d, dict) else None


def change(d, p, text, mode):
    # the journey with a change applied (see journey_apply in auto.sh)
    d.update(p.get("set") or {})
    if p.get("stop"):
        d["stop"] = {"reason": p["stop"], "detail": text}
    if p.get("runId"):
        d["runId"] = text
    if "steps" in p or mode == "new":
        if not isinstance(d.get("steps"), list):
            sys.exit(1)
        for x in d["steps"]:
            u = (p.get("steps") or {}).get(x.get("name")) if isinstance(x, dict) else None
            if u:
                if u.get("state"):
                    x["state"] = u["state"]
                if u.get("bump"):
                    x["attempts"] = (x.get("attempts") or 0) + 1
    for k, v in (p.get("append") or {}).items():
        d[k] = (d[k] if isinstance(d.get(k), list) else []) + [v]
    return d


def steps_of(j):
    return [x for x in (j.get("steps") if isinstance(j.get("steps"), list) else []) if isinstance(x, dict)]


def step_state(j, name):
    for x in steps_of(j):
        if one_line(x.get("name")) == name:
            return one_line(x.get("state"))
    return ""


def first_open(j, order):
    # the first step, in order, that is not done; empty when all are
    for name in order:
        if step_state(j, name) != "done":
            return name
    return ""


def limit(j, order, step, now, late):
    # None, or the journey stopped for `--until` (the step comes after it) or, with `late`, for the
    # time limit (now is later than the deadline). The asked-for stop comes first.
    until, deadline = one_line(j.get("until")), one_line(j.get("deadline"))
    if until in order and order.index(step) > order.index(until):
        j.update({"state": "stopped", "endedAt": now, "stop": {"reason": "until", "detail": "stopped after " + until + ", as asked"}})
        return j
    if late and now > deadline:
        j.update({"state": "stopped", "endedAt": now, "stop": {"reason": "time-limit", "detail": "the deadline " + deadline + " has passed"}})
        return j
    return None


def op_apply():
    # Change the journey: journey path, `new` (start: there is no journey yet) or `old`, the
    # change as JSON, a text, state and path of decisions.json. Prints the result line (the status
    # line, or with "print": "stop" the stop line), then the journey. `!notopen` alone when the
    # journey is not in the state the change requires.
    jf, mode, patch, text, ds, df = a[:6]
    p = json.loads(patch)
    d = {} if mode == "new" else journey_of(jf)
    if d is None:
        if p.get("require"):
            out("!notopen")
            return
        sys.exit(1)
    if p.get("require") and d.get("state") != p["require"]:
        out("!notopen")
        return
    d = change(d, p, text, mode)
    rows_out(stop_line(d["stop"]) if p.get("print") == "stop" else status_line(d, ds, df), d)


def op_step():
    # `step-start` and `step-done` in one pass: journey, state and path of decisions.json, start|done,
    # the step, the step order, now, the refusal the shell found for the step's result (empty: none),
    # 1|0 the analysis is BLOCKED, 1|0 record the run id, the run id. First line: `!notopen`,
    # `!unreadable`, `!done`, `!next <step>`, `!refuse` (nothing written); or `!stopped <stop line>`
    # and the journey (a limit was reached); or the status line and the journey.
    jf, ds, df, kind, step, order, now, refuse, blocked, runid, text = a[:11]
    order = order.split(" ")
    j = journey_of(jf)
    if j is None or j.get("state") != "open":
        out("!notopen")
    elif not steps_of(j):
        out("!unreadable")
    elif step_state(j, step) == "done":
        out("!done")
    elif first_open(j, order) != step:
        out("!next " + first_open(j, order))
    else:
        stopped = limit(j, order, step, now, kind == "start" or step_state(j, step) != "running")
        if stopped is not None:
            rows_out("!stopped " + stop_line(stopped["stop"]), stopped)
        elif refuse != "":
            out("!refuse")
        elif kind == "start":
            j = change(j, {"set": {"stepsChangedAt": now}, "steps": {step: {"state": "running", "bump": True}}}, "", "old")
            rows_out(status_line(j, ds, df), j)
        elif blocked == "1":
            r = j.get("analyzeRounds")
            import math
            rounds = (math.floor(r) if isinstance(r, (int, float)) and not isinstance(r, bool) and r >= 0 else 0) + 1
            if rounds >= 2:
                # still BLOCKED after the second round: the journey stops; a person has to act
                j = change(j, {"set": {"stepsChangedAt": now, "analyzeRounds": rounds, "state": "stopped", "endedAt": now,
                                       "stop": {"reason": "blocked", "detail": "the analysis is still BLOCKED after %d rounds" % rounds}},
                               "steps": {"analyze": {"state": "done"}}}, "", "old")
            else:
                j = change(j, {"set": {"stepsChangedAt": now, "analyzeRounds": rounds},
                               "steps": {"scenarios": {"state": "pending"}, "analyze": {"state": "pending"}}}, "", "old")
            rows_out(status_line(j, ds, df), j)
        else:
            j = change(j, {"set": {"stepsChangedAt": now}, "runId": runid == "1", "steps": {step: {"state": "done"}}}, text, "old")
            rows_out(status_line(j, ds, df), j)


def op_next():
    # `next` in one pass: journey, the step order, now. First line: the `next` line; then the
    # journey when this call changed it (all steps done, or a limit reached). `!unreadable` alone
    # for a journey that cannot be walked.
    jf, order, now = a[:3]
    order = order.split(" ")
    j = journey_of(jf)
    if j is None or one_line(j.get("state")) == "":
        sys.exit(1)
    st = j.get("stop")
    if j["state"] == "stopped":
        out(stop_line(st) if isinstance(st, dict) and "detail" in st and isinstance(st.get("reason"), str) else "!unreadable")
    elif j["state"] == "done":
        out("{\"next\":\"done\"}")
    elif j["state"] != "open" or not steps_of(j):
        out("!unreadable")
    else:
        step = first_open(j, order)
        if step == "":
            # nothing is left to do, so a passed deadline no longer matters
            j.update({"state": "done", "endedAt": now})
            rows_out("{\"next\":\"done\"}", j)
        else:
            stopped = limit(j, order, step, now, True)
            if stopped is not None:
                rows_out(stop_line(stopped["stop"]), stopped)
            else:
                out("{\"next\":\"%s\"}" % step)


def journey_open(js, jf):
    # None when the journey is open, else the marker to print: !nojourney or !notopen
    ok, d = rd(js, jf)
    state = d.get("state") if ok and isinstance(d, dict) and isinstance(d.get("state"), str) else ""
    if state == "":
        return "!nojourney"
    return None if state == "open" else "!notopen"


def op_status():
    # journey, state and path of decisions.json -> the status line, or `!decisions`
    ok, d = rd("1", a[0])
    if not ok or not isinstance(d, dict) or not isinstance(d.get("state"), str) or d["state"] == "":
        sys.exit(1)
    n = needs_count(a[1], a[2])
    if n is None:
        out("!decisions")
    else:
        d["needsPerson"] = n
        emit(d)


def op_journey():
    # what the verbs that look at a run need from the journey: its state, run id and start time,
    # then the steps as `name:state:attempts` words
    import math
    d = load(a[0])
    if not isinstance(d, dict):
        sys.exit(1)

    def n(v):
        return math.floor(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0
    s = one_line
    out("\n".join([s(d.get("state")), s(d.get("runId")), s(d.get("startedAt")),
                   " ".join("%s:%s:%d" % (s(x.get("name")), s(x.get("state")), n(x.get("attempts"))) for x in steps_of(d))]))


def checkpoint_rows(doc):
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict) and isinstance(doc.get("criteria"), list):
        return doc["criteria"]
    return []


def cid(r):
    for k in ("criterion_id", "criterionId", "id"):
        if isinstance(r.get(k), str) and r[k] != "":
            return r[k]
    return None


def has_rows(v):
    # a verification.json that holds a result: the rows the handoff reads (the document itself when
    # it is a list, else the list under `rows` or `criteria`), at least one, every one an object
    rows = None
    if isinstance(v, list):
        rows = v
    elif isinstance(v, dict):
        for k in ("rows", "criteria"):
            if isinstance(v.get(k), list):
                rows = v[k]
                break
    return isinstance(rows, list) and len(rows) > 0 and all(isinstance(r, dict) for r in rows)


def op_verified():
    # exit 0 when the file is one JSON document that holds a verification result
    ok, v = rd("1", a[0])
    if not ok or not has_rows(v):
        sys.exit(1)


def op_runfacts():
    # What `step-done run` needs from a run: manifest, checkpoint, state and path of the plan.
    # Lines: ok|bad (the manifest parses), `=` and its status in small letters (an empty line when
    # the status is not text), its started_at, ok|bad (the
    # checkpoint parses), 1|0 (a checkpoint row is about a row of this plan), then every
    # checkpointed_at.
    okm, m = rd("1", a[0])
    okk, k = rd("1", a[1])
    okp, p = rd(a[2], a[3])
    rows = [r for r in (checkpoint_rows(k) if okk else []) if isinstance(r, dict)]
    ids = plan_ids(p)[1] if okp else set()
    m = m if isinstance(m, dict) else {}
    st = m.get("status")
    lines = ["ok" if okm else "bad", "=" + one_line(low(st)) if isinstance(st, str) else "", one_line(m.get("started_at")), "ok" if okk else "bad",
             "1" if any(cid(r) in ids for r in rows if cid(r) is not None) else "0"]
    lines += [one_line(r["checkpointed_at"]) for r in rows if isinstance(r.get("checkpointed_at"), str)]
    out("\n".join(lines))


def op_audit():
    # The file checks of `audit`, in one pass. Arguments: journey, then a state (1 there, 0 absent,
    # ! there but not a readable file) and a path for each of baseline, config, run-config, plan,
    # exclusions, decisions and the run's verification.json, then: the hash of the baseline now,
    # the hash of the known-defect registry now (empty when absent), 1|0 seed.json exists, 1|0 the
    # journey needs a verification, now, the safety keys, the watched run-config keys, the
    # decidable classes, and the codes the shell already found (space lists).
    # Prints the result line, then the new journey.json (not when an audit that had already failed
    # finds the same codes again).
    (jf, bs, bf, cs, cf, rs, rf, ps, pf, es, ef, ds, df, vs, vf,
     bhash, kdhash, seed, needv, now, keys, rckeys, classes, extra) = a[:24]
    keys = keys.split(" ")
    rckeys = rckeys.split(" ")
    classes = classes.split(" ")
    ok, j = rd("1", jf)
    if not ok or not isinstance(j, dict):
        sys.exit(1)
    codes = set(x for x in extra.split(" ") if x)
    if bs == "0":
        codes.add("baseline-missing")
    else:
        ok, b = rd(bs, bf)
        ok = ok and isinstance(b, dict)
        if not ok or j.get("baselineHash") != bhash:
            codes.add("baseline-changed")
        if ok:
            okc, c = rd(cs, cf)
            okr0, r0 = (True, {}) if rs == "0" else rd(rs, rf)
            okr, r = (okr0, r0) if okr0 and isinstance(r0, dict) else (False, {})
            bsaf = b.get("safety") if isinstance(b.get("safety"), dict) else None
            # a baseline that carries `runConfig` recorded the MERGED settings; an earlier one
            # recorded the project config alone and is compared the earlier way
            new = "runConfig" in b
            brc = b.get("runConfig") if isinstance(b.get("runConfig"), dict) else None
            launch = b.get("profile") if isinstance(b.get("profile"), str) else None
            if new:
                okm, m = okc and okr, merged_config(c, r)
            else:
                okm, m = okc, c
            # the address the journey runs against (only a baseline that recorded it)
            if "baseUrl" in b:
                found, v = walk(m, "baseUrl")
                if not okm or not same(v if isinstance(v, str) else None, b["baseUrl"]):
                    codes.add("base-url-changed")
            # the safety settings
            for k in keys:
                found, v = walk(m, k)
                if not okm or bsaf is None:
                    bad = True
                elif new:
                    if k == "profile" and found and launch is not None and same(v, launch):
                        bad = False
                    else:
                        bad = found != (k in bsaf) or (found and (odd(v) or not same(v, bsaf[k])))
                else:
                    bad = k not in bsaf or not same(v if found else None, bsaf[k])
                if bad:
                    codes.add("safety-setting-changed:" + k)
            # the run-config of the spec
            if new:
                for k in rckeys:
                    found = k in r
                    v = r.get(k)
                    if not okr or brc is None:
                        bad = True
                    elif k == "profile" and found and launch is not None and same(v, launch):
                        bad = False
                    else:
                        bad = found != (k in brc) or (found and (odd(v) or not same(v, brc[k])))
                    if bad:
                        codes.add("run-config-safety:" + k)
            else:
                old = b.get("runConfigSafety") if isinstance(b.get("runConfigSafety"), dict) else None
                for k in keys:
                    found, v = walk(r0, k)
                    if not okr0 or old is None:
                        codes.add("run-config-safety:" + k)
                    elif k == "profile" and found and launch is not None and same(v, launch):
                        pass
                    elif found != (k in old) or (found and not same(v, old[k])):
                        codes.add("run-config-safety:" + k)
            # the known-defect registry, by its bytes
            if not same(kdhash if kdhash else None, b.get("knownDefectsHash")):
                codes.add("known-defects-changed")
            # the plan
            okp, rows = (True, []) if ps == "0" else rd(ps, pf)
            if not okp or not isinstance(rows, list):
                codes.add("plan-unreadable")
            else:
                bh = strs(b.get("humanOracleIds")) or set()
                br = strs(b.get("planRowIds"))
                ch, cr = plan_ids(rows)
                gone = (br - cr) if br is not None else set()
                codes.update("human-oracle-added:" + i for i in ch - bh)
                codes.update("plan-row-removed:" + i for i in gone)
                codes.update("human-oracle-removed:" + i for i in bh - ch - gone)
                bhh = b.get("humanOracleHashes") if isinstance(b.get("humanOracleHashes"), dict) else None
                if bhh is not None:
                    hh, odd_ids = plan_hashes(rows)
                    codes.update("human-oracle-changed:" + i for i in ch & bh
                                 if i in bhh and (i in odd_ids or not same(bhh[i], hh.get(i))))
            if seed == "1" and b.get("seedExists") is not True:
                codes.add("seed-added")
            if es != "0":
                oke, cur = rd(es, ef)
                base = b.get("exclusions")
                if not oke:
                    codes.add("exclusion-added")
                elif isinstance(base, list) and isinstance(cur, list):
                    if any(odd(x) or not any(same(x, y) for y in base) for x in cur):
                        codes.add("exclusion-added")
                elif odd(cur) or not same(cur, base):
                    codes.add("exclusion-added")
    if ds != "0":
        okd, rows = rd(ds, df, empty_ok=True)
        if not okd or not isinstance(rows, list):
            codes.add("decisions-unreadable")
        else:
            for n, r in enumerate(rows):
                if isinstance(r, dict) and not (isinstance(r.get("class"), str) and r["class"] in classes):
                    i = r.get("id")
                    codes.add("forbidden-decision:" + (i if isinstance(i, str) else "#%d" % (n + 1)))
    # a journey that is done, or whose verify step is, needs a verification that holds a result
    if needv == "1":
        okv, ver = rd(vs, vf)
        if not okv or not has_rows(ver):
            codes.add("not-verified")
    st = j.get("stop")
    failed = j.get("state") == "stopped" and isinstance(st, dict) and st.get("reason") == "audit"
    if failed:
        codes.update(strs(j.get("auditViolations")) or set())
    allc = sorted(codes)
    bad = failed or len(allc) > 0
    line = "{\"ok\":%s,\"violations\":%s}" % ("false" if bad else "true", json.dumps(allc, separators=(",", ":"), ensure_ascii=False).replace("\x7f", "\\u007f"))
    if not bad:
        j["audit"] = {"ok": True, "at": now}
        rows_out(line, j)
    elif failed and j.get("auditViolations") == allc:
        out(line)
    else:
        if not failed:
            j.update({"state": "stopped", "endedAt": now, "stopBeforeAudit": st})
        j.update({"stop": {"reason": "audit", "detail": ", ".join(allc)}, "auditViolations": allc, "audit": {"ok": False, "at": now}})
        rows_out(line, j)


def op_behind():
    # tracker output on stdin -> ok | behind | none. A JSON line with `behind` decides: ok when
    # every such value is false. Without one, ok only for a single JSON object with "setUp": false.
    lines = sys.stdin.buffer.read().decode("utf-8", "replace").split("\n")
    objs = []
    for line in lines:
        try:
            v = json.loads(line)
        except Exception:
            continue
        if isinstance(v, dict):
            objs.append(v)
    seen = [v["behind"] for v in objs if "behind" in v]
    if seen:
        out("ok" if all(x is False for x in seen) else "behind")
    elif len([x for x in lines if x.strip(" \t\r") != ""]) == 1 and len(objs) == 1 and objs[0].get("setUp") is False:
        out("ok")
    else:
        out("none")


def persona_lines(d):
    # the lines signin_from reads: auth.storageState, then `<id as JSON><tab><auth text>` per persona
    def s(v):
        return one_line(v).replace("\t", " ")
    au = d.get("auth")
    lines = [s(au.get("storageState")) if isinstance(au, dict) else ""]
    for x in (d.get("personas") if isinstance(d.get("personas"), list) else []):
        if isinstance(x, dict) and isinstance(x.get("id"), str):
            lines.append(jstr(x["id"]) + "\t" + s(x.get("auth")))
    return lines


def op_personas():
    # `signin`: state and path of the journey, state and path of the config. `!nojourney` or
    # `!notopen` for a journey that is not open, `!noconfig` without a config, else the lines
    # signin_from reads.
    marker = journey_open(a[0], a[1])
    if marker:
        out(marker)
        return
    if a[2] == "0":
        out("!noconfig")
        return
    ok, d = rd(a[2], a[3])
    if not ok or not isinstance(d, dict):
        sys.exit(1)
    out("\n".join(persona_lines(d)))


def rows_op():
    # The rows verbs take the state and path of the journey first and need it open: prints the
    # marker and answers False when it is not; else drops the two arguments and answers True.
    marker = journey_open(a[0], a[1])
    if marker:
        out(marker)
        return False
    del a[:2]
    return True


def op_decide():
    # (journey) step class question answer evidence no-evidence(1|0) confidence criteria
    if not rows_op():
        return
    rows = rows_in()
    i = next_id(rows, "D")
    none = a[5] == "1"
    rows.append({"id": i, "step": a[0], "class": a[1], "question": a[2], "answer": a[3],
                 "evidence": None if none else a[4], "confidence": a[6],
                 "criteria": [c.strip(" \t\r\n") for c in a[7].split(",") if c.strip(" \t\r\n")],
                 "assumption": True, "needsPerson": none, "second": None, "secondReason": None})
    rows_out(i, rows)


def op_note():
    # (journey) kind text at
    if not rows_op():
        return
    rows = rows_in()
    i = next_id(rows, "N")
    rows.append({"id": i, "kind": a[0], "text": a[1], "at": a[2]})
    rows_out(i, rows)


def op_second():
    # (journey) id verdict reason
    ok, j = rd(a[0], a[1])
    if not rows_op():
        return
    rows = rows_in()
    if a[1] == "stands" and j.get("secondLook") == "unavailable":
        out("!unavailable")
        return
    r = None
    for x in rows:
        if isinstance(x, dict) and x.get("id") == a[0]:
            r = x
            break
    if r is None:
        out("!missing")
        return
    if r.get("second") is None or (r.get("second") == "stands" and a[1] == "ask"):
        r["second"] = a[1]
        r["secondReason"] = a[2]
        if a[1] == "ask":
            r["needsPerson"] = True
    rows_out("{\"id\":%s,\"needsPerson\":%s,\"second\":%s}" % (jstr(r.get("id")), jstr(r.get("needsPerson")), jstr(r.get("second"))), rows)


def op_unavailable():
    # (journey)
    if not rows_op():
        return
    rows = rows_in()
    ids = []
    for x in rows:
        if isinstance(x, dict) and x.get("confidence") == "low" and x.get("second") is None:
            if x.get("needsPerson") is not True:
                ids.append(x.get("id"))
            x["needsPerson"] = True
    rows_out("{\"marked\":[%s]}" % ",".join(jstr(i) for i in ids), rows)


def op_head():
    # What cmd_handoff needs first: journey, the state of the config (1 there), the config. Lines:
    # the journey state, its stop reason, its launch profile, its run id, the stop it had before a
    # failed audit, how many times it was resumed, 1|0 it replaced an earlier journey, its audit
    # (1 passed, 2 failed, 0 none: no record or older than the last change to its steps); then 1 or 0 (the project
    # config is one JSON object); then, after a 1, the lines signin_from reads.
    s = one_line
    j = load(a[0])
    if not isinstance(j, dict):
        sys.exit(1)
    st = j.get("stop") if isinstance(j.get("stop"), dict) else {}
    sb = j.get("stopBeforeAudit") if isinstance(j.get("stopBeforeAudit"), dict) else {}
    au = j.get("audit")
    fresh = (isinstance(au, dict) and isinstance(au.get("at"), str)
             and (not isinstance(j.get("stepsChangedAt"), str) or au["at"] >= j["stepsChangedAt"]))
    audited = ("1" if au.get("ok") is True else "2" if au.get("ok") is False else "0") if fresh else "0"
    lines = [s(j.get("state")), s(st.get("reason")), s(j.get("profile")), s(j.get("runId")), s(sb.get("reason")),
             str(len(j["resumes"]) if isinstance(j.get("resumes"), list) else 0),
             "1" if j.get("replacedFrom") is not None else "0", audited]
    c = None
    if a[1] == "1":
        try:
            c = load(a[2])
        except Exception:
            c = None
    if not isinstance(c, dict):
        lines.append("0")
    else:
        lines.append("1")
        lines += persona_lines(c)
    out("\n".join(lines))


def op_facts():
    # What `handoff` writes its list from: one fact per line, fields split by U+001F, every text
    # on one line (clean). Arguments: journey, then a state (1 there, 0 absent, ! there but not a
    # readable file) and a path for each of decisions, notes, the plan, the cards file, the
    # checkpoint and the verification of the run, the records file and the journeys of the run,
    # then the sign-in line. The jq side is JQ_HANDOFF; the two are kept alike.
    jf = a[0]
    ds, df, ns, nf, ps, pf, cs, cf, ks, kf, vs, vf, rs, rf, ys, yf, signin = a[1:18]
    lines = []

    def put(*f):
        lines.append("\x1f".join(f))

    def clean(v):
        # one line of text: control characters are blanks, runs of blanks are one, none at the ends
        if not isinstance(v, str):
            return ""
        s = "".join(" " if (ord(c) < 32 or 127 <= ord(c) < 160) else ("\ufffd" if 0xD800 <= ord(c) < 0xE000 else c) for c in v)
        return re.sub(" +", " ", s).strip(" ")

    def b(x):
        return "1" if x else "0"

    def rows_of(doc, keys):
        if isinstance(doc, list):
            return doc
        if isinstance(doc, dict):
            for k in keys:
                if isinstance(doc.get(k), list):
                    return doc[k]
        return None

    def who(r):
        return r["persona"] if isinstance(r.get("persona"), str) else ""

    def rtext(v):
        if isinstance(v, str):
            return clean(v)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return json.dumps(norm(v))
        return ""
    ok, j = rd("1", jf)
    if not ok or not isinstance(j, dict):
        sys.exit(1)
    okd, dec = rd(ds, df, True)
    okn, notes = rd(ns, nf, True)
    okp, plan = rd(ps, pf)
    okc, cards = rd(cs, cf)
    okk, cp = rd(ks, kf)
    okv, ver = rd(vs, vf)
    okr, recs = rd(rs, rf, True)
    oky, jour = rd(ys, yf)
    # the plan: of two rows with one id the first counts
    prow = {}
    for r in (plan if okp and isinstance(plan, list) else []):
        if isinstance(r, dict) and isinstance(r.get("id"), str) and r["id"] not in prow:
            prow[r["id"]] = r
    # the title of a check: the cards file, else the row itself, else its id
    titles = {}
    cl = cards.get("cards") if okc and isinstance(cards, dict) else None
    for c in (cl if isinstance(cl, list) else []):
        ch = c.get("checks") if isinstance(c, dict) else None
        for x in (ch if isinstance(ch, list) else []):
            if isinstance(x, dict) and isinstance(x.get("criterion"), str) and clean(x.get("title")) != "" and x["criterion"] not in titles:
                titles[x["criterion"]] = clean(x["title"])

    def title(i):
        if i in titles:
            return titles[i]
        r = prow.get(i)
        t = (clean(r.get("title")) or clean(r.get("label"))) if r is not None else ""
        return t or clean(i)
    # top priority, failing closed: a row of the plan marked P1, a row with no priority, a step of
    # a P1 journey of the run, and any id the plan does not have
    jp1 = set()
    for x in (jour if oky and isinstance(jour, list) else []):
        if isinstance(x, dict) and x.get("priority") == "P1" and isinstance(x.get("steps"), list):
            for s in x["steps"]:
                s = s.get("criterionId") if isinstance(s, dict) else s
                if isinstance(s, str):
                    jp1.add(s)

    def p1(i):
        r = prow.get(i)
        return r is None or not isinstance(r.get("priority"), str) or r["priority"] == "P1" or i in jp1
    dstat = "absent" if ds == "0" else ("ok" if okd and isinstance(dec, list) else "bad")
    decs = [r for r in dec if isinstance(r, dict)] if dstat == "ok" else []
    nstat = "absent" if ns == "0" else ("ok" if okn and isinstance(notes, list) else "bad")
    pstat = "absent" if ps == "0" else ("ok" if okp and isinstance(plan, list) else "bad")
    krows = rows_of(cp, ["criteria"]) if okk else None
    kstat = "absent" if ks == "0" else ("ok" if krows is not None else "bad")
    vrows = rows_of(ver, ["rows", "criteria"]) if okv else None
    # the second check: `override` when a row that is not about a recorded non-pass does not say pass
    if vs == "0":
        vstat = "absent"
    elif vrows is None or any(not isinstance(r, dict) for r in vrows):
        vstat = "bad"
    elif any(low(r.get("inRunVerdict")) not in ("fail", "blocked", "deferred", "error") and low(r.get("verifierVerdict")) != "pass" for r in vrows):
        vstat = "override"
    else:
        vstat = "ok"
    put("S", "decisions", dstat)
    put("S", "notes", nstat)
    put("S", "plan", pstat)
    put("S", "results", kstat)
    put("S", "second", vstat)
    put("J", b(j.get("restartedFrom") is not None), b(j.get("replacedAfterAudit") is True))
    # what the audit found: the code word, and its key, step, check title or question
    av = j.get("auditViolations")
    for code in (av if isinstance(av, list) else []):
        if not isinstance(code, str):
            continue
        parts = code.split(":")
        w, arg = parts[0], ":".join(parts[1:])
        if w in ("human-oracle-added", "human-oracle-removed", "human-oracle-changed", "plan-row-removed"):
            arg = title(arg)
        elif w == "forbidden-decision":
            arg = clean(next((r.get("question") for r in decs if r.get("id") == arg), None))
        else:
            arg = clean(arg)
        put("V", clean(w), arg)
    # decisions: needs a person, and whether a top priority check rests on it (no checks named
    # means the whole spec)
    for r in decs:
        needs = needs_person(r)
        cr = r.get("criteria")
        ids = [c for c in cr if isinstance(c, str)] if isinstance(cr, list) else []
        rests = needs and (len(ids) == 0 or any(p1(c) for c in ids))
        put("D", clean(r.get("step")), clean(r.get("class")), b(needs), b(rests), b(r.get("evidence") is None),
            clean(r.get("question")), clean(r.get("answer")), clean(r.get("evidence")))
    # expected values that are only a proposal: a calculated check, or any check that names a
    # source, whose source is neither a person nor a cited spec line
    oset = set()
    for i, r in prow.items():
        fx = r.get("fixture")
        ex = fx.get("expect") if isinstance(fx, dict) else None
        src = ex.get("oracleSource") if isinstance(ex, dict) else None
        if (r.get("kind") in ("computed-logic", "business-rule") or src is not None) and src not in ("human", "spec"):
            oset.add(i)
            put("O", b(p1(i)), title(i))
    # checks that passed at low confidence: the latest record of each check and role, after the
    # second check; a confidence is never read as better than either file says
    ov = {}
    for r in (vrows or []):
        if isinstance(r, dict) and cid(r) is not None and isinstance(r.get("verifierVerdict"), str):
            ov[(cid(r), who(r))] = r
    latest = {}
    for r in (krows or []):
        if isinstance(r, dict) and cid(r) is not None:
            latest[(cid(r), who(r))] = r
    for (i, persona), r in latest.items():
        verdict = low(r.get("verdict"))
        lowc = r.get("confidence") != "high"
        o = ov.get((i, persona))
        if o is not None and o.get("inRunVerdict") == verdict:
            if o["verifierVerdict"] in ("pass", "fail", "blocked", "deferred", "error"):
                verdict = o["verifierVerdict"]
            if isinstance(o.get("confidence"), str) and o["confidence"] not in ("", "high"):
                lowc = True
        if verdict == "pass" and lowc and i not in oset:
            put("L", b(p1(i)), title(i), clean(persona))
    try:
        si = json.loads(signin)
    except Exception:
        si = None
    ms = si.get("missing") if isinstance(si, dict) else None
    for x in (ms if isinstance(ms, list) else []):
        if isinstance(x, str):
            put("P", clean(x))
    for r in (notes if nstat == "ok" else []):
        if isinstance(r, dict) and clean(r.get("text")) != "":
            put("N", clean(r.get("kind")), clean(r.get("text")))
    for r in (recs if okr and isinstance(recs, list) else []):
        if isinstance(r, dict):
            e, i = rtext(r.get("entity")), rtext(r.get("id"))
            if e != "" or i != "":
                put("R", e, i)
    out("\n".join(lines))


def op_valid():
    load(a[0])


def op_strs():
    d = load(a[0])
    out("\n".join(one_line(walk(d, p)[1]) for p in a[1:]))


OPS = {"valid": op_valid, "verified": op_verified, "strs": op_strs, "gate": op_gate, "baseline": op_baseline,
       "apply": op_apply, "step": op_step, "next": op_next, "status": op_status, "journey": op_journey, "runfacts": op_runfacts, "audit": op_audit,
       "behind": op_behind, "personas": op_personas, "decide": op_decide, "note": op_note, "second": op_second,
       "unavailable": op_unavailable, "head": op_head, "facts": op_facts}

try:
    if op not in OPS:
        sys.exit(2)
    OPS[op]()
except SystemExit:
    raise
except Exception:
    sys.exit(1)
