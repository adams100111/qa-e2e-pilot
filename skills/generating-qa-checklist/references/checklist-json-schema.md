# `checklist.json` schema

`checklist.json` is the machine-readable sibling of `checklist.md`, written
alongside it to `.qa/runs/<run-id>/checklist.json` (Step 8 of this skill).
Where `checklist.md` is the human-editable review artifact, `checklist.json`
is what the honesty-gate scripts parse programmatically:

- **`checkpoint.sh`** (`skills/checkpointing-qa-memory/scripts/checkpoint.sh`,
  Plan H1 Task 3) reads a criterion's `kind`/`tags`/`action` from its row here
  and feeds them to `required-kinds.sh derive` to independently re-derive the
  evidence kinds a `pass` must carry, then rejects a checkpointed `pass`
  unless the recorded `--kinds` is a **superset** of that re-derivation.
- **`record-evidence.sh`** / `check-action-trace.js` Check 3 (Plan H1
  Task 4) read a criterion's `assertedState` from its row here as the
  **fingerprint target**: the persisted-state key the act phase's
  before/after fingerprint must cover (and show changed, when the oracle
  expects a change).

## `checklist.json` is a PROPOSAL, not ground truth

`checklist.json` is written by the same agent that will later run
verification and checkpoint results. **The gate never trusts this file's own
`requiredKinds` field** — `checkpoint.sh` reads only the *structural* facts
(`kind`, `tags`, `action`) from a row and re-derives `requiredKinds` itself
via `required-kinds.sh`, exactly as if the row's `requiredKinds` field did
not exist. Writing a weaker `requiredKinds` here (e.g. omitting
`human-action` on a mutating criterion) does not help an adversarial agent
evade the gate — it is simply ignored. The field exists as documentation /
a sanity cross-check for a human reviewer, not as an input to enforcement.

This validator (`scripts/validate-checklist-json.sh`) checks only that the
file is **structurally well-shaped** — right fields, right types, enum
membership, no duplicate ids — so the gate scripts can parse it reliably. It
makes no judgment about whether a row's claims (`requiredKinds`,
`assertedState`, `humanAction`) are *honest*; that is exactly the boundary
`checkpoint.sh`'s independent re-derivation exists to police (see
`skills/checkpointing-qa-memory/SKILL.md`'s honest-tier note).

## Shape

Top-level: a JSON **array** of per-criterion objects. An empty array (`[]`)
is valid — a Run with no criteria generated yet.

```json
[
  {
    "id": "C-FOUNDERS-01",
    "surface": "/governance/founders",
    "kind": "happy-path",
    "tags": ["human-action"],
    "action": "Fill the founder form (name, shares) and submit",
    "requiredKinds": ["bake", "human-action"],
    "assertedState": {
      "entity": "Founder",
      "readBackPath": "count",
      "expectChange": true
    },
    "humanAction": true
  },
  {
    "id": "C-FOUNDERS-EMPTY-00",
    "surface": "/governance/founders",
    "kind": "multiplicity-0",
    "tags": ["read-only"],
    "action": "View the founders list before any create",
    "requiredKinds": [],
    "assertedState": null,
    "humanAction": false
  }
]
```

## Per-entry fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | **yes** | Non-empty. Matches the criterion's `checklist.md` block ID (e.g. `C-FOUNDERS-01`). Must be unique across the file — a duplicate `id` is a validation error. |
| `surface` | string | **yes** | The route/sub-tab this criterion exercises (matches `checklist.md`'s Surface field). May be empty string for a criterion with no single surface (rare); still must be present and a string. |
| `kind` | string | **yes** | One of the 12-value Kind enum (below). Matches `checklist.md`'s Kind field exactly. |
| `tags` | array of string | **yes** | May be empty (`[]`). Matches `checklist.md`'s Tags field — `independent`, `read-only`, `race`, `cross-tenant`, `cross-role-fk-chain`, `role-sensitive`, `probe-needed`, `human-action`, or none. |
| `action` | string | **yes** | One-line description of the action under test (matches `actionUnderTest` for `human-action`-tagged criteria per Step 7, or the read/observe action otherwise). |
| `requiredKinds` | array of string | optional | **Advisory only** — see "PROPOSAL, not ground truth" above. When present, each element must be one of the four-kind evidence vocabulary: `bake`, `computed`, `probe`, `human-action` (matches `required-kinds.sh`'s vocabulary, `skills/checkpointing-qa-memory/scripts/required-kinds.sh`). May be `[]` for a criterion that requires no evidence kind (e.g. a pure-display, non-probed read). |
| `assertedState` | object or `null` | optional | The fingerprint target for Task 4's Check 3 coverage check. `null` (or the field omitted) means the criterion asserts no specific before/after target — Check 3's back-compat aggregate-`changed` behavior applies. When present as an object, all three sub-fields below are required. |
| `assertedState.entity` | string | required if `assertedState` present | The entity name the fingerprint targets (e.g. `"Founder"`, `"Holding"`) — matches the criterion's Baking assertion `Entity` field in `checklist.md`. |
| `assertedState.readBackPath` | string | required if `assertedState` present | The key/path into the before/after fingerprint that must be present and (per `expectChange`) checked for a value change. A simple top-level key (e.g. `"count"`) or a dot-path (e.g. `"holdings.length"`) — see `check-action-trace.js`'s documented path grammar. |
| `assertedState.expectChange` | boolean | required if `assertedState` present | `true` when the oracle expects this target's value to differ before→after (the common case for a create/update/delete). `false` when the oracle expects the target to be present but **unchanged** (e.g. a rejected invalid write, an idempotent repeat action). |
| `humanAction` | boolean | optional | Mirrors the `human-action` tag — `true` when the Act phase mutates state or drives a control through the UI (Step 7's mechanical rule). Like `requiredKinds`, this is descriptive; the gate's own mutation classification (`mutation-flag.sh derive`, reused inside `required-kinds.sh`) is what actually governs enforcement, not this field. |

## `kind` enum (exact, 12 values)

```
happy-path
multiplicity-0
multiplicity-1
multiplicity-N
empty-state
loading-state
error-state
computed-logic
business-rule
downstream-cascade
cross-tenant
race
```

This is the same list as `checklist.md`'s Kind field comment and
`required-kinds.sh`'s kind-enum regexes — keep all three in sync if the
vocabulary ever changes.

## `requiredKinds` / evidence-kind vocabulary (exact, 4 values)

```
bake
computed
probe
human-action
```

Fixed at four kinds, no fifth (`docs/adr/0018-out-of-agent-evidence-enforcement.md`,
`CONTEXT.md`). This is the same vocabulary `required-kinds.sh derive` and
`checkpoint.sh --kinds` use.

## Worked example — a mutating criterion with `assertedState`

A "create a founder" happy-path criterion, tagged `human-action` because its
Act phase submits a form:

```json
{
  "id": "C-FOUNDERS-01",
  "surface": "/governance/founders",
  "kind": "happy-path",
  "tags": ["human-action"],
  "action": "Fill the founder form (name=\"Jordan\", shares=1000000) and click Add Founder",
  "requiredKinds": ["bake", "human-action"],
  "assertedState": {
    "entity": "Founder",
    "readBackPath": "count",
    "expectChange": true
  },
  "humanAction": true
}
```

`required-kinds.sh derive` on `{"kind":"happy-path","tags":["human-action"],"action":"..."}`
independently re-derives `bake,human-action` from the shape alone (a
mutating action-verb plus a `happy-path` kind not tagged `read-only`) — the
same set this row's own `requiredKinds` claims, but arrived at without
trusting the row. `checkpoint.sh` requires the checkpointed `--kinds` for
`C-FOUNDERS-01` to be a superset of that independent re-derivation, not of
this file's `requiredKinds` field.

The `assertedState` here declares that the fingerprint captured around the
Act phase must contain a `count` key and that `count` must differ
before→after (a founder was added). Check 3 (Task 4) enforces that coverage
+ change requirement; the criterion's own `expectChange: true` claim is not
independently re-derivable the way `requiredKinds` is (there is no
shape-only rule for "does this write change a count") — this is exactly the
in-script best-effort tier described in
`skills/checkpointing-qa-memory/SKILL.md`'s honest-tier note: Check 3 closes
"the fingerprint covers only an unrelated field" and "the target didn't
actually change," not "the agent lied about what `assertedState` should be."

## Worked example — a read-only criterion (no `assertedState`)

```json
{
  "id": "C-FOUNDERS-LIST-VIEW",
  "surface": "/governance/founders",
  "kind": "loading-state",
  "tags": ["read-only"],
  "action": "Observe the founders list while the page is loading",
  "requiredKinds": [],
  "assertedState": null,
  "humanAction": false
}
```

No write, no fingerprint target — `required-kinds.sh derive` on this shape
(a `loading-state` kind, no mutating verb, tagged `read-only`) correctly
derives the empty set, matching this row's own `requiredKinds: []`.

## Validating structurally

```
skills/generating-qa-checklist/scripts/validate-checklist-json.sh <path-to-checklist.json>
```

Exits `0` iff the file is valid JSON, its top-level is an array, and every
entry matches this schema (types, enum membership, no duplicate `id`s).
Exits non-zero with an `ERROR: ...` line per violation, each naming the
offending entry's index and field — e.g.
`ERROR: entry[2].kind: bogus-kind: must be one of the kind enum`. This
checks *shape* only; it does not re-derive `requiredKinds` or validate that
`assertedState` values are honest (see "PROPOSAL, not ground truth" above).
