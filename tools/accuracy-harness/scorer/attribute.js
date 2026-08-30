/*
 * Judge-attribution seam: injected judge decides if a finding asserts a seed's actual defect.
 *
 * Production judgeFn contract: single model call per finding with candidate seeds.
 * Prompt: "Does this finding assert THIS seed's actual defect (not a keyword coincidence)? Answer the seedId or null."
 *
 * Reimplements interrogate's "confidence from an independent judge" pattern (ADR-0001, no dependency).
 */
'use strict';
function candidates(finding, seeds) {
  const t = (finding.text || finding.message || '').toLowerCase();
  return seeds.filter(s => (s.match || []).some(kw => t.indexOf(kw.toLowerCase()) >= 0));
}
function attribute(findings, seeds, judgeFn) {
  return findings.map(f => {
    if (f.seedId || f.judgedSeedId) return f;           // already attributed
    const cand = candidates(f, seeds);
    if (cand.length === 0) return f;                    // no hint → no judge call
    const chosen = judgeFn({ finding: f, candidateSeeds: cand });
    return chosen ? { ...f, judgedSeedId: chosen } : f;
  });
}
module.exports = { attribute, candidates };
