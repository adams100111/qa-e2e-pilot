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

This validator (`scripts/validate-checklist-json.sh`) checks two things.
First, that the file is **structurally well-shaped** — right fields, right
types, enum membership, no duplicate ids — so the gate scripts can parse it
reliably. Second (see "Error-honesty invariants" below), that **no criterion
is authored so that an application failure is the correct answer**. It still
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

## Error-honesty invariants — a criterion may not assert that the application failed

Beyond shape, the validator enforces one semantic rule (spec
`docs/superpowers/specs/2026-09-23-error-honesty-invariants-design.md` §4.1,
[ADR-0026](../../../docs/adr/0026-engine-invariants-outrank-frozen-plan.md)):
**a criterion may not be authored so that an APPLICATION FAILURE is the
correct answer.** This is the check that would have caught the originating
incident, whose criterion pinned `page.rendersWithoutServerError` to the
string `"false"` and so graded an HTTP 500 as a match.

### The governing principle: reject process language, never behaviour language

> **A 3xx or 4xx can be correct behaviour. A 5xx, an unhandled exception, or
> a page crash never can.**

An authorization refusal (a 302 to login, a 403), a validation rejection, a
404 on a deleted record — those are the application **working**, and real
criteria assert exactly that, so they stay legal. A 500, an unhandled
exception page, or a load-time crash is the application **failing**, and no
criterion may pin it as expected.

The same line governs the prose layer. *"Deferred by design"* describes a
decision about the team's backlog and has no business in an oracle, so it is
hard-rejected. *"Expected to fail"* describes the **application** and is
frequently correct — *"the save is expected to fail with a validation
error"* is a sound oracle for an `error-state` criterion. An earlier draft
rejected that phrase in the oracle field, which is precisely where its
legitimate use lives; that would have produced the false-positive class that
makes authors route around a validator.

### Layer 1 — the reserved health namespace (structural)

Checked on `fixture.expect` **and** on a top-level `expect`. These
`expect.path` values describe whole-page or transport health rather than a
domain value:

| `expect.path` | Rejected when |
|---|---|
| `page.rendersWithoutServerError` | `value` is false |
| `page.crashed` | `value` is true |
| `console.hasError` | `value` is true |
| `http.status` | `value` >= 500 |

- **Every spelling of the same assertion is caught.** `value` is normalised
  first, so the boolean (`false`), its string form (`"false"`, `"TRUE"`,
  `" false "` — trimmed, case-folded) and its `0`/`1` form (`page.crashed: 1`
  *is* `page.crashed: true`) all land on the same verdict. For
  `http.status`, both the number `500` and the string `" 500 "` count.
- **`path` is trimmed but deliberately NOT case-folded** — a fuzzy path match
  risks rejecting a legitimate domain path.
- **An `http.status` in the 3xx/4xx range is LEGAL** and must stay so.
- **Paths outside the namespace are untouched** — a domain assertion like
  `counts.evaluators = 2` is unaffected.
- **Deliberate accepts**, pinned by the test matrix so they stay decisions
  rather than surprises: a non-ASCII digit spelling (`٥٠٠`, `５００`), an
  underscored `"1_000"` and an exponent `"5e2"` are not numbers under the
  strict ASCII parse, so an `http.status` pinned to one of them is accepted.
- Each structural message ends with the remediation pointer
  `— move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)`.

### Layer 2 — the reserved prose phrase

Exactly one phrase is hard-rejected, matched **case-insensitively**:
**`deferred by design`**.

- Scanned **only** in the oracle/expect string fields: `oracle`,
  `oracleNote`, `expected`, and the string members of `fixture.expect` /
  `expect`.
- **`action` is NEVER inspected.** That is where an author legitimately
  describes a non-rendering state ("this list does not render until the
  challenge reaches Judging"), and an over-broad net there would make the
  validator something authors route around.
- `expected to fail`, `known defect` and `not a regression` are **not**
  rejected here. They describe application behaviour, so they are demoted to
  `/qa-analyze` **`plan-defect`** flags (printed above its verdict line, so
  they cannot be quietly blessed) — see `qa-kit/commands/qa-analyze.md`.

### The fields this layer reads

`fixture`, `expect`, `oracle`, `oracleNote` and `expected` are **optional
extension fields** — this validator does not require them and does not
type-check them. A `fixture` that is not an object, or an `expect` that is
not an object, contributes no violation rather than an error; the honesty
layer simply has nothing to read. `fixture.expect` is written by qa-kit's
`/qa-scenarios` TDQA augmentation (`{path, value, tolerance, oracleSource}`
for a computing criterion) and gated separately for presence/shape by
`qa-kit/scripts/check-fixtures.sh`.

### Where an inverted criterion is supposed to go

A real, known, unfixed application defect belongs in the project-level
registry `.qa/known-defects.json` (validated by `scripts/known-defects.sh`),
never in a criterion. For one already in a plan, run
`qa-kit/scripts/migrate-inverted-criterion.sh <checklist.json> <criterion-id>`
— it removes the criterion, files the defect with `ticket`/`expiry` empty,
and **exits 2 as its success path** (exit 1 is failure; 0 is never returned).
A known defect is never a verdict: it has no `pass`/`fail` and contributes
nothing to the tally.

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

## Validating

```
skills/generating-qa-checklist/scripts/validate-checklist-json.sh <path-to-checklist.json>
```

Exits `0` iff the file is valid JSON, its top-level is an array, every entry
matches this schema (types, enum membership, no duplicate `id`s), **and no
entry asserts that the application failed**. Exits non-zero with an
`ERROR: ...` line per violation, each naming the offending entry's index and
field — e.g. `ERROR: entry[2].kind: bogus-kind: must be one of the kind enum`
or
`ERROR: entry[0].fixture.expect: page.rendersWithoutServerError may not be pinned to false — move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)`.
**Every** violation is reported, not just the first. It does not re-derive
`requiredKinds` or validate that `assertedState` values are honest (see
"PROPOSAL, not ground truth" above).

Engines: `jq` preferred, `python3` fallback (`QA_ENGINE=jq|python3` forces
one). Both engines normalise identically and neither uses its own language's
string-to-number coercion — `tests/validate-checklist-json/run.sh` carries a
dual-engine parity matrix, because legality must not depend on `QA_ENGINE` or
`PATH`.
