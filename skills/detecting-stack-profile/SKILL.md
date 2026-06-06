---
name: detecting-stack-profile
description: Use at the very start of a Run (first action of Analyze, before index-routes or any criterion) to detect the target's language, framework, packages, ORM, auth scheme, and frontend routing model — from local source AND/OR the running app — and emit a reviewable stack-profile.json that every later phase adapts to. Works against local dev or a bare production URL with no repo (black-box). Picks a per-stack playbook; degrades to a generic, signal:weak profile rather than failing on unknown stacks.
---

# Detecting the Stack Profile

## Overview

Before analyzing surfaces or verifying anything, detect *what you are testing* so
every later phase adapts to it. Detection is **dual-source**:

- **Code-based** — read local manifests (`composer.json`, `package.json`,
  `*.csproj`, `pyproject.toml`, `go.mod`, `Gemfile`, `pom.xml`, `Cargo.toml`) from
  `repos[]`. Authoritative for the **shape oracle** (ORM model/migration paths,
  column precision).
- **Runtime fingerprint** — read-only GETs to `baseUrl`: response headers,
  `Set-Cookie` names, HTML/JS markers, OpenAPI probe. Authoritative for **what is
  actually running** (framework identity, auth scheme, live routes). The *only*
  source against a bare production URL.

The two are merged: runtime wins on live identity, code wins on the shape oracle;
disagreements become a `drift` note and downgrade `signal`.

Output: `.qa/runs/<run-id>/stack-profile.json` — the authoritative per-run copy
(ADR-0002), optionally seeded from a revalidated `.qa/stack-profile.cache.json`
(ADR-0005). It is **reviewable** — confirm it before trusting a long Run.

## Vocabulary (CONTEXT.md)

- **stack-profile** — the detected description of the target's stack for a Run.
- **playbook** — the per-stack executable recipe (`references/playbooks/<id>.md`)
  the agent walks to enumerate routes, bake, and probe.
- **signal: strong | weak** — how sure *detection* is. **Distinct from verdict
  `confidence`.** One-way mapping only: a `weak` signal (or a missing shape
  oracle) *causes* dependent criteria's verdict `confidence` to be `low`. Never
  the reverse; never the same field.
- **runtime fingerprint** vs **code-based detection** — the two sources above.

## When to Use

- The first action of **Analyze**, on **every** Run — even when a checklist is
  supplied and you skip straight to Verify (bake/probe still need the profile).
- Re-run when re-targeting a different `baseUrl` or after a deploy whose build-id
  changed.

## The Process

### Step 1 — Run the detector

```
bash skills/detecting-stack-profile/scripts/detect-stack.sh \
  --out .qa/runs/<run-id>/stack-profile.json
```

It reads `.qa/config.json` for `baseUrl` and `repos[]`. Flags: `--no-runtime`
(skip live probing), `--no-code` (black-box only), `--base-url`, `--repos`,
`--headers-file <captured>` (offline runtime match).

### Step 2 — Validate the profile (turn each into a todo)

- [ ] `mode` is right: `local-matched` (code+runtime agree), `source-drift`
      (build mismatch), or `black-box` (no repo / prod URL).
- [ ] `environment` is right: `production` engages guardrails (writes hard-off,
      conservative fingerprint, black-box crawl opt-in only).
- [ ] Each `components[]` entry has a plausible `framework`, `playbook`, and
      `frontend.routing`. Read `evidence[]`; a `signal: weak` or non-empty
      `drift[]` is a flag, not a failure.
- [ ] `primary.backend` / `primary.frontend` point at the components the target
      actually serves (config `repos[]` role hint → origin match → ask).

### Step 3 — Hand the profile to later phases

- **analyzing-feature-ui / index-routes** dispatch route enumeration on
  `router.strategy` and `frontend.routing`.
- **verifying-backend-persistence** reads `orm.modelsPath` / `orm.migrationsPath`.
- **probing-apis-through-browser** reads `auth.scheme` / `auth.csrf`.
- **writing-qa-reports** surfaces the playbook tier, `signal`, and `drift`.

Open the chosen **playbook** (`references/playbooks/<components[].playbook>.md`)
and follow its fallback ladders.

## The route-enumeration ladder (runtime-truth first)

The playbook walks rungs in order, recording the rung + `signal` that produced it:

1. **runtime introspection served by `baseUrl`** (OpenAPI/Swagger) — describes the
   deployed app; `strong`.
2. **local CLI introspection** (`php artisan route:list --json`, `rails routes`)
   — describes local SOURCE; `strong` **only when preflight confirms the build
   matches**, else `weak` + drift-flagged. Requires a present, side-effect-free
   toolchain; if absent, drop the rung.
3. **static source parse** (grep `routes/*.php`, file-based dir).
4. **live navigation** (browse + snapshot).

For **server-bridge** frontends (Inertia/Livewire/Hotwire/Django) the frontend
surface list **is the backend GET-route list** — never href-grep.

## Extending (zero engine code)

Add a stack by appending a row to `references/stack-signatures.json` (manifest +
package signatures, Wappalyzer-style runtime cookies/headers, playbook, router,
orm, auth). Add `references/playbooks/<id>.md` for a dedicated recipe, or map to
`openapi-generic` / `generic`. The engine is a generic matcher; all knowledge is
data.

## Mini-Evals (given → catch)

1. **Inertia page invisible to href-grep.** *Given* a Laravel+Inertia app whose
   nav uses Wayfinder helpers (`edit().url`), not literal `href="/leads"`. *Catch*
   the detector sets `frontend.routing: server-bridge` (composer `inertiajs/
   inertia-laravel` → `implies`), so enumeration derives surfaces from backend GET
   routes and **finds `/leads`** — the literal-href grep would have missed it.

2. **Wrong model read-back prevented.** *Given* a "Transfer Shares" action whose
   controller persists `EquityTransfer`, not `ShareTransfer`. *Catch* the profile
   carries `orm.migrationsPath`, so verifying-backend-persistence reads the right
   migration for the NOT-NULL/precision columns instead of guessing the table —
   preventing a false pass from baking the wrong model.

3. **Stale route a deterministic source includes.** *Given* `/cap-table` removed
   from the nav but still served. *Catch* rung-1 (`artisan route:list` or OpenAPI
   `paths`) lists the live route deterministically, so analyze visits it and flags
   the stale panel — a grep of the *current* nav source would never surface it.

4. **Black-box prod, no repo.** *Given* only a production `baseUrl`, no `repos[]`.
   *Catch* runtime fingerprint (`laravel_session`/`XSRF-TOKEN`) still yields
   `framework: laravel`, `mode: black-box`, `environment: production` →
   guardrails engage, the run proceeds at `signal: weak` instead of aborting.
