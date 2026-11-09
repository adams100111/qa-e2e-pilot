#!/usr/bin/env node
/*
 * render-report.js — the deterministic QA report renderer (engine 0.10.0,
 * ADR-0028). Builds report.html + report.md for one run directory from its
 * on-disk record — checkpoint.json, verification.json, run-manifest.json,
 * checklist.json, bug-log.json, stack-profile.json and evidence/ — so the
 * agent never hand-writes report HTML. Re-runnable on any run, including runs
 * recorded before 0.10.0 (their loose images render as "not provenance-bound").
 *
 * USAGE:
 *   node render-report.js <run-dir | run-id> [--embed] [--templates <dir>] [--quiet]
 *     <run-dir>   .qa/runs/<run-id>/ (a bare run-id is resolved under ./.qa/runs/)
 *     --embed     inline every screenshot as a base64 data: URI -> one portable
 *                 report.html (report.md keeps relative links either way)
 *     --templates defaults to ../skills/writing-qa-reports/templates
 *
 * The HTML is self-contained: inline CSS + JS from templates/report.html, no
 * external request of any kind, relative image paths (works from file://).
 * Every value read from the run is HTML-escaped. Verdicts shown are the
 * verifier's where verification.json re-checked the criterion (its override
 * wins, CLAUDE.md invariant), else the in-run verdict — and the report says
 * which. Dependency-free: node's fs/path/crypto only.
 */
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const VERDICTS = ["pass", "fail", "blocked", "deferred", "error"];
const IMAGE_EXT = /\.(png|jpe?g|webp|gif)$/i;
const MIME = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif" };

function die(msg) { process.stderr.write("render-report: " + msg + "\n"); process.exit(1); }

function parseArgs(argv) {
  const o = { embed: false, quiet: false, templates: path.join(__dirname, "..", "skills", "writing-qa-reports", "templates"), target: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--embed") o.embed = true;
    else if (a === "--quiet") o.quiet = true;
    else if (a === "--templates") o.templates = argv[++i];
    else if (a === "-h" || a === "--help") { process.stdout.write("usage: render-report.js <run-dir|run-id> [--embed] [--templates <dir>] [--quiet]\n"); process.exit(0); }
    else if (a.startsWith("--")) die("unknown option " + a);
    else if (o.target === null) o.target = a;
    else die("unexpected argument " + a);
  }
  if (!o.target) die("usage: render-report.js <run-dir|run-id> [--embed] [--templates <dir>]");
  return o;
}

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return fallback; }
}

function esc(v) {
  return String(v === undefined || v === null ? "" : v)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
// Markdown: neutralise table pipes / newlines in a cell or bullet.
function mdText(v) { return String(v === undefined || v === null ? "" : v).replace(/\r?\n+/g, " ").replace(/\|/g, "\\|"); }
function urlPath(rel) { return rel.split("/").map(encodeURIComponent).join("/"); }
function slug(s) { return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "x"; }
function sha256(file) { return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"); }
function isFile(p) { try { return fs.statSync(p).isFile(); } catch (_) { return false; } }
function asText(v) { return typeof v === "string" ? v : (v === undefined || v === null ? "" : JSON.stringify(v)); }

function resolveRunDir(target) {
  if (fs.existsSync(path.join(target, "checkpoint.json"))) return target;
  const byId = path.join(".qa", "runs", target);
  if (/^[^/\\]+$/.test(target) && fs.existsSync(path.join(byId, "checkpoint.json"))) return byId;
  die("no checkpoint.json in '" + target + "' (pass .qa/runs/<run-id> or a run-id from the project root)");
}

function loadBugs(raw) {
  let list = [];
  if (Array.isArray(raw)) list = raw;
  else if (raw && Array.isArray(raw.entries)) list = raw.entries;
  else if (raw && Array.isArray(raw.bugs)) list = raw.bugs;
  return list.filter((b) => b && typeof b === "object");
}

function stackLine(stack) {
  if (!stack || typeof stack !== "object") return "";
  if (typeof stack.stack === "string") return stack.stack;
  const comps = Array.isArray(stack.components) ? stack.components : [];
  const parts = comps.map((c) => [c.framework, c.language].filter(Boolean).join(" / ") + (c.role ? " (" + c.role + ")" : "")).filter((s) => s.trim());
  const line = parts.join(", ");
  return [line, stack.mode ? "mode " + stack.mode : "", stack.environment ? "env " + stack.environment : ""].filter(Boolean).join(" · ");
}

// ---------------------------------------------------------------------------
// Evidence: the screenshots + other files of one (criterion, persona).
// ---------------------------------------------------------------------------
function collectEvidence(runDir, c) {
  const crit = c.criterion_id;
  const relDir = c.persona ? "evidence/" + c.persona + "/" + crit : "evidence/" + crit;
  const absDir = path.join(runDir, relDir);
  let names = [];
  try { names = fs.readdirSync(absDir).sort(); } catch (_) { names = []; }

  const shots = [];
  const claimedImages = new Set();
  for (const n of names) {
    if (!/^screenshot-.*\.json$/.test(n)) continue;
    const sc = readJSON(path.join(absDir, n), null);
    if (!sc || typeof sc !== "object" || typeof sc.image !== "string" || /[/\\]|\.\./.test(sc.image)) continue;
    const imgAbs = path.join(absDir, sc.image);
    claimedImages.add(sc.image);
    let integrity = "missing";
    if (isFile(imgAbs)) integrity = sha256(imgAbs) === sc.sha256 ? "ok" : "altered";
    const ref = sc.provenance && typeof sc.provenance.sourceRef === "string" ? sc.provenance.sourceRef : "";
    shots.push({
      rel: relDir + "/" + sc.image, abs: imgAbs, sidecarRel: relDir + "/" + n,
      phase: sc.phase === "before" || sc.phase === "after" ? sc.phase : "image",
      label: typeof sc.label === "string" ? sc.label : "",
      fullPage: sc.fullPage === true, element: typeof sc.element === "string" ? sc.element : "",
      ref, binding: typeof sc.binding === "string" ? sc.binding : "", integrity, legacy: false,
      mime: typeof sc.mime === "string" ? sc.mime : "",
    });
  }
  // Loose images (runs recorded before 0.10.0, or an image never recorded):
  // shown, but marked as not provenance-bound.
  const loose = names.filter((n) => IMAGE_EXT.test(n) && !claimedImages.has(n)).map((n) => relDir + "/" + n);
  for (const ref of Array.isArray(c.evidence_refs) ? c.evidence_refs : []) {
    if (typeof ref === "string" && IMAGE_EXT.test(ref) && !/\.\./.test(ref) && !ref.startsWith("/")
        && !shots.some((s) => s.rel === ref) && !loose.includes(ref) && isFile(path.join(runDir, ref))) loose.push(ref);
  }
  for (const rel of loose) {
    const base = path.basename(rel).toLowerCase();
    shots.push({
      rel, abs: path.join(runDir, rel), sidecarRel: "", label: "",
      phase: base.includes("before") ? "before" : (base.includes("after") ? "after" : "image"),
      fullPage: false, element: "", ref: "", binding: "", integrity: isFile(path.join(runDir, rel)) ? "ok" : "missing", legacy: true, mime: "",
    });
  }
  const order = { before: 0, after: 1, image: 2 };
  shots.sort((a, b) => (order[a.phase] - order[b.phase]) || a.rel.localeCompare(b.rel));

  const files = names.filter((n) => !IMAGE_EXT.test(n) && !/^screenshot-.*\.json$/.test(n)).map((n) => relDir + "/" + n);
  for (const ref of Array.isArray(c.evidence_refs) ? c.evidence_refs : []) {
    if (typeof ref === "string" && !IMAGE_EXT.test(ref) && !/^evidence\/.*screenshot-.*\.json$/.test(ref)
        && !files.includes(ref) && !/\.\./.test(ref) && !ref.startsWith("/")) files.push(ref);
  }
  return { relDir, shots, files };
}

function shotCaption(cid, persona, s) {
  const bits = [cid];
  if (persona) bits.push(persona);
  bits.push(s.phase === "image" ? "screenshot" : s.phase + (s.label ? " (" + s.label + ")" : ""));
  if (s.fullPage) bits.push("full page");
  if (s.element) bits.push(s.element);
  return bits.join(" · ");
}

function shotSrc(s, embed) {
  if (!embed) return urlPath(s.rel);
  if (!isFile(s.abs)) return urlPath(s.rel);
  const ext = path.extname(s.abs).slice(1).toLowerCase();
  const mime = s.mime || MIME[ext] || "application/octet-stream";
  return "data:" + mime + ";base64," + fs.readFileSync(s.abs).toString("base64");
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
// frozenPlanIds(runDir) -> Set of planned criterion ids, or null when the run
// has no journal or its journal never froze a plan. Torn/invalid lines are
// skipped, exactly like the fold.
function frozenPlanIds(runDir) {
  let text;
  try { text = fs.readFileSync(path.join(runDir, "journal.ndjson"), "utf8"); } catch (e) { return null; }
  const ids = new Set();
  let frozen = false;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch (err) { continue; }
    if (!e || typeof e !== "object") continue;
    if (e.event === "plan_frozen") {
      frozen = true;
      for (const c of Array.isArray(e.criteria) ? e.criteria : []) if (c && typeof c === "object") ids.add(String(c.criterionId || ""));
    } else if (e.event === "plan_amended") ids.add(String(e.criterionId || ""));
  }
  return frozen ? ids : null;
}
// opts.evidence === false skips the per-criterion evidence scan (no screenshot
// hashing) for callers that only need verdicts, e.g. qa-dashboard.js; the
// report itself always passes no opts.
function buildModel(runDir, opts) {
  const withEvidence = !(opts && opts.evidence === false);
  const checkpoint = readJSON(path.join(runDir, "checkpoint.json"), null);
  if (!checkpoint || typeof checkpoint !== "object") die("checkpoint.json in " + runDir + " is not valid JSON");
  const manifest = readJSON(path.join(runDir, "run-manifest.json"), {}) || {};
  const checklist = readJSON(path.join(runDir, "checklist.json"), []);
  const verificationRaw = readJSON(path.join(runDir, "verification.json"), null);
  const bugs = loadBugs(readJSON(path.join(runDir, "bug-log.json"), []));
  const stack = readJSON(path.join(runDir, "stack-profile.json"), null);
  const traceability = readJSON(path.join(runDir, "traceability.json"), null);

  const rows = {};
  for (const r of Array.isArray(checklist) ? checklist : []) if (r && r.id) rows[r.id] = r;
  for (const r of Array.isArray(manifest.checklist) ? manifest.checklist : []) {
    const id = r && (r.criterion_id || r.id);
    if (id) rows[id] = Object.assign({}, r, rows[id] || {});
  }

  const verification = Array.isArray(verificationRaw) ? verificationRaw : null;
  const vByKey = {};
  const runLevel = [];
  for (const v of verification || []) {
    if (!v || typeof v !== "object") continue;
    if (String(v.criterionId || "").startsWith("__")) runLevel.push(v);
    else vByKey[(v.criterionId || "") + "\u0000" + (v.persona || "")] = v;
  }

  // 0.11.0 (ADR-0029) — count the LATEST AUTHORITATIVE verdict per criterion.
  // (1) Supersession: a current fold has already moved superseded persona-less
  // rows to checkpoint.superseded[]; a checkpoint.json folded by an older
  // engine still carries them, so the same rule applies here (a persona-less
  // row with a strictly LATER persona-scoped row for the same criterion).
  // (2) Out-of-plan: when the run's journal froze a plan (plan_frozen, plus any
  // plan_amended), a row whose criterion_id is not a planned id (e.g. several
  // ids joined into one by a shell loop) is a process anomaly, not a
  // criterion — listed, never tallied. No journal or no plan: nothing is
  // treated as out-of-plan.
  const allRows = (Array.isArray(checkpoint.criteria) ? checkpoint.criteria : []).filter((c) => c && c.criterion_id);
  const superseded = (Array.isArray(checkpoint.superseded) ? checkpoint.superseded : []).filter((c) => c && c.criterion_id)
    .map((c) => ({ id: String(c.criterion_id), persona: c.persona || "", verdict: String(c.verdict || ""), at: asText(c.checkpointed_at || ""),
      by: c.superseded_by && typeof c.superseded_by === "object" ? c.superseded_by : {} }));
  const liveRows = [];
  for (const c of allRows) {
    const later = (c.persona || "") === "" ? allRows.filter((r) => r.criterion_id === c.criterion_id && (r.persona || "") !== ""
      && String(r.checkpointed_at || "") > String(c.checkpointed_at || "")) : [];
    if (later.length) {
      const by = later.reduce((a, r) => (String(r.checkpointed_at || "") > String(a.checkpointed_at || "") ? r : a));
      superseded.push({ id: String(c.criterion_id), persona: "", verdict: String(c.verdict || ""), at: asText(c.checkpointed_at || ""),
        by: { persona: by.persona || "", verdict: by.verdict, checkpointed_at: by.checkpointed_at } });
    } else liveRows.push(c);
  }
  const planIds = frozenPlanIds(runDir);
  const planned = planIds !== null;
  const outOfPlan = planned ? liveRows.filter((c) => !planIds.has(String(c.criterion_id))).map((c) => ({
    id: String(c.criterion_id), persona: c.persona || "", verdict: String(c.verdict || ""), lastAction: asText(c.last_action || "") })) : [];

  const criteria = liveRows.filter((c) => !planned || planIds.has(String(c.criterion_id))).map((c) => {
    const inRun = VERDICTS.includes(String(c.verdict || "").toLowerCase()) ? String(c.verdict).toLowerCase() : "error";
    const v = vByKey[c.criterion_id + "\u0000" + (c.persona || "")];
    const checked = !!(v && v.inRunVerdict === inRun);
    const verdict = checked && VERDICTS.includes(v.verifierVerdict) ? v.verifierVerdict : inRun;
    const confidence = checked && v.confidence ? v.confidence : (c.confidence || "high");
    const row = rows[c.criterion_id] || {};
    const ev = withEvidence ? collectEvidence(runDir, c) : { relDir: "", shots: [], files: [] };
    const reasons = checked && Array.isArray(v.reasons) ? v.reasons.map(String) : [];
    for (const s of ev.shots) {
      s.flagged = s.integrity !== "ok" || reasons.some((r) => (s.sidecarRel && r.includes(s.sidecarRel)) || r.includes(s.rel));
    }
    return {
      id: c.criterion_id, persona: c.persona || "", inRun, verdict, confidence, checked,
      overridden: checked && verdict !== inRun, reasons,
      title: asText(row.title || row.label || row.surface || ""), oracle: asText(row.oracle || ""),
      tags: Array.isArray(row.tags) ? row.tags.map(String) : [],
      flaky: typeof c.flaky === "boolean" ? c.flaky : (Array.isArray(row.tags) && row.tags.includes("flaky") ? true : null),
      stale: !!(v && v.inRunVerdict !== inRun),
      lastAction: asText(c.last_action || ""), kinds: Array.isArray(c.kinds) ? c.kinds.map(String) : [],
      bugRef: c.bug_ref ? String(c.bug_ref) : "", nonUi: asText(c.nonUiActionReason || ""),
      shots: ev.shots, files: ev.files, anchor: "c-" + slug(c.criterion_id + (c.persona ? "-" + c.persona : "")),
    };
  });

  const tally = { pass: 0, fail: 0, blocked: 0, deferred: 0, error: 0 };
  for (const c of criteria) tally[c.verdict] += 1;
  const evidenced = criteria.filter((c) => c.verdict === "pass" || c.verdict === "fail" || c.inRun === "pass" || c.inRun === "fail");
  const shotCount = criteria.reduce((n, c) => n + c.shots.length, 0);

  return {
    runDir, runId: manifest.run_id || checkpoint.run_id || path.basename(path.resolve(runDir)),
    feature: asText(manifest.target_feature || manifest.feature || ""), buildId: asText(manifest.build_id || ""),
    baseUrl: asText(manifest.base_url || ""), started: asText(manifest.started_at || ""), ended: asText(manifest.ended_at || ""),
    stack: stackLine(stack), cost: manifest.cost && typeof manifest.cost === "object" ? manifest.cost : null,
    criteria, tally, total: criteria.length,
    low: criteria.filter((c) => c.confidence === "low").length,
    verified: verification !== null, checkedCount: criteria.filter((c) => c.checked).length,
    overridden: criteria.filter((c) => c.overridden).length, runLevel,
    evidencedTotal: evidenced.length, evidencedWithShot: evidenced.filter((c) => c.shots.some((s) => !s.legacy)).length,
    shotCount, bugs, traceability, superseded, outOfPlan,
    distinct: new Set(criteria.map((c) => c.id)).size,
    ship: buildShip(runDir, criteria, rows, bugs, allRows, verification !== null),
    ux: buildUx(runDir, checkpoint),
  };
}

// ---------------------------------------------------------------------------
// UX findings (advisory). The always-on UX sweep journals every ux[]/axe entry
// of an observe round as finding_observed {criterionId: "ux-sweep:<surfaceId>",
// source: "ux", method: <detector>, url: <selector>}; the fold keeps one per
// surface + detector + selector. ux-sweep.json lists the objective defects the
// sweep saw on a surface with no visual-ux criterion in the frozen plan. Both
// are advisory: listed, never tallied, never a verdict. Null when the run has
// neither (so a run without a sweep renders exactly as before).
// ---------------------------------------------------------------------------
const UX_PREFIX = "ux-sweep:";
function uxKey(f) { return f.surface + "\u0000" + f.detector + "\u0000" + f.selector; }
function dedupUx(list) {
  const seen = new Set();
  return list.filter((f) => { const k = uxKey(f); if (seen.has(k)) return false; seen.add(k); return true; });
}
function buildUx(runDir, checkpoint) {
  const swept = dedupUx((Array.isArray(checkpoint.findings) ? checkpoint.findings : [])
    .filter((f) => f && typeof f === "object" && f.source === "ux")
    .map((f) => {
      const cid = asText(f.criterionId);
      return { surface: cid.startsWith(UX_PREFIX) ? cid.slice(UX_PREFIX.length) : cid, detector: asText(f.method),
        selector: asText(f.url), message: asText(f.message), channel: asText(f.channel) };
    }));
  const raw = readJSON(path.join(runDir, "ux-sweep.json"), null);
  const list = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.outsidePlan) ? raw.outsidePlan : []);
  const outsidePlan = dedupUx(list.filter((e) => e && typeof e === "object").map((e) => ({
    surface: asText(e.surfaceId || e.surface), detector: asText(e.detector), selector: asText(e.selector),
    message: asText(e.message), variant: e.variant && typeof e.variant === "object"
      ? ["viewport", "locale", "colorScheme"].map((k) => e.variant[k]).filter((v) => typeof v === "string" && v).join(" · ") : asText(e.variant),
  })));
  if (!swept.length && !outsidePlan.length) return null;
  return { swept, outsidePlan };
}


// ---------------------------------------------------------------------------
// Ship readiness (D6): SHIP-READY iff census uncovered = 0, every P1 journey
// passes, no coding-layer (route|service|migration|DB) fail on a P1 criterion,
// no verifier override or re-adjudication dispute on a P1 criterion, and no P1
// low-confidence pass left unreviewed by re-adjudication (ADR-0033). Null (no
// section) for a run with neither coverage.json nor journeys.json whose
// profile is not "ship".
// ---------------------------------------------------------------------------
const CODING_LAYERS = ["route", "service", "migration", "db"];
const DISPUTED_PREFIX = "verifier-disagrees:";
const isDisputed = (lastAction) => String(lastAction || "").startsWith(DISPUTED_PREFIX);

// Same rule as scripts/journeys.sh status (after ADR-0029 supersession), over
// the raw checkpoint rows: a persona-less row is dropped when a persona-scoped
// row for the criterion is strictly later; any fail|error -> fail, all pass ->
// pass, otherwise incomplete. Journey: any failed step -> fail; else all pass.
// `adjust(row)` maps a raw row to the verdict the report shows for it (the
// verifier's where verification.json re-checked it, M7); a step whose record
// the re-adjudicator disputed is marked `disputed`.
function journeyStatus(journeys, checkpointRows, adjust) {
  const rows = checkpointRows.filter((c) => c && typeof c === "object");
  const verdictOf = adjust || ((r) => r.verdict);
  const step = (id) => {
    const mine = rows.filter((r) => r.criterion_id === id);
    const pr = mine.filter((r) => (r.persona || "") !== "");
    const eff = mine.filter((r) => (r.persona || "") === ""
      && !pr.some((p) => String(p.checkpointed_at || "") > String(r.checkpointed_at || ""))).concat(pr);
    const disputed = eff.some((r) => isDisputed(r.last_action));
    const vs = eff.map(verdictOf);
    if (!vs.length) return { verdict: "incomplete", disputed };
    if (vs.some((v) => v === "fail" || v === "error")) return { verdict: "fail", disputed };
    if (vs.every((v) => v === "pass")) return { verdict: "pass", disputed };
    return { verdict: "incomplete", disputed };
  };
  return journeys.filter((j) => j && typeof j === "object").map((j) => {
    const steps = (Array.isArray(j.steps) ? j.steps : []).map((id) => Object.assign({ criterionId: id }, step(id)));
    const verdict = steps.some((s) => s.verdict === "fail") ? "fail"
      : (steps.length > 0 && steps.every((s) => s.verdict === "pass") ? "pass" : "incomplete");
    return { id: j.id, priority: j.priority, steps, verdict };
  });
}

// readAdjudication(runDir) -> what re-adjudication left in adjudication/ (ADR-0033):
// {state: "ran"|"unavailable"|"not-run", decisions, banner, refused:[label],
//  reviewed:Set(label)}. A decision counts as reviewed only when apply.txt
// shows it applied ("applied: <label> …") or a no-op ("noop: <label> …"); an
// entry apply rejected ("ADJUDICATION: rejected entry …"), one checkpoint.sh
// refused, or a batch refused as an upgrade leaves it unreviewed. <label> is
// <criterionId>[@<persona>], as adjudication.sh prints it.
function readAdjudication(runDir) {
  const dir = path.join(runDir, "adjudication");
  const refused = [];
  const reviewed = new Set();
  try {
    for (const line of fs.readFileSync(path.join(dir, "apply.txt"), "utf8").split("\n")) {
      const m = /^ADJUDICATION: checkpoint\.sh refused (\S+?):/.exec(line);
      if (m) refused.push(m[1]);
      const ok = /^(?:applied|noop): (\S+) /.exec(line);
      if (ok) reviewed.add(ok[1]);
    }
  } catch (_) { /* no apply.txt: nothing was applied */ }
  const raw = readJSON(path.join(dir, "decisions.json"), undefined);
  if (raw !== undefined) {
    const decisions = (Array.isArray(raw) ? raw : []).filter((d) => d && typeof d === "object" && typeof d.criterionId === "string");
    return { state: "ran", decisions, banner: "", refused, reviewed, malformed: !Array.isArray(raw) };
  }
  let banner = null;
  try { banner = fs.readFileSync(path.join(dir, "unavailable.txt"), "utf8").split("\n").find((l) => l.trim()) || ""; } catch (_) { banner = null; }
  if (banner !== null) return { state: "unavailable", decisions: [], banner: banner.trim(), refused, reviewed };
  return { state: "not-run", decisions: [], banner: "", refused, reviewed };
}

function buildShip(runDir, criteria, rows, bugs, checkpointRows, verified) {
  const coverage = readJSON(path.join(runDir, "coverage.json"), null);
  const journeysRaw = readJSON(path.join(runDir, "journeys.json"), null);
  const cfg = readJSON(path.join(runDir, "effective-config.json"), null);
  const profile = cfg && typeof cfg.profile === "string" ? cfg.profile : "";
  const hasCov = !!coverage && typeof coverage === "object" && !Array.isArray(coverage);
  const hasJ = Array.isArray(journeysRaw);
  if (!hasCov && !hasJ && profile !== "ship") return null;

  const conditions = [];
  const lines = [];
  const key = (id, persona) => String(id) + "\u0000" + String(persona || "");
  const byKey = {};
  for (const c of criteria) byKey[key(c.id, c.persona)] = c;
  const adjust = (r) => {
    const c = byKey[key(r.criterion_id, r.persona)];
    return c && c.inRun === String(r.verdict || "").toLowerCase() ? c.verdict : r.verdict;
  };

  let census;
  if (hasCov && Number.isFinite(coverage.uncovered)) {
    const left = (Number(coverage.total) || 0) - (Number(coverage.excluded) || 0);
    if (left <= 0) { census = "unknown (empty census)"; conditions.push("census is empty"); }
    else {
      const covered = Number.isFinite(coverage.covered) ? coverage.covered : left - coverage.uncovered;
      const pct = Number.isFinite(coverage.percent) ? coverage.percent : Math.floor((covered / left) * 1000 + 0.5) / 10;
      census = covered + " of " + left + " covered (" + pct + "%) · " + coverage.uncovered + " uncovered"
        + (coverage.excluded ? " · " + coverage.excluded + " excluded" : "") + (coverage.adapterOk === false ? " · census adapter failed" : "");
      if (coverage.uncovered > 0) conditions.push(coverage.uncovered + " census surface(s) uncovered");
    }
    if (coverage.adapterOk === false) conditions.push("census adapter failed");
  } else { census = "unknown"; conditions.push("census coverage unknown"); }
  lines.push(["Census coverage", census]);

  const p1Ids = new Set();
  let p1Text;
  if (hasJ) {
    const statuses = journeyStatus(journeysRaw, checkpointRows, adjust);
    const p1 = statuses.filter((j) => j.priority === "P1");
    for (const j of p1) for (const s of j.steps) p1Ids.add(String(s.criterionId));
    if (!p1.length) { p1Text = "none declared"; conditions.push("no P1 journeys declared"); }
    else {
      const bad = p1.filter((j) => j.verdict !== "pass" || j.steps.some((s) => s.disputed));
      const state = (j) => {
        const d = j.steps.filter((s) => s.disputed).map((s) => s.criterionId);
        return j.verdict + (d.length ? " (disputed: " + d.join(", ") + ")" : "");
      };
      p1Text = (p1.length - bad.length) + " of " + p1.length + " pass" + (bad.length ? " · " + bad.map((j) => j.id + " " + state(j)).join(", ") : "");
      for (const j of bad) conditions.push("P1 journey " + j.id + " is " + state(j));
    }
  } else { p1Text = "none declared"; conditions.push("no P1 journeys declared"); }
  lines.push(["P1 journeys", p1Text]);

  const isP1 = (c) => p1Ids.has(String(c.id)) || (rows[c.id] && rows[c.id].priority === "P1");
  const layerOf = (c) => {
    const b = bugs.find((x) => String(x.criterion_id || x.criterion || "") === c.id || (c.bugRef && String(x.bug_id || x.id || "") === c.bugRef));
    return String((b && (b.suspected_layer || b.layer)) || (rows[c.id] && rows[c.id].layer) || "").toLowerCase();
  };
  const p1Fails = criteria.filter((c) => (c.verdict === "fail" || c.verdict === "error") && isP1(c)).map((c) => ({ id: c.id, layer: layerOf(c) }));
  const blocking = p1Fails.filter((f) => !f.layer || CODING_LAYERS.includes(f.layer));
  const listed = p1Fails.filter((f) => f.layer && !CODING_LAYERS.includes(f.layer));
  const fmt = (f) => f.id + " (" + (f.layer || "layer unknown") + ")";
  lines.push(["Coding-layer fails on P1", (blocking.length ? blocking.map(fmt).join(", ") : "none")
    + (listed.length ? " · listed, not blocking: " + listed.map(fmt).join(", ") : "")]);
  for (const f of blocking) conditions.push((f.layer ? "coding-layer fail on P1 " : "fail on P1 with unknown layer ") + fmt(f));

  // A record the re-adjudicator disputed (ADR-0033) blocks on any P1 criterion,
  // journey step or priority P1 alike, verified or not (I1).
  const disputedP1 = [...new Set(criteria.filter((c) => isDisputed(c.lastAction) && isP1(c)).map((c) => c.id))];
  const disputedText = disputedP1.map((id) => id + " (disputed)");
  if (!verified) {
    lines.push(["Verifier overrides on P1", "unknown" + (disputedText.length ? " · " + disputedText.join(", ") : "")]);
    conditions.push("not independently verified");
  } else {
    const ov = [...new Set(criteria.filter((c) => c.overridden && isP1(c)).map((c) => c.id))];
    const shown = ov.concat(disputedText);
    lines.push(["Verifier overrides on P1", shown.length ? shown.join(", ") : "none"]);
    for (const id of ov) conditions.push("verifier override on P1 " + id);
    const stale = criteria.filter((c) => c.stale && isP1(c)).map((c) => c.id);
    for (const id of stale) conditions.push("verification out of date on P1 " + id);
  }
  for (const id of disputedP1) conditions.push("verifier disputed P1 " + id);

  // Re-adjudication (I2). Unreviewed = a low-confidence pass (as shown, i.e.
  // after verification.json) with no decision that apply.txt shows applied or
  // a no-op — the same selection adjudication.sh select makes. A decision apply
  // rejected or checkpoint.sh refused is not a review. Only P1 ones block.
  const adj = readAdjudication(runDir);
  const lowPasses = criteria.filter((c) => c.verdict === "pass" && c.confidence === "low");
  const adjLabel = (id, persona) => String(id) + (persona ? "@" + String(persona) : "");
  const applied = adj.decisions.filter((d) => adj.reviewed.has(adjLabel(d.criterionId, typeof d.persona === "string" ? d.persona : "")));
  const notApplied = adj.decisions.length - applied.length;
  const judged = new Set(applied.map((d) => key(d.criterionId, typeof d.persona === "string" ? d.persona : "")));
  const unreviewed = lowPasses.filter((c) => !judged.has(key(c.id, c.persona)));
  const unreviewedP1 = [...new Set(unreviewed.filter(isP1).map((c) => c.id))];
  let adjText;
  if (adj.state === "ran") {
    const disputed = applied.filter((d) => d.agree === false);
    adjText = "re-judged " + applied.length + " · disputed " + disputed.length
      + (disputed.length ? " (" + [...new Set(disputed.map((d) => d.criterionId))].join(", ") + ")" : "")
      + (unreviewed.length ? " · " + unreviewed.length + " low-confidence passes not re-judged" : "")
      + (notApplied > 0 ? " · " + notApplied + " not applied (see adjudication/apply.txt)" : "");
    if (unreviewedP1.length) conditions.push(unreviewedP1.length + " P1 low-confidence pass(es) not re-judged: " + unreviewedP1.join(", "));
    if (adj.malformed) conditions.push("adjudication/decisions.json is not a JSON array");
  } else if (adj.state === "unavailable") {
    adjText = adj.banner || "re-adjudication unavailable";
    if (unreviewedP1.length) conditions.push("re-adjudication unavailable — " + unreviewedP1.length + " P1 low-confidence pass(es) unreviewed: " + unreviewedP1.join(", "));
  } else {
    adjText = "did not run — " + unreviewed.length + " low-confidence passes unreviewed";
    if (unreviewedP1.length) conditions.push("re-adjudication did not run — " + unreviewedP1.length + " P1 low-confidence pass(es) unreviewed: " + unreviewedP1.join(", "));
  }
  const refusedP1 = [...new Set(adj.refused.map((l) => l.split("@")[0]).filter((id) => p1Ids.has(id) || (rows[id] && rows[id].priority === "P1")))];
  for (const id of refusedP1) conditions.push("re-adjudication decision on P1 " + id + " was not applied");
  lines.push(["Re-adjudication", adjText]);

  lines.push(["Low-confidence passes", String(lowPasses.length)]);
  // Informational only: rows the bug export parked in <run>/bugs/needs-recheck.json.
  // A file older than the run's verification.json is a previous export's
  // (stale) and is ignored: no row.
  try {
    const nrPath = path.join(runDir, "bugs", "needs-recheck.json");
    let stale = false;
    try { stale = fs.statSync(nrPath).mtimeMs < fs.statSync(path.join(runDir, "verification.json")).mtimeMs; } catch (_) { stale = false; }
    const nr = stale ? null : JSON.parse(fs.readFileSync(nrPath, "utf8"));
    if (Array.isArray(nr)) lines.push(["Needs re-check", String(nr.length)]);
  } catch (e) { /* no export, or unreadable: no row */ }
  lines.push(["Flaky", criteria.some((c) => c.flaky !== null) ? String(criteria.filter((c) => c.flaky === true).length) : "not tracked"]);
  lines.push(["Regression suite", "not yet available"]);

  const turnedOn = [];
  if (cfg && cfg.profileSources && typeof cfg.profileSources === "object") {
    for (const k of Object.keys(cfg.profileSources)) if (cfg.profileSources[k] === "profile-default") turnedOn.push(k);
  }
  return { verdict: conditions.length ? "NOT SHIP-READY" : "SHIP-READY", conditions, lines, profile, turnedOn };
}

function shipProfileLine(s) {
  if (!s.profile) return "";
  return "Profile: " + s.profile + (s.turnedOn.length ? " — turned on by the profile: " + s.turnedOn.join(", ") : "");
}

function htmlShip(m) {
  const s = m.ship;
  if (!s) return "";
  const ok = s.verdict === "SHIP-READY";
  return '<section class="panel ship" id="ship-readiness" aria-label="Ship readiness"><h2>Ship readiness</h2>'
    + '<p class="status-line ' + (ok ? "status-ok" : "status-bad") + '"><b>' + esc(s.verdict) + "</b></p>"
    + (s.conditions.length ? "<ul>" + s.conditions.map((c) => "<li>" + esc(c) + "</li>").join("") + "</ul>" : "")
    + '<table class="plain"><tbody>' + s.lines.map((l) => "<tr><th>" + esc(l[0]) + "</th><td>" + esc(l[1]) + "</td></tr>").join("") + "</tbody></table>"
    + (shipProfileLine(s) ? '<p class="status-line">' + esc(shipProfileLine(s)) + "</p>" : "") + "</section>";
}

function mdShip(m) {
  const s = m.ship;
  if (!s) return "";
  const out = ["## Ship readiness", "", "**" + s.verdict + "**", ""];
  for (const c of s.conditions) out.push("- " + mdText(c));
  if (s.conditions.length) out.push("");
  out.push("| Check | Result |", "|---|---|");
  for (const l of s.lines) out.push("| " + mdText(l[0]) + " | " + mdText(l[1]) + " |");
  if (shipProfileLine(s)) out.push("", mdText(shipProfileLine(s)));
  return out.join("\n");
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------
function htmlShots(c, embed) {
  if (!c.shots.length) {
    return (c.verdict === "pass" || c.verdict === "fail")
      ? '<p class="noshot">No screenshot recorded for this criterion.</p>' : "";
  }
  const figs = c.shots.map((s) => {
    const caption = shotCaption(c.id, c.persona, s);
    const src = shotSrc(s, embed);
    let bind;
    if (s.legacy) bind = "not provenance-bound";
    else if (s.integrity === "altered") bind = "ALTERED after recording";
    else if (s.integrity === "missing") bind = "image missing";
    else if (s.flagged) bind = (s.ref || "unbound") + " · flagged by qa-verify";
    else bind = s.ref ? s.ref + (s.binding ? " · " + s.binding : "") : "unbound (no toolstream)";
    const phaseText = s.phase === "image" ? "screenshot" : s.phase + (s.label ? " · " + s.label : "");
    return '<figure class="shot' + (s.flagged || s.legacy ? " flagged" : "") + '">'
      + '<a class="shot-link" href="' + esc(src) + '" data-group="' + esc(c.anchor) + '" data-caption="' + esc(caption) + '">'
      + '<img src="' + esc(src) + '" alt="' + esc(caption) + '" loading="lazy"></a>'
      + '<figcaption><span class="ph">' + esc(phaseText) + "</span>" + (s.fullPage ? "<span>full page</span>" : "")
      + '<span class="bind mono">' + esc(bind) + "</span></figcaption></figure>";
  });
  return '<div class="shots">' + figs.join("") + "</div>";
}

function htmlCard(c, embed) {
  const rows = [];
  if (c.oracle) rows.push(["Oracle", esc(c.oracle)]);
  if (c.lastAction) rows.push(["Result", esc(c.lastAction)]);
  if (c.kinds.length) rows.push(["Verified via", esc(c.kinds.join(", "))]);
  if (c.tags.length) rows.push(["Tags", esc(c.tags.join(", "))]);
  if (c.nonUi) rows.push(["Non-UI reason", esc(c.nonUi)]);
  if (c.bugRef) rows.push(["Bug", '<a href="#bug-' + esc(slug(c.bugRef)) + '">' + esc(c.bugRef) + "</a>"]);
  const tags = [];
  if (c.persona) tags.push('<span class="tag">' + esc(c.persona) + "</span>");
  tags.push('<span class="tag' + (c.confidence === "low" ? " low" : "") + '">confidence: ' + esc(c.confidence) + "</span>");
  if (c.overridden) tags.push('<span class="tag override">in-run ' + esc(c.inRun) + " → overridden by qa-verify</span>");
  const reasons = c.reasons.length
    ? '<ul class="reasons' + (c.overridden ? "" : " soft") + '">' + c.reasons.map((r) => "<li>" + esc(r) + "</li>").join("") + "</ul>" : "";
  const files = c.files.length
    ? '<ul class="files">' + c.files.map((f) => '<li><a href="' + esc(urlPath(f)) + '">' + esc(f.replace(/^evidence\//, "")) + "</a></li>").join("") + "</ul>" : "";
  return '<article class="card c-' + esc(c.verdict) + '" id="' + esc(c.anchor) + '" data-verdict="' + esc(c.verdict) + '">'
    + '<div class="card-head"><span class="badge v-' + esc(c.verdict) + '">' + esc(c.verdict) + "</span>"
    + '<span class="cid">' + esc(c.id) + "</span>"
    + '<span class="ctitle">' + esc(c.title || c.id) + "</span>" + tags.join("") + "</div>"
    + '<div class="card-body">' + (rows.length ? '<table class="fields">' + rows.map((r) => "<tr><th>" + r[0] + "</th><td>" + r[1] + "</td></tr>").join("") + "</table>" : "")
    + reasons + htmlShots(c, embed) + files + "</div></article>";
}

function htmlBug(b) {
  const id = String(b.bug_id || b.id || "BUG");
  const steps = Array.isArray(b.steps || b.repro) ? (b.steps || b.repro) : [];
  const layer = b.suspected_layer || b.layer || "";
  const sev = b.severity || "";
  const crit = b.criterion_id || b.criterion || "";
  const ev = Array.isArray(b.evidence_refs || b.evidence) ? (b.evidence_refs || b.evidence) : [];
  return '<div class="bug" id="bug-' + esc(slug(id)) + '"><h3>' + esc(id) + (b.title ? " — " + esc(b.title) : "") + "</h3>"
    + '<div class="chips">' + (sev ? '<span class="tag">severity: ' + esc(sev) + "</span>" : "")
    + (layer ? '<span class="tag">suspected layer: ' + esc(layer) + "</span>" : "")
    + (crit ? '<span class="tag">' + esc(crit) + "</span>" : "") + "</div>"
    + (steps.length ? "<ol>" + steps.map((s) => "<li>" + esc(asText(s)) + "</li>").join("") + "</ol>" : "")
    + ((b.expected || b.actual) ? '<div class="ea"><div><b>Expected</b><br>' + esc(asText(b.expected)) + "</div><div><b>Actual</b><br>" + esc(asText(b.actual)) + "</div></div>" : "")
    + ((b.summary || b.root_cause) ? "<p>" + esc(asText(b.summary || b.root_cause)) + "</p>" : "")
    + (b.suggested_fix || b.fix ? "<p><b>Suggested fix:</b> " + esc(asText(b.suggested_fix || b.fix)) + "</p>" : "")
    + (ev.length ? '<ul class="files">' + ev.map((e) => '<li><a href="' + esc(urlPath(String(e))) + '">' + esc(String(e)) + "</a></li>").join("") + "</ul>" : "")
    + "</div>";
}

function htmlTraceability(t) {
  const rows = Array.isArray(t) ? t : (t && Array.isArray(t.rows) ? t.rows : (t && Array.isArray(t.entries) ? t.entries : []));
  const objs = rows.filter((r) => r && typeof r === "object");
  if (!objs.length) return "";
  const cols = Array.from(new Set(objs.reduce((a, r) => a.concat(Object.keys(r)), []))).slice(0, 8);
  return "<h2>Traceability</h2><div class=\"table-scroll\"><table class=\"plain\"><thead><tr>" + cols.map((k) => "<th>" + esc(k) + "</th>").join("")
    + "</tr></thead><tbody>" + objs.map((r) => "<tr>" + cols.map((k) => "<td>" + esc(asText(r[k])) + "</td>").join("") + "</tr>").join("") + "</tbody></table></div>";
}

// One sentence on rows that exist in checkpoint.json but are not counted as
// separate criterion outcomes (ADR-0029). Empty when there are none.
function countNote(m) {
  const bits = [];
  if (m.superseded.length) bits.push(m.superseded.length + " superseded row(s) not counted (the latest verdict per criterion is)");
  if (m.outOfPlan.length) bits.push(m.outOfPlan.length + " out-of-plan row(s) excluded (criterion id not in the frozen plan)");
  return bits.length ? m.distinct + " criteria · " + bits.join(" · ") : "";
}

function htmlAnomalies(m) {
  if (!m.superseded.length && !m.outOfPlan.length) return "";
  const oop = m.outOfPlan.map((c) => "<li><span class=\"mono\">" + esc(c.id.length > 160 ? c.id.slice(0, 160) + "…" : c.id) + "</span> — "
    + esc(c.verdict) + (c.persona ? " (" + esc(c.persona) + ")" : "") + "</li>").join("");
  const sup = m.superseded.map((c) => "<li><span class=\"mono\">" + esc(c.id) + "</span> — " + esc(c.verdict) + " (shared, " + esc(c.at) + ") superseded by "
    + esc(String(c.by.verdict || "")) + " (" + esc(String(c.by.persona || "")) + ", " + esc(asText(c.by.checkpointed_at || "")) + ")</li>").join("");
  return '<h2 id="process-anomalies">Process anomalies</h2><p class="status-line">' + esc(countNote(m)) + ".</p>"
    + (oop ? "<details open><summary>Out-of-plan rows (" + m.outOfPlan.length + ")</summary><ul>" + oop + "</ul></details>" : "")
    + (sup ? "<details><summary>Superseded rows (" + m.superseded.length + ")</summary><ul>" + sup + "</ul></details>" : "");
}

const UX_NOTE = "Recorded by the always-on UX sweep. Advisory: never a verdict on its own and not counted in the tally; "
  + "an objective defect becomes fail@FE only through a visual-ux criterion for its surface.";
const OUTSIDE_NOTE = "Objective UX defects the sweep saw on a surface that has no visual-ux criterion in the frozen plan. Not counted in verdicts; add a visual-ux row for the surface to have one judged.";
function htmlUx(m) {
  if (!m.ux) return "";
  const table = (list, withVariant) => '<div class="table-scroll"><table class="plain"><thead><tr><th>Surface</th><th>Detector</th><th>Selector</th><th>Message</th>'
    + (withVariant ? "<th>Variant</th>" : "") + "</tr></thead><tbody>" + list.map((f) => "<tr><td class=\"mono\">" + esc(f.surface) + "</td><td>" + esc(f.detector)
    + "</td><td class=\"mono\">" + esc(f.selector) + "</td><td>" + esc(f.message) + "</td>" + (withVariant ? "<td>" + esc(f.variant) + "</td>" : "") + "</tr>").join("")
    + "</tbody></table></div>";
  return '<h2 id="ux-findings">UX findings (advisory)</h2><p class="status-line">' + esc(UX_NOTE) + "</p>"
    + (m.ux.swept.length ? "<details open><summary>Swept findings (" + m.ux.swept.length + ")</summary>" + table(m.ux.swept, false) + "</details>" : "")
    + (m.ux.outsidePlan.length ? '<h3 id="ux-outside-plan">UX defects outside the plan (' + m.ux.outsidePlan.length + ')</h3><p class="status-line status-warn">'
      + esc(OUTSIDE_NOTE) + "</p>" + table(m.ux.outsidePlan, true) : "");
}

function mdUx(m) {
  if (!m.ux) return "";
  const out = ["", "---", "", "## UX findings (advisory)", "", UX_NOTE, ""];
  const table = (list, withVariant) => {
    out.push("| Surface | Detector | Selector | Message |" + (withVariant ? " Variant |" : ""), "|---|---|---|---|" + (withVariant ? "---|" : ""));
    for (const f of list) out.push("| `" + mdText(f.surface) + "` | " + mdText(f.detector) + " | `" + mdText(f.selector) + "` | " + mdText(f.message) + " |" + (withVariant ? " " + mdText(f.variant) + " |" : ""));
    out.push("");
  };
  if (m.ux.swept.length) table(m.ux.swept, false);
  if (m.ux.outsidePlan.length) { out.push("### UX defects outside the plan", "", OUTSIDE_NOTE, ""); table(m.ux.outsidePlan, true); }
  return out.join("\n");
}

function verificationLine(m) {
  if (!m.verified) {
    return '<p class="status-line status-warn">Not independently verified — no verification.json. Run <code>scripts/qa-verify.sh ' + esc(m.runId) + "</code>, then re-render.</p>";
  }
  const failedRunLevel = m.runLevel.filter((r) => r.verifierVerdict && r.verifierVerdict !== "pass");
  const cls = (m.overridden || failedRunLevel.length) ? "status-bad" : "status-ok";
  return '<p class="status-line ' + cls + '">qa-verify re-checked ' + m.checkedCount + " criterion record(s); "
    + m.overridden + " overridden" + (failedRunLevel.length ? "; run-level check(s) failed: " + esc(failedRunLevel.map((r) => r.criterionId).join(", ")) : "") + ".</p>";
}

function renderHtml(m, tpl, embed) {
  const chips = VERDICTS.map((v) => '<span class="chip v-' + v + '"><b>' + m.tally[v] + "</b> " + v + "</span>").join("")
    + '<span class="chip total"><b>' + m.total + "</b> total</span>";
  const runLevel = m.runLevel.filter((r) => Array.isArray(r.reasons) && r.reasons.length).map((r) =>
    '<details class="runlevel"><summary>' + esc(r.criterionId) + " — " + esc(r.verifierVerdict) + " (confidence " + esc(r.confidence) + ", " + r.reasons.length + " note(s))</summary><ul>"
    + r.reasons.map((x) => "<li>" + esc(asText(x)) + "</li>").join("") + "</ul></details>").join("");
  const cost = m.cost
    ? '<div class="panel"><h3>Cost</h3><p class="status-line">' + esc(m.cost.toolCalls) + " tool calls · " + esc(m.cost.criteriaDone !== undefined ? m.cost.criteriaDone : m.cost.criteria)
      + (m.cost.criteriaBudget ? " / " + esc(m.cost.criteriaBudget) + " criteria budget" : " criteria") + (m.cost.budgetWarn ? " · <b>budget ≥80% consumed</b>" : "") + "</p></div>" : "";

  const active = m.criteria.filter((c) => c.verdict !== "deferred");
  const deferred = m.criteria.filter((c) => c.verdict === "deferred");
  const filters = ["all"].concat(VERDICTS.filter((v) => v !== "deferred" && m.tally[v] > 0)).map((v, i) =>
    '<button type="button" class="filter" data-filter="' + v + '" aria-pressed="' + (i === 0) + '">' + v + (v === "all" ? "" : " (" + m.tally[v] + ")") + "</button>").join("");

  const body = [
    "<header><h1>QA report — " + esc(m.feature || m.runId) + "</h1>",
    '<div class="meta"><span><b>Run</b> <span class="mono">' + esc(m.runId) + "</span></span>"
      + (m.started ? "<span><b>Started</b> " + esc(m.started) + "</span>" : "") + (m.ended ? "<span><b>Ended</b> " + esc(m.ended) + "</span>" : "")
      + (m.buildId ? "<span><b>Build</b> " + esc(m.buildId) + "</span>" : "") + (m.baseUrl ? "<span><b>Target</b> " + esc(m.baseUrl) + "</span>" : "")
      + (m.stack ? "<span><b>Stack</b> " + esc(m.stack) + "</span>" : "") + "</div></header>"
      + (m.ship ? "\n" + htmlShip(m) : ""),
    '<section class="summary" aria-label="Summary">',
    '<div class="panel"><h3>Verdicts</h3><div class="chips">' + chips + "</div>"
      + (m.low ? '<p class="status-line" style="margin-top:8px"><span class="tag low">' + m.low + " with confidence: low</span></p>" : "")
      + ((m.superseded.length || m.outOfPlan.length) ? '<p class="status-line status-warn" style="margin-top:8px">' + countNote(m) + ' · <a href="#process-anomalies">details</a></p>' : "") + "</div>",
    '<div class="panel"><h3>Verification</h3>' + verificationLine(m) + runLevel + "</div>",
    '<div class="panel"><h3>Screenshots</h3><p class="status-line' + (m.evidencedWithShot < m.evidencedTotal ? " status-warn" : "") + '">'
      + m.evidencedWithShot + " of " + m.evidencedTotal + " pass/fail criteria carry a recorded screenshot · " + m.shotCount + " image(s)"
      + (m.shotCount ? ' · <a href="#gallery-section">view all</a>' : "") + "</p></div>",
    cost, "</section>",
    "<h2>Criteria</h2>",
    active.length ? '<div class="toolbar" role="group" aria-label="Filter by verdict"><span>Show</span>' + filters + "</div>" : "",
    '<div class="cards">' + (active.map((c) => htmlCard(c, embed)).join("") || "<p><em>No criteria were checkpointed.</em></p>") + "</div>",
    '<h2>Deferred</h2><div class="deferred">' + (deferred.length ? deferred.map((c) =>
      '<div class="deferred-item" id="' + esc(c.anchor) + '"><b>DEFERRED — <span class="mono">' + esc(c.id) + "</span>" + (c.title ? ": " + esc(c.title) : "") + "</b>"
      + "<p>" + esc(c.lastAction || c.nonUi || "No reason recorded.") + "</p>" + htmlShots(c, embed) + "</div>").join("") : "<p><em>No criteria were deferred this run.</em></p>") + "</div>",
    "<h2>Bugs</h2>" + (m.bugs.length ? m.bugs.map(htmlBug).join("") : "<p><em>No bugs logged this run.</em></p>"),
    htmlAnomalies(m) + htmlUx(m),
    htmlTraceability(m.traceability),
    '<section id="gallery-section" hidden><h2>All screenshots</h2><div class="shots" id="gallery"></div></section>',
    "<footer>Rendered by qa-e2e-pilot render-report.js from the run's own record" + (embed ? " (screenshots embedded)" : "") + ". Click a screenshot to enlarge; ← → step through, Esc closes.</footer>",
  ].join("\n");

  return tpl.split("{{TITLE}}").join(esc("QA report — " + (m.feature || m.runId))).split("{{BODY}}").join(body);
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------
function renderMd(m, tpl) {
  const meta = [];
  meta.push("**Run:** `" + mdText(m.runId) + "`");
  if (m.started) meta.push("**Started:** " + mdText(m.started));
  if (m.ended) meta.push("**Ended:** " + mdText(m.ended));
  if (m.buildId) meta.push("**Build:** " + mdText(m.buildId));
  if (m.baseUrl) meta.push("**Target:** " + mdText(m.baseUrl));
  if (m.stack) meta.push("**Stack:** " + mdText(m.stack));
  const head = "# QA report — " + mdText(m.feature || m.runId) + "\n\n" + meta.join("  \n") + (m.ship ? "\n\n---\n\n" + mdShip(m) : "");

  const sum = ["| Verdict | Count |", "|---|---|"].concat(VERDICTS.map((v) => "| " + v + " | " + m.tally[v] + " |"), ["| **Total** | **" + m.total + "** |", ""]);
  if (m.low) sum.push("> " + m.low + " verdict(s) carry confidence: low.", "");
  if (!m.verified) sum.push("> **Not independently verified** — no verification.json. Run `scripts/qa-verify.sh " + mdText(m.runId) + "`, then re-render.", "");
  else sum.push("qa-verify re-checked " + m.checkedCount + " criterion record(s); " + m.overridden + " overridden.", "");
  sum.push("Screenshots: " + m.evidencedWithShot + " of " + m.evidencedTotal + " pass/fail criteria carry a recorded screenshot (" + m.shotCount + " image(s)).");
  if (m.superseded.length || m.outOfPlan.length) {
    sum.push("", "**Process anomalies:** " + mdText(countNote(m)) + ".");
    for (const c of m.outOfPlan) sum.push("- Out-of-plan row: `" + mdText(c.id.length > 160 ? c.id.slice(0, 160) + "…" : c.id) + "` — " + mdText(c.verdict));
    if (m.superseded.length) {
      sum.push("- Superseded rows: " + m.superseded.map((c) => "`" + mdText(c.id) + "` " + mdText(c.verdict) + " → " + mdText(String(c.by.verdict || "")) + " (" + mdText(String(c.by.persona || "")) + ")").join("; "));
    }
  }
  for (const r of m.runLevel) {
    if (!Array.isArray(r.reasons) || !r.reasons.length) continue;
    sum.push("", "**" + mdText(r.criterionId) + "** (" + mdText(r.verifierVerdict) + ", confidence " + mdText(r.confidence) + "):");
    for (const x of r.reasons) sum.push("- " + mdText(asText(x)));
  }

  const crit = [];
  for (const c of m.criteria.filter((x) => x.verdict !== "deferred")) {
    crit.push("### " + mdText(c.id) + (c.title ? " — " + mdText(c.title) : "") + (c.persona ? " (" + mdText(c.persona) + ")" : ""), "");
    crit.push("| Field | Value |", "|---|---|");
    crit.push("| Verdict | **" + c.verdict + "**" + (c.overridden ? " (in-run " + c.inRun + ", overridden by qa-verify)" : "") + " |");
    crit.push("| Confidence | " + mdText(c.confidence) + " |");
    if (c.oracle) crit.push("| Oracle | " + mdText(c.oracle) + " |");
    if (c.lastAction) crit.push("| Result | " + mdText(c.lastAction) + " |");
    if (c.kinds.length) crit.push("| Verified via | " + mdText(c.kinds.join(", ")) + " |");
    if (c.nonUi) crit.push("| Non-UI reason | " + mdText(c.nonUi) + " |");
    if (c.bugRef) crit.push("| Bug | [" + mdText(c.bugRef) + "](#" + slug(c.bugRef) + ") |");
    crit.push("");
    if (c.reasons.length) { crit.push("Verifier notes:"); for (const r of c.reasons) crit.push("- " + mdText(r)); crit.push(""); }
    if (c.shots.length) {
      for (const s of c.shots) {
        const cap = shotCaption(c.id, c.persona, s) + (s.legacy ? " (not provenance-bound)" : (s.integrity !== "ok" ? " (" + s.integrity + ")" : ""));
        crit.push("![" + mdText(cap).replace(/[[\]]/g, "") + "](" + urlPath(s.rel) + ")");
      }
      crit.push("");
    } else if (c.verdict === "pass" || c.verdict === "fail") {
      crit.push("_No screenshot recorded._", "");
    }
    if (c.files.length) { crit.push("Evidence: " + c.files.map((f) => "[" + mdText(f.replace(/^evidence\//, "")) + "](" + urlPath(f) + ")").join(" · "), ""); }
  }
  const deferred = m.criteria.filter((c) => c.verdict === "deferred").map((c) =>
    "### DEFERRED — " + mdText(c.id) + (c.title ? ": " + mdText(c.title) : "") + "\n\n**Reason:** " + mdText(c.lastAction || c.nonUi || "No reason recorded.") + "\n");
  const bugs = m.bugs.map((b) => {
    const id = String(b.bug_id || b.id || "BUG");
    const lines = ["### " + mdText(id) + (b.title ? " — " + mdText(b.title) : ""), ""];
    if (b.severity) lines.push("- **Severity:** " + mdText(b.severity));
    if (b.suspected_layer || b.layer) lines.push("- **Suspected layer:** " + mdText(b.suspected_layer || b.layer));
    if (b.criterion_id || b.criterion) lines.push("- **Criterion:** " + mdText(b.criterion_id || b.criterion));
    if (b.expected) lines.push("- **Expected:** " + mdText(asText(b.expected)));
    if (b.actual) lines.push("- **Actual:** " + mdText(asText(b.actual)));
    if (b.summary || b.root_cause) lines.push("- " + mdText(asText(b.summary || b.root_cause)));
    const steps = Array.isArray(b.steps || b.repro) ? (b.steps || b.repro) : [];
    if (steps.length) { lines.push("", "Steps to reproduce:"); steps.forEach((s, i) => lines.push((i + 1) + ". " + mdText(asText(s)))); }
    return lines.join("\n") + "\n";
  });

  const fill = {
    HEADER: head, SUMMARY: sum.join("\n"),
    CRITERIA: crit.join("\n") || "_No criteria were checkpointed._",
    DEFERRED: deferred.join("\n") || "_No criteria were deferred this run._",
    BUGS: bugs.join("\n") || "_No bugs logged this run._",
    EXTRA: mdUx(m) + "\n---\n\n_Rendered by qa-e2e-pilot render-report.js from the run's own record. Image links are relative to this run directory._\n",
  };
  let out = tpl;
  for (const k of Object.keys(fill)) out = out.split("{{" + k + "}}").join(fill[k]);
  return out;
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  const runDir = resolveRunDir(o.target);
  const htmlTpl = fs.readFileSync(path.join(o.templates, "report.html"), "utf8");
  const mdTpl = fs.readFileSync(path.join(o.templates, "report.md"), "utf8");
  const m = buildModel(runDir);
  fs.writeFileSync(path.join(runDir, "report.html"), renderHtml(m, htmlTpl, o.embed));
  fs.writeFileSync(path.join(runDir, "report.md"), renderMd(m, mdTpl));
  if (!o.quiet) {
    process.stdout.write("wrote " + path.join(runDir, "report.html") + " + report.md" + (o.embed ? " (screenshots embedded)" : "") + "\n");
    process.stdout.write("tally: " + VERDICTS.map((v) => v + "=" + m.tally[v]).join(" ") + " total=" + m.total
      + " low=" + m.low + " screenshots=" + m.shotCount + " (" + m.evidencedWithShot + "/" + m.evidencedTotal + " pass/fail criteria)"
      + " verified=" + (m.verified ? "yes" : "no") + " criteria=" + m.distinct + " superseded=" + m.superseded.length
      + " out_of_plan=" + m.outOfPlan.length + "\n");
  }
}

// Run as a script -> render. Required as a module (scripts/qa-dashboard.js) ->
// expose the model so verdict, supersession and ship logic live in one place.
if (require.main === module) main();
else module.exports = { VERDICTS, buildModel, loadBugs, readJSON, journeyStatus, readAdjudication };
