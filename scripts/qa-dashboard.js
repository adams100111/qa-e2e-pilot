#!/usr/bin/env node
/*
 * qa-dashboard.js — the project-level QA state dashboard (engine 0.12.1).
 * Reads a project's .qa/ tree (constitution, specs, runs, known-defect
 * registry) and shows where it stands: one self-contained HTML page, a
 * terminal view, or the model as JSON for other tools.
 *
 * USAGE:
 *   node qa-dashboard.js html [--project <dir>] [--out <file>] [--refresh <sec>]
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
  if (status === "running" || (status === "stalled" && ctx.nowMs - lastActivityMs < ACTIVE_STALL_WINDOW_MS)) {
    const loc = cur.cursor && typeof cur.cursor === "object" ? cur.cursor : {};
    const logged = (journal || []).filter((e) => e.event === "bug_logged").map((e) => ({
      id: str(e.bugId), title: str(e.title), severity: str(e.severity), layer: str(e.suspectedLayer) }));
    const fromLog = bugs.map((b) => ({ id: str(b.bug_id || b.id), title: str(b.title), severity: str(b.severity), layer: str(b.suspected_layer || b.layer) }));
    const seen = new Set(), latestBugs = [];
    for (const b of fromLog.concat(logged).reverse()) { const k = b.id || b.title; if (seen.has(k)) continue; seen.add(k); latestBugs.push(b); }
    run.active = {
      phase: str(cur.phase), criterion: str(loc.criterionId), persona: str(loc.personaId || loc.scenarioId), subState: str(loc.subState),
      events: (journal || []).slice(-10).reverse().map((e) => ({ t: str(e.t), text: describeEvent(e) })),
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

  const model = {
    schema: "qa-dashboard/1", generatedAt: new Date(nowMs).toISOString(), project: { name: path.basename(project), dir: project },
    plugin: pluginInfo(), stallMinutes: opts.stallMinutes, constitution, config: configInfo(config), specs, runs,
    active: runs.filter((r) => r.active).map((r) => r.id), trends, knownDefects: knownDefectsInfo(qa, nowMs),
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

const CSS = `
:root{--bg:#f6f7f9;--panel:#fff;--ink:#18202b;--muted:#5d6878;--line:#e3e7ed;--soft:#f0f2f5;--link:#1f5fbf;
--pass:#16794a;--fail:#c62828;--blocked:#b45309;--deferred:#5f6b7a;--error:#6d28d9;--run:#1f5fbf;--warn-bg:#fdecec;--warn-ink:#8f1d1d}
@media (prefers-color-scheme:dark){:root{--bg:#11151b;--panel:#181e26;--ink:#e5e9ef;--muted:#9aa5b4;--line:#2a333f;--soft:#1f2630;--link:#8ab4f8;--run:#8ab4f8;--warn-bg:#3d1a1a;--warn-ink:#f5b3b3}}
*,*::before,*::after{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans Arabic",Tahoma,sans-serif}
a{color:var(--link)}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.86em}
.wrap{max-width:1280px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:1.45rem;margin:0 0 4px}
h2{font-size:1.08rem;margin:28px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--line)}
h3{font-size:.95rem;margin:0 0 6px}
.meta{color:var(--muted);font-size:.86rem;display:flex;flex-wrap:wrap;gap:4px 18px}
.meta b{color:var(--ink);font-weight:600}
.cards{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));margin-top:16px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.kpi b{display:block;font-size:1.5rem}
.kpi span{color:var(--muted);font-size:.82rem}
.scroll{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:.86rem}
th,td{text-align:start;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:.76rem;text-transform:uppercase;letter-spacing:.04em;background:var(--soft)}
tr:last-child td{border-bottom:0}
.st{display:inline-block;border-radius:999px;padding:1px 9px;font-size:.78rem;font-weight:600;color:#fff;background:var(--deferred)}
.st-running{background:var(--run)}.st-stalled{background:var(--blocked)}.st-paused{background:var(--deferred)}.st-complete{background:var(--pass)}
.st-BLOCKED,.st-NOT-SHIP-READY,.st-expired{background:var(--fail)}.st-OK,.st-SHIP-READY,.st-cleared{background:var(--pass)}.st-outstanding{background:var(--blocked)}
.bar{height:6px;background:var(--soft);border-radius:3px;overflow:hidden;min-width:80px;margin-top:4px}
.bar i{display:block;height:100%;background:var(--run)}
.warn{background:var(--warn-bg);color:var(--warn-ink);border-radius:8px;padding:8px 12px;margin:8px 0;font-weight:600}
.active{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
ol.events{margin:6px 0 0;padding-inline-start:0;list-style:none;font-size:.84rem}
ol.events li{padding:3px 0;border-bottom:1px dashed var(--line)}
ol.events time{color:var(--muted);margin-inline-end:8px}
.muted{color:var(--muted)}
.trends{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
svg.trend{max-width:100%;height:auto;display:block;margin-top:6px}
svg .b-pass{fill:var(--pass)}svg .b-fail{fill:var(--fail)}svg .b-blocked{fill:var(--blocked)}svg .b-bugs{fill:var(--error)}svg .axis{stroke:var(--line)}
.legend{font-size:.78rem;color:var(--muted);display:flex;gap:12px;flex-wrap:wrap;margin-top:4px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-inline-end:4px;vertical-align:middle}
footer{margin-top:32px;color:var(--muted);font-size:.8rem}
`;

function renderHtml(m, opts) {
  const runs = m.runs;
  const count = (s) => runs.filter((r) => r.status === s).length;
  const openBugs = runs.length ? runs[0].bugs.total : 0;
  const c = m.constitution, cfg = m.config;
  const head = '<header><h1>QA dashboard — ' + t(m.project.name) + "</h1>"
    + '<div class="meta"><span><b>Generated</b> ' + esc(m.generatedAt) + "</span>"
    + "<span><b>Plugin</b> " + esc(m.plugin.name + " " + m.plugin.version) + "</span>"
    + "<span><b>Constitution</b> " + (c.present ? '<span class="mono">' + esc(c.version || "unversioned") + "</span> · " + c.roles + " roles" : "none") + "</span>"
    + "<span><b>Profile</b> " + (cfg.present ? esc(cfg.profile) + (cfg.environment ? " · env " + t(cfg.environment) : "") + (cfg.gates.length ? " · gates " + esc(cfg.gates.join(", ")) : "")
      + (cfg.maxParallel !== null ? " · maxParallel " + cfg.maxParallel : "") + " · API writes " + (cfg.allowApiWrites ? "on" : "off") : "no config.json") + "</span>"
    + (opts.refresh ? "<span><b>Auto-refresh</b> every " + opts.refresh + "s</span>" : "") + "</div></header>";

  const kpis = '<section class="cards">'
    + [[count("running"), "running"], [count("stalled"), "stalled"], [runs.length, "runs"], [m.specs.length, "specs"],
      [openBugs, "bugs in the latest run"], [m.knownDefects.present ? m.knownDefects.counts.outstanding : 0, "known defects outstanding"]]
      .map((k) => '<div class="panel kpi"><b>' + esc(k[0]) + "</b><span>" + esc(k[1]) + "</span></div>").join("") + "</section>";

  const activeRuns = runs.filter((r) => r.active);
  const active = "<h2>Active runs</h2>" + (activeRuns.length ? '<div class="active">' + activeRuns.map((r) => {
    const a = r.active;
    const pct = r.progress.percent !== null ? Math.min(100, r.progress.percent) : 0;
    return '<article class="panel"><h3>' + badge(r.status) + " " + t(r.id) + "</h3>"
      + (r.status === "stalled" ? '<div class="warn">Stalled: no journal activity for ' + esc(fmtDuration(r.idleMinutes / 60)) + " (threshold " + m.stallMinutes + "m). Resume with /qa-resume " + t(r.id) + ".</div>" : "")
      + '<div class="meta"><span><b>Target</b> ' + t(r.target) + "</span><span><b>Phase</b> " + t(a.phase || "—") + "</span>"
      + "<span><b>Criterion</b> " + t(a.criterion || "—") + "</span><span><b>Persona</b> " + t(a.persona || "—") + "</span>"
      + (a.subState ? "<span><b>Step</b> " + t(a.subState) + "</span>" : "") + "</div>"
      + '<div class="meta"><span><b>Progress</b> ' + esc(progText(r)) + "</span>"
      + (r.ratePerHour !== null ? "<span><b>Rate</b> " + esc(r.ratePerHour) + "/h</span>" : "")
      + (r.eta ? "<span><b>ETA</b> " + esc(fmtDuration(r.eta.hours)) + " (" + esc(r.eta.at) + ")</span>" : "") + "</div>"
      + '<div class="bar"><i style="width:' + pct + '%"></i></div>'
      + "<h3 style=\"margin-top:10px\">Latest events</h3><ol class=\"events\">" + a.events.map((e) => "<li><time>" + esc(e.t.replace("T", " ").replace("Z", "")) + "</time>" + t(e.text) + "</li>").join("") + "</ol>"
      + "<h3 style=\"margin-top:10px\">Latest bugs</h3>" + (a.bugs.length ? '<ol class="events">' + a.bugs.map((b) => "<li>" + t(b.title || b.id)
        + ' <span class="muted">' + esc([b.severity, b.layer].filter(Boolean).join(" · ")) + "</span></li>").join("") + "</ol>" : '<p class="muted">None logged.</p>')
      + "</article>";
  }).join("") + "</div>" : '<p class="muted">No run is in progress.</p>');

  const runRows = runs.map((r) => {
    const pct = r.progress.percent !== null ? Math.min(100, r.progress.percent) : 0;
    return "<tr><td class=\"mono\">" + t(r.id) + "</td><td>" + t(r.target) + "</td><td>" + esc((r.started || "").replace("T", " ").replace(/:\d\d(\.\d+)?Z$/, "Z")) + "</td>"
      + "<td>" + badge(r.status) + (r.manifestStatus && r.status === "paused" ? '<div class="muted">' + t(r.manifestStatus) + "</div>" : "")
      + (r.status === "complete" && !r.closed ? '<div class="muted">not closed</div>' : "") + "</td>"
      + "<td>" + esc(progText(r)) + '<div class="bar"><i style="width:' + pct + '%"></i></div>'
      + (r.ratePerHour !== null ? '<div class="muted">' + esc(r.ratePerHour) + "/h" + (r.eta ? " · ETA " + esc(fmtDuration(r.eta.hours)) : "") + "</div>" : "") + "</td>"
      + "<td>" + esc(tallyText(r)) + (r.superseded || r.outOfPlan ? '<div class="muted">' + esc((r.superseded ? r.superseded + " superseded" : "") + (r.superseded && r.outOfPlan ? " · " : "") + (r.outOfPlan ? r.outOfPlan + " out-of-plan" : "")) + "</div>" : "") + "</td>"
      + "<td>" + esc(sevText(r.bugs.bySeverity)) + "</td><td>" + (r.verified ? "yes" : "no") + "</td>"
      + "<td>" + (r.ship ? '<span class="st st-' + esc(r.ship.verdict.replace(/ /g, "-")) + '" title="' + esc(r.ship.conditions.join("; ")) + '">' + esc(r.ship.verdict) + "</span>" : '<span class="muted">—</span>') + "</td>"
      + "<td>" + (r.report ? '<a href="' + esc(r.report.rel) + '">report</a>' : '<span class="muted">—</span>') + "</td></tr>";
  }).join("");
  const runsTable = "<h2>Runs</h2>" + (runs.length ? '<div class="scroll"><table><thead><tr><th>Run</th><th>Target</th><th>Started</th><th>Status</th><th>Progress</th><th>Verdicts</th><th>Bugs</th><th>Verified</th><th>Ship</th><th>Report</th></tr></thead><tbody>'
    + runRows + "</tbody></table></div>" : '<p class="muted">No runs yet.</p>');

  const specRows = m.specs.map((s) => "<tr><td>" + t(s.target) + "</td><td>" + (s.hasChecklist ? s.criteria : '<span class="muted">no checklist</span>') + "</td>"
    + "<td>" + (s.journeys ? "P1 " + s.journeys.P1 + " · P2 " + s.journeys.P2 + (s.journeys.P3 ? " · P3 " + s.journeys.P3 : "") : '<span class="muted">—</span>') + "</td>"
    + "<td>human " + s.oracle.human + " · spec " + s.oracle.spec + " · llm-suggested " + s.oracle["llm-suggested"] + "</td>"
    + "<td>" + (s.analysis.verdict === "missing" ? '<span class="muted">not analyzed</span>' : badge(s.analysis.verdict) + (s.analysis.stale ? ' <span class="muted">stale</span>' : "")) + "</td>"
    + "<td>" + (s.coverage ? esc(s.coverage.percent + "%") + (s.coverage.uncovered ? '<div class="muted">' + s.coverage.uncovered + " uncovered</div>" : "") : '<span class="muted">—</span>') + "</td>"
    + "<td>" + s.runs + (s.latestRun ? '<div class="muted">latest ' + esc(s.latestRun.status) + "</div>" : "") + "</td>"
    + "<td>" + (s.drift ? "stale roles" : "in sync") + "</td></tr>").join("");
  const specsTable = "<h2>Specs</h2>" + (m.specs.length ? '<div class="scroll"><table><thead><tr><th>Target</th><th>Criteria</th><th>Journeys</th><th>Oracle sources</th><th>Analysis</th><th>Coverage</th><th>Runs</th><th>Roles</th></tr></thead><tbody>'
    + specRows + "</tbody></table></div>" : '<p class="muted">No specs under .qa/specs/.</p>');

  const trends = m.trends.length ? "<h2>Trends</h2>" + '<div class="trends">' + m.trends.map((tr) => '<div class="panel"><h3>' + t(tr.target) + "</h3>" + svgTrend(tr)
    + '<div class="legend"><span><i style="background:var(--pass)"></i>pass</span><span><i style="background:var(--fail)"></i>fail/error</span><span><i style="background:var(--blocked)"></i>blocked</span><span><i style="background:var(--error)"></i>bugs</span></div>'
    + '<div class="muted" style="font-size:.78rem">' + tr.points.length + " runs, oldest first</div></div>").join("") + "</div>" : "";

  const kd = m.knownDefects;
  const kdHtml = "<h2>Known defects</h2>" + (!kd.present ? '<p class="muted">No .qa/known-defects.json registry.</p>'
    : (kd.error ? '<div class="warn">' + esc(kd.error) + "</div>" : "") + (!kd.valid ? '<div class="warn">The registry does not validate (scripts/known-defects.sh validate).</div>' : "")
      + '<p class="muted">' + kd.counts.outstanding + " outstanding · " + kd.counts.expired + " expired · " + kd.counts.cleared + " cleared</p>"
      + (kd.entries.length ? '<div class="scroll"><table><thead><tr><th>Id</th><th>Title</th><th>Severity</th><th>Ticket</th><th>Expiry</th><th>State</th></tr></thead><tbody>'
        + kd.entries.map((e) => "<tr><td class=\"mono\">" + t(e.id) + "</td><td>" + t(e.title) + "</td><td>" + esc(e.severity) + "</td><td>" + t(e.ticket) + "</td><td>" + esc(e.expiry) + "</td><td>" + badge(e.state) + "</td></tr>").join("")
        + "</tbody></table></div>" : ""));

  const body = head + kpis + active + runsTable + specsTable + trends + kdHtml
    + "<footer>Rendered by " + esc(m.plugin.name) + " qa-dashboard.js from the project's .qa/ record. Read-only; credentials are never read or shown.</footer>";
  return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    + (opts.refresh ? '<meta http-equiv="refresh" content="' + opts.refresh + '">\n' : "")
    + '<meta name="generator" content="qa-e2e-pilot qa-dashboard.js">\n<title>' + esc("QA dashboard — " + m.project.name) + "</title>\n<style>" + CSS + "</style>\n</head>\n<body><div class=\"wrap\">\n"
    + body + "\n</div></body>\n</html>\n";
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
  const o = { mode: argv[0], project: ".", out: null, refresh: 0, watch: 0, stallMinutes: 30, now: process.env.QA_DASHBOARD_NOW || "" };
  const usage = "usage: qa-dashboard.sh html [--project <dir>] [--out <file>] [--refresh <sec>] | tui [--project <dir>] [--watch <sec>] | json [--project <dir>]";
  if (!o.mode || o.mode === "-h" || o.mode === "--help") { process.stdout.write(usage + "\n"); process.exit(o.mode ? 0 : 2); }
  if (!["html", "tui", "json"].includes(o.mode)) die("unknown mode " + o.mode + "\n" + usage);
  const int = (v, name) => { const n = Number(v); if (!Number.isInteger(n) || n < 0) die(name + " needs a whole number of seconds/minutes"); return n; };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i], v = argv[i + 1];
    if (a === "--project") { o.project = v; i++; }
    else if (a === "--out") { o.out = v; i++; }
    else if (a === "--refresh") { o.refresh = int(v, a); i++; }
    else if (a === "--watch") { o.watch = int(v, a); i++; }
    else if (a === "--stall-minutes") { o.stallMinutes = int(v, a); i++; }
    else if (a === "--now") { o.now = v; i++; }
    else die("unknown option " + a + "\n" + usage);
    if (v === undefined) die(a + " needs a value");
  }
  if (o.now && !Number.isFinite(Date.parse(o.now))) die("--now must be an ISO-8601 time");
  return o;
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
    const m = buildDashboard({ project: o.project, nowMs: nowMs(), stallMinutes: o.stallMinutes, linkBase: path.dirname(out) });
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, renderHtml(m, { refresh: o.refresh }));
    process.stdout.write("wrote " + out + " (" + m.runs.length + " runs, " + m.specs.length + " specs, " + m.active.length + " active)\n");
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
else module.exports = { runStatus, computeRate, computeEta, fmtDuration, resolveTarget, describeEvent, makeRedactor, buildDashboard, renderHtml, renderTui };
