---
description: Show where a project (or a specific target) stands in the qa-kit process — which artifacts exist, which step is next, and any constitution-drift advisory. Read-only.
argument-hint: [<target>]
disable-model-invocation: false
---

Report the qa-kit process state for this project. **Read-only** — inspect artifact presence only;
never create, modify, or run anything. Full input: `$ARGUMENTS` (an optional `<target>` scopes the
spec-level checks to `.qa/specs/<target>/`; with no target, list every `.qa/specs/*/`).

## What to do

1. **Constitution (project-level).** Check for `.qa/constitution.state.json` (authoritative machine
   state) and `.qa/constitution.md` (human policy).
   - Absent → the project has no constitution. Next step: **`/qa-constitution`**. Stop here (nothing
     downstream can exist meaningfully yet); say so.
   - Present → read its `version` from `.qa/constitution.state.json` and report it + the role count.

2. **Specs.** For the target (or each `.qa/specs/<t>/` directory), check, in order:
   - `qa-spec.md` + `spec-roles.json` → the spec step is done. If absent → next step: **`/qa-spec`**.
   - `scenarios.md` + `checklist.json` → scenarios done. If absent (but spec present) → next step:
     **`/qa-scenarios`**.
   - `analysis.md` → analyze done. If absent (but scenarios present) → next step: **`/qa-analyze`**.
   - a `runs.json` entry or `.qa/runs/<id>/` for this spec → at least one run happened. If none (but
     scenarios present) → next step: **`/qa-run "<target>"`**.

3. **Drift advisory (per spec).** For each spec with a `spec-roles.json`, compare its stamped
   `constitutionVersion` to the current `.qa/constitution.state.json` `version`:
   - equal → in sync.
   - different → **advisory** (not a block): "spec `<target>` was snapshotted from constitution
     `<stamped>`, but the constitution is now `<current>` — its frozen roles may be stale; re-run
     `/qa-spec` for `<target>` if you want the current roles." *(Once qa-kit's `spec-snapshot.sh drift`
     helper ships, use it for this comparison; until then compare the two `version` strings directly.)*

4. **Print a compact summary:** one line for the constitution (version + role count, or "none"), then
   one line per spec — `<target>: spec ✓ / scenarios ✓ / analyze ✗ / runs 0 · next: /qa-analyze
   [· drift: stale]`. End with the single **next step** for the requested scope. Never invent an
   artifact you did not find; report only what is present on disk.
