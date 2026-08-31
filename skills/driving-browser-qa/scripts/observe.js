/*
 * observe.js — the CONSOLIDATED observe-round payload (ADR-0006).
 *
 * Replaces the legacy 6-call per-step loop (snapshot -> act -> wait -> console_messages ->
 * network_requests -> snapshot) with ONE structured `evaluate` call per round. Acts stay separate
 * calls; waits stay separate calls. Injected via the `evaluate` capability (Playwright MCP
 * `browser_evaluate`) — never `browser_run_code_unsafe`.
 *
 * On first injection it installs read-only buffering interceptors on console.error/warn,
 * window.onerror, unhandledrejection, fetch, and XMLHttpRequest, so every later observe() returns
 * everything that happened SINCE the previous round without extra MCP calls. It never issues a
 * request itself — it only observes.
 *
 * SELF-HEALING ACROSS NAVIGATION: a full-page navigation/reload/redirect gives the document a
 * fresh `window`, so the interceptors installed on the PREVIOUS document are gone —
 * `window.__qaObserve` is undefined on the new document even though this same script was injected
 * before. This file's entry point checks for that and re-runs the installer before calling
 * __qaObserve, so a round on a freshly-navigated document re-installs instead of throwing. The
 * installer itself stays idempotent (`window.__qaObserveInstalled` guard), so re-running it on a
 * document where it already ran (e.g. re-injecting mid-session) is a safe no-op. This does NOT
 * recover console/network activity that happened DURING the load itself, before any interceptor
 * could attach — that load-window evidence must come from the driver-backed
 * browser_console_messages / browser_network_requests calls (see SKILL.md's Observe-Round section).
 *
 * Returns JSON: { round, domDigest, console[], network[], ux[], axe }.
 *   - domDigest: compact live-region text + interactive-element inventory (the snapshot substitute
 *     for identifying what to act on next — data-testid/label/href, not a Playwright ref; use it to
 *     build a selector, e.g. `[data-testid="…"]`, for the next act call's `target`)
 *   - console:   buffered errors/warnings since last round (catches bug class: p.map crash, thrown
 *     handlers) — this is diagnostic evidence, not optional decoration; read it every round
 *   - network:   buffered fetch/XHR {method,url,status,ok} since last round (catches 4xx/5xx, wrong
 *     route). For a response BODY, or traffic that happened before this script was installed, fall
 *     back to the separate browser_network_request / browser_network_requests capability — the
 *     observe-round consolidates the *redundant* per-step reads, it does not replace a targeted
 *     deeper read a step genuinely needs (no-evidence-regression guard, see SKILL.md).
 *   - ux:        objective UX detector findings IF window.__qaUxDetect has been wired up separately
 *     (e.g. by injecting detecting-visual-ux/scripts/ux-detectors.js and exposing its result as that
 *     global) — empty otherwise. The visual-UX criterion may still run ux-detectors.js as its own
 *     dedicated evaluate call; that call is outside the observe-round's per-step budget.
 *   - axe:       axe-core violations summary IF window.axe is present (inject axe.min.js separately)
 *
 * Usage (pass this WHOLE file to browser_evaluate as the function body, every round — including
 * the first observe after any navigation): the tail below installs-if-needed and then calls
 * __qaObserve() itself, so a single evaluate call is both the self-heal check and the round read.
 *   ... (this file's own source) ...
 *   // returns { round, domDigest, console[], network[], ux[], axe }
 *
 * If you already know the current document has the interceptors installed (no navigation since
 * the last round) a lighter, cheaper snippet also works: `return __qaObserve({ digestSelector:
 * 'body', runUx: true });` — but after ANY full-page navigation/reload/redirect, re-inject this
 * whole file (or use the self-healing tail below) instead, since that lighter snippet throws
 * `__qaObserve is not defined` on a document it was never installed on.
 */
function installObserve() {
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
}

// --- self-healing round entry point ---
// A full-page navigation/reload/redirect replaces `window`, so a previously-installed
// __qaObserve is gone on the new document even though this exact script ran before. Re-install
// (idempotent, cheap no-op if already present) BEFORE invoking, so a round called on a
// freshly-navigated document self-heals instead of throwing "__qaObserve is not defined".
if (typeof window.__qaObserve !== 'function') {
  installObserve();
}
return (typeof window.__qaObserve === 'function')
  ? window.__qaObserve({ digestSelector: 'body', runUx: true })
  : 'install-failed';
