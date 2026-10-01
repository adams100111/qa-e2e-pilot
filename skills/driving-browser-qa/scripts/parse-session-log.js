'use strict';
/*
 * parse-session-log.js — read a Playwright MCP `--save-session` session.md and
 * emit the ordered calls as classified JSON `[{class, mutating, code}]`.
 * Dependency-free. VERIFIED against the REAL saved file (@playwright/mcp@0.0.79):
 * each executed step is a section "### Tool call: <name>" whose "- Result"
 * fenced-json block carries the generated Playwright code in a `code` field
 * (e.g. {"code":"await page.locator('#add').click();", ...}) — NOT MCP tool
 * names, and NOT the "Ran Playwright code" ```js shape (that is the INTERACTIVE
 * response, not the saved file). We extract each Result's `code`, classify by
 * code pattern, and flag `mutating` ONLY when the code writes app state, so
 * read-only observation evaluate is never a workaround.
 *
 * The `classify(code)` here is the SINGLE source of truth also used by
 * check-action-trace.js for act-phase evaluate payloads (Check 2) — keep them
 * one function via the shared export.
 */
const fs = require('fs');
const path = require('path');

// Does this snippet WRITE app/DOM/storage state? (read-only reads are ignored.)
//
// ASSIGN is the assignment-operator tail shared by every "X = ..." alternative:
// plain `=` AND the compound forms (`+=`, `||=`, `??=`, `**=`, `<<=`, ...), but
// NEVER a comparison. Before 0.8.1 each alternative ended in a bare `\s*=`,
// which also matched `==`/`===` — so a READ like
// `typeof window.__qaObserve === 'function'` or `el.value === ''` was judged a
// write, and the block-hook denied read-only probes (and the engine's own
// observe round). `=(?!=)` rejects the comparison; `<=`/`>=`/`!=` never matched
// (their first char is not in the operator set). Compound assignments were a
// genuine gap (`el.value += 'x'` slipped through) and are now caught.
const ASSIGN = String.raw`\s*(?:\*\*|<<|>>>?|&&|\|\||\?\?|[-+*/%&|^])?=(?!=)`;
const MUTATION_RE = new RegExp([
  String.raw`\.setItem\(`, String.raw`\.removeItem\(`, String.raw`localStorage\.clear\(`,
  String.raw`sessionStorage\.(set|remove|clear)`,
  String.raw`\.value` + ASSIGN, String.raw`\.checked` + ASSIGN, String.raw`\.innerHTML` + ASSIGN,
  String.raw`\.innerText` + ASSIGN, String.raw`\.textContent` + ASSIGN,
  String.raw`\.setAttribute\(`, String.raw`\.dispatchEvent\(`, String.raw`\.click\(\)`,
  String.raw`\.submit\(\)`, String.raw`\.requestSubmit\(`, String.raw`\.remove\(\)`,
  String.raw`\[['"` + '`' + String.raw`](value|checked|innerHTML|innerText|textContent)['"` + '`' + String.raw`]\]` + ASSIGN,
  String.raw`document\.\w+` + ASSIGN, String.raw`window\.\w+` + ASSIGN,
  // 0.9.0: the key may itself be quoted ({"method":"POST"} — strict JSON, or
  // a quoted JS key); before, only a bare `method:` key was recognised, so a
  // JSON-quoted write request slipped past the classifier entirely.
  String.raw`['"` + '`' + String.raw`]?method['"` + '`' + String.raw`]?\s*:\s*['"` + '`' + String.raw`]\s*(POST|PUT|PATCH|DELETE)`,
  String.raw`\.open\(\s*['"` + '`' + String.raw`]\s*(POST|PUT|PATCH|DELETE)`,
  String.raw`\.(post|put|patch|delete)\s*\(`, String.raw`sendBeacon\(`, String.raw`\.dispatch\(`,
  String.raw`setState\(`
].join('|'), 'i');

// --- the engine's OWN observe round: a content-addressed allowance ----------
// observe.js (this directory) is the sanctioned read-only observe payload
// (ADR-0006). It is not a write in the sense this classifier exists for — it
// never changes the app's persisted/server state or the DOM the user acts on —
// but it DOES install instrumentation that is syntactically a global write:
// `window.__qaObserveInstalled = true`, `window.__qaObserve = ...`, and a
// PASS-THROUGH wrapper `window.fetch = function (...) { return of.apply(...) }`
// (plus console/XHR wrappers the regex never matched). A regex cannot tell a
// pass-through fetch wrapper from a response-FORGING one
// (`window.fetch = () => Promise.resolve(new Response(...))` — which must stay
// a mutation), so no precise, spoof-proof regex carve-out exists for it.
//
// Instead the allowance is CONTENT-ADDRESSED: the shipped observe.js source is
// read from disk (never a hard-coded name, marker, or hash that could drift or
// be spoofed), and every occurrence of it inside a payload — compared with all
// whitespace removed, so the harness wrapper `() => { ... }` or re-indentation
// does not matter — is EXCISED before the regex runs on what remains. So:
//   - the verbatim observe round (bare, wrapped, re-indented) -> not mutating;
//   - observe.js with ANY non-whitespace edit (e.g. a tampered fetch wrapper)
//     does not match -> classified in full -> `window.fetch =` -> mutating;
//   - observe.js PLUS extra code -> the extra code is still classified;
//   - a payload that merely names observe / __qaObserve -> no allowance.
// Whitespace-insensitivity cannot smuggle behaviour in: removing or adding
// whitespace between observe.js's own tokens can only break it or change
// literal spacing, never introduce a new operation.
// If observe.js cannot be read, there is NO allowance (fail-closed to the
// plain classifier — the hook's own fail-open contract is unaffected).
let OBSERVE_NORM = null;
try {
  const raw = fs.readFileSync(path.join(__dirname, 'observe.js'), 'utf8');
  const n = raw.replace(/\s+/g, '');
  if (n.length > 200) OBSERVE_NORM = n; // never allow-list a truncated/empty file
} catch (e) { OBSERVE_NORM = null; }

// Remove every whitespace-insensitive occurrence of the shipped observe.js
// source from `s`, returning the remainder (each excised span -> "\n").
function exciseObserve(s) {
  if (!OBSERVE_NORM || s.length < OBSERVE_NORM.length) return s;
  for (;;) {
    const chars = []; const map = [];
    for (let i = 0; i < s.length; i++) {
      if (!/\s/.test(s[i])) { chars.push(s[i]); map.push(i); }
    }
    const at = chars.join('').indexOf(OBSERVE_NORM);
    if (at < 0) return s;
    const start = map[at], end = map[at + OBSERVE_NORM.length - 1] + 1;
    s = s.slice(0, start) + '\n' + s.slice(end);
  }
}

// True iff a raw JS snippet writes state. Used BOTH for full session.md code
// AND for a bare action-trace evaluate `payload` (which has no `page.evaluate(`
// wrapper) — so a payload is judged by what it does, not by its wrapper.
function mutates(src) { return MUTATION_RE.test(exciseObserve(String(src || ''))); }

// Decode the body of a single- or double-quoted JS string literal.
function decodeJsString(body) {
  return body.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|[\s\S])/g, function (m, e) {
    switch (e[0]) {
      case 'n': return e.length === 1 ? '\n' : e;
      case 'r': return e.length === 1 ? '\r' : e;
      case 't': return e.length === 1 ? '\t' : e;
      case 'b': return '\b';
      case 'f': return '\f';
      case 'v': return '\v';
      case '0': return '\0';
      case 'u':
        if (e.length === 1) return e;
        return String.fromCodePoint(parseInt(e[1] === '{' ? e.slice(2, -1) : e.slice(1), 16));
      case 'x': return e.length === 1 ? e : String.fromCharCode(parseInt(e.slice(1), 16));
      default: return e; // \' \" \\ and any identity escape
    }
  });
}

// @playwright/mcp records a browser_evaluate as generated Playwright code with
// the payload QUOTED: `await page.evaluate('() => {\n ... it\'s ...}')`. Inline
// the decoded payload so it is classified exactly as the bare payload would be
// (the escaping would otherwise hide e.g. `method:\'POST\'` from the regex and
// stop the observe allowance from recognising its source).
function unquoteEvaluateArgs(code) {
  return code.replace(/\.(evaluate|evaluateHandle)\(\s*(?:'((?:[^'\\]|\\[\s\S])*)'|"((?:[^"\\]|\\[\s\S])*)")/g,
    function (m, fn, sq, dq) { return '.' + fn + '(' + decodeJsString(sq !== undefined ? sq : dq); });
}

// Classify one Playwright code snippet into a behavior class + mutating flag.
function classify(code) {
  const c = String(code || '');
  const isEval  = /\.(evaluate|evaluateHandle|\$eval|\$\$eval)\s*\(/.test(c);
  const isRoute = /\.route(FromHAR)?\s*\(/.test(c);
  const isHuman = /\.(click|dblclick|fill|type|press|selectOption|hover|check|uncheck|setInputFiles|dragTo|tap)\s*\(/.test(c);
  let cls = 'other';
  if (isRoute) cls = 'route';
  else if (isEval) cls = 'evaluate';
  else if (isHuman) cls = 'human-path';
  // human-path acts are inherently state-driving (that's the point) and are the
  // SANCTIONED path — mutating:true but class human-path => never a workaround.
  // evaluate/route are workarounds ONLY when they mutate; route is treated as
  // mutating (backend interception manufactures state) unless it is a passive
  // read. `other` (navigation, waits) is not mutating.
  let mutating;
  if (cls === 'human-path') mutating = true;
  else if (cls === 'route') mutating = true;
  else if (cls === 'evaluate') mutating = mutates(unquoteEvaluateArgs(c));
  else mutating = false;
  return { class: cls, mutating: mutating, code: c.slice(0, 200) };
}

function parse(md) {
  const text = String(md || '');
  const calls = [];
  const FENCE = String.fromCharCode(96,96,96); // three backticks (kept out of source literally)
  // REAL @playwright/mcp --save-session format: one "### Tool call: <name>"
  // section per call; the executed Playwright code is the `code` field inside
  // that call's "- Result" fenced-json block (NOT a "Ran Playwright code" js
  // block — that is the interactive response format, not the saved file).
  const sections = text.split(/^###\s+Tool call:/m).slice(1);
  const reJson = new RegExp(FENCE + 'json\\s*([\\s\\S]*?)' + FENCE);
  for (let k = 0; k < sections.length; k++) {
    const sec = sections[k];
    const rIdx = sec.indexOf('- Result');
    if (rIdx < 0) continue;
    const m = sec.slice(rIdx).match(reJson);
    if (!m) continue;
    let code = '';
    try { const obj = JSON.parse(m[1]); code = typeof obj.code === 'string' ? obj.code : ''; }
    catch (e) { continue; }
    if (code.trim()) calls.push(classify(code));
  }
  return calls;
}
if (require.main === module) {
  const p = process.argv[2];
  if (!p) { process.stderr.write('usage: parse-session-log.js <session.md>\n'); process.exit(2); }
  process.stdout.write(JSON.stringify(parse(fs.readFileSync(p, 'utf8'))) + '\n');
}
module.exports = { parse: parse, classify: classify, mutates: mutates };
