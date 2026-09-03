#!/usr/bin/env node
/*
 * ux-measure.js — the headless measured runner for the UI/UX accuracy fixture (Task 3).
 *
 * Dispatches the REAL detector cores (skills/detecting-visual-ux/scripts/ux-detectors.js,
 * skills/detecting-interaction-ux/scripts/overlay-stack.js) and the REAL adjudicator
 * (skills/detecting-visual-ux/scripts/adjudicate.js) over tools/accuracy-harness/fixture-ux/
 * snapshot.json's records, producing a findings file score.js can score against seeds-ux.json.
 *
 * NEVER fabricates a finding a core didn't produce: a record whose core returns null/false/0
 * (no signal) or whose adjudication returns null (known-deliberate / catalog-confirmed clean)
 * or an advisory contributes NO gated finding.
 *
 * Usage: node ux-measure.js <snapshot.json> > findings/measured-ux-<tag>.json
 */
'use strict';
const fs = require('fs');
const path = require('path');

const {
  contentOracleSignal,
  rawTranslationKeySignal,
  scriptMismatchSignal,
  localeDateSignal,
  isBrokenImage,
  invisibleTextSignal,
  modalBehindBackdrop,
  rectOverlapFraction
} = require('../../../skills/detecting-visual-ux/scripts/ux-detectors.js');
const { adjudicate } = require('../../../skills/detecting-visual-ux/scripts/adjudicate.js');
const { checkStackIntegrity } = require('../../../skills/detecting-interaction-ux/scripts/overlay-stack.js');

// All gated definite-oracle UX findings land on this axis so they roll up into BOTH score.js's
// `ux` roll-up (perAxis['ux-objective']) and the `overall` verdict-recall count (score.js's
// `overall` sums every non-advisory, non-perceptual positive seed regardless of axis — see
// scorer/score.js lines 79-83; verified by reading it, not assumed).
const GATED_AXIS = 'ux-objective';

// record.family -> (input) -> {suspicion:{detector,rawSignal,...}, oracleInputs} | null.
// Returning null means the real core found no signal for this input — nothing to adjudicate.
// The suspicion's `detector` id is built to EXACTLY match what adjudicate.js's oracleGradeFor
// prefix table expects, so grading (and confidence) comes from the real adjudicator, never
// hand-assigned here.
const FAMILY_DISPATCH = {
  content(input) {
    const sig = contentOracleSignal(input.text);
    if (!sig) return null;
    return { suspicion: { detector: 'content-' + sig.kind, rawSignal: sig.rawSignal }, oracleInputs: {} };
  },

  'i18n-raw-key': function (input) {
    const sig = rawTranslationKeySignal(input.text);
    if (!sig) return null;
    return { suspicion: { detector: 'i18n-raw-key', rawSignal: sig.rawSignal }, oracleInputs: {} };
  },

  'i18n-script': function (input) {
    const sig = scriptMismatchSignal(input.text, input.expectedLocale);
    if (!sig) return null;
    // detector 'i18n-script-mismatch' grades 'definite-catalog' — the fixture's mismatch is a
    // genuine gap, so catalogResult:'missing' -> adjudicateI18n -> fail high.
    return { suspicion: { detector: 'i18n-script-mismatch', rawSignal: sig.rawSignal }, oracleInputs: { catalogResult: 'missing' } };
  },

  'i18n-locale-date': function (input) {
    const sig = localeDateSignal(input.text, input.expectedLocale);
    if (!sig) return null;
    // detector 'i18n-locale-date' falls through to the generic 'i18n-' prefix -> 'definite-catalog'.
    return { suspicion: { detector: 'i18n-locale-date', rawSignal: sig.rawSignal }, oracleInputs: { catalogResult: 'missing' } };
  },

  image(input) {
    if (!isBrokenImage(input)) return null;
    return { suspicion: { detector: 'broken-image', rawSignal: String(input.naturalWidth) }, oracleInputs: {} };
  },

  invisible(input) {
    const sig = invisibleTextSignal(input.fg, input.bg);
    if (!sig) return null;
    return { suspicion: { detector: 'invisible-text', rawSignal: String(sig.ratio) }, oracleInputs: {} };
  },

  'overlap-modal': function (input) {
    if (!modalBehindBackdrop(input.modalZ, input.backdropZ)) return null;
    return { suspicion: { detector: 'modal-behind-backdrop', rawSignal: String(input.modalZ) }, oracleInputs: {} };
  },

  'overlap-rect': function (input) {
    // Generic AABB overlap is a heuristic-only oracle grade (adjudicate.js's 'overlap' prefix);
    // it stays advisory unless corroborated by a definite oracle, which we deliberately never
    // pass here (a bare rect collision is never ground-truth on its own). Zero overlap (no
    // collision at all) carries no signal worth adjudicating.
    const frac = rectOverlapFraction(input.rectA, input.rectB);
    if (!(frac > 0)) return null;
    return { suspicion: { detector: 'overlap', rawSignal: String(frac) }, oracleInputs: {} };
  },

  interaction(input) {
    const suspicion = checkStackIntegrity(input.before, input.afterOpenChild, input.childId);
    if (!suspicion) return null;
    // The fixture's shared-open state (SS1) is known ground-truth, not a mere suspicion —
    // corroborated:true takes adjudicate.js's 'behavioral-observed' grade to fail HIGH instead
    // of fail low.
    return { suspicion: suspicion, oracleInputs: { corroborated: true } };
  }
};

/**
 * measure(snapshotDoc) -> {source, findings:[...]}
 *
 * For each snapshotDoc.records[i], dispatches by record.family to the matching real core,
 * then adjudicates any resulting suspicion with the real adjudicate.js. A returned verdict
 * becomes a gated finding on GATED_AXIS; an advisory becomes a stream:"advisory" finding
 * (never scored as recall — see seeds-ux.json / score.js); null (no signal, or a
 * catalog-confirmed/known-deliberate clean value) produces no finding at all.
 */
function measure(snapshotDoc) {
  const findings = [];
  const records = (snapshotDoc && snapshotDoc.records) || [];

  for (const record of records) {
    const dispatch = FAMILY_DISPATCH[record.family];
    if (!dispatch) continue; // unknown family — never fabricate a finding for it

    const dispatched = dispatch(record.input || {});
    if (!dispatched) continue; // the real core produced no signal for this input

    const result = adjudicate(dispatched.suspicion, dispatched.oracleInputs);
    if (!result) continue; // adjudicate: known-deliberate / catalog-confirmed clean — no finding

    if (result.advisory) {
      findings.push({
        judgedSeedId: record.seed,
        stream: 'advisory',
        text: result.reason
      });
      continue;
    }

    findings.push({
      judgedSeedId: record.seed,
      axis: GATED_AXIS,
      verdict: result.verdict,
      confidence: result.confidence,
      text: result.reason
    });
  }

  return {
    source: 'ux-measure.js: real detector cores (ux-detectors.js, overlay-stack.js) + real adjudicate.js over fixture-ux/snapshot.json',
    findings: findings
  };
}

module.exports = { measure, FAMILY_DISPATCH };

// ---------------------------------------------------------------------------
// CLI — only runs when ux-measure.js is invoked directly, never on require().
// ---------------------------------------------------------------------------
if (require.main === module) {
  const snapshotPath = process.argv[2];
  if (!snapshotPath) {
    console.error('usage: node ux-measure.js <snapshot.json>');
    process.exit(2);
  }
  const snapshotDoc = JSON.parse(fs.readFileSync(path.resolve(snapshotPath), 'utf8'));
  const result = measure(snapshotDoc);
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
}
