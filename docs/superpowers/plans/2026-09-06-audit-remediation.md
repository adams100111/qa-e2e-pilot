# Audit-Findings Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the gaps the 2026-09-06 deep audit found — wire the two unwired verification authorities into the live flow, gate the fast engine test suites in CI, and fix a set of small correctness/doc issues — without regressing any existing suite.

**Architecture:** Four independent increments. **A** adds a post-run verification step (engine runs `qa-verify.sh` at run end via a `core/` regeneration; a new qa-kit `/qa-verify` command runs `verify-plan.sh` and reads the engine's `verification.json` through shared run state). **B** adds a `run-engine-ci.sh` single-source CI job. **C** is small script/doc fixes. **D** is an operational accuracy run (separate, not code — tracked here but executed by a human/agent against a live app).

**Tech Stack:** Bash (dual-engine: jq preferred, python3 fallback — no `grep -P`/perl/node in bash paths), Node (only the existing `check-action-trace.js`), Markdown command/persona/template sources, GitHub Actions YAML, JSON test fixtures.

## Global Constraints

- **Engine-untouched is per-increment.** Only Increment A's A1 task and Increment C's engine-side tasks (C1, C2, C5) may touch engine files, and each does so deliberately. qa-kit tasks (A2, A3) MUST NOT touch engine files (`core/`, root `commands/`/`skills/`/`scripts/`, `qa-verify.sh`, `harness-profiles.json`, `build-adapter.sh`, `validate-adapters.sh`, the engine's `harnesses/<h>/*`, the byte-oracle inputs).
- **Engine content changes go through `core/`, never the committed generated files directly.** After editing `core/persona-body.md`, regenerate with `bash scripts/build-adapter.sh claude` (and the others) and commit the regenerated `agents/qa-e2e-pilot.md` + `commands/*.md`; `bash scripts/validate-adapters.sh` MUST stay green (the Claude byte-oracle).
- **qa-kit cannot reference engine files by path** (per-plugin `${CLAUDE_PLUGIN_ROOT}`). Cross-plugin data flows only through `.qa/runs/<run-id>/` (`checkpoint.json`, `checklist.json`, `verification.json`) or qualified slug.
- **Dual-engine idiom** in every new/edited script: `has_jq`/`has_py`/`die`, jq `-Sc` ⇔ python `json.dumps(sort_keys=True, separators=(",",":"))` for byte-identity, no `grep -P`/perl/node in bash.
- **Vocabulary unchanged.** Verdicts exactly `pass|fail|blocked|deferred|error`; confidence `high|low`; suspected layer `FE|route|service|migration|DB`. No sixth verdict.
- **Never weaken an existing gate or characterization suite.** Every task ends green on the suites it touches; the full `bash qa-kit/scripts/run-qakit-ci.sh` stays green after every qa-kit task.
- **Commit trailer:** end each commit body with the repo's required `Co-Authored-By` trailer. NEVER add any Claude/Anthropic attribution. Only push when the user asks.
- **No destructive git.** Never run any git operation that discards/reverts uncommitted work without explicit per-action user confirmation.

---

## File Structure

**Increment A (post-run verification wiring). Everything command/agent-shaped is generated-and-committed — edit the `core/`/manifest SOURCE, then regenerate; never hand-edit the committed `qa-kit/commands/*.md` or `qa-kit/agents/qa-kit.md`:**
- Modify: `core/persona-body.md` (engine Remember phase — add bare `scripts/qa-verify.sh` run) → regenerate `agents/qa-e2e-pilot.md` + `commands/*.md` via `build-adapter.sh`.
- Create: `qa-kit/core/commands/qa-verify.md` (tokenized source) → regenerate `qa-kit/commands/qa-verify.md`.
- Create: `qa-kit/templates/qa-verify-template.md` (copied verbatim; not token-checked).
- Modify (SOURCES): `qa-kit/core/commands/qa-scenarios.md` (prose), `qa-kit/core/commands/qa-status.md` (next-step ladder), `qa-kit/core/persona-body.md` (agent flow list), and all four `qa-kit/harnesses/*/manifest.tmpl` (the `constitution -> … -> run` flow-string → add `-> verify`) → regenerate `qa-kit/commands/*` + `qa-kit/agents/qa-kit.md`.
- Modify: `tests/qa-kit-phases/run.sh` (assert the wiring on the COMMITTED output).
- Verify after regen: `bash qa-kit/scripts/validate-qakit-adapters.sh` (byte-oracle) + `bash scripts/validate-adapters.sh` (engine byte-oracle).

**Increment B (CI breadth):**
- Create: `scripts/run-engine-ci.sh`
- Modify: `.github/workflows/adapters.yml` (add `engine` job), `docs/doc-sync-todo.md` (flip the deferred item)

**Increment C (small fixes):**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (C1 node dep+guard, C4 fail-note, C5 resume nit) → regenerate not needed (scripts aren't tokenized), but this is an engine skill file — allowed under C.
- Create: `skills/checkpointing-qa-memory/references/mini-evals-extended.md` (C2)
- Modify: `skills/checkpointing-qa-memory/SKILL.md` (C2 trim <500)
- Modify: `harnesses/pi/README.md`, `harnesses/codex/README.md`, `harnesses/opencode/README.md`, `docs/harness-adapters.md` (C3 "16"→"17"), `docs/doc-sync-todo.md` (tick)
- Modify: `tests/checkpoint/run.sh` (C1/C4/C5 cases)

**Increment D (accuracy run — operational):**
- Create: `docs/accuracy-runs/2026-XX-pi.md`

---

## Increment A — wire the two verification authorities

### Task A1: Engine runs qa-verify.sh at the end of every interactive run

**Files:**
- Modify: `core/persona-body.md` (Remember phase, currently the "5. **Remember**" bullet near line 49)
- Regenerate: `agents/qa-e2e-pilot.md`, `commands/qa-run.md`, `commands/qa-roles.md`, `commands/qa-resume.md` (via `build-adapter.sh`)
- Verify: `scripts/validate-adapters.sh`

**Interfaces:**
- Produces: an interactive run now writes `.qa/runs/<run-id>/verification.json` (already qa-verify.sh's output) as a mandatory step, so A2's `/qa-verify` has it to read on fresh runs.
- Consumes: `scripts/qa-verify.sh <run-id>` (unchanged; already writes `verification.json` and prints a one-line summary to stderr, exit non-zero if any pass was overridden).

- [ ] **Step 1: Confirm the current Remember phase text and byte-oracle baseline**

Run: `bash scripts/validate-adapters.sh && sed -n '49p' core/persona-body.md`
Expected: validate-adapters prints its success line (byte-oracle green); the sed prints the "5. **Remember**" bullet.

- [ ] **Step 2: Edit `core/persona-body.md` Remember phase**

Append to the end of the "5. **Remember**" bullet (after the existing "On resume: …" sentence) this sentence:

```
**At run end, run the out-of-agent authority:** invoke the plugin's `scripts/qa-verify.sh <run-id>` once (referenced bare, matching how this persona already names `scripts/preflight.sh`/`scripts/detect-stack.sh` — no `${CLAUDE_PLUGIN_ROOT}`, which the engine persona never uses and which would mis-render for non-Claude harnesses), after the last criterion is checkpointed. It re-checks every recorded `pass` against the captured toolstream and writes `.qa/runs/<run-id>/verification.json`; treat it as authoritative — any verdict it **overrides** replaces the recorded verdict in `report.md`/`report.html`, and any **confidence downgrade** it records flows into the tally. If it is skipped (no `jq`/`python3`, or the run had no passes), say so in the report rather than implying an independent re-check happened.
```

- [ ] **Step 3: Regenerate the adapters**

Run: `bash scripts/build-adapter.sh claude && bash scripts/build-adapter.sh codex && bash scripts/build-adapter.sh pi && bash scripts/build-adapter.sh opencode`
Expected: no error; `git status` shows `agents/qa-e2e-pilot.md` and `commands/*.md` modified (the committed Claude artifacts re-rendered from the new `core/`).

- [ ] **Step 4: Verify the byte-oracle still holds and no `{{token}}` leaked**

Run: `bash scripts/validate-adapters.sh`
Expected: success line printed; exit 0. (This proves the committed Claude files match the generator output byte-for-byte and no residual `{{` remains.)

- [ ] **Step 5: Grep-confirm the wiring landed in the generated agent**

Run: `grep -c 'qa-verify.sh <run-id>' agents/qa-e2e-pilot.md`
Expected: `1` (the Remember-phase instruction rendered into the committed agent).

- [ ] **Step 6: Commit**

```bash
git add core/persona-body.md agents/qa-e2e-pilot.md commands/
git commit -m "$(cat <<'EOF'
feat(engine): run qa-verify.sh at run end so interactive runs get the out-of-agent re-check

The deterministic authority was invoked only by qa-ci.sh; interactive runs
described it but never ran it. Remember phase now runs it and treats its
verification.json as authoritative. Regenerated adapters; byte-oracle green.

Co-Authored-By: <required trailer per repo>
EOF
)"
```

---

### Task A2: New `/qa-verify` qa-kit command + template

**Files:**
- Create: `qa-kit/core/commands/qa-verify.md` (TOKENIZED source — this is what the generator renders; use `{{PLUGIN_ROOT}}` for the scripts/templates root, NOT a literal `${CLAUDE_PLUGIN_ROOT}`)
- Regenerate: `qa-kit/commands/qa-verify.md` (Claude byte-oracle target — produced by `build-qakit-adapter.sh claude`, never hand-edited)
- Create: `qa-kit/templates/qa-verify-template.md` (templates are copied verbatim, NOT token-checked; `{{...}}` runtime fill-markers are fine here)
- Verify: `bash qa-kit/scripts/build-qakit-adapter.sh claude && bash qa-kit/scripts/validate-qakit-adapters.sh`

**CRITICAL packaging fact (self-review catch):** qa-kit is generated-and-committed exactly like the engine. `qa-kit/core/commands/*.md` are the tokenized sources; `qa-kit/commands/*.md` are the committed Claude byte-oracle target (`validate-qakit-adapters.sh` enforces `qa-kit/commands` == `build-qakit-adapter.sh claude` output, and fails on any residual `{{` in rendered commands/agent). So EVERY command/agent edit in A2+A3 goes in `core/` (or the manifests), then regenerate. Never hand-edit `qa-kit/commands/*.md` or `qa-kit/agents/qa-kit.md`.

**Interfaces:**
- Consumes (shared run state, per packaging constraint — never engine paths):
  - `${CLAUDE_PLUGIN_ROOT}/scripts/verify-plan.sh <checkpoint.json> <checklist.json>` → prints `{ok, outOfPlan:[ids], planned:<n>, acted:<n>}`, exit 0 iff every acted criterion is in the plan.
  - `.qa/runs/<run-id>/verification.json` — JSON array of `{criterionId, persona, verdict, confidence, reasons[...], ...}` records written by the engine's qa-verify.sh (A1). Records whose verdict != the checkpoint's recorded verdict are overrides.
  - `.qa/runs/<run-id>/checkpoint.json` (`{criteria:[{criterion_id,verdict,...}]}`) and `checklist.json` (top-level array of `{id,...}`).
- Produces: `.qa/specs/<target>/verification.md`; command exits non-zero if any out-of-plan act OR any override exists (so automation can gate), while the prose stays advisory in tone.

- [ ] **Step 1: Write `qa-kit/core/commands/qa-verify.md`** (the TOKENIZED source)

Model the frontmatter + structure on `qa-kit/core/commands/qa-analyze.md`. Use `{{PLUGIN_ROOT}}` wherever the command shells out to a qa-kit script or reads a qa-kit template (it renders to `${CLAUDE_PLUGIN_ROOT}` for Claude, `.pi/qa-kit` etc. for other harnesses). Content:

```markdown
---
description: The post-run verification surface for a qa-kit run — runs the out-of-plan-act check (verify-plan.sh) and surfaces the engine's deterministic re-verification (verification.json) as overrides. Reports; the deterministic results are authoritative.
argument-hint: <target>
disable-model-invocation: false
---

Produce `.qa/specs/<target>/verification.md` — the post-run verification of the latest run for
`<target>`. This is the **sixth** qa-kit step: constitution → spec → scenarios → analyze → run →
**verify** → status. Full input: `$ARGUMENTS` — the first token is `<target>`.

## What to do

1. **Resolve the run.** Find `<target>`'s latest run dir (its `runs.json` entry, else the newest
   `.qa/runs/<id>/` whose `checkpoint.json` covers this target). Require `checkpoint.json` +
   `checklist.json`. If no run exists, error and point at `/qa-run "<target>"`.

2. **Out-of-plan acts (verify-plan).** Run
   `bash "{{PLUGIN_ROOT}}/scripts/verify-plan.sh" .qa/runs/<id>/checkpoint.json .qa/runs/<id>/checklist.json`.
   Parse its JSON. A non-empty `outOfPlan[]` is a **process violation** — a criterion was acted that
   the frozen plan never authorized. List every offending id; do not bury it.

3. **Deterministic re-verification (engine).** Read `.qa/runs/<id>/verification.json`.
   - **Absent** → the engine did not run its out-of-agent re-check for this run (older run, or the
     engine ran without `jq`/`python3`). State this plainly: "deterministic re-verification not found
     for this run — its verdicts reflect the in-run agent's self-report only." Never imply verified.
   - **Present** → for each record, compare its `verdict` to the checkpoint's recorded verdict for the
     same `(criterionId, persona)`. Surface every **override** (verdict changed) and every
     **confidence downgrade** (`reasons[]` explains why), with the reason text.

4. **Write `verification.md`** from `{{PLUGIN_ROOT}}/templates/qa-verify-template.md`: the three
   states (verified / overridden / not-verified), the out-of-plan list, and per-override reasons.

5. **Report:** counts — out-of-plan acts, overrides, confidence downgrades — and the next step
   (`/qa-status "<target>"`). If any out-of-plan act or override exists, say so first.

Guardrails: read-only w.r.t. artifacts (never edits `checkpoint.json`/`checklist.json`/
`verification.json`); the deterministic results (verify-plan exit code, verification.json overrides)
are authoritative and are reported as facts, not opinions. The command exits non-zero when an
out-of-plan act or override exists so CI can gate; it does not itself mutate the run.
```

- [ ] **Step 2: Write `qa-kit/templates/qa-verify-template.md`**

```markdown
# Verification — {{target}}

**Run:** `{{run-id}}`  ·  **Checked:** {{n-passes}} passes  ·  **Planned criteria:** {{n-planned}}

## Out-of-plan acts
{{ one of: "None — every acted criterion was in the frozen plan." | a bullet list of offending
criterion ids, each: "`<id>` — acted but absent from checklist.json (process violation)." }}

## Deterministic re-verification
{{ one of:
  - "VERIFIED — the engine's qa-verify.sh re-checked every recorded pass; no verdict was overridden."
  - "OVERRIDDEN — the following passes were overridden by the out-of-agent authority:" + a list,
     each: "`<criterionId>`[@`<persona>`] — recorded `pass` → `<override-verdict>`; reason: <reason>."
  - "NOT VERIFIED — no verification.json for this run; verdicts reflect the in-run agent's self-report
     only. Re-run under an engine that emits verification.json for an independent re-check." }}

## Confidence downgrades
{{ "None." | per-criterion: "`<criterionId>` → confidence low; reason: <reason>." }}

## Verdict
{{ "clean — no out-of-plan acts, no overrides." | "attention — <n> out-of-plan act(s), <m> override(s); see above." }}

Next: `/qa-status "{{target}}"`.
```

- [ ] **Step 3: Regenerate the committed Claude command + confirm all harnesses render it**

Run: `bash qa-kit/scripts/build-qakit-adapter.sh claude && bash qa-kit/scripts/build-qakit-adapter.sh pi && ls qa-kit/dist/claude/commands/ qa-kit/dist/pi/commands/`
Then copy the regenerated Claude output into the committed tree the byte-oracle checks (the build writes `dist/`; the committed `qa-kit/commands/qa-verify.md` must equal `dist/claude/commands/qa-verify.md`). Inspect how the existing commands got committed (they are byte-identical to `dist/claude/commands/`); reproduce that for the new file — e.g. `cp qa-kit/dist/claude/commands/qa-verify.md qa-kit/commands/qa-verify.md`.
Expected: `qa-verify.md` present in both dist listings, no residual `{{` (the build fails loudly on any), and the committed file equals the Claude dist output. `{{PLUGIN_ROOT}}` rendered to `${CLAUDE_PLUGIN_ROOT}` for claude and to `.pi/qa-kit` for pi — confirm with `grep PLUGIN_ROOT qa-kit/commands/qa-verify.md` returning nothing and `grep -c CLAUDE_PLUGIN_ROOT qa-kit/commands/qa-verify.md` ≥ 1.

- [ ] **Step 4: Run the qa-kit adapter validator + full gate**

Run: `bash qa-kit/scripts/validate-qakit-adapters.sh && bash qa-kit/scripts/run-qakit-ci.sh`
Expected: byte-oracle green; `run-qakit-ci: all green` (nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add qa-kit/core/commands/qa-verify.md qa-kit/commands/qa-verify.md qa-kit/templates/qa-verify-template.md
git commit -m "feat(qa-kit): add /qa-verify post-run step (verify-plan + engine verification.json)"
```

---

### Task A3: Update the flow references (scenarios prose, status ladder, agent list) + phases test

**Files (edit the SOURCES, then regenerate — the committed files are byte-oracle targets):**
- Modify: `qa-kit/core/commands/qa-scenarios.md` (the prose line)
- Modify: `qa-kit/core/commands/qa-status.md` (next-step ladder)
- Modify: `qa-kit/core/persona-body.md` (the numbered flow list — this is the source of `qa-kit/agents/qa-kit.md`, generated via each `manifest.tmpl` + `{{PERSONA_BODY}}`)
- Modify: all four `qa-kit/harnesses/{claude,codex,pi,opencode}/manifest.tmpl` (the `description` flow-string `constitution -> spec -> scenarios -> analyze -> run` → add ` -> verify`)
- Regenerate + commit: `qa-kit/commands/qa-scenarios.md`, `qa-kit/commands/qa-status.md`, `qa-kit/agents/qa-kit.md`
- Modify: `tests/qa-kit-phases/run.sh` (assert /qa-verify wiring on the COMMITTED output)

**Interfaces:**
- Consumes: the `/qa-verify` command file from A2 (asserts its content).

- [ ] **Step 1: Write the failing test assertions in `tests/qa-kit-phases/run.sh`**

Append near the end of the suite (before the final `echo` tally), reusing its `check` helper and `ROOT`:

```bash
# A3: /qa-verify command exists and wires verify-plan + verification.json
QV="$ROOT/qa-kit/commands/qa-verify.md"
check "qa-verify command exists" "$([ -f "$QV" ] && echo y)" "y"
check "qa-verify references verify-plan.sh" "$(grep -c 'verify-plan.sh' "$QV")" "1"
check "qa-verify reads verification.json" "$(grep -c 'verification.json' "$QV")" "1"
QVT="$ROOT/qa-kit/templates/qa-verify-template.md"
check "qa-verify template has three states" \
  "$(grep -Eic 'VERIFIED|OVERRIDDEN|NOT VERIFIED' "$QVT")" "3"
# status ladder and agent flow name the new step
check "status names /qa-verify" "$(grep -c '/qa-verify' "$ROOT/qa-kit/commands/qa-status.md")" "1"
check "agent flow names /qa-verify" "$(grep -c 'qa-verify' "$ROOT/qa-kit/agents/qa-kit.md")" "1"
```

- [ ] **Step 2: Run the test to verify the new checks FAIL**

Run: `bash tests/qa-kit-phases/run.sh; echo "exit=$?"`
Expected: FAIL lines for "status names /qa-verify" and "agent flow names /qa-verify" (the command + template already exist from A2, so those pass; the status/agent edits are not yet made), non-zero exit.

- [ ] **Step 3: Edit `qa-kit/core/commands/qa-scenarios.md` prose**

Replace `at run time \`verify-plan.sh\` (beside \`qa-verify\`) flags any act on a criterion NOT in this plan.` with:

```
after the run, `/qa-verify` runs `verify-plan.sh` and flags any act on a criterion NOT in this plan.
```

- [ ] **Step 4: Edit `qa-kit/core/commands/qa-status.md` next-step ladder**

In the ordered checks, after the `analysis.md → analyze done` line and before/around the run line, add a `/qa-verify` rung:

```markdown
   - a `runs.json` entry or `.qa/runs/<id>/` for this spec → at least one run happened. If none (but
     scenarios present) → next step: **`/qa-run "<target>"`**.
   - `.qa/specs/<t>/verification.md` → post-run verify done. If absent (but a run exists) → next step:
     **`/qa-verify "<target>"`**.
```

- [ ] **Step 5: Edit `qa-kit/core/persona-body.md` flow list + all four `manifest.tmpl` flow-strings**

In `qa-kit/core/persona-body.md`, after the `5. **\`/qa-run\`**` line, add:

```markdown
6. **`/qa-verify`** *(later)* — post-run: run `verify-plan.sh` (out-of-plan acts) and surface the
   engine's `verification.json` overrides.
```

Update the trailing "Only `/qa-constitution` and `/qa-status` exist so far" note if present so it stays accurate. Then in each of `qa-kit/harnesses/{claude,codex,pi,opencode}/manifest.tmpl`, change the `description` flow-string `constitution -> spec -> scenarios -> analyze -> run` to `constitution -> spec -> scenarios -> analyze -> run -> verify`.

- [ ] **Step 6: Regenerate the committed qa-kit artifacts**

Run: `for h in claude codex pi opencode; do bash qa-kit/scripts/build-qakit-adapter.sh $h; done`
Then reproduce the committed-tree copy the byte-oracle expects (as in A2 Step 3): the committed `qa-kit/commands/*.md` and `qa-kit/agents/qa-kit.md` must equal `dist/claude/commands/*` and `dist/claude/agent/qa-kit.md`. Copy the regenerated Claude outputs over the committed files.
Expected: no residual `{{`; builds succeed for all four harnesses.

- [ ] **Step 7: Run the byte-oracle + the failing test (now passing) + full gate**

Run: `bash qa-kit/scripts/validate-qakit-adapters.sh && bash tests/qa-kit-phases/run.sh && bash qa-kit/scripts/run-qakit-ci.sh`
Expected: byte-oracle green (committed == generated); `qa-kit-phases: PASS=<n> FAIL=0`; `run-qakit-ci: all green`.

- [ ] **Step 8: Commit**

```bash
git add qa-kit/core/commands/qa-scenarios.md qa-kit/core/commands/qa-status.md qa-kit/core/persona-body.md qa-kit/harnesses/*/manifest.tmpl qa-kit/commands/ qa-kit/agents/qa-kit.md tests/qa-kit-phases/run.sh
git commit -m "feat(qa-kit): wire /qa-verify into scenarios prose, status ladder, agent flow (regenerated) + phases test"
```

---

## Increment B — gate the fast engine suites in CI

### Task B1: `scripts/run-engine-ci.sh` + adapters.yml engine job

**Files:**
- Create: `scripts/run-engine-ci.sh`
- Modify: `.github/workflows/adapters.yml`
- Modify: `docs/doc-sync-todo.md`

**Interfaces:**
- Consumes: `tests/<suite>/run.sh` for each enrolled suite (each self-contained, exits non-zero on failure).
- Produces: a one-command engine gate mirroring `qa-kit/scripts/run-qakit-ci.sh`.

- [ ] **Step 1: Probe every non-qa-kit suite once under a timeout to decide enrollment**

Run:
```bash
cd /home/dev/repos/qa-e2e-pilot
QAKIT="constitution spec-snapshot qa-kit-enforcement runconfig-merge data-baseline check-fixtures detect-seed auto-seed qa-kit-phases qakit-adapters qakit-install"
for d in tests/*/; do s=$(basename "$d"); case " $QAKIT " in *" $s "*) continue;; esac
  timeout 90 bash "$d/run.sh" >/dev/null 2>&1 && echo "OK   $s" || echo "SKIP $s (rc=$?)"; done
```
Expected: a list partitioning engine suites into OK (fast, self-contained) and SKIP (timed out / needs live app). Record it — the OK set seeds the SUITES list; each SKIP gets a one-line reason comment.

- [ ] **Step 2: Write `scripts/run-engine-ci.sh`**

Mirror `qa-kit/scripts/run-qakit-ci.sh` exactly (same header shape, `set -euo pipefail`, per-suite `echo "== tests/$d =="`, fail-fast loop). Seed `SUITES=(...)` with the OK set from Step 1 (at minimum the 7 audit-measured fast suites: `checkpoint fold action-trace required-kinds qa-verify provenance journal`, plus any other OK suites). Below the array, a comment block lists each excluded suite with its reason (honest-caps rule — silent truncation reads as "covered everything"):

```bash
#!/usr/bin/env bash
# One command to gate the ENGINE's self-contained test suites. THIS list is the single source of
# truth — CI (.github/workflows/adapters.yml) calls this script, so adding a suite here enrolls it.
# A blanket tests/*/run.sh glob is NOT used: some suites need a live browser/app and hang (measured
# 2-min timeout). Excluded suites and why (probed <under timeout 90>, 2026-09-06):
#   <suite> — <reason it is not gated here>
#   ...
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES=( checkpoint fold action-trace required-kinds qa-verify provenance journal <others-from-step-1> )
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  bash "$ROOT/tests/$d/run.sh"
done
echo "run-engine-ci: all green"
```

- [ ] **Step 3: Run it locally**

Run: `bash scripts/run-engine-ci.sh 2>&1 | tail -5`
Expected: each enrolled suite prints its PASS line; final `run-engine-ci: all green`; exit 0. (If any suite is flaky/slow, move it to the excluded comment with its reason — do not leave the gate red.)

- [ ] **Step 4: Add the `engine` job to `.github/workflows/adapters.yml`**

Mirror the existing `qa-kit` job. Add a third job:

```yaml
  engine:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: engine self-contained test suites
        run: bash scripts/run-engine-ci.sh
```

(Match the checkout action version and any `needs:`/setup steps the existing jobs use — read the file first and copy its conventions, including jq/python3/node availability which ubuntu-latest already provides.)

- [ ] **Step 5: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/adapters.yml')); print('yaml ok')"`
Expected: `yaml ok`. (If PyYAML is absent, use `python3 -c "import json"`-style check via a yaml-to-json tool, or skip with a note — GitHub will validate on push.)

- [ ] **Step 6: Flip the doc-sync-todo item**

In `docs/doc-sync-todo.md`, change the "Deferred (measured): the broader 44-suite tests corpus stays ungated" item from `- [ ]` to `- [x]` and append: "→ partially enrolled via `scripts/run-engine-ci.sh` (fast self-contained suites gated in CI; each excluded suite listed with its reason in that script)."

- [ ] **Step 7: Commit**

```bash
git add scripts/run-engine-ci.sh .github/workflows/adapters.yml docs/doc-sync-todo.md
git commit -m "ci(engine): gate self-contained engine suites via run-engine-ci.sh (single-source list)"
```

---

## Increment C — small correctness + doc fixes

### Task C1: Declare + guard the `node` dependency in checkpoint.sh

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh`
- Test: `tests/checkpoint/run.sh`

**Interfaces:**
- Consumes: `check-action-trace.js` (unchanged) via `node` in `gate_value_check`'s `human-action` branch (line ~626).

- [ ] **Step 1: Write the failing test — node-less host + human-action pass**

In `tests/checkpoint/run.sh`, add a case that runs a `pass` upsert with `--kinds human-action` on a PATH that has jq/python3 but not node, and asserts the stderr names node clearly and the exit is non-zero. Use the suite's existing fakebin/restricted-PATH pattern (grep the file for how it builds a restricted PATH; reuse it). Assert: `grep -qi 'node' <stderr>` and exit != 0, and NOT a raw "command not found".

- [ ] **Step 2: Run to verify it FAILS (raw command-not-found today)**

Run: `bash tests/checkpoint/run.sh 2>&1 | tail -3`
Expected: the new case FAILs (current behavior is a bare `node: command not found`, not the guarded message).

- [ ] **Step 3: Edit the header dependency note (line ~52)**

Change:
```
# DEPENDENCIES: bash, coreutils (date, mkdir, mv, cat), and EITHER jq OR python3
#               for safe JSON updates (jq preferred; python3 used as fallback).
```
to add a third line:
```
#               NODE is required ONLY when gating a `human-action` kind (the value-check
#               shells out to check-action-trace.js); no node needed otherwise.
```

- [ ] **Step 4: Guard the node call in `gate_value_check` (human-action branch, ~line 626)**

Before the `if ! node "$(dirname ...)/check-action-trace.js" ...` call, add:
```bash
      if ! command -v node >/dev/null 2>&1; then
        echo "EVIDENCE GATE: human-action gating requires 'node' (check-action-trace.js) but node is not on PATH — install node, or record a non-pass verdict." >&2
        return 1
      fi
```

- [ ] **Step 5: Run to verify the test PASSES**

Run: `bash tests/checkpoint/run.sh 2>&1 | tail -1`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 6: Commit**

```bash
git add skills/checkpointing-qa-memory/scripts/checkpoint.sh tests/checkpoint/run.sh
git commit -m "fix(checkpoint): declare + guard node dependency for human-action gating (clear error)"
```

---

### Task C2: Trim `checkpointing-qa-memory/SKILL.md` below 500 lines

**Files:**
- Create: `skills/checkpointing-qa-memory/references/mini-evals-extended.md`
- Modify: `skills/checkpointing-qa-memory/SKILL.md`

**Interfaces:** none (content only). The SKILL body must keep ≥3 mini-evals in-line and reference the extended file one level deep (`references/mini-evals-extended.md`).

- [ ] **Step 1: Confirm the current length and the mini-eval block range**

Run: `wc -l skills/checkpointing-qa-memory/SKILL.md && grep -n '^## Mini-Evals' skills/checkpointing-qa-memory/SKILL.md`
Expected: 517 lines; the Mini-Evals header at line ~331 (so the block is ~331-517, ~186 lines).

- [ ] **Step 2: Move all but the first 3 mini-evals into the references file**

Cut mini-evals 4..N (keep the first 3 representative ones in-body) into a new
`skills/checkpointing-qa-memory/references/mini-evals-extended.md` with a one-line H1 title. Do NOT alter the eval text; only relocate.

- [ ] **Step 3: Add a one-line pointer in SKILL.md after the retained evals**

```markdown
> Further worked mini-evals (the full bug-class set) live in [`references/mini-evals-extended.md`](references/mini-evals-extended.md).
```

- [ ] **Step 4: Verify the body is now < 500 lines and still has ≥3 evals**

Run: `wc -l skills/checkpointing-qa-memory/SKILL.md && grep -c '^\*\*Eval' skills/checkpointing-qa-memory/SKILL.md`
Expected: line count < 500; eval count ≥ 3.

- [ ] **Step 5: Validate frontmatter/JSON/refs are intact**

Run: `bash -n skills/checkpointing-qa-memory/scripts/*.sh 2>/dev/null; head -6 skills/checkpointing-qa-memory/SKILL.md`
Expected: frontmatter (`name:`/`description:`) unchanged; the reference link is exactly one level deep.

- [ ] **Step 6: Commit**

```bash
git add skills/checkpointing-qa-memory/SKILL.md skills/checkpointing-qa-memory/references/mini-evals-extended.md
git commit -m "docs(skill): split checkpointing-qa-memory mini-evals to references; body <500 lines"
```

---

### Task C3: Fix "16 skills" → "17 skills" in four files

**Files:**
- Modify: `harnesses/pi/README.md:3`, `harnesses/codex/README.md:3`, `harnesses/opencode/README.md:3`, `docs/harness-adapters.md:4`
- Modify: `docs/doc-sync-todo.md` (tick the item)

**Interfaces:** none. Confirm none of these four files are byte-oracle inputs (they are READMEs/docs, not `core/` or committed generated agent/command files) — safe to edit directly.

- [ ] **Step 1: Verify these files are not generator inputs**

Run: `grep -l '16 skills' harnesses/*/README.md docs/harness-adapters.md && grep -rn 'README' scripts/build-adapter.sh scripts/validate-adapters.sh | grep -i 'byte\|oracle\|diff' | head`
Expected: the four files listed; no evidence that harness READMEs feed the byte-oracle (the oracle checks `agents/` + `commands/`, per the validator).

- [ ] **Step 2: Replace the string in all four files**

Change `same 16 skills` → `same 17 skills` in the three harness READMEs and `docs/harness-adapters.md`.

- [ ] **Step 3: Tick the doc-sync-todo item (line ~37)**

Change the `- [ ] **(engine-doc item — NOT a qa-kit change)** the per-harness engine adapter READMEs …16…→17…` item to `- [x]` with a "(done 2026-09-06)" note.

- [ ] **Step 4: Verify no "16 skills" remains and adapters still validate**

Run: `grep -rn '16 skills' harnesses/ docs/ ; bash scripts/validate-adapters.sh`
Expected: no matches from grep; validate-adapters prints success (unaffected — these files aren't oracle inputs).

- [ ] **Step 5: Commit**

```bash
git add harnesses/pi/README.md harnesses/codex/README.md harnesses/opencode/README.md docs/harness-adapters.md docs/doc-sync-todo.md
git commit -m "docs: correct '16 skills' -> '17 skills' in harness READMEs + harness-adapters"
```

---

### Task C4: Note a `fail`/`error` upsert with no `--bug-ref`

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (`cmd_upsert`, after verdict validation ~line 911)
- Test: `tests/checkpoint/run.sh`

**Interfaces:** none. Behavior: a stderr `NOTE:` only — no rejection, no record change, mirroring the existing un-gated-pass note.

- [ ] **Step 1: Write the failing test**

In `tests/checkpoint/run.sh`, add a case: upsert `fail` with no `--bug-ref`; assert the record still writes (exit 0) AND stderr contains a `NOTE:` mentioning `bug-ref`/`suspected layer`. Add a companion case: `fail` WITH `--bug-ref X` emits NO such note.

- [ ] **Step 2: Run to verify it FAILS (no note today)**

Run: `bash tests/checkpoint/run.sh 2>&1 | tail -3`
Expected: the "fail-without-bug-ref emits NOTE" case FAILs.

- [ ] **Step 3: Add the note in `cmd_upsert`**

After the verdict `case` validation and the `[[ -n "$nonui_reason" ]] && confidence="low"` line, add:
```bash
  # A fail/error should carry a bug-log ref (which is where the suspected layer lives). Not
  # mandatory (would break characterization), but surface a visible nudge — mirrors the
  # un-gated-pass NOTE.
  if [[ "$verdict" == "fail" || "$verdict" == "error" ]] && [[ -z "$bug_ref" ]]; then
    echo "NOTE: ${verdict} recorded for '${crit_id}' with no --bug-ref — the bug-log entry is where the suspected layer (FE|route|service|migration|DB) is recorded; add one for a complete failure trail." >&2
  fi
```
Note: `$bug_ref` is parsed in the `while` options loop below the validation, so this check must go AFTER that loop. Place it just before the `local kinds_json="[]"` line (after option parsing, alongside the other post-parse validations).

- [ ] **Step 4: Run to verify PASSES**

Run: `bash tests/checkpoint/run.sh 2>&1 | tail -1`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add skills/checkpointing-qa-memory/scripts/checkpoint.sh tests/checkpoint/run.sh
git commit -m "feat(checkpoint): NOTE on fail/error recorded without --bug-ref (suspected-layer nudge)"
```

---

### Task C5: Harden `cmd_resume` missing-`.criteria` + duplicate-id note

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (`cmd_resume` ~line 292; `checklist_row_for` ~line 722)
- Test: `tests/checkpoint/run.sh`

- [ ] **Step 1: Write the failing tests**

Two cases in `tests/checkpoint/run.sh`: (a) `--resume` on a `checkpoint.json` that is `{}` (no `.criteria`) exits 1 with the "no criteria" message and does NOT crash; (b) a `checklist.json` with two rows sharing an `id`, on a `pass` upsert for that id, emits a stderr note about the duplicate. (For (a), assert clean exit-1 + message; for (b), assert the note appears.)

- [ ] **Step 2: Run to verify current behavior**

Run: `bash tests/checkpoint/run.sh 2>&1 | tail -3`
Expected: case (a) may pass already by accident (`[[ null -eq 0 ]]`); case (b) FAILs (no duplicate note today). The point of (a) is to lock the behavior so the refactor in Step 3 can't regress it.

- [ ] **Step 3: Make `.criteria` length explicit in `cmd_resume` jq branch (~line 292)**

Change `count=$(jq '.criteria | length' "$file")` to `count=$(jq '(.criteria // []) | length' "$file")` so a missing array is an explicit 0 rather than relying on bash's `[[ null -eq 0 ]]`.

- [ ] **Step 4: Add a duplicate-id note in `checklist_row_for` (~line 722)**

After selecting the first matching row, when jq/python finds >1 match for the id, emit to stderr: `NOTE: checklist.json has N rows with id '<crit_id>' — using the first; a duplicate criterion id is a plan bug.` Keep the RETURN value (first row) unchanged so no gate behavior shifts. (In the jq branch, compute the count with a second expression; in python, `len([r for r ...])`.)

- [ ] **Step 5: Run to verify PASSES**

Run: `bash tests/checkpoint/run.sh 2>&1 | tail -1`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 6: Full checkpoint + qa-verify regression (these two suites exercise checkpoint.sh + gate)**

Run: `bash tests/checkpoint/run.sh >/dev/null 2>&1 && echo cp-ok; bash tests/qa-verify/run.sh >/dev/null 2>&1 && echo qv-ok`
Expected: `cp-ok` and `qv-ok`.

- [ ] **Step 7: Commit**

```bash
git add skills/checkpointing-qa-memory/scripts/checkpoint.sh tests/checkpoint/run.sh
git commit -m "fix(checkpoint): explicit .criteria//[] on resume; note duplicate checklist ids"
```

---

## Increment D — first live accuracy run on a non-Claude harness (operational)

### Task D1: Execute + record the pi accuracy run

**Files:**
- Create: `docs/accuracy-runs/2026-XX-pi.md`

**This task is operational, not code** — it requires the pi harness, a live target app, and both plugins co-installed. It cannot be completed by a headless code subagent. Track it here; execute it manually (or with an interactive agent driving pi against a real app).

- [ ] **Step 1: Co-install engine + qa-kit for pi into a target project**

Follow `docs/harness-adapters.md`: run `harnesses/pi/install-pi.sh <project>` then `qa-kit/harnesses/pi/install-pi.sh <project>` (the qa-kit installer aborts if the engine skills dir is absent — install engine first).

- [ ] **Step 2: Run the full qa-kit flow against a real feature**

`/qa-constitution` → `/qa-spec` → `/qa-scenarios` → `/qa-analyze` → `/qa-run` → `/qa-verify` → `/qa-status`, on a disposable-env target with at least a few computed/human-action criteria.

- [ ] **Step 3: Record `docs/accuracy-runs/2026-XX-pi.md`**

Capture: pi harness version, target app + commit, criteria count, verdict tally, every deviation from Claude behavior, and explicitly which enforcement layers were active (no block-hook/capture-hook on pi → lint + fingerprints + `--save-session` floor only, no live-hook tier). List any bug the run surfaced in the plugins themselves.

- [ ] **Step 4: Commit**

```bash
git add docs/accuracy-runs/2026-XX-pi.md
git commit -m "docs(accuracy): first live pi accuracy run — findings + active enforcement layers"
```

---

## Sequencing

**A1 → A2 → A3 → C1 → C4 → C5 → C2 → C3 → B1 → D1.**

- A1 (engine PR) lands first so a fresh run emits `verification.json` for A2 to read. A1/A2/A3 can be one PR or three; A1 must precede A2's merge.
- The C tasks are independent of A/B and of each other except C1/C4/C5 all edit `checkpoint.sh` — do them in sequence (C1, then C4, then C5) to avoid edit conflicts, each with its own test + commit.
- B1 is independent; do it after C so the engine suites it enrolls include any C-touched behavior.
- D1 is operational and can happen any time after A merges (it exercises `/qa-verify`).

## Self-Review

- **Spec coverage:** F1+F2 → Increment A (corrected: new `/qa-verify` post-run step + engine run-end qa-verify). F3 → Increment B. F5 → C2. F6 → C1. F7 → C3. F8 → C4. F9 → C5. F4 → Increment D. All eight findings mapped.
- **Placeholder scan:** the two YAML/command bodies and every script edit show the actual text; the only intentional TBD is `2026-XX` in the D1 filename (a real run date) and `<others-from-step-1>` in B1's SUITES (resolved by B1 Step 1's probe, which is a real command, not a placeholder).
- **Type/name consistency:** `/qa-verify` command file, `qa-verify-template.md`, `verification.md` output, and `verification.json` (engine's, read-only) are named consistently across A1/A2/A3 and the tests. `verify-plan.sh`'s JSON keys (`outOfPlan`, `ok`, `planned`, `acted`) match its header. The checkpoint edits reference real line anchors (~52, ~292, ~626, ~722, ~911) and the real function names (`cmd_upsert`, `gate_value_check`, `cmd_resume`, `checklist_row_for`).

## Execution Handoff

Two execution options:
1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks. NOTE: this session's subagent budget is exhausted (200/200); subagent-driven needs a fresh session or a raised `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`.
2. **Inline Execution** — execute tasks in this session with checkpoints (works now).
