# Stack auto-detection & adaptation — design

- **Date:** 2026-06-06
- **Status:** Approved (grilled; ready for planning)
- **Repo:** qa-e2e-pilot (the plugin)

## Problem

Today the analyze phase guesses the project's shape with a single bundled
script (`index-routes.sh`) that only recognises `nextjs` / `react-router` /
`generic` on the frontend and `laravel` / `express` / `trpc` on the backend,
using literal-string grepping. On anything else — .NET, Django, FastAPI, Flask,
Hono, Rails, Spring, Go — route discovery silently degrades to a weak
`href=`/`to=` grep, and even on supported stacks it never uses the framework's
own authoritative introspection. The result is non-reproducible, incomplete
surface maps: the foundation of the whole "verify against ground truth" promise
is itself an unverified guess. It also assumes a **local repo that matches the
deployed app** — but we must support **testing a running production/remote
target with no local source at all**.

We want the agent to **detect the language, framework, packages, ORM, auth, and
toolchain of the target, and adapt every later phase to it** — for *any* stack,
against *local dev or production*, deterministically where the target offers it,
and with honest graceful degradation where it doesn't.

## Goals

1. **Deterministic, evidence-based detection** of each component's language,
   framework (+version), key packages, ORM, auth scheme, frontend routing model,
   and dev/test/build commands — emitted as a reviewable `stack-profile.json`
   with per-component **`signal`** strength and the **evidence** behind each call.
2. **Adaptation, not just detection.** The profile drives analyze (route
   enumeration), bake (read-back strategy), probe (auth/CSRF), and preflight.
3. **Works against production / remote with no local repo** (black-box mode),
   not just local dev.
4. **Zero-code extensibility.** Adding a stack = add data to `signatures.json`
   (+ optionally a playbook). No engine edits.
5. **Graceful degradation, never hard-fail.** Unrecognised stack still runs at
   `signal: weak` via a generic path.

## Non-goals

- Running arbitrary `dev`/`test`/`build` commands during detection. Detection
  only runs **known side-effect-free introspection** (`route:list`, OpenAPI
  fetch) and otherwise reads files/HTTP. Detected `commands.*` are *recorded*,
  not executed at detect time.
- Per-stack bespoke source parsers for every framework (we lean on each
  framework's own introspection or its OpenAPI doc).
- Replacing the driver-capability mechanism. This mirrors it.

## Vocabulary (added to CONTEXT.md)

The repo's `CONTEXT.md` already defines **`confidence: high | low`** as a
**verdict** attribute. This feature introduces *different* concepts and MUST NOT
overload that word:

- **stack-profile** — the detected, reviewable description of the target's
  stack for a run.
- **playbook** — a per-stack executable recipe (markdown) the agent walks.
- **signal: strong | weak** — how sure *detection* is about the stack.
  **Distinct from verdict `confidence`.** One-way mapping only: a `weak` signal
  (or a missing shape-oracle) *causes* dependent criteria's verdict
  `confidence` to be `low`. Never the reverse; never the same field.
- **runtime fingerprint** (detection from the running app: headers/cookies/HTML)
  vs **code-based detection** (detection from local source manifests).

## Detection sources (dual-source)

Detection has **two sources**, merged with a defined precedence:

1. **Runtime fingerprint — always run; the *only* source against bare prod.**
   Read-only GETs to `baseUrl`: response headers, `Set-Cookie` names, HTML/JS
   markers, and a small OpenAPI probe. Reuses **Wappalyzer-style** patterns
   (see schema). Examples: `laravel_session`/`XSRF-TOKEN`→Laravel;
   `csrftoken`/`sessionid`→Django; `connect.sid`→Express; `JSESSIONID`→Java;
   `X-Powered-By`/`Server`/`X-AspNet-Version` headers; `X-Inertia` header;
   `__NEXT_DATA__`/`/_next/`→Next; `/openapi.json` or
   `/swagger/v1/swagger.json` 200→OpenAPI backend.
2. **Code-based — only when `repos[]` present.** Read manifests:
   `composer.json` (PHP), `package.json` (JS/TS), `*.csproj`/`*.sln` (.NET),
   `pyproject.toml`/`requirements.txt`/`Pipfile` (Python), `go.mod` (Go),
   `Gemfile` (Ruby), `pom.xml`/`build.gradle` (Java), `Cargo.toml` (Rust);
   versions/packages from lockfiles.

**Merge precedence:** for *what is actually running* (framework identity, auth
scheme, live routes/OpenAPI) → trust **runtime**. For the *shape oracle*
(migration precision, NOT-NULL columns) → trust **code**. Record both; on
disagreement (e.g. local says Laravel 12 but runtime fingerprint or build-id
differs) → emit a **drift warning** and downgrade affected `signal`/confidence.

### Three detection modes

- **Local source + matching build** (richest): code + runtime agree, build-id
  matches → `signal: strong`.
- **Source present but build drift**: runtime trusted for live facts, code-based
  facts drift-flagged → mixed signal.
- **Pure black-box prod (no repo)**: runtime-only → `signal: weak` on
  code-derived facts; bake/probe still fully work (pure HTTP read-back);
  **production guardrails auto-engage** (see Production safety).

## Tiered support model

- **Tier 1 — shipped playbook** (v1: `laravel`, `openapi-generic`): deterministic
  rung-1 enumeration, `signal: strong`.
- **Tier 2 — OpenAPI-detected**: any backend exposing OpenAPI/Swagger gets
  rung-1 ground truth via `openapi-generic` even without a hand-written playbook
  (covers much of .NET/FastAPI/NestJS/Hono).
- **Tier 3 — unknown**: `generic` playbook — live nav + best-effort grep,
  `signal: weak`, still produces a report.

## Architecture

New skill **`detecting-stack-profile`**, mirroring the repo's engine/data/
reference split:

```
skills/detecting-stack-profile/
  SKILL.md
  scripts/detect-stack.sh          # generic engine: dual-source detect + merge → JSON
  references/
    stack-signatures.json          # DATA only (Wappalyzer-style + manifest/package sigs)
    playbooks/
      laravel.md                   # Tier 1, full
      openapi-generic.md           # Tier 1/2, full
      generic.md                   # Tier 3 fallback, full
```

### Authority boundary (single source of truth)

- **`detect-stack.sh` is the ONE authoritative detector.** Framework detection
  is **stripped out of `index-routes.sh`**, which is demoted to a profile-driven
  **static-parse rung** (it reads `router.strategy` and does grep/selector scan,
  no longer guesses the framework).
- **`stack-signatures.json` = machine-readable data only** (Wappalyzer-style
  `cookies`/`headers`/`html`/`js`/`implies` patterns with version capture groups
  for the runtime path; `manifest`/`packages` signatures for the code path;
  framework→{playbook, default `router.strategy`, `frontend.routing`, `orm`
  paths, `auth.scheme`, default rung commands}). The **detector reads only
  this**. May seed from Wappalyzer's MIT dataset (credited, like opslane/verify).
- **playbook `.md` = executable recipe only** (fallback ladders, bake/probe
  guidance, mini-evals). The **agent reads only this**.
- **No fact stated twice.** A procedure needing a fact *references the profile
  field* (e.g. `orm.migrationsPath`), never re-states the literal.
  signatures = data; playbook = procedure; profile = resolved instance.

### `stack-profile.json` schema

```json
{
  "generatedAt": "<ISO-8601>",
  "mode": "local-matched | source-drift | black-box",
  "environment": "disposable | production",
  "repoRoot": "<abs path | null>",
  "components": [
    {
      "role": "backend | frontend | fullstack",
      "path": "<relative path | null>",
      "language": "php",
      "languageVersion": "8.4",
      "framework": "laravel",
      "frameworkVersion": "12",
      "packages": [{ "name": "laravel/framework", "version": "12.x" }],
      "router": {
        "strategy": "runtime-openapi | local-cli | static-parse | live-nav",
        "rung1": "GET /openapi.json | php artisan route:list --json | ...",
        "openapiUrl": null
      },
      "frontend": { "routing": "server-bridge | file-based | config-router | black-box" },
      "orm": { "name": "eloquent", "modelsPath": "app/Models", "migrationsPath": "database/migrations" },
      "auth": { "scheme": "session-cookie | bearer | none", "csrf": "laravel-xsrf | null" },
      "commands": { "dev": "composer dev", "test": "composer test", "build": "npm run build" },
      "buildIdSource": "etag | vercel | next | asset-hash | none",
      "playbook": "laravel",
      "signal": "strong | weak",
      "evidence": ["runtime: Set-Cookie laravel_session", "code: composer.json laravel/framework ^12"],
      "drift": [],
      "i18n": {
        "present": true,
        "libraries": ["react-intl"],
        "mechanisms": ["laravel-lang", "js-catalog"],
        "catalogs": [
          { "root": "lang", "locale": "ar", "format": "php", "mechanism": "laravel-lang", "path": "lang/ar/messages.php", "namespace": "messages" }
        ],
        "locales": ["ar", "en"],
        "signal": "strong",
        "evidence": ["code: lang/ar/messages.php"]
      }
    }
  ],
  "primary": { "backend": 0, "frontend": 0 },
  "notes": []
}
```

For a component with no detected translations, `i18n` degrades to
`present: false, libraries: [], mechanisms: [], catalogs: [], locales: [],
signal: "weak", evidence: ["no i18n catalog directory found"]`.

### Route enumeration ladder (runtime-truth first)

Reordered so the rung that describes **the thing under test** is preferred, and
local-source introspection cannot silently lie about a drifted deploy:

```
1. runtime introspection served by baseUrl   (OpenAPI/Swagger at baseUrl)        ← describes the deployed app; strong
2. local CLI introspection                     (artisan route:list, rails routes) ← describes local SOURCE
3. static source parse                          (grep routes/*.php, file-based)
4. live navigation                              (browse + snapshot)
```

**Hard rule:** rung-2 (local CLI) may claim `signal: strong` **only when
preflight confirms `repos[]` matches the running build-id**. On a remote
`baseUrl` whose build ≠ local source, rung-2 output is `signal: weak` and
drift-flagged. Rung-2 also requires a present, side-effect-free toolchain
(`route:list` only); if absent, drop the rung rather than fail.

### Frontend enumeration dispatches on `frontend.routing`

| `frontend.routing` | Page list comes from | Notes |
|---|---|---|
| **server-bridge** (Inertia/Livewire/Hotwire/Django) | **the backend GET routes** | Cross-map each to its page component (`resources/js/pages/<x>.tsx` for Inertia) and its controller/imported components. **Never href-grep.** This is the Inertia fix. |
| **file-based** (Next/Nuxt/SvelteKit/Remix) | route-convention directory | extend existing Next logic |
| **config-router** (React/Vue Router) | router config object | extend existing react-router logic |
| **black-box** (no source) | live-crawl from `baseUrl` | bounded, GET-only, destructive-link-aware (see Production safety); only path needing no source |

### Playbook structure

Each playbook (markdown the agent executes as a recipe): **route enumeration
ladder**, **frontend enumeration** (dispatch on `frontend.routing`), **backend
mapping** (endpoint→model→migration via profile `orm` paths), **read-back /
baking strategy**, **probe & auth conventions** (via `auth`), **dev/test/build &
build-id**, and **≥3 mini-evals** from the 14-bug list. `openapi-generic` rung-1
= fetch the OpenAPI doc, treat `paths` as the route list and schemas as the
shape oracle. `generic` rung-1 = live nav + grep, explicitly `signal: weak`.

## Profile lifecycle & caching (ADR-0005)

- **Authoritative per-run copy** is always written to
  `.qa/runs/<run-id>/stack-profile.json` (evidence for that run; honours
  ADR-0002).
- **Optional project-level cache** at `.qa/stack-profile.cache.json`
  (config-level, git-ignored). At preflight, if present, **revalidate cheaply**
  against recorded build-id + a single homepage fingerprint GET. Match → copy
  into the run dir, skip full detection. Drift → full re-detect + refresh cache.
- **Black-box/prod** still revalidates but **never skips the runtime
  fingerprint** (a prod deploy can change underneath). Code-based facts cache;
  runtime facts get a lightweight re-check.
- This needs **ADR-0005** (a cache feeding run state is a hard-to-reverse
  decision touching ADR-0002's spirit).

## Production safety

When `environment: production` (set explicitly, or inferred from non-localhost
`baseUrl` + no `seedableEnvMarker`):

- **`allowApiWrites` hard-off**, regardless of config. Mutating introspection
  (`artisan` beyond `route:list`, seeding, migrations) refused.
- **Even UI-driven writes require explicit production-write confirmation.**
- **Fingerprint = tiny fixed allowlist, not a scan:** homepage + ≤4 well-known
  paths, single GET each, short timeout, **serialized** (respect
  `maxRequestsPerSecond`). Config `fingerprintPaths`/`noProbePaths`. Never a
  path wordlist.
- **Black-box crawl off by default on non-disposable targets** — requires
  `allowBlackboxCrawl: true`; otherwise only **checklist-named surfaces** are
  verified (never auto-wander prod). When enabled: GET-only, same-origin,
  bounded by `maxDepth`/`maxPages`, and **destructive-link-aware** — skip links
  matching `logout|sign-out|delete|remove|destroy|revoke|cancel|archive` or
  carrying `?_method=`/`data-method`/`data-confirm`; `crawlDenyPatterns` extends.
- **Identity warning:** preflight warns the run uses a real session against real
  data and **recommends a dedicated test account/tenant**; recorded in report.

## Pipeline integration

Run detection as the **first action of Analyze, unconditionally** (bake/probe
need the profile even when a checklist is supplied). Consumers:

| Phase / skill | Uses |
|---|---|
| `analyzing-feature-ui` + `index-routes.sh` | `router.strategy`/`rung1` + `frontend.routing` to enumerate (run command / fetch OpenAPI / dispatch frontend / else grep); profile supersedes index-routes' detection (now rung-3) |
| `verifying-backend-persistence` (bake) | `orm.modelsPath`/`migrationsPath` to locate model + migration + precision |
| `probing-apis-through-browser` | `auth.scheme`/`csrf` to form probe requests |
| `driving-browser-qa` / `preflight.sh` | `buildIdSource`, build-match check, prod warning, `commands.dev` |
| `writing-qa-reports` | surface tier + `signal` + drift so weak/prod runs are honestly labelled |

## Implementation plan (one plan, three sequential slices)

- **Slice A — Detection only (zero behavior change).** `detect-stack.sh`
  (dual-source + merge), `stack-signatures.json` (Wappalyzer-style + manifest
  sigs), profile schema (`signal`, `frontend.routing`, `mode`, `environment`),
  run-dir write + revalidated cache (ADR-0005), `CONTEXT.md` vocab. Deliverable:
  a reviewable `stack-profile.json`; nothing consumes it yet → cannot break
  verify. **Standalone, safely mergeable PR.**
- **Slice B — Adaptation (behavior change).** Strip detection from
  `index-routes.sh`, demote to profile-driven rung with `frontend.routing`
  dispatch (incl. Inertia server-bridge fix); wire bake (`orm`), probe (`auth`),
  preflight (`buildIdSource`), reports (tier/`signal`). Ship 3 playbooks. Depends
  on A.
- **Slice C — Production/black-box hardening.** Prod-mode guardrails, opt-in
  bounded black-box crawl, destructive-link denylist, fingerprint throttling,
  no-repo mode. Depends on B.

## v1 scope

- `detect-stack.sh` (multi-language manifest reader + Wappalyzer-style runtime
  matcher + merge).
- `stack-signatures.json` recognition rows for: laravel, symfony, aspnet,
  django, fastapi, flask, hono, express, nestjs, nextjs, react-router, rails,
  spring, go (gin/chi) — each mapping to one of the three v1 playbooks.
- **Full playbooks:** `laravel.md`, `openapi-generic.md`, `generic.md`.
- Wire the five consumers above.

Dedicated .NET/Django/FastAPI/Hono playbooks are post-v1 (they work via
`openapi-generic` in v1; a dedicated playbook only adds non-OpenAPI rungs).

## Testing

- **Smoke (`detect-stack.sh`):** fixtures — (a) the Laravel CRM → `laravel`,
  strong, valid rung-1; (b) minimal FastAPI → `openapi-generic`; (c)
  unrecognised → `generic`, `weak`, valid JSON; (d) bare prod URL (no repo) →
  runtime-only black-box, prod guardrails engaged; (e) two-backend monorepo →
  correct `primary` selection.
- **Skill mini-evals:** ≥3 in `detecting-stack-profile/SKILL.md` from the bug
  list (e.g. wrong-model mapping a profile `orm` path prevents; a stale route a
  deterministic `route:list`/OpenAPI includes that grep missed; an Inertia page
  href-grep misses but server-bridge enumeration finds).
- **Existing validation suite still passes:** `bash -n` all `.sh`, `node
  --check` all `.js`, JSON validity, skill bodies < 500 lines.

## Risks & mitigations

- **Monorepo scan cost** → bounded depth; skip `node_modules`/`vendor`/build.
- **Introspection needs toolchain / could mutate** → side-effect-free allowlist
  only (`route:list`, OpenAPI fetch); never `dev`/`test`/`build` at detect time;
  absent toolchain → drop a rung, don't fail.
- **Wrong framework guess** → `signal` + `evidence` + `drift` emitted; profile
  reviewable; weak/drift surfaced in report.
- **Prod probing looks like scanning** → capped serialized fingerprint allowlist,
  black-box crawl opt-in + destructive-link-aware.

## Resolved decisions (from grilling)

1. Route ladder reordered: runtime-served truth first; local CLI gated to strong
   only on build-match. ✔
2. Dual-source detection (runtime fingerprint + code-based) with merge
   precedence; black-box/no-repo mode; production write-gate. ✔
3. `signal: strong|weak` (not `confidence`); one-way mapping; CONTEXT.md vocab. ✔
4. `frontend.routing` classification; server-bridge derives from backend routes
   (Inertia fix); black-box live-crawl. ✔
5. One authoritative detector; strip detection from `index-routes.sh`;
   signatures=data / playbook=procedure / profile=instance; Wappalyzer-style
   schema. ✔
6. Run-dir authoritative + revalidated project cache; ADR-0005. ✔
7. Conservative prod-mode; black-box crawl off by default (`allowBlackboxCrawl`);
   destructive-link denylist; test-tenant warning. ✔
8. One plan, three sequential slices A→B→C; A is a no-behavior-change PR. ✔
