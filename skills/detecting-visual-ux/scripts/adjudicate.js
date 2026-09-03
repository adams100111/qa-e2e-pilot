// adjudicate.js — pure UX-suspicion classifier (spec §2–§4, ADR-0019).
// Dual-mode like ux-detectors.js: exports pure functions for Node tests / the
// agent's adjudication step. NO DOM, NO I/O. The oracle is the spec/domain rule,
// never the implementation itself — "in the catalog" is only a deliberateness
// heuristic, so a catalog-present Latin value never self-certifies (spec §4.2, Q1).
(function () {
  'use strict';

  // detector-prefix -> oracle grade. Longest-prefix wins so specific detector
  // ids override family defaults. Editing THIS table changes classification —
  // it is the single source the doctrine (references/adjudication.md) documents.
  var ORACLE_GRADES = [
    // definite DOM oracle: the DOM itself is the evidence; needs no source; -> high.
    ['content-', 'definite-dom'],
    ['i18n-raw-key', 'definite-dom'],
    ['broken-image', 'definite-dom'],
    ['invisible-text', 'definite-dom'],       // fg≈bg: unreadable, unambiguous (grill Q3)
    ['modal-behind-backdrop', 'definite-dom'],// z-inversion of a modal vs its own backdrop (grill Q4)
    // definite but catalog-dependent: verdict only once the catalog oracle resolves.
    ['i18n-script-mismatch', 'definite-catalog'],
    ['i18n-', 'definite-catalog'],
    // standards threshold (WCAG): a real verdict but confidence low (no spec oracle).
    ['contrast', 'standards'],
    ['target-size', 'standards'],
    // behavioral invariant violation, observed directly (overlay-stack, Task 1): a real
    // verdict, not advisory — confidence low until the shared state cause is code-localized.
    ['interaction-', 'behavioral-observed'],
    // everything else (generic overlap, layout heuristics): advisory unless corroborated.
    ['overlap', 'heuristic']
  ];

  function oracleGradeFor(detector) {
    var best = null, bestLen = -1;
    for (var i = 0; i < ORACLE_GRADES.length; i++) {
      var pfx = ORACLE_GRADES[i][0];
      if (detector.indexOf(pfx) === 0 && pfx.length > bestLen) { best = ORACLE_GRADES[i][1]; bestLen = pfx.length; }
    }
    return best || 'heuristic';
  }

  var SEP = '␟'; // symbol-for-unit-separator: never appears in a detector id or rawSignal
  function deliberateKey(s) { return String(s.detector) + SEP + String(s.rawSignal == null ? '' : s.rawSignal); }
  function isKnownDeliberate(s, knownDeliberate) {
    if (!knownDeliberate || !knownDeliberate.length) return false;
    var k = deliberateKey(s);
    for (var i = 0; i < knownDeliberate.length; i++) { if (deliberateKey(knownDeliberate[i]) === k) return true; }
    return false;
  }

  function failHigh(family, reason) { return { verdict: 'fail', suspectedLayer: 'FE', confidence: 'high', family: family, reason: reason }; }
  function failLow(family, reason)  { return { verdict: 'fail', suspectedLayer: 'FE', confidence: 'low',  family: family, reason: reason }; }
  function advisory(reason)         { return { advisory: true, reason: reason }; }

  // Catalog adjudication for the i18n script-mismatch / raw-key-with-catalog path
  // (spec §4.2 table). catalogResult is one of:
  //   'missing'              key absent in target locale        -> definite gap  -> fail high
  //   'empty'                key present but empty in target     -> definite gap  -> fail high
  //   'present-latin-legit'  Latin value that is a proper-noun/brand/URL/code    -> deliberate -> null
  //   'present-latin-eq-en'  Latin value == the en string, reads as prose -> suspected untranslated
  //   'present-translated'   correctly localized                 -> pass (no finding) -> null
  //   'no-catalog'           black-box / no catalog located      -> observed-only -> advisory
  // catalogCompleteness (0..1): fraction of target-locale keys that are translated.
  // A suspected-untranslated string is a VERDICT only where the app's convention is
  // full-translation, derived autonomously from an otherwise-complete catalog (grill Q7).
  function adjudicateI18n(catalogResult, catalogCompleteness) {
    switch (catalogResult) {
      case 'missing':
      case 'empty':
        return failHigh('i18n', 'i18n key ' + catalogResult + ' in the target locale catalog (definite gap)');
      case 'present-latin-legit':
      case 'present-translated':
        return null; // deliberate / correct — no finding
      case 'present-latin-eq-en':
        if (typeof catalogCompleteness === 'number' && catalogCompleteness >= 0.9) {
          return failHigh('i18n', 'untranslated fallback: target value equals the en string in an otherwise-complete catalog (convention = full-translation)');
        }
        return advisory('suspected untranslated: target value is Latin and equals en, but the catalog is only partly translated — advisory, not a verdict');
      case 'no-catalog':
      default:
        return advisory('script-mismatch observed but no catalog to adjudicate against (black-box) — advisory');
    }
  }

  // A Latin-script test that mirrors ux-detectors.js's script reflex: true when the
  // string contains at least one A–Z/a–z run and no non-Latin letter script.
  function isLatinProse(s) {
    if (!s) return false;
    if (!/[A-Za-z]/.test(s)) return false;
    // any letter from a major non-Latin script -> not "Latin prose"
    return !/[؀-ۿЀ-ӿ一-鿿぀-ヿ가-힯]/.test(s);
  }

  function deriveCatalogResult(entry) {
    if (!entry) return 'no-catalog';
    if (!entry.presentInTarget) return 'missing';
    var tv = entry.targetValue;
    if (tv == null || String(tv).trim() === '') return 'empty';
    if (entry.isTechnical) return 'present-latin-legit';
    // Latin value equal to en, reading as prose -> suspected untranslated fallback.
    if (isLatinProse(tv) && entry.enValue != null && String(tv).trim() === String(entry.enValue).trim()) return 'present-latin-eq-en';
    // Latin but a legitimately different value (localized to another Latin language), or non-Latin script -> translated.
    return 'present-translated';
  }

  // The classifier. Returns a verdict object, an advisory object, or null (dropped:
  // known-deliberate, or a catalog-confirmed deliberate/correct value).
  function adjudicate(suspicion, oracleInputs) {
    oracleInputs = oracleInputs || {};
    if (isKnownDeliberate(suspicion, oracleInputs.knownDeliberate)) return null; // agent already judged this intentional (spec §6)
    var grade = oracleGradeFor(suspicion.detector);
    switch (grade) {
      case 'definite-dom':
        // DOM/screenshot IS the evidence — full confidence even black-box (spec §2 degrade ¶).
        return failHigh(suspicion.detector.split('-')[0] === 'i18n' ? 'i18n' : 'content-or-visual',
          'definite DOM oracle: ' + suspicion.detector + ' (' + suspicion.rawSignal + ')');
      case 'definite-catalog':
        return adjudicateI18n(oracleInputs.catalogResult, oracleInputs.catalogCompleteness);
      case 'standards':
        return failLow('standards', 'standards-threshold oracle (WCAG): ' + suspicion.detector);
      case 'behavioral-observed':
        // An observed overlay-stack invariant violation IS a fail (the destruction is
        // objectively observed), but confidence is low until the shared open/route state
        // both overlays bind to is localized in code (spec §7). Distinct from 'heuristic'
        // (a mere suspicion → advisory): this is a real observed defect.
        return oracleInputs.corroborated
          ? failHigh('interaction', 'observed overlay-stack invariant violation, shared-state cause localized in code: ' + suspicion.detector)
          : failLow('interaction', 'observed overlay-stack invariant violation (' + suspicion.detector + ') — confidence low until the shared open/route state is localized in code');
      case 'heuristic':
      default:
        // Heuristic-only: advisory UNLESS a definite oracle corroborated it (spec §2).
        if (oracleInputs.corroborated) return failHigh('heuristic-corroborated', 'heuristic suspicion corroborated by a definite oracle: ' + suspicion.detector);
        return advisory('heuristic-only suspicion (' + suspicion.detector + ') — advisory unless a definite oracle corroborates');
    }
  }

  var api = { ORACLE_GRADES: ORACLE_GRADES, oracleGradeFor: oracleGradeFor, deliberateKey: deliberateKey, isKnownDeliberate: isKnownDeliberate, adjudicateI18n: adjudicateI18n, adjudicate: adjudicate, isLatinProse: isLatinProse, deriveCatalogResult: deriveCatalogResult };
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
  else if (typeof window !== 'undefined') { window.__adjudicate = api; }
})();
