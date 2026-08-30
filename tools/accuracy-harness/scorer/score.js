#!/usr/bin/env node
/*
 * score.js — the rerunnable proof. Scores a findings file against seeds.json and prints
 * true bug-recall PER AXIS, then checks the acceptance gate.
 *
 * Usage:
 *   node scorer/score.js <findings.json> [--seeds seeds.json] [--gate]
 *
 * findings.json shape: { "source": "...", "findings": [ { "seedId"?: "F1", "judgedSeedId"?: "F1",
 *                        "axis"?: "functional", "verdict"?: "fail",
 *                        "text": "free-text of what the run reported" }, ... ] }
 *
 * Strict attribution: a seed is RECALLED only when some finding has finding.seedId === seed.id
 * OR finding.judgedSeedId === seed.id (the latter assigned by attribute.js, Task 0.4). A bare
 * keyword (`seed.match`) appearing in finding text is a HINT used by the judge to decide
 * attribution — it is NEVER, by itself, a scorer credit.
 *
 * Precision: seeds with polarity:"negative" are clean values that must NOT be flagged. A
 * finding attributed to a negative-control seed is a false positive; precision = TP / (TP+FP)
 * over positive/negative seeds that were recalled.
 *
 * Verdict enum: any finding carrying a `verdict` outside pass|fail|blocked|deferred|error throws.
 *
 * Subjective seeds (stream:"advisory") are scored in a SEPARATE advisory stream and never
 * counted in the verdict-recall gate or the `overall` denominator (ADR-0008: aesthetics are
 * advisory, never a verdict).
 *
 * MEASURED vs ESTIMATED: numbers are MEASURED when findings.json is a real qa-e2e-pilot run's
 * bug-log.json (converted via convert-buglog.js). The bundled findings/baseline.json and
 * findings/after-fixed.json are ESTIMATED projections (labeled as such) — see README.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const VERDICTS = new Set(['pass', 'fail', 'blocked', 'deferred', 'error']);

function creditsSeed(finding, seed) {
  if (finding.seedId && finding.seedId === seed.id) return true;
  if (finding.judgedSeedId && finding.judgedSeedId === seed.id) return true;
  return false; // NOTE: keyword `match` is a judge hint (attribute.js), never a scorer credit
}

function score(findingsDoc, seedsDoc) {
  const seeds = seedsDoc.seeds;
  const findings = findingsDoc.findings || [];

  // enum guard — a demo/real finding may only carry a real verdict (or none, for advisory notes)
  for (const f of findings) {
    if (f.verdict != null && !VERDICTS.has(f.verdict)) {
      throw new Error(`invalid verdict "${f.verdict}" (allowed: ${[...VERDICTS].join('|')})`);
    }
  }

  const positive = seeds.filter(s => (s.polarity || 'positive') === 'positive' && s.stream !== 'advisory');
  const negative = seeds.filter(s => s.polarity === 'negative');
  const advisorySeeds = seeds.filter(s => s.stream === 'advisory');

  const recalled = seed => findings.some(f => creditsSeed(f, seed));

  // precision: TP = attributed to a positive seed; FP = attributed to a negative-control seed
  const tp = positive.filter(recalled).length;
  const fp = negative.filter(recalled).length;
  const precision = (tp + fp) === 0 ? 1 : tp / (tp + fp);

  const byAxis = {};
  for (const s of positive) (byAxis[s.axis] = byAxis[s.axis] || []).push(s);
  const scoreList = list => {
    const hit = list.filter(recalled).length;
    return { total: list.length, hit, ratio: list.length ? hit / list.length : 1,
             missed: list.filter(s => !recalled(s)) };
  };
  const perAxis = {}; for (const ax of Object.keys(byAxis)) perAxis[ax] = scoreList(byAxis[ax]);
  const rollups = {
    functional: scoreList([...(byAxis['functional']||[]), ...(byAxis['broken-journey']||[])]),
    ux: scoreList(byAxis['ux-objective'] || [])
  };
  const overall = scoreList(positive);
  const advisory = scoreList(advisorySeeds);

  const g = seedsDoc.gate || {};
  const checks = [
    ['functional recall', rollups.functional.ratio, g.functionalRecallMin],
    ['ux-objective recall', (perAxis['ux-objective']||{ratio:1}).ratio, g.uxObjectiveRecallMin],
    ['overall recall', overall.ratio, g.overallVerdictRecallMin],
    ['precision', precision, g.precisionMin]
  ].filter(c => c[2] != null);
  const pass = checks.every(c => c[1] >= c[2] - 1e-9);

  return { perAxis, rollups, overall, precision, advisory, gate: { pass, checks } };
}

module.exports = { score };

// ---------------------------------------------------------------------------
// CLI — only runs when score.js is invoked directly, never on require().
// ---------------------------------------------------------------------------
if (require.main === module) {
  function loadJSON(p) { return JSON.parse(fs.readFileSync(p, 'utf8')); }

  const args = process.argv.slice(2);
  if (!args[0] || args[0] === '-h' || args[0] === '--help') {
    console.error('usage: node score.js <findings.json> [--seeds <seeds.json>] [--gate]');
    process.exit(2);
  }
  const findingsPath = args[0];
  const seedsPath = (function () {
    const i = args.indexOf('--seeds');
    return i >= 0 ? args[i + 1] : path.join(__dirname, '..', 'seeds.json');
  })();
  const enforceGate = args.includes('--gate');

  const seedsDoc = loadJSON(seedsPath);
  const findingsDoc = loadJSON(findingsPath);

  const result = score(findingsDoc, seedsDoc);

  function pct(x) { return (x * 100).toFixed(0) + '%'; }
  function bar(x) { const n = Math.round(x * 20); return '[' + '#'.repeat(n) + '-'.repeat(20 - n) + ']'; }

  console.log('\n=== qa-e2e-pilot accuracy scorer ===');
  console.log('findings source : ' + (findingsDoc.source || findingsPath) + (findingsDoc.estimated ? '  (ESTIMATED)' : '  (MEASURED)'));
  console.log('seeds           : ' + seedsPath + '  (' + seedsDoc.seeds.length + ' planted bugs)\n');

  console.log('Per sub-axis:');
  Object.keys(result.perAxis).sort().forEach(function (ax) {
    const r = result.perAxis[ax];
    console.log('  ' + ax.padEnd(16) + bar(r.ratio) + ' ' + pct(r.ratio) + '  (' + r.hit + '/' + r.total + ')');
  });

  console.log('\nNorth-star roll-ups:');
  ['functional', 'ux'].forEach(function (name) {
    const r = result.rollups[name];
    console.log('  ' + name.padEnd(16) + bar(r.ratio) + ' ' + pct(r.ratio) + '  (' + r.hit + '/' + r.total + ')');
  });
  console.log('  ' + 'overall'.padEnd(16) + bar(result.overall.ratio) + ' ' + pct(result.overall.ratio) + '  (' + result.overall.hit + '/' + result.overall.total + ')');

  console.log('\nPrecision: ' + pct(result.precision) + ' (false positives lower this)');

  // advisory stream (reported, never gated)
  console.log('\nAdvisory stream (aesthetics — reported, NOT a verdict): ' + result.advisory.hit + '/' + result.advisory.total + ' advised');

  // missed detail
  if (result.overall.missed.length) {
    console.log('\nMissed (false-greens):');
    result.overall.missed.forEach(function (s) { console.log('  - ' + s.id + ' [' + s.axis + '] ' + (s.title || '')); });
  }

  // gate
  if (enforceGate) {
    console.log('\n=== ACCEPTANCE GATE ===');
    result.gate.checks.forEach(function (c) {
      const ok = c[1] >= c[2] - 1e-9;
      console.log('  ' + (ok ? 'PASS' : 'FAIL') + '  ' + c[0].padEnd(24) + pct(c[1]) + ' >= ' + pct(c[2]));
    });
    console.log(result.gate.pass ? '\nGATE: PASS' : '\nGATE: FAIL');
    process.exit(result.gate.pass ? 0 : 1);
  }
}
