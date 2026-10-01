/**
 * backend-probe.js — injected into the browser page context via browser_evaluate.
 *
 * Usage (from SKILL.md step 3):
 *   Copy the function definition into the evaluate call, then invoke:
 *     probe({ url: '/api/trpc/governance.templateList' })
 *
 *   THE SANCTIONED RECORDED WRITE PROBE (0.9.0, ADR-0027) — the only mutating
 *   browser_evaluate the block-hook admits, and only when .qa/config.json has
 *   allowApiWrites:true + a disposable seedableEnvMarker + environment !=
 *   production. The payload must be THIS FILE, verbatim, followed by exactly
 *   one call whose argument is strict JSON (double-quoted keys, no
 *   expressions) and whose url is same-origin relative:
 *     return await probe({"url": "/api/foo", "method": "<one of POST|PUT|PATCH|DELETE>", "body": {"x": 1}, "allowWrite": true, "csrf": "laravel-xsrf"});
 *   (Keep this file free of a literal quoted write method: the block-hook's
 *   classifier must judge this source alone as read-only.)
 *   The capture hook records it like any other call; qa-verify binds the
 *   criterion's probe evidence to it by --source-ref seq:<N>.
 *
 * Contract:
 *   - GET by default; any mutating method requires explicit allowWrite: true.
 *   - csrf: 'laravel-xsrf' sends X-XSRF-TOKEN from the XSRF-TOKEN cookie;
 *     csrf: 'meta' sends X-CSRF-TOKEN from <meta name="csrf-token">. The
 *     token is sent, never returned.
 *   - Uses fetch with credentials:'include' so session cookies ride along.
 *   - NEVER echoes Authorization, Cookie, or Set-Cookie header values.
 *   - Returns { ok, status, url, body, durationMs } — nothing else.
 *   - body is truncated to 8 000 chars to stay within agent context limits.
 *   - On network failure returns { ok: false, status: 0, url, body: errorMessage, durationMs }.
 */

async function probe({ url, method = 'GET', body = null, allowWrite = false, csrf = null }) {
  const SAFE_METHODS = ['GET', 'HEAD', 'OPTIONS'];
  const norm = method.toUpperCase();

  if (!SAFE_METHODS.includes(norm) && !allowWrite) {
    return {
      ok: false,
      status: 0,
      url,
      body: '[probe] Write refused: pass allowWrite:true to enable mutating requests.',
      durationMs: 0,
    };
  }

  const MAX_BODY = 8000;
  const t0 = performance.now();

  try {
    const init = {
      method: norm,
      credentials: 'include',
      headers: { 'Accept': 'application/json' },
    };

    if (body !== null && !SAFE_METHODS.includes(norm)) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }

    if (!SAFE_METHODS.includes(norm) && csrf === 'laravel-xsrf') {
      const m = document.cookie.match(/(?:^|;\s*)XSRF-TOKEN=([^;]+)/);
      if (m) init.headers['X-XSRF-TOKEN'] = decodeURIComponent(m[1]);
    } else if (!SAFE_METHODS.includes(norm) && csrf === 'meta') {
      const el = document.querySelector('meta[name="csrf-token"]');
      if (el) init.headers['X-CSRF-TOKEN'] = el.getAttribute('content');
    }

    const res = await fetch(url, init);
    const durationMs = Math.round(performance.now() - t0);

    // Read the body as text first so we can truncate safely.
    const raw = await res.text();
    const truncated = raw.length > MAX_BODY
      ? raw.slice(0, MAX_BODY) + `\n[truncated – original length ${raw.length}]`
      : raw;

    // Try to parse as JSON for easier inspection; fall back to plain text.
    let parsed;
    try {
      parsed = JSON.parse(truncated);
    } catch (_) {
      parsed = truncated;
    }

    return {
      ok: res.ok,
      status: res.status,
      method: norm,
      url: res.url,       // actual URL after any redirects
      body: parsed,
      durationMs,
    };
  } catch (err) {
    const durationMs = Math.round(performance.now() - t0);
    return {
      ok: false,
      status: 0,
      url,
      body: `[probe] fetch error: ${err.message}`,
      durationMs,
    };
  }
}
