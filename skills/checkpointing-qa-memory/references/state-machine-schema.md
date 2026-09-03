# `state-machine.json` schema

`state-machine.json` (`skills/checkpointing-qa-memory/references/state-machine.json`)
is the **statechart-as-data** for a Run (ADR-0017 / Run FSM Enforcement).
It declares the pipeline's 6 phases, the per-criterion sub-states, the legal
edges between them, the transition guards, and the per-phase tool surface.
It is a **contract**, not an enforcement engine: this skill's
`validate-state-machine.sh` only checks the file is structurally well-shaped
and internally cross-referenced. The engines that actually READ this data —
`fold.jq`/`fold.py` (per-criterion sub-state inference + the `illegal-edge`
anomaly) and `qa-verify.sh` (phase-surface enforcement) — are later tasks;
they hold only the *generic* edge-check procedure, never a hard-coded phase
or sub-state name. Renaming/adding a phase, sub-state, or edge is a **data
edit** to this file, not a code change.

**Not a hard cage.** Per the Run FSM Enforcement plan's Global Constraints,
phase-surface enforcement is record-only → `qa-verify` (the authority); the
cooperative transition guard (a later task) only *declines to record* an
illegal edge — it cannot prevent off-surface work with Read/Write/browser
tools. This file is the shared data both mechanisms read; it is not itself a
live bound on what the agent can do.

## Top-level shape

```json
{
  "phases": [{"id": "Pre-flight", "order": 0}, ...],
  "subStates": ["pending", "arranging", "acting", "baking", "reconciling", "verdict"],
  "legalPhaseEdges": [["Pre-flight", "Analyze"], ...],
  "legalSubStateEdges": [["pending", "arranging"], ...],
  "guards": [{"edge": ["arranging", "acting"], "requires": "mutates"}, ...],
  "toolClasses": ["browser-navigate", ...],
  "phaseToolSurface": {
    "Verify": {"allowedToolClasses": [...], "forbiddenToolClasses": [...]}
  }
}
```

## Fields

### `phases` (array, required)

One entry per Run phase, `{id: non-empty string, order: number}`. **The 6
phase ids are the pipeline's EMITTED names, exactly as `core/persona-body.md`
numbers and names them** — `Pre-flight`(0), `Analyze`(1), `Generate`(2),
`Verify`(3), `Report`(4), `Remember`(5) — matched case-insensitively to the
free-text `--phase` value a caller supplies. This deliberately does **not**
match the earlier deferred spec's aspirational `PreFlight → Analyze →
Discover → Generate → Verify → Report` list: that list invented a "Discover"
phase the pipeline never emits, and omitted "Remember" (the pipeline's phase
5, `checkpointing-qa-memory`). This file adopts **reality** — the drift is
reconciled in ADR-0021, not here. `order` values must be unique (checked by
the validator) — they establish the pipeline's declared linear sequence,
independent of array position.

### `subStates` (array of strings, required)

The 6 per-criterion sub-states, in the canonical order a mutating criterion
passes through them: `pending`, `arranging`, `acting`, `baking`,
`reconciling`, `verdict`. These are **internal machine state, never a
verdict** — the verdict vocabulary (`pass|fail|blocked|deferred|error`) is
unchanged and orthogonal. Sub-states are **fold-inferred** from existing
journal events (see the inference table below) — there is no new emission
protocol; `checkpoint.sh`'s 3-arg CLI is untouched.

### `legalPhaseEdges` (array of `[from, to]` string pairs, required)

The Run's phase sequence is strictly linear and forward-only (this pipeline
never loops a phase back onto an earlier one):

```
Pre-flight → Analyze → Generate → Verify → Report → Remember
```

Every pair's `from`/`to` must be a declared phase id (checked by the
validator).

### `legalSubStateEdges` (array of `[from, to]` string pairs, required)

See "The sub-state grammar" below for the full edge-by-edge rationale.
Every pair's `from`/`to` must be a declared sub-state (checked by the
validator).

### `guards` (array of `{edge, requires}`, required)

A guard names a precondition for observing a specific sub-state edge.
`edge` is either:
- a **literal** `[from, to]` pair that must appear (verbatim) in
  `legalSubStateEdges`, or
- the **wildcard** form `["*", to]`, matching a transition into `to` from
  *any* source sub-state — used for the honesty-gate guard, which applies
  uniformly regardless of which sub-state a criterion verdicts from.

`requires` is a non-empty string naming the precondition; this file does not
interpret it — fold/qa-verify (later tasks) look the name up. The four
guards this file declares:

| Edge | `requires` | Meaning |
|---|---|---|
| `arranging → acting` | `mutates` | Only a criterion whose frozen-plan entry (`plan_frozen`'s per-criterion `mutates` field) is `true` may open an act window. |
| `arranging → baking` | `not-mutates` | The mirror guard: the skip-acting edge is only legal for a criterion whose `mutates` is `false`. |
| `arranging → verdict` | `not-mutates` | The pure-observe edge (a criterion with no bake at all): only legal for a `mutates:false` criterion. This closes the gap where a **mutating** criterion that skipped its act entirely would otherwise take the same unguarded `arranging → verdict` path as a legitimate observe-only criterion — with this guard, the fold flags a `mutates:true` tuple reaching `verdict` without an `acting` window as an illegal edge. |
| `acting → baking` | `act_committed` | Entering `baking` from `acting` requires an observed `act_committed` event for that criterion's key (closing the act the criterion opened). |
| `* → verdict` | `honesty-gate` | Any transition into `verdict`, regardless of source sub-state, is gated by the existing pass-gate machinery (`checkpoint.sh` + `required-kinds.sh`) — a `pass` must carry the evidence the gate independently re-derives. |

### `toolClasses` (array of strings, optional)

The closed vocabulary `phaseToolSurface` entries are drawn from — declared
here so the validator can catch a typo'd/invented class name, and so a
future reader has one place to see the full set:

| Class | Covers | Notes |
|---|---|---|
| `browser-navigate` | `browser_navigate`, `browser_navigate_back`, `browser_tabs`, `browser_resize` | Pure navigation; never itself a mutation of app data. |
| `browser-snapshot` | `browser_snapshot`, `browser_take_screenshot`, `browser_console_messages`, `browser_network_requests`, `browser_network_request` | Passive observation/read tools. |
| `browser-interaction` | `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_select_option`, `browser_hover`, `browser_file_upload`, `browser_handle_dialog`, `browser_drag`, `browser_drop` | The **sanctioned** human-path mutation route (ADR-0015) — driving state through real UI affordances. |
| `browser-evaluate-readonly` | `browser_evaluate` calls classified non-mutating by `parse-session-log.js`'s `mutates()` | In-page reads/observation via injected JS. |
| `browser-evaluate-mutating` | `browser_evaluate` calls classified mutating by `mutates()` | A **workaround** outside a criterion's `acting` window (ADR-0015) — the act phase is UI-only; this class is what the honesty gate and the Verify tool-surface forbid. |
| `browser-mutation` | The **umbrella** of every class that can mutate app/browser state: `browser-interaction` ∪ `browser-evaluate-mutating` (∪ a mutating `route`/interception, when present) | Never itself listed in an `allowedToolClasses` — it exists purely as a coarse label for phases where **no** mutation of any kind is sanctioned (see `phaseToolSurface` below). |
| `probe` | `probing-apis-through-browser`'s in-page authenticated fetch / `backend-probe.js` reads | Read-only unless `allowApiWrites` + the disposable-env marker is set (unrelated config, not modeled here). |
| `bash` | Any Bash tool invocation (`checkpoint.sh`, `journal-emit.sh`, `record-evidence.sh`, `detect-stack.sh`, `preflight.sh`, ...) | The pipeline's own bookkeeping/tooling calls — always sanctioned everywhere; every phase's `allowedToolClasses` includes it. |

Mapping a *real* tool name to one of these classes (and correlating that
call's timestamp against the journal's phase timeline) is `qa-verify`'s job
(a later task) — this file only declares the vocabulary and which phases
sanction which classes.

### `phaseToolSurface` (object, required)

One entry per phase (key = a declared phase id), each
`{allowedToolClasses?: [string], forbiddenToolClasses?: [string]}` (both
optional; either may be omitted or `[]`). This is the **temporal**
enforcement surface: a later task correlates a toolstream call's `ts`/`seq`
against the journal's phase timeline and flags a call whose class is
forbidden for the phase active at that moment.

| Phase | Allowed | Forbidden | Rationale |
|---|---|---|---|
| `Pre-flight` | navigate, snapshot, evaluate-readonly, bash | `browser-mutation` | Reachability/auth/driver checks are read-only. |
| `Analyze` | navigate, snapshot, evaluate-readonly, bash | `browser-mutation` | Stack/surface detection reads the app and code; never writes. |
| `Generate` | bash | `browser-mutation`, `browser-navigate` | Checklist generation works from the surface map + code; no live browser needed. |
| `Verify` | interaction, evaluate-readonly, navigate, snapshot, probe, bash | `browser-evaluate-mutating` | The only phase where mutation is sanctioned — but only through the **human-path** `browser-interaction` class; a raw mutating `evaluate` is the ADR-0015 workaround the gate rejects, even here. |
| `Report` | bash | `browser-mutation`, `browser-navigate` | Report writing is offline synthesis of already-captured evidence. |
| `Remember` | bash | `browser-mutation`, `browser-navigate` | Checkpointing/journaling never touches the browser. |

Note `Verify`'s forbidden list names only `browser-evaluate-mutating`, not
the coarser `browser-mutation` — `browser-interaction` (the sanctioned
human-path route) is explicitly *allowed* there, so the coarse umbrella
would be wrong. The other five phases forbid the coarse `browser-mutation`
because **no** mutation of any kind is sanctioned in them.

## The sub-state grammar

**Every criterion always begins with `criterion_started`** (persona-body.md
phase 3: "For each criterion, at its start journal `criterion_started`") —
so `pending → arranging` is the one edge every criterion takes, unconditionally.
From `arranging`, three paths diverge, all landing on `verdict`:

1. **Mutating path** — a criterion whose frozen-plan `mutates` is `true`
   opens an act window, closes it, then bakes/reconciles:
   ```
   pending → arranging → acting → baking → reconciling → verdict
   ```
   (`arranging→acting` guarded by `mutates`; `acting→baking` guarded by
   `act_committed`.)

2. **Non-mutating, still-baked, path** — a criterion that never mutates
   (`mutates: false`) has no act window (persona-body.md: "derive-gated by
   `mutation-flag.sh`, a **no-op** for a non-mutating criterion" — no
   `act_intent`/`act_committed` is ever emitted for it) but still performs a
   baking/computed-logic read (e.g. a multiplicity-0 empty-state read, or a
   read-only reconciliation) before its verdict:
   ```
   pending → arranging → baking → reconciling → verdict
   pending → arranging → baking → verdict            (reconciling collapsed — see below)
   ```
   (`arranging→baking` guarded by `not-mutates`.)

3. **Pure-observe path (no bake at all)** — a criterion with no act *and* no
   distinguishable read-back/reconciliation step either (e.g. "observe the
   loading spinner renders", a rendering-only check with nothing to bake)
   goes straight from `arranging` to `verdict`:
   ```
   pending → arranging → verdict
   ```

**Decision (resolving the brief's open question): `pending → verdict` is
NOT a legal edge.** Since `criterion_started` is mandatory and unconditional
for every criterion in this pipeline, a `criterion_verdict` observed for a
tuple that never saw a `criterion_started` is not a legitimate "pure-observe
skip" — it is a **missing event**, and fold already flags exactly this case
today as the `verdict-without-started` anomaly (`fold.jq`/`fold.py`,
pre-dating this statechart). The pure-observe case this file supports is
`arranging → verdict` (case 3 above), which still requires the mandatory
`criterion_started` to have fired first.

**Baking/reconciling window (documented simplification).** The dynamic
journal events carry no distinct signal for "entered reconciling" separate
from "entered baking" — `verifying-backend-persistence`'s read-back and
`verifying-computed-logic`'s independent recompute are both *steps* inside
the same criterion, not separately journaled sub-phases. When a future event
type distinguishes them, `baking → reconciling → verdict` is the edge to
use; **until then, fold's Task 2 inference treats `baking` and `reconciling`
as the same observed window**, and a criterion that never distinctly signals
`reconciling` legally verdicts directly via `baking → verdict`. Both edges
are declared so neither shape is ever flagged `illegal-edge`.

## Sub-state inference table (what fold — a later task — reads)

Fold infers a tuple's (scenarioId, criterionId, personaId) current
sub-state purely from the existing journal events — **no new event type**.
The frozen plan's per-criterion `mutates` field (from the `plan_frozen`
event) participates in the mutating/non-mutating branch below.

| Sub-state | Inferred when |
|---|---|
| `pending` | The tuple is listed in `plan_frozen`'s `criteria`/`order`, but no `criterion_started` has been observed for it yet. |
| `arranging` | `criterion_started` observed; no `act_intent` observed for its key; verdict not yet observed. Also the terminal inferred state for a non-mutating tuple **before** any bake-signal is separately available (see the baking/reconciling note above — until a future event distinguishes it, a non-mutating tuple's fold-visible state stays `arranging` up to its verdict, and its overall arc is validated against the grammar's `arranging → verdict` / `arranging → baking → verdict` shapes, not against a literal mid-run "now in baking" read). |
| `acting` | `act_intent` observed for the key; no matching `act_committed` yet; verdict not yet observed. |
| `baking` | `act_committed` observed for the key; verdict not yet observed. (A non-mutating tuple has no `act_committed` to observe — see the note above; its transition into `verdict` is still valid per the `arranging → baking → verdict` / `arranging → verdict` grammar shapes even though fold has no discrete "now in baking" moment to report for it.) |
| `reconciling` | Same observed window as `baking` today (no separate signal) — see "documented simplification" above. |
| `verdict` | `criterion_verdict` observed for the tuple. |

**Illegal-edge candidates** (Task 2 formalizes these against
`legalSubStateEdges`): `act_committed` with no prior `act_intent` for the
same key (already flagged today as `act-committed-no-intent`; Task 2 reframes
it as an `illegal-edge` against this file's grammar); `criterion_verdict`
with no prior `criterion_started` (already flagged today as
`verdict-without-started`).

## Worked example

A mutating criterion `C-FOUNDERS-01` (scenarioId `s1`, personaId `p1`) whose
frozen-plan entry carries `mutates: true`:

```
journal:
  plan_frozen      {criteria:[{criterionId:"C-FOUNDERS-01", scenarioId:"s1", personaId:"p1", mutates:true}], order:["C-FOUNDERS-01"]}
  criterion_started {scenarioId:"s1", criterionId:"C-FOUNDERS-01", personaId:"p1"}
  act_intent        {key:"s1|C-FOUNDERS-01|p1", writeSet:{...}}
  act_committed     {key:"s1|C-FOUNDERS-01|p1", outcome:"landed"}
  criterion_verdict {scenarioId:"s1", criterionId:"C-FOUNDERS-01", personaId:"p1", verdict:"pass", ...}
```

Inferred sub-state sequence: `pending` (after `plan_frozen`, before
`criterion_started`) → `arranging` (after `criterion_started`) → `acting`
(after `act_intent`) → `baking` (after `act_committed`) → `verdict` (after
`criterion_verdict`, taking the `baking → verdict` edge since no distinct
`reconciling` signal exists). Every observed transition
(`pending→arranging`, `arranging→acting`, `acting→baking`, `baking→verdict`)
is a member of `legalSubStateEdges` — no `illegal-edge` anomaly.

Contrast: if the same journal were missing `act_intent` (only
`act_committed` appears), fold's existing `act-committed-no-intent` anomaly
fires, and — per this file's grammar — the observed jump `arranging →
baking` via a commit-with-no-intent is also an `illegal-edge` against the
*mutating* path (it is legal only under the `not-mutates` guard, which does
not hold here since `plan_frozen` declared `mutates: true`).

## Validating structurally

```
skills/checkpointing-qa-memory/scripts/validate-state-machine.sh <path-to-state-machine.json>
```

Exits `0` iff the file is valid JSON and every cross-reference holds: every
`legalPhaseEdges`/`legalSubStateEdges` pair references a declared phase/
sub-state; every `guards[].edge` is a declared `legalSubStateEdges` entry or
a `["*", <sub-state>]` wildcard; every `phaseToolSurface` key is a declared
phase id; declared phases have unique `order` values; and (when
`toolClasses` is present) every `phaseToolSurface` class name is a member of
it. Exits non-zero with one `ERROR: ...` line per violation, naming the
offending index/field — e.g. `ERROR: legalSubStateEdges[8]: "bogus" is not a
declared subState`.
