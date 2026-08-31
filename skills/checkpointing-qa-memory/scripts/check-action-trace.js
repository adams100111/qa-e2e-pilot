'use strict';
/*
 * check-action-trace.js — the human-action evidence value-check (spec A1).
 * exit 0 = valid (act performed through the UI, no concealed workaround);
 * exit 1 = REJECT with a one-line reason on stderr. `--allow-nonui` permits a
 * logged opt-out (checkpoint forces confidence low upstream).
 *
 * Representations bridged here:
 *   - steps[]        = agent self-report, MCP-tool-level {tool,target,phase,payload?}
 *   - sessionCalls[] = INDEPENDENT ground truth, Playwright-code-level
 *                      {class,mutating,code} parsed from session.md by
 *                      parse-session-log.js (real @playwright/mcp format).
 *
 * Check 2 (act-phase payload lint): an act-phase browser_evaluate is a
 *   workaround ONLY if its payload MUTATES (read-only observe evaluate is fine);
 *   browser_run_code_unsafe / a backend browser_route on the act path are always
 *   workarounds.
 * Check 1 (act-phase tool class): an act step whose tool is not a human-path
 *   tool and is not a read-only evaluate is a workaround.
 * Check 0 (concealed-workaround reconciliation): a MUTATING evaluate/route call
 *   in session.md that has NO corresponding recorded step (of ANY phase) is a
 *   concealed workaround. session.md is phase-less and timestamp-thin, so we
 *   reconcile the WHOLE criterion window against ALL recorded steps — this still
 *   catches "took a mutating shortcut and didn't record it"; phase-mislabeling
 *   is the acknowledged residual (reviewer spot-check), per spec §2B.
 */
const fs = require('fs');
const path = require('path');
// Reuse the ONE classifier so act-payloads and session code are judged identically.
const { mutates } = require(path.join(__dirname, '..', '..', 'driving-browser-qa', 'scripts', 'parse-session-log.js'));
const HUMAN_PATH_TOOLS = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_file_upload','browser_navigate']);
function die(msg) { process.stderr.write('HUMAN-ACTION GATE: ' + msg + '\n'); process.exit(1); }

// Is this self-reported act step a workaround? human-path tools are fine; an
// evaluate is a workaround only if its bare payload MUTATES (read-only observe
// evaluate is allowed); anything else on the act path (run_code_unsafe / route /
// unknown) is a workaround. `mutates()` is the same lint used on session.md.
function actStepIsWorkaround(s) {
  if (HUMAN_PATH_TOOLS.has(s.tool)) return false;
  if (s.tool === 'browser_evaluate') return mutates(s.payload || '') === true;
  return true; // browser_run_code_unsafe, browser_route, or any non-human-path tool
}

function main() {
  const p = process.argv[2];
  const allowNonUi = process.argv.indexOf('--allow-nonui') >= 0;
  if (!p) { process.stderr.write('usage: check-action-trace.js <action-trace.json> [--allow-nonui]\n'); process.exit(2); }
  let doc;
  try { doc = JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { die('action-trace.json is missing or not valid JSON'); }
  const steps = Array.isArray(doc.steps) ? doc.steps : null;
  if (!steps) die('action-trace.json has no steps[] array');
  const actSteps = steps.filter(function (s) { return s && s.phase === 'act'; });
  if (actSteps.length === 0) die('action-trace has no act-phase step — the action-under-test was never performed');

  if (allowNonUi) process.exit(0); // logged tool-limitation opt-out (confidence low upstream)

  // Check 1/2 — act-phase steps must be human-path (or read-only evaluate).
  const badAct = actSteps.filter(actStepIsWorkaround);
  if (badAct.length) {
    die('act performed via workaround "' + (badAct[0].tool) + '"' +
        (badAct[0].payload ? ' (' + String(badAct[0].payload).slice(0, 60) + ')' : '') +
        ' — perform through the UI, or record the UI-impossibility as a fail (or log nonUiActionReason)');
  }

  // Check 0 — reconcile MUTATING session.md calls against ALL recorded steps.
  // A recorded step "covers" a session call if it is a human-path act (covers a
  // .click()/.fill() etc.) or an evaluate step whose payload also mutates
  // (covers a recorded mutating evaluate opt-out). We count coverage capacity so
  // N concealed mutating calls need N covering steps.
  const sessionCalls = Array.isArray(doc.sessionCalls) ? doc.sessionCalls : [];
  // Coverage = recorded NON-UI mutations only (a mutating evaluate / run_code_unsafe
  // / route). A human-path step must NOT count — a click cannot account for a
  // concealed setItem (this was a real bug the logic proof caught).
  let coverage = steps.filter(function (s) {
    return (s.tool === 'browser_evaluate' && mutates(s.payload || '')) || s.tool === 'browser_run_code_unsafe' || s.tool === 'browser_route';
  }).length;
  const mutatingSession = sessionCalls.filter(function (c) { return c && c.mutating && c.class !== 'human-path'; });
  // human-path mutations in session.md are the sanctioned act itself — never concealed.
  for (let i = 0; i < mutatingSession.length; i++) {
    if (coverage > 0) { coverage -= 1; continue; }
    die('session.md shows a mutating "' + mutatingSession[i].class + '" call not accounted for by any recorded step (' +
        String(mutatingSession[i].code).slice(0, 60) + ') — concealed workaround');
  }
  process.exit(0);
}
main();
