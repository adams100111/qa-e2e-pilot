# 0016. Opt-in cross-project role seed store (does not override per-project config)

Status: Accepted
Date: 2026-09-01

## Context
Roles/personas are per-project by design (ADR-0004) and regenerate-not-reconcile (ADR-0011): every
role run rebuilds `.qa/config.json` `personas[]` + `.qa/authz-matrix.json` from current source +
confirmation, and prior human edits do not survive a re-run. For a **recurring target** — e.g. an
`innovation`-shaped app with 7–8 roles across a `UserType` enum + team pivots — that means re-deciding
the same 7–8 roles from scratch for every fresh checkout / new `.qa/`. There was no way to define a
project's roles once and reuse them. The `/qa-roles` command (this change) needs somewhere to save a
reusable roster, which crosses the per-project boundary ADR-0004 deliberately drew.

## Decision
Add an **opt-in, cross-project role SEED store** at `~/.claude/qa-e2e-pilot/roles/<project-key>.json`
(`project-key` = git remote `owner/repo` slug, fallback `baseUrl` host). It is a **seed / prefill,
never a config bypass**:
- `--global` writes the *confirmed* personas + authz-matrix there AFTER the normal 3-round
  confirmation and per-project write.
- `--from-global` pre-fills the confirmation frontier's *recommended defaults* from it, but the 3
  rounds still run and `write-persona-config.sh` still regenerates the per-project files.
- The per-project `.qa/config.json` + `.qa/authz-matrix.json` remain the ONLY authoritative source a
  Run reads (ADR-0004 intact); the global file is never read at Run time.
- Same secret rule as everywhere: `auth` is a credential citation/convention only, never a password.

## Consequences
- ADR-0004 (per-project authoritative) and ADR-0011 (regenerate-not-reconcile) are preserved — the
  global store only saves a human from re-deciding a stable roster; it cannot silently change what a
  Run verifies, and confirmation is never skipped.
- The store is opt-in; users who never pass `--global`/`--from-global` see no change and no global file.
- A future concern: if a project's roles drift, a stale global seed could propose outdated defaults —
  acceptable because confirmation always runs and the user can correct any default in the frontier.
