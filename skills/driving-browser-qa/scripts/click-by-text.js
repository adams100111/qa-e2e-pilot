// Browser-context script: find and click a clickable element by visible text.
// Handles LTR and RTL/Arabic text by stripping Unicode direction marks and
// normalising whitespace before comparison.
// Inject via browser_evaluate / browser_run_code_unsafe.
// Usage: pass labelText (string) and optional containerSelector (CSS string, default: document).
// Returns: { found: bool, tagName, href, role, textContent, landed: location.href }
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

  var match = null;
  for (var i = 0; i < candidates.length; i++) {
    var el = candidates[i];
    // Skip hidden elements.
    if (el.offsetParent === null && el.tagName.toLowerCase() !== 'body') continue;
    var text = normalise(el.innerText || el.textContent);
    if (text === needle) {
      match = el;
      break;
    }
  }

  if (!match) {
    throw new Error(
      'clickByText: no visible clickable element with text "' + labelText + '" found' +
      (containerSelector ? ' inside "' + containerSelector + '"' : '')
    );
  }

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
