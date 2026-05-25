// Browser-context script: set a value on a React-controlled input/textarea/select.
// Inject via browser_evaluate / browser_run_code_unsafe.
// Usage: pass selector (CSS string or element ref) and value.
// Returns: the element's .value after the events, for caller verification.
(function reactSetInput(selectorOrEl, value) {
  var el = (typeof selectorOrEl === 'string')
    ? document.querySelector(selectorOrEl)
    : selectorOrEl;

  if (!el) {
    throw new Error('reactSetInput: element not found for selector: ' + selectorOrEl);
  }

  var tag = el.tagName.toLowerCase();
  if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') {
    throw new Error('reactSetInput: expected input/textarea/select, got ' + tag);
  }

  // Use the native prototype setter to bypass React's synthetic value tracking.
  var proto = tag === 'select'
    ? window.HTMLSelectElement.prototype
    : (tag === 'textarea' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype);

  var nativeSetter = Object.getOwnPropertyDescriptor(proto, 'value');
  if (nativeSetter && nativeSetter.set) {
    nativeSetter.set.call(el, value);
  } else {
    el.value = value;
  }

  // Dispatch bubbling synthetic-compatible events so React state updates.
  el.dispatchEvent(new Event('input',  { bubbles: true, cancelable: true }));
  el.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));

  return el.value;
})
