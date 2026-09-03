// overlay-stack.js — the interaction/behavioral UX family (family 9, ADR-0019 sub-plan B).
// Dual-mode like ux-detectors.js: browser DETECT extracts the overlay stack; pure cores
// check the five behavioral invariants against before/after snapshots and emit suspicions
// (adjudicated by detecting-visual-ux/scripts/adjudicate.js's `behavioral-observed` grade).
// A SUSPICION carries no verdict/confidence — the classifier assigns those. NO I/O.
(function () {
  'use strict';

  function overlaySuspicion(detector, descriptor, evidence, rawSignal) {
    return {
      detector: detector,
      axis: 'ux-suspicion',
      overlayId: descriptor ? descriptor.id : null,
      role: descriptor ? descriptor.role : null,
      evidence: evidence,
      rawSignal: rawSignal
    };
  }

  function byId(stack, id) {
    for (var i = 0; i < stack.length; i++) { if (stack[i].id === id && stack[i].present !== false) return stack[i]; }
    return null;
  }
  function present(stack) { var out = []; for (var i = 0; i < stack.length; i++) { if (stack[i].present !== false) out.push(stack[i]); } return out; }
  function topmost(stack) {
    var p = present(stack), best = null;
    for (var i = 0; i < p.length; i++) { if (best === null || (p[i].zIndex || 0) >= (best.zIndex || 0)) best = p[i]; }
    return best;
  }

  // Invariant 1: opening `childId` must NOT remove an overlay that was present before.
  function checkStackIntegrity(before, afterOpenChild, childId) {
    if (!byId(afterOpenChild, childId)) return null; // child didn't actually open — not this invariant's call
    var b = present(before);
    for (var i = 0; i < b.length; i++) {
      var parent = b[i];
      if (parent.id === childId) continue;
      if (!byId(afterOpenChild, parent.id)) {
        return overlaySuspicion('interaction-overlay-destroyed', parent,
          'overlay "' + parent.id + '" was present before opening "' + childId + '" but is gone after — child destroyed parent instead of stacking',
          parent.id + ' -> (destroyed by ' + childId + ')');
      }
    }
    return null;
  }

  // Invariant 2: after an action completes, the expected parent/base must be present.
  function checkReturnToContext(afterAction, expectedParentId) {
    if (byId(afterAction, expectedParentId)) return null;
    return overlaySuspicion('interaction-no-return', { id: expectedParentId, role: null },
      'after the action, expected context "' + expectedParentId + '" is not present — no return-to-context',
      'missing-return:' + expectedParentId);
  }

  // Invariant 3: after closing the child, the surface must not be an empty dead-end.
  function checkNoDeadEnd(afterClose) {
    if (present(afterClose).length > 0) return null;
    return overlaySuspicion('interaction-dead-end', { id: null, role: null },
      'after closing the child overlay, no overlay or base context is present — dead-end',
      'dead-end:empty-stack');
  }

  // Invariant 4: the topmost aria-modal overlay must be focus-trapped.
  function checkFocusTrap(stack) {
    var top = topmost(stack);
    if (!top || !top.ariaModal) return null;
    if (top.focusTrapped) return null;
    return overlaySuspicion('interaction-focus-untrapped', top,
      'topmost modal "' + top.id + '" is not focus-trapped — focus can escape behind the overlay',
      'focus-untrapped:' + top.id);
  }

  // Invariant 5: opening the child must not remove a NON-parent sibling overlay.
  function checkNoDestructiveOnOpen(before, afterOpenChild) {
    var afterIds = {}; var pa = present(afterOpenChild);
    for (var i = 0; i < pa.length; i++) afterIds[pa[i].id] = true;
    // the parent is whichever before-overlay the new child declares as parentId
    var childParent = null;
    for (var j = 0; j < pa.length; j++) { if (pa[j].parentId) { childParent = pa[j].parentId; break; } }
    var b = present(before);
    for (var k = 0; k < b.length; k++) {
      var o = b[k];
      if (o.id === childParent) continue;       // the parent legitimately may be covered, not this invariant
      if (!afterIds[o.id]) {
        return overlaySuspicion('interaction-destructive-on-open', o,
          'sibling overlay "' + o.id + '" (not the opener parent) disappeared when the child opened — destructive side effect',
          'destroyed-sibling:' + o.id);
      }
    }
    return null;
  }

  // Browser-only: extract the current overlay stack from the live DOM/accessibility tree.
  // Overlay = [role=dialog] / [aria-modal=true] / a position:fixed|absolute panel with a
  // high z-index. focusTrapped ~ the overlay contains the active element AND declares
  // aria-modal or a focus-trap sentinel. May MISS non-semantic overlays (plain divs) —
  // those fall through to the generative critic (layer 3, deferred sub-plan C).
  function extractOverlayStack() {
    var out = [];
    if (typeof document === 'undefined') return out;
    var nodes = document.querySelectorAll('[role="dialog"],[aria-modal="true"],.modal,.dialog,.sheet,.drawer,[data-overlay]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var cs = (typeof getComputedStyle !== 'undefined') ? getComputedStyle(el) : {};
      var role = el.getAttribute('role') || 'dialog';
      var name = el.getAttribute('aria-label') || (el.textContent || '').trim().slice(0, 40);
      var z = parseInt((cs && cs.zIndex) || '0', 10); if (!Number.isFinite(z)) z = 0;
      var active = document.activeElement;
      out.push({
        id: role + ':' + name,
        role: role,
        ariaModal: el.getAttribute('aria-modal') === 'true',
        zIndex: z,
        position: (cs && cs.position) || 'static',
        focusTrapped: !!(active && el.contains(active)) && (el.getAttribute('aria-modal') === 'true'),
        parentId: null, // set by the agent across the drive (the opener), not inferable from one snapshot
        present: true
      });
    }
    return out;
  }

  var api = {
    overlaySuspicion: overlaySuspicion,
    checkStackIntegrity: checkStackIntegrity,
    checkReturnToContext: checkReturnToContext,
    checkNoDeadEnd: checkNoDeadEnd,
    checkFocusTrap: checkFocusTrap,
    checkNoDestructiveOnOpen: checkNoDestructiveOnOpen,
    extractOverlayStack: extractOverlayStack
  };
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
  else if (typeof window !== 'undefined') { window.__overlayStack = api; }
})();
