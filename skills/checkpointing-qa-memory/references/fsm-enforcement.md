# Run FSM enforcement (ADR-0021)

Full record: [ADR-0021](../../../docs/adr/0021-run-fsm-enforcement.md). This doc is the
skill-local reference for the mechanics; see `state-machine-schema.md` for the statechart's
field-by-field shape and the sub-state inference table.

**Not a hard cage.** Three cooperating layers, none of which can *prevent* off-surface work with
Read/Write/browser tools — only detect it after the fact, flag it record-only, or decline to
*write* it:

1. **Fold detects** an illegal sub-state edge after the fact.
2. **`qa-verify` holds record-only phase-surface authority** — it flags, never blocks.
3. **`journal-emit.sh` cooperatively declines** to *write* an illegal edge (best-effort,
   `--force`-able).

The universal authority on every harness is **`qa-verify`** (deterministic, out-of-agent).
Sub-states are **fold-inferred, never agent-emitted** — no CLI change to `checkpoint.sh` or
`journal-emit.sh`.

## `state-machine.json` — the statechart-as-data

`references/state-machine.json` declares, for the whole pipeline:

- `phases` — the 6 **emitted** phase names, ordered: `Pre-flight`(0), `Analyze`(1), `Generate`(2),
  `Verify`(3), `Report`(4), `Remember`(5). This deliberately does NOT match the earlier deferred
  spec's aspirational `PreFlight → Analyze → Discover → Generate → Verify → Report` list — that
  list invented a "Discover" phase the pipeline never emits and omitted "Remember." ADR-0021
  reconciles the drift explicitly.
- `subStates` — `pending, arranging, acting, baking, reconciling, verdict` — internal machine
  state, never a verdict. The verdict vocabulary (`pass|fail|blocked|deferred|error`) and
  confidence (`high|low`) are unchanged and orthogonal.
- `legalPhaseEdges` / `legalSubStateEdges` — the strictly linear phase sequence, and the
  sub-state grammar's three converging paths (mutating: `pending→arranging→acting→baking→
  reconciling→verdict`; non-mutating-but-baked; pure-observe: `arranging→verdict`).
- `guards` — `{edge, requires}`: `arranging→acting` requires `mutates`; `arranging→baking` and
  `arranging→verdict` require `not-mutates`; `acting→baking` requires an observed
  `act_committed`; `*→verdict` requires the honesty gate.
- `toolClasses` / `phaseToolSurface` — the closed tool-class vocabulary and each phase's
  allowed/forbidden classes (e.g. `Verify` allows `browser-interaction`/`probe`/etc. but forbids
  `browser-evaluate-mutating`; `Report`/`Remember` forbid all `browser-mutation` and
  `browser-navigate`).

`scripts/validate-state-machine.sh <path>` checks the file is structurally well-formed and
internally cross-referenced (every edge/guard/phaseToolSurface entry references a declared
phase/sub-state/tool class). It is a contract checker, not an enforcement engine — fold and
`qa-verify` are the engines that read this data and hold only the generic edge-check procedure,
never a hard-coded phase or sub-state name. Editing this file changes behavior in all three
consuming mechanisms with no code change.

## Fold: sub-state inference + `illegal-edge` anomaly

`fold.jq`/`fold.py`'s pass-2 per-tuple state tracks `act_intent`/`act_committed` alongside the
existing `started`/`verdict` tracking, and derives each tuple's current `subState` purely from
replaying journal events already emitted by Plan B (`plan_frozen`, `criterion_started`,
`act_intent`, `act_committed`, `criterion_verdict`) — no new event type. `cursor.json` gained a
`subState` field. An observed transition not in `state-machine.json`'s `legalSubStateEdges`
(e.g. `act_committed` with no prior `act_intent`) is recorded as an `illegal-edge` anomaly in
`fold-anomalies.json`: `{rule:"illegal-edge", tuple, from, to, guard}` — never a fold abort,
matching every other fold anomaly rule's "record and stay total" discipline.

## `qa-verify`: phase-surface enforcement (record-only)

`qa-verify.sh` gained a phase-surface pass: it reads the journal's `phase_entered` timeline and
each criterion's acting windows (`act_intent`→`act_committed`), the H2 `toolstream.jsonl`
(`ts`/`seq`, no phase tag), and `state-machine.json`'s `phaseToolSurface`, then temporally
correlates each toolstream call to the phase active at its timestamp. Two independent checks:
a mutating tool call outside every acting window (gated on `windows_active` — true only when at
least one acting window was actually recorded, since the 3-arg `checkpoint.sh` CLI emits none),
and a tool call whose class is forbidden for the currently-active phase (e.g. `browser_*` after
`Report`), which fires regardless of `windows_active`. Either finding lands in `verification.json`
as a synthetic `criterionId:"__phase-surface__"` record with **`verifierVerdict:"pass"` and
`confidence:"low"`, always** — record-only, never a hard override of any criterion's verdict. No
`toolstream.jsonl` → the pass is skipped entirely (degrade, never a false positive).

## Transition guard: cooperative decline (best-effort)

`journal-emit.sh`'s `act-intent`/`act-commit` subcommands run a pre-append guard: infer the
tuple's sub-state from the journal, check the implied edge against `state-machine.json`'s
`legalSubStateEdges` (path overridable via `STATE_MACHINE_JSON`), and **decline** — nothing
appended, non-zero exit, message naming the violated edge — on an illegal edge (`act-commit`
with no prior `act-intent`; `act-intent` with no prior `criterion_started`). `--force` bypasses
the decline (logged as a NOTE on stderr). Absent `state-machine.json` → the guard skips entirely
(never dies — the guard is best-effort, not the authority). The 3-arg `checkpoint.sh` path is
untouched. This guards **recorded** state only; it cannot stop off-surface work bypassing
`journal-emit.sh` altogether — that gap is `qa-verify`'s to close.

## Per-harness assurance tier

Codex's managed sandbox gives the block-hook's phase-independent absolutes the strongest live
backing. Claude/Pi/opencode run the identical bundled hook logic but only best-effort — the hook
script files are user-writable unhardened, with no hash-chain. Porting Codex-grade live
enforcement to the other three harnesses is pending H4 work, not yet shipped. **`qa-verify` is
the universal deterministic authority on every harness**, independent of hook tier.

## Scripts

| Script | Usage |
|---|---|
| `scripts/validate-state-machine.sh <path>` | Structural validator for `state-machine.json` — every edge/guard/phaseToolSurface entry cross-references a declared phase/sub-state/tool class |
| `scripts/fold.sh <run-id>` | (Also documented in the main SKILL.md Scripts Reference.) Now also derives each tuple's `subState` into `cursor.json` and records `illegal-edge` anomalies into `fold-anomalies.json`, dispatching to `fold.jq`/`fold.py` |
