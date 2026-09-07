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
  // The base-context descriptor (baseContext: true, appended by extractOverlayStack) exists
  // ONLY for checkNoDeadEnd's clean-close-vs-true-dead-end distinction. Every other invariant
  // checker must never see it: it isn't a real overlay, has no z-index/focus semantics, and
  // must never win a topmost()/byId() comparison or be treated as a "sibling"/"parent" overlay.
  // All four checkers below filter it out first via overlaysOnly().
  function overlaysOnly(stack) {
    var out = []; for (var i = 0; i < stack.length; i++) { if (!stack[i].baseContext) out.push(stack[i]); } return out;
  }
  function topmost(stack) {
    var p = present(stack), best = null;
    for (var i = 0; i < p.length; i++) { if (best === null || (p[i].zIndex || 0) >= (best.zIndex || 0)) best = p[i]; }
    return best;
  }

  // Invariant 1: opening `childId` must NOT remove an overlay that was present before.
  function checkStackIntegrity(before, afterOpenChild, childId) {
    before = overlaysOnly(before); afterOpenChild = overlaysOnly(afterOpenChild);
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
    afterAction = overlaysOnly(afterAction);
    if (byId(afterAction, expectedParentId)) return null;
    return overlaySuspicion('interaction-no-return', { id: expectedParentId, role: null },
      'after the action, expected context "' + expectedParentId + '" is not present — no return-to-context',
      'missing-return:' + expectedParentId);
  }

  // Invariant 3: after closing the child, the surface must not be an empty dead-end.
  // extractOverlayStack() appends a base-context descriptor (baseContext: true, see below) to
  // every captured stack. This is the ONE checker that deliberately looks at it (every other
  // invariant checker strips it via overlaysOnly() and never sees it). An empty OVERLAY stack
  // alone is not proof of a dead-end — a correctly, fully-closed flow leaves a healthy base page
  // underneath. Suspicion only stands when the overlay stack is empty AND that base context is
  // also missing/inert. Fixtures captured before this descriptor existed (plain overlay arrays
  // with no baseContext entry at all) still resolve correctly: no base entry found == base
  // absent == dead-end when the overlay stack is also empty, matching the prior behavior.
  function checkNoDeadEnd(afterClose) {
    var overlays = present(overlaysOnly(afterClose));
    if (overlays.length > 0) return null;
    var base = null;
    for (var i = 0; i < afterClose.length; i++) {
      if (afterClose[i] && afterClose[i].baseContext) { base = afterClose[i]; break; }
    }
    if (base && base.present !== false) return null; // healthy base context -> clean close, not a dead-end
    return overlaySuspicion('interaction-dead-end', { id: null, role: null },
      'after closing the child overlay, no overlay is present and the base context is missing or inert — dead-end',
      'dead-end:empty-stack');
  }

  // Invariant 4: the topmost aria-modal overlay must be focus-trapped.
  function checkFocusTrap(stack) {
    var top = topmost(overlaysOnly(stack));
    if (!top || !top.ariaModal) return null;
    if (top.focusTrapped) return null;
    return overlaySuspicion('interaction-focus-untrapped', top,
      'topmost modal "' + top.id + '" is not focus-trapped — focus can escape behind the overlay',
      'focus-untrapped:' + top.id);
  }

  // Invariant 5: opening the child must not remove a NON-parent sibling overlay.
  function checkNoDestructiveOnOpen(before, afterOpenChild) {
    before = overlaysOnly(before); afterOpenChild = overlaysOnly(afterOpenChild);
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

  // Browser-only: assess whether the underlying base page (what's left once every overlay
  // closes) is itself present and healthy. Used only by checkNoDeadEnd to tell "all overlays
  // correctly closed, healthy base page" apart from a true dead-end (blank/inert surface).
  // Healthy = the <main> landmark (preferred) or <body> (fallback) is not
  // display:none/visibility:hidden, has layout size, and is not empty of content.
  //
  // KNOWN BLIND SPOT: when there is no <main> landmark, this falls back to <body> — and body
  // can stay "present" (nav/footer chrome still mounted) even when the actual content viewport
  // underneath a closed overlay is blank, i.e. a real dead-end. We mitigate, but do not
  // eliminate, this by requiring MORE than trivial chrome in the body-fallback path (multiple
  // element children AND non-trivial text, not just "something exists" — a lone nav bar with a
  // couple of links should not count as healthy). Apps without a <main> landmark therefore get a
  // weaker dead-end check than apps that have one; state this limitation in the report exactly
  // as the non-semantic-overlay coverage limit is already stated (SKILL.md Step 5).
  function extractBaseContext() {
    var descriptor = { id: '__base-context__', role: 'base-context', baseContext: true, present: false };
    if (typeof document === 'undefined' || !document.body) return descriptor;
    var main = document.querySelector('main,[role="main"]');
    var target = main || document.body;
    var cs = (typeof getComputedStyle !== 'undefined') ? getComputedStyle(target) : {};
    var hidden = !!(cs && (cs.display === 'none' || cs.visibility === 'hidden'));
    var hasSize = true;
    if (typeof target.getBoundingClientRect === 'function') {
      var rect = target.getBoundingClientRect();
      hasSize = !!(rect && (rect.width > 0 || rect.height > 0));
    }
    var childCount = (target.children && target.children.length) || 0;
    var textLen = (target.textContent || '').trim().length;
    var hasContent = main
      ? (childCount > 0 || textLen > 0)
      : (childCount > 1 && textLen > 40); // stricter bar for the body-fallback blind spot above
    descriptor.present = !hidden && hasSize && hasContent;
    return descriptor;
  }

  // Browser-only: extract the current overlay stack from the live DOM/accessibility tree.
  // Overlay = [role=dialog] / [aria-modal=true] / a position:fixed|absolute panel with a
  // high z-index. focusTrapped ~ the overlay contains the active element AND declares
  // aria-modal or a focus-trap sentinel. May MISS non-semantic overlays (plain divs) —
  // those fall through to the generative critic (layer 3, deferred sub-plan C).
  // The returned array ends with a base-context descriptor (extractBaseContext(), marked
  // baseContext: true) so checkNoDeadEnd can tell a clean close from a true dead-end — the
  // other four invariant checks strip it via overlaysOnly() before doing anything else, so it
  // can never be mistaken for a real overlay (e.g. topmost()-by-z-index in checkFocusTrap).
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
    out.push(extractBaseContext());
    return out;
  }

  var api = {
    overlaySuspicion: overlaySuspicion,
    checkStackIntegrity: checkStackIntegrity,
    checkReturnToContext: checkReturnToContext,
    checkNoDeadEnd: checkNoDeadEnd,
    checkFocusTrap: checkFocusTrap,
    checkNoDestructiveOnOpen: checkNoDestructiveOnOpen,
    extractOverlayStack: extractOverlayStack,
    extractBaseContext: extractBaseContext
  };
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
  else if (typeof window !== 'undefined') { window.__overlayStack = api; }
})();
