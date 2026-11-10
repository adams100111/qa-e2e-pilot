#!/usr/bin/env node
/*
 * qa-dashboard.js — the project-level QA state dashboard (engine 0.12.2).
 * Reads a project's .qa/ tree (constitution, specs, runs, known-defect
 * registry) and shows where it stands: one self-contained HTML page, a
 * terminal view, or the model as JSON for other tools.
 *
 * USAGE:
 *   node qa-dashboard.js html [--project <dir>] [--out <file>] [--refresh <sec>] [--watch <sec>] [--open]
 *   node qa-dashboard.js tui  [--project <dir>] [--watch <sec>]
 *   node qa-dashboard.js json [--project <dir>]
 *   common: [--stall-minutes <n>] (default 30) [--now <ISO-8601>] (tests)
 *
 * Read-only. Per-run verdicts, supersession and ship readiness come from
 * render-report.js's own buildModel (one implementation, never re-derived
 * here). Never reads .qa/auth; every string shown passes the same redaction
 * bug-export.sh applies (config enforcement.redactedKeys / secretPatterns,
 * built-in defaults when absent). The HTML references nothing external and
 * works from file://. Dependency-free: node's fs/path/child_process only.
 */
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const RR = require("./render-report.js");

const VERDICTS = RR.VERDICTS;
const HOUR = 3600000;
const RATE_WINDOW_MS = 2 * HOUR;
// A stalled run stays in the active panel for a day; older ones are abandoned
// and only show as "stalled" in the runs table.
const ACTIVE_STALL_WINDOW_MS = 24 * HOUR;
const SEVERITIES = ["critical", "high", "medium", "low"];

function die(msg, code) { process.stderr.write("qa-dashboard: " + msg + "\n"); process.exit(code || 2); }

// ---------------------------------------------------------------------------
// Guarded file access: everything under .qa/auth is off limits, whatever the
// caller asks for. Failures read as "absent".
// ---------------------------------------------------------------------------
let AUTH_DIR = null;
function guard(p) {
  const abs = path.resolve(p);
  if (AUTH_DIR && (abs === AUTH_DIR || abs.startsWith(AUTH_DIR + path.sep))) throw new Error("refusing to read " + abs);
  return abs;
}
function readText(p) { try { return fs.readFileSync(guard(p), "utf8"); } catch (_) { return null; } }
function readJSON(p, fallback) { const t = readText(p); if (t === null) return fallback; try { return JSON.parse(t); } catch (_) { return fallback; } }
function mtimeMs(p) { try { return fs.statSync(guard(p)).mtimeMs; } catch (_) { return null; } }
function exists(p) { try { fs.statSync(guard(p)); return true; } catch (_) { return false; } }
function listDirs(p) {
  let names = [];
  try { names = fs.readdirSync(guard(p)).sort(); } catch (_) { return []; }
  return names.filter((n) => { try { return fs.lstatSync(guard(path.join(p, n))).isDirectory(); } catch (_) { return false; } });
}
function str(v) { return typeof v === "string" ? v : (v === undefined || v === null ? "" : (typeof v === "object" ? JSON.stringify(v) : String(v))); }
function parseTime(v) { const t = typeof v === "string" && v ? Date.parse(v) : NaN; return Number.isFinite(t) ? t : null; }

// ---------------------------------------------------------------------------
// Redaction — the same rules as bug-export.sh: keys naming a credential (or
// listed in enforcement.redactedKeys) are dropped, redactedKeys literals and
// secretPatterns matches inside strings become "<redacted>".
// ---------------------------------------------------------------------------
const SENS_KEY = /password|passwd|secret|token|api[_-]?key|authorization|cookie|credential/i;
const DEFAULT_PATTERNS = ["(password|passwd|secret|token|api[_-]?key|apikey|authorization|bearer|access[_-]?key|private[_-]?key|client[_-]?secret)\\s*[=:]\\s*\\S+"];
const AUTH_PATTERNS = ["authorization\\s*[=:]\\s*((bearer|basic)\\s+)?\\S+", "bearer\\s+[A-Za-z0-9._~+/=-]+", "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"];
function makeRedactor(config) {
  const enf = config && typeof config === "object" && config.enforcement && typeof config.enforcement === "object" ? config.enforcement : {};
  const rk = (Array.isArray(enf.redactedKeys) ? enf.redactedKeys : []).filter((k) => typeof k === "string" && k !== "");
  const rkl = rk.map((k) => k.toLowerCase());
  const cfgp = Array.isArray(enf.secretPatterns) ? enf.secretPatterns : null;
  let pats = cfgp !== null ? cfgp : DEFAULT_PATTERNS;
  pats = (cfgp !== null && cfgp.length === 0 ? [] : AUTH_PATTERNS).concat(pats);
  const res = [];
  for (const p of pats) {
    if (typeof p !== "string" || p === "") continue;
    try { res.push(new RegExp(p.replace(/^\(\?i\)/, ""), "gi")); } catch (_) { /* not a JS regex: skipped, like bug-export */ }
  }
  const red = (v) => {
    if (Array.isArray(v)) return v.map(red);
    if (v && typeof v === "object") {
      const o = {};
      for (const k of Object.keys(v)) if (!rkl.includes(k.toLowerCase()) && !SENS_KEY.test(k)) o[k] = red(v[k]);
      return o;
    }
    if (typeof v === "string") {
      let s = v.replace(/[\x01-\x08\x0b-\x1f\x7f]/g, "");
      for (const k of rk) s = s.split(k).join("<redacted>");
      for (const r of res) s = s.replace(r, "<redacted>");
      return s;
    }
    return v;
  };
  return red;
}

// ---------------------------------------------------------------------------
// Run status, rate and ETA (pure; exported for tests).
// ---------------------------------------------------------------------------
// runStatus -> running | stalled | paused | complete | unknown.
// A manifest that says complete wins; a paused/blocked/aborted manifest is
// paused; otherwise the cursor decides: every criterion done = complete (the
// run was never closed); some left = running while the journal moved within
// the stall window, stalled after it.
function runStatus(o) {
  const ms = String(o.manifestStatus || "").toLowerCase();
  if (/^(complete|completed|done|finished|ended)$/.test(ms)) return "complete";
  if (/^(paused|blocked|aborted|stopped|cancel)/.test(ms)) return "paused";
  if (Number.isFinite(o.total) && o.total > 0 && Number.isFinite(o.done) && o.done >= o.total) return "complete";
  if (o.lastActivityMs === null || o.lastActivityMs === undefined) return "unknown";
  return o.nowMs - o.lastActivityMs < o.stallMs ? "running" : "stalled";
}

// computeRate -> criteria per hour, or null. Uses the distinct criterion
// verdicts recorded in the RATE_WINDOW_MS before the latest one (a resumed
// run's idle gap does not dilute it); with fewer than two, falls back to
// done / hours since the run started.
function computeRate(verdicts, nowMs, done, startedMs) {
  const list = (verdicts || []).filter((v) => Number.isFinite(v.t)).sort((a, b) => a.t - b.t);
  if (list.length >= 2) {
    const last = list[list.length - 1].t;
    const seen = new Map();
    for (const v of list) if (v.t >= last - RATE_WINDOW_MS && !seen.has(v.key)) seen.set(v.key, v.t);
    const times = [...seen.values()];
    const span = last - Math.min(...times);
    if (times.length >= 2 && span > 0) return (times.length - 1) / (span / HOUR);
  }
  if (Number.isFinite(startedMs) && Number.isFinite(done) && done > 0 && nowMs > startedMs) return done / ((nowMs - startedMs) / HOUR);
  return null;
}

function computeEta(rate, done, total, nowMs) {
  if (!rate || !(rate > 0) || !Number.isFinite(done) || !Number.isFinite(total) || total <= done) return null;
  const hours = (total - done) / rate;
  return { hours: Math.round(hours * 100) / 100, at: new Date(nowMs + hours * HOUR).toISOString() };
}

function fmtDuration(hours) {
  if (hours === null || hours === undefined || !Number.isFinite(hours)) return "";
  const mins = Math.round(hours * 60);
  if (mins < 60) return mins + "m";
  const h = Math.floor(mins / 60), m = mins % 60;
  if (h < 48) return h + "h" + (m ? String(m).padStart(2, "0") + "m" : "");
  return Math.round(h / 24) + "d";
}

// ---------------------------------------------------------------------------
// Journal
// ---------------------------------------------------------------------------
function readJournal(runDir) {
  const text = readText(path.join(runDir, "journal.ndjson"));
  if (text === null) return null;
  const out = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try { const e = JSON.parse(line); if (e && typeof e === "object") out.push(e); } catch (_) { /* torn line */ }
  }
  return out;
}

function clip(s, n) { const a = Array.from(str(s)); return a.length > n ? a.slice(0, n - 1).join("") + "…" : a.join(""); }

// One human-readable line per journal event.
function describeEvent(e) {
  const who = (x) => (x ? " · " + x : "");
  const crit = str(e.criterionId);
  switch (e.event) {
    case "run_started": return "Run started";
    case "run_ended": return "Run ended" + (e.status ? " (" + str(e.status) + ")" : "");
    case "plan_frozen": return "Plan frozen: " + (Array.isArray(e.criteria) ? e.criteria.length : 0) + " criteria";
    case "plan_amended": return "Plan amended: " + crit;
    case "phase_entered": return "Entered phase " + str(e.phase);
    case "phase_exited": return "Left phase " + str(e.phase);
    case "criterion_started": return "Started " + crit + who(e.personaId || e.scenarioId);
    case "criterion_verdict": return str(e.verdict).toUpperCase() + " " + crit + who(e.personaId) + (e.confidence === "low" ? " (low confidence)" : "")
      + (e.lastAction ? " — " + clip(e.lastAction, 140) : "");
    case "act_intent": return "About to act on " + (str(e.key).split(":").pop() || crit)
      + (Array.isArray(e.writeSet) && e.writeSet.length ? " (" + e.writeSet.length + " write(s))" : "");
    case "act_committed": return "Act " + (e.outcome ? str(e.outcome) : "committed") + ": " + (str(e.key).split(":").pop() || crit);
    case "finding_observed": return "Finding on " + crit + ": " + clip([e.status, e.message].filter((x) => x !== undefined && x !== null && x !== "").map(str).join(" "), 140);
    case "bug_logged": return "Bug logged: " + clip(e.title || e.bugId, 140) + (e.suspectedLayer ? " [" + str(e.suspectedLayer) + "]" : "");
    case "capture_probed": return "Capture channel probed (" + str(e.channel) + ")";
    default: return str(e.event || "event") + (crit ? " " + crit : "");
  }
}

// ---------------------------------------------------------------------------
// Project pieces
// ---------------------------------------------------------------------------
function pluginInfo() {
  const p = readJSON(path.join(__dirname, "..", ".claude-plugin", "plugin.json"), {}) || {};
  return { name: str(p.name || "qa-e2e-pilot"), version: str(p.version || "") };
}

function constitutionInfo(qa) {
  const st = readJSON(path.join(qa, "constitution.state.json"), null);
  const mdPresent = exists(path.join(qa, "constitution.md"));
  if (!st || typeof st !== "object") return { present: mdPresent, version: "", roles: 0, mdPresent };
  const roles = Array.isArray(st.roles) ? st.roles.filter((r) => r && typeof r === "object") : [];
  return { present: true, version: str(st.version), roles: roles.length, mdPresent,
    planes: { global: roles.filter((r) => r.plane === "global").length, contextual: roles.filter((r) => r.plane === "contextual").length } };
}

function configInfo(config) {
  if (!config || typeof config !== "object") return { present: false };
  const gates = config.gates && typeof config.gates === "object" ? config.gates : {};
  return {
    present: true, profile: typeof config.profile === "string" && config.profile ? config.profile : "full (default)",
    environment: str(config.environment), maxParallel: Number.isFinite(config.maxParallel) ? config.maxParallel : null,
    allowApiWrites: config.allowApiWrites === true,
    gates: Object.keys(gates).filter((k) => !k.startsWith("_")).map((k) => k + ": " + str(gates[k])),
    personas: Array.isArray(config.personas) ? config.personas.length : null,
  };
}

function rowsOf(checklist) {
  if (Array.isArray(checklist)) return checklist.filter((r) => r && typeof r === "object");
  if (checklist && Array.isArray(checklist.criteria)) return checklist.criteria.filter((r) => r && typeof r === "object");
  return [];
}
function journeysOf(raw) {
  const list = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.journeys) ? raw.journeys : null);
  return list ? list.filter((j) => j && typeof j === "object") : null;
}

function analysisVerdict(specDir) {
  const text = readText(path.join(specDir, "analysis.md"));
  if (text === null) return { verdict: "missing", stale: false };
  const m = /^##\s+Verdict\s*$([\s\S]*?)(?=^##\s|(?![\s\S]))/m.exec(text);
  const body = m ? m[1] : "";
  const verdict = m ? (/\bBLOCKED\b/.test(body) ? "BLOCKED" : "OK") : "unknown";
  const a = mtimeMs(path.join(specDir, "analysis.md")), c = mtimeMs(path.join(specDir, "checklist.json"));
  return { verdict, stale: a !== null && c !== null && a < c };
}

function coverageOf(cov) {
  if (!cov || typeof cov !== "object" || Array.isArray(cov)) return null;
  if (Number.isFinite(cov.percent)) return { percent: cov.percent, uncovered: Number.isFinite(cov.uncovered) ? cov.uncovered : null };
  const left = (Number(cov.total) || 0) - (Number(cov.excluded) || 0);
  if (left > 0 && Number.isFinite(cov.covered)) return { percent: Math.round((cov.covered / left) * 1000) / 10, uncovered: Number.isFinite(cov.uncovered) ? cov.uncovered : null };
  return null;
}

function specInfo(qa, target, constitutionVersion) {
  const dir = path.join(qa, "specs", target);
  const rows = rowsOf(readJSON(path.join(dir, "checklist.json"), null));
  const journeys = journeysOf(readJSON(path.join(dir, "journeys.json"), null));
  const jc = { P1: 0, P2: 0, P3: 0 };
  for (const j of journeys || []) if (jc[j.priority] !== undefined) jc[j.priority] += 1;
  const oracle = { human: 0, spec: 0, "llm-suggested": 0 };
  for (const r of rows) {
    const src = r.fixture && r.fixture.expect && typeof r.fixture.expect === "object" ? r.fixture.expect.oracleSource : undefined;
    if (typeof src === "string" && oracle[src] !== undefined) oracle[src] += 1;
  }
  const roles = readJSON(path.join(dir, "spec-roles.json"), null);
  const stamped = roles && typeof roles === "object" ? str(roles.constitutionVersion) : "";
  return {
    target, criteria: rows.length, hasChecklist: exists(path.join(dir, "checklist.json")),
    journeys: journeys ? jc : null, oracle, analysis: analysisVerdict(dir),
    coverage: coverageOf(readJSON(path.join(dir, "coverage.json"), null)),
    drift: stamped && constitutionVersion ? stamped !== constitutionVersion : false,
  };
}

// The spec a run belongs to: manifest target_feature equal to a spec name,
// then its first word, then the longest spec name inside the run id, else the
// target_feature (or the run id) as given.
function resolveTarget(runId, targetFeature, specNames) {
  const tf = str(targetFeature).trim();
  if (tf && specNames.includes(tf)) return tf;
  const head = tf.split(/[\s(]/)[0];
  if (head && specNames.includes(head)) return head;
  const inId = specNames.filter((s) => runId === s || runId.includes(s)).sort((a, b) => b.length - a.length);
  if (inId.length) return inId[0];
  return head || runId;
}

function relLink(fromDir, abs) { return path.relative(fromDir, abs).split(path.sep).map(encodeURIComponent).join("/"); }

// ---------------------------------------------------------------------------
// Target detail: the latest run of a target, shaped for people rather than
// for the engine — journeys made of checks in plan order, bugs with what
// happened and what was expected, and one readiness sentence. Generic: a
// spec without journeys.json groups its checks by role instead.
// ---------------------------------------------------------------------------
const VERDICT_RANK = { fail: 5, error: 4, blocked: 3, deferred: 2, pass: 1 };
const SEV_RANK = { critical: 0, high: 1, medium: 2, low: 3, unrated: 4 };
const CLOSED_BUG = /^(fixed|closed|resolved|verified|wontfix|duplicate|cleared)/i;

// "HLC-K01-create-auto-accept-hackathon" -> "Create auto accept hackathon";
// ids without a code prefix only lose their separators.
function humanize(id) {
  const raw = str(id);
  let s = raw.replace(/^[A-Z][A-Z0-9]*-[A-Z]{0,3}\d+[a-z]?-(?=[a-z0-9])/, "").replace(/[-_]+/g, " ").trim();
  if (!s) s = raw;
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function journeyCheckIds(j) {
  const list = Array.isArray(j.criteria) ? j.criteria : (Array.isArray(j.steps) ? j.steps : []);
  return list.map((x) => (typeof x === "string" ? x : (x && typeof x === "object" ? str(x.criterionId || x.id) : ""))).filter(Boolean);
}

function emptyCounts() { return { pass: 0, fail: 0, blocked: 0, deferred: 0, error: 0, pending: 0 }; }

function runDetail(dir, model, specJourneys, currentId, reportRel) {
  const plan = rowsOf(readJSON(path.join(dir, "checklist.json"), null));
  const planRow = new Map(plan.map((r) => [str(r.id), r]));
  const byId = new Map();
  for (const c of model.criteria) {
    const prev = byId.get(c.id);
    if (!prev || (VERDICT_RANK[c.verdict] || 0) > (VERDICT_RANK[prev.verdict] || 0)) byId.set(c.id, c);
  }
  // Bug logs come in two key styles (engine camelCase and older snake_case).
  const pick = (o, ...keys) => { for (const k of keys) if (o[k] !== undefined && o[k] !== null && o[k] !== "") return o[k]; return ""; };
  const bugs = model.bugs.map((b) => {
    const sev = str(pick(b, "severity")).toLowerCase();
    return {
      id: str(pick(b, "id", "bugId", "bug_id")), title: str(pick(b, "title", "summary")), severity: SEV_RANK[sev] !== undefined ? sev : "unrated",
      status: str(pick(b, "status") || "open"), criterionId: str(pick(b, "criterionId", "criterion_id", "criterion")),
      role: str(pick(b, "persona", "personaId", "role")), layer: str(pick(b, "suspectedLayer", "suspected_layer", "layer")),
      observed: clip(pick(b, "observed", "actual"), 700), expected: clip(pick(b, "expected"), 700), journey: "", journeyName: "", link: "",
    };
  });
  const bugIdsBy = {};
  for (const b of bugs) if (b.criterionId) (bugIdsBy[b.criterionId] = bugIdsBy[b.criterionId] || []).push(b.id);

  const check = (id) => {
    const c = byId.get(id), r = planRow.get(id) || {};
    return { id, name: humanize(id), role: str(c ? c.persona : r.role), verdict: c ? c.verdict : "pending",
      lowConfidence: !!(c && c.verdict === "pass" && c.confidence === "low"), note: c ? clip(c.lastAction, 500) : "",
      bugs: bugIdsBy[id] || [], link: c && reportRel ? reportRel + "#" + c.anchor : "", current: id === currentId };
  };

  const order = [], seen = new Set();
  const add = (id) => { if (id && !seen.has(id)) { seen.add(id); order.push(id); } };
  for (const r of plan) add(str(r.id));
  for (const c of model.criteria) add(c.id);

  const groups = [], assigned = new Set(), index = new Map();
  for (const j of specJourneys || []) {
    const g = { id: str(j.id), name: str(j.name || j.title || j.id), priority: str(j.priority), ids: [] };
    for (const i of journeyCheckIds(j)) if (!g.ids.includes(i)) { g.ids.push(i); assigned.add(i); }
    groups.push(g); index.set(g.id, g);
  }
  // Checks tagged journey:<id> but missing from journeys.json join that journey.
  for (const id of order) {
    if (assigned.has(id)) continue;
    const r = planRow.get(id), c = byId.get(id);
    const tags = (r && Array.isArray(r.tags) ? r.tags : []).concat(c && Array.isArray(c.tags) ? c.tags : []);
    const tag = tags.map(str).find((x) => x.startsWith("journey:") && index.has(x.slice(8)));
    if (tag) { index.get(tag.slice(8)).ids.push(id); assigned.add(id); }
  }
  const rest = order.filter((id) => !assigned.has(id));
  if (rest.length) {
    if (groups.length) groups.push({ id: "other", name: "Checks outside the journeys", priority: "", ids: rest });
    else {
      const byRole = new Map();
      for (const id of rest) { const role = check(id).role || "any role"; if (!byRole.has(role)) byRole.set(role, []); byRole.get(role).push(id); }
      for (const [role, ids] of byRole) groups.push({ id: "role:" + role, name: "Checks as " + role, priority: "", ids });
    }
  }
  const prioRank = (p) => (/^P\d+$/.test(p) ? Number(p.slice(1)) : 99);
  const journeys = groups.filter((g) => g.ids.length).map((g, i) => {
    const checks = g.ids.map(check), counts = emptyCounts();
    for (const k of checks) counts[k.verdict] = (counts[k.verdict] || 0) + 1;
    return { id: g.id, name: g.name, priority: g.priority, checks, counts, _i: i };
  }).sort((a, b) => prioRank(a.priority) - prioRank(b.priority) || a._i - b._i).map((j) => { delete j._i; return j; });

  const journeyOf = new Map();
  for (const j of journeys) for (const k of j.checks) if (!journeyOf.has(k.id)) journeyOf.set(k.id, j);
  for (const b of bugs) {
    const j = journeyOf.get(b.criterionId);
    if (j) { b.journey = j.id; b.journeyName = j.name; }
    const c = byId.get(b.criterionId);
    if (c && reportRel) b.link = reportRel + "#" + c.anchor;
  }
  bugs.sort((a, b) => SEV_RANK[a.severity] - SEV_RANK[b.severity]);
  return { journeys, bugs };
}

// One readiness headline and one sentence of facts, from the latest run.
function readinessOf(run, detail) {
  const t = run.tally;
  if (!t) return { level: "unknown", headline: "No results yet", facts: "This run has not recorded a verdict." };
  const failed = (t.fail || 0) + (t.error || 0), blocked = t.blocked || 0;
  const main = detail.journeys.filter((j) => j.priority === "P1");
  const hit = main.filter((j) => j.counts.fail + j.counts.error > 0).length;
  const open = detail.bugs.filter((b) => !CLOSED_BUG.test(b.status)).length;
  const plural = (n, one, many) => n + " " + (n === 1 ? one : many);
  const parts = [];
  if (failed) parts.push(plural(failed, "check failed", "checks failed") + (main.length ? ", touching " + hit + " of " + main.length + " main journeys" : ""));
  if (blocked) parts.push(plural(blocked, "check is blocked", "checks are blocked"));
  if (open) parts.push(plural(open, "bug is open", "bugs are open"));
  const facts = parts.length ? parts.join(". ") + "." : "";
  if (run.ship) {
    const ok = run.ship.verdict === "SHIP-READY";
    return { level: ok ? "good" : "bad", headline: ok ? "Ready to ship" : "Not ready to ship", facts: facts || (ok ? "Every ship condition holds." : run.ship.conditions.join("; ")) };
  }
  if (run.status === "complete") {
    if (failed || blocked) return { level: "bad", headline: "Not ready to ship", facts };
    return { level: "good", headline: "Every check passed", facts: facts || "No failures, nothing blocked." };
  }
  const head = { running: "In progress", stalled: "Stalled", paused: "Paused" }[run.status] || "Unfinished";
  return { level: failed || blocked ? "warn" : "progress", headline: head, facts: facts || "No failures so far." };
}

function runInfo(qa, runId, specNames, ctx) {
  const dir = path.join(qa, "runs", runId);
  const manifest = readJSON(path.join(dir, "run-manifest.json"), null);
  const man = manifest && typeof manifest === "object" ? manifest : {};
  const cursor = readJSON(path.join(dir, "cursor.json"), null);
  const cur = cursor && typeof cursor === "object" ? cursor : {};
  const checkpoint = readJSON(path.join(dir, "checkpoint.json"), null);
  const journal = readJournal(dir);

  let model = null, modelError = "";
  if (checkpoint && typeof checkpoint === "object") {
    try { model = RR.buildModel(dir, { evidence: false }); } catch (e) { modelError = String(e && e.message || e); }
  } else if (exists(path.join(dir, "checkpoint.json"))) modelError = "checkpoint.json is not valid JSON";

  const num = (...vs) => { for (const v of vs) if (Number.isFinite(v)) return v; return null; };
  const done = num(cur.criteria_done, man.criteria_done, model ? model.distinct : undefined);
  const total = num(cur.criteria_total, man.criteria_total, model ? model.distinct : undefined);
  const firstT = journal && journal.length ? parseTime(journal[0].t) : null;
  const startedMs = parseTime(man.started_at) || firstT;
  // Activity = the newest of the journal and the tool stream: a long check
  // drives the browser for many minutes without a journal event, and that is
  // work, not a stall. Falls back to cursor / checkpoint for older runs.
  const moved = [mtimeMs(path.join(dir, "journal.ndjson")), mtimeMs(path.join(dir, "toolstream.jsonl"))].filter((v) => v !== null);
  const lastActivityMs = moved.length ? Math.max(...moved) : (mtimeMs(path.join(dir, "cursor.json")) || mtimeMs(path.join(dir, "checkpoint.json")));
  const manifestStatus = str(man.status);
  const status = runStatus({ manifestStatus, done, total, lastActivityMs, nowMs: ctx.nowMs, stallMs: ctx.stallMs });

  let rate = null, eta = null;
  if (status === "running" || status === "stalled") {
    const verdicts = (journal || []).filter((e) => e.event === "criterion_verdict")
      .map((e) => ({ t: parseTime(e.t), key: str(e.criterionId) + "\u0000" + str(e.personaId) }));
    rate = computeRate(verdicts, ctx.nowMs, done, startedMs);
    if (rate !== null) rate = Math.round(rate * 10) / 10;
    eta = status === "running" ? computeEta(rate, done, total, ctx.nowMs) : null;
  }

  const bugs = model ? model.bugs : RR.loadBugs(readJSON(path.join(dir, "bug-log.json"), []));
  const bySeverity = {};
  for (const b of bugs) {
    const s = str(b.severity).toLowerCase();
    const k = SEVERITIES.includes(s) ? s : "unrated";
    bySeverity[k] = (bySeverity[k] || 0) + 1;
  }
  const reportAbs = path.join(dir, "report.html");
  const run = {
    id: runId, target: resolveTarget(runId, man.target_feature, specNames), feature: str(man.target_feature),
    started: startedMs ? new Date(startedMs).toISOString() : "", ended: str(man.ended_at),
    manifestStatus, status, closed: !!man.ended_at || /^(complete|completed|done|finished|ended)$/i.test(manifestStatus),
    progress: { done, total, percent: Number.isFinite(done) && total ? Math.floor((done / total) * 1000) / 10 : null },
    ratePerHour: rate, eta,
    lastActivity: lastActivityMs ? new Date(lastActivityMs).toISOString() : "",
    idleMinutes: lastActivityMs ? Math.max(0, Math.round((ctx.nowMs - lastActivityMs) / 60000)) : null,
    tally: model ? model.tally : null, total: model ? model.total : null,
    lowPasses: model ? model.criteria.filter((c) => c.verdict === "pass" && c.confidence === "low").length : null,
    superseded: model ? model.superseded.length : 0, outOfPlan: model ? model.outOfPlan.length : 0,
    bugs: { total: bugs.length, bySeverity },
    verified: model ? model.verified : false,
    ship: model && model.ship ? { verdict: model.ship.verdict, conditions: model.ship.conditions } : null,
    report: exists(reportAbs) ? { abs: reportAbs, rel: relLink(ctx.linkBase, reportAbs) } : null,
    modelError,
  };
  if (model) {
    const active = status === "running" || status === "stalled";
    const currentId = active && cur.cursor && typeof cur.cursor === "object" ? str(cur.cursor.criterionId) : "";
    const spec = specNames.includes(run.target) ? journeysOf(readJSON(path.join(qa, "specs", run.target, "journeys.json"), null)) : null;
    Object.defineProperty(run, "_detail", { value: () => runDetail(dir, model, spec, currentId, run.report ? run.report.rel : ""), enumerable: false });
  }
  if (status === "running" || (status === "stalled" && ctx.nowMs - lastActivityMs < ACTIVE_STALL_WINDOW_MS)) {
    const loc = cur.cursor && typeof cur.cursor === "object" ? cur.cursor : {};
    const logged = (journal || []).filter((e) => e.event === "bug_logged").map((e) => ({
      id: str(e.bugId), title: str(e.title), severity: str(e.severity), layer: str(e.suspectedLayer) }));
    const fromLog = bugs.map((b) => ({ id: str(b.bug_id || b.id), title: str(b.title), severity: str(b.severity), layer: str(b.suspected_layer || b.layer) }));
    const seen = new Set(), latestBugs = [];
    for (const b of fromLog.concat(logged).reverse()) { const k = b.id || b.title; if (seen.has(k)) continue; seen.add(k); latestBugs.push(b); }
    run.active = {
      phase: str(cur.phase), criterion: str(loc.criterionId), persona: str(loc.personaId || loc.scenarioId), subState: str(loc.subState),
      events: (journal || []).slice(-10).reverse().map((e) => ({ t: str(e.t), text: describeEvent(e), event: str(e.event),
        criterionId: str(e.criterionId || (e.key ? str(e.key).split(":").pop() : "")), persona: str(e.personaId || e.scenarioId),
        verdict: str(e.verdict), confidence: str(e.confidence), title: str(e.title), phase: str(e.phase) })),
      bugs: latestBugs.slice(0, 5),
    };
  }
  return run;
}

function knownDefectsInfo(qa, nowMs) {
  const reg = path.join(qa, "known-defects.json");
  if (!exists(reg)) return { present: false };
  const raw = readJSON(reg, null);
  const entries = Array.isArray(raw) ? raw.filter((e) => e && typeof e === "object") : [];
  const today = new Date(nowMs).toISOString().slice(0, 10);
  const script = path.join(__dirname, "known-defects.sh");
  let states = null, error = "", valid = true;
  try {
    states = JSON.parse(execFileSync("bash", [script, "status", reg, today], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  } catch (e) { error = "known-defects.sh status failed" + (e.stderr ? ": " + String(e.stderr).split("\n")[0] : ""); }
  try { execFileSync("bash", [script, "validate", reg, today], { stdio: ["ignore", "ignore", "ignore"] }); } catch (_) { valid = false; }
  const byId = {};
  for (const s of Array.isArray(states) ? states : []) if (s && typeof s === "object") byId[str(s.id)] = str(s.state);
  const list = entries.map((e) => ({ id: str(e.id), title: str(e.title), ticket: str(e.ticket), expiry: str(e.expiry),
    severity: str(e.severity), surface: str(e.surface), state: byId[str(e.id)] || "unknown" }));
  const counts = { outstanding: 0, expired: 0, cleared: 0 };
  for (const e of list) if (counts[e.state] !== undefined) counts[e.state] += 1;
  return { present: true, valid, error, entries: list, counts };
}

function buildDashboard(opts) {
  const project = path.resolve(opts.project || ".");
  const qa = path.join(project, ".qa");
  if (!fs.existsSync(qa)) die("no .qa directory in " + project);
  AUTH_DIR = path.join(qa, "auth");
  const nowMs = opts.nowMs;
  const ctx = { nowMs, stallMs: opts.stallMinutes * 60000, linkBase: opts.linkBase || project };
  const config = readJSON(path.join(qa, "config.json"), null);
  const constitution = constitutionInfo(qa);
  const specNames = listDirs(path.join(qa, "specs"));
  const specs = specNames.map((t) => specInfo(qa, t, constitution.version));
  const runIds = listDirs(path.join(qa, "runs")).filter((id) => ["checkpoint.json", "cursor.json", "run-manifest.json"].some((f) => exists(path.join(qa, "runs", id, f))));
  const runs = runIds.map((id) => runInfo(qa, id, specNames, ctx))
    .sort((a, b) => (b.started || "").localeCompare(a.started || "") || b.id.localeCompare(a.id));

  for (const s of specs) {
    const mine = runs.filter((r) => r.target === s.target);
    s.runs = mine.length;
    s.latestRun = mine.length ? { id: mine[0].id, status: mine[0].status } : null;
    if (!s.coverage) {
      for (const r of mine) {
        const cov = coverageOf(readJSON(path.join(qa, "runs", r.id, "coverage.json"), null));
        if (cov) { s.coverage = Object.assign({ from: r.id }, cov); break; }
      }
    }
  }

  const trends = [];
  const targets = [...new Set(runs.map((r) => r.target))];
  for (const t of targets) {
    const pts = runs.filter((r) => r.target === t && r.tally).slice().reverse()
      .map((r) => ({ runId: r.id, started: r.started, pass: r.tally.pass, fail: r.tally.fail + r.tally.error, blocked: r.tally.blocked, bugs: r.bugs.total }));
    if (pts.length >= 2) trends.push({ target: t, points: pts });
  }

  // One entry per target: its latest run, in people's terms. Targets with an
  // active run come first, then the most recently started.
  const features = [];
  for (const tg of targets) {
    const mine = runs.filter((r) => r.target === tg);
    const latest = mine.find((r) => r.active) || mine[0];
    const detail = latest && latest._detail ? latest._detail() : { journeys: [], bugs: [] };
    features.push({
      target: tg, title: humanize(tg), runId: latest.id, status: latest.status, started: latest.started,
      active: !!latest.active, runs: mine.length, readiness: readinessOf(latest, detail), journeys: detail.journeys, bugs: detail.bugs,
    });
  }
  features.sort((a, b) => (b.active ? 1 : 0) - (a.active ? 1 : 0) || (b.started || "").localeCompare(a.started || ""));

  const model = {
    schema: "qa-dashboard/1", generatedAt: new Date(nowMs).toISOString(), project: { name: path.basename(project), dir: project },
    plugin: pluginInfo(), stallMinutes: opts.stallMinutes, constitution, config: configInfo(config), specs, runs,
    active: runs.filter((r) => r.active).map((r) => r.id), features, trends, knownDefects: knownDefectsInfo(qa, nowMs),
  };
  return makeRedactor(config)(model);
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------
function esc(v) {
  return str(v).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
function t(v) { return '<span dir="auto">' + esc(v) + "</span>"; }
function badge(status) { return '<span class="st st-' + esc(status) + '">' + esc(status) + "</span>"; }
function sevText(bySeverity) {
  const keys = SEVERITIES.concat(["unrated"]).filter((k) => bySeverity[k]);
  return keys.length ? keys.map((k) => bySeverity[k] + " " + k).join(" · ") : "none";
}
function progText(r) {
  const p = r.progress;
  if (!Number.isFinite(p.done) || !Number.isFinite(p.total)) return "—";
  return p.done + "/" + p.total + (p.percent !== null ? " (" + p.percent + "%)" : "");
}
function tallyText(r) {
  if (!r.tally) return "—";
  return VERDICTS.map((v) => r.tally[v] + " " + v).join(" · ") + (r.lowPasses ? " · " + r.lowPasses + " low-conf pass" : "");
}

function svgTrend(tr) {
  const w = 22, gap = 8, h = 90;
  const max = Math.max(1, ...tr.points.map((p) => p.pass + p.fail + p.blocked), ...tr.points.map((p) => p.bugs));
  const scale = (v) => Math.round((v / max) * (h - 14));
  const width = tr.points.length * (w + gap) + gap;
  const bars = tr.points.map((p, i) => {
    const x = gap + i * (w + gap);
    let y = h;
    const seg = (v, cls) => { const hh = scale(v); y -= hh; return hh ? '<rect class="' + cls + '" x="' + x + '" y="' + y + '" width="' + (w - 6) + '" height="' + hh + '"></rect>' : ""; };
    const bugH = scale(p.bugs);
    return "<g><title>" + esc(p.runId + " — pass " + p.pass + ", fail " + p.fail + ", blocked " + p.blocked + ", bugs " + p.bugs) + "</title>"
      + seg(p.pass, "b-pass") + seg(p.fail, "b-fail") + seg(p.blocked, "b-blocked")
      + (bugH ? '<rect class="b-bugs" x="' + (x + w - 5) + '" y="' + (h - bugH) + '" width="4" height="' + bugH + '"></rect>' : "") + "</g>";
  }).join("");
  return '<svg class="trend" role="img" aria-label="' + esc("Trend for " + tr.target) + '" viewBox="0 0 ' + width + " " + h + '" width="' + width + '" height="' + h + '">'
    + '<line class="axis" x1="0" y1="' + h + '" x2="' + width + '" y2="' + h + '"></line>' + bars + "</svg>";
}

// Design: an app console. A sidebar of test targets and project records; per
// target a top bar with the readiness pill, a hero whose run dial draws every
// check of the run as one tick (grouped by journey, coloured by verdict, the
// running one pulsing), a single stat rail, journey cards that repeat the
// dial in miniature, and a bug list. Cards and bugs open a side panel. Works
// without JavaScript: views stack, cards and bugs expand in place.
const CSS = `
:root{color-scheme:light dark;
--bg:#f3f5fa;--side:#e9edf5;--panel:#ffffff;--raised:#f7f9fc;--line:#dfe4ee;--line2:#c9d1df;--ink:#111a2c;--muted:#5b667c;--faint:#8a94a8;
--accent:#4b5cf0;--accent-soft:#e6e9ff;--pass:#18a058;--fail:#e5484d;--blocked:#d9930d;--deferred:#8a94a8;--error:#9b5de5;--pending:#cfd6e3;
--pass-soft:#e3f5ea;--fail-soft:#fde8e8;--blocked-soft:#fdf1dc;--shadow:0 1px 2px rgba(17,26,44,.06),0 8px 24px -12px rgba(17,26,44,.18);
--ui:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI Variable Text","Segoe UI",system-ui,"Geeza Pro","Noto Sans Arabic",Tahoma,sans-serif;
--num:"Avenir Next Condensed","Bahnschrift SemiCondensed","Bahnschrift","Roboto Condensed","Arial Narrow",var(--ui);
--code:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{
--bg:#0f1522;--side:#0c111c;--panel:#151c2b;--raised:#1b2436;--line:#232d42;--line2:#33405b;--ink:#e9edf5;--muted:#9aa4ba;--faint:#6c7790;
--accent:#8692ff;--accent-soft:#232a52;--pass:#3ccf8e;--fail:#ff5d6c;--blocked:#f5b544;--deferred:#7a859c;--error:#c48cff;--pending:#2c364d;
--pass-soft:#12301f;--fail-soft:#3a1820;--blocked-soft:#352812;--shadow:0 1px 0 rgba(255,255,255,.03) inset,0 12px 32px -16px rgba(0,0,0,.7)}}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 var(--ui);font-variant-numeric:tabular-nums;overflow-wrap:break-word}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
code,.code{font-family:var(--code);font-size:.86em;overflow-wrap:anywhere}
button{font:inherit;color:inherit}
[hidden]{display:none!important}
.app{display:grid;grid-template-columns:252px minmax(0,1fr);min-height:100vh}
.side{background:var(--side);border-inline-end:1px solid var(--line);padding:18px 12px;position:sticky;top:0;height:100vh;overflow-y:auto;display:flex;flex-direction:column;gap:18px}
.brand{display:flex;align-items:center;gap:10px;padding:2px 8px}
.brand svg{flex:none}
.brand b{display:block;font-size:.95rem;letter-spacing:-.01em}
.brand span{display:block;color:var(--muted);font-size:.8rem}
.nav h2{font-size:.75rem;font-weight:600;color:var(--faint);margin:0 8px 6px}
.nav a{display:grid;grid-template-columns:auto minmax(0,1fr) auto;align-items:center;gap:10px;padding:7px 8px;border-radius:8px;color:var(--ink);text-decoration:none}
.nav a:hover{background:var(--raised)}
.nav a[aria-current="true"]{background:var(--panel);box-shadow:var(--shadow)}
.nav a small{color:var(--muted);font-size:.78rem}
.nav .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dot{width:8px;height:8px;border-radius:50%;background:var(--deferred)}
.dot.s-running{background:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}.dot.s-good{background:var(--pass)}.dot.s-bad{background:var(--fail)}.dot.s-warn{background:var(--blocked)}
.side-foot{margin-top:auto;padding:10px 8px 0;border-top:1px solid var(--line);color:var(--muted);font-size:.8rem}
.side-foot b{color:var(--ink);font-weight:600}
.main{min-width:0;padding:0 32px 64px}
.top{display:flex;flex-wrap:wrap;align-items:center;gap:8px 16px;padding:20px 0 18px;border-bottom:1px solid var(--line)}
.crumb{color:var(--muted);font-size:.85rem;width:100%}
.top h1{margin:0;font:600 1.6rem/1.15 var(--ui);letter-spacing:-.02em}
.pill{display:inline-flex;align-items:center;gap:7px;border-radius:999px;padding:3px 11px 3px 9px;font-size:.82rem;font-weight:600;background:var(--raised);border:1px solid var(--line)}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.pill.l-progress{color:var(--accent);background:var(--accent-soft);border-color:transparent}
.pill.l-good{color:var(--pass);background:var(--pass-soft);border-color:transparent}
.pill.l-bad{color:var(--fail);background:var(--fail-soft);border-color:transparent}
.pill.l-warn{color:var(--blocked);background:var(--blocked-soft);border-color:transparent}
.pill.live::before{animation:beat 1.6s ease-in-out infinite}
@keyframes beat{50%{opacity:.35}}
.top .acts{margin-inline-start:auto;display:flex;gap:8px}
.btn{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--line2);background:var(--panel);border-radius:8px;padding:6px 12px;font-size:.85rem;font-weight:500;color:var(--ink);cursor:pointer;text-decoration:none}
.btn:hover{border-color:var(--accent);text-decoration:none}
.stale{margin:16px 0 0;padding:10px 14px;border-radius:10px;background:var(--blocked-soft);font-size:.88rem}
.hero{display:grid;grid-template-columns:minmax(0,1fr);gap:20px;margin-top:22px}
@media (min-width:1100px){.hero{grid-template-columns:auto minmax(0,1fr) minmax(280px,360px)}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow)}
.dialwrap{padding:18px 22px;display:grid;place-items:center;position:relative;min-width:272px}
.dial{display:block;width:232px;height:232px}
.dial .tk{stroke-linecap:round}
.v-pass{stroke:var(--pass);color:var(--pass)}.v-fail{stroke:var(--fail);color:var(--fail)}.v-error{stroke:var(--error);color:var(--error)}
.v-blocked{stroke:var(--blocked);color:var(--blocked)}.v-deferred{stroke:var(--deferred);color:var(--deferred)}.v-pending{stroke:var(--pending);color:var(--faint)}
.tk.low{stroke-opacity:.5}
.mini .tk.now{stroke:var(--accent)}
.tk.now{stroke:var(--accent);animation:beat 1.4s ease-in-out infinite}
.dialc{position:absolute;inset:0;display:grid;place-content:center;text-align:center;pointer-events:none}
.dialc b{font:600 3rem/1 var(--num);letter-spacing:-.02em}
.dialc span{color:var(--muted);font-size:.82rem}
.state{padding:20px 22px;display:flex;flex-direction:column;gap:10px}
.state h2{margin:0;font:600 1.3rem/1.3 var(--ui);letter-spacing:-.015em;max-width:40ch}
.state p{margin:0;color:var(--muted)}
.state .facts{color:var(--ink);font-size:.98rem;max-width:62ch}
.hot small,.now-box small{display:block;color:var(--faint);font-size:.76rem;margin-bottom:4px}
.hot ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column}
.hot li{display:flex;justify-content:space-between;gap:12px;padding:6px 0;border-bottom:1px solid var(--line);font-size:.9rem}
.hot li:last-child{border-bottom:0}
.hot li a{min-width:0}
.hot li>span{color:var(--fail);font-size:.82rem;white-space:nowrap;flex:none}
.now-box{margin-top:auto;padding:12px 14px;border-radius:10px;background:var(--raised);border:1px solid var(--line)}
.now-box small{display:block;color:var(--faint);font-size:.76rem}
.now-box a{font-weight:600}
.warnbox{padding:10px 14px;border-radius:10px;background:var(--blocked-soft);color:var(--ink)!important;font-size:.88rem}
.feed{padding:16px 18px;display:flex;flex-direction:column;min-width:0}
.feed h3,.sechead h3{margin:0;font-size:.95rem;font-weight:600}
.feed ol{list-style:none;margin:10px 0 0;padding:0;display:flex;flex-direction:column;gap:2px}
.feed li{display:grid;grid-template-columns:3.2em minmax(0,1fr);gap:10px;padding:5px 0;font-size:.85rem;color:var(--muted);border-bottom:1px dashed var(--line)}
.feed li:last-child{border-bottom:0}
.feed li:first-child{color:var(--ink)}
.feed time{color:var(--faint)}
.rail{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));margin-top:20px}
.rail>div{padding:14px 20px;border-inline-start:1px solid var(--line)}
.rail>div:first-child{border-inline-start:0}
.rail small{display:block;color:var(--muted);font-size:.8rem}
.rail b{display:block;font:600 2.1rem/1.1 var(--num);letter-spacing:-.01em;margin-top:2px}
.rail em{font-style:normal;color:var(--faint);font-size:.8rem}
.rail .r-pass b{color:var(--pass)}.rail .r-fail b{color:var(--fail)}.rail .r-bugs b{color:var(--ink)}
.bar{display:flex;height:6px;border-radius:3px;overflow:hidden;background:var(--pending);margin-top:10px}
.bar i{display:block;height:100%}
.bar .b-pass{background:var(--pass)}.bar .b-fail{background:var(--fail)}.bar .b-error{background:var(--error)}.bar .b-blocked{background:var(--blocked)}.bar .b-deferred{background:var(--deferred)}
.sechead{display:flex;flex-wrap:wrap;align-items:center;gap:10px 16px;margin:34px 0 12px}
.sechead p{margin:0;color:var(--muted);font-size:.85rem}
.seg{display:inline-flex;flex-wrap:wrap;background:var(--raised);border:1px solid var(--line);border-radius:9px;padding:2px;gap:2px;margin-inline-start:auto}
.seg button{border:0;background:transparent;padding:5px 11px;border-radius:7px;font-size:.82rem;cursor:pointer;color:var(--muted)}
.seg button[aria-pressed="true"]{background:var(--panel);color:var(--ink);box-shadow:var(--shadow)}
.seg button span{margin-inline-start:5px;color:var(--faint)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px}
details.jc{background:var(--panel);border:1px solid var(--line);border-radius:14px;transition:border-color .15s}
details.jc:hover{border-color:var(--line2)}
details.jc>summary{list-style:none;cursor:pointer;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 12px;padding:14px 16px;align-items:center}
details.jc>summary::-webkit-details-marker{display:none}
.jc .jid{color:var(--faint);font-size:.76rem;font-weight:600}
.jc .jn{font-weight:600;line-height:1.3;margin-top:2px}
.jc .js{font-size:.82rem;margin-top:6px;color:var(--muted)}
.jc .js.t-bad{color:var(--fail);font-weight:600}.jc .js.t-warn{color:var(--blocked);font-weight:600}.jc .js.t-good{color:var(--pass)}
.mini{position:relative;width:58px;height:58px;grid-row:span 3;align-self:center}
.mini svg{width:58px;height:58px;display:block}
.mini b{position:absolute;inset:0;display:grid;place-content:center;font:600 .95rem/1 var(--num)}
.jc.p1{border-top:3px solid var(--accent)}
.jc .detail{padding:0 16px 14px}
ol.checks{list-style:none;margin:0;padding:0;counter-reset:ck}
ol.checks>li{counter-increment:ck;display:grid;grid-template-columns:1.8em minmax(0,1fr);gap:2px 10px;padding:10px 8px;border-radius:10px}
ol.checks>li+li{border-top:1px solid var(--line)}
ol.checks>li::before{content:counter(ck);color:var(--faint);font-size:.8rem;text-align:end;padding-top:2px}
ol.checks>li.v-fail,ol.checks>li.v-error{background:var(--fail-soft);border-top-color:transparent}
ol.checks>li.v-blocked{background:var(--blocked-soft)}
ol.checks>li.now{box-shadow:inset 0 0 0 2px var(--accent)}
.ckh{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 10px}
.ckn{font-weight:600}
.vl{font-size:.76rem;font-weight:600;display:inline-flex;align-items:center;gap:5px}
.vl::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.vl.v-pending::before,.vl.v-deferred::before{background:transparent;box-shadow:inset 0 0 0 1.5px currentColor}
.ckm{font-size:.8rem;color:var(--muted);grid-column:2}
.ckm>*+*::before{content:"";display:inline-block;width:3px;height:3px;border-radius:50%;background:var(--faint);margin:0 8px;vertical-align:middle}
.ckt{font-size:.85rem;color:var(--muted);grid-column:2;margin:3px 0 0;overflow-wrap:anywhere}
.flash{animation:flash 1.6s ease-out}
@keyframes flash{0%{background:var(--accent-soft)}100%{background:transparent}}
.tools{display:flex;flex-wrap:wrap;gap:8px 10px;align-items:center;margin:0 0 10px}
.tools input,.tools select{font:inherit;font-size:.85rem;background:var(--panel);color:var(--ink);border:1px solid var(--line2);border-radius:8px;padding:6px 10px;min-width:0}
.tools input{flex:1 1 220px;max-width:340px}
.tools .seg{margin-inline-start:0}
.shown{font-size:.82rem;color:var(--muted)}
.linkbtn{background:none;border:0;color:var(--accent);cursor:pointer;padding:0;text-decoration:underline}
.bugs-list{overflow:hidden}
details.bug+details.bug{border-top:1px solid var(--line)}
details.bug>summary{list-style:none;cursor:pointer;display:grid;grid-template-columns:86px minmax(0,1fr) minmax(0,220px);gap:4px 16px;padding:12px 16px;align-items:center}
details.bug>summary::-webkit-details-marker{display:none}
details.bug>summary:hover{background:var(--raised)}
.sev{display:inline-flex;justify-self:start;align-items:center;gap:6px;font-size:.76rem;font-weight:650;padding:2px 9px;border-radius:999px;background:var(--raised);color:var(--muted)}
.sev-critical,.sev-high{background:var(--fail-soft);color:var(--fail)}.sev-medium{background:var(--blocked-soft);color:var(--blocked)}
.bt{font-weight:600;line-height:1.35}
.bw{font-size:.8rem;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
@media (max-width:760px){details.bug>summary{grid-template-columns:minmax(0,1fr)}.bw{white-space:normal}}
.bd{padding:2px 16px 16px}
.bd dl{display:grid;gap:14px;margin:0}
.bd dt{font-size:.78rem;font-weight:600;color:var(--muted)}
.bd dd{margin:3px 0 0;overflow-wrap:anywhere}
.bd .meta{margin:14px 0 0;font-size:.82rem;color:var(--muted)}
.empty{padding:18px;color:var(--muted);margin:0}
.view+.view{margin-top:56px}
.js .view{display:none}.js .view.on{display:block}.js .view+.view{margin-top:0}
.tablewrap{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:.84rem}
th,td{text-align:start;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:.78rem;white-space:nowrap;background:var(--raised)}
tr:last-child td{border-bottom:0}
.st{display:inline-block;border-radius:999px;padding:1px 9px;font-size:.76rem;font-weight:600;background:var(--raised);color:var(--muted);white-space:nowrap}
.st-running{background:var(--accent-soft);color:var(--accent)}.st-stalled,.st-outstanding{background:var(--blocked-soft);color:var(--blocked)}.st-complete,.st-OK,.st-SHIP-READY,.st-cleared{background:var(--pass-soft);color:var(--pass)}
.st-BLOCKED,.st-NOT-SHIP-READY,.st-expired{background:var(--fail-soft);color:var(--fail)}
.pbar{height:4px;background:var(--pending);border-radius:2px;overflow:hidden;min-width:80px;margin-top:5px}.pbar i{display:block;height:100%;background:var(--accent)}
.muted{color:var(--muted)}
.trends{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
.trends .card{padding:14px 16px}
.trends h3{margin:0 0 6px;font-size:.9rem}
svg.trend{max-width:100%;height:auto;display:block}
svg .b-pass{fill:var(--pass)}svg .b-fail{fill:var(--fail)}svg .b-blocked{fill:var(--blocked)}svg .b-bugs{fill:var(--error)}svg .axis{stroke:var(--line)}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;margin:8px 0 0;padding:0;list-style:none;font-size:.78rem;color:var(--muted)}
.legend i{display:inline-block;width:9px;height:9px;border-radius:2px;margin-inline-end:5px;vertical-align:-1px}
.setup{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 22px;margin:0;padding:18px 20px}
.setup dt{color:var(--muted)}.setup dd{margin:0}
.warn{background:var(--fail-soft);border-radius:10px;padding:10px 14px;margin:0 0 12px;font-weight:600}
.scrim{position:fixed;inset:0;background:rgba(8,12,20,.45);z-index:20}
.sheet{position:fixed;inset-block:0;inset-inline-end:0;width:min(600px,100vw);background:var(--panel);border-inline-start:1px solid var(--line);box-shadow:-24px 0 48px -24px rgba(0,0,0,.45);z-index:21;display:flex;flex-direction:column;animation:slide .18s ease-out}
@keyframes slide{from{transform:translateX(24px);opacity:0}}
[dir=rtl] .sheet{animation-name:none}
.sheet header{display:flex;align-items:flex-start;gap:12px;padding:18px 20px;border-bottom:1px solid var(--line)}
.sheet header h2{margin:0;font-size:1.1rem;line-height:1.3;flex:1}
.sheet .sheet-body{overflow-y:auto;padding:16px 20px 28px}
.sheet .detail,.sheet .bd{padding:0}
footer{margin-top:48px;color:var(--faint);font-size:.78rem}
@media (max-width:900px){.app{grid-template-columns:minmax(0,1fr)}.side{position:static;height:auto;border-inline-end:0;border-bottom:1px solid var(--line);padding:12px}
.side{min-width:0}.nav{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;min-width:0;max-width:100%}.nav h2,.side-foot{display:none}.nav a{white-space:nowrap;grid-template-columns:auto auto auto;flex:none}.nav .nm{overflow:visible}.brand{display:none}
.main{padding:0 16px 48px}.rail>div{border-inline-start:0;border-top:1px solid var(--line)}.rail>div:first-child{border-top:0}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
`;

const JS = `
(function(){
var D=document,B=D.body,root=D.documentElement;root.classList.add("js");
var gen=Date.parse(B.getAttribute("data-generated")),refresh=Number(B.getAttribute("data-refresh"))||0,live=B.getAttribute("data-live")==="1";
var KEY="qa-dashboard:"+location.pathname;
function store(v){try{if(v===undefined)return JSON.parse(sessionStorage.getItem(KEY)||"null");sessionStorage.setItem(KEY,JSON.stringify(v));}catch(e){return null;}}
function two(n){return(n<10?"0":"")+n;}
function clock(d){return two(d.getHours())+":"+two(d.getMinutes());}
function stamp(d){var n=new Date();return(d.toDateString()===n.toDateString()?"":d.toLocaleDateString([],{month:"short",day:"numeric"})+" ")+clock(d);}
function ago(ms){var m=Math.round(ms/60000);if(m<1)return"just now";if(m<60)return m+" min ago";var h=Math.floor(m/60);if(h<48)return h+" h "+(m%60?m%60+" min ":"")+"ago";return Math.round(h/24)+" days ago";}
function each(sel,fn,ctx){[].forEach.call((ctx||D).querySelectorAll(sel),fn);}
each("time[data-t]",function(el){var d=new Date(el.getAttribute("datetime"));if(!isNaN(d))el.textContent=el.getAttribute("data-t")==="clock"?clock(d):stamp(d);});
var agoEl=D.getElementById("ago"),staleEl=D.getElementById("stale");
function tick(){var age=Date.now()-gen;if(agoEl)agoEl.textContent=ago(age);if(staleEl){var limit=refresh?refresh*3000+30000:3600000;staleEl.hidden=!(live&&age>limit);}}
tick();setInterval(tick,30000);
var st=store()||{},filt=st.filt||{};
var views=D.querySelectorAll(".view"),first=views[0]&&views[0].id;
function route(){var id=decodeURIComponent(location.hash.slice(1)),v=id&&D.getElementById(id);
if(!v||!v.classList.contains("view")){var inner=v&&v.closest&&v.closest(".view");v=inner||D.getElementById(st.view)||D.getElementById(first);}
if(!v)return;each(".view",function(x){x.classList.toggle("on",x===v);});
each(".nav a",function(a){a.setAttribute("aria-current",String(a.getAttribute("href")==="#"+v.id));});st.view=v.id;}
window.addEventListener("hashchange",function(){route();window.scrollTo(0,0);});route();
each(".bugs[data-key]",function(box){var k=box.getAttribute("data-key"),f=filt[k]||(filt[k]={sev:"all",q:"",j:""});
var bar=box.querySelector(".tools"),btns=box.querySelectorAll("button[data-sev]"),q=box.querySelector("input[type=search]"),sel=box.querySelector("select"),items=box.querySelectorAll("details.bug"),empty=box.querySelector(".empty"),shown=box.querySelector(".shown");
if(bar)bar.hidden=false;
function apply(){var n=0;[].forEach.call(items,function(it){var ok=(f.sev==="all"||it.getAttribute("data-sev")===f.sev)&&(!f.j||it.getAttribute("data-j")===f.j)&&(!f.q||it.getAttribute("data-text").indexOf(f.q.toLowerCase())>=0);it.hidden=!ok;if(ok)n++;});
[].forEach.call(btns,function(b){b.setAttribute("aria-pressed",String(b.getAttribute("data-sev")===f.sev));});if(empty)empty.hidden=n>0;if(shown)shown.textContent=n===items.length?"":n+" of "+items.length+" shown";}
[].forEach.call(btns,function(b){b.addEventListener("click",function(){f.sev=b.getAttribute("data-sev");apply();});});
if(q){q.value=f.q;q.addEventListener("input",function(){f.q=q.value.trim();apply();});}
if(sel){sel.value=f.j;sel.addEventListener("change",function(){f.j=sel.value;apply();});}
each("[data-clear]",function(c){c.addEventListener("click",function(){f.sev="all";f.q="";f.j="";if(q)q.value="";if(sel)sel.value="";apply();});},box);apply();});
each(".grid[data-key]",function(g){var k=g.getAttribute("data-key"),f=filt[k]||(filt[k]={jf:"all"}),btns=D.querySelectorAll("button[data-jf][data-for='"+k+"']");
function apply(){each("details.jc",function(c){c.hidden=!(f.jf==="all"||(f.jf==="main"&&c.classList.contains("p1"))||(f.jf==="bad"&&c.getAttribute("data-bad")==="1"));},g);[].forEach.call(btns,function(b){b.setAttribute("aria-pressed",String(b.getAttribute("data-jf")===f.jf));});}
[].forEach.call(btns,function(b){b.hidden=false;b.parentNode.hidden=false;b.addEventListener("click",function(){f.jf=b.getAttribute("data-jf");apply();});});apply();});
var scrim=D.getElementById("scrim"),sheet=D.getElementById("sheet"),sTitle=D.getElementById("sheet-title"),sBody=D.getElementById("sheet-body"),opener=null;
function openSheet(det,focusId){var body=det.querySelector(".detail,.bd");if(!body)return;opener=det;sTitle.textContent=det.getAttribute("data-title")||"";
sBody.innerHTML=body.innerHTML;scrim.hidden=false;sheet.hidden=false;st.sheet=det.id;D.getElementById("sheet-close").focus();
if(focusId){var el=sBody.querySelector("[data-ck='"+focusId+"']");if(el){el.scrollIntoView({block:"center"});el.classList.add("flash");}}}
function closeSheet(){scrim.hidden=true;sheet.hidden=true;st.sheet="";if(opener){var s=opener.querySelector("summary");if(s)s.focus();}}
D.addEventListener("click",function(e){var t=e.target;if(!t.closest)return;
var sum=t.closest("details.jc>summary,details.bug>summary");if(sum){e.preventDefault();openSheet(sum.parentNode);return;}
if(t.closest("#sheet-close")||t===scrim){closeSheet();return;}
var a=t.closest("a[href^='#']");if(a){var id=decodeURIComponent(a.getAttribute("href").slice(1)),el=D.getElementById(id);
if(el&&el.matches("details.jc,details.bug")){e.preventDefault();var v=el.closest(".view");if(v&&!v.classList.contains("on")){location.hash=v.id;}openSheet(el);return;}
var ck=D.querySelector("[data-ck='"+id+"']");if(ck){e.preventDefault();var jc=ck.closest("details.jc");if(jc)openSheet(jc,id);}}});
D.addEventListener("keydown",function(e){if(e.key==="Escape"&&!sheet.hidden){closeSheet();return;}
if(e.key==="/"&&!/INPUT|SELECT|TEXTAREA/.test(D.activeElement.tagName)){var s=D.querySelector(".view.on .bugs input[type=search]");if(s){e.preventDefault();s.focus();}}});
if(st.sheet){var d=D.getElementById(st.sheet);if(d)openSheet(d);}
function save(){st.y=window.scrollY;st.filt=filt;store(st);}
window.addEventListener("pagehide",save);
if(st.y)window.scrollTo(0,st.y);
if(refresh){var reload=function(){var a=D.activeElement;if(a&&/INPUT|SELECT/.test(a.tagName)){setTimeout(reload,5000);return;}save();location.reload();};setTimeout(reload,refresh*1000);}
})();
`;

const VERDICT_LABEL = { pass: "Passed", fail: "Failed", error: "Error", blocked: "Blocked", deferred: "Deferred", pending: "Not run yet" };
const TALLY_ORDER = ["pass", "fail", "error", "blocked", "deferred", "pending"];

function utcText(iso) { return iso ? str(iso).slice(0, 16).replace("T", " ") + " UTC" : ""; }
function timeTag(iso, kind) { return iso ? '<time datetime="' + esc(iso) + '" data-t="' + (kind || "stamp") + '">' + esc(utcText(iso)) + "</time>" : ""; }
function slug(s) { return str(s).toLowerCase().replace(/[^a-z0-9؀-ۿ]+/g, "-").replace(/^-+|-+$/g, "") || "x"; }

// Activity in people's words; falls back to the engine's own line.
function eventText(e) {
  const name = e.criterionId ? humanize(e.criterionId) : "";
  const as = e.persona ? ", as " + e.persona : "";
  switch (e.event) {
    case "criterion_started": return "Started " + name + as;
    case "criterion_verdict": return (VERDICT_LABEL[e.verdict] || e.verdict || "Verdict") + ": " + name + as + (e.confidence === "low" ? " (low confidence)" : "");
    case "act_intent": return "Acting on " + name;
    case "act_committed": return "Saved the action for " + name;
    case "bug_logged": return "Logged a bug: " + (e.title || "untitled");
    case "phase_entered": return "Entered the " + (e.phase || "next") + " phase";
    default: return e.text;
  }
}

function journeySummary(j) {
  const c = j.counts, n = j.checks.length, parts = [];
  const bad = c.fail + c.error;
  if (bad) parts.push(bad + " failed");
  if (c.blocked) parts.push(c.blocked + " blocked");
  if (c.deferred) parts.push(c.deferred + " deferred");
  if (c.pending) parts.push(c.pending + " to go");
  if (!parts.length) return { text: n === 1 ? "Passed" : "All " + n + " passed", tone: "good" };
  return { text: parts.join(", "), tone: bad ? "bad" : (c.blocked ? "warn" : "") };
}

// One radial tick per check. groups: [[{verdict, low, now, title}]]; a gap
// of two tick slots separates groups when there is more than one.
function dialSvg(groups, size, inner, outer, label, cls) {
  const n = groups.reduce((a, g) => a + g.length, 0);
  if (!n) return "";
  const gap = groups.length > 1 ? 2 : 0;
  const slots = n + gap * groups.length;
  const c = size / 2, circ = 2 * Math.PI * ((inner + outer) / 2);
  const width = Math.max(1.2, Math.min(7, (circ / slots) * 0.62));
  let i = 0, out = "";
  for (const g of groups) {
    for (const k of g) {
      const a = (-90 + ((i + 0.5) / slots) * 360) * Math.PI / 180;
      const ro = k.now ? outer + 5 : outer;
      const p = (r) => (c + r * Math.cos(a)).toFixed(2) + " " + (c + r * Math.sin(a)).toFixed(2);
      out += '<path class="tk v-' + esc(k.verdict) + (k.low ? " low" : "") + (k.now ? " now" : "") + '" d="M' + p(inner) + "L" + p(ro) + '" stroke-width="' + width.toFixed(2) + '">'
        + (k.title ? "<title>" + esc(k.title) + "</title>" : "") + "</path>";
      i++;
    }
    i += gap;
  }
  return '<svg class="' + (cls || "dial") + '" viewBox="0 0 ' + size + " " + size + '" role="img" aria-label="' + esc(label) + '">' + out + "</svg>";
}

// A segmented ring: one arc per check with a hairline gap, for the small
// journey rings where radial ticks would read as scattered dashes.
function ringSvg(checks, size, r, w, label) {
  const n = checks.length;
  if (!n) return "";
  const c = size / 2, gapDeg = n > 1 ? Math.min(6, 120 / n) : 0;
  const pt = (deg) => { const a = (deg - 90) * Math.PI / 180; return (c + r * Math.cos(a)).toFixed(2) + " " + (c + r * Math.sin(a)).toFixed(2); };
  let out = '<circle cx="' + c + '" cy="' + c + '" r="' + r + '" fill="none" stroke="var(--pending)" stroke-width="' + w + '" opacity=".35"/>';
  checks.forEach((k, i) => {
    const a0 = (i / n) * 360 + gapDeg / 2, a1 = ((i + 1) / n) * 360 - gapDeg / 2;
    if (n === 1) { out += '<circle class="tk v-' + esc(k.verdict) + '" cx="' + c + '" cy="' + c + '" r="' + r + '" fill="none" stroke-width="' + w + '"/>'; return; }
    out += '<path class="tk v-' + esc(k.verdict) + (k.low ? " low" : "") + (k.now ? " now" : "") + '" d="M' + pt(a0) + " A" + r + " " + r + " 0 " + (a1 - a0 > 180 ? 1 : 0) + " 1 " + pt(a1)
      + '" fill="none" stroke-width="' + w + '" stroke-linecap="butt"><title>' + esc(k.title) + "</title></path>";
  });
  return '<svg viewBox="0 0 ' + size + " " + size + '" role="img" aria-label="' + esc(label) + '">' + out + "</svg>";
}

function tick(k) { return { verdict: k.verdict, low: k.lowConfidence, now: k.current, title: k.name + ": " + (k.current ? "running now" : VERDICT_LABEL[k.verdict]) }; }

function checkList(f, j) {
  return '<ol class="checks">' + j.checks.map((k, i) => {
    const id = "ck-" + slug(f.target) + "-" + slug(j.id) + "-" + i;
    const meta = [k.role ? "<span>as " + t(k.role) + "</span>" : "", k.lowConfidence ? "<span>low confidence</span>" : "",
      k.bugs.length ? "<span>" + k.bugs.map((b) => '<a href="#bug-' + esc(slug(f.target) + "-" + slug(b)) + '">bug ' + esc(b) + "</a>").join(", ") + "</span>" : "",
      k.link ? '<span><a href="' + esc(k.link) + '">evidence</a></span>' : ""].filter(Boolean).join("");
    return '<li id="' + esc(id) + '" data-ck="' + esc(id) + '" class="v-' + esc(k.verdict) + (k.current ? " now" : "") + '"><div class="ckh"><span class="ckn">' + t(k.name) + '</span><span class="vl v-' + esc(k.verdict) + '">'
      + esc(k.current ? "Running now" : VERDICT_LABEL[k.verdict] || k.verdict) + "</span></div>" + (meta ? '<div class="ckm">' + meta + "</div>" : "")
      + (k.note ? '<p class="ckt">' + t(k.note) + "</p>" : "") + "</li>";
  }).join("") + "</ol>";
}

function journeyCard(f, j) {
  const sum = journeySummary(j);
  const pct = j.checks.length ? Math.round((j.counts.pass / j.checks.length) * 100) : 0;
  const named = !/^role:|^other$/.test(j.id);
  return '<details class="jc' + (j.priority === "P1" ? " p1" : "") + '" id="j-' + esc(slug(f.target) + "-" + slug(j.id)) + '" data-title="' + esc(j.name) + '" data-bad="' + (j.counts.fail + j.counts.error ? 1 : 0) + '">'
    + '<summary><div><div class="jid">' + esc(named ? j.id : j.checks.length + " checks") + '</div><div class="jn">' + t(j.name) + '</div><div class="js' + (sum.tone ? " t-" + sum.tone : "") + '">' + esc(sum.text)
    + "</div></div>"
    + '<div class="mini">' + ringSvg(j.checks.map(tick), 58, 24, 5, j.name + ": " + sum.text) + "<b>" + pct + "</b></div></summary>"
    + '<div class="detail">' + checkList(f, j) + "</div></details>";
}

function bugsBlock(f) {
  const key = "bugs:" + f.target;
  if (!f.bugs.length) return '<div class="sechead"><h3>Bugs</h3></div><div class="card"><p class="empty">No bugs logged in this run.</p></div>';
  const sevs = ["critical", "high", "medium", "low", "unrated"].filter((s) => f.bugs.some((b) => b.severity === s));
  const journeys = [];
  for (const b of f.bugs) if (b.journey && !journeys.some((x) => x[0] === b.journey)) journeys.push([b.journey, b.journeyName]);
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  const tools = '<div class="tools" hidden><div class="seg" role="group" aria-label="Severity"><button type="button" data-sev="all" aria-pressed="true">All<span>' + f.bugs.length + "</span></button>"
    + sevs.map((s) => '<button type="button" data-sev="' + s + '" aria-pressed="false">' + cap(s) + "<span>" + f.bugs.filter((b) => b.severity === s).length + "</span></button>").join("") + "</div>"
    + (journeys.length > 1 ? '<select aria-label="Journey"><option value="">Every journey</option>' + journeys.map((x) => '<option value="' + esc(x[0]) + '">' + esc(x[1]) + "</option>").join("") + "</select>" : "")
    + '<input type="search" placeholder="Search bugs   /" aria-label="Search bugs"><span class="shown" aria-live="polite"></span></div>';
  const rows = f.bugs.map((b, i) => {
    const where = [b.journeyName, b.role ? "as " + b.role : ""].filter(Boolean).join(", ");
    return '<details class="bug" id="' + esc("bug-" + slug(f.target) + "-" + slug(b.id || "n" + i)) + '" data-title="' + esc(b.title || b.id) + '" data-sev="' + esc(b.severity) + '" data-j="' + esc(b.journey)
      + '" data-text="' + esc([b.title, b.id, b.criterionId, b.observed, b.expected, b.journeyName, b.role, b.layer].join(" ").toLowerCase()) + '">'
      + '<summary><span class="sev sev-' + esc(b.severity) + '">' + esc(cap(b.severity)) + '</span><span class="bt">' + t(b.title || b.id) + '</span><span class="bw">' + t(where) + "</span></summary>"
      + '<div class="bd"><dl>' + (b.observed ? "<div><dt>What happened</dt><dd>" + t(b.observed) + "</dd></div>" : "")
      + (b.expected ? "<div><dt>What should happen</dt><dd>" + t(b.expected) + "</dd></div>" : "")
      + (b.layer ? "<div><dt>Likely layer</dt><dd>" + t(b.layer) + "</dd></div>" : "") + "</dl>"
      + '<p class="meta">' + [b.id ? "Bug " + esc(b.id) : "", b.status ? "status " + esc(b.status) : "", b.criterionId ? "found by " + t(humanize(b.criterionId)) : "",
        b.link ? '<a href="' + esc(b.link) + '">open the evidence</a>' : ""].filter(Boolean).join(", ") + "</p></div></details>";
  }).join("");
  return '<div class="sechead"><h3>Bugs</h3><p>' + f.bugs.length + " logged, most severe first</p></div>"
    + '<div class="bugs" data-key="' + esc(key) + '">' + tools + '<div class="card bugs-list">' + rows
    + '<p class="empty" hidden>No bug matches these filters. <button type="button" class="linkbtn" data-clear>Clear filters</button></p></div></div>';
}

function targetView(m, f, run) {
  const r = f.readiness, slugT = slug(f.target);
  const liveRun = run.status === "running";
  const counts = emptyCounts();
  if (run.tally) {
    for (const v of VERDICTS) counts[v] = run.tally[v] || 0;
    const done = VERDICTS.reduce((a, v) => a + counts[v], 0);
    counts.pending = Number.isFinite(run.progress.total) ? Math.max(0, run.progress.total - done) : 0;
  }
  const total = TALLY_ORDER.reduce((a, v) => a + counts[v], 0);
  const passPct = total ? Math.round((counts.pass / total) * 100) : 0;
  const seen = new Set();
  const groups = f.journeys.map((j) => j.checks.filter((k) => !seen.has(k.id) && seen.add(k.id)).map((k) => Object.assign(tick(k), { low: false }))).filter((g) => g.length);
  const hot = f.journeys.filter((j) => j.counts.fail + j.counts.error + j.counts.blocked > 0)
    .sort((a, b) => (b.priority === "P1") - (a.priority === "P1") || (b.counts.fail + b.counts.error) - (a.counts.fail + a.counts.error)).slice(0, 5);
  const sevCount = (s) => f.bugs.filter((b) => b.severity === s).length;

  let html = '<header class="top"><div class="crumb">' + t(m.project.name) + " / test targets</div><h1>" + t(f.title) + "</h1>"
    + '<span class="pill l-' + esc(r.level) + (liveRun ? " live" : "") + '">' + esc(r.headline) + "</span>"
    + '<div class="acts">' + (run.report ? '<a class="btn" href="' + esc(run.report.rel) + '">Open run report</a>' : "") + "</div></header>";

  // hero: dial, state, feed
  const dial = groups.length ? '<div class="card dialwrap">' + dialSvg(groups, 232, 84, 108, "Every check in the run, grouped by journey: " + TALLY_ORDER.filter((v) => counts[v]).map((v) => counts[v] + " " + VERDICT_LABEL[v].toLowerCase()).join(", "))
    + '<div class="dialc"><b>' + (Number.isFinite(run.progress.percent) ? Math.floor(run.progress.percent) : passPct) + '%</b><span>' + (Number.isFinite(run.progress.done) ? run.progress.done + " of " + run.progress.total + " checked" : "checked") + "</span></div></div>" : "";
  let now = "";
  if (run.active && run.active.criterion) {
    let anchor = "";
    f.journeys.forEach((j) => j.checks.forEach((k, i) => { if (!anchor && k.id === run.active.criterion) anchor = "ck-" + slugT + "-" + slug(j.id) + "-" + i; }));
    now = '<div class="now-box"><small>Checking now</small>' + (anchor ? '<a href="#' + esc(anchor) + '">' + t(humanize(run.active.criterion)) + "</a>" : t(humanize(run.active.criterion)))
      + (run.active.persona ? " as " + t(run.active.persona) : "") + "</div>";
  }
  const state = '<div class="card state"><h2>' + esc(r.facts || r.headline) + "</h2>"
    + "<p>Latest run <code>" + t(run.id) + "</code>" + (run.started ? ", started " + timeTag(run.started) : "") + (f.runs > 1 ? ", " + f.runs + " runs in total" : "") + "</p>"
    + (run.status === "stalled" ? '<p class="warnbox">Stalled: no activity for ' + esc(fmtDuration(run.idleMinutes / 60)) + " (threshold " + m.stallMinutes + " min). Resume it with <code>/qa-resume " + t(run.id) + "</code>.</p>" : "")
    + (hot.length ? '<div class="hot"><small>Where it fails</small><ul>' + hot.map((j) => '<li><a href="#j-' + esc(slugT + "-" + slug(j.id)) + '">' + t(j.name) + "</a><span>"
      + esc([j.counts.fail + j.counts.error ? j.counts.fail + j.counts.error + " failed" : "", j.counts.blocked ? j.counts.blocked + " blocked" : ""].filter(Boolean).join(", ")) + (j.priority === "P1" ? " · main" : "") + "</span></li>").join("") + "</ul></div>" : "")
    + now + "</div>";
  const feed = run.active ? '<div class="card feed"><h3>Live activity</h3><ol>' + run.active.events.slice(0, 8).map((e) => "<li>" + timeTag(e.t, "clock") + "<span>" + t(eventText(e)) + "</span></li>").join("") + "</ol></div>" : "";
  html += '<section class="hero">' + dial + state + feed + "</section>";

  // stat rail
  const seg = (v) => counts[v] ? '<i class="b-' + v + '" style="width:' + (counts[v] / total * 100).toFixed(2) + '%"></i>' : "";
  html += '<section class="card rail">'
    + '<div class="r-pass"><small>Passed</small><b>' + counts.pass + "</b><em>" + (run.lowPasses ? run.lowPasses + " with low confidence" : "of " + total + " checks") + "</em></div>"
    + '<div class="r-fail"><small>Failed</small><b>' + (counts.fail + counts.error) + "</b><em>" + (counts.blocked ? counts.blocked + " blocked, " : "") + (counts.deferred ? counts.deferred + " deferred" : "nothing deferred") + "</em></div>"
    + '<div class="r-bugs"><small>Bugs</small><b>' + f.bugs.length + "</b><em>" + (["critical", "high", "medium"].filter(sevCount).map((s) => sevCount(s) + " " + s).join(", ") || "none above low") + "</em></div>"
    + "<div><small>" + (run.eta ? "Finishes around" : "Not run yet") + "</small><b>" + (run.eta ? timeTag(run.eta.at, "clock") : counts.pending) + "</b><em>"
    + (run.eta ? esc(fmtDuration(run.eta.hours)) + " left at " + esc(run.ratePerHour) + " an hour" : (counts.pending ? "checks left" : "every check ran")) + "</em>"
    + '<div class="bar" aria-hidden="true">' + TALLY_ORDER.filter((v) => v !== "pending").map(seg).join("") + "</div></div></section>";

  // journeys
  if (f.journeys.length) {
    const named = f.journeys.some((j) => j.priority);
    const gk = "jg:" + f.target;
    html += '<div class="sechead"><h3>' + (named ? "Journeys" : "Checks by role") + "</h3><p>" + f.journeys.length + (named ? " journeys" : " roles") + ", one tick per check</p>"
      + (named ? '<div class="seg" role="group" aria-label="Show journeys" hidden><button type="button" data-for="' + esc(gk) + '" data-jf="all" aria-pressed="true" hidden>All</button><button type="button" data-for="' + esc(gk) + '" data-jf="main" aria-pressed="false" hidden>Main</button><button type="button" data-for="' + esc(gk) + '" data-jf="bad" aria-pressed="false" hidden>With failures</button></div>' : "")
      + '</div><div class="grid" data-key="' + esc(gk) + '">' + f.journeys.map((j) => journeyCard(f, j)).join("") + "</div>";
  }
  return '<section class="view" id="t-' + esc(slugT) + '">' + html + bugsBlock(f) + "</section>";
}

function renderHtml(m, opts) {
  const runs = m.runs, byId = new Map(runs.map((r) => [r.id, r]));
  const c = m.constitution, cfg = m.config;
  const live = runs.some((r) => r.status === "running");
  const feats = m.features || [];
  const lvl = (f) => (f.readiness.level === "progress" ? "running" : f.readiness.level);
  const pctOf = (f) => { const r = byId.get(f.runId); return r && Number.isFinite(r.progress.percent) ? Math.floor(r.progress.percent) + "%" : ""; };

  const side = '<aside class="side"><div class="brand"><svg width="26" height="26" viewBox="0 0 26 26" aria-hidden="true">'
    + Array.from({ length: 12 }, (_, i) => { const a = (i / 12) * 2 * Math.PI - Math.PI / 2; return '<path d="M' + (13 + 7 * Math.cos(a)).toFixed(1) + " " + (13 + 7 * Math.sin(a)).toFixed(1) + "L" + (13 + 12 * Math.cos(a)).toFixed(1) + " " + (13 + 12 * Math.sin(a)).toFixed(1) + '" stroke="' + (i < 9 ? "var(--pass)" : i < 10 ? "var(--fail)" : "var(--pending)") + '" stroke-width="2.2" stroke-linecap="round"/>'; }).join("")
    + "</svg><div><b>QA console</b><span>" + t(m.project.name) + "</span></div></div>"
    + '<nav class="nav" aria-label="Test targets"><h2>Test targets</h2>' + (feats.length ? feats.map((f) => '<a href="#t-' + esc(slug(f.target)) + '"><span class="dot s-' + esc(lvl(f)) + '"></span><span class="nm">' + t(f.title) + "</span><small>" + esc(pctOf(f)) + "</small></a>").join("") : '<span class="muted" style="padding:0 8px">None yet</span>') + "</nav>"
    + '<nav class="nav" aria-label="Project"><h2>Project</h2><a href="#runs"><span class="dot"></span><span class="nm">Runs</span><small>' + runs.length + "</small></a>"
    + '<a href="#trends"><span class="dot"></span><span class="nm">Trends</span><small>' + m.trends.length + "</small></a>"
    + '<a href="#plans"><span class="dot"></span><span class="nm">Test plans</span><small>' + m.specs.length + "</small></a>"
    + '<a href="#defects"><span class="dot' + (m.knownDefects.present && m.knownDefects.counts.expired ? " s-bad" : "") + '"></span><span class="nm">Known defects</span><small>' + (m.knownDefects.present ? m.knownDefects.counts.outstanding : 0) + "</small></a>"
    + '<a href="#setup"><span class="dot"></span><span class="nm">Setup</span><small></small></a></nav>'
    + '<div class="side-foot">Updated <b id="ago">' + timeTag(m.generatedAt) + "</b>" + (opts.refresh ? "<br>Refreshes every " + esc(opts.refresh) + " s" : "") + "</div></aside>";

  let views = feats.map((f) => targetView(m, f, byId.get(f.runId))).join("");
  if (!feats.length) views += '<section class="view" id="t-none"><header class="top"><h1>No runs yet</h1></header><p class="muted">Start one with <code>/qa-run</code>; this console fills in as it goes.</p></section>';

  const head = (title, sub) => '<header class="top"><div class="crumb">' + t(m.project.name) + " / project</div><h1>" + esc(title) + "</h1>" + (sub ? '<span class="pill">' + esc(sub) + "</span>" : "") + "</header>";
  const runRows = runs.map((r) => {
    const pct = r.progress.percent !== null ? Math.min(100, r.progress.percent) : 0;
    return "<tr><td class=\"code\">" + t(r.id) + "</td><td>" + t(r.target) + "</td><td>" + timeTag(r.started) + "</td>"
      + "<td>" + badge(r.status) + (r.manifestStatus && r.status === "paused" ? '<div class="muted">' + t(r.manifestStatus) + "</div>" : "")
      + (r.status === "complete" && !r.closed ? '<div class="muted">not closed</div>' : "") + "</td>"
      + "<td>" + esc(progText(r)) + '<div class="pbar"><i style="width:' + pct + '%"></i></div>'
      + (r.ratePerHour !== null ? '<div class="muted">' + esc(r.ratePerHour) + "/h" + (r.eta ? ", ETA " + esc(fmtDuration(r.eta.hours)) : "") + "</div>" : "") + "</td>"
      + "<td>" + esc(tallyText(r)) + (r.superseded || r.outOfPlan ? '<div class="muted">' + esc([r.superseded ? r.superseded + " superseded" : "", r.outOfPlan ? r.outOfPlan + " out-of-plan" : ""].filter(Boolean).join(", ")) + "</div>" : "") + "</td>"
      + "<td>" + esc(sevText(r.bugs.bySeverity)) + "</td><td>" + (r.verified ? "yes" : "no") + "</td>"
      + "<td>" + (r.ship ? '<span class="st st-' + esc(r.ship.verdict.replace(/ /g, "-")) + '" title="' + esc(r.ship.conditions.join("; ")) + '">' + esc(r.ship.verdict) + "</span>" : '<span class="muted">—</span>') + "</td>"
      + "<td>" + (r.report ? '<a href="' + esc(r.report.rel) + '">report</a>' : '<span class="muted">—</span>') + "</td></tr>";
  }).join("");
  views += '<section class="view" id="runs">' + head("Runs", runs.length + " runs") + '<div class="card tablewrap" style="margin-top:22px">'
    + (runs.length ? "<table><thead><tr><th>Run</th><th>Target</th><th>Started</th><th>Status</th><th>Progress</th><th>Verdicts</th><th>Bugs</th><th>Verified</th><th>Ship</th><th>Report</th></tr></thead><tbody>" + runRows + "</tbody></table>" : '<p class="empty">No runs yet.</p>') + "</div></section>";

  views += '<section class="view" id="trends">' + head("Trends", "") + '<div style="margin-top:22px">' + (m.trends.length ? '<div class="trends">' + m.trends.map((tr) => '<div class="card"><h3>' + t(humanize(tr.target)) + "</h3>" + svgTrend(tr)
    + '<ul class="legend"><li><i style="background:var(--pass)"></i>pass</li><li><i style="background:var(--fail)"></i>fail or error</li><li><i style="background:var(--blocked)"></i>blocked</li><li><i style="background:var(--error)"></i>bugs</li></ul>'
    + '<p class="muted" style="font-size:.78rem;margin:6px 0 0">' + tr.points.length + " runs, oldest first</p></div>").join("") + "</div>" : '<div class="card"><p class="empty">Trends appear once a target has two runs.</p></div>') + "</div></section>";

  const specRows = m.specs.map((s) => "<tr><td>" + t(s.target) + "</td><td>" + (s.hasChecklist ? s.criteria : '<span class="muted">no checklist</span>') + "</td>"
    + "<td>" + (s.journeys ? "P1 " + s.journeys.P1 + ", P2 " + s.journeys.P2 + (s.journeys.P3 ? ", P3 " + s.journeys.P3 : "") : '<span class="muted">—</span>') + "</td>"
    + "<td>human " + s.oracle.human + ", spec " + s.oracle.spec + ", suggested " + s.oracle["llm-suggested"] + "</td>"
    + "<td>" + (s.analysis.verdict === "missing" ? '<span class="muted">not analyzed</span>' : badge(s.analysis.verdict) + (s.analysis.stale ? ' <span class="muted">stale</span>' : "")) + "</td>"
    + "<td>" + (s.coverage ? esc(s.coverage.percent + "%") + (s.coverage.uncovered ? '<div class="muted">' + s.coverage.uncovered + " uncovered</div>" : "") : '<span class="muted">—</span>') + "</td>"
    + "<td>" + s.runs + (s.latestRun ? '<div class="muted">latest ' + esc(s.latestRun.status) + "</div>" : "") + "</td>"
    + "<td>" + (s.drift ? "out of date" : "in sync") + "</td></tr>").join("");
  views += '<section class="view" id="plans">' + head("Test plans", m.specs.length + " plans") + '<div class="card tablewrap" style="margin-top:22px">'
    + (m.specs.length ? "<table><thead><tr><th>Target</th><th>Checks</th><th>Journeys</th><th>Expected results from</th><th>Analysis</th><th>Coverage</th><th>Runs</th><th>Roles</th></tr></thead><tbody>" + specRows + "</tbody></table>" : '<p class="empty">No test plans under .qa/specs/.</p>') + "</div></section>";

  const kd = m.knownDefects;
  views += '<section class="view" id="defects">' + head("Known defects", kd.present ? kd.counts.outstanding + " outstanding, " + kd.counts.expired + " expired" : "no registry") + '<div style="margin-top:22px">'
    + (!kd.present ? '<div class="card"><p class="empty">No known-defect registry (.qa/known-defects.json).</p></div>'
      : (kd.error ? '<div class="warn">' + esc(kd.error) + "</div>" : "") + (!kd.valid ? '<div class="warn">The registry does not validate (scripts/known-defects.sh validate).</div>' : "")
        + '<div class="card tablewrap">' + (kd.entries.length ? "<table><thead><tr><th>Id</th><th>Title</th><th>Severity</th><th>Ticket</th><th>Expiry</th><th>State</th></tr></thead><tbody>"
          + kd.entries.map((e) => "<tr><td class=\"code\">" + t(e.id) + "</td><td>" + t(e.title) + "</td><td>" + esc(e.severity) + "</td><td>" + t(e.ticket) + "</td><td>" + esc(e.expiry) + "</td><td>" + badge(e.state) + "</td></tr>").join("")
          + "</tbody></table>" : '<p class="empty">The registry is empty.</p>') + "</div>") + "</div></section>";

  views += '<section class="view" id="setup">' + head("Setup", "") + '<div class="card" style="margin-top:22px"><dl class="setup"><dt>Plugin</dt><dd>' + esc(m.plugin.name + " " + m.plugin.version) + "</dd>"
    + "<dt>Roles</dt><dd>" + (c.present ? c.roles + " roles, constitution <code>" + esc(c.version || "unversioned") + "</code>" : "no constitution yet") + "</dd>"
    + "<dt>Profile</dt><dd>" + (cfg.present ? esc(cfg.profile) + (cfg.environment ? ", environment " + t(cfg.environment) : "") : "no .qa/config.json") + "</dd>"
    + (cfg.present ? "<dt>Gates</dt><dd>" + (cfg.gates.length ? esc(cfg.gates.join(", ")) : "none") + "</dd><dt>Parallel checks</dt><dd>" + (cfg.maxParallel !== null ? esc(cfg.maxParallel) : "default") + "</dd><dt>API writes</dt><dd>" + (cfg.allowApiWrites ? "allowed" : "not allowed") + "</dd>" : "")
    + "</dl></div></section>";

  const lead = feats[0];
  const main = '<main class="main"><p class="stale" id="stale" hidden>This page has stopped updating while a run is still going. Keep it live with <code>qa-dashboard.sh html --watch 60</code>.</p>' + views
    + "<footer>Written by " + esc(m.plugin.name) + " qa-dashboard from this project's .qa/ folder. Read-only; credentials are never read or shown.</footer></main>";
  const sheet = '<div class="scrim" id="scrim" hidden></div><aside class="sheet" id="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-title" hidden><header><h2 id="sheet-title"></h2><button type="button" class="btn" id="sheet-close">Close</button></header><div class="sheet-body" id="sheet-body"></div></aside>';
  return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    + (opts.refresh ? '<noscript><meta http-equiv="refresh" content="' + opts.refresh + '"></noscript>\n' : "")
    + '<meta name="generator" content="qa-e2e-pilot qa-dashboard.js">\n<title>' + esc((lead ? lead.title + ": " + lead.readiness.headline : "QA console") + " | " + m.project.name) + "</title>\n<style>" + CSS + "</style>\n</head>\n"
    + '<body data-generated="' + esc(m.generatedAt) + '" data-refresh="' + esc(opts.refresh || 0) + '" data-live="' + (live ? "1" : "0") + '"><div class="app">\n'
    + side + main + "\n</div>" + sheet + "\n<script>" + JS + "</script>\n</body>\n</html>\n";
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------
function palette(color) {
  const w = (code) => (s) => (color ? "\x1b[" + code + "m" + s + "\x1b[0m" : s);
  return { bold: w("1"), dim: w("2"), red: w("31"), green: w("32"), yellow: w("33"), blue: w("34"), magenta: w("35"), cyan: w("36") };
}
function pad(s, n) { const a = Array.from(str(s)); return a.length >= n ? a.slice(0, Math.max(0, n - 1)).join("") + (n > 0 ? "…" : "") : a.join("") + " ".repeat(n - a.length); }

function renderTui(m, opts) {
  const c = palette(opts.color);
  const width = Math.max(60, opts.width || 100);
  const st = (s) => ({ running: c.blue, stalled: c.yellow, paused: c.dim, complete: c.green }[s] || ((x) => x))(s);
  const out = [];
  const cfg = m.config, con = m.constitution;
  out.push(c.bold("QA dashboard · " + m.project.name) + c.dim(" · " + m.plugin.name + " " + m.plugin.version + " · " + m.generatedAt));
  out.push("Constitution " + (con.present ? (con.version || "unversioned") + " · " + con.roles + " roles" : "none")
    + " · profile " + (cfg.present ? cfg.profile + (cfg.environment ? " · env " + cfg.environment : "") : "no config.json"));
  out.push("");
  const activeRuns = m.runs.filter((r) => r.active);
  out.push(c.bold("ACTIVE"));
  if (!activeRuns.length) out.push(c.dim("  no run in progress"));
  for (const r of activeRuns) {
    const a = r.active;
    out.push("  " + st(r.status) + " " + r.id + c.dim(" (" + r.target + ")"));
    out.push("    " + [a.phase && "phase " + a.phase, a.criterion && "criterion " + a.criterion, a.persona && "persona " + a.persona].filter(Boolean).join(" · "));
    out.push("    " + progText(r) + (r.ratePerHour !== null ? " · " + r.ratePerHour + "/h" : "") + (r.eta ? " · ETA " + fmtDuration(r.eta.hours) : ""));
    if (r.status === "stalled") out.push("    " + c.yellow("STALLED: no journal activity for " + fmtDuration(r.idleMinutes / 60) + " — /qa-resume " + r.id));
    for (const e of a.events) out.push("    " + c.dim(e.t.slice(11, 19)) + " " + clip(e.text, width - 14));
    for (const b of a.bugs) out.push("    " + c.red("bug") + " " + clip((b.title || b.id) + (b.severity || b.layer ? " [" + [b.severity, b.layer].filter(Boolean).join(" · ") + "]" : ""), width - 10));
  }
  out.push("");
  const lead = (m.features || [])[0];
  if (lead && lead.journeys.length) {
    out.push(c.bold(lead.journeys.some((j) => j.priority) ? "JOURNEYS" : "CHECKS BY ROLE") + c.dim(" · " + lead.title + " · " + lead.readiness.headline));
    if (lead.readiness.facts) out.push("  " + lead.readiness.facts);
    const glyph = (k) => k.current ? c.cyan("◉") : ({ pass: k.lowConfidence ? c.green("○") : c.green("●"), fail: c.red("◆"), error: c.magenta("◆"),
      blocked: c.yellow("■"), deferred: c.dim("○"), pending: c.dim("·") }[k.verdict] || "?");
    const nameW = Math.min(36, Math.max(12, Math.floor(width * 0.34)));
    for (const j of lead.journeys) {
      const sum = journeySummary(j), sumW = 22;
      const room = Math.max(4, width - nameW - sumW - 8);
      const shown = j.checks.slice(0, room), more = j.checks.length - shown.length;
      const tone = sum.tone === "bad" ? c.red : sum.tone === "warn" ? c.yellow : sum.tone === "good" ? c.green : (x) => x;
      out.push("  " + pad((/^role:|^other$/.test(j.id) ? "" : j.id + " ") + j.name, nameW) + " " + shown.map(glyph).join("")
        + (more ? c.dim(" +" + more) : "") + " ".repeat(Math.max(1, room - shown.length - (more ? String(more).length + 2 : 0) + 1)) + tone(sum.text));
    }
    out.push(c.dim("  ● passed  ○ low confidence  ◆ failed  ■ blocked  · not run yet  ◉ running now"));
    out.push("");
  }
  out.push(c.bold("RUNS"));
  const idW = Math.min(44, Math.max(10, ...m.runs.map((r) => r.id.length)));
  out.push(c.dim("  " + pad("run", idW) + " " + pad("status", 9) + " " + pad("progress", 16) + " pass fail blk  def  err  bugs ver ship"));
  for (const r of m.runs) {
    const tl = r.tally;
    const n = (v) => pad(tl ? String(tl[v]) : "-", 4);
    out.push("  " + pad(r.id, idW) + " " + st(pad(r.status, 9)) + " " + pad(progText(r), 16) + " "
      + c.green(n("pass")) + " " + c.red(n("fail")) + " " + c.yellow(n("blocked")) + " " + n("deferred") + " " + c.magenta(n("error")) + " "
      + pad(String(r.bugs.total), 5) + pad(r.verified ? "yes" : "no", 4)
      + (r.ship ? (r.ship.verdict === "SHIP-READY" ? c.green(r.ship.verdict) : c.red(r.ship.verdict)) : c.dim("-")));
  }
  out.push("");
  out.push(c.bold("SPECS"));
  const tW = Math.min(44, Math.max(8, ...m.specs.map((s) => s.target.length)));
  for (const s of m.specs) {
    out.push("  " + pad(s.target, tW) + " " + pad(String(s.criteria) + " crit", 9) + " "
      + pad(s.journeys ? "P1 " + s.journeys.P1 + " P2 " + s.journeys.P2 : "no journeys", 12) + " "
      + pad("oracle h" + s.oracle.human + " s" + s.oracle.spec + " llm" + s.oracle["llm-suggested"], 20) + " "
      + (s.analysis.verdict === "BLOCKED" ? c.red("BLOCKED") : s.analysis.verdict === "OK" ? c.green("OK") : c.dim(s.analysis.verdict))
      + (s.analysis.stale ? c.dim(" (stale)") : "") + (s.coverage ? " · cov " + s.coverage.percent + "%" : "") + " · runs " + s.runs);
  }
  out.push("");
  const kd = m.knownDefects;
  out.push(c.bold("KNOWN DEFECTS") + " " + (kd.present ? kd.counts.outstanding + " outstanding · " + kd.counts.expired + " expired · " + kd.counts.cleared + " cleared" + (kd.valid ? "" : c.red(" · registry invalid")) : c.dim("no registry")));
  if (kd.present) for (const e of kd.entries) out.push("  " + pad(e.state, 12) + " " + clip(e.id + " — " + e.title, width - 16));
  return out.join("\n") + "\n";
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const o = { mode: argv[0], project: ".", out: null, refresh: 0, watch: 0, open: false, stallMinutes: 30, now: process.env.QA_DASHBOARD_NOW || "" };
  const usage = "usage: qa-dashboard.sh html [--project <dir>] [--out <file>] [--refresh <sec>] [--watch <sec>] [--open] | tui [--project <dir>] [--watch <sec>] | json [--project <dir>]";
  if (!o.mode || o.mode === "-h" || o.mode === "--help") { process.stdout.write(usage + "\n"); process.exit(o.mode ? 0 : 2); }
  if (!["html", "tui", "json"].includes(o.mode)) die("unknown mode " + o.mode + "\n" + usage);
  const int = (v, name) => { const n = Number(v); if (!Number.isInteger(n) || n < 0) die(name + " needs a whole number of seconds/minutes"); return n; };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i], v = argv[i + 1];
    if (a === "--project") { o.project = v; i++; }
    else if (a === "--out") { o.out = v; i++; }
    else if (a === "--refresh") { o.refresh = int(v, a); i++; }
    else if (a === "--watch") { o.watch = int(v, a); i++; }
    else if (a === "--open") { o.open = true; continue; }
    else if (a === "--stall-minutes") { o.stallMinutes = int(v, a); i++; }
    else if (a === "--now") { o.now = v; i++; }
    else die("unknown option " + a + "\n" + usage);
    if (v === undefined) die(a + " needs a value");
  }
  if (o.now && !Number.isFinite(Date.parse(o.now))) die("--now must be an ISO-8601 time");
  return o;
}

// Opens the page with the platform's default browser; failure is only a note.
function openInBrowser(file) {
  const { spawn } = require("child_process");
  const [cmd, args] = process.platform === "darwin" ? ["open", [file]] : process.platform === "win32" ? ["cmd", ["/c", "start", "", file]] : ["xdg-open", [file]];
  try { const p = spawn(cmd, args, { stdio: "ignore", detached: true }); p.on("error", () => process.stderr.write("qa-dashboard: could not open a browser; open " + file + "\n")); p.unref(); }
  catch (_) { process.stderr.write("qa-dashboard: could not open a browser; open " + file + "\n"); }
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  const nowMs = () => (o.now ? Date.parse(o.now) : Date.now());
  if (o.mode === "json") {
    process.stdout.write(JSON.stringify(buildDashboard({ project: o.project, nowMs: nowMs(), stallMinutes: o.stallMinutes }), null, 2) + "\n");
    return;
  }
  if (o.mode === "html") {
    const out = path.resolve(o.out || path.join(o.project, ".qa", "dashboard.html"));
    // --watch keeps rewriting the page; the open tab reloads on the same beat
    // (keeping its scroll, open sections and filters).
    const refresh = o.refresh || o.watch;
    const write = () => {
      const m = buildDashboard({ project: o.project, nowMs: nowMs(), stallMinutes: o.stallMinutes, linkBase: path.dirname(out) });
      fs.mkdirSync(path.dirname(out), { recursive: true });
      const tmp = out + ".tmp-" + process.pid;
      fs.writeFileSync(tmp, renderHtml(m, { refresh }));
      fs.renameSync(tmp, out); // atomic: a reloading tab never reads half a page
      return m;
    };
    const m = write();
    process.stdout.write("wrote " + out + " (" + m.runs.length + " runs, " + m.specs.length + " specs, " + m.active.length + " active)\n");
    if (o.open) openInBrowser(out);
    if (!o.watch) return;
    const stop = () => { process.stdout.write("\n"); process.exit(0); };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    process.stdout.write("rewriting every " + o.watch + "s · Ctrl-C to stop\n");
    setInterval(() => { try { write(); } catch (e) { process.stderr.write("qa-dashboard: " + (e && e.message || e) + "\n"); } }, o.watch * 1000);
    return;
  }
  const tty = !!process.stdout.isTTY;
  const color = !("NO_COLOR" in process.env) && (tty || (process.env.FORCE_COLOR && process.env.FORCE_COLOR !== "0"));
  const frame = () => renderTui(buildDashboard({ project: o.project, nowMs: nowMs(), stallMinutes: o.stallMinutes }), { color, width: process.stdout.columns || Number(process.env.COLUMNS) || 100 });
  if (!o.watch) { process.stdout.write(frame()); return; }
  const stop = () => { if (tty) process.stdout.write("\x1b[?25h"); process.stdout.write("\n"); process.exit(0); };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  const hint = palette(color).dim("(refreshing every " + o.watch + "s · Ctrl-C to quit)");
  const draw = () => {
    const f = frame();
    if (tty) process.stdout.write("\x1b[?25l\x1b[H\x1b[2J" + f + hint + "\n");
    else process.stdout.write(f + "-- refreshing every " + o.watch + "s · Ctrl-C to quit --\n\n");
  };
  draw();
  setInterval(draw, o.watch * 1000);
}

if (require.main === module) main();
else module.exports = { humanize, readinessOf, journeySummary, runStatus, computeRate, computeEta, fmtDuration, resolveTarget, describeEvent, makeRedactor, buildDashboard, renderHtml, renderTui };
