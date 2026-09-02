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
// ===== Pure, DOM-free cores (shared by the browser walk AND the node unit tests) =====
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

// content/data-rendering: definite content-oracle artifacts in a rendered value.
// Q2 (human-like precision): the bare literals `undefined`/`null`/`NaN` are flagged ONLY
// WHOLE-CELL — i.e. when the element's entire trimmed direct text IS the literal, exactly how
// they leak from a data slot that rendered nothing but the raw value. A human does NOT flag
// prose that merely CONTAINS or ENDS IN the word ("The result is NaN", "This field is
// undefined", "Value is null", "The null hypothesis"), so those must NOT match — whole-string
// equality (not a trailing-token regex) is what keeps that boundary precise. `$NaN` (currency),
// `[object Object]`, `Invalid Date`, and raw `{{interp}}` never occur in legitimate prose, so
// they stay position-independent (matched anywhere in the text).
function contentOracleSignal(text) {
  const t = String(text == null ? '' : text);
  const trimmed = t.trim();
  if (trimmed === 'null') return { kind: 'null', rawSignal: 'null' };
  if (trimmed === 'undefined') return { kind: 'undefined', rawSignal: 'undefined' };
  if (trimmed === 'NaN') return { kind: 'nan', rawSignal: 'NaN' };
  const checks = [
    ['object-object', /\[object [A-Z]\w*\]/],                 // [object Object], [object Array]
    ['currency-nan', /\$NaN(?=\s*$)/],                        // value-position; unambiguous anywhere
    ['invalid-date', /\bInvalid Date\b/],
    ['raw-interp', /\{\{[^}]+\}\}/],                          // unrendered {{ interpolation }}
    ['raw-iso', /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/]
  ];
  for (let i = 0; i < checks.length; i++) {
    const m = t.match(checks[i][1]);
    if (m) return { kind: checks[i][0], rawSignal: m[0].trim() };
  }
  return null;
}
// A required control whose resolved label is empty is a content gap.
function isEmptyRequiredLabel(labelText) {
  return String(labelText == null ? '' : labelText).trim() === '';
}

// i18n: a bare translation key rendered as a label (whole-text dotted identifier),
// excluding URLs / emails / domains / file names / numbers to hold precision.
function rawTranslationKeySignal(text) {
  const t = String(text == null ? '' : text).trim();
  if (!t || /\s/.test(t)) return null;                       // real labels have spaces
  if (t.indexOf('@') !== -1 || t.indexOf('://') !== -1) return null;   // email / URL
  // Q4 (human-like precision): version strings, ccTLD domains, and file names are NOT keys.
  if (/^v\d/i.test(t)) return null;                          // v1.2.3, v2 — a version, not a key
  if (/^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2}$/.test(t)) return null;  // ccTLD domain: example.co.uk
  if (/\.(com|org|net|io|dev|co|gov|edu|app|html?|js|mjs|cjs|jsx|ts|tsx|vue|css|scss|less|json|ya?ml|toml|xml|md|txt|csv|pdf|png|jpe?g|gif|webp|svg|ico|py|rb|go|rs|java|kt|swift|php)$/i.test(t)) return null;
  if (!/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/.test(t)) return null;  // dotted identifier
  // PascalCase.PascalCase (React.Component, Foo.Bar, Error.NotFound) is a breadcrumb/namespace,
  // not a translation key: every segment starts uppercase. Real keys are lowercase-dotted.
  if (t.split('.').every(function (seg) { return /^[A-Z]/.test(seg); })) return null;
  return { rawSignal: t };
}
// i18n: locale -> expected Unicode script. Latin/unknown locales carry no script oracle.
const LOCALE_SCRIPT = {
  ar: 'Arabic', fa: 'Arabic', ur: 'Arabic', ps: 'Arabic',
  he: 'Hebrew', yi: 'Hebrew',
  ru: 'Cyrillic', uk: 'Cyrillic', bg: 'Cyrillic', sr: 'Cyrillic',
  el: 'Greek', ja: 'Han', zh: 'Han', ko: 'Hangul',
  hi: 'Devanagari', mr: 'Devanagari', th: 'Thai'
};
function scriptMismatchSignal(text, expectedLocale) {
  const loc = String(expectedLocale || '').toLowerCase().split(/[-_]/)[0];
  const script = LOCALE_SCRIPT[loc];
  if (!script) return null;                                  // no non-Latin script expected
  const trimmed = String(text == null ? '' : text).trim();
  const letters = trimmed.match(/\p{L}/gu) || [];
  if (letters.length < 3) return null;                       // abbrev/brand/symbol — precision guard
  // Q3 (human-like precision): a human does NOT read a brand / acronym / URL / code identifier as
  // "untranslated" just because it's Latin on an Arabic page (GitHub, PDF, https://…, api.v2).
  // Exempt when NO token reads as translatable prose. A word-like token is Title-case or
  // lowercase ONLY (^[A-Za-z][a-z]+$) — a brand/acronym/CamelCase token ("GitHub", "PDF",
  // "iPhone") or a bare digit token never matches. A phrase reads as prose once it has >=2
  // such tokens ("Save changes", "Save Changes", "Sign In", "Sohranit izmeneniya" all do);
  // a lone Title-Case/lowercase word stays exempt as a possible proper noun.
  // URLs/emails/code punctuation are exempt outright.
  if (/:\/\/|[@<>{}=;\\]|www\./.test(trimmed)) return null;  // URL / email / code
  const wordTokens = trimmed.split(/\s+/).filter(function (tok) {
    return /^[A-Za-z][a-z]+$/.test(tok);                     // Title-case/lowercase word => reads as prose
  });
  if (wordTokens.length < 2) return null;                    // <2 prose words -> brand/acronym/proper-noun, not a bug
  const re = new RegExp('\\p{Script=' + script + '}', 'u');
  let inScript = 0;
  for (let i = 0; i < letters.length; i++) if (re.test(letters[i])) inScript++;
  const frac = inScript / letters.length;
  if (frac >= 0.5) return null;                              // predominantly correct script
  return { expectedScript: script, fraction: Number(frac.toFixed(2)), rawSignal: trimmed.slice(0, 40) };
}

// ===== Browser-only DOM walk. Returns the findings array (browser_evaluate completion value). =====
function DETECT() {
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
  // A SUSPICION carries NO verdict/suspectedLayer/confidence — adjudication assigns those.
  function suspicion(detector, el, evidence, rawSignal) {
    return {
      detector: detector,
      axis: 'ux-suspicion',
      selector: cssPath(el),
      text: visibleText(el),
      evidence: evidence,
      rawSignal: rawSignal
    };
  }
  // Direct (own) text of an element, whitespace-collapsed — avoids double-flagging on ancestors.
  function directText(el) {
    let s = '';
    Array.prototype.forEach.call(el.childNodes, function (n) { if (n.nodeType === 3) s += n.textContent; });
    return s.replace(/\s+/g, ' ').trim();
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

  // ---- Content / data-rendering suspicions ----
  all.forEach(function (el) {
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) return;
    const direct = directText(el);
    if (!direct) return;
    const sig = contentOracleSignal(direct);
    if (sig) findings.push(suspicion('content-' + sig.kind, el, direct, sig.rawSignal));
  });
  Array.prototype.slice.call(document.querySelectorAll('[required], [aria-required="true"]'))
    .forEach(function (el) {
      let lbl = '';
      if (el.id) {
        const forLbl = document.querySelector('label[for="' + el.id + '"]');
        if (forLbl) lbl = (forLbl.textContent || '').trim();
      }
      if (!lbl && el.getAttribute('aria-label')) lbl = el.getAttribute('aria-label').trim();
      // Q5: aria-labelledby is a first-class labelling mechanism — resolve referenced elements'
      // text, else a properly-labelled required control is falsely flagged as label-less.
      if (!lbl && el.getAttribute('aria-labelledby')) {
        lbl = el.getAttribute('aria-labelledby').split(/\s+/).map(function (id) {
          const t = document.getElementById(id);
          return t ? (t.textContent || '').trim() : '';
        }).filter(Boolean).join(' ').trim();
      }
      if (!lbl && el.closest) { const wrap = el.closest('label'); if (wrap) lbl = (wrap.textContent || '').trim(); }
      if (isEmptyRequiredLabel(lbl)) {
        findings.push(suspicion('content-empty-required-label', el, 'required control has no visible/aria label', ''));
      }
    });

  // ---- i18n-script suspicions ----
  const EXPECTED_LOCALE = (document.documentElement.getAttribute('lang') || '').trim();
  all.forEach(function (el) {
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) return;
    const direct = directText(el);
    if (!direct) return;
    const key = rawTranslationKeySignal(direct);
    if (key) { findings.push(suspicion('i18n-raw-key', el, direct, key.rawSignal)); return; }
    const mm = scriptMismatchSignal(direct, EXPECTED_LOCALE);
    if (mm) {
      findings.push(suspicion('i18n-script-mismatch', el,
        'expected ' + mm.expectedScript + ' script; ' + Math.round(mm.fraction * 100) + '% in-script',
        mm.rawSignal));
    }
  });

  return findings;
}

// ===== Dual entry point =====
// Browser (injected via browser_evaluate): run the DOM walk — the ternary's VALUE is the
// findings array, exactly like the previous IIFE form, so the evaluate() contract is preserved.
// Node (unit tests / tooling): export the pure cores; DETECT() is never called, so `document`
// is never referenced on require.
typeof document !== 'undefined'
  ? DETECT()
  : (typeof module !== 'undefined' && module.exports &&
     (module.exports = {
       relLuminance: relLuminance,
       parseRGB: parseRGB,
       contrastRatio: contrastRatio,
       DETECT: DETECT,
       contentOracleSignal: contentOracleSignal,
       isEmptyRequiredLabel: isEmptyRequiredLabel,
       rawTranslationKeySignal: rawTranslationKeySignal,
       scriptMismatchSignal: scriptMismatchSignal
     }));
