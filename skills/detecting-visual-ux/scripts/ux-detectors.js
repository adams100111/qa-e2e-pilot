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
  // Walk up for the first non-transparent background.
  function effectiveBg(el) {
    let node = el;
    while (node && node !== document.documentElement) {
      const c = parseRGB(getComputedStyle(node).backgroundColor);
      if (c && c.a !== 0) return c;
      node = node.parentElement;
    }
    return { r: 255, g: 255, b: 255, a: 1 };
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
    const scrollable = st.overflow === 'auto' || st.overflow === 'scroll' ||
      st.overflowX === 'auto' || st.overflowX === 'scroll';
    if ((clipsX || clipsY) && !scrollable) {
      findings.push(finding('overflow', el,
        'Content clipped: scroll ' + el.scrollWidth + 'x' + el.scrollHeight +
        ' > client ' + el.clientWidth + 'x' + el.clientHeight + ' with overflow:' + st.overflow));
    }
  });

  // ---- 3. Touch-target size (WCAG SC 2.5.8, 24x24 AA) -> U3-class ----
  Array.prototype.slice.call(document.querySelectorAll('button, a[href], [role=button], input[type=checkbox], input[type=radio]'))
    .forEach(function (el) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return; // not rendered / detached — nothing to assert
      if (r.width < 24 || r.height < 24) {
        findings.push(finding('target-size', el,
          'Target ' + Math.round(r.width) + 'x' + Math.round(r.height) +
          ' below WCAG AA 24x24 (SC 2.5.8)'));
      }
    });

  // ---- 4. Missing accessible name -> U4-class (static half) ----
  Array.prototype.slice.call(document.querySelectorAll('button, a[href], [role=button]'))
    .forEach(function (el) {
      const name = (el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') ||
                    el.getAttribute('title') || el.getAttribute('alt') ||
                    (el.textContent || '').trim());
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
