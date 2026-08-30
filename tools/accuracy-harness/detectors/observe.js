/*
 * observe.js — the CONSOLIDATED observe-round payload (ADR-0006).
 *
 * Replaces the legacy 6-call per-step loop (snapshot -> act -> wait -> console_messages ->
 * network_requests -> snapshot) with ONE structured `evaluate` call per round. Acts stay separate
 * calls. Injected via the `evaluate` capability (Playwright MCP `browser_evaluate`) — never
 * `browser_run_code_unsafe` (ADR-0009).
 *
 * On first injection it installs buffering interceptors on console.error/warn, window.onerror,
 * fetch, and XMLHttpRequest, so every later observe() returns everything that happened SINCE the
 * previous round without extra MCP calls. It is READ-ONLY: it never issues requests, only observes.
 *
 * Returns JSON: { round, domDigest, console[], network[], ux[], axe }.
 *   - domDigest: compact live-region text + interactive-element inventory (the snapshot substitute)
 *   - console:   buffered errors/warnings since last round (catches bug class: p.map crash, thrown handlers)
 *   - network:   buffered fetch/XHR {method,url,status,ok} since last round (catches 4xx/5xx, wrong route)
 *   - ux:        objective UX detector findings (contrast/overflow/target/name) — see ux-detectors.js
 *   - axe:       axe-core violations summary IF window.axe is present (inject axe.min.js separately)
 *
 * Usage (pass to browser_evaluate as the function body):
 *   return __qaObserve({ digestSelector: 'body', runUx: true });
 */
(function installObserve() {
  if (window.__qaObserveInstalled) return;
  window.__qaObserveInstalled = true;
  var buf = { console: [], network: [], round: 0 };
  window.__qaBuf = buf;

  // --- console + uncaught errors ---
  ['error', 'warn'].forEach(function (level) {
    var orig = console[level].bind(console);
    console[level] = function () {
      try {
        buf.console.push({ level: level, text: Array.prototype.map.call(arguments, String).join(' ').slice(0, 400) });
      } catch (e) { /* never break the app */ }
      return orig.apply(console, arguments);
    };
  });
  window.addEventListener('error', function (e) {
    buf.console.push({ level: 'error', text: (e.message || 'uncaught') + ' @ ' + (e.filename || '') + ':' + (e.lineno || '') });
  });
  window.addEventListener('unhandledrejection', function (e) {
    buf.console.push({ level: 'error', text: 'unhandledrejection: ' + String(e.reason).slice(0, 300) });
  });

  // --- fetch ---
  if (window.fetch) {
    var of = window.fetch;
    window.fetch = function (input, init) {
      var url = (typeof input === 'string') ? input : (input && input.url) || '';
      var method = (init && init.method) || (input && input.method) || 'GET';
      return of.apply(this, arguments).then(function (res) {
        buf.network.push({ method: method, url: String(url).slice(0, 300), status: res.status, ok: res.ok });
        return res;
      }, function (err) {
        buf.network.push({ method: method, url: String(url).slice(0, 300), status: 0, ok: false, error: String(err).slice(0, 200) });
        throw err;
      });
    };
  }

  // --- XHR ---
  var OX = window.XMLHttpRequest;
  if (OX) {
    var op = OX.prototype.open, os = OX.prototype.send;
    OX.prototype.open = function (m, u) { this.__qa = { method: m, url: String(u).slice(0, 300) }; return op.apply(this, arguments); };
    OX.prototype.send = function () {
      var self = this;
      this.addEventListener('loadend', function () {
        if (self.__qa) buf.network.push({ method: self.__qa.method, url: self.__qa.url, status: self.status, ok: self.status >= 200 && self.status < 400 });
      });
      return os.apply(this, arguments);
    };
  }

  // --- the observe function the agent calls each round ---
  window.__qaObserve = function (opts) {
    opts = opts || {};
    buf.round++;
    var root = document.querySelector(opts.digestSelector || 'body') || document.body;

    var interactive = Array.prototype.slice.call(root.querySelectorAll('button, a[href], input, select, [role=button], [role=link]'))
      .slice(0, 80).map(function (el) {
        var r = el.getBoundingClientRect();
        return {
          tag: el.tagName.toLowerCase(),
          testid: el.getAttribute('data-testid') || undefined,
          label: (el.getAttribute('aria-label') || el.value || (el.textContent || '').trim()).slice(0, 40),
          href: el.getAttribute('href') || undefined,
          visible: r.width > 0 && r.height > 0
        };
      });

    var liveText = (root.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 1500);

    var ux = [];
    if (opts.runUx !== false && typeof window.__qaUxDetect === 'function') {
      try { ux = window.__qaUxDetect(); } catch (e) { ux = [{ detector: 'error', message: String(e) }]; }
    }

    var axe = null;
    if (window.axe && typeof window.axe.run === 'function') {
      axe = 'call-axe-run-separately'; // axe.run is async; agent injects axe.min.js + awaits window.axe.run() in its own evaluate
    }

    var payload = {
      round: buf.round,
      domDigest: { liveText: liveText, interactive: interactive },
      console: buf.console.splice(0),   // drain since last round
      network: buf.network.splice(0),   // drain since last round
      ux: ux,
      axe: axe
    };
    return payload;
  };
})();
return (typeof __qaObserve === 'function') ? 'observe-installed' : 'install-failed';
