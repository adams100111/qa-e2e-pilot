/*
 * crawl-safety.js — the census crawl's click-safety classifier (English + Arabic).
 *
 * Injected via the `evaluate` capability (Playwright MCP `browser_evaluate`) — NEVER
 * `browser_run_code_unsafe`. Read-only: it inspects the page and returns a verdict per
 * interactive element; it never clicks, focuses, or submits anything.
 *
 * Returns: [{ selector, label, safe, reason }] — one entry per interactive element on the page.
 * The crawl may click ONLY entries with `safe: true`. Every `safe: false` entry is recorded in the
 * crawl file's `unexplored[]` with its reason. Default is DENY: an element that matches no safe
 * rule is `safe: false, reason: "not-allowlisted"`.
 *
 * Side effect (browser): sets `window.__qaRouteMatch` to `page:<component>` read from Inertia's
 * `#app[data-page]` `.component` or Next.js `#__NEXT_DATA__` `.page`, else null.
 *
 * Options (browser): set `window.__qaCrawlOptions = { denyPatterns: [...] }` in an earlier
 * evaluate call (the config's `crawlDenyPatterns`, regex strings, case-insensitive; an invalid
 * regex falls back to a plain substring match). `origin` defaults to `location.origin`.
 *
 * UNSAFE rules (checked first — unsafe always wins over safe):
 *   - any of the element's names (accessible name, aria-label, aria-labelledby text, visible text,
 *     title, value, alt) matches UNSAFE_EN or the Arabic unsafe terms (after Arabic normalisation:
 *     tashkeel/tatweel/bidi marks stripped, alef variants folded) → `unsafe-name`
 *   - effective type submit/image (a <button> with no type inside a form is a submit) → `type-submit`;
 *     type reset → `type-reset`
 *   - inside a form whose method is not GET → `inside-non-get-form`
 *   - `data-method` other than get → `non-get-method`; `data-confirm` → `data-confirm`
 *   - a link whose href names logout/sign-out/delete/destroy/remove/revoke or carries `_method=`
 *     → `unsafe-href`
 * NOT-SAFE (but not destructive) link/state guards: `non-http-href`, `cross-origin`, `download`,
 *   `deny-pattern`, `disabled`, `not-visible`.
 * SAFE rules: same-origin `a[href]` → `same-origin-link`; `[role=tab]` → `tab`; `summary` or
 *   `[aria-expanded]` → `disclosure`; `[aria-haspopup]` → `popup-opener`; a button/menuitem whose
 *   accessible name matches SAFE_EN or the Arabic safe terms → `safe-name`.
 */

// ===== Pure, DOM-free cores (shared by the browser walk AND the node unit tests) =====
var UNSAFE_EN = /(delete|remove|destroy|archive|approve|reject|accept|decline|send|submit|save|publish|cancel|confirm|revoke|disband|withdraw|announce|transition|advance|reset|logout|sign out)/i;
var SAFE_EN = /^(open|view|details|show|more|edit|filter|sort|next|previous|expand|menu)\b/i;
var UNSAFE_AR_TERMS = ['حذف', 'إزالة', 'أرشفة', 'اعتماد', 'موافقة', 'رفض', 'قبول', 'إرسال', 'حفظ', 'نشر', 'إلغاء', 'تأكيد', 'سحب', 'إعلان', 'تسجيل الخروج'];
var SAFE_AR_TERMS = ['عرض', 'تفاصيل', 'المزيد', 'فتح', 'تعديل', 'تصفية', 'القائمة', 'التالي', 'السابق'];
var UNSAFE_HREF = /(log-?out|sign-?out|delete|destroy|remove|revoke)|[?&]_method=/i;

function normalizeText(s) {
  return String(s == null ? '' : s)
    .replace(/[​-‏‪-‮⁦-⁩﻿]/g, '')
    .replace(/[ؐ-ًؚ-ٰٟۖ-ۭ]/g, '')
    .replace(/ـ/g, '')
    .replace(/[آأإٱ]/g, 'ا')
    .replace(/\s+/g, ' ')
    .trim();
}

function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
var UNSAFE_AR = new RegExp('(' + UNSAFE_AR_TERMS.map(function (t) { return escapeRe(normalizeText(t)); }).join('|') + ')');
var SAFE_AR = new RegExp('(' + SAFE_AR_TERMS.map(function (t) { return escapeRe(normalizeText(t)); }).join('|') + ')');

function accessibleName(d) {
  var candidates = [d.labelledByText, d.ariaLabel, d.text, d.title, d.value, d.alt];
  for (var i = 0; i < candidates.length; i++) {
    var n = normalizeText(candidates[i]);
    if (n) return n.length > 120 ? n.slice(0, 120) : n;
  }
  return '';
}

function isUnsafeName(s) {
  var n = normalizeText(s);
  return n !== '' && (UNSAFE_EN.test(n) || UNSAFE_AR.test(n));
}
function isSafeName(s) {
  var n = normalizeText(s);
  return n !== '' && (SAFE_EN.test(n) || SAFE_AR.test(n));
}

function matchesDenyPattern(href, patterns) {
  for (var i = 0; i < (patterns || []).length; i++) {
    var p = patterns[i];
    if (!p) continue;
    var hit;
    try { hit = new RegExp(p, 'i').test(href); } catch (e) { hit = href.indexOf(p) !== -1; }
    if (hit) return true;
  }
  return false;
}

/**
 * classify(descriptor, opts) → { selector, label, safe, reason }
 * descriptor: { tag, type?, role?, href?, download?, text?, ariaLabel?, labelledByText?, title?,
 *   value?, alt?, ariaHaspopup?, ariaExpanded?, dataMethod?, dataConfirm?, disabled?, visible?,
 *   formMethod? (null/absent = not inside a form), selector? }
 * opts: { origin?, denyPatterns? }
 */
function classify(d, opts) {
  opts = opts || {};
  var tag = String(d.tag || '').toLowerCase();
  var type = d.type == null ? '' : String(d.type).toLowerCase();
  var role = String(d.role || '').toLowerCase();
  var inForm = d.formMethod != null && d.formMethod !== '';
  var formMethod = inForm ? String(d.formMethod).toLowerCase() : null;
  var label = accessibleName(d);
  function out(safe, reason) { return { selector: d.selector || '', label: label, safe: safe, reason: reason }; }

  // ---- unsafe: every name source is checked, so an icon's aria-label or a title counts ----
  var names = [d.labelledByText, d.ariaLabel, d.text, d.title, d.value, d.alt];
  for (var i = 0; i < names.length; i++) {
    if (isUnsafeName(names[i])) return out(false, 'unsafe-name');
  }
  var effectiveType = type;
  if (tag === 'button' && !type && inForm) effectiveType = 'submit';
  if ((tag === 'button' || tag === 'input') && (effectiveType === 'submit' || effectiveType === 'image')) return out(false, 'type-submit');
  if ((tag === 'button' || tag === 'input') && effectiveType === 'reset') return out(false, 'type-reset');
  if (inForm && formMethod !== 'get') return out(false, 'inside-non-get-form');
  if (d.dataMethod != null && d.dataMethod !== '' && String(d.dataMethod).toLowerCase() !== 'get') return out(false, 'non-get-method');
  if (d.dataConfirm != null && d.dataConfirm !== false) return out(false, 'data-confirm');

  var isLink = tag === 'a' && d.href != null && d.href !== '';
  if (isLink) {
    var href = String(d.href);
    if (UNSAFE_HREF.test(href)) return out(false, 'unsafe-href');
    var base = opts.origin || (typeof window !== 'undefined' && window.location ? window.location.origin : 'http://localhost');
    var resolved;
    try { resolved = new URL(href, base + '/'); } catch (e) { return out(false, 'non-http-href'); }
    if (resolved.protocol !== 'http:' && resolved.protocol !== 'https:') return out(false, 'non-http-href');
    if (resolved.origin !== new URL(base + '/').origin) return out(false, 'cross-origin');
    if (d.download) return out(false, 'download');
    if (matchesDenyPattern(resolved.pathname + resolved.search, opts.denyPatterns) || matchesDenyPattern(href, opts.denyPatterns)) return out(false, 'deny-pattern');
  }
  if (d.disabled) return out(false, 'disabled');
  if (d.visible === false) return out(false, 'not-visible');

  // ---- safe allowlist ----
  if (isLink) return out(true, 'same-origin-link');
  if (role === 'tab') return out(true, 'tab');
  if (tag === 'summary') return out(true, 'disclosure');
  if (d.ariaHaspopup != null && String(d.ariaHaspopup).toLowerCase() !== 'false') return out(true, 'popup-opener');
  if (d.ariaExpanded != null) return out(true, 'disclosure');
  var buttonLike = tag === 'button' || role === 'button' || role === 'menuitem' ||
    (tag === 'input' && effectiveType === 'button');
  if (buttonLike && isSafeName(label)) return out(true, 'safe-name');
  return out(false, 'not-allowlisted');
}

// ===== In-page walk =====
var INTERACTIVE_SELECTOR = 'a[href], button, input[type=submit], input[type=button], input[type=image], input[type=reset], ' +
  '[role=button], [role=link], [role=tab], [role=menuitem], [aria-haspopup], [aria-expanded], summary';

function cssSelector(el) {
  var testId = el.getAttribute && el.getAttribute('data-testid');
  if (testId) return '[data-testid="' + testId.replace(/"/g, '\\"') + '"]';
  if (el.id) return '#' + String(el.id).replace(/([^\w-])/g, '\\$1');
  var path = [];
  var node = el;
  while (node && node.nodeType === 1 && node !== document.documentElement) {
    var part = node.tagName.toLowerCase();
    var parent = node.parentNode;
    if (parent && parent.children) {
      var same = Array.prototype.filter.call(parent.children, function (s) { return s.tagName === node.tagName; });
      if (same.length > 1) part += ':nth-child(' + (Array.prototype.indexOf.call(parent.children, node) + 1) + ')';
    }
    path.unshift(part);
    node = parent;
  }
  return path.join(' > ');
}

function isVisible(el) {
  if (!el.getBoundingClientRect) return true;
  var rect = el.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return false;
  var style = typeof getComputedStyle === 'function' ? getComputedStyle(el) : null;
  if (!style) return true;
  if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
  if (parseFloat(style.opacity) === 0) return false;
  return true;
}

function describe(el) {
  var attr = function (n) { return el.getAttribute(n); };
  var labelledBy = attr('aria-labelledby');
  var labelledByText = '';
  if (labelledBy) {
    labelledByText = labelledBy.split(/\s+/).map(function (id) {
      var ref = document.getElementById(id);
      return ref ? (ref.innerText || ref.textContent || '') : '';
    }).join(' ');
  }
  var img = el.querySelector ? el.querySelector('img[alt]') : null;
  var form = el.form || (el.closest ? el.closest('form') : null);
  var formMethod = null;
  if (form) formMethod = attr('formmethod') || form.getAttribute('method') || 'get';
  return {
    tag: el.tagName.toLowerCase(),
    type: attr('type'),
    role: attr('role'),
    href: attr('href'),
    download: el.hasAttribute ? el.hasAttribute('download') : false,
    text: el.innerText || el.textContent || '',
    ariaLabel: attr('aria-label'),
    labelledByText: labelledByText,
    title: attr('title'),
    value: el.tagName.toLowerCase() === 'input' ? attr('value') : null,
    alt: img ? img.getAttribute('alt') : null,
    ariaHaspopup: attr('aria-haspopup'),
    ariaExpanded: attr('aria-expanded'),
    dataMethod: attr('data-method'),
    dataConfirm: attr('data-confirm'),
    disabled: (el.hasAttribute && el.hasAttribute('disabled')) || attr('aria-disabled') === 'true',
    visible: isVisible(el),
    formMethod: formMethod,
    selector: cssSelector(el)
  };
}

function SCAN(opts) {
  opts = opts || {};
  var o = {
    origin: opts.origin || window.location.origin,
    denyPatterns: opts.denyPatterns || []
  };
  var els = Array.prototype.slice.call(document.querySelectorAll(INTERACTIVE_SELECTOR));
  var seen = [];
  var results = [];
  els.forEach(function (el) {
    if (seen.indexOf(el) !== -1) return;
    seen.push(el);
    results.push(classify(describe(el), o));
  });
  return results;
}

// ===== Page component → census routeMatch =====
// census.sh maps adapter `page:<component>` surfaces only through a visit's `routeMatch`.
// Inertia: `#app[data-page]` JSON `.component`; Next.js: `#__NEXT_DATA__` JSON `.page`.
function parseJson(s) {
  if (s == null || s === '') return null;
  try { return JSON.parse(s); } catch (e) { return null; }
}
/** pageComponent(dataPageJson, nextDataJson) → component name, or null when neither exposes one. */
function pageComponent(dataPageJson, nextDataJson) {
  var inertia = parseJson(dataPageJson);
  if (inertia && typeof inertia.component === 'string' && inertia.component !== '') return inertia.component;
  var next = parseJson(nextDataJson);
  if (next && typeof next.page === 'string' && next.page !== '') return next.page;
  return null;
}
/** routeMatchFor(...) → "page:<component>" or null (omit routeMatch from the visit). */
function routeMatchFor(dataPageJson, nextDataJson) {
  var c = pageComponent(dataPageJson, nextDataJson);
  return c === null ? null : 'page:' + c;
}
function PAGE_ROUTE_MATCH() {
  var app = document.getElementById('app');
  var dataPage = app && app.getAttribute ? app.getAttribute('data-page') : null;
  if (!dataPage && document.querySelector) {
    var script = document.querySelector('script[data-page]');
    dataPage = script ? script.textContent : null;
  }
  var nextEl = document.getElementById('__NEXT_DATA__');
  return routeMatchFor(dataPage, nextEl ? nextEl.textContent : null);
}

// ===== Dual entry point =====
// Browser: the ternary's VALUE is the classification array (the evaluate() contract). As a side
// effect it publishes `window.__qaRouteMatch` ("page:<component>" or null) for the visit record.
// Node: export the pure cores; SCAN() is never called on require.
typeof document !== 'undefined'
  ? (window.__qaRouteMatch = PAGE_ROUTE_MATCH(), SCAN(window.__qaCrawlOptions || {}))
  : (typeof module !== 'undefined' && module.exports &&
     (module.exports = {
       classify: classify,
       normalizeText: normalizeText,
       accessibleName: accessibleName,
       isUnsafeName: isUnsafeName,
       isSafeName: isSafeName,
       SCAN: SCAN,
       pageComponent: pageComponent,
       routeMatchFor: routeMatchFor,
       PAGE_ROUTE_MATCH: PAGE_ROUTE_MATCH,
       UNSAFE_EN: UNSAFE_EN,
       SAFE_EN: SAFE_EN,
       UNSAFE_AR_TERMS: UNSAFE_AR_TERMS,
       SAFE_AR_TERMS: SAFE_AR_TERMS
     }));
