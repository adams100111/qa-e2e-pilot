'use strict';
/*
 * parse-session-log.js — read a Playwright MCP `--save-session` session.md and
 * emit the ordered calls as classified JSON `[{class, mutating, code}]`.
 * Dependency-free. VERIFIED format (@playwright/mcp@0.0.79,
 * playwright-core/lib/coreBundle.js): each executed step is a section titled
 * "Ran Playwright code" followed by a ```js fenced block of GENERATED PLAYWRIGHT
 * CODE (e.g. `await page.locator('#add').click();`) — NOT MCP tool names. So we
 * classify by code pattern, and (crucially) flag `mutating` ONLY when the code
 * writes app state, so read-only observation evaluate is never a workaround.
 *
 * The `classify(code)` here is the SINGLE source of truth also used by
 * check-action-trace.js for act-phase evaluate payloads (Check 2) — keep them
 * one function via the shared export.
 */
const fs = require('fs');

// Does this snippet WRITE app/DOM/storage state? (read-only reads are ignored.)
const MUTATION_RE = /\.setItem\(|\.removeItem\(|localStorage\.clear\(|sessionStorage\.(set|remove|clear)|\.value\s*=|\.checked\s*=|\.innerHTML\s*=|\.innerText\s*=|\.textContent\s*=|\.setAttribute\(|\.dispatchEvent\(|\.click\(\)|\.submit\(\)|\.requestSubmit\(|\.remove\(\)|\[['\"](value|checked|innerHTML|innerText|textContent)['\"]\]\s*=|document\.\w+\s*=|window\.\w+\s*=|method\s*:\s*['\"](POST|PUT|PATCH|DELETE)|\.open\(\s*['\"](POST|PUT|PATCH|DELETE)|sendBeacon\(|\.dispatch\(|setState\(/;

// True iff a raw JS snippet writes state. Used BOTH for full session.md code
// AND for a bare action-trace evaluate `payload` (which has no `page.evaluate(`
// wrapper) — so a payload is judged by what it does, not by its wrapper.
function mutates(src) { return MUTATION_RE.test(String(src || '')); }

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
  else if (cls === 'evaluate') mutating = mutates(c);
  else mutating = false;
  return { class: cls, mutating: mutating, code: c.slice(0, 200) };
}

function parse(md) {
  const text = String(md || '');
  const calls = [];
  // Match each "Ran Playwright code" section's fenced js code block. The fence
  // marker is built from char codes so this SOURCE contains no literal triple
  // backtick (keeps the code copy-pasteable inside a markdown code block).
  const FENCE = String.fromCharCode(96, 96, 96); // three backticks
  const re = new RegExp('Ran Playwright code[\\s\\S]*?' + FENCE + '(?:js|javascript)?\\s*([\\s\\S]*?)' + FENCE, 'g');
  let m;
  while ((m = re.exec(text)) !== null) {
    const code = m[1].trim();
    if (code) calls.push(classify(code));
  }
  return calls;
}

if (require.main === module) {
  const p = process.argv[2];
  if (!p) { process.stderr.write('usage: parse-session-log.js <session.md>\n'); process.exit(2); }
  process.stdout.write(JSON.stringify(parse(fs.readFileSync(p, 'utf8'))) + '\n');
}
module.exports = { parse: parse, classify: classify, mutates: mutates };
