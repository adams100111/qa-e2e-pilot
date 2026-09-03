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

// Task 4: held-out gate check — a heldOut:true positive seed must ALSO be recalled at 1.0,
// independent of (and in addition to) the overall/functional/ux-objective thresholds.
const heldOutSeeds = {
  gate: { functionalRecallMin: 0.5, uxObjectiveRecallMin: 0.5, overallVerdictRecallMin: 0.5, precisionMin: 0.8, heldOutRecallMin: 1.0 },
  seeds: [
    { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
    { id: 'H1', axis: 'ux-objective', polarity: 'positive', heldOut: true, match: ['locale-date'] },
    { id: 'N1', axis: 'functional', polarity: 'negative', match: ['clean'] }
  ]
};

test('held-out seed recalled -> held-out check passes and the gate passes', () => {
  const r = score({ findings: [
    { seedId: 'F1', verdict: 'fail', text: 'wrong denominator' },
    { seedId: 'H1', verdict: 'fail', text: 'locale-date mismatch' }
  ] }, heldOutSeeds);
  assert.equal(r.heldOut.total, 1);
  assert.equal(r.heldOut.hit, 1);
  assert.equal(r.heldOut.ratio, 1);
  const heldOutCheck = r.gate.checks.find(c => c[0] === 'held-out recall');
  assert.ok(heldOutCheck, 'expected a held-out recall check in the gate');
  assert.equal(heldOutCheck[1], 1);
  assert.equal(r.gate.pass, true);
});

test('held-out seed NOT recalled -> gate FAILS on the held-out check even if overall is above threshold', () => {
  const r = score({ findings: [
    { seedId: 'F1', verdict: 'fail', text: 'wrong denominator' }
    // H1 (heldOut) missing from findings entirely
  ] }, heldOutSeeds);
  // overall recall is 1/2 = 50%, exactly at overallVerdictRecallMin (0.5) -> that check alone
  // would pass, but the held-out check must independently fail the gate.
  assert.equal(r.overall.ratio, 0.5);
  assert.equal(r.heldOut.total, 1);
  assert.equal(r.heldOut.hit, 0);
  assert.equal(r.heldOut.ratio, 0);
  const heldOutCheck = r.gate.checks.find(c => c[0] === 'held-out recall');
  assert.equal(heldOutCheck[1], 0);
  assert.equal(r.gate.pass, false);
});

test('knownGap:true seed is excluded from the positive/overall denominator', () => {
  const withGap = {
    gate: { overallVerdictRecallMin: 0.5, precisionMin: 0.8 },
    seeds: [
      { id: 'F1', axis: 'functional', polarity: 'positive', match: ['denominator'] },
      { id: 'G1', axis: 'ux-objective', polarity: 'positive', knownGap: true, gapReason: 'out of scope', match: ['gap'] }
    ]
  };
  const r = score({ findings: [{ seedId: 'F1', verdict: 'fail', text: 'wrong denominator' }] }, withGap);
  // G1 (knownGap) never enters the denominator — overall is F1-only, fully recalled.
  assert.equal(r.overall.total, 1);
  assert.equal(r.overall.hit, 1);
  assert.equal(r.overall.ratio, 1);
});

test('a seeds set with no heldOutRecallMin (existing seeds.json shape) gates identically (backward-compat)', () => {
  const r = score({ findings: [{ seedId: 'F1', verdict: 'fail', text: 'wrong denominator' }] }, seeds);
  // `seeds` (top of file) has no heldOutRecallMin in its gate block.
  assert.ok(!seeds.gate.heldOutRecallMin);
  const heldOutCheck = r.gate.checks.find(c => c[0] === 'held-out recall');
  assert.equal(heldOutCheck, undefined, 'held-out check must be omitted (null-guarded) when heldOutRecallMin is absent');
  // heldOut bucket still computed/reported (empty, ratio 1) even though it is not gated.
  assert.equal(r.heldOut.total, 0);
  assert.equal(r.heldOut.ratio, 1);
});
