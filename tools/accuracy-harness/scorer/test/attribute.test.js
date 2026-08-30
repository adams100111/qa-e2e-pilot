const { test } = require('node:test');
const assert = require('node:assert');
const { attribute } = require('../attribute.js');

const seeds = [{ id: 'F2', axis: 'functional', match: ['amount', 'precision'],
  title: 'SAFE amount truncates to 2 decimals (sub-cent loss)' }];

test('judge rejects keyword collision, credits real defect', () => {
  const findings = [
    { text: 'the amount field is nicely aligned' },       // keyword "amount" but NOT the defect
    { text: 'SAFE amount shows 4000.00, lost the sub-cent tail' } // the real defect
  ];
  const stubJudge = ({ finding }) =>
    /sub-cent|lost the/.test(finding.text) ? 'F2' : null;
  const out = attribute(findings, seeds, stubJudge);
  assert.equal(out[0].judgedSeedId, undefined);
  assert.equal(out[1].judgedSeedId, 'F2');
});

test('findings with no candidate seeds are left untouched', () => {
  const out = attribute([{ text: 'totally unrelated' }], seeds, () => { throw new Error('judge should not be called'); });
  assert.equal(out[0].judgedSeedId, undefined);
});
