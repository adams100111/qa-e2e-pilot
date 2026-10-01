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
function buildModel(runDir) {
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
    const ev = collectEvidence(runDir, c);
    const reasons = checked && Array.isArray(v.reasons) ? v.reasons.map(String) : [];
    for (const s of ev.shots) {
      s.flagged = s.integrity !== "ok" || reasons.some((r) => (s.sidecarRel && r.includes(s.sidecarRel)) || r.includes(s.rel));
    }
    return {
      id: c.criterion_id, persona: c.persona || "", inRun, verdict, confidence, checked,
      overridden: checked && verdict !== inRun, reasons,
      title: asText(row.title || row.label || row.surface || ""), oracle: asText(row.oracle || ""),
      tags: Array.isArray(row.tags) ? row.tags.map(String) : [],
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
  };
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
      + (m.stack ? "<span><b>Stack</b> " + esc(m.stack) + "</span>" : "") + "</div></header>",
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
    htmlAnomalies(m),
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
  const head = "# QA report — " + mdText(m.feature || m.runId) + "\n\n" + meta.join("  \n");

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
    EXTRA: "\n---\n\n_Rendered by qa-e2e-pilot render-report.js from the run's own record. Image links are relative to this run directory._\n",
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

main();
