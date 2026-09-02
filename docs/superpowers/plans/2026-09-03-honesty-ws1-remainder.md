# Honesty WS-1 Remainder (Plan H1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two remaining WS-1 gate-integrity gaps from the honesty-hardening spec — **#2** (`--kinds` binding: the gate independently re-derives a criterion's required evidence kinds and enforces `recorded ⊇ derived`, so dropping `human-action`/`bake`/`probe` fails) and **#4** (fingerprint-target: the criterion declares the persisted state its act asserts, and the gate requires the before/after fingerprint to *cover* that target and show a change when the oracle expects one) — in-script, building on the merged Plan A `mutation-flag.sh`.

**Scope note — this is Plan H1 of the honesty-hardening effort (spec `docs/specs/2026-09-02-qa-honesty-hardening-design.md`, ADR-0018).** WS-1's #3 (semantic mutation classifier) + A (nav fail-closed) shipped in the earlier gate-integrity PR#31; #8 (squash) in PR#32. Plan H1 finishes WS-1 with #2 and #4. **Plan H2** (WS-3 sound core: capture-hook + block-hook + out-of-agent `qa-verify` + provenance) and **Plan H3** (fast-follows: persona-identity #6, clock #7, WS-2 doctrine, other-3 hook adapters) follow.

**The honest tier boundary (state it plainly, everywhere):** Plan H1's checks are **in-script and best-effort** — they re-derive from the criterion's *declared shape*, closing the "just drop `--human-action`" and "fingerprint an irrelevant field" holes. They do **NOT** close "lie about the criterion's kind/tags" or "fabricate the target's fingerprint values" — those need `qa-verify`'s independent re-derivation from the toolstream + re-bake, which is **Plan H2**. Where Plan H1 can only best-effort, the run is `confidence: low` + the authoritative-verdict-is-`qa-verify` framing (per spec §6). Never present the in-script check as sound.

**Architecture:** A new `required-kinds.sh derive <criterion-json>` produces the trusted required-kinds set (the four-kind vocabulary `bake|computed|probe|human-action`, no fifth) from deterministic rules over the criterion's *shape* (kind/tags/action), reusing `mutation-flag.sh derive` for the mutates→`human-action` rule. `generating-qa-checklist` emits a machine-readable `checklist.json` (the agent's *proposal*: per-criterion `{id, kind, tags, action, requiredKinds, assertedState}`) alongside today's `checklist.md`. `checkpoint.sh`'s pass-gate, when a `checklist.json` row exists for the criterion, **re-derives** `requiredKinds` itself from that row's shape (ignoring the row's own `requiredKinds` field) and rejects unless the recorded `--kinds` is a superset — closing #2's regress. For #4, the criterion's `assertedState` (entity + read-back path) is threaded into `action-trace.json` via a new `record-evidence.sh --fingerprint-target`, and `check-action-trace.js` Check 3 requires the fingerprint to include that target key and show a change on it when expected.

**Tech Stack:** Bash (`set -uo pipefail`), `jq` preferred / `python3` fallback (+ the `has_jq`/`has_py`/`die` idiom), Node (dependency-free, for `check-action-trace.js` only), `mutation-flag.sh derive`. Skills copied verbatim into `dist/` (validate-adapters static sweep, no byte-oracle for these files).

## Global Constraints

- **`jq` preferred / `python3` fallback / `die`; no new hard deps.** `required-kinds.sh` follows `mutation-flag.sh`'s exact idiom. `check-action-trace.js` stays dependency-free Node (its existing gate path). Do not add a Node dependency to any `.sh` gate path.
- **Vocabulary is fixed.** Evidence kinds are exactly `bake | computed | probe | human-action` (no fifth — confirmed the codebase has only these four). Verdicts `pass|fail|blocked|deferred|error`; confidence `high|low`; suspected layer `FE|route|service|migration|DB`. Do not invent kinds/verdicts.
- **The gate re-derives; it NEVER trusts the agent's `requiredKinds` field.** `checkpoint.sh` reads only the criterion's *structural* facts (`kind`, `tags`, `action`) from `checklist.json` and runs `required-kinds.sh derive` on them; it ignores any `requiredKinds` the agent wrote. Recorded `--kinds` must be a **superset** of the derivation. (The residual "agent lies about `kind`/`tags`" hole is Plan H2's `qa-verify` — documented, not silently accepted.)
- **Back-compat is preserved.** A `pass` with no `checklist.json` row for the criterion keeps today's behavior (the "un-gated" stderr note, `checkpoint.sh:786`); the 248 checkpoint characterization assertions stay green (extend by ADDING cases). #4's Check 3 stays back-compat when `assertedState`/`--fingerprint-target` is absent (today's aggregate-`changed` behavior).
- **`checklist.json` is the agent's PROPOSAL, validated structurally, re-derived semantically.** Emitting it is a `generating-qa-checklist` addition; a `validate-checklist-json.sh` checks structure (required fields, enum values). The gate never trusts its `requiredKinds`.
- **Fingerprint-target is a COVERAGE check, not equality.** Check 3 requires the fingerprint's `before`/`after` to *contain* the asserted target key (formatted-in-DOM ≠ stored, so no exact equality), and — when the criterion's oracle expects a change — the target's value must differ before→after. A fingerprint that covers only an unrelated field while the asserted target is absent/unchanged → reject.
- **Portability:** all four edited files are under `skills/` (copied verbatim into `dist/`). After edits, regenerate dist (`for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done`), `bash scripts/validate-adapters.sh` exit 0, `bash tests/portability/run.sh` `FAIL=0` (no `grep -P`/`perl`). `dist/` git-ignored.
- **Tests** are bash runners at `tests/<name>/run.sh` (check/get, mktemp -d, dual-engine jq-mask) and node-driven for `check-action-trace.js` (`tests/action-trace/run.sh` idiom). Extend `tests/checkpoint/run.sh` (kinds gate) + `tests/action-trace/run.sh` (fingerprint) by ADDING cases.
- **Commit messages: NO Claude/Anthropic attribution, NO `Co-Authored-By`.**

## Self-grilled decisions (my recommendations, applied)

- **Q1 required-kinds source** → `checkpoint.sh` reads the criterion's shape from `.qa/runs/<run>/checklist.json[id]` and re-derives; back-compat (un-gated note) when the row is absent. No hard checklist.json dependency.
- **Q2 deriver** → new `required-kinds.sh derive` reusing `mutation-flag.sh derive` for mutates→`human-action`, plus rules for `computed`(computed-logic/business-rule), `probe`(cross-tenant/probe-needed/cross-role-fk-chain), `bake`(non-read-only state criteria). Output ⊆ the four-kind vocabulary.
- **Q3 checklist.json** → `generating-qa-checklist` emits it as the agent's proposal (structural facts + advisory requiredKinds + assertedState); the gate re-derives and ignores the advisory field.
- **Q4 #4 target** → criterion `assertedState {entity, readBackPath, expectChange}` → `record-evidence.sh --fingerprint-target` → `action-trace.json.fingerprintTarget` → Check 3 coverage+change check. In-script best-effort.
- **Q5 tier honesty** → document (SKILL + a low-confidence banner) that #2/#4 in-script close drop/irrelevant-field holes only; `qa-verify` (Plan H2) is authoritative for lie-about-kind / fabricated-values.

---

### Task 1: `required-kinds.sh derive` — independent required-kinds deriver

Create the trusted deriver: from a criterion's shape, produce the required evidence-kinds set, reusing `mutation-flag.sh` for the mutation rule. This is the agent-untrusted source #2 enforces against.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/required-kinds.sh`
- Create: `tests/required-kinds/run.sh`

**Interfaces:**
- `required-kinds.sh derive <criterion-json>` → prints a sorted CSV of required kinds (subset of `bake,computed,human-action,probe`). Rules (union, all that match):
  - `mutation-flag.sh derive <criterion-json>` is `true` → add `human-action` (a state-mutating act must have a human-action trace).
  - `kind` ∈ `{computed-logic, business-rule}` → add `computed`.
  - `kind` ∈ `{multiplicity-0, multiplicity-1, multiplicity-N, happy-path, downstream-cascade, empty-state}` OR the criterion is not tagged `read-only` and asserts persisted state → add `bake`.
  - `tags` contains `cross-tenant` OR `cross-role-fk-chain` OR `probe-needed` → add `probe`.
  - A purely read-only/observational criterion (tag `read-only`, no mutation, no persisted-state assertion, `kind` like `loading-state`/`error-state`) → may derive the empty set (nothing required) — that is valid (returns empty string).
- Reads criterion fields: `kind` (string), `tags` (array), plus whatever `mutation-flag.sh derive` reads (`kinds`/`httpMethod`/`action`/`title`). Note: the derivation must NOT read the agent's `requiredKinds` field.

- [ ] **Step 1** — write `tests/required-kinds/run.sh`: a mutating criterion (`{"action":"Create a founder","kind":"happy-path"}`) → `bake,human-action`; a `computed-logic` criterion → `computed`; a `cross-tenant`-tagged probe criterion (`{"kind":"cross-tenant","tags":["cross-tenant","probe-needed"]}`) → `probe` (+ `bake` if it asserts state — pick the fixture to make the expectation exact); a read-only `loading-state` (`{"kind":"loading-state","tags":["read-only"]}`) → empty; dropping-a-kind adversary: a mutating criterion still derives `human-action` regardless of what `kinds` the agent put. Dual-engine. Run → FAIL.
- [ ] **Step 2** — implement `required-kinds.sh` (has_jq/has_py/die; shell `mutation-flag.sh derive` by path; union the rules; sort+dedupe the CSV; use `grep -Ei`, never `grep -P`).
- [ ] **Step 3** — pass both engines + a jq-masked pass; validate (bash -n, dist regen, validate-adapters, portability).
- [ ] **Step 4** — commit: `feat(checkpointing): required-kinds.sh — independent required-kinds deriver (agent-untrusted, reuses mutation-flag)`.

---

### Task 2: `checklist.json` emitter + schema doc in `generating-qa-checklist`

Add the machine-readable per-criterion `checklist.json` (the agent's proposal) that `checkpoint.sh` reads for the criterion shape, plus a schema doc + a structural validator.

**Files:**
- Modify: `skills/generating-qa-checklist/SKILL.md` — a new step: after filling `checklist.md`, also emit `.qa/runs/<run-id>/checklist.json` per the schema; note it is a *proposal* (the gate re-derives `requiredKinds`).
- Create: `skills/generating-qa-checklist/references/checklist-json-schema.md` — the schema: an array of `{id, surface, kind, tags:[], action, requiredKinds:[], assertedState:{entity, readBackPath, expectChange:bool}|null, humanAction:bool}`.
- Create: `skills/generating-qa-checklist/scripts/validate-checklist-json.sh` — structural validator: every entry has `id` (non-empty), `kind` (from the enum), `tags` (array), `action` (string); `requiredKinds`/`assertedState` optional but typed if present. Exits non-zero + names the offending entry on violation.
- Create: `tests/validate-checklist-json/run.sh`

**Interfaces:**
- `validate-checklist-json.sh <checklist.json path>` → exit 0 if structurally valid, else non-zero + a message naming the bad entry/field.
- The schema is the contract `checkpoint.sh` (Task 3) and `record-evidence.sh`/Check 3 (Task 4) consume: `assertedState` feeds #4's fingerprint-target; `kind`/`tags`/`action` feed #2's re-derivation.

- [ ] **Step 1** — write `tests/validate-checklist-json/run.sh`: a well-formed checklist.json → exit 0; a missing `id` → non-zero naming the entry; a bad `kind` enum value → non-zero; an `assertedState` missing `entity` → non-zero; empty array → exit 0 (valid, vacuous). Dual-engine.
- [ ] **Step 2** — write the schema doc; implement `validate-checklist-json.sh`.
- [ ] **Step 3** — add the emit-checklist.json step to `SKILL.md` (prose: emit the JSON per the schema; the gate re-derives, so this is a proposal — mini-eval showing a mutating criterion's row). Body < 500 lines (`awk`).
- [ ] **Step 4** — pass both engines; validate; dist regen; validate-adapters; portability; commit: `feat(generating-qa-checklist): emit machine-readable checklist.json (proposal) + schema + structural validator`.

---

### Task 3: `checkpoint.sh` #2 binding — enforce recorded kinds ⊇ re-derived

Wire the gate: when a `checklist.json` row exists for the criterion, re-derive `requiredKinds` via `required-kinds.sh` and reject a `pass` unless the recorded `--kinds` is a superset. Back-compat when no row.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` — in `cmd_upsert`'s pass-gate (around `:784-793`, before/within `gate_pass`): if `.qa/runs/<run>/checklist.json` has a row for `crit_id`, run `required-kinds.sh derive <that row>` → `required`; reject unless the recorded `kinds_csv` ⊇ `required` (die with a message naming the missing kind). If no checklist.json or no row → today's behavior (un-gated note).
- Modify: `tests/checkpoint/run.sh` — ADD cases (do not edit existing).

**Interfaces:**
- Consumes: `required-kinds.sh derive` (Task 1), `checklist.json` (Task 2). Produces: the pass-gate now rejects a mutating criterion checkpointed `--kinds bake` (dropping the derived `human-action`) — AC-3.

- [ ] **Step 1** — add cases to `tests/checkpoint/run.sh`: with a `checklist.json` present, a mutating criterion (row derives `bake,human-action`) checkpointed `pass --kinds bake` → **rejected** naming `human-action` (AC-3); the same with `--kinds bake,human-action` (+ valid artifacts) → accepted; a criterion with NO checklist.json row → today's un-gated note (existing Case 19 semantics preserved); a read-only criterion (derives empty) → any/no kinds accepted. Run → the new reject cases FAIL (not yet wired), existing 248 still pass.
- [ ] **Step 2** — wire the re-derivation + superset check into `cmd_upsert` (shell `required-kinds.sh` by path; parse checklist.json for the row via jq/python3; keep the QA_ENGINE/has_jq discipline). Reject before the existing `gate_pass` artifact checks (a dropped kind fails fast).
- [ ] **Step 3** — run `tests/checkpoint/run.sh` (existing 248 + new all green, both engines incl. the fakebin python3 pass) + `tests/required-kinds/run.sh`; validate; dist; validate-adapters; portability.
- [ ] **Step 4** — commit: `feat(checkpointing): #2 gate binds recorded --kinds to independently re-derived requiredKinds (drop human-action -> reject)`.

---

### Task 4: #4 fingerprint-target — declare + cover the asserted state

Thread the criterion's `assertedState` into the action-trace and enforce Check 3 covers it: the fingerprint must include the asserted target key and (when a change is expected) show it changed.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/record-evidence.sh` — `cmd_action_trace` gains `--fingerprint-target <json>` (`{entity, readBackPath, expectChange}`) → stored as `action-trace.json.fingerprintTarget`.
- Modify: `skills/checkpointing-qa-memory/scripts/check-action-trace.js` — Check 3: when `fingerprintTarget` is present, require the `before`/`after` fingerprint to *contain* the target key (`readBackPath`), and if `expectChange` is true, require the target's value to differ before→after (reject `changed=false` on the asserted target); if `expectChange` is false, the target must be present but unchanged. Back-compat: no `fingerprintTarget` → today's aggregate-`changed` behavior unchanged.
- Modify: `tests/action-trace/run.sh` — ADD cases.

**Interfaces:**
- `record-evidence.sh <run> <crit> action-trace … --fingerprint-target '{"entity":"founder","readBackPath":"count","expectChange":true}'` → the trace carries `fingerprintTarget`.
- Check 3 with a `fingerprintTarget` present rejects: a fingerprint that omits the target key, or one where `expectChange:true` but the target value is equal before→after (AC-6: covering an unchanged unrelated field while the asserted state changed → reject).

- [ ] **Step 1** — add cases to `tests/action-trace/run.sh`: a `fingerprintTarget {readBackPath:"count", expectChange:true}` with `before.count=0, after.count=1` (human-path act) → **pass**; the same target but `before.count=1, after.count=1` (asserted state did NOT change) → **reject** (AC-6); a fingerprint that omits `count` entirely while `fingerprintTarget.readBackPath="count"` → **reject** (target not covered); no `fingerprintTarget` at all → today's behavior (back-compat cases still pass). Run → new cases FAIL.
- [ ] **Step 2** — add `--fingerprint-target` to `record-evidence.sh` (thread into the written JSON, both jq + python3 writers). Add the `fingerprintTarget` coverage+change logic to Check 3 in `check-action-trace.js` (dependency-free; navigate the `readBackPath` — support a simple dot-path or top-level key; document the supported path grammar). Keep all existing Check 0/1/2/3 behavior for the no-target case.
- [ ] **Step 3** — run `tests/action-trace/run.sh` (existing + new green) + `tests/checkpoint/run.sh` (248 + Task 3, green); `node --check check-action-trace.js`; validate; dist; validate-adapters; portability.
- [ ] **Step 4** — commit: `feat(checkpointing): #4 fingerprint-target — criterion declares asserted state; Check 3 requires the fingerprint cover + change it`.

---

### Task 5: Document the tier + wire the checklist.json contract

Record #2/#4 where documented, and — critically — state the honest tier boundary (in-script best-effort; `qa-verify` authoritative) so nobody presents these as sound.

**Files:**
- Modify: `skills/checkpointing-qa-memory/SKILL.md` — document the #2 required-kinds binding (gate re-derives, ignores the agent's field) + #4 fingerprint-target; add `required-kinds.sh` to the Scripts Reference; add `checklist.json` to the Run Directory Layout; a mini-eval (drop-human-action → reject). Add the honest tier note: "these close drop-a-kind / fingerprint-irrelevant-field; `qa-verify` (out-of-agent) is authoritative for lie-about-kind / fabricated-values." Body < 500 lines.
- Modify: `skills/generating-qa-checklist/SKILL.md` — cross-reference the `assertedState` field's role in #4 (link to interaction-discipline / the schema doc).
- Modify: `docs/adr/0018-out-of-agent-evidence-enforcement.md` — note WS-1 #2 + #4 landed in-script (best-effort tier); the sound tier (independent re-derivation + re-bake) remains `qa-verify` (Plan H2).
- Modify: `CONTEXT.md` — confirm the evidence-kind vocabulary is recorded (add a one-line `required-kinds` / `assertedState` glossary entry if the terms aren't present).

- [ ] **Step 1** — SKILL.md edits (both skills) + the honest tier note + mini-eval; `awk` < 500.
- [ ] **Step 2** — ADR-0018 note + CONTEXT terms.
- [ ] **Step 3** — dist regen; validate-adapters exit 0; commit: `docs(honesty): document WS-1 #2/#4 in-script tier (qa-verify authoritative) + checklist.json contract`.

---

## Self-Review

**1. Spec coverage** (§5A #2 + #4, Appendix T-3 + T-4, AC-3 + AC-6):
- #2 independent required-kinds re-derivation + `recorded ⊇ derived` + `checklist.json` → Tasks 1 (deriver) + 2 (checklist.json) + 3 (gate binding). AC-3 (drop human-action → reject) → Task 3. ✅
- #4 fingerprint-target declare + cover + change → Task 4. AC-6 (cover unchanged unrelated field while asserted state changed → reject) → Task 4. ✅
- Honest tier boundary (in-script best-effort; qa-verify authoritative) → constraint + Task 5. ✅
- **Explicitly deferred to Plan H2:** the SOUND versions (independent re-derivation from the toolstream, re-bake) via `qa-verify`; the capture/block hooks; provenance. Stated in the header + tier note. ✅

**2. Grounding-gap alignment (from exploration):**
- No checklist.json emitter → Task 2 adds it (proposal) + schema + validator. ✅
- No independent requiredKinds derivation → Task 1 `required-kinds.sh` (reuses mutation-flag, avoids trusting the agent's requiredKinds). ✅
- Case 19 (pass with no --kinds silently un-gated) → Task 3 keeps back-compat when no checklist.json row, but a row now forces the superset check. ✅
- No assertedState/fingerprintTarget field → Task 4 adds it (record-evidence + action-trace schema + Check 3). ✅
- #4 was deferred from the earlier plan as "qa-verify's job" → Plan H1 does the in-script coverage check now, documented as best-effort with qa-verify authoritative (Task 5). ✅
- 248 checkpoint characterization assertions → extend by ADDING cases; back-compat preserved (constraint). ✅

**3. Placeholder scan:** none — every task names exact files, subcommand signatures, the four-kind vocabulary, criterion field names, test assertions (AC-3/AC-6), and commit messages. The `readBackPath` grammar is specified (dot-path or top-level key) rather than left open.

**4. Type consistency:** the criterion shape fields (`id, kind, tags, action, requiredKinds, assertedState{entity,readBackPath,expectChange}, humanAction`) are identical across `checklist-json-schema.md`, `validate-checklist-json.sh`, `required-kinds.sh` (reads kind/tags/action), `checkpoint.sh` (reads the row), and `record-evidence.sh`/`check-action-trace.js` (`assertedState`→`fingerprintTarget`). The required-kinds output is always ⊆ `{bake,computed,probe,human-action}`. `required-kinds.sh derive` reuses `mutation-flag.sh derive`'s exact interface. Back-compat: absent checklist.json row / absent fingerprintTarget → today's behavior, keeping the 248 assertions green.
