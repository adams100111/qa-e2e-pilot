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
 *     title, value, alt) matches UNSAFE_EN, UNSAFE_LOGOUT (`log out`/`sign-out` spacing) or the
 *     Arabic unsafe terms (after Arabic normalisation: tashkeel/tatweel/bidi marks stripped, alef
 *     variants folded, ى→ي, ة→ه, applied to terms and names alike) → `unsafe-name`.
 *     Status-tab exception: on a [role=tab] or a[href] only, a name source that is WHOLLY a
 *     past-tense status word with an optional count ("Accepted (3)", "المقبولة") is skipped.
 *   - effective type submit/image (a <button> with no type inside a form is a submit) → `type-submit`;
 *     type reset → `type-reset`
 *   - inside a form whose method/formmethod is not explicitly "get" (a missing method counts as
 *     non-GET: SPA forms submit by XHR) → `inside-non-get-form`
 *   - `data-method` other than get → `non-get-method`; `data-confirm` → `data-confirm`
 *   - a link whose href names an unsafe verb (delete, destroy, remove, revoke, accept, approve,
 *     reject, decline, publish, cancel, confirm, withdraw, verify, unsubscribe, impersonate,
 *     mark-read, toggle, leave, join, log out, sign out) or carries `_method=` → `unsafe-href`
 * NOT-SAFE (but not destructive) link/state guards: `non-http-href`, `cross-origin`, `download`,
 *   `deny-pattern`, `disabled`, `not-visible`.
 * SAFE rules: same-origin `a[href]` → `same-origin-link`; `[role=tab]` → `tab`; `summary` or
 *   `[aria-expanded]` → `disclosure`; `[aria-haspopup]` → `popup-opener`; a button/menuitem whose
 *   accessible name STARTS with a SAFE_EN term or an Arabic safe term (optional leading ال) and
 *   contains no safe-name disqualifier ("Open registration", "Show results", "عرض النتائج" →
 *   `not-allowlisted`) AND passes the object allowlist → `safe-name`. Next/Previous (التالي/
 *   السابق) are never safe button names — a wizard "Next" saves its step — so they are only ever
 *   followed as links (`same-origin-link`). Object allowlist: the name
 *   is the bare verb (+ optional count/chevron), or the word after
 *   the verb is a detail object (details, more, menu, profile, info, information, filters,
 *   options, list, page, all / التفاصيل, القائمة, المزيد, الملف, المعلومات, الخيارات, الكل,
 *   الصفحة), or the verb is edit/تعديل. "Open hackathon", "View awards", "فتح التصويت" → not.
 * SELECTORS: the in-page walk emits a selector only when it matches exactly one element; else the
 *   selector is blank and a would-be-safe entry becomes `ambiguous-selector`.
 */

// ===== Pure, DOM-free cores (shared by the browser walk AND the node unit tests) =====
var UNSAFE_EN = /(delete|remove|destroy|archive|approve|reject|accept|decline|send|submit|save|publish|cancel|confirm|revoke|disband|withdraw|announce|transition|advance|reset|logout|sign out)/i;
// next/previous/التالي/السابق are NOT safe button names: a wizard's "Next" saves the step (I11).
// They are followed only as links (same-origin-link, navigated, never clicked).
var SAFE_EN = /^(open|view|details|show|more|edit|filter|sort|expand|menu)\b/i;
var UNSAFE_AR_TERMS = ['حذف', 'إزالة', 'أرشفة', 'اعتماد', 'موافقة', 'رفض', 'قبول', 'إرسال', 'حفظ', 'نشر', 'إلغاء', 'تأكيد', 'سحب', 'إعلان', 'تسجيل الخروج'];
var SAFE_AR_TERMS = ['عرض', 'تفاصيل', 'المزيد', 'فتح', 'تعديل', 'تصفية', 'القائمة'];
var UNSAFE_HREF = /(delete|destroy|remove|revoke|accept|approve|reject|decline|publish|cancel|confirm|withdraw|verify|unsubscribe|impersonate|mark-?read|toggle|leave|join|log\s*-?\s*out|sign\s*-?\s*out)|[?&]_method=/i;
// Supplementary unsafe guard on names (the binding UNSAFE_EN only knows "logout" / "sign out").
var UNSAFE_LOGOUT = /log\s*-?\s*out|sign\s*-?\s*out/i;
// Disqualifiers that only block `safe-name` (the element becomes `not-allowlisted`): a
// "View"/"Open" button that names a state change ("Open registration", "Show results").
var SAFE_DISQUALIFY_EN = /\b(close|end|start|launch|finish|complete|lock|unlock|enable|disable|activate|deactivate|assign|invite|join|leave|register|duplicate|restore|move|mark|stage|phase|registration|voting|results|winners)/i;
var SAFE_DISQUALIFY_AR_TERMS = ['إغلاق', 'إنهاء', 'بدء', 'إطلاق', 'تفعيل', 'تعطيل', 'تعيين', 'دعوة', 'انضمام', 'مغادرة', 'تسجيل', 'نقل', 'المرحلة', 'النتائج'];
// Status-tab exception: a [role=tab] or a[href] whose WHOLE name is a past-tense status word (with
// an optional count) is exempt from the unsafe-name check for that name source. Buttons never are.
var STATUS_EN = /^(accepted|approved|rejected|archived|published|cancell?ed|submitted|confirmed|sent|advanced|declined|withdrawn)(\s*\(?\d+\)?)?$/i;
var STATUS_AR_TERMS = ['مقبول', 'مرفوض', 'مؤرشف', 'منشور', 'ملغى', 'معتمد'];

function normalizeText(s) {
  return String(s == null ? '' : s)
    .replace(/[​-‏‪-‮⁦-⁩﻿]/g, '')
    .replace(/[ؐ-ًؚ-ٰٟۖ-ۭ]/g, '')
    .replace(/ـ/g, '')
    .replace(/[آأإٱ]/g, 'ا')
    .replace(/\u0649/g, '\u064A')
    .replace(/\u0629/g, '\u0647')
    .replace(/\s+/g, ' ')
    .trim();
}

function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
var UNSAFE_AR = new RegExp('(' + UNSAFE_AR_TERMS.map(function (t) { return escapeRe(normalizeText(t)); }).join('|') + ')');
function termAlternation(terms) { return terms.map(function (t) { return escapeRe(normalizeText(t)); }).join('|'); }
// Anchored like SAFE_EN: the name must START with a safe term (optional leading ال), then a space or end.
var SAFE_AR = new RegExp('^(?:ال)?(?:' + termAlternation(SAFE_AR_TERMS) + ')(?:\\s|$)');
var SAFE_DISQUALIFY_AR = new RegExp('(' + termAlternation(SAFE_DISQUALIFY_AR_TERMS) + ')');
var STATUS_AR = new RegExp('^(?:ال)?(?:' + termAlternation(STATUS_AR_TERMS) + ')(?:ه|ات|ون|ين)?(\\s*\\(?[0-9\\u0660-\\u0669]+\\)?)?$');

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
  return n !== '' && (UNSAFE_EN.test(n) || UNSAFE_AR.test(n) || UNSAFE_LOGOUT.test(n));
}
// Object allowlist (fix round 2): a safe verb is safe-name only when (a) the name is the bare
// verb with an optional count/chevron, (b) the next word is a detail
// object, or (c) the verb is edit/تعديل. "Open hackathon", "View awards", "فتح التصويت" → not safe.
var SAFE_EDIT_VERBS = ['edit', 'تعديل'];
var SAFE_OBJECTS_EN = ['details', 'more', 'menu', 'profile', 'info', 'information', 'filters', 'options', 'list', 'page', 'all'];
var SAFE_OBJECTS_AR_TERMS = ['التفاصيل', 'القائمة', 'المزيد', 'الملف', 'المعلومات', 'الخيارات', 'الكل', 'الصفحة'];
var BARE_TAIL = /^(?:\(?[0-9\u0660-\u0669]+\)?)?\s*[\u2039\u203A\u00AB\u00BB\u2190-\u2193\u25B4-\u25BF\u2304\u2335<>\u2026.:]*$/i;
var SAFE_VERB_AR = new RegExp('^((?:ال)?(?:' + SAFE_AR_TERMS.map(function (t) { return escapeRe(normalizeText(t)); }).join('|') + '))(?:\\s|$)');

/** safeVerbAndTail(normalizedName) → { verb, tail } or null when no safe verb leads the name. */
function safeVerbAndTail(n) {
  var m = n.match(SAFE_EN);
  if (!m) m = n.match(SAFE_VERB_AR);
  if (!m) return null;
  return { verb: m[1].toLowerCase(), tail: n.slice(m[0].length).trim() };
}

function passesObjectAllowlist(n) {
  var vt = safeVerbAndTail(n);
  if (!vt) return false;
  var verb = vt.verb.replace(/^ال/, '');
  if (SAFE_EDIT_VERBS.indexOf(verb) !== -1 || SAFE_EDIT_VERBS.indexOf(vt.verb) !== -1) return true;
  if (BARE_TAIL.test(vt.tail)) return true;
  var first = vt.tail.split(' ')[0].replace(/[.,:;!?\u060C\u061B\u061F]+$/, '').toLowerCase();
  if (SAFE_OBJECTS_EN.indexOf(first) !== -1) return true;
  return SAFE_OBJECTS_AR_TERMS.map(normalizeText).indexOf(first) !== -1;
}

function isSafeName(s) {
  var n = normalizeText(s);
  if (n === '' || !(SAFE_EN.test(n) || SAFE_AR.test(n))) return false;
  if (SAFE_DISQUALIFY_EN.test(n) || SAFE_DISQUALIFY_AR.test(n)) return false;
  return passesObjectAllowlist(n);
}
function isStatusName(s) {
  var n = normalizeText(s);
  return n !== '' && (STATUS_EN.test(n) || STATUS_AR.test(n));
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
 *   formMethod? (null/absent = not inside a form; '' = inside a form with no method, which is
 *   non-GET — only an explicit "get" counts as GET), selector? }
 * opts: { origin?, denyPatterns? }
 */
function classify(d, opts) {
  opts = opts || {};
  var tag = String(d.tag || '').toLowerCase();
  var type = d.type == null ? '' : String(d.type).toLowerCase();
  var role = String(d.role || '').toLowerCase();
  var inForm = d.formMethod != null;
  var formMethod = inForm ? String(d.formMethod).trim().toLowerCase() : null;
  var isLink = tag === 'a' && d.href != null && d.href !== '';
  var statusExempt = role === 'tab' || isLink;
  var label = accessibleName(d);
  function out(safe, reason) { return { selector: d.selector || '', label: label, safe: safe, reason: reason }; }

  // ---- unsafe: every name source is checked, so an icon's aria-label or a title counts ----
  var names = [d.labelledByText, d.ariaLabel, d.text, d.title, d.value, d.alt];
  for (var i = 0; i < names.length; i++) {
    if (statusExempt && isStatusName(names[i])) continue;
    if (isUnsafeName(names[i])) return out(false, 'unsafe-name');
  }
  var effectiveType = type;
  if (tag === 'button' && !type && inForm) effectiveType = 'submit';
  if ((tag === 'button' || tag === 'input') && (effectiveType === 'submit' || effectiveType === 'image')) return out(false, 'type-submit');
  if ((tag === 'button' || tag === 'input') && effectiveType === 'reset') return out(false, 'type-reset');
  if (inForm && formMethod !== 'get') return out(false, 'inside-non-get-form');
  if (d.dataMethod != null && d.dataMethod !== '' && String(d.dataMethod).toLowerCase() !== 'get') return out(false, 'non-get-method');
  if (d.dataConfirm != null && d.dataConfirm !== false) return out(false, 'data-confirm');

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
  if (form) formMethod = attr('formmethod') || form.getAttribute('method') || '';
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

/**
 * A selector is emitted only when it matches exactly one element; otherwise it is blanked and a
 * would-be-safe entry becomes `ambiguous-selector` (an nth-child path can land on another element
 * after a re-render). Unsafe entries keep their reason.
 */
function requireUniqueSelector(r) {
  var count = 0;
  try { count = r.selector ? document.querySelectorAll(r.selector).length : 0; } catch (e) { count = 0; }
  if (count === 1) return r;
  return { selector: '', label: r.label, safe: false, reason: r.safe ? 'ambiguous-selector' : r.reason };
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
    results.push(requireUniqueSelector(classify(describe(el), o)));
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
       isStatusName: isStatusName,
       passesObjectAllowlist: passesObjectAllowlist,
       SCAN: SCAN,
       pageComponent: pageComponent,
       routeMatchFor: routeMatchFor,
       PAGE_ROUTE_MATCH: PAGE_ROUTE_MATCH,
       UNSAFE_EN: UNSAFE_EN,
       SAFE_EN: SAFE_EN,
       UNSAFE_AR_TERMS: UNSAFE_AR_TERMS,
       SAFE_AR_TERMS: SAFE_AR_TERMS
     }));
