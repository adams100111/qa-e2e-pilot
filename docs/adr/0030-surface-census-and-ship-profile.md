# ADR-0030 — Surface census through stack adapters and a read-only crawl; `ship|smoke|full` run profiles

## Status

Accepted (2026-11-09). Ship QA increment 1; released with increment 2 (engine and qa-kit together).
Design: [`docs/superpowers/specs/2026-11-09-ship-grade-qa-design.md`](../superpowers/specs/2026-11-09-ship-grade-qa-design.md)
§1a, 1b, 1d, 1e and its "Settled" sections. Extends [ADR-0003](./0003-sequential-verification-narrow-pool.md)
(narrow parallel pool), [ADR-0005](./0005-stack-profile-cache.md) (stack profile picks the adapter),
[ADR-0008](./0008-viewport-and-persona-as-config.md) (viewport / responsive matrix),
[ADR-0012](./0012-per-role-scope-and-cross-role-tests.md) (per-persona rows) and
[ADR-0019](./0019-human-eye-ux-detection-engine.md) (critic stays advisory). Adds no verdict, confidence level,
suspected layer or evidence kind. qa-kit stays additive ([ADR-0022](./0022-qa-kit-process-shell.md)).

## Context

The first module-scale run (186 criteria, 13 roles, hackathons module, Oct–Nov 2026) could not say what
it had covered. Pages, tabs, roles, scheduled jobs and notifications were simply absent, and nothing
showed it. The UX detectors, axe, the critic and `responsiveMatrix` existed but were off, so no mobile,
dark-mode or full RTL pass happened. Permission negatives were 14 hand-written checks against a
15-role authz matrix. Turning all of this on by hand, per run, is the step people skip.

Two constraints shape the answer. The plugin is general, so stack knowledge (route registries, page
directories, `artisan`, `rails routes`) must stay behind a replaceable boundary and run however the
project runs its toolchain (directly, `ddev exec`, `docker compose exec`). And a crawl that discovers
surfaces by clicking is a write risk on any environment: an "Approve" or "حذف" button looks like
navigation to a naive crawler.

## Decision

**A. The census = stack adapter + read-only crawl, merged by a script.**
- `adapters/census/<stack>.sh --repo <path> [--exec-prefix "<prefix>"]` (laravel, nextjs, rails,
  django, express, generic; contract in `adapters/census/README.md`) prints the app's own surfaces:
  routes and pages with `surfaceId` (`"<METHOD> <uri>"` or `page:<Component>`), permission hints,
  jobs, mails, notifications, locales. Failure is `{"ok":false,...}` + exit 3, never a partial
  success. The adapter is chosen from `stack-profile.json`; new config key `exec.prefix` (default
  `""`, whitespace word-split, no shell quoting) is prepended to every runtime command.
- Skill `taking-surface-census` crawls per confirmed persona, breadth-first from the landing page
  (`census.maxVisits`, default 300; depth 4), and writes `.qa/census/crawl/crawl-<persona>.json`
  (visits with status, findings, forms, `routeMatch` from Inertia `data-page` / Next
  `__NEXT_DATA__`; an `unexplored` list with reasons).
- `scripts/census.sh build` merges both into `.qa/census.json`: parameterised routes collapse to one
  surface (most literal segments wins), and the diffs list `unreachable` (declared, no role reached
  it), `overreach` (reached by a role the access file does not allow) and `crawlOnly`. A failed
  adapter degrades to crawl-only with an `adapter-failed:` warning and `adapterOk:false`; it never
  yields an empty "all covered".

**B. The crawl is read-only on every environment.** `crawl-safety.js` classifies each control
before any click. Unsafe checks run first and win: English and Arabic destructive or state-changing
labels in any name source (aria-labelledby, aria-label, text, title, value, alt), after normalising
Arabic (tashkeel, tatweel, bidi marks, alef/yaa/taa variants); submit-like buttons in forms; hrefs
naming state-changing verbs or `_method=`. A safe verb must lead the name and be followed by an
allowlisted object or nothing; everything else is `not-allowlisted`. The skill re-verifies a control
right before clicking it, answers native dialogs `accept:false`, closes dialogs it opened (Escape
first), stops clicking for a persona after any observed in-scope non-GET request, never types or
submits, and skips the crawl on production unless `allowBlackboxCrawl` (the existing invariant).
A thinner census is the accepted cost of a false "unsafe".

**C. `ship|smoke|full` profiles resolve into the run's effective config.** `scripts/profile.sh
resolve <config> [--run-config f] [--stack-profile f] [--profile p]` picks the profile (flag >
run-config > config > `full`) and fills defaults **only for keys the user did not set**; any present
key wins, including an explicit `[]`. `ship`: `responsiveMatrix` desktop 1440×900 + mobile 390×844,
`colorSchemes` `[light, dark]`, `locales` from the stack profile's i18n catalog, all UX detector
families + axe + the critic, `gates {coverage: block, oracle: enforce, dataPolicy: enforce}`,
`maxParallel` 3. `smoke`: desktop, `[light]`, first locale, coverage `advise`. `full` adds nothing —
today's behaviour, and the default. Output carries `profile` and `profileSources` so the report can
say what the profile turned on. The agent writes it to `.qa/runs/<run-id>/effective-config.json` in
phase 0 (re-resolved with the stack profile in phase 1) and every later phase reads that file.

**D. Ship rows run in a fixed shape (D7).** P1 journeys run sequentially at the primary variant.
Generated read-only rows (load-clean sweep, read-only deny, ownership isolation, UX revisits) carry
`independent` + `read-only` and fan out through `fanning-out-criteria` across up to `maxParallel`
contexts. Dark mode is applied with a new driver capability, `emulate_media` (Playwright
`browser_emulate_media`, added to `harness-profiles.json`); locales go through the app's own switch.
A driver without the capability makes a dark row `blocked`.

**E. Ship-QA kinds, not new evidence.** The checklist kind enum gains `load-clean`, `deny` and
`input-validation`. In `required-kinds.sh`, `input-validation` always requires `bake` (the rejected
value must leave persisted state unchanged, even on a `read-only` row); `load-clean` and `deny` add
nothing on their own; a `deny` row tagged `api-write` keeps the ADR-0027 swap to `probe`. Mutating
deny probes run only with `allowApiWrites` + a disposable marker; otherwise they are `deferred` rows
tagged `deny-write-deferred`.

**F. Generated data obeys a data policy.** New config `dataPolicy` (`market`, `forbiddenMarkers`,
`emailDomain`, `dateWindow`, `cleanup`) is checked by `scripts/data-policy.sh check`; created
records are tracked by id (`record`/`list`) for cleanup. Increment 2 makes it a record-time gate.

**G. qa-kit owns who SHOULD reach what, and the coverage gate.** `surface-access.sh` derives
`.qa/surface-access.json` from adapter hints and crawl reach. On a surface **with** permission
hints, a persona reaching it without a matching hint is never `allowed` until a human confirms it in
`/qa-constitution`. On a surface with **no** hint, `allowed` is the crawl's `reachedBy` (source
`crawl`) and every such persona is also listed in `reachedWithoutEvidence`: that `allowed` exists only
so the overreach diff stays quiet; it is not permission evidence, produces no deny rows, and the
confirm table asks a human about each pair. Hints resolve against persona `role`/`id` (`role:X`) and
the optional persona `permissions[]` (`can:X`/`permission:X`, `*` and `prefix.*` wildcards); an
unresolvable hint sends the pair to `reachedWithoutEvidence`, never silently to `allowed`. `generate-ship-criteria.sh` emits
rows from census × access × authz matrix, with deny rows only where permission evidence exists.
`coverage.sh` blocks a ship run (`/qa-analyze`) while any role × surface pair is uncovered and not
excluded with a reason, when the census is empty, or when the adapter failed without
`--accept-crawl-only`. The engine scripts stay engine-owned; qa-kit calls them by name.

**H. UX rows reach the detectors (0.12.0 note).** The detectors run only on a criterion tagged
`visual-ux`, so the generated `ux-revisit` rows also carry `visual-ux`, and rows on `#dialog:`/`#sheet:`
surfaces carry `interaction-ux`; the generator also emits one `visual-ux` row per reached surface at the
primary variant. Under `ship`, `coverage.sh --require-visual-ux` blocks a plan with an
in-scope UI surface that has no `visual-ux` row. Under `ship` (or `detection.ux.objective`), the run also
sweeps every page it visits: detector and axe output is journaled as advisory `source: "ux"` findings,
and an objective defect on a surface outside the plan's `visual-ux` rows goes to `ux-sweep.json` (through
`ux-sweep.sh`). The
sweep never sets a verdict and never adds a row to the frozen plan; a sweep finding becomes `fail@FE`
only when a `visual-ux` criterion for that surface runs.

## Consequences

- New: 1 skill (18 total), 6 adapters, 4 engine scripts (`census.sh`, `profile.sh`, `journeys.sh`,
  `data-policy.sh`), 3 qa-kit scripts, 10 suites, 1 driver capability, config keys `profile`,
  `exec.prefix`, `census.maxVisits`, `ship.denyStatuses`, `colorSchemes`, `locales`, `dataPolicy`.
- `.qa/config.json.example` no longer sets `responsiveMatrix: []`: under "user values win" an empty
  matrix turns a ship run's mobile pass off. It also leaves `colorSchemes` and `locales` unset and
  documents them in `_profileDoc`, for the same reason.
- A run without a profile is unchanged (`full`), so existing configs and checklists keep working.
- Status-filter tabs and links whose label or href contains a state-changing word ("Accepted",
  `?status=accepted`) are partly left `unexplored`; the census is thinner there by design. Narrow the
  href verb check to path segments if a real census turns out too thin.
- The crawl does not percent-decode URL segments, so a page recorded both raw and encoded appears
  twice as crawl-only.
