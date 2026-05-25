/**
 * backend-probe.js — injected into the browser page context via browser_evaluate.
 *
 * Usage (from SKILL.md step 3):
 *   Copy the function definition into the evaluate call, then invoke:
 *     probe({ url: '/api/trpc/governance.templateList' })
 *     probe({ url: '/api/foo', method: 'POST', body: { x: 1 }, allowWrite: true })
 *
 * Contract:
 *   - GET by default; any mutating method requires explicit allowWrite: true.
 *   - Uses fetch with credentials:'include' so session cookies ride along.
 *   - NEVER echoes Authorization, Cookie, or Set-Cookie header values.
 *   - Returns { ok, status, url, body, durationMs } — nothing else.
 *   - body is truncated to 8 000 chars to stay within agent context limits.
 *   - On network failure returns { ok: false, status: 0, url, body: errorMessage, durationMs }.
 */

async function probe({ url, method = 'GET', body = null, allowWrite = false }) {
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
