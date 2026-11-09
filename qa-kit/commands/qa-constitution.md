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

5. **Profile and gates.** Read the project's effective ship settings from the engine's
   `profile.sh resolve` (an engine script — qa-kit cannot address it by `${CLAUDE_PLUGIN_ROOT}`, ADR-0022,
   so resolve it against the engine's checkout or plugin root; if it cannot be resolved or fails, write
   "unresolved" in the rows below and say so — never guess): run
   `profile.sh resolve .qa/config.json --stack-profile <stack-profile.json>` with the stack profile the
   locales come from — `.qa/stack-profile.cache.json` when present, else the latest run's
   `.qa/runs/<run-id>/stack-profile.json`, else invoke `/qa-e2e-pilot:detecting-stack-profile` to write
   one — and read the printed `profile` (default `full`; `ship` and `smoke` are the opt-in profiles), its
   `locales` (empty means the app default, one pass) and the gate leaves it resolved. Record them in the constitution's "Enabled optional gates" table: the `profile` row (the
   project's default profile), `coverage`/`oracle`/`dataPolicy` from `gates.*`, `uiux` from
   `detection.ux` (objective, advisoryAesthetics, critic, axe), and `security` = whether deny / isolation
   criteria are generated (on under `ship`). The `oracle` row is informational: the ORACLE GATE keys on
   `fixture.expect.oracleSource` and on profile `ship`, never on `gates.oracle`. Never invent a value
   `profile.sh` did not print. The
   constitution is re-rendered from the template, so tell the operator to re-apply any hand edits to those
   rows after a re-run.

6. **Surface-access confirmation round (who SHOULD reach each surface).** Needs a census, so build one
   first if `.qa/census.json` is missing or stale: invoke `/qa-e2e-pilot:taking-surface-census` (the
   read-only per-role crawl; the engine's `census.sh build` then merges it with the stack adapter's
   routes into `.qa/census.json`). The adapter output lives at the canonical path
   **`.qa/census/adapter.json`** (the adapter is the stack profile's framework id when an adapter of that
   name exists, else `generic`). Then:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/surface-access.sh" derive .qa/census.json <personas-tmp> \
       --adapter .qa/census/adapter.json > .qa/surface-access.json
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/surface-access.sh" confirm-table .qa/surface-access.json
   ```
   `<personas-tmp>` is the `personas` array from step 2, which carries each persona's `permissions`
   when the role flow recorded them; `can:`/`permission:` hints match only those (exactly, `*`, or
   `prefix.*`), so a persona without `permissions` lands in "reached without permission evidence"
   instead of being allowed. `--adapter` is required for hints: the census does not carry
   `permissionHints`. Show the
   `confirm-table` Markdown to the operator **in one pass**: first the "Reached without permission
   evidence — confirm or deny" section (a persona the crawl reached on a surface no hint grants it —
   reaching a page is never evidence of permission), then one section per permission-hint group. Collect
   the answers into a `decisions.json` (`byHint` for a group, `bySurface` for one surface, `pairs`
   `{surfaceId, persona, decision: allow|deny}` for a single reached-without-evidence pair) and run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/surface-access.sh" apply .qa/surface-access.json <decisions.json> > <tmp>`,
   then move `<tmp>` over `.qa/surface-access.json`; exit 1 means a typo in a decision, so fix it rather
   than guess. Afterwards re-run the engine's
   `census.sh build ... --access .qa/surface-access.json` so its overreach diff uses the confirmed
   access. Interactive runs follow the human-interaction discipline: ask one grouped question set, never
   a per-surface interrogation.

   **Under `autonomousSetup` (no human in the loop) assume, never deny.** Run
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/surface-access.sh" apply --assume .qa/surface-access.json > <tmp>` and
   move it over `.qa/surface-access.json`. That accepts the derived `allowed` and marks each entry
   `assumption: true`, leaves every `reachedWithoutEvidence` pair **undecided** and every entry
   unconfirmed — so no deny row is generated from crawl reach, and deny rows exist only where a permission
   hint matched. Never decide a pair `deny` on the operator's behalf (that turns surfaces the role may
   legitimately use into false deny criteria); `--assume` refuses deny decisions. List the undecided
   pairs as assumed in the report so a human confirms them later with a plain `apply`.

7. **Report plainly.** Tell the operator:   - the new version hash and how many roles/personas it covers;
   - the diff from step 3, if one ran (or "no prior constitution — this is the first stamp");
   - that **personas were regenerated wholesale** (ADR-0011) — this run did not merge or preserve
     any prior role edits;
   - that **per-role customizations belong in a spec, not the constitution** — a later `/qa-spec`
     step is where a run narrows/overrides roles for one target, and the constitution itself is
     never the place to hand-tune an individual role;
   - the resolved `profile`/gate rows (step 5) and how many surface-access decisions were confirmed
     vs. assumed (step 6), plus the reached-without-evidence pairs still undecided.

Guardrails: never hand-author `.qa/constitution.state.json` or `.qa/constitution.md` (always via
`constitution.sh`); never hand-author `.qa/config.json`/`.qa/authz-matrix.json` (always via the
engine's role flow / `write-persona-config.sh`); never hand-author `.qa/surface-access.json` (always via `surface-access.sh`); the diff is informational, never a merge/reconciliation.
