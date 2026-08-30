#!/usr/bin/env node
/*
 * pass-gate.js — reference implementation of the EXECUTION-ENFORCEMENT seam (plan §fix-3a).
 *
 * Invariant enforced: "a green toast is not a pass" becomes machine-checkable. A `pass` verdict is
 * INVALID unless the criterion recorded the evidence classes its kind requires:
 *   - any write criterion        -> a bake read-back artifact (evidence/<id>/bake-read-back.json)
 *   - any computed-logic criterion -> an independent recompute artifact (evidence/<id>/recompute.md)
 *   - a probe was needed          -> a network/probe artifact (evidence/<id>/network-response.json)
 * Missing evidence => the pass is downgraded to `blocked` (env/precondition) or flagged INVALID for
 * the agent to fix, never silently accepted. blocked/deferred/error/fail are exempt (they are honest
 * non-passes). This is the seam the plan proposes wiring into checkpoint.sh (PLAN-ONLY there); this
 * standalone node script proves it works and can be adopted verbatim.
 *
 * Usage:
 *   node pass-gate.js <criterion.json>
 * criterion.json: { "id":"GOV-01", "verdict":"pass", "kinds":["write","computed"],
 *                   "probeNeeded": false,
 *                   "evidenceRefs":["evidence/GOV-01/bake-read-back.json", ...] }
 * exit 0 = valid pass (or non-pass verdict); exit 1 = INVALID pass (evidence missing).
 */
'use strict';
const fs = require('fs');

const p = process.argv[2];
if (!p) { console.error('usage: node pass-gate.js <criterion.json>'); process.exit(2); }
const c = JSON.parse(fs.readFileSync(p, 'utf8'));

if (c.verdict !== 'pass') {
  console.log('OK  ' + c.id + ' verdict=' + c.verdict + ' (only pass is gated)');
  process.exit(0);
}

const refs = (c.evidenceRefs || []).join('\n');
const kinds = c.kinds || [];
const required = [];
if (kinds.indexOf('write') >= 0) required.push({ what: 'bake read-back', rx: /bake-read-back\.json/ });
if (kinds.indexOf('computed') >= 0) required.push({ what: 'independent recompute', rx: /recompute\.(md|json)/ });
if (c.probeNeeded) required.push({ what: 'probe/network body', rx: /network-response\.json/ });

const missing = required.filter(function (r) { return !r.rx.test(refs); });

if (missing.length === 0) {
  console.log('OK  ' + c.id + ' pass is valid (' + required.map(function (r) { return r.what; }).join(', ') + ' present)');
  process.exit(0);
}
console.log('INVALID PASS  ' + c.id + ' — a pass requires evidence: ' + missing.map(function (m) { return m.what; }).join(', '));
console.log('  => downgrade to blocked (precondition/evidence missing) or supply the evidence. "A green toast is not a pass."');
process.exit(1);
