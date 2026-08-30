#!/usr/bin/env node
/*
 * convert-buglog.js — turns a REAL qa-e2e-pilot run's bug-log.json into a findings file the
 * accuracy scorer (score.js) can consume, matching on STRUCTURED fields (expected/actual/
 * layer/title), never hand-typed keywords.
 *
 * Observed bug-log shapes vary across real runs (see report for the full survey):
 *   - { run_id, entries: [{ bug_id, criterion_id, title, suspected_layer, expected, actual, ... }] }
 *   - { runId, bugs: [...] } (sometimes bugs: [] with the content elsewhere — degrade to no findings)
 *   - a plain array of bug objects, with field names varying by run: id|bug_id, criterion|criterion_id,
 *     suspectedLayer|suspected_layer|layer, actual|observed, root_cause|rootCause, verdict (sometimes
 *     present explicitly, sometimes absent — a logged bug is inherently a "fail" so that's the default).
 *
 * A logged bug-log entry never carries an "axis" field in any observed run; axis is therefore omitted
 * from the produced finding unless the source entry has one (carried through unchanged, never guessed).
 *
 * Downstream: converted findings have no seedId. For a real (non-fixture) run this is expected — a
 * real run's bugs aren't fixture seeds. Attribution to fixture seeds (when scoring against seeds.json)
 * happens later via the judge seam (attribute.js, Task 0.4). This module's only job is faithful
 * text + verdict/suspectedLayer/axis carry-through.
 */
'use strict';

// Alias lists: try each candidate key in order, first non-empty value wins. This is how we
// "degrade gracefully" across the observed field-name variance instead of assuming one schema.
const FIELD_ALIASES = {
  id: ['bug_id', 'id'],
  title: ['title'],
  expected: ['expected'],
  actual: ['actual', 'observed'],
  rootCause: ['root_cause', 'rootCause'],
  impact: ['impact'],
  suspectedLayer: ['suspected_layer', 'suspectedLayer', 'layer'],
  verdict: ['verdict'],
  axis: ['axis']
};

function pick(entry, keys) {
  for (const key of keys) {
    const v = entry[key];
    if (v != null && v !== '') return v;
  }
  return undefined;
}

// Locate the array of bug entries regardless of top-level wrapper shape.
function entriesOf(bugLog) {
  if (Array.isArray(bugLog)) return bugLog;
  if (bugLog && Array.isArray(bugLog.entries)) return bugLog.entries;
  if (bugLog && Array.isArray(bugLog.bugs)) return bugLog.bugs;
  if (bugLog && Array.isArray(bugLog.issues)) return bugLog.issues;
  return [];
}

function sourceOf(bugLog) {
  if (Array.isArray(bugLog)) return 'unknown';
  return (bugLog && (bugLog.run_id || bugLog.runId || bugLog.run)) || 'unknown';
}

// Compose a faithful text from whatever structured fields the entry actually has, so the judge
// (attribute.js) has real expected/actual content to reason over — never a hand-typed keyword.
function composeText(entry) {
  const title = pick(entry, FIELD_ALIASES.title);
  const expected = pick(entry, FIELD_ALIASES.expected);
  const actual = pick(entry, FIELD_ALIASES.actual);
  const rootCause = pick(entry, FIELD_ALIASES.rootCause);
  const impact = pick(entry, FIELD_ALIASES.impact);

  const parts = [];
  if (title) parts.push(title);
  if (expected) parts.push(`Expected: ${expected}`);
  if (actual) parts.push(`Actual: ${actual}`);
  // Only fall back to root-cause/impact when the entry has no expected/actual at all
  // (some observed shapes, e.g. hackathons-fullstack-20260826, carry only root_cause/impact).
  if (!expected && !actual) {
    if (rootCause) parts.push(`Root cause: ${rootCause}`);
    if (impact) parts.push(`Impact: ${impact}`);
  }
  return parts.join(' | ');
}

function convert(bugLog) {
  const entries = entriesOf(bugLog);

  const findings = entries
    .map(entry => {
      const text = composeText(entry);
      if (!text) return null; // nothing structured to compose a faithful finding from — skip

      const finding = {
        verdict: pick(entry, FIELD_ALIASES.verdict) || 'fail', // a logged bug is inherently a fail
        text
      };
      const axis = pick(entry, FIELD_ALIASES.axis);
      if (axis !== undefined) finding.axis = axis;
      const suspectedLayer = pick(entry, FIELD_ALIASES.suspectedLayer);
      if (suspectedLayer !== undefined) finding.suspectedLayer = suspectedLayer;
      return finding;
    })
    .filter(Boolean);

  return { source: sourceOf(bugLog), estimated: false, findings };
}

module.exports = { convert };

// ---------------------------------------------------------------------------
// CLI convenience — only runs when invoked directly, never on require().
//   node convert-buglog.js <bug-log.json> > findings/measured-<run>.json
// ---------------------------------------------------------------------------
if (require.main === module) {
  const fs = require('fs');
  const inputPath = process.argv[2];
  if (!inputPath) {
    console.error('Usage: node convert-buglog.js <bug-log.json>');
    process.exit(1);
  }
  const bugLog = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
  process.stdout.write(JSON.stringify(convert(bugLog), null, 2) + '\n');
}
