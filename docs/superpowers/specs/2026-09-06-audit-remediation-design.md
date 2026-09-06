# Audit-Findings Remediation — Design

**Date:** 2026-09-06
**Source:** the 2026-09-06 deep audit of both plugins (5-dimension inline audit: engine scripts/gates,
skills content, portability layer, qa-kit shell, docs-vs-reality). All suites green at audit time
(~810 checks run); findings below are the gaps that survived.

## Problem

The audit found that the *paper* enforcement design is stronger than what actually executes:

- **F1 — `verify-plan.sh` is unwired.** qa-kit's out-of-plan-act checker exists, is dual-engine, and
  has a green suite — but no command, agent, or CI step runs it against a real run.
  `qa-scenarios.md` *promises* it fires "at run time"; `qa-analyze.md` never mentions it.
- **F2 — `qa-verify.sh` runs only in CI.** The engine's out-of-agent anti-forgery authority is invoked
  solely by `scripts/qa-ci.sh`. Interactive runs — the primary mode — never get the deterministic
  re-check; the agent persona mentions it in prose but is never instructed to run it.
- **F3 — CI gates 12 of 46 suites.** The measured blanket-glob hang is real for *some* suites, but the
  7 heaviest engine suites (checkpoint 265, fold 85, action-trace 74, qa-verify 77, provenance 36,
  required-kinds 24, journal 32 — 593 checks) each complete standalone in seconds. A regression in
  `checkpoint.sh` currently merges green.
- **F5 — `checkpointing-qa-memory/SKILL.md` is 517 lines**, breaking the repo's own <500-line rule.
- **F6 — undeclared `node` dependency.** `checkpoint.sh`'s header documents deps as
  bash/coreutils/jq-or-python3, but the human-action gate shells out to `node`
  (`check-action-trace.js`). Missing node fails closed but with a raw "command not found".
- **F7 — "16 skills" staleness** in 4 files: `harnesses/{pi,codex,opencode}/README.md:3` and
  `docs/harness-adapters.md:4` (actual: 17).
- **F8 — the failure-side contract is not machine-noted.** A `fail` with no `--bug-ref` (and hence no
  suspected layer, which lives in the bug-log entry) records silently, while the pass side gets
  loud gating.
- **F9 (minor) —** `cmd_resume`'s jq branch tolerates a missing `.criteria` only via bash's
  `[[ null -eq 0 ]]` accident (`checkpoint.sh:292`); `checklist_row_for` silently uses the first row
  when checklist ids are duplicated.
- **F4 — no non-Claude harness has ever had a live end-to-end run.** The documented manual accuracy
  run has never been executed; the hook-layer gap on non-Claude harnesses (no block-hook /
  capture-hook) is documented but unvalidated in practice.

## Constraints (binding)

- **Engine-untouched applies per increment**, not globally: Increment A's qa-kit half, and nothing
  else in qa-kit work, may touch the engine. Engine changes land as their own increments and
  regenerate through `core/` + `build-adapter.sh` (never editing the committed generated files
  directly), keeping the Claude byte-oracle green.
- **qa-kit cannot reference engine files by path** (per-plugin `${CLAUDE_PLUGIN_ROOT}`). Cross-plugin
  coupling happens only through the shared project state in `.qa/runs/<run-id>/` or by qualified
  slug.
- All script changes keep the dual-engine idiom (jq preferred, python3 fallback, no
  `grep -P`/perl/node in bash paths) and must not break the existing characterization suites.
- Verdict/confidence/suspected-layer vocabularies are unchanged. No sixth verdict.

## Design

### Increment A — wire the two authorities into the operational flow (F1 + F2)

The packaging constraint shapes this: qa-kit cannot invoke the engine's `qa-verify.sh` by path, so
the wiring is split across the seam both plugins already share — the run directory.

**A1 (engine increment).** The engine finishes every run by running its own authority. Edit
`core/persona-body.md` (and `core/commands/qa-run.md` if the Report phase is described there): the
Report phase gains a mandatory final step — run
`${CLAUDE_PLUGIN_ROOT}/scripts/qa-verify.sh <run-id>` and treat its output as authoritative: any
override it emits replaces the recorded verdict in the report, and its verdict/confidence downgrades
are reflected in the tally. `qa-verify.sh` already writes its results into the run dir; the report
cites them. Regenerate adapters; byte-oracle updates with the regeneration.

**A2 (qa-kit increment).** `/qa-analyze` step 1 becomes "verify before analyzing":
1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/verify-plan.sh .qa/runs/<run-id>/checkpoint.json
   .qa/runs/<run-id>/checklist.json`. Non-zero exit → the analysis MUST lead with the out-of-plan
   criteria list; out-of-plan acts are a process violation finding, not a footnote.
2. Read the engine's qa-verify output from the run dir (written by A1). If it is absent (older run,
   engine not yet upgraded), say so explicitly in the analysis — "deterministic re-verification not
   found for this run" — never silently proceed as if verified.
The `qa-analyze-template.md` gains a fixed "Verification" section with three states: verified /
overridden (list) / not-verified (reason).

**A3.** Fix the `qa-scenarios.md` prose to say *where* verify-plan actually fires (in `/qa-analyze`),
so the promise and the wiring agree.

Tests: extend `tests/qa-kit-phases/run.sh` — the qa-analyze command text must reference
`verify-plan.sh` and the template must contain the Verification section; a negative fixture with an
out-of-plan criterion must make the documented invocation exit non-zero.

### Increment B — gate the engine suites in CI (F3)

New engine script `scripts/run-engine-ci.sh`, mirroring `run-qakit-ci.sh` exactly (single-source
enumerated list, per-suite echo header, fail-fast): seeded with the 7 measured-fast suites
(checkpoint, fold, action-trace, required-kinds, qa-verify, provenance, journal), then — as part of
this increment — each remaining non-qa-kit suite is probed once under `timeout 90`; every suite that
passes standalone joins the list, and each excluded suite gets a one-line reason comment in the
script (the honest-caps rule). `.github/workflows/adapters.yml` gains an `engine` job calling it.
The known-hanging suites stay excluded with their reasons on record; the doc-sync-todo item flips
from "deferred, maintainer decision" to "partially enrolled; remainder listed with reasons".

### Increment C — small correctness and doc fixes (F5–F9)

- **C1 (F6):** `checkpoint.sh` — add `node` to the header's dependency note ("node is required only
  when gating `human-action` kinds"), and in `gate_value_check`'s human-action branch check
  `command -v node` first, dying with a clear message ("human-action gating requires node; install it
  or record a non-pass verdict") instead of a raw command-not-found. Same guard in `qa-verify.sh`'s
  human-action path if it lacks one.
- **C2 (F5):** trim `checkpointing-qa-memory/SKILL.md` below 500 lines by moving its largest
  reference-grade section (the 38-item mini-eval block keeps ≥3 representative evals in-body; the
  rest moves to `references/mini-evals-extended.md`, one level deep — allowed).
- **C3 (F7):** `16 skills` → `17 skills` in `harnesses/pi/README.md`, `harnesses/codex/README.md`,
  `harnesses/opencode/README.md`, `docs/harness-adapters.md`. Pure doc fix; no generated file is
  involved (verify: these READMEs are not byte-oracle inputs). Tick the doc-sync-todo item.
- **C4 (F8):** on a `fail`/`error` upsert with no `--bug-ref`, emit a stderr `NOTE:` (mirroring the
  un-gated-pass note) — visible nudge, no rejection, no characterization break.
- **C5 (F9):** `cmd_resume` jq branch: `count=$(jq '.criteria | length // 0' ...)` so a missing
  array is an explicit 0, not a bash accident. `checklist_row_for`: unchanged behavior, but add a
  stderr note when >1 row matches the id (duplicate-id checklist is a plan bug worth surfacing).
- Tests: checkpoint suite gains cases for C1 (PATH without node + human-action kind → clear
  message), C4 (fail without bug-ref → NOTE on stderr), C5 (checkpoint.json with no `.criteria`;
  duplicate-id checklist).

### Increment D — first live accuracy run on a non-Claude harness (F4)

Operational, not code: execute the documented manual accuracy-run procedure
(`docs/harness-adapters.md`) once on **pi** (closest dispatch model to Claude), against a real target
app, engine + qa-kit co-installed. Deliverable: `docs/accuracy-runs/2026-XX-pi.md` recording harness
version, target, criteria count, verdict tally, every deviation from Claude behavior, and explicitly
which enforcement layers were active (no hooks on pi — lint + fingerprints only). Findings feed
later increments; this one only measures. Codex/opencode repeat later, one doc each.

## Sequencing

A (wire the authorities — highest safety value) → C (small, fast, independent) → B (CI breadth) →
D (operational, any time after A). A1/A2 land as separate PRs (engine PR first so A2's "read the
qa-verify output" has something to read in fresh runs).

## Out of scope

- **Mobile / React-Native driver abstraction** — a real direction (the capability-map driver layer
  already anticipates non-Playwright drivers) but its own brainstorm → spec: a new capability column
  (candidate driver: [Argent](https://github.com/software-mansion/argent), an MCP server with
  tap/type/UI-hierarchy/screenshot plus the diagnostic tier — network inspection and in-app JS
  eval), per-driver ADR-0015 gate semantics (human-path = tap/swipe/type; JS eval/adb/deep-link =
  lint/carve-out territory), and hook-matcher extensions. Not part of remediation.
- Hook-layer parity for non-Claude harnesses (revisit *after* Increment D produces measurements).
- Making `--bug-ref` mandatory on `fail` (rejected for now: breaks characterization; C4's note is
  the deliberate middle ground).

## Success criteria

1. A fresh interactive run ends with `qa-verify.sh` executed and its result in the report; a
   qa-kit run's `/qa-analyze` refuses to bury out-of-plan acts. 2. `adapters.yml` runs three jobs
   (adapters, qa-kit, engine) and the engine job gates ≥600 checks. 3. All four F7 files say 17;
   every SKILL.md body <500 lines. 4. A human-action pass attempt on a node-less host prints the
   clear message. 5. `docs/accuracy-runs/` contains the first pi run record.
