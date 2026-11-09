/*
 * form-inventory.js — read-only inventory of the forms on the current page and their
 * client-side constraints, for the census (feeds the generated input-validation criteria).
 *
 * Injected via the `evaluate` capability (Playwright MCP `browser_evaluate`) — NEVER
 * `browser_run_code_unsafe`. It reads attributes only: it never focuses, types into, or
 * submits a field.
 *
 * Returns: [{ formId, action, method, fields: [{ name, type, required, maxLength, min, max, pattern }] }]
 *   - formId:  the form's id, else its name, else `form[<index>]`
 *   - action:  the `action` attribute, else the current path; method upper-cased, null when the attribute is absent (script-submitted forms are not assumed GET)
 *   - fields:  user-editable controls only (hidden/submit/button/reset/image inputs excluded);
 *              `type` is the input type (default `text`), or `select` / `textarea`;
 *              `required` is the `required` attribute or `aria-required="true"`;
 *              `maxLength` is a number or null; `min`/`max` are numbers for number/range
 *              inputs and the raw attribute string otherwise (dates); `pattern` raw or null.
 *   - controls outside any <form> (common in SPAs) are grouped into one pseudo-form
 *     `{ formId: "page", action: null, method: null, fields }`, emitted only when non-empty.
 */

// ===== Pure, DOM-free cores =====
var EXCLUDED_INPUT_TYPES = ['hidden', 'submit', 'button', 'reset', 'image'];
var NUMERIC_TYPES = ['number', 'range'];

function nullIfEmpty(v) { return v == null || String(v) === '' ? null : String(v); }

function fieldType(f) {
  var tag = String(f.tag || 'input').toLowerCase();
  if (tag === 'select') return 'select';
  if (tag === 'textarea') return 'textarea';
  return f.type ? String(f.type).toLowerCase() : 'text';
}

function bound(v, type) {
  var s = nullIfEmpty(v);
  if (s === null) return null;
  if (NUMERIC_TYPES.indexOf(type) !== -1) {
    var n = Number(s);
    return isFinite(n) ? n : s;
  }
  return s;
}

/** inventoryField(descriptor) → field object, or null when the control is not user-editable. */
function inventoryField(f) {
  var type = fieldType(f);
  if (EXCLUDED_INPUT_TYPES.indexOf(type) !== -1) return null;
  var ml = parseInt(f.maxLength, 10);
  return {
    name: nullIfEmpty(f.name) || nullIfEmpty(f.id) || nullIfEmpty(f.ariaLabel) || nullIfEmpty(f.placeholder),
    type: type,
    required: f.required === true || f.required === '' || String(f.ariaRequired) === 'true',
    maxLength: isFinite(ml) && ml >= 0 ? ml : null,
    min: bound(f.min, type),
    max: bound(f.max, type),
    pattern: nullIfEmpty(f.pattern)
  };
}

/**
 * inventoryForm(descriptor) → { formId, action, method, fields }
 * descriptor: { id?, name?, index?, action?, method?, fields: [{ tag, name?, id?, type?, required?,
 *   ariaRequired?, maxLength?, min?, max?, pattern?, ariaLabel?, placeholder? }] }
 */
function inventoryForm(d) {
  var fields = (d.fields || []).map(inventoryField).filter(function (x) { return x !== null; });
  return {
    formId: nullIfEmpty(d.id) || nullIfEmpty(d.name) || ('form[' + (d.index || 0) + ']'),
    action: nullIfEmpty(d.action),
    method: d.method ? String(d.method).toUpperCase() : null,
    fields: fields
  };
}

// ===== In-page walk =====
var CONTROL_SELECTOR = 'input, select, textarea';

function describeControl(el) {
  var attr = function (n) { return el.getAttribute(n); };
  return {
    tag: el.tagName.toLowerCase(),
    name: attr('name'),
    id: attr('id'),
    type: attr('type'),
    required: el.hasAttribute('required'),
    ariaRequired: attr('aria-required'),
    maxLength: attr('maxlength'),
    min: attr('min'),
    max: attr('max'),
    pattern: attr('pattern'),
    ariaLabel: attr('aria-label'),
    placeholder: attr('placeholder')
  };
}

function INVENTORY() {
  var forms = Array.prototype.slice.call(document.querySelectorAll('form'));
  var out = forms.map(function (form, i) {
    return inventoryForm({
      id: form.getAttribute('id'),
      name: form.getAttribute('name'),
      index: i,
      action: form.getAttribute('action') || window.location.pathname,
      method: form.getAttribute('method'),
      fields: Array.prototype.slice.call(form.querySelectorAll(CONTROL_SELECTOR)).map(describeControl)
    });
  });
  var orphans = Array.prototype.slice.call(document.querySelectorAll(CONTROL_SELECTOR)).filter(function (el) {
    return !el.form && !(el.closest && el.closest('form'));
  });
  var pageFields = orphans.map(describeControl).map(inventoryField).filter(function (x) { return x !== null; });
  if (pageFields.length) out.push({ formId: 'page', action: null, method: null, fields: pageFields });
  return out;
}

// ===== Dual entry point =====
typeof document !== 'undefined'
  ? INVENTORY()
  : (typeof module !== 'undefined' && module.exports &&
     (module.exports = {
       inventoryForm: inventoryForm,
       inventoryField: inventoryField,
       INVENTORY: INVENTORY
     }));
