const { test } = require('node:test');
const assert = require('node:assert');
const { convert } = require('../convert-buglog.js');

// Real shape observed in /home/dev/projects/innovation/.qa/runs/hackathons-roles-2026-07-03/bug-log.json
// { run_id, entries: [{ bug_id, criterion_id, title, severity, suspected_layer, steps, expected, actual,
//   expected_vs_actual_evidence, evidence_refs, fix, logged_at }] } — no per-entry "verdict" field
// (bug-log entries are inherently failures; every logged bug is a fail).
const canonicalBugLog = {
  run_id: 'hackathons-roles-2026-07-03',
  entries: [
    {
      bug_id: 'BUG-001',
      criterion_id: 'C3/C4/C5',
      title: 'Team workspace page returns HTTP 500 for every role',
      severity: 'critical',
      suspected_layer: 'service',
      steps: ['Log in as leader@hack.test.', 'Navigate to /hackathons/6/team.'],
      expected: 'The Team workspace page renders (team roster, task board, submission form).',
      actual: "Error: Call to a member function first() on null in HackathonResource::toArray().",
      evidence_refs: ['.playwright-mcp/page-2026-07-03T04-54-04-499Z.yml'],
      fix: null,
      logged_at: '2026-07-03T04:54:10Z'
    }
  ]
};

test('canonical shape: doc is estimated:false with source from run_id', () => {
  const out = convert(canonicalBugLog);
  assert.equal(out.estimated, false);
  assert.equal(out.source, 'hackathons-roles-2026-07-03');
  assert.equal(out.findings.length, 1);
});

test('canonical shape: composed text carries expected + actual content for judge attribution', () => {
  const out = convert(canonicalBugLog);
  const text = out.findings[0].text;
  assert.match(text, /Team workspace page returns HTTP 500/);
  assert.match(text, /Team workspace page renders/); // from expected
  assert.match(text, /first\(\) on null/); // from actual
});

test('canonical shape: suspectedLayer carried through unchanged; verdict defaults to fail', () => {
  const out = convert(canonicalBugLog);
  assert.equal(out.findings[0].suspectedLayer, 'service');
  assert.equal(out.findings[0].verdict, 'fail');
});

// A second observed shape: plain array of bug objects with an explicit verdict field
// (from a different run) — verify graceful handling / carry-through instead of assuming shape.
const arrayBugLog = [
  {
    id: 'BUG-1',
    severity: 'high',
    criterion: 'C3 (in-flight dedup)',
    verdict: 'fail',
    confidence: 'high',
    suspectedLayer: 'service',
    title: 'Rapid double-submit creates two rows',
    expected: 'The second request should see the first as in-flight.',
    observed: 'Both POSTs returned 201, both jobs ran independently.'
  }
];

test('array shape with explicit verdict: verdict carried through unchanged, axis omitted when absent', () => {
  const out = convert(arrayBugLog);
  assert.equal(out.estimated, false);
  assert.equal(out.findings[0].verdict, 'fail');
  assert.equal('axis' in out.findings[0], false);
  assert.match(out.findings[0].text, /Rapid double-submit/);
});

test('unknown/empty shape degrades gracefully to zero findings, never throws', () => {
  const out = convert({ runId: 'evaluations-management-20260822', bugs: [], note: 'no bugs found' });
  assert.equal(out.estimated, false);
  assert.deepEqual(out.findings, []);
});
