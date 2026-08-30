const { test } = require('node:test');
const assert = require('node:assert');
const { score } = require('../score.js'); // Task 0.3 exports score()

const seeds = {
  gate: { functionalRecallMin: 0.7, uxObjectiveRecallMin: 0.75, overallVerdictRecallMin: 0.7, precisionMin: 0.8 },
  seeds: [
    { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
    { id: 'N1', axis: 'functional', polarity: 'negative', match: ['issued shares correct'] } // clean value; flagging it is a false positive
  ]
};

test('flagging a negative-control seed lowers precision', () => {
  const findings = { findings: [
    { seedId: 'F1', text: 'wrong denominator' },   // true positive
    { seedId: 'N1', text: 'issued shares correct look wrong' } // FALSE positive on a clean value
  ]};
  const r = score(findings, seeds);
  assert.equal(r.precision, 0.5); // 1 TP / (1 TP + 1 FP)
});

test('silent on negative controls yields precision 1', () => {
  const findings = { findings: [ { seedId: 'F1', text: 'wrong denominator' } ] };
  const r = score(findings, seeds);
  assert.equal(r.precision, 1);
});
