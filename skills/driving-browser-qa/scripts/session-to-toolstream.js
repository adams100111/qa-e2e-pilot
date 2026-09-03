'use strict';
/*
 * session-to-toolstream.js — convert a Playwright MCP `--save-session`
 * session.md into toolstream events consumable by scripts/toolstream.sh's
 * `append` (and, from there, scripts/provenance.sh's binding `check`).
 *
 * WHY: non-Claude harnesses (Codex/Pi/opencode) already run the Playwright
 * MCP with `--save-session`, producing a session.md, but have no
 * capture-hook writing .qa/runs/<run>/toolstream.jsonl the way Claude's
 * hook does. Without a toolstream, provenance.sh degrades every artifact to
 * "no-toolstream" and qa-verify discounts confidence to low. This script
 * closes that gap: feed it the session.md, pipe its ndjson output through
 * `toolstream.sh append`, and those harnesses get the same high-confidence
 * provenance binding Claude gets.
 *
 * Reuses the SINGLE source of truth for session parsing/classification,
 * the sibling ./parse-session-log.js (`parse(md) -> [{class, mutating,
 * code}]`) — this file does not re-implement any of that parsing, and is
 * dependency-free beyond it (no crypto, no third-party packages).
 *
 * Each parsed call becomes ONE event:
 *   { tool, args, resultDigest, responseBody }
 * Deliberately NO `seq`/`ts` here — `toolstream.sh append` stamps a
 * monotonic seq and a UTC timestamp onto whatever object it's given; this
 * converter's output is meant to be piped one line at a time through
 * `toolstream.sh append <run-id> <line>`, not written to the toolstream
 * file directly.
 *
 * `tool` mapping — MUST satisfy provenance.sh's class-appropriate binding
 * check (see that file's header comment for the exact rules: human-path
 * requires a captured tool name ENDING WITH one of the human-interaction
 * short names; evaluate/route require one CONTAINING browser_evaluate /
 * browser_navigate respectively):
 *   class "human-path" -> derive the verb from the code:
 *     .click(/.dblclick(       -> browser_click
 *     .fill(                   -> browser_fill_form
 *     .type(                   -> browser_type
 *     .selectOption(           -> browser_select_option
 *     .press(                  -> browser_press_key
 *     .hover(                  -> browser_hover
 *     .setInputFiles(          -> browser_file_upload
 *     .dragTo(                 -> browser_drag
 *     .check(/.uncheck(/.tap(  -> browser_click (closest interaction)
 *     (no pattern matched -- shouldn't happen, class human-path implies
 *      parse-session-log.js's own isHuman regex already matched one of the
 *      above) -> browser_click
 *   class "evaluate" -> browser_evaluate
 *   class "route"    -> browser_navigate
 *   class "other"    -> browser_navigate
 * Each is emitted as the FULL MCP tool name
 * (`mcp__plugin_playwright_playwright__browser_<verb>`) so it satisfies
 * provenance.sh's containment/endswith checks against the short name.
 *
 * `resultDigest` is a short, deterministic, NON-cryptographic digest of the
 * code (provenance.sh never reads resultDigest — it binds on `.tool`
 * class-appropriateness, and on `.responseBody` containment for bake/probe
 * kinds only, neither of which applies to resultDigest). Good enough to be
 * stable across runs for the same input.
 *
 * `responseBody` is always null: parse-session-log.js's parse() extracts
 * only `code` from the saved session (the "- Result" section's response
 * body is not reliably present/structured in the saved format), and
 * provenance.sh's action-trace binding (the path this converter's output
 * feeds) checks the captured `.tool`, never `.responseBody`.
 */
const fs = require('fs');
const { parse } = require('./parse-session-log.js');

const TOOL_PREFIX = 'mcp__plugin_playwright_playwright__';

// humanVerb(code) -> the closest browser_* interaction verb for a
// class:"human-path" snippet. Order matters only where one pattern could be
// a substring of another's surrounding text; each check requires the
// literal ".<method>(" so e.g. ".dblclick(" never matches ".click(".
function humanVerb(code) {
  const c = String(code || '');
  if (/\.click\(/.test(c)) return 'browser_click';
  if (/\.dblclick\(/.test(c)) return 'browser_click';
  if (/\.fill\(/.test(c)) return 'browser_fill_form';
  if (/\.type\(/.test(c)) return 'browser_type';
  if (/\.selectOption\(/.test(c)) return 'browser_select_option';
  if (/\.press\(/.test(c)) return 'browser_press_key';
  if (/\.hover\(/.test(c)) return 'browser_hover';
  if (/\.setInputFiles\(/.test(c)) return 'browser_file_upload';
  if (/\.dragTo\(/.test(c)) return 'browser_drag';
  if (/\.(check|uncheck|tap)\(/.test(c)) return 'browser_click';
  return 'browser_click';
}

function verbFor(call) {
  switch (call.class) {
    case 'human-path': return humanVerb(call.code);
    case 'evaluate': return 'browser_evaluate';
    case 'route': return 'browser_navigate';
    default: return 'browser_navigate'; // class "other" (navigate/wait/etc.)
  }
}

// digest(code) -> short deterministic string, no crypto dependency. Only
// needs to be stable for the same input, never needs to be collision-proof
// or secure (see the header note on why provenance.sh never reads this).
function digest(code) {
  const s = String(code || '');
  let h = 5381;
  for (let i = 0; i < s.length; i++) {
    h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  }
  return s.length + '-' + h.toString(16);
}

// sessionToEvents(md) -> [{tool, args, resultDigest, responseBody}]
function sessionToEvents(md) {
  const calls = parse(md);
  return calls.map(function (call) {
    return {
      tool: TOOL_PREFIX + verbFor(call),
      args: { code: call.code },
      resultDigest: digest(call.code),
      responseBody: null
    };
  });
}

if (require.main === module) {
  const p = process.argv[2];
  if (!p) {
    process.stderr.write('usage: session-to-toolstream.js <session.md>\n');
    process.exit(2);
  }
  const md = fs.readFileSync(p, 'utf8');
  const events = sessionToEvents(md);
  for (let i = 0; i < events.length; i++) {
    process.stdout.write(JSON.stringify(events[i]) + '\n');
  }
}

module.exports = { sessionToEvents: sessionToEvents };
