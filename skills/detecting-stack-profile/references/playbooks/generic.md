# Playbook — Generic (unknown / unsupported stack)

The honest fallback. No deterministic introspection is assumed; everything is
`signal: weak` and the report says so. Read fields from the profile where present.

## Route enumeration ladder

1. **runtime introspection** — try a small set of well-known doc paths anyway
   (`/openapi.json`, `/swagger/v1/swagger.json`); if one returns 200, switch to
   the openapi-generic playbook instead.
2. **local CLI** — none assumed.
3. **static parse** — best-effort grep of the source for literal route strings
   (`href=`, `to=`, framework route DSLs). Lossy; explicitly `weak`.
4. **live navigation** — the primary path here: browse from `baseUrl`, snapshot,
   and follow same-origin in-app links.

## Frontend enumeration — black-box live-crawl

The only enumeration available without source. **Off by default on non-disposable
targets** (requires `allowBlackboxCrawl: true`); otherwise verify only the
checklist-named surfaces.

When enabled:
- GET-only, same-origin, bounded by `maxDepth` / `maxPages`.
- **Destructive-link-aware** — skip any link whose text/href/attrs match
  `logout|sign-out|delete|remove|destroy|revoke|cancel|archive` or that carry
  `?_method=`, `data-method`, or `data-confirm`. Extend via `crawlDenyPatterns`.
- Throttle to `maxRequestsPerSecond`.

## Backend mapping & baking

No ORM/migration oracle. Bake by UI read-back only: navigate away and back to the
list/detail VIEW, snapshot, and confirm the entity is present at the right count.
Shape checks are limited to what the UI/API response exposes. Numeric recompute is
`confidence: low` (no spec/schema oracle) unless the checklist supplies one.

## Probe & auth

`auth.scheme` is usually `none`/unknown — read existing network traffic
(`browser_network_requests`) for the truth; only attempt an in-page fetch if
same-origin is confirmed at preflight.

## Mini-Evals (given → catch)

1. **Unknown stack still runs.** *Given* a framework with no signature row.
   *Catch* the profile is `generic`/`weak`; live-crawl + UI read-back still
   produce a report instead of aborting.
2. **Destructive GET avoided.** *Given* a crawl that encounters
   `<a href="/items/5/delete">`. *Catch* the destructive-link denylist skips it —
   the crawl never mutates state.
3. **OpenAPI discovered late.** *Given* a "generic" target that actually serves
   `/openapi.json`. *Catch* rung-1's probe finds it and promotes the run to the
   openapi-generic playbook, recovering deterministic routes.
