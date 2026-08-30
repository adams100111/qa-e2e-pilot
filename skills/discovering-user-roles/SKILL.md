---
name: discovering-user-roles
description: Use after detecting-stack-profile, before generating-qa-checklist, on any target that has more than one kind of authenticated user — to statically discover the project's user roles on two planes (global RBAC/permission source, and contextual/team-membership roles) and emit a reviewable discovered-roles.json proposal. For each role records its plane, a file:line source citation, and how a browser session would authenticate as it (seeded-credential convention or storageState path — never a guessed password). This skill only DISCOVERS and PROPOSES; a later HITL step (bootstrapping-qa-config's roles-confirm round) confirms the set. Degrades to signal:weak with [anonymous] + any bare role literals found in code, rather than failing, when no RBAC source exists.
---

# Discovering User Roles

## Overview

Most features aren't tested by one kind of user. A "creating a submission" criterion
run only as an admin will never catch an authorization leak that lets a `jury`
member see another team's draft. Before the checklist is generated, find out
**who this app's users can be** — statically, from source — and hand a reviewable
proposal downstream.

Discovery is **two-plane**:

- **Plane 1 — global roles.** An RBAC/permission source: a role enum or const
  list, a permission/role seeder or config, and route-middleware/policy `role:`
  guards. Reference shape: a spatie/laravel-permission app exposes roles in an
  enum like `app/Enums/UserType.php`, a `config/permission*.php`, and `role:`
  route middleware.
- **Plane 2 — contextual/team roles.** Role columns on pivot/membership tables
  — `team_members.role` values, a `ChallengeUserRole`-style pivot enum. These
  roles only make sense *within* a team/challenge/organization scope, not
  globally.

This skill does **not** ask the human anything and does **not** write
`.qa/config.json`. It emits a proposal artifact for a later HITL round
(Task 2B.2, `bootstrapping-qa-config`) to confirm/edit. Never invent a
password — an uninferable credential is recorded as `auth: unknown`, not
guessed.

Output: `.qa/runs/<run-id>/discovered-roles.json`.

## Vocabulary (CONTEXT.md-aligned)

- **global role** — a role that grants capability across the whole app,
  independent of which record/team/tenant is in view (Plane 1).
- **contextual role** — a role that only has meaning inside one owning record
  (a team, a challenge, an organization) — the same person can hold a
  different contextual role on a different team (Plane 2).
- **signal: strong | weak** — same meaning as `detecting-stack-profile`'s
  `signal`: how sure *discovery* is, not a verdict. A `weak` signal here should
  downgrade the `confidence` of any role-sensitive criterion built on it, same
  one-way rule as stack-profile's signal.
- **auth method** — how an automated browser logs in as a discovered role:
  a seeded-credential convention (`qa.{role}@<host>`), a captured
  `storageState` path, plain form-login with no fixture, or `unknown`.

## When to Use

- After `detecting-stack-profile` has written `stack-profile.json` (its
  `framework`/`orm` fields pick which plane-1 signatures to look for) and
  before `generating-qa-checklist` runs Step 6's cross-role/cross-tenant
  expansion.
- Whenever the surface map or code shows more than one distinct authenticated
  actor, OR the target has any team/membership/pivot concept at all.
- Skip (or run once and cache) on a genuinely single-user app — Step 5's
  degrade path handles that case cheaply rather than making it an error.
- Re-run when the RBAC source changes (new role added to the enum/config) —
  this skill always regenerates the proposal from current source, it never
  reconciles against a stale prior run.

## The Process

### Step 1 — Load the stack profile

Read `.qa/runs/<run-id>/stack-profile.json`. Its `framework`/`orm` fields pick
which Plane-1 signatures apply:

| Stack signal | Global-role signature to grep for |
|---|---|
| Laravel + `spatie/laravel-permission` (composer.json) | role enum (`app/Enums/*Type.php`, `app/Enums/*Role.php`), `config/permission*.php`, `Route::middleware('role:...')` / `#[Middleware(['role:...'])]` |
| Rails + `cancancan`/`pundit`/`rolify` | `app/models/ability.rb`, `app/policies/*_policy.rb`, a `roles` gem table |
| Django + `django-guardian`/groups | `Group` fixtures/migrations, `@permission_required`, `groups.filter(name=...)` |
| Node/Express/Nest + `casl`/`accesscontrol` | `defineAbility`/`AccessControl` rule tables, `@Roles(...)` decorators |
| No RBAC library detected | fall through to Step 5's degrade path |

If `stack-profile.json` is missing or `signal: weak`, proceed anyway with the
generic fallback row — do not block on it.

### Step 2 — Plane 1: scan for global roles

- [ ] **Role enum/const list.** Grep for an enum or const array whose case
      names read like roles (`admin`, `super-admin`, `user`, `evaluator`,
      `jury`, `manager`...). Record the defining file + line per case.
- [ ] **Permission/role seeder or config.** Find the seeder or config that
      creates/lists these roles at runtime (a `RolesAndPermissionsSeeder`, a
      `config/permission*.php`, a `roles.yml`). This confirms the enum isn't
      dead code — the role actually gets created in the DB/permission store.
- [ ] **Route-middleware/policy guards.** Grep routes/controllers for
      `role:<name>` middleware, `@Roles`, policy `can('...')` checks scoped by
      role, or framework-native decorators. Record at least one guard
      citation per role — a role with an enum case but **zero** guards or
      seeder references is a dead/unused value; still list it, but note
      `unused: true` rather than silently dropping it.
- [ ] Cross-reference: a role only counts as **discovered with strong signal**
      when it appears in ≥2 of {enum, seeder/config, guard}. A role found in
      only one place still gets listed, but contributes to `signal: weak`.

### Step 3 — Plane 2: scan for contextual/team roles

- [ ] Grep migrations/schema for a `role` (or `type`) string/enum column on a
      pivot or membership table — table names containing `_members`,
      `_user`, `_participants`, or a model named `TeamMember`/`Membership`.
- [ ] Find what defines that column's legal values: a sibling PHP enum
      (`ChallengeUserRole`), a CHECK constraint in the migration, or a config
      map keyed by team "purpose"/"type" (`config('teams.roles.<purpose>')`
      style — walk every purpose key, each is a distinct contextual role
      set).
- [ ] Record each contextual role value with: the pivot table, the column
      name, and the file defining its legal values. If a CHECK constraint's
      allowed values differ from the sibling enum's cases, record BOTH and
      flag the mismatch as a `drift` note (do not silently pick one — this is
      exactly the kind of divergence a later criterion should probe).
- [ ] A contextual role with the same string as a global role (e.g. `jury`
      appearing both in the global enum and a pivot column) is **not** a
      duplicate — record it twice, once per plane, since the two may grant
      different capability (global `jury` = a site-wide permission bundle;
      pivot `jury` = "this person reviews submissions for this specific
      challenge").

### Step 4 — Infer an auth method per discovered role (never guess a password)

- [ ] **Seeded-credential convention.** Grep test/demo/QA seeders for a
      pattern that mints one login per role — commonly a loop over the role
      list producing `<prefix>.{role}@<host>` (e.g. `qa.{role}@`,
      `demo.{role}@`). Record the citation and the **email/login pattern
      only**. If the seeder references a password via a named constant, cite
      the constant's existence (`Hash::make(self::QA_PASSWORD)`) — never copy
      the literal value into the artifact, even if it's plaintext in source.
- [ ] **storageState path.** If `.qa/config.json` or a fixtures directory
      already references a captured, per-role `storageState` file, record
      that path as the auth method instead.
- [ ] **Form-login, no fixture found.** If a login form exists but no seeded
      credential or storageState is discoverable for that specific role,
      record `auth: unknown` — this is the expected, honest answer for most
      contextual roles (a team role is usually reached by logging in as
      *some* global-role account and then acting inside that team, not by a
      role-specific login of its own).
- [ ] A contextual role's auth is frequently `auth: unknown` or
      `auth: "login as the global-role account holding this team membership"`
      — that's a valid, non-guessed answer; record it as such rather than
      inventing a per-team login.

### Step 5 — Compute signal and degrade gracefully

- [ ] **`signal: strong`** — at least one Plane-1 role was corroborated by
      ≥2 of {enum, seeder/config, guard} (Step 2's cross-reference).
- [ ] **`signal: weak`** — no RBAC source was found on either plane. Do NOT
      fail or block the Run. Instead:
      1. Emit `[anonymous]` as the sole confirmed role.
      2. Broadly grep the codebase for bare role-like string literals
         (`'admin'`, `"role"`, `req.user.role ===`, `if user.is_admin`) and
         list each as an **unconfirmed candidate**: `plane: "unknown"`,
         `source` = the file:line hit, `auth: "unknown"`.
      3. Set the top-level `signal` to `"weak"` so downstream criteria built
         on these candidates are marked lower-confidence, per the one-way
         signal→confidence rule.
- [ ] A role found in code but never reachable via any discoverable login
      (no seeder, no storageState, no obvious form-login target) still gets
      listed — `auth: unknown` is a valid terminal state for this skill, not
      a reason to omit the role. Confirming/filling it in is Task 2B.2's job,
      not this skill's.

### Step 6 — Emit discovered-roles.json

Write `.qa/runs/<run-id>/discovered-roles.json` with this exact shape:

```json
{
  "runId": "<run-id>",
  "generatedAt": "<ISO-8601>",
  "signal": "strong",
  "roles": [
    {
      "name": "admin",
      "plane": "global",
      "source": "app/Enums/UserType.php:11",
      "auth": "qa.admin@<host> (seeded credential loop; password via a named constant, not printed)"
    },
    {
      "name": "leader",
      "plane": "contextual",
      "source": "Modules/Teams/config/config.php (roles.collaboration.leader) + team_members.role column",
      "auth": "unknown — reached by logging in as the global-role account holding this team membership"
    }
  ],
  "candidates": [],
  "driftNotes": [],
  "notes": []
}
```

Fields:

- `roles[].plane` — exactly `global` or `contextual`.
- `roles[].source` — a file:line citation when the discovery pinpoints one
  case/line; a file (or two files joined with ` + `) when the value is
  assembled from more than one place (e.g. a config map plus the migration
  column it constrains).
- `roles[].auth` — a login convention/path string, or the literal string
  `"unknown"` (optionally with a short clause explaining why, e.g. "no
  seeded login found for this contextual role"). Never a password.
- `candidates[]` — only populated on the `signal: weak` degrade path; same
  shape as `roles[]` but `plane: "unknown"` and always `auth: "unknown"`.
- `driftNotes[]` — free-text notes when a CHECK constraint and its sibling
  enum disagree (Step 3), or when an enum case has no corroborating
  seeder/guard (`unused: true` roles land here too).

### Step 7 — Hand off

- `generating-qa-checklist`'s Step 6 cross-role/cross-tenant heuristic
  expands per discovered role once this file exists (see that skill's
  reference to `discovering-user-roles`) — pass it this file's path.
- `bootstrapping-qa-config`'s roles→credentials→scope confirmation round
  (Task 2B.2) consumes `roles[]` as its Round-1 numbered proposal — this
  skill's job ends at emitting the proposal, it does not ask the human
  anything itself.
- If `signal: weak`, say so plainly in your response so the human knows the
  eventual persona confirmation round will be mostly `candidates[]`, not
  `roles[]`.

## Checklist Summary

- [ ] Load `stack-profile.json`; pick the Plane-1 signature row for the
      detected framework (or fall through to the generic/weak path).
- [ ] Plane 1: find the role enum/const, the seeder/config, and ≥1 guard per
      role; cross-reference for `strong` vs `weak` per role.
- [ ] Plane 2: find pivot/membership tables with a `role` column and the
      enum/config/CHECK constraint defining its values; record drift if the
      CHECK and enum disagree.
- [ ] Infer an auth method per role from seeders/storageState; never guess a
      password; `unknown` is a valid, honest answer.
- [ ] Degrade to `signal: weak` + `[anonymous]` + code-literal candidates
      when no RBAC source exists at all — never fail the Run.
- [ ] Emit `discovered-roles.json`; hand the path to `generating-qa-checklist`
      and note it for the later HITL confirmation round.

## Mini-Evals

**Eval 1 — Spatie/Laravel two-plane discovery (grounded in a real
spatie/laravel-permission app)**
Given: `app/Enums/UserType.php` defines `SUPER_ADMIN='super-admin'`,
`ADMIN='admin'`, `EVALUATOR='evaluator'`, `USER='user'`, `JURY='jury'`
(lines 10–14); `config/permission.php` + `config/permission_seeder.php`
exist; route guards `role:admin|super-admin` and `role:super-admin` appear
in two module route files; a `QaFixturesSeeder` loops
`Role::pluck('name')->each(...)` minting `qa.{roleName}@<host>` logins
against a named password constant. Separately, `team_members.role` is a
plain string column constrained by `config('teams.roles.<purpose>')` maps
(`collaboration`: `leader`/`member`/`mentor`; `advisory`:
`mentor`/`supervisor`), and a `ChallengeUserRole` enum
(`JURY`/`EVALUATOR`) is the sole source of truth for a separate
`challenge_user.role` pivot column, whose migration CHECK constraint
actually allows `('jury','participant')` — a mismatch with the enum's
`EVALUATOR` case.
Catch: Step 2 lists all 5 global roles as `signal: strong` (enum + seeder +
guard corroborate `admin`/`super-admin`; `evaluator`/`user`/`jury` are
`strong` via enum + seeder even without a dedicated route guard hit). Step 3
lists 4 distinct contextual `team_members.role` values (`leader`, `member`,
`mentor`, `supervisor`) each citing the config map + migration column, and
separately lists the `challenge_user` pivot's `jury`/`evaluator` values,
flagging the enum-vs-CHECK mismatch in `driftNotes[]` instead of silently
picking one. Step 4 records each global role's auth as the
`qa.{role}@<host>` convention (citing the seeder, not the password); each
contextual role gets `auth: unknown` with the "login as the global-role
holder" note. Without the two-plane split, a checklist generator would only
ever see the 5 global roles and never test team-scoped authorization (a
`leader`-only action attempted by a `member`).

**Eval 2 — Degrade to weak signal (no RBAC source at all)**
Given: a small internal tool with a single `users` table, no role/permission
library, no enum, and exactly one scattered check:
`if (req.user.email === 'owner@corp.test')` gating one admin route.
Catch: Step 2 finds no enum, no seeder, no `role:`-style guard — Plane 1
yields nothing. Step 3 finds no pivot/membership table — Plane 2 yields
nothing. Step 5's degrade path fires: `signal: "weak"`, `roles: [{"name":
"anonymous", ...}]`, and `candidates: [{"name": "owner-check (literal
email)", "plane": "unknown", "source": "routes/admin.js:14", "auth":
"unknown"}]`. The skill does not fail or block the Run; it emits the weak
proposal and says so. `generating-qa-checklist` still runs, just without
per-role expansion beyond the single hard-coded gate, and any criterion
built on the `owner-check` candidate is downstream-flagged lower-confidence.

**Eval 3 — Non-PHP stack, no discoverable RBAC library**
Given: a Next.js + Prisma app (`stack-profile.json` reports
`framework: "next"`, no auth/permission package in `package.json`) whose
`schema.prisma` has a plain `role String` column on the `User` model with
values only ever set to `"member"` / `"owner"` inside app code
(`lib/teams.ts: user.role = "owner"`), no seeder, no fixture login.
Catch: Step 1's signature table has no matching row for "Next.js + no RBAC
lib," so Step 2 correctly finds nothing framework-specific but still runs
the **generic fallback**: grep the schema for a `role`-shaped column,
finding `User.role`. Because it's a column on the primary `User` model
(not a pivot/membership table), it's recorded as `plane: "global"` with
`source: "prisma/schema.prisma (User.role) + lib/teams.ts:22"`, `auth:
"unknown"` (no seeder found). `signal` is `"weak"` because only one
corroborating source (the assignment site) backs the role, not two — the
proposal still ships, correctly flagged for HITL confirmation of both the
role list and its credentials, rather than the skill assuming a
Laravel-shaped answer or failing outright on the unfamiliar stack.
