---
description: Discover, confirm, and save the tested project's user roles/personas + authz-matrix — standalone, without running a full QA pass. Optionally seed from / save to a reusable global role store.
argument-hint: [--refresh] [--global] [--from-global]
disable-model-invocation: false
---

Run role/persona discovery + confirmation **on its own** (no verify/report phases), so a user can
define or refresh the project's roles after an RBAC change without a full `/qa-run`. This is pure
orchestration over existing skills — it invents no role logic.

## Arguments

- `--refresh` — re-run discovery from current source even if `personas[]` already exists in
  `.qa/config.json` (roles are regenerate-not-reconcile, ADR-0011; this rebuilds them).
- `--global` — after confirmation, ALSO save the confirmed personas + authz-matrix to the reusable
  **global role store** for this project (see below).
- `--from-global` — pre-fill the confirmation frontier's recommended defaults from the global store
  (if present) so a recurring target's 7–8 roles don't have to be re-decided from scratch. The 3
  rounds still run and the per-project files are still regenerated — the global file only seeds.

Full input: `$ARGUMENTS`

## Scopes (where roles are saved)

- **Per-project (default, authoritative):** `.qa/config.json` → `personas[]` and
  `.qa/authz-matrix.json`, written ONLY via `confirming-discovered-roles`' `write-persona-config.sh`
  (never hand-authored). Unchanged by this command's existence (ADR-0004).
- **Global (opt-in, a SEED only):** `{{GLOBAL_ROLES_DIR}}/<project-key>.json`, where
  `project-key` = the git remote `owner/repo` slug (fallback: the `baseUrl` host). It is a
  **discovery seed / prefill, never a config bypass** — see ADR-0016. It obeys the same rule as the
  per-project files: `auth` is a credential *citation/convention* only, **never a password/secret**.
- **Per-run selection** is a separate concern handled at run time by the frontier engine (which
  personas/scenarios run this pass); `/qa-roles` defines the roster, it does not select a run's subset.

## What to do

1. **Config.** Read `.qa/config.json`; if absent, invoke `bootstrapping-qa-config` (infer defaults,
   ask only the gaps, write a valid config). Compute `<project-key>` from the git remote or `baseUrl`.
2. **Seed from global (only if `--from-global`).** If `{{GLOBAL_ROLES_DIR}}/<project-key>.json`
   exists, read it and carry its personas/authz rows in as the frontier's *recommended defaults* for
   step 4. If absent, note that and continue with source-derived defaults.
3. **Detect + discover.** Invoke `detecting-stack-profile` (writes `stack-profile.json`), then
   `discovering-user-roles` → `.qa/runs/<run-id>/discovered-roles.json` (the role proposal; it only
   proposes, never writes config, never guesses a password).
4. **Confirm + persist (per-project).** Invoke `confirming-discovered-roles` — its 3-round HITL
   frontier (roles → credentials → scope) over the proposal (seeded by step 2 when `--from-global`),
   which writes `.qa/config.json` `personas[]` + `.qa/authz-matrix.json` via `write-persona-config.sh`.
   If `personas[]` already exists and `--refresh` was NOT passed, report the existing roster and stop
   (nothing to do) unless the user asks to refresh.
5. **Save to global (only if `--global`).** After a successful confirmation, write the confirmed
   `personas[]` + authz-matrix to `{{GLOBAL_ROLES_DIR}}/<project-key>.json` (create the dir if
   needed). Strip anything secret-shaped; store only the `auth` citations/conventions. This never
   overrides the per-project files — it is a reusable seed for the next fresh checkout.
6. **Report.** Surface: the confirmed persona count + ids, the authz-matrix row count, any
   `assumption:true` entries (frontier budget-exceeded defaults), and which scopes were written
   (per-project always; global if `--global`). Do NOT run verify/report — this command stops at roles.

Guardrails: never hand-author the config JSON (always `write-persona-config.sh`); the global store is
a seed, never a confirmation bypass; secrets are never written to any scope.
