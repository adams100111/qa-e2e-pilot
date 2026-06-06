# ADR-0005 — Stack profile: run-dir authoritative + revalidated project cache

## Status

Accepted (2026-06-06).

## Context

`detecting-stack-profile` produces a `stack-profile.json` describing the target's
language/framework/ORM/auth/routing. Two forces pull in opposite directions:

- **ADR-0002** is firm that *run state lives in `.qa/runs/<run-id>/` as plain
  files*, not reused agent state — so each Run's evidence is self-contained and
  resumable.
- A stack rarely changes between Runs, and **runtime fingerprinting hits the live
  app**. Re-detecting from scratch every Run is wasteful and, against a
  production target, mildly impolite (repeated GETs to `/openapi.json`, `/swagger`).

## Decision

- The **authoritative copy for a Run is always written to
  `.qa/runs/<run-id>/stack-profile.json`** — it is evidence for that Run.
  ADR-0002 is honoured; nothing trusts agent memory.
- An **optional project-level cache** lives at `.qa/stack-profile.cache.json`
  (config-level, like `.qa/config.json`; git-ignored). At preflight, if present,
  it is **revalidated cheaply** against the recorded build-id plus a single
  homepage fingerprint GET:
  - **match** → copy the cache into the run dir, skip full detection.
  - **drift** (build-id changed, or the homepage fingerprint differs) → full
    re-detect and refresh the cache.
- **Black-box / production** Runs still do the cheap revalidation but **never skip
  the runtime fingerprint** entirely: code-based facts may cache, runtime facts
  always get a lightweight re-check, because a prod deploy can change underneath.

## Consequences

- ADR-0002 intact: every Run owns its profile on disk.
- Redundant full detection is avoided in the common "same stack as last run" case.
- Production probing is minimized to one revalidation GET on a cache hit.
- A new artifact (`.qa/stack-profile.cache.json`) must be git-ignored alongside
  `.qa/runs/` and `.qa/auth/`.
- The cache is an optimization only — deleting it is always safe (forces a
  re-detect).
