# Generative Critic (Layer 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the **generative critic** (layer 3, ADR-0019 §5) to the human-eye-UX engine: a multimodal read of a screenshot + interaction trace + persona/locale that asks *"what looks broken, wrong, confusing, or off?"* to catch the novel long-tail the invariants miss — emitting **advisory suspicions only** (a critic suspicion becomes a verdict solely when a definite oracle corroborates it, via the existing adjudication classifier), through a **portable disk-file vision contract** with a per-harness capability flag that **degrades honestly** (vision-absent → layers 1–2 + a banner), and a **cost ceiling** that runs the critic only where it pays and logs sampled-vs-skipped.

**Architecture:** This generalizes the existing `detecting-visual-ux` Step 4 (today a subjective *aesthetics* read) into the full critic — same "advisory, never a verdict" guarantee, widened prompt (broken/wrong/confusing/off, not just hierarchy/spacing/garishness) and inputs (screenshot **+ interaction trace + persona/locale**). Portability follows ADR-0017 + the harness-capability-matrix: the vision *logic* is one skill body; a per-harness `vision` descriptor in `harness-profiles.json` binds the native disk-image read (Read on Claude/opencode, `localImage` on Codex, adapter-`ImageContent`/Read on Pi). The critic's suspicions carry a `critic-` detector prefix so the merged `adjudicate.js` classifier grades them `heuristic` → **advisory unless corroborated** — the soundness spine is reused, not rebuilt. Coverage is **estimated, not measured** (you cannot measure recall on unseeded bugs, §11) — stated honestly; the critic never enters the C1 measured recall gate.

**Tech Stack:** Markdown skill body + doctrine; dependency-free Node/bash for the small testable primitives (the vision-capability resolver + degrade banner, the sampled-vs-skipped log); `harness-profiles.json` (the per-harness `vision` binding). No new runtime dependency. The multimodal judgment itself is agent-runtime (not unit-testable) — only its plumbing and its advisory-only guarantee are tested.

## Global Constraints

- **This is sub-plan C2 of the human-eye-UX design (ADR-0019).** Sub-plans A (adjudication, PR #42), B (behavioral family, PR #43), and C1 (the measured recall gate, PR #44) are merged. C2 is the LAST piece of the engine. Its coverage is **estimated, not measured** — it must NEVER be counted in the C1 measured gate, and the docs must not claim a measured number for it.
- **Advisory only — never a verdict on its own (the soundness spine, §5 + decision 2).** A critic suspicion becomes a `fail` verdict ONLY when a definite oracle corroborates it through `adjudicate.js` (the `heuristic` grade → advisory unless `corroborated`). The critic never emits a verdict directly. A `critic-*` detector MUST grade to `heuristic` (advisory). This keeps precision intact while raising recall.
- **Portable vision = disk-file + per-harness read (§5 vision contract).** Consume screenshots via a **disk-file PNG + the harness's native read**, NEVER the raw MCP image content-block (forwarding differs across harnesses — Codex `#10334`, opencode/Pi unconfirmed). Screenshot → `--output-dir` PNG → Read (Claude/opencode) / `localImage` (Codex) / adapter-`ImageContent`-or-Read (Pi), resolved by the per-harness `vision` binding.
- **Never split screenshot-take from screenshot-judge across a subagent boundary** (opencode discards image parts across `task`). The take + judge happen in one agent context (sequential-by-default v1 sidesteps this).
- **Degrade honestly when vision is absent.** A vision-incapable harness/model → the engine runs layers 1–2 (the shipped definite-oracle detectors + adjudication) and prints a **banner** that the layer-3 critic was skipped (vision unavailable) — never a silent omission, never a false "fully checked" claim.
- **Cost ceiling (§10) — no silent coverage caps.** The critic runs only on interaction-heavy surfaces + surfaces where layers 1–2 already flagged, capped by `criteriaBudget` / the run-level ceiling. Every surface the critic was SKIPPED on (by the cost cap) is **logged** (sampled-vs-skipped), so a capped run never reads as "critic ran everywhere."
- **Fully autonomous — no in-loop HITL (§6).** The critic's free exploration is **read-only** Arrange/observe; any mutation it wants becomes a proper gated criterion, never ad-hoc clicking. An ambiguous critic suspicion the code can't resolve is advisory, never a blocking prompt.
- **Verdicts/confidence/layer vocab unchanged** (`pass|fail|blocked|deferred|error`; `high|low`; `FE|...`). No sixth verdict. The critic's advisory items carry NO verdict/confidence/layer (like the existing aesthetics advisory).
- **Portability:** the critic skill body + the resolver/log helpers are **core** (copied verbatim into every `dist/<h>/`); only the `vision` read-binding is per-harness (a `harness-profiles.json` field + the generated adapter). `validate-adapters.sh` byte-oracle + the portability test stay green.
- **No Claude/Anthropic attribution** in any commit; no `Co-Authored-By` trailer. Never commit `dist/`.

## Self-grilled decisions (my own recommended answers applied)

1. **Generalize the existing Step 4 vs. a new skill** → **generalize** `detecting-visual-ux`'s Step 4 (already the multimodal advisory read) into the full critic — same advisory-only guarantee, widened prompt + inputs. Avoids a redundant skill; the critic is the same "read the screenshot, emit advisory" mechanism, just broader. *Applied (Task 2).*
2. **Advisory-only enforcement** → a `critic-*` detector prefix that `adjudicate.js` grades `heuristic` (→ advisory unless corroborated). The classifier already defaults unknown prefixes to `heuristic`, so this is a guarantee to TEST, not new grading logic — but pin it with an explicit test + a one-line `ORACLE_GRADES` comment so a future edit can't silently promote a critic suspicion to a verdict. *Applied (Task 1).*
3. **Vision-capability representation** → a `vision` object per harness in `harness-profiles.json` (`{capable:true, read:"Read"|"localImage"|"adapter"}`), per the matrix's Vision row (all four are capable today with disk-file reads). A tiny resolver returns the read-binding or a degrade signal. *Applied (Task 1).*
4. **Degrade trigger** → vision-absent = the `vision.capable` flag is false OR the run's model is a pinned text-only tier. Since all four shipped harnesses are vision-capable, the degrade path is for a future/edge harness or a text-only model pin — build the mechanism + banner, exercise it via a synthetic vision-absent profile in tests. *Applied (Task 1/2).*
5. **Cost-ceiling trigger** → run the critic on a surface iff (it is interaction-heavy — has a driven multi-step/overlay sequence) OR (layers 1–2 produced ≥1 finding/suspicion on it), bounded by `criteriaBudget`. Everything skipped by the cap is appended to a `critic-coverage.json` sampled-vs-skipped log. *Applied (Task 3).*
6. **Estimated-not-measured honesty** → the critic's advisory items are excluded from the C1 gate (they're `stream:"advisory"` / heuristic by construction — the existing scorer already excludes advisory). The docs state the critic's coverage is estimated; no measured number is claimed for it. *Applied (Task 4).*

---

## File Structure

- `harness-profiles.json` **(modify)** — add a `vision` descriptor per harness (`{capable, read}`) from the capability matrix.
- `skills/detecting-visual-ux/scripts/vision-binding.sh` **(new)** — a tiny resolver: given a harness id (or `QA_HARNESS`), print the vision read-binding (`Read`/`localImage`/`adapter`) or `absent`; and a `banner` subcommand printing the honest degrade banner. jq-preferred/python3-fallback.
- `tests/vision-binding/run.sh` **(new)** — resolver + degrade tests (each harness → its read; a synthetic vision-absent profile → `absent` + banner), both engines.
- `skills/detecting-visual-ux/scripts/adjudicate.js` **(modify)** — add an explicit `['critic-', 'heuristic']` row to `ORACLE_GRADES` (pins the advisory-only guarantee; the default is already heuristic, but make it explicit + commented so it can't be silently changed).
- `tests/ux-adjudicate/run.sh` **(modify)** — assert `critic-*` → `heuristic` → advisory (uncorroborated) and → fail-high only when `corroborated` (a definite oracle backs it).
- `skills/detecting-visual-ux/scripts/critic-coverage.sh` **(new)** — append a `{surface, decision:"ran"|"skipped", reason}` record to `.qa/runs/<run-id>/critic-coverage.json` (the sampled-vs-skipped log); jq/python3. 
- `tests/critic-coverage/run.sh` **(new)** — append/read/missing-file tests, both engines.
- `skills/detecting-visual-ux/SKILL.md` **(modify)** — generalize Step 4 into the generative critic: the widened prompt + inputs (screenshot + interaction trace + persona/locale), the disk-file vision contract via `vision-binding.sh`, the advisory-only routing through `adjudicate.js`, the never-split-across-subagent rule, the degrade banner, and the cost-ceiling trigger + `critic-coverage.sh` logging. Keep < 500 lines (use the references doc for depth).
- `skills/detecting-visual-ux/references/adjudication.md` **(modify)** — note the `critic-`/`heuristic` grade + the estimated-not-measured stance.
- `docs/adr/0019-human-eye-ux-detection-engine.md` **(modify)** — implementation note: C2 (the generative critic) landed; the full engine (A/B/C1/C2) is complete; the critic's coverage is estimated-not-measured (NOT part of the measured gate).
- `docs/specs/harness-capability-matrix.md` **(modify)** — mark the vision row as wired (the `vision` binding shipped).
- `CONTEXT.md` **(modify)** — add a `Generative critic` (layer 3) glossary term.

---

## Task 1: Vision-capability binding + the advisory-only critic grade

**Files:**
- Modify: `harness-profiles.json`
- Create: `skills/detecting-visual-ux/scripts/vision-binding.sh`
- Modify: `skills/detecting-visual-ux/scripts/adjudicate.js`
- Test: `tests/vision-binding/run.sh`, `tests/ux-adjudicate/run.sh`

**Interfaces:**
- `vision-binding.sh resolve [<harness>]` → prints `Read` | `localImage` | `adapter` | `absent` (from `harness-profiles.json`'s `harnesses[<h>].vision`; default `<harness>` from `QA_HARNESS`, else `claude`).
- `vision-binding.sh banner` → prints the honest degrade banner (e.g. `NOTE: layer-3 generative critic SKIPPED — vision unavailable for this harness/model; ran layers 1–2 (definite-oracle detectors + adjudication) only.`).
- `oracleGradeFor('critic-anything')` → `'heuristic'` (explicit row); `adjudicate(criticSuspicion, {})` → advisory; `adjudicate(criticSuspicion, {corroborated:true})` → fail high.

- [ ] **Step 1: Add the `vision` descriptor to `harness-profiles.json`** — per harness, from the matrix Vision row: claude `{capable:true, read:"Read"}`, codex `{capable:true, read:"localImage"}`, opencode `{capable:true, read:"Read"}`, pi `{capable:true, read:"adapter"}`. (A future/edge vision-absent harness would set `capable:false`.)
- [ ] **Step 2: Write the failing tests** — `tests/vision-binding/run.sh` (both engines): each harness → its read binding; `QA_HARNESS` override; a synthetic profile with `capable:false` → `absent`; `banner` prints the degrade text. In `tests/ux-adjudicate/run.sh`: `oracleGradeFor("critic-layout-off")` → `heuristic`; `adjudicate({detector:"critic-layout-off",rawSignal:"x"},{})` → `{advisory:true}`; `adjudicate({detector:"critic-layout-off",rawSignal:"x"},{corroborated:true})` → `confidence:'high'`. Run → FAIL.
- [ ] **Step 3: Implement `vision-binding.sh`** — jq-preferred/python3-fallback/die, honor `QA_ENGINE`; read `harnesses[<h>].vision.read` (→ that string) or `absent` when `vision.capable` is false / missing; `banner` prints the fixed degrade line. Mirror the sibling scripts' header/engine-resolution pattern.
- [ ] **Step 4: Add the explicit critic grade** in `adjudicate.js` — add `['critic-', 'heuristic'],` to `ORACLE_GRADES` with a comment: `// the generative critic (layer 3) is advisory-only — its suspicions never ground a verdict on their own (ADR-0019 §5); a definite oracle corroborating one promotes it via the heuristic-corroborated path.` (Behavior is unchanged from the default, but the explicit row + comment prevents a silent future promotion.)
- [ ] **Step 5: Run tests** — `bash tests/vision-binding/run.sh` + `bash tests/ux-adjudicate/run.sh` → `FAIL=0`; `node --check skills/detecting-visual-ux/scripts/adjudicate.js`; `bash -n skills/detecting-visual-ux/scripts/vision-binding.sh`; validate `harness-profiles.json` parses.
- [ ] **Step 6: Commit**
```bash
git add harness-profiles.json skills/detecting-visual-ux/scripts/vision-binding.sh skills/detecting-visual-ux/scripts/adjudicate.js tests/vision-binding/run.sh tests/ux-adjudicate/run.sh
git commit -m "feat(ux): per-harness vision binding + explicit critic-*/heuristic grade (layer-3 advisory-only guarantee)"
```

---

## Task 2: The generative-critic step in the skill

**Files:**
- Modify: `skills/detecting-visual-ux/SKILL.md`
- Modify: `skills/detecting-visual-ux/references/adjudication.md`

**Interfaces:** consumes `vision-binding.sh` (Task 1), `adjudicate.js` (the `critic-` grade), `critic-coverage.sh` (Task 3). Produces the agent procedure for the layer-3 read.

- [ ] **Step 1: Generalize Step 4 into the generative critic.** Widen the existing "Subjective advisory read" step: (a) INPUTS — a full-surface `browser_take_screenshot` to a `--output-dir` PNG, consumed via the read binding from `vision-binding.sh resolve` (Read/localImage/adapter — the disk-file contract, NEVER the raw MCP image block), PLUS the interaction trace (the driven sequence, from `walking-multistep-flows`/`driving-browser-qa`) and the persona/locale; (b) PROMPT — widen from aesthetics-only to *"what looks broken, wrong, confusing, or off for this persona/locale?"* (missing/overlapping/mis-aligned/illegible/unexpected content, confusing flow, wrong-for-locale), covering the long tail the invariants miss; (c) OUTPUT — each observation is a `critic-<slug>` **advisory suspicion** run through `adjudicate.js` → it stays advisory UNLESS a definite oracle (a content/i18n/asset finding, or a behavioral invariant) corroborates it (then the classifier promotes it). The critic NEVER emits a verdict directly.
- [ ] **Step 2: The vision contract + never-split rule.** Document: screenshot → PNG → the `vision-binding.sh` read; the take + judge happen in ONE agent context (never split across a subagent `task` boundary — opencode drops image parts). If `vision-binding.sh resolve` returns `absent` → SKIP the critic, run layers 1–2 only, and emit `vision-binding.sh banner` into the report (honest degrade).
- [ ] **Step 3: The cost ceiling.** The critic runs on a surface iff it is interaction-heavy (a driven multi-step/overlay sequence ran) OR layers 1–2 already produced ≥1 finding/suspicion there, within `criteriaBudget`. Every surface the cap SKIPPED is logged via `critic-coverage.sh` (Task 3). State plainly: a capped run is not "critic ran everywhere" — the coverage log is the honest record.
- [ ] **Step 4: Read-only discipline.** The critic's free exploration is read-only Arrange/observe; any mutation it wants to test becomes a proper gated (human-action) criterion, never ad-hoc clicking.
- [ ] **Step 5: Keep < 500 lines** — put the long critic prompt/rubric in `references/` (extend the existing adjudication or a new `references/generative-critic.md` linked one level deep) if SKILL.md would exceed. Update `references/adjudication.md` with the `critic-`/heuristic grade + the estimated-not-measured note. Verify `wc -l` < 500; frontmatter unchanged.
- [ ] **Step 6: Gates + commit** — `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (exit 0); portability test.
```bash
git add skills/detecting-visual-ux/SKILL.md skills/detecting-visual-ux/references/
git commit -m "feat(ux): generative critic (layer 3) — screenshot+trace+persona multimodal advisory read, disk-file vision, cost-capped"
```

---

## Task 3: The sampled-vs-skipped coverage log

**Files:**
- Create: `skills/detecting-visual-ux/scripts/critic-coverage.sh`
- Test: `tests/critic-coverage/run.sh`

**Interfaces:**
- `critic-coverage.sh log <run-id> <surface> <ran|skipped> <reason>` → appends `{surface, decision, reason}` to `.qa/runs/<run-id>/critic-coverage.json` (creating `{records:[...]}` if absent), atomically. 
- `critic-coverage.sh read <run-id>` → prints the records array (`[]` when absent). Feeds the report's honest coverage section.

- [ ] **Step 1: Failing tests** (`tests/critic-coverage/run.sh`, both engines): missing-file `read` → `[]`; `log ran/skipped` → records grow; the `decision` must be one of `ran|skipped` (die otherwise); reason preserved; valid JSON. Run → FAIL.
- [ ] **Step 2: Implement `critic-coverage.sh`** — jq/python3/die, honor `QA_ENGINE`, atomic temp→rename write, `run-id` validated as a simple token (mirror `journal-emit.sh`'s `validate_token`). Reject a `decision` not in `ran|skipped`.
- [ ] **Step 3: Run tests** — `bash tests/critic-coverage/run.sh` → `FAIL=0`; `bash -n`; emitted JSON parses.
- [ ] **Step 4: Commit**
```bash
git add skills/detecting-visual-ux/scripts/critic-coverage.sh tests/critic-coverage/run.sh
git commit -m "feat(ux): critic-coverage sampled-vs-skipped log (no silent coverage caps)"
```

---

## Task 4: Docs — ADR-0019 note (engine complete) + matrix + CONTEXT

**Files:**
- Modify: `docs/adr/0019-human-eye-ux-detection-engine.md`
- Modify: `docs/specs/harness-capability-matrix.md`
- Modify: `CONTEXT.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: ADR-0019 implementation note** — sub-plan **C2 (the generative critic, layer 3) landed**: the widened multimodal advisory read (screenshot + interaction trace + persona/locale), the portable disk-file vision binding (`vision-binding.sh` + the `harness-profiles.json` `vision` descriptor), the advisory-only guarantee (`critic-`/heuristic grade), the honest degrade banner, and the cost-ceiling + `critic-coverage.sh` sampled-vs-skipped log. State that **the full human-eye-UX engine (A adjudication + B behavioral + C1 measured gate + C2 critic) is now complete.** Reaffirm honestly: the critic's long-tail coverage is **estimated, not measured** (excluded from the C1 gate); the measured guarantee remains 100%/100%/held-out-2-of-2 on the *seeded taxonomy* (layers 1–2), and the critic *reaches for* the unknown tail without a measured recall claim.
- [ ] **Step 2: harness-capability-matrix** — mark the Vision row as **wired** (the `vision` binding shipped in `harness-profiles.json` + `vision-binding.sh`); note the disk-file contract is now the code path. Keep the per-harness `verify` caveats (Pi adapter-`ImageContent`, Codex `#10334`) as operational notes.
- [ ] **Step 3: CONTEXT.md** — add a **Generative critic** term (house format): layer 3 of the UX engine — the multimodal model reading a screenshot + interaction trace + persona/locale for "what looks broken/wrong/confusing/off"; emits **advisory** suspicions only, a verdict only when a definite oracle corroborates one; its coverage is estimated, never measured. `_Avoid_:` treating a critic suspicion as a verdict; conflating it with the definite-oracle detectors (layers 1–2).
- [ ] **Step 4: Gates + commit** — `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (exit 0).
```bash
git add docs/adr/0019-human-eye-ux-detection-engine.md docs/specs/harness-capability-matrix.md CONTEXT.md
git commit -m "docs(ux): ADR-0019 note (C2 critic landed — engine complete; critic coverage estimated-not-measured) + matrix + CONTEXT"
```

---

## Self-Review

**1. Spec coverage (§5, §10).**
- Multimodal read of screenshot + interaction trace + persona/locale → advisory suspicions, forced through §1 adjudication → Task 2 + Task 1's `critic-`/heuristic grade. ✅
- Portable disk-file vision contract + per-harness read binding + capability flag → Task 1 (`vision-binding.sh` + `harness-profiles.json`) + Task 2 (the read path). ✅
- Vision-absent → degrade to layers 1–2 + honest banner → Task 1 (`banner`) + Task 2 (skip + emit). ✅
- Never split take/judge across a subagent boundary → Task 2 doctrine. ✅
- Cost ceiling (interaction-heavy + layers-1–2-flagged, capped, sampled-vs-skipped logged) → Task 2 (trigger) + Task 3 (`critic-coverage.sh`). ✅
- Advisory-only, precision-preserving, estimated-not-measured → Task 1 (grade) + Task 4 (docs); excluded from the C1 gate (existing advisory exclusion). ✅
- Read-only exploration; mutation → a gated criterion → Task 2 discipline. ✅

**2. Placeholder scan.** None — every step names exact files, the `vision` descriptor values per harness, the resolver/log CLIs, the `critic-` grade row, the banner text shape, and the commit messages. The critic *prompt/rubric* is prose authored in-task (a doctrine artifact, not inlinable code) with its inputs/output/advisory-only contract fully specified here.

**3. Type consistency.** `vision-binding.sh resolve` returns exactly `Read|localImage|adapter|absent` (the `harness-profiles.json` `vision.read` values + the absent signal). `critic-*` detector ids grade to `heuristic` in `ORACLE_GRADES` and route through the existing `adjudicate` advisory/corroborated paths (no new return shape). `critic-coverage.sh`'s `{surface,decision,reason}` record + `decision ∈ {ran,skipped}` are consistent across log/read/tests. Verdict/confidence/layer vocab unchanged; the critic adds no verdict.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-03-ux-generative-critic.md`. Execution: **Subagent-Driven Development** (fresh implementer per task + task-scoped review + fix loop; final whole-branch review on the most capable model), per the autonomous `/loop` directive. **Note:** the multimodal judgment is agent-runtime and not unit-testable — the tests cover the vision-binding resolver, the advisory-only grade guarantee, and the coverage log; the whole-branch review should confirm the advisory-only guarantee and the honest-degrade/estimated-not-measured framing, not attempt to measure critic recall.
