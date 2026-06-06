# Stack auto-detection & adaptation — design

- **Date:** 2026-06-06
- **Status:** Draft (awaiting review)
- **Repo:** qa-e2e-pilot (the plugin)

## Problem

Today the analyze phase guesses the project's shape with a single bundled
script (`index-routes.sh`) that only recognises `nextjs` / `react-router` /
`generic` on the frontend and `laravel` / `express` / `trpc` on the backend,
using literal-string grepping. On anything else — .NET, Django, FastAPI, Flask,
Hono, Rails, Spring, Go — route discovery silently degrades to a weak
`href=`/`to=` grep, and even on supported stacks it never uses the framework's
own authoritative introspection (e.g. `php artisan route:list`). The result is
non-reproducible, incomplete surface maps: the foundation of the whole "verify
against ground truth" promise is itself an unverified guess.

We want the agent to **detect the language, framework, packages, ORM, auth, and
toolchain of the project under test, and adapt every later phase to it** — for
*any* stack — with deterministic, reproducible results where the framework
offers them, and honest graceful degradation where it doesn't.

## Goals

1. **Deterministic, evidence-based detection** of each component's language,
   framework (+version), key packages, ORM, auth scheme, and dev/test/build
   commands — emitted as a reviewable `stack-profile.json` with per-component
   **confidence** and the **evidence** behind each conclusion.
2. **Adaptation, not just detection.** The profile drives analyze (route
   enumeration), bake (read-back strategy), probe (auth/CSRF convention), and
   preflight (build-id source / dev command).
3. **Zero-code extensibility.** Adding a new stack = add a row to a signatures
   data file + (optionally) a markdown playbook. No edits to the engine.
4. **Graceful degradation, never hard-fail.** An unrecognised stack still runs,
   at lower confidence, via a generic live-navigation path.

## Non-goals

- Running arbitrary `dev`/`test`/`build` commands during detection. Detection
  only ever runs **known side-effect-free introspection** (`route:list`,
  fetching `/openapi.json`) and otherwise reads files. The detected
  `commands.*` are *recorded* for later phases, not executed at detect time.
- Per-stack bespoke source parsers for every framework (rejected — unbounded
  maintenance; we lean on each framework's own introspection or its OpenAPI doc).
- Replacing the existing driver-capability mechanism. This mirrors it.

## Tiered support model

"Supported" has three honest tiers, surfaced in the report:

- **Tier 1 — shipped playbook** (v1: `laravel`, `openapi-generic`): deterministic
  rung-1 enumeration, **high** confidence.
- **Tier 2 — OpenAPI-detected**: *any* backend exposing an OpenAPI/Swagger
  document gets rung-1 ground truth via the `openapi-generic` playbook even
  without a hand-written playbook. One playbook covers a large swath of
  .NET (Swashbuckle), FastAPI, NestJS, Hono (`@hono/zod-openapi`), etc.
- **Tier 3 — unknown**: the `generic` playbook — live browser navigation +
  best-effort static grep, **low** confidence, still produces a report.

## Architecture

A new skill **`detecting-stack-profile`** owns detection. It follows the repo's
existing "engine + data + reference" split:

```
skills/detecting-stack-profile/
  SKILL.md
  scripts/detect-stack.sh          # generic engine; reads manifests, matches signatures, emits JSON
  references/
    stack-signatures.json          # the rules (data, not code) — add a stack by editing this
    playbooks/
      laravel.md                   # Tier 1, full
      openapi-generic.md           # Tier 1/2, full
      generic.md                   # Tier 3 fallback, full
```

### The detection engine (`detect-stack.sh`)

Deterministic, dependency-light (jq → python3 → grep fallback, matching the
repo's other scripts). Steps:

1. **Find components.** Scan the repo root (and any `repos[]` paths from
   `.qa/config.json`) to a bounded depth, skipping `node_modules`, `vendor`,
   `.git`, build dirs. Each discovered manifest is a candidate component:
   `composer.json` (PHP), `package.json` (JS/TS), `*.csproj`/`*.sln` (.NET),
   `pyproject.toml`/`requirements.txt`/`Pipfile` (Python), `go.mod` (Go),
   `Gemfile` (Ruby), `pom.xml`/`build.gradle` (Java), `Cargo.toml` (Rust).
2. **Classify each component** against `stack-signatures.json`: ecosystem →
   language; package signatures → framework (+version from the lockfile);
   framework → `role`, `playbook`, `router.strategy`, `orm` paths, default
   `commands`, `auth.scheme`.
3. **Resolve the router strategy to a concrete rung-1** for that component:
   prefer the framework introspection command if its toolchain is present
   (e.g. `php artisan route:list --json`); else, if an OpenAPI URL is
   configured/derivable, mark `openapi`; else fall to `dsl-grep` / `file-based`
   / `generic`.
4. **Resolve ambiguity / pick primaries** (see below).
5. **Emit `stack-profile.json`** to `.qa/runs/<run-id>/stack-profile.json` with
   evidence + confidence per component.

### `stack-profile.json` schema

```json
{
  "generatedAt": "<ISO-8601>",
  "repoRoot": "<abs path>",
  "components": [
    {
      "role": "backend | frontend | fullstack",
      "path": "<relative path>",
      "language": "php",
      "languageVersion": "8.4",
      "framework": "laravel",
      "frameworkVersion": "12",
      "packages": [{ "name": "laravel/framework", "version": "12.x" }],
      "router": {
        "strategy": "artisan-route-list | openapi | file-based | dsl-grep | generic",
        "rung1": "php artisan route:list --json",
        "openapiUrl": null
      },
      "orm": { "name": "eloquent", "modelsPath": "app/Models", "migrationsPath": "database/migrations" },
      "auth": { "scheme": "session-cookie | bearer | none", "csrf": "laravel-xsrf | null" },
      "commands": { "dev": "composer dev", "test": "composer test", "build": "npm run build" },
      "buildIdSource": "etag | vercel | next | asset-hash | none",
      "playbook": "laravel",
      "confidence": "high | low",
      "evidence": ["composer.json: laravel/framework ^12", "artisan present"]
    }
  ],
  "primary": { "backend": 0, "frontend": 1 },
  "notes": []
}
```

### Component / ambiguity resolution

- A monolith (e.g. Laravel + Inertia/React in one repo) yields one
  `fullstack` component or a `backend` + `frontend` pair from the two manifests;
  both are recorded.
- A monorepo with several backends records all of them; `primary.backend` is
  chosen by, in order: (a) a `.qa/config.json` `repos[]` role hint, (b) the
  component whose routes match the running app's observed network origin
  (`baseUrl`/`apiOrigin`), (c) prompting the user. The choice + reason go in
  `notes[]`.

### The playbook (the "act upon it" layer)

Each playbook is markdown the agent **executes as a recipe** (not loose prose).
Every analysis need is a **fallback ladder**, each rung recording the source +
confidence it produced:

```
Route enumeration (laravel.md):
  1. deterministic:  php artisan route:list --json        ← preferred, ground truth, high confidence
  2. static parse:   grep routes/*.php                     ← if artisan unavailable
  3. live nav:       browse + snapshot                      ← last resort, low confidence
```

Playbook sections (consistent across all): **route enumeration ladder**,
**backend mapping** (endpoint → model → migration), **read-back / baking
strategy**, **probe & auth conventions**, **dev/test/build & build-id**, and
**≥3 mini-evals** drawn from the 14-bug list.

`openapi-generic.md` rung-1 = fetch the OpenAPI doc and treat its `paths` as the
authoritative route list and its schemas as the shape oracle for baking.
`generic.md` rung-1 = live navigation + the existing grep, explicitly low
confidence.

## Pipeline integration

Add detection as the **first action of the Analyze phase**, before
`index-routes.sh`, and run it **unconditionally** (even when a checklist is
supplied and the run skips to Verify) because bake/probe also need the profile.

Consumers of `stack-profile.json`:

| Phase / skill | Uses |
|---|---|
| `analyzing-feature-ui` + `index-routes.sh` | `router.strategy`/`rung1` to enumerate routes (run the command / fetch OpenAPI / else grep); profile supersedes index-routes' built-in detection, which becomes the rung-2 fallback |
| `verifying-backend-persistence` (bake) | `orm.modelsPath`/`migrationsPath` to locate the model + migration to read back and to read column precision |
| `probing-apis-through-browser` | `auth.scheme`/`csrf` to form correct probe requests |
| `driving-browser-qa` / `preflight.sh` | `buildIdSource` and `commands.dev` (recorded, optional) |
| `writing-qa-reports` | surface the tier + confidence so a low-confidence stack is honestly labelled |

## v1 scope

- `detect-stack.sh` (multi-language manifest reader + signature matcher).
- `stack-signatures.json` with **recognition rows** for: laravel, symfony,
  aspnet, django, fastapi, flask, hono, express, nestjs, nextjs, react-router,
  rails, spring, go (gin/chi). Each row maps to one of the three v1 playbooks.
- **Full playbooks:** `laravel.md`, `openapi-generic.md`, `generic.md`.
- Recognition rows for the not-yet-fully-played-back stacks route to
  `openapi-generic` (if an OpenAPI doc is detectable) or `generic`.
- Wire the five consumers above to read the profile.

Dedicated full playbooks for .NET / Django / FastAPI / Hono are **post-v1** —
they already work via `openapi-generic` in v1; a dedicated playbook only adds
the non-OpenAPI rungs (e.g. `manage.py show_urls`, EF migrations precision).

## Testing

- **Unit/smoke (`detect-stack.sh`):** run against fixtures — (a) the Laravel CRM
  → asserts `framework: laravel`, `playbook: laravel`, valid rung-1; (b) a
  minimal FastAPI fixture → `playbook: openapi-generic`; (c) an unrecognised
  repo → `playbook: generic`, `confidence: low`, still valid JSON. Assert valid
  JSON and correct primary selection on a two-backend fixture.
- **Skill mini-evals:** ≥3 in `detecting-stack-profile/SKILL.md` from the bug
  list (e.g. wrong-model mapping that a profile's `orm` path prevents; a stale
  route a deterministic `route:list` includes that grep missed).
- **Existing validation suite still passes:** `bash -n` all `.sh`, `node
  --check` all `.js`, JSON validity, skill bodies < 500 lines.

## Risks & mitigations

- **Monorepo scan cost** → bounded depth; skip `node_modules`/`vendor`/build dirs.
- **Introspection needs the app's toolchain** (php/artisan, python) and could
  have side effects → only run commands on a known side-effect-free allowlist
  (`route:list`, OpenAPI fetch); never run `dev`/`test`/`build` at detect time;
  if the toolchain is absent, drop a rung rather than fail.
- **Wrong framework guess** → confidence + evidence are emitted and the profile
  is reviewable; low confidence is surfaced in the report.

## Open questions (resolved for v1)

- *Where does detection run?* First action of Analyze, unconditional. ✔
- *Which playbooks ship in v1?* `laravel`, `openapi-generic`, `generic`. ✔
- *How is ambiguity resolved?* config hint → origin match → prompt. ✔
