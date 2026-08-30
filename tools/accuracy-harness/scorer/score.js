#!/usr/bin/env node
/*
 * score.js — the rerunnable proof. Scores a findings file against seeds.json and prints
 * true bug-recall PER AXIS, then checks the acceptance gate.
 *
 * Usage:
 *   node scorer/score.js <findings.json> [--seeds seeds.json] [--gate]
 *
 * findings.json shape: { "source": "...", "findings": [ { "seedId"?: "F1",
 *                        "axis"?: "functional", "verdict"?: "fail",
 *                        "text": "free-text of what the run reported" }, ... ] }
 *
 * Matching: a seed is RECALLED if some finding has finding.seedId === seed.id, OR any of the
 * seed's `match` keywords appears (case-insensitive) in finding.text/message. Subjective seeds
 * (stream:"advisory") are scored in a SEPARATE advisory stream and never counted in the
 * verdict-recall gate (ADR-0008: aesthetics are advisory, never a verdict).
 *
 * MEASURED vs ESTIMATED: numbers are MEASURED when findings.json is a real qa-e2e-pilot run's
 * bug-log.json (converted via convert-buglog.js). The bundled findings/baseline.json and
 * findings/after-fixed.json are ESTIMATED projections (labeled as such) — see README.
 */
'use strict';
const fs = require('fs');
const path = require('path');

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
const seeds = seedsDoc.seeds;
const findingsDoc = loadJSON(findingsPath);
const findings = findingsDoc.findings || [];

function findingText(f) {
  return [f.text, f.message, f.title, f.detector].filter(Boolean).join(' ').toLowerCase();
}
function recalled(seed) {
  return findings.some(function (f) {
    if (f.seedId && f.seedId === seed.id) return true;
    const t = findingText(f);
    return (seed.match || []).some(function (kw) { return t.indexOf(kw.toLowerCase()) >= 0; });
  });
}

// Group seeds by axis; split advisory out.
const axes = {};
const advisory = [];
seeds.forEach(function (s) {
  if (s.stream === 'advisory') { advisory.push(s); return; }
  (axes[s.axis] = axes[s.axis] || []).push(s);
});

// Roll-ups per the north-star: functional = functional + broken-journey; ux = ux-objective.
const rollup = {
  functional: ['functional', 'broken-journey'],
  ux: ['ux-objective']
};

function scoreAxis(list) {
  const hit = list.filter(recalled);
  return { total: list.length, hit: hit.length, missed: list.filter(function (s) { return !recalled(s); }), ratio: list.length ? hit.length / list.length : 1 };
}

function pct(x) { return (x * 100).toFixed(0) + '%'; }
function bar(x) { const n = Math.round(x * 20); return '[' + '#'.repeat(n) + '-'.repeat(20 - n) + ']'; }

console.log('\n=== qa-e2e-pilot accuracy scorer ===');
console.log('findings source : ' + (findingsDoc.source || findingsPath) + (findingsDoc.estimated ? '  (ESTIMATED)' : '  (MEASURED)'));
console.log('seeds           : ' + seedsPath + '  (' + seeds.length + ' planted bugs)\n');

console.log('Per sub-axis:');
Object.keys(axes).sort().forEach(function (ax) {
  const r = scoreAxis(axes[ax]);
  console.log('  ' + ax.padEnd(16) + bar(r.ratio) + ' ' + pct(r.ratio) + '  (' + r.hit + '/' + r.total + ')');
});

console.log('\nNorth-star roll-ups:');
const results = {};
Object.keys(rollup).forEach(function (name) {
  const list = rollup[name].reduce(function (acc, ax) { return acc.concat(axes[ax] || []); }, []);
  const r = scoreAxis(list);
  results[name] = r;
  console.log('  ' + name.padEnd(16) + bar(r.ratio) + ' ' + pct(r.ratio) + '  (' + r.hit + '/' + r.total + ')');
});

// overall verdict recall = all non-advisory seeds
const overall = scoreAxis(seeds.filter(function (s) { return s.stream !== 'advisory'; }));
console.log('  ' + 'overall'.padEnd(16) + bar(overall.ratio) + ' ' + pct(overall.ratio) + '  (' + overall.hit + '/' + overall.total + ')');

// advisory stream (reported, never gated)
const adv = scoreAxis(advisory);
console.log('\nAdvisory stream (aesthetics — reported, NOT a verdict): ' + adv.hit + '/' + adv.total + ' advised');

// missed detail
const allMissed = seeds.filter(function (s) { return s.stream !== 'advisory' && !recalled(s); });
if (allMissed.length) {
  console.log('\nMissed (false-greens):');
  allMissed.forEach(function (s) { console.log('  - ' + s.id + ' [' + s.axis + '] ' + s.title); });
}

// gate
if (enforceGate) {
  const g = seedsDoc.gate || {};
  const checks = [
    ['functional recall', results.functional.ratio, g.functionalRecallMin],
    ['ux-objective recall', scoreAxis(axes['ux-objective'] || []).ratio, g.uxObjectiveRecallMin],
    ['overall verdict recall', overall.ratio, g.overallVerdictRecallMin]
  ];
  console.log('\n=== ACCEPTANCE GATE ===');
  let pass = true;
  checks.forEach(function (c) {
    if (c[2] == null) return;
    const ok = c[1] >= c[2] - 1e-9;
    pass = pass && ok;
    console.log('  ' + (ok ? 'PASS' : 'FAIL') + '  ' + c[0].padEnd(24) + pct(c[1]) + ' >= ' + pct(c[2]));
  });
  console.log(pass ? '\nGATE: PASS' : '\nGATE: FAIL');
  process.exit(pass ? 0 : 1);
}
