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
const HUMAN_PATH_TOOLS = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_file_upload']);
// browser_navigate is NOT a human-path act tool: following a real link is a
// browser_click side effect, so an act-phase browser_navigate is an address-bar
// URL-skip (gap A) — fail-closed unless the step is carve-out-tagged. Five
// named exceptions (WS-2 C, spec §5A): deep-link (open a URL that arrived
// out-of-band, e.g. an emailed reset link), auth-boundary (typed-URL probe of
// a route the persona should/shouldn't reach — a negative-access criterion),
// persona-switch (re-login as another role via a typed URL mid-criterion),
// out-of-band (fetch a side-channel artifact — Mailpit/email/webhook — that
// has no UI affordance). `NAV_CARVEOUTS.has()` is a Set-membership check, not
// a truthy `s.carveout` check: an UNKNOWN/misspelled carveout value is fail-
// closed to "not carved out" (the step is a workaround), never silently
// allowed — see interaction-discipline.md §1 for when each is legitimate.
const NAV_CARVEOUTS = new Set(['deep-link', 'auth-boundary', 'persona-switch', 'out-of-band']);
function navIsCarvedOut(s) { return s.tool === 'browser_navigate' && NAV_CARVEOUTS.has(s.carveout); }
// Phase enum (spec §5A/WS-2 C): {arrange, act, assert}. Fail-closed on the
// unrecognized side: the recognized NON-act phases are exactly {arrange,
// assert} — any step whose phase is 'act' OR is not one of those two
// (unknown label, typo, or omitted entirely) is act-checked. This closes the
// dodge where a mutation labeled with a bogus/missing phase (e.g.
// phase:"weird", or no phase at all) would otherwise skip the act-phase
// workaround check by never matching `phase === 'act'`.
const NON_ACT_PHASES = new Set(['arrange', 'assert']);
function isActPhase(s) { return !!s && (s.phase === 'act' || !NON_ACT_PHASES.has(s.phase)); }
function die(msg) { process.stderr.write('HUMAN-ACTION GATE: ' + msg + '\n'); process.exit(1); }

// readBackPath grammar (Plan H1 #4, fingerprint-target): a top-level key
// (e.g. "count") or a simple dot-path into nested plain objects (e.g.
// "founder.count"). No array indices, wildcards, or bracket syntax. A path
// segment missing from an intermediate object (or a path into a non-object)
// resolves to { found: false } — "not covered" — rather than throwing, so a
// malformed/mismatched target rejects cleanly instead of crashing the gate.
function resolvePath(obj, pathStr) {
  const segs = String(pathStr || '').split('.').filter(Boolean);
  if (!segs.length) return { found: false, value: undefined };
  let cur = obj;
  for (const seg of segs) {
    if (cur === null || typeof cur !== 'object' || !(seg in cur)) return { found: false, value: undefined };
    cur = cur[seg];
  }
  return { found: true, value: cur };
}

// Is this self-reported act step a workaround? human-path tools are fine; an
// evaluate is a workaround only if its bare payload MUTATES (read-only observe
// evaluate is allowed); anything else on the act path (run_code_unsafe / route /
// unknown) is a workaround. `mutates()` is the same lint used on session.md.
function actStepIsWorkaround(s) {
  if (s.tool === 'browser_navigate') return !navIsCarvedOut(s); // act-phase URL-skip unless carve-out-tagged
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
  const actSteps = steps.filter(isActPhase);
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
  // CONTENT-MATCH disclosure (spoof-resistant). A bare COUNT of recorded mutating
  // steps was defeatable: a fabricated decoy mutating step (e.g. document.title='x',
  // never run) would "cover" an unrelated genuine concealed workaround. Instead,
  // each MUTATING session call's inner source must EQUAL a recorded mutating step's
  // payload (squashing whitespace + all brackets so wrapper parens are noise) —
  // a decoy that doesn't equal the concealed call provides no cover. A human-path
  // session mutation is the sanctioned act and is never concealable.
  // #8 squash hardening — STRUCTURE-PRESERVING normalization. The old form
  // `.replace(/[\s(){}\[\];]+/g,'')` deleted every bracket/brace/paren, so two
  // structurally-different snippets (store "x" vs store "[x]") collapsed to the
  // SAME string and a disclosed decoy could alias an UNRELATED concealed call.
  // Instead: drop only whitespace + statement separators and canonicalize quote
  // style (', ", ` -> "), KEEPING structural brackets so distinct structures stay
  // distinct while quote-style-only and whitespace-only differences still match.
  const squash = (x) => String(x || '').replace(/[\s;]+/g, '').replace(/['"`]/g, '"');
  const innerCode = (code) => {
    let c = String(code || '');
    const a = c.indexOf('=>');
    if (a >= 0) {
      // Arrow body: everything after `() =>`. The body is self-balanced, so the
      // slice carries EXACTLY ONE extra trailing ')' from the enclosing
      // `evaluate(`/`route(` wrapper. Drop precisely that one — NOT a greedy
      // "strip while unbalanced" — so a ')' inside a string literal (e.g.
      // setItem("k","a)") ) is preserved and an honest disclosure still matches
      // instead of being false-rejected.
      c = c.slice(a + 2).replace(/\)[\s;]*$/, '');
    } else {
      c = c.replace(/^\s*await\s+/, '').replace(/^page\.(evaluate|evaluateHandle|\$eval|\$\$eval|route|routeFromHAR)\s*/, '');
    }
    return squash(c);
  };
  const disclosed = steps
    .filter((s) => (s.tool === 'browser_evaluate' && mutates(s.payload || '')) || s.tool === 'browser_run_code_unsafe' || s.tool === 'browser_route')
    .map((s) => squash(s.payload || ''));
  const mutatingSession = sessionCalls.filter((c) => c && c.mutating && c.class !== 'human-path');
  for (let i = 0; i < mutatingSession.length; i++) {
    const inner = innerCode(mutatingSession[i].code);
    const idx = inner ? disclosed.indexOf(inner) : -1;
    if (idx >= 0) { disclosed.splice(idx, 1); continue; }  // disclosed one-to-one
    die('session.md shows a mutating "' + mutatingSession[i].class + '" call NOT DISCLOSED by any recorded step (' +
        String(mutatingSession[i].code).slice(0, 60) + ') — concealed workaround');
  }

  // Check 3 — state-fingerprint net (spec A1 Check 3). The tool-agnostic
  // backstop: the mutation lint is an enumerable denylist and cannot recognize
  // an ARBITRARY app-global mutator (e.g. window.__APP__.createItem()). If the
  // action-trace carries before/after persisted-state fingerprints and state
  // CHANGED across the act, there MUST be a human-path act step that plausibly
  // caused it; if every act step is a non-human-path tool (evaluate/route/…),
  // the change came from a non-UI path → unattributed mutation → violation,
  // regardless of whether the lint recognized the specific write. Inert when no
  // fingerprints are supplied (then only Check 0/1/2 apply — the driver SHOULD
  // capture fingerprints for human-action criteria; it reuses the bake read-back).
  const fp = doc.fingerprints;
  // R1: fingerprints are MANDATORY for a human-action pass — otherwise Check 3
  // is trivially skipped by omitting them and an opaque mutator (axios.post,
  // window.app.*) sails through. Capture before/after persisted state around the
  // act (reuse the bake read-back).
  if (!fp || typeof fp !== 'object' || !('before' in fp) || !('after' in fp)) {
    die('human-action pass requires before/after state fingerprints (Check 3 evidence) — capture the persisted state around the act, or record a non-pass verdict');
  }
  const changed = JSON.stringify(fp.before) !== JSON.stringify(fp.after);
  // N2: if state changed, EVERY act step must be human-path. A single non-human-
  // path act step (evaluate/route/run_code_unsafe) co-existing with a state change
  // means the change is not attributable to a UI action — reject, even if the
  // lint classified that step's payload as non-mutating (opaque mutator). A decoy
  // human-path click no longer launders it (the check is "all", not "some").
  if (changed) {
    const bad = actSteps.find((s) => !HUMAN_PATH_TOOLS.has(s.tool) && !navIsCarvedOut(s));
    if (bad) {
      die('persisted state changed across the act while a non-human-path act step was present ("' + bad.tool + '") — the change is not attributable to a UI action (Check 3)');
    }
  }

  // Check 3b (fingerprint-target coverage, Plan H1 #4). The aggregate
  // whole-blob diff above only proves SOMETHING changed — an agent could
  // fingerprint an irrelevant field and leave the criterion's actually-
  // asserted state undetected. When the criterion declares fingerprintTarget
  // {entity, readBackPath, expectChange}, require the before/after
  // fingerprint to CONTAIN that target key (coverage, not equality — no
  // comparison against an external expected value; that is qa-verify's
  // re-bake, Plan H2) and show a change (or non-change) as the oracle
  // expects. Absent fingerprintTarget -> this block is a no-op (back-compat;
  // only the aggregate-changed check above applies).
  // Presence rule (back-compat-safe): a key that is ABSENT, or explicitly
  // `null` (the schema's legit "no target" value, same convention as
  // assertedState:null), means "no target declared" -> Check 3b is a no-op,
  // same as today's behavior. Any other non-object value (string, number,
  // array, ...) is PRESENT-BUT-MALFORMED -> die, rather than silently
  // skipping the block (that silent-skip was the hole: fingerprintTarget:
  // "bogus" sailed through with no diagnostic).
  const target = doc.fingerprintTarget;
  const targetPresent = 'fingerprintTarget' in doc && target !== null;
  if (targetPresent) {
    if (typeof target !== 'object') {
      die('fingerprintTarget must be an object with entity/readBackPath/expectChange');
    }
    const rbp = target.readBackPath;
    if (typeof rbp !== 'string' || !rbp) {
      die('fingerprintTarget.readBackPath must be a non-empty string');
    }
    // expectChange MUST be a strict boolean — the schema declares it a
    // required boolean. Anything else (omitted, null, "true" the string, 1,
    // ...) previously matched neither the `=== true` nor `=== false` branch
    // below and fell through to silent accept, even when the asserted target
    // was unchanged. Require the caller to declare intent explicitly rather
    // than guessing a default.
    if (typeof target.expectChange !== 'boolean') {
      die('fingerprintTarget.expectChange must be a boolean (true = asserted state must change, false = must stay unchanged)');
    }
    const b = resolvePath(fp.before, rbp);
    const a = resolvePath(fp.after, rbp);
    if (!b.found || !a.found) {
      die('fingerprint does not cover the asserted state "' + rbp + '" (Check 3 target)');
    }
    const targetChanged = JSON.stringify(b.value) !== JSON.stringify(a.value);
    if (target.expectChange === true && !targetChanged) {
      die('asserted state "' + rbp + '" did not change across the act (Check 3 target, expectChange:true)');
    }
    if (target.expectChange === false && targetChanged) {
      die('asserted state "' + rbp + '" changed across the act but the criterion expects no change (Check 3 target, expectChange:false)');
    }
  }
  process.exit(0);
}
main();
