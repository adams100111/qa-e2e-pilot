#!/usr/bin/env node
/*
 * pass-gate.js — SUPERSEDED prototype. Kept for reference only; not wired into the pipeline.
 *
 * The REAL evidence gate (ADR-0010) lives in
 * `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (`cmd_upsert` / `gate_pass`), enforced
 * inside the single chokepoint every verdict flows through, paired with
 * `skills/checkpointing-qa-memory/scripts/record-evidence.sh` as the evidence writer. That shipped
 * gate differs from this file in every load-bearing way:
 *   - field names are **snake_case** (`evidence_refs`, `kinds`), not the camelCase
 *     (`evidenceRefs`, `kinds`, `probeNeeded`) used below;
 *   - `kinds` is a CSV subset of `bake|computed|probe` (see `generating-qa-checklist/SKILL.md`'s
 *     `Kind`+`Tags` derivation table), not the ad-hoc `write`/`computed` values this prototype checks;
 *   - the shipped gate is **content-aware**: it requires each kind's canonical artifact
 *     (`evidence/<crit>/{bake-read-back,recompute,network-response}.json`) to exist, be non-empty,
 *     parse as valid JSON, AND contain that kind's required keys — a mere filename match (what this
 *     prototype's regexes do, below) is NOT sufficient there; an empty or touch-created artifact file
 *     is correctly rejected by checkpoint.sh but would pass this prototype's `rx.test(refs)` check
 *     since it only tests the joined evidenceRefs STRING, never opens the files;
 *   - the shipped gate rejects with a stderr message and writes nothing; it does not "downgrade" a
 *     verdict (no code path silently rewrites `pass` to `blocked`) — the comment further down in this
 *     file describing a downgrade is aspirational/inaccurate relative to what shipped.
 * This file originally proposed the seam (plan §fix-3a); the shipped design in checkpoint.sh is the
 * one in force. It is left here, unmodified in shape, as the original standalone spec/reference —
 * do not import it, do not treat its schema as current. See ADR-0010 for the full rationale.
 *
 * ---- Original prototype doc (historical, schema below does NOT match the shipped gate) ----
 *
 * Invariant enforced: "a green toast is not a pass" becomes machine-checkable. A `pass` verdict is
 * INVALID unless the criterion recorded the evidence classes its kind requires:
 *   - any write criterion        -> a bake read-back artifact (evidence/<id>/bake-read-back.json)
 *   - any computed-logic criterion -> an independent recompute artifact (evidence/<id>/recompute.md)
 *   - a probe was needed          -> a network/probe artifact (evidence/<id>/network-response.json)
 * Missing evidence => the pass is downgraded to `blocked` (env/precondition) or flagged INVALID for
 * the agent to fix, never silently accepted. blocked/deferred/error/fail are exempt (they are honest
 * non-passes). This is the seam the plan proposed wiring into checkpoint.sh; checkpoint.sh's actual
 * implementation supersedes this file (see header above) — this standalone node script is the
 * original proof that the seam works, kept for reference only.
 *
 * Usage:
 *   node pass-gate.js <criterion.json>
 * criterion.json: { "id":"GOV-01", "verdict":"pass", "kinds":["write","computed"],
 *                   "probeNeeded": false,
 *                   "evidenceRefs":["evidence/GOV-01/bake-read-back.json", ...] }
 * exit 0 = valid pass (or non-pass verdict); exit 1 = INVALID pass (evidence missing).
 * NOTE: this checks filename patterns against the joined evidenceRefs list only — it never opens or
 * validates the referenced files. The shipped gate in checkpoint.sh checks file content; this does not.
 */
'use strict';
const fs = require('fs');

const p = process.argv[2];
if (!p) { console.error('usage: node pass-gate.js <criterion.json>'); process.exit(2); }
const c = JSON.parse(fs.readFileSync(p, 'utf8'));

if (c.verdict !== 'pass') {
  console.log('OK  ' + c.id + ' verdict=' + c.verdict + ' (only pass is gated)');
  process.exit(0);
}

const refs = (c.evidenceRefs || []).join('\n');
const kinds = c.kinds || [];
const required = [];
if (kinds.indexOf('write') >= 0) required.push({ what: 'bake read-back', rx: /bake-read-back\.json/ });
if (kinds.indexOf('computed') >= 0) required.push({ what: 'independent recompute', rx: /recompute\.(md|json)/ });
if (c.probeNeeded) required.push({ what: 'probe/network body', rx: /network-response\.json/ });

const missing = required.filter(function (r) { return !r.rx.test(refs); });

if (missing.length === 0) {
  console.log('OK  ' + c.id + ' pass is valid (' + required.map(function (r) { return r.what; }).join(', ') + ' present)');
  process.exit(0);
}
console.log('INVALID PASS  ' + c.id + ' — a pass requires evidence: ' + missing.map(function (m) { return m.what; }).join(', '));
console.log('  => downgrade to blocked (precondition/evidence missing) or supply the evidence. "A green toast is not a pass."');
process.exit(1);
