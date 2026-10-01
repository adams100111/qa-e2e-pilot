'use strict';
/*
 * write-probe-gate.js — recognise THE SANCTIONED RECORDED WRITE PROBE and
 * decide whether the environment allows it (0.9.0, ADR-0027).
 *
 * WHY: a criterion that asserts a server-side rule with no UI affordance by
 * design ("PATCH another user's registration -> 403", "POST without a
 * challenge -> 422") needs ONE API write. block-hook.sh denies every
 * mutating browser_evaluate, and the host harness denies out-of-browser
 * curl/python, so on a disposable env with allowApiWrites:true such criteria
 * could only end `blocked` (a real run lost eight). This module defines the
 * single shape that is admitted instead — narrow enough to be checked
 * mechanically, recorded by the capture hook like every other call, and
 * bound by qa-verify to the criterion's probe evidence:
 *
 *   payload = backend-probe.js (THIS directory) verbatim, whitespace-
 *             insensitive (the harness's `async () => { ... }` wrapper and
 *             re-indentation are fine; ANY other edit is not)
 *           + exactly ONE `[return] [await] probe(<STRICT JSON object>)`
 *   the JSON argument: keys ⊆ {url, method, body, allowWrite, csrf};
 *             method ∈ POST|PUT|PATCH|DELETE; allowWrite === true;
 *             url a same-origin RELATIVE path ("/..." but not "//...").
 *
 * Strict JSON is the point: it cannot contain an expression, a function
 * call, or an assignment, so nothing but the declared request can ride
 * along. A payload that merely names probe(), edits backend-probe.js, adds
 * code, or uses a JS object literal is NOT the sanctioned shape.
 *
 * writesAllowed(config) mirrors the engine's write gate exactly (the same
 * three conditions auto-seed.sh and probing-apis-through-browser use):
 * allowApiWrites === true AND a non-empty seedableEnvMarker that is not the
 * historical bootstrap sentinel "QA_DISPOSABLE_ENV" AND environment !==
 * "production". Never production.
 *
 * CLI (used by block-hook.sh and qa-verify.sh; payload on stdin):
 *   node write-probe-gate.js check <config.json|->
 *     exit 0  sanctioned AND writes allowed      stdout {"sanctioned":true,"allowed":true,"method":..,"url":..}
 *     exit 1  not the sanctioned shape           stdout {"sanctioned":false,"reason":..}
 *     exit 3  sanctioned shape, writes NOT allowed stdout {"sanctioned":true,"allowed":false,"reason":..}
 *     exit 2  internal error (callers fail open / treat as not sanctioned)
 *   node write-probe-gate.js allowed <config.json>
 *     exit 0 writes allowed / 3 not allowed; stdout {"allowed":..,"reason":..}
 *   node write-probe-gate.js verify-evidence <artifact.json> <toolstream.jsonl> [config.json]
 *     qa-verify's api-write backstop: exit 0 when the probe artifact is bound
 *     by --source-ref seq:<N> to a captured sanctioned write probe AND the
 *     config allows writes; exit 1 with the reason on stdout otherwise.
 */
const fs = require('fs');
const path = require('path');

let PROBE_NORM = null;
try {
  const raw = fs.readFileSync(path.join(__dirname, 'backend-probe.js'), 'utf8');
  const n = raw.replace(/\s+/g, '');
  if (n.length > 200) PROBE_NORM = n;
} catch (e) { PROBE_NORM = null; }

const ALLOWED_KEYS = new Set(['url', 'method', 'body', 'allowWrite', 'csrf']);
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

// Remove the ONE whitespace-insensitive occurrence of backend-probe.js from
// `s`; null when it is absent (or occurs more than once).
function exciseProbe(s) {
  if (!PROBE_NORM) return null;
  const chars = []; const map = [];
  for (let i = 0; i < s.length; i++) {
    if (!/\s/.test(s[i])) { chars.push(s[i]); map.push(i); }
  }
  const joined = chars.join('');
  const at = joined.indexOf(PROBE_NORM);
  if (at < 0) return null;
  if (joined.indexOf(PROBE_NORM, at + 1) >= 0) return null;
  const start = map[at], end = map[at + PROBE_NORM.length - 1] + 1;
  return s.slice(0, start) + '\n' + s.slice(end);
}

function sanctionedWriteProbe(payload) {
  const rest = exciseProbe(String(payload || ''));
  if (rest === null) return { sanctioned: false, reason: 'the payload does not carry skills/probing-apis-through-browser/scripts/backend-probe.js verbatim' };
  // Strip the harness wrapper: `[async] () => {` ... `}` around the call.
  let body = rest.trim();
  const wrap = body.match(/^(?:async\s*)?\(\s*\)\s*=>\s*\{([\s\S]*)\}\s*;?$/);
  if (wrap) body = wrap[1].trim();
  const call = body.match(/^(?:return\s+)?(?:await\s+)?probe\(\s*(\{[\s\S]*\})\s*\)\s*;?$/);
  if (!call) return { sanctioned: false, reason: 'after backend-probe.js, the payload must be exactly one `return await probe(<JSON>)` call' };
  let arg;
  try { arg = JSON.parse(call[1]); } catch (e) {
    return { sanctioned: false, reason: 'the probe() argument must be strict JSON (double-quoted keys, no expressions)' };
  }
  if (!arg || typeof arg !== 'object' || Array.isArray(arg)) return { sanctioned: false, reason: 'the probe() argument must be a JSON object' };
  for (const k of Object.keys(arg)) {
    if (!ALLOWED_KEYS.has(k)) return { sanctioned: false, reason: 'unexpected probe() key "' + k + '" (allowed: url, method, body, allowWrite, csrf)' };
  }
  const method = typeof arg.method === 'string' ? arg.method.toUpperCase() : '';
  if (!WRITE_METHODS.has(method)) return { sanctioned: false, reason: 'method must be POST, PUT, PATCH or DELETE' };
  if (arg.allowWrite !== true) return { sanctioned: false, reason: 'allowWrite must be true' };
  if (typeof arg.url !== 'string' || !/^\/(?!\/)/.test(arg.url)) return { sanctioned: false, reason: 'url must be a same-origin relative path starting with "/"' };
  if (arg.csrf !== undefined && arg.csrf !== null && arg.csrf !== 'laravel-xsrf' && arg.csrf !== 'meta') {
    return { sanctioned: false, reason: 'csrf must be "laravel-xsrf", "meta", or absent' };
  }
  return { sanctioned: true, method: method, url: arg.url };
}

function writesAllowed(cfg) {
  if (!cfg || typeof cfg !== 'object') return { allowed: false, reason: 'no readable .qa/config.json' };
  if (cfg.allowApiWrites !== true) return { allowed: false, reason: 'allowApiWrites is not true in .qa/config.json' };
  const marker = cfg.seedableEnvMarker;
  if (typeof marker !== 'string' || marker.trim() === '') return { allowed: false, reason: 'seedableEnvMarker is empty — the environment is not marked disposable' };
  if (marker === 'QA_DISPOSABLE_ENV') return { allowed: false, reason: 'seedableEnvMarker is the bootstrap sentinel "QA_DISPOSABLE_ENV", which is treated as NOT disposable' };
  if (cfg.environment === 'production') return { allowed: false, reason: 'environment is production — API writes are never allowed there' };
  return { allowed: true };
}

function readConfig(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) { return null; }
}

// verifyApiWriteEvidence — qa-verify's out-of-agent backstop for an
// `api-write` criterion: its probe artifact must carry provenance.sourceRef
// `seq:<N>`, toolstream event N must be a captured browser_evaluate, and that
// call's payload must be the sanctioned write probe; and the config must
// still allow API writes. Returns null when all hold, else a reason string.
function verifyApiWriteEvidence(artifactPath, toolstreamPath, cfg) {
  const a = writesAllowed(cfg);
  if (!a.allowed) return 'api-write pass on an environment that does not allow API writes (' + a.reason + ')';
  let art;
  try { art = JSON.parse(fs.readFileSync(artifactPath, 'utf8')); } catch (e) { return 'api-write probe evidence is missing or not valid JSON'; }
  const ref = art && art.provenance && art.provenance.sourceRef;
  const m = typeof ref === 'string' ? ref.match(/^(?:seq:)?([0-9]+)$/) : null;
  if (!m) return 'api-write probe evidence is not bound to its write: record it with --source-ref seq:<N> naming the captured sanctioned write probe';
  const seq = Number(m[1]);
  let ev = null;
  try {
    for (const line of fs.readFileSync(toolstreamPath, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let o; try { o = JSON.parse(line); } catch (e) { continue; }
      if (o && o.seq === seq) { ev = o; break; }
    }
  } catch (e) { return 'api-write probe evidence cannot be checked: no toolstream for this run'; }
  if (!ev) return 'api-write probe evidence names seq:' + seq + ', which is not in the toolstream';
  if (typeof ev.tool !== 'string' || !/browser_evaluate$/.test(ev.tool)) return 'api-write probe evidence names seq:' + seq + ', which is a ' + ev.tool + ' call, not the sanctioned write probe';
  const args = ev.args || {};
  const payload = (typeof args.function === 'string' ? args.function : '') + '\n' + (typeof args.code === 'string' ? args.code : '');
  const s = sanctionedWriteProbe(payload);
  if (!s.sanctioned) return 'api-write probe evidence names seq:' + seq + ', whose payload is not the sanctioned write probe (' + s.reason + ')';
  return null;
}

module.exports = { sanctionedWriteProbe: sanctionedWriteProbe, writesAllowed: writesAllowed, verifyApiWriteEvidence: verifyApiWriteEvidence };

if (require.main === module) {
  try {
    const cmd = process.argv[2];
    const cfg = cmd === 'verify-evidence' ? null : readConfig(process.argv[3] || '.qa/config.json');
    if (cmd === 'allowed') {
      const a = writesAllowed(cfg);
      process.stdout.write(JSON.stringify(a) + '\n');
      process.exit(a.allowed ? 0 : 3);
    } else if (cmd === 'check') {
      const payload = fs.readFileSync(0, 'utf8');
      const s = sanctionedWriteProbe(payload);
      if (!s.sanctioned) { process.stdout.write(JSON.stringify(s) + '\n'); process.exit(1); }
      const a = writesAllowed(cfg);
      process.stdout.write(JSON.stringify(Object.assign({}, s, a)) + '\n');
      process.exit(a.allowed ? 0 : 3);
    } else if (cmd === 'verify-evidence') {
      // verify-evidence <artifact.json> <toolstream.jsonl> [config.json]
      const r = verifyApiWriteEvidence(process.argv[3], process.argv[4], readConfig(process.argv[5] || '.qa/config.json'));
      if (r) { process.stdout.write(r + '\n'); process.exit(1); }
      process.exit(0);
    } else {
      process.stderr.write('usage: write-probe-gate.js {check|allowed|verify-evidence} ...\n');
      process.exit(2);
    }
  } catch (e) {
    process.exit(2);
  }
}
