# HITL frontier-in-rounds — a reusable pattern for tree-shaped confirmation

> **Now executable:** this round pattern is implemented and tested as `skills/confirming-discovered-roles/scripts/frontier.js` (`computeFrontier`/`applyAnswers`/`recommendedDefault`/`budgetExceeded`); `confirming-discovered-roles` drives the rounds around it. See `tests/frontier/run.sh`.

## What this is (and isn't)

This is a **native, from-scratch reimplementation of a grilling-style
frontier-in-rounds shape** (numbered items with a recommended default, human
confirm/edit, recompute the frontier for dependent decisions) — per ADR-0001,
qa-e2e-pilot reimplements reusable *patterns* rather than forking, vendoring,
or taking a runtime dependency on another skill. This file has no import of
and no call into any other skill. Treat "grilling-style round" anywhere else
in this plugin's docs as a pointer to *this* file.

It is a **prompt-pattern + render/recompute algorithm**, not a new interactive
tool. A consuming skill renders each round through the host's own question UI
(`AskUserQuestion` in Claude Code; plain numbered text elsewhere) — one round
per host prompt — and drives the recompute logic described below between
prompts.

**When to use it:** the decisions form a **dependency tree** — confirming or
editing decision A changes which options are even valid for decision B. Role →
credentials → scope is the canonical case: which credential strategy applies
depends on which roles survived confirmation; which scope entries exist
depends on which credential (account) got bound to each role.

**When NOT to use it:** the decisions are independent of each other. See
"Relationship to `bootstrapping-qa-config`'s own flat form" below — do not
reach for rounds when one flat batch of questions already covers the case.

## Core concepts

- **Design tree.** Model the full set of decisions as a tree: each decision
  node lists the other decisions it depends on (`dependsOn`). A decision with
  no unsettled dependencies is answerable now.
- **Frontier.** The frontier is the set of decisions whose prerequisites are
  already settled (confirmed or edited) and which have not yet been rendered.
  Round 1's frontier is every decision with no dependencies at all.
- **Round.** One frontier, rendered in full, as one prompt. Every item in the
  current frontier is shown together — never trickled out one at a time.
- **Fact vs. decision.** A *fact* (a role enum's case names, a seeded fixture
  user, an FK column) is discoverable by static analysis and must be found
  BEFORE the round is rendered — it is never posed as an open question ("what
  roles does your app have?" is forbidden). A *decision* is what the human
  does with a proposed fact: keep it, edit it, or drop it. Rounds only ever
  ask decisions; they present facts as evidence (the source citation) behind
  each recommended default.

## Round schema

```jsonc
{
  "roundName": "roles",                 // stable name for this frontier
  "items": [
    {
      "id": "role:evaluator",           // stable id, referenced by dependsOn
      "dependsOn": [],                  // ids of decisions this one requires settled
      "sourceCitation": "app/Enums/UserType.php:6 (UserType::EVALUATOR)",
      "recommendedDefault": "keep — include, test as this role",
      "status": "proposed"              // proposed -> confirmed | edited | dropped
    }
  ]
}
```

- `onConfirm(item)` → `status: "confirmed"`, value = `recommendedDefault` as-is.
- `onEdit(item, value)` → `status: "edited"`, value = the human's replacement.
- `onDrop(item)` → `status: "dropped"` (only meaningful for items that may be
  removed entirely, e.g. a proposed role the human doesn't want tested).

**Concrete-engine mapping.** `frontier.js`'s tree node is
`{ id, prereqs, default }` — `prereqs` is this schema's `dependsOn`,
`default` is this schema's `recommendedDefault`. frontier.js has no
`sourceCitation` or `status` field at all; those are consuming-skill
bookkeeping layered on top for rendering, not part of what gets passed to
`computeFrontier`. `status: "dropped"` in particular has no counterpart in
the engine — see `confirming-discovered-roles`' own "Engine (frontier.js)"
section for how a drop is modeled (the id is simply never added to
`settled`, and the consuming skill tracks a `decided` set so a dropped id
is not re-rendered by a later `computeFrontier` call).

## The algorithm

1. **Build the tree.** Before rendering anything, static-analysis/subagent
   discovery enumerates every decision node and its `dependsOn` edges across
   ALL rounds this flow will ever need — not just round 1. (The nodes for
   later rounds may still have placeholder `recommendedDefault`s that depend
   on upstream answers; that's fine, they get recomputed in step 5.)
2. **Compute the initial frontier** = every node with `dependsOn: []`.
3. **Render the round.** Present the whole frontier as one numbered list, each
   item's `sourceCitation` and `recommendedDefault` visible. Ask the human to
   confirm the set, edit any item, or drop any item. Wait for the full answer
   batch before proceeding — do not act on partial answers.
4. **Apply answers.** For each item: mark `confirmed`, `edited`, or `dropped`
   per the human's response.
5. **Recompute.**
   - Any node whose `dependsOn` includes a `dropped` id is itself dropped —
     removed from the tree entirely, never rendered, never orphaned.
     (Against the concrete engine this means the id is simply never added
     to `settled`, not a literal deletion from `tree.nodes` — see the
     concrete-engine mapping above.)
   - Any node whose `dependsOn` includes an `edited` id has its
     `recommendedDefault` regenerated (re-run the discovery/recommendation
     logic using the edited value as input) before it is ever shown. A node
     whose `dependsOn` are all `confirmed` (no edits, no drops) keeps its
     original recommendation unchanged.
   - Nodes with no path back to an edited/dropped id are untouched — recompute
     is scoped to the affected subtree, not a full re-ask of everything.
6. **Recompute the frontier** = every node not yet rendered whose `dependsOn`
   are now fully settled (confirmed, edited, or — transitively — descended
   only from confirmed/edited nodes).
7. **Repeat from step 3** with the new frontier as the next round, until the
   frontier is empty.
8. **Never block.** Track a round budget (a plugin default; keep it small —
   3–5 rounds covers roles→credentials→scope with room for one clarifying
   round). If the budget is exhausted and the frontier is still non-empty,
   STOP asking: auto-accept the recommended default for every remaining node,
   write each one into the output artifact tagged `"assumption": true` with
   the reason ("round budget exhausted"), and proceed. A logged assumption
   beats an interrogation loop that never lets the run start.

## Worked example: role/persona confirmation (3 rounds)

Discovery has already run (two-plane: a global `UserType` enum plus a
`team_members.role` pivot column) and built the tree before any round is
shown. Facts below (enum cases, seeded users, policy checks) are the
plugin's job — none of them are asked as questions.

### Round 1 — Roles (frontier = every role candidate, no dependencies)

| # | id | source | recommended default |
|---|----|--------|----------------------|
| 1 | `role:super-admin` | `app/Enums/UserType.php:4` (`UserType::SUPER_ADMIN`) | keep — include, test as this role |
| 2 | `role:admin` | `app/Enums/UserType.php:5` | keep |
| 3 | `role:evaluator` | `app/Enums/UserType.php:6` | keep |
| 4 | `role:jury` | `app/Enums/UserType.php:7` | keep |
| 5 | `role:user` | `app/Enums/UserType.php:8` | keep |
| 6 | `role:team-member` | `team_members.role` pivot column (contextual plane), values `owner`/`member` | keep — test as a sub-role of `user` |

**Human answer:** drops item 6 ("team ownership is exercised through
`submission` code paths already covered by `user`; not a distinct authz
boundary worth its own login"). Items 1–5 confirmed as recommended.

**Recompute:** `role:team-member` is dropped. Every Round-2/3 node whose
`dependsOn` included `role:team-member` is removed from the tree — no
orphaned credential or scope entry is ever generated for it. The frontier for
Round 2 = one credential-decision node per surviving role: `{super-admin,
admin, evaluator, jury, user}`.

### Round 2 — Credentials (frontier = one item per settled role)

| # | id | dependsOn | source | recommended default |
|---|----|-----------|--------|----------------------|
| 1 | `cred:super-admin` | `role:super-admin` | `database/seeders/UserSeeder.php:12`, fixture `admin@example.test` | seeded-credential login |
| 2 | `cred:admin` | `role:admin` | same seeder, `type=admin` row | seeded-credential login |
| 3 | `cred:evaluator` | `role:evaluator` | same seeder, `type=evaluator` row (`evaluator@example.test`) | seeded-credential login |
| 4 | `cred:jury` | `role:jury` | no seeded fixture found | storageState capture |
| 5 | `cred:user` | `role:user` | same seeder, `type=user` row | seeded-credential login |

**Human answer:** edits item 3 — the seeded `evaluator@example.test` has no
submissions assigned, so scope tests against it would be vacuous; the human
points at `evaluator2@example.test` instead, which does own assigned work.
Items 1, 2, 4, 5 confirmed as recommended.

**Recompute:** `cred:evaluator`'s bound account changed
(`evaluator@example.test` → `evaluator2@example.test`). Only the Round-3 node
that depends on `cred:evaluator` is regenerated — its `recommendedDefault` is
re-derived from `evaluator2`'s actual assigned-submissions data, not the
original (empty) seed row's. The Round-3 nodes depending on `cred:super-admin`,
`cred:admin`, `cred:jury`, `cred:user` are untouched; the edit's blast radius
stayed scoped to the `evaluator` subtree.

### Round 3 — Scope (frontier = one item per settled credential)

| # | id | dependsOn | source | recommended default |
|---|----|-----------|--------|----------------------|
| 1 | `scope:super-admin` | `cred:super-admin` | no scope filter found in any controller | owns — global |
| 2 | `scope:admin` | `cred:admin` | `HackathonPolicy::view` checks `admin_id` | owns, scoped by `hackathon.admin_id` |
| 3 | `scope:evaluator` | `cred:evaluator` (→ `evaluator2@example.test`) | `submissions.evaluator_id` cross-referenced against `evaluator2`'s 3 assigned rows | read-scoped, `evaluator_id = evaluator2.id` |
| 4 | `scope:jury` | `cred:jury` | `jury_assignments` pivot | read-scoped, rows in `jury_assignments` for this juror |
| 5 | `scope:user` | `cred:user` | `submissions.team_id → teams.id` chain | owns, scoped to `team_id` for the user's teams |

**Human answer:** confirms all five as recommended — no further edits.

**Recompute:** frontier is now empty (nothing left with unsettled
dependencies, nothing left unrendered). Rounds stop. The confirmed set —
5 roles, 5 credential bindings, 5 scope rows — is handed to the consuming
skill's deterministic writer (e.g. `.qa/config.json`'s `personas[]` +
`authzMatrix`, never hand-authored).

### Contrast: an all-defaults-accepted pass-through

If the human had accepted every recommended default with no edits and no
drops in all three rounds above, the recompute step at the end of each round
would find nothing to regenerate (no edited/dropped ids) — each round still
renders exactly once, in order, but produces zero re-prompts. Rounds are not
retried or re-shown once answered; "no edits" simply means the next frontier
computes from the recommendations as given.

## Relationship to `bootstrapping-qa-config`'s own flat form

`bootstrapping-qa-config`'s Step 2 asks 4 questions (base URL, environment,
authentication, allow-writes) as **one flat batch**. That is correct for that
case: none of those 4 answers changes what the other 3 even mean — they are
independent, not a dependency tree. Do not "upgrade" that batch to rounds; it
would add ceremony with no recompute to perform. Reach for rounds only when a
later decision's *option set* — not just its default — depends on an earlier
answer, as roles → credentials → scope does here.
