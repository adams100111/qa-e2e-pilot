'use strict';
/*
 * frontier.js — HITL topological round engine (spec §2F / algorithms A5).
 * Dependency-free. Kahn-style waves: the frontier is every decision whose
 * prereqs are all settled and which is not itself settled; everything else
 * with an unmet prereq is deferred. Editing a settled node unsettles its
 * transitive dependents so the frontier recomputes. No I/O, no prompting —
 * confirming-discovered-roles drives the rounds around this pure core.
 */
function nodeMap(tree) {
  const m = {};
  (tree.nodes || []).forEach(function (n) { m[n.id] = n; });
  return m;
}
function computeFrontier(tree, settled) {
  settled = settled || {};
  const settledIds = Object.keys(settled);
  const isSettled = function (id) { return Object.prototype.hasOwnProperty.call(settled, id); };
  const frontier = [], deferred = [];
  (tree.nodes || []).forEach(function (n) {
    if (isSettled(n.id)) return;
    const ready = (n.prereqs || []).every(isSettled);
    if (ready) frontier.push(n.id); else deferred.push(n.id);
  });
  return { frontier: frontier, deferred: deferred, settledIds: settledIds };
}
function recommendedDefault(tree, id) {
  const n = nodeMap(tree)[id];
  return n && Object.prototype.hasOwnProperty.call(n, 'default') ? n.default : null;
}
// direct + transitive dependents of a node id.
function dependentsOf(tree, id) {
  const out = new Set();
  let grew = true;
  const seed = new Set([id]);
  while (grew) {
    grew = false;
    (tree.nodes || []).forEach(function (n) {
      if (out.has(n.id)) return;
      if ((n.prereqs || []).some(function (p) { return seed.has(p) || out.has(p); })) {
        out.add(n.id); grew = true;
      }
    });
  }
  return out;
}
function applyAnswers(tree, settled, answers) {
  const next = Object.assign({}, settled || {});
  Object.keys(answers || {}).forEach(function (id) {
    const edited = Object.prototype.hasOwnProperty.call(next, id) && next[id] !== answers[id];
    next[id] = answers[id];
    if (edited) {
      dependentsOf(tree, id).forEach(function (dep) { delete next[dep]; });
    }
  });
  return next;
}
function budgetExceeded(rounds, budget) { return Number(rounds) > Number(budget); }
module.exports = { computeFrontier: computeFrontier, recommendedDefault: recommendedDefault, applyAnswers: applyAnswers, budgetExceeded: budgetExceeded };
