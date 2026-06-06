# Playbook — OpenAPI-generic (any backend exposing an OpenAPI/Swagger doc)

Covers FastAPI, ASP.NET (Swashbuckle), NestJS, Spring, Hono (`@hono/zod-openapi`),
and anything else that serves an OpenAPI document. Read fields from the run's
`stack-profile.json` component.

## Route enumeration ladder

1. **runtime introspection served by `baseUrl`** — fetch the OpenAPI doc at
   `router.openapiUrl` (or the candidates in the signature's `openapiPaths`, e.g.
   `/openapi.json`, `/swagger/v1/swagger.json`, `/v3/api-docs`, `/api-json`).
   `paths` = the authoritative route list (method + path + params); component
   schemas = the **shape oracle** for baking. `strong` — it describes the running
   app. This is the preferred rung and usually sufficient.
2. **local CLI** — only if the framework also ships a route lister (rare here);
   otherwise skip.
3. **static parse** — grep the source for the framework's route decorators
   (`@app.get`, `[HttpGet]`, `@Get()`, `app.get(`).
4. **live navigation** — black-box crawl (see below).

## Frontend enumeration — black-box

OpenAPI describes the API, not pages. If a separate frontend component exists in
the profile, use its own playbook/`frontend.routing`. Otherwise treat the UI as
black-box: enumerate surfaces by live-crawl from `baseUrl` (GET-only, same-origin,
bounded, destructive-link-aware — and **off by default on non-disposable
targets** unless `allowBlackboxCrawl`).

## Backend mapping & baking

The OpenAPI schema *is* the shape oracle: for a write to `POST /things`, read the
request/response schema's `required` fields and types. Bake by issuing the
corresponding `GET /things/{id}` (or list) read-back with the session's auth and
reconciling the response against the schema — every `required` field present and
typed, multiplicity 0/1/N. There is no migration to read; the schema replaces it
(so precision bugs below the schema's declared type are lower-confidence here).

## Probe & auth

Use `auth.scheme` from the profile (`bearer` → send the `Authorization` header
captured from the session; `session-cookie` → in-page fetch with credentials).
`auth.csrf` if set.

## Mini-Evals (given → catch)

1. **Route present in `paths`, never linked in UI.** *Given* `GET /admin/export`
   in the OpenAPI doc with no UI entry point. *Catch* rung-1 lists it from
   `paths`, so analyze probes it directly — a UI-only crawl would never reach it.
2. **Schema `required` field bakes NULL.** *Given* `POST /orders` whose response
   schema marks `total` required. *Catch* the bake read-back reconciles against the
   schema and flags a returned `total: null` as a fail @ service.
3. **Doc disabled in prod.** *Given* a production target with Swagger turned off
   (404 on `/openapi.json`). *Catch* the ladder drops to static-parse/live-nav and
   marks `signal: weak`, rather than asserting an empty route list as truth.
