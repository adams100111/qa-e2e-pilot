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

// Task 0.3b: ux-perceptual seeds are vision-only (no vision reviewer exists yet) and must be
// gate-excluded — reported in a separate `perceptual` bucket instead of counted as positive.
test('ux-perceptual seeds are excluded from gated measurement and reported separately', () => {
  const perceptualSeeds = {
    gate: { functionalRecallMin: 0.5, uxObjectiveRecallMin: 0.5, overallVerdictRecallMin: 0.5, precisionMin: 0.8 },
    seeds: [
      { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
      { id: 'U1', axis: 'ux-objective', polarity: 'positive', match: ['contrast'] },
      { id: 'P1', axis: 'ux-perceptual', polarity: 'positive', stream: 'advisory-eligible', match: ['misaligned'] }
    ]
  };

  const rMissed = score({ findings: [
    { seedId: 'F1', verdict: 'fail', text: 'wrong denominator' },
    { seedId: 'U1', verdict: 'fail', text: 'low contrast helper' }
  ] }, perceptualSeeds);

  // P1 not recalled: overall/perAxis/rollups must not include it at all
  assert.equal(rMissed.overall.total, 2); // F1, U1 only — P1 excluded
  assert.equal(rMissed.rollups.ux.total, 1); // ux-objective only, P1 (ux-perceptual) never enters
  assert.ok(!('ux-perceptual' in rMissed.perAxis));
  assert.ok(rMissed.perceptual, 'expected a perceptual bucket on the result');
  assert.equal(rMissed.perceptual.total, 1);
  assert.equal(rMissed.perceptual.hit, 0);
  assert.equal(rMissed.gate.pass, true); // F1+U1 both recalled -> gate passes regardless of P1

  // Now recall P1 too — gate result must be identical (unaffected either way)
  const rRecalled = score({ findings: [
    { seedId: 'F1', verdict: 'fail', text: 'wrong denominator' },
    { seedId: 'U1', verdict: 'fail', text: 'low contrast helper' },
    { seedId: 'P1', verdict: 'fail', text: 'misaligned columns' }
  ] }, perceptualSeeds);

  assert.equal(rRecalled.overall.total, 2); // still excludes P1
  assert.equal(rRecalled.perceptual.hit, 1);
  assert.equal(rRecalled.gate.pass, rMissed.gate.pass); // recalling P1 changes nothing about the gate
});
