const { test } = require('node:test');
const assert = require('node:assert');
const { measure } = require('../ux-measure.js');

test('content-nan record yields one high-confidence gated fail finding', () => {
  const snapshot = {
    records: [
      { seed: 'C1', family: 'content', kind: 'nan', input: { text: 'NaN' } }
    ]
  };
  const out = measure(snapshot);
  assert.equal(out.findings.length, 1);
  const f = out.findings[0];
  assert.equal(f.judgedSeedId, 'C1');
  assert.equal(f.verdict, 'fail');
  assert.equal(f.confidence, 'high');
  assert.equal(f.axis, 'ux-objective');
});

test('negative-control clean-content record yields no gated finding', () => {
  const snapshot = {
    records: [
      { seed: 'NC1', family: 'content', kind: 'clean', polarity: 'negative', input: { text: '1,250.00' } }
    ]
  };
  const out = measure(snapshot);
  assert.equal(out.findings.length, 0);
});

test('sheet-stack (interaction) record with corroborated ground-truth yields an interaction-overlay-destroyed fail', () => {
  const snapshot = {
    records: [
      { seed: 'SS1', family: 'interaction', kind: 'interaction-overlay-destroyed', heldOut: true,
        input: {
          before: [
            { id: 'dialog:Deliverables', role: 'dialog', ariaModal: true, zIndex: 100, position: 'fixed', focusTrapped: true, parentId: null, present: true }
          ],
          afterOpenChild: [
            { id: 'dialog:New Deliverable', role: 'dialog', ariaModal: true, zIndex: 100, position: 'fixed', focusTrapped: true, parentId: null, present: true }
          ],
          childId: 'dialog:New Deliverable'
        } }
    ]
  };
  const out = measure(snapshot);
  assert.equal(out.findings.length, 1);
  const f = out.findings[0];
  assert.equal(f.judgedSeedId, 'SS1');
  assert.equal(f.verdict, 'fail');
  assert.equal(f.confidence, 'high');
  assert.equal(f.axis, 'ux-objective');
  assert.match(f.text, /interaction-overlay-destroyed/);
});

test('correctly-stacked interaction negative control yields no finding', () => {
  const snapshot = {
    records: [
      { seed: 'NC5', family: 'interaction', kind: 'correctly-stacked', polarity: 'negative',
        input: {
          before: [
            { id: 'dialog:Deliverables', role: 'dialog', ariaModal: true, zIndex: 100, position: 'fixed', focusTrapped: true, parentId: null, present: true }
          ],
          afterOpenChild: [
            { id: 'dialog:Deliverables', role: 'dialog', ariaModal: true, zIndex: 100, position: 'fixed', focusTrapped: true, parentId: null, present: true },
            { id: 'dialog:Child', role: 'dialog', ariaModal: true, zIndex: 100, position: 'fixed', focusTrapped: true, parentId: 'dialog:Deliverables', present: true }
          ],
          childId: 'dialog:Child'
        } }
    ]
  };
  const out = measure(snapshot);
  assert.equal(out.findings.length, 0);
});

test('generic overlap-rect heuristic (uncorroborated) is advisory only, never a gated finding', () => {
  const snapshot = {
    records: [
      { seed: 'O2', family: 'overlap-rect', kind: 'rect-collision', stream: 'advisory',
        input: { rectA: { left: 20, top: 20, right: 160, bottom: 50 },
                 rectB: { left: 100, top: 30, right: 240, bottom: 60 } } }
    ]
  };
  const out = measure(snapshot);
  const gated = out.findings.filter(f => f.verdict === 'fail');
  assert.equal(gated.length, 0);
  assert.equal(out.findings.length, 1);
  assert.equal(out.findings[0].stream, 'advisory');
});

test('unknown family is skipped, never fabricated', () => {
  const snapshot = { records: [{ seed: 'X1', family: 'nonexistent-family', input: {} }] };
  const out = measure(snapshot);
  assert.equal(out.findings.length, 0);
});
