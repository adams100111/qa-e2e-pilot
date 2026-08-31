# ADR-0010 — Execution-enforcement evidence gate: derived `kinds`, enforced in `checkpoint.sh`

## Status

Accepted (2026-08-30). Part of the accuracy overhaul ([docs/plans/2026-08-30-qa-accuracy-persona-overhaul.md](../plans/2026-08-30-qa-accuracy-persona-overhaul.md)).

## Context

The measured baseline missed bug classes #1 (F1) and #3 (F3) partly through an **execution-discipline**
failure, not a detection failure: the agent drove the UI, saw a green toast, and recorded `pass`
without ever baking the write back or independently recomputing the business rule. Nothing in the
pipeline made that gap visible or blocked it — a `pass` was structurally indistinguishable whether or
not the agent actually did the verification steps `walking-multistep-flows` /
`verifying-backend-persistence` / `verifying-computed-logic` describe. This is the "a green toast is
not a pass" problem the master plan names as the R1 execution-discipline miss-class.

Phase 1 needed a mechanical, un-bypassable check that a `pass` is backed by the evidence its
criterion actually requires — without inventing new authoring surface, without adding a bypassable
side-step, and without touching the verdict vocabulary.

## Decision

Four settled decisions, together:

1. **Required evidence `kinds` are DERIVED, not hand-authored.** A criterion does not carry a new,
   independent `kinds: [...]` field for an author to fill in (and drift from the rest of the
   checklist). Instead `generating-qa-checklist` computes a CSV `Kinds` subset of `bake|computed|probe`
   deterministically from fields the checklist already carries — `Kind` (e.g. `computed-logic`,
   `downstream-cascade`, `happy-path`) and `Tags` (`read-only`, `cross-tenant`, `probe-needed`) — via
   the mapping table in `generating-qa-checklist/SKILL.md` (Step 6, "Derive `Kinds`"). `probe-needed`
   is a **first-class generator-set tag**: the generator decides it mechanically (oracle value is
   server-side-only, or the UI could mask a wrong 2xx body) at authoring time, and the table then
   derives `Kinds: probe` from it — never the reverse. This keeps exactly one place (`Kind`+`Tags`)
   as the source of truth for both execution order (existing Step 6 table) and evidence requirements
   (new derivation), so they cannot silently diverge.
2. **The gate is enforced INSIDE `checkpoint.sh cmd_upsert`**, not as a separate, optional
   verification step. `checkpoint.sh` is the single chokepoint every verdict flows through before it
   becomes durable run state (ADR-0002) — there is no other path to recording a `pass`. Wiring the
   gate here, rather than as a `pass-gate.js`-style standalone script the agent could choose to run
   or skip, makes it structurally un-bypassable: `checkpoint.sh <run> <crit> pass --kinds <csv>`
   either succeeds with the record written, or fails with nothing written.
3. **The check is CONTENT-AWARE**, not filename-presence. For each kind in `--kinds`, `checkpoint.sh`
   resolves the kind's canonical artifact path (`evidence/<crit>/{bake-read-back,recompute,
   network-response}.json`) and requires it to (a) exist, (b) be non-empty, (c) parse as valid JSON,
   and (d) contain that kind's required keys (`bake`: `readBack`, `multiplicity`; `computed`:
   `oracle`, `observed`, `match`; `probe`: `status`, `shape`) — key presence only, no value/type
   comparison. A companion script, `record-evidence.sh`, is the one writer of these structured
   artifacts, so the shape the gate checks and the shape produced are the same contract. Checking
   filename presence alone would be gameable by `touch`-ing an empty file; requiring real content
   closes that.
4. **On a `pass` lacking required evidence, the gate REJECTS** the upsert outright: non-zero exit,
   nothing written, and an actionable message on stderr naming the missing kind and the exact expected
   artifact path (e.g. `kind 'bake' artifact 'evidence/C1/bake-read-back.json' is missing`). There is
   **no auto-downgrade** to `blocked` and **no new verdict** — the agent decides what actually
   happened: supply the missing evidence (bake/recompute/probe for real, then retry), or record the
   honest verdict `blocked` itself. Non-`pass` verdicts (`fail`/`blocked`/`deferred`/`error`) are exempt
   from the gate entirely — they are already honest non-passes and never claimed the evidence existed.
   Omitting `--kinds` on a `pass` is back-compat for untagged/legacy criteria: it is allowed, but
   `checkpoint.sh` prints an un-gated note to stderr so the gap is visible rather than silent.

## Consequences

- **Closes the R1 execution-discipline miss-class**: a `pass` can no longer be recorded on UI
  appearance alone when its `Kind`/`Tags` imply bake/recompute/probe evidence — the measured baseline's
  F1/F3 misses (declaring pass without baking or recomputing) are now structurally blocked at the one
  chokepoint every criterion's verdict passes through.
- **Resume / compaction (ADR-0002 preserved)**: `kinds` and evidence status are now first-class fields
  on the checkpoint record and surface in `--resume` and `--list` output (`kinds: <csv>`,
  `evidence: complete|ungated|n/a`), so a resumed run can see at a glance which passed criteria are
  evidence-backed vs. legacy-ungated, without re-deriving anything. The file-cursor resume mechanism
  itself (checkpoint file per run, read on resume) is unchanged.
- **No verdict-vocabulary change**: `pass | fail | blocked | deferred | error` remains exactly the
  five values; `confidence` remains orthogonal (`high | low`). The gate only decides whether a `pass`
  *attempt* is accepted — it never mints or downgrades to a sixth state.
- **Oracle invariant preserved**: the gate checks *evidence presence/shape*, never *evidence
  correctness against the backend's own formula* — that judgment still lives in
  `verifying-computed-logic`, with the spec/domain rule as the oracle. `record-evidence.sh`'s
  `computed` artifact stores whatever `oracle`/`observed`/`match` the agent computed; the gate does
  not re-derive or trust-but-verify those values, it only requires they were recorded.
- **New authoring surface is minimal**: `generating-qa-checklist` gains one derived field (`Kinds`)
  and reuses the existing `probe-needed` tag; `checkpointing-qa-memory` gains `--kinds` on
  `checkpoint.sh` plus the new `record-evidence.sh` helper. No new skill, no new run-state file.
- **Reference prototype superseded**: `tools/accuracy-harness/scorer/pass-gate.js`, the original
  standalone proof-of-concept for this seam (camelCase `evidenceRefs`/`kinds`/`probeNeeded`,
  filename-regex matching), predates this decision and does not match the shipped shape. It is kept
  for reference, marked superseded, and not deleted (see the reconciliation note in that file).

## Alternatives considered

- **Separate, optional gate step** (e.g. a `verify-evidence.sh` the agent runs before checkpointing,
  or `pass-gate.js` invoked by hand): rejected — it is bypassable by construction. Anything not on the
  single path to a durable `pass` can be, and under time/token pressure will be, skipped.
- **Filename-presence check only** (does `evidence/<crit>/bake-read-back.json` exist?): rejected — an
  empty or `touch`-created file satisfies a presence check while carrying zero information, which is
  exactly the "green toast" failure mode restated as a file instead of a toast. Content-aware
  (non-empty, valid JSON, required keys) closes this.
- **Auto-downgrade a missing-evidence `pass` to `blocked`**: rejected — silently rewriting the agent's
  stated verdict hides the gap instead of surfacing it, and conflates "verification legitimately
  couldn't happen" (a real `blocked`) with "verification was claimed but not evidenced" (an invalid
  `pass`). Rejecting and requiring the agent to choose keeps the verdict honest and visible in the
  transcript.
- **An explicit, hand-authored `kinds[]` field on each criterion**: rejected as redundant with `Kind` +
  `Tags`, which the checklist already carries for execution-order tagging (Step 6). A second
  hand-maintained field is one more place to drift out of sync with the criterion's actual nature;
  deriving `Kinds` mechanically from existing fields keeps a single source of truth.

## References

- `skills/generating-qa-checklist/SKILL.md` — Step 6, `Kinds` derivation table.
- `skills/checkpointing-qa-memory/scripts/checkpoint.sh` — `gate_pass`, `kind_artifact`,
  `kind_required_keys`, `--kinds` option.
- `skills/checkpointing-qa-memory/scripts/record-evidence.sh` — the artifact writer.
- `tools/accuracy-harness/scorer/pass-gate.js` — superseded standalone prototype (kept for reference).
- [ADR-0002](./0002-run-state-in-dot-qa-not-agent-memory.md) — run state / resume file convention this
  gate's `kinds`/evidence fields extend.
- [CONTEXT.md](../../CONTEXT.md) — verdict, confidence, oracle definitions this decision does not
  alter.
