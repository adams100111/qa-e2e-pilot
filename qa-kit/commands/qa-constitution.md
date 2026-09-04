---
description: Discover/confirm this project's roles and stamp the living QA constitution — the project-specific policy doc + version/hash that later qa-kit specs snapshot.
argument-hint: [--refresh] [--global] [--from-global]
disable-model-invocation: false
---

Run role discovery/confirmation via the qa-e2e-pilot engine's role skills, then stamp a versioned
**constitution**: `.qa/constitution.state.json` (machine, authoritative) and `.qa/constitution.md`
(human, project policy). This is thin orchestration over the engine's existing skills +
qa-kit's bundled `constitution.sh` (`${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh`) — it invents no
role logic and no new hashing/diff logic.

## Arguments

Forwarded as-is to the role flow: `--refresh`, `--global`, `--from-global`. Full input: `$ARGUMENTS`.

## What to do

1. **Roles.** Run the engine's role flow end to end by invoking its skills (qa-kit depends on the
   `qa-e2e-pilot` plugin, so both are enabled — invoke by qualified slug):
   `/qa-e2e-pilot:discovering-user-roles` → `/qa-e2e-pilot:confirming-discovered-roles`, which writes
   `.qa/config.json` `personas[]` and `.qa/authz-matrix.json` **wholesale** (ADR-0011: regenerate,
   never reconcile). Do not duplicate that flow's steps here; invoke it.

2. **Compute the new version.** Extract just the `personas` array out of `.qa/config.json`
   (it holds more than personas) into a temp file, then run:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh" version <personas-tmp> .qa/authz-matrix.json
   ```
   This prints the new deterministic version hash. Keep it — steps 3–4 need it.

3. **Informational diff (only if a prior constitution exists).** If `.qa/constitution.state.json`
   already exists from an earlier run:
   - Compute the new machine state to a temp file:
     `bash "${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh" state <personas-tmp> <new-version> > <new-state-tmp>`.
   - Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh" diff .qa/constitution.state.json <new-state-tmp>`.
   - Print the result to the operator as a plain sentence, e.g. "since the last constitution:
     +auditor, −guest, admin role→superadmin" (from the diff's `added`/`removed`/`changed`).
   - This is **awareness only** — never merge or preserve the prior role set; step 4 always
     writes the wholesale-regenerated set.

4. **Write the constitution.** Two files, both stamped with the same `<personas-tmp>` +
   `<new-version>`; the human doc additionally takes an ISO-8601 `<timestamp>` (compute it once):
   - `.qa/constitution.state.json` ← `bash "${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh" state
     <personas-tmp> <new-version>` (authoritative machine state; later qa-kit steps read this file,
     never the `.md`). `state` takes no timestamp — the machine state is timestamp-free by design.
   - `.qa/constitution.md` ← `bash "${CLAUDE_PLUGIN_ROOT}/scripts/constitution.sh" render <personas-tmp>
     <new-version> "${CLAUDE_PLUGIN_ROOT}/templates/constitution-template.md" <timestamp>` (human doc;
     always renders from the pristine template — see that file's regeneration note before assuming
     edits persist).

5. **Report plainly.** Tell the operator:
   - the new version hash and how many roles/personas it covers;
   - the diff from step 3, if one ran (or "no prior constitution — this is the first stamp");
   - that **personas were regenerated wholesale** (ADR-0011) — this run did not merge or preserve
     any prior role edits;
   - that **per-role customizations belong in a spec, not the constitution** — a later `/qa-spec`
     step is where a run narrows/overrides roles for one target, and the constitution itself is
     never the place to hand-tune an individual role.

Guardrails: never hand-author `.qa/constitution.state.json` or `.qa/constitution.md` (always via
`constitution.sh`); never hand-author `.qa/config.json`/`.qa/authz-matrix.json` (always via the
engine's role flow / `write-persona-config.sh`); the diff is informational, never a merge/reconciliation.
