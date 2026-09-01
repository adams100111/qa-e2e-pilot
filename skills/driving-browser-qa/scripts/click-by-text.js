// Browser-context script: find a clickable element by visible text and resolve
// it to a selector for the caller to act on.
// resolve-only (ADR-0015): returns a selector to click via browser_click; never
// clicks in-evaluate.
// Handles LTR and RTL/Arabic text by stripping Unicode direction marks and
// normalising whitespace before comparison.
// Inject via browser_evaluate.
// Usage: pass labelText (string) and optional containerSelector (CSS string, default: document).
// Returns EITHER:
//   { found: true, selector, tagName, href, role, textContent }
//     -- exactly one visible match; `selector` is a unique CSS selector the
//        caller passes to browser_click. Nothing is clicked here.
//   { found: false, ambiguous: true, count, candidates: [{selector,tagName,href,role,textContent}, ...] }
//     -- MULTIPLE visible elements matched the text; nothing was resolved. The caller must
//        disambiguate (e.g. narrow via containerSelector) and re-invoke rather than guess.
// Throws when NO visible clickable element matches.
(function clickByText(labelText, containerSelector) {
  // Strip Unicode bidi control characters and collapse whitespace.
  function normalise(str) {
    return (str || '')
      .replace(/[​-‏‪-‮⁦-⁩﻿]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // Real visibility test. `offsetParent === null` is NOT a valid proxy for
  // "hidden" — it is also null for `position: fixed` elements even when they
  // are fully visible on screen (a common pattern for modals/toasts/sticky
  // headers), which caused clickByText to silently skip visible, clickable
  // fixed-position controls. Test actual rendered geometry + computed style
  // instead: a non-zero box AND not display:none/visibility:hidden/opacity:0.
  function isVisible(el) {
    var rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    var style = window.getComputedStyle(el);
    if (!style) return true;
    if (style.display === 'none') return false;
    if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    if (parseFloat(style.opacity) === 0) return false;
    return true;
  }

  // Build a unique CSS selector for an element without mutating the DOM.
  // Prefers a stable attribute (data-testid, id) when present; otherwise
  // falls back to a positional path of tag:nth-child from the document root.
  function cssSelector(el) {
    if (el.getAttribute && el.getAttribute('data-testid')) {
      return '[data-testid="' + el.getAttribute('data-testid').replace(/"/g, '\\"') + '"]';
    }
    if (el.id) {
      return '#' + el.id.replace(/([^\w-])/g, '\\$1');
    }
    var path = [];
    var node = el;
    while (node && node.nodeType === 1 && node !== document.documentElement) {
      var selector = node.tagName.toLowerCase();
      var parent = node.parentNode;
      if (parent) {
        var siblings = Array.prototype.filter.call(parent.children, function (sib) {
          return sib.tagName === node.tagName;
        });
        if (siblings.length > 1) {
          selector += ':nth-child(' + (Array.prototype.indexOf.call(parent.children, node) + 1) + ')';
        }
      }
      path.unshift(selector);
      node = parent;
    }
    return path.join(' > ');
  }

  var needle = normalise(labelText);
  var root = containerSelector
    ? document.querySelector(containerSelector)
    : document;

  if (containerSelector && !root) {
    throw new Error('clickByText: container not found for selector: ' + containerSelector);
  }

  // Candidates: interactive elements that carry visible text.
  var candidates = Array.from(
    root.querySelectorAll('button, a, [role="button"], [role="link"], [role="menuitem"], [role="option"]')
  );

  // Collect ALL visible matches instead of stopping at the first — silently
  // resolving "the first match" when several visible elements share the same
  // text (e.g. a "Delete" button repeated per row in a list) risks the caller
  // acting on the wrong control with no signal.
  var matches = [];
  for (var i = 0; i < candidates.length; i++) {
    var el = candidates[i];
    if (!isVisible(el)) continue;
    var text = normalise(el.innerText || el.textContent);
    if (text === needle) {
      matches.push(el);
    }
  }

  if (matches.length === 0) {
    throw new Error(
      'clickByText: no visible clickable element with text "' + labelText + '" found' +
      (containerSelector ? ' inside "' + containerSelector + '"' : '')
    );
  }

  if (matches.length > 1) {
    // Ambiguity signal instead of a silent, potentially-wrong resolution. The
    // caller should narrow with containerSelector (e.g. scope to the active
    // row/dialog) and re-invoke.
    return {
      found: false,
      ambiguous: true,
      count: matches.length,
      candidates: matches.map(function (el) {
        return {
          selector:    cssSelector(el),
          tagName:     el.tagName.toLowerCase(),
          href:        el.href || el.getAttribute('href') || null,
          role:        el.getAttribute('role') || null,
          textContent: normalise(el.innerText || el.textContent)
        };
      })
    };
  }

  var match = matches[0];

  // Return the resolved selector + metadata; the caller clicks it via
  // browser_click (a genuine human-path act), not an in-evaluate .click().
  return {
    found:       true,
    selector:    cssSelector(match),
    tagName:     match.tagName.toLowerCase(),
    href:        match.href || match.getAttribute('href') || null,
    role:        match.getAttribute('role') || null,
    textContent: normalise(match.innerText || match.textContent)
  };
})
