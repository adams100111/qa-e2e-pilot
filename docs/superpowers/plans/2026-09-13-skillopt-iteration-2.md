# SkillOpt Stack-Profile Iteration 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore cross-version CI, expand the stack-profile benchmark, run multiple bounded SkillOpt seeds, and promote nothing unless the validation gate proves a general improvement.

**Architecture:** First make the existing cost-summary jq reducer parse on jq 1.6 and 1.8. Then enlarge only the train and validation datasets with distinct synthetic repositories and strict Pydantic-validated assertions. A Python experiment driver invokes the existing lifecycle commands for fixed seeds, summarizes validation evidence, and leaves the final test sealed unless a candidate passes every gate.

**Tech Stack:** Bash 3.2-compatible orchestration, jq 1.6+, Python 3.12, Pydantic v2, SkillOpt, JSON, YAML.

**Spec:** `docs/superpowers/specs/2026-09-13-skillopt-stack-profile-pilot-design.md`

## Global Constraints

- Preserve all uncommitted files and existing worktrees; use no destructive VCS command.
- Keep `skills/detecting-stack-profile/SKILL.md` unchanged until a separate adoption decision.
- Keep target network and web search disabled and automatic adoption off.
- Do not expose test items to training, reflection, or selection.
- Do not run the post-training final test unless a candidate improves validation hard score with zero per-item regression.
- Use strict Pydantic models for benchmark data; keep Bash limited to repository-native lifecycle dispatch.
- Commit reproducible harness, fixtures, tests, and documentation only; ignore model outputs.

---

### Task 1: Restore jq 1.6 CI portability

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/cost-summary.sh`
- Modify: `tests/cost-summary/run.sh`

**Interfaces:**
- Consumes: sorted boundary and timestamp JSON arrays.
- Produces: `attribute_jq(bounds_json, ts_json)` with byte-equivalent jq 1.6+, jq 1.8, and Python behavior.

- [x] **Step 1: Reproduce the failure with jq 1.6**

Run the existing cost-summary suite with an isolated jq 1.6 binary first on `PATH`.
Expected: the reducer fails to parse at `) as $acc`, reproducing the GitHub job.

- [x] **Step 2: Add a jq compatibility regression check**

Extend the test runner so an optional `JQ_COMPAT_BIN` runs the full fixture through that executable and asserts `toolCalls == 7`, `C1 == 3`, and `C2 == 2`.

- [x] **Step 3: Verify the new check is red**

Run: `JQ_COMPAT_BIN=/tmp/jq-1.6 bash tests/cost-summary/run.sh`
Expected: FAIL in the compatibility case before production code changes.

- [x] **Step 4: Parenthesize the reduce expression**

Change the jq program from `reduce ... ) as $acc` to `(reduce ... )) as $acc`; this is accepted by jq 1.6 and retains the same accumulator value.

- [x] **Step 5: Verify both engines**

Run: `JQ_COMPAT_BIN=/tmp/jq-1.6 bash tests/cost-summary/run.sh`
Expected: `FAIL=0`, including the existing Python fallback checks.

- [x] **Step 6: Commit**

Commit message: `fix: support jq 1.6 in cost summary`

### Task 2: Expand train and validation evidence

**Files:**
- Create: `tools/skillopt-pilot/fixtures/{django,spring,express,rails,vue,static}/**`
- Modify: `tools/skillopt-pilot/data/train/items.json`
- Modify: `tools/skillopt-pilot/data/val/items.json`
- Modify: `tests/skillopt-pilot/test_core.py`

**Interfaces:**
- Consumes: the canonical detector's `detect-stack.sh --repo <path>` JSON contract.
- Produces: 8–12 train items and 4–6 validation items with unique IDs, semantic hashes, fixtures, and dotted-path assertions.

- [x] **Step 1: Add failing corpus-size and uniqueness tests**

Assert at least 8 train cases and 4 validation cases, while retaining duplicate-ID, fixture-existence, and cross-split semantic-overlap checks.

- [x] **Step 2: Verify the corpus-size test is red**

Run: `python3 -m unittest tests/skillopt-pilot/test_core.py -v`
Expected: FAIL because train has 2 items and validation has 2.

- [x] **Step 3: Add synthetic framework fixtures and assertions**

Add code-only fixtures spanning Python, Java, Node, Ruby, client-only, and static/unknown shapes. Derive expected values by running the canonical detector, then encode only stable semantic assertions such as framework, playbook, signal, routing strategy, ORM, auth, and i18n presence.

- [x] **Step 4: Verify deterministic data validation**

Run: `python3 -m unittest tests/skillopt-pilot/test_core.py tests/skillopt-pilot/test_integration.py -v`
Expected: all tests pass and no test fixture appears in train or validation.

- [x] **Step 5: Commit**

Commit message: `test(skillopt): expand stack-profile benchmark corpus`

### Task 3: Add repeatable multi-seed experiment tracking

**Files:**
- Create: `tools/skillopt-pilot/experiment.py`
- Modify: `tools/skillopt-pilot/run.sh`
- Modify: `tools/skillopt-pilot/README.md`
- Modify: `tests/skillopt-pilot/test_integration.py`
- Modify: `tests/skillopt-pilot/run.sh`

**Interfaces:**
- Consumes: fixed seeds, training summaries, selection rollout score files, and ignored output roots.
- Produces: one isolated run per seed plus `iteration-summary.json` containing scores, gate decisions, candidate hashes, and eligibility.

- [x] **Step 1: Write failing summary and dispatch tests**

Test that only candidates with improved validation hard score and no per-item regression are eligible, that missing/corrupt artifacts fail closed, and that `run.sh experiment` dispatches without invoking `final`.

- [x] **Step 2: Verify the tests are red**

Run the Python integration and shell acceptance suites.
Expected: FAIL because the experiment module and mode do not exist.

- [x] **Step 3: Implement the minimal Python experiment driver**

Use Pydantic models to validate run summaries. Run seeds `42`, `314`, and `2718` in isolated output directories, compare each candidate against its own baseline selection results, and emit an atomic JSON summary. Never invoke the final mode.

- [x] **Step 4: Verify the tests are green**

Run the Python integration, shell acceptance, and suite-coverage checks.
Expected: all pass.

- [x] **Step 5: Commit**

Commit message: `feat(skillopt): add multi-seed experiment tracking`

### Task 4: Execute iteration two and apply the sealed gate

**Files:**
- Create ignored artifacts: `outputs/skillopt/stack-profile/iteration-2/**`
- Modify canonical skill only after a separate explicit adoption decision.

**Interfaces:**
- Consumes: Tasks 1–3 and installed SkillOpt revision `79124b37e9a6371e13b753f8bcd7adb1e493ade1`.
- Produces: three-seed evidence, a gate decision, and—only for an eligible candidate—one final held-out evaluation.

- [ ] **Step 1: Run three bounded seeds**

Run: `bash tools/skillopt-pilot/run.sh experiment`
Expected: three isolated run records and one validated summary.

- [ ] **Step 2: Audit test sealing and exact candidate diffs**

Confirm training configurations have `eval_test: false`, no training artifact contains a test item ID, and each proposed edit is general rather than fixture-specific.

- [ ] **Step 3: Apply the validation gate**

If no candidate improves hard score without per-item regression, record `no-candidate` and stop. If one or more qualify, select the strongest stable candidate by hard score, then soft score, then smallest edit.

- [ ] **Step 4: Conditionally run final exactly once**

Only for the selected eligible candidate, evaluate the unchanged test split once and record per-item and aggregate deltas. Do not adopt automatically.

- [ ] **Step 5: Run all repository gates**

Run adapter validation, suite coverage, full engine CI, QA-kit CI, and pilot tests. Expected: all green locally and in GitHub Actions.

- [ ] **Step 6: Record results and commit reproducible updates**

Update the assessment with seeds, scores, exact gate decision, final-test status, and next recommendation. Keep generated outputs ignored.

### Task 5: Land through the repository workflow

**Files:**
- No additional production files.

**Interfaces:**
- Consumes: a clean verified branch.
- Produces: a merged pull request or an explicit evidence-backed stop if checks fail.

- [ ] **Step 1: Verify branch status and complete test evidence**
- [ ] **Step 2: Push the branch and create a pull request against `main`**
- [ ] **Step 3: Wait for required GitHub checks and diagnose failures**
- [ ] **Step 4: Merge with a normal merge commit and request branch deletion only after checks pass**
