// Browser-context script: find and click a clickable element by visible text.
// Handles LTR and RTL/Arabic text by stripping Unicode direction marks and
// normalising whitespace before comparison.
// Inject via browser_evaluate / browser_run_code_unsafe.
// Usage: pass labelText (string) and optional containerSelector (CSS string, default: document).
// Returns EITHER:
//   { found: true, tagName, href, role, textContent, landed: location.href }   -- exactly one match, clicked
//   { found: false, ambiguous: true, count, candidates: [{tagName,href,role,textContent}, ...] }
//     -- MULTIPLE visible elements matched the text; nothing was clicked. The caller must
//        disambiguate (e.g. narrow via containerSelector) and re-invoke rather than guess.
// Throws when NO visible clickable element matches.
// NOTE: navigation happens synchronously; `landed` is the URL *after* the click
//       only if the page did not navigate (same-page). For cross-page navigation
//       read location.href in a subsequent evaluate call.
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
  // clicking "the first match" when several visible elements share the same
  // text (e.g. a "Delete" button repeated per row in a list) risks acting on
  // the wrong control with no signal to the caller.
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
    // Ambiguity signal instead of a silent, potentially-wrong click. The
    // caller should narrow with containerSelector (e.g. scope to the active
    // row/dialog) and re-invoke.
    return {
      found: false,
      ambiguous: true,
      count: matches.length,
      candidates: matches.map(function (el) {
        return {
          tagName: el.tagName.toLowerCase(),
          href: el.href || el.getAttribute('href') || null,
          role: el.getAttribute('role') || null,
          textContent: normalise(el.innerText || el.textContent)
        };
      })
    };
  }

  var match = matches[0];

  // Capture metadata BEFORE the click so the caller can verify intent.
  var result = {
    found:       true,
    tagName:     match.tagName.toLowerCase(),
    href:        match.href || match.getAttribute('href') || null,
    role:        match.getAttribute('role') || null,
    textContent: normalise(match.innerText || match.textContent),
    landed:      null
  };

  match.click();

  // If we're still on the same page (no navigation), capture the current URL.
  result.landed = window.location.href;
  return result;
})
