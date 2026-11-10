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
  const lastActivityMs = mtimeMs(path.join(dir, "journal.ndjson")) || mtimeMs(path.join(dir, "cursor.json")) || mtimeMs(path.join(dir, "checkpoint.json"));
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

// Design: the page answers three questions in order: can this ship and what
// is in the way, where is the live run, what exactly is broken. The one
// strong visual is the journey line: one stop per check in plan order,
// coloured and shaped by verdict (shape carries meaning without colour).
// Everything else stays quiet. Works without JavaScript (details/summary);
// the inline script only adds local times, filters, freshness, and keeps
// scroll, open sections and filters across auto-refresh.
const CSS = `
:root{color-scheme:light dark;
--page:#edf0f3;--surface:#fff;--ink:#16212e;--soft:#4e5a69;--faint:#768190;--rule:#d5dbe2;--wash:#f5f7f9;
--pass:#1f7a4d;--fail:#c33a2e;--error:#6e44c2;--blocked:#b4761a;--deferred:#8b95a3;--pending:#b3bcc7;--now:#2456c6;
--good-bg:#e5f2ea;--bad-bg:#fbe8e5;--warn-bg:#fbf0de;--progress-bg:#e7edfa;--link:#2456c6;
--sans:"Avenir Next",Avenir,"Segoe UI Variable Text","Segoe UI",system-ui,-apple-system,"Geeza Pro","Noto Sans Arabic",Tahoma,sans-serif;
--code:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--page:#0e131a;--surface:#151c25;--ink:#e4e9ef;--soft:#a6b0bd;--faint:#7d8896;--rule:#27313d;--wash:#1a222c;
--pass:#45b07b;--fail:#ef6a5c;--error:#a688f2;--blocked:#e2a23f;--deferred:#7f8996;--pending:#4a5563;--now:#7ea3ff;
--good-bg:#132a1e;--bad-bg:#35191a;--warn-bg:#2f2513;--progress-bg:#17223a;--link:#8fb0ff}}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--page);color:var(--ink);font:15px/1.55 var(--sans);font-variant-numeric:tabular-nums}
a{color:var(--link);text-underline-offset:2px}
:focus-visible{outline:2px solid var(--now);outline-offset:2px;border-radius:3px}
code,.code{font-family:var(--code);font-size:.85em;overflow-wrap:anywhere}
body{overflow-wrap:break-word}
.low-note{color:var(--faint);display:inline-flex;align-items:center;gap:4px}
.low-note .stop{width:10px;height:10px;cursor:default}
[hidden]{display:none!important}
.wrap{max-width:1180px;margin:0 auto;padding:0 16px 72px}
.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:4px 24px;padding:18px 0 14px;border-bottom:1px solid var(--rule)}
.top h1{font-size:1rem;font-weight:600;margin:0}
.top h1 span{color:var(--faint);font-weight:500}
.fresh{margin:0;color:var(--soft);font-size:.88rem}
.stale{margin:12px 0 0;padding:10px 14px;border-radius:8px;background:var(--warn-bg);color:var(--ink);font-size:.9rem}
.feature{padding:28px 0 8px}
.f-title{font-size:clamp(1.75rem,3.2vw,2.45rem);line-height:1.1;font-weight:650;letter-spacing:-.015em;margin:0}
.f-run{margin:8px 0 0;color:var(--soft);font-size:.9rem}
.verdict{margin:20px 0 0;padding:14px 18px;border-radius:10px;border-inline-start:5px solid var(--faint);background:var(--wash)}
.verdict p{margin:0}
.v-head{font-size:1.3rem;font-weight:650;line-height:1.25}
.v-facts{margin-top:4px!important;color:var(--soft);max-width:72ch}
.lv-good{border-color:var(--pass);background:var(--good-bg)}.lv-bad{border-color:var(--fail);background:var(--bad-bg)}
.lv-warn{border-color:var(--blocked);background:var(--warn-bg)}.lv-progress{border-color:var(--now);background:var(--progress-bg)}
.live{margin:16px 0 0;display:grid;gap:14px 32px;grid-template-columns:minmax(0,1fr)}
@media (min-width:900px){.live{grid-template-columns:minmax(0,1.1fr) minmax(0,1fr)}}
.live p{margin:0}
.count{font-size:1.05rem}.count b{font-size:1.6rem;font-weight:650;margin-inline-end:4px}
.eta,.doing{color:var(--soft);margin-top:4px!important}
.doing a{font-weight:600}
.tally{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--wash);margin:10px 0 8px;box-shadow:inset 0 0 0 1px var(--rule)}
.tally i{display:block;height:100%}
.legend{display:flex;flex-wrap:wrap;gap:4px 16px;margin:0;padding:0;list-style:none;font-size:.86rem;color:var(--soft)}
.legend li{display:flex;align-items:center;gap:6px}
.legend li>i{display:inline-block;border-radius:2px}
.legend b{color:var(--ink);font-weight:600}
.warnbox{margin-top:12px!important;padding:10px 14px;border-radius:8px;background:var(--warn-bg);font-weight:600}
.activity{margin:0;padding:0;list-style:none;font-size:.86rem;border-inline-start:2px solid var(--rule)}
.activity li{padding:3px 0 3px 12px;color:var(--soft);overflow-wrap:anywhere}
.activity li:first-child{color:var(--ink)}
.activity time{display:inline-block;min-width:3.6em;color:var(--faint);margin-inline-end:6px}
.sec{font-size:1.15rem;font-weight:650;margin:36px 0 2px}
.sec-note{margin:0 0 10px;color:var(--soft);font-size:.9rem}
.grp{font-size:.92rem;font-weight:600;color:var(--soft);margin:18px 0 0;padding-bottom:6px}
.journeys{background:var(--surface);border:1px solid var(--rule);border-radius:12px;padding:2px 16px}
.grp + .journeys{margin-top:0}
details.jr + details.jr{border-top:1px solid var(--rule)}
details.jr>summary{list-style:none;display:grid;grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"name sum" "line line";gap:8px 16px;align-items:center;padding:12px 2px;cursor:pointer}
@media (min-width:860px){details.jr>summary{grid-template-columns:minmax(220px,300px) minmax(0,1fr) 150px;grid-template-areas:"name line sum"}}
details.jr>summary::-webkit-details-marker{display:none}
.jr-name{grid-area:name;font-weight:600;line-height:1.3}
.jr-name small{display:block;font-weight:500;color:var(--faint);font-size:.78rem;margin-bottom:1px}
.jr-sum{grid-area:sum;text-align:end;font-size:.88rem;color:var(--soft)}
.jr-sum.t-bad{color:var(--fail);font-weight:600}.jr-sum.t-warn{color:var(--blocked);font-weight:600}.jr-sum.t-good{color:var(--pass)}
.line{grid-area:line;display:inline-flex;flex-wrap:wrap;align-items:center;gap:6px;max-width:100%;justify-self:start;
background-image:linear-gradient(to bottom,transparent 5px,var(--rule) 5px,var(--rule) 7px,transparent 7px);background-size:100% 18px}
.line.main{background-image:linear-gradient(to bottom,transparent 4.5px,var(--soft) 4.5px,var(--soft) 7.5px,transparent 7.5px)}
.stop{display:block;width:12px;height:12px;border-radius:50%;background:var(--pass);flex:none;cursor:pointer}
.stop.v-fail,.stop.v-error{background:var(--fail);border-radius:0;clip-path:polygon(50% 0,100% 50%,50% 100%,0 50%);transform:scale(1.25)}
.stop.v-error{background:var(--error)}
.stop.v-blocked{background:var(--blocked);border-radius:2px}
.stop.v-deferred{background:var(--surface);box-shadow:inset 0 0 0 3px var(--deferred)}
.stop.v-pending{background:var(--surface);box-shadow:inset 0 0 0 2px var(--pending)}
.stop.low{background:radial-gradient(circle,var(--surface) 0 2px,var(--pass) 2.5px)}
.stop.now{background:var(--surface);box-shadow:inset 0 0 0 3px var(--now);animation:pulse 1.8s ease-out infinite}
@keyframes pulse{0%{box-shadow:inset 0 0 0 3px var(--now),0 0 0 0 color-mix(in srgb,var(--now) 55%,transparent)}100%{box-shadow:inset 0 0 0 3px var(--now),0 0 0 9px transparent}}
@media (prefers-reduced-motion:reduce){.stop.now{animation:none}.flash{animation:none!important}}
ol.checks{margin:0 0 14px;padding:0 0 0 2px;list-style:none;counter-reset:ck}
ol.checks>li{counter-increment:ck;display:grid;grid-template-columns:2.2em 7.2em minmax(0,1fr);gap:2px 10px;padding:8px 6px;border-radius:8px;align-items:start}
ol.checks>li::before{content:counter(ck);color:var(--faint);font-size:.82rem;text-align:end;padding-top:2px}
ol.checks>li.v-fail,ol.checks>li.v-error{background:var(--bad-bg)}
ol.checks>li.v-blocked{background:var(--warn-bg)}
ol.checks>li.now{box-shadow:inset 0 0 0 2px var(--now)}
.flash{animation:flash 1.6s ease-out}
@keyframes flash{0%{background:color-mix(in srgb,var(--now) 30%,transparent)}100%{background:transparent}}
.mark{font-size:.82rem;font-weight:600;padding-top:2px;display:flex;align-items:center;gap:6px}
.mark::before{content:"";width:9px;height:9px;border-radius:50%;background:currentColor;flex:none}
.mark.v-pass{color:var(--pass)}.mark.v-fail{color:var(--fail)}.mark.v-error{color:var(--error)}.mark.v-blocked{color:var(--blocked)}
.mark.v-deferred,.mark.v-pending{color:var(--faint)}
.mark.v-fail::before,.mark.v-error::before{border-radius:0;clip-path:polygon(50% 0,100% 50%,50% 100%,0 50%);width:11px;height:11px}
.mark.v-blocked::before{border-radius:2px}
.mark.v-pending::before,.mark.v-deferred::before{background:transparent;box-shadow:inset 0 0 0 2px currentColor}
.ck-body{min-width:0}
.ck-body p{margin:0}
.ck-name{font-weight:600}
.ck-meta{font-size:.84rem;color:var(--soft)}
.ck-meta>*+*::before{content:"/";color:var(--rule);margin:0 8px}
.ck-note{font-size:.88rem;color:var(--soft);margin-top:3px!important;max-width:90ch;overflow-wrap:anywhere}
.filters{display:flex;flex-wrap:wrap;gap:10px 14px;align-items:center;margin:4px 0 12px}
.seg{display:inline-flex;flex-wrap:wrap;max-width:100%;border:1px solid var(--rule);border-radius:8px;overflow:hidden;background:var(--surface)}
.seg button{font:inherit;font-size:.86rem;border:0;background:transparent;color:var(--ink);padding:6px 12px;cursor:pointer}
.seg button+button{border-inline-start:1px solid var(--rule)}
.seg button[aria-pressed="true"]{background:var(--ink);color:var(--surface)}
.seg button span{color:inherit;opacity:.7;margin-inline-start:4px}
.filters input,.filters select{font:inherit;font-size:.88rem;color:var(--ink);background:var(--surface);border:1px solid var(--rule);border-radius:8px;padding:6px 10px;min-width:0}
.filters input{flex:1 1 220px;max-width:360px}
.filters select{max-width:100%}
.shown{font-size:.86rem;color:var(--soft)}
.linkbtn{font:inherit;font-size:.86rem;background:none;border:0;color:var(--link);text-decoration:underline;cursor:pointer;padding:0}
.buglist{background:var(--surface);border:1px solid var(--rule);border-radius:12px}
details.bug+details.bug{border-top:1px solid var(--rule)}
details.bug>summary{list-style:none;display:grid;grid-template-columns:5.4em minmax(0,1fr);gap:2px 12px;padding:12px 16px;cursor:pointer}
details.bug>summary::-webkit-details-marker{display:none}
details.bug[open]>summary{background:var(--wash)}
.sev{font-size:.82rem;font-weight:650;padding-top:2px}
.sev-critical,.sev-high{color:var(--fail)}.sev-medium{color:var(--blocked)}.sev-low,.sev-unrated{color:var(--faint)}
.bug-title{font-weight:600;line-height:1.35}
.bug-where{grid-column:2;font-size:.84rem;color:var(--soft)}
.bug-body{padding:4px 16px 16px calc(5.4em + 28px)}
.bug-body dl{display:grid;gap:12px 28px;margin:0;grid-template-columns:minmax(0,1fr)}
@media (min-width:860px){.bug-body dl{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}}
.bug-body dt{font-size:.82rem;font-weight:650;color:var(--soft)}
.bug-body dd{margin:2px 0 0;overflow-wrap:anywhere}
.bug-body .more{margin:12px 0 0;font-size:.86rem;color:var(--soft)}
@media (max-width:640px){details.bug>summary{grid-template-columns:minmax(0,1fr)}.bug-where{grid-column:1}.bug-body{padding-inline-start:16px}}
.empty{padding:16px;color:var(--soft);margin:0}
.others{margin-top:40px;border-top:1px solid var(--rule)}
details.fold{border-bottom:1px solid var(--rule)}
details.fold>summary{list-style:none;cursor:pointer;padding:14px 2px;display:flex;flex-wrap:wrap;gap:4px 14px;align-items:baseline}
details.fold>summary::-webkit-details-marker{display:none}
details.fold>summary::before{content:"";width:7px;height:7px;border-inline-end:2px solid var(--faint);border-bottom:2px solid var(--faint);transform:rotate(-45deg);align-self:center;transition:transform .15s}
[dir=rtl] details.fold>summary::before{transform:rotate(135deg)}
details.fold[open]>summary::before{transform:rotate(45deg)}
.fold-title{font-weight:650}
.fold-meta{color:var(--soft);font-size:.88rem}
details.fold .feature{padding-top:4px}
details.fold .f-title{font-size:1.5rem}
.records{margin-top:44px}
.records>h2{font-size:1.15rem;margin:0 0 4px}
.scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--rule);border-radius:10px;margin-bottom:16px}
table{border-collapse:collapse;width:100%;font-size:.86rem}
th,td{text-align:start;padding:7px 10px;border-bottom:1px solid var(--rule);vertical-align:top}
th{color:var(--soft);font-weight:600;background:var(--wash);white-space:nowrap}
tr:last-child td{border-bottom:0}
.st{display:inline-block;border-radius:999px;padding:0 9px;font-size:.78rem;font-weight:600;color:#fff;background:var(--deferred);white-space:nowrap}
.st-running{background:var(--now)}.st-stalled{background:var(--blocked)}.st-paused{background:var(--deferred)}.st-complete{background:var(--pass)}
.st-BLOCKED,.st-NOT-SHIP-READY,.st-expired{background:var(--fail)}.st-OK,.st-SHIP-READY,.st-cleared{background:var(--pass)}.st-outstanding{background:var(--blocked)}
.bar{height:6px;background:var(--wash);border-radius:3px;overflow:hidden;min-width:80px;margin-top:4px}
.bar i{display:block;height:100%;background:var(--now)}
.warn{background:var(--bad-bg);border-radius:8px;padding:8px 12px;margin:8px 0;font-weight:600}
.muted{color:var(--soft)}
.trends{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));margin-bottom:16px}
.panel{background:var(--surface);border:1px solid var(--rule);border-radius:10px;padding:12px 14px}
.panel h3{font-size:.95rem;margin:0 0 6px}
svg.trend{max-width:100%;height:auto;display:block;margin-top:6px}
svg .b-pass{fill:var(--pass)}svg .b-fail{fill:var(--fail)}svg .b-blocked{fill:var(--blocked)}svg .b-bugs{fill:var(--error)}svg .axis{stroke:var(--rule)}
.setup{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:4px 18px;margin:0 0 16px;font-size:.9rem}
.setup dt{color:var(--soft)}.setup dd{margin:0}
footer{margin-top:36px;color:var(--faint);font-size:.8rem}
`;

const JS = `
(function(){
var B=document.body,gen=Date.parse(B.getAttribute("data-generated")),refresh=Number(B.getAttribute("data-refresh"))||0,live=B.getAttribute("data-live")==="1";
var KEY="qa-dashboard:"+location.pathname;
function store(v){try{if(v===undefined)return JSON.parse(sessionStorage.getItem(KEY)||"null");sessionStorage.setItem(KEY,JSON.stringify(v));}catch(e){return null;}}
function two(n){return(n<10?"0":"")+n;}
function clock(d){return two(d.getHours())+":"+two(d.getMinutes());}
function stamp(d){var n=new Date();return(d.toDateString()===n.toDateString()?"":d.toLocaleDateString([],{month:"short",day:"numeric"})+" ")+clock(d);}
function ago(ms){var m=Math.round(ms/60000);if(m<1)return"just now";if(m<60)return m+" min ago";var h=Math.floor(m/60);if(h<48)return h+" h "+(m%60?m%60+" min ":"")+"ago";return Math.round(h/24)+" days ago";}
[].forEach.call(document.querySelectorAll("time[data-t]"),function(el){var d=new Date(el.getAttribute("datetime"));if(!isNaN(d))el.textContent=el.getAttribute("data-t")==="clock"?clock(d):stamp(d);});
var agoEl=document.getElementById("ago"),staleEl=document.getElementById("stale");
function tick(){var age=Date.now()-gen;if(agoEl)agoEl.textContent=ago(age);if(staleEl){var limit=refresh?refresh*3000+30000:3600000;staleEl.hidden=!(live&&age>limit);}}
tick();setInterval(tick,30000);
var st=store()||{},filt=st.filt||{};
if(st.open){[].forEach.call(document.querySelectorAll("details[data-key]"),function(d){d.open=st.open.indexOf(d.getAttribute("data-key"))>=0;});}
[].forEach.call(document.querySelectorAll(".bugs[data-key]"),function(box){
var k=box.getAttribute("data-key"),f=filt[k]||(filt[k]={sev:"all",q:"",j:""});
var bar=box.querySelector(".filters"),btns=box.querySelectorAll("button[data-sev]"),q=box.querySelector("input[type=search]"),sel=box.querySelector("select"),items=box.querySelectorAll("details.bug"),empty=box.querySelector(".empty"),shown=box.querySelector(".shown");
if(bar)bar.hidden=false;
function apply(){var n=0;[].forEach.call(items,function(it){var ok=(f.sev==="all"||it.getAttribute("data-sev")===f.sev)&&(!f.j||it.getAttribute("data-j")===f.j)&&(!f.q||it.getAttribute("data-text").indexOf(f.q.toLowerCase())>=0);it.hidden=!ok;if(ok)n++;});
[].forEach.call(btns,function(b){b.setAttribute("aria-pressed",String(b.getAttribute("data-sev")===f.sev));});
if(empty)empty.hidden=n>0;if(shown)shown.textContent=n===items.length?"":n+" of "+items.length+" shown";}
[].forEach.call(btns,function(b){b.addEventListener("click",function(){f.sev=b.getAttribute("data-sev");apply();});});
if(q){q.value=f.q;q.addEventListener("input",function(){f.q=q.value.trim();apply();});}
if(sel){sel.value=f.j;sel.addEventListener("change",function(){f.j=sel.value;apply();});}
[].forEach.call(box.querySelectorAll("[data-clear]"),function(c){c.addEventListener("click",function(){f.sev="all";f.q="";f.j="";if(q)q.value="";if(sel)sel.value="";apply();});});
apply();});
function openTo(el){for(var p=el;p;p=p.parentElement)if(p.tagName==="DETAILS")p.open=true;}
function show(el){openTo(el);var rm=window.matchMedia&&matchMedia("(prefers-reduced-motion: reduce)").matches;el.scrollIntoView({block:"center",behavior:rm?"auto":"smooth"});el.classList.remove("flash");void el.offsetWidth;el.classList.add("flash");}
document.addEventListener("click",function(e){var s=e.target.closest&&e.target.closest(".stop[data-ck]");if(s){e.preventDefault();var li=document.getElementById(s.getAttribute("data-ck"));if(li)show(li);return;}
var a=e.target.closest&&e.target.closest("a[href^='#']");if(a){var t=document.getElementById(decodeURIComponent(a.getAttribute("href").slice(1)));if(t){e.preventDefault();show(t);}}});
document.addEventListener("keydown",function(e){if(e.key==="/"&&!/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)){var s=document.querySelector(".bugs:not([hidden]) input[type=search]");if(s&&s.offsetParent){e.preventDefault();s.focus();}}});
function save(){store({y:window.scrollY,open:[].map.call(document.querySelectorAll("details[open][data-key]"),function(d){return d.getAttribute("data-key");}),filt:filt});}
window.addEventListener("pagehide",save);
if(st.y)window.scrollTo(0,st.y);
if(refresh){var reload=function(){var a=document.activeElement;if(a&&/INPUT|SELECT/.test(a.tagName)){setTimeout(reload,5000);return;}save();location.reload();};setTimeout(reload,refresh*1000);}
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
    case "criterion_started": return "Started: " + name + as;
    case "criterion_verdict": return (VERDICT_LABEL[e.verdict] || e.verdict || "Verdict") + ": " + name + as + (e.confidence === "low" ? " (low confidence)" : "");
    case "act_intent": return "Acting on: " + name;
    case "act_committed": return "Action saved: " + name;
    case "bug_logged": return "Bug logged: " + (e.title || "untitled");
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

function renderJourney(f, j, key) {
  const main = j.priority === "P1";
  const sum = journeySummary(j);
  const ckId = (k, i) => "ck-" + slug(f.target) + "-" + slug(j.id) + "-" + i;
  const stops = j.checks.map((k, i) => '<i class="stop v-' + esc(k.verdict) + (k.lowConfidence ? " low" : "") + (k.current ? " now" : "")
    + '" data-ck="' + esc(ckId(k, i)) + '" title="' + esc(k.name + ": " + (k.current ? "running now" : VERDICT_LABEL[k.verdict] || k.verdict) + (k.role ? ", as " + k.role : "")) + '"></i>').join("");
  const items = j.checks.map((k, i) => {
    const meta = [k.role ? "<span>as " + t(k.role) + "</span>" : "", k.lowConfidence ? "<span>low confidence</span>" : "",
      k.bugs.length ? "<span>" + k.bugs.map((b) => '<a href="#bug-' + esc(slug(f.target) + "-" + slug(b)) + '">bug ' + esc(b) + "</a>").join(", ") + "</span>" : "",
      k.link ? '<span><a href="' + esc(k.link) + '">evidence</a></span>' : ""].filter(Boolean).join("");
    return '<li id="' + esc(ckId(k, i)) + '" class="v-' + esc(k.verdict) + (k.current ? " now" : "") + '"><span class="mark v-' + esc(k.verdict) + '">'
      + esc(k.current ? "Running now" : (VERDICT_LABEL[k.verdict] || k.verdict)) + '</span><div class="ck-body"><p class="ck-name">' + t(k.name) + "</p>"
      + (meta ? '<p class="ck-meta">' + meta + "</p>" : "") + (k.note ? '<p class="ck-note">' + t(k.note) + "</p>" : "") + "</div></li>";
  }).join("");
  return '<details class="jr" data-key="' + esc(key) + '"><summary><span class="jr-name">' + (j.priority || /^role:|^other$/.test(j.id) ? "" : "")
    + (/^role:|^other$/.test(j.id) ? "" : "<small>" + esc(j.id) + "</small>") + t(j.name) + "</span>"
    + '<span class="line' + (main ? " main" : "") + '" aria-hidden="true">' + stops + "</span>"
    + '<span class="jr-sum' + (sum.tone ? " t-" + sum.tone : "") + '">' + esc(sum.text) + "</span></summary>"
    + '<ol class="checks" aria-label="' + esc("Checks in " + j.name) + '">' + items + "</ol></details>";
}

function renderBugs(f) {
  const key = "bugs:" + f.target;
  if (!f.bugs.length) return '<h3 class="sec">Bugs</h3><p class="sec-note">No bugs logged in this run.</p>';
  const sevs = ["critical", "high", "medium", "low", "unrated"].filter((s) => f.bugs.some((b) => b.severity === s));
  const journeys = [];
  for (const b of f.bugs) if (b.journey && !journeys.some((x) => x[0] === b.journey)) journeys.push([b.journey, b.journeyName]);
  const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  const bar = '<div class="filters" hidden><div class="seg" role="group" aria-label="Severity"><button type="button" data-sev="all" aria-pressed="true">All<span>' + f.bugs.length + "</span></button>"
    + sevs.map((s) => '<button type="button" data-sev="' + s + '" aria-pressed="false">' + cap(s) + "<span>" + f.bugs.filter((b) => b.severity === s).length + "</span></button>").join("") + "</div>"
    + (journeys.length > 1 ? '<select aria-label="Journey"><option value="">Every journey</option>' + journeys.map((x) => '<option value="' + esc(x[0]) + '">' + esc(x[1]) + "</option>").join("") + "</select>" : "")
    + '<input type="search" placeholder="Search bugs  ( / )" aria-label="Search bugs"><span class="shown" aria-live="polite"></span></div>';
  const items = f.bugs.map((b, i) => {
    const where = [b.journeyName, b.role ? "as " + b.role : "", b.layer ? "likely " + b.layer : ""].filter(Boolean).join(", ");
    const id = "bug-" + slug(f.target) + "-" + slug(b.id || "n" + i);
    return '<details class="bug" id="' + esc(id) + '" data-key="' + esc(key + ":" + (b.id || i)) + '" data-sev="' + esc(b.severity) + '" data-j="' + esc(b.journey)
      + '" data-text="' + esc([b.title, b.id, b.criterionId, b.observed, b.expected, b.journeyName, b.role].join(" ").toLowerCase()) + '">'
      + '<summary><span class="sev sev-' + esc(b.severity) + '">' + esc(cap(b.severity)) + '</span><span class="bug-title">' + t(b.title || b.id) + "</span>"
      + (where ? '<span class="bug-where">' + t(where) + "</span>" : "") + "</summary>"
      + '<div class="bug-body"><dl>' + (b.observed ? "<div><dt>What happened</dt><dd>" + t(b.observed) + "</dd></div>" : "")
      + (b.expected ? "<div><dt>What should happen</dt><dd>" + t(b.expected) + "</dd></div>" : "") + "</dl>"
      + '<p class="more">' + [b.id ? "Bug " + esc(b.id) : "", b.status ? "status " + esc(b.status) : "", b.criterionId ? "found by " + t(b.criterionId) : "",
        b.link ? '<a href="' + esc(b.link) + '">open the evidence in the run report</a>' : ""].filter(Boolean).join(", ") + "</p></div></details>";
  }).join("");
  return '<h3 class="sec">Bugs</h3><p class="sec-note">Most severe first. Open one to see what happened and what should happen.</p>'
    + '<div class="bugs" data-key="' + esc(key) + '">' + bar + '<div class="buglist">' + items
    + '<p class="empty" hidden>No bug matches these filters. <button type="button" class="linkbtn" data-clear>Clear filters</button></p></div></div>';
}

function renderFeature(m, f, run) {
  const r = f.readiness;
  let html = '<h2 class="f-title">' + t(f.title) + "</h2>"
    + '<p class="f-run">Latest run <code>' + t(run.id) + "</code>" + (run.started ? ", started " + timeTag(run.started) : "")
    + (run.report ? ', <a href="' + esc(run.report.rel) + '">full run report</a>' : "") + (f.runs > 1 ? ", " + f.runs + " runs in total" : "") + "</p>"
    + '<div class="verdict lv-' + esc(r.level) + '"><p class="v-head">' + esc(r.headline) + "</p>" + (r.facts ? '<p class="v-facts">' + esc(r.facts) + "</p>" : "") + "</div>";

  const counts = emptyCounts(), seenCk = new Set();
  if (run.tally) {
    for (const v of VERDICTS) counts[v] = run.tally[v] || 0;
    const done = VERDICTS.reduce((a, v) => a + counts[v], 0);
    counts.pending = Number.isFinite(run.progress.total) ? Math.max(0, run.progress.total - done) : 0;
  } else for (const j of f.journeys) for (const k of j.checks) if (!seenCk.has(k.id)) { seenCk.add(k.id); counts[k.verdict] += 1; }
  const lowPass = run.lowPasses || 0;
  const n = TALLY_ORDER.reduce((a, v) => a + counts[v], 0);
  const color = { pass: "--pass", fail: "--fail", error: "--error", blocked: "--blocked", deferred: "--deferred", pending: "--pending" };
  const tally = n ? '<div class="tally" role="img" aria-label="' + esc(TALLY_ORDER.filter((v) => counts[v]).map((v) => counts[v] + " " + VERDICT_LABEL[v].toLowerCase()).join(", ")) + '">'
    + TALLY_ORDER.filter((v) => counts[v]).map((v) => '<i style="width:' + (counts[v] / n * 100).toFixed(2) + "%;background:var(" + color[v] + ')"></i>').join("") + "</div>"
    + '<ul class="legend">' + TALLY_ORDER.filter((v) => counts[v]).map((v) => '<li><span class="mark v-' + v + '" aria-hidden="true"></span><b>' + counts[v] + "</b> " + VERDICT_LABEL[v].toLowerCase()
      + (v === "pass" && lowPass ? ' <span class="low-note">(<i class="stop low" aria-hidden="true"></i>' + lowPass + " with low confidence)</span>" : "") + "</li>").join("") + "</ul>" : "";

  let live = "";
  if (run.active) {
    const a = run.active, p = run.progress;
    let now = "";
    if (a.criterion) {
      let anchor = "";
      f.journeys.forEach((j) => j.checks.forEach((k, i) => { if (!anchor && k.id === a.criterion) anchor = "ck-" + slug(f.target) + "-" + slug(j.id) + "-" + i; }));
      now = '<p class="doing">Now checking ' + (anchor ? '<a href="#' + esc(anchor) + '">' + t(humanize(a.criterion)) + "</a>" : t(humanize(a.criterion))) + (a.persona ? " as " + t(a.persona) : "") + "</p>";
    }
    live = '<div class="live"><div>'
      + (Number.isFinite(p.done) && Number.isFinite(p.total) ? '<p class="count"><b>' + p.done + "</b>of " + p.total + " checks done</p>" : "")
      + (run.eta ? '<p class="eta">About ' + esc(fmtDuration(run.eta.hours).replace(/h/, " h ").replace(/m$/, " min").trim()) + " left at " + esc(run.ratePerHour) + " checks an hour, finishing around " + timeTag(run.eta.at, "clock") + "</p>" : "")
      + now + tally
      + (run.status === "stalled" ? '<p class="warnbox">Stalled: no journal activity for ' + esc(fmtDuration(run.idleMinutes / 60)) + " (threshold " + m.stallMinutes + " min). Resume it with <code>/qa-resume " + t(run.id) + "</code>.</p>" : "")
      + "</div><div><ol class=\"activity\" aria-label=\"Latest activity\">" + a.events.slice(0, 7).map((e) => "<li>" + timeTag(e.t, "clock") + t(eventText(e)) + "</li>").join("") + "</ol></div></div>";
  } else if (tally) live = '<div class="live"><div>' + tally + "</div></div>";

  const groups = [["Main journeys", f.journeys.filter((j) => j.priority === "P1")],
    ["Other journeys", f.journeys.filter((j) => j.priority && j.priority !== "P1")],
    [f.journeys.some((j) => j.priority) ? "Outside the journeys" : "", f.journeys.filter((j) => !j.priority)]];
  const jHtml = f.journeys.length ? '<h3 class="sec">' + (f.journeys.some((j) => j.priority) ? "Journeys" : "Checks by role") + "</h3>"
    + '<p class="sec-note">Each stop is one check, in plan order. Select a row or a stop to see the checks.</p>'
    + groups.filter((g) => g[1].length).map((g) => (g[0] ? '<h4 class="grp">' + esc(g[0]) + "</h4>" : "") + '<div class="journeys">'
      + g[1].map((j) => renderJourney(f, j, "j:" + f.target + ":" + j.id)).join("") + "</div>").join("") : "";
  return html + live + jHtml + renderBugs(f);
}

function renderHtml(m, opts) {
  const runs = m.runs, byId = new Map(runs.map((r) => [r.id, r]));
  const c = m.constitution, cfg = m.config;
  const live = runs.some((r) => r.status === "running");
  const head = '<header class="top"><h1>' + t(m.project.name) + " <span>QA</span></h1>"
    + '<p class="fresh">Updated <span id="ago">' + timeTag(m.generatedAt) + "</span>" + (opts.refresh ? ", refreshes every " + esc(opts.refresh) + " s" : "") + "</p></header>"
    + '<p class="stale" id="stale" hidden>This page has stopped updating while a run is still going. Keep it live with <code>qa-dashboard.sh html --watch 60</code>.</p>';

  const feats = m.features || [];
  const lead = feats[0];
  let body = "";
  if (!lead) body += '<section class="feature"><h2 class="f-title">No runs yet</h2><p class="f-run">Start one with <code>/qa-run</code>; this page fills in as it goes.</p></section>';
  else body += '<section class="feature" id="f-' + esc(slug(lead.target)) + '">' + renderFeature(m, lead, byId.get(lead.runId)) + "</section>";
  if (feats.length > 1) {
    body += '<section class="others"><h2 class="sec">Other test targets</h2><p class="sec-note">Their latest run each. Open one for its journeys and bugs.</p>'
      + feats.slice(1).map((f) => {
        const run = byId.get(f.runId);
        return '<details class="fold" data-key="' + esc("f:" + f.target) + '"><summary><span class="fold-title">' + t(f.title) + '</span><span class="fold-meta">'
          + esc(f.readiness.headline) + (f.readiness.facts ? ". " + esc(f.readiness.facts.replace(/\.$/, "")) : "") + (f.started ? ", " : "") + timeTag(f.started) + "</span></summary>"
          + '<section class="feature" id="f-' + esc(slug(f.target)) + '">' + renderFeature(m, f, run) + "</section></details>";
      }).join("") + "</section>";
  }

  const runRows = runs.map((r) => {
    const pct = r.progress.percent !== null ? Math.min(100, r.progress.percent) : 0;
    return "<tr><td class=\"code\">" + t(r.id) + "</td><td>" + t(r.target) + "</td><td>" + timeTag(r.started) + "</td>"
      + "<td>" + badge(r.status) + (r.manifestStatus && r.status === "paused" ? '<div class="muted">' + t(r.manifestStatus) + "</div>" : "")
      + (r.status === "complete" && !r.closed ? '<div class="muted">not closed</div>' : "") + "</td>"
      + "<td>" + esc(progText(r)) + '<div class="bar"><i style="width:' + pct + '%"></i></div>'
      + (r.ratePerHour !== null ? '<div class="muted">' + esc(r.ratePerHour) + "/h" + (r.eta ? ", ETA " + esc(fmtDuration(r.eta.hours)) : "") + "</div>" : "") + "</td>"
      + "<td>" + esc(tallyText(r)) + (r.superseded || r.outOfPlan ? '<div class="muted">' + esc([r.superseded ? r.superseded + " superseded" : "", r.outOfPlan ? r.outOfPlan + " out-of-plan" : ""].filter(Boolean).join(", ")) + "</div>" : "") + "</td>"
      + "<td>" + esc(sevText(r.bugs.bySeverity)) + "</td><td>" + (r.verified ? "yes" : "no") + "</td>"
      + "<td>" + (r.ship ? '<span class="st st-' + esc(r.ship.verdict.replace(/ /g, "-")) + '" title="' + esc(r.ship.conditions.join("; ")) + '">' + esc(r.ship.verdict) + "</span>" : '<span class="muted">—</span>') + "</td>"
      + "<td>" + (r.report ? '<a href="' + esc(r.report.rel) + '">report</a>' : '<span class="muted">—</span>') + "</td></tr>";
  }).join("");
  const runsTable = runs.length ? '<div class="scroll"><table><thead><tr><th>Run</th><th>Target</th><th>Started</th><th>Status</th><th>Progress</th><th>Verdicts</th><th>Bugs</th><th>Verified</th><th>Ship</th><th>Report</th></tr></thead><tbody>'
    + runRows + "</tbody></table></div>" : '<p class="muted">No runs yet.</p>';

  const trends = m.trends.length ? '<div class="trends">' + m.trends.map((tr) => '<div class="panel"><h3>' + t(humanize(tr.target)) + "</h3>" + svgTrend(tr)
    + '<ul class="legend"><li><i style="width:10px;height:10px;background:var(--pass)"></i>pass</li><li><i style="width:10px;height:10px;background:var(--fail)"></i>fail or error</li><li><i style="width:10px;height:10px;background:var(--blocked)"></i>blocked</li><li><i style="width:10px;height:10px;background:var(--error)"></i>bugs</li></ul>'
    + '<p class="muted" style="font-size:.8rem;margin:4px 0 0">' + tr.points.length + " runs, oldest first</p></div>").join("") + "</div>" : '<p class="muted">Trends appear once a target has two runs.</p>';

  const specRows = m.specs.map((s) => "<tr><td>" + t(s.target) + "</td><td>" + (s.hasChecklist ? s.criteria : '<span class="muted">no checklist</span>') + "</td>"
    + "<td>" + (s.journeys ? "P1 " + s.journeys.P1 + ", P2 " + s.journeys.P2 + (s.journeys.P3 ? ", P3 " + s.journeys.P3 : "") : '<span class="muted">—</span>') + "</td>"
    + "<td>human " + s.oracle.human + ", spec " + s.oracle.spec + ", suggested " + s.oracle["llm-suggested"] + "</td>"
    + "<td>" + (s.analysis.verdict === "missing" ? '<span class="muted">not analyzed</span>' : badge(s.analysis.verdict) + (s.analysis.stale ? ' <span class="muted">stale</span>' : "")) + "</td>"
    + "<td>" + (s.coverage ? esc(s.coverage.percent + "%") + (s.coverage.uncovered ? '<div class="muted">' + s.coverage.uncovered + " uncovered</div>" : "") : '<span class="muted">—</span>') + "</td>"
    + "<td>" + s.runs + (s.latestRun ? '<div class="muted">latest ' + esc(s.latestRun.status) + "</div>" : "") + "</td>"
    + "<td>" + (s.drift ? "out of date" : "in sync") + "</td></tr>").join("");
  const specsTable = m.specs.length ? '<div class="scroll"><table><thead><tr><th>Target</th><th>Checks</th><th>Journeys</th><th>Expected results from</th><th>Analysis</th><th>Coverage</th><th>Runs</th><th>Roles</th></tr></thead><tbody>'
    + specRows + "</tbody></table></div>" : '<p class="muted">No test plans under .qa/specs/.</p>';

  const kd = m.knownDefects;
  const kdHtml = !kd.present ? '<p class="muted">No known-defect registry (.qa/known-defects.json).</p>'
    : (kd.error ? '<div class="warn">' + esc(kd.error) + "</div>" : "") + (!kd.valid ? '<div class="warn">The registry does not validate (scripts/known-defects.sh validate).</div>' : "")
      + (kd.entries.length ? '<div class="scroll"><table><thead><tr><th>Id</th><th>Title</th><th>Severity</th><th>Ticket</th><th>Expiry</th><th>State</th></tr></thead><tbody>'
        + kd.entries.map((e) => "<tr><td class=\"code\">" + t(e.id) + "</td><td>" + t(e.title) + "</td><td>" + esc(e.severity) + "</td><td>" + t(e.ticket) + "</td><td>" + esc(e.expiry) + "</td><td>" + badge(e.state) + "</td></tr>").join("")
        + "</tbody></table></div>" : '<p class="muted">The registry is empty.</p>');

  const setup = '<dl class="setup"><dt>Plugin</dt><dd>' + esc(m.plugin.name + " " + m.plugin.version) + "</dd>"
    + "<dt>Roles</dt><dd>" + (c.present ? c.roles + " roles, constitution <code>" + esc(c.version || "unversioned") + "</code>" : "no constitution yet") + "</dd>"
    + "<dt>Profile</dt><dd>" + (cfg.present ? esc(cfg.profile) + (cfg.environment ? ", environment " + t(cfg.environment) : "") : "no .qa/config.json") + "</dd>"
    + (cfg.present ? "<dt>Gates</dt><dd>" + (cfg.gates.length ? esc(cfg.gates.join(", ")) : "none") + "</dd><dt>Parallel checks</dt><dd>" + (cfg.maxParallel !== null ? esc(cfg.maxParallel) : "default") + "</dd><dt>API writes</dt><dd>" + (cfg.allowApiWrites ? "allowed" : "not allowed") + "</dd>" : "")
    + "</dl>";

  const fold = (key, title, meta, inner) => '<details class="fold" data-key="' + esc(key) + '"><summary><span class="fold-title">' + esc(title) + '</span><span class="fold-meta">' + meta + "</span></summary>" + inner + "</details>";
  const records = '<section class="records"><h2>Records</h2>'
    + fold("rec:runs", "Every run", esc(runs.length + " runs, " + runs.filter((r) => r.status === "running").length + " running, " + runs.filter((r) => r.status === "stalled").length + " stalled"), runsTable)
    + fold("rec:trends", "Trends", esc(m.trends.length + " targets with history"), trends)
    + fold("rec:specs", "Test plans", esc(m.specs.length + " plans"), specsTable)
    + fold("rec:kd", "Known defects", kd.present ? esc(kd.counts.outstanding + " outstanding, " + kd.counts.expired + " expired, " + kd.counts.cleared + " cleared") : "no registry", kdHtml)
    + fold("rec:setup", "Setup", esc(cfg.present ? cfg.profile + " profile" : "no config"), setup) + "</section>";

  const doc = head + body + records
    + "<footer>Written by " + esc(m.plugin.name) + " qa-dashboard from this project's .qa/ folder. Read-only; credentials are never read or shown.</footer>";
  return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    + (opts.refresh ? '<noscript><meta http-equiv="refresh" content="' + opts.refresh + '"></noscript>\n' : "")
    + '<meta name="generator" content="qa-e2e-pilot qa-dashboard.js">\n<title>' + esc((lead ? lead.title + ": " + lead.readiness.headline : "QA") + " | " + m.project.name) + "</title>\n<style>" + CSS + "</style>\n</head>\n"
    + '<body data-generated="' + esc(m.generatedAt) + '" data-refresh="' + esc(opts.refresh || 0) + '" data-live="' + (live ? "1" : "0") + '"><div class="wrap">\n'
    + doc + "\n</div>\n<script>" + JS + "</script>\n</body>\n</html>\n";
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
