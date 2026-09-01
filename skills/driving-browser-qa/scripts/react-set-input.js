// Browser-context script: read back a React-controlled input/textarea/select's
// current value + validity for assertion.
// read-only (ADR-0015): value entry on the act path uses browser_type/browser_fill_form;
// this helper only reads a field back.
// Inject via browser_evaluate.
// Usage: pass selector (CSS string or element ref).
// Returns: { value, validity: { valid, valueMissing, typeMismatch, rangeUnderflow,
//            rangeOverflow, stepMismatch, patternMismatch, badInput } } for the
// element's current state, for caller verification against an intended value.
(function reactReadInput(selectorOrEl) {
  var el = (typeof selectorOrEl === 'string')
    ? document.querySelector(selectorOrEl)
    : selectorOrEl;

  if (!el) {
    throw new Error('reactReadInput: element not found for selector: ' + selectorOrEl);
  }

  var tag = el.tagName.toLowerCase();
  if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') {
    throw new Error('reactReadInput: expected input/textarea/select, got ' + tag);
  }

  var validity = null;
  if (el.validity) {
    validity = {
      valid:            el.validity.valid,
      valueMissing:     el.validity.valueMissing,
      typeMismatch:     el.validity.typeMismatch,
      rangeUnderflow:   el.validity.rangeUnderflow,
      rangeOverflow:    el.validity.rangeOverflow,
      stepMismatch:     el.validity.stepMismatch,
      patternMismatch:  el.validity.patternMismatch,
      badInput:         el.validity.badInput
    };
  }

  return { value: el.value, validity: validity };
})
