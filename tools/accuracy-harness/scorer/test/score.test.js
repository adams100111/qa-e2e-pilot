const { test } = require('node:test');
const assert = require('node:assert');
const { score } = require('../score.js');

const seeds = {
  gate: { functionalRecallMin: 0.5, uxObjectiveRecallMin: 0.5, overallVerdictRecallMin: 0.5, precisionMin: 0.8 },
  seeds: [
    { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
    { id: 'U1', axis: 'ux-objective', polarity: 'positive', match: ['contrast'] },
    { id: 'N1', axis: 'functional', polarity: 'negative', match: ['clean'] },
    { id: 'S1', axis: 'ux-subjective', polarity: 'positive', stream: 'advisory', match: ['garish'] }
  ]
};

test('bare keyword match does NOT credit a seed (strict attribution)', () => {
  const r = score({ findings: [{ text: 'the denominator is fine actually' }] }, seeds);
  assert.equal(r.rollups.functional.hit, 0); // keyword present, but no seedId/judgedSeedId
});

test('explicit seedId credits the seed', () => {
  const r = score({ findings: [{ seedId: 'F1', verdict: 'fail', text: 'wrong denominator' }] }, seeds);
  assert.equal(r.rollups.functional.hit, 1);
});

test('judgedSeedId (from attribute.js) credits the seed', () => {
  const r = score({ findings: [{ judgedSeedId: 'U1', verdict: 'fail', text: 'low contrast helper' }] }, seeds);
  assert.equal(r.perAxis['ux-objective'].hit, 1);
});

test('finding on a negative-control seed is a false positive', () => {
  const r = score({ findings: [
    { seedId: 'F1', verdict: 'fail', text: 'x' },
    { seedId: 'N1', verdict: 'fail', text: 'flagged a clean value' }
  ]}, seeds);
  assert.equal(r.precision, 0.5);
});

test('advisory-stream seeds never count in verdict recall or the gate', () => {
  const r = score({ findings: [{ seedId: 'S1', verdict: 'fail', text: 'garish' }] }, seeds);
  assert.equal(r.overall.total, 2); // F1,U1 — N1 is a negative control (precision only), S1 advisory; both excluded from verdict recall
  assert.ok(r.advisory.total >= 1);
});

test('an out-of-enum verdict throws', () => {
  assert.throws(() => score({ findings: [{ seedId: 'F1', verdict: 'advisory', text: 'x' }] }, seeds),
    /verdict.*advisory/i);
});
