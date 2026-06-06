# Playbook — Laravel (incl. Inertia / Livewire server-bridge)

Executable recipe. Read fields from the run's `stack-profile.json` component;
never hard-code paths the profile already carries (`orm.*`, `router.*`, `auth.*`).

## Route enumeration ladder

Walk in order; record the rung + `signal` that produced the list.

1. **runtime introspection served by `baseUrl`** — only if the app exposes an
   OpenAPI/JSON route doc (rare for vanilla Laravel; common with Scramble/
   L5-Swagger). If `router.openapiUrl` is set, fetch it; `paths` = routes; `strong`.
2. **local CLI** — `php artisan route:list --json` from the backend repo. Parse
   to `{method, uri, name, action}`. **`strong` only when preflight confirms the
   running build matches `repos[]`**; on a remote/prod `baseUrl` with a build
   mismatch, mark the list `signal: weak` and add a `drift` note. Requires a
   bootable local toolchain; if `artisan` is absent or errors, drop this rung.
3. **static parse** — grep `routes/*.php` for `Route::(get|post|put|patch|delete|
   apiResource|resource)` and `->name(...)`. Lossy (route groups, model binding).
4. **live navigation** — browse from `baseUrl`, snapshot, follow same-origin links.

## Frontend enumeration — server-bridge

Laravel renders pages server-side (Inertia `Inertia::render('pages/x')`, Livewire,
or Blade). **The frontend surface list IS the backend GET-route list** — do NOT
href-grep.

- Take the GET routes from the ladder above.
- For Inertia: map each GET route → its controller → the `Inertia::render('<comp>')`
  string → the page component file under the frontend pages dir (e.g.
  `resources/js/pages/<comp>.tsx`). Record route → page component → imported
  child components (static import scan) for the "related components" map.
- For Livewire/Blade: map the route → the view/component it returns.

## Backend mapping (endpoint → model → migration)

For each writing action, locate the controller method, the Eloquent model it
touches, and the migration that defines the table. Use `orm.modelsPath`
(`app/Models`) and `orm.migrationsPath` (`database/migrations`) from the profile.
Read the migration for required/NOT-NULL columns, enums, and `decimal(p,s)` scale
— these feed the bake oracle (the sub-cent precision bug class).

## Baking (read-back)

Read persisted state back via the live app (never the DB directly):
- navigate to the list/detail VIEW and snapshot (forces a fresh GET), or
- read the GET response body, or
- in-page authenticated `fetch()` with session cookies (READ-ONLY).
Confirm shape (every NOT-NULL column non-null per the migration) and multiplicity
0/1/N. Hand numeric recompute to verifying-computed-logic.

## Probe & auth

`auth.scheme: session-cookie`, `auth.csrf: laravel-xsrf`. For any in-page write
probe (gated), send the `X-XSRF-TOKEN` header read from the `XSRF-TOKEN` cookie;
Laravel returns 419 on a missing/mismatched token. Same-origin in-page fetch
carries `laravel_session` automatically with `credentials:'include'`.

## Commands / build-id

`commands.dev = composer dev`. Build-id: Laravel has no native build hash; use the
Vite manifest hash (`/build/manifest.json`) or an ETag as the freshness signal at
preflight.

## Mini-Evals (given → catch)

1. **Inertia route grep misses.** *Given* nav via Wayfinder `edit().url`. *Catch*
   server-bridge enumeration lists the GET route from `artisan route:list` and
   maps it to `resources/js/pages/...`, finding the page the href-grep missed.
2. **decimal precision.** *Given* `amount = shares × price` stored in a
   `decimal(_,2)` column. *Catch* reading `orm.migrationsPath` reveals the scale,
   so the bake oracle flags `4,000,000 × $0.001` truncation that a UI read accepts.
3. **419 masked as generic error.** *Given* a write that toasts "Something went
   wrong". *Catch* knowing `auth.csrf: laravel-xsrf`, probe with `X-XSRF-TOKEN`;
   a 419 vs a real 422 localizes the suspected layer (FE token wiring vs service).
4. **Build drift on staging.** *Given* `baseUrl` is staging on an older build than
   local source. *Catch* the ladder downgrades the local `route:list` rung to
   `weak` + drift, so a "missing route" finding isn't blamed on the deployed app.
