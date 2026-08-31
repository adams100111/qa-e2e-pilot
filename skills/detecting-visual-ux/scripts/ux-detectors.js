/*
 * ux-detectors.js — dependency-free, in-page OBJECTIVE visual-UX detectors.
 *
 * Injected via the `evaluate` capability (Playwright MCP `browser_evaluate`) — NEVER
 * `browser_run_code_unsafe`. Runs read-only against the single rendered page: no golden
 * baseline, no axe-core, no npm dependency. Returns a JSON-serializable array of findings.
 *
 * Adapted from tools/accuracy-harness/detectors/ux-detectors.js for skills/detecting-visual-ux
 * (Phase 3, see docs/adr/0007-ux-detection-objective-verdict-subjective-advisory.md).
 *
 * Each finding is OBJECTIVE and machine-checkable — it maps to verdict `fail`, suspected layer
 * `FE`, confidence `low` (low because the threshold is a WCAG standard, not a spec/domain numeric
 * oracle — see ADR-0007). Subjective aesthetics are NEVER judged here; those go to the advisory
 * stream via a separate multimodal screenshot read (see SKILL.md Step 3) and are NEVER a verdict.
 *
 * Thresholds are WCAG 2.2:
 *   - contrast:        SC 1.4.3, 4.5:1 normal text / 3:1 large text (>=24px, or >=18.66px + bold)
 *   - overflow/clip:    scrollWidth/scrollHeight > clientWidth/clientHeight while overflow is not
 *                       auto/scroll (i.e. content is silently clipped, not scrollable)
 *   - target-size:      SC 2.5.8 (AA), 24x24 CSS px minimum for buttons/links/checkboxes/radios
 *   - accessible-name:  SC 4.1.2 / axe `button-name` analog — no text/aria-label/aria-labelledby/
 *                       title/alt on an interactive element. Elements with a short symbol-only
 *                       name (e.g. "?", icon glyphs) are flagged `probeClick: true` — a STATIC
 *                       check cannot see a runtime exception; the driving-browser-qa per-step loop
 *                       must click these and read `browser_console_messages` to confirm the second
 *                       half of the U4 class (console error thrown on click). See SKILL.md Step 2.
 *
 * PRECISION DISCIPLINE: every detector below is threshold-gated, not "flag everything with color/
 * size/overflow." A clean AA-passing control (e.g. black-on-white ~17:1, a full-size button, a
 * non-clipping cell) must produce zero findings — verified against the accuracy-harness negative
 * controls (N2 et al). Do not lower thresholds "to be safe"; a false positive here becomes a false
 * `fail` in a real QA run.
 */
(function () {
  function relLuminance(r, g, b) {
    const a = [r, g, b].map(function (v) {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  }
  function parseRGB(s) {
    const m = (s || '').match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map(function (x) { return parseFloat(x.trim()); });
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  }
  function contrastRatio(fg, bg) {
    const L1 = relLuminance(fg.r, fg.g, fg.b);
    const L2 = relLuminance(bg.r, bg.g, bg.b);
    const hi = Math.max(L1, L2), lo = Math.min(L1, L2);
    return (hi + 0.05) / (lo + 0.05);
  }
  // Alpha-composite `fg` OVER `bg` (both {r,g,b,a}), returning an opaque {r,g,b,a:1}.
  function compositeOver(fg, bg) {
    const a = fg.a;
    return {
      r: fg.r * a + bg.r * (1 - a),
      g: fg.g * a + bg.g * (1 - a),
      b: fg.b * a + bg.b * (1 - a),
      a: 1
    };
  }
  // Walk up accumulating backdrop via proper alpha compositing: every semi-transparent
  // ancestor background is composited OVER what's already been accumulated, so a stack of
  // translucent layers resolves to the real visual backdrop instead of stopping at the first
  // non-fully-transparent color. Falls back to the <html> background (dark-theme pages often
  // set the page bg there, not on <body>) before defaulting to white.
  function effectiveBg(el) {
    let node = el;
    let acc = null; // accumulated backdrop so far, composited bottom-up
    const chain = [];
    while (node && node !== document.documentElement) {
      chain.push(node);
      node = node.parentElement;
    }
    chain.push(document.documentElement); // include <html> as the final ancestor
    // Walk from the outermost (html) down to the element so compositing order is correct:
    // each layer is painted OVER the accumulated result of everything behind it.
    for (let i = chain.length - 1; i >= 0; i--) {
      const c = parseRGB(getComputedStyle(chain[i]).backgroundColor);
      if (!c || c.a === 0) continue; // fully transparent: contributes nothing, keep going
      acc = acc ? compositeOver(c, acc) : compositeOver(c, { r: 255, g: 255, b: 255, a: 1 });
    }
    return acc || { r: 255, g: 255, b: 255, a: 1 };
  }
  function cssPath(el) {
    if (el.getAttribute && el.getAttribute('data-testid')) return '[data-testid=' + el.getAttribute('data-testid') + ']';
    if (el.id) return '#' + el.id;
    const cls = (el.className && el.className.toString().trim().split(/\s+/)[0]) || '';
    return el.tagName.toLowerCase() + (cls ? '.' + cls : '');
  }
  function visibleText(el) {
    return (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40);
  }
  function finding(detector, el, message, extra) {
    return Object.assign({
      detector: detector,
      axis: 'ux-objective',
      suspectedLayer: 'FE',
      confidence: 'low',
      selector: cssPath(el),
      text: visibleText(el),
      message: message
    }, extra || {});
  }

  const findings = [];
  const all = Array.prototype.slice.call(document.querySelectorAll('body *'));

  // ---- 1. Contrast (WCAG SC 1.4.3) -> U1-class ----
  all.forEach(function (el) {
    const hasText = el.childNodes.length && Array.prototype.some.call(el.childNodes, function (n) {
      return n.nodeType === 3 && n.textContent.trim();
    });
    if (!hasText) return;
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) return;
    const fg = parseRGB(st.color);
    if (!fg) return;
    const bg = effectiveBg(el);
    const size = parseFloat(st.fontSize);
    const bold = parseInt(st.fontWeight, 10) >= 700;
    const large = size >= 24 || (size >= 18.66 && bold);
    const ratio = contrastRatio(fg, bg);
    const min = large ? 3 : 4.5;
    if (ratio < min) {
      findings.push(finding('contrast', el,
        'Contrast ' + ratio.toFixed(2) + ':1 below WCAG AA ' + min + ':1 (SC 1.4.3)'));
    }
  });

  // ---- 2. Overflow / clipping -> U2-class ----
  all.forEach(function (el) {
    const st = getComputedStyle(el);
    if (st.overflow === 'visible' && st.overflowX === 'visible' && st.overflowY === 'visible') return;
    const clipsX = el.scrollWidth - el.clientWidth > 1;
    const clipsY = el.scrollHeight - el.clientHeight > 1;
    // Each axis is scrollable independently — consult overflowX for X-clip and overflowY for
    // Y-clip. A vertically-scrollable pane (overflow-y:auto) must not be flagged just because
    // its horizontal axis (or the shorthand) reads differently.
    const scrollableX = st.overflowX === 'auto' || st.overflowX === 'scroll';
    const scrollableY = st.overflowY === 'auto' || st.overflowY === 'scroll';
    const clippedX = clipsX && !scrollableX;
    const clippedY = clipsY && !scrollableY;
    if (!clippedX && !clippedY) return;
    // Intentional horizontal truncation: text-overflow:ellipsis on a nowrap line is a deliberate
    // UX pattern, not a bug — downgrade to an advisory hint instead of a fail. A clip with NO
    // ellipsis (or a Y-clip) stays a fail.
    if (clippedX && !clippedY && st.textOverflow === 'ellipsis' && st.whiteSpace === 'nowrap') {
      findings.push({
        detector: 'overflow-ellipsis-hint', axis: 'ux-objective-hint',
        selector: cssPath(el), text: visibleText(el),
        message: 'Horizontal truncation with text-overflow:ellipsis — looks intentional, not flagged as a fail'
      });
      return;
    }
    findings.push(finding('overflow', el,
      'Content clipped: scroll ' + el.scrollWidth + 'x' + el.scrollHeight +
      ' > client ' + el.clientWidth + 'x' + el.clientHeight + ' with overflow:' + st.overflow));
  });

  // ---- 3. Touch-target size (WCAG SC 2.5.8, 24x24 AA) -> U3-class ----
  // A control the user cannot see or reach isn't a "too-small target" bug — skip it, same as the
  // existing 0x0 (not rendered/detached) skip.
  function isInvisible(el) {
    // visibility:hidden is reversible by a descendant's own visibility:visible (standard cascade
    // behavior) — getComputedStyle(el).visibility already reflects that cascade for the ELEMENT
    // ITSELF, so checking only el's own value (not ancestors) correctly un-skips a genuinely
    // visible control nested under a visibility:hidden wrapper. display:none and opacity:0 do NOT
    // have a reversing mechanism (they compound down the tree), so those stay ancestor-walked.
    if (getComputedStyle(el).visibility === 'hidden') return true;
    let node = el;
    while (node) {
      const st = node === el ? getComputedStyle(el) : getComputedStyle(node);
      if (st.display === 'none' || parseFloat(st.opacity) === 0) return true;
      node = node.parentElement;
    }
    return false;
  }
  Array.prototype.slice.call(document.querySelectorAll('button, a[href], [role=button], input[type=checkbox], input[type=radio]'))
    .forEach(function (el) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return; // not rendered / detached — nothing to assert
      if (isInvisible(el)) return; // hidden via visibility/opacity/display — not a real target
      if (r.width < 24 || r.height < 24) {
        findings.push(finding('target-size', el,
          'Target ' + Math.round(r.width) + 'x' + Math.round(r.height) +
          ' below WCAG AA 24x24 (SC 2.5.8)'));
      }
    });

  // ---- 4. Missing accessible name -> U4-class (static half) ----
  // Resolve an aria-labelledby reference to its referenced element(s)' text content.
  function labelledByText(el) {
    const ref = el.getAttribute('aria-labelledby');
    if (!ref) return '';
    return ref.split(/\s+/).map(function (id) {
      const t = document.getElementById(id);
      return t ? (t.textContent || '').trim() : '';
    }).filter(Boolean).join(' ');
  }
  // Per the ARIA accname algorithm, aria-hidden subtrees are EXCLUDED from name computation —
  // a candidate that is itself aria-hidden="true", or sits under an ancestor (up to but excluding
  // the control `boundary`) that is aria-hidden="true", must NOT supply a name.
  function isAriaHiddenInScope(node, boundary) {
    let n = node;
    while (n && n !== boundary) {
      if (n.getAttribute && n.getAttribute('aria-hidden') === 'true') return true;
      n = n.parentElement;
    }
    return false;
  }
  // A name can come from the element itself OR be supplied by a descendant — e.g.
  // <button><svg><title>Close</title></svg></button>, <a><img alt="Home"></a>,
  // <button><span aria-label="Menu"></span></button>. Only conclude "no name" when NEITHER
  // self NOR any non-aria-hidden descendant resolves one.
  function childSuppliedName(el) {
    // Scan every matching candidate (not just the first) so an aria-hidden decoy earlier in the
    // subtree doesn't shadow a legitimately-named candidate elsewhere.
    function firstVisibleName(selector, getText) {
      const nodes = Array.prototype.slice.call(el.querySelectorAll(selector));
      for (let i = 0; i < nodes.length; i++) {
        const node = nodes[i];
        if (isAriaHiddenInScope(node, el)) continue;
        const t = getText(node);
        if (t) return t;
      }
      return '';
    }
    const imgAlt = firstVisibleName('img[alt]', function (n) { return (n.getAttribute('alt') || '').trim(); });
    if (imgAlt) return imgAlt;
    const svgTitleText = firstVisibleName('svg > title, svg title', function (n) { return (n.textContent || '').trim(); });
    if (svgTitleText) return svgTitleText;
    const ariaLabelText = firstVisibleName('[aria-label]', function (n) { return (n.getAttribute('aria-label') || '').trim(); });
    if (ariaLabelText) return ariaLabelText;
    const labelledbyNodes = Array.prototype.slice.call(el.querySelectorAll('[aria-labelledby]'));
    for (let i = 0; i < labelledbyNodes.length; i++) {
      const node = labelledbyNodes[i];
      if (isAriaHiddenInScope(node, el)) continue;
      const t = labelledByText(node);
      if (t) return t;
    }
    return '';
  }
  Array.prototype.slice.call(document.querySelectorAll('button, a[href], [role=button]'))
    .forEach(function (el) {
      const name = (el.getAttribute('aria-label') || labelledByText(el) ||
                    el.getAttribute('title') || el.getAttribute('alt') ||
                    (el.textContent || '').trim() || childSuppliedName(el));
      if (!name || name.length === 0) {
        findings.push(finding('accessible-name', el,
          'Interactive element has no accessible name (WCAG SC 4.1.2 / axe button-name)'));
        return;
      }
      // Symbol-only / single-glyph label (e.g. "?", icon font ligature): a real accessible name
      // exists so the static check must NOT fail it, but it is exactly the shape of control that
      // hides a broken click handler behind a plausible-looking label. Flag for a click-probe so
      // driving-browser-qa clicks it and reads browser_console_messages for a thrown error — the
      // dynamic half of the U4 class. This is a HINT, not a finding: it carries no verdict itself.
      if (/^[^\w\s]{1,2}$/.test(name)) {
        findings.push({
          detector: 'accessible-name-probe', axis: 'ux-objective-hint',
          selector: cssPath(el), text: visibleText(el), probeClick: true,
          message: 'Symbol-only label "' + name + '" — click-probe for a thrown console error (U4 dynamic half)'
        });
      }
    });

  return findings;
})();
