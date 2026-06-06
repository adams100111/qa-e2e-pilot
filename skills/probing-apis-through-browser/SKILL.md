---
name: probing-apis-through-browser
description: Use when the UI masks a real error (generic toast, blank state, spinner, or optimistic update) and you need the ground truth from the backend. Injects an authenticated fetch into the live page context or reads existing network traffic to surface real HTTP status codes, response bodies, and actual request URLs — without ever printing secrets or writing to the backend unless explicitly allowed.
---

# Probing APIs Through the Browser

## Overview

The UI lies. A toast says "Something went wrong." A list renders blank. A wizard step silently disappears. The real error — 400 validation envelope, 500 with an enum mismatch, a path typo, a 201 whose body carries no id — lives in the network response body.

This skill gets that truth. It reads existing traffic first, falls back to an authenticated in-page fetch if a fresh read is needed, and gates any write behind two explicit config flags. Secrets are never printed.

**Vocabulary used here:**
- **Criterion**: the end-to-end behavior under test.
- **Probing**: going under a lying UI to read the truth — network response body or API read-back with the session's cookies.
- **Session**: the isolated browser context whose storageState (cookies, localStorage) carries the authenticated identity.
- **allowApiWrites / seedableEnvMarker**: the two config flags in `.qa/config.json` that must both be true before any write is issued.
- **auth scheme**: read `auth.scheme` / `auth.csrf` from the run's `stack-profile.json` to form requests correctly — `session-cookie` (in-page fetch carries cookies with `credentials:'include'`; for `csrf: laravel-xsrf` send `X-XSRF-TOKEN` from the `XSRF-TOKEN` cookie), or `bearer` (send the `Authorization` header captured from the session). In **production** mode, writes are hard-off regardless of the flags above.

---

## When to Probe

Probe only when the UI masks an error and you cannot determine verdict from the visible page.

Trigger conditions:
- [ ] A toast fires but carries no actionable detail ("Something went wrong", "Error", "Failed").
- [ ] A list, table, or panel renders blank or with a spinner that never resolves.
- [ ] An action appears to succeed (optimistic update, green toast) but the subsequent state is wrong.
- [ ] A wizard step transitions or submits and the next step is wrong or missing.
- [ ] You need to confirm what URL was actually called (path mismatch suspect).
- [ ] A 2xx response looks fine but the returned body does not contain an expected field (e.g., a missing id).

Do NOT probe speculatively. Always attempt to read existing network traffic before issuing any new request.

---

## The Probing Checklist

### Step 1 — Pre-flight: confirm cross-origin capability

Before issuing any fresh request from the page context, check whether same-origin probing is possible.

- [ ] Compare `baseUrl` in `.qa/config.json` with the page's current origin (`window.location.origin`).
- [ ] If they match: same-origin fetch with `credentials:'include'` will carry cookies. Proceed to step 3 if a fresh read is needed.
- [ ] If they differ (cross-origin): the session cookies will NOT ride on a fetch from page context. **Fall back to the network tab** (step 2) and do not attempt an in-page fetch.

Cross-origin capability must be **detected**, never assumed.

---

### Step 2 — Read existing network traffic (default path)

Use **browser_network_requests** (list) to find the failing call, then **browser_network_request** (read one body) to get the full truth.

```
1. Call browser_network_requests — list all captured requests.
2. Identify the call of interest by URL pattern, method, and/or status code.
3. Call browser_network_request with that request's id to read:
     - actual URL (catches path mismatches, e.g. /init vs /initialize)
     - HTTP status
     - response body (full JSON envelope, validation errors, enum lists)
4. Record { status, url, body } in the criterion's trace.
```

This step alone resolves most lying-UI bugs:

| Bug | What the UI showed | What the network body showed |
|-----|-------------------|------------------------------|
| #1 templates list crashed | Blank list / no error | API returned wrong envelope shape; `p.map` failed client-side |
| #2 Overview 500 | Generic error page | Response body carried the real enum mismatch message |
| #4–#6, #10 wizard 400/422/500 | Toast or silent fail | True validation envelope with field-level errors |
| #5 path mismatch | Wizard step missing | Actual URL in request was `/init`, route expected `/initialize` |
| #11 setupId missing after 201 | Green toast, next step broken | 201 body lacked the `setupId` field the client expected |

Stop here if the body gives you enough to write the verdict. Only continue to step 3 if you need a fresh, authenticated read (e.g., to confirm persisted state after a mutation).

---

### Step 3 — Authenticated read-back via in-page fetch (same-origin only)

Use this when you need a fresh API call that carries the session's cookies — for example, to confirm what the server actually persisted after a mutation appeared to succeed.

Prerequisites:
- [ ] Pre-flight (step 1) confirmed same-origin capability.
- [ ] The call is a **read** (GET/HEAD). If you need a write, go to step 4.

**Inject backend-probe.js into the page:**

1. Copy the full contents of `scripts/backend-probe.js` from this skill directory.
2. Append an invocation line:
   ```js
   return await probe({ url: '/api/trpc/governance.templateList' });
   ```
3. Pass the combined text to **browser_evaluate** (or **browser_run_code_unsafe** if evaluate is unavailable).
4. Capture the returned object: `{ ok, status, url, body, durationMs }`.

The script uses `credentials:'include'` so the existing session cookies authenticate the call automatically. It refuses any non-GET unless `allowWrite:true` is explicitly passed. It strips auth headers from anything it echoes and truncates body to 8 000 chars.

**Interpreting the result:**

| Field | Use |
|-------|-----|
| `ok` | `false` means the server returned 4xx/5xx |
| `status` | Exact HTTP status code |
| `url` | Actual URL after redirects — catches path mismatches |
| `body` | Parsed JSON or raw text — the real error envelope |
| `durationMs` | Sanity-check for timeouts |

If `body` is `[probe] fetch error: …`, the fetch itself failed (network error, CORS block). Fall back to the network tab.

---

### Step 4 — Gated writes (seed / mutate)

Direct API writes are opt-in and doubly gated. You may only issue a write if **both** conditions are true:

- [ ] `allowApiWrites` is `true` in `.qa/config.json`.
- [ ] `seedableEnvMarker` resolves to a live, disposable environment (the marker key/value must be present in the config and must match what the running backend advertises).

If either condition is missing:
- Set the criterion verdict to **blocked**.
- Record the reason: "Write needed but allowApiWrites is off" or "seedableEnvMarker not present — refusing to write to an unknown environment."
- Do NOT seed on a hunch. Do NOT infer the environment is disposable.

When both gates are clear and `allowWrite:true` is passed:
```js
return await probe({
  url: '/api/governance/seed-template',
  method: 'POST',
  body: { name: 'test-fixture' },
  allowWrite: true,   // explicit — required
});
```

---

### Step 5 — Record and never print secrets

After probing:

- [ ] Record `{ status, url, body }` in the criterion trace / bug log.
- [ ] **Never** include the value of Authorization headers, Cookie strings, or Set-Cookie values in any output, report, or log.
- [ ] The `probe()` function strips these automatically; do not add workarounds that re-expose them.
- [ ] If a body contains a token or secret (e.g., a seed response includes an API key), redact it in the recorded output before logging: replace with `[REDACTED]`.

---

## Verdict Mapping

| Observed outcome | Verdict |
|-----------------|---------|
| Network body confirms feature works as specified | pass |
| Network body shows a real server error | fail (with body excerpt in trace) |
| Write needed but allowApiWrites/seedableEnvMarker absent | blocked |
| Cross-origin — cannot read fresh body; existing traffic insufficient | deferred |
| probe() throws or evaluate tool unavailable | error |

---

## Mini-Evals

These are concrete "given X → catch Y" cases drawn from the real governance module QA session.

### Mini-eval 1 — Wrong envelope shape crashes the list (Bug #1)

**Given:** The templates list renders blank. The UI shows no error.

**Probe:** Call `browser_network_requests`, find the tRPC `templateList` call. Call `browser_network_request` on it.

**Catch:** The response body is `{ result: { data: [...] } }` but the client code expected `{ items: [...] }` and called `.map` on `undefined`. Status was 200, making the toast suppress. The body reveals the shape mismatch immediately.

**Verdict:** fail — client shape assumption wrong; no UI feedback surfaced the real cause.

---

### Mini-eval 2 — Out-of-enum role crashes Overview (Bug #2)

**Given:** The Overview panel returns a 500. The page shows a generic error boundary.

**Probe:** `browser_network_request` on the failing `/api/governance/overview` call.

**Catch:** Body: `{ error: { code: 'BAD_INPUT', message: 'role must be one of [owner, admin, member]', received: 'superAdmin' } }`. The UI never surfaced the enum list. The network body names the allowed values and the bad value in one read.

**Verdict:** fail — backend rejects a role value the FE sends; body gives the exact enum for the bug report.

---

### Mini-eval 3 — 201 response hides missing setupId (Bug #11)

**Given:** The wizard completes with a green toast ("Template created"). The next wizard step fails silently.

**Probe step A:** `browser_network_request` on the POST that returned 201.

**Catch (step A):** Body is `{ ok: true }` — the `setupId` field the client expected is absent. Status 201 misled the client into proceeding.

**Probe step B (if needed):** Inject `backend-probe.js` and GET the newly created resource by slug to confirm the server state.

**Catch (step B):** The server resource exists but has no `setupId` field — the backend omitted it from the creation response.

**Verdict:** fail — API contract gap; 201 body incomplete; downstream step receives `undefined` for `setupId`.

---

### Mini-eval 4 — Path mismatch: `/init` vs `/initialize` (Bug #5)

**Given:** A wizard step submits; the network shows a 404. The UI toasts "Failed to initialize."

**Probe:** `browser_network_request` — read the `url` field of the 404 request.

**Catch:** Actual URL is `/api/governance/templates/init`. The backend route is registered at `/initialize`. The path difference is one word; only the `url` field in the network response reveals it without inspecting client source.

**Verdict:** fail — client calls the wrong path; fix is a one-line constant change.

---

## Reference

- `scripts/backend-probe.js` — inject via browser_evaluate; returns `{ ok, status, url, body, durationMs }`; refuses non-GET without `allowWrite:true`; strips auth headers.
- Browser tools used: **browser_network_requests** (list captured traffic), **browser_network_request** (read one response body), **browser_evaluate** / **browser_run_code_unsafe** (inject probe script).
- Config flags: `allowApiWrites`, `seedableEnvMarker` — both required for any write; see `.qa/config.json` (ADR-0004).
