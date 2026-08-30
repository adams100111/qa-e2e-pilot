/*
 * ux-detectors.js — dependency-free, in-page OBJECTIVE UX/layout detectors.
 *
 * Injected via the `evaluate` capability (Playwright MCP `browser_evaluate`) — NEVER
 * `browser_run_code_unsafe` (RCE-equivalent, ungated; see ADR-0009). Runs against the single
 * rendered page: no golden baseline required (pixel-diff can't judge a first run — see ADR-0009).
 *
 * Returns a JSON-serializable array of findings. Each finding maps to a FAIL @ suspected layer FE,
 * confidence: low (objective-UX has no spec/domain numeric oracle) — see ADR-0007 / plan §wider-detection.
 * Subjective aesthetics are NOT judged here — those go to the advisory stream (ADR-0008).
 *
 * Thresholds are WCAG 2.2:
 *   - contrast:      SC 1.4.3, 4.5:1 normal text / 3:1 large text
 *   - target-size:   SC 2.5.8 (AA) 24x24 CSS px minimum
 *   Sources cited in docs/plans/accuracy-overhaul.md §tooling.
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

  const findings = [];
  const all = Array.prototype.slice.call(document.querySelectorAll('body *'));

  // ---- 1. Contrast (WCAG SC 1.4.3) ----
  all.forEach(function (el) {
    const txt = (el.childNodes.length && Array.prototype.some.call(el.childNodes, function (n) {
      return n.nodeType === 3 && n.textContent.trim();
    }));
    if (!txt) return;
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
      findings.push({
        detector: 'contrast', axis: 'ux-objective', suspectedLayer: 'FE', confidence: 'low',
        selector: cssPath(el), text: visibleText(el),
        message: 'Contrast ' + ratio.toFixed(2) + ':1 below WCAG AA ' + min + ':1 (SC 1.4.3)'
      });
    }
  });

  // ---- 2. Overflow / clipping ----
  all.forEach(function (el) {
    const st = getComputedStyle(el);
    if (st.overflow === 'visible' && st.overflowX === 'visible' && st.overflowY === 'visible') return;
    const clipsX = el.scrollWidth - el.clientWidth > 1;
    const clipsY = el.scrollHeight - el.clientHeight > 1;
    if ((clipsX || clipsY) && (st.overflow !== 'auto' && st.overflow !== 'scroll' &&
        st.overflowX !== 'auto' && st.overflowX !== 'scroll')) {
      findings.push({
        detector: 'overflow', axis: 'ux-objective', suspectedLayer: 'FE', confidence: 'low',
        selector: cssPath(el), text: visibleText(el),
        message: 'Content clipped: scroll ' + el.scrollWidth + 'x' + el.scrollHeight +
                 ' > client ' + el.clientWidth + 'x' + el.clientHeight + ' with overflow:' + st.overflow
      });
    }
  });

  // ---- 3. Touch-target size (WCAG SC 2.5.8, 24x24 AA) ----
  Array.prototype.slice.call(document.querySelectorAll('button, a[href], [role=button], input[type=checkbox], input[type=radio]'))
    .forEach(function (el) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return;
      if (r.width < 24 || r.height < 24) {
        findings.push({
          detector: 'target-size', axis: 'ux-objective', suspectedLayer: 'FE', confidence: 'low',
          selector: cssPath(el), text: visibleText(el),
          message: 'Target ' + Math.round(r.width) + 'x' + Math.round(r.height) +
                   ' below WCAG AA 24x24 (SC 2.5.8)'
        });
      }
    });

  // ---- 4. Missing accessible name on interactive elements (axe overlaps; cheap pre-check) ----
  Array.prototype.slice.call(document.querySelectorAll('button, a[href], [role=button]'))
    .forEach(function (el) {
      const name = (el.getAttribute('aria-label') || el.getAttribute('title') ||
                    (el.textContent || '').trim());
      const hasIconOnly = !name || name.length === 0;
      if (hasIconOnly) {
        findings.push({
          detector: 'accessible-name', axis: 'ux-objective', suspectedLayer: 'FE', confidence: 'low',
          selector: cssPath(el), text: '(no accessible name)',
          message: 'Interactive element has no accessible name (WCAG SC 4.1.2 / axe button-name)'
        });
      }
    });

  return findings;
})();
