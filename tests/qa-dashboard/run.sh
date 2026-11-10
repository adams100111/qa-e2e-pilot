#!/usr/bin/env bash
# Tests for scripts/qa-dashboard.sh / qa-dashboard.js — the project-level QA
# state dashboard: running vs stalled vs paused vs complete detection, rate and
# ETA math, verdict tallies identical to render-report.js (supersession), a
# self-contained HTML page (no external URL), .qa/auth never touched (an
# fs-tracing preload fails the run on any access) and no secret in any output,
# terminal output without colour off a TTY or under NO_COLOR, watch mode
# exiting cleanly on Ctrl-C, and Arabic text kept intact.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SH="$ROOT/scripts/qa-dashboard.sh"
JS="$ROOT/scripts/qa-dashboard.js"
RR="$ROOT/scripts/render-report.js"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
has(){ case "$2" in *"$3"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: $1 (expected to contain [$3])"; ;; esac; }
lacks(){ case "$2" in *"$3"*) fail=$((fail+1)); echo "FAIL: $1 (expected NOT to contain [$3])" ;; *) pass=$((pass+1)) ;; esac; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; echo "qa-dashboard: PASS=0 FAIL=0"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: qa-dashboard needs python3 to write fixtures" >&2; exit 1; }
W="$(mktemp -d)"
cleanup(){ chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
P="$W/proj"
NOW="2026-11-09T12:00:00Z"
AR_TITLE="لا يظهر زر حفظ الفريق بعد تعديل اسم الهاكاثون"

# ---------------------------------------------------------------------------
# Fixture project. Times are relative to $NOW; journal mtimes are set below.
# ---------------------------------------------------------------------------
python3 - "$P" "$AR_TITLE" <<'PY'
import json, os, sys
P, AR = sys.argv[1], sys.argv[2]
qa = os.path.join(P, ".qa")
def w(rel, v):
    p = os.path.join(qa, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))
def jl(rel, events):
    w(rel, "".join(json.dumps(dict(e, seq=i + 1), ensure_ascii=False) + "\n" for i, e in enumerate(events)))
w("config.json", {"baseUrl": "https://app.example.test", "environment": "staging", "profile": "ship", "maxParallel": 2,
                  "gates": {"coverage": "block"}, "personas": [{"id": "admin", "password": "PersonaPassw0rd!"}],
                  "enforcement": {"redactedKeys": ["S3cr3tLiteral"]}})
w("constitution.state.json", {"version": "abc123def4567890", "roles": [{"id": "admin", "plane": "global"}, {"id": "user", "plane": "global"}, {"id": "leader", "plane": "contextual"}]})
w("constitution.md", "# QA Constitution\n")
w("known-defects.json", [
  {"id": "KD-1", "title": "Banner shows on load", "ticket": "T-1", "expiry": "2026-12-01", "severity": "medium", "observedClass": "degraded", "surface": "/a", "observedBehaviour": "banner"},
  {"id": "KD-2", "title": "Old crash", "ticket": "T-2", "expiry": "2026-11-01", "severity": "high", "observedClass": "non-rendering", "surface": "/b", "observedBehaviour": "blank"}])
row = lambda i, src=None: dict({"id": i, "surface": "/x", "kind": "computed-logic" if src else "happy-path", "tags": [], "action": "a"},
                               **({"fixture": {"expect": {"oracleSource": src}}} if src else {}))
w("specs/alpha/checklist.json", [row("C1", "human"), row("C2", "spec"), row("C3", "llm-suggested"), row("C4", "llm-suggested"), row("C5")])
w("specs/alpha/journeys.json", [{"id": "J1", "priority": "P1", "steps": ["C1", "C2"]}, {"id": "J2", "priority": "P2", "steps": ["C3"]}])
w("specs/alpha/analysis.md", "# Analysis\n\n## Verdict\n\nAdvisory only — the run is **not** blocked.\n")
w("specs/alpha/spec-roles.json", {"constitutionVersion": "abc123def4567890", "roles": []})
w("specs/beta/checklist.json", [row("B1")])
w("specs/beta/analysis.md", "## Verdict\n\n**BLOCKED** — 2 surface x role pairs uncovered.\n\n## Next\n")
w("specs/beta/spec-roles.json", {"constitutionVersion": "0000000000000000", "roles": []})
w("specs/beta/coverage.json", {"total": 10, "covered": 8, "excluded": 0, "uncovered": 2, "percent": 80})

cp = lambda i, v, at, persona="", conf="high", la="ok": {"criterion_id": i, "persona": persona, "verdict": v, "confidence": conf,
                                                        "checkpointed_at": at, "last_action": la, "evidence_refs": []}
plan = lambda ids: {"event": "plan_frozen", "criteria": [{"criterionId": i} for i in ids], "t": "2026-11-01T09:00:00Z"}
# r0: an older complete alpha run (trend point 1)
w("runs/r0-alpha/run-manifest.json", {"run_id": "r0-alpha", "target_feature": "alpha", "status": "complete", "started_at": "2026-11-01T09:00:00Z", "ended_at": "2026-11-01T10:00:00Z", "criteria_total": 3, "criteria_done": 3})
w("runs/r0-alpha/checkpoint.json", {"run_id": "r0-alpha", "criteria": [cp("C1", "fail", "2026-11-01T09:10:00Z"), cp("C2", "fail", "2026-11-01T09:20:00Z"), cp("C3", "pass", "2026-11-01T09:30:00Z")]})
w("runs/r0-alpha/bug-log.json", [{"bug_id": "B0", "title": "Old bug", "severity": "high", "suspected_layer": "service"}])
jl("runs/r0-alpha/journal.ndjson", [{"event": "run_started", "t": "2026-11-01T09:00:00Z"}, plan(["C1", "C2", "C3"])])
# r1: a complete alpha run with a superseded persona-less row, an Arabic bug title and planted secrets
w("runs/r1-alpha (رمضان)/run-manifest.json", {"run_id": "r1", "target_feature": "alpha (phase two)", "status": "completed", "started_at": "2026-11-05T09:00:00Z", "ended_at": "2026-11-05T11:00:00Z", "criteria_total": 4, "criteria_done": 4})
w("runs/r1-alpha (رمضان)/checkpoint.json", {"run_id": "r1", "criteria": [
  cp("C1", "pass", "2026-11-05T09:10:00Z"), cp("C2", "fail", "2026-11-05T09:20:00Z", la="token=abc.def.ghi leaked"),
  cp("C2", "pass", "2026-11-05T10:20:00Z", persona="admin"), cp("C3", "pass", "2026-11-05T09:40:00Z", conf="low"),
  cp("C4", "blocked", "2026-11-05T09:50:00Z", la="S3cr3tLiteral in the page"), cp("C1;C2", "pass", "2026-11-05T10:30:00Z")]})
w("runs/r1-alpha (رمضان)/bug-log.json", [{"bug_id": "B1", "title": AR, "severity": "critical", "suspected_layer": "FE", "actual": "password=hunter2xyz"},
                                         {"bug_id": "B2", "title": "Second", "severity": "low", "suspected_layer": "DB"}])
w("runs/r1-alpha (رمضان)/verification.json", [])
w("runs/r1-alpha (رمضان)/report.html", "<html></html>")
jl("runs/r1-alpha (رمضان)/journal.ndjson", [{"event": "run_started", "t": "2026-11-05T09:00:00Z"}, plan(["C1", "C2", "C3", "C4"])])
# r2: alpha, running — 4 distinct verdicts 10 minutes apart, plus a repeat that must not count twice
ev = [{"event": "run_started", "t": "2026-11-09T11:00:00Z"}, {"event": "phase_entered", "phase": "verify", "t": "2026-11-09T11:00:05Z"}]
for k, (c, m) in enumerate([("C1", "11:15"), ("C2", "11:25"), ("C3", "11:35"), ("C3", "11:40"), ("C4", "11:45")]):
    ev.append({"event": "criterion_started", "criterionId": c, "personaId": "admin", "t": "2026-11-09T" + m + ":00Z"})
    ev.append({"event": "criterion_verdict", "criterionId": c, "personaId": "admin", "verdict": "pass", "confidence": "high", "lastAction": "Saved " + c + (" password=hunter2xyz S3cr3tLiteral" if c == "C4" else ""), "t": "2026-11-09T" + m + ":00Z"})
ev.append({"event": "bug_logged", "bugId": "B9", "title": AR, "suspectedLayer": "FE", "t": "2026-11-09T11:50:00Z"})
ev.append({"event": "criterion_started", "criterionId": "C5", "personaId": "leader", "t": "2026-11-09T11:52:00Z"})
jl("runs/r2-alpha/journal.ndjson", ev)
w("runs/r2-alpha/run-manifest.json", {"run_id": "r2-alpha", "target_feature": "alpha", "status": "in-progress", "started_at": "2026-11-09T11:00:00Z", "ended_at": None, "criteria_total": 16, "criteria_done": 1})
w("runs/r2-alpha/cursor.json", {"criteria_done": 4, "criteria_total": 16, "phase": "verify", "cursor": {"criterionId": "C5", "scenarioId": "leader", "subState": "pending"}})
w("runs/r2-alpha/bug-log.json", [{"bug_id": "B7", "title": "Save button stays disabled", "severity": "medium", "criterion_id": "C2", "persona": "admin",
                                 "suspected_layer": "FE", "observed": "Nothing saved; password=hunter2xyz", "expected": "The record saves"}])
w("runs/r2-alpha/checkpoint.json", {"run_id": "r2-alpha", "criteria": [cp(c, "pass", "2026-11-09T11:%d0:00Z" % (k + 1), persona="admin") for k, c in enumerate(["C1", "C2", "C3", "C4"])]})
# r3: beta, stalled two hours ago
w("runs/r3-beta/cursor.json", {"criteria_done": 2, "criteria_total": 10, "phase": "verify", "cursor": {"criterionId": "B1", "scenarioId": "user", "subState": "arranging"}})
w("runs/r3-beta/checkpoint.json", {"run_id": "r3-beta", "criteria": [cp("B1", "fail", "2026-11-09T09:00:00Z")]})
jl("runs/r3-beta/journal.ndjson", [{"event": "run_started", "t": "2026-11-09T08:30:00Z"},
  {"event": "criterion_verdict", "criterionId": "B1", "personaId": "user", "verdict": "fail", "t": "2026-11-09T09:00:00Z"},
  {"event": "criterion_verdict", "criterionId": "B2", "personaId": "user", "verdict": "pass", "t": "2026-11-09T09:30:00Z"}])
# r4: paused by the operator, though every criterion is done
w("runs/r4-beta/run-manifest.json", {"run_id": "r4-beta", "target_feature": "beta", "status": "paused-environment-blocked", "started_at": "2026-11-08T08:00:00Z", "criteria_total": 1, "criteria_done": 1})
w("runs/r4-beta/cursor.json", {"criteria_done": 1, "criteria_total": 1, "phase": "verify", "cursor": None})
w("runs/r4-beta/checkpoint.json", {"run_id": "r4-beta", "criteria": [cp("B1", "pass", "2026-11-08T08:30:00Z")]})
# not a run: a roles-only directory
w("runs/roles-only/personas.json", [])
# credentials the dashboard must never touch
w("auth/credentials.json", {"password": "SUPERSECRETPW"})
w("auth/admin.json", {"cookies": [{"value": "SUPERSECRETPW"}]})
PY
setm(){ node -e 'const fs=require("fs");const t=(Date.parse(process.argv[2])-Number(process.argv[3])*60000)/1000;fs.utimesSync(process.argv[1],t,t)' "$1" "$NOW" "$2"; }
for f in "$P/.qa/runs/"*/*; do setm "$f" 3000; done
setm "$P/.qa/runs/r2-alpha/journal.ndjson" 5      # running: moved 5 minutes ago
setm "$P/.qa/runs/r3-beta/journal.ndjson" 120     # stalled: idle for two hours
chmod 000 "$P/.qa/auth/credentials.json" "$P/.qa/auth/admin.json"; chmod 000 "$P/.qa/auth"

# fs trace: any access to .qa/auth from the dashboard process aborts it with 97.
cat > "$W/trap-auth.js" <<'JS'
const fs = require("fs"), path = require("path");
const bad = (p) => typeof p === "string" && path.resolve(p).split(path.sep).join("/").includes("/.qa/auth");
for (const n of ["openSync", "readFileSync", "readdirSync", "statSync", "lstatSync", "existsSync", "accessSync", "realpathSync", "open", "readFile", "readdir", "stat", "lstat", "access", "createReadStream"]) {
  const orig = fs[n]; if (typeof orig !== "function") continue;
  fs[n] = function (p, ...rest) { if (bad(p)) { process.stderr.write("TOUCHED .qa/auth via " + n + ": " + p + "\n"); process.exit(97); } return orig.call(this, p, ...rest); };
}
JS
dash(){ NODE_OPTIONS="--require $W/trap-auth.js" QA_DASHBOARD_NOW="$NOW" bash "$SH" "$@"; }
q(){ printf '%s' "$1" | python3 -c 'import json,sys;d=json.load(sys.stdin);r=eval(sys.argv[1]);print(r if isinstance(r,str) else json.dumps(r,sort_keys=True,separators=(",",":"),ensure_ascii=False))' "$2"; }

# ---------------------------------------------------------------------------
# JSON model
# ---------------------------------------------------------------------------
J="$(dash json --project "$P" 2>"$W/err")"; rc=$?
check "json exits 0 with .qa/auth unreadable and traced" "$rc" "0"
check "json no stderr" "$(cat "$W/err")" ""
run(){ q "$J" "[r for r in d['runs'] if r['id']=='$1'][0]$2"; }
check "runs listed newest first, non-runs skipped" "$(q "$J" '[r["id"] for r in d["runs"]]')" '["r2-alpha","r3-beta","r4-beta","r1-alpha (رمضان)","r0-alpha"]'
check "running detected (journal moved 5m ago, 4/16)" "$(run r2-alpha "['status']")" "running"
check "stalled detected (idle 2h, 2/10)" "$(run r3-beta "['status']")" "stalled"
check "stalled idle minutes" "$(run r3-beta "['idleMinutes']")" "120"
check "paused manifest wins over a finished cursor" "$(run r4-beta "['status']")" "paused"
check "complete from manifest" "$(run r0-alpha "['status']")" "complete"
check "running progress" "$(run r2-alpha "['progress']")" '{"done":4,"percent":25,"total":16}'
check "rate: 4 distinct verdicts over 30m = 6/h (repeat not double-counted)" "$(run r2-alpha "['ratePerHour']")" "6"
check "eta: 12 left at 6/h = 2h" "$(run r2-alpha "['eta']")" '{"at":"2026-11-09T14:00:00.000Z","hours":2}'
check "stalled run has no eta" "$(run r3-beta "['eta']")" "null"
check "active panel: running + recently stalled" "$(q "$J" 'd["active"]')" '["r2-alpha","r3-beta"]'
check "active cursor" "$(q "$J" "[[r['active']['criterion'],r['active']['persona'],r['active']['phase']] for r in d['runs'] if r['id']=='r2-alpha'][0]")" '["C5","leader","verify"]'
check "active events newest first, human-readable" "$(q "$J" "[r['active']['events'][0]['text'] for r in d['runs'] if r['id']=='r2-alpha'][0]")" "Started C5 · leader"
check "active events capped at 10" "$(q "$J" "[len(r['active']['events']) for r in d['runs'] if r['id']=='r2-alpha'][0]")" "10"
check "active latest bug from the journal" "$(q "$J" "[r['active']['bugs'][0]['title'] for r in d['runs'] if r['id']=='r2-alpha'][0]")" "$AR_TITLE"
check "target resolved from 'alpha (phase two)'" "$(run "r1-alpha (رمضان)" "['target']")" "alpha"
check "target resolved from run id" "$(run r3-beta "['target']")" "beta"
check "bugs by severity" "$(run "r1-alpha (رمضان)" "['bugs']")" '{"bySeverity":{"critical":1,"low":1},"total":2}'
check "verified flag" "$(run "r1-alpha (رمضان)" "['verified']")" "true"
check "low-confidence passes" "$(run "r1-alpha (رمضان)" "['lowPasses']")" "1"
check "report link" "$(run "r1-alpha (رمضان)" "['report']['rel']")" ".qa/runs/r1-alpha%20(%D8%B1%D9%85%D8%B6%D8%A7%D9%86)/report.html"

# supersession / out-of-plan: identical to render-report.js's own tally
cp -R "$P/.qa/runs/r1-alpha (رمضان)" "$W/r1copy"
RT="$(node "$RR" "$W/r1copy" | sed -n 's/^tally: \(pass=[0-9]* fail=[0-9]* blocked=[0-9]* deferred=[0-9]* error=[0-9]*\).*/\1/p')"
DT="$(q "$J" "' '.join(k+'='+str([r for r in d['runs'] if r['id']=='r1-alpha (رمضان)'][0]['tally'][k]) for k in ['pass','fail','blocked','deferred','error'])")"
check "tally equals render-report (superseded + out-of-plan rows)" "$DT" "$RT"
check "tally values" "$DT" "pass=3 fail=0 blocked=1 deferred=0 error=0"
check "superseded / out-of-plan counts" "$(run "r1-alpha (رمضان)" "['superseded']"),$(run "r1-alpha (رمضان)" "['outOfPlan']")" "1,1"

# specs
spec(){ q "$J" "[s for s in d['specs'] if s['target']=='$1'][0]$2"; }
check "spec criteria" "$(spec alpha "['criteria']")" "5"
check "spec journeys" "$(spec alpha "['journeys']")" '{"P1":1,"P2":1,"P3":0}'
check "spec oracle sources" "$(spec alpha "['oracle']")" '{"human":1,"llm-suggested":2,"spec":1}'
check "analysis OK ('not blocked' prose)" "$(spec alpha "['analysis']['verdict']")" "OK"
check "analysis BLOCKED" "$(spec beta "['analysis']['verdict']")" "BLOCKED"
check "spec coverage" "$(spec beta "['coverage']['percent']")" "80"
check "spec role drift" "$(spec alpha "['drift']"),$(spec beta "['drift']")" "false,true"
check "spec run counts" "$(spec alpha "['runs']"),$(spec beta "['runs']")" "3,2"
# header
check "constitution" "$(q "$J" '[d["constitution"]["version"],d["constitution"]["roles"]]')" '["abc123def4567890",3]'
check "profile" "$(q "$J" '[d["config"]["profile"],d["config"]["environment"],d["config"]["gates"]]')" '["ship","staging",["coverage: block"]]'
check "plugin version" "$(q "$J" 'd["plugin"]["version"]')" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
# trend + known defects
check "trend for alpha, oldest first" "$(q "$J" '[[p["runId"],p["pass"],p["fail"],p["bugs"]] for t in d["trends"] if t["target"]=="alpha" for p in t["points"]]')" '[["r0-alpha",1,2,1],["r1-alpha (رمضان)",3,0,2],["r2-alpha",4,0,1]]'
check "known defects states" "$(q "$J" '[[e["id"],e["state"]] for e in d["knownDefects"]["entries"]]')" '[["KD-1","outstanding"],["KD-2","expired"]]'
check "known defects counts" "$(q "$J" 'd["knownDefects"]["counts"]')" '{"cleared":0,"expired":1,"outstanding":1}'
# secrets
for s in SUPERSECRETPW PersonaPassw0rd hunter2xyz S3cr3tLiteral abc.def.ghi; do lacks "json has no secret $s" "$J" "$s"; done
has "redaction marker" "$J" "<redacted>"
has "arabic title intact (json)" "$J" "$AR_TITLE"

# features: each target's latest run in people's terms
feat(){ q "$J" "[f for f in d['features'] if f['target']=='$1'][0]$2"; }
check "features: active targets first" "$(q "$J" '[f["target"] for f in d["features"]]')" '["alpha","beta"]'
check "feature uses the latest run" "$(feat alpha "['runId']"),$(feat beta "['runId']")" "r2-alpha,r3-beta"
check "journeys from journeys.json steps, priority order, leftovers grouped" "$(feat alpha "[[j['id'],j['priority'],[k['id'] for k in j['checks']]] for j in f['journeys']]" 2>/dev/null || q "$J" "[[j['id'],j['priority'],[k['id'] for k in j['checks']]] for f in d['features'] if f['target']=='alpha' for j in f['journeys']]")" '[["J1","P1",["C1","C2"]],["J2","P2",["C3"]],["other","",["C4"]]]'
check "journey counts" "$(q "$J" "[j['counts'] for f in d['features'] if f['target']=='alpha' for j in f['journeys']][0]")" '{"blocked":0,"deferred":0,"error":0,"fail":0,"pass":2,"pending":0}'
check "no journeys.json -> checks grouped by role" "$(q "$J" "[j['name'] for f in d['features'] if f['target']=='beta' for j in f['journeys']]")" '["Checks as any role"]'
check "feature bug tied to its journey" "$(q "$J" "[[b['id'],b['severity'],b['journey'],b['role'],b['expected']] for f in d['features'] if f['target']=='alpha' for b in f['bugs']]")" '[["B7","medium","J1","admin","The record saves"]]'
check "readiness running" "$(feat alpha "['readiness']")" '{"facts":"1 bug is open.","headline":"In progress","level":"progress"}'
check "readiness stalled with a failure" "$(feat beta "['readiness']['headline']"),$(feat beta "['readiness']['level']")" "Stalled,warn"
check "check names are readable" "$(q "$J" "[k['name'] for f in d['features'] if f['target']=='alpha' for j in f['journeys'] for k in j['checks']][0]")" "C1"

# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------
dash html --project "$P" >/dev/null 2>"$W/err"; rc=$?
check "html exits 0" "$rc" "0"
H="$(cat "$P/.qa/dashboard.html")"
check "html default path written" "$([ -s "$P/.qa/dashboard.html" ] && echo yes)" "yes"
has "html doctype" "$H" "<!DOCTYPE html>"
has "html dark mode" "$H" "prefers-color-scheme:dark"
has "html dir=auto on user text" "$H" 'dir="auto"'
has "html arabic title intact" "$H" "$AR_TITLE"
has "html stalled warning" "$H" "Stalled: no journal activity"
has "html trend svg" "$H" '<svg class="trend"'
has "html ship-less runs show a dash" "$H" "Ship"
has "html report link relative to .qa/dashboard.html" "$H" 'href="runs/r1-alpha%20(%D8%B1%D9%85%D8%B6%D8%A7%D9%86)/report.html"'
lacks "html no meta refresh by default" "$H" 'http-equiv="refresh"'
EXT="$(printf '%s' "$H" | grep -Eio '(src|href|action)=["'"'"']?[a-z]*:?//[^"'"'"' >]*|url\([^)]*//|@import|<script[^>]*src|<link[^>]*href' | head -3)"
check "html references nothing external" "$EXT" ""
for s in SUPERSECRETPW PersonaPassw0rd hunter2xyz S3cr3tLiteral abc.def.ghi; do lacks "html has no secret $s" "$H" "$s"; done
has "html journey line for main journeys" "$H" 'class="line main"'
has "html stops link to their check" "$H" 'data-ck="ck-alpha-j1-0"'
has "html check list item" "$H" 'id="ck-alpha-j1-0"'
has "html readiness headline" "$H" '<p class="v-head">In progress</p>'
has "html roles fallback" "$H" "Checks as any role"
has "html empty bug state" "$H" "No bugs logged in this run."
has "html bug detail" "$H" "What should happen"
has "html bug links its check" "$H" 'href="#bug-alpha-b7"'
has "html works without js (details)" "$H" '<details class="jr"'
has "html filters hidden until js runs" "$H" '<div class="filters" hidden>'
has "html generated time for local rendering" "$H" 'data-generated="2026-11-09T12:00:00.000Z"'
dash html --project "$P" --out "$W/out/d.html" --refresh 15 >/dev/null 2>&1; rc=$?
check "html --out exits 0" "$rc" "0"
H2="$(cat "$W/out/d.html")"
has "html meta refresh" "$H2" '<meta http-equiv="refresh" content="15">'
has "html refresh only without js (state kept on reload)" "$H2" '<noscript><meta http-equiv="refresh" content="15"></noscript>'
has "html refresh period for the script" "$H2" 'data-refresh="15"'
has "html link relative to --out" "$H2" 'href="../proj/.qa/runs/r1-alpha%20(%D8%B1%D9%85%D8%B6%D8%A7%D9%86)/report.html"'

# html --watch rewrites the page (atomically) and exits 0 on SIGTERM; --open uses the platform opener
mkdir -p "$W/bin"
for o in open xdg-open; do printf '#!/bin/sh\necho "$@" >> "%s/opened"\n' "$W" > "$W/bin/$o"; chmod +x "$W/bin/$o"; done
PATH="$W/bin:$PATH" NODE_OPTIONS="--require $W/trap-auth.js" QA_DASHBOARD_NOW="$NOW" node "$JS" html --project "$P" --out "$W/w/d.html" --watch 1 --open >"$W/hw.out" 2>&1 &
hp=$!
m1=""; for _ in $(seq 1 40); do [ -s "$W/w/d.html" ] && { m1="$(node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$W/w/d.html")"; break; }; sleep 0.1; done
m2="$m1"; for _ in $(seq 1 40); do m2="$(node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$W/w/d.html" 2>/dev/null)"; [ "$m2" != "$m1" ] && break; sleep 0.1; done
kill -TERM "$hp" 2>/dev/null; wait "$hp"; rc=$?
check "html --watch exits 0 on SIGTERM" "$rc" "0"
check "html --watch rewrote the page" "$([ -n "$m1" ] && [ "$m2" != "$m1" ] && echo yes)" "yes"
has "html --watch implies the page refresh" "$(cat "$W/w/d.html")" 'data-refresh="1"'
check "html --watch leaves no temp file" "$(ls "$W/w" | grep -c tmp)" "0"
has "html --open used the platform opener" "$(cat "$W/opened" 2>/dev/null)" "$W/w/d.html"
T0="$(COLUMNS=100 dash tui --project "$P" 2>&1)"
has "tui journeys section" "$T0" "JOURNEYS"
has "tui journey line with legend" "$T0" "◆ failed"

# ---------------------------------------------------------------------------
# Terminal
# ---------------------------------------------------------------------------
T="$(dash tui --project "$P" 2>&1)"; rc=$?
check "tui exits 0" "$rc" "0"
lacks "tui non-TTY has no ANSI escapes" "$T" $'\x1b['
has "tui stalled warning" "$T" "STALLED"
has "tui running row" "$T" "r2-alpha"
has "tui eta" "$T" "ETA 2h"
has "tui arabic intact" "$T" "$AR_TITLE"
for s in SUPERSECRETPW hunter2xyz S3cr3tLiteral; do lacks "tui has no secret $s" "$T" "$s"; done
T="$(FORCE_COLOR=1 dash tui --project "$P" 2>&1)"
has "tui FORCE_COLOR colours" "$T" $'\x1b[1m'
T="$(NO_COLOR=1 FORCE_COLOR=1 dash tui --project "$P" 2>&1)"
lacks "tui NO_COLOR wins" "$T" $'\x1b['
# watch mode: redraws, then Ctrl-C exits 0
NODE_OPTIONS="--require $W/trap-auth.js" QA_DASHBOARD_NOW="$NOW" node "$JS" tui --project "$P" --watch 1 >"$W/watch.out" 2>&1 &
wp=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  [ "$(grep -c 'Ctrl-C to quit' "$W/watch.out" 2>/dev/null)" -ge 2 ] && break; sleep 0.2
done
kill -INT "$wp" 2>/dev/null; wait "$wp"; rc=$?
check "watch exits 0 on SIGINT" "$rc" "0"
check "watch redrew at least twice" "$([ "$(grep -c 'Ctrl-C to quit' "$W/watch.out")" -ge 2 ] && echo yes)" "yes"
lacks "watch non-TTY has no ANSI escapes" "$(cat "$W/watch.out")" $'\x1b['

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------
U="$(node -e '
const d = require(process.argv[1]); const H = 3600000, now = Date.parse("2026-11-09T12:00:00Z");
const s = (o) => d.runStatus(Object.assign({ nowMs: now, stallMs: 30 * 60000 }, o));
console.log(JSON.stringify([
  s({ manifestStatus: "in-progress", done: 3, total: 9, lastActivityMs: now - 29 * 60000 }),
  s({ manifestStatus: "in-progress", done: 3, total: 9, lastActivityMs: now - 31 * 60000 }),
  s({ manifestStatus: "", done: 9, total: 9, lastActivityMs: now }),
  s({ manifestStatus: "completed", done: 3, total: 9, lastActivityMs: now }),
  s({ manifestStatus: "paused", done: 3, total: 9, lastActivityMs: now }),
  s({ manifestStatus: "", done: null, total: null, lastActivityMs: null }),
  d.computeRate([], now, 6, now - 3 * H),
  d.computeRate([{ t: now - H, key: "a" }], now, 0, null),
  d.computeEta(4, 10, 18, now),
  d.computeEta(4, 18, 18, now),
  [d.fmtDuration(0.5), d.fmtDuration(2.25), d.fmtDuration(100)],
  d.resolveTarget("eval-x-20260101", "evaluation counters", ["eval-x", "eval"]),
  [d.humanize("HLC-K01-create-auto-accept-hackathon"), d.humanize("C1"), d.humanize("checkout_flow-v2")],
  d.journeySummary({ checks: [1, 2, 3], counts: { pass: 1, fail: 1, error: 0, blocked: 0, deferred: 0, pending: 1 } }),
  d.readinessOf({ status: "complete", tally: { pass: 3, fail: 1, error: 0, blocked: 0, deferred: 0 }, ship: null },
    { journeys: [{ priority: "P1", counts: { fail: 1, error: 0 } }, { priority: "P1", counts: { fail: 0, error: 0 } }], bugs: [{ status: "open" }, { status: "fixed" }] }),
]));' "$JS")"
check "pure helpers" "$U" '["running","stalled","complete","complete","paused","unknown",2,null,{"hours":2,"at":"2026-11-09T14:00:00.000Z"},null,["30m","2h15m","4d"],"eval-x",["Create auto accept hackathon","C1","Checkout flow v2"],{"text":"1 failed, 1 to go","tone":"bad"},{"level":"bad","headline":"Not ready to ship","facts":"1 check failed, touching 1 of 2 main journeys. 1 bug is open."}]'

# errors
dash json --project "$W/nowhere" >/dev/null 2>&1; check "no .qa -> exit 2" "$?" "2"
dash bogus >/dev/null 2>&1; check "unknown mode -> exit 2" "$?" "2"

echo "qa-dashboard: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
